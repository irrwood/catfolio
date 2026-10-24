import SwiftUI
import UIKit

struct PortfolioDetailsCard: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sitsOnMacOverviewCard) private var sitsOnMacOverviewCard
    let holdings: [Holding]
    let onSelect: (Holding) -> Void
    let showsHeatmap: Bool
    let zoomNamespace: Namespace.ID?
    /// Set on the Performance tab: the heatmap is drawn as the isometric hero
    /// rather than inside a card.
    let hero: HeatmapHeroState?
    let floatsFilter: Bool
    let isSidebar: Bool
    let searchQuery: String

    init(
        holdings: [Holding],
        onSelect: @escaping (Holding) -> Void,
        showsHeatmap: Bool = false,
        zoomNamespace: Namespace.ID? = nil,
        hero: HeatmapHeroState? = nil,
        floatsFilter: Bool = false,
        isSidebar: Bool = false,
        searchQuery: String = ""
    ) {
        self.holdings = holdings
        self.onSelect = onSelect
        self.showsHeatmap = showsHeatmap
        self.zoomNamespace = zoomNamespace
        self.hero = hero
        self.floatsFilter = floatsFilter
        self.isSidebar = isSidebar
        self.searchQuery = searchQuery
    }
    @AppStorage("portfolio.holdings.mergeETF") private var mergesETF = false
    @AppStorage("portfolio.holdings.shows52Week") private var shows52Week = false
    @AppStorage("portfolio.holdings.showsVolume") private var showsVolume = false
    @AppStorage("portfolio.holdings.showsWeight") private var showsWeight = true
    @AppStorage("portfolio.holdings.showsTicker") private var showsTicker = true
    @AppStorage("portfolio.holdings.showsShares") private var showsShares = true
    @AppStorage("portfolio.holdings.showsPerformanceAmount") private var showsPerformanceAmount = true
    @AppStorage("portfolio.holdings.showsPerformancePercent") private var showsPerformancePercent = true
    @State private var selectedMergedRow: ETFLookThroughRow?
    private var showsMergedHoldings: Bool {
        mergesETF || LaunchArguments.contains("--show-merged-etf") || LaunchArguments.contains("--show-etf")
    }
    private var needsETFData: Bool {
        showsHeatmap ? heatmapLooksThroughETF : showsMergedHoldings
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
    @AppStorage("portfolio.holdings.sortField") private var holdingSortFieldRawValue = HoldingSortField.marketValue.rawValue
    @AppStorage("portfolio.holdings.sortAscending") private var holdingSortAscending = false
    @State private var holdingPerformancePeriod: HoldingPerformancePeriod = .holdingPeriod
    @State private var week52SortRanges: [String: Holding52WeekRange] = [:]
    @State private var isLoadingWeek52Sort = false
    @State private var week52SortGeneration = 0
    @State private var volumeSortRanges: [String: HoldingVolumeRange] = [:]
    @State private var isLoadingVolumeSort = false
    @State private var volumeSortGeneration = 0
    @State private var heatmapPerformancePeriod: HoldingPerformancePeriod = .today
    @State private var heatmapGroupsBySector = LaunchArguments.all
        .contains("--group-heatmap-by-sector")
    @State private var heatmapLooksThroughETF = LaunchArguments.all
        .contains("--look-through-heatmap-etf")

    var body: some View {
        Group {
            if isSidebar {
                sidebarSection
            } else if showsHeatmap, let hero {
                PerformanceHeatmapHero(
                    state: hero,
                    renderKey: heatmapRenderKey,
                    heatmap: { heatmapView(isSnapshot: $0) }
                )
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    if !showsHeatmap {
                        headerRow
                    } else if MacPlatform.isMac {
                        heatmapHeaderRow
                    }

                    Group {
                        if !showsHeatmap {
                            holdingsTable
                        } else {
                            heatmapView(isSnapshot: false)
                        }
                    }
                }
                .padding(.horizontal, CatfolioStyle.pageHorizontalInset)
                .padding(.top, topInset)
                .padding(.bottom, 18)
                // On a Mac Overview card the card is the ground, in the one
                // card colour every card there shares.
                .background(sitsOnMacOverviewCard
                    ? Color.clear
                    : (colorScheme == .light ? Color.white : Color(red: 0, green: 0.008, blue: 0)))
            }
        }
        .toolbar {
            // The Mac's heatmap card carries its filter in its own header.
            if showsHeatmap, hero?.isExpanded ?? true, !MacPlatform.isMac {
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
        .task(id: "\(needsETFData)-\(etfHoldingsKey)") {
            guard needsETFData,
                  etfResponse == nil || loadedETFHoldingsKey != etfHoldingsKey else { return }
            await loadETF()
        }
        .task(id: "daily-\(showsHeatmap)-\(showsMergedHoldings)-\(activePerformancePeriod.rawValue)-\(etfHoldingsKey)") {
            guard (showsHeatmap || showsMergedHoldings), activePerformancePeriod == .today else { return }
            await model.refreshHoldingDailyChanges()
        }
        .task(id: "heatmap-constituents-\(loadedETFHoldingsKey)-\(heatmapLooksThroughETF)-\(heatmapPerformancePeriod.rawValue)") {
            guard showsHeatmap, heatmapLooksThroughETF, heatmapPerformancePeriod == .today else { return }
            await loadETFConstituentDailyChanges()
        }
        .task(id: week52SortLoadKey) {
            week52SortGeneration &+= 1
            let generation = week52SortGeneration
            guard !week52SortLoadKey.isEmpty else { isLoadingWeek52Sort = false; return }
            isLoadingWeek52Sort = true
            defer { if generation == week52SortGeneration { isLoadingWeek52Sort = false } }
            let ranges = await Holding52WeekRange.load(week52SortRequests)
            guard !Task.isCancelled, generation == week52SortGeneration else { return }
            week52SortRanges = ranges
        }
        .task(id: volumeSortLoadKey) {
            volumeSortGeneration &+= 1
            let generation = volumeSortGeneration
            guard !volumeSortLoadKey.isEmpty else { isLoadingVolumeSort = false; return }
            isLoadingVolumeSort = true
            defer { if generation == volumeSortGeneration { isLoadingVolumeSort = false } }
            let ranges = await HoldingVolumeRange.load(week52SortRequests)
            guard !Task.isCancelled, generation == volumeSortGeneration else { return }
            volumeSortRanges = ranges
        }
        .appSheet(item: $selectedMergedRow) { row in
            HoldingAmountSourcesPage(ticker: row.ticker, initialRow: row)
        }
    }

    private func heatmapView(isSnapshot: Bool) -> HoldingsHeatmapView {
        HoldingsHeatmapView(
            holdings: holdings,
            dailyChanges: model.holdingDailyChanges,
            isLoading: !isSnapshot && (model.isPortfolioLoading || (heatmapLooksThroughETF && isLoadingETF)
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

    /// The list's name and its view menu, on the left of the header — and,
    /// once the header has scrolled away, floating at the top of the page.
    private var titleMenu: some View {
        Menu {
            Picker(L10n.text("持仓列表"), selection: Binding(get: { showsMergedHoldings }, set: { mergesETF = $0 })) {
                Text(L10n.text("持仓明细")).tag(false)
                Text(L10n.text("ETF 穿透")).tag(true)
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(L10n.text("显示股数"), isOn: $showsShares)
                .accessibilityIdentifier("portfolio-list-show-shares")
            Toggle(L10n.text("显示股票代码"), isOn: $showsTicker)
                .accessibilityIdentifier("portfolio-list-show-ticker")
            Toggle(L10n.text("显示占比"), isOn: $showsWeight)
                .accessibilityIdentifier("portfolio-list-show-weight")
            Toggle(L10n.text("显示涨跌幅"), isOn: $showsPerformancePercent)
                .accessibilityIdentifier("portfolio-list-show-performance-percent")
            Toggle(L10n.text("显示涨跌金额"), isOn: $showsPerformanceAmount)
                .accessibilityIdentifier("portfolio-list-show-performance-amount")
            // One of the two at a time: they share the row's right side.
            Toggle(L10n.text("52 周"), isOn: Binding(get: { shows52Week && !showsVolume }, set: {
                shows52Week = $0
                if $0 { showsVolume = false }
            }))
            Toggle(L10n.text("成交量"), isOn: Binding(get: { showsVolume }, set: {
                showsVolume = $0
                if $0 { shows52Week = false }
            }))
        } label: {
            // The list's name with the menu's arrow right after it; what
            // the menu chose goes on the line below, with the count and
            // the day. A title that never changes keeps the menu's
            // source bounds still.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    Text(tableTitle)
                        .font(Typography.text(size: 22, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)
                    Image("PortfolioHeaderDisclosure")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                .foregroundStyle(CatfolioTheme.primaryText)
                ZStack(alignment: .leading) {
                    Text("0").appText(.caption, weight: .medium)
                        .hidden().accessibilityHidden(true)
                    headerSubtitle
                }
            }
            .fixedSize(horizontal: true, vertical: true)
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            titleMenu

            Spacer()
            if isLoadingVolumeSort {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L10n.text("正在读取成交量分布…"))
            } else if isLoadingWeek52Sort {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L10n.text("正在读取 52 周范围…"))
            }
            filterMenu
                .accessibilityIdentifier("portfolio-inline-filter")
                .anchorPreference(key: PortfolioFloatingFilterPreference.self, value: .bounds) { anchor in
                    floatsFilter ? PortfolioFloatingFilterSource(bounds: anchor,
                        title: AnyView(titleMenu), menu: AnyView(filterMenu)) : nil
                }
        }
    }

    /// The Mac's heatmap card: its title, and its filter at the top right.
    private var heatmapHeaderRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(tableTitle)
                .font(Typography.text(size: 22, weight: .semibold))
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            filterMenu
                .accessibilityIdentifier("performance.heatmap.filter")
        }
    }

    @ViewBuilder
    private var filterMenu: some View {
        if !showsHeatmap {
            HoldingSortMenu(
                field: Binding(get: { holdingSortField }, set: { holdingSortFieldRawValue = $0.rawValue }),
                fields: sortFields,
                ascending: $holdingSortAscending,
                performancePeriod: $holdingPerformancePeriod,
                iconOnly: true,
                isSidebar: isSidebar
            )
        } else {
            HeatmapPerformancePeriodMenu(period: $heatmapPerformancePeriod,
                groupsBySector: $heatmapGroupsBySector, looksThroughETF: $heatmapLooksThroughETF)
        }
    }

    private var activePerformancePeriod: HoldingPerformancePeriod {
        showsHeatmap ? heatmapPerformancePeriod : holdingPerformancePeriod
    }

    /// On the Mac's Overview each card's first line sits the same distance
    /// below its top edge; the heatmap's title is centred on its taller
    /// filter button, so it starts higher to land on the same line.
    private var topInset: CGFloat {
        guard MacPlatform.isMac else { return 24 }
        return showsHeatmap ? 8 : 16
    }

    private var tableTitle: String {
        showsHeatmap ? L10n.text("持仓热力图") : L10n.text("持仓列表")
    }

    /// The list and column the menu chose, for the line under the title.
    private var modeLabels: [String] {
        guard !showsHeatmap else { return [] }
        var labels = [L10n.text(showsMergedHoldings ? "ETF 穿透" : "持仓明细")]
        if showsVolume { labels.append(L10n.text("成交量")) }
        else if shows52Week { labels.append(L10n.text("52 周")) }
        return labels
    }

    /// Rows in the list on screen; nil until an ETF breakdown has loaded.
    private var tableCount: Int? {
        guard !showsHeatmap else { return nil }
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return listItems.count }
        guard showsMergedHoldings else { return holdings.count }
        guard let exposures = listExposures, !exposures.isEmpty else { return nil }
        return exposures.count
    }

    /// The count, then what the rows measure: the day the latest figures are
    /// from — named as the header and the Today card name it — or 持有期.
    private var headerSubtitle: some View {
        let period: String? = switch activePerformancePeriod {
        case .today: model.latestSessionDate.map { DataDayLabel.text(for: $0, locale: appLocale) }
        case .holdingPeriod: L10n.text("持有期")
        }
        let parts = [tableCount.map(String.init)].compactMap { $0 } + modeLabels + [period].compactMap { $0 }
        return Text(parts.joined(separator: " · "))
            .appText(.caption, weight: .medium)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var listExposures: [ETFLookThroughRow]? {
        guard showsMergedHoldings, loadedETFHoldingsKey == etfHoldingsKey else { return nil }
        return etfResponse?.rows
    }

    private var unsortedListItems: [PortfolioHoldingListItem] {
        PortfolioHoldingListItem.make(holdings: holdings, exposures: listExposures,
            period: holdingPerformancePeriod, dailyChanges: model.holdingDailyChanges)
    }

    private var listItems: [PortfolioHoldingListItem] {
        PortfolioHoldingListItem.filtered(
            PortfolioHoldingListItem.sorted(unsortedListItems, by: holdingSortField, ascending: holdingSortAscending,
                week52Ranges: week52SortRanges, volumeRanges: volumeSortRanges),
            query: searchQuery)
    }

    private var volumeSortLoadKey: String {
        guard !showsHeatmap, holdingSortField == .volumeArea else { return "" }
        return "\(model.localUpdatedAt?.timeIntervalSince1970 ?? 0)|"
            + week52SortRequests.map { "\($0.ticker):\($0.currency)" }.joined(separator: "|")
    }

    private var week52SortRequests: [Holding52WeekRequest] {
        unsortedListItems.compactMap { Holding52WeekRequest(item: $0) }.sorted { $0.ticker < $1.ticker }
    }

    private var week52SortLoadKey: String {
        guard !showsHeatmap, holdingSortField == .week52Position else { return "" }
        return "\(model.localUpdatedAt?.timeIntervalSince1970 ?? 0)|"
            + week52SortRequests.map { "\($0.ticker):\($0.currency)" }.joined(separator: "|")
    }

    @ViewBuilder
    private var holdingsStatus: some View {
        if showsMergedHoldings {
            if let etfError, failedETFHoldingsKey == etfHoldingsKey {
                Text(L10n.message(etfError)).appText(.caption).foregroundStyle(.secondary)
            } else if listExposures == nil {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(L10n.text("正在计算 ETF 底层持仓…")).appText(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sidebarSection: some View {
        Section {
            holdingsStatus
            ForEach(listItems) { item in
                NavigationLink(value: WorkspaceSelection.holding(WorkspaceHoldingDestination(item: item))) {
                    holdingRow(item)
                }
                .accessibilityIdentifier("sidebar.holding.\(item.id)")
            }
            if listItems.isEmpty {
                if model.isPortfolioLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView.search(text: searchQuery)
                } else {
                    Text(L10n.text("暂无持仓数据")).foregroundStyle(.secondary)
                }
            }
        } header: {
            headerRow
                .textCase(nil)
                .padding(.vertical, 8)
                // Catalyst reserves 16pt after a section header but only 8pt
                // after a row, and ignores listRowInsets on this header.
                // Reclaim that extra space without moving its leading edge.
                .padding(.trailing, MacPlatform.isMac ? -8 : 0)
        }
        .environment(\.isSidebarHoldingRow, true)
        .accessibilityIdentifier("workspace.holdings")
    }

    @ViewBuilder
    private var holdingsTable: some View {
        holdingsStatus
        // Both modes keep the same row, zoom source and open action.
        // Until the current exposure data is ready, these are the direct holdings.
        LazyVStack(spacing: 4) {
            ForEach(listItems) { item in
                let detail = item.detailHolding
                Button {
                    if let detail { onSelect(detail) }
                    else if case let .exposure(row, _, _, _) = item { selectedMergedRow = row }
                } label: {
                    holdingRow(item)
                }
                .buttonStyle(HoldingPressButtonStyle())
                .holdingZoomSource(item.ticker, in: detail == nil ? nil : zoomNamespace)
            }
        }
    }

    @ViewBuilder
    private func holdingRow(_ item: PortfolioHoldingListItem) -> some View {
        if showsVolume {
            HoldingVolumeRow(item: item, performancePeriod: holdingPerformancePeriod,
                showsWeight: showsWeight, showsTicker: showsTicker, showsShares: showsShares,
                showsPerformanceAmount: showsPerformanceAmount, showsPerformancePercent: showsPerformancePercent,
                suppliedRange: holdingSortField == .volumeArea ? volumeSortRanges[item.ticker.uppercased()] : nil,
                loadsRange: holdingSortField != .volumeArea)
        } else if shows52Week {
            Holding52WeekRow(item: item, performancePeriod: holdingPerformancePeriod,
                showsWeight: showsWeight, showsTicker: showsTicker, showsShares: showsShares,
                showsPerformanceAmount: showsPerformanceAmount, showsPerformancePercent: showsPerformancePercent,
                suppliedRange: holdingSortField == .week52Position ? week52SortRanges[item.ticker.uppercased()] : nil,
                loadsRange: holdingSortField != .week52Position)
        } else {
            HoldingRow(item: item, performancePeriod: holdingPerformancePeriod, showsWeight: showsWeight, showsTicker: showsTicker, showsShares: showsShares,
                showsPerformanceAmount: showsPerformanceAmount, showsPerformancePercent: showsPerformancePercent)
        }
    }

    /// A sort that belongs to a hidden column falls back to market value
    /// while that column is off, and comes back with it.
    private var holdingSortField: HoldingSortField {
        let saved = HoldingSortField(rawValue: holdingSortFieldRawValue) ?? .marketValue
        return sortFields.contains(saved) ? saved : .marketValue
    }

    private var sortFields: [HoldingSortField] {
        HoldingSortField.available(shows52Week: shows52Week && !showsVolume, showsVolume: showsVolume)
    }

    private var etfHoldingsKey: String {
        "\(model.portfolioSource)|" + model.selectedAccountKeys.sorted().joined(separator: ",") + "|" + holdings.map {
            "\($0.ticker):\($0.shares):\($0.quotePrice):\($0.averageCost):\($0.costCurrency ?? ""):\($0.quoteCurrency ?? ""):\($0.marketValue):\($0.unrealized)"
        }.joined(separator: "|")
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
