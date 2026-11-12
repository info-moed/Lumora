import Foundation
import VideoToolbox
import DiskArbitration
import IOKit
import AVFoundation
import Metal
import MetalPerformanceShaders

/// What Lumora knows about a volume, in plain terms.
struct VolumeInfo: Hashable {
    var name: String
    var mountPoint: URL
    var bus: String                  // "Thunderbolt", "USB", "PCI-Express" (internal), "SATA", "Network"…
    var isInternal: Bool
    var isSolidState: Bool?          // nil when the drive doesn't say
    var totalBytes: Int64
    var freeBytes: Int64
    var measuredReadMBps: Double?
    var measuredWriteMBps: Double?

    var kindDescription: String {
        let medium = isSolidState == true ? "SSD" : (isSolidState == false ? "hard drive" : "drive")
        return isInternal ? "Internal \(medium)" : "\(bus) \(medium)"
    }
}

enum StorageInspector {
    static func describe(_ url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeNameKey, .volumeTotalCapacityKey,
                                                              .volumeAvailableCapacityForImportantUsageKey,
                                                              .volumeIsInternalKey, .volumeIsLocalKey]),
              let volume = values.volume else { return nil }
        var info = VolumeInfo(name: values.volumeName ?? volume.lastPathComponent, mountPoint: volume,
                              bus: values.volumeIsLocal == false ? "Network" : "Unknown",
                              isInternal: values.volumeIsInternal ?? false, isSolidState: nil,
                              totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                              freeBytes: values.volumeAvailableCapacityForImportantUsage ?? 0)
        if let session = DASessionCreate(kCFAllocatorDefault),
           let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
           let desc = DADiskCopyDescription(disk) as? [String: Any] {
            if let proto = desc[kDADiskDescriptionDeviceProtocolKey as String] as? String { info.bus = proto }
            if let isInternalDisk = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool { info.isInternal = isInternalDisk }
            if let bsd = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String { info.isSolidState = solidState(bsd: bsd) }
        }
        return info
    }

    /// Walks the IORegistry from the disk up to its storage device and reads "Medium Type".
    private static func solidState(bsd: String) -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let options = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        guard let chars = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Device Characteristics" as CFString,
                                                          kCFAllocatorDefault, options) as? [String: Any],
              let medium = chars["Medium Type"] as? String else { return nil }
        return medium.localizedCaseInsensitiveContains("solid")
    }

    /// Sequential read speed of an existing file, bypassing the cache (reads at most `bytes`).
    static func measureRead(_ file: URL, bytes: Int = 384 << 20) -> Double? {
        let fd = open(file.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let block = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 4096)
        defer { buffer.deallocate() }
        let start = Date()
        var total = 0
        while total < bytes {
            let n = read(fd, buffer, block)
            if n <= 0 { break }
            total += n
        }
        let t = Date().timeIntervalSince(start)
        return total > (16 << 20) && t > 0 ? Double(total) / t / 1_000_000 : nil
    }

    /// Sequential write speed of a folder's volume (writes then deletes a small test file).
    static func measureWrite(_ folder: URL, bytes: Int = 256 << 20) -> Double? {
        let url = folder.appendingPathComponent(".lumora-speedtest-\(UUID().uuidString)")
        let fd = open(url.path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard fd >= 0 else { return nil }
        defer { close(fd); unlink(url.path) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let block = 8 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 4096)
        defer { buffer.deallocate() }
        memset(buffer, 0x5A, block)
        let start = Date()
        var total = 0
        while total < bytes {
            let n = write(fd, buffer, block)
            if n <= 0 { return nil }
            total += n
        }
        fsync(fd)
        let t = Date().timeIntervalSince(start)
        return t > 0 ? Double(total) / t / 1_000_000 : nil
    }
}

/// Where temporary and intermediate files go. Always a fast SSD you choose; never the source drive.
@MainActor
@Observable
final class ScratchManager {
    static let shared = ScratchManager()

    var root: URL {
        didSet { UserDefaults.standard.set(root.path, forKey: "scratchRoot"); refresh() }
    }
    private(set) var volume: VolumeInfo?

