import Foundation
import Metal
import AVFoundation

/// Where in an export something happened. The stage decides between source, encoder and packaging explanations.
enum RenderStage: String, Codable, CaseIterable {
    case prepare, grain, levels, decode, encode, validate, join, hdr10Container, metadata, deliver, finished

    var displayName: String {
        switch self {
        case .prepare: return "preparing"
        case .grain: return "measuring film grain"
        case .levels: return "measuring HDR light levels"
        case .decode: return "reading the source"
        case .encode: return "encoding"
        case .validate: return "checking finished parts"
        case .join: return "joining the parts"
        case .hdr10Container: return "adding HDR10 metadata to the container"
        case .metadata: return "adding Dolby Vision or HDR10+ metadata"
        case .deliver: return "saving to your output folder"
        case .finished: return "finished"
        }
    }
}

// MARK: - Typed errors thrown by the recovery code

/// A source file that can't be read correctly at some point.
struct SourceDamage: LocalizedError, Codable, Hashable {
    enum Kind: String, Codable { case damaged, truncated, indexMissing, unsupported, endedEarly }
    var kind: Kind
    var file: String
    var frame: Int?
    var seconds: Double?
    var detail: String

    var errorDescription: String? {
        switch kind {
        case .indexMissing: return "“\(file)” is incomplete: its index is missing, so no frames can be read."
        case .truncated: return "“\(file)” is cut short" + (seconds.map { ": the video stops at \(FailureText.time($0))." } ?? ".")
        case .endedEarly: return "“\(file)” ended early" + (frame.map { " at frame \($0)" } ?? "") + ": \(detail)"
        case .unsupported: return "“\(file)” can't be decoded on this Mac: \(detail)"
        case .damaged: return "“\(file)” is damaged" + (seconds.map { " near \(FailureText.time($0))" } ?? "") + ": \(detail)"
        }
    }
}

/// The source changed or vanished while the export was using it.
struct SourceChange: LocalizedError, Codable, Hashable {
    var moved: Bool
    var file: String
    var errorDescription: String? {
        moved ? "The source file “\(file)” was moved or deleted during the export, so its audio and subtitles can't be added. Put it back and export again."
              : "The source file “\(file)” changed during the export. Start over with the new file, or put the original back and resume."
    }
}

/// The joined video doesn't have the planned number of frames: never delivered.
struct FrameCountMismatch: LocalizedError, Codable, Hashable {
    var got: Int
    var expected: Int
    var errorDescription: String? { "The rendered video has \(got) frames but should have \(expected), so Lumora didn't save it." }
}

/// An error the GPU reported for a command buffer.
struct GPUFault: LocalizedError, CustomNSError {
    var underlying: NSError
    var errorDescription: String? { "The graphics processor reported an error: \(underlying.localizedDescription)" }
    static var errorDomain: String { "Lumora.GPUFault" }
    var errorUserInfo: [String: Any] { [NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: errorDescription ?? ""] }
}

/// Saving the finished video failed; the finished file is kept in the checkpoint folder.
struct DeliveryFailure: LocalizedError, CustomNSError {
    var underlying: Error
    var kept: URL
    var errorDescription: String? { underlying.localizedDescription }
    static var errorDomain: String { "Lumora.DeliveryFailure" }
    var errorUserInfo: [String: Any] { [NSUnderlyingErrorKey: underlying as NSError, NSLocalizedDescriptionKey: errorDescription ?? ""] }
}

// MARK: - Classification

