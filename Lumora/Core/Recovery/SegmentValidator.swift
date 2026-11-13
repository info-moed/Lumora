import Foundation
import CryptoKit

/// Checks a finished segment before it is trusted: the number of coded pictures equals the frames it should hold,
/// its keyframes decode, and its SHA-256 (recorded in the journal, so a file damaged on disk later is caught).
enum SegmentValidator {
    struct Result { var packets: Int; var bytes: Int64; var sha256: String }

    enum Problem: LocalizedError {
        case missing(String), empty(String), wrongCount(String, Int, Int), undecodable(String, String), changed(String)
        var errorDescription: String? {
            switch self {
            case .missing(let f): return "The saved part \(f) is missing."
            case .empty(let f): return "The saved part \(f) is empty."
            case .wrongCount(let f, let got, let want): return "The saved part \(f) holds \(got) frames instead of \(want)."
            case .undecodable(let f, let why): return "The saved part \(f) can't be decoded: \(why)"
            case .changed(let f): return "The saved part \(f) changed on disk since it was finished."
            }
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Coded pictures in a video file or raw stream (ffprobe -count_packets; AV2 OBU streams are counted by Lumora).
    static func packets(_ url: URL, rate: (num: Int, den: Int)) throws -> Int {
        if url.pathExtension == "obu" { return try AV2Stream.summary(of: url).temporalUnits }
        var args = ["-v", "error", "-select_streams", "v:0", "-count_packets", "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0"]
        if ["hevc", "266"].contains(url.pathExtension) { args = ["-f", url.pathExtension == "hevc" ? "hevc" : "vvc"] + args }
        let out = try ToolLocator.run("ffprobe", args + [url.path])
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: ",")) ?? "") ?? -1
    }

    /// Decodes the keyframes only (fast): a torn or corrupted file fails here.
    static func keyframesDecode(_ url: URL) -> String? {
        guard url.pathExtension != "obu", ToolLocator.isAvailable("ffmpeg") else { return nil }
        var args = ["-v", "error", "-nostdin", "-skip_frame", "nokey"]
        if ["hevc", "266"].contains(url.pathExtension) { args += ["-f", url.pathExtension == "hevc" ? "hevc" : "vvc"] }
        args += ["-i", url.path, "-map", "0:v:0", "-f", "null", "-"]
        guard let err = try? ToolLocator.runCapturingStderr("ffmpeg", args) else { return "FFmpeg couldn't read it" }
        let lines = RenderLog.splitLines(err).filter { !$0.contains("deprecated") }
        return lines.isEmpty ? nil : lines.suffix(3).joined(separator: " ")
    }

    /// Full check of a just-finished segment.
    static func validate(_ url: URL, frames: Int, rate: (num: Int, den: Int)) throws -> Result {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else { throw Problem.missing(name) }
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard bytes > 16 else { throw Problem.empty(name) }
        var count = frames
        if ToolLocator.isAvailable("ffprobe") || url.pathExtension == "obu" {
            count = (try? packets(url, rate: rate)) ?? -1
            guard count == frames else { throw Problem.wrongCount(name, max(0, count), frames) }
        }
        if let why = keyframesDecode(url) { throw Problem.undecodable(name, why) }
        return Result(packets: count, bytes: bytes, sha256: try sha256(url))
    }

    /// Re-check of a journaled segment at resume: size and SHA-256 first (cheap, catches torn files), then packets.
    static func revalidate(_ seg: ExportJournal.DoneSegment, in dir: URL, rate: (num: Int, den: Int)) -> Problem? {
        let url = dir.appendingPathComponent(seg.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing(seg.file) }
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard bytes == seg.bytes, (try? sha256(url)) == seg.sha256 else { return .changed(seg.file) }
        if ToolLocator.isAvailable("ffprobe"), let n = try? packets(url, rate: rate), n != seg.frames {
            return .wrongCount(seg.file, n, seg.frames)
        }
        if let why = keyframesDecode(url) { return .undecodable(seg.file, why) }
        return nil
    }
}
