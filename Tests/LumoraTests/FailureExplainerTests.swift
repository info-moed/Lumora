import XCTest
import AVFoundation
import Metal
@testable import Lumora

/// Plain-language failure explanations, from the exact error chains and encoder messages measured on macOS 27.
/// Pure: no media, no encoders.
final class FailureExplainerTests: XCTestCase {

    func ns(_ domain: String, _ code: Int, _ underlying: NSError? = nil, path: String? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        if let path { info[NSFilePathErrorKey] = path }
        return NSError(domain: domain, code: code, userInfo: info)
    }

    func classify(_ e: Error, stage: RenderStage = .encode, pressure: SystemSnapshot.Pressure = .normal) -> RenderFailure {
        var c = FailureContext(stage: stage, segment: 3, frames: 96..<120, fps: 24, scratch: FileManager.default.temporaryDirectory,
                               output: URL(fileURLWithPath: "/tmp/out/clip.mkv"), sourceName: "clip.mov")
        c.pressure = pressure
        return FailureClassifier.classify(e, context: c)
    }

    func explain(_ e: Error, stage: RenderStage = .encode, pressure: SystemSnapshot.Pressure = .normal, progress: Double = 0.63) -> FailureReport {
        var x = FailureExplainer.Facts()
        x.progress = progress
        x.sourceName = "clip.mov"
        x.outputFolder = "out"
        x.delivery = .dolbyVision81
        return FailureExplainer.explain(classify(e, stage: stage, pressure: pressure), facts: x)
    }

    // MARK: The measured error chains

    func testErrorChainsMapToTheRightKind() {
        let cases: [(String, Error, RenderStage, RenderFailure.Kind)] = [
            ("broken pipe after the encoder died", ns(NSCocoaErrorDomain, 512, ns(NSPOSIXErrorDomain, Int(EPIPE))), .encode, .encoderFailed),
            ("no space (POSIX under Cocoa)", ns(NSCocoaErrorDomain, 512, ns(NSPOSIXErrorDomain, Int(ENOSPC))), .encode, .diskFull),
            ("move into a read-only folder", ns(NSCocoaErrorDomain, 513, ns(NSPOSIXErrorDomain, Int(EACCES))), .deliver, .noPermission),
            ("move into a missing folder", ns(NSCocoaErrorDomain, 4, ns(NSPOSIXErrorDomain, Int(ENOENT))), .deliver, .outputDriveGone),
            ("out of space", ns(NSCocoaErrorDomain, 640), .deliver, .diskFull),
            ("AVError diskFull", ns(AVFoundationErrorDomain, -11807), .encode, .diskFull),
            ("AVError outOfMemory", ns(AVFoundationErrorDomain, -11801), .encode, .outOfMemory),
            ("damaged frame while reading", ns(AVFoundationErrorDomain, -11821, ns(NSOSStatusErrorDomain, -12137)), .decode, .sourceDamaged),
            ("moov missing", ns(AVFoundationErrorDomain, -11829, ns(NSOSStatusErrorDomain, -12848)), .prepare, .sourceIndexMissing),
            ("truncated faststart", ns(AVFoundationErrorDomain, -11880, ns(NSOSStatusErrorDomain, -12551)), .decode, .sourceTruncated),
            ("VT invalid session", ns(NSOSStatusErrorDomain, -12903), .encode, .hardwareEncoderReset),
            ("VT encoder malfunction", ns(NSOSStatusErrorDomain, -12912), .encode, .hardwareEncoderReset),
            ("encoder temporarily unavailable", ns(AVFoundationErrorDomain, -11840), .encode, .hardwareEncoderReset),
            ("unsupported output settings", ns(AVFoundationErrorDomain, -11861), .encode, .encoderRejectedSetting),
            ("encoder not found", ns(AVFoundationErrorDomain, -11834), .encode, .toolMissing),
            ("GPU timeout", GPUFault(underlying: ns(MTLCommandBufferErrorDomain, Int(MTLCommandBufferError.timeout.rawValue))), .encode, .gpuError),
            ("GPU page fault", GPUFault(underlying: ns(MTLCommandBufferErrorDomain, Int(MTLCommandBufferError.pageFault.rawValue))), .encode, .gpuError),
            ("GPU out of memory", GPUFault(underlying: ns(MTLCommandBufferErrorDomain, Int(MTLCommandBufferError.outOfMemory.rawValue))), .encode, .outOfMemory),
            ("quota", ns(NSPOSIXErrorDomain, Int(EDQUOT)), .encode, .diskFull),
            ("read-only volume", ns(NSPOSIXErrorDomain, Int(EROFS)), .deliver, .noPermission),
            ("privacy-protected folder", ns(NSPOSIXErrorDomain, Int(EPERM), path: NSHomeDirectory() + "/Desktop/x.mkv"), .deliver, .privacyBlocked),
            ("canceled", CancellationError(), .encode, .canceled),
            ("source moved", SourceChange(moved: true, file: "clip.mov"), .encode, .sourceMoved),
            ("source changed", SourceChange(moved: false, file: "clip.mov"), .join, .sourceChanged),
            ("short join", FrameCountMismatch(got: 95, expected: 96), .join, .frameCountMismatch),
            ("missing tool", LumoraError.missingTool("x265"), .encode, .toolMissing),
            ("truncated source", SourceDamage(kind: .endedEarly, file: "clip.mov", frame: 57, seconds: 2.375, detail: "ends"), .decode, .sourceTruncated),
            ("unknown", ns("com.example.thing", 42), .encode, .unknown),
        ]
        for (label, e, stage, want) in cases {
            XCTAssertEqual(classify(e, stage: stage).kind, want, label)
        }
    }

