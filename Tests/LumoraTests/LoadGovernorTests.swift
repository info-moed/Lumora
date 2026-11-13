import XCTest
@testable import Lumora

/// How Lumora backs off when the Mac is under pressure, from synthetic samples (no real load is created).
final class LoadGovernorTests: XCTestCase {
    let g = LoadGovernor.shared
    private var savedRecovery = 10.0

    override func setUp() {
        savedRecovery = LoadGovernor.recoverySeconds
        LoadGovernor.recoverySeconds = 0
        g.reset()
    }

    private var savedReader: (() -> Int?)!

    override func tearDown() {
        g.reset()
        LoadGovernor.recoverySeconds = savedRecovery
        if let savedReader { LoadGovernor.pressureReader = savedReader }
    }

    func sample(t: Double, pressure: Int = 1, thermal: ProcessInfo.ThermalState = .nominal, busy: Double = 4, others: Double = 1) -> SystemSample {
        var s = SystemSample()
        s.time = t; s.cores = 14; s.busyCores = busy; s.othersCores = others; s.pressureLevel = pressure; s.thermal = thermal
        s.topAppsByCPU = [.init(name: "Busy App", cores: 7, memoryMB: 900), .init(name: "Browser", cores: 1.2, memoryMB: 3000)]
        s.topAppsByMemory = [.init(name: "Browser", cores: 1.2, memoryMB: 3000)]
        return s
    }

    func testMemoryWarningHalvesAndCriticalPauses() {
        g.observe(sample(t: 1, pressure: 2), rendering: true)
        XCTAssertEqual(g.limit(4), 2)
        XCTAssertNil(g.pauseReason)
        g.observe(sample(t: 2, pressure: 4), rendering: true)
        XCTAssertEqual(g.limit(4), 1)
        XCTAssertNotNil(g.pauseReason)
        XCTAssertTrue(g.pauseReason?.contains("memory") ?? false)
        g.observe(sample(t: 3, pressure: 1), rendering: true)
        XCTAssertNil(g.pauseReason, "work resumes once memory pressure is normal again")
        XCTAssertEqual(g.limit(4), 4)
    }

    func testThermalPacesAndLowersConcurrency() {
        g.observe(sample(t: 1, thermal: .serious), rendering: true)
        XCTAssertEqual(g.current.pacing, 0.2, accuracy: 1e-9)
        XCTAssertEqual(g.limit(3), 2)
        g.observe(sample(t: 2, thermal: .nominal), rendering: true)
        XCTAssertEqual(g.current.pacing, 0)
    }

    func testOverloadNeedsFifteenSecondsSustained() {
        for t in 0...14 { g.observe(sample(t: Double(t), busy: 13.8, others: 8), rendering: true) }
        XCTAssertNil(g.current.overload)
        g.observe(sample(t: 15.5, busy: 13.8, others: 8), rendering: true)
        let o = try? XCTUnwrap(g.current.overload)
        XCTAssertEqual(o?.topByCPU.first?.name, "Busy App")
        XCTAssertTrue(o?.reasons.first?.contains("8 of 14 cores") ?? false, "\(o?.reasons ?? [])")
        // Continue snoozes it.
        g.choose(.continued)
        g.observe(sample(t: 17, busy: 13.8, others: 8), rendering: true)
        XCTAssertNil(g.current.overload)
        // Not rendering: never an alarm.
        g.reset()
        for t in 0...30 { g.observe(sample(t: Double(t), busy: 13.8, others: 8), rendering: false) }
        XCTAssertNil(g.current.overload)
    }

    /// The warning belongs to the render it was raised for: once the last render ends it goes, and the next export
    /// starts its own 15-second clock (only `observe` cleared it before, and that runs only while rendering).
    func testOverloadEndsWithTheLastRender() {
        for t in 0...16 { g.observe(sample(t: Double(t), busy: 13.8, others: 8), rendering: true) }
        XCTAssertNotNil(g.current.overload)
        g.renderingEnded()
        XCTAssertNil(g.current.overload)
        XCTAssertFalse(g.overloadSuspected)
        g.observe(sample(t: 100, busy: 13.8, others: 8), rendering: true)
        XCTAssertNil(g.current.overload, "a new render needs its own 15 seconds of overload")
    }

