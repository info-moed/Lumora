import SwiftUI
import MetalKit
import AppKit

/// Original vs interpolated (or any two versions), synced in time and shown in real HDR side by side.
/// Each side keeps its own colour interpretation, so an SDR original and an HDR interpolated file both
/// display correctly. Step through the interpolated file frame by frame and see which frames are generated.
@MainActor
@Observable
final class CompareModel {
    enum Layout: String, CaseIterable { case sideBySide = "Side by side", wipe = "Wipe" }

    var a: SourceDescriptor?, b: SourceDescriptor?
    var colorsA: [SourceColor] = [], colorsB: [SourceColor] = []
    var colorA: SourceColor?, colorB: SourceColor?
    var analysisA: AnalysisResult?
    var frameA: DecodedFrame?, frameB: DecodedFrame?
    var indexB = 0
    var layout: Layout = .sideBySide
    var wipe: Float = 0.5
    var target: OutputTarget = .hdr10_1000
    var report: InterpolationEvaluator.Report?
    var benchmark: InterpolationEvaluator.Benchmark?
    var fileScores: FileMetrics.Result?
    var status = "Drop the original on the left and the interpolated file on the right."
    var progress: Double?
    var token = 0
    private var task: Task<Void, Never>?

    var frameLabel: String {
        guard let a, let b else { return "" }
        let posA = Double(indexB) / b.fps * a.fps
        let frac = posA - posA.rounded(.down)
        let kind = (frac < 0.02 || frac > 0.98) ? "original frame" : String(format: "generated frame (t = %.2f)", frac)
        return "Interpolated frame \(indexB) · \(String(format: "%.3f", Double(indexB) / b.fps)) s · \(kind)"
    }

    func load(_ url: URL, left: Bool, analysis: AnalysisResult? = nil) {
        run("Opening \(url.lastPathComponent)") { [self] in
            let (d, colors) = try await SourceInspector.inspect(url)
            if left { a = d; colorsA = colors; colorA = colors.first; analysisA = analysis }
            else { b = d; colorsB = colors; colorB = colors.first }
            report = nil
            await seek(to: indexB)
        }
    }

    /// Loads both sides in one go (used right after an export: source on the left, result on the right).
    func loadPair(original: URL?, processed: URL?, analysis: AnalysisResult?) {
        run("Opening both versions") { [self] in
            if let original {
                let (d, colors) = try await SourceInspector.inspect(original)
                a = d; colorsA = colors; colorA = colors.first; analysisA = analysis
            }
            if let processed {
                let (d, colors) = try await SourceInspector.inspect(processed)
                b = d; colorsB = colors; colorB = colors.first
            }
            report = nil
            await seek(to: 0)
            status = "Ready. Step with ← → or grade the interpolation."
        }
    }

    func seek(to index: Int) async {
        guard let b else {
            if let a { frameA = try? await decode(a, Int(0)) }
            token += 1
            return
        }
        indexB = max(0, min(b.frameCount - 1, index))
        let seconds = Double(indexB) / b.fps
        frameB = try? await decode(b, indexB)
        if let a { frameA = try? await decode(a, Int((seconds * a.fps).rounded())) }
        token += 1
    }

    private func decode(_ d: SourceDescriptor, _ i: Int) async throws -> DecodedFrame? {
        let s = try await d.makeFrameSource()
        try s.start(at: max(0, min(d.frameCount - 1, i)), count: 1)
        defer { s.cancel() }
        return try s.nextFrame()
    }

    func step(_ delta: Int) { Task { await seek(to: indexB + delta) } }

    func evaluate() {
        guard let a, let b, let ca = colorA, let cb = colorB else { return }
        run("Grading the interpolation against the original") { [self] in
            report = try await InterpolationEvaluator.evaluate(original: a, originalColor: ca, analysis: analysisA,
                                                               interpolated: b, interpolatedColor: cb) { v in
                Task { @MainActor in self.progress = v }
            }
            status = report.map { "\($0.verdict) · \($0.score)/100" } ?? ""
        }
    }