    private init() {
        if let p = UserDefaults.standard.string(forKey: "scratchRoot") {
            root = URL(fileURLWithPath: p)
        } else {
            root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Lumora Scratch")
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() { volume = StorageInspector.describe(root) }

    /// A fresh folder for one job, removed by the caller when done.
    nonisolated static func jobDirectory(_ label: String) throws -> URL {
        let base = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "scratchRoot")
                       ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Lumora Scratch").path)
        let dir = base.appendingPathComponent("\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static var proxiesFolder: URL {
        let base = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "scratchRoot")
                       ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Lumora Scratch").path)
        let dir = base.appendingPathComponent("Proxies", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func ensureSpace(_ bytes: Int64) throws {
        refresh()
        if let free = volume?.freeBytes, free < bytes + (2 << 30) {
            throw LumoraError.unsupported("The scratch drive needs \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) free. Choose another scratch drive in Settings → Storage.")
        }
    }

    func purgeAll() {
        for f in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
        refresh()
    }
}

/// Decides how to read a source: stream it with read-ahead, or stage it to the SSD first.
struct StoragePlan {
    enum Strategy: String { case stream = "Stream from the source drive", streamReadAhead = "Stream with read-ahead (single reader)",
                            stageToScratch = "Copy to the scratch SSD first" }
    var source: VolumeInfo?
    var scratch: VolumeInfo?
    var sourceBitrateMBps: Double
    var strategy: Strategy
    var maxConcurrentReaders: Int
    var buildProxy: Bool
    var explanation: String

    static func make(for d: SourceDescriptor, measureSpeed: Bool = true) -> StoragePlan {
        let src = StorageInspector.describe(d.url)
        let scratchRoot = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "scratchRoot")
                              ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].path)
        let scratch = StorageInspector.describe(scratchRoot)
        let size = (try? d.url.resourceValues(forKeys: [.totalFileSizeKey]).totalFileSize).map { Double($0 ?? 0) } ?? 0
        let bitrate = d.durationSeconds > 0 ? size / d.durationSeconds / 1_000_000 : 0
        var info = src
        if measureSpeed, d.kind != .rawSequence { info?.measuredReadMBps = StorageInspector.measureRead(d.url) }
        let read = info?.measuredReadMBps ?? (src?.isSolidState == false ? 150 : 1500)
        let rotational = src?.isSolidState == false || read < 300
        let sameVolume = src?.mountPoint == scratch?.mountPoint
        var plan = StoragePlan(source: info, scratch: scratch, sourceBitrateMBps: bitrate, strategy: .stream,
                               maxConcurrentReaders: 8, buildProxy: false, explanation: "")
        if rotational && !sameVolume {
            plan.maxConcurrentReaders = 1          // several readers on a hard drive cause seek thrash
            plan.buildProxy = true                 // smooth scrubbing from the SSD instead of seeking the HDD
            let fits = Double(scratch?.freeBytes ?? 0) > size * 1.2
            if bitrate * 1.4 > read, fits {
                plan.strategy = .stageToScratch
                plan.explanation = String(format: "This file needs about %.0f MB/s but the drive reads %.0f MB/s. Copying it to the SSD once is faster than streaming.", bitrate, read)
            } else {
                plan.strategy = .streamReadAhead
                plan.explanation = String(format: "The source is on a hard drive (%.0f MB/s). Lumora reads it once, in order, with read-ahead, and builds a small preview proxy on the SSD so scrubbing never seeks the hard drive.", read)
            }
        } else {
            plan.explanation = String(format: "The source drive is fast (%.0f MB/s). Reading directly.", read)
        }
        Log.info(.storage, "Plan for \(d.url.lastPathComponent): \(plan.strategy.rawValue). Source \(info?.kindDescription ?? "?") read \(Int(read)) MB/s, needs \(String(format: "%.1f", bitrate)) MB/s. Scratch: \(scratch?.kindDescription ?? "?") \(scratch?.mountPoint.path ?? "")")
        return plan
    }
}

/// Keeps the page cache filled ahead of the decoder on slow drives, so AVFoundation / FFmpeg never wait on seeks.
/// Uses F_RDADVISE hints: the kernel reads ahead asynchronously, nothing is copied into our memory.
final class ReadAheadAdvisor: @unchecked Sendable {
    private let fd: Int32
    private let fileSize: Int64
    private let window: Int64
    private var advisedUpTo: Int64 = 0
    private let lock = NSLock()

