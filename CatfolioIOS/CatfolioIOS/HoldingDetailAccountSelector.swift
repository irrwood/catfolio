import SwiftUI
import UIKit
import Observation

struct HoldingDetailAccountSelector: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme

    @ScaledMetric(relativeTo: .subheadline) private var labelSize = 14.0
    @ScaledMetric(relativeTo: .subheadline) private var lineHeight = 16.0
    @ScaledMetric(relativeTo: .caption2) private var badgeSize = 11.0

    let options: [HoldingDetailAccountOption]
    let selectedAccountKeys: Set<String>
    let onSelectAll: () -> Void
    let onToggleAccount: (String) -> Void

    private var allAccountKeys: Set<String> {
        Set(options.map(\.id))
    }

    private var allMarketValue: Double {
        options.reduce(0) { $0 + $1.marketValue }
    }

    private var displayCurrency: String {
        options.first?.currency ?? "USD"
    }

    private var allUnrealized: Double? {
        guard options.allSatisfy({ $0.unrealized != nil }) else { return nil }
        return options.compactMap(\.unrealized).reduce(0, +)
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                accountButton(
                    id: "all",
                    title: L10n.text("All"),
                    marketValue: allMarketValue,
                    currency: displayCurrency,
                    unrealized: allUnrealized,
                    isSelected: selectedAccountKeys == allAccountKeys,
                    action: onSelectAll
                )

                ForEach(options) { option in
                    accountButton(
                        id: option.id,
                        title: conciseAccountName(L10n.accountName(option.displayName)),
                        marketValue: option.marketValue,
                        currency: option.currency,
                        unrealized: option.unrealized,
                        isSelected: selectedAccountKeys.contains(option.id),
                        action: { onToggleAccount(option.id) }
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .scrollIndicators(.hidden)
        // Only a row wider than the screen takes horizontal drags. One that
        // fits still bounced, and so caught a swipe back that began on it.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
    }

    private func accountButton(
        id: String,
        title: String,
        marketValue: Double,
        currency: String,
        unrealized: Double?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // Figma 479:6258: account name and return badge above the figures.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: labelSize, weight: .medium))
                        .tracking(0.28)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    FinancialText(HoldingDetailAccountOption.unrealizedPercent(marketValue: marketValue, unrealized: unrealized)
                        .map { DisplayFormat.percent($0) } ?? "—")
                        .font(Typography.number(size: badgeSize, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 5)
                        .frame(minHeight: 18)
                        .background(Color.primary.opacity(isSelected ? 0.10 : 0.05),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .opacity(0.40)
                        .accessibilityIdentifier("holding-detail-account-return-\(id)")
                }
                .frame(minHeight: lineHeight, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    FinancialText(DisplayFormat.money(marketValue, currency: currency, fractionDigits: 0))
                        .foregroundStyle(Color.primary.opacity(0.50))
                        .lineLimit(1)
                        .frame(height: lineHeight, alignment: .leading)
                    FinancialText(unrealized.map { DisplayFormat.money($0, currency: currency, signed: true, fractionDigits: 0) } ?? "—", isDirectional: true)
                        .foregroundStyle(Color.primary.opacity(0.20))
                        .lineLimit(1)
                        .frame(height: lineHeight, alignment: .leading)
                        .accessibilityLabel(L10n.text("未实现盈亏"))
                }
                .font(Typography.number(size: labelSize, weight: .medium))
            }
            .textCase(.uppercase)
            .foregroundStyle(CatfolioTheme.primaryText)
            .fixedSize(horizontal: true, vertical: false)
            .padding(10)
            .frame(minWidth: 128, minHeight: 74, alignment: .leading)
            .modifier(AccountGlassSurface(isSelected: isSelected, colorScheme: colorScheme))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("holding-detail-account-\(id)")
        .accessibilityLabel(
            L10n.text("\(title)，持仓市值 \(DisplayFormat.money(marketValue, currency: currency))")
        )
        .accessibilityValue(L10n.text("未实现盈亏") + " " + (unrealized.map { DisplayFormat.money($0, currency: currency, signed: true) } ?? "—"))
        .accessibilityHint(L10n.text("未实现盈亏比例") + " " +
            (HoldingDetailAccountOption.unrealizedPercent(marketValue: marketValue, unrealized: unrealized)
                .map { DisplayFormat.percent($0) } ?? "—"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The selector's place before the accounts are read: two empty cards of
    /// the same size and surface, so the figures fill in without a jump.
    static var shells: some View { Shells() }

    private struct Shells: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            HStack(spacing: 12) {
                ForEach(0..<2, id: \.self) { index in
                    Color.clear
                        .frame(width: 128, height: 74)
                        .modifier(AccountGlassSurface(isSelected: index == 0, colorScheme: colorScheme))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .accessibilityHidden(true)
        }
    }

    private func conciseAccountName(_ value: String) -> String {
        guard let component = value.components(separatedBy: "·").last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !component.isEmpty else { return value }
        return component
    }

    private struct AccountGlassSurface: ViewModifier {
        let isSelected: Bool
        let colorScheme: ColorScheme

        private var tint: Color {
            if isSelected {
                return Color(red: 0, green: 0.92, blue: 1).opacity(colorScheme == .dark ? 0.25 : 0.22)
            }
            return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05)
        }

        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content
                    .background {
                        if isSelected {
                            LinearGradient(colors: [Color.black.opacity(colorScheme == .dark ? 0.30 : 0.02), tint],
                                startPoint: .top, endPoint: .bottom)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .glassEffect(.regular.tint(isSelected ? .clear : tint).interactive(), in: .rect(cornerRadius: 16))
            } else {
                content
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .background(tint, in: RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.06), lineWidth: 0.75)
                    }
            }
        }
    }
}
