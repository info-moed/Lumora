// Lumora grading engine.
// One code path renders the preview, the analysis passes and the export, so what you see is what you encode.
//
// Pipeline per pixel:
//   encoded camera signal -> scene-linear (camera log / SDR / HDR decode)
//   -> source gamut to linear BT.2020 working space -> white balance + exposure
//   -> edge-aware local contrast ("punch", guided filter) -> HDR/SDR tone curve with hue-preserving norm
//   -> optional reference-match curve (fitted to an official UHD grade)
//   -> highlight desaturation -> Oklab vibrance/saturation with skin protection
//   -> output gamut + soft gamut compression -> PQ / HLG / BT.1886 encode -> TPDF dither

#include <metal_stdlib>
#include "ShaderTypes.h"
using namespace metal;

constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

constant float3 kLuma2020 = float3(0.2627f, 0.6780f, 0.0593f);

// Oklab (Björn Ottosson), defined from CIE XYZ D65. Matrices given as columns.
constant float3x3 kXYZtoLMS = float3x3(float3( 0.8189330101f,  0.0329845436f,  0.0482003018f),
                                       float3( 0.3618667424f,  0.9293118715f,  0.2643662691f),
                                       float3(-0.1288597137f,  0.0361456387f,  0.6338517070f));
constant float3x3 kLMStoLab = float3x3(float3( 0.2104542553f,  1.9779984951f,  0.0259040371f),
                                       float3( 0.7936177850f, -2.4285922050f,  0.7827717662f),
                                       float3(-0.0040720468f,  0.4505937099f, -0.8086757660f));
constant float3x3 kLabToLMS = float3x3(float3( 1.0f,           1.0f,           1.0f),
                                       float3( 0.3963377774f, -0.1055613458f, -0.0894841775f),
                                       float3( 0.2158037573f, -0.0638541728f, -1.2914855480f));
constant float3x3 kLMStoXYZ = float3x3(float3( 1.2270138511f, -0.0405801784f, -0.0763812845f),
                                       float3(-0.5577999807f,  1.1122568696f, -0.4214819784f),
                                       float3( 0.2812561490f, -0.0716766787f,  1.5861632204f));

// max3/min3 come from the Metal standard library (metal_math).

// Interleaved gradient noise (Jimenez): cheap, well-distributed, no texture needed.
inline float ign(float2 p, int seed) {
    p += float2(float(seed % 64) * 5.588238f, float((seed / 64) % 64) * 5.588238f);
    return fract(52.9829189f * fract(dot(p, float2(0.06711056f, 0.00583715f))));
}

inline float2 srcUV(float2 uv, constant GradeUniforms& u) { return u.sourceRect.xy + uv * u.sourceRect.zw; }

// Reference-match correction (stops) for a given output luminance, linearly interpolated.
inline float matchCorrection(float nits, constant GradeUniforms& u) {
    if (u.matchCurveSize < 2) return 0.0f;
    float x = (log2(max(nits, 0.01f)) - MATCH_LOG_MIN) / (MATCH_LOG_MAX - MATCH_LOG_MIN) * float(u.matchCurveSize - 1);
    x = clamp(x, 0.0f, float(u.matchCurveSize - 1));
    int i = min(int(x), u.matchCurveSize - 2);
    return mix(u.matchCurve[i], u.matchCurve[i + 1], x - float(i));
}
inline float3 cbrtSigned(float3 v) { return sign(v) * pow(abs(v), 1.0f / 3.0f); }
inline float3 xyzToOklab(float3 xyz) { return kLMStoLab * cbrtSigned(kXYZtoLMS * xyz); }
inline float3 oklabToXYZ(float3 lab) { float3 l = kLabToLMS * lab; return kLMStoXYZ * (l * l * l); }

// ------------------------------------------------------------------------------------------
// Transfer functions
// ------------------------------------------------------------------------------------------

// Apple Log (Apple Log Profile White Paper, 2023). Apple Log 2 uses the same curve with Apple Wide Gamut primaries.
inline float appleLogToLinear(float p) {
    const float R0 = -0.05641088f, Rt = 0.01f, sigma = 47.28711236f;
    const float beta = 0.00964052f, gamma = 0.08550479f, delta = 0.69336945f;
    const float Pt = sigma * (Rt - R0) * (Rt - R0);
    if (p >= Pt)   return exp2((p - delta) / gamma) - beta;
    if (p >= 0.0f) return sqrt(p / sigma) + R0;
    return R0;
}

// Sony S-Log3
inline float slog3ToLinear(float x) {
    const float cut = 171.2102946929f / 1023.0f;
    float c = x * 1023.0f;
    return (x >= cut) ? pow(10.0f, (c - 420.0f) / 261.5f) * 0.19f - 0.01f
                      : (c - 95.0f) * 0.01125f / (171.2102946929f - 95.0f);
}

// ARRI LogC3 (EI 800)
inline float logc3ToLinear(float t) {
    const float cut = 0.010591f, a = 5.555556f, b = 0.052272f, c = 0.247190f;
    const float d = 0.385537f, e = 5.367655f, f = 0.092809f;
    return (t > e * cut + f) ? (pow(10.0f, (t - d) / c) - b) / a : (t - f) / e;
}

// ARRI LogC4
inline float logc4ToLinear(float x) {
    const float a = (262144.0f - 16.0f) / 117.45f;
    const float b = (1023.0f - 95.0f) / 1023.0f;
    const float c = 95.0f / 1023.0f;
    const float s = (7.0f * M_LN2_F * exp2(7.0f - 14.0f * c / b)) / (a * b);
    const float t = (exp2(14.0f * (-c / b) + 6.0f) - 64.0f) / a;
    return (x >= 0.0f) ? (exp2(14.0f * (x - c) / b + 6.0f) - 64.0f) / a : x * s + t;
}

// Panasonic V-Log
inline float vlogToLinear(float x) {
    const float cut2 = 0.181f, b = 0.00873f, c = 0.241514f, d = 0.598206f;
    return (x < cut2) ? (x - 0.125f) / 5.6f : pow(10.0f, (x - d) / c) - b;
}

// SMPTE ST 2084 (PQ)
constant float PQ_M1 = 0.1593017578125f, PQ_M2 = 78.84375f;
constant float PQ_C1 = 0.8359375f, PQ_C2 = 18.8515625f, PQ_C3 = 18.6875f;
inline float pqToNits(float v) {
    float p = pow(max(v, 0.0f), 1.0f / PQ_M2);
    return 10000.0f * pow(max(p - PQ_C1, 0.0f) / (PQ_C2 - PQ_C3 * p), 1.0f / PQ_M1);
}
inline float nitsToPQ(float n) {
    float y = pow(clamp(n / 10000.0f, 0.0f, 1.0f), PQ_M1);
    return pow((PQ_C1 + PQ_C2 * y) / (1.0f + PQ_C3 * y), PQ_M2);
}

// ITU-R BT.2100 HLG
constant float HLG_A = 0.17883277f, HLG_B = 0.28466892f, HLG_C = 0.55991073f;
inline float hlgInverseOETF(float v) {
    return (v <= 0.5f) ? v * v / 3.0f : (exp((v - HLG_C) / HLG_A) + HLG_B) / 12.0f;
}
inline float hlgOETF(float e) {
    e = max(e, 0.0f);
    return (e <= 1.0f / 12.0f) ? sqrt(3.0f * e) : HLG_A * log(12.0f * e - HLG_B) + HLG_C;
}

inline float decodeChannel(float v, int tf) {
    switch (tf) {
        case TF_APPLE_LOG: return appleLogToLinear(v);
        case TF_SLOG3:     return slog3ToLinear(v);
        case TF_LOGC3:     return logc3ToLinear(v);
        case TF_LOGC4:     return logc4ToLinear(v);
        case TF_VLOG:      return vlogToLinear(v);
        case TF_BT1886:    return pow(max(v, 0.0f), 2.4f);
        case TF_SRGB:      return (v <= 0.04045f) ? v / 12.92f : pow((max(v, 0.0f) + 0.055f) / 1.055f, 2.4f);
        case TF_PQ:        return pqToNits(v) / 144.0f;     // ~26 nits -> 0.18
        case TF_HLG:       return hlgInverseOETF(v) * 3.75f; // HLG gray -> ~0.18
        default:           return v;
    }
}

inline float3 decodeToSceneLinear(float3 rgb, constant GradeUniforms& u) {
    if (u.legalToFull != 0) rgb = (rgb * 876.0f + 64.0f) / 1023.0f;
    float3 lin = float3(decodeChannel(rgb.r, u.inputTransfer),
                        decodeChannel(rgb.g, u.inputTransfer),
                        decodeChannel(rgb.b, u.inputTransfer));
    // Inverse tone mapping: rebuild highlight range above the knee. Used for SDR -> HDR, and to give
    // dim or conservative HDR masters (e.g. personal UHD rips) real highlight punch.
    if (u.highlightExpansion > 0.0f) {
        float m = max3(lin.r, lin.g, lin.b);
        float t = saturate((m - u.expansionKnee) / max(u.expansionCeiling - u.expansionKnee, 1e-3f));
        lin *= 1.0f + u.highlightExpansion * t * t;
    }
    return lin;
}

inline float3 toWorking(float3 encoded, constant GradeUniforms& u) {
    float3 w = u.inputToWorking * decodeToSceneLinear(encoded, u);
    return w * u.wbGain.rgb * u.exposure;
}

