import Foundation

/// Answers "what should I export?" in plain English, for where the video is going.
enum FormatAdvisor {
    enum Destination: String, CaseIterable, Identifiable {
        case youtube, socialPhone, appleDevices, homeTheater, client, broadcast, streamingDelivery, archive, smallestFile
        var id: String { rawValue }
        var title: String {
            switch self {
            case .youtube: return "YouTube"
            case .socialPhone: return "Instagram, TikTok or phones"
            case .appleDevices: return "iPhone, iPad, Mac, Apple TV"
            case .homeTheater: return "My home theater (Plex, Infuse, TV)"
            case .client: return "Sending to a client or someone who isn't technical"
            case .broadcast: return "TV broadcast"
            case .streamingDelivery: return "Delivering to a streaming service or distributor"
            case .archive: return "Archive / master copy"
            case .smallestFile: return "Smallest file at good quality"
            }
        }
    }

    struct Advice {
        var delivery: DeliveryFormat
        var codec: Codec
        var bitDepth: Int
        var peakNits: Float
        var look: Look?
        var headline: String          // one sentence
        var why: [String]             // plain-English reasons
        var alsoMake: String?         // a second version worth exporting
        var watchOut: [String]
    }

    static func advise(for dest: Destination, source: SourceDescriptor?, color: SourceColor?,
                       report: HDRReportCard?) -> Advice {
        let sourceIsSDR = color?.transfer.isSDR ?? false
        let sourceIsLog = color?.transfer.isCameraLog ?? false
        var watch: [String] = []
        if sourceIsSDR {
            watch.append("Your source is SDR. Lumora can make convincing HDR, but detail that was already blown out to pure white can't come back.")
        }
        if let r = report, r.verdict == .fakeHDR || r.verdict == .conservative {
            watch.append("This file's HDR is dim (\(r.verdict.rawValue.lowercased())). The Rip Revive preset fixes that.")
        }
        if color?.gamut.isVerified == false {
            watch.append("Apple Log 2 colour is approximate until its exact gamut numbers are added (see README).")
        }

        switch dest {
        case .youtube:
            return Advice(delivery: .hdr10, codec: .hevc, bitDepth: 10, peakNits: 1000, look: sourceIsLog ? .punchy : nil,
                          headline: "Upload HDR10 HEVC at 1000 nits.",
                          why: ["YouTube accepts HDR10 and makes the SDR version for viewers without HDR automatically.",
                                "1000 nits is what most HDR TVs and phones can actually show, so nothing gets clipped.",
                                "HEVC exports fast on your Mac's media engine and keeps quality high for YouTube to re-encode."],
                          alsoMake: "A SDR Rec.709 version if you want full control over how non-HDR viewers see it.",
                          watchOut: watch)
        case .socialPhone:
            return Advice(delivery: .dolbyVision84, codec: .hevc, bitDepth: 10, peakNits: 1000, look: .punchy,
                          headline: "Export Dolby Vision 8.4 (HLG) HEVC — the same format iPhones record.",
                          why: ["Instagram and phones handle iPhone-style HDR best because it's what they see most.",
                                "HLG still looks reasonable on non-HDR phones, so nobody gets a washed-out picture.",
                                "Punchy reads well on small screens."],
                          alsoMake: "An SDR version for TikTok or apps that don't show HDR well.",
                          watchOut: watch + ["Social apps re-compress heavily; very fine detail and grain get softened regardless."])
        case .appleDevices:
            return Advice(delivery: .dolbyVision84, codec: .hevc, bitDepth: 10, peakNits: 1000, look: nil,
                          headline: "Dolby Vision 8.4 (HLG) HEVC plays perfectly across Apple devices.",
                          why: ["It's Apple's native HDR format, so Photos, AirDrop and Apple TV handle it with no fuss.",
                                "Falls back gracefully on older or non-HDR screens."],
                          alsoMake: nil, watchOut: watch)
        case .homeTheater:
            // Rip Revive only for HDR that measured dim; well-graded HDR and SDR keep the current look.
            let dim = report.map { $0.verdict == .conservative || $0.verdict == .fakeHDR } ?? false
            return Advice(delivery: .dolbyVision81, codec: .hevc, bitDepth: 10, peakNits: 1000, look: dim ? .ripRevive : nil,
                          headline: "HDR10 + Dolby Vision 8.1 in HEVC, in an MKV with all audio and subtitles kept.",
                          why: ["Every HDR TV plays the HDR10 layer; Dolby Vision TVs (LG, Sony, TCL, Apple TV 4K) get scene-by-scene tuning on top.",
                                "MKV keeps every audio track and subtitle from your original.",
                                "HEVC is what Plex, Infuse and smart TVs decode most reliably."],
                          alsoMake: "AV1 10-bit HDR10 if all your devices support AV1 — about 30% smaller files.",
                          watchOut: watch)
        case .client:
            return Advice(delivery: .sdr, codec: .hevc, bitDepth: 10, peakNits: 100, look: .natural,
                          headline: "Send SDR Rec.709. It looks the same on every screen.",
                          why: ["HDR files can look dark or washed out on a laptop or office monitor that isn't set up for HDR.",
                                "SDR removes the guesswork — what you approved is what they see."],
                          alsoMake: "An HDR10 version labelled “for HDR TVs” if they'll present on a big screen.",
                          watchOut: watch)
        case .broadcast:
            return Advice(delivery: .hlg, codec: .prores422HQ, bitDepth: 10, peakNits: 1000, look: .natural,
                          headline: "HLG in ProRes 422 HQ — the broadcast HDR standard.",
                          why: ["Broadcasters use HLG because one signal works on both HDR and regular TVs.",
                                "ProRes 422 HQ is the delivery codec most broadcast workflows ask for."],
                          alsoMake: nil, watchOut: watch + ["Always check the broadcaster's delivery spec sheet; it overrides general advice."])
        case .streamingDelivery:
            return Advice(delivery: .hdr10, codec: .prores4444XQ, bitDepth: 12, peakNits: 1000, look: .natural,
                          headline: "12-bit ProRes 4444 XQ, PQ, 1000 nits, plus an SDR version.",
                          why: ["Distributors want a top-quality master they can re-encode themselves.",
                                "12-bit keeps the smoothest gradients for their encoders.",
                                "Most services also require a matching SDR deliverable."],
                          alsoMake: "SDR Rec.709 ProRes 422 HQ.",
                          watchOut: watch + ["Professional delivery usually needs a colourist's QC and, for Dolby Vision, Dolby-certified tools. Lumora gets you close; it doesn't replace that sign-off."])
        case .archive:
            return Advice(delivery: .hdr10, codec: .prores4444XQ, bitDepth: 12, peakNits: 1000, look: nil,
                          headline: "12-bit ProRes 4444 XQ, and keep your original camera files too.",
                          why: ["ProRes 4444 XQ is near-lossless and every editor opens it, now and in ten years.",
                                "Your original log/RAW files let you re-grade later as screens get brighter."],
                          alsoMake: nil, watchOut: watch + ["Expect roughly 1–2 GB per minute at 4K."])
        case .smallestFile:
            return Advice(delivery: .hdr10, codec: .av1, bitDepth: 10, peakNits: 1000, look: nil,
                          headline: "AV1 10-bit HDR10 — the best size-to-quality that plays on modern devices.",
                          why: ["AV1 is about 30% smaller than HEVC at the same quality.",
                                "M3-and-newer Macs, recent iPhones, and most 2021+ TVs decode it in hardware."],
                          alsoMake: "VVC (H.266) or AV2 only if you're experimenting: they're smaller still, but almost nothing plays them yet.",
                          watchOut: watch + ["Encoding AV1 is much slower than HEVC because it runs on the CPU."])
        }
    }
}
