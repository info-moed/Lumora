import Foundation
import Metal
import CoreML

/// Result of generating one in-between frame.
struct InterpolationOutput {
    var texture: MTLTexture
    /// QC tiles whose forward/backward motion disagrees (flow models only).
    var motionBad: [Bool]?
}

/// Generates in-between frames. All engines work on the *encoded source signal* (log / PQ / HLG / gamma)
/// before grading. Original frames are never touched.
protocol InterpolationEngine: AnyObject {
    var name: String { get }
    /// Generates one frame per time in `times` into the matching texture of `outputs`.
    func interpolate(_ a: MTLTexture, _ b: MTLTexture, times: [Float], into outputs: [MTLTexture],
                     qcTiles: (x: Int, y: Int)) throws -> [InterpolationOutput]
}

extension InterpolationEngine {
    func interpolate(_ a: MTLTexture, _ b: MTLTexture, t: Float, into dst: MTLTexture) throws {
        _ = try interpolate(a, b, times: [t], into: [dst], qcTiles: (1, 1))
    }
}

/// Describes a Core ML interpolation model. Lives in Resources/interpolation_models.json.
struct InterpolationModelSpec: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String
    var file: String
    var inputA: String
    var inputB: String
    var timestep: String?
    var timestepKind: String        // "scalar" ([1]) or "map" ([1,1,H,W])
    var output: String              // image output (image mode)
    var padMultiple: Int
    var tier: String
    var license: String
    var notes: String
    /// "image": the network outputs the finished frame (fp16).
    /// "flow":  the network outputs motion + blend mask; Lumora warps the original 10/12-bit pixels in fp32.
    var outputKind: String? = nil
    var flowOutput: String? = nil   // [1,4,H,W]: t->0 (dx,dy), t->1 (dx,dy), in model pixels
    var maskOutput: String? = nil   // [1,1,H,W]: weight of frame A (0...1)
    var modelScale: Float? = nil    // resolution the network runs at (flow mode), e.g. 0.5 for 4K

    var isFlow: Bool { outputKind == "flow" && flowOutput != nil && maskOutput != nil }

    static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumora/Models", isDirectory: true)
    }
    var url: URL { Self.modelsFolder.appendingPathComponent(file) }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Bundled entries plus models converted in Model Lab (user entries win on the same id).
    static func all() -> [InterpolationModelSpec] {
        var list: [InterpolationModelSpec] = []
        if let u = Bundle.main.url(forResource: "interpolation_models", withExtension: "json"), let d = try? Data(contentsOf: u) {
            list = (try? JSONDecoder().decode([InterpolationModelSpec].self, from: d)) ?? []
        }
        let user = modelsFolder.appendingPathComponent("models.json")
        if let d = try? Data(contentsOf: user), let extra = try? JSONDecoder().decode([InterpolationModelSpec].self, from: d) {
            list.removeAll { e in extra.contains { $0.id == e.id } }
            list += extra
        }
        return list
    }
}

/// RIFE, IFRNet, FILM, GMFSS… converted to Core ML.
///
/// Flow mode (recommended for HDR and 12-bit): the network sees an SDR-like proxy of the frames (what it was
/// trained on) and only predicts motion. Lumora warps and blends the *original* frames in 32-bit float on the
/// GPU, so generated frames keep the full precision of 10/12-bit HDR. It also yields a forward/backward motion
/// check for artifact detection.
///
/// Image mode: the network outputs the frame directly from the encoded signal in fp16 (~11 bits of precision).
final class CoreMLInterpolator: InterpolationEngine {
    let spec: InterpolationModelSpec
    var name: String { spec.displayName }
    /// Decode uniforms for the source colour (used to build the SDR proxy in flow mode).
    var proxyUniforms: GradeUniforms
    private let model: MLModel
    private let ctx = MetalContext.shared
    // Read-only from outside so the QC benchmark can measure the last prediction's motion, mask and tile counts.
    private(set) var dims = (tw: 0, th: 0, cw: 0, ch: 0)
    private(set) var bufA: MTLBuffer?, bufB: MTLBuffer?, bufOut: MTLBuffer?, bufFlow: MTLBuffer?, bufMask: MTLBuffer?
    private(set) var tileBuffer: MTLBuffer?

