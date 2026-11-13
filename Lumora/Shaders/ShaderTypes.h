// Shared between Swift (via the bridging header) and Metal so uniform layouts can never drift.
#ifndef LUMORA_SHADER_TYPES_H
#define LUMORA_SHADER_TYPES_H

#include <simd/simd.h>

// ---- Input transfer functions (scene-referred decode) ----
#define TF_LINEAR    0
#define TF_APPLE_LOG 1   // Apple Log and Apple Log 2 share the same curve; they differ in primaries
#define TF_SLOG3     2
#define TF_LOGC3     3
#define TF_LOGC4     4
#define TF_VLOG      5
#define TF_BT1886    6
#define TF_SRGB      7
#define TF_PQ        8
#define TF_HLG       9

// ---- Output encodings ----
#define OUT_PQ  0
#define OUT_HLG 1
#define OUT_SDR 2

typedef struct {
    matrix_float3x3 inputToWorking;   // linear source gamut -> linear BT.2020 (working space)
    matrix_float3x3 workingToOutput;  // linear BT.2020 -> linear output gamut
    matrix_float3x3 workingToXYZ;
    matrix_float3x3 xyzToWorking;
    matrix_float3x3 outputToXYZ;      // for the CIE scope
    vector_float4   wbGain;           // white-balance gains in working space (luminance-normalised)
    vector_float4   outputLuma;       // luma coefficients of the output gamut
    vector_float4   viewport;         // x, y, w, h of the image inside the destination, in pixels
    vector_float4   sourceRect;       // crop inside the decoded frame: uv origin (xy) and size (zw)
    float exposure;                   // linear multiplier, includes per-scene auto exposure
    float midGreyNits;                // where scene 0.18 lands on the display
    float peakNits;                   // target display peak
    float contrast;                   // slope around mid gray, in stops-per-stop
    float toe;                        // shadow density
    float shoulder;                   // highlight roll-off hardness (higher = brighter, snappier highlights)
    float localContrast;              // "punch": detail/clarity in log-luminance
    float saturation;
    float vibrance;                   // boosts low-chroma colors more than already-saturated ones
    float skinProtect;                // 0..1, holds skin hues back from saturation boosts
    float highlightDesat;             // pulls near-peak highlights toward neutral, like film
    float blackNits;
    float highlightExpansion;         // inverse tone mapping: SDR->HDR, or punching up a dim HDR master
    float expansionKnee;              // source-linear level where expansion starts
    float expansionCeiling;           // source-linear level of the source's brightest highlights
    float split;                      // 0 = off; else fraction of width showing the ungraded source
    int   inputTransfer;
    int   outputTransfer;
    int   legalToFull;                // re-expand legal-range code values before a camera log curve
    int   gamutCompress;
    float ditherAmplitude;            // one code value at the output bit depth (0 = off)
    float debandThreshold;            // signal units; 0 = off
    float debandRadius;               // source pixels
    float guidedEpsilon;              // edge preservation of the punch filter (stops^2)
    int   falseColor;                 // preview: show brightness bands instead of the picture
    int   frameSeed;                  // varies dither/deband noise per frame
    int   matchCurveSize;             // 0 = no reference-match curve
    int   passthrough;                // "Keep original look": show/encode display-referred sources as mastered
    float matchCurve[64];             // stops of correction over log2(nits) from MATCH_LOG_MIN to MATCH_LOG_MAX
} GradeUniforms;

#define MATCH_LOG_MIN (-6.643856f)    // log2(0.01 nits)
#define MATCH_LOG_MAX (13.287712f)    // log2(10000 nits)

typedef struct {
    float kr;
    float kb;
    int   width;
    int   height;
    int   bits;      // 8, 10 or 12
    int   chroma;    // 0 = 4:2:0, 1 = 4:2:2, 2 = 4:4:4
    int   pad0;
    int   pad1;
} PackUniforms;

typedef struct {
    int   width;        // tensor width/height (padded tile)
    int   height;
    int   srcWidth;     // full texture size
    int   srcHeight;
    int   srcX;         // tile origin in the texture (reads clamp at the edges)
    int   srcY;
    int   outX;         // where tensor (0,0) lands in the destination
    int   outY;
    int   innerX0;      // tensor-space region actually written (drops tile overlap)
    int   innerY0;
    int   innerX1;
    int   innerY1;
} TensorUniforms;

typedef struct {
    int   tensorWidth;   // padded model tensor size
    int   tensorHeight;
    int   contentWidth;  // model-resolution picture inside the tensor
    int   contentHeight;
    float t;             // time of the generated frame (0..1)
    float threshold;     // flow inconsistency threshold (fraction of motion)
    int   tilesX;        // QC tile grid (full resolution)
    int   tilesY;
} FlowUniforms;

#define SCOPE_W 512
#define SCOPE_H 256
#define CIE_N   256
#define THUMB_W 32
#define THUMB_H 18
#define NITS_BINS 256

typedef struct {
    int   tileSize;
    float threshold; // per-pixel "novel structure" threshold in signal units
    int   tilesX;
    int   tilesY;
    int   smooth;    // grain-aware: compare 3x3-averaged luma so film grain isn't mistaken for artifacts
    int   pad0;
    int   pad1;
    int   pad2;
} InterpQCUniforms;

