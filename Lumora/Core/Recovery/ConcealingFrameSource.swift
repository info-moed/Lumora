import Foundation
import AVFoundation

/// An AVFoundation decode error that keeps the original NSError (domain, code, underlying chain) and where it happened.
/// Its message reads like the older `LumoraError.decodeFailed`.
struct SourceReadError: LocalizedError, CustomNSError {
    var underlying: NSError
    var seconds: Double?
    var errorDescription: String? { "Couldn't decode the video: \(underlying.localizedDescription)" }
    var errorUserInfo: [String: Any] { [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: errorDescription ?? ""] }
    static var errorDomain: String { "Lumora.SourceReadError" }
}

/// Wraps the source a render or the analysis reads from. AVFoundation stops at the first damaged frame (measured: 42
/// of 96 frames on a byte-damaged MP4, where FFmpeg conceals the damage and keeps 94), so when it fails mid-file the
/// rest is read through FFmpeg from that frame on, and the damage is recorded with its time. A source that ends
/// before the frames a render asked for raises a clear error instead of a silently short export.
final class ConcealingFrameSource: FrameSource {
    private var base: FrameSource
    private let descriptor: SourceDescriptor?
    private(set) var damage = DamageMap()
    private var next = 0
    private var end: Int?
    private var switched = false
    let label: String

    var width: Int { base.width }
    var height: Int { base.height }
    var fps: Double { base.fps }
    var frameCount: Int { base.frameCount }

    init(base: FrameSource, descriptor: SourceDescriptor?) {
        self.base = base
        self.descriptor = descriptor
        self.label = descriptor?.url.lastPathComponent ?? "source"
        damage.fps = base.fps
    }

    /// Wraps decoders that can fail mid-file (AVFoundation, FFmpeg); RAW stills and plug-ins pass through.
    static func wrap(_ s: FrameSource, descriptor: SourceDescriptor) -> FrameSource {
        (s is AVFoundationFrameSource || s is FFmpegFrameSource) ? ConcealingFrameSource(base: s, descriptor: descriptor) : s
    }

    func start(at frame: Int, count: Int?) throws {
        next = frame
        end = count.map { frame + $0 }
        try base.start(at: frame, count: count)
    }

    func nextFrame() throws -> DecodedFrame? {
        if let end, next >= end { return nil }
        do {
            if let f = try base.nextFrame() {
                defer { next += 1 }
                return DecodedFrame(texture: f.texture, index: next, backing: f.backing)
            }
            // Ended. Fine when reading to the end; a render that asked for more frames than exist gets a clear error.
            guard let end else { return nil }
            if try fallBack(reason: "AVFoundation stopped reading") { return try nextFrame() }
            throw SourceDamage(kind: .endedEarly, file: label, frame: next, seconds: Double(next) / max(1, fps),
                               detail: "the video data ends at frame \(next) of the \(end) frames this export reads")
        } catch let e as SourceDamage {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let at = Double(next) / max(1, fps)
            RenderLog.current?.warn("Can't decode \(label) at \(FailureText.time(at, precise: true)) (frame \(next)): \(error.localizedDescription)", tag: "decode")
            if try fallBack(reason: error.localizedDescription) {
                damage.add(.init(start: next, count: 1, kind: .concealed, note: error.localizedDescription))
                return try nextFrame()
            }
            throw error
        }
    }

    /// Continues from frame `next` with FFmpeg, which conceals damaged pictures instead of stopping. Once only.
    private func fallBack(reason: String) throws -> Bool {
        guard !switched, base is AVFoundationFrameSource, let d = descriptor, ToolLocator.isAvailable("ffmpeg") else { return false }
        switched = true
        var dd = d
        dd.kind = .ffmpeg
        let ff = try FFmpegFrameSource(descriptor: dd)
        try ff.start(at: next, count: end.map { $0 - next })
        base.cancel()
        base = ff
        RenderLog.current?.warn("Reading on from \(FailureText.time(Double(next) / max(1, fps), precise: true)) with FFmpeg, which repairs damaged pictures as well as it can (\(reason))", tag: "decode")
        Log.warning(.ingest, "\(label): AVFoundation stopped at frame \(next); reading on with FFmpeg")
        return true
    }

    func cancel() { base.cancel() }
}

/// FFmpeg's decoder messages (damaged pictures it concealed), kept in a small ring and copied into the export log.
final class DecoderMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var pipe: Pipe?

    var recent: [String] { lock.lock(); defer { lock.unlock() }; return lines }

    func attach(log: RenderLog?, label: String) -> Pipe {
        pipe?.fileHandleForReading.readabilityHandler = nil
        let p = Pipe()
        pipe = p
        p.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let new = RenderLog.splitLines(String(decoding: data, as: UTF8.self))
            guard let self else { return }
            self.lock.lock()
            self.lines += new
            if self.lines.count > 200 { self.lines.removeFirst(self.lines.count - 200) }
            self.lock.unlock()
            for l in new.prefix(20) { log?.line(.stderr, "decode", "\(label): \(l)") }
        }
        return p
    }
}
