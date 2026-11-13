import Foundation
import IOKit
import Darwin
import AppKit

/// One reading of the whole Mac, taken about once a second while something is rendering or the monitor is open.
/// Every counter comes from a public or documented interface (no admin rights): host CPU ticks, per-process resource
/// usage, the GPU's own utilization statistics, the kernel's memory pressure level, swap usage and thermal state.
struct SystemSample: Sendable {
    struct Child: Sendable, Hashable { var pid: Int32; var name: String; var cores: Double; var footprintMB: Double }
    struct App: Sendable, Hashable, Identifiable { var id: String { name }; var name: String; var cores: Double; var memoryMB: Double }

    var time: Double = 0                     // seconds, host clock (CACurrentMediaTime base)
    var primed = false                       // false on a sampler's first tick: every rate reads 0 then
    var interval: Double = 1
    var cores = 1
    var performanceCores = 0
    var efficiencyCores = 0
    var clusterMapApproximate = false
    var perCore: [Double] = []               // busy 0...1 per logical CPU
    var busyCores: Double = 0                // sum of per-core busy, in cores
    var performanceBusy: Double = 0          // 0...1 averaged over the P cluster
    var efficiencyBusy: Double = 0
    var selfCores: Double = 0                // Lumora itself
    var childCores: Double = 0               // encoders and other helper processes Lumora started
    var children: [Child] = []
    var othersCores: Double = 0              // everything else: busy - Lumora - children (exact, includes system)
    var gpuDevice: Double?                   // 0...1, the GPU's own "Device Utilization %"
    var gpuRenderer: Double?
    var gpuTiler: Double?
    var pressureLevel = 1                    // 1 normal, 2 warning, 4 critical
    var memoryFreePercent: Int?
    var swapUsedMB: Double = 0
    var swapTotalMB: Double = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    var lowPowerMode = false
    var selfFootprintMB: Double = 0
    var childFootprintMB: Double = 0
    var topAppsByCPU: [App] = []             // same-user processes, grouped by app (names only, local display)
    var topAppsByMemory: [App] = []
    var systemProcessesCores: Double = 0     // others that can't be named (root, other users)
    var appsScannedAt: Double = 0
    var costMs: Double = 0                   // CPU time this tick cost the sampler itself

    var othersFraction: Double { othersCores / Double(max(1, cores)) }
    var totalBusyFraction: Double { busyCores / Double(max(1, cores)) }
}

/// Reads the counters behind `SystemSample`. All work happens on one utility queue; readers get the latest sample.
final class SystemSampler: @unchecked Sendable {
    static let shared = SystemSampler()

    // User-initiated, not utility: the readings matter most when the Mac is overloaded, and on a saturated Mac a
    // utility thread was seen skipping several seconds of ticks. A tick costs about 0.3 ms of CPU.
    private let queue = DispatchQueue(label: "lumora.monitor.sampler", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var users = 0
    private var listeners: [UUID: (SystemSample) -> Void] = [:]
    private var latestSample = SystemSample()
    private var history: [SystemSample] = []
    private var appScanWanted = false
    private var forceAppScan = false

    // Sampling state (queue only)
    private var lastTicks: [UInt32] = []
    private var lastTime: Double = 0
    private var lastSelfCPU: UInt64 = 0
    private var lastChildCPU: [Int32: UInt64] = [:]
    private var lastChildTotal: UInt64 = 0   // every descendant's CPU so far, live and already exited
    private var childCPUTotal: Double = 0    // seconds, cumulative
    /// Helper CPU counted so far, in seconds (tests compare it with getrusage).
    var childCPUSeconds: Double { queue.sync { childCPUTotal } }
    private var lastAppCPU: [Int32: UInt64] = [:]
    private var lastAppScan: Double = 0
    private var cachedApps: ([SystemSample.App], [SystemSample.App], Double) = ([], [], 0)
    private var groupCache: [Int32: String] = [:]
    private(set) var ticks = 0
    private(set) var totalCostMs: Double = 0

    let timebase: (numer: UInt64, denom: UInt64) = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return (UInt64(tb.numer), UInt64(max(1, tb.denom)))
    }()
    let clusterMap: ClusterMap = ClusterMap.detect()

    var latest: SystemSample { lock.lock(); defer { lock.unlock() }; return latestSample }
    var recent: [SystemSample] { lock.lock(); defer { lock.unlock() }; return history }
    var averageCostMs: Double { lock.lock(); defer { lock.unlock() }; return ticks > 0 ? totalCostMs / Double(ticks) : 0 }

