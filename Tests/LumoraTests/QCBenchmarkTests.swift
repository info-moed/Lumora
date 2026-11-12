import XCTest
import Metal
import MetalPerformanceShaders
import ImageIO
import UniformTypeIdentifiers
@testable import Lumora

/// Ground-truth benchmark for the interpolation artifact checker (InterpolationQC + FrameStream).
///
/// Ground truth: Big Buck Bunny's native 60 fps render. Frames are removed and rebuilt ("30->60": n-1, n+1 -> n;
/// "15->60": n-2, n+2 -> n-1, n, n+1), so every generated frame has a real answer. Skipped unless LUMORA_QC_BENCH=1;
/// run it with scripts/qc-bench.sh.
///
/// - test1_Dataset: scans the film (motion, cuts, fades), samples windows into the committed manifest
///   (Tests/LumoraTests/Resources/qc-bench-manifest.json), caches the frames, and for every triplet builds every
///   candidate with the real engines plus the reference-free features and true per-tile errors
///   (qc-dataset/<split>/tiles.csv, frames.csv, ref.json).
/// - test2_Baseline: the current checker at sensitivity 0 / 0.5 / 1 against raw primary and the per-tile oracle,
///   on every split, through the real FrameStream (qc-results/baseline.md and baseline-<split>.json).
/// - test3_Evaluate: the entry point for designs. Runs whatever policy the app code implements through FrameStream
///   over the chosen splits and writes qc-results/<label>-<split>.json. Environment:
///   LUMORA_QC_LABEL (name), LUMORA_QC_SPLITS (comma list), LUMORA_QC_SENSITIVITY (comma list, default 0.5),
///   LUMORA_QC_REPAIR_MODEL (model id or "none"), LUMORA_QC_INTELLIGENCE (eachFrame | perScene | exhaustive),
///   LUMORA_QC_FLICKER=0, LUMORA_QC_LIMIT (windows per split).
final class QCBenchmarkTests: XCTestCase {

    override func setUpWithError() throws {
        guard QCBench.env["LUMORA_QC_BENCH"] == "1" else { throw XCTSkip("QC benchmark: set LUMORA_QC_BENCH=1 (scripts/qc-bench.sh)") }
        try TestHardware.requireGPU()
        guard FileManager.default.fileExists(atPath: QCBench.film1080.path) else {
            throw XCTSkip("Big Buck Bunny 60 fps render not found at \(QCBench.film1080.path)")
        }
        let installed = InterpolationModelSpec.all().filter(\.isInstalled).map(\.id)
        guard installed.contains(QCBench.imageModel), installed.contains(QCBench.flowModel) else {
            throw XCTSkip("RIFE 4.25 image and flow models must be installed (Model Lab)")
        }
        QCBench.ensureDir(QCBench.dataset)
        QCBench.ensureDir(QCBench.results)
    }

    // MARK: - Shared preparation

    static var prepared: (QCManifest, FrameProvider)?

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    static let compact: JSONEncoder = {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return d
    }()

    static func prepare() async throws -> (QCManifest, FrameProvider) {
        if let p = prepared { return p }
        let (_, colors) = try await SourceInspector.inspect(QCBench.film1080)
        let sdr = try XCTUnwrap(colors.first, "no color interpretation for the film")
        QCBench.log("film color: \(sdr.name) transfer \(sdr.transfer) gamut \(sdr.gamut) legalToFull \(sdr.legalToFull)")
        var manifest: QCManifest
        if QCBench.env["LUMORA_QC_RESELECT"] != "1", let d = try? Data(contentsOf: QCBench.manifestURL),
           let m = try? decoder.decode(QCManifest.self, from: d) {
            manifest = m
            QCBench.log("manifest: \(m.windows.count) windows (committed)")
        } else {
            let scan = try await loadOrScan()
            let shots = ShotAnalysis(scan)
            let (windows, excluded) = WindowSelector.select(scan, shots)
            let (conv, convReport) = try await calibrateConversion()
            manifest = QCManifest(filmFrames: scan.frames, cutRule: ShotAnalysis.cutRule, transitionRule: ShotAnalysis.transitionRule,
                                  exclusionCounts: excluded, cuts: shots.cuts,
                                  transitions: shots.transitions.map { [$0.lowerBound, $0.upperBound] },
                                  decode: ["legalOut": conv.legalOut ? "1" : "0", "chromaX": "\(conv.chromaX)", "matrix": "BT.709",
                                           "check": convReport, "sdrColor": "\(sdr.name), legalToFull \(sdr.legalToFull)"],
                                  synthetic: Dictionary(uniqueKeysWithValues: SyntheticClips.all.map { ($0.name, $0.graph) }),
                                  grain: GrainMaker.filter.replacingOccurrences(of: "%d", with: "1000 + center"),
                                  hdr: FrameProvider.hdrRecipe, windows: windows)
            manifest.storyFrames = shots.creditsStart
            QCBench.ensureDir(QCBench.manifestURL.deletingLastPathComponent())
            try encoder.encode(manifest).write(to: QCBench.manifestURL, options: .atomic)
            QCBench.log("manifest written: \(windows.count) windows, \(shots.cuts.count) cuts, \(shots.transitions.count) transitions -> \(QCBench.manifestURL.path)")
        }
        let conv = YUVConversion(legalOut: manifest.decode["legalOut"] == "1", chromaX: Float(manifest.decode["chromaX"] ?? "0") ?? 0)
        let provider = FrameProvider(sdr: sdr, conv: conv)
        try await ensureFrames(manifest)
        prepared = (manifest, provider)
        return (manifest, provider)
    }

