import XCTest
import simd
@testable import Lumora

/// The player kernel against a double-precision CPU reference, from exact code values: bit depth, range, matrix,
/// transfer, primaries, chroma siting. Frames are built in memory, or come through the real FFmpeg / AVFoundation
/// decode paths from lossless files.
final class PlayerColorMathTests: XCTestCase {
    let renderer = PlayerRenderer()

    override func setUp() async throws { try TestHardware.requireGPU() }

    // MARK: Reference

    struct Ref {
        static func luma(_ m: Int) -> (Double, Double) {
            switch m {
            case 1: return (0.2126, 0.0722)
            case 5, 6: return (0.299, 0.114)
            default: return (0.2627, 0.0593)
            }
        }

        /// Code values → R'G'B' (normalized, unclamped).
        static func rgbPrime(y: Double, cb: Double, cr: Double, bits: Int, full: Bool, matrix: Int) -> SIMD3<Double> {
            let s = pow(2, Double(bits - 8)), maxC = pow(2, Double(bits)) - 1
            let Y = full ? y / maxC : (y - 16 * s) / (219 * s)
            let Cb = full ? (cb - pow(2, Double(bits - 1))) / maxC : (cb - 128 * s) / (224 * s)
            let Cr = full ? (cr - pow(2, Double(bits - 1))) / maxC : (cr - 128 * s) / (224 * s)
            let (kr, kb) = luma(matrix)
            let kg = 1 - kr - kb
            return SIMD3(Y + 2 * (1 - kr) * Cr, Y - 2 * kb * (1 - kb) / kg * Cb - 2 * kr * (1 - kr) / kg * Cr, Y + 2 * (1 - kb) * Cb)
        }

        static func hlgInv(_ v: Double) -> Double {
            let a = 0.17883277, b = 0.28466892, c = 0.55991073
            return v <= 0.5 ? v * v / 3 : (exp((v - c) / a) + b) / 12
        }

