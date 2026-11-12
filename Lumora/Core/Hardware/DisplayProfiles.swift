import AppKit

/// A screen the picture is graded for: how bright it gets in small highlights (peak) and across the whole screen
/// (sustained, where brightness limiters kick in), and what kind of panel it is.
struct DisplayProfile: Identifiable, Hashable, Codable {
    enum Panel: String, Codable { case miniLED = "mini-LED", oled = "OLED", lcd = "LCD", reference = "reference" }
    var id: String { name }
    var name: String
    var peakNits: Float
    var sustainedNits: Float
    var panel: Panel
    var source: String            // "measured from this Mac", "Apple spec", "typical"

    var summary: String { "\(Int(peakNits)) nits peak, \(Int(sustainedNits)) full-screen, \(panel.rawValue)" }

    /// Devices to grade for. Figures are typical/spec values; Lumora reads the actual Mac screen separately.
    static let devices: [DisplayProfile] = [
        DisplayProfile(name: "iPhone or iPad Pro (recent)", peakNits: 1600, sustainedNits: 1000, panel: .oled, source: "Apple spec"),
        DisplayProfile(name: "OLED TV", peakNits: 900, sustainedNits: 250, panel: .oled, source: "typical"),
        DisplayProfile(name: "Bright OLED TV (2024+)", peakNits: 1500, sustainedNits: 300, panel: .oled, source: "typical"),
        DisplayProfile(name: "Mini-LED TV", peakNits: 2000, sustainedNits: 700, panel: .miniLED, source: "typical"),
        DisplayProfile(name: "Entry HDR TV / monitor", peakNits: 600, sustainedNits: 350, panel: .lcd, source: "typical"),
        DisplayProfile(name: "Pro Display XDR", peakNits: 1600, sustainedNits: 1000, panel: .miniLED, source: "Apple spec")
    ]

    /// Future-proof master: graded for 4000 nits; dynamic metadata lets every screen map it down well.
    static let futureProof = DisplayProfile(name: "Future-proof master (4000 nits)", peakNits: 4000, sustainedNits: 1000,
                                            panel: .reference, source: "mastering standard")
}

enum DisplayInspector {
    /// The screen this window is on, as measured: a reference mode reports its exact scale (1.0 = 100 nits);
    /// known Apple panels use their published figures; anything else is estimated from the HDR headroom macOS reports.
    @MainActor
    static func current(_ screen: NSScreen? = NSScreen.main) -> DisplayProfile? {
        guard let screen else { return nil }
        let name = screen.localizedName
        let reference = screen.maximumReferenceExtendedDynamicRangeColorComponentValue
        let potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        if reference > 1 {
            let peak = Float(reference) * 100
            return DisplayProfile(name: "\(name) (reference mode)", peakNits: peak, sustainedNits: min(peak, 1000),
                                  panel: .reference, source: "measured from this Mac")
        }
        if name.localizedCaseInsensitiveContains("XDR") {
            let builtIn = name.localizedCaseInsensitiveContains("Built-in") || name.localizedCaseInsensitiveContains("Liquid Retina")
            return DisplayProfile(name: builtIn ? "This MacBook Pro's XDR display" : name, peakNits: 1600, sustainedNits: 1000,
                                  panel: .miniLED, source: "Apple spec")
        }
        guard potential > 1.05 else {
            return DisplayProfile(name: "\(name) (SDR only)", peakNits: 100, sustainedNits: 100, panel: .lcd, source: "measured from this Mac")
        }
        // External HDR screen: headroom is relative to SDR white (~200 nits on most HDR monitors).
        let peak = Float(potential) * 200
        return DisplayProfile(name: name, peakNits: min(peak, 4000), sustainedNits: min(peak, 400), panel: .lcd,
                              source: "estimated from macOS HDR headroom")
    }
}

extension AutoPresetEngine {
    /// Adapts a preset to a screen: highlights use the screen's real peak, and bright scenes are held back where a
    /// brightness limiter (OLED especially) would otherwise dim the whole picture unpredictably.
    static func adapt(_ p: PresetCandidate, for display: DisplayProfile, analysis a: AnalysisResult, pop: Bool) -> PresetCandidate {
        var out = p
        if pop && !out.params.passthrough {
            // "Make it pop": use the screen's headroom for highlights, a touch more clarity and color.
            out.params.shoulder = max(out.params.shoulder, display.peakNits >= 1500 ? 2.8 : 2.4)
            out.params.localContrast = min(0.5, out.params.localContrast + 0.06)
            out.params.vibrance = min(0.6, out.params.vibrance + 0.08)
            if out.color.transfer == .pq || out.color.transfer == .hlg {
                out.params.expandHDRSources = true
                out.params.highlightExpansion = max(out.params.highlightExpansion, 2)
            }
        }
        // Brightness-limiter guard: estimate each scene's average light and pull down scenes that would exceed
        // about 45% of what the screen can sustain full-screen.
        let limit = display.sustainedNits * 0.45
        let mid = (display.peakNits > 100 ? 26 : 18) * powf(2, out.params.midGreyStops)
        out.sceneExposures = a.scenes.enumerated().map { i, s in
            let e = p.sceneExposures[safe: i] ?? 0
            let estimatedAverage = mid * powf(2, s.keyStops + e) * 1.6
            return estimatedAverage > limit ? e - log2f(estimatedAverage / limit) * 0.7 : e
        }
        return out
    }
}
