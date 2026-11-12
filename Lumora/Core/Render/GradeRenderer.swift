import Metal
import MetalPerformanceShaders
import CoreVideo
import CoreImage

/// Encodes Lumora's GPU passes. One instance per concurrent pipeline (preview, each export segment).
final class GradeRenderer {
    private let ctx = MetalContext.shared
    private var moments: MTLTexture?, momentsBlur: MTLTexture?, coeffs: MTLTexture?
    private var history: MTLTexture?, stabilized: MTLTexture?
    private var lastTemporalKey: Int?
    private var blur: MPSImageGaussianBlur?
    private var blurSigma: Float = 0
    private lazy var histBuffer = ctx.device.makeBuffer(length: Int(HIST_BINS) * 4, options: .storageModeShared)!
    private lazy var statsBuffer = ctx.device.makeBuffer(length: 8 * 4, options: .storageModeShared)!
    private lazy var thumbBuffer = ctx.device.makeBuffer(length: Int(THUMB_W * THUMB_H) * 4, options: .storageModeShared)!

    struct FrameStats {
        var histogram: [UInt32]
        var count: UInt32
        var skin: UInt32
        var chromaSum: UInt32
        var thumbnail: [Float]      // 32x18 mean luma, for duplicate-frame detection
    }

    // MARK: Edge-aware punch (guided filter)

    /// Builds guided-filter coefficients (a, b) at quarter resolution. With `temporalKey` (e.g. the shot index)
    /// the coefficients are eased toward the previous frame of the same shot, so clarity never flickers.
    private func encodeGuide(_ cb: MTLCommandBuffer, source: MTLTexture, uniforms: inout GradeUniforms,
                             width: Int, height: Int, temporalKey: Int? = nil) -> MTLTexture {
        let bw = max(8, width / 4), bh = max(8, height / 4)
        if moments?.width != bw || moments?.height != bh {
            moments = ctx.makeTexture(width: bw, height: bh, format: .rg32Float)
            momentsBlur = ctx.makeTexture(width: bw, height: bh, format: .rg32Float)
            coeffs = ctx.makeTexture(width: bw, height: bh, format: .rg32Float)
            history = ctx.makeTexture(width: bw, height: bh, format: .rg32Float)
            stabilized = ctx.makeTexture(width: bw, height: bh, format: .rg32Float)
            lastTemporalKey = nil
        }
        let sigma = max(1, Float(bw) * 0.015)
        if blur == nil || abs(sigma - blurSigma) > 0.5 {
            blur = MPSImageGaussianBlur(device: ctx.device, sigma: sigma)
            blur?.edgeMode = .clamp
            blurSigma = sigma
        }
        var enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(source, index: 0)
        enc.setTexture(moments, index: 1)
        enc.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("logLumaKernel"), width: bw, height: bh)
        enc.endEncoding()
        blur!.encode(commandBuffer: cb, sourceTexture: moments!, destinationTexture: momentsBlur!)
        enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(momentsBlur, index: 0)
        enc.setTexture(coeffs, index: 1)
        enc.setBytes(&uniforms, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("guidedCoeffKernel"), width: bw, height: bh)
        enc.endEncoding()
        // Smooth the coefficients themselves (standard guided filter step).
        blur!.encode(commandBuffer: cb, sourceTexture: coeffs!, destinationTexture: momentsBlur!)

