import Foundation
import Metal
import CoreVideo
import simd

/// What the screen can show right now.
struct DisplayState: Equatable {
    /// Current EDR headroom (maximumExtendedDynamicRangeColorComponentValue, smoothed): 1 on SDR screens.
    var headroom: Double = 1
    /// Reference mode (a fixed-headroom preset on Pro Display XDR / MacBook Pro): SDR white is exactly 100 nits.
    var referenceMode = false
}

/// How the player should read the signal; "Interpret as" in the controls.
enum InterpretMode: String, CaseIterable, Identifiable {
    case auto, sdr, pq, hlg
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .sdr: return "SDR"
        case .pq: return "PQ"
        case .hlg: return "HLG"
        }
    }
}

/// The tone mapping the player applies to one frame, for the info overlay.
struct ToneMapSummary: Equatable {
    var sourcePeak: Double
    var displayPeak: Double
    var referenceWhite: Double
    var mapping: String
    var peakSource: String
}

/// Converts a decoded Y'CbCr frame to the EDR drawable in one compute pass (Player.metal).
final class PlayerRenderer {
    let device: MTLDevice
    /// The player's own queue: playback never waits behind an export's long compute passes.
    let queue: MTLCommandQueue
    private var pipelines: [Int: MTLComputePipelineState] = [:]
    private let dummy: MTLTexture
    private let ctx = MetalContext.shared

    init() {
        device = ctx.device
        queue = device.makeCommandQueue()!
        queue.label = "Lumora player"
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        dummy = device.makeTexture(descriptor: d)!
    }

    private func pipeline(layout: FrameLayout.Storage, sampleBytes: Int) throws -> MTLComputePipelineState {
        let key = layout.rawValue * 10 + sampleBytes
        if let p = pipelines[key] { return p }
        let c = MTLFunctionConstantValues()
        var l = Int32(layout.rawValue), b = Int32(sampleBytes)
        c.setConstantValue(&l, type: .int, index: 0)
        c.setConstantValue(&b, type: .int, index: 1)
        let fn = try ctx.library.makeFunction(name: "playerKernel", constantValues: c)
        let p = try device.makeComputePipelineState(function: fn)
        pipelines[key] = p
        return p
    }

    // MARK: Uniforms

    /// Y'CbCr → R'G'B' for luma weights Kr, Kb (columns: Y, Cb, Cr).
    static func yuvMatrix(kr: Float, kb: Float) -> simd_float3x3 {
        let kg = 1 - kr - kb
        return simd_float3x3(columns: (SIMD3(1, 1, 1),
                                       SIMD3(0, -2 * kb * (1 - kb) / kg, 2 * (1 - kb)),
                                       SIMD3(2 * (1 - kr), -2 * kr * (1 - kr) / kg, 0)))
    }

    static func matrix(for code: Int) -> (simd_float3x3, Int32) {
        switch code {
        case 0: return (matrix_identity_float3x3, Int32(PLAYER_MATRIX_GBR))
        case 1: return (yuvMatrix(kr: 0.2126, kb: 0.0722), Int32(PLAYER_MATRIX_YCBCR))
        case 4: return (yuvMatrix(kr: 0.30, kb: 0.11), Int32(PLAYER_MATRIX_YCBCR))
        case 5, 6: return (yuvMatrix(kr: 0.299, kb: 0.114), Int32(PLAYER_MATRIX_YCBCR))
        case 7: return (yuvMatrix(kr: 0.212, kb: 0.087), Int32(PLAYER_MATRIX_YCBCR))
        case 8: return (simd_float3x3(columns: (SIMD3(1, 1, 1), SIMD3(-1, 1, -1), SIMD3(1, 0, -1))), Int32(PLAYER_MATRIX_YCGCO))
        default: return (yuvMatrix(kr: 0.2627, kb: 0.0593), Int32(PLAYER_MATRIX_YCBCR))     // 9, 10, 14 and anything else
        }
    }

    static func lumaWeights(_ g: Gamut) -> SIMD3<Float> {
        switch g {
        case .rec2020: return SIMD3(0.2627, 0.6780, 0.0593)
        case .p3d65: return SIMD3(0.2290, 0.6917, 0.0793)
        default: return SIMD3(0.2126, 0.7152, 0.0722)
        }
    }

