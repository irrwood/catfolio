import SwiftUI

/// The three upcoming dates on Returns. Figma 610:15179.
struct CorporateEventsCard: View {
    let holdings: [Holding]
    private let store = CorporateEventsStore.shared
    private static let limit = 3

    private var scope: CorporateCalendarHoldings { CorporateCalendarHoldings(holdings) }

    private var upcoming: [CorporateEvent] {
        let today = CorporateCalendarDay.key(Date(), calendar: .current)
        return Array(store.events(for: Set(scope.tickers)).filter { $0.date >= today }.prefix(Self.limit))
    }

    var body: some View {
        CorporateEventsCardContent(holdings: holdings, events: upcoming, isLoading: store.isLoading)
            .task(id: scope.tickers.joined(separator: ",")) { await store.load(tickers: scope.tickers) }
    }
}

/// Rendering is independent of the calendar store, so cached, loading and
/// empty states use the same card and can be checked without a network call.
struct CorporateEventsCardContent: View {
    @Environment(\.locale) private var appLocale
    let holdings: [Holding]
    let events: [CorporateEvent]
    var isLoading = false

    var body: some View {
        let scope = CorporateCalendarHoldings(holdings)
        VStack(spacing: 0) {
            NavigationLink {
                CorporateCalendarView(holdings: holdings)
            } label: {
                HStack(spacing: 12) {
                    Text(L10n.text("公司日历"))
                        .appText(.heading, weight: .medium, trimsLeading: true)
                        .foregroundStyle(CatfolioTheme.primaryText)
                    Spacer(minLength: 8)
                    if isLoading && events.isEmpty {
                        ProgressView().controlSize(.mini)
                    }
                    SettingsChevron()
                }
                .padding(.horizontal, HoldingDetailCardStyle.contentInset)
                .padding(.top, 20)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(SettingsRowButtonStyle())
            .accessibilityIdentifier("corporate-calendar.open")

            // A fixed preview of at most three dates, inside the Returns scroll view.
            if !events.isEmpty {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 {
                        CatfolioPalette.calendarSeparator.frame(height: 1)
                            .padding(.leading, HoldingDetailCardStyle.contentInset + 44 + 16)
                    }
                    CorporateEventCardRow(event: event, holding: scope.holding(event))
                }
            } else {
                Text(L10n.text(isLoading ? "加载中…" : "近期没有财报或除息"))
                    .appText(.footnote)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HoldingDetailCardStyle.contentInset)
            }
        }
        .padding(.bottom, 6)
        .padding(1)
        .holdingDetailCard()
        .clipShape(RoundedRectangle(cornerRadius: HoldingDetailCardStyle.cornerRadius, style: .continuous))
        .accessibilityIdentifier("corporate-calendar.card")
    }
}

struct CorporateEventCardAmounts {
    let total: String?
    let perShare: String?

    init(event: CorporateEvent, shares: Double) {
        total = event.incomeUSD(shares: shares).map { DisplayFormat.money($0, fractionDigits: 2) }
        if event.kind.isDividend, let amount = event.amount, let currency = event.currency {
            perShare = DisplayFormat.money(amount, currency: currency, fractionDigits: 2)
        } else {
            perShare = nil
        }
    }
}

struct CorporateEventCardRow: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var primaryLineHeight: CGFloat = 12
    @ScaledMetric(relativeTo: .footnote) private var secondaryLineHeight: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var detailHeight: CGFloat = 32
    let event: CorporateEvent
    let holding: Holding?

    var body: some View {
        let date = CorporateCalendarDay.date(event.date, calendar: .current) ?? Date()
        let amounts = CorporateEventCardAmounts(event: event, shares: holding?.shares ?? 0)
        HStack(alignment: .center, spacing: 16) {
            CorporateEventDateTile(date: date, day: Int(event.date.suffix(2)) ?? 0)
            if typeSize.isAccessibilitySize {
                accessibleDetails(amounts)
            } else {
                HStack(spacing: 10) {
                    logo
                    VStack(spacing: 6) {
                        HStack(alignment: .center, spacing: 8) {
                            companyName
                            Spacer(minLength: 0)
                            if let total = amounts.total { totalText(total) }
                        }
                        .frame(minHeight: primaryLineHeight)
                        HStack(alignment: .center, spacing: 8) {
                            eventKind
                            Spacer(minLength: 0)
                            if let perShare = amounts.perShare { perShareText(perShare) }
                        }
                        .frame(minHeight: secondaryLineHeight)
                    }
                    .frame(height: detailHeight, alignment: .top)
                }
            }
        }
        .padding(.horizontal, HoldingDetailCardStyle.contentInset)
        .padding(.vertical, 14)
        .frame(minHeight: 72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription(date: date, amounts: amounts))
        .accessibilityIdentifier("corporate-calendar.event.\(event.id)")
    }

    private var logo: some View {
        AssetLogo(ticker: event.ticker, logoSymbol: holding?.logoSymbol, size: 44, cornerRadius: 12)
    }

    private var companyName: some View {
        Text(holding?.shortName ?? event.ticker)
            .appText(.body, weight: .semibold, trimsLeading: true)
            .foregroundStyle(CatfolioTheme.primaryText)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
    }

    private var eventKind: some View {
        Text(event.kindTitle)
            .appText(.footnote, weight: .medium, trimsLeading: true)
            .foregroundStyle(SettingsTemplate.secondaryText)
    }

    private func totalText(_ value: String) -> some View {
        FinancialText(value)
            .appNumber(.callout, weight: .semibold, trimsLeading: true)
            .foregroundStyle(CatfolioTheme.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .layoutPriority(1)
    }

    private func perShareText(_ value: String) -> some View {
        FinancialText(value)
            .appNumber(.footnote, weight: .medium, trimsLeading: true)
            .foregroundStyle(SettingsTemplate.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .layoutPriority(1)
    }

    private func accessibleDetails(_ amounts: CorporateEventCardAmounts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                logo
                companyName
            }
            eventKind
            if let total = amounts.total { totalText(total) }
            if let perShare = amounts.perShare { perShareText(perShare) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func accessibilityDescription(date: Date, amounts: CorporateEventCardAmounts) -> String {
        var parts = [date.formatted(.dateTime.year().month().day().locale(appLocale)),
                     holding?.shortName ?? event.ticker, event.kindTitle]
        if let total = amounts.total { parts.append(L10n.text("股息总额") + " " + total) }
        if let perShare = amounts.perShare { parts.append(L10n.text("每股股息") + " " + perShare) }
        return parts.joined(separator: ", ")
    }
}

struct CorporateEventDateTile: View {
    @Environment(\.locale) private var appLocale
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 44
    let date: Date
    let day: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 7) {
            Text(date.formatted(.dateTime.month(.abbreviated).locale(appLocale)).uppercased(with: appLocale))
                .appText(.nano, weight: .bold, trimsLeading: true)
                .tracking(0.2)
                .foregroundStyle(CatfolioPalette.calendarMonth)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(String(day))
                .appNumber(.body, weight: .medium, trimsLeading: true)
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(1)
        }
        .padding(.top, 2)
        .frame(width: size, height: size)
        .background(LinearGradient(colors: [CatfolioPalette.calendarTileTop, CatfolioPalette.calendarTileBottom],
                                   startPoint: .top, endPoint: .bottom), in: shape)
        .overlay { shape.strokeBorder(SettingsTemplate.cardBorder, lineWidth: 0.5) }
        .accessibilityHidden(true)
    }
}
