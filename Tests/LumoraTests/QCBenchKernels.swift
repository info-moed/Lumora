import Foundation
import Metal
@testable import Lumora

/// GPU kernels used only by the QC benchmark (compiled at run time, so the app's shader library is untouched).
/// Everything is measured in the encoded signal the interpolation pipeline works on (BT.1886 gamma for SDR, PQ for
/// HDR10), never after grading.
enum QCBenchKernels {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    constant float3 kL = float3(0.2627f, 0.6780f, 0.0593f);     // same luma weights as the app's QC and compare kernels
    inline float lum(float4 c) { return dot(c.rgb, kL); }

    struct YUVParams { float kr; float kb; int legalOut; int pad; float chromaX; float chromaY; float pad1; float pad2; };

    // NV12 (8-bit, video range) -> R'G'B' in the encoded signal, matching the app's AVFoundation decode.
    kernel void nv12ToRGB(texture2d<float, access::read>   yT  [[texture(0)]],
                          texture2d<float, access::sample> uvT [[texture(1)]],
                          texture2d<float, access::write>  dst [[texture(2)]],
                          constant YUVParams& p                [[buffer(0)]],
                          uint2 gid                            [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float Y = yT.read(gid).r * 255.0f;
        float2 cw = float2(uvT.get_width(), uvT.get_height());
        float2 c = (float2(gid) + 0.5f) * 0.5f + float2(p.chromaX, p.chromaY);
        float2 uv = uvT.sample(s, c / cw).rg * 255.0f;
        float yn = (Y - 16.0f) / 219.0f, cb = (uv.x - 128.0f) / 224.0f, cr = (uv.y - 128.0f) / 224.0f;
        float r = yn + 2.0f * (1.0f - p.kr) * cr;
        float b = yn + 2.0f * (1.0f - p.kb) * cb;
        float g = (yn - p.kr * r - p.kb * b) / (1.0f - p.kr - p.kb);
        float3 o = float3(r, g, b);
        if (p.legalOut != 0) o = o * (219.0f / 255.0f) + 16.0f / 255.0f;
        dst.write(float4(o, 1.0f), gid);
    }

    // Box downscale by an integer factor. mode 0: red channel (a luma plane), 1: luma of RGB.
    kernel void boxDown(texture2d<float, access::read>  src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant int2& fm                   [[buffer(0)]],
                        uint2 gid                           [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        int f = fm.x;
        float s = 0.0f;
        for (int y = 0; y < f; y++) for (int x = 0; x < f; x++) {
            float4 v = src.read(gid * uint(f) + uint2(x, y));
            s += fm.y == 0 ? v.r : lum(v);
        }
        dst.write(float4(s / float(f * f)), gid);
    }

    kernel void hist64(texture2d<float, access::read> src [[texture(0)]],
                       device atomic_uint* h              [[buffer(0)]],
                       uint2 gid                          [[thread_position_in_grid]]) {
        if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
        int bin = clamp(int(src.read(gid).r * 64.0f), 0, 63);
        atomic_fetch_add_explicit(&h[bin], 1u, memory_order_relaxed);
    }

    struct BMParams { int blocksX; int blocksY; int nOffsets; int block; };

    // Exhaustive block matching (one thread per block x offset). best = (mean abs diff << 14) | offset rank;
    // offsets are sorted by length, so ties resolve to the smallest motion.
    kernel void blockMatch(texture2d<float, access::read> prev [[texture(0)]],
                           texture2d<float, access::read> cur  [[texture(1)]],
                           device const int2* offsets          [[buffer(0)]],
                           device atomic_uint* best            [[buffer(1)]],
                           device float* zero                  [[buffer(2)]],
                           constant BMParams& p                [[buffer(3)]],
                           uint2 gid                           [[thread_position_in_grid]]) {
        if (gid.x >= uint(p.blocksX * p.blocksY) || gid.y >= uint(p.nOffsets)) return;
        int bx = int(gid.x) % p.blocksX, by = int(gid.x) / p.blocksX;
        int2 o = offsets[gid.y];
        int W = int(cur.get_width()), H = int(cur.get_height());
        float sad = 0.0f; int n = 0;
        for (int y = 0; y < p.block; y++) for (int x = 0; x < p.block; x++) {
            int2 q = int2(bx * p.block + x, by * p.block + y);
            if (q.x >= W || q.y >= H) continue;
            int2 r = clamp(q + o, int2(0), int2(W - 1, H - 1));
            sad += abs(cur.read(uint2(q)).r - prev.read(uint2(r)).r);
            n++;
        }
        float m = sad / float(max(n, 1));
        if (gid.y == 0) zero[gid.x] = m;
        uint packed = (min(uint(m * 16383.0f), 16383u) << 14) | gid.y;
        atomic_fetch_min_explicit(&best[gid.x], packed, memory_order_relaxed);
    }

    struct TileP { int tile; int tilesX; int tilesY; int pad; };

    // Per 64-px tile: squared error (RGB sum), SSIM sum over full 8x8 luma blocks, SSIM block count, pixel count.
    kernel void tileErr(texture2d<float, access::read> a [[texture(0)]],
                        texture2d<float, access::read> b [[texture(1)]],
                        device atomic_float* out         [[buffer(0)]],
                        constant TileP& tp               [[buffer(1)]],
                        uint2 gid                        [[thread_position_in_grid]]) {
        uint W = a.get_width(), H = a.get_height();
        uint2 o = gid * 8;
        if (o.x >= W || o.y >= H) return;
        float sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0, se = 0; int n = 0;
        for (uint y = 0; y < 8; y++) for (uint x = 0; x < 8; x++) {
            uint2 q = o + uint2(x, y);
            if (q.x >= W || q.y >= H) continue;
            float3 ca = a.read(q).rgb, cb = b.read(q).rgb;
            float la = dot(ca, kL), lb = dot(cb, kL);
            sa += la; sb += lb; saa += la * la; sbb += lb * lb; sab += la * lb;
            float3 d = ca - cb; se += dot(d, d); n++;
        }
        uint tx = min(o.x / uint(tp.tile), uint(tp.tilesX - 1)), ty = min(o.y / uint(tp.tile), uint(tp.tilesY - 1));
        uint t = ty * uint(tp.tilesX) + tx;
        atomic_fetch_add_explicit(&out[t * 4 + 0], se, memory_order_relaxed);
        atomic_fetch_add_explicit(&out[t * 4 + 3], float(n), memory_order_relaxed);
        if (n == 64) {
            float nn = 64.0f, ma = sa / nn, mb = sb / nn;
            float va = saa / nn - ma * ma, vb = sbb / nn - mb * mb, cov = sab / nn - ma * mb;
            const float C1 = 0.0001f, C2 = 0.0009f;
            float ssim = ((2 * ma * mb + C1) * (2 * cov + C2)) / ((ma * ma + mb * mb + C1) * (va + vb + C2));
            atomic_fetch_add_explicit(&out[t * 4 + 1], ssim, memory_order_relaxed);
            atomic_fetch_add_explicit(&out[t * 4 + 2], 1.0f, memory_order_relaxed);
        }
    }

    inline float lumAt(texture2d<float, access::read> t, int2 p) {
        int2 q = clamp(p, int2(0), int2(int(t.get_width()) - 1, int(t.get_height()) - 1));
        return lum(t.read(uint2(q)));
    }
    inline float gradAt(texture2d<float, access::read> t, int2 p) {
        return abs(lumAt(t, p + int2(1, 0)) - lumAt(t, p - int2(1, 0))) + abs(lumAt(t, p + int2(0, 1)) - lumAt(t, p - int2(0, 1)));
    }

    // Reference-free tile features (half-rate sampling, like interpQCKernel). 12 sums + 2 maxima per tile.
    kernel void tileFeat(texture2d<float, access::read> A  [[texture(0)]],
                         texture2d<float, access::read> B  [[texture(1)]],
                         texture2d<float, access::read> P  [[texture(2)]],   // primary model output
                         texture2d<float, access::read> Q  [[texture(3)]],   // the other model's output
                         texture2d<float, access::read> Pf [[texture(4)]],   // primary, flip test-time augmentation
                         texture2d<float, access::read> Qf [[texture(5)]],
                         texture2d<float, access::read> BL [[texture(6)]],   // cross-fade
                         device atomic_float* out          [[buffer(0)]],
                         device atomic_uint* omax          [[buffer(1)]],
                         constant TileP& tp                [[buffer(2)]],
                         uint2 gid                         [[thread_position_in_grid]]) {
        uint W = P.get_width(), H = P.get_height();
        uint2 q = gid * 2;
        if (q.x >= W || q.y >= H) return;
        int2 p = int2(q);
        float lA = lumAt(A, p), lB = lumAt(B, p), lP = lumAt(P, p), lQ = lumAt(Q, p);
        float lPf = lumAt(Pf, p), lQf = lumAt(Qf, p), lBL = lumAt(BL, p);
        float gA = gradAt(A, p), gB = gradAt(B, p), gP = gradAt(P, p);
        uint tx = min(q.x / uint(tp.tile), uint(tp.tilesX - 1)), ty = min(q.y / uint(tp.tile), uint(tp.tilesY - 1));
        uint t = ty * uint(tp.tilesX) + tx;
        device atomic_float* o = out + t * 12;
        atomic_fetch_add_explicit(&o[0], lP, memory_order_relaxed);
        atomic_fetch_add_explicit(&o[1], abs(lA - lB), memory_order_relaxed);
        atomic_fetch_add_explicit(&o[2], gA, memory_order_relaxed);
        atomic_fetch_add_explicit(&o[3], gP, memory_order_relaxed);
        atomic_fetch_add_explicit(&o[4], abs(lP - lQ), memory_order_relaxed);
        atomic_fetch_add_explicit(&o[5], abs(lP - lPf), memory_order_relaxed);
        atomic_fetch_add_explicit(&o[6], abs(lQ - lQf), memory_order_relaxed);
        atomic_fetch_add_explicit(&o[7], abs(lP - lBL), memory_order_relaxed);
        atomic_fetch_add_explicit(&o[8], min(abs(lP - lA), abs(lP - lB)), memory_order_relaxed);
        atomic_fetch_add_explicit(&o[9], 1.0f, memory_order_relaxed);
        atomic_fetch_add_explicit(&o[10], max(0.0f, gP - max(gA, gB)), memory_order_relaxed);
        atomic_fetch_add_explicit(&o[11], abs(lP - lPf) > 0.02f ? 1.0f : 0.0f, memory_order_relaxed);
        atomic_fetch_max_explicit(&omax[t * 2 + 0], as_type<uint>(abs(lP - lQ)), memory_order_relaxed);
        atomic_fetch_max_explicit(&omax[t * 2 + 1], as_type<uint>(abs(lP - lPf)), memory_order_relaxed);
    }

    struct FlowStatP { int tw; int th; int cw; int ch; float t; int fullW; int fullH; int tile; int tilesX; int tilesY; int pad0; int pad1; };

    // Statistics of the flow model's last prediction (motion t->0 / t->1 and blend mask) per full-resolution tile.
    kernel void flowStats(device const half* flow      [[buffer(0)]],
                          device const half* mask      [[buffer(1)]],
                          device atomic_float* out     [[buffer(2)]],
                          device atomic_uint* omax     [[buffer(3)]],
                          constant FlowStatP& p        [[buffer(4)]],
                          uint2 gid                    [[thread_position_in_grid]]) {
        if (gid.x >= uint(p.cw) || gid.y >= uint(p.ch)) return;
        uint plane = uint(p.tw * p.th);
        uint i = gid.y * uint(p.tw) + gid.x;
        float2 f0 = float2(flow[i], flow[plane + i]);
        float2 f1 = float2(flow[2 * plane + i], flow[3 * plane + i]);
        float m = float(mask[i]);
        float sx = float(p.fullW) / float(p.cw);
        float2 full = (float2(gid) + 0.5f) * float2(float(p.fullW) / float(p.cw), float(p.fullH) / float(p.ch));
        uint tx = min(uint(full.x) / uint(p.tile), uint(p.tilesX - 1)), ty = min(uint(full.y) / uint(p.tile), uint(p.tilesY - 1));
        uint t = ty * uint(p.tilesX) + tx;
        float k = p.t / max(1.0f - p.t, 1e-3f);
        float err = length(f0 + k * f1) / (1.0f + length(f0) + k * length(f1));
        bool occ = m < 0.15f || m > 0.85f;
        device atomic_float* o = out + t * 8;
        atomic_fetch_add_explicit(&o[0], m, memory_order_relaxed);
        atomic_fetch_add_explicit(&o[1], occ ? 1.0f : 0.0f, memory_order_relaxed);
        atomic_fetch_add_explicit(&o[2], length(f0) * sx, memory_order_relaxed);
        atomic_fetch_add_explicit(&o[3], length(f1) * sx, memory_order_relaxed);
        atomic_fetch_add_explicit(&o[4], err, memory_order_relaxed);
        atomic_fetch_add_explicit(&o[5], err > 0.35f ? 1.0f : 0.0f, memory_order_relaxed);
        atomic_fetch_add_explicit(&o[6], 1.0f, memory_order_relaxed);
        atomic_fetch_add_explicit(&o[7], (!occ && err > 0.35f) ? 1.0f : 0.0f, memory_order_relaxed);
        atomic_fetch_max_explicit(&omax[t], as_type<uint>(max(length(f0), length(f1)) * sx), memory_order_relaxed);
    }

    kernel void flipH(texture2d<float, access::read>  src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      uint2 gid                           [[thread_position_in_grid]]) {
        uint W = dst.get_width(), H = dst.get_height();
        if (gid.x >= W || gid.y >= H) return;
        dst.write(src.read(uint2(W - 1 - gid.x, gid.y)), gid);
    }

    // PQ BT.2020 R'G'B' -> 10-bit limited-range Y'CbCr (BT.2020 NCL, 4:4:4) -> R'G'B': what a 10-bit HDR10 file holds.
    kernel void quant10(texture2d<float, access::read>  src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        uint2 gid                           [[thread_position_in_grid]]) {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float3 c = clamp(src.read(gid).rgb, 0.0f, 1.0f);
        const float kr = 0.2627f, kb = 0.0593f, kg = 1.0f - kr - kb;
        float y = kr * c.r + kg * c.g + kb * c.b;
        float cb = (c.b - y) / (2.0f * (1.0f - kb)), cr = (c.r - y) / (2.0f * (1.0f - kr));
        float yq = clamp(round(64.0f + 876.0f * y), 4.0f, 1019.0f);
        float cbq = clamp(round(512.0f + 896.0f * cb), 4.0f, 1019.0f), crq = clamp(round(512.0f + 896.0f * cr), 4.0f, 1019.0f);
        y = (yq - 64.0f) / 876.0f; cb = (cbq - 512.0f) / 896.0f; cr = (crq - 512.0f) / 896.0f;
        float r = y + 2.0f * (1.0f - kr) * cr, b = y + 2.0f * (1.0f - kb) * cb;
        float g = (y - kr * r - kb * b) / kg;
        dst.write(float4(r, g, b, 1.0f), gid);
    }
    """
}

/// Thin wrapper around the app's Metal context plus the benchmark kernels.
final class BenchGPU {
    static let shared = BenchGPU()
    let ctx = MetalContext.shared
    private var psos: [String: MTLComputePipelineState] = [:]

    private init() {
        let lib = try! ctx.device.makeLibrary(source: QCBenchKernels.source, options: nil)
        for n in ["nv12ToRGB", "boxDown", "hist64", "blockMatch", "tileErr", "tileFeat", "flowStats", "flipH", "quant10"] {
            psos[n] = try! ctx.device.makeComputePipelineState(function: lib.makeFunction(name: n)!)
        }
    }

    func dispatch(_ cb: MTLCommandBuffer, _ name: String, w: Int, h: Int, _ setup: (MTLComputeCommandEncoder) -> Void) {
        let enc = cb.makeComputeCommandEncoder()!
        setup(enc)
        ctx.dispatch2D(enc, psos[name]!, width: w, height: h)
        enc.endEncoding()
    }

    func run(_ body: (MTLCommandBuffer) -> Void) {
        let cb = ctx.queue.makeCommandBuffer()!
        body(cb)
        cb.commit()
        cb.waitUntilCompleted()
    }

    func zeroed(_ bytes: Int) -> MTLBuffer {
        let b = ctx.device.makeBuffer(length: max(16, bytes), options: .storageModeShared)!
        memset(b.contents(), 0, b.length)
        return b
    }

    func texture(_ w: Int, _ h: Int, _ f: MTLPixelFormat = .rgba16Float) -> MTLTexture { ctx.makeTexture(width: w, height: h, format: f) }

    func like(_ t: MTLTexture) -> MTLTexture { texture(t.width, t.height, t.pixelFormat) }

    func flip(_ t: MTLTexture) -> MTLTexture {
        let o = like(t)
        run { cb in dispatch(cb, "flipH", w: t.width, h: t.height) { $0.setTexture(t, index: 0); $0.setTexture(o, index: 1) } }
        return o
    }

    func quant10(_ t: MTLTexture) -> MTLTexture {
        let o = like(t)
        run { cb in dispatch(cb, "quant10", w: t.width, h: t.height) { $0.setTexture(t, index: 0); $0.setTexture(o, index: 1) } }
        return o
    }

    func blend(_ a: MTLTexture, _ b: MTLTexture, t: Float) -> MTLTexture {
        let o = like(a)
        BlendInterpolator().encode(nil, a, b, t: t, into: o)
        return o
    }

    func copy(_ t: MTLTexture) -> MTLTexture {
        let o = like(t)
        run { cb in let bl = cb.makeBlitCommandEncoder()!; bl.copy(from: t, to: o); bl.endEncoding() }
        return o
    }
}

/// A frame's 64-px tile grid (same indexing as interpQCKernel: tile = pixel / 64, clamped).
struct TileGrid: Hashable, Codable {
    var width: Int, height: Int, tile: Int = QCBench.tile
    var tilesX: Int { (width + tile - 1) / tile }
    var tilesY: Int { (height + tile - 1) / tile }
    var count: Int { tilesX * tilesY }
    init(_ t: MTLTexture) { width = t.width; height = t.height }
    init(width: Int, height: Int) { self.width = width; self.height = height }
    /// Pixels interpQCKernel samples (even coordinates) inside tile i.
    func sampledPixels(_ i: Int) -> Int {
        let x0 = (i % tilesX) * tile, y0 = (i / tilesX) * tile
        let w = min(tile, width - x0), h = min(tile, height - y0)
        return ((w + 1) / 2) * ((h + 1) / 2)
    }
}

/// True error of one picture against another, per tile.
struct TileErr {
    var sse: [Float], ssimSum: [Float], ssimN: [Float], px: [Float]
    var mse: Double {
        let s = sse.reduce(0.0) { $0 + Double($1) }, n = px.reduce(0.0) { $0 + Double($1) }
        return s / max(1, 3 * n)
    }
    var psnr: Double { Self.psnr(mse) }
    var ssim: Double {
        let n = ssimN.reduce(0.0) { $0 + Double($1) }
        return n > 0 ? ssimSum.reduce(0.0) { $0 + Double($1) } / n : 1
    }
    func tilePSNR(_ i: Int) -> Double { Self.psnr(Double(sse[i]) / max(1, 3 * Double(px[i]))) }
    func tileSSIM(_ i: Int) -> Double { ssimN[i] > 0 ? Double(ssimSum[i] / ssimN[i]) : 1 }
    static func psnr(_ mse: Double) -> Double { mse <= 1e-10 ? 100 : min(100, 10 * log10(1 / mse)) }
}

extension BenchGPU {
    /// Tile errors for several (picture, reference) pairs in one command buffer.
    func tileErrors(_ pairs: [(MTLTexture, MTLTexture)]) -> [TileErr] {
        guard let first = pairs.first?.0 else { return [] }
        let g = TileGrid(first)
        var tp = SIMD4<Int32>(Int32(g.tile), Int32(g.tilesX), Int32(g.tilesY), 0)
        let bufs = pairs.map { _ in zeroed(g.count * 16) }
        run { cb in
            for (k, (a, b)) in pairs.enumerated() {
                dispatch(cb, "tileErr", w: (a.width + 7) / 8, h: (a.height + 7) / 8) { e in
                    e.setTexture(a, index: 0); e.setTexture(b, index: 1)
                    e.setBuffer(bufs[k], offset: 0, index: 0)
                    e.setBytes(&tp, length: 16, index: 1)
                }
            }
        }
        return bufs.map { b in
            let p = b.contents().bindMemory(to: Float.self, capacity: g.count * 4)
            var e = TileErr(sse: [], ssimSum: [], ssimN: [], px: [])
            for i in 0..<g.count { e.sse.append(p[i * 4]); e.ssimSum.append(p[i * 4 + 1]); e.ssimN.append(p[i * 4 + 2]); e.px.append(p[i * 4 + 3]) }
            return e
        }
    }

    /// interpQCKernel's raw per-tile counts of "structure in neither neighbor" pixels at a given threshold.
    func qcCounts(a: MTLTexture, b: MTLTexture, mid: MTLTexture, threshold: Float, smooth: Bool) -> [Float] {
        let g = TileGrid(mid)
        let buf = zeroed(g.count * 4)
        var q = InterpQCUniforms(tileSize: Int32(g.tile), threshold: threshold, tilesX: Int32(g.tilesX), tilesY: Int32(g.tilesY),
                                 smooth: smooth ? 1 : 0, pad0: 0, pad1: 0, pad2: 0)
        run { cb in
            let enc = cb.makeComputeCommandEncoder()!
            enc.setTexture(a, index: 0); enc.setTexture(b, index: 1); enc.setTexture(mid, index: 2)
            enc.setBytes(&q, length: MemoryLayout<InterpQCUniforms>.stride, index: 0)
            enc.setBuffer(buf, offset: 0, index: 1)
            ctx.dispatch2D(enc, ctx.pipeline("interpQCKernel"), width: mid.width, height: mid.height)
            enc.endEncoding()
        }
        let p = buf.contents().bindMemory(to: UInt32.self, capacity: g.count)
        return (0..<g.count).map { Float(p[$0]) }
    }

    /// 12 feature sums and 2 maxima per tile (see tileFeat), normalized to means where they are sums.
    func tileFeatures(a: MTLTexture, b: MTLTexture, primary: MTLTexture, alt: MTLTexture, primaryFlip: MTLTexture,
                      altFlip: MTLTexture, blend: MTLTexture) -> [[Float]] {
        let g = TileGrid(primary)
        let out = zeroed(g.count * 12 * 4), omax = zeroed(g.count * 2 * 4)
        var tp = SIMD4<Int32>(Int32(g.tile), Int32(g.tilesX), Int32(g.tilesY), 0)
        run { cb in
            dispatch(cb, "tileFeat", w: (primary.width + 1) / 2, h: (primary.height + 1) / 2) { e in
                for (i, t) in [a, b, primary, alt, primaryFlip, altFlip, blend].enumerated() { e.setTexture(t, index: i) }
                e.setBuffer(out, offset: 0, index: 0); e.setBuffer(omax, offset: 0, index: 1)
                e.setBytes(&tp, length: 16, index: 2)
            }
        }
        let p = out.contents().bindMemory(to: Float.self, capacity: g.count * 12)
        let m = omax.contents().bindMemory(to: Float.self, capacity: g.count * 2)
        return (0..<g.count).map { i in
            let n = max(1, p[i * 12 + 9])
            var f = (0..<12).map { k in k == 9 ? p[i * 12 + 9] : p[i * 12 + k] / n }
            f.append(m[i * 2]); f.append(m[i * 2 + 1])
            return f
        }
    }

    /// Flow-model statistics from the engine's last prediction (call right after a single-time interpolate()).
    func flowStats(_ e: CoreMLInterpolator, t: Float, full: TileGrid) -> [[Float]] {
        guard let flow = e.bufFlow, let mask = e.bufMask else { return [] }
        let d = e.dims
        let out = zeroed(full.count * 8 * 4), omax = zeroed(full.count * 4)
        var p: [Int32] = [Int32(d.tw), Int32(d.th), Int32(d.cw), Int32(d.ch), 0, Int32(full.width), Int32(full.height),
                          Int32(full.tile), Int32(full.tilesX), Int32(full.tilesY), 0, 0]
        p[4] = Int32(bitPattern: t.bitPattern)
        run { cb in
            dispatch(cb, "flowStats", w: d.cw, h: d.ch) { enc in
                enc.setBuffer(flow, offset: 0, index: 0); enc.setBuffer(mask, offset: 0, index: 1)
                enc.setBuffer(out, offset: 0, index: 2); enc.setBuffer(omax, offset: 0, index: 3)
                enc.setBytes(&p, length: p.count * 4, index: 4)
            }
        }
        let o = out.contents().bindMemory(to: Float.self, capacity: full.count * 8)
        let m = omax.contents().bindMemory(to: Float.self, capacity: full.count)
        var tileCounts: [Float] = []
        if let tb = e.tileBuffer, tb.length >= full.count * 4 {
            let c = tb.contents().bindMemory(to: UInt32.self, capacity: full.count)
            tileCounts = (0..<full.count).map { Float(c[$0]) }
        }
        return (0..<full.count).map { i in
            let n = max(1, o[i * 8 + 6])
            // [engine gated count, mask mean, occlusion share, |f0| mean px, |f1| mean px, err mean, err>0.35 share,
            //  non-occluded err>0.35 share, model px, max |flow| px]
            return [tileCounts.isEmpty ? 0 : tileCounts[i], o[i * 8] / n, o[i * 8 + 1] / n, o[i * 8 + 2] / n, o[i * 8 + 3] / n,
                    o[i * 8 + 4] / n, o[i * 8 + 5] / n, o[i * 8 + 7] / n, o[i * 8 + 6], m[i]]
        }
    }
}
