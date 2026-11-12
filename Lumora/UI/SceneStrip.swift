import SwiftUI

/// The film at a glance: every scene as a block lit at its real highlight brightness (in HDR on XDR displays),
/// with interpolation repairs and VMAF results laid over it. Click to jump.
struct SceneStrip: View {
    @Environment(AppModel.self) private var model
    @Environment(EncodeMonitor.self) private var monitor

    var body: some View {
        GeometryReader { g in
            if let a = model.analysis, let d = model.descriptor, a.frameCount > 0 {
                let total = CGFloat(a.frameCount)
                ZStack(alignment: .topLeading) {
                    if let img = HDRStrip.image(nits: brightness(a, samples: 1024)) {
                        Image(decorative: img, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .allowedDynamicRange(.high)
                            .frame(height: g.size.height - 10)
                    }
                    Canvas { ctx, size in
                        let h = size.height - 10
                        for s in a.scenes.dropFirst() {
                            let x = size.width * CGFloat(s.start) / total
                            ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: h)), with: .color(Theme.surround.opacity(0.9)))
                        }
                        for e in model.qcEvents where e.action != .accepted {
                            let x = size.width * CGFloat(e.sourceA) / total
                            ctx.fill(Path(CGRect(x: x, y: h - 4, width: 2, height: 4)), with: .color(Theme.marginal))
                        }
                        if let t = monitor.target?.vmaf, monitor.totalFrames > 0 {
                            for c in monitor.chunks {
                                guard let v = c.vmafLow ?? c.vmafMean else { continue }
                                let x0 = size.width * CGFloat(c.range.lowerBound) / CGFloat(monitor.totalFrames)
                                let x1 = size.width * CGFloat(c.range.upperBound) / CGFloat(monitor.totalFrames)
                                ctx.fill(Path(CGRect(x: x0, y: h + 4, width: max(1, x1 - x0 - 1), height: 5)),
                                         with: .color(Theme.vmafColor(v, target: t)))
                            }
                        }
                        if let map = model.motionMap {
                            for r in map.routes where r.status != .skipped {
                                guard let sc = a.scenes[safe: r.scene] else { continue }
                                let x0 = size.width * CGFloat(sc.start) / total, x1 = size.width * CGFloat(sc.end) / total
                                let color: Color = r.status == .uncertain ? Theme.fail : (r.pain > 0.04 ? Theme.marginal : Theme.pass)
                                ctx.fill(Path(CGRect(x: x0, y: 0, width: max(1, x1 - x0 - 1), height: 3)), with: .color(color.opacity(0.9)))
                            }
                        }
                        let px = size.width * CGFloat(model.previewTime * d.fps) / total
                        ctx.fill(Path(CGRect(x: px - 1, y: 0, width: 2, height: h)), with: .color(.white))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    model.scrub(to: Double(p.x / g.size.width) * d.durationSeconds)
                }
                .help("Scenes lit at their highlight brightness. Top row: interpolation pain map (green settled, amber hard, red not yet confident). Amber ticks: repaired frames. Bottom row: quality per chunk.")
            } else {
                RoundedRectangle(cornerRadius: 3).fill(Theme.rail)
                    .overlay(Text("Scenes appear here after analysis").font(Theme.note).foregroundStyle(.secondary))
            }
        }
    }

    /// Highlight level per position: measured nits for HDR sources, an estimate of the graded result otherwise.
    private func brightness(_ a: AnalysisResult, samples: Int) -> [Float] {
        let isHDR = model.selectedColor.map { $0.transfer == .pq || $0.transfer == .hlg } ?? false
        let peak = model.previewTarget.effectivePeak
        return (0..<samples).map { i in
            let f = Int(Double(i) / Double(samples) * Double(a.frameCount))
            guard let s = a.scenes[safe: a.sceneIndex(for: f)] else { return 0 }
            let n = isHDR ? 25.92 * powf(2, s.p995) : model.previewTarget.baseMidGreyNits * powf(2, s.p995)
            return min(peak, max(0.5, n))
        }
    }
}
