import Foundation

/// Netflix VMAF via libvmaf, fully streamed: the reference (Lumora's lossless pre-encode render, held in RAM)
/// and the encoded chunk (decoded by FFmpeg) flow through named pipes. Nothing is extracted to disk.
///
/// HDR note: VMAF was trained on SDR viewing. Lumora scores the PQ/HLG-coded 10-bit signal directly, which
/// tracks compression loss consistently but is not a calibrated HDR quality scale. Treat targets as relative:
/// the same target gives the same visual safety margin from clip to clip.
enum VMAFRunner {
    enum Pool: String, CaseIterable, Codable, Identifiable {
        case mean = "Average", p5 = "Worst 5% of frames", harmonic = "Harmonic mean"
        var id: String { rawValue }
    }

    struct Options: Codable, Hashable {
        var model = "vmaf_v0.6.1"
        var subsample = 1          // score every Nth frame (fast validation: 2-3)
        var threads = 8
        var downscaleHeight: Int?  // fast validation: score 4K at 1080p with the standard model
    }

    struct Result {
        var frames: [(index: Int, score: Double)]
        var mean: Double
        var min: Double
        var harmonic: Double
        var p5: Double

        func pooled(_ p: Pool) -> Double { p == .mean ? mean : (p == .p5 ? p5 : harmonic) }
    }

    enum Backend { case vmafCLI, ffmpegLibvmaf, none }

    /// Clears colour tags at the start of each branch of a two-input FFmpeg comparison graph. The reference Y4M
    /// carries no matrix while an encode is tagged (BT.709 / BT.2020), and FFmpeg would then convert one side's
    /// matrix before the metric sees it: a CRF 18 encode scored VMAF 47 / XPSNR 10 dB instead of 99 / 45 dB.
    /// Metrics must compare code values exactly as coded, as the vmaf CLI path does.
    static let untagged = "setparams=range=unknown:color_primaries=unknown:color_trc=unknown:colorspace=unknown,"

    static let backend: Backend = {
        if ToolLocator.isAvailable("vmaf") { return .vmafCLI }
        if let filters = try? ToolLocator.run("ffmpeg", ["-hide_banner", "-filters"]),
           String(decoding: filters, as: UTF8.self).contains("libvmaf") { return .ffmpegLibvmaf }
        return .none
    }()
    static var available: Bool { backend != .none }

    static var sameCodeValues: String { untagged }   // the same fix, found twice; one filter for both names

