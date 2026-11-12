import Foundation

/// Learns, on your Mac, which encoder setting reaches a VMAF target for a given kind of shot, so each new chunk
/// starts close to the answer and needs fewer trial encodes. Ridge regression over a handful of shot features;
/// samples persist between sessions in Application Support.
final class QualityPredictor: @unchecked Sendable {
    static let shared = QualityPredictor()

    struct Sample: Codable { var x: [Double]; var y: Double }
    private var samples: [String: [Sample]] = [:]
    private let lock = NSLock()
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("quality-predictor.json")
    }()

    private init() {
        if let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode([String: [Sample]].self, from: d) { samples = s }
    }

    /// Features of a chunk: brightness design, range, faces, interpolated share, resolution, content kind, target.
    static func features(scene: SceneStats, interpolatedShare: Double, pixels: Int, kind: ContentKind, target: Double) -> [Double] {
        var x: [Double] = [1, Double(scene.keyStops), Double(scene.p995 - scene.p005), Double(scene.skinFraction),
                           interpolatedShare, log2(Double(pixels) / 2_073_600), target - 95]
        for k in ContentKind.allCases { x.append(k == kind ? 1 : 0) }
        return x
    }

    func predict(codecKey: String, x: [Double]) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let s = samples[codecKey], s.count >= 12, let w = solve(s) else { return nil }
        return zip(w, x).reduce(0) { $0 + $1.0 * $1.1 }
    }

    func record(codecKey: String, x: [Double], level: Double) {
        lock.lock()
        samples[codecKey, default: []].append(Sample(x: x, y: level))
        if samples[codecKey]!.count > 3000 { samples[codecKey]!.removeFirst(500) }
        let snapshot = samples
        lock.unlock()
        if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url) }
    }

    var sampleCounts: [String: Int] { lock.lock(); defer { lock.unlock() }; return samples.mapValues(\.count) }

    /// w = (XᵀX + λI)⁻¹ Xᵀy by Gaussian elimination (n ≈ 15).
    private func solve(_ s: [Sample]) -> [Double]? {
        let n = s[0].x.count
        var a = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
        for sm in s where sm.x.count == n {
            for i in 0..<n {
                for j in 0..<n { a[i][j] += sm.x[i] * sm.x[j] }
                a[i][n] += sm.x[i] * sm.y
            }
        }
        for i in 1..<n { a[i][i] += 0.5 }        // ridge (bias term unregularised)
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[p][c]) > 1e-9 else { return nil }
            a.swapAt(c, p)
            for r in 0..<n where r != c {
                let f = a[r][c] / a[c][c]
                for k in c...n { a[r][k] -= f * a[c][k] }
            }
        }
        return (0..<n).map { a[$0][n] / a[$0][$0] }
    }
}