// ------------------------------------------------------------------------------------------
// Grading
// ------------------------------------------------------------------------------------------

inline float3 colorBoost(float3 rgbRel, constant GradeUniforms& u) {
    float3 lab = xyzToOklab(u.workingToXYZ * rgbRel);
    float C = length(lab.yz);
    if (C < 1e-5f) return rgbRel;
    float h = atan2(lab.z, lab.y);
    // Skin lives roughly between 25 and 75 degrees of Oklab hue at moderate chroma.
    float skinHue = smoothstep(0.35f, 0.55f, h) * (1.0f - smoothstep(1.15f, 1.40f, h));
    float skinChroma = smoothstep(0.015f, 0.04f, C) * (1.0f - smoothstep(0.16f, 0.22f, C));
    float skin = skinHue * skinChroma * u.skinProtect;
    float vib = 1.0f + u.vibrance * (1.0f - smoothstep(0.0f, 0.22f, C));
    float boost = u.saturation * vib;
    boost = mix(boost, 1.0f + (boost - 1.0f) * 0.25f, skin);
    return u.xyzToWorking * oklabToXYZ(float3(lab.x, lab.yz * boost));
}

// Luminance-preserving soft gamut compression: pull out-of-gamut colors toward neutral just enough.
inline float3 softGamut(float3 o, float3 luma) {
    float Y = dot(o, luma);
    if (Y <= 0.0f) return float3(0.0f);
    float m = min3(o.r, o.g, o.b);
    if (m >= 0.0f) return o;
    float t = Y / (Y - m);
    return Y + (o - Y) * t;
}

// Returns linear light in nits, output gamut.
// `guide` holds guided-filter coefficients (a, b): the edge-preserving base layer is a*I + b, so detail
// is enhanced without the halos a plain blur creates around high-contrast edges.
inline float3 gradeToNits(float3 w, float2 guide, constant GradeUniforms& u) {
    float Y = max(dot(w, kLuma2020), 1e-6f);
    float mx = max3(w.r, w.g, w.b);
    float norm = max(mix(Y, mx, 0.5f), 1e-6f);   // hue-preserving norm between luminance and max(RGB)
    float e = log2(norm / 0.18f);

    // Punch: add back local detail relative to the edge-aware base, with a soft clamp.
    float I = log2(Y / 0.18f);
    float d = clamp(I - (guide.x * I + guide.y), -2.5f, 2.5f);
    e += u.localContrast * d / (1.0f + 0.2f * d * d);

    // Tone curve: contrast around mid gray, generalized Reinhard shoulder to peak, toe for density.
    float L = u.midGreyNits * exp2(u.contrast * e);
    float n = max(u.shoulder, 0.5f);
    float outN = L / pow(1.0f + pow(L / u.peakNits, n), 1.0f / n);
    float toeN = u.toe * u.midGreyNits * 0.06f;
    outN = outN * outN / (outN + toeN + 1e-6f);
    outN = u.blackNits + outN * (1.0f - u.blackNits / u.peakNits);
    outN = min(outN * exp2(matchCorrection(outN, u)), u.peakNits);

    float3 rgbN = max(w, 0.0f) * (outN / norm);

    // Film-like highlight desaturation as values approach peak.
    float Yn = dot(rgbN, kLuma2020);
    float hd = smoothstep(0.5f * u.peakNits, u.peakNits, max3(rgbN.r, rgbN.g, rgbN.b)) * u.highlightDesat;
    rgbN = mix(rgbN, float3(Yn), hd);

    // Color work relative to diffuse white so the vibrance thresholds behave the same at any peak.
    float rel = u.midGreyNits / 0.18f;
    rgbN = colorBoost(rgbN / rel, u) * rel;

    float3 o = u.workingToOutput * rgbN;
    if (u.gamutCompress != 0) o = softGamut(o, u.outputLuma.rgb);
    return clamp(o, 0.0f, u.peakNits);
}

// "Keep original look": display light exactly as mastered (PQ as-is, HLG through its 1000-nit OOTF,
// SDR at BT.2408's 203-nit reference white inside HDR). Returns false when a real tone map is needed
// (camera log, or HDR going to SDR).
inline bool displayNits(float3 enc, constant GradeUniforms& u, thread float3& out) {
    float3 n;
    switch (u.inputTransfer) {
        case TF_PQ:
            if (u.outputTransfer == OUT_SDR) return false;
            n = float3(pqToNits(enc.r), pqToNits(enc.g), pqToNits(enc.b));
            break;
        case TF_HLG: {
            if (u.outputTransfer == OUT_SDR) return false;
            float3 s = float3(hlgInverseOETF(enc.r), hlgInverseOETF(enc.g), hlgInverseOETF(enc.b));
            n = 1000.0f * s * pow(max(dot(s, kLuma2020), 1e-6f), 0.2f);
            break;
        }
        case TF_BT1886: n = pow(saturate(enc), 2.4f) * (u.outputTransfer == OUT_SDR ? 100.0f : 203.0f); break;
        case TF_SRGB:   n = float3(decodeChannel(enc.r, TF_SRGB), decodeChannel(enc.g, TF_SRGB), decodeChannel(enc.b, TF_SRGB))
                            * (u.outputTransfer == OUT_SDR ? 100.0f : 203.0f); break;
        default: return false;
    }
    float3 o = u.workingToOutput * (u.inputToWorking * n);
    if (u.gamutCompress != 0) o = softGamut(o, u.outputLuma.rgb);
    // Soft knee above 75% of the target peak, so a 4000-nit master fits a 1000-nit target without hard clipping.
    // Only HDR masters can exceed the target: an SDR master to SDR is already in range and must stay untouched
    // (the knee used to dim everything above 75 nits of an SDR picture in "Keep original look").
    if (u.inputTransfer == TF_PQ || u.inputTransfer == TF_HLG) {
        float k = 0.75f * u.peakNits, r = u.peakNits - k;
        o = select(o, k + r * tanh((o - k) / r), o > k);
    }
    out = clamp(o, 0.0f, u.peakNits);
    return true;
}

/// Every pass (preview, export, scopes, metering, LUTs) gets its light from here.
inline float3 renderNits(float3 enc, float2 guide, constant GradeUniforms& u) {
    float3 n;
    if (u.passthrough != 0 && displayNits(enc, u, n)) return n;
    return gradeToNits(toWorking(enc, u), guide, u);
}

inline float3 encodeOutput(float3 nits, constant GradeUniforms& u) {
    switch (u.outputTransfer) {
        case OUT_PQ:
            return float3(nitsToPQ(nits.r), nitsToPQ(nits.g), nitsToPQ(nits.b));
        case OUT_HLG: {
            // BT.2100 HLG, 1000-nit nominal peak, system gamma 1.2: invert the OOTF, then OETF.
            float3 d = max(nits / 1000.0f, 0.0f);
            float Yd = max(dot(d, u.outputLuma.rgb), 1e-6f);
            float3 s = d * pow(Yd, 1.0f / 1.2f - 1.0f);
            return float3(hlgOETF(s.r), hlgOETF(s.g), hlgOETF(s.b));
        }
        default:
            return pow(saturate(nits / 100.0f), 1.0f / 2.4f);
    }
}

// Brightness bands for the false-colour preview (shown at a comfortable ~100 nits).
inline float3 falseColorNits(float nits, float peak) {
    float3 c;
    if (nits >= peak * 0.98f)  c = float3(1.0f, 1.0f, 1.0f);   // clipping
    else if (nits > 1000.0f)   c = float3(1.0f, 0.1f, 0.1f);   // above 1000
    else if (nits > 600.0f)    c = float3(1.0f, 0.5f, 0.0f);
    else if (nits > 203.0f)    c = float3(1.0f, 0.9f, 0.0f);   // above HDR reference white
    else if (nits > 50.0f)     c = float3(0.2f, 0.8f, 0.2f);
    else if (nits > 10.0f)     c = float3(0.5f, 0.5f, 0.5f);   // mid-tones / skin
    else if (nits > 1.0f)      c = float3(0.1f, 0.3f, 1.0f);
    else                       c = float3(0.4f, 0.0f, 0.6f);   // deep shadows
    return c * 100.0f;
}

inline float2 viewportUV(uint2 gid, constant GradeUniforms& u, thread bool& inside) {
    float2 p = float2(gid) + 0.5f - u.viewport.xy;
    inside = p.x >= 0.0f && p.y >= 0.0f && p.x < u.viewport.z && p.y < u.viewport.w;
    return p / u.viewport.zw;
}

// ------------------------------------------------------------------------------------------
// Kernels
// ------------------------------------------------------------------------------------------

// Guided-filter inputs at low resolution: (I, I^2) with I = log2(Y / 0.18). MPS blurs both.
kernel void logLumaKernel(texture2d<float, access::sample> src [[texture(0)]],
                          texture2d<float, access::write>  dst [[texture(1)]],
                          constant GradeUniforms& u        [[buffer(0)]],
                          uint2 gid                        [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5f) / float2(dst.get_width(), dst.get_height());
    float3 w = toWorking(src.sample(linearSampler, srcUV(uv, u)).rgb, u);
    float I = log2(max(dot(w, kLuma2020), 1e-6f) / 0.18f);
    dst.write(float4(I, I * I, 0.0f, 1.0f), gid);
}

