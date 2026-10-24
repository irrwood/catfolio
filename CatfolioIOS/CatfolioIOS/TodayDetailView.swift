import SwiftUI

/// The full attribution behind the TODAY figure on the home page.
///
/// All attribution is arithmetic on the page's holdings and daily quotes.
/// The top brief narrates those computed facts and can expand with sourced news.
struct TodayDetailView: View {
    enum Presentation { case page, home }
    let presentation: Presentation
    @Environment(\.locale) private var appLocale
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var selectedSector: SectorBreakdown?
    @State private var showsSectorMembers = false
    @State private var selectedHolding: Holding?
    struct Contribution: Identifiable {
        let holding: Holding
        let changePercent: Double
        let amount: Double

        var id: String { holding.ticker }
    }

    let holdings: [Holding]
    /// Each holding's change since the previous session, in percent, in the
    /// reader's currency (`AppModel.holdingDayReturns`).
    let dailyChanges: [String: Double]
    let benchmarkChange: Double?
    var sessionDate: String? = nil
    let isLoading: Bool
    var briefStore: TodayBriefStore = .shared
    private let contributions: [Contribution]
    private let sectorTotals: (rows: [SectorBreakdown], lookThroughUsed: Bool, unclassifiedWeight: Double)

    init(holdings: [Holding], dailyChanges: [String: Double], benchmarkChange: Double?,
         sessionDate: String? = nil, isLoading: Bool = false, briefStore: TodayBriefStore = .shared,
         presentation: Presentation = .page) {
        self.presentation = presentation
        self.holdings = holdings
        self.dailyChanges = dailyChanges
        self.benchmarkChange = benchmarkChange
        self.sessionDate = sessionDate
        self.isLoading = isLoading
        self.briefStore = briefStore
        let contributions = Self.makeContributions(holdings: holdings, dailyChanges: dailyChanges)
        self.contributions = contributions
        self.sectorTotals = Self.makeSectorTotals(contributions)
    }

    private var briefContext: TodayBriefContext {
        TodayBriefContext(sessionDate: sessionDate, total: total,
            benchmarkChange: benchmarkChange.flatMap { $0.isFinite ? $0 : nil },
            stocks: contributions.map { .init(ticker: $0.holding.ticker.uppercased(),
                name: $0.holding.shortName, logoSymbol: $0.holding.logoSymbol,
                changePercent: $0.changePercent, amount: $0.amount) },
            sectors: sectorRows.map { .init(id: $0.id, name: $0.displayName,
                icon: $0.symbolName, amount: $0.amount,
                tickers: $0.components.map { $0.holding.ticker.uppercased() }) }, language: appLocale.identifier)
    }

    private static func makeContributions(holdings: [Holding], dailyChanges: [String: Double]) -> [Contribution] {
        holdings.compactMap { holding in
            let key = holding.ticker.uppercased()
            guard let change = dailyChanges[key] ?? holding.todayChangePercent,
                  let amount = PortfolioMath.dayContribution(
                      marketValue: holding.marketValue, changePercent: change) else { return nil }
            return Contribution(holding: holding, changePercent: change, amount: amount)
        }
        .sorted { $0.amount == $1.amount ? $0.id < $1.id : $0.amount > $1.amount }
    }

    private var total: Double { contributions.reduce(0) { $0 + $1.amount } }
    private var percentageGainers: [Contribution] {
        Array(contributions.filter { $0.changePercent > 0 }.sorted {
            $0.changePercent == $1.changePercent ? $0.id < $1.id : $0.changePercent > $1.changePercent
        }.prefix(5))
    }
    private var percentageLosers: [Contribution] {
        Array(contributions.filter { $0.changePercent < 0 }.sorted {
            $0.changePercent == $1.changePercent ? $0.id < $1.id : $0.changePercent < $1.changePercent
        }.prefix(5))
    }
    private var largestPercentageMagnitude: Double {
        max(contributions.map { abs($0.changePercent) }.max() ?? 1, 0.01)
    }

    /// Sum of every move regardless of sign — how much actually happened today,
    /// as opposed to what survived the offsetting.
    private var grossMovement: Double {
        contributions.reduce(0) { $0 + abs($1.amount) }
    }

