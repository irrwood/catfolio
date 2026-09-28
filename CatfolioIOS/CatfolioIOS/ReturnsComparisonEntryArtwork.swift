import SwiftUI

/// The two comparison entry surfaces from Figma 496:23834.
struct ReturnsComparisonEntryArtwork: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let isCycle: Bool
    private var isDay: Bool { colorScheme == .light }
    private var dayInk: Color { isCycle ? Color(red: 0.53, green: 0.10, blue: 0.25) : Color(red: 0.39, green: 0.27, blue: 0.04) }
    private var dayAccent: Color { isCycle ? Color(red: 0.76, green: 0.23, blue: 0.39) : Color(red: 0.58, green: 0.40, blue: 0.06) }
    private var prefix: String { isCycle ? "EntryCycle" : "EntryReturn" }
    private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(prefix + "Icon").renderingMode(.template).resizable().scaledToFit().frame(width: 20, height: 20)
                Spacer()
                Image("SettingsChevron").foregroundStyle(isDay ? dayInk.opacity(0.55) : .white.opacity(0.5))
            }
            .foregroundStyle(isDay ? dayInk : .white)
            .frame(height: 24)
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 4) {
                Text(isCycle ? "CYCLE" : "RETURN")
                    .font(Typography.text(size: 14, weight: .bold))
                    .tracking(0.56)
                    .foregroundStyle(isDay ? dayAccent : .white.opacity(0.4))
                    .blendMode(isDay ? .normal : .plusLighter)
                Text(title)
                    .font(Typography.text(size: 20, weight: .semibold))
                    .foregroundStyle(isDay ? dayInk : (isCycle ? Color.white : Color.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding([.horizontal, .top], 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 173)
        .background {
            GeometryReader { proxy in
                illustration
                    .frame(width: 173, height: 173)
                    .scaleEffect(x: proxy.size.width / 173, y: 1, anchor: .topLeading)
            }
        }
        .clipShape(shape)
        .modifier(EntryGlass())
        .contentShape(shape)
    }

    private var illustration: some View {
        ZStack(alignment: .topLeading) {
            if isDay {
                LinearGradient(colors: isCycle
                    ? [Color(red: 1, green: 0.66, blue: 0.75), Color(red: 1, green: 0.88, blue: 0.91)]
                    : [Color(red: 0.96, green: 0.79, blue: 0.32), Color(red: 1, green: 0.94, blue: 0.74)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Color.black
                (isCycle ? Color(red: 227 / 255, green: 0, blue: 69 / 255)
                         : Color(red: 198 / 255, green: 155 / 255, blue: 0)).opacity(0.6)
            }
            if isCycle { stripes }
            asset("Back", width: 188, height: 156.955, x: -8, y: 35)
            if !isCycle { glow }
            asset("Middle", width: 188.5, height: 141.028, x: -8, y: 50.952)
            asset("Front", width: 188.5, height: isCycle ? 112.456 : 142.214,
                  x: -8, y: isCycle ? 100.535 : 70.782)
        }
        .frame(width: 173, height: 173, alignment: .topLeading)
        .drawingGroup()
        .visualEffect { content, proxy in
            content.layerEffect(Shader(function: ShaderFunction(library: .default, name: "returnsProgressiveBlur"), arguments: [
                .float2(proxy.size), .float2(0.364, 0.587), .float2(0.147, 1), .float(18.1)
            ]), maxSampleOffset: CGSize(width: 18.1, height: 18.1))
        }
        .overlay(alignment: .topLeading) { if isCycle { glow } }
        .overlay { if !isCycle { stripes } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var glow: some View {
        asset("Glow", width: 355.6, height: 279.6, x: -163.8, y: 28.2)
            // Asset-catalog SVG rendering omits the exported SVG blur filter.
            .blur(radius: 32.9)
    }

    private func asset(_ suffix: String, width: CGFloat, height: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Image(prefix + suffix)
            .renderingMode(isDay ? .template : .original)
            .resizable()
            .foregroundStyle(dayLayerColor(suffix))
            .frame(width: width, height: height).offset(x: x, y: y)
    }

    private func dayLayerColor(_ suffix: String) -> Color {
        switch suffix {
        case "Back":
            isCycle ? Color(red: 1, green: 0.75, blue: 0.81) : Color(red: 1, green: 0.86, blue: 0.49)
        case "Middle":
            isCycle ? Color(red: 1, green: 0.89, blue: 0.92) : Color(red: 1, green: 0.95, blue: 0.79)
        default: .white
        }
    }

    @ViewBuilder private var stripes: some View {
        if isCycle {
            HStack(spacing: 0) {
                ForEach(0..<5) { index in
                    LinearGradient(colors: index.isMultiple(of: 2) ? [.white, .clear] : [.clear, .white],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .blendMode(.overlay)
            .opacity(isDay ? 0.25 : 1)
        } else {
            VStack(spacing: 0) {
                LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .white], startPoint: .leading, endPoint: .trailing)
            }
            .blendMode(.overlay)
            .opacity(isDay ? 0.25 : 1)
        }
    }

    private struct EntryGlass: ViewModifier {
        @Environment(\.colorScheme) private var colorScheme
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.glassEffect(colorScheme == .light ? .regular.interactive() : .clear.interactive(), in: RoundedRectangle(cornerRadius: 24))
            } else {
                content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
    }
}
