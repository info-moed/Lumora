import XCTest
import Metal
@testable import Lumora

/// Fast regression tests for the learned artifact scorer (ArtifactScorer + QCScorerWeights).
///
/// - The committed fixture (Resources/qc-scorer-fixture.json, written by scripts/qc_scorer/train.py from validation
///   frames: numbers only, no pictures) pins that the Swift trees reproduce the trained predictions, and that on
///   those frames the policy never lowers a frame's PSNR by more than 0.1 dB at any sensitivity while still switching
///   most of the broken tiles it was shown.
/// - A synthetic pan with planted artifacts runs the real GPU path (models required): planted tiles get replaced,
///   untouched frames don't get worse.
final class QCScorerTests: XCTestCase {

    struct Fixture: Decodable {
        struct Parity: Decodable { var tag: String; var x: [Float]; var quality: Float; var gains: [String: Float]; var risks: [String: Float] }
        struct Tile: Decodable { var x: [Float]; var px: Double; var psnr: [String: Double]; var broken: Bool }
        struct Frame: Decodable {
            var name: String
            var hasAlternative: Bool
            var frame: [Float]           // frame-level statistics (shot-change test)
            var tiles: [Tile]            // every tile of the frame
        }
        var trained: String
        var parity: [Parity]
        var frames: [Frame]
    }

