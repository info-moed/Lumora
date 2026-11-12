import Foundation
import CoreImage
import Metal
import UniformTypeIdentifiers

/// Exports the current frame as true HDR stills: 10-bit HEIC (native), HDR AVIF (via FFmpeg: libaom 4:4:4, or
/// SVT-AV1 4:2:0 when the FFmpeg build has no libaom), plus a matching SDR JPEG for places that can't show HDR.
enum StillExporter {
    /// The AV1 encoder this FFmpeg build offers for AVIF stills (nil: no FFmpeg, or no AV1 encoder in it).
    static let avifEncoder: String? = {
        guard ToolLocator.isAvailable("ffmpeg"),
              let data = try? ToolLocator.run("ffmpeg", ["-hide_banner", "-encoders"]) else { return nil }
        let list = String(decoding: data, as: UTF8.self)
        return ["libaom-av1", "libsvtav1"].first { list.contains(" \($0) ") }
    }()

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
            if let encoder = avifEncoder {
                let png = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
                defer { try? FileManager.default.removeItem(at: png) }
                try ctx.ciContext.writePNGRepresentation(of: hdr, to: png, format: .RGBA16, colorSpace: hdrSpace, options: [:])
                let avif = base.appendingPathExtension("avif")
                let trc = hdrTarget.kind == .hlg ? "arib-std-b67" : "smpte2084"
                let aom = encoder == "libaom-av1"
                // setparams tags the frames themselves, so the AVIF's colour box carries BT.2020 + PQ/HLG
                // (output options alone leave it "unknown" with some encoders).
                var args = ["-y", "-v", "error", "-i", png.path,
                            "-vf", "setparams=color_primaries=bt2020:color_trc=\(trc):colorspace=bt2020nc,format=\(aom ? "yuv444p10le" : "yuv420p10le")",
                            "-c:v", encoder, "-crf", "18"]
                args += aom ? ["-still-picture", "1"] : ["-svtav1-params", "avif=1"]
                args += ["-color_primaries", "bt2020", "-color_trc", trc, "-colorspace", "bt2020nc", avif.path]
                try ToolLocator.run("ffmpeg", args)
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