    func testLowerPriorityPacesAndIsRevocable() {
        g.choose(.lowerPriority)
        XCTAssertEqual(g.current.pacing, 0.5, accuracy: 1e-9)
        XCTAssertTrue(ChildPolicy.shared.lowerPriority)
        g.choose(.none)
        XCTAssertEqual(g.current.pacing, 0)
        XCTAssertFalse(ChildPolicy.shared.lowerPriority)
    }

    func testPauseChoiceHoldsWork() async throws {
        g.choose(.paused)
        let started = Date()
        let t = Task { await LoadGovernor.shared.holdIfNeeded() }
        try await Task.sleep(nanoseconds: 300_000_000)
        g.choose(.none)
        await t.value
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.25)
    }

    /// A critical-pressure pause with nothing monitoring (a batch between files): the normal event came within the
    /// recovery time and was ignored, and no further event comes. The pause must still end once memory is fine.
    func testMemoryPauseEndsWithoutFurtherEvents() async throws {
        savedReader = LoadGovernor.pressureReader
        LoadGovernor.recoverySeconds = 1.5
        g.setPressure(4, source: "event")
        g.setPressure(1, source: "event")               // too soon: ignored
        XCTAssertNotNil(g.current.memoryPause)
        LoadGovernor.pressureReader = { 1 }               // the kernel reports normal from now on
        let started = Date()
        let hold = Task { await LoadGovernor.shared.holdIfNeeded() }
        let watchdog = Task { try await Task.sleep(nanoseconds: 8_000_000_000); hold.cancel() }
        await hold.value
        watchdog.cancel()
        let waited = Date().timeIntervalSince(started)
        XCTAssertNil(g.current.memoryPause, "the pause latched after \(waited) s")
        XCTAssertLessThan(waited, 6)
    }

    /// A hot Mac moves the helpers (where a CLI encode's heat is) to the background band, and back once it cools.
    func testThermalBackoffMovesHelpersToTheBackgroundBand() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["20"]
        try p.runWatched()
        defer { if p.isRunning { p.terminate() } }
        XCTAssertEqual(ChildPolicy.inBackground(p.processIdentifier), false)
        g.observe(sample(t: 1, thermal: .serious), rendering: true)
        XCTAssertTrue(g.current.thermalBackoff)
        XCTAssertTrue(ChildPolicy.shared.thermalBackoff)
        XCTAssertEqual(g.current.pacingReason, "while the Mac is hot")
        XCTAssertEqual(ChildPolicy.inBackground(p.processIdentifier), true)
        g.observe(sample(t: 2, thermal: .nominal), rendering: true)
        XCTAssertFalse(ChildPolicy.shared.thermalBackoff)
        XCTAssertEqual(ChildPolicy.inBackground(p.processIdentifier), false)
        // The person's Lower priority outlasts a cooled Mac.
        g.choose(.lowerPriority)
        g.observe(sample(t: 3, thermal: .serious), rendering: true)
        g.observe(sample(t: 4, thermal: .nominal), rendering: true)
        XCTAssertEqual(ChildPolicy.inBackground(p.processIdentifier), true)
        g.choose(.none)
        XCTAssertEqual(ChildPolicy.inBackground(p.processIdentifier), false)
    }

    func testGPUPacingSaysWhyAndClears() {
        g.setGPULatency(p90Ms: 20)
        XCTAssertEqual(g.current.pacing, 0.15, accuracy: 1e-9)
        XCTAssertTrue(g.current.pacingReason?.contains("display") ?? false)
        g.setGPULatency(p90Ms: nil)                        // what a new export does at its start
        XCTAssertEqual(g.current.pacing, 0)
        XCTAssertNil(g.current.pacingReason)
    }

    func testDiskPauseCallsHook() {
        var hooked: String?
        RenderHooks.pausedForDisk = { hooked = $0 }
        defer { RenderHooks.pausedForDisk = nil }
        g.setDiskPause("Paused: Test is almost full. Free 3 GB to continue.")
        XCTAssertEqual(hooked, "Paused: Test is almost full. Free 3 GB to continue.")
        XCTAssertEqual(g.pauseReason, hooked)
        g.setDiskPause(nil)
        XCTAssertNil(g.pauseReason)
    }
}
