import XCTest
@testable import Lumora

/// The "making the most of the Mac" verdict from synthetic measurement windows, plus the stall detector.
final class BottleneckClassifierTests: XCTestCase {
    func load(busy: Double, me: Double = 0.5, kids: Double, others: Double, cores: Int = 14,
              gpu: Double? = 0.1, gpuMine: Double? = 0.05) -> LoadWindow {
        var l = LoadWindow()
        l.cores = cores; l.busyCores = busy; l.selfCores = me; l.childCores = kids; l.othersCores = others
        l.performanceBusy = min(1, busy / Double(cores)); l.efficiencyBusy = min(1, busy / Double(cores))
        l.gpuDevice = gpu; l.gpuLumora = gpuMine
        return l
    }

    func cli(starved: Double) -> PipelineWindow {
        var p = PipelineWindow()
        p.writerStarved = starved; p.writerBackpressure = 1 - starved
        p.graderStarved = 0.1; p.graderGPU = 0.1; p.graderBlocked = 1 - starved; p.producerBlocked = 0.8; p.producerDecode = 0.2
        p.activeLanes = 2
        return p
    }

    @discardableResult
    func feed(_ c: BottleneckClassifier, from: Int = 1, to: Int = 40, fps: Double = 30, paused: String? = nil,
              _ p: PipelineWindow, _ l: LoadWindow) -> Verdict {
        var v = Verdict()
        for t in from...to { v = c.update(ClassifierTick(time: Double(t), frames: Int(Double(t) * fps), paused: paused, pipeline: p, load: l)) }
        return v
    }

    func context(segments: Int = 3, frames: Int = 5000) -> ClassifierContext {
        var c = ClassifierContext(); c.encoderName = "SvtAv1EncApp"; c.segments = segments; c.totalFrames = frames
        return c
    }

    func testMeasuringFirst() {
        let c = BottleneckClassifier(context: context())
        let v = feed(c, to: 8, cli(starved: 0.05), load(busy: 13.6, me: 0.6, kids: 12.5, others: 0.5))
        XCTAssertEqual(v.kind, .measuring)
        XCTAssertNil(v.score)
    }

    func testEncoderSaturatedIsGood() {
        let c = BottleneckClassifier(context: context())
        let v = feed(c, cli(starved: 0.05), load(busy: 13.6, me: 0.6, kids: 12.5, others: 0.5))
        XCTAssertEqual(v.kind, .encoderSaturated)
        XCTAssertTrue(v.isGood)
        XCTAssertEqual(v.confidence, .high)
        XCTAssertEqual(v.score ?? 0, 13.1 / 13.5, accuracy: 0.02)
        XCTAssertTrue(v.reason.contains("every core"))
        XCTAssertTrue(v.suggestion?.contains("faster encoder preset") ?? false)
        XCTAssertTrue(v.sentence.hasPrefix("Making good use of your Mac (97%). SvtAv1EncApp is using every core"), v.sentence)
    }

    func testEncoderBoundWithIdleCores() {
        let c = BottleneckClassifier(context: context())
        let v = feed(c, cli(starved: 0.05), load(busy: 6, me: 0.5, kids: 5.2, others: 0.3))
        XCTAssertEqual(v.kind, .encoderCoresIdle)
        XCTAssertFalse(v.isGood)
        XCTAssertTrue(v.suggestion?.contains("Optimize for this Mac measures the best count") ?? false)
    }

    /// Measured on this Mac: libaom, one segment, 1.5 cores, while other apps kept 10 of 14 cores busy.
    func testLightlyThreadedEncoderOnABusyMacIsNotCalledSaturated() {
        var ctx = context(segments: 1, frames: 192); ctx.encoderName = "aomenc"; ctx.encoderScalesPoorly = true
        let v = feed(BottleneckClassifier(context: ctx), cli(starved: 0.0), load(busy: 11.8, me: 0.05, kids: 1.5, others: 10.2))
        XCTAssertEqual(v.kind, .encoderCoresIdle)
        XCTAssertFalse(v.isGood)
        XCTAssertTrue(v.reason.contains("of the 3.8 cores other apps leave free"), v.reason)
    }

