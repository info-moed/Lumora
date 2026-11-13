import Foundation

/// Every way opening or playing a file can fail, each with a message that says what to do about it.
enum PlayerError: LocalizedError, Equatable {
    case missingTool(String, String)            // tool, how to install it
    case unsupportedCodec(String)
    case noVideoTrack
    case damaged(String)
    case tooLarge(Int, Int)
    case decoderFailed(String, String)          // tool, the end of its error output
    case cacheFull(Int64)
    case dvProfile5InMKV
    case notAFile

    static let ffmpegHint = "brew install ffmpeg"
    static let avmHint = "bash scripts/install-encoders.sh (builds avmdec)"
    static let generalHint = "scripts/deps.sh install"

    var errorDescription: String? {
        switch self {
        case .missingTool(let tool, let how):
            return "This file needs “\(tool)”, which isn't installed. Install it with: \(how)."
        case .unsupportedCodec(let c):
            return "Lumora can't decode this video (codec “\(c)”). Neither macOS nor the installed FFmpeg supports it."
        case .noVideoTrack:
            return "This file has no video track."
        case .damaged(let detail):
            return "This file is damaged or isn't a video Lumora can read: \(detail)"
        case .tooLarge(let w, let h):
            return "The video reports an impossible size (\(w)×\(h)). Lumora plays 16 to 16384 pixels per side."
        case .decoderFailed(let tool, let tail):
            let t = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(tool) stopped with an error" + (t.isEmpty ? "." : ": \(t.suffix(400))")
        case .cacheFull(let free):
            return "Not enough free space to pre-decode this video (\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free). "
                + "Free some space or choose another scratch drive in Settings → Storage."
        case .dvProfile5InMKV:
            return "Dolby Vision profile 5 in Matroska: macOS can only convert profile 5 from MP4 or MOV, so the colors would be wrong. "
                + "Use “Remux to MP4 for correct colors”."
        case .notAFile:
            return "That isn't a file Lumora can play (a folder, or a file that no longer exists)."
        }
    }
}
