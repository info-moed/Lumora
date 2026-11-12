import Foundation

struct PresetCandidate: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var look: Look
    var color: SourceColor
    var params: GradeParams
    var sceneExposures: [Float]   // per-scene auto exposure, in stops
    var reason: String
    var recommended = false
}

/// Turns detection + analysis into a ranked set of ready-to-use presets.
enum AutoPresetEngine {
    static func generate(colors: [SourceColor], analysis a: AnalysisResult, report: HDRReportCard?) -> [PresetCandidate] {
        // Every plausible interpretation gets presets, so an uncertain detection (Apple Log vs Apple Log 2)
        // is resolved by simply looking at both.
        let plausible = colors.filter { $0.confidence >= 0.25 }.prefix(2)
        let isHDRSource = colors.first.map { $0.transfer == .pq || $0.transfer == .hlg } ?? false
        var looks: [Look] = [.natural, .punchy, .superPunchy, .cinematic, .brightClean, .moody]
        if isHDRSource { looks.insert(.ripRevive, at: 0) }
        // Finished HDR/SDR masters can be kept exactly as graded (interpolate / upscale / re-encode only).
        let displayReferred = colors.first.map { [.pq, .hlg, .bt1886, .sRGB].contains($0.transfer) } ?? false
        if displayReferred { looks.insert(.original, at: 0) }

        var out: [PresetCandidate] = []
        for color in plausible {
            for look in looks {
                var p = look.params
                let range = a.globalP995 - a.globalP005
                if range > 11 { p.contrast *= 0.93; p.shoulder *= 0.9 }      // very wide range: soften
                if range < 7 { p.contrast *= 1.05 }                            // flat scene: firm up
                if a.skinFraction > 0.06 { p.skinProtect = max(p.skinProtect, 0.9); p.vibrance *= 0.85 }
                if a.avgChroma < 0.04 { p.vibrance += 0.08 }                   // muted footage: a bit more colour
                if isHDRSource && look != .ripRevive { p.expandHDRSources = false }
                if look == .original { p = look.params }

                // Exposure: finished HDR/SDR masters keep their exposure; log/RAW gets auto exposure.
                let autoExpose = color.transfer.isCameraLog || color.transfer == .linear
                let targetKey: Float = -1.2                                    // typical well-exposed scene
                let global = autoExpose ? max(-3, min(3, (targetKey - a.globalKey) * 0.8)) : 0
                let scenes = a.scenes.map { s -> Float in
                    guard autoExpose else { return 0 }
                    let rel = max(-1.5, min(1.5, -(s.keyStops - a.globalKey)))
                    var e = global + rel * look.sceneNormalization
                    if s.p995 + e > 5.5 { e -= (s.p995 + e - 5.5) * 0.5 }      // protect hot highlights
                    return e
                }
                out.append(PresetCandidate(name: plausible.count > 1 ? "\(look.displayName) · \(color.name)" : look.displayName,
                                           look: look, color: color, params: p, sceneExposures: scenes,
                                           reason: reason(look: look, color: color, a: a, report: report)))
            }
        }
        // Recommend one: people-heavy -> Natural; scenery/products -> Punchy; dim HDR rip -> Rip Revive.
        let pick: Look
        if let r = report, r.verdict == .conservative || r.verdict == .fakeHDR { pick = .ripRevive }
        else if a.skinFraction > 0.08 { pick = .natural }
        else { pick = .punchy }
        if let i = out.firstIndex(where: { $0.look == pick }) { out[i].recommended = true }
        return out
    }

    private static func reason(look: Look, color: SourceColor, a: AnalysisResult, report: HDRReportCard?) -> String {
        var bits = ["\(color.name)", "\(a.scenes.count) scene\(a.scenes.count == 1 ? "" : "s")"]
        switch look {
        case .original: bits.append("no regrade: exactly as mastered, for interpolating or re-encoding")
        case .natural: bits.append("true-to-life contrast, skin first")
        case .punchy: bits.append("deeper blacks, brighter highlights, more clarity")
        case .superPunchy: bits.append("maximum pop, skin still protected")
        case .cinematic: bits.append("softer highlights, film-like roll-off")
        case .brightClean: bits.append("airy, lifted mid-tones")
        case .moody: bits.append("darker, denser, restrained colour")
        case .ripRevive: bits.append("rebuilds dim HDR highlights" + (report.map { " (now ~\(Int($0.p999Nits)) nits)" } ?? ""))
        }
        return bits.joined(separator: " · ")
    }
}
