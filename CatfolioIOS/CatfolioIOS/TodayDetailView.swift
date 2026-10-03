import SwiftUI

/// The full attribution behind the TODAY figure on the home page.
///
/// Everything here is arithmetic on data the app already holds: each holding's
/// market value and its daily change. Nothing is fetched, and nothing is
/// generated — the summary line is a sort, not a model's opinion, so it cannot
/// be wrong in a way the numbers beside it are not.
struct TodayDetailView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selectedSector: SectorBreakdown?
    @State private var showsSectorMembers = false
    struct Contribution: Identifiable {
        let holding: Holding
        let changePercent: Double
        let amount: Double

        var id: String { holding.ticker }
    }

    let holdings: [Holding]
    let dailyChanges: [String: Double]
    let benchmarkChange: Double?

    private var contributions: [Contribution] {
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
    private var sectorTotals: (rows: [SectorBreakdown], lookThroughUsed: Bool, unclassifiedWeight: Double) {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                summary

                if !sectorRows.isEmpty {
                    sectorSection
                }

                if !percentageGainers.isEmpty {
                    ranking(percentageGainers, title: L10n.text("持仓涨幅榜"))
                        .accessibilityIdentifier("today.percentage-gainers")
                }
                if !percentageLosers.isEmpty {
                    ranking(percentageLosers, title: L10n.text("持仓跌幅榜"))
                        .accessibilityIdentifier("today.percentage-losers")
                }

                if contributions.isEmpty {
                    ContentUnavailableView(
                        L10n.text("暂无今日行情"),
                        systemImage: "chart.bar.xaxis",
                        description: Text(L10n.text("持仓的当日涨跌还没有读取到。"))
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CatfolioStyle.pageHorizontalInset)
        }
        // ScrollView does not supply List's grouped page and row surfaces.
        // Keep the shared card fill distinct from the page in either theme.
        .background(Color(uiColor: .systemGroupedBackground))
        .accessibilityIdentifier("today-detail-scroll")
        .navigationDestination(isPresented: $showsSectorMembers) {
            if let selectedSector {
                SectorMembersView(breakdown: selectedSector)
            }
        }
        .softTopScrollEdge()
        .navigationTitle(L10n.text("今日"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("今日盈亏"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(DisplayFormat.money(total, signed: true, fractionDigits: 2))
                .appNumber(.display, weight: .bold)
                .foregroundStyle(total >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            if !contributions.isEmpty {
                // What the net is made of: the rising holdings' gain and the
                // falling ones' loss, each with how many there are.
                HStack(spacing: 12) {
                    splitMetric(title: L10n.text("盈利"), amount: gainTotal, count: gainCount,
                                color: CatfolioTheme.positive)
                    splitMetric(title: L10n.text("亏损"), amount: lossTotal, count: lossCount,
                                color: CatfolioTheme.danger)
                }
                .padding(.top, 8)
            }
            if let benchmarkChange, benchmarkChange.isFinite {
                HStack(spacing: 5) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(CatfolioTheme.accent)
                    Text("SPY")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(DisplayFormat.percent(benchmarkChange, signed: true))
                        .appNumber(.callout, weight: .medium)
                        .foregroundStyle(benchmarkChange >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                }
                .padding(.top, 2)
            }
            if let headline {
                Text(headline)
                    .currencyFont(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ContentCard())
    }

    private var gainTotal: Double { contributions.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount } }
    private var lossTotal: Double { contributions.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount } }
    private var gainCount: Int { contributions.filter { $0.amount > 0 }.count }
    private var lossCount: Int { contributions.filter { $0.amount < 0 }.count }

    private func splitMetric(title: String, amount: Double, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("\(title) · \(count) 只"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(DisplayFormat.money(amount, signed: amount != 0, fractionDigits: 2))
                .appNumber(.heading, weight: .semibold)
                .foregroundStyle(count == 0 ? Color.secondary : color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(count == 0 ? 0.04 : 0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var sectorSection: some View {
        let rows = sectorRows
        let columns = typeSize >= .xxxLarge ? 1 : 2
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("按行业"))
                .font(.headline)
            // Eleven sectors at most plus unclassified. Eager rows keep the
            // scroll content height stable as cards enter and leave the screen.
            VStack(spacing: 12) {
                ForEach(Array(stride(from: 0, to: rows.count, by: columns)), id: \.self) { index in
                    TodaySectorRowLayout(columns: columns, spacing: 12) {
                        sectorCard(rows[index])
                        if columns == 2 {
                            if index + 1 < rows.count {
                                sectorCard(rows[index + 1])
                            }
                        }
                    }
                }
            }
        }
    }

    private func sectorCard(_ row: SectorBreakdown) -> some View {
        Button {
            selectedSector = row
            showsSectorMembers = true
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Image(systemName: row.symbolName)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    Text(L10n.text("\(row.components.count) 项"))
                        .font(.caption)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.displayName)
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                    Text(DisplayFormat.money(row.amount, signed: true, fractionDigits: 2))
                        .appNumber(.body, weight: .semibold)
                        .foregroundStyle(row.amount >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(ContentCard())
            .contentShape(RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("today-sector.\(row.id)")
    }

    private func ranking(_ rows: [Contribution], title: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title + " · %")
                .font(.headline)
            VStack(spacing: 12) {
                ForEach(rows) { contribution in
                    contributionRow(contribution)
                    if contribution.id != rows.last?.id { Divider() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(ContentCard())
        }
    }

    private func contributionRow(_ contribution: Contribution) -> some View {
        let value = contribution.changePercent
        let tint = value >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger
        let money = DisplayFormat.money(contribution.amount, signed: true, fractionDigits: 2)
        let percentage = DisplayFormat.percent(contribution.changePercent, signed: true)
        return HStack(alignment: .center, spacing: 12) {
            // The same mark the home list shows, so a holding reads as itself
            // here without the reader matching names.
            AssetLogo(ticker: contribution.holding.ticker, logoSymbol: contribution.holding.logoSymbol, size: 36)
            contributionDetail(contribution, value: value, tint: tint, money: money, percentage: percentage)
        }
        .padding(.vertical, 3)
    }

    private func contributionDetail(_ contribution: Contribution, value: Double, tint: Color,
                                    money: String, percentage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(contribution.holding.shortName)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(percentage)
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
                Text(money)
                    .appNumber(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 62, alignment: .trailing)
            }
        }
    }
}

/// Measure each card at its final column width, then give both cards the taller
/// height. Localized names can wrap without staggering card edges or amounts.
struct TodaySectorRowLayout: Layout {
    var columns: Int
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let columnWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        let height = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columnWidth = max(0, (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (columnWidth + spacing), y: bounds.minY),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: columnWidth, height: bounds.height))
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
                    Text(DisplayFormat.money(breakdown.amount, signed: true, fractionDigits: 2))
                        .currencyFont(.largeTitle, weight: .bold)
                        .monospacedDigit()
                        .foregroundStyle(breakdown.amount >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                }
                .padding(.vertical, 6)
            }

            Section {
                ForEach(breakdown.components) { component in
                    HStack(alignment: .center, spacing: 12) {
                    AssetLogo(ticker: component.holding.ticker, logoSymbol: component.holding.logoSymbol, size: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(component.holding.shortName)
                                .font(.body)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(DisplayFormat.money(component.amount, signed: true, fractionDigits: 2))
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
                    .padding(.vertical, 2)
                }
            } header: {
                Text(L10n.text("\(breakdown.components.count) 项持仓"))
            } footer: {
                if breakdown.sector == nil {
                    Text(L10n.text("这些标的没有可用的行业资料，主要是非美股上市证券。补齐后会自动归入对应行业。"))
                }
            }
        }
        .softTopScrollEdge()
        .navigationTitle(breakdown.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
    }

    private func percentText(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(fraction < 0.1 ? 1 : 0))) + "%"
    }
}