    func testDeliveryFailureKeepsTheFinishedVideoAndExplainsIt() {
        let kept = URL(fileURLWithPath: "/tmp/Checkpoints/abc/final.mkv")
        let e = DeliveryFailure(underlying: ns(NSCocoaErrorDomain, 640), kept: kept)
        var x = FailureExplainer.Facts()
        x.finishedVideoKept = true
        let r = FailureExplainer.explain(classify(e), facts: x)
        XCTAssertEqual(r.failure.kind, .diskFull)
        XCTAssertEqual(r.failure.stage, .deliver)
        XCTAssertTrue(r.means.contains("Nothing has to be rendered again"), r.means)
        XCTAssertEqual(r.actions.first, .saveElsewhere)
    }

    // MARK: Tools: signals, settings, metadata

    func testCrashedEncoderNamesTheToolAndSignal() {
        let crash = ToolFailure(tool: "SvtAv1EncApp", exitStatus: 0, signal: SIGSEGV, stderrTail: "Svt[info]: encoding\n")
        let r = explain(crash)
        XCTAssertEqual(r.failure.kind, .toolCrashed)
        XCTAssertTrue(r.title.contains("SVT-AV1"), r.title)
        XCTAssertTrue(r.simple.contains("0:04–0:05"), r.simple)
        XCTAssertTrue(r.proLine.contains("signal 11 (SIGSEGV)"), r.proLine)
        XCTAssertEqual(r.actions.first, .resume)
        XCTAssertEqual(r.actions.first?.label(r), "Resume from 63%")

        let killed = ToolFailure(tool: "x265", exitStatus: 0, signal: SIGKILL, stderrTail: "")
        XCTAssertEqual(classify(killed).kind, .toolCrashed, "SIGKILL with normal memory pressure")
        XCTAssertEqual(classify(killed, pressure: .critical).kind, .outOfMemory, "SIGKILL under memory pressure")
        XCTAssertEqual(explain(killed, pressure: .critical).actions.first, .resumeLessMemory)

        var stopped = killed
        stopped.signal = SIGTERM
        stopped.stoppedByLumora = true
        XCTAssertNotEqual(classify(stopped).kind, .toolCrashed, "Lumora stopping a tool isn't a crash")
    }

    func testRejectedSettingsAreNamedFromRealEncoderMessages() {
        let samples: [(String, String, [String], String, String?)] = [
            ("SvtAv1EncApp", "Svt[error]: CRF must be [0 - 70]\n", ["--crf", "99"], "CRF", "between 0 and 70"),
            ("SvtAv1EncApp", "Unprocessed tokens: --bogus-opt 3\n", ["--bogus-opt", "3"], "--bogus-opt", nil),
            ("aomenc", "Error: Tried to set control 25 = 99\nFailed to control codec: Invalid parameter\n", ["--cq-level=99"], "--cq-level=99", nil),
            ("aomenc", "Error: Unrecognized option --bogus=1\n", ["--bogus=1"], "--bogus", nil),
            ("avmenc", "Error: Tried to set option qp = 999\n", ["--qp=999"], "--qp=999", nil),
            ("x265", "x265: unrecognized option `--bogus'\n", ["--bogus"], "--bogus", nil),
            ("x265", "x265 [error]: preset or tune unrecognized\n", ["--preset", "warp"], "preset or tune", nil),
            ("vvencapp", "Parameter Check Error: QP exceeds supported range (0 to 63)\n", ["--qp", "99"], "QP", "between 0 and 63"),
            ("vvencapp", "command line error: Unknown option `bogus'\n", ["--bogus"], "--bogus", nil),
        ]
        for (tool, stderr, args, setting, range) in samples {
            let r = explain(ToolFailure(tool: tool, args: args, exitStatus: 1, stderrTail: stderr))
            XCTAssertEqual(r.failure.kind, .encoderRejectedSetting, "\(tool): \(stderr)")
            XCTAssertEqual(r.failure.setting, setting, "\(tool): \(stderr)")
            XCTAssertEqual(r.failure.range, range, "\(tool): \(stderr)")
            XCTAssertTrue(r.simple.contains("“\(setting)”"), r.simple)
            XCTAssertEqual(r.actions.first, .resetSettings)
        }
    }