    static func transferMode(_ cicp: Int) -> Int32 {
        switch cicp {
        case 16: return Int32(PLAYER_TF_PQ)
        case 18: return Int32(PLAYER_TF_HLG)
        case 13: return Int32(PLAYER_TF_SRGB)
        case 8: return Int32(PLAYER_TF_LINEAR)
        case 4: return Int32(PLAYER_TF_GAMMA22)
        case 5: return Int32(PLAYER_TF_GAMMA28)
        default: return Int32(PLAYER_TF_BT1886)
        }
    }

    /// SMPTE ST 2084 in double precision (CPU side of the EETF and the tests' reference).
    static func pq(_ nits: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let y = pow(min(max(nits / 10000, 0), 1), m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }
    static func pqInverse(_ v: Double) -> Double {
        let m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875
        let p = pow(max(v, 0), 1 / m2)
        return 10000 * pow(max(p - c1, 0) / (c2 - c3 * p), 1 / m1)
    }

    /// BT.2390 EETF constants in the PQ domain: source black/peak, normalized display black/peak, knee start.
    struct EETF: Equatable { var lb, lw, minLum, maxLum, ks: Double }

    static func eetf(sourcePeak: Double, displayPeak: Double, sourceBlack: Double = 0, displayBlack: Double = 0) -> EETF {
        let lb = pq(sourceBlack), lw = pq(sourcePeak)
        let span = max(1e-6, lw - lb)
        let maxLum = min(1, (pq(displayPeak) - lb) / span)
        let minLum = max(0, (pq(displayBlack) - lb) / span)
        return EETF(lb: lb, lw: lw, minLum: minLum, maxLum: maxLum, ks: 1.5 * maxLum - 0.5)
    }

    /// The EETF on one luminance in nits (double precision; the kernel does the same in float).
    static func applyEETF(_ nits: Double, _ e: EETF) -> Double {
        let span = e.lw - e.lb
        let e1 = min(max((pq(nits) - e.lb) / span, 0), 1)
        var e2 = e1
        if e1 >= e.ks {
            let t = (e1 - e.ks) / (1 - e.ks), t2 = t * t, t3 = t2 * t
            e2 = (2 * t3 - 3 * t2 + 1) * e.ks + (t3 - 2 * t2 + t) * (1 - e.ks) + (-2 * t3 + 3 * t2) * e.maxLum
        }
        let e3 = e2 + e.minLum * pow(1 - e2, 4)
        return pqInverse(e3 * span + e.lb)
    }

    /// BT.2100 HLG system gamma for a display of peak `lw` nits.
    static func hlgGamma(_ lw: Double) -> Double { 1.2 + 0.42 * log10(lw / 1000) }

    /// The content's peak: MaxCLL when sane, else the mastering display's peak, else Lumora's export record, else
    /// the "assume untagged HDR peaks at" setting.
    static func sourcePeak(_ info: MediaInfo, assumed: Double) -> (Double, String) {
        let h = info.video.hdr
        if let cll = h?.maxCLL, cll > 0, cll <= 10_000, cll <= (h?.mdcvMaxNits ?? 10_000) { return (cll, "MaxCLL") }
        if let m = h?.mdcvMaxNits, m > 0, m <= 10_000 { return (m, "mastering display") }
        if let p = info.manifestPeakNits, p > 0, p <= 10_000 { return (p, "Lumora's export record") }
        return (assumed, "assumed (no metadata)")
    }

    /// Builds the kernel's uniforms for a frame drawn into `viewport` (pixels) of a destination.
    static func uniforms(frame: PlayerFrame, info: MediaInfo, display: DisplayState, settings: PlayerSettings,
                         interpret: InterpretMode, viewport: SIMD4<Float>, outputMode: Int32 = Int32(PLAYER_OUT_EXTENDED_LINEAR))
        -> (PlayerUniforms, ToneMapSummary) {
        var color = frame.color
        switch interpret {
        case .auto: if let alt = info.video.alternativeTransfer, alt == 18 || alt == 16 { color.transfer = alt }
        case .sdr: if color.isHDR { color.transfer = 1 }
        case .pq: color.transfer = 16
        case .hlg: color.transfer = 18
        }
        let l = frame.layout
        var u = PlayerUniforms()
        let (m, mode) = l.forcesGBR ? (matrix_identity_float3x3, Int32(PLAYER_MATRIX_GBR)) : matrix(for: color.matrix)
        u.yuvToRgb = m
        u.matrixMode = (l.chroma != .c444 && mode == Int32(PLAYER_MATRIX_GBR)) ? Int32(PLAYER_MATRIX_YCBCR) : mode
        if u.matrixMode == Int32(PLAYER_MATRIX_YCBCR) && mode == Int32(PLAYER_MATRIX_GBR) { u.yuvToRgb = matrix(for: 9).0 }
        let gamut = color.gamut
        u.toBT2020 = ColorScience.matrix(from: gamut, to: .rec2020)
        u.viewport = viewport
        u.lumaSize = SIMD4(Float(l.width), Float(l.height), Float(l.width) / max(1, viewport.z), Float(l.height) / max(1, viewport.w))
        let (sx, sy) = l.chroma.subsampling
        u.chroma = l.chroma == .mono ? SIMD4(0, 0, 1, 1)
            : SIMD4(Float(l.chromaWidth), Float(l.chromaHeight), 1 / Float(sx), 1 / Float(sy))
        let loc = color.chromaLocation
        u.chromaOffset = SIMD4(loc.offset(horizontal: true, subsampling: sx), loc.offset(horizontal: false, subsampling: sy), 0, 0)
        u.strides = SIMD4(UInt32(l.strides[0]), UInt32(l.strides[1]), UInt32(l.strides[2]), 0)
        u.offsets = SIMD4(UInt32(l.offsets[0]), UInt32(l.offsets[1]), UInt32(l.offsets[2]), 0)
        let w = lumaWeights(gamut)
        u.luma = SIMD4(w.x, w.y, w.z, 0)
        u.bits = Int32(l.bits)
        u.containerBits = Int32(l.sampleBytes * 8)
        u.msbAligned = l.msbAligned ? 1 : 0
        u.fullRange = (color.fullRange || l.forcesFullRange) ? 1 : 0
        u.transfer = transferMode(color.transfer)
        u.outputMode = outputMode

        let refWhite = display.referenceMode ? 100.0 : Double(settings.referenceWhite)
        let dstPeak = max(1, display.headroom) * refWhite
        u.refWhite = Float(refWhite)
        var srcPeak = refWhite
        var source = "SDR"
        let isPQ = u.transfer == Int32(PLAYER_TF_PQ), isHLG = u.transfer == Int32(PLAYER_TF_HLG)
        if isPQ || l.storage == .rgbaTexture {
            (srcPeak, source) = sourcePeak(info, assumed: Double(settings.assumedPeak))
        } else if isHLG {
            // BT.2100: the HLG OOTF targets the display's own peak (400-2000 nits). On a screen without HDR headroom
            // the nominal 1000-nit rendering is tone mapped like PQ, which keeps diffuse white near SDR white.
            let lw = display.headroom > 1.25 ? min(2000, max(400, dstPeak)) : 1000
            u.hlgLw = Float(lw)
            u.hlgGamma = Float(hlgGamma(lw))
            srcPeak = lw
            source = "HLG at \(Int(lw)) nits (γ \(String(format: "%.3f", hlgGamma(lw))))"
        }
        u.srcPeak = Float(srcPeak)
        u.dstPeak = Float(dstPeak)
        let hdr = isPQ || isHLG || l.storage == .rgbaTexture
        u.toneMap = (hdr && dstPeak < srcPeak && outputMode == Int32(PLAYER_OUT_EXTENDED_LINEAR)) ? 1 : 0
        let e = eetf(sourcePeak: srcPeak, displayPeak: dstPeak)
        u.eetfLb = Float(e.lb); u.eetfLw = Float(e.lw); u.eetfMaxLum = Float(e.maxLum); u.eetfKS = Float(e.ks); u.eetfMinLum = Float(e.minLum)
        let mapping: String
        if outputMode == Int32(PLAYER_OUT_PQ) || outputMode == Int32(PLAYER_OUT_HLG) { mapping = "macOS (signal passed through)" }
        else if !hdr { mapping = "none (SDR)" }
        else if u.toneMap != 0 { mapping = "BT.2390 EETF to \(Int(dstPeak.rounded())) nits" }
        else { mapping = "none: the display reaches the content peak" }
        return (u, ToneMapSummary(sourcePeak: srcPeak, displayPeak: dstPeak, referenceWhite: refWhite, mapping: mapping, peakSource: source))
    }

    // MARK: Encoding

    /// Retains what the GPU reads until the command buffer completes.
    final class Keepalive { var items: [Any] = [] }

    /// Encodes the conversion of `frame` into `destination` (rgba16Float, or rgba32Float for tests).
    func encode(_ cb: MTLCommandBuffer, frame: PlayerFrame, uniforms: PlayerUniforms, destination: MTLTexture) throws {
        let l = frame.layout
        let p = try pipeline(layout: l.storage, sampleBytes: l.sampleBytes)
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        let keep = Keepalive()
        keep.items.append(frame.planes)
        var u = uniforms
        enc.setComputePipelineState(p)
        enc.setTexture(dummy, index: 0)
        enc.setTexture(dummy, index: 1)
        switch frame.planes {
        case .pixelBuffer(let pb):
            if l.storage == .rgbaTexture {
                if let (t, cv) = ctx.texture(from: pb, format: .rgba16Float) { enc.setTexture(t, index: 0); keep.items.append(cv) }
            } else {
                let y: MTLPixelFormat = l.sampleBytes == 1 ? .r8Unorm : .r16Unorm
                let c: MTLPixelFormat = l.sampleBytes == 1 ? .rg8Unorm : .rg16Unorm
                if let (t, cv) = ctx.texture(from: pb, format: y, plane: 0) { enc.setTexture(t, index: 0); keep.items.append(cv) }
                if let (t, cv) = ctx.texture(from: pb, format: c, plane: 1) { enc.setTexture(t, index: 1); keep.items.append(cv) }
            }
            enc.setBuffer(nil, offset: 0, index: 0)
        case .buffer(let b):
            enc.setBuffer(b.buffer, offset: 0, index: 0)
        }
        enc.setTexture(destination, index: 2)
        enc.setBytes(&u, length: MemoryLayout<PlayerUniforms>.stride, index: 1)
        let w = p.threadExecutionWidth, h = max(1, p.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
        cb.addCompletedHandler { _ in _ = keep }
    }

    /// Renders a frame offscreen at its own size (tests and snapshots). rgba32Float, shared, so it can be read back.
    func render(frame: PlayerFrame, uniforms: PlayerUniforms, width: Int? = nil, height: Int? = nil) throws -> MTLTexture {
        let w = width ?? frame.layout.width, h = height ?? frame.layout.height
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderWrite, .shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d), let cb = queue.makeCommandBuffer() else {
            throw PlayerError.decoderFailed("Metal", "couldn't allocate a \(w)×\(h) texture")
        }
        try encode(cb, frame: frame, uniforms: uniforms, destination: tex)
        cb.commit()
        cb.waitUntilCompleted()
        return tex
    }

    /// Reads an rgba32Float texture back (tests).
    static func readBack(_ t: MTLTexture) -> [SIMD4<Float>] {
        var out = [SIMD4<Float>](repeating: .zero, count: t.width * t.height)
        out.withUnsafeMutableBytes {
            t.getBytes($0.baseAddress!, bytesPerRow: t.width * 16, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        return out
    }

    /// A viewport that letterboxes a picture of display aspect `aspect` into w × h pixels.
    static func letterbox(aspect: Double, width: Int, height: Int) -> SIMD4<Float> {
        let dw = Double(width), dh = Double(height)
        var w = dw, h = dw / max(0.01, aspect)
        if h > dh { h = dh; w = dh * aspect }
        return SIMD4(Float(((dw - w) / 2).rounded()), Float(((dh - h) / 2).rounded()), Float(w.rounded()), Float(h.rounded()))
    }
}
