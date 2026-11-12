import Foundation

/// Finds letterbox / pillarbox bars so they don't skew brightness analysis or waste bits in the encode.
enum CropDetector {
    static func detect(_ d: SourceDescriptor) async throws -> SIMD4<Float> {
        let src = try await d.makeFrameSource()
        let renderer = GradeRenderer()
        var rows: [UInt32] = [], cols: [UInt32] = []
        for f in [0.1, 0.22, 0.35, 0.5, 0.63, 0.77, 0.9].map({ Int(Double(d.frameCount) * $0) }) {
            try src.start(at: f, count: 1)
            if let frame = try src.nextFrame() { renderer.rowColMax(frame.texture, rows: &rows, cols: &cols) }
        }
        src.cancel()
        // The bars' level is the darkest row *or* column maximum: with pillarbox bars every row crosses the
        // picture, so only the columns see the bars.
        guard rows.count > 16, cols.count > 16, let rowFloor = rows.min(), let colFloor = cols.min() else { return UniformBuilder.fullFrame }
        let floor = min(rowFloor, colFloor)
        let threshold = floor + UInt32(0.04 * 65535)
        func span(_ v: [UInt32]) -> (Int, Int) {
            let first = v.firstIndex { $0 > threshold } ?? 0
            let last = v.lastIndex { $0 > threshold } ?? (v.count - 1)
            return (first, last + 1)
        }
        var (y0, y1) = span(rows), (x0, x1) = span(cols)
        let h = rows.count, w = cols.count
        // Ignore tiny edges (< 0.5%) and implausible crops (< 50% of the frame).
        if Float(y0) < Float(h) * 0.005 { y0 = 0 }
        if Float(h - y1) < Float(h) * 0.005 { y1 = h }
        if Float(x0) < Float(w) * 0.005 { x0 = 0 }
        if Float(w - x1) < Float(w) * 0.005 { x1 = w }
        guard y1 - y0 > h / 2, x1 - x0 > w / 2 else { return UniformBuilder.fullFrame }
        y0 &= ~1; x0 &= ~1
        let ch = (y1 - y0) & ~1, cw = (x1 - x0) & ~1
        return SIMD4<Float>(Float(x0) / Float(w), Float(y0) / Float(h), Float(cw) / Float(w), Float(ch) / Float(h))
    }
}
