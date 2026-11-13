import Foundation

/// What the person can do about a failure. The UI maps each to a button; the label depends on the mode.
enum FailureAction: String, Codable, CaseIterable, Hashable {
    case resume, resumeLessMemory, startOver, discard, chooseScratch, saveAgain, saveElsewhere, showFolder
    case openPrivacySettings, installTool, chooseCodec, copyReport, openLog, resetSettings, editEncoderOptions
    case retryLastStep, saveWithoutDynamicMetadata, repairSource, exportAnyway, showDamage, locateSource, restartMac, quitOtherApps

    func label(_ r: FailureReport) -> String {
        let p = r.progressText
        switch self {
        case .resume: return r.progress > 0.005 ? "Resume from \(p)" : "Try again"
        case .resumeLessMemory: return "Resume using less memory"
        case .startOver: return "Start over"
        case .discard: return "Discard saved progress"
        case .chooseScratch: return "Choose another scratch drive…"
        case .saveAgain: return "Save again"
        case .saveElsewhere: return "Save to another folder…"
        case .showFolder: return "Show the folder in Finder"
        case .openPrivacySettings: return "Open Privacy & Security settings"
        case .installTool: return "How to install \(r.failure.tool ?? "the tool")"
        case .chooseCodec: return "Choose a different codec"
        case .copyReport: return "Copy diagnostic report"
        case .openLog: return "Open the export log"
        case .resetSettings: return "Reset to recommended settings"
        case .editEncoderOptions: return "Edit encoder options"
        case .retryLastStep: return "Try the last step again"
        case .saveWithoutDynamicMetadata: return "Save without \(r.dynamicMetadataName) (HDR10 only)"
        case .repairSource: return "Repair a copy"
        case .exportAnyway: return r.failure.kind == .sourceTruncated ? "Export what's there" : "Export anyway and rebuild those frames"
        case .showDamage: return "Show me where"
        case .locateSource: return "Locate the file…"
        case .restartMac: return "Restart your Mac, then resume"
        case .quitOtherApps: return "Quit other apps, then resume"
        }
    }
}

/// A failure explained for people: a title, one plain sentence, what it means for their file, and one or two
/// things to do; the technical details are one click away.
struct FailureReport: Codable, Identifiable, Hashable {
    var id = UUID()
    var failure: RenderFailure
    var title: String
    var simple: String
    var means: String
    var actions: [FailureAction]
    var proLine: String
    var technical: [String] = []
    var exportID: String?
    var logPath: String?
    var progress: Double = 0          // saved progress, 0…1 (frames in validated segments / planned frames)
    var savedBytes: Int64 = 0
    var finishedVideoKept = false
    var delivery: DeliveryFormat?
    var date = Date()

    var progressText: String { "\(Int((progress * 100).rounded(.down)))%" }
    var dynamicMetadataName: String { delivery == .hdr10Plus ? "HDR10+" : "Dolby Vision" }
    var primaryAction: FailureAction? { actions.first }
}

enum FailureText {
    /// "1:05" or "1:02:03"; fractions of a second for times under a minute when they matter ("0:01.9").
    static func time(_ s: Double, precise: Bool = false) -> String {
        guard s.isFinite, s >= 0 else { return "0:00" }
        let total = Int(s)
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        var out = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
        if precise { out += String(format: ".%d", Int((s - Double(total)) * 10)) }
        return out
    }

    /// What a tool is for, in words.
    static func purpose(_ tool: String) -> String {
        switch tool {
        case "SvtAv1EncApp": return "the AV1 encoder"
        case "aomenc": return "the libaom AV1 encoder"
        case "x265": return "the 12-bit HEVC encoder"
        case "vvencapp": return "the VVC encoder"
        case "avmenc": return "the AV2 encoder"
        case "ffmpeg", "ffprobe": return "the video reader and joiner"
        case "MP4Box", "mkvmerge": return "the file packager"
        case "dovi_tool": return "the Dolby Vision tool"
        case "hdr10plus_tool": return "the HDR10+ tool"
        case "vmaf": return "the quality meter"
        default: return "a helper tool"
        }
    }