    /// "X drove N% of today's gain" — derived, not written by a model.
    ///
    /// Measured against the net figure, which is what the headline claims to
    /// explain. When gains and losses nearly cancel, that denominator collapses
    /// and any single holding "explains" several hundred percent of it — so
    /// below a meaningful net, the honest statement is that the day offset
    /// itself, not that one stock drove it.
    private var headline: String? {
        guard !contributions.isEmpty, grossMovement > 0.01 else { return nil }

        // A day is only "driven" if the net is a real share of what moved.
        guard abs(total) >= grossMovement * 0.2 else {
            return L10n.text("涨跌基本抵消：合计变动 \(DisplayFormat.money(grossMovement, fractionDigits: 0))，净额 \(DisplayFormat.money(total, signed: true, fractionDigits: 2))")
        }

        // The leader has to move the same way the day did.
        let sameDirection = contributions.filter { total >= 0 ? $0.amount > 0 : $0.amount < 0 }
        guard let leader = sameDirection.max(by: { abs($0.amount) < abs($1.amount) }) else { return nil }
        let share = min(100, abs(leader.amount) / abs(total) * 100)
        guard share.isFinite, share >= 15 else { return nil }
        let verb = total >= 0 ? L10n.text("涨幅") : L10n.text("跌幅")
        return L10n.text("\(leader.holding.shortName) 贡献了今日 \(share.formatted(.number.precision(.fractionLength(0))))% 的\(verb)")
    }

    // MARK: - Sector attribution

    /// A sector, what it moved, and which holdings put it there.
    ///
    /// `sector == nil` is the unclassified bucket, kept as a first-class row so
    /// its members can be inspected — that list is also the shortest path to
    /// knowing which tickers still need reference data.
    struct SectorBreakdown: Identifiable {
        struct Component: Identifiable {
            let holding: Holding
            /// The slice of this holding's move attributed to the sector.
            let amount: Double
            /// How much of the holding landed here. Below 1 for a fund spread
            /// across sectors.
            let fraction: Double
            let isLookThrough: Bool

            var id: String { holding.ticker }
        }

        let sector: PortfolioSector?
        let amount: Double
        let components: [Component]

        var id: String { sector?.rawValue ?? "unclassified" }
        var displayName: String { sector.map { L10n.label($0.displayName) } ?? L10n.text("未分类") }
        var symbolName: String { sector?.symbolName ?? "questionmark.circle" }
    }

    /// Each holding's move is spread by its own sector split, so a fund
    /// contributes to several sectors and a single stock to one. The part no
    /// source can classify is kept aside rather than redistributed.
    private static func makeSectorTotals(_ contributions: [Contribution]) -> (rows: [SectorBreakdown], lookThroughUsed: Bool, unclassifiedWeight: Double) {
        var totals: [PortfolioSector: Double] = [:]
        var members: [PortfolioSector: [SectorBreakdown.Component]] = [:]
        var unclassified = 0.0
        var unclassifiedMembers: [SectorBreakdown.Component] = []
        var usedLookThrough = false
        var unclassifiedValue = 0.0
        var totalValue = 0.0

        for contribution in contributions {
            let split = SectorAttribution.split(
                ticker: contribution.holding.ticker,
                name: contribution.holding.displayName
            )
            if split.isLookThrough { usedLookThrough = true }
            for (sector, weight) in split.weights {
                let slice = contribution.amount * weight
                totals[sector, default: 0] += slice
                members[sector, default: []].append(
                    .init(holding: contribution.holding, amount: slice,
                          fraction: weight, isLookThrough: split.isLookThrough)
                )
            }
            let gap = split.unclassifiedFraction
            if gap > 0.0001 {
                unclassified += contribution.amount * gap
                unclassifiedMembers.append(
                    .init(holding: contribution.holding, amount: contribution.amount * gap,
                          fraction: gap, isLookThrough: split.isLookThrough)
                )
            }

            let value = contribution.holding.marketValue
            if value.isFinite {
                totalValue += value
                unclassifiedValue += value * gap
            }
        }

        let componentOrder: (SectorBreakdown.Component, SectorBreakdown.Component) -> Bool = { lhs, rhs in
            if abs(lhs.amount) == abs(rhs.amount) { return lhs.id < rhs.id }
            return abs(lhs.amount) > abs(rhs.amount)
        }
        var rows: [SectorBreakdown] = totals.map { sector, amount in
            let components = (members[sector] ?? []).sorted(by: componentOrder)
            return SectorBreakdown(sector: sector, amount: amount, components: components)
        }
        rows.sort { lhs, rhs in
            if abs(lhs.amount) == abs(rhs.amount) { return lhs.id < rhs.id }
            return abs(lhs.amount) > abs(rhs.amount)
        }

        if !unclassifiedMembers.isEmpty {
            rows.append(SectorBreakdown(
                sector: nil, amount: unclassified,
                components: unclassifiedMembers.sorted(by: componentOrder)
            ))
        }
        return (rows, usedLookThrough, totalValue > 0 ? unclassifiedValue / totalValue : 0)
    }

