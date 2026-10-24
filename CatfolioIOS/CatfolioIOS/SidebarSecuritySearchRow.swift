import SwiftUI

/// A compact identity and quote, in the security's listing currency.
struct SidebarSecuritySearchRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let result: MarketSecurityResult
    let entry: WatchlistEntry
    let quote: WatchlistQuote?
    let isHeld: Bool

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    identity
                    metrics
                }
            } else {
                HStack(spacing: 12) {
                    identity
                    Spacer(minLength: 0)
                    metrics
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .contentShape(Rectangle())
        .researchLayoutFrame("sidebar-search.row.\(result.id)")
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.text("打开个股"))
    }

    private var identity: some View {
        HStack(spacing: 10) {
            AssetLogo(ticker: result.ticker, logoSymbol: entry.logoSymbol, size: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) { ticker; venue }
                    VStack(alignment: .leading, spacing: 3) { ticker; venue }
                }
                Text(CompanyNameCatalog.displayName(ticker: result.ticker, fallback: result.name))
                    .appText(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .researchLayoutFrame("sidebar-search.identity.\(result.id)")
    }

    private var ticker: some View {
        Text(result.ticker)
            .appText(.callout, weight: .semibold)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(result.ticker + (isHeld ? ", " + L10n.text("已持有") : ""))
    }

    private var venue: some View {
        Text([result.venue, entry.currency].filter { !$0.isEmpty }.joined(separator: " · "))
            .appText(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var metrics: some View {
        SecuritySearchQuoteMetrics(quote: quote)
            .researchLayoutFrame("sidebar-search.metrics.\(result.id)")
    }
}

struct SecuritySearchQuoteMetrics: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    let quote: WatchlistQuote?

    var body: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
            Text(quote.map { $0.price.formatted(.number.precision(.fractionLength(2))) } ?? "—")
                .appNumber(.callout, weight: .semibold)
            Text(quote?.changePercent.map { DisplayFormat.percent($0, signed: $0 != 0) } ?? "—")
                .appNumber(.callout, weight: .semibold)
                .foregroundStyle(changeColor)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var changeColor: Color {
        guard let change = quote?.changePercent, change != 0 else { return .secondary }
        return change > 0 ? CatfolioTheme.gain(for: colorScheme) : CatfolioTheme.loss(for: colorScheme)
    }
}
