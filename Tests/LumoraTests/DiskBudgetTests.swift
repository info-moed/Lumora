import XCTest
@testable import Lumora

/// Disk space before and during a job, and the cache inventory that may only ever touch Lumora's own files.
final class DiskBudgetTests: XCTestCase {
    private var savedSpace: ((URL) -> DiskBudget.VolumeSpace?)!
    private var root: URL!

    override func setUp() {
        savedSpace = DiskBudget.space
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LumoraDiskBudget-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        DiskBudget.space = savedSpace
        try? FileManager.default.removeItem(at: root)
    }

    let gb: Int64 = 1 << 30

    func fakeVolumes(scratchFree: Int64, outFree: Int64) {
        let g = gb
        DiskBudget.space = { url in
            url.path.hasPrefix("/Volumes/Out")
                ? DiskBudget.VolumeSpace(name: "Out", free: outFree, total: 2000 * g, id: "out")
                : DiskBudget.VolumeSpace(name: "Macintosh HD", free: scratchFree, total: 1000 * g, id: "internal")
        }
    }

    func request(_ out: Int64, delivery: DeliveryFormat = .hdr10, output: String = "/Users/Shared/x.mkv") -> DiskBudget.Request {
        DiskBudget.Request(outputBytes: out, codec: .av1, delivery: delivery, scratch: URL(fileURLWithPath: "/tmp/scratch"),
                           output: URL(fileURLWithPath: output))
    }

    func testSameVolumeNeedsScratchPeakOnly() {
        fakeVolumes(scratchFree: 200 * gb, outFree: 0)
        let e = DiskBudget.estimate(request(10 * gb))
        XCTAssertEqual(e.needs.count, 1)
        XCTAssertEqual(e.needs[0].need, 30 * gb, "segments + join + container pass")
        XCTAssertTrue(e.fits)
    }

    func testDifferentOutputVolumeNeedsACopy() {
        fakeVolumes(scratchFree: 200 * gb, outFree: 8 * gb)
        let e = DiskBudget.estimate(request(10 * gb, output: "/Volumes/Out/x.mkv"))
        XCTAssertEqual(e.needs.count, 2)
        let out = try? XCTUnwrap(e.needs.first { $0.volume == "Out" })
        XCTAssertEqual(out?.need, 10 * gb)
        XCTAssertFalse(e.fits)
        XCTAssertEqual(out?.shortfall, 7 * gb, "10 GB + 5 GB margin − 8 GB free")
        XCTAssertTrue(e.message.contains("on Out"), e.message)
    }

    func testDolbyVisionNeedsExtraPasses() {
        fakeVolumes(scratchFree: 200 * gb, outFree: 0)
        XCTAssertEqual(DiskBudget.estimate(request(10 * gb, delivery: .dolbyVision81)).needs[0].need, 50 * gb)
    }

    func testProResNeedsFarMoreThanAV1() {
        let sizes = StreamSizes(total: 4 * gb, video: 4 * gb, other: 0)
        func forecast(_ c: Codec) -> Int64 {
            SizeForecaster.quick(width: 1920, height: 1080, outputFrames: 24 * 600, outputFps: 24, codec: c, kind: .realLife,
                                 grainSynthesis: false, target: nil, quality: 0.8, bitDepth: 10, chroma: .c420, source: sizes,
                                 carryOther: false, key: "test").high
        }
        fakeVolumes(scratchFree: 2000 * gb, outFree: 0)
        let prores = DiskBudget.estimate(request(forecast(.prores422HQ))).needs[0].need
        let av1 = DiskBudget.estimate(request(forecast(.av1))).needs[0].need
        XCTAssertGreaterThan(prores, av1 * 5)
    }