    private var sectorRows: [SectorBreakdown] { sectorTotals.rows }
    private var unclassifiedShare: Double { sectorTotals.unclassifiedWeight }

    private var appDisclaimer: String {
        briefContext.language.hasPrefix("zh") ? "非投资建议" : "Not investment advice"
    }

    var body: some View {
        Group {
            if presentation == .home { homeCards }
            else { detailPage }
        }
        .navigationDestination(isPresented: $showsSectorMembers) {
            if let selectedSector {
                SectorMembersView(breakdown: selectedSector)
            }
        }
        // The sheet inherits the model from the page, as the heatmap's does.
        .securityDetail(item: $selectedHolding) { holding, close in
            HoldingDetailView(holding: holding, onClose: close)
        }
        .securityDetailOpenFeedback(trigger: selectedHolding?.ticker, enabled: hapticsEnabled)
    }

    private var detailPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if !contributions.isEmpty, !holdings.contains(where: { $0.publicDisclosure != nil }) {
                    TodayBriefView(context: briefContext, store: briefStore)
                }
                summary

                if !percentageGainers.isEmpty {
                    ranking(percentageGainers, title: L10n.text("持仓涨幅榜"))
                        .accessibilityIdentifier("today.percentage-gainers")
                }
                if !percentageLosers.isEmpty {
                    ranking(percentageLosers, title: L10n.text("持仓跌幅榜"))
                        .accessibilityIdentifier("today.percentage-losers")
                }