    /// Starts sampling (once a second) for one more user; `release()` stops it when nobody needs it.
    func retain() {
        // Checked and created under one lock, so two first users at once can't start two timers.
        lock.lock(); defer { lock.unlock() }
        users += 1
        guard timer == nil else { return }
        // After an idle gap the first tick only sets the baseline (instead of averaging over the gap).
        queue.async { [weak self] in self?.lastTime = 0 }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func release() {
        lock.lock()
        users = max(0, users - 1)
        let stop = users == 0 ? timer : nil
        if users == 0 { timer = nil }
        lock.unlock()
        stop?.cancel()
    }

    /// While on, the (heavier, every 5 s) scan of other apps runs, so the monitor can name what else is busy.
    /// Turning it on scans at the next tick; asking again while it is on keeps the 5 s pace.
    func wantAppScan(_ on: Bool) { lock.lock(); if on && !appScanWanted { forceAppScan = true }; appScanWanted = on; lock.unlock() }

    @discardableResult
    func observe(_ f: @escaping (SystemSample) -> Void) -> UUID {
        let id = UUID()
        lock.lock(); listeners[id] = f; lock.unlock()
        return id
    }
    func stopObserving(_ id: UUID) { lock.lock(); listeners[id] = nil; lock.unlock() }

    /// Takes one sample now (on the caller's thread). Tests use it; the timer calls it once a second.
    @discardableResult
    func sampleNow() -> SystemSample { queue.sync { tick() } ; return latest }

    // MARK: - Tick

    private func tick() {
        let cpu0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let now = CACurrentMediaTimeCompat()
        var s = SystemSample()
        s.time = now
        s.interval = lastTime > 0 ? max(0.05, now - lastTime) : 1
        let first = lastTime == 0
        s.primed = !first
        lastTime = now

        readCPU(&s)
        let me = getpid()
        let mine = Self.rusage(me)
        if let r = mine {
            let cpu = r.ri_user_time + r.ri_system_time
            if !first, cpu >= lastSelfCPU { s.selfCores = ns(cpu - lastSelfCPU) / 1e9 / s.interval }
            lastSelfCPU = cpu
            s.selfFootprintMB = Double(r.ri_phys_footprint) / 1_048_576
        }
        readChildren(&s, first: first, reaped: mine.map { $0.ri_child_user_time + $0.ri_child_system_time } ?? 0)
        s.othersCores = max(0, s.busyCores - s.selfCores - s.childCores)
        readGPU(&s)
        readMemory(&s)
        s.thermal = ProcessInfo.processInfo.thermalState
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        lock.lock(); let scan = appScanWanted && (forceAppScan || now - lastAppScan >= 5); forceAppScan = false; lock.unlock()
        if scan { scanApps(now: now); lastAppScan = now }
        if appScanWanted || now - cachedApps.2 < 15 {
            s.topAppsByCPU = cachedApps.0
            s.topAppsByMemory = cachedApps.1
            s.appsScannedAt = cachedApps.2
            let named = s.topAppsByCPU.reduce(0) { $0 + $1.cores }
            s.systemProcessesCores = max(0, s.othersCores - named)
        }
        let cost = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu0) / 1e6
        s.costMs = cost
        lock.lock()
        latestSample = s
        history.append(s)
        if history.count > 150 { history.removeFirst(history.count - 150) }
        ticks += 1
        totalCostMs += cost
        let ls = Array(listeners.values)
        lock.unlock()
        for l in ls { l(s) }
    }

    private func ns(_ ticks: UInt64) -> Double { Double(ticks) * Double(timebase.numer) / Double(timebase.denom) }