    init(spec: InterpolationModelSpec, proxyUniforms: GradeUniforms, computeUnits: MLComputeUnits? = nil) throws {
        self.spec = spec
        self.proxyUniforms = proxyUniforms
        var url = spec.url
        if url.pathExtension == "mlpackage" {
            let compiled = url.deletingPathExtension().appendingPathExtension("mlmodelc")
            if !FileManager.default.fileExists(atPath: compiled.path) {
                let tmp = try MLModel.compileModel(at: url)
                try? FileManager.default.removeItem(at: compiled)
                try FileManager.default.moveItem(at: tmp, to: compiled)
            }
            url = compiled
        }
        let config = MLModelConfiguration()
        // Measured best for this model on this Mac, else let Core ML choose per layer (ANE / GPU Neural Accelerators).
        config.computeUnits = computeUnits ?? MacProfile.current?.coreMLUnits[spec.id].flatMap(MLComputeUnits.init(rawValue:)) ?? .all
        config.allowLowPrecisionAccumulationOnGPU = true
        model = try MLModel(contentsOf: url, configuration: config)
    }

    private func prepare(width: Int, height: Int) {
        let scale: Float = spec.isFlow ? (spec.modelScale ?? (width > 2560 ? 0.5 : 1.0)) : 1.0
        let cw = max(64, Int(Float(width) * scale)), ch = max(64, Int(Float(height) * scale))
        let m = max(1, spec.padMultiple)
        let tw = (cw + m - 1) / m * m, th = (ch + m - 1) / m * m
        guard tw != dims.tw || th != dims.th || cw != dims.cw || ch != dims.ch else { return }
        dims = (tw, th, cw, ch)
        let plane = tw * th * MemoryLayout<Float16>.size
        bufA = ctx.device.makeBuffer(length: 3 * plane, options: .storageModeShared)
        bufB = ctx.device.makeBuffer(length: 3 * plane, options: .storageModeShared)
        bufOut = ctx.device.makeBuffer(length: 3 * plane, options: .storageModeShared)
        bufFlow = ctx.device.makeBuffer(length: 4 * plane, options: .storageModeShared)
        bufMask = ctx.device.makeBuffer(length: plane, options: .storageModeShared)
    }

    private func array(_ buffer: MTLBuffer, channels: Int) throws -> MLMultiArray {
        let (w, h) = (dims.tw, dims.th)
        return try MLMultiArray(dataPointer: buffer.contents(), shape: [1, channels, h, w].map { NSNumber(value: $0) },
                                dataType: .float16, strides: [channels * h * w, h * w, w, 1].map { NSNumber(value: $0) })
    }

    /// Copies a Core ML output (fp16 or fp32, contiguous) into a Metal-visible fp16 buffer.
    private func copy(_ arr: MLMultiArray, into buffer: MTLBuffer, count: Int) throws {
        let n = min(count, arr.count)
        let dst = buffer.contents().bindMemory(to: Float16.self, capacity: n)
        switch arr.dataType {
        case .float16:
            memcpy(dst, arr.dataPointer, n * MemoryLayout<Float16>.size)
        case .float32:
            let src = arr.dataPointer.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { dst[i] = Float16(src[i]) }
        default:
            throw LumoraError.unsupported("Unsupported model output type")
        }
    }

    private func timestepFeature(_ t: Float) throws -> MLFeatureValue {
        if spec.timestepKind == "map" {
            let arr = try MLMultiArray(shape: [1, 1, dims.th, dims.tw].map { NSNumber(value: $0) }, dataType: .float16)
            let p = arr.dataPointer.bindMemory(to: Float16.self, capacity: arr.count)
            for i in 0..<arr.count { p[i] = Float16(t) }
            return MLFeatureValue(multiArray: arr)
        }
        let s = try MLMultiArray(shape: [1], dataType: .float32)
        s[0] = NSNumber(value: t)
        return MLFeatureValue(multiArray: s)
    }

