import Foundation
import AVFoundation
import CoreImage
import Metal

/// A decoded frame as a GPU texture. `backing` keeps the CoreVideo storage alive until the GPU is done.
struct DecodedFrame {
    let texture: MTLTexture
    let index: Int
    let backing: [AnyObject]
}

protocol FrameSource: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var fps: Double { get }
    var frameCount: Int { get }
    /// Positions the source. `count == nil` reads to the end.
    func start(at frame: Int, count: Int?) throws
    func nextFrame() throws -> DecodedFrame?
    func cancel()
}

// MARK: - AVFoundation (hardware decode on the M5 media engine)

final class AVFoundationFrameSource: FrameSource {
    let url: URL
    private(set) var width = 0
    private(set) var height = 0
    private(set) var fps: Double = 24
    private(set) var frameCount = 0

    private let asset: AVURLAsset
    private let convertDolbyVisionToPQ: Bool
    /// 12-bit work decodes to 32-bit float so 12-bit ProRes 4444 XQ / RAW keeps every code value.
    let highPrecision: Bool
    private var track: AVAssetTrack?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private let ctx = MetalContext.shared

    init(url: URL, convertDolbyVisionToPQ: Bool = false, highPrecision: Bool = false) {
        self.url = url
        self.asset = AVURLAsset(url: url)
        self.convertDolbyVisionToPQ = convertDolbyVisionToPQ
        self.highPrecision = highPrecision
    }

    func prepare() async throws {
        guard let t = try await asset.loadTracks(withMediaType: .video).first else { throw LumoraError.noVideoTrack }
        track = t
        let (size, rate, range) = try await t.load(.naturalSize, .nominalFrameRate, .timeRange)
        width = Int(size.width) & ~1
        height = Int(size.height) & ~1
        fps = rate > 0 ? Double(rate) : 24
        frameCount = safeFrameCount(seconds: range.duration.seconds, fps: fps)
    }

    func start(at frame: Int, count: Int?) throws {
        reader?.cancelReading()
        guard let track else { throw LumoraError.noVideoTrack }
        let r = try AVAssetReader(asset: asset)
        let startTime = CMTime(seconds: Double(frame) / fps, preferredTimescale: 600_000)
        let duration = count.map { CMTime(seconds: (Double($0) - 0.5) / fps, preferredTimescale: 600_000) } ?? .positiveInfinity
        r.timeRange = CMTimeRange(start: startTime, duration: duration)

        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                highPrecision ? kCVPixelFormatType_128RGBAFloat : kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        // No colour properties = no colour matching: we receive the camera's encoded signal untouched,
        // which is what the log decoders expect. The exception is Dolby Vision profile 5 (IPTPQc2),
        // which is only meaningful after Dolby processing, so we ask AVFoundation for PQ BT.2020.
        if convertDolbyVisionToPQ {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
            ]
        }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        o.alwaysCopiesSampleData = false
        r.add(o)
        guard r.startReading() else { throw LumoraError.decodeFailed(r.error?.localizedDescription ?? "reader") }
        reader = r
        output = o
    }

    func nextFrame() throws -> DecodedFrame? {
        guard let output, let sample = output.copyNextSampleBuffer() else {
            if let err = reader?.error { throw LumoraError.decodeFailed(err.localizedDescription) }
            return nil
        }
        guard let pb = CMSampleBufferGetImageBuffer(sample),
              let pair = ctx.texture(from: pb, format: highPrecision ? .rgba32Float : .rgba16Float) else {
            throw LumoraError.decodeFailed("pixel buffer")
        }
        let (tex, cvTex) = pair
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        return DecodedFrame(texture: tex, index: safeFrameIndex(seconds: pts.seconds, fps: fps), backing: [pb, cvTex])
    }

    func cancel() { reader?.cancelReading() }
}

// MARK: - Camera RAW stills / CinemaDNG sequences (Core Image RAW pipeline)

final class RAWSequenceFrameSource: FrameSource {
    let files: [URL]
    let fps: Double
    private(set) var width = 0
    private(set) var height = 0
    var frameCount: Int { files.count }
    private var next = 0
    private var end = 0
    private let ctx = MetalContext.shared
    private let linear2020 = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!

    init(files: [URL], fps: Double) throws {
        self.files = files
        self.fps = fps
        guard let first = files.first, let f = CIRAWFilter(imageURL: first) else {
            throw LumoraError.unsupported("Core Image can't open this RAW format.")
        }
        width = Int(f.nativeSize.width) & ~1
        height = Int(f.nativeSize.height) & ~1
    }

    func start(at frame: Int, count: Int?) throws {
        next = max(0, frame)
        end = min(files.count, count.map { frame + $0 } ?? files.count)
    }

