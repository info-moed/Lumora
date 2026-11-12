import Foundation
import Metal

/// Reference frames from your own films. After any change to Lumora (or a tool update), "Check" re-renders them
/// with the saved settings and flags frames whose picture moved by more than a visible amount.
struct GoldenFrame: Codable, Identifiable {
    var id = UUID()
    var source: String
    var frame: Int
    var look: Look
    var params: GradeParams
    var exposure: Float
    var colorName: String
    var target: OutputTarget
    var width: Int
    var height: Int
    var created = Date()
    var note: String
}

enum RegressionSet {
    private static var folder: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora/Regression")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func all() -> [GoldenFrame] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(GoldenFrame.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created < $1.created }
    }

    /// Saves the current frame and settings as a reference (its rendered pixels, in a comparable form).
    @MainActor
    static func add(from model: AppModel, note: String) async throws {
        guard let d = model.descriptor, let p = model.selectedPreset, let c = model.selectedColor else { return }
        let f = Int(model.previewTime * d.fps)
        let exposure = model.analysis.map { p.sceneExposures[safe: $0.sceneIndex(for: f)] ?? 0 } ?? 0
        let pixels = try await render(d: d, frame: f, params: model.params, exposure: exposure, color: c, target: model.previewTarget)
        let g = GoldenFrame(source: d.url.path, frame: f, look: p.look, params: model.params, exposure: exposure, colorName: c.name,
                            target: model.previewTarget, width: pixels.width, height: pixels.height, note: note)
        try JSONEncoder().encode(g).write(to: folder.appendingPathComponent("\(g.id).json"))
        try pixels.data.write(to: folder.appendingPathComponent("\(g.id).bin"))
        Log.notice(.app, "Added reference frame \(f) of \(d.url.lastPathComponent) to the regression set")
    }

    struct Result: Identifiable { var id: UUID; var name: String; var psnr: Float; var ok: Bool; var missing: Bool }

    /// Re-renders every reference and compares (PSNR in a perceptual domain; ≥ 45 dB = no visible change).
    static func check(progress: ProgressReporter) async -> [Result] {
        var out: [Result] = []
        let items = all()
        for (i, g) in items.enumerated() {
            let name = "\(URL(fileURLWithPath: g.source).lastPathComponent) @ \(g.frame)"
            progress.update(Double(i) / Double(max(1, items.count)), detail: name)
            guard FileManager.default.fileExists(atPath: g.source),
                  let ref = try? Data(contentsOf: folder.appendingPathComponent("\(g.id).bin")),
                  let (d, colors) = try? await SourceInspector.inspect(URL(fileURLWithPath: g.source)),
                  let c = colors.first(where: { $0.name == g.colorName }) ?? colors.first,
                  let now = try? await render(d: d, frame: g.frame, params: g.params, exposure: g.exposure, color: c, target: g.target) else {
                out.append(Result(id: g.id, name: name, psnr: 0, ok: false, missing: true)); continue
            }
            let psnr = compare(ref, now.data)
            out.append(Result(id: g.id, name: name, psnr: psnr, ok: psnr >= 45, missing: false))
        }
        progress.update(1, detail: nil)
        Log.notice(.app, "Regression check: \(out.filter(\.ok).count) of \(out.count) unchanged")
        return out
    }

    private static func render(d: SourceDescriptor, frame: Int, params: GradeParams, exposure: Float, color: SourceColor,
                               target: OutputTarget) async throws -> (data: Data, width: Int, height: Int) {
        let src = try await d.makeFrameSource()
        try src.start(at: frame, count: 1)
        guard let f = try src.nextFrame() else { throw LumoraError.unsupported("Frame not readable") }
        let r = GradeRenderer()
        let ctx = MetalContext.shared
        let graded = ctx.makeTexture(width: f.texture.width, height: f.texture.height, format: .rgba16Float)
        let cb = ctx.queue.makeCommandBuffer()!
        // The viewport is the whole destination: a zero viewport would leave every pixel outside the picture (black).
        r.encodeGrade(cb, source: f.texture, destination: graded,
                      uniforms: UniformBuilder.make(source: color, params: params, target: target, sceneExposureStops: exposure,
                                                    viewport: SIMD4<Float>(0, 0, Float(graded.width), Float(graded.height)), crop: d.crop))
        await cb.commitAndWait()
        let small = r.comparable(graded, color: SourceColor(name: "out", transfer: target.kind == .hdr10 ? .pq : (target.kind == .hlg ? .hlg : .bt1886),
                                                           gamut: .rec2020, legalToFull: false, confidence: 1), width: 960)
        // `comparable` renders into GPU-private memory; copy to a CPU-visible texture before reading it back.
        let readable = ctx.makeTexture(width: small.width, height: small.height, format: small.pixelFormat,
                                       usage: [.shaderRead], storage: .shared)
        let copy = ctx.queue.makeCommandBuffer()!
        let blit = copy.makeBlitCommandEncoder()!
        blit.copy(from: small, to: readable)
        blit.endEncoding()
        await copy.commitAndWait()
        var buf = [Float](repeating: 0, count: small.width * small.height * 4)      // RGBA, 32-bit float
        readable.getBytes(&buf, bytesPerRow: small.width * 16, from: MTLRegionMake2D(0, 0, small.width, small.height), mipmapLevel: 0)
        return (Data(bytes: buf, count: buf.count * 4), small.width, small.height)
    }

    private static func compare(_ a: Data, _ b: Data) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let x = a.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let y = b.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let mse = zip(x, y).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Float(x.count)
        return mse <= 1e-12 ? 99 : 10 * log10f(1 / mse)
    }
}
