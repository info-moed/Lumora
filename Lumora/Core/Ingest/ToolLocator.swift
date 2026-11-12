import Foundation

/// Finds helper command-line tools: bundled copies first (Contents/Resources/bin), then Homebrew.
enum ToolLocator {
    static func url(for name: String) -> URL? {
        if let override = UserDefaults.standard.string(forKey: "toolPath.\(name)"),
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("bin/\(name)")) }
        candidates += ["/opt/homebrew/bin", "/usr/local/bin",
                       NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/bin"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func isAvailable(_ name: String) -> Bool { url(for: name) != nil }

    /// Runs a tool and returns its stderr (FFmpeg prints filter statistics such as `idet` there).
    static func runCapturingStderr(_ name: String, _ args: [String]) throws -> String {
        guard let exe = url(for: name) else { throw LumoraError.missingTool(name) }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let err = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = err
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs a tool to completion and returns stdout. Throws with stderr on failure.
    @discardableResult
    static func run(_ name: String, _ args: [String]) throws -> Data {
        guard let exe = url(for: name) else { throw LumoraError.missingTool(name) }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw LumoraError.toolFailed(name, String(decoding: errData.suffix(2000), as: UTF8.self))
        }
        return data
    }
}

enum LumoraError: LocalizedError {
    case noVideoTrack, decodeFailed(String), missingTool(String), toolFailed(String, String)
    case needsVendorSDK(String), unsupported(String), cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "This file has no video track."
        case .decodeFailed(let s): return "Couldn't decode the video: \(s)"
        case .missingTool(let t): return "The helper tool “\(t)” isn't installed. See README → Encoders."
        case .toolFailed(let t, let e): return "\(t) failed: \(e)"
        case .needsVendorSDK(let ext): return ".\(ext) files need the camera maker's RAW SDK plug-in. See README → RAW formats."
        case .unsupported(let s): return s
        case .cancelled: return "Cancelled."
        }
    }
}
