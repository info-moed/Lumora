import Foundation

/// What the person wants from this file, in plain words.
enum Goal: String, CaseIterable, Identifiable, Codable {
    case watchOnTV = "Watch it on my TV", archive = "Archive it (keep the best quality)", saveSpace = "Make it much smaller",
         share = "Share it or play it anywhere", smoother = "Make motion smoother"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .watchOnTV: return "tv"; case .archive: return "archivebox"; case .saveSpace: return "arrow.down.right.and.arrow.up.left"
        case .share: return "square.and.arrow.up"; case .smoother: return "wind"
        }
    }
}

/// One recommended setting with the reason, in the words a beginner would use.
struct Recommendation: Identifiable, Hashable {
    let id = UUID()
    var area: String          // "Look", "HDR", "Motion", "Codec", …
    var value: String
    var why: String
}

/// Everything Lumora would set for this file and goal.
struct RecommendedSettings {
    var items: [Recommendation]
    var look: Look
    var delivery: DeliveryFormat
    var codec: Codec
    var profileName: String
    var planMode: PlanMode
    var budgetHours: Double
    var interpolation: InterpolationSettings.Mode
    var intelligence: MotionIntelligence
    var grainAware: Bool
    var filmTexture: FilmTexture
    var removeBlackBars: Bool
    var headline: String
}