    private func readCPU(_ s: inout SystemSample) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { lastTicks = ticks }
        let n = Int(count)
        s.cores = n
        let map = clusterMap.kinds(count: n)
        s.clusterMapApproximate = clusterMap.approximate
        s.performanceCores = map.filter { $0 == .performance }.count
        s.efficiencyCores = map.filter { $0 == .efficiency }.count
        guard lastTicks.count == ticks.count else { s.perCore = Array(repeating: 0, count: n); return }
        var per: [Double] = []
        per.reserveCapacity(n)
        let stride = Int(CPU_STATE_MAX)
        for c in 0..<n {
            let b = c * stride
            let user = UInt64(ticks[b + Int(CPU_STATE_USER)] &- lastTicks[b + Int(CPU_STATE_USER)])
            let sys = UInt64(ticks[b + Int(CPU_STATE_SYSTEM)] &- lastTicks[b + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(ticks[b + Int(CPU_STATE_NICE)] &- lastTicks[b + Int(CPU_STATE_NICE)])
            let idle = UInt64(ticks[b + Int(CPU_STATE_IDLE)] &- lastTicks[b + Int(CPU_STATE_IDLE)])
            let total = user + sys + nice + idle
            per.append(total > 0 ? Double(user + sys + nice) / Double(total) : 0)
        }
        s.perCore = per
        s.busyCores = per.reduce(0, +)
        var p = 0.0, e = 0.0
        for (i, v) in per.enumerated() { if map[safe: i] == .efficiency { e += v } else { p += v } }
        s.performanceBusy = s.performanceCores > 0 ? p / Double(s.performanceCores) : 0
        s.efficiencyBusy = s.efficiencyCores > 0 ? e / Double(s.efficiencyCores) : 0
    }

    /// Lumora's child processes (and theirs), with CPU since the last tick and memory footprint.
    ///
    /// The total counts every helper's CPU, including helpers that started and exited between two ticks (a
    /// quality-search trial, a metric call): it is the change in (CPU of the live descendants, each with the helpers
    /// it has reaped) + (CPU of the helpers Lumora has reaped, `reaped`). A helper that exits moves its CPU from the
    /// first term to the second, so nothing is lost or counted twice, and none of it is booked as other apps.
    private func readChildren(_ s: inout SystemSample, first: Bool, reaped: UInt64) {
        var seen: [Int32: UInt64] = [:]
        var kids: [SystemSample.Child] = []
        var stack = Self.childPIDs(getpid())
        var depth = 0
        var total = reaped
        while !stack.isEmpty, depth < 64 {
            let pid = stack.removeFirst()
            depth += 1
            guard seen[pid] == nil, let r = Self.rusage(pid) else { continue }
            let cpu = r.ri_user_time + r.ri_system_time + r.ri_child_user_time + r.ri_child_system_time
            seen[pid] = cpu
            total += cpu
            var cores = 0.0
            if !first {
                // A helper not seen at the last tick started since then: all of its CPU belongs to this interval.
                let since = lastChildCPU[pid].map { cpu >= $0 ? cpu - $0 : cpu } ?? cpu
                cores = ns(since) / 1e9 / s.interval
            }
            let name = ChildPolicy.shared.name(for: pid) ?? Self.processName(pid)
            kids.append(.init(pid: pid, name: name, cores: cores, footprintMB: Double(r.ri_phys_footprint) / 1_048_576))
            ChildPolicy.shared.sweep(pid: pid, name: name)
            stack += Self.childPIDs(pid)
        }
        // A helper whose parent exited first leaves Lumora's tree: the total can drop; that is not negative work.
        if !first, total >= lastChildTotal {
            let d = ns(total - lastChildTotal) / 1e9
            s.childCores = d / s.interval
            childCPUTotal += d
        }
        lastChildTotal = total
        lastChildCPU = seen
        s.children = kids.sorted { $0.cores > $1.cores }
        s.childFootprintMB = kids.reduce(0) { $0 + $1.footprintMB }
    }

    private func readGPU(_ s: inout SystemSample) {
        var it = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var service = IOIteratorNext(it)
        while service != 0 {
            if s.gpuDevice == nil,
               let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                if let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue { s.gpuDevice = min(1, max(0, u / 100)) }
                if let u = (stats["Renderer Utilization %"] as? NSNumber)?.doubleValue { s.gpuRenderer = min(1, max(0, u / 100)) }
                if let u = (stats["Tiler Utilization %"] as? NSNumber)?.doubleValue { s.gpuTiler = min(1, max(0, u / 100)) }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(it)
        }
    }

    private func readMemory(_ s: inout SystemSample) {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { s.pressureLevel = Int(level) }
        var free: Int32 = 0
        size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &free, &size, nil, 0) == 0 { s.memoryFreePercent = Int(free) }
        var swap = xsw_usage()
        size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsedMB = Double(swap.xsu_used) / 1_048_576
            s.swapTotalMB = Double(swap.xsu_total) / 1_048_576
        }
    }

    /// Same-user processes grouped by app. Other users' and system processes can't be read without admin rights;
    /// their share is still exact in `othersCores` (from host CPU ticks) and shown as "system processes".
    private func scanApps(now: Double) {
        let me = getpid()
        let mine = Set(lastChildCPU.keys)
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return }
        let dt = lastAppScan > 0 ? max(0.5, now - lastAppScan) : 0
        var cpuByGroup: [String: Double] = [:]
        var memByGroup: [String: Double] = [:]
        var seen: [Int32: UInt64] = [:]
        for pid in pids.prefix(Int(got)) where pid > 0 && pid != me && !mine.contains(pid) {
            guard let r = Self.rusage(pid) else { continue }
            let cpu = r.ri_user_time + r.ri_system_time
            seen[pid] = cpu
            let group = groupCache[pid] ?? Self.appGroup(pid)
            groupCache[pid] = group
            if dt > 0, let last = lastAppCPU[pid], cpu >= last { cpuByGroup[group, default: 0] += ns(cpu - last) / 1e9 / dt }
            memByGroup[group, default: 0] += Double(r.ri_phys_footprint) / 1_048_576
        }
        lastAppCPU = seen
        groupCache = groupCache.filter { seen[$0.key] != nil }
        let apps = Set(cpuByGroup.keys).union(memByGroup.keys).map {
            SystemSample.App(name: $0, cores: cpuByGroup[$0] ?? 0, memoryMB: memByGroup[$0] ?? 0)
        }
        cachedApps = (Array(apps.filter { $0.cores >= 0.05 }.sorted { $0.cores > $1.cores }.prefix(8)),
                      Array(apps.sorted { $0.memoryMB > $1.memoryMB }.prefix(8)), now)
    }

    // MARK: - Process helpers

    static func rusage(_ pid: Int32) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? info : nil
    }

    static func childPIDs(_ pid: Int32) -> [Int32] {
        var buf = [Int32](repeating: 0, count: 64)
        let n = buf.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        return Array(buf.prefix(Int(min(n, 64)))).filter { $0 > 0 }
    }

    static func processPath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    static func processName(_ pid: Int32) -> String {
        processPath(pid).map { ($0 as NSString).lastPathComponent } ?? "process \(pid)"
    }

    /// The display name a person would recognize: the outermost .app bundle the executable lives in, else its name.
    static func appGroup(_ pid: Int32) -> String {
        guard let path = processPath(pid) else { return "Other processes" }
        return groupName(path: path)
    }

    static func groupName(path: String) -> String {
        let parts = path.split(separator: "/")
        if let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            return String(parts[i].dropLast(4))
        }
        return String(parts.last ?? "process")
    }
}

