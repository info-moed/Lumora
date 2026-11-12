import Foundation

/// Scores a finished file against its source (same frame rate), e.g. a re-encoded rip against the original:
/// every installed metric, plus Apple's AVQT. Both files are decoded by FFmpeg and streamed; nothing is written.
enum FileMetrics {
    struct Result {
        var scores: MetricScores
        var avqt: Double?
        var notes: [String]
    }

    static func measure(reference: URL, test: URL, hdr: Bool, width: Int, height: Int, frames: Int, rate: (Int, Int),
                        offsetSeconds: Double = 0) async throws -> Result {
        let work = try ScratchManager.jobDirectory("filemetrics")
        defer { try? FileManager.default.removeItem(at: work) }
        var notes: [String] = []
        let metrics = Set(QualityMetric.allCases.filter { $0.isAvailable && $0 != .avqt && !($0 == .ssimulacra2 && hdr) })
        let ctx = MetricSuite.Context(width: width, height: height, rate: rate, hdr: hdr, frames: frames,
                                      threads: ChipProfile.current.cpuCores, fast: true, workDir: work)
        // Reference stream: FFmpeg decodes the original into 10-bit 4:2:0 Y4M, piped straight into each metric.
        let writeReference: (FileHandle) throws -> Void = { handle in
            let p = Process()
            p.executableURL = ToolLocator.url(for: "ffmpeg")
            var args = ["-v", "error", "-nostdin"]
            if offsetSeconds > 0 { args += ["-ss", String(format: "%.4f", offsetSeconds)] }
            args += ["-i", reference.path, "-vf", "scale=\(width):\(height),format=yuv420p10le", "-strict", "-1", "-f", "yuv4mpegpipe", "-"]
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            while let chunk = try pipe.fileHandleForReading.read(upToCount: 8 << 20), !chunk.isEmpty {
                try handle.write(contentsOf: chunk)
            }
            p.waitUntilExit()
        }
        let scores = try await MetricSuite.measure(metrics, reference: writeReference, distorted: test, ctx: ctx)
        var avqt: Double?
        if ToolLocator.isAvailable("AVQT") {
            let csv = work.appendingPathComponent("avqt.csv")
            // VERIFY flag names against `AVQT --help` for your version.
            if (try? ToolLocator.run("AVQT", ["--reference", reference.path, "--test", test.path, "--output", csv.path])) != nil,
               let text = try? String(contentsOf: csv, encoding: .utf8) {
                let values = text.split(separator: "\n").dropFirst().compactMap { line in
                    line.split(separator: ",").last.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                }
                if !values.isEmpty { avqt = values.reduce(0, +) / Double(values.count) }
            } else {
                notes.append("AVQT is installed but didn't run; check its command-line flags in the log.")
            }
        }
        return Result(scores: scores, avqt: avqt, notes: notes)
    }
}
