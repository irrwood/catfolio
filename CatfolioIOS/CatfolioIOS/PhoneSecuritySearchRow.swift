import SwiftUI

/// Two text lines on iPhone: code and venue beside the price, then company
/// name beside the change. Long labels truncate instead of adding a third line.
struct PhoneSecuritySearchRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let result: MarketSecurityResult
    let entry: WatchlistEntry
    let quote: WatchlistQuote?
    let isHeld: Bool

    var body: some View {
        HStack(spacing: SettingsTemplate.iconSpacing) {
            AssetLogo(ticker: result.ticker, logoSymbol: entry.logoSymbol, size: 36)
                .researchLayoutFrame("phone-search.logo.\(result.id)")
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                identity
                metrics
            }
        }
        .contentShape(Rectangle())
        .researchLayoutFrame("phone-search.row.\(result.id)")
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.text("打开个股"))
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(result.ticker)
                    .appText(.subheading, weight: .medium)
                    .layoutPriority(1)
                    .accessibilityLabel(result.ticker + (isHeld ? ", " + L10n.text("已持有") : ""))
                Text([result.venue, entry.currency].filter { !$0.isEmpty }.joined(separator: " · "))
                    .appText(.caption)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .researchLayoutFrame("phone-search.venue.\(result.id)")
                if isHeld {
                    heldBadge
                }
            }
            .researchLayoutFrame("phone-search.header.\(result.id)")
            Text(CompanyNameCatalog.displayName(ticker: result.ticker, fallback: entry.name))
                .appText(.label)
                .foregroundStyle(SettingsTemplate.secondaryText)
                .researchLayoutFrame("phone-search.name.\(result.id)")
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .researchLayoutFrame("phone-search.identity.\(result.id)")
    }

    private var heldBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .appText(.caption)
            .foregroundStyle(SettingsTemplate.secondaryText)
            .fixedSize(horizontal: true, vertical: false)
            .researchLayoutFrame("phone-search.held.\(result.id)")
            .accessibilityHidden(true)
    }

    private var metrics: some View {
        VStack(alignment: .trailing, spacing: SettingsTemplate.subtitleSpacing) {
            Text(quote.map { $0.price.formatted(.number.precision(.fractionLength(2))) } ?? "—")
                .appNumber(.subheading, weight: .medium)
                .researchLayoutFrame("phone-search.price.\(result.id)")
            Text(quote?.changePercent.map { DisplayFormat.percent($0, signed: $0 != 0) } ?? "—")
                .appNumber(.label, weight: TypeScale.label.weight)
                .foregroundStyle(changeColor)
                .researchLayoutFrame("phone-search.change.\(result.id)")
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .researchLayoutFrame("phone-search.metrics.\(result.id)")
    }

    private var changeColor: Color {
        guard let change = quote?.changePercent, change != 0 else { return .secondary }
        return change > 0 ? CatfolioTheme.gain(for: colorScheme) : CatfolioTheme.loss(for: colorScheme)
    }
}