    func testShortClipHasNothingToSplit() {
        let c = BottleneckClassifier(context: context(segments: 1, frames: 300))
        let v = feed(c, cli(starved: 0.05), load(busy: 4, me: 0.5, kids: 3.2, others: 0.3))
        XCTAssertEqual(v.kind, .encoderCoresIdle)
        XCTAssertTrue(v.suggestion?.contains("too short") ?? false, v.suggestion ?? "")
    }

    func testOtherAppsCompeting() {
        let c = BottleneckClassifier(context: context())
        let v = feed(c, cli(starved: 0.05), load(busy: 13.8, me: 0.6, kids: 6.5, others: 6.7))
        XCTAssertEqual(v.kind, .otherApps)
        XCTAssertTrue(v.reason.contains("6.7 of 14 cores"), v.reason)
    }

    /// Measured on this Mac: aomenc held 1.4 cores while other apps kept 12.3 of 14 busy. Of what others left free
    /// Lumora used nearly all, but the score must say how little of the Mac it got, and never look good.
    func testOtherAppsScoreIsLumorasShareOfTheMac() {
        var ctx = context(segments: 1, frames: 192); ctx.encoderName = "aomenc"; ctx.encoderScalesPoorly = true
        let v = feed(BottleneckClassifier(context: ctx), cli(starved: 0.0), load(busy: 13.8, me: 0.05, kids: 1.4, others: 12.35))
        XCTAssertEqual(v.kind, .otherApps)
        XCTAssertEqual(v.score ?? 1, 1.45 / 14, accuracy: 0.01)
        XCTAssertFalse(v.isGood)
        XCTAssertTrue(v.kind.isAlarm, "the ring is never green for an alarm")
        XCTAssertTrue(v.reason.contains("(10% of the Mac)"), v.reason)
    }

    /// Lumora's own rests (here Lower priority: rest as long as it worked) starve the encoder; that is not decoding.
    func testOwnPacingIsNotCalledDecode() {
        var p = producerBound(decode: 0.4, interp: 0, upscale: 0); p.producerPaced = 0.5
        var l = load(busy: 3, kids: 2, others: 0.5); l.pacingReason = "because you chose Lower priority"
        let v = feed(BottleneckClassifier(context: context()), p, l)
        XCTAssertEqual(v.kind, .resting)
        XCTAssertTrue(v.reason.contains("because you chose Lower priority"), v.reason)
        XCTAssertTrue(v.suggestion?.contains("Normal priority") ?? false, v.suggestion ?? "")
        XCTAssertFalse(v.isGood)
        // Without pacing the same window is decode-bound.
        XCTAssertEqual(feed(BottleneckClassifier(context: context()), producerBound(decode: 0.4, interp: 0, upscale: 0), load(busy: 3, kids: 2, others: 0.5)).kind, .decode)
    }

    /// The thermal verdict only says Lumora backed off when the governor did.
    func testThermalVerdictClaimsOnlyWhatWasDone() {
        var hot = load(busy: 13.6, kids: 12.5, others: 0.5); hot.thermal = 2
        let plain = feed(BottleneckClassifier(context: context()), to: 30, cli(starved: 0.05), hot)
        XCTAssertEqual(plain.kind, .thermal)
        XCTAssertFalse(plain.reason.contains("background band"), plain.reason)
        hot.thermalBackoff = true
        let backed = feed(BottleneckClassifier(context: context()), to: 30, cli(starved: 0.05), hot)
        XCTAssertTrue(backed.reason.contains("background band"), backed.reason)
    }

    /// Target quality after the last frame is rendered: the search is the whole job, and it is classified.
    func testQualitySearchAfterRenderingIsClassified() {
        var ctx = context(); ctx.targetQuality = true
        var p = PipelineWindow(); p.chunksRenderBlocked = 1; p.chunksEncodersStarved = 0
        let v = feed(BottleneckClassifier(context: ctx), p, load(busy: 3.6, me: 0.2, kids: 1.4, others: 2))
        XCTAssertEqual(v.kind, .qualitySearch)
        XCTAssertFalse(v.isGood, "1.6 of 14 cores is not making good use")
    }

