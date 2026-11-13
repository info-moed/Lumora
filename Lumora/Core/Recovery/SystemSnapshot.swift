import Foundation
import Darwin

/// The state of the Mac at a moment (export start, every heartbeat, the moment of a failure): enough to tell a full
/// disk, memory pressure, heat or a sleep from an encoder bug.
struct SystemSnapshot: Codable, Hashable {
    enum Pressure: String, Codable { case normal, warning, critical }

    var date = Date()
    var scratchFree: Int64?
    var scratchTotal: Int64?
    var scratchVolume: String?
    var outputFree: Int64?
    var outputVolume: String?
    var memoryFreeBytes: Int64 = 0         // free + inactive pages
    var compressedBytes: Int64 = 0
    var swapUsedBytes: Int64 = 0
    var pressure: Pressure = .normal
    var thermal: String = "nominal"
    var onBattery = false
    var lowPowerMode = false
    var uptimeSeconds: Double = 0
    var bootSession: String = ""
    var appResidentBytes: Int64 = 0
    var openFiles: Int = 0
    var sleeps: [SleepEvent] = []

    struct SleepEvent: Codable, Hashable { var slept: Date; var woke: Date? }

    /// Tests replace the live readings (memory pressure, sleep events, boot session) through this.
    nonisolated(unsafe) static var provider: (() -> SystemSnapshot)?

    static func capture(scratch: URL?, output: URL?, pressure: Pressure = MemoryPressureWatch.shared.level,
                        sleeps: [SleepEvent] = []) -> SystemSnapshot {
        if let p = provider { var s = p(); s.date = Date(); return s }
        var s = SystemSnapshot()
        if let scratch, let v = volume(scratch) { (s.scratchFree, s.scratchTotal, s.scratchVolume) = (v.free, v.total, v.name) }
        if let output, let v = volume(output.deletingLastPathComponent()) { (s.outputFree, s.outputVolume) = (v.free, v.name) }
        let vm = vmStats()
        s.memoryFreeBytes = vm.free
        s.compressedBytes = vm.compressed
        s.swapUsedBytes = swapUsed()
        s.pressure = pressure
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: s.thermal = "nominal"
        case .fair: s.thermal = "fair"
        case .serious: s.thermal = "serious"
        case .critical: s.thermal = "critical"
        @unknown default: s.thermal = "unknown"
        }
        s.onBattery = PowerState.onBattery
        s.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        s.uptimeSeconds = ProcessInfo.processInfo.systemUptime
        s.bootSession = bootSessionUUID()
        s.appResidentBytes = residentBytes()
        s.openFiles = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
        s.sleeps = sleeps
        return s
    }

    static func volume(_ url: URL) -> (free: Int64, total: Int64, name: String)? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        guard let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
                                                          .volumeNameKey, .volumeAvailableCapacityKey]) else { return nil }
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        return (free, Int64(v.volumeTotalCapacity ?? 0), v.volumeName ?? "this Mac")
    }

    /// `kern.bootsessionuuid`: changes on every restart, so a journal written before a power loss can tell.
    nonisolated(unsafe) static var bootSessionOverride: String?
    static func bootSessionUUID() -> String {
        if let o = bootSessionOverride { return o }
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }

    private static func vmStats() -> (free: Int64, compressed: Int64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        let page = Int64(vm_kernel_page_size)
        return ((Int64(stats.free_count) + Int64(stats.inactive_count)) * page, Int64(stats.compressor_page_count) * page)
    }

    private static func swapUsed() -> Int64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Int64(usage.xsu_used)
    }

    private static func residentBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    /// Lines for the log and the report ("SYSTEM" entries).
    var lines: [String] {
        func gb(_ b: Int64?) -> String { b.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown" }
        var out: [String] = []
        if let v = scratchVolume { out.append("scratch drive “\(v)”: \(gb(scratchFree)) free of \(gb(scratchTotal))") }
        if let v = outputVolume { out.append("output drive “\(v)”: \(gb(outputFree)) free") }
        out.append("memory: \(gb(memoryFreeBytes)) free or inactive, \(gb(compressedBytes)) compressed, swap \(gb(swapUsedBytes)), pressure \(pressure.rawValue)")
        out.append("thermal state \(thermal), \(onBattery ? "on battery" : "on power adapter")\(lowPowerMode ? ", Low Power Mode" : "")")
        out.append(String(format: "uptime %.0f min, Lumora uses %@, %d open files", uptimeSeconds / 60,
                          ByteCountFormatter.string(fromByteCount: appResidentBytes, countStyle: .memory), openFiles))
        for e in sleeps {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            out.append("slept at \(f.string(from: e.slept))" + (e.woke.map { ", woke at \(f.string(from: $0))" } ?? ", did not wake"))
        }
        return out
    }
}

/// The last memory-pressure level macOS reported (a dispatch source; cheap, always on once started).
final class MemoryPressureWatch: @unchecked Sendable {
    static let shared = MemoryPressureWatch()
    private let lock = NSLock()
    private var _level: SystemSnapshot.Pressure = .normal
    private var source: DispatchSourceMemoryPressure?
    /// Tests set this to simulate pressure.
    nonisolated(unsafe) static var override: SystemSnapshot.Pressure?

    var level: SystemSnapshot.Pressure {
        if let o = Self.override { return o }
        lock.lock(); defer { lock.unlock() }; return _level
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard source == nil else { return }
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let e = s.data
            let l: SystemSnapshot.Pressure = e.contains(.critical) ? .critical : (e.contains(.warning) ? .warning : .normal)
            self.lock.lock(); self._level = l; self.lock.unlock()
            RenderLog.broadcast(.system, "memory pressure is now \(l.rawValue)")
        }
        s.resume()
        source = s
    }
}
