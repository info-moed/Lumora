import Foundation
import Metal
import MetalFX
import MetalPerformanceShaders
import CoreML

enum UpscaleMode: Codable, Hashable {
    case off
    case metalFX(targetHeight: Int)                 // built in, instant, no download
    case model(id: String, targetHeight: Int)       // Real-ESRGAN etc. through Core ML (best detail)

    var targetHeight: Int? {
        switch self { case .off: return nil; case .metalFX(let h), .model(_, let h): return h }
    }
}

struct UpscaleModelSpec: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String
    var file: String
    var input: String
    var output: String
    var scale: Int
    var tile: Int
    var license: String
    var notes: String

    var url: URL { InterpolationModelSpec.modelsFolder.appendingPathComponent(file) }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func all() -> [UpscaleModelSpec] {
        guard let u = Bundle.main.url(forResource: "upscale_models", withExtension: "json"),
              let d = try? Data(contentsOf: u) else { return [] }
        return (try? JSONDecoder().decode([UpscaleModelSpec].self, from: d)) ?? []
    }
}

/// Runs before grading, on the encoded source signal: crop away black bars, then upscale.
/// Upscaling the log / PQ signal (perceptually spaced) keeps HDR intact and matches how the models were trained.
final class PreGradeStage {
    let outputWidth: Int
    let outputHeight: Int
    private let crop: SIMD4<Float>
    private let mode: UpscaleMode
    private let ctx = MetalContext.shared
    private var cropped: MTLTexture?
    private var metalFX: [MTLFXSpatialScaler] = []
    private var fxTextures: [MTLTexture] = []
    private var model: CoreMLUpscaler?
    private var modelOut: MTLTexture?
    private var resized: MTLTexture?
    private var outRing: [MTLTexture] = []
    private var outIndex = 0

    var isActive: Bool { mode != .off }

    init(sourceWidth: Int, sourceHeight: Int, crop: SIMD4<Float>, mode: UpscaleMode) throws {
        self.crop = crop
        self.mode = mode
        let cw = Int(Float(sourceWidth) * crop.z) & ~1, ch = Int(Float(sourceHeight) * crop.w) & ~1
        if let th = mode.targetHeight, th > ch {
            outputHeight = th & ~1
            outputWidth = Int((Float(cw) * Float(th) / Float(ch)).rounded()) & ~1
        } else {
            outputWidth = cw
            outputHeight = ch
        }
        if case .model(let id, _) = mode {
            guard let spec = UpscaleModelSpec.all().first(where: { $0.id == id }), spec.isInstalled else {
                throw LumoraError.unsupported("The upscaling model isn't installed. See README → Upscaling.")
            }
            model = try CoreMLUpscaler(spec: spec)
        }
    }

    /// Returns the texture to grade and the crop rect the grade should still apply (full frame once cropped).
    func process(_ src: MTLTexture) throws -> (MTLTexture, SIMD4<Float>) {
        guard isActive else { return (src, crop) }
        let cw = Int(Float(src.width) * crop.z) & ~1, ch = Int(Float(src.height) * crop.w) & ~1
        if cropped?.width != cw || cropped?.height != ch {
            cropped = ctx.makeTexture(width: cw, height: ch, format: .rgba16Float)
        }
        var rect = crop
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(src, index: 0)
        enc.setTexture(cropped, index: 1)
        enc.setBytes(&rect, length: 16, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("cropCopyKernel"), width: cw, height: ch)
        enc.endEncoding()

        var current = cropped!
        if outputWidth != cw || outputHeight != ch {
            switch mode {
            case .metalFX:
                current = try encodeMetalFX(cb, current)
            case .model:
                cb.commit()
                cb.waitUntilCompleted()
                if modelOut == nil { modelOut = ctx.makeTexture(width: cw * model!.spec.scale, height: ch * model!.spec.scale,
                                                                format: .rgba16Float) }
                try model!.upscale(current, into: modelOut!)
                current = modelOut!
                let cb2 = ctx.queue.makeCommandBuffer()!
                current = resizeIfNeeded(cb2, current)
                let out = ringTexture()
                let blit = cb2.makeBlitCommandEncoder()!
                blit.copy(from: current, to: out)
                blit.endEncoding()
                cb2.commit()
                cb2.waitUntilCompleted()
                return (out, UniformBuilder.fullFrame)
            case .off:
                break
            }
        }
        current = resizeIfNeeded(cb, current)
        let out = ringTexture()
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: current, to: out)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return (out, UniformBuilder.fullFrame)
    }

    /// Each processed frame gets its own texture so later pipeline stages can still be reading earlier ones.
    private func ringTexture() -> MTLTexture {
        if outRing.isEmpty {
            outRing = (0..<12).map { _ in ctx.makeTexture(width: outputWidth, height: outputHeight, format: .rgba16Float) }
        }
        outIndex = (outIndex + 1) % outRing.count
        return outRing[outIndex]
    }

    /// MetalFX spatial upscaling in steps of at most 2x (perceptual mode: our signal is log/PQ-encoded).
    private func encodeMetalFX(_ cb: MTLCommandBuffer, _ input: MTLTexture) throws -> MTLTexture {
        if metalFX.isEmpty {
            var w = input.width, h = input.height
            var inputUsage: MTLTextureUsage = []
            while w < outputWidth || h < outputHeight {
                let nw = min(outputWidth, w * 2), nh = min(outputHeight, h * 2)
                let d = MTLFXSpatialScalerDescriptor()
                d.inputWidth = w; d.inputHeight = h; d.outputWidth = nw; d.outputHeight = nh
                d.colorTextureFormat = .rgba16Float
                d.outputTextureFormat = .rgba16Float
                d.colorProcessingMode = .perceptual
                guard let s = d.makeSpatialScaler(device: ctx.device) else {
                    throw LumoraError.unsupported("MetalFX upscaling isn't available on this Mac.")
                }
                if inputUsage.isEmpty { inputUsage = s.colorTextureUsage }
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: nw, height: nh, mipmapped: false)
                td.usage = s.outputTextureUsage.union([.shaderRead])
                td.storageMode = .private
                fxTextures.append(ctx.device.makeTexture(descriptor: td)!)
                metalFX.append(s)
                w = nw; h = nh
            }
        }
        var current = input
        for (s, out) in zip(metalFX, fxTextures) {
            s.colorTexture = current
            s.outputTexture = out
            s.inputContentWidth = current.width
            s.inputContentHeight = current.height
            s.encode(commandBuffer: cb)
            current = out
        }
        return current
    }

    private func resizeIfNeeded(_ cb: MTLCommandBuffer, _ t: MTLTexture) -> MTLTexture {
        guard t.width != outputWidth || t.height != outputHeight else { return t }
        if resized == nil { resized = ctx.makeTexture(width: outputWidth, height: outputHeight, format: .rgba16Float) }
        MPSImageLanczosScale(device: ctx.device).encode(commandBuffer: cb, sourceTexture: t, destinationTexture: resized!)
        return resized!
    }
}