    func interpolate(_ a: MTLTexture, _ b: MTLTexture, times: [Float], into outputs: [MTLTexture],
                     qcTiles: (x: Int, y: Int)) throws -> [InterpolationOutput] {
        prepare(width: a.width, height: a.height)
        var cb = ctx.queue.makeCommandBuffer()!
        if spec.isFlow {
            var f = FlowUniforms(tensorWidth: Int32(dims.tw), tensorHeight: Int32(dims.th),
                                 contentWidth: Int32(dims.cw), contentHeight: Int32(dims.ch),
                                 t: 0, threshold: 0, tilesX: 0, tilesY: 0)
            var pu = proxyUniforms
            for (tex, buf) in [(a, bufA!), (b, bufB!)] {
                let enc = cb.makeComputeCommandEncoder()!
                enc.setTexture(tex, index: 0)
                enc.setBuffer(buf, offset: 0, index: 0)
                enc.setBytes(&f, length: MemoryLayout<FlowUniforms>.stride, index: 1)
                enc.setBytes(&pu, length: MemoryLayout<GradeUniforms>.stride, index: 2)
                ctx.dispatch2D(enc, ctx.pipeline("flowProxyKernel"), width: dims.tw, height: dims.th)
                enc.endEncoding()
            }
        } else {
            var tu = TensorUniforms(width: Int32(dims.tw), height: Int32(dims.th), srcWidth: Int32(a.width),
                                    srcHeight: Int32(a.height), srcX: 0, srcY: 0, outX: 0, outY: 0,
                                    innerX0: 0, innerY0: 0, innerX1: Int32(a.width), innerY1: Int32(a.height))
            for (tex, buf) in [(a, bufA!), (b, bufB!)] {
                let enc = cb.makeComputeCommandEncoder()!
                enc.setTexture(tex, index: 0)
                enc.setBuffer(buf, offset: 0, index: 0)
                enc.setBytes(&tu, length: MemoryLayout<TensorUniforms>.stride, index: 1)
                ctx.dispatch2D(enc, ctx.pipeline("textureToTensorKernel"), width: dims.tw, height: dims.th)
                enc.endEncoding()
            }
        }
        cb.commit()
        cb.waitUntilCompleted()

        // One batched prediction for every time between this pair (e.g. 3 frames for 4x).
        let ia = MLFeatureValue(multiArray: try array(bufA!, channels: 3))
        let ib = MLFeatureValue(multiArray: try array(bufB!, channels: 3))
        let providers: [MLFeatureProvider] = try times.map { t in
            var d: [String: MLFeatureValue] = [spec.inputA: ia, spec.inputB: ib]
            if let name = spec.timestep { d[name] = try timestepFeature(t) }
            return try MLDictionaryFeatureProvider(dictionary: d)
        }
        let results = try model.predictions(fromBatch: MLArrayBatchProvider(array: providers))

        let plane = dims.tw * dims.th
        var outs: [InterpolationOutput] = []
        for (i, t) in times.enumerated() {
            let r = results.features(at: i)
            cb = ctx.queue.makeCommandBuffer()!
            var motionBad: [Bool]? = nil
            if spec.isFlow, let fl = r.featureValue(for: spec.flowOutput!)?.multiArrayValue,
               let mk = r.featureValue(for: spec.maskOutput!)?.multiArrayValue {
                try copy(fl, into: bufFlow!, count: 4 * plane)
                try copy(mk, into: bufMask!, count: plane)
                var f = FlowUniforms(tensorWidth: Int32(dims.tw), tensorHeight: Int32(dims.th),
                                     contentWidth: Int32(dims.cw), contentHeight: Int32(dims.ch), t: t,
                                     threshold: 0.35, tilesX: Int32(qcTiles.x), tilesY: Int32(qcTiles.y))
                var enc = cb.makeComputeCommandEncoder()!
                enc.setTexture(a, index: 0)
                enc.setTexture(b, index: 1)
                enc.setTexture(outputs[i], index: 2)
                enc.setBuffer(bufFlow, offset: 0, index: 0)
                enc.setBuffer(bufMask, offset: 0, index: 1)
                enc.setBytes(&f, length: MemoryLayout<FlowUniforms>.stride, index: 2)
                ctx.dispatch2D(enc, ctx.pipeline("flowWarpBlendKernel"), width: outputs[i].width, height: outputs[i].height)
                enc.endEncoding()
                let tiles = qcTiles.x * qcTiles.y
                if tileBuffer?.length != tiles * 4 { tileBuffer = ctx.device.makeBuffer(length: tiles * 4, options: .storageModeShared) }
                memset(tileBuffer!.contents(), 0, tileBuffer!.length)
                enc = cb.makeComputeCommandEncoder()!
                enc.setBuffer(bufFlow, offset: 0, index: 0)
                enc.setBuffer(bufMask, offset: 0, index: 1)
                enc.setBytes(&f, length: MemoryLayout<FlowUniforms>.stride, index: 2)
                enc.setBuffer(tileBuffer, offset: 0, index: 3)
                enc.setBuffer(bufA, offset: 0, index: 4)          // frame A's proxy: only textured areas count
                ctx.dispatch2D(enc, ctx.pipeline("flowConsistencyKernel"), width: dims.cw, height: dims.ch)
                enc.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
                let counts = tileBuffer!.contents().bindMemory(to: UInt32.self, capacity: tiles)
                let perTile = Float(dims.cw * dims.ch) / Float(max(1, tiles))
                motionBad = (0..<tiles).map { Float(counts[$0]) > perTile * 0.06 }
            } else if let img = r.featureValue(for: spec.output)?.multiArrayValue {
                try copy(img, into: bufOut!, count: 3 * plane)
                var tu = TensorUniforms(width: Int32(dims.tw), height: Int32(dims.th), srcWidth: Int32(a.width),
                                        srcHeight: Int32(a.height), srcX: 0, srcY: 0, outX: 0, outY: 0,
                                        innerX0: 0, innerY0: 0, innerX1: Int32(a.width), innerY1: Int32(a.height))
                let enc = cb.makeComputeCommandEncoder()!
                enc.setBuffer(bufOut, offset: 0, index: 0)
                enc.setBytes(&tu, length: MemoryLayout<TensorUniforms>.stride, index: 1)
                enc.setTexture(outputs[i], index: 0)
                ctx.dispatch2D(enc, ctx.pipeline("tensorToTextureKernel"), width: a.width, height: a.height)
                enc.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
            } else {
                throw LumoraError.unsupported("\(spec.displayName) didn't return the expected outputs.")
            }
            outs.append(InterpolationOutput(texture: outputs[i], motionBad: motionBad))
        }
        return outs
    }
}

/// Plain cross-fade. Correct for fades and dissolves; the safe fallback everywhere else.
final class BlendInterpolator: InterpolationEngine {
    let name = "Blend"
    private let ctx = MetalContext.shared

    func interpolate(_ a: MTLTexture, _ b: MTLTexture, times: [Float], into outputs: [MTLTexture],
                     qcTiles: (x: Int, y: Int)) throws -> [InterpolationOutput] {
        for (t, dst) in zip(times, outputs) { encode(nil, a, b, t: t, into: dst) }
        return outputs.map { InterpolationOutput(texture: $0, motionBad: nil) }
    }

    func encode(_ commandBuffer: MTLCommandBuffer?, _ a: MTLTexture, _ b: MTLTexture, t: Float, into dst: MTLTexture) {
        let cb = commandBuffer ?? ctx.queue.makeCommandBuffer()!
        var tt = t
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(a, index: 0)
        enc.setTexture(b, index: 1)
        enc.setTexture(dst, index: 2)
        enc.setBytes(&tt, length: 4, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("blendKernel"), width: dst.width, height: dst.height)
        enc.endEncoding()
        if commandBuffer == nil { cb.commit(); cb.waitUntilCompleted() }
    }
}