    static func displayName(_ tool: String) -> String {
        switch tool {
        case "SvtAv1EncApp": return "AV1 encoder (SVT-AV1)"
        case "aomenc": return "AV1 encoder (libaom)"
        case "x265": return "HEVC encoder (x265)"
        case "vvencapp": return "VVC encoder (VVenC)"
        case "avmenc": return "AV2 encoder (AVM)"
        case "ffmpeg": return "video joiner (FFmpeg)"
        case "MP4Box": return "file packager (MP4Box)"
        case "mkvmerge": return "file packager (mkvmerge)"
        case "dovi_tool": return "Dolby Vision tool"
        case "hdr10plus_tool": return "HDR10+ tool"
        default: return tool
        }
    }
}

enum FailureExplainer {
    struct Facts {
        var progress: Double = 0
        var savedBytes: Int64 = 0
        var finishedVideoKept = false
        var scratchVolume: String?
        var outputFolder: String?
        var sourceName = ""
        var claimedSeconds: Double?
        var actualSeconds: Double?
        var damagePlaces = 0
        var damagedFrames = 0
        var retried = false
        var delivery: DeliveryFormat?
        var neededBytes: Int64?
        var freeBytes: Int64?
        var mid = false           // a missing tool found mid-run (something already saved)
        var upfront = false       // found by the check before rendering anything
    }