/// Real-ESRGAN-class super-resolution through Core ML, processed in overlapping tiles so 4K/8K output fits
/// in memory. fp16 tensors in unified memory; on M5 Core ML can run it on the GPU Neural Accelerators.
final class CoreMLUpscaler {
    let spec: UpscaleModelSpec
    private let model: MLModel
    private let ctx = MetalContext.shared
    private lazy var inBuf = ctx.device.makeBuffer(length: 3 * spec.tile * spec.tile * 2, options: .storageModeShared)!
    private lazy var outBuf = ctx.device.makeBuffer(length: 3 * spec.tile * spec.tile * spec.scale * spec.scale * 2,
                                                    options: .storageModeShared)!

    init(spec: UpscaleModelSpec) throws {
        self.spec = spec
        var url = spec.url
        if url.pathExtension == "mlpackage" {
            let compiled = url.deletingPathExtension().appendingPathExtension("mlmodelc")
            if !FileManager.default.fileExists(atPath: compiled.path) {
                try FileManager.default.moveItem(at: try MLModel.compileModel(at: url), to: compiled)
            }
            url = compiled
        }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        model = try MLModel(contentsOf: url, configuration: config)
    }

    func upscale(_ src: MTLTexture, into dst: MTLTexture) throws {
        let T = spec.tile, O = 16, C = T - 2 * O, s = spec.scale
        let inArray = try MLMultiArray(dataPointer: inBuf.contents(), shape: [1, 3, T, T].map { NSNumber(value: $0) },
                                       dataType: .float16, strides: [3 * T * T, T * T, T, 1].map { NSNumber(value: $0) })
        let TS = T * s
        let outArray = try MLMultiArray(dataPointer: outBuf.contents(), shape: [1, 3, TS, TS].map { NSNumber(value: $0) },
                                        dataType: .float16, strides: [3 * TS * TS, TS * TS, TS, 1].map { NSNumber(value: $0) })
        let options = MLPredictionOptions()
        options.outputBackings = [spec.output: outArray]
        for cy in stride(from: 0, to: src.height, by: C) {
            for cx in stride(from: 0, to: src.width, by: C) {
                try Task.checkCancellation()
                var tin = TensorUniforms(width: Int32(T), height: Int32(T), srcWidth: Int32(src.width), srcHeight: Int32(src.height),
                                         srcX: Int32(cx - O), srcY: Int32(cy - O), outX: 0, outY: 0,
                                         innerX0: 0, innerY0: 0, innerX1: Int32(T), innerY1: Int32(T))
                var cb = ctx.queue.makeCommandBuffer()!
                var enc = cb.makeComputeCommandEncoder()!
                enc.setTexture(src, index: 0)
                enc.setBuffer(inBuf, offset: 0, index: 0)
                enc.setBytes(&tin, length: MemoryLayout<TensorUniforms>.stride, index: 1)
                ctx.dispatch2D(enc, ctx.pipeline("textureToTensorKernel"), width: T, height: T)
                enc.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()

                _ = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [spec.input: MLFeatureValue(multiArray: inArray)]),
                                         options: options)

                var tout = TensorUniforms(width: Int32(TS), height: Int32(TS), srcWidth: 0, srcHeight: 0, srcX: 0, srcY: 0,
                                          outX: Int32((cx - O) * s), outY: Int32((cy - O) * s),
                                          innerX0: Int32(O * s), innerY0: Int32(O * s),
                                          innerX1: Int32((O + C) * s), innerY1: Int32((O + C) * s))
                cb = ctx.queue.makeCommandBuffer()!
                enc = cb.makeComputeCommandEncoder()!
                enc.setBuffer(outBuf, offset: 0, index: 0)
                enc.setBytes(&tout, length: MemoryLayout<TensorUniforms>.stride, index: 1)
                enc.setTexture(dst, index: 0)
                ctx.dispatch2D(enc, ctx.pipeline("tensorToTextureKernel"), width: TS, height: TS)
                enc.endEncoding()
                cb.commit()
                cb.waitUntilCompleted()
            }
        }
    }
}