    func testGPUBound() {
        let c = BottleneckClassifier(context: context())
        var p = cli(starved: 0.8); p.graderStarved = 0.05; p.graderGPU = 0.9
        let v = feed(c, p, load(busy: 4, kids: 3, others: 0.5, gpu: 0.96, gpuMine: 0.92))
        XCTAssertEqual(v.kind, .gpu)
        XCTAssertGreaterThan(v.score ?? 0, 0.9)
    }

    func testGPUOneFrameAtATimeIsUnsure() {
        let c = BottleneckClassifier(context: context())
        var p = cli(starved: 0.8); p.graderStarved = 0.05; p.graderGPU = 0.4
        let v = feed(c, p, load(busy: 4, kids: 3, others: 0.5, gpu: 0.4, gpuMine: 0.35))
        XCTAssertEqual(v.kind, .gpuSerial)
        XCTAssertEqual(v.confidence, .low)
        XCTAssertTrue(v.headline.hasPrefix("Not sure yet"))
    }

    func producerBound(decode: Double, interp: Double, upscale: Double) -> PipelineWindow {
        var p = cli(starved: 0.8); p.graderStarved = 0.8; p.producerBlocked = 0
        p.producerDecode = decode; p.producerInterp = interp; p.producerUpscale = upscale
        return p
    }

    func testDecodeInterpolationAndUpscaleBound() {
        let l = load(busy: 3, kids: 2, others: 0.5)
        XCTAssertEqual(feed(BottleneckClassifier(context: context()), producerBound(decode: 0.9, interp: 0.05, upscale: 0), l).kind, .decode)
        XCTAssertEqual(feed(BottleneckClassifier(context: context()), producerBound(decode: 0.1, interp: 0.85, upscale: 0), l).kind, .interpolation)
        XCTAssertEqual(feed(BottleneckClassifier(context: context()), producerBound(decode: 0.1, interp: 0.05, upscale: 0.8), l).kind, .upscale)
    }

    func testDiskBound() {
        let c = BottleneckClassifier(context: context())
        var l = load(busy: 2.5, kids: 1.5, others: 0.4); l.writeMBps = 950; l.driveMBps = 1000
        XCTAssertEqual(feed(c, cli(starved: 0.05), l).kind, .disk)
        let low = BottleneckClassifier(context: context())
        var l2 = load(busy: 13, kids: 12, others: 0.4); l2.diskLow = true
        let v = feed(low, to: 20, cli(starved: 0.05), l2)
        XCTAssertEqual(v.kind, .disk)
        XCTAssertTrue(v.headline.contains("almost full"))
    }

    func testThermalAndMemory() {
        var hot = load(busy: 13.6, kids: 12.5, others: 0.5); hot.thermal = 2
        let c = BottleneckClassifier(context: context())
        XCTAssertEqual(feed(c, to: 30, cli(starved: 0.05), hot).kind, .thermal)
        var tight = load(busy: 13.6, kids: 12.5, others: 0.5); tight.pressure = 2
        XCTAssertEqual(feed(BottleneckClassifier(context: context()), to: 20, cli(starved: 0.05), tight).kind, .memory)
        var swapping = load(busy: 13.6, kids: 12.5, others: 0.5); swapping.swapGrowthMBPerMin = 300
        XCTAssertEqual(feed(BottleneckClassifier(context: context()), to: 20, cli(starved: 0.05), swapping).kind, .memory)
    }

    func testHardwareEngineBound() {
        var ctx = context(segments: 2); ctx.hardware = true
        var p = PipelineWindow(); p.engineNotReady = 0.88; p.graderBlocked = 0.8; p.producerBlocked = 0.7; p.producerDecode = 0.3
        let v = feed(BottleneckClassifier(context: ctx), p, load(busy: 2, me: 1.6, kids: 0, others: 0.4, gpu: 0.3, gpuMine: 0.25))
        XCTAssertEqual(v.kind, .hardwareEngine)
        XCTAssertTrue(v.isGood)
        XCTAssertEqual(v.score ?? 0, 0.88, accuracy: 0.02)
        XCTAssertTrue(v.reason.contains("inferred"))
    }

