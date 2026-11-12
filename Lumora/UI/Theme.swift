import SwiftUI
import CoreGraphics

/// Lumora's visual language: a grading suite. Neutral grey surround (no tinted near-black) so the picture is
/// judged correctly, quiet chrome, wide "expanded" headings, and colour used only where it carries meaning.
/// The one bold element: real HDR light in the scene strip, which glows above SDR white on XDR displays.
enum Theme {
    static let surround = Color(red: 0.157, green: 0.157, blue: 0.157)   // neutral ~16% grey, D65
    static let rail = Color(red: 0.188, green: 0.188, blue: 0.188)
    static let hairline = Color.white.opacity(0.08)
    static let signal = Color(red: 0.42, green: 0.79, blue: 0.86)      // controls and focus
    static let pass = Color(red: 0.38, green: 0.79, blue: 0.55)
    static let marginal = Color(red: 0.92, green: 0.72, blue: 0.32)
    static let fail = Color(red: 0.90, green: 0.41, blue: 0.34)

    static func heading(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .semibold).width(.expanded) }
    static func figure(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .semibold).width(.expanded).monospacedDigit() }
    static let body = Font.system(size: 12)
    static let note = Font.system(size: 11)

    static func vmafColor(_ score: Double, target: Double) -> Color {
        score >= target ? pass : (score >= target - 3 ? marginal : fail)
    }
}

/// A titled inspector section, separated by a hairline rather than boxed in a card.
struct InspectorSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.heading())
                Spacer()
                if let trailing { Text(trailing).font(Theme.note).foregroundStyle(.secondary) }
            }
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Slider with a live value, a tick at its default, and double-click on the label to reset.
struct ParamSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var defaultValue: Float? = nil
    var format = "%.2f"
    var unit = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(Theme.body)
                    .onTapGesture(count: 2) { if let d = defaultValue { value = d } }
                    .help(defaultValue == nil ? "" : "Double-click to reset")
                Spacer()
                Text(String(format: format, value) + (unit.isEmpty ? "" : " \(unit)"))
                    .font(Theme.body.monospacedDigit()).foregroundStyle(.secondary)
            }
            ZStack(alignment: .leading) {
                if let d = defaultValue {
                    GeometryReader { g in
                        Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 6)
                            .offset(x: g.size.width * CGFloat((d - range.lowerBound) / (range.upperBound - range.lowerBound)), y: 12)
                    }
                }
                Slider(value: $value, in: range).controlSize(.small)
            }
            .frame(height: 22)
        }
    }
}

struct Metric: View {
    let value: String
    var unit: String = ""
    let caption: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Theme.figure(20)).foregroundStyle(color)
                if !unit.isEmpty { Text(unit).font(Theme.note).foregroundStyle(.secondary) }
            }
            Text(caption).font(Theme.note).foregroundStyle(.secondary)
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

/// A one-pixel-tall image in the PQ colour space: SwiftUI displays it with real HDR headroom on XDR screens.
enum HDRStrip {
    static func image(nits: [Float]) -> CGImage? {
        let w = max(1, nits.count)
        var px = [UInt16](repeating: 0, count: w * 4)
        for (i, n) in nits.enumerated() {
            let v = UInt16(min(1, max(0, TransferMath.nitsToPQ(n))) * 65535)
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 65535
        }
        guard let space = CGColorSpace(name: CGColorSpace.itur_2100_PQ),
              let provider = CGDataProvider(data: Data(bytes: px, count: px.count * 2) as CFData) else { return nil }
        return CGImage(width: w, height: 1, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
