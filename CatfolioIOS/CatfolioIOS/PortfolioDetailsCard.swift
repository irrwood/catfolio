import SwiftUI
import UIKit

struct PortfolioDetailsCard: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let holdings: [Holding]
    let onSelect: (Holding) -> Void
    let showsHeatmap: Bool
    let zoomNamespace: Namespace.ID?
    /// Set on the Performance tab: the heatmap is drawn as the isometric hero
    /// rather than inside a card.
    let hero: HeatmapHeroState?
    let floatsFilter: Bool

    @State private var tableMode: String

    init(
        holdings: [Holding],
        onSelect: @escaping (Holding) -> Void,
        showsHeatmap: Bool = false,
        zoomNamespace: Namespace.ID? = nil,
        hero: HeatmapHeroState? = nil,
        floatsFilter: Bool = false
    ) {
        self.holdings = holdings
        self.onSelect = onSelect
        self.showsHeatmap = showsHeatmap
        self.zoomNamespace = zoomNamespace
        self.hero = hero
        self.floatsFilter = floatsFilter
        _tableMode = State(initialValue: showsHeatmap ? "热力图" : "持仓")
    }
    @AppStorage("portfolio.holdings.mergeETF") private var mergesETF = false
    @State private var selectedMergedRow: ETFLookThroughRow?
    private var showsMergedHoldings: Bool {
        mergesETF || LaunchArguments.contains("--show-merged-etf") || LaunchArguments.contains("--show-etf")
    }
    private var needsETFData: Bool {
        (tableMode == "持仓" && showsMergedHoldings)
            || (tableMode == "热力图" && heatmapLooksThroughETF)
    }

    @State private var etfResponse: ETFLookThroughResponse?
    @State private var etfError: String?
    @State private var failedETFHoldingsKey = ""
    @State private var isLoadingETF = false
    @State private var etfLoadGeneration = 0
    @State private var loadedETFHoldingsKey = ""
    @State private var etfConstituentDailyChanges: [String: Double] = [:]
    @State private var loadedETFConstituentChangesKey = ""
    @State private var isLoadingETFConstituentChanges = false
    @State private var headerUsesGlass = false
    @AppStorage("portfolio.holdings.sortField") private var holdingSortFieldRawValue = HoldingSortField.marketValue.rawValue
    @AppStorage("portfolio.holdings.sortAscending") private var holdingSortAscending = false
    @State private var holdingPerformancePeriod: HoldingPerformancePeriod = .holdingPeriod
    @State private var heatmapPerformancePeriod: HoldingPerformancePeriod = .today
    @State private var heatmapGroupsBySector = LaunchArguments.all
        .contains("--group-heatmap-by-sector")
    @State private var heatmapLooksThroughETF = LaunchArguments.all
        .contains("--look-through-heatmap-etf")

    var body: some View {
        Group {
            if showsHeatmap, let hero {
                PerformanceHeatmapHero(
                    state: hero,
                    renderKey: heatmapRenderKey,
                    heatmap: { heatmapView(isSnapshot: $0) }
                )
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    if !showsHeatmap { headerRow }

                    Group {
                        if tableMode == "持仓" {
                            if showsMergedHoldings { mergedHoldingsTable } else { holdingsTable }
                        } else {
                            heatmapView(isSnapshot: false)
                        }
                    }
                }
                .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
                .padding(.top, 24)
                .padding(.bottom, 18)
                .background(colorScheme == .light ? Color.white : Color(red: 0, green: 0.008, blue: 0))
            }
        }
        .toolbar {
            if showsHeatmap {
                ToolbarItem(placement: .topBarTrailing) {
                    HeatmapPerformancePeriodMenu(period: $heatmapPerformancePeriod,
                        groupsBySector: $heatmapGroupsBySector, looksThroughETF: $heatmapLooksThroughETF,
                        isToolbarItem: true)
                        .accessibilityIdentifier("performance.heatmap.filter")
                }
            }
        }
        // Local exposure preparation must not wait for network quotes.
        .environment(\.securityDetailZoomOrigin, zoomNamespace)
        .task(id: "\(tableMode)-\(etfHoldingsKey)-\(heatmapLooksThroughETF)-\(showsMergedHoldings)") {
            guard needsETFData,
                  etfResponse == nil || loadedETFHoldingsKey != etfHoldingsKey else { return }
            await loadETF()
        }
        .task(id: "heatmap-daily-\(tableMode)-\(etfHoldingsKey)-\(heatmapPerformancePeriod.rawValue)") {
            guard tableMode == "热力图", heatmapPerformancePeriod == .today else { return }
            await model.refreshHoldingDailyChanges()
        }
        .task(id: "heatmap-constituents-\(tableMode)-\(loadedETFHoldingsKey)-\(heatmapLooksThroughETF)-\(heatmapPerformancePeriod.rawValue)") {
            guard tableMode == "热力图", heatmapLooksThroughETF,
                  heatmapPerformancePeriod == .today else { return }
            await loadETFConstituentDailyChanges()
        }
        .task(id: "merged-daily-\(tableMode)-\(showsMergedHoldings)-\(holdingPerformancePeriod.rawValue)-\(etfHoldingsKey)") {
            guard tableMode == "持仓", showsMergedHoldings, holdingPerformancePeriod == .today else { return }
            await model.refreshHoldingDailyChanges()
        }
        .appSheet(item: $selectedMergedRow) { row in
            ETFMergedHoldingDetail(row: row, holdings: holdingsByTicker, dailyChanges: model.holdingDailyChanges,
                holdingsAsOf: etfResponse?.holdingsAsOf, source: etfResponse?.holdingsSource)
        }
    }

    private func heatmapView(isSnapshot: Bool) -> HoldingsHeatmapView {
        HoldingsHeatmapView(
            holdings: holdings,
            dailyChanges: model.holdingDailyChanges,
            isLoading: !isSnapshot && ((heatmapLooksThroughETF && isLoadingETF)
                || (heatmapPerformancePeriod == .today
                    && (model.isHoldingDailyChangesLoading || isLoadingETFConstituentChanges))),
            performancePeriod: heatmapPerformancePeriod,
            groupsBySector: heatmapGroupsBySector,
            usesETFLookThrough: heatmapLooksThroughETF,
            lookThroughRows: loadedETFHoldingsKey == etfHoldingsKey
                ? etfResponse?.rows
                : nil,
            lookThroughDailyChanges: etfConstituentDailyChanges,
            screenInset: hero == nil ? CatfolioStyle.pageHorizontalInset : SettingsTemplate.pageInset,
            isInteractive: !isSnapshot,
            onSelect: onSelect
        )
    }

    /// Everything that changes how the heatmap draws, so the hero re-renders
    /// its textures only when one of them does.
    private var heatmapRenderKey: Int {
        var hasher = Hasher()
        for holding in holdings {
            hasher.combine(holding.ticker)
            hasher.combine(holding.logoSymbol)
            hasher.combine(holding.marketValue)
            hasher.combine(holding.todayChangePercent)
            hasher.combine(holding.unrealizedPercent)
        }
        for (ticker, change) in model.holdingDailyChanges.sorted(by: { $0.key < $1.key }) {
            hasher.combine(ticker)
            hasher.combine(change)
        }
        hasher.combine(heatmapPerformancePeriod.rawValue)
        hasher.combine(heatmapGroupsBySector)
        hasher.combine(heatmapLooksThroughETF)
        hasher.combine(loadedETFHoldingsKey == etfHoldingsKey ? etfResponse?.rows.count ?? -1 : -1)
        hasher.combine(etfConstituentDailyChanges.count)
        return hasher.finalize()
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Menu {
                Button {
                    mergesETF = false
                    tableMode = "持仓"
                } label: {
                    Label(L10n.text("持仓明细"), systemImage: tableMode == "持仓" && !showsMergedHoldings ? "checkmark" : "list.bullet")
                }
                // One look-through list: what was "合并穿透" and "ETF 穿透".
                Button {
                    mergesETF = true
                    tableMode = "持仓"
                } label: {
                    Label(L10n.text("ETF 穿透"), systemImage: tableMode == "持仓" && showsMergedHoldings ? "checkmark" : "square.3.layers.3d")
                }
            } label: {
                // The list's name, then its count with the day in small
                // type — the title no longer carries the app's name.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 2) {
                        Text(tableTitle)
                            .font(Typography.text(size: 22, weight: .semibold))
                        Image("PortfolioHeaderDisclosure")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 20, height: 20)
                    }
                    .foregroundStyle(CatfolioTheme.primaryText)
                    headerSubtitle
                }
            }
            .buttonStyle(.plain)

            Spacer()
            filterMenu(floating: false)
                .accessibilityIdentifier("portfolio-inline-filter")
                .anchorPreference(key: PortfolioFloatingFilterPreference.self, value: .bounds) { anchor in
                    floatsFilter ? PortfolioFloatingFilterSource(bounds: anchor,
                        menu: AnyView(filterMenu(floating: true))) : nil
                }
        }
        .onGeometryChange(for: Bool.self) { geometry in
            guard #available(iOS 26.0, *) else { return false }
            // Only publish the threshold crossing, not every global position.
            let threshold = UIScreen.main.bounds.midY + (headerUsesGlass ? 28 : 0)
            return geometry.frame(in: .global).midY <= threshold
        } action: { _, usesGlass in
            guard usesGlass != headerUsesGlass else { return }
            // Not animated: glass animated in from nothing drew for a frame
            // as a grey square before settling into its capsule.
            headerUsesGlass = usesGlass
        }
    }

    @ViewBuilder
    private func filterMenu(floating: Bool) -> some View {
        if tableMode == "持仓" {
            HoldingSortMenu(
                field: Binding(get: { holdingSortField }, set: { holdingSortFieldRawValue = $0.rawValue }),
                ascending: $holdingSortAscending,
                performancePeriod: $holdingPerformancePeriod,
                iconOnly: true,
                usesGlass: floating || headerUsesGlass,
                showsFilterTitle: floating
            )
        } else {
            HeatmapPerformancePeriodMenu(period: $heatmapPerformancePeriod,
                groupsBySector: $heatmapGroupsBySector, looksThroughETF: $heatmapLooksThroughETF,
                usesGlass: floating || headerUsesGlass, showsFilterTitle: floating)
        }
    }

    private var tableTitle: String {
        switch tableMode {
        case "热力图": L10n.text("持仓热力图")
        default: showsMergedHoldings ? L10n.text("ETF 穿透") : L10n.text("持仓列表")
        }
    }

    /// Rows in the list on screen; nil until an ETF breakdown has loaded.
    private var tableCount: Int? {
        switch tableMode {
        case "热力图": return nil
        default: if !showsMergedHoldings { return holdings.count }
        }
        guard loadedETFHoldingsKey == etfHoldingsKey, let rows = etfResponse?.rows, !rows.isEmpty else { return nil }
        return rows.count
    }

    /// "111  9月25日 / 周四": the count in a light weight, the day small.
    private var headerSubtitle: some View {
        let date = model.localUpdatedAt ?? Date()
        let day = date.formatted(.dateTime.month(.abbreviated).day().locale(appLocale))
        let weekday = date.formatted(.dateTime.weekday(.abbreviated).locale(appLocale))
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let tableCount {
                Text("\(tableCount)")
                    .font(Typography.number(size: 17, weight: .light))
                    .monospacedDigit()
                    .foregroundStyle(CatfolioTheme.primaryText)
            }
            Text("\(day) / \(weekday)")
                .appText(.caption, weight: .medium)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private var holdingsTable: some View {
        LazyVStack(spacing: 4) {
            ForEach(sortedHoldings) { holding in
                Button {
                    onSelect(holding)
                } label: {
                    HoldingRow(
                        holding: holding,
                        performancePeriod: holdingPerformancePeriod,
                        dailyChangePercent: dailyChangePercent(for: holding)
                    )
                }
                .buttonStyle(HoldingPressButtonStyle())
                .holdingDetailPreview(holding) { onSelect(holding) }
                .holdingZoomSource(holding.ticker, in: zoomNamespace)
                // The native-zoom control's source. Inert unless the flag is
                // set, so A's row renders exactly as before.
                .securityDetailNativeZoomSource(holding.ticker, in: zoomNamespace,
                    enabled: SecurityDetailNativeZoom.isEnabled
                        || SecurityDetailNativeZoom.isForced)
                .environment(\.securityDetailZoomOrigin, zoomNamespace)
            }
        }
    }

    private var holdingsByTicker: [String: Holding] {
        Dictionary(holdings.map { ($0.ticker.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var mergedEntries: [(row: ETFLookThroughRow, performance: HoldingPerformanceValues?)] {
        guard loadedETFHoldingsKey == etfHoldingsKey else { return [] }
        let direct = holdingsByTicker
        return (etfResponse?.rows ?? []).map { row in
            (row: row, performance: row.mergedPerformance(for: holdingPerformancePeriod,
                holdings: direct, dailyChanges: model.holdingDailyChanges))
        }.sorted { left, right in
            if holdingSortField == .name {
                let comparison = CompanyNameCatalog.displayName(ticker: left.row.ticker, fallback: left.row.name)
                    .localizedStandardCompare(CompanyNameCatalog.displayName(ticker: right.row.ticker, fallback: right.row.name))
                if comparison != .orderedSame {
                    return holdingSortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
                }
            }
            func value(_ entry: (row: ETFLookThroughRow, performance: HoldingPerformanceValues?)) -> Double? {
                switch holdingSortField {
                case .marketValue: entry.row.totalUSD
                case .unrealized: entry.performance?.amount
                case .unrealizedPercent: entry.performance?.percent
                case .name: nil
                }
            }
            return compareOptional(value(left), value(right), leftTicker: left.row.ticker, rightTicker: right.row.ticker)
        }
    }

    @ViewBuilder
    private var mergedHoldingsTable: some View {
        if let etfError, failedETFHoldingsKey == etfHoldingsKey {
            Text(L10n.message(etfError)).appText(.caption).foregroundStyle(.secondary)
            holdingsTable
        } else if loadedETFHoldingsKey != etfHoldingsKey || etfResponse == nil {
            HStack(spacing: 8) {
                ProgressView()
                Text(L10n.text("正在计算 ETF 底层持仓…")).appText(.caption).foregroundStyle(.secondary)
            }
            holdingsTable
        } else {
            LazyVStack(spacing: 4) {
                ForEach(mergedEntries, id: \.row.id) { entry in
                    if entry.row.fromETFUSD == 0, let direct = directHolding(for: entry.row.ticker) {
                        // Held only outright: the same row, and the page itself.
                        Button { onSelect(direct) } label: {
                            ETFMergedHoldingRow(row: entry.row, performance: entry.performance,
                                portfolioTotal: etfPortfolioTotal)
                        }
                        .buttonStyle(HoldingPressButtonStyle())
                        .holdingDetailPreview(direct) { onSelect(direct) }
                        .holdingZoomSource(direct.ticker, in: zoomNamespace)
                    } else {
                        Button { selectedMergedRow = entry.row } label: {
                            ETFMergedHoldingRow(row: entry.row, performance: entry.performance,
                                portfolioTotal: etfPortfolioTotal)
                        }
                        .buttonStyle(HoldingPressButtonStyle())
                    }
                }
            }
        }
    }

    private var holdingSortField: HoldingSortField {
        HoldingSortField(rawValue: holdingSortFieldRawValue) ?? .marketValue
    }

    private struct HoldingSortEntry {
        let holding: Holding
        let value: Double?
    }

    /// Decorate-sort-undecorate.
    ///
    /// `sorted(by:)` takes a comparator, so anything derived inside it runs
    /// O(n log n) times — twice per comparison here. `performanceValues` uppercases
    /// the ticker and hashes it into the daily-change dictionary, so deriving the
    /// sort key once per holding drops that from ~2n log n allocations to n.
    ///
    /// `compareOptional` delegates to `compare` whenever both sides are present, and
    /// `.marketValue` always is, so routing all three numeric fields through it
    /// keeps the ordering identical to the previous per-case comparators.
    private var sortedHoldings: [Holding] {
        let field = holdingSortField
        let entries = holdings.map { holding in
            switch field {
            case .marketValue:
                HoldingSortEntry(holding: holding, value: holding.marketValue)
            case .unrealized:
                HoldingSortEntry(holding: holding, value: performanceValues(for: holding)?.amount)
            case .unrealizedPercent:
                HoldingSortEntry(holding: holding, value: performanceValues(for: holding)?.percent)
            case .name:
                HoldingSortEntry(holding: holding, value: nil)
            }
        }
        return entries.sorted { left, right in
            guard field != .name else {
                let comparison = left.holding.shortName.localizedStandardCompare(right.holding.shortName)
                if comparison == .orderedSame {
                    let tickerComparison = left.holding.ticker.localizedStandardCompare(right.holding.ticker)
                    return holdingSortAscending
                        ? tickerComparison == .orderedAscending
                        : tickerComparison == .orderedDescending
                }
                return holdingSortAscending
                    ? comparison == .orderedAscending
                    : comparison == .orderedDescending
            }
            return compareOptional(
                left.value,
                right.value,
                leftTicker: left.holding.ticker,
                rightTicker: right.holding.ticker
            )
        }.map(\.holding)
    }

    private func compare(
        _ left: Double,
        _ right: Double,
        leftTicker: String,
        rightTicker: String
    ) -> Bool {
        if left.isFinite != right.isFinite { return left.isFinite }
        if left == right || (!left.isFinite && !right.isFinite) {
            let comparison = leftTicker.localizedStandardCompare(rightTicker)
            return holdingSortAscending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
        return holdingSortAscending ? left < right : left > right
    }

    private func compareOptional(
        _ left: Double?,
        _ right: Double?,
        leftTicker: String,
        rightTicker: String
    ) -> Bool {
        switch (left, right) {
        case let (.some(leftValue), .some(rightValue)):
            return compare(leftValue, rightValue, leftTicker: leftTicker, rightTicker: rightTicker)
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return compare(0, 0, leftTicker: leftTicker, rightTicker: rightTicker)
        }
    }

    private func dailyChangePercent(for holding: Holding) -> Double? {
        model.holdingDailyChanges[holding.ticker.uppercased()] ?? holding.todayChangePercent
    }

    private func performanceValues(for holding: Holding) -> HoldingPerformanceValues? {
        holding.performanceValues(
            for: holdingPerformancePeriod,
            dailyChangePercent: dailyChangePercent(for: holding)
        )
    }

    private var etfHoldingsKey: String {
        "\(model.portfolioSource)|" + model.selectedAccountKeys.sorted().joined(separator: ",") + "|" + holdings.map {
            "\($0.ticker):\($0.shares):\($0.quotePrice):\($0.averageCost):\($0.costCurrency ?? ""):\($0.quoteCurrency ?? ""):\($0.marketValue):\($0.unrealized)"
        }.joined(separator: "|")
    }

    private var etfPortfolioTotal: Double {
        etfResponse?.rows.reduce(0) { $0 + $1.totalUSD } ?? 0
    }

    private func directHolding(for ticker: String) -> Holding? {
        holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
    }

    private func loadETF() async {
        etfLoadGeneration &+= 1
        let generation = etfLoadGeneration
        let requestedKey = etfHoldingsKey
        isLoadingETF = true
        etfError = nil
        defer {
            if generation == etfLoadGeneration { isLoadingETF = false }
        }
        do {
            let response = try await model.loadETFLookThrough(basis: .market)
            guard !Task.isCancelled, generation == etfLoadGeneration,
                  requestedKey == etfHoldingsKey else { return }
            etfResponse = response
            let activeTickers = Set(response.rows.map { $0.ticker.uppercased() })
            etfConstituentDailyChanges = etfConstituentDailyChanges.filter { activeTickers.contains($0.key) }
            loadedETFConstituentChangesKey = ""
            loadedETFHoldingsKey = requestedKey
        } catch {
            guard !Task.isCancelled, generation == etfLoadGeneration,
                  requestedKey == etfHoldingsKey else { return }
            etfResponse = nil
            failedETFHoldingsKey = requestedKey
            etfError = error.localizedDescription
        }
    }

    private func loadETFConstituentDailyChanges() async {
        guard let rows = etfResponse?.rows,
              loadedETFHoldingsKey == etfHoldingsKey else { return }
        let tickers = rows
            .filter { $0.totalUSD.isFinite && $0.totalUSD > 0 && $0.ticker != "ETF 其他" }
            .sorted { $0.totalUSD > $1.totalUSD }
            .map(\.ticker)
        let signature = "\(etfHoldingsKey)|\(tickers.map { $0.uppercased() }.joined(separator: ","))"
        guard signature != loadedETFConstituentChangesKey else { return }

        isLoadingETFConstituentChanges = true
        defer { isLoadingETFConstituentChanges = false }
        let holdingsKey = etfHoldingsKey
        let client = LocalMarketDataClient()
        // Populate the leading tiles first, then the tail needed for aggregate
        // P&L. Each batch reuses the quote cache and bounded request concurrency.
        let batchSize = HoldingsHeatmapView.maximumLookThroughTiles
        for start in stride(from: 0, to: tickers.count, by: batchSize) {
            guard !Task.isCancelled, loadedETFHoldingsKey == holdingsKey else { return }
            let batch = Array(tickers[start..<min(start + batchSize, tickers.count)])
            let changes = await client.dailyChanges(tickers: batch)
            guard !Task.isCancelled, loadedETFHoldingsKey == holdingsKey else { return }
            etfConstituentDailyChanges.merge(changes) { _, fresh in fresh }
            // Later batches fill the summaries without blocking the whole map.
            isLoadingETFConstituentChanges = false
        }
        loadedETFConstituentChangesKey = signature
    }
}

enum HoldingSortField: String, CaseIterable, Identifiable {
    case marketValue
    case unrealized
    case unrealizedPercent
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .marketValue: L10n.text("市值")
        case .unrealized: L10n.text("盈利")
        case .unrealizedPercent: L10n.text("收益率")
        case .name: L10n.text("名称")
        }
    }

    var compactTitle: String {
        switch self {
        case .marketValue: L10n.text("Mkt Cap")
        case .unrealized: L10n.text("P&L")
        case .unrealizedPercent: L10n.text("Return")
        case .name: L10n.text("Name")
        }
    }
}

enum HoldingPerformancePeriod: String, CaseIterable, Identifiable {
    case today
    case holdingPeriod

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: L10n.text("今日")
        case .holdingPeriod: L10n.text("持有期")
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .holdingPeriod: "calendar.badge.clock"
        }
    }
}

struct HeatmapPerformancePeriodMenu: View {
    @Environment(\.locale) private var appLocale
    @Binding var period: HoldingPerformancePeriod
    @Binding var groupsBySector: Bool
    @Binding var looksThroughETF: Bool
    var usesGlass = false
    var showsFilterTitle = false
    var isToolbarItem = false

    var body: some View {
        Menu {
            Section(L10n.text("收益时间")) {
                ForEach(HoldingPerformancePeriod.allCases) { option in
                    Button {
                        period = option
                    } label: {
                        Label(
                            option.title,
                            systemImage: period == option ? "checkmark" : option.systemImage
                        )
                    }
                }
            }

            Divider()

            Section(L10n.text("布局")) {
                Toggle(L10n.text("按板块分组"), isOn: $groupsBySector)
                Toggle(L10n.text("穿透 ETF"), isOn: $looksThroughETF)
            }
        } label: {
            if isToolbarItem {
                Image("PortfolioHeaderSort")
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: 24, height: 24)
            } else {
                PortfolioFilterLabel(showsTitle: showsFilterTitle, usesGlass: usesGlass)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .menuOrder(.fixed)
        .accessibilityLabel(
            L10n.text("热力图筛选：\(period.title)，\(groupsBySector ? "按板块分组" : "不分组")，")
                + (looksThroughETF ? L10n.text("已穿透 ETF") : L10n.text("未穿透 ETF"))
        )
    }
}

struct HoldingSortMenu: View {
    @Environment(\.locale) private var appLocale
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @Binding var field: HoldingSortField
    @Binding var ascending: Bool
    @Binding var performancePeriod: HoldingPerformancePeriod
    var iconOnly = false
    var usesGlass = false
    var showsFilterTitle = false

    var body: some View {
        menu
        .buttonStyle(.plain)
        .appText(.footnote, weight: .medium)
        .foregroundStyle(.secondary)
        .sensoryFeedback(.selection, trigger: performancePeriod) { _, _ in hapticsEnabled }
        .accessibilityLabel(L10n.text("筛选：\(performancePeriod.title)；排序：\(field.title)，\(ascending ? "升序" : "降序")"))
    }

    private var menu: some View {
        Menu {
            Section(L10n.text("收益时间")) {
                ForEach(HoldingPerformancePeriod.allCases) { period in
                    Button {
                        performancePeriod = period
                    } label: {
                        Label(
                            period.title,
                            systemImage: performancePeriod == period ? "checkmark" : period.systemImage
                        )
                    }
                }
            }

            Divider()

            Section(L10n.text("排序方式")) {
                ForEach(HoldingSortField.allCases) { option in
                    Button {
                        field = option
                    } label: {
                        if field == option {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(option.title)
                        }
                    }
                }
            }

            Divider()

            Button {
                ascending.toggle()
            } label: {
                Label(
                    ascending ? L10n.text("改为降序") : L10n.text("改为升序"),
                    systemImage: ascending ? "arrow.down" : "arrow.up"
                )
            }
        } label: {
            Group {
                if iconOnly {
                    PortfolioFilterLabel(showsTitle: showsFilterTitle, usesGlass: usesGlass)
                } else {
                    HStack(spacing: 3) {
                        Text(field.compactTitle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
            }
        }
        .menuOrder(.fixed)
    }
}

struct PortfolioFilterLabel: View {
    let showsTitle: Bool
    let usesGlass: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image("PortfolioHeaderSort")
                .renderingMode(.template).resizable().scaledToFit()
                .frame(width: 24, height: 24)
            if showsTitle { Text(L10n.text("筛选")).appText(.footnote, weight: .medium) }
        }
        .padding(.horizontal, 17)
        .frame(minHeight: 44)
        .fixedSize()
        .modifier(PortfolioHeaderMaterialControl(usesGlass: usesGlass))
    }
}

struct PortfolioFloatingFilterSource {
    let bounds: Anchor<CGRect>
    // The bindings still belong to the details card, including its transient
    // performance period and ETF sort. Both presentations operate on that state.
    let menu: AnyView
}

struct PortfolioFloatingFilterPreference: PreferenceKey {
    static var defaultValue: PortfolioFloatingFilterSource? { nil }
    static func reduce(value: inout PortfolioFloatingFilterSource?, nextValue: () -> PortfolioFloatingFilterSource?) {
        value = nextValue() ?? value
    }
}

struct PortfolioFloatingFilterOverlay: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(PortfolioFloatingFilterPreference.self) { source in
            GeometryReader { geometry in
                if let source, Self.shouldFloat(sourceFrame: geometry[source.bounds]) {
                    source.menu
                        .accessibilityIdentifier("portfolio-floating-filter")
                        .padding(.top, 10)
                        .padding(.trailing, CatfolioStyle.pageHorizontalInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
        }
    }

    static func shouldFloat(sourceFrame: CGRect) -> Bool {
        sourceFrame.height > 0 && sourceFrame.maxY.isFinite && sourceFrame.maxY <= 0
    }
}

struct PortfolioHeaderMaterialControl: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let usesGlass: Bool

    private var fill: Color {
        colorScheme == .light
            ? Color(red: 244 / 255, green: 244 / 255, blue: 244 / 255)
            : Color.white.opacity(0.12)
    }

    /// One structure in both states, switched without animation. Swapping a
    /// filled view for a glass one rebuilt the control, and glass animated in
    /// drew for a frame as a grey square before becoming a capsule.
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(fill.opacity(usesGlass ? 0 : 1), in: Capsule())
                .glassEffect(usesGlass ? .regular.interactive() : .identity, in: Capsule())
                .animation(nil, value: usesGlass)
        } else {
            content.background(fill, in: Capsule())
        }
    }
}

struct HoldingPerformanceValues {
    let amount: Double
    let percent: Double
}

extension Holding {
    func performanceValues(
        for period: HoldingPerformancePeriod,
        dailyChangePercent: Double?
    ) -> HoldingPerformanceValues? {
        switch period {
        case .holdingPeriod:
            guard unrealized.isFinite, unrealizedPercent.isFinite else { return nil }
            return HoldingPerformanceValues(amount: unrealized, percent: unrealizedPercent)
        case .today:
            guard let dailyChangePercent,
                  let amount = PortfolioMath.dayContribution(
                      marketValue: marketValue, changePercent: dailyChangePercent) else { return nil }
            return HoldingPerformanceValues(amount: amount, percent: dailyChangePercent)
        }
    }
}

struct HoldingRow: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.colorScheme) private var colorScheme
    /// The list's zoom namespace, so the row's logo can fly to the page's.
    @Environment(\.securityDetailZoomOrigin) private var zoomOrigin
    let holding: Holding
    let performancePeriod: HoldingPerformancePeriod
    let dailyChangePercent: Double?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var performance: HoldingPerformanceValues? {
        holding.performanceValues(
            for: performancePeriod,
            dailyChangePercent: dailyChangePercent
        )
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, size: 44, cornerRadius: 12)
                        HoldingIdentity(holding: holding, compact: false)
                    }
                    HoldingMetrics(
                        holding: holding,
                        performance: performance,
                        period: performancePeriod,
                        alignment: .leading,
                        compact: false
                    )
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, size: 44, cornerRadius: 12)
                        .securityDetailLogoSource(holding.ticker, in: zoomOrigin)

                    // Figma trims font boxes; 2pt here gives the visible text 16pt top/bottom in this 64pt cell.
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .center, spacing: 8) {
                            SecurityDisplayName(
                                name: holding.shortName, scale: .body, weight: .semibold,
                                showsClassMarkers: false
                            )
                                .layoutPriority(1)

                            Spacer(minLength: 4)

                            Text(holding.displayedMarketValue)
                                .appNumber(.callout, weight: .semibold)
                                .foregroundStyle(CatfolioTheme.primaryText)
                                .numericTransition(holding.marketValue)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                // Figma cap trims both strings; SwiftUI's number line box sits 1pt low.
                                .offset(y: -1)
                        }

                        HStack(alignment: .center, spacing: 5) {
                            HStack(spacing: 2) {
                                Text(DisplayFormat.listShares(holding.shares, locale: appLocale))
                                    .appNumber(.footnote, weight: .medium, monospaced: false)
                                Text(holding.ticker)
                                    .appText(.footnote, weight: .medium)
                                SecurityClassBadges(markers: holding.classMarkers)
                            }
                                .foregroundStyle(Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(0)

                            Spacer(minLength: 2)

                            performanceLabel
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.text("\(holding.shortName)，\(formattedShares) 股 \(holding.ticker)，市值 \(DisplayFormat.money(holding.marketValue))，\(performancePeriod.title)盈亏 \(profitDescription)")
        )
    }

    private var formattedShares: String {
        DisplayFormat.listShares(holding.shares, compact: false, locale: appLocale)
    }

    private var profitDescription: String {
        guard let performance else { return L10n.text("暂无数据") }
        return "\(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2)) · \(DisplayFormat.percent(performance.percent))"
    }

    private var performanceLabel: some View {
        HoldingPerformanceLabel(performance: performance)
    }
}

