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
        _tableMode = State(initialValue: showsHeatmap ? "热力图"
            : LaunchArguments.contains("--show-etf") ? "ETF 穿透" : "持仓")
    }
    @AppStorage("portfolio.holdings.mergeETF") private var mergesETF = false
    @State private var selectedMergedRow: ETFLookThroughRow?
    private var showsMergedHoldings: Bool {
        mergesETF || LaunchArguments.contains("--show-merged-etf")
    }
    private var needsETFData: Bool {
        tableMode == "ETF 穿透" || (tableMode == "持仓" && showsMergedHoldings)
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
    @State private var etfVisibleLimit = 20
    @State private var etfSortField = ETFExposureSortField.totalExposure
    @State private var etfSortAscending = false
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
                        } else if tableMode == "热力图" {
                            heatmapView(isSnapshot: false)
                        } else {
                            etfTable
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
        .onChange(of: etfSortField) { _, _ in etfVisibleLimit = 20 }
        .onChange(of: etfSortAscending) { _, _ in etfVisibleLimit = 20 }
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
                Button {
                    mergesETF = true
                    tableMode = "持仓"
                } label: {
                    Label(L10n.text("合并穿透"), systemImage: tableMode == "持仓" && showsMergedHoldings ? "checkmark" : "square.stack.3d.up")
                }
                Button {
                    tableMode = "ETF 穿透"
                } label: {
                    Label(L10n.text("ETF 穿透"), systemImage: tableMode == "ETF 穿透" ? "checkmark" : "square.3.layers.3d")
                }
            } label: {
                HStack(spacing: 0) {
                    Text(tableTitle)
                    Image("PortfolioHeaderDisclosure")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 24, height: 24)
                }
                .font(Typography.number(size: colorScheme == .light ? 28 : 32))
                .foregroundStyle(.primary)
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
            withAnimation(.easeOut(duration: 0.18)) { headerUsesGlass = usesGlass }
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
        } else if tableMode == "ETF 穿透" {
            ETFExposureSortMenu(field: $etfSortField, ascending: $etfSortAscending, showsFilterTitle: floating)
        } else {
            HeatmapPerformancePeriodMenu(period: $heatmapPerformancePeriod,
                groupsBySector: $heatmapGroupsBySector, looksThroughETF: $heatmapLooksThroughETF,
                usesGlass: floating || headerUsesGlass, showsFilterTitle: floating)
        }
    }

    private var itemCount: String {
        switch tableMode {
        case "ETF 穿透": L10n.text("All \(etfResponse?.rows.count ?? 0)")
        default: L10n.text("All \(holdings.count)")
        }
    }

    private var tableTitle: String {
        switch tableMode {
        case "ETF 穿透": L10n.text("ETF 穿透")
        case "热力图": L10n.text("持仓热力图")
        default: showsMergedHoldings ? L10n.text("合并穿透") : "Catfolio"
        }
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
            Text(L10n.text("ETF 已拆分并合并到同名股票。盈亏按基金成分权重分摊估算，点按可看金额来源；未覆盖部分保留为 ETF 其他。"))
                .appText(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVStack(spacing: 4) {
                ForEach(mergedEntries, id: \.row.id) { entry in
                    if entry.row.fromETFUSD == 0, let direct = directHolding(for: entry.row.ticker) {
                        Button { onSelect(direct) } label: {
                            HoldingRow(holding: direct, performancePeriod: holdingPerformancePeriod,
                                dailyChangePercent: dailyChangePercent(for: direct))
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

    @ViewBuilder
    private var etfTable: some View {
        if isLoadingETF, etfResponse == nil {
            HStack(spacing: 10) {
                ProgressView()
                Text(L10n.text("正在计算 ETF 底层持仓…"))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .font(.subheadline)
            .frame(minHeight: 90)
        } else if let etfError {
            Label(etfError, systemImage: "square.3.layers.3d.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        } else if let response = etfResponse {
            HStack(spacing: 12) {
                ETFSummaryMetric(title: L10n.text("ETF 市值"), value: DisplayFormat.money(response.etfTotalUSD))
                ETFSummaryMetric(title: L10n.text("底层证券"), value: L10n.text("\(response.constituentCount) 项"))
                ETFSummaryMetric(
                    title: L10n.text("成分覆盖"),
                    value: DisplayFormat.percent(response.coveredWeightPercent, signed: false)
                )
            }
            .padding(.vertical, 10)

            Text(L10n.text("\(response.etfTickers.joined(separator: " · ")) 按当前市值和基金权重拆开，再与相同股票的直接持仓合并。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)

            VStack(spacing: 0) {
                ForEach(visibleETFRows) { row in
                    ETFExposureRow(
                        row: row,
                        directHolding: directHolding(for: row.ticker),
                        portfolioTotal: etfPortfolioTotal
                    )
                }
            }

            if visibleETFRows.count < sortedETFRows.count {
                Button {
                    etfVisibleLimit += 20
                } label: {
                    HStack {
                        Text(L10n.text("显示更多"))
                        Spacer()
                        Text("\(visibleETFRows.count) / \(sortedETFRows.count)")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.down")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(L10n.text("再显示 20 项 ETF 底层持仓"))
            }
        }
    }

    private var etfHoldingsKey: String {
        "\(model.portfolioSource)|" + model.selectedAccountKeys.sorted().joined(separator: ",") + "|" + holdings.map {
            "\($0.ticker):\($0.shares):\($0.quotePrice):\($0.averageCost):\($0.costCurrency ?? ""):\($0.quoteCurrency ?? ""):\($0.marketValue):\($0.unrealized)"
        }.joined(separator: "|")
    }

    private var sortedETFRows: [ETFLookThroughRow] {
        guard let rows = etfResponse?.rows else { return [] }
        return rows.sorted { left, right in
            let ordered: Bool
            switch etfSortField {
            case .totalExposure:
                ordered = compareETF(left.totalUSD, right.totalUSD, left: left.ticker, right: right.ticker)
            case .indirectExposure:
                ordered = compareETF(left.fromETFUSD, right.fromETFUSD, left: left.ticker, right: right.ticker)
            case .directExposure:
                ordered = compareETF(left.directUSD, right.directUSD, left: left.ticker, right: right.ticker)
            case .name:
                let leftName = CompanyNameCatalog.displayName(ticker: left.ticker, fallback: left.name)
                let rightName = CompanyNameCatalog.displayName(ticker: right.ticker, fallback: right.name)
                let result = leftName.localizedStandardCompare(rightName)
                if result == .orderedSame {
                    ordered = etfSortAscending ? left.ticker < right.ticker : left.ticker > right.ticker
                } else {
                    ordered = etfSortAscending ? result == .orderedAscending : result == .orderedDescending
                }
            }
            return ordered
        }
    }

    private var visibleETFRows: [ETFLookThroughRow] {
        Array(sortedETFRows.prefix(etfVisibleLimit))
    }

    private var etfPortfolioTotal: Double {
        etfResponse?.rows.reduce(0) { $0 + $1.totalUSD } ?? 0
    }

    private func directHolding(for ticker: String) -> Holding? {
        holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
    }

    private func compareETF(_ leftValue: Double, _ rightValue: Double, left: String, right: String) -> Bool {
        if leftValue == rightValue {
            return etfSortAscending ? left < right : left > right
        }
        return etfSortAscending ? leftValue < rightValue : leftValue > rightValue
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
            etfVisibleLimit = 20
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

enum ETFExposureSortField: String, CaseIterable, Identifiable {
    case totalExposure
    case indirectExposure
    case directExposure
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .totalExposure: L10n.text("总暴露")
        case .indirectExposure: L10n.text("ETF 间接")
        case .directExposure: L10n.text("直接持仓")
        case .name: L10n.text("名称")
        }
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

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), usesGlass {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(
                    colorScheme == .light
                        ? Color(red: 244 / 255, green: 244 / 255, blue: 244 / 255)
                        : Color.white.opacity(0.12),
                    in: Capsule()
                )
        }
    }
}

struct ETFExposureSortMenu: View {
    @Environment(\.locale) private var appLocale
    @Binding var field: ETFExposureSortField
    @Binding var ascending: Bool
    var showsFilterTitle = false

    var body: some View {
        menu
        .buttonStyle(.plain)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityLabel(L10n.text("ETF 穿透排序：\(field.title)，\(ascending ? "升序" : "降序")"))
    }

    private var menu: some View {
        Menu {
            Section(L10n.text("排序方式")) {
                ForEach(ETFExposureSortField.allCases) { option in
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
            if showsFilterTitle {
                PortfolioFilterLabel(showsTitle: true, usesGlass: true)
            } else {
                HStack(spacing: 5) {
                    Text(field.title)
                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .menuOrder(.fixed)
    }
}

struct ETFSummaryMetric: View {
    @Environment(\.locale) private var appLocale
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .appNumber(.callout, weight: .bold)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ETFExposureRow: View {
    @Environment(\.locale) private var appLocale
    let row: ETFLookThroughRow
    let directHolding: Holding?
    let portfolioTotal: Double

    private var portfolioWeight: Double {
        guard portfolioTotal > 0 else { return 0 }
        return row.totalUSD / portfolioTotal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                AssetLogo(ticker: row.ticker, logoSymbol: row.logoSymbol)

                VStack(alignment: .leading, spacing: 3) {
                    Text(CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name))
                        .font(.subheadline.weight(.bold))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(row.ticker)
                        if let directHolding {
                            Text("·")
                            Text(L10n.text("\(formattedShares(directHolding.shares)) 股"))
                        }
                    }
                    .appNumber(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(DisplayFormat.money(row.totalUSD, fractionDigits: 2))
                        .appNumber(.callout, weight: .bold)
                    Text(DisplayFormat.percent(portfolioWeight * 100, signed: false))
                        .appNumber(.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                .layoutPriority(2)
            }

            HStack(spacing: 12) {
                exposureLabel(L10n.text("直接"), value: row.directUSD, color: CatfolioPalette.blue500)
                exposureLabel("ETF", value: row.fromETFUSD, color: CatfolioPalette.green500)
                Spacer(minLength: 4)
                if row.directUSD > 0, row.fromETFUSD > 0 {
                    Text(L10n.text("重叠持仓"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.1), in: Capsule())
                }
            }

            if let directHolding {
                HStack(spacing: 6) {
                    Text(L10n.text("现价 \(DisplayFormat.money(directHolding.quotePrice, currency: directHolding.quoteCurrency))"))
                    Text("·")
                    Text(
                        L10n.text("盈亏 \(DisplayFormat.money(directHolding.unrealized, signed: true, fractionDigits: 2)) ")
                            + "(\(DisplayFormat.percent(directHolding.unrealizedPercent)))"
                    )
                    .foregroundStyle(directHolding.unrealized >= 0 ? CatfolioPalette.green500 : CatfolioPalette.rose500)
                }
                .appNumber(.micro, weight: .semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            }
        }
        .padding(.vertical, 9)
        .frame(minHeight: 76)
        .accessibilityElement(children: .combine)
    }

    private func exposureLabel(_ title: String, value: Double, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text("\(title) \(DisplayFormat.money(value))")
                .appNumber(.micro, weight: .semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func formattedShares(_ value: Double) -> String {
        DisplayFormat.shares(value)
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
                        AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, size: 40)
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
                HStack(alignment: .center, spacing: 8) {
                    AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, size: 40)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(holding.shortName)
                                .appText(.body, weight: .medium)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)

                            Spacer(minLength: 4)

                            Text(holding.displayedMarketValue)
                                .appNumber(.body)
                                .numericTransition(holding.marketValue)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            HStack(spacing: 2) {
                                Text(DisplayFormat.shares(holding.shares))
                                    .appNumber(.caption, monospaced: false)
                                Text(holding.ticker)
                                    .appText(.caption, weight: .medium)
                            }
                                .foregroundStyle(.secondary)
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
        DisplayFormat.shares(holding.shares)
    }

    private var profitDescription: String {
        guard let performance else { return L10n.text("暂无数据") }
        return "\(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2)) · \(DisplayFormat.percent(performance.percent))"
    }

    @ViewBuilder
    private var performanceLabel: some View {
        if let performance {
            HStack(spacing: 2) {
                Text(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2))
                    .numericTransition(performance.amount)
                Circle()
                    .fill(.secondary)
                    .frame(width: 2, height: 2)
                    .accessibilityHidden(true)
                Text(DisplayFormat.percent(performance.percent))
                    .numericTransition(performance.percent)
            }
            .appNumber(.caption, weight: .medium)
            .foregroundStyle(rowAccent)
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
            return CatfolioTheme.gain(for: colorScheme)
        }
        return CatfolioPalette.rose500
    }
}

struct HoldingIdentity: View {
    @Environment(\.locale) private var appLocale
    let holding: Holding
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(holding.shortName)
                .appText(.body, weight: .medium)
                .foregroundStyle(.primary)
                .lineLimit(compact ? 1 : nil)

            HStack(spacing: 2) {
                Text(DisplayFormat.shares(holding.shares))
                    .appNumber(.caption, monospaced: false)
                Text(holding.ticker)
                    .appText(.caption, weight: .medium)
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

private struct ETFMergedHoldingRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let row: ETFLookThroughRow
    let performance: HoldingPerformanceValues?
    let portfolioTotal: Double

    private var portfolioWeightText: String {
        guard portfolioTotal.isFinite, portfolioTotal > 0, row.totalUSD.isFinite else { return "—" }
        return DisplayFormat.percent(row.totalUSD / portfolioTotal * 100, signed: false)
    }

    var body: some View {
        HStack(spacing: 8) {
            AssetLogo(ticker: row.ticker, logoSymbol: row.logoSymbol, size: 40)
            VStack(alignment: .leading, spacing: 5) {
                if dynamicTypeSize.isAccessibilitySize {
                    name
                    amount
                    subtitle
                    profit
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        name
                        Spacer(minLength: 4)
                        amount
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        subtitle
                        Spacer(minLength: 2)
                        profit
                    }
                }
            }
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.text("查看合并金额与盈亏来源"))
    }

    private var name: some View {
        Text(row.ticker == "ETF 其他" ? L10n.text("ETF 其他") : CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name))
            .appText(.body, weight: .medium).foregroundStyle(.primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
    }

    private var amount: some View {
        Text(DisplayFormat.money(row.totalUSD, fractionDigits: 2))
            .appNumber(.body).foregroundStyle(.primary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var subtitle: some View {
        Text("\(row.ticker == "ETF 其他" ? L10n.text("ETF 其他") : row.ticker) · \(portfolioWeightText)")
            .appText(.caption, weight: .medium).foregroundStyle(.secondary).lineLimit(1)
            .accessibilityLabel(L10n.text("\(row.ticker == "ETF 其他" ? L10n.text("ETF 其他") : row.ticker)，")
                + L10n.text("\(portfolioWeightText) · 组合占比"))
    }

    @ViewBuilder private var profit: some View {
        if let performance {
            Text("≈\(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2)) · \(DisplayFormat.percent(performance.percent))")
                .appNumber(.caption, weight: .medium)
                .foregroundStyle(performance.amount >= 0 ? CatfolioTheme.gain(for: colorScheme) : CatfolioTheme.loss(for: colorScheme))
                .fixedSize(horizontal: true, vertical: false)
        } else {
            Text(L10n.text("暂无数据")).appText(.caption).foregroundStyle(.secondary)
        }
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
