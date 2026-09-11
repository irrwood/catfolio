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
                  change.isFinite, holding.marketValue.isFinite else { return nil }
            // Yesterday's value moved by `change`, so today's move is the part
            // of the current value that the change accounts for.
            let previous = holding.marketValue / (1 + change / 100)
            let amount = holding.marketValue - previous
            guard amount.isFinite else { return nil }
            return Contribution(holding: holding, changePercent: change, amount: amount)
        }
        .sorted { $0.amount > $1.amount }
    }

    private var total: Double { contributions.reduce(0) { $0 + $1.amount } }
    private var gainers: [Contribution] { Array(contributions.filter { $0.amount > 0 }.prefix(5)) }
    private var losers: [Contribution] { Array(contributions.filter { $0.amount < 0 }.reversed().prefix(5)) }
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
    private var largestMagnitude: Double {
        max(contributions.map { abs($0.amount) }.max() ?? 1, 0.01)
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

        var rows = totals.map { sector, amount in
            SectorBreakdown(
                sector: sector, amount: amount,
                components: (members[sector] ?? []).sorted { abs($0.amount) > abs($1.amount) }
            )
        }
        .sorted { abs($0.amount) > abs($1.amount) }

        if !unclassifiedMembers.isEmpty {
            rows.append(SectorBreakdown(
                sector: nil, amount: unclassified,
                components: unclassifiedMembers.sorted { abs($0.amount) > abs($1.amount) }
            ))
        }
        return (rows, usedLookThrough, totalValue > 0 ? unclassifiedValue / totalValue : 0)
    }

    private var sectorRows: [SectorBreakdown] { sectorTotals.rows }
    private var unclassifiedShare: Double { sectorTotals.unclassifiedWeight }

    private var sectorFootnote: String {
        var parts: [String] = []
        if sectorTotals.lookThroughUsed {
            parts.append(L10n.text("指数基金按其成分股的行业构成分摊，非逐只成分的当日涨跌"))
        }
        if unclassifiedShare > 0.005 {
            let pct = (unclassifiedShare * 100).formatted(.number.precision(.fractionLength(0)))
            parts.append(L10n.text("未分类占当前市值 \(pct)%，主要是非美股上市标的，行业资料暂未覆盖"))
        }
        return parts.isEmpty ? L10n.text("行业来自打包的美股公司资料，用于当前归类，不适用于历史回溯。") : L10n.sentences(parts)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("今日盈亏"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(DisplayFormat.money(total, signed: true, fractionDigits: 2))
                        .appNumber(.display, weight: .bold)
                        .foregroundStyle(total >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                        .contentTransition(.numericText(value: total))
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
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 6)
            }

            if !sectorRows.isEmpty {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                             count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 12) {
                        ForEach(sectorRows) { row in
                            let definition = row.sector.map { SectorPerformanceDefinition.definition(for: $0) }
                            Button {
                                selectedSector = row
                                showsSectorMembers = true
                            } label: {
                                SectorGlassCard(
                                    title: row.displayName,
                                    icon: definition?.icon ?? row.symbolName,
                                    caption: L10n.text("\(row.components.count) 项"),
                                    value: DisplayFormat.money(row.amount, signed: true, fractionDigits: 2),
                                    tint: definition?.color ?? .gray,
                                    valueColor: row.amount >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("today-sector.\(row.id)")
                        }
                    }
                    .padding(.vertical, 4)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } header: {
                    Text(L10n.text("按行业"))
                } footer: {
                    Text(sectorFootnote)
                }
                .headerProminence(.increased)
            }

            if !gainers.isEmpty {
                Section {
                    ForEach(gainers) { contributionRow($0) }
                } header: {
                    Text(L10n.text("推动上涨 · \(gainers.count) 项"))
                }
                .headerProminence(.increased)
            }

            if !losers.isEmpty {
                Section {
                    ForEach(losers) { contributionRow($0) }
                } header: {
                    Text(L10n.text("拖累下跌 · \(losers.count) 项"))
                }
                .headerProminence(.increased)
            }

            if !percentageGainers.isEmpty {
                Section {
                    ForEach(percentageGainers) { contributionRow($0, byPercentage: true) }
                } header: {
                    Text(L10n.text("持仓涨幅榜")) + Text(" · %")
                }
                .headerProminence(.increased)
                .accessibilityIdentifier("today.percentage-gainers")
            }

            if !percentageLosers.isEmpty {
                Section {
                    ForEach(percentageLosers) { contributionRow($0, byPercentage: true) }
                } header: {
                    Text(L10n.text("持仓跌幅榜")) + Text(" · %")
                }
                .headerProminence(.increased)
                .accessibilityIdentifier("today.percentage-losers")
            }

            if contributions.isEmpty {
                Section {
                    ContentUnavailableView(
                        L10n.text("暂无今日行情"),
                        systemImage: "chart.bar.xaxis",
                        description: Text(L10n.text("持仓的当日涨跌还没有读取到。"))
                    )
                }
            } else {
                Section {
                    Text(L10n.text("按持仓当前市值和当日涨跌推算，未计入今日的买入卖出。行情为各标的最近可用报价。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationDestination(isPresented: $showsSectorMembers) {
            if let selectedSector {
                SectorMembersView(breakdown: selectedSector)
            }
        }
        .softTopScrollEdge()
        .navigationTitle(L10n.text("今日"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func contributionRow(_ contribution: Contribution, byPercentage: Bool = false) -> some View {
        let value = byPercentage ? contribution.changePercent : contribution.amount
        let tint = value >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger
        let money = DisplayFormat.money(contribution.amount, signed: true, fractionDigits: 2)
        let percentage = DisplayFormat.percent(contribution.changePercent, signed: true)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(contribution.holding.shortName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(byPercentage ? percentage : money)
                    .appNumber(.subheading, weight: .semibold)
                    .foregroundStyle(tint)
            }
            HStack(spacing: 8) {
                // Each ranking scales bars in its own unit: money or daily percentage.
                GeometryReader { geo in
                    let ratio = abs(value) / (byPercentage ? largestPercentageMagnitude : largestMagnitude)
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: max(3, geo.size.width * ratio), height: 5)
                }
                .frame(height: 5)
                Text(byPercentage ? money : percentage)
                    .appNumber(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 62, alignment: .trailing)
            }
        }
        .padding(.vertical, 3)
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
    }

    private func percentText(_ fraction: Double) -> String {
        (fraction * 100).formatted(.number.precision(.fractionLength(fraction < 0.1 ? 1 : 0))) + "%"
    }
}