    func testShortfallMessageHasExactAmounts() {
        fakeVolumes(scratchFree: 22 * gb, outFree: 0)
        var r = request(12 * gb)
        r.stagingBytes = 2 * gb
        let e = DiskBudget.estimate(r)
        XCTAssertEqual(e.needs[0].need, 38 * gb)
        XCTAssertEqual(e.needs[0].shortfall, 21 * gb)
        XCTAssertEqual(e.message, "Needs about 38 GB on Macintosh HD, 22 GB free: free 21 GB (including a 5 GB margin).")
    }

    func testPauseDuringJob() {
        // 1 TB drive: the floor is 2 GB + 3 GB cap = 5 GB.
        XCTAssertEqual(DiskBudget.floor(total: 1000 * gb), 5 * gb)
        XCTAssertFalse(DiskBudget.shouldPause(free: 50 * gb, total: 1000 * gb, remainingFrames: 1000, bytesPerFrame: 1_000_000, finishBytes: 2 * gb))
        XCTAssertTrue(DiskBudget.shouldPause(free: 6 * gb, total: 1000 * gb, remainingFrames: 1000, bytesPerFrame: 1_000_000, finishBytes: 2 * gb))
    }

    func testInventoryListsOnlyLumoraItemsAndClearNeverLeavesItsFolders() throws {
        let fm = FileManager.default
        let scratch = root.appendingPathComponent("scratch"), models = root.appendingPathComponent("models")
        let downloads = models.appendingPathComponent("Downloads")
        for d in [scratch, models, downloads] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        func file(_ u: URL, _ bytes: Int = 200_000) throws {
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: u)
        }
        try file(scratch.appendingPathComponent("export-1A2B3C4D/seg0.mkv"))
        try file(scratch.appendingPathComponent("Proxies/a.mov"))
        try file(scratch.appendingPathComponent("My Movie.mov"))              // a person's file in the scratch folder
        try file(scratch.appendingPathComponent("Vacation/clip.mov"))
        try file(models.appendingPathComponent("rife.mlmodelc/model.bin"))
        try file(models.appendingPathComponent("notes.txt"))
        try file(downloads.appendingPathComponent("rife.zip"))
        let roots = DiskBudget.Roots(scratch: scratch, models: models, downloads: downloads)
        // An old job folder: make it look stale.
        let old = Date().addingTimeInterval(-3600)
        try fm.setAttributes([.modificationDate: old, .creationDate: old], ofItemAtPath: scratch.appendingPathComponent("export-1A2B3C4D").path)

        let items = DiskBudget.inventory(roots)
        let names = Set(items.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, ["export-1A2B3C4D", "Proxies", "rife.mlmodelc", "rife.zip"])
        XCTAssertTrue(items.allSatisfy { $0.bytes > 0 })

        // A running job started before the folder was touched protects it.
        try fm.setAttributes([.modificationDate: Date(), .creationDate: Date()], ofItemAtPath: scratch.appendingPathComponent("export-1A2B3C4D").path)
        XCTAssertFalse(DiskBudget.inventory(roots, activeSince: Date().addingTimeInterval(-30)).contains { $0.url.lastPathComponent == "export-1A2B3C4D" })

        // Clearing refuses anything outside Lumora's folders, even if asked.
        let outside = root.appendingPathComponent("outside.mov")
        try file(outside)
        let trap = DiskBudget.CacheItem(label: "trap", bytes: 1, url: outside, recommended: true)
        let rootTrap = DiskBudget.CacheItem(label: "root", bytes: 1, url: scratch, recommended: true)
        DiskBudget.clear(items + [trap, rootTrap], roots: roots)
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
        XCTAssertTrue(fm.fileExists(atPath: scratch.appendingPathComponent("My Movie.mov").path))
        XCTAssertTrue(fm.fileExists(atPath: scratch.appendingPathComponent("Vacation/clip.mov").path))
        XCTAssertTrue(fm.fileExists(atPath: models.appendingPathComponent("notes.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: scratch.appendingPathComponent("Proxies").path))
        XCTAssertFalse(fm.fileExists(atPath: downloads.appendingPathComponent("rife.zip").path))
        XCTAssertTrue(DiskBudget.inventory(roots).isEmpty)
    }
}
