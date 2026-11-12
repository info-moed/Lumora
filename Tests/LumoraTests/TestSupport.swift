import XCTest
import Metal
import VideoToolbox
@testable import Lumora

/// What this machine can actually run. Virtual machines (e.g. GitHub-hosted macOS runners) may have no usable
/// GPU and no hardware video encoder; tests that need them skip with a clear reason instead of crashing, and
/// the full set runs on real Apple silicon (locally and in the scheduled dependency check).
enum TestHardware {
    static let gpu: Bool = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let lib = try? device.makeDefaultLibrary(bundle: Bundle.main) else { return false }
        return lib.makeFunction(name: "gradeKernel") != nil
    }()

    static func hardwareEncoder(_ codec: CMVideoCodecType) -> Bool {
        var list: CFArray?
        guard VTCopyVideoEncoderList(nil, &list) == noErr, let encoders = list as? [[String: Any]] else { return false }
        return encoders.contains { e in
            (e[kVTVideoEncoderList_CodecType as String] as? NSNumber)?.uint32Value == codec
                && (e[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool ?? false)
        }
    }

    static func requireGPU() throws {
        if !gpu { throw XCTSkip("No usable Metal GPU on this machine (virtual machine?)") }
    }

    static func requireHardwareHEVC() throws {
        try requireGPU()
        if !hardwareEncoder(kCMVideoCodecType_HEVC) { throw XCTSkip("No hardware HEVC encoder on this machine") }
    }

    /// ProRes has a software encoder on every Mac, so only the GPU is truly required.
    static func requireProRes() throws { try requireGPU() }
}

extension AnalysisResult {
    /// One scene, no cuts: enough for planner and validation tests.
    static let empty = AnalysisResult(frameCount: 100,
                                      scenes: [SceneStats(start: 0, end: 100, keyStops: 0, p005: -6, p50: 0, p995: 3, skinFraction: 0, avgChroma: 0)],
                                      transitions: [], cutFrames: [0], duplicateFrames: [], globalKey: 0, globalP005: -6, globalP995: 3,
                                      skinFraction: 0, avgChroma: 0, globalHistogram: [])
}

extension SourceColor {
    static let testSDR = SourceColor(name: "SDR Rec.709", transfer: .bt1886, gamut: .rec709, legalToFull: true, confidence: 1)
}