/// A row's profit: the amount, then its percentage on a tinted tag — green
/// for a gain, red for a loss. The holdings list's, shared by the
/// look-through list so the two read the same.
struct HoldingPerformanceLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let performance: HoldingPerformanceValues?

    var body: some View {
        if let performance {
            HStack(spacing: 4) {
                Text(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2))
                    .appNumber(.footnote, weight: .medium)
                    .foregroundStyle(rowAccent)
                    .numericTransition(performance.amount)
                Text(DisplayFormat.percent(performance.percent, signed: false))
                    .appNumber(.caption, weight: .semibold, monospaced: false)
                    .foregroundStyle(rowAccent)
                    .numericTransition(performance.percent)
                    .padding(.horizontal, 5)
                    .frame(minHeight: 17)
                    .background(badgeColor, in: RoundedRectangle(cornerRadius: 4))
            }
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)
        } else {
            Text(L10n.text("暂无数据"))
                .font(PortfolioHomeTypography.medium(12, relativeTo: .caption))
                .foregroundStyle(rowAccent)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
    }

    private var rowAccent: Color {
        if (performance?.amount ?? 0) >= 0 {
            return colorScheme == .light
                ? Color(red: 1 / 255, green: 184 / 255, blue: 1 / 255)
                : CatfolioTheme.gain(for: colorScheme)
        }
        return CatfolioTheme.loss(for: colorScheme)
    }

    private var badgeColor: Color {
        if (performance?.amount ?? 0) >= 0 {
            return colorScheme == .light
                ? Color(red: 220 / 255, green: 247 / 255, blue: 220 / 255)
                : rowAccent.opacity(0.18)
        }
        return CatfolioTheme.loss(for: colorScheme).opacity(0.18)
    }
}

