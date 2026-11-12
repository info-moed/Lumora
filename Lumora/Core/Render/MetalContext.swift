import Metal
import MetalKit
import CoreVideo
import CoreImage

/// One device, one queue, prebuilt pipelines and a CoreVideo texture cache shared by every stage.
/// Unified memory means decoded frames from the media engine are wrapped as textures with zero copies.
final class MetalContext {
    static let shared = MetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let textureCache: CVMetalTextureCache
    let ciContext: CIContext
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var names: [ObjectIdentifier: String] = [:]

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            fatalError("Lumora requires an Apple silicon GPU with Metal")
        }
        self.device = device
        self.queue = queue
        self.library = library
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache!
        self.ciContext = CIContext(mtlDevice: device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false
        ])
        for name in ["logLumaKernel", "gradeKernel", "pack420Kernel", "pack422Kernel",
                     "analyzeKernel", "measureKernel", "lutKernel",
                     "packPlanarKernel", "packY416Kernel", "textureToTensorKernel", "tensorToTextureKernel",
                     "blendKernel", "interpQCKernel", "repairKernel", "guidedCoeffKernel",
                     "temporalBlendKernel", "scopeKernel", "probeKernel", "rowColMaxKernel", "nitsHistogramKernel", "cropCopyKernel",
                     "flowProxyKernel", "flowWarpBlendKernel", "flowConsistencyKernel", "compareKernel",
                     "blendErrorKernel", "pqLumaHistKernel", "toneMatchKernel", "contentStatsKernel",
                     "bilateralKernel", "grainStatsKernel", "regrainKernel"] {
            guard let fn = library.makeFunction(name: name),
                  let pso = try? device.makeComputePipelineState(function: fn) else {
                fatalError("Missing Metal kernel \(name)")
            }
            pipelines[name] = pso
            names[ObjectIdentifier(pso)] = name
        }
    }

    func pipeline(_ name: String) -> MTLComputePipelineState { pipelines[name]! }

    func name(of pso: MTLComputePipelineState) -> String? { names[ObjectIdentifier(pso)] }

    func dispatch2D(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, width: Int, height: Int,
                    threadgroup: (Int, Int)? = nil) {
        enc.setComputePipelineState(pso)
        // Threadgroup shape measured on this Mac (Optimize for this Mac), else the hardware's natural shape.
        let tuned = threadgroup ?? names[ObjectIdentifier(pso)].flatMap { MacProfile.current?.threadgroups[$0] }.map { ($0[0], $0[1]) }
        let w = tuned?.0 ?? pso.threadExecutionWidth
        let h = tuned?.1 ?? max(1, pso.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    func makeTexture(width: Int, height: Int, format: MTLPixelFormat,
                     usage: MTLTextureUsage = [.shaderRead, .shaderWrite],
                     storage: MTLStorageMode = .private) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                         mipmapped: false)
        d.usage = usage
        d.storageMode = storage
        return device.makeTexture(descriptor: d)!
    }

    /// Wraps a CVPixelBuffer plane as a Metal texture. Keep the returned CVMetalTexture alive
    /// until the GPU has finished with the texture.
    func texture(from pixelBuffer: CVPixelBuffer, format: MTLPixelFormat, plane: Int = 0) -> (MTLTexture, CVMetalTexture)? {
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let w = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) : CVPixelBufferGetWidth(pixelBuffer)
        let h = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) : CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                                                               format, w, h, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture, let tex = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (tex, cvTexture)
    }
}
