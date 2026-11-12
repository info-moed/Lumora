import Foundation

/// Carries a film's original Dolby Vision metadata (including the colourist's trims) through interpolation,
/// black-bar cropping and re-encoding, instead of replacing it with simpler generated metadata.
///
/// How: extract the RPU (converting profile 7 to 8.1), then rebuild it for the new frame sequence: every output
/// frame takes the metadata of the source frame it came from (generated frames: the nearest original in the same
/// shot, since Lumora never interpolates across cuts). Done with dovi_tool's editor in two passes, removals then
/// duplications applied from the end so indices never shift. L5 (active area) is reset when black bars are removed.
enum DolbyVisionRetimer {
    enum Decision: Equatable {
        case retimeOriginal          // keep the colourist's Dolby Vision, retimed
        case generateNew(String)     // reason: why the original can't be kept
        case none
    }

    /// Plain-English decision used by the UI, the recommender and the export.
    static func decide(source d: SourceDescriptor, look: Look, passthrough: Bool, codec: Codec, delivery: DeliveryFormat) -> Decision {
        guard delivery == .dolbyVision81 else { return .none }
        guard d.isDolbyVision, d.dvProfile != 5 else { return .generateNew("the source has no HDR10-compatible Dolby Vision to keep") }
        guard codec == .hevc || codec == .hevc12 else { return .generateNew("Dolby Vision is only written into HEVC") }
        guard look == .original || passthrough else { return .generateNew("the picture is being regraded, so the original Dolby Vision no longer describes it") }
        guard d.scanFix == .none else { return .generateNew("frames are being deinterlaced or reconstructed") }
        return .retimeOriginal
    }

    /// Output-frame → source-frame mapping for an export plan.
    static func sourceFrames(for plan: [PlannedFrame]) -> [Int] {
        plan.map { $0.kind == .original || $0.kind == .holdAcrossCut ? $0.a : ($0.t < 0.5 ? $0.a : $0.b) }
    }

    /// Produces an RPU file with exactly `mapping.count` frames, or throws (the caller then generates new metadata).
    static func retime(source url: URL, mapping: [Int], cropped: Bool, workDir: URL) throws -> URL {
        let hevc = workDir.appendingPathComponent("source-bl.hevc")
        let rpu = workDir.appendingPathComponent("source-rpu.bin")
        try ToolLocator.run("ffmpeg", ["-y", "-v", "error", "-i", url.path, "-map", "0:v:0", "-c:v", "copy",
                                       "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", hevc.path])
        defer { try? FileManager.default.removeItem(at: hevc) }
        // Mode 2: convert to profile 8.1 (drops the enhancement layer's reference, keeps all dynamic metadata and trims).
        try ToolLocator.run("dovi_tool", ["-m", "2", "extract-rpu", "-i", hevc.path, "-o", rpu.path])
        // Work from the RPU's real length: frames past the last one the output uses must be removed too, and an RPU
        // shorter than the frames the output needs can't be lined up at all.
        let sourceCount = try frameCount(of: rpu)
        guard let last = mapping.max(), let first = mapping.min(), first >= 0, last < sourceCount else {
            throw LumoraError.unsupported("The original Dolby Vision covers \(sourceCount) frames, but the output needs source frame \(mapping.max() ?? -1).")
        }

        // Pass 1: remove source frames no output frame uses (and reset the active area if we cropped).
        var counts = [Int](repeating: 0, count: sourceCount)
        for s in mapping { counts[s] += 1 }
        let unused = counts.enumerated().filter { $0.element == 0 }.map(\.offset)
        var pass1: [String: Any] = [:]
        if !unused.isEmpty { pass1["remove"] = ranges(unused).map { "\($0.lowerBound)-\($0.upperBound)" } }
        if cropped { pass1["active_area"] = ["crop": true] }
        var current = rpu
        if !pass1.isEmpty {
            let json = workDir.appendingPathComponent("dv-pass1.json"), out = workDir.appendingPathComponent("rpu-pass1.bin")
            try JSONSerialization.data(withJSONObject: pass1).write(to: json)
            try ToolLocator.run("dovi_tool", ["editor", "-i", current.path, "-j", json.path, "-o", out.path])
            current = out
        }
        // Pass 2: duplicate frames that feed several output frames, last first so earlier indices don't move.
        let kept = counts.enumerated().filter { $0.element > 0 }        // in post-removal order
        var dups: [[String: Int]] = []
        for (newIndex, entry) in kept.enumerated().reversed() where entry.element > 1 {
            dups.append(["source": newIndex, "offset": newIndex + 1, "length": entry.element - 1])
        }
        if !dups.isEmpty {
            let json = workDir.appendingPathComponent("dv-pass2.json"), out = workDir.appendingPathComponent("rpu-pass2.bin")
            try JSONSerialization.data(withJSONObject: ["duplicate": dups]).write(to: json)
            try ToolLocator.run("dovi_tool", ["editor", "-i", current.path, "-j", json.path, "-o", out.path])
            current = out
        }
        // Verify the frame count before trusting it.
        let n = try frameCount(of: current)
        if n != mapping.count {
            Log.warning(.encode, "Retimed RPU has \(n) frames, expected \(mapping.count)")
            throw LumoraError.unsupported("Dolby Vision retiming produced the wrong frame count.")
        }
        Log.notice(.encode, "Dolby Vision retimed: \(sourceCount) source frames → \(mapping.count) output frames (removed \(unused.count), \(dups.count) duplications)\(cropped ? ", active area reset" : "")")
        return current
    }

    /// Number of frames in a binary RPU file ("Frames: N" in `dovi_tool info --summary`).
    static func frameCount(of rpu: URL) throws -> Int {
        let info = String(decoding: try ToolLocator.run("dovi_tool", ["info", "-i", rpu.path, "-s"]), as: UTF8.self)
        guard let line = info.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Frames:") }),
              let n = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") else {
            throw LumoraError.unsupported("Couldn't read the Dolby Vision frame count.")
        }
        return n
    }

    private static func ranges(_ v: [Int]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for x in v {
            if let last = out.last, last.upperBound + 1 == x { out[out.count - 1] = last.lowerBound...x } else { out.append(x...x) }
        }
        return out
    }
}
