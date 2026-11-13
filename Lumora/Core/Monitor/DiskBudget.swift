import Foundation

/// How much disk space a job needs, where, and what Lumora can safely free. Checked before any heavy job starts
/// and watched while it runs, so an export pauses cleanly before a drive fills instead of failing at the end.
enum DiskBudget {
    struct VolumeSpace: Sendable, Equatable { var name: String; var free: Int64; var total: Int64; var id: String }

    /// Free space provider (tests replace it). Uses the space macOS would make available for important work.
    nonisolated(unsafe) static var space: (URL) -> VolumeSpace? = { url in
        var u = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: u.path), u.pathComponents.count > 1 { u.deleteLastPathComponent() }
        guard let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
                                                      .volumeNameKey, .volumeIdentifierKey, .volumeAvailableCapacityKey]) else { return nil }
        let free = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
        let id = (v.volumeIdentifier as? NSObject)?.description ?? v.volumeName ?? "volume"
        return VolumeSpace(name: v.volumeName ?? "this Mac", free: free, total: Int64(v.volumeTotalCapacity ?? 0), id: id)
    }

    /// A cheap reading (statfs, no purgeable space) for the checks every few seconds during a job; asking macOS for
    /// the space available for important use costs tens of milliseconds, so that is only done to confirm a pause.
    static func quickSpace(_ url: URL) -> (free: Int64, total: Int64)? {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return nil }
        return (Int64(s.f_bavail) * Int64(s.f_bsize), Int64(s.f_blocks) * Int64(s.f_bsize))
    }

    struct Request: Sendable {
        var outputBytes: Int64                  // high end of the size forecast
        var codec: Codec
        var delivery: DeliveryFormat
        var segments = 1
        var targetQuality: (concurrent: Int, chunkBytes: Int64, trials: Int)?
        var stagingBytes: Int64 = 0             // source copy to the scratch drive (auto-stage)
        var modelBytes: Int64 = 0               // model downloads and compiles
        var cacheBytes: Int64 = 0               // upscale / interpolation caches
        var scratch: URL
        var output: URL
        var source: URL?
    }

    struct Need: Sendable, Equatable, Identifiable {
        var id: String { volume }
        var volume: String
        var need: Int64
        var free: Int64
        var margin: Int64
        var shortfall: Int64 { max(0, need + margin - free) }
        var fits: Bool { shortfall == 0 }
    }

    struct Estimate: Sendable, Equatable {
        var items: [(String, Int64)]
        var needs: [Need]
        var fits: Bool { needs.allSatisfy(\.fits) }
        var message: String {
            if let n = needs.first(where: { !$0.fits }) {
                return "Needs about \(gb(n.need)) on \(n.volume), \(gb(n.free)) free: free \(gb(n.shortfall)) (including a \(gb(n.margin)) margin)."
            }
            return needs.map { "\($0.volume): needs about \(gb($0.need)), \(gb($0.free)) free" }.joined(separator: " · ")
        }
        static func == (a: Estimate, b: Estimate) -> Bool { a.needs == b.needs && a.items.map(\.0) == b.items.map(\.0) && a.items.map(\.1) == b.items.map(\.1) }
    }

    static let margin: Int64 = 5 << 30
    static let reserve: Int64 = 2 << 30

    static func gb(_ b: Int64) -> String {
        b >= 1 << 30 ? String(format: "%.0f GB", Double(b) / 1_073_741_824) : String(format: "%.0f MB", Double(max(0, b)) / 1_048_576)
    }

    /// Peak scratch use: the parallel segments (1x the output), their join (1x), the HDR10 container pass (1x),
    /// Dolby Vision / HDR10+ metadata passes (2x more), quality-search trial encodes, a source copy and models.
    static func estimate(_ r: Request) -> Estimate {
        var items: [(String, Int64)] = []
        let out = max(0, r.outputBytes)
        items.append(("Segments being encoded", out))
        items.append(("Joining the segments", out))
        items.append(("Container and HDR metadata pass", out))
        if [.dolbyVision81, .dolbyVision84, .hdr10Plus].contains(r.delivery) { items.append(("Dolby Vision / HDR10+ metadata passes", out * 2)) }
        if let tq = r.targetQuality {
            items.append(("Quality-search trial encodes", Int64(tq.concurrent) * tq.chunkBytes * Int64(max(1, tq.trials))))
        }
        if r.stagingBytes > 0 { items.append(("Copy of the source on the scratch drive", r.stagingBytes)) }
        if r.modelBytes > 0 { items.append(("Model downloads and compiles", r.modelBytes)) }
        if r.cacheBytes > 0 { items.append(("Upscaling / interpolation caches", r.cacheBytes)) }
        let scratchNeed = items.reduce(0) { $0 + $1.1 }

        var byVolume: [String: (VolumeSpace, Int64)] = [:]
        func add(_ url: URL, _ bytes: Int64) {
            guard let v = space(url) else { return }
            byVolume[v.id] = (v, (byVolume[v.id]?.1 ?? 0) + bytes)
        }
        add(r.scratch, scratchNeed)
        // The finished file is moved into place; across volumes that is a copy, so the output drive needs it too.
        let sameVolume = space(r.scratch)?.id == space(r.output.deletingLastPathComponent())?.id
        if !sameVolume { add(r.output.deletingLastPathComponent(), out) }
        if let s = r.source, space(s)?.id != space(r.scratch)?.id, byVolume[space(s)?.id ?? ""] == nil { add(s, 0) }
        let needs = byVolume.values.map { Need(volume: $0.0.name, need: $0.1, free: $0.0.free, margin: margin) }
            .sorted { $0.volume < $1.volume }
        return Estimate(items: items, needs: needs)
    }

    // MARK: - Lumora's own caches

    struct CacheItem: Identifiable, Sendable, Hashable {
        var id: String { url.path }
        var label: String
        var bytes: Int64
        var url: URL
        var recommended: Bool                    // checked by default
    }

    struct Roots: Sendable {
        var scratch: URL
        var models: URL
        var downloads: URL
        static var app: Roots {
            let scratch = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "scratchRoot")
                              ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                                .appendingPathComponent("Lumora Scratch").path)
            return Roots(scratch: scratch, models: InterpolationModelSpec.modelsFolder,
                         downloads: InterpolationModelSpec.modelsFolder.appendingPathComponent("Downloads", isDirectory: true))
        }
    }

    /// `activeSince` is when the oldest running job started: job folders made or changed since then are never listed.
    /// Only Lumora-made items: stale job folders on the scratch drive (not used by a running export), proxies,
    /// compiled Core ML models (rebuilt on next use) and model downloads. Never anything else. Call off the main thread.
    static func inventory(_ roots: Roots = .app, activeSince: Date? = nil) -> [CacheItem] {
        let fm = FileManager.default
        var out: [CacheItem] = []
        let jobPattern = try? NSRegularExpression(pattern: "^[a-z]+-[0-9A-F]{8}$")
        for f in (try? fm.contentsOfDirectory(at: roots.scratch, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? [] {
            let name = f.lastPathComponent
            if name == "Proxies" {
                let b = size(f)
                if b > 0 { out.append(CacheItem(label: "Preview proxies", bytes: b, url: f, recommended: true)) }
                continue
            }
            guard jobPattern?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { continue }
            let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let touched = max(v?.contentModificationDate ?? .distantPast, v?.creationDate ?? .distantPast)
            if let activeSince, touched >= activeSince.addingTimeInterval(-60) { continue }   // may belong to a running job
            let b = size(f)
            if b > 0 { out.append(CacheItem(label: "Leftover \(name.split(separator: "-").first ?? "job") files", bytes: b, url: f, recommended: true)) }
        }
        for f in (try? fm.contentsOfDirectory(at: roots.models, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "mlmodelc" {
            let b = size(f)
            if b > 0 { out.append(CacheItem(label: "Compiled model \(f.deletingPathExtension().lastPathComponent) (rebuilt when needed)", bytes: b, url: f, recommended: false)) }
        }
        for f in (try? fm.contentsOfDirectory(at: roots.downloads, includingPropertiesForKeys: nil)) ?? [] {
            let b = size(f)
            if b > 0 { out.append(CacheItem(label: "Model download \(f.lastPathComponent)", bytes: b, url: f, recommended: false)) }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Removes the chosen items, refusing anything outside Lumora's own folders.
    @discardableResult
    static func clear(_ items: [CacheItem], roots: Roots = .app) -> Int64 {
        var freed: Int64 = 0
        let allowed = [roots.scratch, roots.models, roots.downloads].map { $0.standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        for item in items {
            let p = item.url.standardizedFileURL.resolvingSymlinksInPath().path
            guard allowed.contains(where: { p.hasPrefix($0) && p.count > $0.count }) else { continue }
            let b = size(item.url)
            if (try? FileManager.default.removeItem(at: item.url)) != nil { freed += b }
        }
        Log.notice(.storage, "Cleared \(gb(freed)) of Lumora caches (\(items.count) items)")
        return freed
    }

    static func size(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0) }
        var total: Int64 = 0
        let e = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    // MARK: - During a job

    /// The space always kept free: 2 GB plus 2% of the drive, capped at 5 GB in all (2% of a large drive is more
    /// than macOS needs to keep working).
    static func floor(total: Int64) -> Int64 { reserve + min(total / 50, 3 << 30) }

    /// Whether to pause now: free space minus what the rest of the job will still write, against the reserve.
    static func shouldPause(free: Int64, total: Int64, remainingFrames: Int, bytesPerFrame: Double, finishBytes: Int64) -> Bool {
        let upcoming = Int64(Double(max(0, remainingFrames)) * max(0, bytesPerFrame)) + finishBytes
        return free - upcoming < floor(total: total)
    }
}
