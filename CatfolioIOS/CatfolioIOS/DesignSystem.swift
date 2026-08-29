import SwiftUI

enum CatfolioStyle {
    static let green = Color(red: 47 / 255, green: 138 / 255, blue: 62 / 255)
    static let red = Color(red: 228 / 255, green: 0, blue: 20 / 255)
    static let blue = Color(red: 112 / 255, green: 140 / 255, blue: 255 / 255)
    static let cardRadius: CGFloat = 20
    static let controlRadius: CGFloat = 12
}

struct ContentCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(20)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: CatfolioStyle.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CatfolioStyle.cardRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 1)
            }
    }
}

extension View {
    func contentCard() -> some View {
        modifier(ContentCard())
    }

    @ViewBuilder
    func catfolioTabBarBehavior() -> some View {
        if #available(iOS 26.0, *) {
            self.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}

struct GlassChoiceBar: View {
    let choices: [String]
    @Binding var selection: String

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(choices, id: \.self) { choice in
                        Button(choice) { selection = choice }
                            .buttonStyle(.glass(glass(for: choice)))
                            .font(.caption.weight(.bold))
                            .accessibilityAddTraits(selection == choice ? .isSelected : [])
                    }
                }
            }
        } else {
            HStack(spacing: 4) {
                ForEach(choices, id: \.self) { choice in
                    Button(choice) { selection = choice }
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(selection == choice ? CatfolioStyle.blue.opacity(0.18) : .clear, in: Capsule())
                }
            }
            .padding(4)
            .background(.thinMaterial, in: Capsule())
        }
    }

    @available(iOS 26.0, *)
    private func glass(for choice: String) -> Glass {
        selection == choice
            ? .regular.tint(CatfolioStyle.blue.opacity(0.28)).interactive()
            : .regular.interactive()
    }
}

struct GlassIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass(.regular.interactive()))
            .accessibilityLabel(accessibilityLabel)
        } else {
            Button(action: action) {
                Image(systemName: systemImage)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel(accessibilityLabel)
        }
    }
}

struct GlassPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                button
                    .buttonStyle(.glassProminent)
            } else {
                button
                    .buttonStyle(.borderedProminent)
            }
        }
        .disabled(isDisabled)
    }

    private var button: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.body.weight(.semibold))
    }
}

struct AssetLogo: View {
    let ticker: String
    let logoSymbol: String?

    var body: some View {
        Text(String(ticker.prefix(1)))
            .font(.headline.weight(.heavy))
            .foregroundStyle(.secondary)
        .frame(width: 42, height: 42)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

enum DisplayFormat {
    static func money(_ value: Double, currency: String = "USD", signed: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency == "GBX" ? "GBP" : currency
        formatter.maximumFractionDigits = abs(value) >= 1_000 ? 0 : 2
        let adjusted = currency == "GBX" ? value / 100 : value
        let text = formatter.string(from: NSNumber(value: abs(adjusted))) ?? "\(adjusted)"
        guard signed else { return text }
        return "\(value >= 0 ? "+" : "-")\(text)"
    }

    static func percent(_ value: Double, signed: Bool = true) -> String {
        "\(signed && value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    static func ratioPercent(_ value: Double?) -> String {
        guard let value else { return "暂无" }
        return percent(value * 100)
    }
}