enum Recommender {
    static func recommend(goal: Goal, playsAV1: Bool, descriptor d: SourceDescriptor, color: SourceColor,
                          analysis a: AnalysisResult, profile: ContentProfile?, report: HDRReportCard?,
                          sizes: StreamSizes?, detectedCrop: Bool) -> RecommendedSettings {
        var items: [Recommendation] = []
        let kind = profile?.kind ?? .realLife
        let hdrSource = color.transfer == .pq || color.transfer == .hlg
        let logSource = color.transfer.isCameraLog || color.transfer == .linear
        let filmRate = d.fps < 26
        let anime = kind == .anime || kind == .oldAnime
        let grainy = [.realLifeHeavyGrain, .oldAnime, .lowLightNoisy].contains(kind)

        // Look
        var look: Look
        if logSource {
            look = anime ? .natural : (goal == .share ? .punchy : .natural)
            items.append(.init(area: "Look", value: look.displayName, why: "This is camera log footage; it needs grading. Natural keeps skin and light true to life."))
        } else if let r = report, hdrSource, r.verdict == .conservative || r.verdict == .fakeHDR {
            look = .ripRevive
            items.append(.init(area: "Look", value: "Rip Revive", why: "The HDR on this file is dim (highlights around \(Int(r.p999Nits)) nits). Rip Revive brings them up without touching the colorist's mid-tones."))
        } else {
            look = .original
            items.append(.init(area: "Look", value: "Keep original look", why: hdrSource ? "The HDR is already well graded; Lumora keeps it exactly as mastered." : "Keeps the picture exactly as it is."))
        }

        // HDR / delivery
        var delivery: DeliveryFormat = hdrSource || logSource ? .hdr10 : .sdr
        if !hdrSource && !logSource && goal == .watchOnTV {
            delivery = .hdr10
            if look == .original {
                look = .natural
                // The Look line must state what is applied, not the "keep it as it is" it said before conversion.
                if let i = items.firstIndex(where: { $0.area == "Look" }) {
                    items[i] = .init(area: "Look", value: look.displayName,
                                     why: "Converting to HDR needs a grade; Natural keeps the picture true to the original while rebuilding the highlights.")
                }
            }
            items.append(.init(area: "HDR", value: "Convert to HDR10", why: "Your TV can show brighter highlights than this SDR file has. Lumora rebuilds them; this is optional and can be turned off."))
        } else if goal == .share {
            delivery = hdrSource || logSource ? .dolbyVision84 : .sdr
            items.append(.init(area: "HDR", value: delivery.displayName, why: "Plays well everywhere, including phones and screens without HDR."))
        } else {
            items.append(.init(area: "HDR", value: delivery.displayName, why: delivery == .sdr ? "The source is SDR; keeping it SDR preserves it exactly." : "HDR10 plays on every HDR TV, Apple TV, Plex and Infuse."))
        }

        // Codec, quality and time
        var codec: Codec
        var plan: PlanMode
        var budget = 8.0
        var profileName = "Imperceptible"
        switch goal {
        case .archive:
            codec = .av1; plan = .bestForMac
            items.append(.init(area: "Codec", value: "AV1 (SVT-AV1)", why: "The smallest files that still look identical, and widely supported for the future. Lumora keeps your original too."))
        case .saveSpace:
            codec = playsAV1 ? .av1 : .hevc12; plan = .budget; budget = 10
            items.append(.init(area: "Codec", value: codec.displayName, why: playsAV1 ? "AV1 makes the smallest files. An overnight encode finds the best size." : "Your devices may not play AV1, so archival HEVC instead."))
        case .share:
            codec = .hevc; plan = .fastest; profileName = "Transparent streaming"
            items.append(.init(area: "Codec", value: "HEVC (hardware)", why: "Plays on almost every device and encodes in minutes on the media engine."))
        case .watchOnTV, .smoother:
            codec = playsAV1 ? .av1 : .hevc; plan = .bestForMac
            items.append(.init(area: "Codec", value: codec.displayName, why: playsAV1 ? "Your TV/player handles AV1: smaller files, same picture." : "HEVC plays on every TV and Apple device."))
        }
        // Dolby Vision: keep the colorist's original when nothing is regraded and the codec can carry it.
        if d.isDolbyVision && d.dvProfile != 5 && (goal == .watchOnTV || goal == .archive || goal == .saveSpace) {
            if look == .original && d.scanFix == .none {
                if codec == .av1 {
                    items.append(.init(area: "Dolby Vision", value: "Not kept in AV1",
                                       why: "AV1 files here are HDR10 (every HDR TV plays them). Choose HEVC instead to keep the film's original Dolby Vision."))
                } else {
                    delivery = .dolbyVision81
                    if codec == .hevc { codec = .hevc12 }
                    items.append(.init(area: "Dolby Vision", value: "Keep the original (retimed)",
                                       why: "Carries the colorist's own Dolby Vision, including the trims for different TVs, into the new file."))
                }
            } else {
                items.append(.init(area: "Dolby Vision", value: "Generated fresh",
                                   why: "The picture is being changed, so Lumora writes new Dolby Vision that matches it."))
            }
        }
        items.append(.init(area: "Quality", value: profileName, why: profileName == "Imperceptible" ? "Lumora proves you can't tell it from the source before keeping each part." : "Excellent quality, quick to make."))
        items.append(.init(area: "Time", value: plan.rawValue, why: plan == .budget ? "Uses the night to make the smallest file." : (plan == .fastest ? "Done quickly." : "Stops where waiting longer stops paying off on this Mac.")))

        // Motion
        var interp: InterpolationSettings.Mode = .off
        var intelligence: MotionIntelligence = .eachFrame
        if goal == .smoother {
            interp = filmRate ? .targetFPS(num: 60, den: 1) : .multiply(2)
            intelligence = .perScene
            items.append(.init(area: "Motion", value: filmRate ? "Interpolate to 60 fps" : "Double the frame rate",
                               why: "Smoother motion, with a model chosen per scene and every new frame checked.\(anime ? " Held animation frames are skipped so drawings move smoothly." : "")"))
        } else if kind == .fastMotion && !filmRate {
            interp = .multiply(2); intelligence = .perScene
            items.append(.init(area: "Motion", value: "Double the frame rate", why: "Fast action at \(Int(d.fps.rounded())) fps benefits from smoother motion."))
        } else {
            items.append(.init(area: "Motion", value: "Keep original frame rate",
                               why: filmRate ? "It's a film at \(String(format: "%.3g", d.fps)) fps; interpolating it creates the 'soap opera' look." : "Motion is already smooth."))
        }

        // Grain and clean-up
        var texture = FilmTexture.off
        if grainy {
            items.append(.init(area: "Grain", value: "Grain-aware, with grain synthesis", why: "Keeps the film's grain looking right while making the file much smaller."))
        } else if kind == .realLife, (profile?.grain ?? 1) < 0.0025, filmRate, codec == .av1 || codec == .av1Pro,
                  goal == .archive || goal == .watchOnTV {
            texture = .fine
            items.append(.init(area: "Grain", value: "Restore film texture: fine (optional)", why: "This film looks scrubbed of grain; a light, free film texture often makes it look more natural. Turn off if you prefer it clean."))
        }
        if detectedCrop { items.append(.init(area: "Picture", value: "Remove black bars", why: "Saves space and keeps brightness measurements accurate.")) }
        if d.suggestedScanFix != .none {
            items.append(.init(area: "Picture", value: d.suggestedScanFix.displayName, why: "This source is \(d.suggestedScanFix == .inverseTelecine ? "telecined" : "interlaced"); fixing it first avoids combing and judder."))
        }

        let headline = "\(goal.rawValue): \(look.displayName), \(delivery.displayName), \(codec == .av1 ? "AV1" : codec.displayName), \(profileName.lowercased())"
        return RecommendedSettings(items: items, look: look, delivery: delivery, codec: codec, profileName: profileName,
                                   planMode: plan, budgetHours: budget, interpolation: interp, intelligence: intelligence,
                                   grainAware: grainy, filmTexture: texture, removeBlackBars: detectedCrop, headline: headline)
    }
}
