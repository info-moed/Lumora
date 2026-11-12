import Foundation
import Observation
import CryptoKit

/// One Practical-RIFE release in the catalog (Resources/rife_catalog.json).
struct RIFERelease: Codable, Identifiable, Hashable {
    var id: String               // "4.25", "4.25.lite"
    var released: String
    var variant: String
    var pad: Int
    var url: URL?                // direct download when a mirror exists; otherwise use sourcePage
    var sourcePage: URL
    var notes: String
    var sha256: String? = nil    // pinned digest of the download; a mismatch is refused

    var imageModelID: String { "rife-\(id)" }
    var flowModelID: String { "rife-\(id)-flow" }
    var fileStem: String { "RIFE-\(id)" }
}

/// Downloads, converts (Core ML, image + HDR flow variants) and ranks interpolation models — all on this Mac.
@MainActor
@Observable
final class ModelLab {
    static let shared = ModelLab()

    enum Status: Equatable { case notDownloaded, downloaded, converted, working(String) }

    private(set) var catalog: [RIFERelease] = []
    private(set) var status: [String: Status] = [:]
    /// Best model per content type, learned from benchmarks on your footage.
    private(set) var choices: [ContentKind: String] = [:]
    var environmentReady = false

    /// Practical-RIFE source revision used for conversion (verified 2026-11-11). Update deliberately.
    nonisolated static let practicalRIFECommit = "bbfd2ea90910789a860ea3e2b32a240cd577b75e"

    nonisolated static var root: URL { InterpolationModelSpec.modelsFolder }
    nonisolated static var downloads: URL { root.appendingPathComponent("Downloads", isDirectory: true) }
    nonisolated static var lab: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora/ModelLab", isDirectory: true) }
    nonisolated static var registry: URL { root.appendingPathComponent("models.json") }
    private static var choicesURL: URL { root.appendingPathComponent("model-choices.json") }

