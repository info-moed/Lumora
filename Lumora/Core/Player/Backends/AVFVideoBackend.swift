import Foundation
import AVFoundation
import CoreVideo
import VideoToolbox

/// MP4 / MOV decoded in-process by VideoToolbox. Frames arrive as IOSurface-backed CVPixelBuffers in the
/// stream's own Y'CbCr layout (no color conversion requested), and the player kernel reads them as textures.
final class AVFVideoBackend: PlayerVideoBackend, @unchecked Sendable {
    let info: MediaInfo
    private(set) var choice: DecoderChoice
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let trackStart: Double
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var target = 0
    private let pixelFormat: OSType
    private let layout: FrameLayout
    /// Dolby Vision 5 / AV1 profile 10.0: macOS converts IPTPQc2 to PQ BT.2020 for us (RGB out).
    let convertsDolbyVision: Bool
    var randomAccessPoints: [Int]? { nil }
    var note: String? { convertsDolbyVision ? "Dolby Vision \(info.video.dolbyVision?.profile ?? 5) converted to PQ by macOS." : nil }

    init(info: MediaInfo, choice: DecoderChoice) throws {
        self.info = info
        self.choice = choice
        asset = AVURLAsset(url: info.url)
        let loaded = MediaProbe.blocking(timeout: 10) { [asset] () async throws -> (AVAssetTrack, CMTimeRange)? in
            guard let t = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            return (t, try await t.load(.timeRange))
        }
        guard let (t, range) = loaded ?? nil else { throw PlayerError.noVideoTrack }
        track = t
        trackStart = range.start.isNumeric ? range.start.seconds : 0
        let v = info.video
        let dv = v.dolbyVision.map { $0.blCompatibilityID == 0 && ($0.profile == 5 || $0.profile == 10) } ?? false
        convertsDolbyVision = dv
        let full = v.color.fullRange
        let (fmt, l): (OSType, FrameLayout) = {
            if dv {
                return (kCVPixelFormatType_64RGBAHalf,
                        FrameLayout(storage: .rgbaTexture, width: v.width, height: v.height, chroma: .c444, sampleBytes: 2, bits: 16, msbAligned: false))
            }
            func bi(_ f: OSType, _ c: PlayerChroma, _ bytes: Int, _ bits: Int, _ msb: Bool) -> (OSType, FrameLayout) {
                (f, FrameLayout(storage: .biplanarTexture, width: v.width, height: v.height, chroma: c, sampleBytes: bytes, bits: bits, msbAligned: msb))
            }
            switch (v.bitDepth > 10 ? 16 : v.bitDepth > 8 ? 10 : 8, v.chroma) {
            case (8, .c422): return bi(full ? kCVPixelFormatType_422YpCbCr8BiPlanarFullRange : kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, .c422, 1, 8, false)
            case (8, .c444): return bi(full ? kCVPixelFormatType_444YpCbCr8BiPlanarFullRange : kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, .c444, 1, 8, false)
            case (8, _): return bi(full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, .c420, 1, 8, false)
            case (10, .c422): return bi(full ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, .c422, 2, 10, true)
            case (10, .c444): return bi(full ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, .c444, 2, 10, true)
            case (10, _): return bi(full ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, .c420, 2, 10, true)
            case (_, .c444): return bi(kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange, .c444, 2, 16, false)   // ProRes 4444 / XQ (12-bit)
            default: return bi(kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange, .c422, 2, 16, false)
            }
        }()
        pixelFormat = fmt
        layout = l
        if let hw = Self.usesHardware(asset: asset, track: t) {
            self.choice.hardware = hw
            if !hw { self.choice.tool = "AVFoundation (VideoToolbox, software)" }
        }
    }

    deinit { stop() }

    /// Asks VideoToolbox whether it decodes this track's format in hardware (one throwaway session).
    static func usesHardware(asset: AVURLAsset, track: AVAssetTrack) -> Bool? {
        let fd = MediaProbe.blocking(timeout: 5) { () async throws -> CMFormatDescription? in try await track.load(.formatDescriptions).first }
        guard let fd = fd ?? nil else { return nil }
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil,
                                           imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr,
              let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }
        var value: CFTypeRef?
        let status = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                                           allocator: nil, valueOut: &value)
        guard status == noErr else { return false }
        return (value as? Bool) ?? false
    }

    func start(atFrame i: Int) throws {
        lock.lock()
        reader?.cancelReading()
        reader = nil
        output = nil
        lock.unlock()
        let fps = info.fps
        target = max(0, i)
        let r = try AVAssetReader(asset: asset)
        let start = trackStart + max(0, (Double(target) - 0.5) / fps)
        r.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600_000), duration: .positiveInfinity)
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        if convertsDolbyVision {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        o.alwaysCopiesSampleData = false
        r.add(o)
        guard r.startReading() else {
            throw PlayerError.decoderFailed("AVFoundation", r.error?.localizedDescription ?? "the reader didn't start")
        }
        lock.lock()
        reader = r
        output = o
        lock.unlock()
    }

    func next() throws -> PlayerFrame? {
        while true {
            lock.lock(); let o = output, r = reader; lock.unlock()
            guard let o, let r else { return nil }
            guard let sample = o.copyNextSampleBuffer() else {
                if r.status == .failed, let e = r.error { throw PlayerError.decoderFailed("AVFoundation", e.localizedDescription) }
                return nil
            }
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }   // an empty sample (edit gap)
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds - trackStart
            let index = Int((pts * info.fps).rounded())
            if index < target { continue }
            return PlayerFrame(index: index, pts: Double(index) / info.fps, layout: layout, planes: .pixelBuffer(pb), color: info.video.color)
        }
    }

    func interrupt() {
        lock.lock(); let r = reader; lock.unlock()
        r?.cancelReading()
    }

    func stop() {
        lock.lock()
        reader?.cancelReading()
        reader = nil
        output = nil
        lock.unlock()
    }
}