    static func loadOrScan() async throws -> FilmScan {
        if let s = FilmScan.load() { QCBench.log("scan: \(s.frames) frames (cached)"); return s }
        QCBench.log("scanning the 1080p film (every frame: thumbnails, histogram, block motion)...")
        let s = try await FilmScan.scan()
        try s.save()
        QCBench.log("scan done: \(s.frames) frames")
        return s
    }

    /// Instrument check: my NV12 cache -> RGB must reproduce the app's own AVFoundation decode of the same frame
    /// (and both readers must land on the same frame number after a seek).
    static func calibrateConversion() async throws -> (YUVConversion, String) {
        let gpu = BenchGPU.shared
        var scores: [YUVConversion: [Double]] = [:]
        var appOffsets: [Int] = []
        let variants = [false, true].flatMap { l in [Float(0), 0.25].map { YUVConversion(legalOut: l, chromaX: $0) } }
        for k in [1200, 4089, 15482, 19000, 25000] {
            // Frames k-1, k, k+1 through the benchmark reader (content-checked against the sequential scan in ensureFrames).
            let r = NV12Reader(url: QCBench.film1080)
            try await r.start(at: k - 1)
            var nv: [Int: NV12Frame] = [:]
            while nv.count < 3, let (idx, pb) = try r.next() { if idx >= k - 1 { nv[idx] = NV12Frame(pb) } }
            r.cancel()
            XCTAssertEqual(nv.keys.sorted(), [k - 1, k, k + 1], "NV12 reader frame numbering after a seek")
            let app = AVFoundationFrameSource(url: QCBench.film1080, fps: 60)
            try await app.prepare()
            try app.start(at: k + QCBench.ptsOffset, count: 1)
            let f = try XCTUnwrap(try app.nextFrame())
            XCTAssertEqual(f.index, k + QCBench.ptsOffset, "app decode seek label")
            let appTex = gpu.copy(f.texture)
            app.cancel()
            // Which frame does the app's decode really show? (k-1, k or k+1, by PSNR with the default conversion.)
            let near = [k - 1, k, k + 1].map { gpu.tileErrors([(gpu.rgb(nv[$0]!, YUVConversion()), appTex)])[0].psnr }
            appOffsets.append(near.indices.max { near[$0] < near[$1] }! - 1)
            for v in variants { scores[v, default: []].append(gpu.tileErrors([(gpu.rgb(nv[k]!, v), appTex)])[0].psnr) }
        }
        let best = variants.max { scores[$0]!.reduce(0, +) < scores[$1]!.reduce(0, +) }!
        let report = variants.map { "\($0.description): \(scores[$0]!.map { fmt($0, 1) }.joined(separator: "/")) dB" }.joined(separator: "; ")
        QCBench.log("decode check vs app AVFoundation decode: \(report); app frame content offset after start(at:) = \(appOffsets)")
        XCTAssertEqual(appOffsets, appOffsets.map { _ in 0 }, "the app's seek shows a different frame than it labels")
        XCTAssertGreaterThan(scores[best]!.min()!, 45, "cached frames don't match the app's decode")
        return (best, "best \(best.description), PSNR vs app decode \(scores[best]!.map { fmt($0, 1) }.joined(separator: "/")) dB; app seek content offsets \(appOffsets)")
    }

    static func ensureFrames(_ m: QCManifest) async throws {
        var need: [String: Set<Int>] = [:]
        for w in m.windows where w.source.hasPrefix("bbb") {
            need["bbb1080", default: []].formUnion((w.center - 2)...(w.center + 2))
            if w.source == "bbb2160" { need["bbb2160", default: []].formUnion((w.center - 2)...(w.center + 2)) }
            if let p = w.partner, p >= 0 { need["bbb1080", default: []].formUnion((p - 2)...(p + 2)) }
        }
        for (src, url) in [("bbb1080", QCBench.film1080), ("bbb2160", QCBench.film2160)] {
            let missing = (need[src] ?? []).filter { !FrameCache.exists(src, "\($0)") }.sorted()
            if missing.isEmpty { continue }
            QCBench.log("caching \(missing.count) frames of \(src)...")
            var reader: NV12Reader?
            var i = 0
            var current = -1
            while i < missing.count {
                let want = missing[i]
                if reader == nil || want > current + 300 || want <= current {
                    reader?.cancel()
                    reader = NV12Reader(url: url)
                    try await reader!.start(at: max(0, want - 1))
                }
                guard let (idx, pb) = try reader!.next() else { throw LumoraError.decodeFailed("\(src) ended before frame \(want)") }
                current = idx
                if idx == want {
                    try FrameCache.save(NV12Frame(pb), src, "\(idx)")
                    i += 1
                } else if idx > want {
                    throw LumoraError.decodeFailed("\(src): wanted frame \(want), reader is at \(idx)")
                }
            }
            reader?.cancel()
        }
        // Instrument check: every cached 1080p frame shows the content the sequential scan saw at that index.
        if let scan = FilmScan.load() {
            var bad: [Int] = []
            for k in (need["bbb1080"] ?? []).sorted() {
                guard let f = FrameCache.load("bbb1080", "\(k)") else { continue }
                if seekOffsets([(k, lumaTexture(f))], scan: scan)[0] != 0 { bad.append(k) }
            }
            QCBench.log("cached frame check: \((need["bbb1080"] ?? []).count) frames, \(bad.count) mismatched \(bad.prefix(10))")
            XCTAssertTrue(bad.isEmpty, "cached frames don't match the scan: \(bad.prefix(20))")
        }
        for clip in SyntheticClips.all where m.windows.contains(where: { $0.source == "synth-\(clip.name)" }) { try clip.ensureCached() }
        for w in m.windows where w.variant == "grain" { try GrainMaker.ensure(w) }
    }

