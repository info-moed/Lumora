import Foundation
import CryptoKit

/// Everything needed to rebuild an ExportJob after a relaunch. SourceDescriptor and PresetCandidate aren't Codable
/// (and Swift can't add synthesized Codable from another file), so they are mirrored field by field here.
struct ExportRecipe: Codable {
    struct Source: Codable {
        var url: URL
        var kind: SourceKind
        var files: [URL]
        var width, height, fpsNum, fpsDen, frameCount: Int
        var codec: String
        var bitDepth: Int?
        var primariesTag, transferTag, matrixTag, logTag: String?
        var isDolbyVision: Bool
        var dvProfile: Int?
        var dvHasEnhancementLayer: Bool
        var make, model: String?
        var hasAudio: Bool
        var fieldOrder: String?
        var scanFix, suggestedScanFix: ScanFix
        var originalKind: SourceKind?
        var originalFpsNum, originalFpsDen, originalFrameCount: Int
        var crop: [Float]
    }
    struct Preset: Codable {
        var name: String
        var look: Look
        var color: SourceColor
        var params: GradeParams
        var sceneExposures: [Float]
        var reason: String
        var recommended: Bool
    }

    var source: Source
    var preset: Preset
    var analysis: AnalysisResult
    var delivery: DeliveryFormat
    var peakNits: Float
    var codec: Codec
    var bitDepth: Int
    var chroma: ChromaFormat
    var quality: Float
    var interpolation: InterpolationSettings
    var sourcePeakNits: Float
    var upscale: UpscaleMode
    var qualityTarget: QualityTarget?
    var encodeChoice: EncodeChoice?
    var filmTexture: FilmTexture
    var externalRepair: ExternalRepairPlan?
    var frameRange: [Int]?
    var filmTextureStrength: Float
    var contentKind: ContentKind
    var outputURL: URL

    init(_ j: ExportJob) {
        let d = j.descriptor
        source = Source(url: d.url, kind: d.kind, files: d.files, width: d.width, height: d.height, fpsNum: d.fpsNum,
                        fpsDen: d.fpsDen, frameCount: d.frameCount, codec: d.codec, bitDepth: d.bitDepth, primariesTag: d.primariesTag,
                        transferTag: d.transferTag, matrixTag: d.matrixTag, logTag: d.logTag, isDolbyVision: d.isDolbyVision,
                        dvProfile: d.dvProfile, dvHasEnhancementLayer: d.dvHasEnhancementLayer, make: d.make, model: d.model,
                        hasAudio: d.hasAudio, fieldOrder: d.fieldOrder, scanFix: d.scanFix, suggestedScanFix: d.suggestedScanFix,
                        originalKind: d.originalKind, originalFpsNum: d.originalFpsNum, originalFpsDen: d.originalFpsDen,
                        originalFrameCount: d.originalFrameCount, crop: [d.crop.x, d.crop.y, d.crop.z, d.crop.w])
        let p = j.preset
        preset = Preset(name: p.name, look: p.look, color: p.color, params: p.params, sceneExposures: p.sceneExposures,
                        reason: p.reason, recommended: p.recommended)
        analysis = j.analysis
        delivery = j.delivery; peakNits = j.peakNits; codec = j.codec; bitDepth = j.bitDepth; chroma = j.chroma
        quality = j.quality; interpolation = j.interpolation; sourcePeakNits = j.sourcePeakNits; upscale = j.upscale
        qualityTarget = j.qualityTarget; encodeChoice = j.encodeChoice; filmTexture = j.filmTexture
        externalRepair = j.externalRepair; frameRange = j.frameRange.map { [$0.lowerBound, $0.upperBound] }
        filmTextureStrength = j.filmTextureStrength; contentKind = j.contentKind; outputURL = j.outputURL
    }

    var job: ExportJob {
        let s = source
        var d = SourceDescriptor(url: s.url, kind: s.kind)
        d.files = s.files; d.width = s.width; d.height = s.height; d.fpsNum = s.fpsNum; d.fpsDen = s.fpsDen
        d.frameCount = s.frameCount; d.codec = s.codec; d.bitDepth = s.bitDepth; d.primariesTag = s.primariesTag
        d.transferTag = s.transferTag; d.matrixTag = s.matrixTag; d.logTag = s.logTag; d.isDolbyVision = s.isDolbyVision
        d.dvProfile = s.dvProfile; d.dvHasEnhancementLayer = s.dvHasEnhancementLayer; d.make = s.make; d.model = s.model
        d.hasAudio = s.hasAudio; d.fieldOrder = s.fieldOrder; d.scanFix = s.scanFix; d.suggestedScanFix = s.suggestedScanFix
        d.originalKind = s.originalKind; d.originalFpsNum = s.originalFpsNum; d.originalFpsDen = s.originalFpsDen
        d.originalFrameCount = s.originalFrameCount
        if s.crop.count == 4 { d.crop = SIMD4<Float>(s.crop[0], s.crop[1], s.crop[2], s.crop[3]) }
        let p = PresetCandidate(name: preset.name, look: preset.look, color: preset.color, params: preset.params,
                                sceneExposures: preset.sceneExposures, reason: preset.reason, recommended: preset.recommended)
        var j = ExportJob(descriptor: d, preset: p, analysis: analysis, delivery: delivery, codec: codec, outputURL: outputURL)
        j.peakNits = peakNits; j.bitDepth = bitDepth; j.chroma = chroma; j.quality = quality; j.interpolation = interpolation
        j.sourcePeakNits = sourcePeakNits; j.upscale = upscale; j.qualityTarget = qualityTarget; j.encodeChoice = encodeChoice
        j.filmTexture = filmTexture; j.externalRepair = externalRepair
        if let r = frameRange, r.count == 2 { j.frameRange = r[0]..<r[1] }
        j.filmTextureStrength = filmTextureStrength; j.contentKind = contentKind
        return j
    }

    /// A stable hash of what is rendered (not where it is saved), so the Export sheet can tell whether saved progress
    /// matches the export about to start. Sets and integer-keyed dictionaries are put in a fixed order first.
    func hash(includingOutput: Bool = false) -> String {
        var r = self
        if !includingOutput { r.outputURL = URL(fileURLWithPath: "/") }
        guard let data = try? JSONEncoder().encode(r),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return "" }
        let canonical = Self.canonical(obj, key: nil)
        let out = (try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys, .fragmentsAllowed])) ?? data
        return SHA256.hash(data: out).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonical(_ v: Any, key: String?) -> Any {
        if let d = v as? [String: Any] {
            var o: [String: Any] = [:]
            for (k, x) in d { o[k] = canonical(x, key: k) }
            return o
        }
        if let a = v as? [Any] {
            let mapped = a.map { canonical($0, key: nil) }
            if ["cutFrames", "duplicateFrames", "flagged"].contains(key ?? ""), let nums = mapped as? [Int] { return nums.sorted() }
            if key == "routes", mapped.count % 2 == 0 {
                // [key, value, key, value, …] in insertion order: sort the pairs by key.
                let pairs = stride(from: 0, to: mapped.count, by: 2).map { (mapped[$0], mapped[$0 + 1]) }
                if pairs.allSatisfy({ $0.0 is Int }) {
                    return pairs.sorted { ($0.0 as! Int) < ($1.0 as! Int) }.flatMap { [$0.0, $0.1] }
                }
            }
            return mapped
        }
        return v
    }
}
