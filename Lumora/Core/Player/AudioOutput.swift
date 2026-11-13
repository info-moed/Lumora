import Foundation
import AVFoundation
import QuartzCore

/// Interleaved stereo Float32 at 48 kHz, starting exactly at the requested time.
protocol PlayerAudioSource: AnyObject {
    /// Reads up to `frames` sample frames into `into` (2 × frames floats). Returns frames read; 0 at the end.
    func read(into: UnsafeMutablePointer<Float>, frames: Int) -> Int
    func stop()
}

enum PlayerAudio {
    static let sampleRate = 48_000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    /// The audio source for a track: AVFoundation for MP4 / MOV, FFmpeg for everything else.
    static func makeSource(info: MediaInfo, track: Int, at seconds: Double) throws -> PlayerAudioSource {
        if info.isAVFContainer, info.avfDecodable || !ToolLocator.isAvailable("ffmpeg"),
           let s = try? AVFAudioSource(url: info.url, track: track, at: seconds) {
            return s
        }
        return try FFmpegAudioSource(url: info.url, track: track, at: seconds)
    }
}

/// `ffmpeg -ss T -i FILE -map 0:a:N -f f32le -ac 2 -ar 48000 -`: any audio codec FFmpeg reads, resampled.
final class FFmpegAudioSource: PlayerAudioSource {
    private let child: ChildProcess
    private var dropBytes = 0

    init(url: URL, track: Int, at seconds: Double) throws {
        var args = ["-v", "error", "-nostdin"]
        if seconds > 0 { args += ["-ss", String(format: "%.6f", seconds)] }
        args += ["-i", url.path, "-map", "0:a:\(track)", "-vn", "-sn", "-dn", "-f", "f32le", "-ac", "2", "-ar", "48000", "-"]
        child = try ChildProcess(tool: "ffmpeg", args: args, qos: .userInitiated)
    }

    func read(into: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let got = child.read(into: UnsafeMutableRawPointer(into), count: frames * 8)
        return got / 8
    }

    func stop() { child.terminate() }
    deinit { child.terminate() }
}

/// MP4 / MOV audio through AVAssetReader, mixed to stereo and resampled to 48 kHz by AVFoundation.
final class AVFAudioSource: PlayerAudioSource {
    private let reader: AVAssetReader
    private let output: AVAssetReaderAudioMixOutput
    private var pending: [Float] = []
    private var pendingAt = 0
    private var trim: Int
    /// Reads and cancellation never overlap (cancelReading during copyNextSampleBuffer crashes in CoreMedia).
    private let lock = NSLock()
    private var stopped = false

    init(url: URL, track: Int, at seconds: Double) throws {
        let asset = AVURLAsset(url: url)
        let tracks = MediaProbe.blocking(timeout: 10) { try await asset.loadTracks(withMediaType: .audio) } ?? []
        guard track < tracks.count else { throw PlayerError.noVideoTrack }
        reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, seconds), preferredTimescale: 48_000), duration: .positiveInfinity)
        output = AVAssetReaderAudioMixOutput(audioTracks: [tracks[track]], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: PlayerAudio.sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw PlayerError.decoderFailed("AVFoundation", reader.error?.localizedDescription ?? "audio") }
        trim = 0
        start = seconds
    }
    private let start: Double
    private var first = true

    func read(into: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var done = 0
        while done < frames && !stopped {
            if pendingAt >= pending.count {
                guard reader.status == .reading, let sb = output.copyNextSampleBuffer(),
                      let block = CMSampleBufferGetDataBuffer(sb) else { break }
                if first {
                    // The reader starts at the packet holding T; drop the samples before T so audio lands exactly.
                    first = false
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                    if pts.isFinite, pts < start { trim = Int(((start - pts) * PlayerAudio.sampleRate).rounded()) }
                }
                let bytes = CMBlockBufferGetDataLength(block)
                pending = [Float](repeating: 0, count: bytes / 4)
                pending.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
                pendingAt = min(pending.count, trim * 2)
                trim = max(0, trim - pending.count / 2)
                continue
            }
            let n = min(frames - done, (pending.count - pendingAt) / 2)
            pending.withUnsafeBufferPointer { src in
                (into + done * 2).update(from: src.baseAddress! + pendingAt, count: n * 2)
            }
            pendingAt += n * 2
            done += n
        }
        return done
    }

    func stop() {
        lock.lock()
        if !stopped { stopped = true; reader.cancelReading() }
        lock.unlock()
    }
    deinit { stop() }
}

/// Plays one audio source through AVAudioEngine and is the playback clock while it plays.
/// In manual rendering mode (tests) nothing reaches the output device; tests pull samples with `renderOffline`.
final class AudioOutput: @unchecked Sendable {
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let manual: Bool
    private let lock = NSLock()
    private var source: PlayerAudioSource?
    private var feeder: Thread?
    private var generation = 0
    private var slots = DispatchSemaphore(value: 4)       // 4 × 0.25 s scheduled ahead
    private var startMedia = 0.0
    private(set) var isRunning = false
    private(set) var sourceEnded = false
    static let chunkFrames = 12_000                         // 0.25 s

