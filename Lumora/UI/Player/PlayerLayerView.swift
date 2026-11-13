import SwiftUI
import AppKit
import QuartzCore
import Metal

/// The player's picture: an NSView backed by a CAMetalLayer, driven by the window's display link. Each refresh asks
/// the engine for the frame due when this refresh reaches the screen, and converts it straight into the EDR drawable.
final class PlayerMetalView: NSView {
    /// Documentation screenshots are captured offscreen, where a CAMetalLayer draws nothing. In snapshot mode the
    /// frame is also rendered for an SDR screen into an ordinary image view, which offscreen capture can see.
    nonisolated(unsafe) static var snapshotMode = false

    weak var engine: PlayerEngine?
    let renderer = PlayerRenderer()
    private var link: CADisplayLink?
    private var headroom = HeadroomFilter(initial: 1)
    private var lastTick: CFTimeInterval = 0
    private var drawnToken = -1
    private var drawnSize = CGSize.zero
    private var drawnHeadroom = 0.0
    private var snapshotView: NSImageView?
    private var inFlight = 0

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = MetalContext.shared.device
        l.pixelFormat = .rgba16Float
        l.framebufferOnly = false
        l.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        l.backgroundColor = NSColor.black.cgColor
        l.maximumDrawableCount = 3
        return l
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil, !Self.snapshotMode else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        updateFrameRate()
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    /// ProMotion: run the screen at a multiple of the content rate (24p at 48 / 72 / 120 Hz).
    func updateFrameRate() {
        guard let link, let fps = engine?.fps, fps > 0 else { return }
        let f = Float(fps)
        let multiple = max(1, (120 / f).rounded(.down))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(f, 120), maximum: 120, preferred: min(120, f * multiple))
    }

    private func displayState(dt: Double) -> DisplayState {
        let screen = window?.screen ?? NSScreen.main
        let reference = Double(screen?.maximumReferenceExtendedDynamicRangeColorComponentValue ?? 0)
        if reference > 0 {
            return DisplayState(headroom: reference, referenceMode: true)
        }
        let raw = Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        return DisplayState(headroom: headroom.update(raw, dt: dt), referenceMode: false)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let engine else { return }
        let now = CACurrentMediaTime()
        let dt = lastTick > 0 ? now - lastTick : 0
        lastTick = now
        let frame = engine.frameForDisplay(targetHost: link.targetTimestamp)
        let display = displayState(dt: dt)
        let size = CGSize(width: bounds.width * (window?.backingScaleFactor ?? 2), height: bounds.height * (window?.backingScaleFactor ?? 2))
        if engine.renderToken == drawnToken && size == drawnSize && abs(display.headroom - drawnHeadroom) < 0.01 { return }
        guard inFlight < 2 else { return }
        draw(frame, display: display, size: size)
        drawnToken = engine.renderToken
        drawnSize = size
        drawnHeadroom = display.headroom
    }

    /// Redraws now (paused frame after a settings change, resize).
    func redraw() { drawnToken = -1 }

    private func draw(_ frame: PlayerFrame?, display: DisplayState, size: CGSize) {
        guard let engine, size.width >= 1, size.height >= 1 else { return }
        let l = metalLayer
        l.drawableSize = size
        // The same decision picks the kernel's output encoding (engine.uniforms), so layer and pixels always agree.
        let output = frame.map { engine.output(for: $0) } ?? .extendedLinear(edr: engine.isHDR)
        l.wantsExtendedDynamicRangeContent = output.wantsEDR
        switch output {
        case .pq:
            l.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
            let peak = Float(engine.toneMap?.sourcePeak ?? 1000)
            let minNits = Float(engine.info?.video.hdr?.mdcvMinNits ?? 0.005)
            l.edrMetadata = CAEDRMetadata.hdr10(minLuminance: minNits, maxLuminance: peak, opticalOutputScale: 100)
        case .hlg:
            l.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
            l.edrMetadata = CAEDRMetadata.hlg
        case .extendedLinear:
            l.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
            l.edrMetadata = nil              // Lumora tone maps to the headroom itself
        }
        guard let drawable = l.nextDrawable(), let cb = renderer.queue.makeCommandBuffer() else { return }
        let w = drawable.texture.width, h = drawable.texture.height
        if let frame, let info = engine.info {
            let vp = PlayerRenderer.letterbox(aspect: info.video.displayAspect, width: w, height: h)
            if let u = engine.uniforms(for: frame, display: display, viewport: vp) {
                try? renderer.encode(cb, frame: frame, uniforms: u, destination: drawable.texture)
            }
        } else {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            pass.colorAttachments[0].storeAction = .store
            cb.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        inFlight += 1
        cb.addCompletedHandler { [weak self] _ in DispatchQueue.main.async { self?.inFlight -= 1 } }
        cb.present(drawable)
        cb.commit()
        if Self.snapshotMode { updateSnapshot(frame) }
    }

    /// Snapshot mode: the current frame rendered for an SDR screen (headroom 1) into an image view.
    func updateSnapshot(_ frame: PlayerFrame? = nil) {
        guard let engine, let f = frame ?? engine.currentFrame, let info = engine.info else { return }
        let w = min(f.layout.width, 1600)
        let h = max(1, Int((Double(w) / info.video.displayAspect).rounded()))
        let vp = SIMD4<Float>(0, 0, Float(w), Float(h))
        guard let u = engine.uniforms(for: f, display: DisplayState(headroom: 1), viewport: vp),
              let tex = try? renderer.render(frame: f, uniforms: u, width: w, height: h),
              let image = Self.cgImage(tex) else { return }
        let iv = snapshotView ?? {
            let iv = NSImageView(frame: bounds)
            iv.autoresizingMask = [.width, .height]
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.backgroundColor = NSColor.black.cgColor
            addSubview(iv)
            snapshotView = iv
            return iv
        }()
        iv.frame = bounds
        iv.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    /// An rgba32Float texture in extended linear BT.2020 as a CGImage (Core Graphics converts it for display).
    static func cgImage(_ t: MTLTexture) -> CGImage? {
        let px = PlayerRenderer.readBack(t)
        var data = Data(count: px.count * 16)
        data.withUnsafeMutableBytes { raw in
            let f = raw.bindMemory(to: Float.self)
            for (i, p) in px.enumerated() {
                f[4 * i] = min(1, max(0, p.x)); f[4 * i + 1] = min(1, max(0, p.y)); f[4 * i + 2] = min(1, max(0, p.z)); f[4 * i + 3] = 1
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: t.width, height: t.height, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: t.width * 16,
                       space: space, bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let engine: PlayerEngine

    func makeNSView(context: Context) -> PlayerMetalView {
        let v = PlayerMetalView(frame: .zero)
        v.engine = engine
        return v
    }

    func updateNSView(_ v: PlayerMetalView, context: Context) {
        v.engine = engine
        // Settings and "Interpret as" changes redraw a paused frame; new frames are picked up by the display link
        // itself (reading renderToken here would re-run SwiftUI on every frame).
        _ = engine.interpret
        _ = engine.settings
        _ = engine.info
        v.updateFrameRate()
        v.redraw()
        if PlayerMetalView.snapshotMode { _ = engine.renderToken; v.updateSnapshot() }
    }

    static func dismantleNSView(_ v: PlayerMetalView, coordinator: ()) {
        v.engine = nil
    }
}