    func testBusyMacDoesNotHideABusyMediaEngine() {
        var ctx = context(segments: 2); ctx.hardware = true
        var p = PipelineWindow(); p.engineNotReady = 0.75; p.graderBlocked = 0.7; p.producerBlocked = 0.6; p.producerDecode = 0.3
        let v = feed(BottleneckClassifier(context: ctx), p, load(busy: 13.9, me: 0.3, kids: 0, others: 13.6))
        XCTAssertEqual(v.kind, .hardwareEngine, "other apps' CPU doesn't limit a hardware encode that keeps Lumora waiting")
    }

    func testQualitySearchBound() {
        var ctx = context(); ctx.targetQuality = true
        var p = PipelineWindow(); p.chunksRenderBlocked = 0.85; p.chunksEncodersStarved = 0.05
        let v = feed(BottleneckClassifier(context: ctx), p, load(busy: 13.5, kids: 12.4, others: 0.5))
        XCTAssertEqual(v.kind, .qualitySearch)
        XCTAssertTrue(v.isGood)
    }

    func testMixed() {
        var p = cli(starved: 0.35); p.graderStarved = 0.3
        let v = feed(BottleneckClassifier(context: context()), p, load(busy: 9, kids: 7, others: 1))
        XCTAssertEqual(v.kind, .mixed)
    }

    func testPausedHasNoScore() {
        let c = BottleneckClassifier(context: context())
        feed(c, cli(starved: 0.05), load(busy: 13.6, kids: 12.5, others: 0.5))
        let v = feed(c, from: 41, to: 42, paused: "Paused: on battery", cli(starved: 0.05), load(busy: 1, kids: 0, others: 0.5))
        XCTAssertEqual(v.kind, .paused)
        XCTAssertNil(v.score)
        let back = feed(c, from: 43, to: 43, cli(starved: 0.05), load(busy: 13.6, kids: 12.5, others: 0.5))
        XCTAssertEqual(back.kind, .encoderSaturated, "the earlier verdict returns after a pause")
    }

    func testScoreFormula() {
        let l = load(busy: 14, me: 1, kids: 11, others: 2)
        XCTAssertEqual(BottleneckClassifier.cpuUse(l), 12.0 / 12.0, accuracy: 1e-9)
        XCTAssertEqual(BottleneckClassifier.cpuUse(load(busy: 12, me: 1, kids: 11, others: 0)), 12.0 / 14.0, accuracy: 1e-9)
        XCTAssertEqual(BottleneckClassifier.gpuUse(load(busy: 1, kids: 0, others: 0, gpu: 0.6, gpuMine: 0.3)), 0.3 / 0.7, accuracy: 1e-9)
        var unknown = load(busy: 1, kids: 0, others: 0, gpu: 0.6, gpuMine: 0.3); unknown.gpuOthersKnown = false
        XCTAssertEqual(BottleneckClassifier.gpuUse(unknown), 0.6, accuracy: 1e-9, "with Core ML running, the device total is used")
    }

    func testNoFlickerOnAlternatingInputs() {
        let c = BottleneckClassifier(context: context())
        let a = load(busy: 13.6, kids: 12.5, others: 0.5), b = load(busy: 6, kids: 5.2, others: 0.3)
        var kinds: [Bottleneck] = []
        for t in 1...80 {
            let v = c.update(ClassifierTick(time: Double(t), frames: t * 30, paused: nil, pipeline: cli(starved: 0.05), load: t % 2 == 0 ? a : b))
            if t > 15, kinds.last != v.kind { kinds.append(v.kind) }
        }
        XCTAssertLessThanOrEqual(kinds.count, 2, "verdict flickered: \(kinds)")
    }

    func testSwitchOnlyAfterPersistence() {
        let c = BottleneckClassifier(context: context())
        feed(c, cli(starved: 0.05), load(busy: 13.6, kids: 12.5, others: 0.5))
        var p = cli(starved: 0.9); p.graderStarved = 0.05; p.graderGPU = 0.95
        let gpuLoad = load(busy: 3, kids: 2, others: 0.5, gpu: 0.97, gpuMine: 0.95)
        let early = feed(c, from: 41, to: 43, p, gpuLoad)
        XCTAssertEqual(early.kind, .encoderSaturated, "one change in the numbers must not flip the verdict at once")
        let later = feed(c, from: 44, to: 80, p, gpuLoad)
        XCTAssertEqual(later.kind, .gpu)
    }

    // MARK: - Stalls

