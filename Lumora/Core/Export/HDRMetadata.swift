import Foundation

/// HDR10 static metadata plus generators for HDR10+ and Dolby Vision dynamic metadata.
/// Mastering display: P3-D65 primaries (the industry norm for HDR mastering) at the target peak.
enum HDRMetadata {
    struct Static {
        var peakNits: Float
        var minNits: Float = 0.005
        var maxCLL: Float
        var maxFALL: Float
    }

    // P3-D65 in units of 0.00002 (ST 2086 / HEVC SEI ordering: G, B, R, white point).
    static let p3 = (g: (13250, 34500), b: (7500, 3000), r: (34000, 16000), wp: (15635, 16450))

    /// 24-byte big-endian mastering display color volume, as VideoToolbox expects.
    static func vtMasteringDisplay(_ s: Static) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(contentsOf: [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        func u32(_ v: UInt32) { d.append(contentsOf: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }) }
        for (x, y) in [p3.g, p3.b, p3.r, p3.wp] { u16(x); u16(y) }
        u32(UInt32(s.peakNits * 10000))
        u32(UInt32(s.minNits * 10000))
        return d
    }

    /// 4-byte big-endian content light level (MaxCLL, MaxFALL).
    static func vtContentLightLevel(_ s: Static) -> Data {
        let a = UInt16(min(65535, s.maxCLL.rounded())), b = UInt16(min(65535, s.maxFALL.rounded()))
        return Data([UInt8(a >> 8), UInt8(a & 0xFF), UInt8(b >> 8), UInt8(b & 0xFF)])
    }

    static func svtMastering(_ s: Static) -> String {
        "G(0.265,0.690)B(0.150,0.060)R(0.680,0.320)WP(0.3127,0.3290)L(\(Int(s.peakNits)),\(s.minNits))"
    }

    static func x265Mastering(_ s: Static) -> String {
        "G(\(p3.g.0),\(p3.g.1))B(\(p3.b.0),\(p3.b.1))R(\(p3.r.0),\(p3.r.1))WP(\(p3.wp.0),\(p3.wp.1))"
            + "L(\(Int(s.peakNits * 10000)),\(Int(s.minNits * 10000)))"
    }

    /// VVenC `MasteringDisplayColourVolume`: G, B, R, white point (units of 0.00002), max, min (0.0001 cd/m²).
    static func vvencMastering(_ s: Static) -> String {
        [p3.g.0, p3.g.1, p3.b.0, p3.b.1, p3.r.0, p3.r.1, p3.wp.0, p3.wp.1,
         Int(s.peakNits * 10000), Int(s.minNits * 10000)].map(String.init).joined(separator: ",")
    }

