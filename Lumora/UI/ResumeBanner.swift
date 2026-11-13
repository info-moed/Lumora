import SwiftUI

/// At launch and after a failure: "An export of “clip – Natural – HDR10.mkv” stopped at 63% (Lumora quit
/// unexpectedly). [Resume from 63%] [Start over] [Discard]". Simple mode shows the main button and "More".
struct ResumeBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.progress == nil, let offer = model.resumeOffers.first {
            ResumeBannerContent(offer: offer, simple: model.simpleMode, more: model.resumeOffers.count - 1,
                                resume: { model.resume(offer) }, startOver: { model.startOver(offer) },
                                discard: { model.discard(offer) }, details: { model.renderFailure = offer.report })
        }
    }
}

struct ResumeBannerContent: View {
    let offer: ResumeOffer
    let simple: Bool
    var more = 0
    var resume: () -> Void = {}
    var startOver: () -> Void = {}
    var discard: () -> Void = {}
    var details: () -> Void = {}

    private var resumeLabel: String {
        if offer.onlyDeliveryLeft { return "Save again" }
        return offer.percent > 0 ? "Resume from \(offer.percent)%" : "Try again"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle").font(.system(size: 20)).foregroundStyle(Theme.signal)
            VStack(alignment: .leading, spacing: 2) {
                Text("An export of “\(offer.journal.outputName)” stopped at \(offer.percent)% (\(offer.reasonText)).")
                    .font(Theme.body.weight(.semibold)).lineLimit(2)
                Text(offer.onlyDeliveryLeft ? "The finished video is saved; only saving it to your folder is left."
                     : "Saved \(offer.savedDate). Resuming encodes only the missing part"
                        + (more > 0 ? " · \(more) more saved export\(more == 1 ? "" : "s") in Activity" : "") + ".")
                    .font(Theme.note).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if simple {
                Menu("More") {
                    Button("Start over", action: startOver)
                    Button("Discard saved progress", action: discard)
                    Button("Details…", action: details)
                }
                .fixedSize()
            } else {
                Button("Details…", action: details).buttonStyle(.link)
                Button("Discard", action: discard)
                Button("Start over", action: startOver)
            }
            Button(resumeLabel, action: resume).buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.rail))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }
}

/// The Export sheet's row: "Resume from 63% (saved Nov 12, 4:41 PM)", on by default when saved progress matches.
struct ResumeOfferRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        if let offer = model.resumeOfferForOpenFile {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Resume from \(offer.percent)% (saved \(offer.savedDate))", isOn: $model.resumeSavedProgress)
                Text("Used when the settings match the saved export; otherwise Lumora starts over.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings › Storage: what saved progress uses, with a way to discard it.
struct SavedProgressRow: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let offers = model.resumeOffers
        let bytes = offers.reduce(Int64(0)) { $0 + $1.bytes }
        LabeledContent("Saved progress") {
            HStack {
                Text(offers.isEmpty ? "None" : "\(offers.count) export\(offers.count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                if !offers.isEmpty { Button("Discard all") { model.discardAllSavedProgress() } }
            }
        }
        .onAppear { model.refreshResumeOffers() }
        Text("Exports that stopped keep their finished parts for 14 days so they can resume. The oldest go first when they would take more than a quarter of the free space.")
            .font(Theme.note).foregroundStyle(.secondary)
    }
}