    init(manualRendering: Bool) throws {
        manual = manualRendering
        engine.attach(node)
        if manualRendering {
            try engine.enableManualRenderingMode(.offline, format: PlayerAudio.format, maximumFrameCount: 4096)
        }
        engine.connect(node, to: engine.mainMixerNode, format: PlayerAudio.format)
        engine.prepare()
    }

    deinit { stop(); engine.stop() }

    var volume: Float {
        get { node.volume }
        set { node.volume = max(0, min(1, newValue)) }
    }

    /// Starts playing `source` (positioned at media time `at`) now.
    func start(source: PlayerAudioSource, at media: Double) throws {
        stop()
        if !engine.isRunning { try engine.start() }
        lock.lock()
        generation += 1
        let gen = generation
        self.source = source
        startMedia = media
        sourceEnded = false
        slots = DispatchSemaphore(value: 4)
        let sem = slots
        lock.unlock()
        // Schedule the first second before playing so the clock starts with audio actually flowing.
        for _ in 0..<4 { sem.wait(); if !scheduleChunk(gen: gen, sem: sem) { break } }
        node.play()
        isRunning = true
        let t = Thread { [weak self] in
            while true {
                sem.wait()
                guard let self else { return }
                self.lock.lock(); let current = self.generation == gen; self.lock.unlock()
                guard current else { return }
                if !self.scheduleChunk(gen: gen, sem: sem) { return }
            }
        }
        t.name = "Lumora audio feeder"
        t.qualityOfService = .userInteractive
        feeder = t
        t.start()
    }

    /// Reads 0.25 s and schedules it; false at the end of the source.
    private func scheduleChunk(gen: Int, sem: DispatchSemaphore) -> Bool {
        lock.lock(); let src = source; lock.unlock()
        guard let src, let buf = AVAudioPCMBuffer(pcmFormat: PlayerAudio.format, frameCapacity: AVAudioFrameCount(Self.chunkFrames)) else { return false }
        var inter = [Float](repeating: 0, count: Self.chunkFrames * 2)
        let n = inter.withUnsafeMutableBufferPointer { src.read(into: $0.baseAddress!, frames: Self.chunkFrames) }
        guard n > 0 else { lock.lock(); sourceEnded = true; lock.unlock(); return false }
        buf.frameLength = AVAudioFrameCount(n)
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
        for k in 0..<n { l[k] = inter[2 * k]; r[k] = inter[2 * k + 1] }
        node.scheduleBuffer(buf, completionCallbackType: .dataConsumed) { _ in sem.signal() }
        return true
    }

    func stop() {
        lock.lock()
        generation += 1
        let src = source
        source = nil
        let sem = slots
        lock.unlock()
        sem.signal()
        node.stop()                 // also releases the scheduled buffers (their callbacks signal the feeder)
        src?.stop()
        isRunning = false
    }

    /// Media time being heard at host time `host` (seconds, CACurrentMediaTime base), from the last render.
    func mediaTime(atHost host: CFTimeInterval) -> Double? {
        guard isRunning, let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let pt = node.playerTime(forNodeTime: nodeTime) else { return nil }
        lock.lock(); let base = startMedia; lock.unlock()
        let heard = base + Double(pt.sampleTime) / pt.sampleRate
        if manual || !nodeTime.isHostTimeValid { return heard }
        let renderHost = AVAudioTime.seconds(forHostTime: nodeTime.hostTime)
        let latency = engine.outputNode.presentationLatency
        return heard + (host - renderHost) - latency
    }

    /// Tests: pull `frames` samples through the engine (manual rendering only).
    func renderOffline(frames: Int) throws -> AVAudioPCMBuffer {
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(frames))!
        var remaining = frames
        let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
        while remaining > 0 {
            let n = AVAudioFrameCount(min(4096, remaining))
            let status = try engine.renderOffline(n, to: chunk)
            guard status == .success || status == .insufficientDataFromInputNode else { break }
            let have = Int(out.frameLength), got = Int(chunk.frameLength)
            for c in 0..<Int(out.format.channelCount) {
                (out.floatChannelData![c] + have).update(from: chunk.floatChannelData![c], count: got)
            }
            out.frameLength = AVAudioFrameCount(have + got)
            remaining -= got
            if got == 0 { break }
        }
        return out
    }
}

/// The video clock when there is no audio (raw .obu / .266, silent files) or the rate isn't 1x: host time.
struct HostClock: Equatable {
    var anchorMedia = 0.0
    var anchorHost: CFTimeInterval = 0
    var rate = 0.0

    func time(atHost h: CFTimeInterval) -> Double { anchorMedia + (h - anchorHost) * rate }

    mutating func set(media: Double, host: CFTimeInterval, rate: Double) {
        anchorMedia = media; anchorHost = host; self.rate = rate
    }
}

/// Smooths the display's EDR headroom, which macOS ramps in when HDR content starts and moves with the
/// brightness slider, so the tone mapping follows it without flicker (first-order low-pass, τ = 0.3 s).
struct HeadroomFilter: Equatable {
    var value: Double
    var tau = 0.3

    init(initial: Double) { value = max(1, initial) }

    mutating func update(_ raw: Double, dt: Double) -> Double {
        let r = max(1, raw)
        guard dt > 0 else { return value }
        let a = 1 - exp(-dt / tau)
        value += (r - value) * a
        return value
    }
}
