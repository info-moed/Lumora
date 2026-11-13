import Foundation

/// Reads an AV2 low-overhead OBU stream (what avmenc writes with --obu) far enough to check how it is signaled:
/// which OBUs it holds and the color description of its content interpretation OBU. FFmpeg and ffprobe can't read
/// AV2 yet, so this is how Lumora confirms an AV2 export carries the right primaries, transfer and matrix.
///
/// Layout (AVM research-v15 / AV2 v1.0, av2/common/obu_util.c): each OBU starts with its size as LEB128, counting
/// the OBU header, then a one-byte header (extension flag, 5-bit type, 2-bit temporal layer; one more byte when the
/// extension flag is set), then the payload. The content interpretation OBU (type 24) begins with
/// ci_scan_type_idc (2 bits), four presence flags (color description, chroma sample position, aspect ratio,
/// timing) and 2 reserved bits; the color description is a Rice-Golomb (k = 2) color_description_idc, explicit
/// 8-bit primaries, transfer and matrix when that idc is 0, and a full-range bit (av2/encoder/bitstream_ci.c).
enum AV2Stream {
    static let sequenceHeader = 1, temporalDelimiter = 2, contentInterpretation = 24

    struct ColorInfo: Equatable {
        var descriptionIDC: Int
        var primaries: Int
        var transfer: Int
        var matrix: Int
        var fullRange: Bool
    }

    struct Summary {
        var obuCounts: [Int: Int] = [:]
        var color: ColorInfo?
        var chromaSamplePosition: Int?
        var temporalUnits: Int { obuCounts[AV2Stream.temporalDelimiter] ?? 0 }
        var sequenceHeaders: Int { obuCounts[AV2Stream.sequenceHeader] ?? 0 }
    }

    static func summary(of url: URL) throws -> Summary {
        try summary(of: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func summary(of data: Data) throws -> Summary {
        let bytes = [UInt8](data)
        var s = Summary()
        var i = 0
        while i < bytes.count {
            guard let (size, lengthBytes) = leb128(bytes, at: i), size >= 1, i + lengthBytes + size <= bytes.count else {
                throw LumoraError.decodeFailed("Not an AV2 OBU stream (bad OBU size at byte \(i)).")
            }
            let h = i + lengthBytes
            let header = bytes[h]
            let headerSize = header & 0x80 != 0 ? 2 : 1
            let type = Int((header >> 2) & 0x1F)
            guard size >= headerSize else { throw LumoraError.decodeFailed("Not an AV2 OBU stream (short OBU at byte \(i)).") }
            s.obuCounts[type, default: 0] += 1
            if type == contentInterpretation, s.color == nil {
                let payload = Array(bytes[(h + headerSize)..<(h + size)])
                (s.color, s.chromaSamplePosition) = parseContentInterpretation(payload)
            }
            i = h + size
        }
        guard s.sequenceHeaders > 0 else { throw LumoraError.decodeFailed("Not an AV2 OBU stream (no sequence header).") }
        return s
    }

    /// The CICP triple a color_description_idc stands for (avm/avm_image.h: AVM_COLOR_DESC_IDC_*).
    static func cicp(forDescriptionIDC idc: Int) -> (Int, Int, Int)? {
        switch idc {
        case 1: return (1, 1, 1)       // BT.709 SDR
        case 2: return (9, 16, 9)      // BT.2100 PQ
        case 3: return (9, 18, 9)      // BT.2100 HLG
        case 4: return (1, 13, 0)      // sRGB
        case 5: return (1, 13, 5)      // sYCC
        default: return nil
        }
    }

    private static func parseContentInterpretation(_ p: [UInt8]) -> (ColorInfo?, Int?) {
        var r = BitReader(p)
        let scanType = r.bits(2)
        let colorPresent = r.bit(), cspPresent = r.bit()
        _ = r.bit(); _ = r.bit(); _ = r.bits(2)       // aspect ratio, timing, reserved
        var color: ColorInfo?
        if colorPresent {
            var quotient = 0
            while r.bit() && quotient < 32 { quotient += 1 }
            let idc = quotient << 2 | r.bits(2)
            var triple = cicp(forDescriptionIDC: idc) ?? (2, 2, 2)
            if idc == 0 { triple = (r.bits(8), r.bits(8), r.bits(8)) }
            color = ColorInfo(descriptionIDC: idc, primaries: triple.0, transfer: triple.1, matrix: triple.2, fullRange: r.bit())
        }
        var csp: Int?
        if cspPresent { csp = r.uvlc(); if scanType != 1 { _ = r.uvlc() } }
        return (color, csp)
    }

    private static func leb128(_ b: [UInt8], at start: Int) -> (Int, Int)? {
        var value = 0
        for k in 0..<8 where start + k < b.count {
            value |= Int(b[start + k] & 0x7F) << (7 * k)
            if b[start + k] & 0x80 == 0 { return (value, k + 1) }
        }
        return nil
    }

    private struct BitReader {
        let bytes: [UInt8]
        var pos = 0
        init(_ b: [UInt8]) { bytes = b }
        mutating func bit() -> Bool {
            defer { pos += 1 }
            guard pos / 8 < bytes.count else { return false }
            return bytes[pos / 8] >> (7 - pos % 8) & 1 == 1
        }
        mutating func bits(_ n: Int) -> Int { (0..<n).reduce(0) { v, _ in v << 1 | (bit() ? 1 : 0) } }
        mutating func uvlc() -> Int {
            var zeros = 0
            while !bit() && zeros < 32 { zeros += 1 }
            return zeros >= 32 ? 0 : (1 << zeros) - 1 + bits(zeros)
        }
    }
}
