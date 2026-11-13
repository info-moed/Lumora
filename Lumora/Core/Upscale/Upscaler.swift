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
    /// Context pixels kept around each tile and thrown away (default 16). Models that fold pixels into channels
    /// (x2plus works at half resolution inside) need more to hide tile edges.
    var overlap: Int?
    /// Seconds per megapixel of input, measured on an M3 Max (RealESRGANTests' benchmark); used by time estimates.
    var secondsPerMegapixel: Double?

    var url: URL { InterpolationModelSpec.modelsFolder.appendingPathComponent(file) }
    /// The package, or a compiled copy of it on its own.
    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: url.path)
            || FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("mlmodelc").path)
    }

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
        if let th = mode.targetHeight, th > ch, ch > 0, cw > 0 {
            outputHeight = th & ~1
            outputWidth = Int((Float(cw) * Float(th) / Float(ch)).rounded()) & ~1
        } else {
            outputWidth = cw
            outputHeight = ch
        }
        if case .model(let id, _) = mode {
            guard let spec = UpscaleModelSpec.all().first(where: { $0.id == id }), spec.isInstalled else {
                throw LumoraError.unsupported("The upscaling model isn't installed. Convert it with scripts/convert_realesrgan_coreml.py "
                                              + "(see the feature reference → Upscaling), or choose MetalFX.")
            }
            let m = try CoreMLUpscaler(spec: spec)
            // The model's full-size result has to fit in one Metal texture before it's resized to the target.
            let limit = 16384
            if outputWidth != cw || outputHeight != ch, max(cw, ch) * m.scale > limit {
                throw LumoraError.unsupported("\(spec.displayName) would make a \(cw * m.scale)×\(ch * m.scale) picture, larger than "
                                              + "the GPU allows (\(limit) pixels). Use MetalFX, or a 2× model, for this source.")
            }
            model = m
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
                if modelOut == nil { modelOut = ctx.makeTexture(width: cw * model!.scale, height: ch * model!.scale,
                                                                format: .rgba16Float) }
                try model!.upscale(current, into: modelOut!)
                let cb2 = ctx.queue.makeCommandBuffer()!
                if CoreMLUpscaler.antiRinging {
                    var s = Int32(model!.scale)
                    let e = cb2.makeComputeCommandEncoder()!
                    e.setTexture(current, index: 0)
                    e.setTexture(modelOut, index: 1)
                    e.setBytes(&s, length: 4, index: 0)
                    ctx.dispatch2D(e, ctx.pipeline("antiRingKernel"), width: modelOut!.width, height: modelOut!.height)
                    e.endEncoding()
                }
                current = modelOut!
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
/// The tile size and scale are read from the model itself, so a model converted with another `--tile` still works.
final class CoreMLUpscaler {
    let spec: UpscaleModelSpec
    /// Square input tile of the model, in pixels.
    let tile: Int
    /// Output pixels per input pixel (the model's real factor; the manifest's `scale` is only a description).
    let scale: Int
    /// Context pixels on every side of a tile that are computed but thrown away, so tile edges never show.
    var overlap: Int
    /// Clamp the result to the range of the nearby input pixels (see antiRingKernel). Tests switch it off to compare.
    static var antiRinging = true
    private let model: MLModel
    private let ctx = MetalContext.shared
    private lazy var inBuf = ctx.device.makeBuffer(length: 3 * tile * tile * 2, options: .storageModeShared)!
    private lazy var outBuf = ctx.device.makeBuffer(length: 3 * tile * tile * scale * scale * 2, options: .storageModeShared)!

    /// Which processors Core ML may use (tests compare them; the app lets Core ML choose).
    static var computeUnits: MLComputeUnits = .all

    init(spec: UpscaleModelSpec) throws {
        self.spec = spec
        let config = MLModelConfiguration()
        config.computeUnits = Self.computeUnits
        model = try MLModel(contentsOf: try Self.compiledURL(spec), configuration: config)
        let inShape = model.modelDescription.inputDescriptionsByName[spec.input]?.multiArrayConstraint?.shape.map(\.intValue) ?? []
        let outShape = model.modelDescription.outputDescriptionsByName[spec.output]?.multiArrayConstraint?.shape.map(\.intValue) ?? []
        guard inShape.count == 4, outShape.count == 4, inShape[1] == 3, outShape[1] == 3, inShape[2] == inShape[3],
              inShape[2] > 32, outShape[2] == outShape[3], outShape[2] % inShape[2] == 0 else {
            throw LumoraError.unsupported("\(spec.file) isn't a Real-ESRGAN model Lumora can use (input \(inShape), output \(outShape)). "
                                          + "Convert it with scripts/convert_realesrgan_coreml.py.")
        }
        tile = inShape[2]
        scale = outShape[2] / inShape[2]
        // Even, so every tile starts on the same 2x2 grid (x2plus folds 2x2 pixels into channels).
        overlap = min(max(4, spec.overlap ?? 16), tile / 4) & ~1
    }

    /// The compiled model next to the package, compiled again whenever the package is newer (a re-converted model
    /// must never be shadowed by the old compiled copy). A compiled model on its own is used as it is.
    static func compiledURL(_ spec: UpscaleModelSpec) throws -> URL {
        let fm = FileManager.default
        let url = spec.url
        guard url.pathExtension == "mlpackage" else { return url }
        let compiled = url.deletingPathExtension().appendingPathExtension("mlmodelc")
        guard fm.fileExists(atPath: url.path) else { return compiled }
        func modified(_ u: URL) -> Date { (try? fm.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast }
        func newest(_ u: URL) -> Date {
            var d = modified(u)
            if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for case let f as URL in e { d = max(d, modified(f)) }
            }
            return d
        }
        if fm.fileExists(atPath: compiled.path), modified(compiled) >= newest(url) { return compiled }
        let fresh = try MLModel.compileModel(at: url)
        if fm.fileExists(atPath: compiled.path) { _ = try fm.replaceItemAt(compiled, withItemAt: fresh) }
        else { try fm.moveItem(at: fresh, to: compiled) }
        return compiled
    }

    func upscale(_ src: MTLTexture, into dst: MTLTexture) throws {
        let T = tile, O = overlap, C = T - 2 * O, s = scale
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
