import XCTest
@testable import Lumora

/// The live load readings: cluster map, per-process CPU of child processes, timebase conversion and the sampler's
/// own cost. Headless: the only child process is a niced `yes` writing to /dev/null for a couple of seconds.
final class MonitorSamplerTests: XCTestCase {
    func testClusterMapAndRanges() {
        let sampler = SystemSampler.shared
        sampler.sampleNow()
        Thread.sleep(forTimeInterval: 0.3)
        let s = sampler.sampleNow()
        let p = ClusterMap.sysctl("hw.perflevel0.logicalcpu") ?? 0
        let e = ClusterMap.sysctl("hw.perflevel1.logicalcpu") ?? 0
        XCTAssertEqual(s.cores, ProcessInfo.processInfo.activeProcessorCount)
        if p + e > 0 { XCTAssertEqual(s.performanceCores + s.efficiencyCores, p + e) }
        XCTAssertEqual(s.efficiencyCores, e)
        XCTAssertFalse(SystemSampler.shared.clusterMap.approximate, "the device tree names each CPU's cluster on Apple silicon")
        XCTAssertTrue((0...1).contains(s.performanceBusy))
        XCTAssertTrue((0...1).contains(s.efficiencyBusy))
        XCTAssertEqual(s.perCore.count, s.cores)
        XCTAssertTrue(s.perCore.allSatisfy { (0...1).contains($0) })
        if let g = s.gpuDevice { XCTAssertTrue((0...1).contains(g)) }
        XCTAssertTrue([1, 2, 4].contains(s.pressureLevel), "pressure level \(s.pressureLevel)")
        XCTAssertGreaterThanOrEqual(s.othersCores, 0)
        XCTAssertGreaterThan(s.selfFootprintMB, 1)
        print("Sampler: \(s.cores) CPUs (\(s.performanceCores) P, \(s.efficiencyCores) E\(s.clusterMapApproximate ? ", approximate" : "")), busy \(String(format: "%.1f", s.busyCores)) cores, GPU \(s.gpuDevice.map { "\(Int($0 * 100))%" } ?? "n/a"), pressure \(s.pressureLevel), swap \(Int(s.swapUsedMB)) MB")
    }