private struct SecurityDisplayName: View {
    let name: String
    let scale: TypeScale
    let weight: Font.Weight
    var singleLine = true
    var showsClassMarkers = true

    private var parts: SecurityNameParts { SecurityNameParts(name) }

    var body: some View {
        HStack(alignment: .center, spacing: 1) {
            Text(parts.primary)
                .appText(scale, weight: weight)
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(singleLine ? 1 : nil)
                .truncationMode(.tail)

            if showsClassMarkers {
                SecurityClassBadges(markers: parts.classMarkers)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

struct SecurityClassBadges: View {
    let markers: [String]

    var body: some View {
        ForEach(markers.indices, id: \.self) { index in
            SecurityClassBadge(marker: markers[index])
        }
    }
}

struct SecurityClassBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let marker: String
    @ScaledMetric(relativeTo: .caption) private var badgeHeight: CGFloat = 18

    private let gray = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)

    var body: some View {
        Text(marker)
            .appText(.caption, weight: .medium)
            .foregroundStyle(gray)
            .padding(.horizontal, 3)
            // Align the visible capital, not the font's descender space.
            .offset(y: -0.5)
            .frame(height: badgeHeight)
            .background(gray.opacity(colorScheme == .dark ? 0.24 : 0.1),
                        in: RoundedRectangle(cornerRadius: 3))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityHidden(true)
    }
}

struct HoldingIdentity: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SecurityDisplayName(name: holding.shortName, scale: .body, weight: .medium,
                                singleLine: compact, showsClassMarkers: false)

            HStack(spacing: 2) {
                Text(DisplayFormat.listShares(holding.shares, locale: appLocale))
                    .appNumber(.caption, monospaced: false)
                Text(holding.ticker)
                    .appText(.caption, weight: .medium)
                SecurityClassBadges(markers: holding.classMarkers)
            }
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 1 : nil)
        }
    }
}

