import SwiftUI
import MetalKit
import MetalPerformanceShaders

/// The EDR layer setup shared by live HDR views: PQ with HDR10 metadata at the job's peak, HLG, or BT.709.
enum EDRLayerSetup {
    static func configure(_ layer: CAMetalLayer, target: OutputTarget) {
        switch target.kind {
        case .hdr10:
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            layer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: target.effectivePeak, opticalOutputScale: 100)
        case .hlg:
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            layer.edrMetadata = CAEDRMetadata.hlg
        case .sdr:
            layer.wantsExtendedDynamicRangeContent = false
            layer.colorspace = CGColorSpace(name: CGColorSpace.itur_709)
            layer.edrMetadata = nil
        }
    }
}

/// The frame a render is producing right now, in HDR on an HDR display when the output is HDR. It polls the
/// preview hub four times a second and draws only when a new frame arrived; it never touches the render path.
struct LiveFrameView: NSViewRepresentable {
    var lane: LaneID?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: MetalContext.shared.device)
        v.colorPixelFormat = .rgba16Float
        v.framebufferOnly = false
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.delegate = context.coordinator
        v.clearColor = MTLClearColorMake(0, 0, 0, 1)
        context.coordinator.attach(v)
        return v
    }

    func updateNSView(_ v: MTKView, context: Context) {
        context.coordinator.lane = lane
        context.coordinator.poll()
    }

    static func dismantleNSView(_ v: MTKView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        var lane: LaneID?
        private weak var view: MTKView?
        private var timer: Timer?
        private var shownSerial = -1
        private var frame: PreviewFrame?
        private var snapshotView: NSImageView?
        private lazy var scaler = MPSImageBilinearScale(device: MetalContext.shared.device)

        func attach(_ v: MTKView) {
            view = v
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        func detach() { timer?.invalidate(); timer = nil }

        func poll() {
            let f = RenderMonitor.testPreview ?? RenderMonitor.shared.activeRun?.hub.frame(for: lane)
            guard let f, f.serial != shownSerial, let v = view else { return }
            shownSerial = f.serial
            frame = f
            if EDRViewer.snapshotMode { showSnapshot(f, in: v) }
            v.needsDisplay = true
        }

        private func showSnapshot(_ f: PreviewFrame, in v: MTKView) {
            guard let image = LivePreviewHub.cgImage(f.texture, target: f.target) else { return }
            let iv = snapshotView ?? {
                let iv = NSImageView(frame: v.bounds)
                iv.autoresizingMask = [.width, .height]
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.wantsLayer = true
                iv.layer?.backgroundColor = NSColor.black.cgColor
                v.addSubview(iv)
                snapshotView = iv
                return iv
            }()
            iv.frame = v.bounds
            iv.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

        func draw(in view: MTKView) {
            guard let layer = view.layer as? CAMetalLayer else { return }
            EDRLayerSetup.configure(layer, target: frame?.target ?? .sdr)
            guard let drawable = view.currentDrawable, let cb = MetalContext.shared.queue.makeCommandBuffer() else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
            if let f = frame {
                // Fit the preview into the drawable, centered (letterboxed), with one bilinear scale.
                let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
                let sw = Double(f.texture.width), sh = Double(f.texture.height)
                let k = min(dw / sw, dh / sh)
                let w = (sw * k).rounded(.down), h = (sh * k).rounded(.down)
                let x = ((dw - w) / 2).rounded(.down), y = ((dh - h) / 2).rounded(.down)
                var transform = MPSScaleTransform(scaleX: k, scaleY: k, translateX: x, translateY: y)
                withUnsafePointer(to: &transform) { ptr in
                    scaler.scaleTransform = ptr
                    scaler.clipRect = MTLRegionMake2D(Int(x), Int(y), max(1, Int(w)), max(1, Int(h)))
                    scaler.encode(commandBuffer: cb, sourceTexture: f.texture, destinationTexture: drawable.texture)
                    scaler.scaleTransform = nil
                }
                scaler.clipRect = MPSRectNoClip
            }
            cb.present(drawable)
            cb.commit()
        }
    }
}

/// The last few frames as small SDR pictures.
struct FilmstripView: View {
    let images: [CGImage]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(height: 44).clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }
}