    static func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: QCScorerTests.self).url(forResource: "qc-scorer-fixture", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testWeightsLoadAndMatchTheTrainedFeatures() throws {
        let model = try XCTUnwrap(QCScorerModel.shared, "trained scorer weights failed to load")
        XCTAssertNotNil(model.set(alternative: true))
        XCTAssertNotNil(model.set(alternative: false))
        XCTAssertEqual(try Self.fixture().trained, QCScorerWeights.trained, "fixture and weights come from different training runs")
    }

    func testSwiftTreesReproduceTrainedPredictions() throws {
        let model = try XCTUnwrap(QCScorerModel.shared)
        let f = try Self.fixture()
        XCTAssertGreaterThan(f.parity.count, 50)
        let names: [ArtifactScorer.Choice: String] = [.alternative: "alternative", .blend: "blend", .nearest: "nearest", .average: "average"]
        for p in f.parity {
            let set = try XCTUnwrap(model.set(alternative: p.tag == "alt"))
            XCTAssertEqual(set.quality.predict(p.x), p.quality, accuracy: 2e-3)
            for o in set.options {
                XCTAssertEqual(o.gain.predict(p.x), try XCTUnwrap(p.gains[names[o.choice]!]), accuracy: 2e-3)
                XCTAssertEqual(o.risk.predict(p.x), try XCTUnwrap(p.risks[names[o.choice]!]), accuracy: 2e-3)
            }
        }
    }

    static let column: [UInt8: String] = [0: "P", 1: "Q", 2: "blend", 3: "nearest", 4: "average"]

    /// Exact frame PSNR change of the policy on a fixture frame (hard tile switching, like qcComposeKernel).
    static func gain(_ fr: Fixture.Frame, _ d: ArtifactScorer.Decision) -> Double {
        let mse = { (p: Double) in pow(10, -p / 10) }
        var raw = 0.0, sse = 0.0
        for (i, t) in fr.tiles.enumerated() {
            raw += t.px * mse(t.psnr["P"]!)
            sse += t.px * mse(t.psnr[column[d.choices[i]]!]!)
        }
        return 10 * log10(raw / max(sse, 1e-12))
    }

    func testPolicyNeverLowersFixtureFramesAndCatchesBrokenTiles() throws {
        let scorer = ArtifactScorer()
        let f = try Self.fixture()
        XCTAssertGreaterThan(f.frames.count, 5)
        for s: Float in [0, 0.5, 1] {
            var broken = 0, caught = 0, switched = 0, worst = 0.0, total = 0.0
            for fr in f.frames {
                let m = ArtifactScorer.Measurement(tilesX: fr.tiles.count, tilesY: 1, scale: 1, features: fr.tiles.map(\.x), frame: fr.frame,
                                                   hasAlternative: fr.hasAlternative)
                let d = scorer.decide(m, sensitivity: s)
                XCTAssertFalse(d.shotChange, "\(fr.name): a real frame pair was taken for a shot change")
                let g = Self.gain(fr, d)
                worst = min(worst, g)
                total += g
                XCTAssertGreaterThan(g, -0.1, "\(fr.name) at sensitivity \(s): \(g) dB")
                for (i, t) in fr.tiles.enumerated() where t.broken {
                    broken += 1
                    if d.choices[i] != 0 { caught += 1 }
                }
                switched += d.switched
            }
            print("QC-SCORER fixture s=\(s): \(f.frames.count) frames, mean gain \(total / Double(f.frames.count)) dB, worst \(worst) dB, broken \(caught)/\(broken) switched, \(switched) tiles switched")
            XCTAssertGreaterThan(total, 0, "sensitivity \(s) should gain on frames with broken tiles")
            if s >= 0.5 { XCTAssertGreaterThan(Double(caught), 0.3 * Double(broken), "sensitivity \(s) catches too few broken tiles") }
        }
    }

    func testSensitivityIsMonotonic() throws {
        let scorer = ArtifactScorer()
        let f = try Self.fixture()
        var counts: [Int] = []
        for s: Float in [0, 0.25, 0.5, 0.75, 1] {
            counts.append(f.frames.reduce(0) { n, fr in
                n + scorer.decide(ArtifactScorer.Measurement(tilesX: fr.tiles.count, tilesY: 1, scale: 1, features: fr.tiles.map(\.x),
                                                            frame: fr.frame, hasAlternative: fr.hasAlternative), sensitivity: s).switched
            })
        }
        XCTAssertEqual(counts, counts.sorted(), "higher sensitivity must switch at least as many tiles: \(counts)")
        XCTAssertGreaterThan(counts.last!, counts.first!)
    }

    func testShotChangeHoldsTheNearestOriginal() throws {
        let set = try XCTUnwrap(QCScorerModel.shared?.set(alternative: true))
        // Unrelated pictures: no tile correlation, large differences everywhere.
        XCTAssertTrue(set.isShotChange([0.0, 0.25, 0.2, 0.8, 0.5, 0.2]))
        // A still frame pair is never a shot change.
        XCTAssertFalse(set.isShotChange([1.0, 0.002, 0.001, 0.0, 0.05, 0.002]))
    }

    // MARK: - Planted artifacts through the real GPU path

    /// A textured, smoothly panning picture (no file, no FFmpeg): frame at time `x` in pixels of pan.
    static func pan(_ w: Int, _ h: Int, shift: Float) -> MTLTexture {
        let ctx = MetalContext.shared
        let t = ctx.makeTexture(width: w, height: h, format: .rgba32Float, storage: .shared)
        var px = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let u = Float(x) + shift, v = Float(y) + shift * 0.4
                let a = 0.5 + 0.2 * sin(u * 0.07) * cos(v * 0.05) + 0.12 * sin((u + v) * 0.21) + 0.08 * sin(u * 0.013 + v * 0.031)
                px[(y * w + x) * 4 + 0] = a
                px[(y * w + x) * 4 + 1] = 0.9 * a + 0.05
                px[(y * w + x) * 4 + 2] = 1.1 * a - 0.08
            }
        }
        px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 16) }
        return t
    }

    static func psnr(_ a: MTLTexture, _ b: MTLTexture) -> (frame: Double, tiles: [Double]) {
        func read(_ t: MTLTexture) -> [Float] {
            let s = MetalContext.shared.makeTexture(width: t.width, height: t.height, format: .rgba32Float, storage: .shared)
            let cb = MetalContext.shared.queue.makeCommandBuffer()!
            let bl = cb.makeBlitCommandEncoder()!
            bl.copy(from: t, to: s)
            bl.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            var px = [Float](repeating: 0, count: t.width * t.height * 4)
            px.withUnsafeMutableBytes { s.getBytes($0.baseAddress!, bytesPerRow: t.width * 16, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0) }
            return px
        }
        let pa = read(a), pb = read(b)
        let tx = (a.width + 63) / 64, ty = (a.height + 63) / 64
        var sse = [Double](repeating: 0, count: tx * ty), n = [Double](repeating: 0, count: tx * ty)
        for y in 0..<a.height {
            for x in 0..<a.width {
                let i = min(y / 64, ty - 1) * tx + min(x / 64, tx - 1)
                for c in 0..<3 { let d = Double(pa[(y * a.width + x) * 4 + c] - pb[(y * a.width + x) * 4 + c]); sse[i] += d * d }
                n[i] += 3
            }
        }
        let f = 10 * log10(n.reduce(0, +) / max(1e-12, sse.reduce(0, +)))
        return (f, zip(sse, n).map { 10 * log10($0.1 / max(1e-12, $0.0)) })
    }

    func testPlantedArtifactsAreReplacedAndCleanFramesKept() throws {
        try TestHardware.requireGPU()
        let specs = InterpolationModelSpec.all()
        guard let img = specs.first(where: { $0.id == "rife-4.25" && $0.isInstalled }),
              let flow = specs.first(where: { $0.id == "rife-4.25-flow" && $0.isInstalled }) else {
            throw XCTSkip("RIFE 4.25 image and flow models are not installed")
        }
        let sdr = SourceColor(name: "SDR", transfer: .bt1886, gamut: .rec709, legalToFull: false, confidence: 1)
        let proxy = UniformBuilder.analysis(source: sdr, gridW: 1, gridH: 1)
        let primary = try CoreMLInterpolator(spec: img, proxyUniforms: proxy)
        let alt = try CoreMLInterpolator(spec: flow, proxyUniforms: proxy)
        let (w, h) = (640, 384)
        alt.modelScaleOverride = ArtifactScorer.alternativeModelScale(forWidth: w)
        let a = Self.pan(w, h, shift: 0), b = Self.pan(w, h, shift: 12), truth = Self.pan(w, h, shift: 6)
        let ctx = MetalContext.shared
        let p = ctx.makeTexture(width: w, height: h, format: .rgba32Float)
        let q = ctx.makeTexture(width: w, height: h, format: .rgba32Float)
        _ = try primary.interpolate(a, b, times: [0.5], into: [p], qcTiles: (1, 1))
        _ = try alt.interpolate(a, b, times: [0.5], into: [q], qcTiles: (1, 1))
        let scorer = ArtifactScorer()

        // Clean frame: whatever the scorer does must not cost more than 0.1 dB.
        let m0 = scorer.measure(a: a, b: b, primary: p, alternative: q, alternativeEngine: alt, t: 0.5, primaryIsFlow: false)
        let d0 = scorer.decide(m0, sensitivity: 1)
        XCTAssertFalse(d0.shotChange)
        let out0 = ctx.makeTexture(width: w, height: h, format: .rgba32Float)
        scorer.compose(primary: p, alternative: q, a: a, b: b, t: 0.5, decision: d0, into: out0)
        let raw0 = Self.psnr(p, truth).frame, pol0 = Self.psnr(out0, truth).frame
        XCTAssertGreaterThan(pol0, raw0 - 0.1, "clean frame: raw \(raw0) dB, with QC \(pol0) dB")

        // Plant artifacts: a tear (content from far along the pan), a black hole and a 1-px checkerboard.
        let planted = [12, 23, 36]                       // tiles of the 10x6 grid
        let far = Self.pan(w, h, shift: 60)
        let broken = ctx.makeTexture(width: w, height: h, format: .rgba32Float, storage: .shared)
        var px = [Float](repeating: 0, count: w * h * 4)
        let pc = ctx.makeTexture(width: w, height: h, format: .rgba32Float, storage: .shared)
        let cb = ctx.queue.makeCommandBuffer()!
        let bl = cb.makeBlitCommandEncoder()!
        bl.copy(from: p, to: pc)
        bl.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        px.withUnsafeMutableBytes { pc.getBytes($0.baseAddress!, bytesPerRow: w * 16, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        var farPx = [Float](repeating: 0, count: w * h * 4)
        farPx.withUnsafeMutableBytes { far.getBytes($0.baseAddress!, bytesPerRow: w * 16, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        for (k, tile) in planted.enumerated() {
            let x0 = (tile % 10) * 64, y0 = (tile / 10) * 64
            for y in y0..<(y0 + 64) {
                for x in x0..<(x0 + 64) {
                    for c in 0..<3 {
                        let i = (y * w + x) * 4 + c
                        px[i] = k == 0 ? farPx[i] : k == 1 ? 0 : ((x + y) % 2 == 0 ? 0.05 : 0.95)
                    }
                }
            }
        }
        px.withUnsafeBytes { broken.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 16) }
        for s: Float in [0, 0.5, 1] {
            let m = scorer.measure(a: a, b: b, primary: broken, alternative: q, alternativeEngine: alt, t: 0.5, primaryIsFlow: false)
            let d = scorer.decide(m, sensitivity: s)
            XCTAssertFalse(d.shotChange)
            let out = ctx.makeTexture(width: w, height: h, format: .rgba32Float)
            scorer.compose(primary: broken, alternative: q, a: a, b: b, t: 0.5, decision: d, into: out)
            let raw = Self.psnr(broken, truth), pol = Self.psnr(out, truth)
            let caught = planted.filter { d.choices[$0] != 0 }.count
            print("QC-SCORER planted s=\(s): caught \(caught)/\(planted.count), switched \(d.switched) tiles, raw \(raw.frame) dB -> \(pol.frame) dB")
            XCTAssertEqual(caught, planted.count, "sensitivity \(s): planted tiles switched \(planted.map { d.choices[$0] })")
            XCTAssertGreaterThan(pol.frame, raw.frame + 3, "sensitivity \(s)")
            for (i, c) in d.choices.enumerated() where c != 0 && !planted.contains(i) {
                XCTAssertGreaterThan(pol.tiles[i], raw.tiles[i] - 1, "sensitivity \(s): tile \(i) got worse")
            }
        }
    }
}