    func nextFrame() throws -> DecodedFrame? {
        guard next < end else { return nil }
        let index = next
        next += 1
        guard let f = CIRAWFilter(imageURL: files[index]) else { throw LumoraError.decodeFailed(files[index].lastPathComponent) }
        f.boostAmount = 0                 // no baked-in tone curve: scene-linear output
        f.isGamutMappingEnabled = false   // keep the full camera gamut; we gamut-map ourselves
        guard var image = f.outputImage else { throw LumoraError.decodeFailed(files[index].lastPathComponent) }
        // Core Image is bottom-left origin; flip into Metal's top-left convention and crop to even size.
        let e = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: -e.origin.x, y: -e.origin.y))
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -e.height))
        let tex = ctx.makeTexture(width: width, height: height, format: .rgba32Float)
        let cb = ctx.queue.makeCommandBuffer()!
        ctx.ciContext.render(image, to: tex, commandBuffer: cb,
                             bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: linear2020)
        cb.commit()
        cb.waitUntilCompleted()
        return DecodedFrame(texture: tex, index: index, backing: [])
    }

    func cancel() { next = end }
}

// MARK: - FFmpeg pipe (everything AVFoundation can't open)

final class FFmpegFrameSource: FrameSource {
    let url: URL
    let width: Int
    let height: Int
    let fps: Double
    let frameCount: Int
    private var process: Process?
    private var handle: FileHandle?
    private var index = 0
    private let scanFilter: String?
    private let colorFilter: String
    private let ctx = MetalContext.shared

    init(descriptor d: SourceDescriptor) throws {
        url = d.url
        scanFilter = d.scanFix.ffmpegFilter
        // State the YCbCr matrix and range explicitly: a wrong guess (BT.601/709 on a BT.2020 HDR file)
        // silently shifts colours. The signal stays PQ/HLG/log-encoded; nothing is tone mapped.
        let wide = d.primariesTag == "ITU_R_2020" || d.transferTag?.contains("2084") == true || d.transferTag?.contains("HLG") == true
        colorFilter = "in_color_matrix=\(wide ? "bt2020" : "bt709"):in_range=tv:out_range=pc"
        width = d.width
        height = d.height
        fps = d.fps
        frameCount = d.frameCount
        guard ToolLocator.isAvailable("ffmpeg") else { throw LumoraError.missingTool("ffmpeg") }
    }

    func start(at frame: Int, count: Int?) throws {
        cancel()
        let p = Process()
        p.executableURL = ToolLocator.url(for: "ffmpeg")
        var args = ["-v", "error", "-nostdin"]
        if frame > 0 { args += ["-ss", String(format: "%.6f", Double(frame) / fps)] }
        args += ["-i", url.path]
        if let count { args += ["-frames:v", "\(count)"] }
        // 16-bit RGB without colour management: the encoded signal, like the AVFoundation path.
        let scale = "scale=\(width):\(height):flags=lanczos+accurate_rnd+full_chroma_int:\(colorFilter)"
        args += ["-vf", scanFilter.map { "\($0),\(scale)" } ?? scale, "-f", "rawvideo", "-pix_fmt", "rgba64le", "-"]
        p.arguments = FFHarden.args("ffmpeg", args)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        handle = pipe.fileHandleForReading
        index = frame
    }

    func nextFrame() throws -> DecodedFrame? {
        guard let handle else { return nil }
        let frameBytes = width * height * 8
        var data = Data(capacity: frameBytes)
        while data.count < frameBytes {
            guard let chunk = try handle.read(upToCount: frameBytes - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count == frameBytes else { return nil }
        let tex = ctx.makeTexture(width: width, height: height, format: .rgba16Unorm,
                                  usage: [.shaderRead], storage: .shared)
        data.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: raw.baseAddress!, bytesPerRow: width * 8)
        }
        defer { index += 1 }
        return DecodedFrame(texture: tex, index: index, backing: [])
    }

    func cancel() {
        process?.terminate()
        process = nil
        handle = nil
    }
}

// MARK: - Vendor RAW plug-ins (BRAW, R3D, ARRIRAW, Canon RAW)

/// Camera vendors license their RAW SDKs separately, so they load as plug-in bundles from
/// ~/Library/Application Support/Lumora/PlugIns. Each plug-in decodes to scene-linear BT.2020
/// (or reports its own log/gamut) and hands frames over as Metal textures.
protocol VendorRAWPlugin {
    var fileExtensions: [String] { get }
    var outputColor: SourceColor { get }
    func makeFrameSource(url: URL) throws -> FrameSource
}

enum VendorRAWRegistry {
    static let vendorExtensions = ["braw", "r3d", "ari", "arx", "crm", "mxf_raw"]
    static var plugins: [VendorRAWPlugin] = []   // populated by PlugInLoader at launch

    static func plugin(for url: URL) -> VendorRAWPlugin? {
        plugins.first { $0.fileExtensions.contains(url.pathExtension.lowercased()) }
    }
}