    /// - writeReference: writes the reference as a 4:2:0 10-bit Y4M stream (header + frames) to the handle.
    /// - using: the backend to run (defaults to the detected one; tests pass `.ffmpegLibvmaf` to exercise the fallback).
    static func score(writeReference: @escaping (FileHandle) throws -> Void, distorted: URL, frameRate: (Int, Int),
                      options o: Options, workDir: URL, using chosen: Backend? = nil) async throws -> Result {
        let tag = UUID().uuidString.prefix(6)
        let json = workDir.appendingPathComponent("vmaf-\(tag).json")
        let scale = o.downscaleHeight.map { "scale=-2:\($0):flags=bicubic," } ?? ""
        Log.debug(.quality, "VMAF \(distorted.lastPathComponent) model=\(o.model) subsample=\(o.subsample) scale=\(o.downscaleHeight ?? 0)")
        switch chosen ?? backend {
        case .none:
            throw LumoraError.missingTool("vmaf (brew install libvmaf)")
        case .vmafCLI:
            let refFifo = workDir.appendingPathComponent("ref-\(tag).y4m").path
            let distFifo = workDir.appendingPathComponent("dist-\(tag).y4m").path
            guard mkfifo(refFifo, 0o600) == 0, mkfifo(distFifo, 0o600) == 0 else { throw LumoraError.unsupported("pipe") }
            defer { unlink(refFifo); unlink(distFifo) }
            let decoder = try launch("ffmpeg", ["-v", "error", "-nostdin", "-r", "\(frameRate.0)/\(frameRate.1)", "-i", distorted.path,
                                                "-vf", "\(scale)format=yuv420p10le", "-strict", "-1", "-f", "yuv4mpegpipe", "-y", distFifo])
            let vmaf = try launch("vmaf", ["--reference", refFifo, "--distorted", distFifo, "--threads", "\(o.threads)",
                                           "--subsample", "\(o.subsample)", "--model", "version=\(o.model)",
                                           "--json", "--output", json.path, "--quiet"])
            if let h = o.downscaleHeight {
                // Reference goes through a scaler so both sides are resampled identically.
                let scaler = Process()
                scaler.executableURL = ToolLocator.url(for: "ffmpeg")
                scaler.arguments = ["-v", "error", "-f", "yuv4mpegpipe", "-i", "pipe:0", "-vf", "scale=-2:\(h):flags=bicubic,format=yuv420p10le",
                                    "-strict", "-1", "-f", "yuv4mpegpipe", "-y", refFifo]
                let pipe = Pipe()
                scaler.standardInput = pipe
                scaler.standardError = FileHandle.nullDevice
                scaler.arguments = FFHarden.args("ffmpeg", scaler.arguments ?? [])
                try scaler.runWatched()
                try await Task.detached { try writeReference(pipe.fileHandleForWriting); try pipe.fileHandleForWriting.close() }.value
                await wait(scaler)
            } else {
                try await Task.detached {
                    let h = try FileHandle(forWritingTo: URL(fileURLWithPath: refFifo))
                    try writeReference(h)
                    try h.close()
                }.value
            }
            await wait(decoder)
            await wait(vmaf)
            guard vmaf.terminationStatus == 0 else { throw LumoraError.toolFailed("vmaf", "exit \(vmaf.terminationStatus)") }
        case .ffmpegLibvmaf:
            let p = Process()
            p.executableURL = ToolLocator.url(for: "ffmpeg")
            let graph = "[1:v]\(untagged)\(scale)format=yuv420p10le[d];[0:v]\(untagged)\(scale)format=yuv420p10le[r];"
                + "[d][r]libvmaf=model=version=\(o.model):n_threads=\(o.threads):n_subsample=\(o.subsample):log_fmt=json:log_path=\(json.lastPathComponent)"
            p.arguments = ["-v", "error", "-f", "yuv4mpegpipe", "-i", "pipe:0", "-r", "\(frameRate.0)/\(frameRate.1)", "-i", distorted.path,
                           "-lavfi", graph, "-f", "null", "-"]
            // The log goes to a plain relative name inside the job folder, so no path characters (':', ',', '\'')
            // ever need escaping inside the filtergraph.
            p.currentDirectoryURL = json.deletingLastPathComponent()
            let pipe = Pipe()
            p.standardInput = pipe
            p.standardError = FileHandle.nullDevice
            p.arguments = FFHarden.args("ffmpeg", p.arguments ?? [])
            try p.runWatched()
            try await Task.detached { try writeReference(pipe.fileHandleForWriting); try pipe.fileHandleForWriting.close() }.value
            await wait(p)
            guard p.terminationStatus == 0 else { throw LumoraError.toolFailed("ffmpeg libvmaf", "exit \(p.terminationStatus)") }
        }
        defer { try? FileManager.default.removeItem(at: json) }
        return try parse(json)
    }