    /// Every installed metric (and AVQT) on the two files — for versions with the same frame rate, like a re-encode.
    func runPerceptualScores() {
        guard let a, let b, let cb = colorB else { return }
        guard abs(a.fps - b.fps) < 0.01 else {
            status = "The frame rates differ, so frames don't pair up. Use “Grade the interpolated file” instead."
            return
        }
        let hdr = cb.transfer == .pq || cb.transfer == .hlg
        run("Scoring with every installed metric") { [self] in
            fileScores = try await FileMetrics.measure(reference: a.url, test: b.url, hdr: hdr, width: b.width, height: b.height,
                                                       frames: b.frameCount, rate: (b.fpsNum, b.fpsDen),
                                                       offsetSeconds: max(0, report?.offsetSeconds ?? 0))
            status = "Scored with \(fileScores?.scores.pooled.count ?? 0) metrics" + (fileScores?.avqt != nil ? " plus AVQT" : "")
        }
    }

    func runBenchmark(apply: @escaping (String?, Float) -> Void) {
        guard let a, let ca = colorA else { return }
        run("Benchmarking models on held-out real frames") { [self] in
            let analysis: AnalysisResult
            if let existing = analysisA { analysis = existing } else {
                analysis = try await SceneAnalyzer.analyze(a, color: ca) { v in Task { @MainActor in self.progress = v * 0.3 } }
                analysisA = analysis
            }
            benchmark = try await InterpolationEvaluator.benchmark(original: a, color: ca, analysis: analysis) { v in
                Task { @MainActor in self.progress = 0.3 + v * 0.7 }
            }
            status = benchmark?.summary ?? ""
            if let bm = benchmark { apply(bm.recommendedModel, bm.recommendedSensitivity) }
        }
    }

    private func run(_ label: String, _ body: @escaping () async throws -> Void) {
        task?.cancel()
        status = label
        progress = 0
        task = Task {
            do { try await body() } catch { status = error.localizedDescription }
            progress = nil
        }
    }
}

