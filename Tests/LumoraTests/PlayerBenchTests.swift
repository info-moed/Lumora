import XCTest
@testable import Lumora

/// Decode speed of every backend the player picks, measured through the player's own code (probe, selector,
/// backend, pipe or texture). On demand only, with local sample files:
///
///     TEST_RUNNER_LUMORA_PLAYER_BENCH=1 xcodebuild test … -only-testing:LumoraTests/PlayerBenchTests
///
/// It reads ~/Library/Caches/Lumora-Bench/player/enc/ and writes a Markdown table to $TMPDIR/player-bench.md.
final class PlayerBenchTests: XCTestCase {
    func testDecodeSpeedPerBackend() throws {
        guard ProcessInfo.processInfo.environment["LUMORA_PLAYER_BENCH"] == "1" else {
            throw XCTSkip("Benchmarks run on demand: TEST_RUNNER_LUMORA_PLAYER_BENCH=1")
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Lumora-Bench/player/enc")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { !["log"].contains($0.pathExtension) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw XCTSkip("no sample files in \(dir.path)") }
        if ProcessInfo.processInfo.environment["LUMORA_PLAYER_BENCH_NICE"] != "0" {
            setpriority(PRIO_PROCESS, 0, 15)          // a shared Mac: decoders inherit the low priority
        }
        var rows = ["| File | Codec | Decoder | HW | Frames | fps | first frame s | steady fps | CPU s/frame |", "|---|---|---|---|---|---|---|---|---|"]
        let only = ProcessInfo.processInfo.environment["LUMORA_PLAYER_BENCH_ONLY"]
        for url in files where only.map({ url.lastPathComponent.contains($0) }) ?? true {
            do {
                let info = try MediaProbe.probe(url)
                let choice = try DecoderSelector.choose(info, caps: .current)
                let b = try PlayerBackends.make(info: info, choice: choice, settings: PlayerSettings(), poolCapacity: 6)
                let ru0 = Self.childCPU()
                let t0 = CFAbsoluteTimeGetCurrent()
                try b.start(atFrame: 0)
                var n = 0
                var first = 0.0
                while n < 240, try b.next() != nil {
                    n += 1
                    if n == 1 { first = CFAbsoluteTimeGetCurrent() - t0 }
                }
                let dt = CFAbsoluteTimeGetCurrent() - t0
                let steady = n > 1 ? Double(n - 1) / max(1e-6, dt - first) : 0
                b.stop()
                let cpu = Self.childCPU() - ru0
                let v = info.video
                rows.append("| \(url.lastPathComponent) | \(v.codec) \(v.bitDepth)-bit \(v.chroma) \(v.width)×\(v.height) | \(b.choice.tool) | \(b.choice.hardware ? "yes" : "no") | \(n) | "
                            + String(format: "%.1f | %.3f | %.1f", Double(n) / dt, first, steady) + " | " + (cpu > 0 ? String(format: "%.3f", cpu / Double(max(1, n))) : "in-process") + " |")
            } catch {
                rows.append("| \(url.lastPathComponent) | – | \((error as? LocalizedError)?.errorDescription ?? "\(error)") | | | | | | |")
            }
        }
        let table = rows.joined(separator: "\n")
        try table.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("player-bench.md"), atomically: true, encoding: .utf8)
        print(table)
    }

    /// User + system CPU seconds of reaped child processes.
    static func childCPU() -> Double {
        var u = rusage()
        getrusage(RUSAGE_CHILDREN, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
}
