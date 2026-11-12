import Foundation
import IOKit

/// Describes the Mac this is running on, so every stage can size itself to the silicon.
/// Tuned for M5 / M5 Pro / M5 Max: GPU Neural Accelerators, two video and ProRes engines on Max,
/// 18-core CPUs (6 super + 12 performance) on Pro and Max, and up to 614 GB/s unified memory.
struct ChipProfile: CustomStringConvertible {
    enum Tier: Int, Comparable {
        case base = 0, pro, max, ultra
        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    let brand: String
    let generation: Int
    let tier: Tier
    let cpuCores: Int
    let gpuCores: Int
    let memoryGB: Int

    static let current = ChipProfile.detect()

    var isM5OrLater: Bool { generation >= 5 }
    /// M5-generation GPUs put a Neural Accelerator in every GPU core (reached through Metal tensors / Core ML).
    var hasGPUNeuralAccelerators: Bool { generation >= 5 }
    /// Max-class chips have two video encode engines and two ProRes engines; Ultra fuses two Max dies.
    var videoEncodeEngines: Int {
        if let measured = MacProfile.current?.vtSessions { return measured }
        switch tier { case .ultra: return 4; case .max: return 2; default: return 1 }
    }
    /// Analysis grid width. More GPU and bandwidth -> finer scene statistics at no real cost.
    var analysisWidth: Int { tier >= .pro ? 960 : 640 }

    /// How many independent encoder instances to run over frame-range segments.
    func segments(for codec: Codec, frameCount: Int) -> Int {
        guard frameCount > 480 else { return 1 }
        if let measured = MacProfile.current?.cliInstances[codec.rawValue], codec.cliKey != nil { return measured }
        switch codec {
        case .hevc, .prores422HQ, .prores4444XQ:
            return videoEncodeEngines                     // one segment per hardware engine
        case .av1:
            return max(1, cpuCores / 8)                   // SVT-AV1 threads well; 2 instances on 18 cores
        case .vvc:
            return max(1, cpuCores / 4)                   // VVenC scales less per instance
        case .av2:
            return max(1, cpuCores / 2)                   // AVM reference encoder: many slow instances
        case .av1Pro:
            return max(1, cpuCores / 4)                   // libaom: limited row-mt scaling per instance
        case .hevc12:
            return max(1, cpuCores / 8)                   // x265 uses its own thread pool well
        }
    }

    func threadsPerSegment(segments: Int) -> Int { max(1, cpuCores / max(1, segments)) }

    var description: String {
        "\(brand) · \(cpuCores)-core CPU · \(gpuCores)-core GPU · \(memoryGB) GB"
            + (hasGPUNeuralAccelerators ? " · GPU Neural Accelerators" : "")
    }

    // MARK: Detection

    static func detect() -> ChipProfile {
        let brand = sysctlString("machdep.cpu.brand_string") ?? "Apple silicon"
        var generation = 0
        if let r = brand.range(of: #"M(\d+)"#, options: .regularExpression) {
            generation = Int(brand[r].dropFirst()) ?? 0
        }
        let tier: Tier = brand.contains("Ultra") ? .ultra
                       : brand.contains("Max")   ? .max
                       : brand.contains("Pro")   ? .pro : .base
        let cpu = sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        let mem = Int((sysctlInt("hw.memsize") ?? 0) / 1_073_741_824)
        return ChipProfile(brand: brand, generation: generation, tier: tier,
                           cpuCores: cpu, gpuCores: gpuCoreCount() ?? 0, memoryGB: mem)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    private static func gpuCoreCount() -> Int? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: Int?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if result == nil,
               let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                result = value
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return result
    }
}
