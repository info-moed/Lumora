import Foundation

struct EncoderSpec: Codable {
    var binary: String
    var input: String          // "stdin" or "fifo"
    var inputArg: String
    var ext: String
    var preset: String
    var qualityBest: Double
    var qualityWorst: Double
    var args: [String]
    var hdrArgs: [String]
    var colorNames: [String: [String: String]]
    var tunes: [String: [String]]? = nil

    /// Quality 0...1 (1 = best) mapped onto the encoder's CRF/QP scale.
    func qualityValue(_ q: Float) -> String {
        String(Int((qualityWorst + (qualityBest - qualityWorst) * Double(q)).rounded()))
    }

    func render(_ values: [String: String], hdr: Bool, tune: String = "default") -> [String] {
        (args + (hdr ? hdrArgs : []) + (tunes?[tune] ?? [])).map { arg in
            var a = arg
            for (k, v) in values { a = a.replacingOccurrences(of: "{\(k)}", with: v) }
            return a
        }
    }
}

final class EncoderCatalog {
    static let shared = EncoderCatalog()
    private var specs: [String: EncoderSpec] = [:]

    private init() {
        guard let url = Bundle.main.url(forResource: "encoders", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (key, value) in obj where !key.hasPrefix("_") {
            if let d = try? JSONSerialization.data(withJSONObject: value),
               let s = try? JSONDecoder().decode(EncoderSpec.self, from: d) { specs[key] = s }
        }
    }

    func spec(for key: String) -> EncoderSpec? { specs[key] }
}