    init?(url: URL, window: Int64 = 512 << 20) {
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0 ?? 0) } ?? 0
        self.window = window
    }

    deinit { close(fd) }

    /// Call as decoding progresses (fraction of the file consumed).
    func advance(toFraction f: Double) {
        lock.lock(); defer { lock.unlock() }
        let position = Int64(Double(fileSize) * max(0, min(1, f)))
        let target = min(fileSize, position + window)
        while advisedUpTo < target {
            let count = Int32(min(Int64(32 << 20), target - advisedUpTo))
            var ra = radvisory(ra_offset: off_t(advisedUpTo), ra_count: count)
            _ = fcntl(fd, F_RDADVISE, &ra)
            advisedUpTo += Int64(count)
        }
    }
}

/// Copies a source to the scratch SSD in large sequential blocks (ideal for old hard drives), with progress.
enum Stager {
    static func stage(_ url: URL, progress: ProgressReporter) async throws -> URL {
        let dest = try ScratchManager.jobDirectory("staged").appendingPathComponent(url.lastPathComponent)
        let inFD = open(url.path, O_RDONLY), outFD = open(dest.path, O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard inFD >= 0, outFD >= 0 else { throw LumoraError.unsupported("Couldn't open the file for staging.") }
        defer { close(inFD); close(outFD) }
        _ = fcntl(inFD, F_NOCACHE, 1); _ = fcntl(outFD, F_NOCACHE, 1)
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let block = 16 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: 4096)
        defer { buf.deallocate() }
        var copied: Int64 = 0
        let start = Date()
        while true {
            try Task.checkCancellation()
            let n = read(inFD, buf, block)
            if n < 0 { throw LumoraError.unsupported("Read error while staging.") }
            if n == 0 { break }
            var off = 0
            while off < n {
                let w = write(outFD, buf + off, n - off)
                if w <= 0 { throw LumoraError.unsupported("Write error while staging (scratch drive full?).") }
                off += w
            }
            copied += Int64(n)
            let mbps = Double(copied) / max(0.001, Date().timeIntervalSince(start)) / 1_000_000
            progress.update(size > 0 ? Double(copied) / Double(size) : nil,
                            detail: "\(ByteCountFormatter.string(fromByteCount: copied, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))",
                            rate: String(format: "%.0f MB/s", mbps))
        }
        Log.info(.storage, "Staged \(url.lastPathComponent) to \(dest.path)")
        return dest
    }
}

/// A small 10-bit HEVC proxy of the *encoded* source signal (log / PQ kept as-is), written while analysis reads
/// the file once. Preview and scrubbing then come from the SSD, not the slow drive. ~1-2 GB per hour of 4K.
final class ProxyWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let ctx = MetalContext.shared
    private let renderer = GradeRenderer()
    private let scaled: MTLTexture
    private let fps: (Int, Int)
    private var count = 0

    init(for d: SourceDescriptor, height: Int = 720) throws {
        url = ScratchManager.proxiesFolder.appendingPathComponent("\(d.url.deletingPathExtension().lastPathComponent)-\(abs(d.url.path.hashValue)).mov")
        try? FileManager.default.removeItem(at: url)
        let (w, h) = Self.outputSize(for: d, height: height)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020],
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
                                              kVTCompressionPropertyKey_Quality as String: 0.6]
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        writer.add(input)
        scaled = ctx.makeTexture(width: w, height: h, format: .rgba16Float)
        fps = (d.fpsNum, d.fpsDen)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
    }

    /// The proxy's picture size: at most `height` lines tall (never upscaled), same aspect ratio, even sizes.
    static func outputSize(for d: SourceDescriptor, height: Int = 720) -> (width: Int, height: Int) {
        let h = min(height, d.height) & ~1
        return ((d.width * h / max(1, d.height)) & ~1, h)
    }

    /// Stores the frame's encoded RGB unchanged (BT.2020 matrix in, BT.2020 matrix out on decode).
    func append(_ frame: MTLTexture) async {
        guard let pool = adaptor.pixelBufferPool else { return }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return }
        let cb = ctx.queue.makeCommandBuffer()!
        MPSImageBilinearScale(device: ctx.device).encode(commandBuffer: cb, sourceTexture: frame, destinationTexture: scaled)
        let keep = renderer.encodePack(cb, rgb: scaled, into: pb, matrixKr: 0.2627, matrixKb: 0.0593)
        await cb.commitAndWait()
        _ = keep
        while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 1_000_000) }
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(count) * CMTimeValue(fps.1), timescale: CMTimeScale(fps.0)))
        count += 1
    }

    func finish() async -> URL? {
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }
}