struct CompareView: View {
    @Environment(CompareModel.self) private var cmp
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var cmp = cmp
        HSplitView {
            VStack(spacing: 8) {
                HStack {
                    sourceHeader("Original", d: cmp.a, colors: cmp.colorsA, selection: $cmp.colorA, left: true)
                    sourceHeader("Interpolated / processed", d: cmp.b, colors: cmp.colorsB, selection: $cmp.colorB, left: false)
                }
                CompareViewer()
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .dropDestination(for: URL.self) { urls, location in
                        guard let u = urls.first else { return false }
                        cmp.load(u, left: cmp.a == nil)
                        return true
                    }
                HStack {
                    Button { cmp.step(-1) } label: { Image(systemName: "chevron.left") }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button { cmp.step(1) } label: { Image(systemName: "chevron.right") }.keyboardShortcut(.rightArrow, modifiers: [])
                    if let b = cmp.b {
                        Slider(value: Binding(get: { Double(cmp.indexB) }, set: { v in Task { await cmp.seek(to: Int(v)) } }),
                               in: 0...Double(max(1, b.frameCount - 1)))
                    }
                    Text(cmp.frameLabel).font(.caption.monospacedDigit()).frame(minWidth: 320, alignment: .leading)
                }
                HStack {
                    Picker("Layout", selection: $cmp.layout) {
                        ForEach(CompareModel.Layout.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 220)
                    if cmp.layout == .wipe { Slider(value: $cmp.wipe, in: 0...1).frame(width: 160) }
                    Picker("Display", selection: $cmp.target) {
                        ForEach(OutputTarget.all, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .frame(width: 220)
                    Spacer()
                    if let p = cmp.progress { ProgressView(value: p).frame(width: 140) }
                    Text(cmp.status).font(.caption).lineLimit(2)
                }
            }
            .padding()
            .frame(minWidth: 720)
            ReportPanel().frame(minWidth: 320, idealWidth: 360)
        }
        .frame(minWidth: 1100, minHeight: 680)
        .onChange(of: cmp.layout) { cmp.token += 1 }
        .onChange(of: cmp.wipe) { cmp.token += 1 }
        .onChange(of: cmp.target) { cmp.token += 1 }
        .onChange(of: cmp.colorA) { cmp.token += 1 }
        .onChange(of: cmp.colorB) { cmp.token += 1 }
    }

    private func sourceHeader(_ title: String, d: SourceDescriptor?, colors: [SourceColor], selection: Binding<SourceColor?>,
                              left: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK, let u = panel.url {
                        cmp.load(u, left: left, analysis: left ? app.analysis : nil)
                    }
                }
            }
            if let d {
                Text(d.url.lastPathComponent).font(.caption).lineLimit(1)
                Text(d.summary).font(.caption2).foregroundStyle(.secondary)
                Picker("Read as", selection: selection) {
                    ForEach(colors) { Text($0.name).tag(Optional($0)) }
                }
                .labelsHidden()
            } else {
                Text("Drop a video or click Choose").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReportPanel: View {
    @Environment(CompareModel.self) private var cmp
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section("Interpolation Report Card") {
                Button("Grade the interpolated file against the original") { cmp.evaluate() }
                    .disabled(cmp.a == nil || cmp.b == nil)
                if let r = cmp.report {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(r.score)").font(.system(size: 40, weight: .bold, design: .rounded))
                        Text("/100  \(r.verdict)").font(.headline)
                    }
                    ForEach(r.findings, id: \.self) { Label($0, systemImage: "info.circle").font(.callout) }
                    if !r.flagged.isEmpty, let a = cmp.a, let b = cmp.b, let cb = cmp.colorB {
                        Button("Repair this interpolated file using the original") {
                            app.repairExternal(original: a, interpolated: b, interpolatedColor: cb, report: r)
                        }
                        .help("Works with files from any app. Scans every in-between frame against the original, rebuilds the bad ones from this file's own original frames (so the look matches, even with HDR added), and writes a repaired copy.")
                    }
                    if !r.flagged.isEmpty {
                        Button("Repair these \(r.flagged.count) frames in place (Lumora exports)") {
                            app.repairLastExport(frames: Set(r.flagged.map(\.outputIndex)))
                        }
                        .help("Re-renders only the affected chunks with exhaustive interpolation and splices them into the file. The previous version is kept.")
                        DisclosureGroup("Problem frames (\(r.flagged.count)) — click to jump") {
                            ForEach(r.flagged.prefix(300)) { f in
                                Button {
                                    Task { await cmp.seek(to: f.outputIndex) }
                                } label: {
                                    HStack {
                                        Text(String(format: "%.2fs", f.seconds)).monospacedDigit()
                                        Text(f.reason).font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            Section("Perceptual scores (same frame rate)") {
                Text("Scores the processed file against the original with every installed metric: VMAF, VMAF NEG, ColorVideoVDP (HDR-aware), PU21-PSNR, XPSNR, SSIMULACRA 2, CAMBI banding, MS-SSIM, PSNR-HVS, CIEDE2000 and Apple's AVQT.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Score with every metric") { cmp.runPerceptualScores() }.disabled(cmp.a == nil || cmp.b == nil)
                if let r = cmp.fileScores {
                    ForEach(r.scores.pooled.sorted { $0.key.displayName < $1.key.displayName }, id: \.key) { m, v in
                        LabeledContent(m.displayName, value: String(format: "%.3f %@ (worst %.3f)", v.mean, m.unit, v.worst)).font(.caption)
                    }
                    if let q = r.avqt { LabeledContent("AVQT (Apple)", value: String(format: "%.2f / 5", q)).font(.caption) }
                    ForEach(r.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Benchmark models on this footage") {
                Text("Removes real frames from the original, rebuilds them with every installed model, and scores each against the true frame. Uses the result to pick the best model and tune the artifact detector.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Run benchmark") {
                    cmp.runBenchmark { model, sensitivity in
                        if let name = model, let spec = InterpolationModelSpec.all().first(where: { $0.displayName == name }) {
                            app.interpolation.primaryModelID = spec.id
                        }
                        app.interpolation.sensitivity = sensitivity
                    }
                }
                .disabled(cmp.a == nil)
                if let bm = cmp.benchmark {
                    Text(bm.summary).font(.callout)
                    ForEach(bm.scores) { s in
                        LabeledContent(s.name, value: String(format: "%.1f dB · SSIM %.3f · %.0f ms", s.psnr, s.ssim, s.msPerFrame))
                            .font(.caption)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Renders both sides through the same grading engine (each with "keep original look" for its own format)
/// into offscreen textures, then composes them into one EDR drawable.
struct CompareViewer: NSViewRepresentable {
    @Environment(CompareModel.self) private var cmp

    func makeCoordinator() -> Coordinator { Coordinator(cmp: cmp) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: MetalContext.shared.device)
        v.colorPixelFormat = .rgba16Float
        v.framebufferOnly = false
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.delegate = context.coordinator
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        _ = cmp.token
        v.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let cmp: CompareModel
        let rA = GradeRenderer(), rB = GradeRenderer()
        init(cmp: CompareModel) { self.cmp = cmp }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

        func draw(in view: MTKView) {
            guard let layer = view.layer as? CAMetalLayer, let drawable = view.currentDrawable else { return }
            let t = cmp.target
            layer.wantsExtendedDynamicRangeContent = t.isHDR
            layer.colorspace = CGColorSpace(name: t.kind == .hdr10 ? CGColorSpace.itur_2100_PQ
                                            : t.kind == .hlg ? CGColorSpace.itur_2100_HLG : CGColorSpace.itur_709)
            layer.edrMetadata = t.kind == .hdr10 ? CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: t.effectivePeak, opticalOutputScale: 100)
                              : t.kind == .hlg ? CAEDRMetadata.hlg : nil
            let ctx = MetalContext.shared
            let W = drawable.texture.width, H = drawable.texture.height
            let side = cmp.layout == .sideBySide
            let panelW = side ? W / 2 : W
            let cb = ctx.queue.makeCommandBuffer()!
            var p = GradeParams.neutral
            p.passthrough = true

            func render(_ frame: DecodedFrame?, _ color: SourceColor?, _ r: GradeRenderer) -> MTLTexture? {
                guard let frame, let color else { return nil }
                let dst = ctx.makeTexture(width: panelW, height: H, format: .rgba16Float)
                let aspect = Float(frame.texture.width) / Float(frame.texture.height)
                var w = Float(panelW), h = Float(panelW) / aspect
                if h > Float(H) { h = Float(H); w = h * aspect }
                let vp = SIMD4<Float>((Float(panelW) - w) / 2, (Float(H) - h) / 2, w, h)
                r.encodeGrade(cb, source: frame.texture, destination: dst,
                              uniforms: UniformBuilder.make(source: color, params: p, target: t, sceneExposureStops: 0, viewport: vp))
                return dst
            }
            let ta = render(cmp.frameA, cmp.colorA, rA), tb = render(cmp.frameB, cmp.colorB, rB)
            let blit = cb.makeBlitCommandEncoder()!
            func copy(_ src: MTLTexture?, from x0: Int, width: Int, to dx: Int) {
                guard let src, width > 0 else { return }
                blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x0, y: 0, z: 0),
                          sourceSize: MTLSize(width: width, height: H, depth: 1), to: drawable.texture,
                          destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: dx, y: 0, z: 0))
            }
            if side {
                copy(ta, from: 0, width: panelW, to: 0)
                copy(tb, from: 0, width: panelW, to: panelW)
            } else {
                let split = Int(Float(W) * cmp.wipe)
                copy(ta, from: 0, width: split, to: 0)
                copy(tb, from: split, width: W - split, to: split)
            }
            blit.endEncoding()
            cb.present(drawable)
            cb.commit()
        }
    }
}