// Learned artifact scorer (ArtifactScorer.swift). Features are measured on an analysis copy at most ~1920 px wide,
// so a tile always covers about the same share of the picture.
#define QC_TILE 64            // analysis-resolution tile size
#define QC_SUMS 22            // per-tile feature sums (see qcFeatureKernel)
#define QC_MAXES 4            // per-tile feature maxima
#define QC_FEATS (QC_SUMS + QC_MAXES)
#define QC_FLOW 8             // per-tile flow statistics slots (see qcFlowStatsKernel)
#define QC_FEATHER 8          // qcComposeKernel: analysis pixels feathered on each side of an edge between candidates

typedef struct {
    int   scale;           // full-resolution pixels per analysis pixel (1, 2, ...)
    int   tilesX;          // analysis tile grid
    int   tilesY;
    int   analysisWidth;
    int   analysisHeight;
    float t;               // time of the generated frame (0..1)
    int   modelWidth;      // flow statistics: model-resolution picture inside the tensor
    int   modelHeight;
    int   tensorWidth;
    int   tensorHeight;
    int   pad0;
    int   pad1;
} QCScoreUniforms;

typedef struct {
    float sigmaSpatial;   // pixels
    float sigmaRange;     // signal units (≈ 2–3 × measured grain)
    int   radius;
    int   pad;
} DenoiseUniforms;

// ---- Built-in player (Player.metal) ----
// Frame storage, picked with a function constant.
#define PLAYER_LAYOUT_BIPLANAR_TEXTURE 0   // CVPixelBuffer: Y texture + interleaved CbCr texture
#define PLAYER_LAYOUT_SEMIPLANAR_BUFFER 1  // nv12 / p010 / p210 / p410 from a pipe: Y plane + interleaved CbCr plane
#define PLAYER_LAYOUT_PLANAR_BUFFER 2      // yuv4xxp / gbrp / gray from a pipe or avmdec: up to three planes
#define PLAYER_LAYOUT_RGBA_TEXTURE 3       // CVPixelBuffer already converted to non-linear R'G'B' by macOS (Dolby Vision 5)

// Signal transfer characteristics the player decodes.
#define PLAYER_TF_BT1886 0   // BT.709 / BT.601 / BT.2020 SDR: display gamma 2.4
#define PLAYER_TF_SRGB   1
#define PLAYER_TF_PQ     2
#define PLAYER_TF_HLG    3
#define PLAYER_TF_LINEAR 4
#define PLAYER_TF_GAMMA22 5
#define PLAYER_TF_GAMMA28 6

#define PLAYER_MATRIX_YCBCR 0
#define PLAYER_MATRIX_GBR   1   // planes hold G, B, R (MatrixCoefficients 0)
#define PLAYER_MATRIX_YCGCO 2

#define PLAYER_OUT_EXTENDED_LINEAR 0   // linear BT.2020, 1.0 = reference white (EDR)
#define PLAYER_OUT_PQ    1             // native PQ signal, BT.2020 (macOS tone mapping)
#define PLAYER_OUT_HLG   2             // native HLG signal, BT.2020 (macOS tone mapping)
#define PLAYER_OUT_CODES 3             // decoded code values (Y, Cb, Cr) for tests

typedef struct {
    matrix_float3x3 yuvToRgb;        // normalized Y'CbCr (Y' 0…1, Cb/Cr −0.5…0.5) -> R'G'B'
    matrix_float3x3 toBT2020;        // linear source primaries -> linear BT.2020
    vector_float4   viewport;        // x, y, w, h of the picture inside the destination, in pixels
    vector_float4   lumaSize;        // luma plane width, height (pixels); zw unused
    vector_float4   chroma;          // chroma plane width, height; horizontal and vertical 1 / subsampling
    vector_float4   chromaOffset;    // chroma-plane coordinate offset (x, y) for the siting; zw unused
    vector_uint4    strides;         // bytes per row of planes 0, 1, 2 (buffer layouts)
    vector_uint4    offsets;         // byte offset of planes 0, 1, 2 inside the buffer
    vector_float4   luma;            // luminance weights of the source primaries (HLG system gamma)
    int   bits;                      // significant bits per sample (8, 10, 12, 16)
    int   containerBits;             // 8 or 16
    int   msbAligned;                // samples sit in the top bits of their container (p010, x420…)
    int   fullRange;
    int   transfer;                  // PLAYER_TF_*
    int   matrixMode;                // PLAYER_MATRIX_*
    int   outputMode;                // PLAYER_OUT_*
    int   toneMap;                   // 1 = BT.2390 EETF toward dstPeak
    float refWhite;                  // nits shown as EDR 1.0
    float srcPeak;                   // nits: the brightest the content claims (clip point)
    float dstPeak;                   // nits: what the display can show right now (headroom × refWhite)
    float hlgLw;                     // HLG nominal display peak (nits)
    float hlgGamma;                  // HLG system gamma for hlgLw
    float eetfLb;                    // BT.2390: PQ of the source black
    float eetfLw;                    // BT.2390: PQ of the source peak
    float eetfMaxLum;                // BT.2390: normalized PQ of the display peak
    float eetfKS;                    // BT.2390: knee start
    float eetfMinLum;                // BT.2390: normalized PQ of the display black
    int   rotation;                  // clockwise rotation the picture is shown with: 0, 90, 180, 270
    int   pad1;
} PlayerUniforms;

#define GRAIN_BINS 32

#define HIST_BINS 128
#define HIST_LOW_STOP (-12.0f)
#define HIST_STOPS_PER_BIN (20.0f / 128.0f)

// stats buffer layout (uint32 each):
// 5..: unused
// 0 count, 1 skin count, 2 chroma sum (x1000), 3 max nits (float bits), 4 nits sum

#endif
