import SwiftUI
import AVKit
import AVFoundation

/// Judge the grade on the TV you'll actually watch on: renders ~15 s around the current position with the current
/// settings (hardware HEVC, HDR10 or HLG) and plays it through AirPlay to an Apple TV.
@MainActor
@Observable
final class AirPlayPreview {
    static let shared = AirPlayPreview()
    var player: AVPlayer?
    var busy = false

    func prepare(_ model: AppModel) {
        guard var job = model.draftJob(), let d = model.descriptor else { return }
        busy = true
        let start = Int(model.previewTime * d.fps)
        job.codec = .hevc
        job.bitDepth = 10
        job.chroma = .c420
        if job.delivery == .dolbyVision81 || job.delivery == .hdr10Plus { job.delivery = .hdr10 }
        job.qualityTarget = nil
        job.quality = 0.85
        job.frameRange = start..<min(d.frameCount, start + Int(d.fps * 15))
        job.outputURL = (try? ScratchManager.jobDirectory("airplay"))?.appendingPathComponent("preview.mov") ?? job.outputURL
        let t = TaskCenter.shared.begin("Preparing AirPlay preview", symbol: "airplayvideo")
        Task {
            do {
                let url = try await ExportEngine().run(job) { _, v in Task { @MainActor in t.progress = v } }
                let p = AVPlayer(url: url)
                p.allowsExternalPlayback = true
                player = p
                TaskCenter.shared.finish(t)
            } catch {
                TaskCenter.shared.finish(t, error: error)
                model.errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}

struct AirPlayPreviewView: View {
    @Environment(AppModel.self) private var model
    @State private var air = AirPlayPreview.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview on your TV").font(Theme.heading(18))
                Spacer()
                RoutePicker().frame(width: 32, height: 24)
            }
            Text("Renders 15 seconds from the current position with your current settings, then plays it. Pick your Apple TV with the AirPlay button to see it on the real screen.")
                .font(Theme.note).foregroundStyle(.secondary)
            if let p = air.player {
                VideoPlayer(player: p).frame(minHeight: 320).onAppear { p.play() }
            } else {
                Button(air.busy ? "Rendering…" : "Render preview") { air.prepare(model) }.disabled(air.busy || model.descriptor == nil)
            }
            if air.player != nil { Button("Render again from the current position") { air.player = nil; air.prepare(model) } }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 460)
    }
}

private struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.isRoutePickerButtonBordered = false
        return v
    }
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