/// Which logical CPUs are performance and which are efficiency cores.
struct ClusterMap: Sendable {
    enum Kind: Sendable { case performance, efficiency }
    var byCPU: [Int: Kind]
    var approximate: Bool

    func kinds(count: Int) -> [Kind] { (0..<count).map { byCPU[$0] ?? .performance } }

    /// The device tree names each CPU's cluster ("E"/"P") and logical id. If that can't be read, the perflevel
    /// counts are used with the efficiency cores assumed at the lowest indices (labeled approximate).
    static func detect() -> ClusterMap {
        var map: [Int: Kind] = [:]
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            var it = io_iterator_t()
            if IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &it) == KERN_SUCCESS {
                var e = IOIteratorNext(it)
                while e != 0 {
                    let type = (IORegistryEntryCreateCFProperty(e, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? Data).flatMap { String(data: $0, encoding: .ascii) }
                    let raw = IORegistryEntryCreateCFProperty(e, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                    var id: Int?
                    if let n = raw as? NSNumber { id = n.intValue }
                    else if let d = raw as? Data, d.count >= 4 { id = d.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) } }
                    if let type, let id {
                        map[id] = type.hasPrefix("E") ? .efficiency : .performance
                    }
                    IOObjectRelease(e)
                    e = IOIteratorNext(it)
                }
                IOObjectRelease(it)
            }
            IOObjectRelease(cpus)
        }
        if !map.isEmpty { return ClusterMap(byCPU: map, approximate: false) }
        let p = sysctl("hw.perflevel0.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let e = sysctl("hw.perflevel1.logicalcpu") ?? 0
        for i in 0..<(p + e) { map[i] = i < e ? .efficiency : .performance }
        return ClusterMap(byCPU: map, approximate: true)
    }

    static func sysctl(_ name: String) -> Int? {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &size, nil, 0) == 0 ? Int(v) : nil
    }
}

/// Host clock in seconds, on the same base as Metal's `gpuStartTime` / `gpuEndTime`.
@inline(__always) func CACurrentMediaTimeCompat() -> Double {
    struct TB { static let scale: Double = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) / 1e9 }() }
    return Double(mach_absolute_time()) * TB.scale
}