    static func explain(_ f: RenderFailure, facts x: Facts = Facts()) -> FailureReport {
        let p = "\(Int((x.progress * 100).rounded(.down)))%"
        let saved = x.progress > 0.005
        let tool = f.tool.map(FailureText.displayName) ?? "encoder"
        let range = segmentTimes(f)
        let source = x.sourceName.isEmpty ? "the source" : "“\(x.sourceName)”"
        var title = "", simple = "", means = "", pro = ""
        var actions: [FailureAction] = []
        let savedLine = saved ? "\(p) of the export is saved and can be resumed." : "Nothing had been saved yet, so the export starts from the beginning."
        let gb = { (b: Int64?) in b.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "some" }

        switch f.kind {
        case .diskFull:
            let vol = f.volume ?? (f.stage == .deliver ? "your output drive" : "the scratch drive")
            let which = f.stage == .deliver ? "your output drive" : "the scratch drive, where Lumora keeps work in progress"
            title = "The drive ran out of space"
            simple = "Lumora ran out of room on “\(vol)” (\(which)) while saving the video. Your source file is fine."
            means = x.finishedVideoKept ? "The finished video is safe in Lumora's scratch folder. Nothing has to be rendered again."
                : "\(savedLine) Nothing was written to your output folder."
            actions = x.finishedVideoKept ? [.saveElsewhere, .saveAgain]
                : [.resume, .chooseScratch]
            if let n = x.neededBytes { means += " Free up about \(gb(n)) first." }
            pro = "Out of space writing \(f.path.map { ($0 as NSString).lastPathComponent } ?? "a file") on “\(vol)”"
                + (x.freeBytes.map { " (\(gb($0)) free)" } ?? "") + "; stage \(f.stage.rawValue)" + (f.segment.map { ", segment \($0)" } ?? "") + "."
        case .outputDriveGone:
            title = "The output drive was disconnected"
            simple = "“\(f.volume ?? x.outputFolder ?? "The output drive")” went away before Lumora could save the finished video."
            means = x.finishedVideoKept ? "The finished video is safe in Lumora's scratch folder. Nothing has to be rendered again."
                : (x.upfront ? "Nothing was rendered yet." : "\(savedLine) Nothing was written to your output folder.")
            actions = x.finishedVideoKept ? [.saveAgain, .saveElsewhere] : (x.upfront ? [.saveElsewhere] : [.resume, .saveElsewhere])
            pro = "The output folder \(x.outputFolder.map { "“\($0)”" } ?? "") is missing; stage \(f.stage.rawValue)."
        case .scratchDriveGone:
            title = "The scratch drive was disconnected"
            simple = "The scratch drive “\(f.volume ?? "scratch")” went away during the export."
            means = saved ? "\(p) is saved on it; reconnect it and resume." : "Reconnect it and try again, or choose another scratch drive."
            actions = [.resume, .chooseScratch]
            pro = "Scratch path missing during \(f.stage.rawValue)."
        case .noPermission:
            title = "Lumora isn't allowed to save there"
            simple = "The folder “\(x.outputFolder ?? folderName(f.path) ?? "output")” is read-only, or you don't have permission to write to it."
            means = x.finishedVideoKept ? "The finished video is safe; nothing needs to be rendered again."
                : (x.upfront || x.progress < 0.005 ? "Nothing was rendered yet." : savedLine)
            actions = x.finishedVideoKept ? [.saveElsewhere, .showFolder] : [.saveElsewhere, .showFolder]
            pro = "Permission denied (\(f.code ?? "no code")) at \(f.stage.rawValue)."
        case .privacyBlocked:
            title = "macOS is blocking access to this folder"
            simple = "Your Mac's privacy settings stop Lumora from saving into “\(x.outputFolder ?? folderName(f.path) ?? "this folder")”."
            means = x.finishedVideoKept ? "The finished video is safe; nothing needs to be rendered again." : "Nothing was lost."
            actions = [.openPrivacySettings, .saveElsewhere]
            pro = "Operation not permitted (EPERM) at \(f.stage.rawValue)."
        case .toolMissing:
            let t = f.tool ?? "a helper tool"
            title = "A helper tool is missing"
            simple = "This export needs \(t) (\(FailureText.purpose(t))), and Lumora can't find it."
            means = x.mid || saved ? "\(p) is saved and resumes once the tool is back." : "Nothing was rendered."
            actions = [.installTool, .chooseCodec]
            pro = "\(t) not found in the app bundle, /opt/homebrew/bin or /usr/local/bin."
        case .toolCrashed:
            title = "The \(tool) crashed"
            simple = "The \(tool) stopped unexpectedly while encoding \(range ?? "part of the video")."
                + (x.retried ? " Lumora tried that part again and it crashed again." : "")
            means = "\(savedLine) Your source file is fine."
            actions = [.resume, .copyReport]
            pro = "\(f.tool ?? "encoder") killed by \(f.signal.map { "signal \($0) (\(ToolFailure.signalName($0)))" } ?? "a signal")"
                + (f.segment.map { " on segment \($0)" } ?? "") + (f.frames.map { " (frames \($0))" } ?? "") + "."
        case .encoderRejectedSetting:
            title = "The encoder didn't accept a setting"
            let setting = f.setting ?? "one of the settings"
            simple = "The \(tool) refused the setting “\(setting)”" + (f.range.map { ": it must be \($0)" } ?? "")
                + ". This usually comes from a custom encoder option."
            means = "Nothing was encoded with these settings, and your source file is fine."
            actions = [.resetSettings, .editEncoderOptions]
            pro = "\(f.tool ?? "encoder"): \(f.lastError ?? f.message)"
        case .encoderFailed:
            title = "The \(tool) stopped with an error"
            simple = "The \(tool) reported: “\(plain(f.lastError ?? f.message))”."
            means = savedLine
            actions = [.resume, .copyReport]
            pro = "\(f.tool ?? "encoder") exited with status \(f.exitStatus ?? -1)" + (f.segment.map { " on segment \($0)" } ?? "") + "."
        case .outOfMemory:
            title = "Your Mac ran out of memory"
            simple = "The export needed more memory than was free, so macOS stopped \(f.tool != nil ? "the \(tool)" : "Lumora")."
            means = savedLine
            actions = [.resumeLessMemory, .quitOtherApps]
            pro = (f.signal.map { "\(f.tool ?? "process") killed by \(ToolFailure.signalName($0)) under memory pressure" } ?? "Out of memory (\(f.code ?? "no code"))") + "."
        case .gpuError:
            title = "The graphics processor reported an error"
            simple = "The GPU stopped while grading the frame at \(f.seconds.map { FailureText.time($0) } ?? "this point"). This can happen when the Mac is very hot, very low on memory, or just after waking from sleep."
            means = saved ? "\(p) is saved; frames already finished aren't affected." : "Frames already finished aren't affected."
            actions = [.resume, .copyReport]
            pro = "Metal command buffer error \(f.code ?? "")."
        case .hardwareEncoderReset:
            title = "The Mac's video encoder stopped responding"
            simple = "The built-in hardware encoder reset itself (this often happens after sleep). Lumora tried again, but it didn't recover."
            means = savedLine
            actions = [.resume, .restartMac]
            pro = "VideoToolbox / AVFoundation \(f.code ?? "")."
        case .interruptedQuit:
            title = "The export was interrupted"
            simple = "Lumora was quit during the export. \(p) was saved."
            means = saved ? "Resuming re-encodes only what is missing." : "Nothing had been finished yet."
            actions = [.resume, .startOver, .discard]
            pro = "The journal recorded a normal quit."
        case .interruptedCrash:
            title = "The export was interrupted"
            simple = "Lumora quit unexpectedly during the export. \(p) was saved."
            means = saved ? "Resuming re-encodes only what is missing." : "Nothing had been finished yet."
            actions = [.resume, .startOver, .discard, .copyReport]
            pro = "A crash report newer than the last heartbeat was found."
        case .interruptedRestart:
            title = "The export was interrupted"
            simple = "Your Mac restarted or lost power during the export. \(p) was saved; at most the parts being encoded at that moment were lost."
            means = "Resuming re-encodes only what is missing."
            actions = [.resume, .startOver, .discard]
            pro = "The boot session changed since the last heartbeat."
        case .interruptedShutdownAsleep:
            title = "The export was interrupted"
            simple = "Your Mac went to sleep and then shut down during the export. \(p) was saved."
            means = "Resuming re-encodes only what is missing."
            actions = [.resume, .startOver, .discard]
            pro = "Last event was sleep; the boot session changed."
        case .interruptedUnknown:
            title = "The export was interrupted"
            simple = "Lumora stopped during the export, probably because it quit unexpectedly. \(p) was saved."
            means = "Resuming re-encodes only what is missing."
            actions = [.resume, .startOver, .discard]
            pro = "The process ended without recording why."
        case .canceled:
            title = "You stopped the export"
            simple = "Nothing was saved to your output folder."
            if saved {
                means = "Lumora kept the finished part (\(p)) so you can resume later. It uses \(gb(x.savedBytes)) on the scratch drive."
                actions = [.resume, .discard]
            } else {
                means = "Nothing was kept."
                actions = []
            }
            pro = "Canceled at \(f.stage.rawValue)."
        case .sourceIndexMissing:
            title = "This video file is incomplete"
            simple = "The end of \(source) is missing, including the index that tells players where every frame is. This happens when a recording or a copy is interrupted."
            means = "Lumora can't read any frames from this file, and the index can't be rebuilt from this file alone. Find the original on the camera card or another complete copy. A recovery tool that uses a working clip from the same camera and settings as a pattern may be able to rescue it."
            actions = [.copyReport]
            pro = "No moov atom (\(f.code ?? "moov atom not found"))."
        case .sourceUnsupported:
            title = "Lumora can't read this kind of video"
            simple = "\(source.prefix(1).uppercased() + source.dropFirst()) uses a format this Mac can't decode."
            means = "Nothing was rendered. Converting it with another app first, or installing FFmpeg, may help."
            actions = [.copyReport]
            pro = f.lastError ?? f.message
        case .sourceTruncated:
            title = "This video file is cut short"
            if let c = x.claimedSeconds, let a = x.actualSeconds {
                simple = "\(source.prefix(1).uppercased() + source.dropFirst()) says it is \(FailureText.time(c)) long, but the video stops at \(FailureText.time(a)). The rest of the file is missing."
            } else {
                simple = "\(source.prefix(1).uppercased() + source.dropFirst()) stops before its end\(f.seconds.map { " (at \(FailureText.time($0)))" } ?? ""). The rest of the file is missing."
            }
            means = "Lumora can export the part that's there. The missing part can't be recovered from this file."
            actions = [.repairSource, .exportAnyway]
            pro = f.lastError ?? f.message
        case .sourceDamaged:
            title = "Part of this video is damaged"
            let n = max(1, x.damagedFrames)
            simple = x.damagedFrames > 0
                ? "\(n) frame\(n == 1 ? "" : "s") around \(f.seconds.map { FailureText.time($0, precise: true) } ?? "one point")\(x.damagePlaces > 1 ? ", and \(x.damagePlaces - 1) more place\(x.damagePlaces == 2 ? "" : "s")," : "") can't be read correctly."
                : "Some frames around \(f.seconds.map { FailureText.time($0, precise: true) } ?? "one point") can't be read correctly."
            means = "Lumora can rebuild those frames from the good frames around them (or by repeating the previous frame) and leaves every other frame untouched."
            actions = [.repairSource, .exportAnyway, .showDamage]
            pro = f.lastError ?? f.message
        case .sourceChanged:
            title = "The source file changed during the export"
            simple = "\(source.prefix(1).uppercased() + source.dropFirst()) was changed while Lumora was using it."
            means = saved ? "\(p) is saved, but it was made from the file as it was before." : "Nothing was saved."
            actions = [.startOver, .resume]
            pro = "Source fingerprint (size, date, first and last 4 MB) no longer matches."
        case .sourceMoved:
            title = "The source file was moved or deleted"
            simple = "\(source.prefix(1).uppercased() + source.dropFirst()) was moved or deleted while Lumora was using it."
            means = saved ? "\(p) is saved, but it was made from the file as it was before. Put it back or locate it to resume." : "Put it back and export again."
            actions = [.locateSource, .startOver]
            pro = "The source path no longer exists."
        case .metadataToolFailed:
            let dynamic = x.delivery.map { ExportEngine.needsMetadataPass($0) } ?? false
            let step = f.stage == .metadata ? "adding \(x.delivery == .hdr10Plus ? "HDR10+" : "Dolby Vision") metadata"
                : (f.stage == .hdr10Container ? "adding HDR10 metadata to the file" : "packaging the file")
            title = f.stage == .metadata ? "Adding \(x.delivery == .hdr10Plus ? "HDR10+" : "Dolby Vision") metadata failed" : "Packaging the file failed"
            simple = "The video itself was encoded fine. The last step (\(step) with \(f.tool ?? "a helper tool")) reported: “\(plain(f.lastError ?? f.message))”."
            means = "The encoded video is saved; nothing needs to be encoded again."
            actions = [.retryLastStep] + (dynamic && f.stage == .metadata ? [.saveWithoutDynamicMetadata] : []) + [.copyReport]
            pro = "\(f.tool ?? "tool") exited with status \(f.exitStatus ?? -1) at \(f.stage.rawValue)."
        case .frameCountMismatch:
            title = "Lumora found a gap in the finished video"
            simple = f.message.replacingOccurrences(of: "The rendered video", with: "The rendered video")
                + " You won't get a file with a skipped moment."
            means = "Resuming re-checks every saved part and redoes only the bad ones."
            actions = [.resume, .copyReport]
            pro = "Frame-count guard at join."
        case .unknown:
            title = "Lumora doesn't recognize this error"
            simple = "The export stopped because of an error Lumora doesn't have an explanation for yet: “\(short(f.message))”."
            means = savedLine
            actions = [.resume, .copyReport, .openLog]
            pro = f.code.map { "Error \($0)." } ?? "No error code."
        }
        var r = FailureReport(failure: f, title: title, simple: plainSentence(simple), means: means, actions: actions, proLine: pro)
        r.progress = x.progress
        r.savedBytes = x.savedBytes
        r.finishedVideoKept = x.finishedVideoKept
        r.delivery = x.delivery
        r.technical = technical(f)
        return r
    }

