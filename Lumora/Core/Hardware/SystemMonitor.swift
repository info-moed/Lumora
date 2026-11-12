import Foundation
import IOKit
import Darwin

/// Live CPU, GPU, memory and thermal readings (once a second) for the optimizer and activity views.
@MainActor
@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()
    var cpu: Double = 0
    var gpu: Double?
    var memory: Double = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    var history: [(cpu: Double, gpu: Double)] = []
    private var timer: Timer?
    private var lastTicks: [UInt32] = []

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    var thermalText: String {
        switch thermal { case .nominal: return "Cool"; case .fair: return "Warm"; case .serious: return "Hot (throttling)"; case .critical: return "Critical"; @unknown default: return "?" }
    }

    private func sample() {
        cpu = cpuLoad()
        gpu = gpuUtilization()
        memory = memoryUsed()
        thermal = ProcessInfo.processInfo.thermalState
        history.append((cpu, gpu ?? 0))
        if history.count > 120 { history.removeFirst() }
    }

    private func cpuLoad() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return cpu }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { lastTicks = ticks }
        guard lastTicks.count == ticks.count else { return 0 }
        var busy: UInt64 = 0, total: UInt64 = 0
        for c in 0..<Int(count) {
            let b = c * Int(CPU_STATE_MAX)
            let d = (0..<Int(CPU_STATE_MAX)).map { UInt64(ticks[b + $0] &- lastTicks[b + $0]) }
            busy += d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
            total += d.reduce(0, +)
        }
        return total > 0 ? Double(busy) / Double(total) : 0
    }

    private func gpuUtilization() -> Double? {
        var it = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var result: Double?
        var service = IOIteratorNext(it)
        while service != 0 {
            if result == nil,
               let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
               let u = stats["Device Utilization %"] as? Int {
                result = Double(u) / 100
            }
            IOObjectRelease(service)
            service = IOIteratorNext(it)
        }
        return result
    }

    private func memoryUsed() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard ok == KERN_SUCCESS else { return memory }
        let used = UInt64(stats.active_count + stats.wire_count + stats.compressor_page_count) * UInt64(vm_kernel_page_size)
        return Double(used) / Double(ProcessInfo.processInfo.physicalMemory)
    }
}