    func testChildProcessIsMeasuredAndNiced() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.runWatched()
        defer { if p.isRunning { p.terminate() } }
        XCTAssertEqual(ChildPolicy.niceness(of: p.processIdentifier), ChildPolicy.singleNice, "children start niced")
        let sampler = SystemSampler.shared
        sampler.sampleNow()
        Thread.sleep(forTimeInterval: 1.0)
        sampler.sampleNow()
        Thread.sleep(forTimeInterval: 1.0)
        let s = sampler.sampleNow()
        let child = try XCTUnwrap(s.children.first { $0.pid == p.processIdentifier }, "child not found in \(s.children.map(\.name))")
        XCTAssertEqual(child.name, "yes")
        XCTAssertGreaterThanOrEqual(child.cores, 0.3, "a busy child should read as a sizable share of a core")
        XCTAssertLessThanOrEqual(child.cores, 1.2)
        XCTAssertGreaterThanOrEqual(s.childCores, child.cores - 0.001)
        XCTAssertEqual(s.othersCores, max(0, s.busyCores - s.selfCores - s.childCores), accuracy: 0.0001)
        print(String(format: "Child yes: %.2f cores; Lumora %.2f, children %.2f, others %.2f of %d", child.cores, s.selfCores, s.childCores, s.othersCores, s.cores))
    }

    func testTimebaseConversionIsSane() throws {
        let r = try XCTUnwrap(SystemSampler.rusage(getpid()))
        let tb = SystemSampler.shared.timebase
        let cpuSeconds = Double(r.ri_user_time + r.ri_system_time) * Double(tb.numer) / Double(tb.denom) / 1e9
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        XCTAssertEqual(sysctl(&mib, 4, &kinfo, &size, nil, 0), 0)
        let started = Double(kinfo.kp_proc.p_un.__p_starttime.tv_sec) + Double(kinfo.kp_proc.p_un.__p_starttime.tv_usec) / 1e6
        let wall = Date().timeIntervalSince1970 - started
        XCTAssertGreaterThan(cpuSeconds, 0)
        XCTAssertLessThanOrEqual(cpuSeconds, wall * Double(ProcessInfo.processInfo.activeProcessorCount) + 1,
                                 "CPU time \(cpuSeconds) s can't exceed wall \(wall) s × cores")
    }

    func testSamplerCostIsTiny() {
        let sampler = SystemSampler.shared
        var costs: [Double] = []
        for _ in 0..<20 {
            costs.append(sampler.sampleNow().costMs)
            Thread.sleep(forTimeInterval: 0.05)
        }
        let avg = costs.dropFirst().reduce(0, +) / Double(costs.count - 1)
        print(String(format: "Sampler cost: average %.2f ms per tick (max %.2f ms) = %.3f%% of one core at 1 Hz", avg, costs.max() ?? 0, avg / 10))
        XCTAssertLessThan(avg, 10, "a 1 Hz tick must stay under 1% of one core")
        // With the app scan (every 5 s while the overload panel is open) included.
        sampler.wantAppScan(true)
        let withScan = sampler.sampleNow().costMs
        sampler.wantAppScan(false)
        print(String(format: "Sampler tick with the other-apps scan: %.2f ms", withScan))
        XCTAssertLessThan(withScan, 50)
    }

    /// Helpers that start and exit between two ticks (quality-search trials, metric calls) are still Lumora's CPU,
    /// not other apps': the sampler counts what reaped helpers used, checked against getrusage(RUSAGE_CHILDREN).
    func testShortLivedHelpersAreCounted() throws {
        let sampler = SystemSampler.shared
        sampler.sampleNow()
        let before = sampler.childCPUSeconds
        var r0 = rusage(); getrusage(RUSAGE_CHILDREN, &r0)
        for _ in 0..<3 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "i=0; while [ $i -lt 60000 ]; do i=$((i+1)); done"]
            try p.run()
            p.waitUntilExit()
        }
        var r1 = rusage(); getrusage(RUSAGE_CHILDREN, &r1)
        sampler.sampleNow()
        let counted = sampler.childCPUSeconds - before
        func secs(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        let reaped = secs(r1.ru_utime) + secs(r1.ru_stime) - secs(r0.ru_utime) - secs(r0.ru_stime)
        print(String(format: "Short-lived helpers: %.3f CPU-s by getrusage, %.3f CPU-s counted by the sampler", reaped, counted))
        XCTAssertGreaterThan(reaped, 0.005)
        XCTAssertGreaterThan(counted, reaped * 0.8, "helpers that lived between two ticks were missed")
        XCTAssertLessThan(counted, reaped * 1.25 + 0.05, "counted twice")
    }

    /// The other-apps scan keeps its 5 s pace however often it is asked for.
    func testAppScanKeepsItsPace() {
        let sampler = SystemSampler.shared
        sampler.wantAppScan(false)
        sampler.wantAppScan(true)
        let first = sampler.sampleNow().appsScannedAt
        XCTAssertGreaterThan(first, 0, "turning the scan on scans at once")
        for _ in 0..<3 {
            sampler.wantAppScan(true)                    // what every monitor tick does while the panel is open
            XCTAssertEqual(sampler.sampleNow().appsScannedAt, first, "scanned again within 5 s")
        }
        sampler.wantAppScan(false)
    }

    /// The GPU probe's command really runs on the GPU (an empty command buffer never does), and its wait is timed
    /// by the GPU's own end timestamp.
    func testGPUProbeRunsOnTheGPU() throws {
        try TestHardware.requireGPU()
        let r = ResponsivenessProbe.shared.probeGPUSpan()
        print(String(format: "GPU probe: GPU span %.3f ms, wait until done %.3f ms", r.span, r.wait ?? -1))
        XCTAssertGreaterThan(r.span, 0, "the probe must execute on the GPU")
        XCTAssertNotNil(r.wait)
    }

    /// Each export's responsiveness covers only its own readings, also after the kept readings reach their cap.
    func testResponsivenessMarkSurvivesTheCap() {
        let probe = ResponsivenessProbe.shared
        probe.resetReadings()
        for _ in 0..<1300 { probe.record(mainMs: 2, rendering: true) }
        let mark = probe.mark()
        for _ in 0..<10 { probe.record(mainMs: 50, rendering: true) }
        let s = probe.busyMain(since: mark)
        XCTAssertEqual(s.count, 10)
        XCTAssertEqual(s.p50, 50)
        XCTAssertNil(probe.idleBaseline, "a few idle pings are no baseline")
        for _ in 0..<ResponsivenessProbe.baselineMinimum { probe.record(mainMs: 3, rendering: false) }
        XCTAssertEqual(probe.idleBaseline?.p95, 3)
        probe.resetReadings()
    }

    func testAppGroupingByBundle() {
        XCTAssertEqual(SystemSampler.groupName(path: "/Applications/Safari.app/Contents/MacOS/Safari"), "Safari")
        XCTAssertEqual(SystemSampler.groupName(path: "/Applications/Xcode.app/Contents/Developer/Toolchains/X.xctoolchain/usr/bin/swift-frontend"), "Xcode")
        XCTAssertEqual(SystemSampler.groupName(path: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"), "Google Chrome")
        XCTAssertEqual(SystemSampler.groupName(path: "/opt/homebrew/bin/avmenc"), "avmenc")
    }
}