    private init() {
        try? FileManager.default.createDirectory(at: Self.downloads, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.lab, withIntermediateDirectories: true)
        if let u = Bundle.main.url(forResource: "rife_catalog", withExtension: "json"), let d = try? Data(contentsOf: u) {
            catalog = (try? JSONDecoder().decode([RIFERelease].self, from: d)) ?? []
        }
        if let d = try? Data(contentsOf: Self.choicesURL),
           let raw = try? JSONDecoder().decode([String: String].self, from: d) {
            choices = Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in ContentKind(rawValue: k).map { ($0, v) } })
        }
        environmentReady = FileManager.default.fileExists(atPath: Self.lab.appendingPathComponent("venv/bin/python").path)
            && FileManager.default.fileExists(atPath: Self.lab.appendingPathComponent("Practical-RIFE").path)
        refresh()
    }

    func refresh() {
        for r in catalog {
            if FileManager.default.fileExists(atPath: Self.root.appendingPathComponent("\(r.fileStem)-Flow.mlpackage").path) {
                status[r.id] = .converted
            } else if FileManager.default.fileExists(atPath: zipURL(r).path) {
                status[r.id] = .downloaded
            } else if case .working = status[r.id] {
            } else { status[r.id] = .notDownloaded }
        }
    }

    func zipURL(_ r: RIFERelease) -> URL { Self.downloads.appendingPathComponent("RIFE_v\(r.id).zip") }

    // MARK: Download / import

    func download(_ r: RIFERelease) async throws {
        guard let url = r.url else { throw LumoraError.unsupported("No direct download for \(r.id). Open its page, download it, then use Import.") }
        status[r.id] = .working("Downloading")
        let task = TaskCenter.shared.begin("Downloading RIFE \(r.id)", symbol: "arrow.down.circle")
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url, delegate: DownloadProgress(task: task))
            try? FileManager.default.removeItem(at: zipURL(r))
            try FileManager.default.moveItem(at: tmp, to: zipURL(r))
            let digest = try Self.sha256(of: zipURL(r))
            if let pinned = r.sha256, pinned.lowercased() != digest {
                try? FileManager.default.removeItem(at: zipURL(r))
                throw LumoraError.unsupported("The RIFE \(r.id) download doesn't match its published checksum, so it was deleted. Expected \(pinned), got \(digest).")
            }
            recordHash(digest, for: r, verified: r.sha256 != nil)
            Log.notice(.models, "Downloaded RIFE \(r.id) from \(url.host ?? "") — SHA-256 \(digest)\(r.sha256 != nil ? " (matches the pinned checksum)" : "")")
            TaskCenter.shared.finish(task)
        } catch {
            TaskCenter.shared.finish(task, error: error)
            status[r.id] = .notDownloaded
            throw error
        }
        refresh()
    }

    func importZip(_ file: URL, for r: RIFERelease) throws {
        let digest = try Self.sha256(of: file)
        if let pinned = r.sha256, pinned.lowercased() != digest {
            throw LumoraError.unsupported("This file isn't the published RIFE \(r.id) release (its checksum differs), so it wasn't imported.")
        }
        try? FileManager.default.removeItem(at: zipURL(r))
        try FileManager.default.copyItem(at: file, to: zipURL(r))
        recordHash(digest, for: r, verified: r.sha256 != nil)
        Log.info(.models, "Imported \(file.lastPathComponent) as RIFE \(r.id) — SHA-256 \(digest)")
        refresh()
    }

    // MARK: Integrity
    //
    // Converting a release runs the Python model code that ships inside its zip (each RIFE version has its own
    // architecture). So: pinned checksums for catalog downloads, a recorded checksum for anything imported by hand,
    // a re-check right before conversion, and the UI asks before running code that wasn't pinned.

    nonisolated static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var hashesURL: URL { root.appendingPathComponent("model-hashes.json") }
    struct HashRecord: Codable { var sha256: String; var verified: Bool }

    private func recordHash(_ digest: String, for r: RIFERelease, verified: Bool) {
        var all = (try? JSONDecoder().decode([String: HashRecord].self, from: Data(contentsOf: Self.hashesURL))) ?? [:]
        all[r.id] = HashRecord(sha256: digest, verified: verified)
        try? JSONEncoder().encode(all).write(to: Self.hashesURL, options: .atomic)
    }

    /// The recorded checksum of the zip on disk, and whether it matched a pinned, published one.
    func provenance(_ r: RIFERelease) -> HashRecord? {
        let all = (try? JSONDecoder().decode([String: HashRecord].self, from: Data(contentsOf: Self.hashesURL))) ?? [:]
        return all[r.id]
    }

    // MARK: Converter environment (Python venv with PyTorch + coremltools, Practical-RIFE source)

    func prepareEnvironment() async throws {
        let task = TaskCenter.shared.begin("Setting up the model converter", symbol: "hammer")
        let reporter = ProgressReporter(task: task)
        do {
            let lab = Self.lab
            if !FileManager.default.fileExists(atPath: lab.appendingPathComponent("venv/bin/python").path) {
                reporter.update(0.05, detail: "Creating Python environment")
                try await shell("/usr/bin/python3", ["-m", "venv", lab.appendingPathComponent("venv").path])
            }
            reporter.update(0.2, detail: "Installing PyTorch and coremltools (a few minutes, once)")
            // Prebuilt wheels only: no package gets to run its own build script on this Mac.
            try await shell(lab.appendingPathComponent("venv/bin/pip").path,
                            ["install", "--upgrade", "--only-binary=:all:", "pip", "torch", "coremltools", "numpy"])
            let rife = lab.appendingPathComponent("Practical-RIFE")
            if !FileManager.default.fileExists(atPath: rife.appendingPathComponent(".git").path) {
                reporter.update(0.85, detail: "Fetching Practical-RIFE source (pinned)")
                try? FileManager.default.removeItem(at: rife)
                // A pinned commit, not whatever happens to be at the tip of the repository.
                try await shell("/usr/bin/git", ["init", "-q", rife.path])
                try await shell("/usr/bin/git", ["-C", rife.path, "fetch", "-q", "--depth", "1",
                                                 "https://github.com/hzwer/Practical-RIFE", Self.practicalRIFECommit])
                try await shell("/usr/bin/git", ["-C", rife.path, "checkout", "-q", "FETCH_HEAD"])
            }
            environmentReady = true
            TaskCenter.shared.finish(task)
        } catch {
            TaskCenter.shared.finish(task, error: error)
            throw error
        }
    }

    /// Installs ColorVideoVDP (and with it PU21 metrics) into the same Python environment, on this Mac.
    func installMetrics() async throws {
        if !environmentReady { try await prepareEnvironment() }
        let task = TaskCenter.shared.begin("Installing perceptual quality metrics", symbol: "eye")
        do {
            try await shell(Self.lab.appendingPathComponent("venv/bin/pip").path, ["install", "--upgrade", "--only-binary=:all:", "cvvdp"])
            FileManager.default.createFile(atPath: Self.lab.appendingPathComponent(".metrics-installed").path, contents: Data())
            Log.notice(.quality, "ColorVideoVDP installed")
            TaskCenter.shared.finish(task)
        } catch {
            TaskCenter.shared.finish(task, error: error)
            throw error
        }
    }

    /// Converts one release into two Core ML models: image output and HDR flow output (true 10/12-bit).
    func convert(_ r: RIFERelease) async throws {
        guard environmentReady else { throw LumoraError.unsupported("Set up the converter first.") }
        guard let script = Bundle.main.url(forResource: "convert_rife_coreml", withExtension: "py") else {
            throw LumoraError.unsupported("Converter script missing from the app bundle.")
        }
        status[r.id] = .working("Converting")
        let task = TaskCenter.shared.begin("Converting RIFE \(r.id) to Core ML", symbol: "cpu")
        let reporter = ProgressReporter(task: task)
        do {
            let work = Self.lab.appendingPathComponent("work-\(r.id)")
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.copyItem(at: Self.lab.appendingPathComponent("Practical-RIFE"), to: work)
            // The zip must still be the file whose checksum was recorded (and pinned, for catalog downloads).
            let digest = try Self.sha256(of: zipURL(r))
            guard let record = provenance(r), record.sha256 == digest, r.sha256.map({ $0.lowercased() == digest }) ?? true else {
                throw LumoraError.unsupported("RIFE \(r.id)'s file changed since it was downloaded or imported. Download or import it again.")
            }
            let unzip = work.appendingPathComponent("unzipped")
            try await shell("/usr/bin/ditto", ["-x", "-k", zipURL(r).path, unzip.path])
            // No links out of the extraction folder.
            let links = FileManager.default.enumerator(at: unzip, includingPropertiesForKeys: [.isSymbolicLinkKey])?
                .compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true } ?? []
            guard links.isEmpty else { throw LumoraError.unsupported("The RIFE \(r.id) archive contains symbolic links, which aren't allowed.") }
            // The zip holds train_log/ (model code + flownet.pkl), sometimes inside another folder.
            let found = FileManager.default.enumerator(at: unzip, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.first { $0.lastPathComponent == "flownet.pkl" }
            guard let pkl = found else { throw LumoraError.unsupported("flownet.pkl not found in the RIFE \(r.id) download.") }
            let trainLog = work.appendingPathComponent("train_log")
            try? FileManager.default.removeItem(at: trainLog)
            try FileManager.default.copyItem(at: pkl.deletingLastPathComponent(), to: trainLog)
            let python = Self.lab.appendingPathComponent("venv/bin/python").path
            reporter.update(0.2, detail: "Image model")
            try await shell(python, [script.path, "--rife-dir", work.path, "--weights", trainLog.path,
                                     "--out", Self.root.appendingPathComponent("\(r.fileStem).mlpackage").path])
            reporter.update(0.6, detail: "HDR flow model")
            try await shell(python, [script.path, "--rife-dir", work.path, "--weights", trainLog.path, "--flow-output",
                                     "--out", Self.root.appendingPathComponent("\(r.fileStem)-Flow.mlpackage").path])
            try register(r)
            try? FileManager.default.removeItem(at: work)
            Log.notice(.models, "RIFE \(r.id) converted (image + flow)")
            TaskCenter.shared.finish(task)
        } catch {
            TaskCenter.shared.finish(task, error: error)
            status[r.id] = .downloaded
            throw error
        }
        refresh()
    }

    private func register(_ r: RIFERelease) throws {
        var list = (try? JSONDecoder().decode([InterpolationModelSpec].self, from: Data(contentsOf: Self.registry))) ?? []
        list.removeAll { $0.id == r.imageModelID || $0.id == r.flowModelID }
        let tier = r.variant == "lite" ? "fast" : (r.variant == "heavy" ? "best" : "balanced")
        list.append(InterpolationModelSpec(id: r.imageModelID, displayName: "RIFE \(r.id)", file: "\(r.fileStem).mlpackage",
                                           inputA: "img0", inputB: "img1", timestep: "timestep", timestepKind: "map",
                                           output: "output", padMultiple: r.pad, tier: tier, license: "MIT (Practical-RIFE)",
                                           notes: r.notes))
        list.append(InterpolationModelSpec(id: r.flowModelID, displayName: "RIFE \(r.id) HDR flow", file: "\(r.fileStem)-Flow.mlpackage",
                                           inputA: "img0", inputB: "img1", timestep: "timestep", timestepKind: "map",
                                           output: "output", padMultiple: r.pad, tier: tier, license: "MIT (Practical-RIFE)",
                                           notes: r.notes + " Flow output: original 10/12-bit pixels are warped in 32-bit float.",
                                           outputKind: "flow", flowOutput: "flow", maskOutput: "mask"))
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        try enc.encode(list).write(to: Self.registry)
    }

    // MARK: Per-content choices

    func record(benchmark: InterpolationEvaluator.Benchmark, for kind: ContentKind) {
        guard let name = benchmark.recommendedModel,
              let spec = InterpolationModelSpec.all().first(where: { $0.displayName == name }) else { return }
        choices[kind] = spec.id
        let raw = Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value) })
        try? JSONEncoder().encode(raw).write(to: Self.choicesURL)
        Log.notice(.models, "Best model for \(kind.displayName) on your footage: \(name)")
    }

    /// The model to use for a content type: your benchmark winner, else the tuning's preference list, else anything installed.
    func bestModel(for kind: ContentKind) -> String? {
        let installed = Set(InterpolationModelSpec.all().filter(\.isInstalled).map(\.id))
        if let c = choices[kind], installed.contains(c) { return c }
        return ContentTuning.preset(kind).interpolationModels.first { installed.contains($0) } ?? installed.sorted().first
    }

    // MARK: Helpers

    private func shell(_ exe: String, _ args: [String]) async throws {
        Log.info(.tools, "\(exe) \(args.joined(separator: " "))")
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            for try await line in out.fileHandleForReading.bytes.lines { Log.debug(.tools, line) }
            p.waitUntilExit()
            if p.terminationStatus != 0 { throw LumoraError.toolFailed((exe as NSString).lastPathComponent, "exit \(p.terminationStatus) — see the log") }
        }.value
    }
}

private final class DownloadProgress: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    let reporter: ProgressReporter
    init(task: TrackedTask) { reporter = ProgressReporter(task: task) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        reporter.update(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite),
                        detail: ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file))
    }
}