    /// "0:41–1:12" for a segment's frames.
    static func segmentTimes(_ f: RenderFailure) -> String? {
        guard let s = f.seconds, let fr = f.frames else { return nil }
        let parts = fr.components(separatedBy: "–").compactMap(Int.init)
        guard parts.count == 2, let first = parts.first, first >= 0 else { return FailureText.time(s) }
        let fps = Double(first) > 0 ? Double(first) / s : 24
        return "\(FailureText.time(s))–\(FailureText.time(Double(parts[1] + 1) / max(1, fps)))"
    }

    static func technical(_ f: RenderFailure) -> [String] {
        var t: [String] = ["Kind: \(f.kind.rawValue)", "Stage: \(f.stage.rawValue) (\(f.stage.displayName))"]
        if let s = f.segment { t.append("Segment: \(s)" + (f.frames.map { ", frames \($0)" } ?? "")) }
        if let tool = f.tool { t.append("Tool: \(tool)") }
        if let s = f.signal { t.append("Signal: \(s) (\(ToolFailure.signalName(s)))") }
        if let e = f.exitStatus, f.signal == nil { t.append("Exit status: \(e)") }
        if let c = f.code { t.append("Error codes: \(c)") }
        if let s = f.setting { t.append("Rejected setting: \(s)") }
        if let l = f.lastError { t.append("Last error line: \(l)") }
        t += f.chain.map { "  " + $0 }
        return t.map(DiagnosticScrub.local)
    }