/// What went wrong, by kind. Each kind has its own plain-language explanation (FailureExplainer).
struct RenderFailure: Codable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case diskFull, outputDriveGone, scratchDriveGone, noPermission, privacyBlocked
        case toolMissing, toolCrashed, encoderRejectedSetting, encoderFailed
        case outOfMemory, gpuError, hardwareEncoderReset
        case interruptedQuit, interruptedCrash, interruptedRestart, interruptedShutdownAsleep, interruptedUnknown
        case canceled
        case sourceIndexMissing, sourceUnsupported, sourceTruncated, sourceDamaged, sourceChanged, sourceMoved
        case metadataToolFailed, frameCountMismatch, unknown

        var isSource: Bool { [.sourceIndexMissing, .sourceUnsupported, .sourceTruncated, .sourceDamaged, .sourceChanged, .sourceMoved].contains(self) }
        var isInterruption: Bool { rawValue.hasPrefix("interrupted") }
        /// Failures that are worth one or two automatic retries of the same segment.
        var transient: Bool { [.gpuError, .hardwareEncoderReset].contains(self) }
    }

    var kind: Kind
    var stage: RenderStage = .encode
    var tool: String?
    var setting: String?
    var range: String?            // allowed values, from the encoder's message
    var lastError: String?        // the tool's last error line, quoted to the user
    var volume: String?
    var path: String?             // the file or folder involved (scrubbed when shown)
    var code: String?             // "NSPOSIXErrorDomain 28 ← …" (technical only)
    var signal: Int32?
    var exitStatus: Int32?
    var chain: [String] = []      // full error chain, outermost first (technical only)
    var segment: Int?
    var frames: String?           // "1200–1439"
    var seconds: Double?          // where in the video (source damage, GPU)
    var message: String           // the error's own message
}

/// Everything known about the export when it failed, beyond the error itself.
struct FailureContext {
    var stage: RenderStage = .encode
    var segment: Int?
    var frames: Range<Int>?
    var fps: Double = 24
    var scratch: URL?
    var output: URL?
    var sourceName = ""
    var pressure: SystemSnapshot.Pressure = .normal
}

enum FailureClassifier {
    /// Classification order: cancellation, typed recovery errors, tool failures (signal → known message → exit),
    /// the NSError chain (POSIX → Cocoa → AVFoundation → VideoToolbox → Metal), LumoraError, unknown.
    static func classify(_ error: Error, context c: FailureContext) -> RenderFailure {
        var f = RenderFailure(kind: .unknown, stage: c.stage, message: error.localizedDescription)
        f.chain = chain(error)
        f.segment = c.segment
        if let r = c.frames { f.frames = "\(r.lowerBound)–\(max(r.lowerBound, r.upperBound - 1))"; f.seconds = Double(r.lowerBound) / c.fps }
        f.code = codes(error).map { "\($0.domain) \($0.code)" }.joined(separator: " ← ")
        if f.code?.isEmpty == true { f.code = nil }

        if error is CancellationError { f.kind = .canceled; return f }
        if case LumoraError.canceled = error { f.kind = .canceled; return f }
        if let d = error as? DeliveryFailure {
            var inner = classify(d.underlying, context: { var x = c; x.stage = .deliver; return x }())
            if inner.kind == .unknown || inner.kind == .scratchDriveGone { inner.kind = .outputDriveGone }
            inner.stage = .deliver
            inner.chain = f.chain
            return inner
        }
        if let s = error as? SourceDamage {
            f.path = s.file
            f.seconds = s.seconds ?? f.seconds
            switch s.kind {
            case .indexMissing: f.kind = .sourceIndexMissing
            case .truncated, .endedEarly: f.kind = .sourceTruncated
            case .unsupported: f.kind = .sourceUnsupported
            case .damaged: f.kind = .sourceDamaged
            }
            f.lastError = s.detail
            return f
        }
        if let s = error as? SourceChange { f.kind = s.moved ? .sourceMoved : .sourceChanged; f.path = s.file; return f }
        if error is FrameCountMismatch { f.kind = .frameCountMismatch; return f }
        if let g = error as? GPUFault {
            f.kind = g.underlying.domain == MTLCommandBufferErrorDomain && g.underlying.code == MTLCommandBufferError.outOfMemory.rawValue
                ? .outOfMemory : .gpuError
            return f
        }
        if let t = error as? ToolFailure { return classifyTool(t, f, c) }
        if case LumoraError.toolFailed(let tool, let text) = error {
            return classifyTool(ToolFailure(tool: tool, stderrTail: text), f, c)
        }
        if case LumoraError.missingTool(let tool) = error { f.kind = .toolMissing; f.tool = tool.components(separatedBy: " ").first; return f }

        // NSError chain.
        let all = codes(error)
        let path = filePath(error)
        f.path = path
        for (domain, code) in all {
            if let k = kind(domain: domain, code: code, stage: c.stage, path: path, context: c) {
                f.kind = k
                if k == .encoderFailed && domain == NSPOSIXErrorDomain {
                    f.lastError = "it stopped taking frames before the end of its part"
                }
                if [.diskFull, .outputDriveGone, .scratchDriveGone, .noPermission, .privacyBlocked].contains(k) {
                    f.volume = volumeName(for: path, stage: c.stage, context: c)
                    if f.kind == .diskFull || f.kind == .outputDriveGone {
                        // A full or vanished output drive at delivery vs the scratch drive during encoding.
                        if k == .outputDriveGone, c.stage != .deliver, let p = path, let s = c.scratch?.path, p.hasPrefix(s) {
                            f.kind = .scratchDriveGone
                        }
                    }
                }
                return f
            }
        }
        if let le = error as? LumoraError {
            switch le {
            case .noVideoTrack: f.kind = .sourceUnsupported
            case .decodeFailed(let s):
                f.kind = .sourceDamaged
                f.lastError = s
            case .needsVendorSDK: f.kind = .sourceUnsupported
            case .unsupported(let s):
                if s.contains("moved or deleted") { f.kind = .sourceMoved; f.path = c.sourceName }
                else if s.contains("doesn't exist (was the drive disconnected?)") { f.kind = .outputDriveGone; f.stage = .deliver }
                else if s.contains("can't write to the folder") { f.kind = .noPermission; f.stage = .deliver }
                else if s.contains("isn't installed") { f.kind = .toolMissing }
                else if s.contains("needs") && s.contains("free") { f.kind = .diskFull }
            default: break
            }
        }
        return f
    }

