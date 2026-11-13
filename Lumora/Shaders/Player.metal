// Lumora's built-in player: one compute pass from decoded Y'CbCr straight to the EDR drawable.
//
// Per output pixel:
//   fetch Y' and Cb/Cr (bilinear, chroma at its real siting) -> code values at the true bit depth
//   -> range (limited / full) -> matrix (BT.709 / BT.2020 NCL / BT.601 / YCgCo / GBR) -> transfer to nits
//   (PQ, HLG with the BT.2100 system gamma, BT.1886, sRGB) -> source primaries to linear BT.2020
//   -> BT.2390 EETF toward the display's current headroom (or clip at the content peak) -> EDR value.
//
// The frame's storage is a function constant, so each layout gets its own specialized pipeline.

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "ColorMath.h"
using namespace metal;

constant int kPlayerLayout [[function_constant(0)]];
constant int kPlayerSampleBytes [[function_constant(1)]];

inline float containerMax() { return kPlayerSampleBytes == 1 ? 255.0f : 65535.0f; }

// Raw container value of the luma sample at integer coordinates (clamped to the plane).
inline float lumaRaw(int2 p, texture2d<float, access::read> yTex, device const uchar* buf, constant PlayerUniforms& u) {
    p = clamp(p, int2(0), int2(int(u.lumaSize.x) - 1, int(u.lumaSize.y) - 1));
    if (kPlayerLayout == PLAYER_LAYOUT_BIPLANAR_TEXTURE) {
        return rint(yTex.read(uint2(p)).r * containerMax());
    }
    device const uchar* row = buf + u.offsets.x + uint(p.y) * u.strides.x;
    return kPlayerSampleBytes == 1 ? float(row[p.x]) : float(((device const ushort*)row)[p.x]);
}

// Raw container values (Cb, Cr) of the chroma sample at integer chroma-plane coordinates.
inline float2 chromaRaw(int2 p, texture2d<float, access::read> cTex, device const uchar* buf, constant PlayerUniforms& u) {
    if (u.chroma.x < 1.0f) {        // monochrome: neutral chroma
        float mid = float(1 << (u.bits - 1)) * (u.msbAligned ? float(1 << (u.containerBits - u.bits)) : 1.0f);
        return float2(mid);
    }
    p = clamp(p, int2(0), int2(int(u.chroma.x) - 1, int(u.chroma.y) - 1));
    if (kPlayerLayout == PLAYER_LAYOUT_BIPLANAR_TEXTURE) {
        return rint(cTex.read(uint2(p)).rg * containerMax());
    }
    if (kPlayerLayout == PLAYER_LAYOUT_SEMIPLANAR_BUFFER) {
        device const uchar* row = buf + u.offsets.y + uint(p.y) * u.strides.y;
        if (kPlayerSampleBytes == 1) return float2(row[2 * p.x], row[2 * p.x + 1]);
        device const ushort* r16 = (device const ushort*)row;
        return float2(r16[2 * p.x], r16[2 * p.x + 1]);
    }
    device const uchar* rb = buf + u.offsets.y + uint(p.y) * u.strides.y;
    device const uchar* rr = buf + u.offsets.z + uint(p.y) * u.strides.z;
    if (kPlayerSampleBytes == 1) return float2(rb[p.x], rr[p.x]);
    return float2(((device const ushort*)rb)[p.x], ((device const ushort*)rr)[p.x]);
}

// Bilinear fetch at a continuous plane coordinate where texel k is centered at k + 0.5. When the coordinate sits
// exactly on a texel center the weights are 0 and the stored value comes back unchanged.
inline float lumaAt(float2 c, texture2d<float, access::read> yTex, device const uchar* buf, constant PlayerUniforms& u) {
    float2 t = c - 0.5f;
    float2 i0 = floor(t);
    float2 f = t - i0;
    int2 i = int2(i0);
    float a = lumaRaw(i, yTex, buf, u);
    if (f.x == 0.0f && f.y == 0.0f) return a;
    float b = lumaRaw(i + int2(1, 0), yTex, buf, u);
    float c0 = lumaRaw(i + int2(0, 1), yTex, buf, u);
    float d = lumaRaw(i + int2(1, 1), yTex, buf, u);
    return mix(mix(a, b, f.x), mix(c0, d, f.x), f.y);
}

inline float2 chromaAt(float2 c, texture2d<float, access::read> cTex, device const uchar* buf, constant PlayerUniforms& u) {
    float2 t = c - 0.5f;
    float2 i0 = floor(t);
    float2 f = t - i0;
    int2 i = int2(i0);
    float2 a = chromaRaw(i, cTex, buf, u);
    if (f.x == 0.0f && f.y == 0.0f) return a;
    float2 b = chromaRaw(i + int2(1, 0), cTex, buf, u);
    float2 c0 = chromaRaw(i + int2(0, 1), cTex, buf, u);
    float2 d = chromaRaw(i + int2(1, 1), cTex, buf, u);
    return mix(mix(a, b, f.x), mix(c0, d, f.x), f.y);
}

// BT.2390 EETF on a luminance in nits; the PQ-domain constants are computed once on the CPU.
inline float eetfNits(float nits, constant PlayerUniforms& u) {
    float span = u.eetfLw - u.eetfLb;
    float e1 = clamp((nitsToPQPrecise(nits) - u.eetfLb) / span, 0.0f, 1.0f);
    float e2 = e1;
    if (e1 >= u.eetfKS) {
        float t = (e1 - u.eetfKS) / (1.0f - u.eetfKS);
        float t2 = t * t, t3 = t2 * t;
        e2 = (2.0f * t3 - 3.0f * t2 + 1.0f) * u.eetfKS + (t3 - 2.0f * t2 + t) * (1.0f - u.eetfKS)
           + (-2.0f * t3 + 3.0f * t2) * u.eetfMaxLum;
    }
    float k = 1.0f - e2;
    float e3 = e2 + u.eetfMinLum * (k * k) * (k * k);
    return pqToNitsPrecise(e3 * span + u.eetfLb);
}

