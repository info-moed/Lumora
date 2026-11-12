import Foundation

/// A plain-English health check for any HDR (or SDR) file, including personal disc rips.
/// Measured from the source signal itself, before any Lumora grading.
struct HDRReportCard: Codable, Hashable {
    var title: String
    var format: String
    var medianNits: Float
    var p99Nits: Float
    var p999Nits: Float          // "where the real highlights live"
    var estimatedPeakNits: Float
    var shareAbove203: Float     // share of pixels brighter than HDR reference white
    var shareAbove1000: Float
    var blackFloorNits: Float
    var verdict: Verdict
    var findings: [String]       // plain-English bullet points
    var suggestion: String

    enum Verdict: String, Codable {
        case vivid = "Vivid, punchy HDR"
        case balanced = "Well-balanced HDR"
        case conservative = "Conservative HDR"
        case fakeHDR = "Basically SDR in an HDR wrapper"
        case sdr = "SDR video"
    }

    /// Converts analysis stops back to source nits (PQ decode maps nits/144 -> scene linear; 0.18 * 2^s * 144).
    private static func nits(_ stop: Float) -> Float { 25.92 * powf(2, stop) }

    static func make(title: String, descriptor d: SourceDescriptor, color: SourceColor,
                     analysis a: AnalysisResult) -> HDRReportCard {
        let isHDR = color.transfer == .pq || color.transfer == .hlg
        let h = a.globalHistogram
        let p50 = nits(Histogram.percentileStop(h, 0.5))
        let p99 = nits(Histogram.percentileStop(h, 0.99))
        let p999 = nits(Histogram.percentileStop(h, 0.999))
        let peak = min(10000, nits(Histogram.percentileStop(h, 0.99999)))
        let floor = nits(Histogram.percentileStop(h, 0.005))
        let above203 = Histogram.fraction(h, aboveStop: log2f(203 / 25.92))
        let above1000 = Histogram.fraction(h, aboveStop: log2f(1000 / 25.92))

        var findings: [String] = []
        let verdict: Verdict
        if !isHDR {
            verdict = .sdr
            findings.append("This is standard (SDR) video, so it has no HDR highlights to begin with.")
        } else if p999 < 220 {
            verdict = .fakeHDR
            findings.append("Even the brightest parts barely pass normal SDR white (~\(Int(p999)) nits). It's HDR on the label only.")
        } else if p999 < 450 {
            verdict = .conservative
            findings.append("Highlights top out around \(Int(p999)) nits — your TV can show much brighter, so it can look dim or flat.")
        } else if above1000 > 0.002 || p999 > 900 {
            verdict = .vivid
            findings.append("Real highlight punch: the brightest details reach roughly \(Int(p999)) nits.")
        } else {
            verdict = .balanced
            findings.append("Bright highlights around \(Int(p999)) nits with a natural overall level.")
        }
        if isHDR {
            if p50 < 8 { findings.append("Most of the picture sits very dark (typical level ~\(Int(p50)) nits) — may look murky in a bright room.") }
            if p50 > 60 { findings.append("Overall picture is bright (typical level ~\(Int(p50)) nits) — may cause TV dimming (ABL).") }
            if floor > 0.3 { findings.append("Blacks look lifted (~\(String(format: "%.2f", floor)) nits) — less depth on OLED screens.") }
            if d.isDolbyVision { findings.append("Has Dolby Vision metadata; Lumora reads the HDR10 base layer.") }
        }
        let suggestion: String
        switch verdict {
        case .fakeHDR, .conservative:
            suggestion = "Try the “Rip Revive” preset: it expands highlights toward 1000 nits and adds clarity while keeping skin tones natural."
        case .sdr:
            suggestion = "Convert SDR → HDR with the Natural or Punchy preset; Lumora rebuilds highlights above the old white point."
        case .balanced:
            suggestion = "Already good. For extra pop, Punchy adds clarity and color without changing the brightness design."
        case .vivid:
            suggestion = "Leave the HDR as is. If you re-encode, use Natural with highlight expansion off."
        }
        return HDRReportCard(title: title, format: color.name, medianNits: p50, p99Nits: p99, p999Nits: p999,
                             estimatedPeakNits: peak, shareAbove203: above203, shareAbove1000: above1000,
                             blackFloorNits: floor, verdict: verdict, findings: findings, suggestion: suggestion)
    }
}