        guard let key = temporalKey else { return momentsBlur! }
        if key == lastTemporalKey {
            var keep: Float = 0.5
            enc = cb.makeComputeCommandEncoder()!
            enc.setTexture(history, index: 0)
            enc.setTexture(momentsBlur, index: 1)
            enc.setTexture(stabilized, index: 2)
            enc.setBytes(&keep, length: 4, index: 0)
            ctx.dispatch2D(enc, ctx.pipeline("temporalBlendKernel"), width: bw, height: bh)
            enc.endEncoding()
        } else {
            let blit = cb.makeBlitCommandEncoder()!
            blit.copy(from: momentsBlur!, to: stabilized!)
            blit.endEncoding()
        }
        let blit = cb.makeBlitCommandEncoder()!
        blit.copy(from: stabilized!, to: history!)
        blit.endEncoding()
        lastTemporalKey = key
        return stabilized!
    }

    /// Grades `source` into `destination` (encoded PQ / HLG / BT.1886 RGB), honouring the viewport.
    func encodeGrade(_ cb: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture,
                     uniforms: GradeUniforms, temporalKey: Int? = nil) {
        var u = uniforms
        let guide = encodeGuide(cb, source: source, uniforms: &u, width: Int(u.viewport.z), height: Int(u.viewport.w),
                                temporalKey: temporalKey)
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(source, index: 0)
        enc.setTexture(guide, index: 1)
        enc.setTexture(destination, index: 2)
        enc.setBytes(&u, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("gradeKernel"), width: destination.width, height: destination.height)
        enc.endEncoding()
    }

    // MARK: Scopes, nits picker, crop detection, reference histograms

    struct Scopes {
        var waveform: [UInt32]   // SCOPE_W x SCOPE_H, rows on the PQ scale (row 0 = black)
        var cie: [UInt32]        // CIE_N x CIE_N over x 0...0.8, y 0...0.9
    }

    func scopes(_ texture: MTLTexture, uniforms: GradeUniforms) -> Scopes {
        let gw = 768, gh = max(2, 768 * texture.height / max(1, texture.width))
        let wf = ctx.device.makeBuffer(length: Int(SCOPE_W * SCOPE_H) * 4, options: .storageModeShared)!
        let cie = ctx.device.makeBuffer(length: Int(CIE_N * CIE_N) * 4, options: .storageModeShared)!
        memset(wf.contents(), 0, wf.length)
        memset(cie.contents(), 0, cie.length)
        var u = uniforms
        u.viewport = SIMD4<Float>(0, 0, Float(gw), Float(gh))
        var grid = SIMD2<UInt32>(UInt32(gw), UInt32(gh))
        let cb = ctx.queue.makeCommandBuffer()!
        let guide = encodeGuide(cb, source: texture, uniforms: &u, width: gw, height: gh)
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(texture, index: 0)
        enc.setTexture(guide, index: 1)
        enc.setBytes(&u, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        enc.setBuffer(wf, offset: 0, index: 1)
        enc.setBuffer(cie, offset: 0, index: 2)
        enc.setBytes(&grid, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        ctx.dispatch2D(enc, ctx.pipeline("scopeKernel"), width: gw, height: gh)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Scopes(waveform: Array(UnsafeBufferPointer(start: wf.contents().bindMemory(to: UInt32.self, capacity: Int(SCOPE_W * SCOPE_H)),
                                                          count: Int(SCOPE_W * SCOPE_H))),
                      cie: Array(UnsafeBufferPointer(start: cie.contents().bindMemory(to: UInt32.self, capacity: Int(CIE_N * CIE_N)),
                                                     count: Int(CIE_N * CIE_N))))
    }

    /// Graded nits at one point of the picture (uv inside the image, 0...1).
    func probe(_ texture: MTLTexture, uniforms: GradeUniforms, at point: SIMD2<Float>) -> SIMD4<Float> {
        var u = uniforms
        u.viewport = SIMD4<Float>(0, 0, 1024, Float(max(2, 1024 * texture.height / max(1, texture.width))))
        let out = ctx.device.makeBuffer(length: 16, options: .storageModeShared)!
        var uv = point
        let cb = ctx.queue.makeCommandBuffer()!
        let guide = encodeGuide(cb, source: texture, uniforms: &u, width: Int(u.viewport.z), height: Int(u.viewport.w))
        let enc = cb.makeComputeCommandEncoder()!
        let pso = ctx.pipeline("probeKernel")
        enc.setComputePipelineState(pso)
        enc.setTexture(texture, index: 0)
        enc.setTexture(guide, index: 1)
        enc.setBytes(&u, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        enc.setBuffer(out, offset: 0, index: 1)
        enc.setBytes(&uv, length: 8, index: 2)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return out.contents().load(as: SIMD4<Float>.self)
    }

    /// Brightest encoded value per row and per column, accumulated into the given arrays.
    func rowColMax(_ texture: MTLTexture, rows: inout [UInt32], cols: inout [UInt32]) {
        let r = ctx.device.makeBuffer(length: texture.height * 4, options: .storageModeShared)!
        let c = ctx.device.makeBuffer(length: texture.width * 4, options: .storageModeShared)!
        memset(r.contents(), 0, r.length)
        memset(c.contents(), 0, c.length)
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(texture, index: 0)
        enc.setBuffer(r, offset: 0, index: 0)
        enc.setBuffer(c, offset: 0, index: 1)
        ctx.dispatch2D(enc, ctx.pipeline("rowColMaxKernel"), width: texture.width, height: texture.height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let rp = r.contents().bindMemory(to: UInt32.self, capacity: texture.height)
        let cp = c.contents().bindMemory(to: UInt32.self, capacity: texture.width)
        if rows.count != texture.height { rows = [UInt32](repeating: 0, count: texture.height) }
        if cols.count != texture.width { cols = [UInt32](repeating: 0, count: texture.width) }
        for i in 0..<texture.height { rows[i] = max(rows[i], rp[i]) }
        for i in 0..<texture.width { cols[i] = max(cols[i], cp[i]) }
    }

    /// log2(nits) histogram (NITS_BINS bins over 0.01...10000 nits). `graded` = our output; otherwise the
    /// source decoded straight to display light (for a PQ reference release).
    func nitsHistogram(_ texture: MTLTexture, uniforms: GradeUniforms, graded: Bool) -> [UInt32] {
        let gw = 640, gh = max(2, 640 * texture.height / max(1, texture.width))
        let hist = ctx.device.makeBuffer(length: Int(NITS_BINS) * 4, options: .storageModeShared)!
        memset(hist.contents(), 0, hist.length)
        var u = uniforms
        u.viewport = SIMD4<Float>(0, 0, Float(gw), Float(gh))
        var gm = SIMD3<UInt32>(UInt32(gw), UInt32(gh), graded ? 0 : 1)
        let cb = ctx.queue.makeCommandBuffer()!
        let guide = encodeGuide(cb, source: texture, uniforms: &u, width: gw, height: gh)
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(texture, index: 0)
        enc.setTexture(guide, index: 1)
        enc.setBytes(&u, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        enc.setBuffer(hist, offset: 0, index: 1)
        enc.setBytes(&gm, length: MemoryLayout<SIMD3<UInt32>>.stride, index: 2)
        ctx.dispatch2D(enc, ctx.pipeline("nitsHistogramKernel"), width: gw, height: gh)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: hist.contents().bindMemory(to: UInt32.self, capacity: Int(NITS_BINS)),
                                         count: Int(NITS_BINS)))
    }

    /// Packs encoded RGB into a biplanar Y'CbCr pixel buffer (x420, 420v or x422).
    func encodePack(_ cb: MTLCommandBuffer, rgb: MTLTexture, into pixelBuffer: CVPixelBuffer,
                    matrixKr: Float, matrixKb: Float) -> [AnyObject] {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let tenBit = format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let is422 = format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        guard let lumaPair = ctx.texture(from: pixelBuffer, format: tenBit ? .r16Unorm : .r8Unorm, plane: 0),
              let chromaPair = ctx.texture(from: pixelBuffer, format: tenBit ? .rg16Unorm : .rg8Unorm, plane: 1) else { return [] }
        let (luma, l) = lumaPair
        let (chroma, c) = chromaPair
        var p = PackUniforms(kr: matrixKr, kb: matrixKb, width: Int32(rgb.width), height: Int32(rgb.height),
                             bits: tenBit ? 10 : 8, chroma: is422 ? 1 : 0, pad0: 0, pad1: 0)
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(rgb, index: 0)
        enc.setTexture(luma, index: 1)
        enc.setTexture(chroma, index: 2)
        enc.setBytes(&p, length: MemoryLayout<PackUniforms>.stride, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline(is422 ? "pack422Kernel" : "pack420Kernel"),
                       width: chroma.width, height: chroma.height)
        enc.endEncoding()
        return [l, c]
    }

    /// 16-bit 4:4:4 Y'CbCr for ProRes 4444 XQ (12-bit path).
    func encodePackY416(_ cb: MTLCommandBuffer, rgb: MTLTexture, into pixelBuffer: CVPixelBuffer,
                        matrixKr: Float, matrixKb: Float) -> [AnyObject] {
        guard let pair = ctx.texture(from: pixelBuffer, format: .rgba16Unorm) else { return [] }
        let (dst, d) = pair
        var p = PackUniforms(kr: matrixKr, kb: matrixKb, width: Int32(rgb.width), height: Int32(rgb.height),
                             bits: 16, chroma: 2, pad0: 0, pad1: 0)
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(rgb, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&p, length: MemoryLayout<PackUniforms>.stride, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("packY416Kernel"), width: rgb.width, height: rgb.height)
        enc.endEncoding()
        return [d]
    }

    /// Planar 10/12-bit Y'CbCr into shared buffers for the software encoders (y4m).
    func encodePackPlanar(_ cb: MTLCommandBuffer, rgb: MTLTexture, planes: PlanarFrame,
                          matrixKr: Float, matrixKb: Float) {
        var p = PackUniforms(kr: matrixKr, kb: matrixKb, width: Int32(planes.width), height: Int32(planes.height),
                             bits: Int32(planes.bits), chroma: Int32(planes.chroma.rawValue), pad0: 0, pad1: 0)
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(rgb, index: 0)
        enc.setBytes(&p, length: MemoryLayout<PackUniforms>.stride, index: 0)
        enc.setBuffer(planes.y, offset: 0, index: 1)
        enc.setBuffer(planes.cb, offset: 0, index: 2)
        enc.setBuffer(planes.cr, offset: 0, index: 3)
        ctx.dispatch2D(enc, ctx.pipeline("packPlanarKernel"), width: planes.chromaWidth, height: planes.chromaHeight)
        enc.endEncoding()
    }

    // MARK: Analysis & measurement

    func analyze(_ texture: MTLTexture, uniforms: GradeUniforms, gridWidth: Int) -> FrameStats {
        let gw = gridWidth, gh = max(2, gridWidth * texture.height / max(1, texture.width))
        memset(histBuffer.contents(), 0, histBuffer.length)
        memset(statsBuffer.contents(), 0, statsBuffer.length)
        memset(thumbBuffer.contents(), 0, thumbBuffer.length)
        var u = uniforms
        var grid = SIMD2<UInt32>(UInt32(gw), UInt32(gh))
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(texture, index: 0)
        enc.setBytes(&u, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        enc.setBuffer(histBuffer, offset: 0, index: 1)
        enc.setBuffer(statsBuffer, offset: 0, index: 2)
        enc.setBytes(&grid, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        enc.setBuffer(thumbBuffer, offset: 0, index: 4)
        ctx.dispatch2D(enc, ctx.pipeline("analyzeKernel"), width: gw, height: gh)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let h = histBuffer.contents().bindMemory(to: UInt32.self, capacity: Int(HIST_BINS))
        let s = statsBuffer.contents().bindMemory(to: UInt32.self, capacity: 8)
        let cells = Int(THUMB_W * THUMB_H)
        let t = thumbBuffer.contents().bindMemory(to: UInt32.self, capacity: cells)
        let perCell = Float(gw * gh) / Float(cells) * 1000
        return FrameStats(histogram: Array(UnsafeBufferPointer(start: h, count: Int(HIST_BINS))),
                          count: s[0], skin: s[1], chromaSum: s[2],
                          thumbnail: (0..<cells).map { Float(t[$0]) / perCell })
    }

    /// Non-blocking analysis: several frames can be in flight on the GPU while the next ones decode.
    func analyzeAsync(_ texture: MTLTexture, uniforms: GradeUniforms, gridWidth: Int) async -> FrameStats {
        let gw = gridWidth, gh = max(2, gridWidth * texture.height / max(1, texture.width))
        let hist = ctx.device.makeBuffer(length: Int(HIST_BINS) * 4, options: .storageModeShared)!
        let stats = ctx.device.makeBuffer(length: 8 * 4, options: .storageModeShared)!
        let cells = Int(THUMB_W * THUMB_H)
        let thumb = ctx.device.makeBuffer(length: cells * 4, options: .storageModeShared)!
        var u = uniforms
        var grid = SIMD2<UInt32>(UInt32(gw), UInt32(gh))
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(texture, index: 0)
        enc.setBytes(&u, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        enc.setBuffer(hist, offset: 0, index: 1)
        enc.setBuffer(stats, offset: 0, index: 2)
        enc.setBytes(&grid, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        enc.setBuffer(thumb, offset: 0, index: 4)
        ctx.dispatch2D(enc, ctx.pipeline("analyzeKernel"), width: gw, height: gh)
        enc.endEncoding()
        await cb.commitAndWait()
        let h = hist.contents().bindMemory(to: UInt32.self, capacity: Int(HIST_BINS))
        let s = stats.contents().bindMemory(to: UInt32.self, capacity: 8)
        let t = thumb.contents().bindMemory(to: UInt32.self, capacity: cells)
        let perCell = Float(gw * gh) / Float(cells) * 1000
        return FrameStats(histogram: Array(UnsafeBufferPointer(start: h, count: Int(HIST_BINS))),
                          count: s[0], skin: s[1], chromaSum: s[2],
                          thumbnail: (0..<cells).map { Float(t[$0]) / perCell })
    }

    /// Graded light level of one frame (max and average of max(R,G,B) in nits), using the export grade.
    func measure(_ texture: MTLTexture, uniforms: GradeUniforms, gridWidth: Int) -> (max: Float, avg: Float) {
        let gw = gridWidth, gh = max(2, gridWidth * texture.height / max(1, texture.width))
        memset(statsBuffer.contents(), 0, statsBuffer.length)
        var u = uniforms
        u.viewport = SIMD4<Float>(0, 0, Float(gw), Float(gh))
        var grid = SIMD2<UInt32>(UInt32(gw), UInt32(gh))
        let cb = ctx.queue.makeCommandBuffer()!
        let guide = encodeGuide(cb, source: texture, uniforms: &u, width: gw, height: gh)
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(texture, index: 0)
        enc.setTexture(guide, index: 1)
        enc.setBytes(&u, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        enc.setBuffer(statsBuffer, offset: 0, index: 2)
        enc.setBytes(&grid, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        ctx.dispatch2D(enc, ctx.pipeline("measureKernel"), width: gw, height: gh)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let s = statsBuffer.contents().bindMemory(to: UInt32.self, capacity: 8)
        let count = Float(gw * gh)
        return (Float(bitPattern: s[3]), Float(s[4]) / count)
    }

    // MARK: LUT baking

    /// Evaluates the global grade on an N³ lattice. Returns RGB triples, red fastest (.cube order).
    func bakeLUT(uniforms: GradeUniforms, size: Int) -> [SIMD3<Float>] {
        var u = uniforms
        var n = UInt32(size)
        let count = size * size * size
        let buffer = ctx.device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)!
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        let pso = ctx.pipeline("lutKernel")
        enc.setComputePipelineState(pso)
        enc.setBytes(&u, length: MemoryLayout<GradeUniforms>.stride, index: 0)
        enc.setBuffer(buffer, offset: 0, index: 1)
        enc.setBytes(&n, length: 4, index: 2)
        enc.dispatchThreads(MTLSize(width: size, height: size, depth: size),
                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 4))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let p = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        return (0..<count).map { SIMD3(p[$0].x, p[$0].y, p[$0].z) }
    }

    // MARK: Content test

    struct ContentFrameStats {
        var detail: Float, edgeDensity: Float, flatShare: Float, grain: Float, colorfulness: Float
    }

    func contentStats(_ texture: MTLTexture, gridWidth: Int = 960) async -> ContentFrameStats {
        let gw = gridWidth, gh = max(16, gridWidth * texture.height / max(1, texture.width))
        let out = ctx.device.makeBuffer(length: 32, options: .storageModeShared)!
        memset(out.contents(), 0, 32)
        var grid = SIMD2<UInt32>(UInt32(gw), UInt32(gh))
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(texture, index: 0)
        enc.setBuffer(out, offset: 0, index: 0)
        enc.setBytes(&grid, length: 8, index: 1)
        ctx.dispatch2D(enc, ctx.pipeline("contentStatsKernel"), width: gw / 8, height: gh / 8)
        enc.endEncoding()
        await cb.commitAndWait()
        let v = out.contents().bindMemory(to: Float.self, capacity: 8)
        let px = max(1, v[6]), blocks = max(1, v[5])
        return ContentFrameStats(detail: v[0] / px, edgeDensity: v[1] / px, flatShare: v[2] / blocks,
                                 grain: v[4] > 0 ? v[3] / v[4] : 0, colorfulness: v[7] / px)
    }

    // MARK: Interpolation evaluation helpers

    /// Renders any source (log, SDR, PQ, HLG) to a common PQ / BT.2020 / 10,000-nit space at `width`,
    /// so an original and an interpolated (even regraded) version can be compared pixel for pixel.
    func comparable(_ texture: MTLTexture, color: SourceColor, width: Int) -> MTLTexture {
        let h = max(16, (width * texture.height / max(1, texture.width)) & ~7)
        let w = width & ~7
        let dst = ctx.makeTexture(width: w, height: h, format: .rgba32Float)
        var p = GradeParams.neutral
        p.passthrough = true
        let u = UniformBuilder.make(source: color, params: p, target: OutputTarget(kind: .hdr10, peakNits: 10000),
                                    sceneExposureStops: 0, viewport: SIMD4<Float>(0, 0, Float(w), Float(h)))
        let cb = ctx.queue.makeCommandBuffer()!
        encodeGrade(cb, source: texture, destination: dst, uniforms: u)
        cb.commit()
        cb.waitUntilCompleted()
        return dst
    }

    /// PSNR (dB, PQ domain) and SSIM (luma) between two comparable renders.
    func compare(_ a: MTLTexture, _ b: MTLTexture) -> (psnr: Float, ssim: Float) {
        let out = ctx.device.makeBuffer(length: 16, options: .storageModeShared)!
        memset(out.contents(), 0, 16)
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(a, index: 0)
        enc.setTexture(b, index: 1)
        enc.setBuffer(out, offset: 0, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("compareKernel"), width: a.width / 8, height: a.height / 8)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let v = out.contents().bindMemory(to: Float.self, capacity: 4)
        let n = max(1, v[2])
        let mse = max(1e-10, v[0] / n)
        return (10 * log10f(1 / mse), v[1] / n)
    }

    /// Mean luma error of `mid` vs a cross-fade of a/b, vs the nearer of a/b, and the a/b difference (motion).
    func blendErrors(_ a: MTLTexture, _ b: MTLTexture, _ mid: MTLTexture, t: Float) -> (vsBlend: Float, vsNearest: Float, motion: Float) {
        let out = ctx.device.makeBuffer(length: 16, options: .storageModeShared)!
        memset(out.contents(), 0, 16)
        var tt = t
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(a, index: 0)
        enc.setTexture(b, index: 1)
        enc.setTexture(mid, index: 2)
        enc.setBytes(&tt, length: 4, index: 0)
        enc.setBuffer(out, offset: 0, index: 1)
        ctx.dispatch2D(enc, ctx.pipeline("blendErrorKernel"), width: mid.width, height: mid.height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let v = out.contents().bindMemory(to: Float.self, capacity: 4)
        let n = max(1, v[3])
        return (v[0] / n, v[1] / n, v[2] / n)
    }

    func pqHistogram(_ tex: MTLTexture) -> [UInt32] {
        let buf = ctx.device.makeBuffer(length: 256 * 4, options: .storageModeShared)!
        memset(buf.contents(), 0, buf.length)
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(tex, index: 0)
        enc.setBuffer(buf, offset: 0, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("pqLumaHistKernel"), width: tex.width, height: tex.height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return Array(UnsafeBufferPointer(start: buf.contents().bindMemory(to: UInt32.self, capacity: 256), count: 256))
    }

    func toneMatch(_ tex: MTLTexture, curve: [Float]) -> MTLTexture {
        let dst = ctx.makeTexture(width: tex.width, height: tex.height, format: .rgba32Float)
        var c = curve
        let cb = ctx.queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setTexture(tex, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&c, length: 256 * 4, index: 0)
        ctx.dispatch2D(enc, ctx.pipeline("toneMatchKernel"), width: tex.width, height: tex.height)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return dst
    }

    // MARK: Thumbnails

    func thumbnail(_ texture: MTLTexture, uniforms: GradeUniforms, width: Int) -> CGImage? {
        let h = max(2, width * texture.height / max(1, texture.width))
        let dst = ctx.makeTexture(width: width, height: h, format: .rgba16Float)
        var u = uniforms
        u.viewport = SIMD4<Float>(0, 0, Float(width), Float(h))
        let cb = ctx.queue.makeCommandBuffer()!
        encodeGrade(cb, source: texture, destination: dst, uniforms: u)
        cb.commit()
        cb.waitUntilCompleted()
        guard let ci = CIImage(mtlTexture: dst, options: [.colorSpace: CGColorSpace(name: CGColorSpace.itur_709)!]) else { return nil }
        let flipped = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ci.extent.height))
        return ctx.ciContext.createCGImage(flipped, from: flipped.extent)
    }
}