struct HoldingMetrics: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let performance: HoldingPerformanceValues?
    let period: HoldingPerformancePeriod
    let alignment: HorizontalAlignment
    let compact: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(holding.displayedMarketValue)
                .appNumber(.body)
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(compact ? 1 : nil)
            // The separator is punctuation, not data. Carrying the gain or
            // loss colour it reads as part of the figure, and a row of red
            // dots between red numbers is noise the eye has to filter.
            Group {
                if let performance {
                    Text(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2))
                        .foregroundStyle(performanceColor)
                    + Text(" · ").foregroundStyle(.secondary)
                    + Text(DisplayFormat.percent(performance.percent))
                        .foregroundStyle(performanceColor)
                } else {
                    Text(performanceText).foregroundStyle(.secondary)
                }
            }
            .appNumber(.caption, weight: .medium)
            .lineLimit(compact ? 1 : nil)
        }
    }

    private var performanceColor: Color {
        (performance?.amount ?? 0) >= 0
            ? (colorScheme == .light
                ? CatfolioTheme.gain(for: .light)
                : CatfolioTheme.gain(for: .dark))
            : CatfolioPalette.rose500
    }

    private var performanceText: String {
        guard let performance else { return L10n.text("\(period.title)暂无数据") }
        return "\(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2)) "
            + "· \(DisplayFormat.percent(performance.percent))"
    }
}

