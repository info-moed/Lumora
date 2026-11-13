import Foundation

/// Where a source is damaged, in frames and seconds: from the quick check on open, the full scan, or decode errors
/// met during analysis or a render.
struct DamageMap: Codable, Hashable {
    struct Span: Codable, Hashable {
        var start: Int                 // first frame
        var count: Int
        var kind: Kind
        var note: String = ""
        enum Kind: String, Codable { case missing, concealed, unreadable }
        var range: Range<Int> { start..<(start + count) }
    }

    var spans: [Span] = []
    var truncatedAtSeconds: Double?    // the video data ends here
    var claimedSeconds: Double?        // what the container says
    var fps: Double = 24
    var decoderMessages: [String] = []

    var isEmpty: Bool { spans.isEmpty && truncatedAtSeconds == nil }
    var damagedFrames: Int { spans.reduce(0) { $0 + $1.count } }
    var missingFrames: [Int] { spans.filter { $0.kind == .missing }.flatMap { Array($0.range) } }

    /// Neighboring spans (within a second) count as one place.
    var places: [Span] {
        var out: [Span] = []
        for s in spans.sorted(by: { $0.start < $1.start }) {
            if var last = out.last, s.start - (last.start + last.count) <= Int(fps) {
                last.count = s.start + s.count - last.start
                out[out.count - 1] = last
            } else { out.append(s) }
        }
        return out
    }

    mutating func add(_ s: Span) {
        if let i = spans.firstIndex(where: { $0.kind == s.kind && $0.start + $0.count == s.start }) {
            spans[i].count += s.count
        } else if !spans.contains(where: { $0.range.overlaps(s.range) && $0.kind == s.kind }) {
            spans.append(s)
        }
        spans.sort { $0.start < $1.start }
    }

    func seconds(_ frame: Int) -> Double { Double(frame) / max(1, fps) }

    /// "2 frames at 0:01.9–0:02.0, and 1 more place".
    var summary: String {
        if spans.isEmpty, let t = truncatedAtSeconds {
            return "Cut short: stops at \(FailureText.time(t, precise: true))" + (claimedSeconds.map { " of \(FailureText.time($0, precise: true))" } ?? "")
        }
        let p = places
        guard let first = p.first else { return "File check: OK" }
        let n = damagedFrames
        var s = "Damaged: \(n) frame\(n == 1 ? "" : "s") at \(FailureText.time(seconds(first.start), precise: true))"
        if first.count > 1 { s += "–\(FailureText.time(seconds(first.start + first.count - 1), precise: true))" }
        if p.count > 1 { s += ", and \(p.count - 1) more place\(p.count == 2 ? "" : "s")" }
        if let t = truncatedAtSeconds { s += "; cut short at \(FailureText.time(t, precise: true))" }
        return s
    }
}
