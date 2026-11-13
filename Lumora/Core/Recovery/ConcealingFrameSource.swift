import Foundation
import AVFoundation

/// An AVFoundation decode error that keeps the original NSError (domain, code, underlying chain) and where it happened.
/// Its message reads like the older `LumoraError.decodeFailed`.
struct SourceReadError: LocalizedError, CustomNSError {
    let underlying: NSError
    var seconds: Double?
    private let message: String          // computed once (see GPUFault)
    init(underlying: NSError, seconds: Double? = nil) {
        self.underlying = underlying
        self.seconds = seconds
        message = "Couldn't decode the video: \(underlying.localizedDescription)"
    }
    var errorDescription: String? { message }
    var errorUserInfo: [String: Any] { [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: message] }
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
            // AVFoundation can also report "completed" with frames missing and no error (a damaged chunk table):
            // reading on with FFmpeg recovers what is there.
            guard let end else {
                if frameCount > 0, next < frameCount - max(2, Int(fps / 2)), try fallBack(reason: "AVFoundation stopped reading at frame \(next) of \(frameCount)") {
                    let resumeAt = next
                    if let f = try nextFrame() { return f }
                    damage.truncatedAtSeconds = Double(resumeAt) / max(1, fps)
                    damage.claimedSeconds = Double(frameCount) / max(1, fps)
                }
                return nil
            }
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
        if d.fpsNum > 0, d.fpsDen > 0 { ff.fillTimeline = (d.fpsNum, d.fpsDen) }
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
        detach()
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

    /// Stops reading the previous decoder's messages and closes that pipe right away.
    func detach() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        try? pipe?.fileHandleForReading.close()
        try? pipe?.fileHandleForWriting.close()
        pipe = nil
    }

    deinit { detach() }
}

/// Shows the previous good frame in place of frames that can't be decoded ("Repeat the previous good frame", and
/// runs too long to re-create). FFmpeg's constant-rate fill on its own repeats whichever neighbor is nearest in time,
/// which can be the frame after the damage.
final class HeldFrameSource: FrameSource {
    private let base: FrameSource
    private let held: Set<Int>
    private var lastGood: DecodedFrame?
    private var skipFirst = false
    private(set) var replaced = 0

    var width: Int { base.width }
    var height: Int { base.height }
    var fps: Double { base.fps }
    var frameCount: Int { base.frameCount }

    init(base: FrameSource, held: Set<Int>) {
        self.base = base
        self.held = held
    }

    func start(at frame: Int, count: Int?) throws {
        // Start on the good frame before a held run, so even the first frame of a segment has something to repeat.
        var from = frame
        while from > 0 && held.contains(from) { from -= 1 }
        skipFirst = from < frame
        lastGood = nil
        try base.start(at: from, count: count.map { $0 + (frame - from) })
        if skipFirst {
            for _ in from..<frame {
                guard let f = try base.nextFrame() else { break }
                if !held.contains(f.index) { lastGood = f }
            }
        }
    }

    func nextFrame() throws -> DecodedFrame? {
        guard let f = try base.nextFrame() else { return nil }
        if held.contains(f.index), let g = lastGood {
            replaced += 1
            return DecodedFrame(texture: g.texture, index: f.index, backing: g.backing)
        }
        lastGood = f
        return f
    }

    func cancel() { base.cancel() }
}
