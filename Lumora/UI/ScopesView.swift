import SwiftUI

/// HDR scopes: luminance waveform on the PQ scale with nit markers, and a CIE 1931 xy plot with
/// Rec.709, P3 and Rec.2020 triangles.
struct ScopesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if let s = model.scopes {
                ZStack(alignment: .topLeading) {
                    if let img = Self.image(s.waveform, width: Int(SCOPE_W), height: Int(SCOPE_H), flipY: true) {
                        Image(decorative: img, scale: 1).resizable().interpolation(.medium)
                    }
                    GeometryReader { g in
                        ForEach([(1.0, "1"), (100.0, "100"), (203.0, "203"), (1000.0, "1000"), (4000.0, "4000")], id: \.0) { nits, label in
                            let y = g.size.height * (1 - CGFloat(TransferMath.nitsToPQ(Float(nits))))
                            Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y)) }
                                .stroke(.white.opacity(0.25), lineWidth: 0.5)
                            Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)).position(x: 16, y: y - 6)
                        }
                    }
                }
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                ZStack {
                    if let img = Self.image(s.cie, width: Int(CIE_N), height: Int(CIE_N), flipY: true) {
                        Image(decorative: img, scale: 1).resizable().interpolation(.medium)
                    }
                    Canvas { ctx, size in
                        for (gamut, color) in [(Gamut.rec709, Color.white), (.p3d65, .yellow), (.rec2020, .cyan)] {
                            let p = gamut.primaries
                            func pt(_ c: SIMD2<Double>) -> CGPoint {
                                CGPoint(x: size.width * c.x / 0.8, y: size.height * (1 - c.y / 0.9))
                            }
                            var path = Path()
                            path.move(to: pt(p.r)); path.addLine(to: pt(p.g)); path.addLine(to: pt(p.b)); path.closeSubpath()
                            ctx.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 1)
                        }
                    }
                }
                .aspectRatio(0.8 / 0.9, contentMode: .fit)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                ProgressView()
            }
        }
        .onChange(of: model.renderToken) { model.refreshScopes() }
    }

    /// Log-scaled density image (green phosphor look).
    static func image(_ counts: [UInt32], width: Int, height: Int, flipY: Bool) -> CGImage? {
        let peak = log1p(Float(counts.max() ?? 1))
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let src = (flipY ? (height - 1 - y) : y) * width + x
                let v = UInt8(min(255, log1p(Float(counts[src])) / max(peak, 1e-3) * 255))
                let i = (y * width + x) * 4
                px[i] = v / 3; px[i + 1] = v; px[i + 2] = v / 3; px[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