    /// MP4Box `-hdr` file: mdcv + clli boxes for track 1 (the video), same units as the HEVC SEI.
    static func mp4BoxHDRXML(_ s: Static, trackID: Int = 1) -> String {
        let a = UInt16(min(65535, s.maxCLL.rounded())), b = UInt16(min(65535, s.maxFALL.rounded()))
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <HDR>
        <Track id="\(trackID)">
        <mdcv display_primaries_0_x="\(p3.g.0)" display_primaries_0_y="\(p3.g.1)" display_primaries_1_x="\(p3.b.0)" \
        display_primaries_1_y="\(p3.b.1)" display_primaries_2_x="\(p3.r.0)" display_primaries_2_y="\(p3.r.1)" \
        white_point_x="\(p3.wp.0)" white_point_y="\(p3.wp.1)" max_display_mastering_luminance="\(UInt32(s.peakNits * 10000))" \
        min_display_mastering_luminance="\(UInt32(s.minNits * 10000))"/>
        <clli max_content_light_level="\(a)" max_pic_average_light_level="\(b)"/>
        </Track>
        </HDR>

        """
    }

    /// mkvmerge track options for the Matroska Color/MasteringMetadata elements (chromaticities as fractions).
    static func mkvmergeStaticArgs(_ s: Static, track: Int) -> [String] {
        func f(_ v: Int) -> String { String(format: "%.4f", Double(v) / 50000) }
        let t = "\(track):"
        return ["--chromaticity-coordinates", t + [p3.r.0, p3.r.1, p3.g.0, p3.g.1, p3.b.0, p3.b.1].map(f).joined(separator: ","),
                "--white-colour-coordinates", t + f(p3.wp.0) + "," + f(p3.wp.1),
                "--max-luminance", t + "\(Int(s.peakNits))",
                "--min-luminance", t + "\(s.minNits)",
                "--max-content-light", t + "\(Int(min(65535, s.maxCLL.rounded())))",
                "--max-frame-light", t + "\(Int(min(65535, s.maxFALL.rounded())))"]
    }

    static func pqCode12(_ nits: Float) -> Int {
        let m1: Float = 0.1593017578125, m2: Float = 78.84375
        let c1: Float = 0.8359375, c2: Float = 18.8515625, c3: Float = 18.6875
        let y = powf(max(0, min(1, nits / 10000)), m1)
        return Int((powf((c1 + c2 * y) / (1 + c3 * y), m2) * 4095).rounded())
    }

    struct Shot { var start: Int; var duration: Int; var maxNits: Float; var avgNits: Float }

    /// Input for `dovi_tool generate` (profile 8.1 or 8.4, CM v4.0): one L1 block per shot from measured light levels.
    /// Checked against dovi_tool 2.3 (CampaignHDRMetadataTests).
    static func doviGeneratorJSON(frames: Int, shots: [Shot], s: Static, profile: String = "8.1") throws -> Data {
        let json: [String: Any] = [
            "cm_version": "V40",
            "profile": profile,
            "length": frames,
            "level6": ["max_display_mastering_luminance": Int(s.peakNits),
                       "min_display_mastering_luminance": Int(s.minNits * 10000),
                       "max_content_light_level": Int(s.maxCLL),
                       "max_frame_average_light_level": Int(s.maxFALL)],
            "shots": shots.map { shot in
                ["start": shot.start, "duration": shot.duration,
                 "metadata_blocks": [["Level1": ["min_pq": 0,
                                                 "max_pq": pqCode12(shot.maxNits),
                                                 "avg_pq": pqCode12(shot.avgNits)]]]] as [String: Any]
            }
        ]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
    }

    /// HDR10+ (ST 2094-40) metadata JSON for `hdr10plus_tool inject`. BETA: luminance distributions are
    /// approximated from each scene's measured max/average, and the schema should be checked against the
    /// hdr10plus_tool version you install.
    static func hdr10PlusJSON(frames: Int, shots: [Shot]) throws -> Data {
        let idx = [1, 5, 10, 25, 50, 75, 90, 95, 99]
        var sceneInfo: [[String: Any]] = []
        for (sceneID, shot) in shots.enumerated() {
            let dist = idx.map { p -> Int in
                let q = Float(p) / 100
                let v = q <= 0.5 ? shot.avgNits * powf(q / 0.5, 1.5)
                                 : shot.avgNits + (shot.maxNits - shot.avgNits) * powf((q - 0.5) / 0.5, 3)
                return Int(v * 10)
            }
            for f in 0..<shot.duration {
                sceneInfo.append([
                    "LuminanceParameters": [
                        "AverageRGB": Int(shot.avgNits * 10),
                        "LuminanceDistributions": ["DistributionIndex": idx, "DistributionValues": dist],
                        "MaxScl": Array(repeating: Int(shot.maxNits * 10), count: 3)
                    ],
                    "NumberOfWindows": 1,
                    "TargetedSystemDisplayMaximumLuminance": 0,
                    "SceneFrameIndex": f,
                    "SceneId": sceneID,
                    "SequenceFrameIndex": shot.start + f
                ])
            }
        }
        let json: [String: Any] = [
            "JSONInfo": ["HDR10plusProfile": "A", "Version": "1.0"],
            "SceneInfo": sceneInfo,
            "SceneInfoSummary": ["SceneFirstFrameIndex": shots.map(\.start), "SceneFrameNumbers": shots.map(\.duration)],
            "ToolInfo": ["Tool": "Lumora", "Version": "0.1"]
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }
}

/// Writes .cube 3D LUTs of a preset (global part of the grade) for Resolve, Final Cut Pro, Premiere, etc.
enum LUTExporter {
    static func export(preset: PresetCandidate, target: OutputTarget, size: Int = 65, to url: URL) throws {
        // A LUT is one fixed transform: use the preset's typical exposure (median of its scenes).
        let sorted = preset.sceneExposures.sorted()
        let typical = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let u = UniformBuilder.make(source: preset.color, params: preset.params, target: target,
                                    sceneExposureStops: typical, viewport: SIMD4<Float>(0, 0, 1, 1))
        let values = GradeRenderer().bakeLUT(uniforms: u, size: size)
        var text = """
        TITLE "Lumora \(preset.name) — \(target.displayName)"
        # Input:  \(preset.color.name) (\(preset.color.transfer.rawValue), \(preset.color.gamut.displayName))
        # Output: \(target.displayName)
        # Bakes exposure, contrast, tone curve, color and gamut mapping.
        # Not included (cannot live in a LUT): local-contrast "punch" and per-scene auto exposure.
        LUT_3D_SIZE \(size)
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0

        """
        text.reserveCapacity(values.count * 28)
        for v in values { text += String(format: "%.6f %.6f %.6f\n", v.x, v.y, v.z) }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

extension HDRMetadata {
    /// Reads the 24-byte big-endian mastering display color volume (the layout `vtMasteringDisplay` writes: G, B, R,
    /// white point as x, y in units of 0.00002, then max and min luminance in 0.0001 cd/m²). Returns primaries as
    /// (x, y) for R, G, B, then the white point.
    static func parseMasteringDisplay(_ d: Data) -> (maxNits: Double, minNits: Double, primaries: [Double])? {
        guard d.count >= 24 else { return nil }
        let b = [UInt8](d.prefix(24))
        func u16(_ o: Int) -> Double { Double(Int(b[o]) << 8 | Int(b[o + 1])) }
        func u32(_ o: Int) -> Double { Double(UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3])) }
        let g = (u16(0), u16(2)), bl = (u16(4), u16(6)), r = (u16(8), u16(10)), wp = (u16(12), u16(14))
        let prim = [r.0, r.1, g.0, g.1, bl.0, bl.1, wp.0, wp.1].map { $0 * 0.00002 }
        let maxN = u32(16) / 10000, minN = u32(20) / 10000
        guard maxN > 0, maxN <= 100_000 else { return nil }
        return (maxN, minN, prim)
    }

    /// Reads the 4-byte big-endian content light level (MaxCLL, MaxFALL).
    static func parseContentLightLevel(_ d: Data) -> (maxCLL: Double, maxFALL: Double)? {
        guard d.count >= 4 else { return nil }
        let b = [UInt8](d.prefix(4))
        return (Double(Int(b[0]) << 8 | Int(b[1])), Double(Int(b[2]) << 8 | Int(b[3])))
    }
}