        /// R'G'B' → linear BT.2020, in units of reference white (what the kernel writes), no tone mapping.
        static func output(_ rgb: SIMD3<Double>, transfer: Int, primaries: Int, refWhite: Double, hlgLw: Double, srcPeak: Double) -> SIMD3<Double> {
            var nits: SIMD3<Double>
            let e = simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1))
            switch transfer {
            case 16: nits = SIMD3(PlayerRenderer.pqInverse(e.x), PlayerRenderer.pqInverse(e.y), PlayerRenderer.pqInverse(e.z))
            case 18:
                let sc = SIMD3(hlgInv(e.x), hlgInv(e.y), hlgInv(e.z))
                let w: SIMD3<Double> = primaries == 9 ? SIMD3(0.2627, 0.6780, 0.0593) : SIMD3(0.2126, 0.7152, 0.0722)
                let ys = simd_dot(w, sc)
                let g = PlayerRenderer.hlgGamma(hlgLw)
                nits = ys > 0 ? hlgLw * pow(ys, g - 1) * sc : .zero
            default:
                let p = simd_max(rgb, SIMD3(repeating: 0))
                nits = SIMD3(pow(p.x, 2.4), pow(p.y, 2.4), pow(p.z, 2.4)) * refWhite
            }
            let m = ColorScience.matrix(from: primaries == 9 ? .rec2020 : .rec709, to: .rec2020)
            let md = simd_double3x3(columns: (SIMD3<Double>(m.columns.0), SIMD3<Double>(m.columns.1), SIMD3<Double>(m.columns.2)))
            let lin = simd_min(md * nits, SIMD3(repeating: srcPeak))
            return lin / refWhite
        }
    }

    // MARK: Building frames in memory

    /// A planar frame filled by `sample(plane, x, y)` (LSB-aligned code values).
    func planarFrame(w: Int, h: Int, bits: Int, chroma: PlayerChroma, color: SignalColor, sample: (Int, Int, Int) -> Int) -> PlayerFrame {
        let bytes = bits > 8 ? 2 : 1
        let l = FrameLayout.planar(width: w, height: h, chroma: chroma, sampleBytes: bytes, bits: bits)
        let pool = BufferPool(device: MetalContext.shared.device, length: l.frameBytes, capacity: 2)
        let b = pool.acquire()!
        for plane in 0..<3 {
            let (pw, ph) = plane == 0 ? (w, h) : (l.chromaWidth, l.chromaHeight)
            for y in 0..<ph {
                for x in 0..<pw {
                    let v = sample(plane, x, y)
                    let off = l.offsets[plane] + y * l.strides[plane] + x * bytes
                    if bytes == 2 { b.bytes.storeBytes(of: UInt16(v), toByteOffset: off, as: UInt16.self) }
                    else { b.bytes.storeBytes(of: UInt8(v), toByteOffset: off, as: UInt8.self) }
                }
            }
        }
        return PlayerFrame(index: 0, pts: 0, layout: l, planes: .buffer(b), color: color)
    }

    func info(for f: PlayerFrame, maxCLL: Double? = nil) -> MediaInfo {
        var i = MediaInfo(url: URL(fileURLWithPath: "/tmp/x.y4m"), container: "y4m")
        i.video.width = f.layout.width; i.video.height = f.layout.height
        i.video.color = f.color
        if let maxCLL { i.video.hdr = HDRStatic(mdcvMaxNits: 10000, maxCLL: maxCLL) }
        return i
    }

    /// Renders 1:1 with a display that can show everything (no tone mapping), returns the output pixels.
    func render(_ f: PlayerFrame, headroom: Double = 100, maxCLL: Double? = nil, settings: PlayerSettings = PlayerSettings(),
                outputMode: Int32 = Int32(PLAYER_OUT_EXTENDED_LINEAR)) throws -> ([SIMD4<Float>], PlayerUniforms) {
        let (u, _) = PlayerRenderer.uniforms(frame: f, info: info(for: f, maxCLL: maxCLL), display: DisplayState(headroom: headroom),
                                             settings: settings, interpret: .auto,
                                             viewport: SIMD4(0, 0, Float(f.layout.width), Float(f.layout.height)), outputMode: outputMode)
        return (PlayerRenderer.readBack(try renderer.render(frame: f, uniforms: u)), u)
    }

    func assertClose(_ got: SIMD4<Float>, _ want: SIMD3<Double>, _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        for k in 0..<3 {
            let g = Double(got[k]), w = want[k]
            let tol = max(1e-3 * abs(w), 2e-5)
            XCTAssertLessThanOrEqual(abs(g - w), tol, "\(msg) channel \(k): got \(g), want \(w)", file: file, line: line)
        }
    }

    // MARK: Tests

    /// Every combination of depth, chroma format, range and transfer on neutral and colored patches.
    func testCodeValuesToLinearLightMatchTheReference() throws {
        let patches: [(Double, Double, Double)] = [(0.06, 0.5, 0.5), (0.3, 0.5, 0.5), (0.5, 0.5, 0.5), (0.75, 0.5, 0.5), (0.92, 0.5, 0.5),
                                                   (0.45, 0.30, 0.70), (0.60, 0.65, 0.40), (0.35, 0.55, 0.25), (0.80, 0.42, 0.58)]
        for bits in [8, 10, 12] {
            for chroma in [PlayerChroma.c420, .c422, .c444] {
                for full in [false, true] {
                    for (transfer, primaries, matrix) in [(16, 9, 9), (18, 9, 9), (1, 1, 1)] {
                        let maxC = Double((1 << bits) - 1)
                        // Normalized patch → code values in the chosen range.
                        let codes: [(Int, Int, Int)] = patches.map { p in
                            if full { return (Int((p.0 * maxC).rounded()), Int((p.1 * maxC).rounded()), Int((p.2 * maxC).rounded())) }
                            let s = Double(1 << (bits - 8))
                            return (Int((16 * s + p.0 * 219 * s).rounded()), Int((16 * s + p.1 * 224 * s).rounded()), Int((16 * s + p.2 * 224 * s).rounded()))
                        }
                        let pw = 8, w = pw * codes.count, h = 4
                        let (sx, sy) = chroma.subsampling
                        var color = SignalColor(primaries: primaries, transfer: transfer, matrix: matrix, fullRange: full, chromaLocation: .left,
                                                primariesTagged: true, transferTagged: true, matrixTagged: true, rangeTagged: true)
                        color.resolve(height: 1080, chroma: chroma)
                        let f = planarFrame(w: w, h: h, bits: bits, chroma: chroma, color: color) { plane, x, _ in
                            let n = plane == 0 ? x / pw : (x * sx) / pw
                            _ = sy
                            return plane == 0 ? codes[n].0 : plane == 1 ? codes[n].1 : codes[n].2
                        }
                        let (px, u) = try render(f)
                        for (n, c) in codes.enumerated() {
                            let rgb = Ref.rgbPrime(y: Double(c.0), cb: Double(c.1), cr: Double(c.2), bits: bits, full: full, matrix: matrix)
                            let want = Ref.output(rgb, transfer: transfer, primaries: primaries, refWhite: Double(u.refWhite),
                                                  hlgLw: Double(u.hlgLw), srcPeak: Double(u.srcPeak))
                            let x = n * pw + pw / 2 - 2            // even column: chroma sample exactly on it (left siting)
                            assertClose(px[(h / 2) * w + x], want, "\(bits)-bit \(chroma) \(full ? "full" : "limited") tf \(transfer) patch \(n)")
                        }
                    }
                }
            }
        }
    }

    /// PQ code values for the classic reference levels decode to those nits.
    func testPQReferenceLevels() throws {
        let levels: [Double] = [0.1, 1, 10, 100, 203, 1000, 4000, 10000]
        let codes = levels.map { Int((64 + 876 * PlayerRenderer.pq($0)).rounded()) }
        let color = SignalColor(primaries: 9, transfer: 16, matrix: 9, chromaLocation: .left, primariesTagged: true, transferTagged: true, matrixTagged: true)
        let f = planarFrame(w: 8 * levels.count, h: 2, bits: 10, chroma: .c444, color: color) { p, x, _ in p == 0 ? codes[x / 8] : 512 }
        let (px, u) = try render(f, maxCLL: 10000)
        XCTAssertEqual(u.srcPeak, 10000)
        for (n, nits) in levels.enumerated() {
            // The code value is quantized to 10 bits, so compare with that code's exact nits, and the level within 1 %.
            let exact = PlayerRenderer.pqInverse((Double(codes[n]) - 64) / 876)
            XCTAssertEqual(Double(px[n * 8 + 4].x) * Double(u.refWhite), exact, accuracy: max(1e-3 * exact, 1e-4), "\(nits) nits")
            XCTAssertEqual(exact, nits, accuracy: nits * 0.03 + 0.002, "10-bit quantization")
        }
    }

    /// Bilinear chroma at each siting: alternating chroma columns, sampled on and between chroma positions.
    func testChromaSitingInterpolation() throws {
        for loc in [ChromaLocation.left, .center, .topLeft] {
            let w = 16, h = 8
            var color = SignalColor(primaries: 9, transfer: 16, matrix: 9, chromaLocation: loc, primariesTagged: true, transferTagged: true,
                                    matrixTagged: true, chromaLocationTagged: true)
            color.resolve(height: 1080, chroma: .c420)
            let cbCols = [300, 700]
            let f = planarFrame(w: w, h: h, bits: 10, chroma: .c420, color: color) { p, x, y in
                p == 0 ? 500 : p == 1 ? cbCols[x % 2] : 512 + (y % 2) * 100
            }
            var s = PlayerSettings(); s.referenceWhite = 100
            let (u, _) = PlayerRenderer.uniforms(frame: f, info: info(for: f), display: DisplayState(headroom: 100), settings: s, interpret: .auto,
                                                 viewport: SIMD4(0, 0, Float(w), Float(h)), outputMode: Int32(PLAYER_OUT_CODES))
            let px = PlayerRenderer.readBack(try renderer.render(frame: f, uniforms: u))
            for y in 2..<6 {
                for x in 2..<14 {
                    // Expected chroma-plane coordinate (texel centers at k + 0.5), bilinear between the neighbors.
                    let cx = (Double(x) + 0.5) / 2 + Double(loc.offset(horizontal: true, subsampling: 2)) - 0.5
                    let cy = (Double(y) + 0.5) / 2 + Double(loc.offset(horizontal: false, subsampling: 2)) - 0.5
                    let x0 = Int(floor(cx)), fx = cx - floor(cx), y0 = Int(floor(cy)), fy = cy - floor(cy)
                    func cb(_ i: Int) -> Double { Double(cbCols[max(0, min(7, i)) % 2]) }
                    func cr(_ j: Int) -> Double { Double(512 + (max(0, min(3, j)) % 2) * 100) }
                    let wantCb = cb(x0) * (1 - fx) + cb(x0 + 1) * fx
                    let wantCr = cr(y0) * (1 - fy) + cr(y0 + 1) * fy
                    let got = px[y * w + x]
                    XCTAssertEqual(Double(got.y), wantCb, accuracy: 1e-3 * wantCb, "\(loc) Cb at \(x),\(y)")
                    XCTAssertEqual(Double(got.z), wantCr, accuracy: 1e-3 * wantCr, "\(loc) Cr at \(x),\(y)")
                    XCTAssertEqual(Double(got.x), 500, accuracy: 1e-3)
                }
            }
        }
    }

    /// The real decode paths: a lossless 10-bit file through the FFmpeg pipe (Y4M, no codec at all) and through
    /// VideoToolbox (lossless HEVC in MP4) must give the same code values as written.
    func testDecodePathsDeliverExactCodeValues() throws {
        try PlayerFixtures.require("ffmpeg", "ffprobe")
        let spec = PlayerFixtures.Spec(width: 64, height: 32, bits: 10, chroma: .c420, frames: 2)
        func sample(_ f: Int, _ p: Int, _ x: Int, _ y: Int) -> Int { p == 0 ? 64 + (x * 13 + y * 7) % 876 : 64 + (x * 29 + y * 11 + p * 100) % 896 }
        let y4m = try PlayerFixtures.cached("codes.y4m") { try PlayerFixtures.writeY4M($0, spec, sample: sample) }
        let lossless = try PlayerFixtures.cached("codes-lossless.mp4") {
            try PlayerFixtures.ffmpeg(["-i", y4m.path, "-c:v", "libx265", "-x265-params", "log-level=error:lossless=1", "-pix_fmt", "yuv420p10le",
                                       "-tag:v", "hvc1", "-f", "mp4", $0.path])
        }
        for (url, expectBackend) in [(y4m, PlayerBackendKind.ffmpeg), (lossless, .avfoundation)] {
            let (_, b) = try PlayerFixtures.backend(url)
            XCTAssertEqual(b.choice.backend, expectBackend, url.lastPathComponent)
            try b.start(atFrame: 0)
            let f = try XCTUnwrap(try b.next())
            var color = f.color
            color.transfer = 16
            let codesFrame = PlayerFrame(index: f.index, pts: f.pts, layout: f.layout, planes: f.planes, color: color)
            var i = MediaInfo(url: url, container: "x"); i.video.width = 64; i.video.height = 32; i.video.color = color
            let (u, _) = PlayerRenderer.uniforms(frame: codesFrame, info: i, display: DisplayState(headroom: 100), settings: PlayerSettings(),
                                                 interpret: .auto, viewport: SIMD4(0, 0, 64, 32), outputMode: Int32(PLAYER_OUT_CODES))
            let px = PlayerRenderer.readBack(try renderer.render(frame: codesFrame, uniforms: u))
            var worst = 0.0
            for y in 0..<32 { for x in 0..<64 { worst = max(worst, abs(Double(px[y * 64 + x].x) - Double(sample(0, 0, x, y)))) } }
            XCTAssertEqual(worst, 0, accuracy: 1e-3, "\(url.lastPathComponent): luma code values")
            // Chroma on its own sample positions (even columns and rows with left siting = exactly a chroma sample in x;
            // vertically 4:2:0 left siting is centered, so compare against the average of the two chroma rows' samples).
            for cy in 1..<15 {
                for cx in 1..<31 {
                    let x = 2 * cx, y = 2 * cy
                    let want = (Double(sample(0, 1, cx, cy)) * 0.75 + Double(sample(0, 1, cx, cy - 1)) * 0.25)
                    XCTAssertEqual(Double(px[y * 64 + x].y), want, accuracy: 1e-3, "\(url.lastPathComponent) Cb at \(x),\(y)")
                }
            }
            b.stop()
        }
    }
}
