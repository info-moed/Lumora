import Foundation

/// What Lumora needs to repair a finished export later without redoing it: chunk boundaries and settings per chunk.
struct ExportManifest: Codable {
    struct Chunk: Codable { var start: Int; var count: Int; var level: Double }
    var output: String
    var source: String
    var codec: Codec
    var rateNum: Int
    var rateDen: Int
    var frames: Int
    var delivery: DeliveryFormat
    var chunks: [Chunk]
    var created: Date
    /// The HDR peak the export was graded to (nil for SDR, and for manifests written before this field existed).
    /// AV2 can't carry mastering metadata, so the player reads its peak from here.
    var peakNits: Float? = nil

    private static var folder: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora/Manifests")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func key(_ output: String) -> String {
        String(output.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }.suffix(180))
    }
    func save() { try? JSONEncoder().encode(self).write(to: Self.folder.appendingPathComponent(Self.key(output) + ".json")) }
    /// Every manifest on this Mac, newest first (the Library's "Your exports" list).
    static func all() -> [ExportManifest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ExportManifest.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }

    static func load(for output: URL) -> ExportManifest? {
        try? JSONDecoder().decode(ExportManifest.self, from: Data(contentsOf: folder.appendingPathComponent(key(output.path) + ".json")))
    }
}

extension ExportManifest: Identifiable {
    var id: String { output }
}
