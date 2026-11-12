import Foundation
import CoreImage
import Metal
import UniformTypeIdentifiers

/// Exports the current frame as true HDR stills: 10-bit HEIC (native), HDR AVIF (via FFmpeg/libaom),
/// plus a matching SDR JPEG for places that can't show HDR.
enum StillExporter {
    static func export(frame: MTLTexture, preset: PresetCandidate, params: GradeParams, sceneExposure: Float,
                       crop: SIMD4<Float>, target: OutputTarget, to base: URL) throws -> [URL] {
        let ctx = MetalContext.shared
        let w = Int(Float(frame.width) * crop.z) & ~1, h = Int(Float(frame.height) * crop.w) & ~1
        func render(_ t: OutputTarget) -> CIImage? {
            let dst = ctx.makeTexture(width: w, height: h, format: .rgba16Float)
            let u = UniformBuilder.make(source: preset.color, params: params, target: t, sceneExposureStops: sceneExposure,
                                        viewport: SIMD4<Float>(0, 0, Float(w), Float(h)), crop: crop)
            let cb = ctx.queue.makeCommandBuffer()!
            GradeRenderer().encodeGrade(cb, source: frame, destination: dst, uniforms: u)
            cb.commit()
            cb.waitUntilCompleted()
            let space = t.kind == .hdr10 ? CGColorSpace.itur_2100_PQ : (t.kind == .hlg ? CGColorSpace.itur_2100_HLG : CGColorSpace.itur_709)
            guard let img = CIImage(mtlTexture: dst, options: [.colorSpace: CGColorSpace(name: space)!]) else { return nil }
            return img.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -img.extent.height))
        }
        var out: [URL] = []
        let hdrTarget = target.isHDR ? target : .hdr10_1000
        let hdrSpace = CGColorSpace(name: hdrTarget.kind == .hlg ? CGColorSpace.itur_2100_HLG : CGColorSpace.itur_2100_PQ)!
        if let hdr = render(hdrTarget) {
            let heic = base.appendingPathExtension("heic")
            try ctx.ciContext.writeHEIF10Representation(of: hdr, to: heic, colorSpace: hdrSpace, options: [:])
            out.append(heic)
            if ToolLocator.isAvailable("ffmpeg") {
                let png = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                try ctx.ciContext.writePNGRepresentation(of: hdr, to: png, format: .RGBA16, colorSpace: hdrSpace, options: [:])
                let avif = base.appendingPathExtension("avif")
                let trc = hdrTarget.kind == .hlg ? "arib-std-b67" : "smpte2084"
                try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", png.path, "-c:v", "libaom-av1", "-still-picture", "1",
                                               "-crf", "18", "-pix_fmt", "yuv444p10le", "-color_primaries", "bt2020",
                                               "-color_trc", trc, "-colorspace", "bt2020nc", avif.path])
                try? FileManager.default.removeItem(at: png)
                out.append(avif)
            }
        }
        if let sdr = render(.sdr) {
            let jpg = base.appendingPathExtension("jpg")
            try ctx.ciContext.writeJPEGRepresentation(of: sdr, to: jpg, colorSpace: CGColorSpace(name: CGColorSpace.itur_709)!,
                                                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
            out.append(jpg)
        }
        return out
    }
}

/// Shareable look files (.lumorapreset). They store the look, not the footage-specific exposure, so a preset
/// made on one clip adapts to the next.
struct PresetFile: Codable {
    var format = "lumora-preset"
    var version = 1
    var name: String
    var look: Look
    var params: GradeParams
    var madeFor: String?

    static let type = UTType(filenameExtension: "lumorapreset") ?? .json

    static func save(_ preset: PresetCandidate, params: GradeParams, to url: URL) throws {
        var p = params
        p.matchCurve = nil   // reference matches belong to one film, not to a look
        let file = PresetFile(name: preset.name, look: preset.look, params: p, madeFor: preset.color.name)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(file).write(to: url)
    }

    static func load(_ url: URL) throws -> PresetFile {
        let f = try JSONDecoder().decode(PresetFile.self, from: Data(contentsOf: url))
        guard f.format == "lumora-preset" else { throw LumoraError.unsupported("Not a Lumora preset.") }
        return f
    }
}