    func testSlowAV2FrameIsNotStalled() {
        // 90 s per frame, 120 s since the last one, encoder busy.
        let s = StallDetector.evaluate(StallInput(now: 1000, startedAt: 0, lastFrameAt: 880, paused: nil, finishing: nil,
                                                  p95FrameInterval: 90, setting: 60, childCores: 6, lastGPUAt: 880, lastGrowthAt: 990))
        XCTAssertFalse(s.isStalled, "\(s)")
        // Even with no CPU sign for a moment, the limit scales with this run's own frame time.
        let quiet = StallDetector.evaluate(StallInput(now: 1000, startedAt: 0, lastFrameAt: 880, paused: nil, finishing: nil,
                                                      p95FrameInterval: 90, setting: 60, childCores: 0))
        XCTAssertFalse(quiet.isStalled, "\(quiet)")
        XCTAssertEqual(StallDetector.limit(StallInput(now: 0, startedAt: 0, lastFrameAt: 0, p95FrameInterval: 90)), 720)
    }

    func testNoFramesAndNoActivityIsStalled() {
        let s = StallDetector.evaluate(StallInput(now: 300, startedAt: 0, lastFrameAt: 100, paused: nil, finishing: nil,
                                                  p95FrameInterval: 0.05, setting: 60, childCores: 0, lastGPUAt: 100, lastGrowthAt: 100,
                                                  waitingOn: "SvtAv1EncApp"))
        XCTAssertEqual(s, .stalled(seconds: 200, on: "SvtAv1EncApp"))
        XCTAssertEqual(s.text, "Stalled 3m: waiting on SvtAv1EncApp")
    }

    func testFlushingEncoderIsWaiting() {
        let s = StallDetector.evaluate(StallInput(now: 500, startedAt: 0, lastFrameAt: 200, paused: nil, finishing: nil,
                                                  p95FrameInterval: 0.1, setting: 60, childCores: 4, inputsClosed: true, waitingOn: "x265"))
        XCTAssertEqual(s, .waiting("x265 (finishing its last frames)"))
        XCTAssertEqual(s.text, "Waiting on x265 (finishing its last frames)")
    }

    func testPausedAndFinishing() {
        XCTAssertEqual(StallDetector.evaluate(StallInput(now: 500, startedAt: 0, lastFrameAt: 100, paused: "Paused: on battery")), .paused("Paused: on battery"))
        XCTAssertEqual(MonitoredRun.finishingStep(children: [.init(pid: 1, name: "ffmpeg", cores: 1, footprintMB: 10)]), "Finishing file: joining segments")
        XCTAssertEqual(StallDetector.evaluate(StallInput(now: 10, startedAt: 0, lastFrameAt: 9.9, p95FrameInterval: 0.05)), .rendering)
    }

    /// Measuring HDR light levels of a long film takes minutes before the first frame: never a stall while it
    /// reports progress, and a stall named after the step when it stops.
    func testPreparationStepIsNotAStall() {
        var i = StallInput(now: 600, startedAt: 0, lastFrameAt: nil, setting: 60)
        i.preparing = "Measuring HDR light levels (40%)"; i.preparingProgressAt = 590; i.preparingWaitingOn = "the HDR light-level measurement"
        XCTAssertEqual(StallDetector.evaluate(i), .preparing("Measuring HDR light levels (40%)"))
        i.preparingProgressAt = 400
        XCTAssertEqual(StallDetector.evaluate(i), .stalled(seconds: 200, on: "the HDR light-level measurement"))
        XCTAssertEqual(StallDetector.evaluate(i).text, "Stalled 3m: waiting on the HDR light-level measurement")
        i.paused = "Paused: on battery"
        XCTAssertEqual(StallDetector.evaluate(i), .paused("Paused: on battery"))
    }

    func testTrialLabels() {
        XCTAssertEqual(RenderProbe.trialLabel("chunk12-t2"), "Chunk 12 · trial 3 (quality search)")
        XCTAssertEqual(RenderProbe.trialLabel("chunk3-g0"), "Chunk 3 · raised quality 1 (perceptual check)")
        XCTAssertEqual(RenderProbe.trialLabel("chunk-2-t0"), "Size forecast sample 2")
    }
}
