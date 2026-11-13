import XCTest
import Metal
import CoreML
@testable import Lumora

/// The interpolation model catalog and the IFRNet converter's output (scripts/convert_ifrnet_coreml.py).
final class InterpolationCatalogTests: XCTestCase {

    func testCatalogDecodesAndIFRNetEntriesMatchTheConverter() throws {
        let all = InterpolationModelSpec.all()
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "duplicate model ids")
        for id in ["ifrnet-l", "ifrnet"] {
            let s = try XCTUnwrap(all.first { $0.id == id }, "\(id) missing from the catalog")
            // The converter's tensor names and the padding its 1/16 encoder needs.
            XCTAssertEqual([s.inputA, s.inputB, s.timestep, s.output], ["img0", "img1", "timestep", "output"])
            XCTAssertEqual(s.timestepKind, "map")
            XCTAssertEqual(s.padMultiple % 16, 0)
            XCTAssertFalse(s.isFlow, "IFRNet flow exports aren't offered: the artifact checker was measured worse with them")
            XCTAssertEqual(s.defaultComputeUnits, .cpuAndGPU)
            XCTAssertTrue(s.license.hasPrefix("MIT"))
            XCTAssertNotEqual(s.tier, "best", "IFRNet must not join the heavy-model candidates of per-scene routing")
        }
        // Entries without the field keep letting Core ML choose.
        XCTAssertEqual(try XCTUnwrap(all.first { $0.id == "rife-4" }).defaultComputeUnits, .all)
        XCTAssertFalse(all.filter(\.isFlow).contains { $0.id.hasPrefix("ifrnet") })
    }

    /// The converted IFRNet must follow the time input (a conversion that bakes in the traced t = 0.5, or a
    /// midpoint-only Vimeo90K checkpoint, gives the same frame at every t) and place frames in the right order.
    func testInstalledIFRNetFollowsTime() throws {
        try TestHardware.requireGPU()
        let installed = InterpolationModelSpec.all().filter { $0.id.hasPrefix("ifrnet") && $0.isInstalled }
        guard !installed.isEmpty else { throw XCTSkip("no IFRNet model installed (scripts/convert_ifrnet_coreml.py)") }
        let ctx = MetalContext.shared
        let w = 160, h = 96
        func pattern(_ dx: Float) -> MTLTexture {
            var px = [Float16](repeating: 1, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let xx = Float(x) - dx, yy = Float(y)
                px[(y * w + x) * 4 + 0] = Float16(0.5 + 0.3 * sin(xx / 9))
                px[(y * w + x) * 4 + 1] = Float16(0.5 + 0.3 * cos(xx / 13 + yy / 7))
                px[(y * w + x) * 4 + 2] = Float16(0.5 + 0.2 * sin(yy / 5))
            } }
            let t = ctx.makeTexture(width: w, height: h, format: .rgba16Float, storage: .shared)
            px.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 8) }
            return t
        }
        func read(_ t: MTLTexture) -> [Float] {
            let s = ctx.makeTexture(width: w, height: h, format: .rgba16Float, storage: .shared)
            let cb = ctx.queue.makeCommandBuffer()!
            let b = cb.makeBlitCommandEncoder()!
            b.copy(from: t, to: s)
            b.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            var px = [Float16](repeating: 0, count: w * h * 4)
            px.withUnsafeMutableBytes { s.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
            return px.map(Float.init)
        }
        /// Mean absolute RGB difference away from the borders.
        func mad(_ a: [Float], _ b: [Float]) -> Float {
            var s: Float = 0, n: Float = 0
            for y in 16..<(h - 16) { for x in 16..<(w - 16) { for c in 0..<3 { s += abs(a[(y * w + x) * 4 + c] - b[(y * w + x) * 4 + c]); n += 1 } } }
            return s / n
        }
        let a = pattern(0), b = pattern(8)
        let truth = [0.25: read(pattern(2)), 0.75: read(pattern(6))]
        let proxy = UniformBuilder.analysis(source: SourceColor(name: "t", transfer: .bt1886, gamut: .rec709, legalToFull: false, confidence: 1),
                                            gridW: 1, gridH: 1)
        for spec in installed {
            let e = try CoreMLInterpolator(spec: spec, proxyUniforms: proxy)
            let outs = [ctx.makeTexture(width: w, height: h, format: .rgba16Float), ctx.makeTexture(width: w, height: h, format: .rgba16Float)]
            _ = try e.interpolate(a, b, times: [0.25, 0.75], into: outs, qcTiles: (1, 1))
            let q = read(outs[0]), r = read(outs[1])
            let right = mad(q, truth[0.25]!) + mad(r, truth[0.75]!), swapped = mad(q, truth[0.75]!) + mad(r, truth[0.25]!)
            XCTAssertGreaterThan(mad(q, r), 0.01, "\(spec.id): the same frame at t = 0.25 and 0.75 (time input ignored)")
            XCTAssertLessThan(right, 0.5 * swapped, "\(spec.id): frames at t = 0.25 / 0.75 are not where they belong")
        }
    }
}
