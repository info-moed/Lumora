import SwiftUI
import MetalKit

/// Real HDR preview. The same grade kernel as the export writes straight into an EDR drawable,
/// so the MacBook Pro XDR screen (or any HDR display) shows the actual PQ / HLG output.
struct EDRViewer: NSViewRepresentable {
    @Environment(AppModel.self) private var model

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: MetalContext.shared.device)
        v.colorPixelFormat = .rgba16Float
        v.framebufferOnly = false
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.delegate = context.coordinator
        v.clearColor = MTLClearColorMake(0, 0, 0, 1)
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        _ = model.renderToken          // re-draw whenever the model says the picture changed
        _ = model.params
        _ = model.previewTarget
        _ = model.splitCompare
        _ = model.falseColor
        v.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let model: AppModel
        let renderer = GradeRenderer()
        init(model: AppModel) { self.model = model }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

        func draw(in view: MTKView) {
            guard let layer = view.layer as? CAMetalLayer else { return }
            switch model.previewTarget.kind {
            case .hdr10:
                layer.wantsExtendedDynamicRangeContent = true
                layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
                layer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: model.previewTarget.effectivePeak,
                                                        opticalOutputScale: 100)
            case .hlg:
                layer.wantsExtendedDynamicRangeContent = true
                layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
                layer.edrMetadata = CAEDRMetadata.hlg
            case .sdr:
                layer.wantsExtendedDynamicRangeContent = false
                layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
                layer.edrMetadata = nil
            }
            guard let drawable = view.currentDrawable else { return }
            let cb = MetalContext.shared.queue.makeCommandBuffer()!
            let dw = Float(drawable.texture.width), dh = Float(drawable.texture.height)
            if let frame = model.previewFrame {
                let crop = model.descriptor?.crop ?? UniformBuilder.fullFrame
                let aspect = Float(frame.texture.width) * crop.z / (Float(frame.texture.height) * crop.w)
                var w = dw, h = dw / aspect
                if h > dh { h = dh; w = dh * aspect }
                let vp = SIMD4<Float>(((dw - w) / 2).rounded(), ((dh - h) / 2).rounded(), w.rounded(), h.rounded())
                if let u = model.previewUniforms(viewport: vp) {
                    renderer.encodeGrade(cb, source: frame.texture, destination: drawable.texture, uniforms: u)
                }
            }
            cb.present(drawable)
            cb.commit()
        }
    }
}
