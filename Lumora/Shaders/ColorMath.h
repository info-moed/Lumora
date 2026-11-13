// Color math shared by the grading engine (Grade.metal) and the player (Player.metal).
// Definitions moved here unchanged from Grade.metal; the constants sit in an unnamed namespace so every shader
// file that includes this header gets its own copy without clashing when the library is linked.
#ifndef LUMORA_COLOR_MATH_H
#define LUMORA_COLOR_MATH_H

#include <metal_stdlib>
using namespace metal;

namespace {
constant float3 kLuma2020 = float3(0.2627f, 0.6780f, 0.0593f);
constant float PQ_M1 = 0.1593017578125f, PQ_M2 = 78.84375f;
constant float PQ_C1 = 0.8359375f, PQ_C2 = 18.8515625f, PQ_C3 = 18.6875f;
constant float HLG_A = 0.17883277f, HLG_B = 0.28466892f, HLG_C = 0.55991073f;
}

// SMPTE ST 2084 (PQ)
inline float pqToNits(float v) {
    float p = pow(max(v, 0.0f), 1.0f / PQ_M2);
    return 10000.0f * pow(max(p - PQ_C1, 0.0f) / (PQ_C2 - PQ_C3 * p), 1.0f / PQ_M1);
}
inline float nitsToPQ(float n) {
    float y = pow(clamp(n / 10000.0f, 0.0f, 1.0f), PQ_M1);
    return pow((PQ_C1 + PQ_C2 * y) / (1.0f + PQ_C3 * y), PQ_M2);
}

// ITU-R BT.2100 HLG
inline float hlgInverseOETF(float v) {
    return (v <= 0.5f) ? v * v / 3.0f : (exp((v - HLG_C) / HLG_A) + HLG_B) / 12.0f;
}
inline float hlgOETF(float e) {
    e = max(e, 0.0f);
    return (e <= 1.0f / 12.0f) ? sqrt(3.0f * e) : HLG_A * log(12.0f * e - HLG_B) + HLG_C;
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

// Full-precision PQ for the player, whose tests compare against a double-precision reference (the library is
// built with fast math, so the plain versions above may differ in the last bits).
inline float pqToNitsPrecise(float v) {
    float p = precise::pow(max(v, 0.0f), 1.0f / PQ_M2);
    return 10000.0f * precise::pow(max(p - PQ_C1, 0.0f) / (PQ_C2 - PQ_C3 * p), 1.0f / PQ_M1);
}
inline float nitsToPQPrecise(float n) {
    float y = precise::pow(clamp(n / 10000.0f, 0.0f, 1.0f), PQ_M1);
    return precise::pow((PQ_C1 + PQ_C2 * y) / (1.0f + PQ_C3 * y), PQ_M2);
}

#endif
