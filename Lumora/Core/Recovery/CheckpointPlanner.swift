import Foundation

/// The fixed segment plan of an export. Every export is cut into segments of a few minutes of encoding each, so a
/// failure, crash, quit or power loss loses at most the segments being encoded at that moment. The plan is worked out
/// once and saved in the journal; a resumed export reuses it, so its segments are the same as an uninterrupted run's.
enum CheckpointPlanner {
    /// Tests set this to force a segment length (in output frames).
    nonisolated(unsafe) static var segmentFramesOverride: Int?

    static let prerollMax = 16
    static let minFrames = 48

    struct Input {
        var frames: Int
        var fps: Double
        var pixels: Int                 // output width × height
        var codec: Codec
        var workers: Int
        /// Output frame indices that start a new shot (original frames on a cut).
        var cutStarts: [Int]
        /// For each output frame, the first output frame of its shot (for preroll). Nil = frame 0.
        var shotStart: (Int) -> Int
        /// Measured encoder speed at 1080p (frames per second), when known.
        var measuredFps1080: Double?
    }

    /// A rough encoding speed for this codec at 1080p on one worker, used only to size segments.
    static func guessFps1080(_ c: Codec) -> Double {
        switch c {
        case .hevc: return 120
        case .prores422HQ, .prores4444XQ: return 90
        case .av1: return 12
        case .hevc12: return 6
        case .av1Pro: return 3
        case .vvc: return 2.5
        case .av2: return 0.4
        }
    }

    /// The shortest segment a codec can be joined from without loss (1: no limit beyond the plan's own).
    static func minFrames(for codec: Codec) -> Int { codec == .vvc ? 64 : 1 }

    static func plan(_ i: Input) -> [ExportJournal.PlannedSegment] {
        let n = i.frames
        guard n > 0 else { return [] }
        let fps = max(1, i.fps)
        let speed = max(0.05, (i.measuredFps1080 ?? guessFps1080(i.codec)) * Double(1920 * 1080) / Double(max(1, i.pixels)))
        // About 150 s of wall-clock encoding per segment, clamped to 2–60 s of video and at least 48 frames.
        var target = Int(speed * 150)
        target = min(max(target, Int(2 * fps)), Int(60 * fps))
        target = max(target, minFrames)
        if let o = segmentFramesOverride { target = max(1, o) }
        var count = max(1, Int((Double(n) / Double(target)).rounded(.up)))
        // At least two segments per worker, for load balancing, as long as segments keep their minimum length.
        if segmentFramesOverride == nil { count = max(count, min(2 * max(1, i.workers), n / minFrames)) }
        // VVC: GPAC 26.07 mis-times a VVenC stream joined from segments shorter than one VVenC GOP (32 frames) and
        // drops pictures (measured: 3 × 24 frames packaged as 25; 3 × 32 and longer exact). Keep two GOPs per segment.
        count = max(1, min(count, n / minFrames(for: i.codec)))
        count = max(1, min(count, n))
        var bounds = [0]
        let cuts = Set(i.cutStarts)
        for k in 1..<max(1, count) {
            let ideal = n * k / count
            let window = max(1, n / count / 10)            // snap to a cut within ±10% of a segment
            let snapped = (max(1, ideal - window)...min(n - 1, ideal + window))
                .filter { cuts.contains($0) }
                .min { abs($0 - ideal) < abs($1 - ideal) } ?? ideal
            let minLen = segmentFramesOverride.map { _ in 1 } ?? minFrames / 2
            if snapped > bounds.last! + minLen - 1 && snapped < n { bounds.append(snapped) }
        }
        bounds.append(n)
        return zip(bounds, bounds.dropFirst()).enumerated().map { idx, pair in
            let (a, b) = pair
            let shot = cuts.contains(a) ? a : i.shotStart(a)
            let preroll = a == 0 ? 0 : min(prerollMax, max(0, a - shot))
            return ExportJournal.PlannedSegment(index: idx, start: a, count: b - a, preroll: preroll)
        }
    }
}