inline float sdrDecode(float v, int tf) {
    v = max(v, 0.0f);
    switch (tf) {
        case PLAYER_TF_SRGB:    return (v <= 0.04045f) ? v / 12.92f : precise::pow((v + 0.055f) / 1.055f, 2.4f);
        case PLAYER_TF_LINEAR:  return v;
        case PLAYER_TF_GAMMA22: return precise::pow(v, 2.2f);
        case PLAYER_TF_GAMMA28: return precise::pow(v, 2.8f);
        default:                return precise::pow(v, 2.4f);
    }
}

kernel void playerKernel(texture2d<float, access::read>  yTex   [[texture(0)]],
                         texture2d<float, access::read>  cTex   [[texture(1)]],
                         texture2d<float, access::write> out    [[texture(2)]],
                         device const uchar*             buf    [[buffer(0)]],
                         constant PlayerUniforms&        u      [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 pix = float2(gid) + 0.5f;
    if (pix.x < u.viewport.x || pix.y < u.viewport.y ||
        pix.x >= u.viewport.x + u.viewport.z || pix.y >= u.viewport.y + u.viewport.w) {
        out.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }
    // Luma-plane coordinate of this output pixel; lumaSize.zw is the scale, exactly 1 for a 1:1 view.
    float2 p = (pix - u.viewport.xy) * u.lumaSize.zw;
    float2 cpos = p * u.chroma.zw + u.chromaOffset.xy;

    float shift = u.msbAligned ? float(1 << (u.containerBits - u.bits)) : 1.0f;
    float yCode = lumaAt(p, yTex, buf, u) / shift;
    float2 cCode = chromaAt(cpos, cTex, buf, u) / shift;

    if (u.outputMode == PLAYER_OUT_CODES) {
        out.write(float4(yCode, cCode.x, cCode.y, 1.0f), gid);
        return;
    }

    // Range: code values to normalized Y' (0…1) and C (−0.5…0.5), in float.
    float s = exp2(float(u.bits - 8));
    float maxCode = exp2(float(u.bits)) - 1.0f;
    float3 rgbPrime;
    if (u.matrixMode == PLAYER_MATRIX_GBR) {
        // Every GBR plane uses the luma range formula; Y holds G, Cb holds B, Cr holds R.
        float3 gbr = u.fullRange != 0 ? float3(yCode, cCode) / maxCode : (float3(yCode, cCode) - 16.0f * s) / (219.0f * s);
        rgbPrime = float3(gbr.z, gbr.x, gbr.y);
    } else {
        float Y, Cb, Cr;
        if (u.fullRange != 0) {
            Y = yCode / maxCode;
            Cb = (cCode.x - exp2(float(u.bits - 1))) / maxCode;
            Cr = (cCode.y - exp2(float(u.bits - 1))) / maxCode;
        } else {
            Y = (yCode - 16.0f * s) / (219.0f * s);
            Cb = (cCode.x - 128.0f * s) / (224.0f * s);
            Cr = (cCode.y - 128.0f * s) / (224.0f * s);
        }
        rgbPrime = u.yuvToRgb * float3(Y, Cb, Cr);
    }

    // Transfer: non-linear signal to absolute linear light (nits), source primaries.
    float3 nits;
    float3 sceneHLG = float3(0.0f);
    if (u.transfer == PLAYER_TF_PQ) {
        float3 e = clamp(rgbPrime, 0.0f, 1.0f);
        nits = float3(pqToNitsPrecise(e.r), pqToNitsPrecise(e.g), pqToNitsPrecise(e.b));
    } else if (u.transfer == PLAYER_TF_HLG) {
        float3 e = clamp(rgbPrime, 0.0f, 1.0f);
        sceneHLG = float3(hlgInverseOETF(e.r), hlgInverseOETF(e.g), hlgInverseOETF(e.b));
        float ys = dot(u.luma.xyz, sceneHLG);
        // BT.2100 OOTF: Fd = Lw · Ys^(γ−1) · E (display black 0).
        nits = ys > 0.0f ? u.hlgLw * precise::pow(ys, u.hlgGamma - 1.0f) * sceneHLG : float3(0.0f);
    } else {
        nits = float3(sdrDecode(rgbPrime.r, u.transfer), sdrDecode(rgbPrime.g, u.transfer),
                      sdrDecode(rgbPrime.b, u.transfer)) * u.refWhite;
    }

    if (u.outputMode == PLAYER_OUT_HLG && u.transfer == PLAYER_TF_HLG) {
        float3 e2020 = u.toBT2020 * sceneHLG;
        out.write(float4(hlgOETF(e2020.r), hlgOETF(e2020.g), hlgOETF(e2020.b), 1.0f), gid);
        return;
    }

    float3 lin = u.toBT2020 * nits;
    if (min3(lin.r, lin.g, lin.b) < 0.0f) lin = softGamut(lin, kLuma2020);

    if (u.outputMode == PLAYER_OUT_PQ) {
        out.write(float4(nitsToPQPrecise(lin.r), nitsToPQPrecise(lin.g), nitsToPQPrecise(lin.b), 1.0f), gid);
        return;
    }

    if (u.toneMap != 0) {
        // Hue-preserving: map the largest component and scale the pixel by the same ratio.
        float m = max3(lin.r, lin.g, lin.b);
        if (m > 0.0f) lin *= eetfNits(m, u) / m;
    } else {
        lin = min(lin, float3(u.srcPeak));
    }
    out.write(float4(lin / u.refWhite, 1.0f), gid);
}