    /// Words a person shouldn't have to read: codes and internals. The Simple sentence never contains them.
    static let jargon = ["errno", "NSError", "domain", "SIGSEGV", "SIGKILL", "stderr", "0x", "OSStatus", "POSIX", "NSCocoa",
                         "NSPOSIX", "AVFoundationErrorDomain", "exit status", "signal 1", "EPIPE", "ENOSPC"]

    private static func plain(_ s: String) -> String {
        var t = short(s)
        for j in ["Svt[error]:", "x265 [error]:", "Error:"] { t = t.replacingOccurrences(of: j, with: "") }
        t = t.replacingOccurrences(of: #"0x[0-9a-fA-F]+"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func short(_ s: String) -> String {
        let first = RenderLog.splitLines(s).last { !$0.isEmpty } ?? s
        let scrubbed = DiagnosticScrub.local(first)
        return scrubbed.count > 160 ? String(scrubbed.prefix(160)) + "…" : scrubbed
    }

    /// The Simple sentence with every code-like token removed (a tool's own message can contain them).
    private static func plainSentence(_ s: String) -> String {
        var t = s
        for j in jargon where j != "0x" {
            t = t.replacingOccurrences(of: j, with: "", options: .caseInsensitive)
        }
        t = t.replacingOccurrences(of: #"0x[0-9a-fA-F]+"#, with: "", options: .regularExpression)
        return t.replacingOccurrences(of: "  ", with: " ")
    }

    private static func folderName(_ path: String?) -> String? {
        path.map { p in
            var isDir: ObjCBool = false
            let u = URL(fileURLWithPath: p)
            return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue ? u.lastPathComponent
                : u.deletingLastPathComponent().lastPathComponent
        }
    }
}