    static func windows(_ m: QCManifest, _ split: String) -> [QCWindow] {
        let ws = m.windows.filter { $0.split == split }
        if let l = QCBench.env["LUMORA_QC_LIMIT"].flatMap(Int.init) { return Array(ws.prefix(l)) }
        return ws
    }

    static func splits(default d: [String]) -> [String] {
        QCBench.env["LUMORA_QC_SPLITS"].map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } } ?? d
    }

    static func refURL(_ split: String) -> URL { QCBench.dataset.appendingPathComponent("\(split)/ref.json") }

    static func loadRefs(_ split: String) throws -> [String: RefFrame] {
        let d = try Data(contentsOf: refURL(split))
        let list = try decoder.decode([RefFrame].self, from: d)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.key, $0) })
    }

    // MARK: - 0. Scan diagnostics (calibrating the cut / fade / motion instruments)

    func test0_Scan() async throws {
        let scan = try await Self.loadOrScan()
        let shots = ShotAnalysis(scan)
        let n = scan.frames
        func pct(_ x: [Float], _ ps: [Double]) -> String {
            let s = x.sorted()
            return ps.map { "p\(Int($0 * 100))=\(fmt(s[min(s.count - 1, Int(Double(s.count - 1) * $0))], 4))" }.joined(separator: " ")
        }
        let res = (1..<n).map { scan.residual($0) }, chi = (1..<n).map { scan.chi2($0) }
        QCBench.log("residual: \(pct(res, [0.5, 0.9, 0.99, 0.999]))  chi2: \(pct(chi, [0.5, 0.9, 0.99, 0.999]))")
        QCBench.log("cuts (\(shots.cuts.count)): \(shots.cuts.map(String.init).joined(separator: " "))")
        QCBench.log("credits start at frame \(shots.creditsStart) (\(fmt(Double(shots.creditsStart) / 60, 1)) s)")
        QCBench.log("transitions (\(shots.transitions.count)): \(shots.transitions.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: " "))")
        for c in shots.cuts.prefix(400) {
            QCBench.log("cut \(c): res \(fmt(scan.residual(c), 4)) chi \(fmt(scan.chi2(c), 3)) mad \(fmt(scan.thumbMAD(c, c - 1), 3)) prev-res \(fmt(scan.residual(c - 1), 4)) next-res \(fmt(scan.residual(c + 1), 4))")
        }
        // Near misses: big residual spikes that were not called cuts.
        let cutSet = Set(shots.cuts)
        let misses = (2..<(n - 2)).filter { !cutSet.contains($0) && scan.residual($0) > 0.03 }.sorted { scan.residual($0) > scan.residual($1) }.prefix(40)
        for k in misses {
            QCBench.log("non-cut spike \(k): res \(fmt(scan.residual(k), 4)) chi \(fmt(scan.chi2(k), 3)) mad \(fmt(scan.thumbMAD(k, k - 1), 3))")
        }
        var motions: [Float] = []
        for c in stride(from: 6, to: n - 6, by: 3) { motions.append(scan.windowMotion(c).p90) }
        QCBench.log("window motion p90 (px over 4 frames): \(pct(motions, [0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.99]))")
        let (ws, excluded) = WindowSelector.select(scan, shots)
        QCBench.log("excluded: \(excluded)")
        var cnt: [String: Int] = [:]
        for w in ws { cnt["\(w.split)/\(w.stratum)", default: 0] += 1 }
        QCBench.log("selected: \(cnt.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        // Contact sheets for eyeballing: cuts (c-1 | c), transitions (start | middle | end), non-cut spikes (k-1 | k).
        let diag = QCBench.dataset.appendingPathComponent("diag", isDirectory: true)
        QCBench.ensureDir(diag)
        var rng = SplitMix(state: 99)
        let someCuts = shots.cuts.shuffled(using: &rng).prefix(16).sorted()
        try await Self.sheet(someCuts.map { [$0 - 1, $0] }, diag.appendingPathComponent("cuts.png"))
        try await Self.sheet(shots.transitions.prefix(12).map { [$0.lowerBound, ($0.lowerBound + $0.upperBound) / 2, $0.upperBound] }, diag.appendingPathComponent("transitions.png"))
        try await Self.sheet(misses.prefix(12).sorted().map { [$0 - 1, $0] }, diag.appendingPathComponent("noncuts.png"))
        let byMotion = ws.filter { $0.split == "test" }
        try await Self.sheet(QCBench.strata.map { st in byMotion.filter { $0.stratum == st.0 }.prefix(2).flatMap { [$0.center - 2, $0.center + 2] } },
                             diag.appendingPathComponent("strata.png"))
        QCBench.log("contact sheets in \(diag.path)")
    }

    /// Instrument check: after a seek, does frame "k" (by PTS) show the content the sequential scan saw at k?
    /// Returns the content offset (best-matching scan index minus k) for each frame read.
    static func seekOffsets(_ frames: [(Int, MTLTexture)], scan: FilmScan) -> [Int] {
        frames.map { (k, y) in
            let m = thumbMADs(y, k, scan: scan)
            // A neighbor only counts as the real match when it is clearly closer (repeated / near-identical frames tie).
            let best = m.min { $0.1 < $1.1 }!
            return best.1 < (m.first { $0.0 == k }?.1 ?? .infinity) - 0.002 ? best.0 - k : 0
        }
    }

    /// Thumbnail MAD of a luma plane against the scan's thumbnails of frames k-4 ... k+4.
    static func thumbMADs(_ y: MTLTexture, _ k: Int, scan: FilmScan) -> [(Int, Float)] {
        let t = FilmScan.thumbW * FilmScan.thumbH
        let thumb = FilmScan.Measurer().measure(lumaPlane: y, factor: y.width / FilmScan.smallW).thumb
        return (max(0, k - 4)...min(scan.frames - 1, k + 4)).map { c in
            var s = 0
            for i in 0..<t { s += abs(Int(thumb[i]) - Int(scan.thumbs[c * t + i])) }
            return (c, Float(s) / Float(t) / 255)
        }
    }

    static func lumaTexture(_ f: NV12Frame) -> MTLTexture {
        let y = BenchGPU.shared.ctx.makeTexture(width: f.width, height: f.height, format: .r8Unorm, usage: [.shaderRead], storage: .shared)
        f.y.withUnsafeBytes { y.replace(region: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: f.width) }
        return y
    }

    func test0b_SeekCheck() async throws {
        let scan = try await Self.loadOrScan()
        for k in [975, 4089, 15482, 20000, 31000] {
            let r = NV12Reader(url: QCBench.film1080)
            try await r.start(at: k)
            var got: [(Int, MTLTexture)] = []
            for _ in 0..<6 { if let (i, pb) = try r.next() { got.append((i, Self.lumaTexture(NV12Frame(pb)))) } }
            r.cancel()
            QCBench.log("NV12Reader seek \(k): indices \(got.map(\.0)) content offsets \(Self.seekOffsets(got, scan: scan))")
            let app = AVFoundationFrameSource(url: QCBench.film1080, fps: 60)
            try await app.prepare()
            try app.start(at: k + QCBench.ptsOffset, count: 6)
            var appGot: [(Int, MTLTexture)] = []
            while let f = try app.nextFrame() { appGot.append((f.index - QCBench.ptsOffset, BenchGPU.shared.copy(f.texture))) }
            app.cancel()
            let offs = appGot.map { (k2, tex) -> Int in
                let small = BenchGPU.shared.texture(FilmScan.smallW, FilmScan.smallH, .r32Float)
                var fm = SIMD2<Int32>(4, 1)
                BenchGPU.shared.run { cb in BenchGPU.shared.dispatch(cb, "boxDown", w: FilmScan.smallW, h: FilmScan.smallH) { e in
                    e.setTexture(tex, index: 0); e.setTexture(small, index: 1); e.setBytes(&fm, length: 8, index: 0) } }
                return Self.seekOffsets([(k2, Self.upscale(small))], scan: scan)[0]
            }
            QCBench.log("app AVFoundationFrameSource start(at: \(k)+2): indices \(appGot.map(\.0)) content offsets \(offs)")
        }
    }

    /// 480x270 r32Float -> 1920x1080 r8 by nearest neighbor (so the measurer's factor-4 path can read it).
    static func upscale(_ small: MTLTexture) -> MTLTexture {
        var f = [Float](repeating: 0, count: small.width * small.height)
        let sh = BenchGPU.shared.ctx.makeTexture(width: small.width, height: small.height, format: .r32Float, storage: .shared)
        BenchGPU.shared.run { cb in let b = cb.makeBlitCommandEncoder()!; b.copy(from: small, to: sh); b.endEncoding() }
        f.withUnsafeMutableBytes { sh.getBytes($0.baseAddress!, bytesPerRow: small.width * 4, from: MTLRegionMake2D(0, 0, small.width, small.height), mipmapLevel: 0) }
        var bytes = [UInt8](repeating: 0, count: 1920 * 1080)
        for y in 0..<1080 { for x in 0..<1920 { bytes[y * 1920 + x] = UInt8(max(0, min(255, (f[(y / 4) * small.width + x / 4] * 255).rounded()))) } }
        return lumaTexture(NV12Frame(width: 1920, height: 1080, y: Data(bytes), uv: Data(count: 1920 * 540)))
    }

    /// Writes rows of 320x180 thumbnails of the given 1080p frames as one PNG.
    static func sheet(_ rows: [[Int]], _ url: URL) async throws {
        guard !rows.isEmpty else { return }
        let gpu = BenchGPU.shared
        let tw = 320, th = 180, cols = rows.map(\.count).max()!
        var px = [UInt8](repeating: 0, count: cols * tw * rows.count * th * 4)
        for (r, frames) in rows.enumerated() {
            for (c, k) in frames.enumerated() {
                let reader = NV12Reader(url: QCBench.film1080)
                try await reader.start(at: k)
                guard let (idx, pb) = try reader.next() else { continue }
                reader.cancel()
                precondition(idx == k)
                let rgb = gpu.rgb(NV12Frame(pb), YUVConversion())
                let small = gpu.ctx.makeTexture(width: tw, height: th, format: .rgba16Float, storage: .shared)
                let cb = gpu.ctx.queue.makeCommandBuffer()!
                MPSImageBilinearScale(device: gpu.ctx.device).encode(commandBuffer: cb, sourceTexture: rgb, destinationTexture: small)
                cb.commit(); cb.waitUntilCompleted()
                var h = [Float16](repeating: 0, count: tw * th * 4)
                h.withUnsafeMutableBytes { small.getBytes($0.baseAddress!, bytesPerRow: tw * 8, from: MTLRegionMake2D(0, 0, tw, th), mipmapLevel: 0) }
                for y in 0..<th { for x in 0..<tw { for ch in 0..<4 {
                    let v = ch == 3 ? 1 : Float(h[(y * tw + x) * 4 + ch])
                    px[((r * th + y) * cols * tw + c * tw + x) * 4 + ch] = UInt8(max(0, min(255, v * 255)))
                } } }
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &px, width: cols * tw, height: rows.count * th, bitsPerComponent: 8, bytesPerRow: cols * tw * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - 1. Dataset

    func test1_Dataset() async throws {
        let (m, provider) = try await Self.prepare()
        try await check4KAlignment(m, provider)
        let lab = TripletLab(provider: provider)
        for split in Self.splits(default: QCBench.allSplits) {
            let dir = QCBench.dataset.appendingPathComponent(split, isDirectory: true)
            let marker = dir.appendingPathComponent("complete.json")
            if QCBench.env["LUMORA_QC_REBUILD"] != "1", QCBench.env["LUMORA_QC_LIMIT"] == nil,
               let d = try? Data(contentsOf: marker), let c = try? JSONDecoder().decode([String: Int].self, from: d),
               c["windows"] == Self.windows(m, split).count {
                QCBench.log("dataset \(split): cached")
                continue
            }
            QCBench.ensureDir(dir)
            let ws = Self.windows(m, split)
            var tiles = TripletLab.tileHeader + "\n", frames = TripletLab.frameHeader + "\n"
            var refs: [RefFrame] = []
            let started = Date()
            for (i, w) in ws.enumerated() {
                let o = try autoreleasepool { try lab.process(w) }
                tiles += o.tileRows.joined(separator: "\n") + "\n"
                frames += o.frameRows.joined(separator: "\n") + "\n"
                refs += o.refs
                if i % 10 == 9 || i == ws.count - 1 {
                    QCBench.log("dataset \(split): \(i + 1)/\(ws.count) windows, \(Int(Date().timeIntervalSince(started))) s")
                }
            }
            try tiles.write(to: dir.appendingPathComponent("tiles.csv"), atomically: true, encoding: .utf8)
            try frames.write(to: dir.appendingPathComponent("frames.csv"), atomically: true, encoding: .utf8)
            try Self.compact.encode(refs).write(to: Self.refURL(split), options: .atomic)
            try? FileManager.default.removeItem(at: marker)
            if QCBench.env["LUMORA_QC_LIMIT"] == nil {
                try JSONEncoder().encode(["windows": ws.count, "frames": refs.count]).write(to: marker)
            }
            let broken = refs.reduce(0) { $0 + BrokenTile.flags($1).filter { $0 }.count }, total = refs.reduce(0) { $0 + $1.px.count }
            QCBench.log("dataset \(split): \(ws.count) windows, \(refs.count) generated frames, \(total) tiles, \(broken) broken (\(fmt(100 * Double(broken) / Double(max(1, total)), 2))%)")
        }
        let timing = lab.modelMs.mapValues { v -> [String: Double] in
            let s = v.sorted()
            return ["medianMsPerFrame": s[s.count / 2], "calls": Double(s.count)]
        }
        try Self.encoder.encode(timing).write(to: QCBench.dataset.appendingPathComponent("model-timing-\(Int(Date().timeIntervalSince1970)).json"))
        QCBench.log("model time: \(timing.map { "\($0.key): \(fmt($0.value["medianMsPerFrame"]!, 1)) ms/frame" }.sorted().joined(separator: ", "))")
    }

    /// Instrument check: frame n of the 2160p render is frame n of the 1080p render.
    func check4KAlignment(_ m: QCManifest, _ provider: FrameProvider) async throws {
        guard let scan = FilmScan.load() else { return }
        let gpu = BenchGPU.shared
        for w in m.windows.filter({ $0.split == "test4k" }).prefix(3) {
            guard let f = FrameCache.load("bbb2160", "\(w.center)") else { continue }
            let y = gpu.ctx.makeTexture(width: f.width, height: f.height, format: .r8Unorm, usage: [.shaderRead], storage: .shared)
            f.y.withUnsafeBytes { y.replace(region: MTLRegionMake2D(0, 0, f.width, f.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: f.width) }
            let thumb = FilmScan.Measurer().measure(lumaPlane: y, factor: 8).thumb
            let t = FilmScan.thumbW * FilmScan.thumbH
            let mads = (-1...1).map { d -> Float in
                let k = w.center + d
                var s = 0
                for i in 0..<t { s += abs(Int(thumb[i]) - Int(scan.thumbs[k * t + i])) }
                return Float(s) / Float(t) / 255
            }
            QCBench.log("4K alignment \(w.id) frame \(w.center): thumbnail MAD vs 1080p frames n-1/n/n+1 = \(mads.map { fmt($0, 4) })")
            XCTAssertLessThanOrEqual(mads[1], mads.min()! + 1e-6, "2160p frame \(w.center) doesn't match 1080p frame \(w.center)")
        }
    }

    // MARK: - 2. Baseline (current checker) + oracle

    static func qcConfigs(_ split: String, sensitivities: [Float], label: String) -> [(String, InterpolationSettings)] {
        sensitivities.map { s in
            var c = PolicyEvaluator.baseSettings(split: split)
            c.artifactRepair = true
            c.sensitivity = s
            return ("\(label)-s\(fmt(s, 1))", c)
        }
    }

    static func analyses(_ split: String) -> [String] {
        split == "cut" ? ["plain", "cutKnown"] : split == "fade" ? ["plain", "fadeKnown"] : ["plain"]
    }

    func test2_Baseline() async throws {
        let (m, provider) = try await Self.prepare()
        var rows: [String] = []
        var ruleRows: [String] = []
        var defRows: [String] = []
        for split in Self.splits(default: QCBench.allSplits) {
            let refs = try Self.loadRefs(split)
            defRows += Self.definitionStats(split, Array(refs.values))
            let ws = Self.windows(m, split)
            let oracle = Self.oracle(refs.values.filter { r in ws.contains { $0.id == r.window } })
            ruleRows += Self.ruleStats(split, Array(refs.values))
            for analysis in Self.analyses(split) {
                let ev = PolicyEvaluator(provider: provider, refs: refs)
                let results = try ev.run(split: split, windows: ws, configs: Self.qcConfigs(split, sensitivities: [0, 0.5, 1], label: "current"),
                                         analysis: analysis)
                let name = analysis == "plain" ? split : "\(split)-\(analysis)"
                try Self.encoder.encode(["oracle6": oracle.0, "oracleAll": oracle.1]).write(to: QCBench.results.appendingPathComponent("oracle-\(name).json"))
                for r in results { try Self.encoder.encode(r).write(to: QCBench.results.appendingPathComponent("baseline-\(r.label)-\(name).json")) }
                rows += Self.tableRows(name, results, oracle: analysis == "plain" ? oracle : nil)
            }
        }
        let report = Self.report(rows: rows, ruleRows: ruleRows, defRows: defRows, manifest: m)
        try report.write(to: QCBench.results.appendingPathComponent("baseline.md"), atomically: true, encoding: .utf8)
        print(report)
    }

    /// Oracle (per-tile best candidate) vs the dataset's raw primary, as Metrics.
    static func oracle(_ refs: [RefFrame]) -> (Metrics, Metrics) {
        func m(_ cands: [String]) -> Metrics {
            Metrics(refs.map { r in
                let raw = r.framePSNR[r.primary]!, o = r.oraclePSNR(cands.filter { r.candPSNR[$0] != nil })
                let b = BrokenTile.flags(r).filter { $0 }.count
                return FrameEval(key: r.key, mode: r.mode, stratum: r.stratum, psnrRaw: raw, psnrPolicy: o, ssimRaw: r.frameSSIM[r.primary]!,
                                 ssimPolicy: .nan, tiles: r.px.count, broken: b, changed: 0, brokenChanged: b, brokenFixed: b, harmful: 0)
            })
        }
        return (m(BrokenTile.requiredCandidates), m(TripletLab.candidates))
    }

    /// What the current rules would do, judged on the dataset (each rule on its own, primary output as input).
    static func ruleStats(_ split: String, _ refs: [RefFrame]) -> [String] {
        var out: [String] = []
        func mean(_ x: [Double]) -> String { x.isEmpty ? "-" : fmt(x.reduce(0, +) / Double(x.count), 2) }
        for (s, key) in [(Float(0), "s0"), (0.5, "s05"), (1, "s1")] {
            let lim = Float(QCBench.tile * QCBench.tile / 4) * (0.08 - 0.05 * s)
            var flagged = 0, flaggedBroken = 0, broken = 0
            var dBlend: [Double] = [], dNear: [Double] = [], dNearFrame: [Double] = []
            var replaceFrames = 0
            for r in refs {
                guard let q = r.qcCounts[key] else { continue }
                let b = BrokenTile.flags(r)
                let bad = q.map { $0 > lim }
                broken += b.filter { $0 }.count
                for i in bad.indices where bad[i] {
                    flagged += 1
                    if b[i] { flaggedBroken += 1 }
                    dBlend.append(Double(r.candPSNR["blend"]![i] - r.candPSNR[r.primary]![i]))
                }
                if Float(bad.filter { $0 }.count) / Float(bad.count) > 0.35 {
                    replaceFrames += 1
                    dNearFrame.append(r.framePSNR["nearest"]! - r.framePSNR[r.primary]!)
                }
                _ = dNear
            }
            out.append("| \(split) | patch rule s=\(fmt(s, 1)) | \(flagged) tiles flagged; \(flaggedBroken) of \(broken) broken tiles caught (recall \(broken > 0 ? fmt(100 * Double(flaggedBroken) / Double(broken), 1) : "-")%, precision \(flagged > 0 ? fmt(100 * Double(flaggedBroken) / Double(flagged), 1) : "-")%) | cross-fade minus primary on flagged tiles: \(mean(dBlend)) dB |")
            out.append("| \(split) | full-frame replace s=\(fmt(s, 1)) (>35% flagged) | \(replaceFrames) of \(refs.count) frames | nearest original minus primary on those frames: \(mean(dNearFrame)) dB |")
        }
        let fl = refs.filter { ($0.rules["flickFlag"] ?? 0) > 0 }
        let dFix = fl.compactMap { r in r.framePSNR["flickerFix"].map { $0 - r.framePSNR[r.primary]! } }
        out.append("| \(split) | flicker rule (raw primary chain) | \(fl.count) of \(refs.filter { $0.mode == "15->60" }.count) 15->60 frames flagged | neighbor blend minus primary on those frames: \(mean(dFix)) dB |")
        return out
    }

    static func tableRows(_ name: String, _ results: [ConfigResult], oracle: (Metrics, Metrics)?) -> [String] {
        guard let first = results.first else { return [] }
        let a = first.all
        func row(_ label: String, _ m: Metrics, ms: Double, added: String, extra: String = "") -> String {
            "| \(name) | \(label) | \(m.frames) | \(fmt(m.psnrPolicy, 2)) | \(fmt(m.gainMean, 3)) | \(fmt(m.gainWorst10, 3)) | \(fmt(m.ssimPolicy, 4)) | \(fmt(100 * m.fracDropOver0_1dB, 1)) | \(fmt(m.worstDropDB, 2)) | \(m.brokenTiles) | \(fmt(100 * m.recall, 1)) | \(fmt(100 * m.precision, 1)) | \(fmt(100 * m.fixedRecall, 1)) | \(fmt(ms, 1)) | \(added) |\(extra)"
        }
        var rawM = a
        rawM.psnrPolicy = a.psnrRaw; rawM.gainMean = 0; rawM.gainWorst10 = 0; rawM.ssimPolicy = a.ssimRaw
        rawM.fracDropOver0_1dB = 0; rawM.worstDropDB = 0; rawM.recall = 0; rawM.precision = .nan; rawM.fixedRecall = 0
        var rows = [row("raw primary (no QC)", rawM, ms: first.msPerFrameRaw, added: "-",
                        extra: a.rawVsDatasetMaxAbsDB.map { " raw vs dataset primary max |Δ| \(fmt($0, 3)) dB" } ?? "")]
        for r in results {
            let acts = r.actions.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
            let held = r.all.heldFraction.map { " held originals \(fmt(100 * $0, 1))%;" } ?? ""
            rows.append(row(r.label, r.all, ms: r.msPerFramePolicy, added: "\(fmt(r.addedMs, 1)) (\(fmt(r.addedPct, 0))%)", extra: "\(held) \(acts)"))
        }
        if let (o6, oa) = oracle {
            rows.append(row("ORACLE (best of 6 per tile)", o6, ms: .nan, added: "-"))
            rows.append(row("ORACLE (best of all \(TripletLab.candidates.count) per tile)", oa, ms: .nan, added: "-"))
        }
        return rows
    }

    /// Why the broken-tile thresholds: candidate-to-candidate noise and how the broken share moves with them.
    static func definitionStats(_ split: String, _ refs: [RefFrame]) -> [String] {
        var noise: [Float] = [], gapAll: [Float] = []
        var grid: [String: Int] = [:]
        var tiles = 0
        let others = BrokenTile.requiredCandidates
        for r in refs {
            guard let p = r.candPSNR[r.primary] else { continue }
            let flipName = r.primary + "Flip"
            for i in p.indices {
                tiles += 1
                if let f = r.candPSNR[flipName]?[i], p[i] < 45 { noise.append(abs(p[i] - f)) }
                let best = others.filter { $0 != r.primary }.compactMap { r.candPSNR[$0]?[i] }.max() ?? p[i]
                gapAll.append(best - p[i])
                for a in [28, 30, 32] { for mg in [1, 2, 3] where Double(p[i]) < Double(a) && Double(best - p[i]) >= Double(mg) { grid["\(a)/\(mg)", default: 0] += 1 } }
            }
        }
        func pc(_ x: [Float], _ q: Double) -> String { x.isEmpty ? "-" : fmt(x.sorted()[Int(Double(x.count - 1) * q)], 2) }
        let g = [28, 30, 32].map { a in [1, 2, 3].map { mg in "\(a) dB/\(mg) dB: \(fmt(100 * Double(grid["\(a)/\(mg)"] ?? 0) / Double(max(1, tiles)), 2))%" }.joined(separator: ", ") }.joined(separator: "; ")
        return ["| \(split) | \(tiles) | \(pc(noise, 0.5)) / \(pc(noise, 0.9)) / \(pc(noise, 0.99)) | \(pc(gapAll, 0.5)) / \(pc(gapAll, 0.9)) / \(pc(gapAll, 0.99)) | \(g) |"]
    }

    static func report(rows: [String], ruleRows: [String], defRows: [String] = [], manifest m: QCManifest) -> String {
        var counts: [String: Int] = [:]
        for w in m.windows { counts[w.split, default: 0] += 1 }
        let sizes = QCBench.allSplits.map { s -> String in
            let n = counts[s] ?? 0
            let frames = (try? loadRefs(s).count) ?? 0
            return "| \(s) | \(n) | \(frames) |"
        }
        return """
        # Interpolation QC benchmark: baseline

        Ground truth: Big Buck Bunny 60 fps (CC-BY 3.0 Blender Foundation). Each window gives one 30->60 frame (n-1, n+1 -> n)
        and three 15->60 frames (n-2, n+2 -> n-1, n, n+1). Splits by film time over the story (the frames before the end
        credits): train 0-60%, val 60-80%, test 80-100%. Held out: the end credits (scrolling text + post-credits scene),
        and the 4K, HDR10, grain and synthetic sets (drawn from the test part of the story or generated). In the
        cut-cutKnown / fade-fadeKnown rows the planner already knows the cut / fade, so "raw" is the hold / cross-fade the
        planner makes, not the model.

        **Broken tile:** \(BrokenTile.definition).

        **Metrics** (per generated frame, RGB PSNR in the pipeline's encoded signal): gain = policy - raw primary; worst10 =
        mean gain over the 10% of frames where raw primary is worst; drop>0.1 = share of frames more than 0.1 dB below raw
        primary (objective: <= 1%), max drop (objective: <= 0.3 dB). Recall/precision: a tile counts as acted on when the
        policy's output differs from raw primary there (tile PSNR vs raw < 70 dB); fixed = broken tile improved by >= 1 dB.
        ms/frame: FrameStream wall time per generated frame (raw = model only); the oracle rows have no cost.

        | split | windows | generated frames |
        |---|---|---|
        \(sizes.joined(separator: "\n"))

        | split | config | frames | PSNR | gain | gain worst10 | SSIM | drop>0.1 % | max drop | broken | recall % | precision % | fixed % | ms/frame | added ms | notes
        |---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
        \(rows.joined(separator: "\n"))

        ## Broken-tile thresholds, checked on the data

        Flip noise = |primary - primary with flip TTA| tile PSNR (tiles under 45 dB): how far two equally valid runs of the
        same model disagree. Gap = best other candidate minus primary. Broken share for absolute / margin thresholds.

        | split | tiles | flip noise p50/p90/p99 dB | gap p50/p90/p99 dB | broken share (abs / margin) |
        |---|---|---|---|---|
        \(defRows.joined(separator: "\n"))

        ## The current rules, judged on the dataset

        | split | rule | how often | effect |
        |---|---|---|---|
        \(ruleRows.joined(separator: "\n"))
        """
    }

    // MARK: - 3. Policy evaluation entry point

    func test3_Evaluate() async throws {
        let (m, provider) = try await Self.prepare()
        let label = QCBench.env["LUMORA_QC_LABEL"] ?? "policy"
        let sens = (QCBench.env["LUMORA_QC_SENSITIVITY"] ?? "0.5").split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        var rows: [String] = []
        for split in Self.splits(default: QCBench.heldOut + ["cut", "fade"]) {
            let refs = try Self.loadRefs(split)
            let ws = Self.windows(m, split)
            for analysis in Self.analyses(split) {
                let results = try PolicyEvaluator(provider: provider, refs: refs)
                    .run(split: split, windows: ws, configs: Self.qcConfigs(split, sensitivities: sens, label: label), analysis: analysis)
                let name = analysis == "plain" ? split : "\(split)-\(analysis)"
                for r in results {
                    let file = sens.count == 1 ? "\(label)-\(name).json" : "\(r.label)-\(name).json"
                    try Self.encoder.encode(r).write(to: QCBench.results.appendingPathComponent(file))
                }
                rows += Self.tableRows(name, results, oracle: nil)
            }
        }
        let table = """
        | split | config | frames | PSNR | gain | gain worst10 | SSIM | drop>0.1 % | max drop | broken | recall % | precision % | fixed % | ms/frame | added ms | notes
        |---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
        \(rows.joined(separator: "\n"))
        """
        try table.write(to: QCBench.results.appendingPathComponent("\(label).md"), atomically: true, encoding: .utf8)
        print(table)
    }
}