    /// Generic libvmaf run (CLI backend): any models and features in one pass. Returns per-frame metric dictionaries.
    static func runLibvmaf(writeReference: @escaping (FileHandle) throws -> Void, distorted: URL, frameRate: (Int, Int),
                           threads: Int, subsample: Int, downscaleHeight: Int?, extraArgs: [String],
                           workDir: URL, decoderInputArgs: [String] = []) async throws -> [(index: Int, metrics: [String: Double])] {
        guard backend == .vmafCLI else {
            // FFmpeg's libvmaf filter: VMAF only.
            let r = try await score(writeReference: writeReference, distorted: distorted, frameRate: frameRate,
                                    options: Options(subsample: subsample, threads: threads, downscaleHeight: downscaleHeight), workDir: workDir)
            return r.frames.map { ($0.index, ["vmaf": $0.score]) }
        }
        let tag = UUID().uuidString.prefix(6)
        let json = workDir.appendingPathComponent("libvmaf-\(tag).json")
        defer { try? FileManager.default.removeItem(at: json) }
        let refFifo = workDir.appendingPathComponent("lref-\(tag).y4m").path
        let distFifo = workDir.appendingPathComponent("ldist-\(tag).y4m").path
        guard mkfifo(refFifo, 0o600) == 0, mkfifo(distFifo, 0o600) == 0 else { throw LumoraError.unsupported("pipe") }
        defer { unlink(refFifo); unlink(distFifo) }
        let scale = downscaleHeight.map { "scale=-2:\($0):flags=bicubic," } ?? ""
        let decoder = try launch("ffmpeg", ["-v", "error", "-nostdin"] + decoderInputArgs + ["-r", "\(frameRate.0)/\(frameRate.1)", "-i", distorted.path,
                                            "-vf", "\(scale)format=yuv420p10le", "-strict", "-1", "-f", "yuv4mpegpipe", "-y", distFifo])
        let vmaf = try launch("vmaf", ["--reference", refFifo, "--distorted", distFifo, "--threads", "\(threads)",
                                       "--subsample", "\(subsample)", "--json", "--output", json.path, "--quiet"] + extraArgs)
        if let h = downscaleHeight {
            let scaler = Process()
            scaler.executableURL = ToolLocator.url(for: "ffmpeg")
            scaler.arguments = ["-v", "error", "-f", "yuv4mpegpipe", "-i", "pipe:0", "-vf", "scale=-2:\(h):flags=bicubic,format=yuv420p10le",
                                "-strict", "-1", "-f", "yuv4mpegpipe", "-y", refFifo]
            let pipe = Pipe()
            scaler.standardInput = pipe
            scaler.standardError = FileHandle.nullDevice
            scaler.arguments = FFHarden.args("ffmpeg", scaler.arguments ?? [])
            try scaler.runWatched()
            try await Task.detached { try writeReference(pipe.fileHandleForWriting); try pipe.fileHandleForWriting.close() }.value
            await wait(scaler)
        } else {
            try await Task.detached {
                let h = try FileHandle(forWritingTo: URL(fileURLWithPath: refFifo))
                try writeReference(h); try h.close()
            }.value
        }
        await wait(decoder)
        await wait(vmaf)
        guard vmaf.terminationStatus == 0 else { throw LumoraError.toolFailed("vmaf", "exit \(vmaf.terminationStatus)") }
        guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any],
              let frames = obj["frames"] as? [[String: Any]] else { throw LumoraError.unsupported("Unreadable libvmaf log") }
        return frames.compactMap { f in
            guard let n = f["frameNum"] as? Int, let m = f["metrics"] as? [String: Any] else { return nil }
            // libvmaf writes non-finite scores as null: PSNR-HVS and CIEDE2000 of an identical frame are +∞.
            return (n, m.compactMapValues { $0 is NSNull ? Double.infinity : ($0 as? NSNumber)?.doubleValue })
        }
    }

    private static func launch(_ tool: String, _ args: [String]) throws -> Process {
        guard let exe = ToolLocator.url(for: tool) else { throw LumoraError.missingTool(tool) }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.runWatched()
        Log.debug(.tools, "\(tool) \(args.joined(separator: " "))")
        return p
    }

    private static func wait(_ p: Process) async {
        await p.exited()
    }

    static func parse(_ url: URL) throws -> Result {
        guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let frames = obj["frames"] as? [[String: Any]] else { throw LumoraError.unsupported("Unreadable VMAF log") }
        let scores: [(Int, Double)] = frames.compactMap { f in
            guard let n = f["frameNum"] as? Int, let m = f["metrics"] as? [String: Any], let v = m["vmaf"] as? Double else { return nil }
            return (n, v)
        }
        let values = scores.map(\.1).sorted()
        guard !values.isEmpty else { throw LumoraError.unsupported("VMAF returned no frames") }
        let mean = values.reduce(0, +) / Double(values.count)
        let harmonic = Double(values.count) / values.reduce(0) { $0 + 1 / max($1 + 1, 1) } - 1
        return Result(frames: scores, mean: mean, min: values.first!, harmonic: harmonic,
                      p5: values[max(0, Int(Double(values.count) * 0.05) - 1)])
    }
}

extension PlanarFrame {
    /// Writes this frame as 4:2:0 10-bit Y4M (what VMAF reads), converting from 12-bit / 4:2:2 / 4:4:4 if needed.
    func writeY4M420p10(to handle: FileHandle) throws {
        try handle.write(contentsOf: Data("FRAME\n".utf8))
        let shift = UInt16(max(0, bits - 10))
        let ySrc = y.contents().bindMemory(to: UInt16.self, capacity: width * height)
        if shift == 0 {
            try handle.write(contentsOf: Data(bytesNoCopy: y.contents(), count: width * height * 2, deallocator: .none))
        } else {
            var out = [UInt16](repeating: 0, count: width * height)
            for i in 0..<out.count { out[i] = ySrc[i] >> shift }
            try out.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        }
        let cw = width / 2, ch = height / 2
        for plane in [cb, cr] {
            let src = plane.contents().bindMemory(to: UInt16.self, capacity: chromaWidth * chromaHeight)
            if chroma == .c420 && shift == 0 {
                try handle.write(contentsOf: Data(bytesNoCopy: plane.contents(), count: cw * ch * 2, deallocator: .none))
                continue
            }
            var out = [UInt16](repeating: 0, count: cw * ch)
            let sx = chroma == .c444 ? 2 : 1, sy = chroma == .c420 ? 1 : 2
            for yy in 0..<ch {
                for xx in 0..<cw {
                    var acc = 0
                    for dy in 0..<sy { for dx in 0..<sx { acc += Int(src[(yy * sy + dy) * chromaWidth + xx * sx + dx]) } }
                    out[yy * cw + xx] = UInt16(acc / (sx * sy)) >> shift
                }
            }
            try out.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        }
    }

    static func y4mHeader420p10(width: Int, height: Int, fps: (Int, Int)) -> String {
        "YUV4MPEG2 W\(width) H\(height) F\(fps.0):\(fps.1) Ip A1:1 C420p10 XYSCSS=420P10\n"
    }
}
