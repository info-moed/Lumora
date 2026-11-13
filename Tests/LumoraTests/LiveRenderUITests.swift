import XCTest
import SwiftUI
import AppKit
import Metal
@testable import Lumora

/// The live render panel, drawn offscreen with a synthetic render in progress (Simple and detail views).
@MainActor
final class LiveRenderUITests: XCTestCase {
    override func tearDown() async throws {
        RenderMonitor.shared.showForTesting(nil, sample: SystemSample())
        RenderMonitor.testPreview = nil
        RenderMonitor.shared.panelDisappeared()
        UserDefaults.standard.removeObject(forKey: "renderMonitorDetail")
    }

    /// A render in progress, as the monitor would show it.
    static func syntheticState(preview: MTLTexture? = nil) -> (MonitoredRun.Snapshot, SystemSample) {
        var s = SystemSample()
        s.cores = 14; s.performanceCores = 10; s.efficiencyCores = 4
        s.busyCores = 13.1; s.selfCores = 0.7; s.childCores = 11.4; s.othersCores = 1.0
        s.performanceBusy = 0.97; s.efficiencyBusy = 0.88
        s.gpuDevice = 0.12; s.pressureLevel = 1; s.swapUsedMB = 1200; s.selfFootprintMB = 900; s.childFootprintMB = 1900
        s.children = [.init(pid: 101, name: "SvtAv1EncApp", cores: 5.8, footprintMB: 980), .init(pid: 102, name: "SvtAv1EncApp", cores: 5.6, footprintMB: 940)]
        s.topAppsByCPU = [.init(name: "Music", cores: 0.4, memoryMB: 400)]
        s.systemProcessesCores = 0.5
        var snap = MonitoredRun.Snapshot(id: UUID(), name: "Aurora – Natural – HDR10.mkv", codecName: "AV1", encoderName: "SvtAv1EncApp",
                                         targetKind: .hdr10, peakNits: 1000)
        snap.status = .rendering
        snap.heartbeat = 0.4
        snap.framesDone = 812; snap.totalFrames = 1412; snap.fraction = 812.0 / 1412
        snap.fps = 11.5; snap.realtime = 0.48; snap.eta = 52; snap.elapsed = 71
        snap.position = 812; snap.timecode = "00:00:33:20"
        var v = Verdict()
        v.kind = .encoderSaturated; v.headline = "Making good use of your Mac"
        v.reason = "SvtAv1EncApp is using every core (CPU 94% busy) and Lumora waits on it 94% of the time, so this is as fast as this quality setting goes."
        v.suggestion = "For more speed, choose a faster encoder preset (a little less quality for the size)."
        v.score = 0.92; v.cpuUse = 0.92; v.gpuUse = 0.1; v.confidence = .high; v.isGood = true
        snap.verdict = v
        snap.lanes = [
            .init(id: "a", label: "Segment 1 · frames 0–705", detail: "at frame 412 · 00:00:17:04", position: 412, progress: 0.58, closed: false, kind: "segment"),
            .init(id: "b", label: "Segment 2 · frames 706–1411", detail: "at frame 1106 · 00:00:46:02", position: 1106, progress: 0.57, closed: false, kind: "segment"),
        ]
        snap.history = (0..<60).map { i -> MonitoredRun.HistoryPoint in
            let x = Double(i)
            let enc: Double = 11 + sin(x / 5) * 0.4
            let oth: Double = 1 + cos(x / 7) * 0.3
            let gpu: Double = 0.12 + sin(x / 9) * 0.03
            let fps: Double = 11.5 + sin(x / 4)
            return MonitoredRun.HistoryPoint(id: i, t: x, lumora: 0.7, encoders: enc, others: oth, idle: 1, gpuLumora: 0.09, gpuDevice: gpu, fps: fps)
        }
        snap.stages = [.init(name: "Decode", msPerFrame: 3.1, share: 0.4), .init(name: "Grade (GPU)", msPerFrame: 4.2, share: 0.6)]
        snap.encoderStarved = 0.02; snap.pipeBlocked = 0.94; snap.gpuLumora = 0.09
        snap.sample = s
        if let preview {
            RenderMonitor.testPreview = PreviewFrame(texture: preview, lane: .segment(0), outputIndex: 812, totalFrames: 1412,
                                                     rate: (24, 1), target: OutputTarget(kind: .sdr, peakNits: 100), time: 1, serial: 1)
        }
        return (snap, s)
    }

    static func gradientTexture() -> MTLTexture {
        let device = MetalContext.shared.device
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 480, height: 270, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)!
        var px = [Float16](repeating: 1, count: 480 * 270 * 4)
        for y in 0..<270 { for x in 0..<480 {
            let i = (y * 480 + x) * 4
            px[i] = Float16(Float(x) / 480); px[i + 1] = Float16(Float(y) / 270); px[i + 2] = 0.5; px[i + 3] = 1
        } }
        t.replace(region: MTLRegionMake2D(0, 0, 480, 270), mipmapLevel: 0, withBytes: px, bytesPerRow: 480 * 8)
        return t
    }

    func render(detail: Bool) async throws -> NSBitmapImageRep {
        try TestHardware.requireGPU()
        UserDefaults.standard.set(detail, forKey: "renderMonitorDetail")
        let (snap, sample) = Self.syntheticState(preview: Self.gradientTexture())
        RenderMonitor.shared.showForTesting(snap, sample: sample)
        let size = CGSize(width: 1100, height: detail ? 900 : 620)
        let view = LiveRenderPanel().environment(RenderMonitor.shared).preferredColorScheme(.dark)
            .frame(width: size.width, height: size.height).background(Theme.surround)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for _ in 0..<15 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 40_000_000) }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: UISmokeTests.shotsDir.appendingPathComponent("live-render-\(detail ? "detail" : "simple").png"))
        }
        return rep
    }

    func distinctColors(_ rep: NSBitmapImageRep) -> Int {
        var seen = Set<UInt32>()
        for y in stride(from: 0, to: rep.pixelsHigh, by: 7) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                seen.insert(UInt32(c.redComponent * 31) << 10 | UInt32(c.greenComponent * 31) << 5 | UInt32(c.blueComponent * 31))
            }
        }
        return seen.count
    }

    func testSimplePanelDraws() async throws {
        let rep = try await render(detail: false)
        XCTAssertGreaterThan(distinctColors(rep), 20, "the panel should draw text, gauges and the verdict")
    }

    func testDetailPanelDraws() async throws {
        let rep = try await render(detail: true)
        XCTAssertGreaterThan(distinctColors(rep), 25)
    }

    func testStatusViewsAndBanner() async throws {
        let (snap, sample) = Self.syntheticState()
        RenderMonitor.shared.showForTesting(snap, sample: sample,
                                            overload: .init(reasons: ["Other apps are using 7 of 14 cores"], topByCPU: [.init(name: "Busy App", cores: 6.5, memoryMB: 800)],
                                                            topByMemory: [], systemCores: 0.6, since: 0))
        let host = NSHostingView(rootView: VStack { RenderStatusPill(); RenderStatusBanner(); LoadBanner() }
            .frame(width: 900, height: 200).preferredColorScheme(.dark))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 200)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertGreaterThan(distinctColors(rep), 4)
        XCTAssertEqual(RunStatus.rendering.text, "Rendering live")
        XCTAssertEqual(RunStatus.paused("Paused: on battery").text, "Paused: on battery")
    }
}