    func testMetadataToolFailuresSayTheVideoIsFine() {
        for (tool, msg) in [("dovi_tool", "Error: Invalid input file type."), ("hdr10plus_tool", "Error: Invalid input file type."),
                            ("MP4Box", "Failure while importing media: Corrupted Data in file/stream"),
                            ("mkvmerge", "Error: The file 'x.hevc' could not be opened")] {
            let r = explain(ToolFailure(tool: tool, exitStatus: 1, stderrTail: msg), stage: .metadata)
            XCTAssertEqual(r.failure.kind, .metadataToolFailed, tool)
            XCTAssertTrue(r.simple.contains("encoded fine"), r.simple)
            XCTAssertTrue(r.simple.contains(tool), r.simple)
            XCTAssertEqual(r.actions.first, .retryLastStep)
        }
        let dv = explain(ToolFailure(tool: "dovi_tool", exitStatus: 1, stderrTail: "Error: Invalid input file type."), stage: .metadata)
        XCTAssertTrue(dv.actions.contains(.saveWithoutDynamicMetadata))
        XCTAssertEqual(FailureAction.saveWithoutDynamicMetadata.label(dv), "Save without Dolby Vision (HDR10 only)")
    }

    func testUnknownErrorIsHonest() {
        let r = explain(ns("com.example.thing", 42))
        XCTAssertEqual(r.title, "Lumora doesn't recognize this error")
        XCTAssertTrue(r.actions.contains(.openLog))
        XCTAssertTrue(r.actions.contains(.copyReport))
        XCTAssertTrue(r.proLine.contains("com.example.thing 42"), r.proLine)
    }

    // MARK: Every kind

    func testEveryKindHasTitleSentenceMeaningAndAction() {
        for kind in RenderFailure.Kind.allCases {
            let f = RenderFailure(kind: kind, stage: kind.isSource ? .decode : .encode, tool: "SvtAv1EncApp",
                                  code: "NSPOSIXErrorDomain 28", signal: SIGSEGV, segment: 2, frames: "48–71", seconds: 2, message: "boom")
            var x = FailureExplainer.Facts()
            x.progress = 0.5
            x.savedBytes = 10 << 20
            x.sourceName = "clip.mov"
            let r = FailureExplainer.explain(f, facts: x)
            XCTAssertFalse(r.title.isEmpty, "\(kind) title")
            XCTAssertFalse(r.simple.isEmpty, "\(kind) simple")
            XCTAssertFalse(r.means.isEmpty, "\(kind) means")
            XCTAssertFalse(r.actions.isEmpty, "\(kind) actions")
            XCTAssertFalse(r.proLine.isEmpty, "\(kind) pro line")
            XCTAssertFalse(r.technical.isEmpty, "\(kind) technical details")
            for word in FailureExplainer.jargon {
                XCTAssertFalse(r.simple.localizedCaseInsensitiveContains(word), "\(kind): Simple text contains “\(word)”: \(r.simple)")
                XCTAssertFalse(r.title.localizedCaseInsensitiveContains(word), "\(kind): title contains “\(word)”")
            }
            // Spelled in pieces so the repository's US-English check doesn't rewrite the list itself.
            for british in ["cancel" + "led", "col" + "our", "behavi" + "our", "recog" + "nise", "organ" + "ise", "anal" + "yse", "fav" + "our"] {
                for text in [r.title, r.simple, r.means] + r.actions.map({ $0.label(r) }) {
                    XCTAssertFalse(text.lowercased().contains(british), "\(kind): British spelling “\(british)” in \(text)")
                }
            }
            XCTAssertFalse(r.simple.contains("{"), "\(kind): unfilled placeholder in \(r.simple)")
        }
    }