// Guided-filter coefficients from blurred (mean I, mean I^2): a = var / (var + eps), b = mean - a * mean.
kernel void guidedCoeffKernel(texture2d<float, access::read>  moments [[texture(0)]],
                              texture2d<float, access::write> coeffs  [[texture(1)]],
                              constant GradeUniforms& u               [[buffer(0)]],
                              uint2 gid                               [[thread_position_in_grid]]) {
    if (gid.x >= coeffs.get_width() || gid.y >= coeffs.get_height()) return;
    float2 m = moments.read(gid).rg;
    float var = max(m.y - m.x * m.x, 0.0f);
    float a = var / (var + u.guidedEpsilon);
    coeffs.write(float4(a, m.x - a * m.x, 0.0f, 1.0f), gid);
}

// Flicker guard: within a shot, ease the punch coefficients toward the previous frame's.
kernel void temporalBlendKernel(texture2d<float, access::read>  previous [[texture(0)]],
                                texture2d<float, access::read>  current  [[texture(1)]],
                                texture2d<float, access::write> dst      [[texture(2)]],
                                constant float& keep                     [[buffer(0)]],
                                uint2 gid                                [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(mix(current.read(gid), previous.read(gid), keep), gid);
}

// Debanding: if a few nearby samples all sit within a tiny threshold of this pixel, the area is a smooth
// gradient that compression has stepped; replace it with their average (noise-varied positions).
inline float3 deband(texture2d<float, access::sample> src, float2 suv, float3 c, uint2 gid, constant GradeUniforms& u) {
    float2 px = 1.0f / float2(src.get_width(), src.get_height());
    float ang = ign(float2(gid), u.frameSeed) * 6.2831853f;
    float r = u.debandRadius * (0.5f + 0.5f * ign(float2(gid.yx), u.frameSeed + 17));
    float2 o = float2(cos(ang), sin(ang)) * r * px;
    float2 p = float2(-o.y, o.x);
    float3 s1 = src.sample(linearSampler, suv + o).rgb, s2 = src.sample(linearSampler, suv - o).rgb;
    float3 s3 = src.sample(linearSampler, suv + p).rgb, s4 = src.sample(linearSampler, suv - p).rgb;
    float3 dmax = max(max(abs(s1 - c), abs(s2 - c)), max(abs(s3 - c), abs(s4 - c)));
    return all(dmax < float3(u.debandThreshold)) ? (s1 + s2 + s3 + s4) * 0.25f : c;
}

// Full grade into an encoded RGB destination (preview drawable, ProRes RGB buffer, or packing source).
kernel void gradeKernel(texture2d<float, access::sample> src   [[texture(0)]],
                        texture2d<float, access::sample> guide [[texture(1)]],
                        texture2d<float, access::write>  dst   [[texture(2)]],
                        constant GradeUniforms& u              [[buffer(0)]],
                        uint2 gid                              [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    bool inside;
    float2 uv = viewportUV(gid, u, inside);
    if (!inside) { dst.write(float4(encodeOutput(float3(0.0f), u), 1.0f), gid); return; }

    float2 suv = srcUV(uv, u);
    float3 enc = src.sample(linearSampler, suv).rgb;
    if (u.debandThreshold > 0.0f) enc = deband(src, suv, enc, gid, u);
    float3 nits;
    if (u.split > 0.0f && abs(uv.x - u.split) < 1.0f / u.viewport.z) {
        nits = float3(160.0f);                                   // divider line
    } else if (u.split > 0.0f && uv.x < u.split) {
        nits = pow(saturate(enc), 2.4f) * 100.0f;                // ungraded signal, shown flat
    } else {
        nits = renderNits(enc, guide.sample(linearSampler, uv).rg, u);
        if (u.falseColor != 0) nits = falseColorNits(dot(nits, u.outputLuma.rgb), u.peakNits);
    }
    float3 out = encodeOutput(nits, u);
    if (u.ditherAmplitude > 0.0f) {
        // Triangular (TPDF) dither of one code value hides banding when quantizing to 10/12 bits.
        float n = ign(float2(gid), u.frameSeed) + ign(float2(gid) + 113.0f, u.frameSeed + 7) - 1.0f;
        out += n * u.ditherAmplitude;
    }
    dst.write(float4(out, 1.0f), gid);
}

inline float codeValue(float v, int bits) {
    return (bits == 10) ? round(clamp(v, 0.0f, 1023.0f)) * 64.0f / 65535.0f   // MSB-aligned in 16 bits
                        : round(clamp(v, 0.0f, 255.0f)) / 255.0f;
}

// Encoded RGB -> limited-range Y'CbCr 4:2:0 biplanar (x420 / 420v).
kernel void pack420Kernel(texture2d<float, access::read>  rgb    [[texture(0)]],
                          texture2d<float, access::write> luma   [[texture(1)]],
                          texture2d<float, access::write> chroma [[texture(2)]],
                          constant PackUniforms& p               [[buffer(0)]],
                          uint2 gid                              [[thread_position_in_grid]]) {
    if (gid.x >= chroma.get_width() || gid.y >= chroma.get_height()) return;
    float kg = 1.0f - p.kr - p.kb;
    float s = (p.bits == 10) ? 4.0f : 1.0f;
    float2 acc = float2(0.0f);
    for (uint dy = 0; dy < 2; dy++) {
        for (uint dx = 0; dx < 2; dx++) {
            uint2 q = gid * 2 + uint2(dx, dy);
            uint2 r = min(q, uint2(p.width - 1, p.height - 1));
            float3 v = saturate(rgb.read(r).rgb);
            float y = p.kr * v.r + kg * v.g + p.kb * v.b;
            acc += float2((v.b - y) / (2.0f * (1.0f - p.kb)), (v.r - y) / (2.0f * (1.0f - p.kr)));
            if (q.x < uint(p.width) && q.y < uint(p.height))
                luma.write(float4(codeValue((16.0f + 219.0f * y) * s, p.bits)), q);
        }
    }
    acc *= 0.25f;
    chroma.write(float4(codeValue((128.0f + 224.0f * acc.x) * s, p.bits),
                        codeValue((128.0f + 224.0f * acc.y) * s, p.bits), 0.0f, 0.0f), gid);
}

// Encoded RGB -> limited-range Y'CbCr 4:2:2 biplanar (x422), used for ProRes 422 HQ.
kernel void pack422Kernel(texture2d<float, access::read>  rgb    [[texture(0)]],
                          texture2d<float, access::write> luma   [[texture(1)]],
                          texture2d<float, access::write> chroma [[texture(2)]],
                          constant PackUniforms& p               [[buffer(0)]],
                          uint2 gid                              [[thread_position_in_grid]]) {
    if (gid.x >= chroma.get_width() || gid.y >= chroma.get_height()) return;
    float kg = 1.0f - p.kr - p.kb;
    float s = (p.bits == 10) ? 4.0f : 1.0f;
    float2 acc = float2(0.0f);
    for (uint dx = 0; dx < 2; dx++) {
        uint2 q = uint2(gid.x * 2 + dx, gid.y);
        uint2 r = min(q, uint2(p.width - 1, p.height - 1));
        float3 v = saturate(rgb.read(r).rgb);
        float y = p.kr * v.r + kg * v.g + p.kb * v.b;
        acc += float2((v.b - y) / (2.0f * (1.0f - p.kb)), (v.r - y) / (2.0f * (1.0f - p.kr)));
        if (q.x < uint(p.width)) luma.write(float4(codeValue((16.0f + 219.0f * y) * s, p.bits)), q);
    }
    acc *= 0.5f;
    chroma.write(float4(codeValue((128.0f + 224.0f * acc.x) * s, p.bits),
                        codeValue((128.0f + 224.0f * acc.y) * s, p.bits), 0.0f, 0.0f), gid);
}

// Per-frame statistics on a downsampled grid: log-luminance histogram, skin coverage, chroma.
kernel void analyzeKernel(texture2d<float, access::sample> src [[texture(0)]],
                          constant GradeUniforms& u        [[buffer(0)]],
                          device atomic_uint* hist         [[buffer(1)]],
                          device atomic_uint* stats        [[buffer(2)]],
                          constant uint2& grid             [[buffer(3)]],
                          device atomic_uint* thumb        [[buffer(4)]],
                          uint2 gid                        [[thread_position_in_grid]]) {
    if (gid.x >= grid.x || gid.y >= grid.y) return;
    float2 uv = (float2(gid) + 0.5f) / float2(grid);
    float3 enc = src.sample(linearSampler, srcUV(uv, u)).rgb;
    uint tx = min(uint(uv.x * THUMB_W), uint(THUMB_W - 1)), ty = min(uint(uv.y * THUMB_H), uint(THUMB_H - 1));
    atomic_fetch_add_explicit(&thumb[ty * THUMB_W + tx], uint(saturate(dot(enc, kLuma2020)) * 1000.0f), memory_order_relaxed);
    float3 w = toWorking(enc, u);
    float Y = max(dot(w, kLuma2020), 1e-7f);
    float stop = log2(Y / 0.18f);
    int bin = clamp(int((stop - HIST_LOW_STOP) / HIST_STOPS_PER_BIN), 0, HIST_BINS - 1);
    atomic_fetch_add_explicit(&hist[bin], 1u, memory_order_relaxed);

    float3 lab = xyzToOklab(u.workingToXYZ * (max(w, 0.0f) * (0.18f / Y)));   // chroma at fixed lightness
    float C = length(lab.yz);
    float h = atan2(lab.z, lab.y);
    bool skin = h > 0.4f && h < 1.3f && C > 0.02f && C < 0.18f && stop > -4.0f && stop < 3.0f;

    atomic_fetch_add_explicit(&stats[0], 1u, memory_order_relaxed);
    if (skin) atomic_fetch_add_explicit(&stats[1], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&stats[2], uint(min(C, 1.0f) * 1000.0f), memory_order_relaxed);
}

// Graded light levels for HDR10 MaxCLL / MaxFALL, measured with the exact export grade.
kernel void measureKernel(texture2d<float, access::sample> src   [[texture(0)]],
                          texture2d<float, access::sample> guide [[texture(1)]],
                          constant GradeUniforms& u             [[buffer(0)]],
                          device atomic_uint* stats             [[buffer(2)]],
                          constant uint2& grid                  [[buffer(3)]],
                          uint2 gid                             [[thread_position_in_grid]]) {
    if (gid.x >= grid.x || gid.y >= grid.y) return;
    float2 uv = (float2(gid) + 0.5f) / float2(grid);
    float3 nits = renderNits(src.sample(linearSampler, srcUV(uv, u)).rgb, guide.sample(linearSampler, uv).rg, u);
    float m = max3(nits.r, nits.g, nits.b);
    atomic_fetch_max_explicit(&stats[3], as_type<uint>(m), memory_order_relaxed);
    atomic_fetch_add_explicit(&stats[4], uint(m), memory_order_relaxed);
}

// ------------------------------------------------------------------------------------------
// 3D LUT baking: evaluate the global part of the grade on an N^3 lattice of source code values.
// Local contrast is spatial and cannot live in a LUT, so the guide is the identity (a = 1, b = 0): no detail.
// Output index order matches .cube files: red varies fastest, then green, then blue.
// ------------------------------------------------------------------------------------------
kernel void lutKernel(constant GradeUniforms& u [[buffer(0)]],
                      device float4* out        [[buffer(1)]],
                      constant uint& size       [[buffer(2)]],
                      uint3 gid                 [[thread_position_in_grid]]) {
    if (gid.x >= size || gid.y >= size || gid.z >= size) return;
    float3 enc = float3(gid) / float(size - 1);
    float3 nits = renderNits(enc, float2(1.0f, 0.0f), u);   // a=1, b=0: base == pixel, no detail
    out[gid.x + gid.y * size + gid.z * size * size] = float4(encodeOutput(nits, u), 1.0f);
}


// ------------------------------------------------------------------------------------------
// 10/12-bit planar packing for software encoders (y4m: yuv420p10/12, yuv422p10, yuv444p12).
// LSB-aligned little-endian 16-bit samples. One thread per chroma sample.
// ------------------------------------------------------------------------------------------
kernel void packPlanarKernel(texture2d<float, access::read> rgb [[texture(0)]],
                             constant PackUniforms& p          [[buffer(0)]],
                             device ushort* yPlane             [[buffer(1)]],
                             device ushort* cbPlane            [[buffer(2)]],
                             device ushort* crPlane            [[buffer(3)]],
                             uint2 gid                         [[thread_position_in_grid]]) {
    uint sx = (p.chroma == 2) ? 1 : 2;
    uint sy = (p.chroma == 0) ? 2 : 1;
    uint cw = uint(p.width) / sx, ch = uint(p.height) / sy;
    if (gid.x >= cw || gid.y >= ch) return;
    float kg = 1.0f - p.kr - p.kb;
    float scale = exp2(float(p.bits - 8));
    float maxCode = exp2(float(p.bits)) - 1.0f;
    float2 acc = float2(0.0f);
    for (uint dy = 0; dy < sy; dy++) {
        for (uint dx = 0; dx < sx; dx++) {
            uint2 q = uint2(gid.x * sx + dx, gid.y * sy + dy);
            float3 v = saturate(rgb.read(q).rgb);
            float y = p.kr * v.r + kg * v.g + p.kb * v.b;
            acc += float2((v.b - y) / (2.0f * (1.0f - p.kb)), (v.r - y) / (2.0f * (1.0f - p.kr)));
            yPlane[q.y * uint(p.width) + q.x] = ushort(clamp(round((16.0f + 219.0f * y) * scale), 0.0f, maxCode));
        }
    }
    acc /= float(sx * sy);
    uint ci = gid.y * cw + gid.x;
    cbPlane[ci] = ushort(clamp(round((128.0f + 224.0f * acc.x) * scale), 0.0f, maxCode));
    crPlane[ci] = ushort(clamp(round((128.0f + 224.0f * acc.y) * scale), 0.0f, maxCode));
}

// 16-bit 4:4:4 A Y' Cb Cr ("y416") for ProRes 4444 XQ: keeps full 12-bit precision into the hardware encoder.
kernel void packY416Kernel(texture2d<float, access::read>  rgb [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant PackUniforms& p            [[buffer(0)]],
                           uint2 gid                           [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float kg = 1.0f - p.kr - p.kb;
    float3 v = saturate(rgb.read(gid).rgb);
    float y = p.kr * v.r + kg * v.g + p.kb * v.b;
    float cb = (v.b - y) / (2.0f * (1.0f - p.kb));
    float cr = (v.r - y) / (2.0f * (1.0f - p.kr));
    dst.write(float4(1.0f, (16.0f + 219.0f * y) * 256.0f / 65535.0f,
                     (128.0f + 224.0f * cb) * 256.0f / 65535.0f,
                     (128.0f + 224.0f * cr) * 256.0f / 65535.0f), gid);
}

// ------------------------------------------------------------------------------------------
// Frame interpolation support. Models run on the camera/HDR *encoded* signal (log, PQ or HLG are all
// perceptually spaced 0..1), before grading, in fp16 tensors: no 8-bit round trip, HDR preserved.
// ------------------------------------------------------------------------------------------

// Texture -> planar NCHW half tensor. Supports tiles: reads start at (srcX, srcY) and clamp at the edges.
kernel void textureToTensorKernel(texture2d<float, access::sample> src [[texture(0)]],
                                  device half* tensor                  [[buffer(0)]],
                                  constant TensorUniforms& t           [[buffer(1)]],
                                  uint2 gid                            [[thread_position_in_grid]]) {
    if (gid.x >= uint(t.width) || gid.y >= uint(t.height)) return;
    int2 q = clamp(int2(gid) + int2(t.srcX, t.srcY), int2(0), int2(t.srcWidth - 1, t.srcHeight - 1));
    float2 uv = (float2(q) + 0.5f) / float2(t.srcWidth, t.srcHeight);
    float3 v = src.sample(linearSampler, uv).rgb;
    uint plane = uint(t.width * t.height);
    uint i = gid.y * uint(t.width) + gid.x;
    tensor[i] = half(v.r);
    tensor[plane + i] = half(v.g);
    tensor[2 * plane + i] = half(v.b);
}

// Tensor -> texture, writing only the tile's inner region (overlap discarded) at its output position.
kernel void tensorToTextureKernel(device const half* tensor           [[buffer(0)]],
                                  constant TensorUniforms& t          [[buffer(1)]],
                                  texture2d<float, access::write> dst [[texture(0)]],
                                  uint2 gid                           [[thread_position_in_grid]]) {
    if (int(gid.x) < t.innerX0 || int(gid.y) < t.innerY0 || int(gid.x) >= t.innerX1 || int(gid.y) >= t.innerY1) return;
    int2 o = int2(gid) + int2(t.outX, t.outY);
    if (o.x < 0 || o.y < 0 || o.x >= int(dst.get_width()) || o.y >= int(dst.get_height())) return;
    uint plane = uint(t.width * t.height);
    uint i = gid.y * uint(t.width) + gid.x;
    dst.write(float4(float(tensor[i]), float(tensor[plane + i]), float(tensor[2 * plane + i]), 1.0f), uint2(o));
}

kernel void blendKernel(texture2d<float, access::sample> a [[texture(0)]],
                        texture2d<float, access::sample> b [[texture(1)]],
                        texture2d<float, access::write> dst [[texture(2)]],
                        constant float& t                  [[buffer(0)]],
                        uint2 gid                          [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5f) / float2(dst.get_width(), dst.get_height());
    dst.write(mix(a.sample(linearSampler, uv), b.sample(linearSampler, uv), t), gid);
}

inline float lumaOf(float3 v) { return dot(v, float3(0.2627f, 0.6780f, 0.0593f)); }

inline float qcLuma(texture2d<float, access::read> t, int2 p, uint w, uint h, int smooth) {
    if (smooth == 0) return lumaOf(t.read(uint2(clamp(p, int2(0), int2(w - 1, h - 1)))).rgb);
    float s = 0.0f;
    for (int yy = -1; yy <= 1; yy++) for (int xx = -1; xx <= 1; xx++)
        s += lumaOf(t.read(uint2(clamp(p + int2(xx, yy), int2(0), int2(w - 1, h - 1)))).rgb);
    return s / 9.0f;
}

// Artifact scan: an interpolated frame should only contain structure that exists in one of its two
// neighbors (allowing a few pixels of motion). Structure in neither = warping, tearing or ghosting.
// Writes per-tile counts of suspicious pixels.
kernel void interpQCKernel(texture2d<float, access::read> a   [[texture(0)]],
                           texture2d<float, access::read> b   [[texture(1)]],
                           texture2d<float, access::read> mid [[texture(2)]],
                           constant InterpQCUniforms& q       [[buffer(0)]],
                           device atomic_uint* tiles          [[buffer(1)]],
                           uint2 gid                          [[thread_position_in_grid]]) {
    uint w = mid.get_width(), h = mid.get_height();
    if (gid.x >= w || gid.y >= h || (gid.x & 1) || (gid.y & 1)) return;   // half-rate sampling is plenty
    // Grain-aware mode compares 3x3 averages: random grain cancels out, real structure doesn't.
    int sm = q.smooth;
    float m = qcLuma(mid, int2(gid), w, h, sm);
    float bestA = 1e9f, bestB = 1e9f;
    int step = q.smooth != 0 ? 2 : 1;
    for (int dy = -3; dy <= 3; dy += step) {
        for (int dx = -3; dx <= 3; dx += step) {
            bestA = min(bestA, abs(m - qcLuma(a, int2(gid) + int2(dx, dy), w, h, sm)));
            bestB = min(bestB, abs(m - qcLuma(b, int2(gid) + int2(dx, dy), w, h, sm)));
        }
    }
    if (min(bestA, bestB) > q.threshold) {
        uint tx = min(gid.x / uint(q.tileSize), uint(q.tilesX - 1));
        uint ty = min(gid.y / uint(q.tileSize), uint(q.tilesY - 1));
        atomic_fetch_add_explicit(&tiles[ty * uint(q.tilesX) + tx], 1u, memory_order_relaxed);
    }
}

// Repairs only the flagged regions: blends the model output toward a safe fallback through a
// feathered tile mask (bilinear-sampled low-res mask = soft edges, no visible seams).
kernel void repairKernel(texture2d<float, access::sample> generated [[texture(0)]],
                         texture2d<float, access::sample> fallback  [[texture(1)]],
                         texture2d<float, access::sample> mask      [[texture(2)]],
                         texture2d<float, access::write>  dst       [[texture(3)]],
                         uint2 gid                                  [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5f) / float2(dst.get_width(), dst.get_height());
    float k = smoothstep(0.0f, 1.0f, mask.sample(linearSampler, uv).r);
    dst.write(mix(generated.sample(linearSampler, uv), fallback.sample(linearSampler, uv), k), gid);
}


// ------------------------------------------------------------------------------------------
// Learned artifact scorer (ArtifactScorer.swift): reference-free per-tile features of a generated frame and of the
// alternatives it could be replaced with, then a per-tile switch to the chosen candidate.
// ------------------------------------------------------------------------------------------

// Analysis copy: box-averaged luma of A, B, the primary output P and the alternative output Q, packed as RGBA.
kernel void qcLumaPackKernel(texture2d<float, access::read>  a   [[texture(0)]],
                             texture2d<float, access::read>  b   [[texture(1)]],
                             texture2d<float, access::read>  p   [[texture(2)]],
                             texture2d<float, access::read>  q   [[texture(3)]],
                             texture2d<float, access::write> dst [[texture(4)]],
                             constant QCScoreUniforms& u         [[buffer(0)]],
                             uint2 gid                           [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.analysisWidth) || gid.y >= uint(u.analysisHeight)) return;
    uint W = p.get_width(), H = p.get_height();
    float4 s = 0.0f;
    float n = 0.0f;
    for (int y = 0; y < u.scale; y++) for (int x = 0; x < u.scale; x++) {
        uint2 c = min(gid * uint(u.scale) + uint2(x, y), uint2(W - 1, H - 1));
        s += float4(lumaOf(a.read(c).rgb), lumaOf(b.read(c).rgb), lumaOf(p.read(c).rgb), lumaOf(q.read(c).rgb));
        n += 1.0f;
    }
    dst.write(s / n, gid);
}

inline float4 qcAt(texture2d<float, access::read> t, int2 p, int2 lim) { return t.read(uint2(clamp(p, int2(0), lim))); }

// One threadgroup of 32x32 threads per 64-px analysis tile; each thread samples one pixel of every 2x2 block (like
// interpQCKernel). Writes QC_FEATS floats per tile: QC_SUMS sums (in this order) then QC_MAXES maxima.
//  0 luma P   1 |A-B|   2 |P-Q|   3 |P-blend|   4 |Q-blend|   5 |P-nearest|   6 |Q-nearest|   7 texture max(gA, gB)
//  8 gradient P   9 excess structure P   10 excess structure Q   11 novelty P   12 novelty Q
//  13 novelty P > 0.04   14 novelty P > 0.10   15 novelty Q > 0.04   16 novelty Q > 0.10
//  17 |A-B| > 0.02   18 |P-Q| > 0.02   19 luma A   20 luma B   21 sample count
//  maxima: 22 |P-Q|   23 |A-B|   24 novelty P   25 novelty Q
// Novelty = distance to the closest luma of A or B within +-3 px: structure that exists in neither neighbor.
kernel void qcFeatureKernel(texture2d<float, access::read> L  [[texture(0)]],   // qcLumaPackKernel output
                            device float* out                 [[buffer(0)]],
                            constant QCScoreUniforms& u       [[buffer(1)]],
                            uint2 tile                        [[threadgroup_position_in_grid]],
                            uint2 lid                         [[thread_position_in_threadgroup]],
                            uint2 tgSize                      [[threads_per_threadgroup]],
                            uint sgi                          [[simdgroup_index_in_threadgroup]],
                            uint lane                         [[thread_index_in_simdgroup]]) {
    threadgroup float partial[32][QC_FEATS];
    float f[QC_FEATS];
    for (int k = 0; k < QC_FEATS; k++) f[k] = 0.0f;
    int2 lim = int2(u.analysisWidth - 1, u.analysisHeight - 1);
    bool live = int(tile.x) < u.tilesX && int(tile.y) < u.tilesY;
    // 32 columns of threads; each thread walks down its column of the tile's 32x32 samples.
    for (uint row = lid.y; live && row < 32; row += tgSize.y) {
        int2 p = int2(tile * QC_TILE + uint2(lid.x, row) * 2);
        if (p.x > lim.x || p.y > lim.y) continue;
        float4 c = qcAt(L, p, lim);
        float lA = c.x, lB = c.y, lP = c.z, lQ = c.w;
        float4 g = abs(qcAt(L, p + int2(1, 0), lim) - qcAt(L, p - int2(1, 0), lim))
                 + abs(qcAt(L, p + int2(0, 1), lim) - qcAt(L, p - int2(0, 1), lim));
        float bestP = 1e9f, bestQ = 1e9f;
        for (int dy = -3; dy <= 3; dy++) for (int dx = -3; dx <= 3; dx++) {
            float2 ab = qcAt(L, p + int2(dx, dy), lim).xy;
            bestP = min(bestP, min(abs(lP - ab.x), abs(lP - ab.y)));
            bestQ = min(bestQ, min(abs(lQ - ab.x), abs(lQ - ab.y)));
        }
        float lBL = mix(lA, lB, u.t), lN = u.t < 0.5f ? lA : lB;
        float tex = max(g.x, g.y);
        float dAB = abs(lA - lB), dPQ = abs(lP - lQ);
        f[0] += lP; f[1] += dAB; f[2] += dPQ; f[3] += abs(lP - lBL); f[4] += abs(lQ - lBL); f[5] += abs(lP - lN); f[6] += abs(lQ - lN);
        f[7] += tex; f[8] += g.z; f[9] += max(0.0f, g.z - tex); f[10] += max(0.0f, g.w - tex);
        f[11] += bestP; f[12] += bestQ;
        f[13] += bestP > 0.04f ? 1.0f : 0.0f; f[14] += bestP > 0.10f ? 1.0f : 0.0f;
        f[15] += bestQ > 0.04f ? 1.0f : 0.0f; f[16] += bestQ > 0.10f ? 1.0f : 0.0f;
        f[17] += dAB > 0.02f ? 1.0f : 0.0f; f[18] += dPQ > 0.02f ? 1.0f : 0.0f;
        f[19] += lA; f[20] += lB; f[21] += 1.0f;
        f[22] = max(f[22], dPQ); f[23] = max(f[23], dAB); f[24] = max(f[24], bestP); f[25] = max(f[25], bestQ);
    }
    for (int k = 0; k < QC_SUMS; k++) f[k] = simd_sum(f[k]);
    for (int k = QC_SUMS; k < QC_FEATS; k++) f[k] = simd_max(f[k]);
    uint groups = (tgSize.x * tgSize.y + 31) / 32;
    if (lane == 0) for (int k = 0; k < QC_FEATS; k++) partial[sgi][k] = f[k];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint li = lid.y * tgSize.x + lid.x;
    if (li < QC_FEATS && live) {
        float s = 0.0f;
        for (uint k = 0; k < groups; k++) s = li < QC_SUMS ? s + partial[k][li] : max(s, partial[k][li]);
        out[(tile.y * uint(u.tilesX) + tile.x) * QC_FEATS + li] = s;
    }
}

// Statistics of the alternative flow model's prediction per analysis tile. Slots: 0 |motion t->0|, 1 |motion t->1|
// (in 1920-px-wide picture units), 2 forward/backward inconsistency, 3 inconsistency > 0.35, 4 occlusion (mask near
// 0 or 1), 5 sample count, 6 unused, 7 max |motion| (float bits, atomic max).
kernel void qcFlowStatsKernel(device const half* flow      [[buffer(0)]],
                              device const half* mask      [[buffer(1)]],
                              device atomic_float* out     [[buffer(2)]],
                              device atomic_uint* omax     [[buffer(3)]],
                              constant QCScoreUniforms& u  [[buffer(4)]],
                              uint2 gid                    [[thread_position_in_grid]]) {
    if (gid.x >= uint(u.modelWidth) || gid.y >= uint(u.modelHeight)) return;
    uint plane = uint(u.tensorWidth * u.tensorHeight);
    uint i = gid.y * uint(u.tensorWidth) + gid.x;
    float2 f0 = float2(flow[i], flow[plane + i]);
    float2 f1 = float2(flow[2 * plane + i], flow[3 * plane + i]);
    float m = float(mask[i]);
    float toRef = 1920.0f / float(u.modelWidth);
    float2 ap = (float2(gid) + 0.5f) * float2(float(u.analysisWidth) / float(u.modelWidth), float(u.analysisHeight) / float(u.modelHeight));
    uint tx = min(uint(ap.x) / uint(QC_TILE), uint(u.tilesX - 1)), ty = min(uint(ap.y) / uint(QC_TILE), uint(u.tilesY - 1));
    uint t = ty * uint(u.tilesX) + tx;
    float k = u.t / max(1.0f - u.t, 1e-3f);
    float err = length(f0 + k * f1) / (1.0f + length(f0) + k * length(f1));
    device atomic_float* o = out + t * QC_FLOW;
    atomic_fetch_add_explicit(&o[0], length(f0) * toRef, memory_order_relaxed);
    atomic_fetch_add_explicit(&o[1], length(f1) * toRef, memory_order_relaxed);
    atomic_fetch_add_explicit(&o[2], err, memory_order_relaxed);
    atomic_fetch_add_explicit(&o[3], err > 0.35f ? 1.0f : 0.0f, memory_order_relaxed);
    atomic_fetch_add_explicit(&o[4], (m < 0.15f || m > 0.85f) ? 1.0f : 0.0f, memory_order_relaxed);
    atomic_fetch_add_explicit(&o[5], 1.0f, memory_order_relaxed);
    atomic_fetch_max_explicit(&omax[t], as_type<uint>(max(length(f0), length(f1)) * toRef), memory_order_relaxed);
}

// Per-tile switch between candidates. choice: 0 primary, 1 alternative model, 2 cross-fade, 3 nearest original,
// 4 average of primary and alternative. Where two neighboring tiles use different candidates, the edge is feathered
// over QC_FEATHER analysis pixels on each side (50/50 on the edge itself), because a hard switch leaves a visible
// step along the tile edge (measured: about 1 in 4 such edges, up to 40 code values). Tiles whose neighbors all use
// the same candidate are copied exactly.
inline float4 qcCandidate(uchar c, uint2 gid, texture2d<float, access::read> p, texture2d<float, access::read> q,
                          texture2d<float, access::read> a, texture2d<float, access::read> b, float t) {
    switch (c) {
        case 1: return q.read(gid);
        case 2: return mix(a.read(gid), b.read(gid), t);
        case 3: return t < 0.5f ? a.read(gid) : b.read(gid);
        case 4: return 0.5f * (p.read(gid) + q.read(gid));
        default: return p.read(gid);
    }
}

kernel void qcComposeKernel(texture2d<float, access::read>  p   [[texture(0)]],
                            texture2d<float, access::read>  q   [[texture(1)]],
                            texture2d<float, access::read>  a   [[texture(2)]],
                            texture2d<float, access::read>  b   [[texture(3)]],
                            texture2d<float, access::write> dst [[texture(4)]],
                            device const uchar* choice          [[buffer(0)]],
                            constant QCScoreUniforms& u         [[buffer(1)]],
                            uint2 gid                           [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int full = QC_TILE * u.scale;
    int tx = min(int(gid.x) / full, u.tilesX - 1), ty = min(int(gid.y) / full, u.tilesY - 1);
    uchar own = choice[ty * u.tilesX + tx];
    // Tent weights of the left / own / right column and the upper / own / lower row of tiles.
    float band = float(QC_FEATHER * u.scale);
    float fx = float(int(gid.x) - tx * full) + 0.5f, fy = float(int(gid.y) - ty * full) + 0.5f;
    float3 hx = float3(tx > 0 ? 0.5f * max(0.0f, 1.0f - fx / band) : 0.0f, 0.0f,
                       tx < u.tilesX - 1 ? 0.5f * max(0.0f, 1.0f - (float(full) - fx) / band) : 0.0f);
    float3 hy = float3(ty > 0 ? 0.5f * max(0.0f, 1.0f - fy / band) : 0.0f, 0.0f,
                       ty < u.tilesY - 1 ? 0.5f * max(0.0f, 1.0f - (float(full) - fy) / band) : 0.0f);
    hx.y = 1.0f - hx.x - hx.z;
    hy.y = 1.0f - hy.x - hy.z;
    bool mixed = false;
    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
        if (hx[dx + 1] * hy[dy + 1] > 0.0f && choice[(ty + dy) * u.tilesX + tx + dx] != own) mixed = true;
    }
    if (!mixed) { dst.write(qcCandidate(own, gid, p, q, a, b, u.t), gid); return; }
    float4 v = 0.0f;
    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
        float w = hx[dx + 1] * hy[dy + 1];
        if (w > 0.0f) v += w * qcCandidate(choice[(ty + dy) * u.tilesX + tx + dx], gid, p, q, a, b, u.t);
    }
    dst.write(v, gid);
}

// ------------------------------------------------------------------------------------------
// HDR scopes: waveform on the PQ (ST 2084) scale and CIE 1931 xy chromaticity of the graded output.
// ------------------------------------------------------------------------------------------
kernel void scopeKernel(texture2d<float, access::sample> src   [[texture(0)]],
                        texture2d<float, access::sample> guide [[texture(1)]],
                        constant GradeUniforms& u              [[buffer(0)]],
                        device atomic_uint* waveform           [[buffer(1)]],
                        device atomic_uint* cie                [[buffer(2)]],
                        constant uint2& grid                   [[buffer(3)]],
                        uint2 gid                              [[thread_position_in_grid]]) {
    if (gid.x >= grid.x || gid.y >= grid.y) return;
    float2 uv = (float2(gid) + 0.5f) / float2(grid);
    float3 nits = renderNits(src.sample(linearSampler, srcUV(uv, u)).rgb, guide.sample(linearSampler, uv).rg, u);
    float Y = dot(nits, u.outputLuma.rgb);
    uint col = min(uint(uv.x * SCOPE_W), uint(SCOPE_W - 1));
    uint row = min(uint(nitsToPQ(Y) * float(SCOPE_H - 1)), uint(SCOPE_H - 1));
    atomic_fetch_add_explicit(&waveform[row * SCOPE_W + col], 1u, memory_order_relaxed);
    float3 xyz = u.outputToXYZ * nits;
    float s = xyz.x + xyz.y + xyz.z;
    if (s > 0.05f) {
        float2 xy = xyz.xy / s;
        uint cx = min(uint(saturate(xy.x / 0.8f) * (CIE_N - 1)), uint(CIE_N - 1));
        uint cy = min(uint(saturate(xy.y / 0.9f) * (CIE_N - 1)), uint(CIE_N - 1));
        atomic_fetch_add_explicit(&cie[cy * CIE_N + cx], 1u, memory_order_relaxed);
    }
}

// Nits picker: graded light at one point (output gamut RGB, in nits).
kernel void probeKernel(texture2d<float, access::sample> src   [[texture(0)]],
                        texture2d<float, access::sample> guide [[texture(1)]],
                        constant GradeUniforms& u              [[buffer(0)]],
                        device float4* result                  [[buffer(1)]],
                        constant float2& uv                    [[buffer(2)]],
                        uint gid                               [[thread_position_in_grid]]) {
    if (gid > 0) return;
    float3 nits = renderNits(src.sample(linearSampler, srcUV(uv, u)).rgb, guide.sample(linearSampler, uv).rg, u);
    result[0] = float4(nits, dot(nits, u.outputLuma.rgb));
}

// Black-bar detection: brightest encoded value in every row and column (x 65535).
kernel void rowColMaxKernel(texture2d<float, access::read> src [[texture(0)]],
                            device atomic_uint* rows           [[buffer(0)]],
                            device atomic_uint* cols           [[buffer(1)]],
                            uint2 gid                          [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;
    float3 v = src.read(gid).rgb;
    uint m = uint(saturate(max3(v.r, v.g, v.b)) * 65535.0f);
    atomic_fetch_max_explicit(&rows[gid.y], m, memory_order_relaxed);
    atomic_fetch_max_explicit(&cols[gid.x], m, memory_order_relaxed);
}

// Luminance histogram in log2(nits), for reference matching.
// mode 0: our graded output. mode 1: the source decoded straight to display nits (a PQ reference release).
kernel void nitsHistogramKernel(texture2d<float, access::sample> src   [[texture(0)]],
                                texture2d<float, access::sample> guide [[texture(1)]],
                                constant GradeUniforms& u              [[buffer(0)]],
                                device atomic_uint* hist               [[buffer(1)]],
                                constant uint3& gridMode               [[buffer(2)]],
                                uint2 gid                              [[thread_position_in_grid]]) {
    if (gid.x >= gridMode.x || gid.y >= gridMode.y) return;
    float2 uv = (float2(gid) + 0.5f) / float2(gridMode.xy);
    float3 w = toWorking(src.sample(linearSampler, srcUV(uv, u)).rgb, u);
    float Y;
    if (gridMode.z == 0) Y = dot(renderNits(src.sample(linearSampler, srcUV(uv, u)).rgb, guide.sample(linearSampler, uv).rg, u), u.outputLuma.rgb);
    else                 Y = dot(w, kLuma2020) * 144.0f;     // PQ decode maps nits/144 -> scene linear
    float x = (log2(max(Y, 0.01f)) - MATCH_LOG_MIN) / (MATCH_LOG_MAX - MATCH_LOG_MIN);
    uint bin = min(uint(saturate(x) * (NITS_BINS - 1)), uint(NITS_BINS - 1));
    atomic_fetch_add_explicit(&hist[bin], 1u, memory_order_relaxed);
}


// Crop + format conversion into a texture the upscalers accept (rgba16Float).
kernel void cropCopyKernel(texture2d<float, access::sample> src [[texture(0)]],
                           texture2d<float, access::write>  dst [[texture(1)]],
                           constant float4& rect                [[buffer(0)]],
                           uint2 gid                            [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = rect.xy + (float2(gid) + 0.5f) / float2(dst.get_width(), dst.get_height()) * rect.zw;
    dst.write(src.sample(linearSampler, uv), gid);
}


// ------------------------------------------------------------------------------------------
// Flow-warped HDR interpolation (true 10/12-bit).
// The network only estimates motion, on an SDR-like proxy (what it was trained on). Lumora then warps the
// original high-bit-depth pixels itself in 32-bit float, so generated frames keep the source's precision.
// ------------------------------------------------------------------------------------------

// Encoded source (log / PQ / HLG / SDR / linear RAW) -> SDR-like proxy tensor for motion estimation.
kernel void flowProxyKernel(texture2d<float, access::sample> src [[texture(0)]],
                            device half* tensor                  [[buffer(0)]],
                            constant FlowUniforms& f             [[buffer(1)]],
                            constant GradeUniforms& u            [[buffer(2)]],
                            uint2 gid                            [[thread_position_in_grid]]) {
    if (gid.x >= uint(f.tensorWidth) || gid.y >= uint(f.tensorHeight)) return;
    uint2 q = min(gid, uint2(f.contentWidth - 1, f.contentHeight - 1));
    float2 uv = (float2(q) + 0.5f) / float2(f.contentWidth, f.contentHeight);
    float3 w = max(toWorking(src.sample(linearSampler, uv).rgb, u), 0.0f) * 2.0f;
    float3 v = pow(w / (1.0f + w), 1.0f / 2.2f);            // Reinhard + gamma: mid gray ~0.55, like SDR video
    uint plane = uint(f.tensorWidth * f.tensorHeight);
    uint i = gid.y * uint(f.tensorWidth) + gid.x;
    tensor[i] = half(v.r); tensor[plane + i] = half(v.g); tensor[2 * plane + i] = half(v.b);
}

inline float tensorBilinear(device const half* t, uint plane, int W, int H, float2 p) {
    p = clamp(p, float2(0.0f), float2(W - 1, H - 1));
    int2 p0 = int2(floor(p));
    int2 p1 = min(p0 + 1, int2(W - 1, H - 1));
    float2 fr = p - float2(p0);
    float a = float(t[plane + uint(p0.y * W + p0.x)]), b = float(t[plane + uint(p0.y * W + p1.x)]);
    float c = float(t[plane + uint(p1.y * W + p0.x)]), d = float(t[plane + uint(p1.y * W + p1.x)]);
    return mix(mix(a, b, fr.x), mix(c, d, fr.x), fr.y);
}

// flow: 4 planes (t->0 dx, dy, t->1 dx, dy) in model pixels. mask: 1 plane, weight of frame A.
kernel void flowWarpBlendKernel(texture2d<float, access::sample> a   [[texture(0)]],
                                texture2d<float, access::sample> b   [[texture(1)]],
                                texture2d<float, access::write>  dst [[texture(2)]],
                                device const half* flow              [[buffer(0)]],
                                device const half* mask              [[buffer(1)]],
                                constant FlowUniforms& f             [[buffer(2)]],
                                uint2 gid                            [[thread_position_in_grid]]) {
    uint W = dst.get_width(), H = dst.get_height();
    if (gid.x >= W || gid.y >= H) return;
    float2 full = float2(W, H);
    float2 toModel = float2(f.contentWidth, f.contentHeight) / full;
    float2 mp = (float2(gid) + 0.5f) * toModel - 0.5f;
    uint plane = uint(f.tensorWidth * f.tensorHeight);
    float2 f0 = float2(tensorBilinear(flow, 0, f.tensorWidth, f.tensorHeight, mp),
                       tensorBilinear(flow, plane, f.tensorWidth, f.tensorHeight, mp)) / toModel;
    float2 f1 = float2(tensorBilinear(flow, 2 * plane, f.tensorWidth, f.tensorHeight, mp),
                       tensorBilinear(flow, 3 * plane, f.tensorWidth, f.tensorHeight, mp)) / toModel;
    float m = saturate(tensorBilinear(mask, 0, f.tensorWidth, f.tensorHeight, mp));
    float2 p = float2(gid) + 0.5f;
    float4 ca = a.sample(linearSampler, (p + f0) / full);
    float4 cb = b.sample(linearSampler, (p + f1) / full);
    dst.write(ca * m + cb * (1.0f - m), gid);
}

// Luma of an SDR-like proxy tensor (planar RGB) at pixel p.
inline float proxyLuma(device const half* t, uint plane, int width, int2 p) {
    uint j = uint(p.y) * uint(width) + uint(p.x);
    return 0.299f * float(t[j]) + 0.587f * float(t[plane + j]) + 0.114f * float(t[2 * plane + j]);
}

// Forward/backward motion check: for smooth motion the two flows point in opposite directions in
// proportion t : (1 - t). Where both frames contribute (mask not ~0/1, i.e. not an occlusion) and they
// disagree, the motion estimate is unreliable and an artifact is likely. Adds weighted counts to QC tiles.
kernel void flowConsistencyKernel(device const half* flow  [[buffer(0)]],
                                  device const half* mask  [[buffer(1)]],
                                  constant FlowUniforms& f [[buffer(2)]],
                                  device atomic_uint* tiles [[buffer(3)]],
                                  device const half* proxyA [[buffer(4)]],
                                  uint2 gid                [[thread_position_in_grid]]) {
    if (gid.x >= uint(f.contentWidth) || gid.y >= uint(f.contentHeight)) return;
    uint plane = uint(f.tensorWidth * f.tensorHeight);
    uint i = gid.y * uint(f.tensorWidth) + gid.x;
    float2 f0 = float2(flow[i], flow[plane + i]);
    float2 f1 = float2(flow[2 * plane + i], flow[3 * plane + i]);
    float m = float(mask[i]);
    if (m < 0.15f || m > 0.85f) return;                               // occlusion: one-sided by design
    // Where the picture has no texture (sky, walls, flat graphics) every motion gives the same pixels, so the two
    // flows are free to disagree without any visible artifact. Only count disagreement on texture: the luma
    // gradient of frame A's proxy where this pixel's content comes from.
    int2 q = clamp(int2(round(float2(gid) + f0)), int2(1), int2(f.contentWidth - 2, f.contentHeight - 2));
    float grad = abs(proxyLuma(proxyA, plane, f.tensorWidth, q + int2(1, 0)) - proxyLuma(proxyA, plane, f.tensorWidth, q - int2(1, 0)))
               + abs(proxyLuma(proxyA, plane, f.tensorWidth, q + int2(0, 1)) - proxyLuma(proxyA, plane, f.tensorWidth, q - int2(0, 1)));
    if (grad < 0.03f) return;
    float k = f.t / max(1.0f - f.t, 1e-3f);
    float err = length(f0 + k * f1) / (1.0f + length(f0) + k * length(f1));
    if (err > f.threshold) {
        float2 uv = (float2(gid) + 0.5f) / float2(f.contentWidth, f.contentHeight);
        uint tx = min(uint(uv.x * f.tilesX), uint(f.tilesX - 1)), ty = min(uint(uv.y * f.tilesY), uint(f.tilesY - 1));
        atomic_fetch_add_explicit(&tiles[ty * uint(f.tilesX) + tx], 1u, memory_order_relaxed);
    }
}

// ------------------------------------------------------------------------------------------
// Interpolation evaluation (original vs interpolated). Inputs are comparable PQ-encoded renders.
// ------------------------------------------------------------------------------------------

// Per 8x8 block: squared error (RGB) and SSIM (luma), accumulated as floats.
kernel void compareKernel(texture2d<float, access::read> a [[texture(0)]],
                          texture2d<float, access::read> b [[texture(1)]],
                          device atomic_float* out         [[buffer(0)]],
                          uint2 gid                        [[thread_position_in_grid]]) {
    uint2 o = gid * 8;
    if (o.x + 8 > a.get_width() || o.y + 8 > a.get_height()) return;
    float sa = 0, sb = 0, saa = 0, sbb = 0, sab = 0, se = 0;
    for (uint y = 0; y < 8; y++) for (uint x = 0; x < 8; x++) {
        float3 ca = a.read(o + uint2(x, y)).rgb, cb = b.read(o + uint2(x, y)).rgb;
        float la = dot(ca, kLuma2020), lb = dot(cb, kLuma2020);
        sa += la; sb += lb; saa += la * la; sbb += lb * lb; sab += la * lb;
        float3 d = ca - cb; se += dot(d, d);
    }
    float n = 64.0f, ma = sa / n, mb = sb / n;
    float va = saa / n - ma * ma, vb = sbb / n - mb * mb, cov = sab / n - ma * mb;
    const float C1 = 0.0001f, C2 = 0.0009f;
    float ssim = ((2 * ma * mb + C1) * (2 * cov + C2)) / ((ma * ma + mb * mb + C1) * (va + vb + C2));
    atomic_fetch_add_explicit(&out[0], se / (n * 3.0f), memory_order_relaxed);
    atomic_fetch_add_explicit(&out[1], ssim, memory_order_relaxed);
    atomic_fetch_add_explicit(&out[2], 1.0f, memory_order_relaxed);
}

// How a generated frame relates to its two real neighbors: error vs a plain cross-fade (ghosting),
// vs either neighbor (a duplicated "fake" frame), and how different the neighbors are (motion amount).
kernel void blendErrorKernel(texture2d<float, access::read> a   [[texture(0)]],
                             texture2d<float, access::read> b   [[texture(1)]],
                             texture2d<float, access::read> mid [[texture(2)]],
                             constant float& t                  [[buffer(0)]],
                             device atomic_float* out           [[buffer(1)]],
                             uint2 gid                          [[thread_position_in_grid]]) {
    if (gid.x >= mid.get_width() || gid.y >= mid.get_height() || (gid.x & 1) || (gid.y & 1)) return;
    float la = dot(a.read(gid).rgb, kLuma2020), lb = dot(b.read(gid).rgb, kLuma2020), lm = dot(mid.read(gid).rgb, kLuma2020);
    atomic_fetch_add_explicit(&out[0], abs(lm - mix(la, lb, t)), memory_order_relaxed);
    atomic_fetch_add_explicit(&out[1], min(abs(lm - la), abs(lm - lb)), memory_order_relaxed);
    atomic_fetch_add_explicit(&out[2], abs(la - lb), memory_order_relaxed);
    atomic_fetch_add_explicit(&out[3], 1.0f, memory_order_relaxed);
}

kernel void pqLumaHistKernel(texture2d<float, access::read> a [[texture(0)]],
                             device atomic_uint* hist         [[buffer(0)]],
                             uint2 gid                        [[thread_position_in_grid]]) {
    if (gid.x >= a.get_width() || gid.y >= a.get_height()) return;
    uint bin = min(uint(saturate(dot(a.read(gid).rgb, kLuma2020)) * 255.0f), 255u);
    atomic_fetch_add_explicit(&hist[bin], 1u, memory_order_relaxed);
}

// Tone normalization for fair comparison when the interpolated file was regraded (e.g. HDR added):
// shift each pixel's PQ luma along a fitted 256-entry curve, keeping its color offsets.
kernel void toneMatchKernel(texture2d<float, access::read>  a   [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant float* curve               [[buffer(0)]],
                            uint2 gid                           [[thread_position_in_grid]]) {
    if (gid.x >= a.get_width() || gid.y >= a.get_height()) return;
    float3 c = a.read(gid).rgb;
    float y = saturate(dot(c, kLuma2020)) * 255.0f;
    int i = min(int(y), 254);
    float mapped = mix(curve[i], curve[i + 1], y - float(i));
    dst.write(float4(c + (mapped - y / 255.0f), 1.0f), gid);
}


// ------------------------------------------------------------------------------------------
// Content test: what kind of picture is this? Per 8x8 block of the (encoded, perceptual) luma:
// detail (Sobel), flat-area share, grain/noise in flat areas, hard-edge share, colorfulness.
// out (atomic float): 0 sobel sum, 1 edge px, 2 flat blocks, 3 noise sum (flat), 4 noise count,
//                     5 blocks, 6 pixels, 7 chroma sum
// ------------------------------------------------------------------------------------------
kernel void contentStatsKernel(texture2d<float, access::sample> src [[texture(0)]],
                               device atomic_float* out             [[buffer(0)]],
                               constant uint2& grid                 [[buffer(1)]],
                               uint2 gid                            [[thread_position_in_grid]]) {
    uint2 o = gid * 8;
    if (o.x + 9 >= grid.x || o.y + 9 >= grid.y || o.x == 0 || o.y == 0) return;
    float2 px = 1.0f / float2(grid);
    float l[10][10];
    float chroma = 0.0f;
    for (int y = 0; y < 10; y++) for (int x = 0; x < 10; x++) {
        float3 c = src.sample(linearSampler, (float2(o) + float2(x, y) - 0.5f) * px).rgb;
        l[y][x] = dot(c, kLuma2020);
        if (x > 0 && y > 0 && x < 9 && y < 9) chroma += max3(c.r, c.g, c.b) - min3(c.r, c.g, c.b);
    }
    float mean = 0, sq = 0, sobel = 0, lap = 0, edges = 0;
    for (int y = 1; y < 9; y++) for (int x = 1; x < 9; x++) {
        float v = l[y][x];
        mean += v; sq += v * v;
        float gx = (l[y-1][x+1] + 2*l[y][x+1] + l[y+1][x+1]) - (l[y-1][x-1] + 2*l[y][x-1] + l[y+1][x-1]);
        float gy = (l[y+1][x-1] + 2*l[y+1][x] + l[y+1][x+1]) - (l[y-1][x-1] + 2*l[y-1][x] + l[y-1][x+1]);
        float g = sqrt(gx * gx + gy * gy);
        sobel += g;
        if (g > 0.35f) edges += 1;
        lap += abs(4 * v - l[y-1][x] - l[y+1][x] - l[y][x-1] - l[y][x+1]);
    }
    mean /= 64.0f;
    float var = sq / 64.0f - mean * mean;
    atomic_fetch_add_explicit(&out[0], sobel, memory_order_relaxed);
    atomic_fetch_add_explicit(&out[1], edges, memory_order_relaxed);
    // "Flat" = smooth area: cel-shaded fills in animation, skies and walls in live action.
    if (var < 0.0004f) {
        atomic_fetch_add_explicit(&out[2], 1.0f, memory_order_relaxed);
        atomic_fetch_add_explicit(&out[3], lap / 64.0f, memory_order_relaxed);   // residual texture there = grain/noise
        atomic_fetch_add_explicit(&out[4], 1.0f, memory_order_relaxed);
    }
    atomic_fetch_add_explicit(&out[5], 1.0f, memory_order_relaxed);
    atomic_fetch_add_explicit(&out[6], 64.0f, memory_order_relaxed);
    atomic_fetch_add_explicit(&out[7], chroma, memory_order_relaxed);
}


// ------------------------------------------------------------------------------------------
// Grain handling: split a frame into clean picture + grain, measure the grain, and put grain back.
// ------------------------------------------------------------------------------------------

// Edge-preserving bilateral filter: removes film grain/noise, keeps edges. Range sigma is set from the measured grain.
kernel void bilateralKernel(texture2d<float, access::read>  src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant DenoiseUniforms& d         [[buffer(0)]],
                            uint2 gid                           [[thread_position_in_grid]]) {
    uint w = src.get_width(), h = src.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 c = src.read(gid);
    float4 acc = 0.0f;
    float wsum = 0.0f;
    float is2 = 1.0f / (2.0f * d.sigmaSpatial * d.sigmaSpatial), ir2 = 1.0f / (2.0f * d.sigmaRange * d.sigmaRange);
    for (int y = -d.radius; y <= d.radius; y++) {
        for (int x = -d.radius; x <= d.radius; x++) {
            uint2 p = uint2(clamp(int2(gid) + int2(x, y), int2(0), int2(w - 1, h - 1)));
            float4 v = src.read(p);
            float dl = lumaOf(v.rgb) - lumaOf(c.rgb);
            float wt = exp(-float(x * x + y * y) * is2 - dl * dl * ir2);
            acc += v * wt;
            wsum += wt;
        }
    }
    dst.write(acc / wsum, gid);
}

// Grain = original - clean. Accumulates grain energy per brightness band (for AV1 grain tables and stats).
kernel void grainStatsKernel(texture2d<float, access::read> orig  [[texture(0)]],
                             texture2d<float, access::read> clean [[texture(1)]],
                             device atomic_float* sums            [[buffer(0)]],   // [GRAIN_BINS] sum of r^2
                             device atomic_uint* counts           [[buffer(1)]],   // [GRAIN_BINS]
                             uint2 gid                            [[thread_position_in_grid]]) {
    if (gid.x >= orig.get_width() || gid.y >= orig.get_height() || (gid.x & 1) || (gid.y & 1)) return;
    float lc = lumaOf(clean.read(gid).rgb);
    float r = lumaOf(orig.read(gid).rgb) - lc;
    uint bin = min(uint(saturate(lc) * GRAIN_BINS), uint(GRAIN_BINS - 1));
    atomic_fetch_add_explicit(&sums[bin], r * r, memory_order_relaxed);
    atomic_fetch_add_explicit(&counts[bin], 1u, memory_order_relaxed);
}

// Re-grains an interpolated clean frame with real grain from the nearest source frame, shifted by a fresh random
// offset so it never "freezes" and keeps exactly the source's grain size, color and strength.
kernel void regrainKernel(texture2d<float, access::read>  cleanMid  [[texture(0)]],
                          texture2d<float, access::read>  origNear  [[texture(1)]],
                          texture2d<float, access::read>  cleanNear [[texture(2)]],
                          texture2d<float, access::write> dst       [[texture(3)]],
                          constant int2& offset                     [[buffer(0)]],
                          uint2 gid                                 [[thread_position_in_grid]]) {
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    uint2 p = uint2((int2(gid) + offset + int2(w, h) * 4) % int2(w, h));
    float4 grain = origNear.read(p) - cleanNear.read(p);
    dst.write(cleanMid.read(gid) + float4(grain.rgb, 0.0f), gid);
}