                if contributions.isEmpty {
                    if isLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                    ContentUnavailableView(
                        L10n.text("暂无今日行情"),
                        systemImage: "chart.bar.xaxis",
                        description: Text(L10n.text("持仓的当日涨跌还没有读取到。"))
                    )
                    }
                }
                Text(appDisclaimer)
                    .font(Typography.rounded(.caption))
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CatfolioStyle.pageHorizontalInset)
        }
        // The standard cell's ground, so the cards read as they do in Settings.
        .background(SettingsTemplate.pageBackground)
        .accessibilityIdentifier("today-detail-scroll")
        .softTopScrollEdge()
        .navigationTitle(L10n.text("今日"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The workspace home owns scrolling; each attribution region retains
    /// its own surface, with no embedded page or second navigation bar.
    private var homeCards: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacDashboardRow {
                VStack(alignment: .leading, spacing: 10) {
                    summary.accessibilityIdentifier("home.today.summary")
                    if !percentageGainers.isEmpty || !percentageLosers.isEmpty {
                        homeMoversRanking
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                if !sectorRows.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        homeCardTitle(L10n.text("行业贡献"))
                        sectorSection
                            .padding(.horizontal, 8)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .settingsCardSurface()
                    .accessibilityIdentifier("home.today.sectors")
                }
            }
            if !contributions.isEmpty, !holdings.contains(where: { $0.publicDisclosure != nil }) {
                TodayBriefView(context: briefContext, store: briefStore)
                    .padding(20)
                    .settingsCardSurface()
            }
            if contributions.isEmpty {
                if isLoading { ProgressView().frame(maxWidth: .infinity) }
                else {
                    ContentUnavailableView(L10n.text("暂无今日行情"), systemImage: "chart.bar.xaxis",
                                           description: Text(L10n.text("持仓的当日涨跌还没有读取到。")))
                }
            }
            Text(appDisclaimer)
                .appText(.caption)
                .foregroundStyle(SettingsTemplate.secondaryText)
        }
    }


    // These titles live inside the cards, so they own one inset rather than
    // inheriting the Settings section header's outside-the-card spacing.
    private func homeCardTitle(_ title: String) -> some View {
        Text(title)
            .font(Typography.text(size: 22, weight: .semibold))
            .foregroundStyle(CatfolioTheme.primaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
            .padding(.top, 20)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
    }

    /// Keep both original top-five selections in one compact list beneath
    /// the daily summary, alongside the taller industry breakdown.
    private var homeMoversRanking: some View {
        let rows = percentageGainers + percentageLosers
        return VStack(alignment: .leading, spacing: 0) {
            homeCardTitle(L10n.text("持仓涨跌榜"))
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, contribution in
                if index > 0 {
                    SettingsTemplate.separator.frame(height: SettingsTemplate.separatorHeight)
                        .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
                }
                if typeSize.isAccessibilitySize {
                    contributionRow(contribution)
                } else {
                    compactMoverRow(contribution)
                }
            }
        }
        .settingsCardSurface()
        .accessibilityIdentifier("home.today.movers")
    }

    private func compactMoverRow(_ contribution: Contribution) -> some View {
        Button { selectedHolding = contribution.holding } label: {
            HStack(spacing: 10) {
                AssetLogo(ticker: contribution.holding.ticker,
                          logoSymbol: contribution.holding.logoSymbol, size: 28)
                Text(contribution.holding.shortName)
                    .appText(.callout, weight: .medium)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                FinancialText(DisplayFormat.percent(contribution.changePercent, signed: true))
                    .appNumber(.callout, weight: .semibold)
                    .foregroundStyle(contribution.changePercent >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                    .fixedSize()
                    .frame(minWidth: 62, alignment: .trailing)
                FinancialText(DisplayFormat.money(contribution.amount, signed: true, fractionDigits: 2), isDirectional: true)
                    .appNumber(.caption)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .fixedSize()
                    .frame(minWidth: 80, alignment: .trailing)
            }
            .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityIdentifier("today.holding.\(contribution.holding.ticker)")
    }

    private var summary: some View {
        // One shared surface from the day's net through its sector breakdown.
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(L10n.text("今日盈亏"))
                    .appText(.callout, weight: .medium)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                FinancialText(DisplayFormat.money(total, signed: true, fractionDigits: 2), isDirectional: true)
                    .appNumber(.display, weight: .bold)
                    .foregroundStyle(total >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                if let benchmarkChange, benchmarkChange.isFinite {
                    FinancialText("SPY " + DisplayFormat.percent(benchmarkChange, signed: true))
                        .appNumber(.footnote, weight: .medium)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)

            if !contributions.isEmpty {
                SettingsTemplate.separator.frame(height: SettingsTemplate.separatorHeight)
                HStack(spacing: 0) {
                    splitMetric(title: L10n.text("盈利"), amount: gainTotal, count: gainCount,
                                color: CatfolioTheme.positive)
                    SettingsTemplate.separator
                        .frame(width: SettingsTemplate.separatorHeight)
                        .padding(.vertical, 18)
                    splitMetric(title: L10n.text("亏损"), amount: lossTotal, count: lossCount,
                                color: CatfolioTheme.danger)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if let headline {
                SettingsTemplate.separator.frame(height: SettingsTemplate.separatorHeight)
                Text(headline)
                    .currencyFont(.footnote)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
                    .padding(.vertical, 14)
            }

            if presentation == .page, !sectorRows.isEmpty {
                sectorSection
            }
        }
        .settingsCardSurface()
    }

    private var gainTotal: Double { contributions.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount } }
    private var lossTotal: Double { contributions.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount } }
    private var gainCount: Int { contributions.filter { $0.amount > 0 }.count }
    private var lossCount: Int { contributions.filter { $0.amount < 0 }.count }

    /// One column under the net: a quiet label, the figure beneath it.
    private func splitMetric(title: String, amount: Double, count: Int, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(L10n.text("\(title) · \(count) 只"))
                .appText(.callout, weight: .medium)
                .foregroundStyle(SettingsTemplate.secondaryText)
            FinancialText(DisplayFormat.money(amount, signed: amount != 0, fractionDigits: 2), isDirectional: true)
                .appNumber(.title, weight: .semibold)
                .foregroundStyle(count == 0 ? SettingsTemplate.secondaryText : color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    /// The industry breakdown continues inside the summary's shared card.
    private var sectorSection: some View {
        TodaySectorCard(rows: sectorRows) { row in
            selectedSector = row
            showsSectorMembers = true
        }
    }

    /// The standard cell: a section title over one card, a row per holding,
    /// divided full width by the card itself.
    private func ranking(_ rows: [Contribution], title: String) -> some View {
        VStack(alignment: .leading, spacing: SettingsTemplate.sectionSpacing) {
            SettingsSectionHeader(title + " · %")
            SettingsCard {
                ForEach(rows) { contribution in
                    contributionRow(contribution)
                }
            }
        }
    }

    private func contributionRow(_ contribution: Contribution) -> some View {
        let value = contribution.changePercent
        let tint = value >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger
        let money = DisplayFormat.money(contribution.amount, signed: true, fractionDigits: 2)
        let percentage = DisplayFormat.percent(contribution.changePercent, signed: true)
        return Button {
            selectedHolding = contribution.holding
        } label: {
            HStack(alignment: .center, spacing: 12) {
                // The same mark the home list shows, so a holding reads as itself
                // here without the reader matching names.
                AssetLogo(ticker: contribution.holding.ticker, logoSymbol: contribution.holding.logoSymbol, size: 36)
                contributionDetail(contribution, value: value, tint: tint, money: money, percentage: percentage)
            }
            .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
            .padding(.vertical, SettingsTemplate.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsRowButtonStyle())
        .accessibilityIdentifier("today.holding.\(contribution.holding.ticker)")
    }

    private func contributionDetail(_ contribution: Contribution, value: Double, tint: Color,
                                    money: String, percentage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(contribution.holding.shortName)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                FinancialText(percentage)
                    .appNumber(.subheading, weight: .semibold)
                    .foregroundStyle(tint)
                    .fixedSize(horizontal: true, vertical: false)
            }
            HStack(spacing: 8) {
                // Both rankings share the daily percentage scale.
                GeometryReader { geo in
                    let ratio = abs(value) / largestPercentageMagnitude
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: max(3, geo.size.width * ratio), height: 5)
                }
                .frame(height: 5)
                FinancialText(money, isDirectional: true)
                    .appNumber(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 62, alignment: .trailing)
            }
        }
    }
}

/// Which holdings put a sector where it is.
///
/// A fund appears with the share of it that belongs here, so a row reading
/// "38% 计入本行业" is legible as an attribution rather than mistaken for the
/// fund's whole move.
private struct SectorMembersView: View {
    @Environment(\.locale) private var appLocale
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var selectedHolding: Holding?
    let breakdown: TodayDetailView.SectorBreakdown

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: breakdown.symbolName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(breakdown.sector == nil ? Color.secondary : CatfolioTheme.accent)
                        Text(breakdown.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    FinancialText(DisplayFormat.money(breakdown.amount, signed: true, fractionDigits: 2), isDirectional: true)
                        .currencyFont(.largeTitle, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(breakdown.amount >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                }
                .padding(.vertical, 6)
                .settingsListRow()
            }

            Section {
                ForEach(breakdown.components) { component in
                    Button { selectedHolding = component.holding } label: {
                        HStack(alignment: .center, spacing: 12) {
                            AssetLogo(ticker: component.holding.ticker, logoSymbol: component.holding.logoSymbol, size: 32)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(component.holding.shortName)
                                        .font(.body)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    FinancialText(DisplayFormat.money(component.amount, signed: true, fractionDigits: 2), isDirectional: true)
                                        .appNumber(.subheading, weight: .medium)
                                        .foregroundStyle(component.amount >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                                }
                                HStack(spacing: 6) {
                                    Text(component.holding.ticker)
                                        .appNumber(.caption)
                                        .foregroundStyle(.tertiary)
                                    if component.fraction < 0.999 {
                                        Text(L10n.text("成分穿透 \(percentText(component.fraction)) 计入本行业"))
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                    .settingsListRow()
                    .accessibilityIdentifier("today-sector-member.\(component.holding.ticker)")
                }
            } header: {
                Text(L10n.text("\(breakdown.components.count) 项持仓"))
            } footer: {
                if breakdown.sector == nil {
                    Text(L10n.text("这些标的没有可用的行业资料，主要是非美股上市证券。补齐后会自动归入对应行业。"))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(SettingsTemplate.pageBackground)
        // The sheet inherits the model from the page, as the heatmap's does.
        .securityDetail(item: $selectedHolding) { holding, close in
            HoldingDetailView(holding: holding, onClose: close)
        }
        .securityDetailOpenFeedback(trigger: selectedHolding?.ticker, enabled: hapticsEnabled)
        .softTopScrollEdge()
        .navigationTitle(breakdown.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func percentText(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(fraction < 0.1 ? 1 : 0))) + "%"
    }
}
