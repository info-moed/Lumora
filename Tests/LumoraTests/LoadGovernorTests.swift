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

    override func tearDown() {
        g.reset()
        LoadGovernor.recoverySeconds = savedRecovery
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