/// The look-through list's row, drawn as the holdings list draws its rows:
/// the security and its combined amount, then its ticker and share of the
/// portfolio against its profit — amount and percentage tag.
private struct ETFMergedHoldingRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: ETFLookThroughRow
    let performance: HoldingPerformanceValues?
    let portfolioTotal: Double

    private var tickerText: String {
        row.ticker == "ETF 其他" ? L10n.text("ETF 其他") : row.ticker
    }

    private var nameText: String {
        row.ticker == "ETF 其他" ? L10n.text("ETF 其他")
            : CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name)
    }

    private var portfolioWeightText: String {
        guard portfolioTotal.isFinite, portfolioTotal > 0, row.totalUSD.isFinite else { return "—" }
        return DisplayFormat.percent(row.totalUSD / portfolioTotal * 100, signed: false)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        AssetLogo(ticker: row.ticker, logoSymbol: row.logoSymbol, size: 44, cornerRadius: 12)
                        SecurityDisplayName(name: nameText, scale: .body, weight: .semibold, singleLine: false)
                    }
                    amount
                    subtitle
                    HoldingPerformanceLabel(performance: performance)
                }
            } else {
                HStack(alignment: .center, spacing: 10) {
                    AssetLogo(ticker: row.ticker, logoSymbol: row.logoSymbol, size: 44, cornerRadius: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .center, spacing: 8) {
                            SecurityDisplayName(name: nameText, scale: .body, weight: .semibold,
                                                showsClassMarkers: false)
                                .layoutPriority(1)
                            Spacer(minLength: 4)
                            amount
                                // As the holdings row: its number box sits 1pt low.
                                .offset(y: -1)
                        }
                        HStack(alignment: .center, spacing: 5) {
                            subtitle
                            Spacer(minLength: 2)
                            HoldingPerformanceLabel(performance: performance)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.text("查看合并金额与盈亏来源"))
    }

    private var amount: some View {
        Text(DisplayFormat.money(row.totalUSD, fractionDigits: 2))
            .appNumber(.callout, weight: .semibold)
            .foregroundStyle(CatfolioTheme.primaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var subtitle: some View {
        Text("\(tickerText) · \(portfolioWeightText)")
            .appText(.footnote, weight: .medium)
            .foregroundStyle(Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255))
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityLabel(L10n.text("\(tickerText)，") + L10n.text("\(portfolioWeightText) · 组合占比"))
    }
}

private struct ETFMergedHoldingDetail: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let row: ETFLookThroughRow
    let holdings: [String: Holding]
    let dailyChanges: [String: Double]
    let holdingsAsOf: String?
    let source: String?

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.text("合并金额")) {
                    amountRow("市值", row.totalUSD)
                    amountRow("分摊成本", row.allocatedCostUSD)
                }
                Section(L10n.text("金额来源")) {
                    if row.directUSD != 0 { amountRow("直接持仓", row.directUSD) }
                    ForEach((row.fundMarketValues ?? [:]).keys.sorted(), id: \.self) { fund in
                        amountRow(fund, row.fundMarketValues?[fund])
                    }
                }
                Section(L10n.text("分摊盈亏")) {
                    performanceRow(.holdingPeriod)
                    performanceRow(.today)
                }
                Section {
                    Text(L10n.text("按基金当前成分权重分摊市值、成本和基金盈亏，再与直接持仓合并。约号表示分摊估算，不代表成分股自身的历史收益。缺少成本或行情时不计算该项盈亏。"))
                    Text(L10n.text("这只是持仓展示模式，不会修改券商持仓、交易记录或账户总额。"))
                    if let holdingsAsOf, !holdingsAsOf.isEmpty { Text(holdingsAsOf) }
                    if let source, !source.isEmpty { Text(L10n.message(source)) }
                }
                .appText(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle(row.ticker == "ETF 其他" ? L10n.text("ETF 其他") : row.ticker)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { AppModalDoneButton { dismiss() } }
            }
        }
    }

    private func amountRow(_ title: String, _ value: Double?) -> some View {
        LabeledContent(L10n.label(title)) {
            Text(value.map { DisplayFormat.money($0, fractionDigits: 2) } ?? "—").appNumber(.body)
        }
    }

    private func performanceRow(_ period: HoldingPerformancePeriod) -> some View {
        let result = row.mergedPerformance(for: period, holdings: holdings, dailyChanges: dailyChanges)
        return LabeledContent(period.title) {
            if let result {
                Text("≈\(DisplayFormat.money(result.amount, signed: true, fractionDigits: 2)) · \(DisplayFormat.percent(result.percent))")
                    .appNumber(.callout)
                    .foregroundStyle(result.amount >= 0 ? CatfolioTheme.gain(for: colorScheme) : CatfolioTheme.loss(for: colorScheme))
            } else {
                Text(L10n.text("暂无数据")).foregroundStyle(.secondary)
            }
        }
    }
}