    private static func classifyTool(_ t: ToolFailure, _ base: RenderFailure, _ c: FailureContext) -> RenderFailure {
        var f = base
        f.tool = t.tool
        f.exitStatus = t.signal == nil ? t.exitStatus : nil
        f.signal = t.signal
        f.lastError = t.lastErrorLine
        f.stage = t.stage.flatMap(RenderStage.init(rawValue:)) ?? c.stage
        let text = t.stderrTail
        if text.contains("No space left on device") { f.kind = .diskFull; f.volume = volumeName(for: nil, stage: f.stage, context: c); return f }
        if let s = t.signal, !t.stoppedByLumora {
            if s == SIGKILL && c.pressure != .normal { f.kind = .outOfMemory; return f }
            if [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGTRAP, SIGKILL, SIGFPE].contains(s) { f.kind = .toolCrashed; return f }
        }
        if let (setting, range) = rejectedSetting(tool: t.tool, stderr: text, args: t.args) {
            f.kind = .encoderRejectedSetting
            f.setting = setting
            f.range = range
            return f
        }
        let metadataTools = ["dovi_tool", "hdr10plus_tool", "MP4Box", "mkvmerge"]
        if metadataTools.contains(t.tool) || [.metadata, .hdr10Container, .join].contains(f.stage) && t.tool != "ffmpeg" {
            f.kind = .metadataToolFailed
            if f.stage == .encode { f.stage = .metadata }
            return f
        }
        if t.tool == "ffmpeg" && [.join, .metadata].contains(f.stage) { f.kind = .metadataToolFailed; return f }
        f.kind = .encoderFailed
        return f
    }

    // MARK: NSError