    func testSimpleTextNeverShowsCodesEvenFromToolMessages() {
        let r = explain(ToolFailure(tool: "x265", exitStatus: 1, stderrTail: "x265 [error]: bad thing at 0x7ffee1 errno 28 (ENOSPC-ish)\n"))
        XCTAssertFalse(r.simple.contains("0x7ffee1"), r.simple)
        XCTAssertFalse(r.simple.localizedCaseInsensitiveContains("errno"), r.simple)
        XCTAssertTrue(r.technical.joined().contains("0x7ffee1") || r.proLine.contains("x265"), "the details keep the original")
    }

    func testPlaceholdersAreFilled() {
        var x = FailureExplainer.Facts()
        x.progress = 0.63
        x.sourceName = "Holiday.mov"
        x.claimedSeconds = 4
        x.actualSeconds = 2.4
        let t = FailureExplainer.explain(RenderFailure(kind: .sourceTruncated, stage: .decode, message: "partial file"), facts: x)
        XCTAssertTrue(t.simple.contains("“Holiday.mov” says it is 0:04 long, but the video stops at 0:02"), t.simple)
        x.damagedFrames = 2
        x.damagePlaces = 2
        let d = FailureExplainer.explain(RenderFailure(kind: .sourceDamaged, stage: .decode, seconds: 1.92, message: "x"), facts: x)
        XCTAssertTrue(d.simple.contains("2 frames around 0:01.9, and 1 more place"), d.simple)
        let disk = FailureExplainer.explain(RenderFailure(kind: .diskFull, stage: .encode, volume: "Scratch SSD", message: "x"), facts: x)
        XCTAssertTrue(disk.simple.contains("“Scratch SSD”"), disk.simple)
        XCTAssertTrue(disk.means.contains("63% of the export is saved"), disk.means)
    }

    // MARK: Diagnostic report privacy

    func testDiagnosticReportIsScrubbed() {
        let home = NSHomeDirectory()
        var f = RenderFailure(kind: .unknown, stage: .encode, message: "failed writing \(home)/Movies/Holiday.mkv on /Volumes/Family Drive/x")
        f.chain = ["NSCocoaErrorDomain 4: \(home)/Movies/Holiday.mkv", "host \(DiagnosticScrub.machineNames.host) \(DiagnosticScrub.machineNames.computer)", "mail someone@example.com"]
        let r = FailureExplainer.explain(f)
        let names = DiagnosticScrub.names(source: URL(fileURLWithPath: "/x/Holiday.mov"), output: URL(fileURLWithPath: "/y/Holiday Natural.mkv"))
        let text = DiagnosticReport.make(r, logURL: nil, names: names)
        XCTAssertFalse(text.contains(home), "home folder")
        XCTAssertFalse(text.contains(NSUserName()), "account name")
        if NSFullUserName().count >= 3 { XCTAssertFalse(text.contains(NSFullUserName()), "full name") }
        let host = DiagnosticScrub.machineNames.host.replacingOccurrences(of: ".local", with: "")
        if host.count >= 3 { XCTAssertFalse(text.localizedCaseInsensitiveContains(host), "host name") }
        let computer = DiagnosticScrub.machineNames.computer
        if computer.count >= 3 { XCTAssertFalse(text.localizedCaseInsensitiveContains(computer), "computer name") }
        XCTAssertFalse(text.contains("Family Drive"), "drive name")
        XCTAssertFalse(text.contains("Holiday"), "file names")
        XCTAssertFalse(text.contains("someone@example.com"), "email")
        XCTAssertTrue(text.contains("<source>") || text.contains("<output>"))
    }

    /// A drive named after the app (or a tool) hides only its path, not the words the report needs.
    func testDriveNamedLikeTheAppKeepsTheReportReadable() {
        let text = DiagnosticScrub.share("Lumora export log\nOutput: /Volumes/Lumora/Movies/x.mkv\nffmpeg failed on “Lumora”",
                                         names: .init(volumes: ["Lumora"]))
        XCTAssertTrue(text.contains("Lumora export log"), text)
        XCTAssertTrue(text.contains("/Volumes/<drive>/Movies"), text)
        XCTAssertTrue(text.contains("“<drive>”"), text)
        XCTAssertTrue(text.contains("ffmpeg failed"), text)
        // A drive that is neither protected nor quoted is still hidden wherever its path appears.
        let other = DiagnosticScrub.share("on /Volumes/Family Drive/a and Family Drive again")
        XCTAssertFalse(other.contains("Family Drive"), other)
    }
}
