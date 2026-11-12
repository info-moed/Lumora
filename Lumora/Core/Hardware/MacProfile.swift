import Foundation
import CoreML

/// Settings measured on this exact Mac by "Optimize for this Mac". Nothing here is assumed from the chip name,
/// so the same tests tune an M5, an M5 Ultra, or chips that don't exist yet.
struct MacProfile: Codable {
    var machine: String
    var chip: String
    var os: String
    var created: Date
    var level: String
    var threadgroups: [String: [Int]] = [:]      // kernel → [width, height]
    var coreMLUnits: [String: Int] = [:]          // model id → MLComputeUnits raw value
    var modelMsPerFrame: [String: Double] = [:]
    var vtSessions: Int?
    var cliInstances: [String: Int] = [:]         // codec → parallel encoder instances
    var cliFps: [String: Double] = [:]
    var pipelineDepth: Int = 4
    var concurrentChunks: Int?
    var ramFraction: Double = 0.30
    var sustainedFactor: Double = 1.0              // throughput after heat soak ÷ throughput when cool
    var scratchWriteMBps: Double?
    var findings: [String] = []

    private static var url: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("mac-profile.json")
    }
    nonisolated(unsafe) static var current: MacProfile? = {
        guard let p = try? JSONDecoder().decode(MacProfile.self, from: Data(contentsOf: url)) else { return nil }
        // A profile only applies to the machine and OS it was measured on.
        return p.machine == machineModel && p.os == osVersion ? p : nil
    }()
    func save() {
        try? JSONEncoder().encode(self).write(to: Self.url)
        MacProfile.current = self
    }
    static func reset() { try? FileManager.default.removeItem(at: url); current = nil }

    static var machineModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(1, size))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
    static var osVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}