    static func codes(_ error: Error) -> [(domain: String, code: Int)] {
        var out: [(String, Int)] = []
        var queue: [NSError] = [error as NSError]
        var seen = 0
        while let e = queue.first, seen < 12 {
            queue.removeFirst(); seen += 1
            // Swift errors bridged as NSError have no meaningful domain/code for classification.
            if !(e.domain.contains(".") && e.domain.hasPrefix("Lumora")) { out.append((e.domain, e.code)) }
            if let u = e.userInfo[NSUnderlyingErrorKey] as? NSError { queue.append(u) }
            if let many = e.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { queue += many }
        }
        return out.filter { ![String(reflecting: LumoraError.self), "Lumora.LumoraError"].contains($0.0) && !$0.0.hasPrefix("Lumora.") }
    }

    static func chain(_ error: Error) -> [String] {
        var out: [String] = []
        var e: NSError? = error as NSError
        var depth = 0
        out.append("\(type(of: error)): \(error.localizedDescription)")
        if let t = error as? ToolFailure {
            out.append("tool \(t.tool), " + (t.signal.map { "killed by \(ToolFailure.signalName($0)) (\($0))" } ?? "exit status \(t.exitStatus)")
                       + (t.stoppedByLumora ? ", stopped by Lumora" : ""))
        }
        while let n = e, depth < 10 {
            if !n.domain.hasPrefix("Lumora.") { out.append("\(n.domain) \(n.code): \(n.localizedDescription)") }
            e = n.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return out
    }

    static func filePath(_ error: Error) -> String? {
        var e: NSError? = error as NSError
        while let n = e {
            if let p = n.userInfo[NSFilePathErrorKey] as? String { return p }
            if let u = n.userInfo[NSURLErrorKey] as? URL { return u.path }
            e = n.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    static let protectedFolders = ["Desktop", "Documents", "Downloads"].map { NSHomeDirectory() + "/" + $0 }

    private static func kind(domain: String, code: Int, stage: RenderStage, path: String?, context c: FailureContext) -> RenderFailure.Kind? {
        let atSource = stage == .decode || stage == .prepare || stage == .levels || stage == .grain
        switch domain {
        case NSPOSIXErrorDomain:
            switch Int32(code) {
            case ENOSPC, EDQUOT: return .diskFull
            case EACCES, EROFS: return .noPermission
            case EPERM:
                if let p = path, protectedFolders.contains(where: { p.hasPrefix($0) }) || p.hasPrefix("/Volumes/") { return .privacyBlocked }
                return .noPermission
            case ENOENT, ENXIO, EIO, ENODEV:
                if atSource { return code == Int(EIO) ? .sourceDamaged : .sourceMoved }
                return .outputDriveGone
            case ENOMEM: return .outOfMemory
            case EPIPE: return stage == .encode ? .encoderFailed : nil    // the encoder stopped reading: it quit
            default: return nil
            }
        case NSCocoaErrorDomain:
            switch code {
            case 640: return .diskFull                                   // NSFileWriteOutOfSpaceError
            case 513, 642: return .noPermission                           // no permission, read-only volume
            case 4, 260: return atSource ? .sourceMoved : .outputDriveGone
            default: return nil
            }
        case AVFoundationErrorDomain:
            switch code {
            case -11807: return .diskFull
            case -11801: return .outOfMemory
            case -11821, -11855, -11849: return stage == .encode ? .sourceDamaged : .sourceDamaged
            case -11834: return .toolMissing
            case -11833, -11828: return .sourceUnsupported
            case -11840: return .hardwareEncoderReset
            case -11861: return .encoderRejectedSetting
            case -11829: return .sourceIndexMissing
            case -11880: return .sourceTruncated
            default: return nil
            }
        case NSOSStatusErrorDomain:
            switch code {
            case -12912, -12903, -12915: return .hardwareEncoderReset
            case -12911, -12909, -12137: return .sourceDamaged
            case -12908: return .toolMissing
            case -12904: return .outOfMemory
            case -12848: return .sourceIndexMissing
            case -12551: return .sourceTruncated
            default: return nil
            }
        case MTLCommandBufferErrorDomain:
            return code == MTLCommandBufferError.outOfMemory.rawValue ? .outOfMemory : .gpuError
        default:
            return nil
        }
    }

    private static func volumeName(for path: String?, stage: RenderStage, context c: FailureContext) -> String? {
        if let p = path, let v = SystemSnapshot.volume(URL(fileURLWithPath: p)) { return v.name }
        let url = stage == .deliver ? c.output?.deletingLastPathComponent() : c.scratch
        return url.flatMap { SystemSnapshot.volume($0)?.name }
    }

    // MARK: Encoder messages that name a rejected setting

    /// The setting an encoder refused and, when its message says so, the allowed range. Patterns are the encoders'
    /// own stderr lines (SVT-AV1, aomenc, avmenc, x265, vvencapp).
    static func rejectedSetting(tool: String, stderr: String, args: [String]) -> (String, String?)? {
        func first(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: stderr, range: NSRange(stderr.startIndex..., in: stderr)) else { return nil }
            return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: stderr).map { String(stderr[$0]) } ?? "" }
        }
        func range(in text: String) -> String? {
            if let m = text.range(of: #"\[\s*-?\d+(\.\d+)?\s*-\s*-?\d+(\.\d+)?\s*\]"#, options: .regularExpression) {
                let nums = text[m].dropFirst().dropLast().components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
                if nums.count == 2 { return "between \(nums[0]) and \(nums[1])" }
            }
            if let m = text.range(of: #"\(\s*-?\d+ to -?\d+\s*\)"#, options: .regularExpression) {
                return "between " + text[m].dropFirst().dropLast().replacingOccurrences(of: " to ", with: " and ").trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
        // Unknown options.
        if let m = first(#"Unprocessed tokens:\s*(\S+)"#) { return (m[1], nil) }
        if let m = first(#"Unrecognized option\s+(\S+)"#) { return (m[1].components(separatedBy: "=")[0], nil) }
        if let m = first(#"unrecognized option [`'"](\S+?)['`"]"#) { return (m[1], nil) }
        if let m = first(#"Unknown option [`'"](\S+?)['`"]"#) { return ("--" + m[1].trimmingCharacters(in: CharacterSet(charactersIn: "-")), nil) }
        // Values out of range.
        if let m = first(#"Svt\[error\]:\s*(.+)"#) {
            let msg = m[1]
            let name = msg.components(separatedBy: " must ").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? msg
            return (name.count <= 40 ? name : msg, range(in: msg))
        }
        if let m = first(#"Tried to set control (\d+) = (\S+)"#) {
            let value = m[2]
            let arg = args.first { $0.hasSuffix("=\(value)") && $0.hasPrefix("--") }
            return (arg ?? "control \(m[1]) = \(value)", nil)
        }
        if let m = first(#"Tried to set option (\S+) = (\S+)"#) {
            let arg = args.first { $0.hasPrefix("--\(m[1])") }
            return (arg ?? "\(m[1]) = \(m[2])", nil)
        }
        if let m = first(#"Parameter Check Error:\s*(.+)"#) {
            let msg = m[1]
            let name = msg.components(separatedBy: " exceeds").first?.components(separatedBy: " must").first ?? msg
            return (name.trimmingCharacters(in: .whitespaces), range(in: msg))
        }
        if stderr.contains("preset or tune unrecognized") { return ("preset or tune", nil) }
        if let m = first(#"x265 \[error\]:\s*(.+)"#), !m[1].contains("x265_encoder_open") {
            let msg = m[1]
            return (msg.components(separatedBy: ":").first ?? msg, range(in: msg))
        }
        if stderr.contains("x265_encoder_open() failed") { return ("encoder settings", nil) }
        return nil
    }
}
