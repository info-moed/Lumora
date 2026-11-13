import Foundation
import Metal
import MetalPerformanceShaders
import CoreImage

/// A downscaled copy of the frame a lane just graded, for the live preview. The copy is a bilinear GPU scale encoded
/// into the grade's own command buffer (so ordering with the reused full-size texture is free), into a small pooled
/// texture: no wait, no CPU readback, and at most one copy in flight per lane, a few times a second.
struct PreviewFrame: @unchecked Sendable {
    var texture: MTLTexture            // rgba16Float, 480 px wide, holding the target-encoded (PQ / HLG / BT.709) signal
    var lane: LaneID
    var outputIndex: Int
    var totalFrames: Int
    var rate: (num: Int, den: Int)
    var target: OutputTarget
    var time: Double                   // host clock when the GPU finished it
    var serial: Int

    var timecode: String { Self.timecode(frame: outputIndex, rate: rate) }

    static func timecode(frame: Int, rate: (num: Int, den: Int)) -> String {
        let fps = Double(rate.num) / Double(max(1, rate.den))
        let whole = max(1, Int(fps.rounded()))
        let secs = Int(Double(frame) / max(0.001, fps))
        return String(format: "%02d:%02d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60, frame % whole)
    }
}

final class LivePreviewHub: @unchecked Sendable {
    /// Seconds between preview copies per lane (tests set 0 to get every frame).
    nonisolated(unsafe) static var interval: Double = 0.25
    static let width = 480
    static let stripWidth = 160
    static let stripCount = 5

    private final class LaneState {
        var pool: [MTLTexture] = []
        var next = 0
        var lastAt: Double = 0
        var inFlight = false
        var strip: [MTLTexture] = []
        var stripNext = 0
        var copies = 0
    }

    private let lock = NSLock()
    private var lanes: [LaneID: LaneState] = [:]
    private var latest: [LaneID: PreviewFrame] = [:]
    private var stripImages: [CGImage] = []
    private var serial = 0
    private let scaler: MPSImageBilinearScale
    private let device: MTLDevice
    private let target: OutputTarget
    private let rate: (num: Int, den: Int)
    private let totalFrames: Int
    private let stripQueue = DispatchQueue(label: "lumora.monitor.filmstrip", qos: .utility)
    var filmstripEnabled: () -> Bool = { true }
    private(set) var published = 0

    init(device: MTLDevice = MetalContext.shared.device, target: OutputTarget, rate: (num: Int, den: Int), totalFrames: Int) {
        self.device = device
        self.scaler = MPSImageBilinearScale(device: device)
        self.target = target
        self.rate = rate
        self.totalFrames = totalFrames
    }

    /// Called right before the grade's command buffer is committed. Usually a no-op (interval not reached, or a copy
    /// still in flight); otherwise encodes one small scale and publishes it when the GPU finishes.
    func offer(_ cb: MTLCommandBuffer, rgb: MTLTexture, outputIndex: Int, lane: LaneID, now: Double) {
        lock.lock()
        let st = lanes[lane] ?? { let s = LaneState(); lanes[lane] = s; return s }()
        guard !st.inFlight, now - st.lastAt >= Self.interval else { lock.unlock(); return }
        st.inFlight = true
        st.lastAt = now
        lock.unlock()

        let h = max(2, Int((Double(Self.width) * Double(rgb.height) / Double(max(1, rgb.width))).rounded()))
        if st.pool.isEmpty || st.pool[0].height != h {
            st.pool = (0..<3).map { _ in make(Self.width, h) }
        }
        let dst = st.pool[st.next % st.pool.count]
        st.next += 1
        scaler.encode(commandBuffer: cb, sourceTexture: rgb, destinationTexture: dst)
        st.copies += 1
        var stripTex: MTLTexture?
        if filmstripEnabled(), st.copies % 4 == 1 {
            let sh = max(2, Int((Double(Self.stripWidth) * Double(rgb.height) / Double(max(1, rgb.width))).rounded()))
            if st.strip.isEmpty || st.strip[0].height != sh { st.strip = (0..<Self.stripCount).map { _ in make(Self.stripWidth, sh) } }
            stripTex = st.strip[st.stripNext % st.strip.count]
            st.stripNext += 1
            scaler.encode(commandBuffer: cb, sourceTexture: dst, destinationTexture: stripTex!)
        }
        let target = self.target, rate = self.rate, total = self.totalFrames
        cb.addCompletedHandler { [weak self] buffer in
            guard let self else { return }
            let done = CACurrentMediaTimeCompat()
            self.lock.lock()
            st.inFlight = false
            if buffer.status == .completed {
                self.serial += 1
                self.latest[lane] = PreviewFrame(texture: dst, lane: lane, outputIndex: outputIndex, totalFrames: total,
                                                 rate: rate, target: target, time: done, serial: self.serial)
                self.published += 1
            }
            self.lock.unlock()
            if let stripTex, buffer.status == .completed { self.stripQueue.async { self.addStrip(stripTex) } }
        }
    }

    private func make(_ w: Int, _ h: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    private func addStrip(_ tex: MTLTexture) {
        guard let img = Self.cgImage(tex, target: target) else { return }
        lock.lock()
        stripImages.append(img)
        if stripImages.count > Self.stripCount { stripImages.removeFirst(stripImages.count - Self.stripCount) }
        lock.unlock()
    }

    func frame(for lane: LaneID?) -> PreviewFrame? {
        lock.lock(); defer { lock.unlock() }
        if let lane { return latest[lane] }
        return latest.values.max { $0.time < $1.time }
    }

    var allFrames: [PreviewFrame] { lock.lock(); defer { lock.unlock() }; return Array(latest.values) }
    var filmstrip: [CGImage] { lock.lock(); defer { lock.unlock() }; return stripImages }

    func dropFilmstrip() {
        lock.lock()
        stripImages.removeAll()
        for st in lanes.values { st.strip.removeAll() }
        lock.unlock()
    }

    /// An SDR picture of a preview texture (for the filmstrip and offscreen snapshots). HDR signals are shown clipped.
    static func cgImage(_ tex: MTLTexture, target: OutputTarget) -> CGImage? {
        let space: CGColorSpace?
        switch target.kind {
        case .hdr10: space = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        case .hlg: space = CGColorSpace(name: CGColorSpace.itur_2100_HLG)
        case .sdr: space = CGColorSpace(name: CGColorSpace.itur_709)
        }
        guard let space, let ci = CIImage(mtlTexture: tex, options: [.colorSpace: space]) else { return nil }
        let flipped = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ci.extent.height))
        return MetalContext.shared.ciContext.createCGImage(flipped, from: flipped.extent, format: .RGBA8,
                                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
