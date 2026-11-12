import Foundation
import CoreGraphics
import Metal

/// The busiest parts of a film (where interpolation is hardest) and a short side-by-side test on them.
struct MotionHotspot: Identifiable, Hashable {
    var id: Int { scene }
    var scene: Int
    var start: Int
    var end: Int
    var motion: Float
    var seconds: Double
    var label: String { String(format: "%02d:%02d  scene %d", Int(seconds) / 60, Int(seconds) % 60, scene + 1) }
}

/// A playable interpolation test: the original frame rate (repeated frames, so it judders like the source)
/// next to the interpolated frames, at the same timing.
struct InterpolationTrial {
    var hotspot: MotionHotspot
    var original: [CGImage]          // at the output rate, held frames repeated
    var interpolated: [CGImage]
    var generatedMask: [Bool]        // which interpolated frames are new
    var outputFps: Double
    var model: String
    var repairs: [QCEvent]
    var verdict: String
}

enum MotionScan {
    /// Top scenes by average frame-to-frame change (cuts excluded), at least ~1 s long.
    static func hotspots(_ a: AnalysisResult, fps: Double, count: Int = 6) -> [MotionHotspot] {
        let minLen = max(12, Int(fps))
        return a.scenes.indices
            .filter { a.scenes[$0].end - a.scenes[$0].start >= minLen }
            .map { MotionHotspot(scene: $0, start: a.scenes[$0].start, end: a.scenes[$0].end, motion: a.sceneMotion($0),
                                 seconds: Double(a.scenes[$0].start) / fps) }
            .sorted { $0.motion > $1.motion }
            .prefix(count).map { $0 }
    }

    /// Interpolates ~2 s of a hotspot at preview size with the current settings (and the scene's routed model).
    static func trial(_ d: SourceDescriptor, color: SourceColor, analysis a: AnalysisResult, preset: PresetCandidate,
                      settings: InterpolationSettings, hotspot h: MotionHotspot, previewTarget: OutputTarget) async throws -> InterpolationTrial {
        var s = settings
        if case .off = s.mode { s.mode = .multiply(2) }        // a test needs something to interpolate
        let (plan, rate) = InterpolationPlanner.plan(sourceFrames: d.frameCount, sourceRate: (d.fpsNum, d.fpsDen), settings: s, analysis: a)
        let first = plan.firstIndex { $0.a >= h.start } ?? 0
        let span = Int(Double(rate.num) / Double(rate.den) * 2)
        let range = first..<min(plan.count, first + span, plan.lastIndex { $0.a < h.end }.map { $0 + 1 } ?? plan.count)
        let stream = try FrameStream(source: try await d.makeFrameSource(), plan: plan[range], settings: s,
                                     proxyUniforms: UniformBuilder.analysis(source: color, gridW: 1, gridH: 1),
                                     proxyWidth: 960, sceneOf: { a.sceneIndex(for: $0) })
        let r = GradeRenderer()
        var interp: [CGImage] = [], orig: [CGImage] = [], mask: [Bool] = []
        var lastOriginal: CGImage?
        var k = range.lowerBound
        while let f = try stream.next() {
            try Task.checkCancellation()
            let p = plan[k]
            let u = UniformBuilder.make(source: color, params: preset.params, target: .sdr, sceneExposureStops: 0,
                                        viewport: .zero, crop: d.crop)
            guard let img = r.thumbnail(f.texture, uniforms: u, width: 640) else { k += 1; continue }
            interp.append(img)
            let isNew = p.kind == .generated || p.kind == .transitionBlend
            mask.append(isNew)
            if !isNew { lastOriginal = img }
            orig.append(lastOriginal ?? img)
            k += 1
        }
        let repaired = stream.events.filter { $0.action != .accepted }
        let modelID = s.routes[h.scene]?.model ?? s.primaryModelID
        let modelName = InterpolationModelSpec.all().first { $0.id == modelID && $0.isInstalled }?.displayName ?? "Blend (no model installed)"
        let gen = mask.filter { $0 }.count
        let verdict = repaired.isEmpty ? "All \(gen) new frames passed the artifact checks."
            : "\(repaired.count) of \(gen) new frames needed repair in this, the hardest motion of the film."
        return InterpolationTrial(hotspot: h, original: orig, interpolated: interp, generatedMask: mask,
                                  outputFps: Double(rate.num) / Double(rate.den), model: modelName, repairs: repaired, verdict: verdict)
    }
}
