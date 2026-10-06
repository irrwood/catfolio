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
    }
    @AppStorage("portfolio.holdings.mergeETF") private var mergesETF = false
    @AppStorage("portfolio.holdings.shows52Week") private var shows52Week = false
    @AppStorage("portfolio.holdings.showsVolume") private var showsVolume = false
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
    @State private var headerUsesGlass = false
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
                        if !showsHeatmap {
                            holdingsTable
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
                } label: {
                    Label(L10n.text("持仓明细"), systemImage: !showsMergedHoldings ? "checkmark" : "list.bullet")
                }
                // One look-through list: what was "合并穿透" and "ETF 穿透".
                Button {
                    mergesETF = true
                } label: {
                    Label(L10n.text("ETF 穿透"), systemImage: showsMergedHoldings ? "checkmark" : "square.3.layers.3d")
                }
                Divider()
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
            if isLoadingVolumeSort {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L10n.text("正在读取成交量分布…"))
            } else if isLoadingWeek52Sort {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(L10n.text("正在读取 52 周范围…"))
            }
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
        if !showsHeatmap {
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

    private var activePerformancePeriod: HoldingPerformancePeriod {
        showsHeatmap ? heatmapPerformancePeriod : holdingPerformancePeriod
    }

    private var tableTitle: String {
        showsHeatmap ? L10n.text("持仓热力图")
            : L10n.text(showsMergedHoldings ? "ETF 穿透" : "持仓列表")
    }

    /// Rows in the list on screen; nil until an ETF breakdown has loaded.
    private var tableCount: Int? {
        guard !showsHeatmap else { return nil }
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
        let parts = [tableCount.map(String.init), period].compactMap { $0 }
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
        PortfolioHoldingListItem.sorted(unsortedListItems, by: holdingSortField, ascending: holdingSortAscending,
            week52Ranges: week52SortRanges, volumeRanges: volumeSortRanges)
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
    private var holdingsTable: some View {
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
        // Both modes keep the same row, zoom source and open action.
        // Until the current exposure data is ready, these are the direct holdings.
        LazyVStack(spacing: 4) {
            ForEach(listItems) { item in
                let detail = item.detailHolding
                Button {
                    if let detail { onSelect(detail) }
                    else if case let .exposure(row, _, _, _) = item { selectedMergedRow = row }
                } label: {
                    if showsVolume {
                        HoldingVolumeRow(item: item, performancePeriod: holdingPerformancePeriod,
                            suppliedRange: holdingSortField == .volumeArea ? volumeSortRanges[item.ticker.uppercased()] : nil,
                            loadsRange: holdingSortField != .volumeArea)
                    } else if shows52Week {
                        Holding52WeekRow(item: item, performancePeriod: holdingPerformancePeriod,
                            suppliedRange: holdingSortField == .week52Position ? week52SortRanges[item.ticker.uppercased()] : nil,
                            loadsRange: holdingSortField != .week52Position)
                    } else {
                        HoldingRow(item: item, performancePeriod: holdingPerformancePeriod)
                    }
                }
                .buttonStyle(HoldingPressButtonStyle())
                .holdingZoomSource(item.ticker, in: detail == nil ? nil : zoomNamespace)
            }
        }
    }

    private var holdingSortField: HoldingSortField {
        HoldingSortField(rawValue: holdingSortFieldRawValue) ?? .marketValue
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

enum HoldingSortField: String, CaseIterable, Identifiable {
    case marketValue
    case unrealized
    case unrealizedPercent
    case week52Position
    case volumeArea
    case name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .marketValue: L10n.text("市值")
        case .unrealized: L10n.text("盈利")
        case .unrealizedPercent: L10n.text("收益率")
        case .week52Position: L10n.text("52 周位置")
        case .volumeArea: L10n.text("成交密集区位置")
        case .name: L10n.text("名称")
        }
    }

    var compactTitle: String {
        switch self {
        case .marketValue: L10n.text("Mkt Cap")
        case .unrealized: L10n.text("P&L")
        case .unrealizedPercent: L10n.text("Return")
        case .week52Position: L10n.text("52 周位置")
        case .volumeArea: L10n.text("成交密集区位置")
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
    @Environment(\.securityDetailZoomOrigin) private var zoomOrigin
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: PortfolioHoldingListItem
    let performancePeriod: HoldingPerformancePeriod
    let week52: Holding52WeekPrices?
    let volume: HoldingVolumePrices?

    init(item: PortfolioHoldingListItem, performancePeriod: HoldingPerformancePeriod,
         week52: Holding52WeekPrices? = nil, volume: HoldingVolumePrices? = nil) {
        self.item = item
        self.performancePeriod = performancePeriod
        self.week52 = week52
        self.volume = volume
    }

    init(holding: Holding, performancePeriod: HoldingPerformancePeriod, dailyChangePercent: Double?) {
        self.init(item: .holding(holding, performance: holding.performanceValues(
            for: performancePeriod, dailyChangePercent: dailyChangePercent)), performancePeriod: performancePeriod)
    }

    @ViewBuilder
    var body: some View {
        if let volume {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name + "，" + item.ticker)
                .accessibilityValue(volumeDescription(volume))
                .accessibilityHint(L10n.text(item.ticker == "ETF 其他" ? "金额来源" : "打开个股"))
        } else if let week52 {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item.name + "，" + item.ticker)
                .accessibilityValue(week52Description(week52))
                .accessibilityHint(L10n.text(item.ticker == "ETF 其他" ? "金额来源" : "打开个股"))
        } else if case let .holding(holding, _) = item {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("\(holding.shortName)，\(DisplayFormat.listShares(holding.shares, compact: false, locale: appLocale)) 股 \(holding.ticker)，市值 \(DisplayFormat.money(holding.marketValue))，\(performancePeriod.title)盈亏 \(profitDescription)"))
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityHint(L10n.text(item.ticker == "ETF 其他" ? "金额来源" : "打开个股"))
        }
    }

    private var content: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibleContent
            } else {
                HStack(alignment: .center, spacing: 10) {
                    logo
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .center, spacing: 8) {
                                SecurityDisplayName(name: item.name, scale: .body, weight: .semibold,
                                                    showsClassMarkers: false)
                                    .layoutPriority(1)
                                Spacer(minLength: 4)
                                // Keep the existing 1pt optical alignment of the number.
                                if let volume {
                                    price(volume.current, currency: volume.currency, isCost: false).offset(y: -1)
                                } else if let week52 {
                                    price(week52.current, currency: week52.currency, isCost: false).offset(y: -1)
                                } else {
                                    amount.offset(y: -1)
                                }
                            }
                            HStack(alignment: .center, spacing: 5) {
                                subtitle
                                Spacer(minLength: 2)
                                if let volume {
                                    price(volume.cost, currency: volume.currency, isCost: true)
                                } else if let week52 {
                                    price(week52.cost, currency: week52.currency, isCost: true)
                                } else {
                                    HoldingPerformanceLabel(performance: item.performance)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let volume { HoldingVolumeProfileBar(prices: volume) }
                        else if let week52 { Holding52WeekBar(positions: week52.positions) }
                    }
                }
            }
        }
        .frame(minHeight: 64)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var accessibleContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                logo
                if case let .holding(holding, _) = item {
                    HoldingIdentity(holding: holding, compact: false)
                } else {
                    SecurityDisplayName(name: item.name, scale: .body, weight: .semibold, singleLine: false)
                }
            }
            if let volume {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("现价") + " " + priceText(volume.current, currency: volume.currency))
                            .appNumber(.callout, weight: .semibold)
                        Text(L10n.text("成本价") + " " + priceText(volume.cost, currency: volume.currency))
                            .appNumber(.footnote, weight: .medium).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    HoldingVolumeProfileBar(prices: volume)
                }
            } else if let week52 {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("现价") + " " + priceText(week52.current, currency: week52.currency))
                            .appNumber(.callout, weight: .semibold)
                        Text(L10n.text("成本价") + " " + priceText(week52.cost, currency: week52.currency))
                            .appNumber(.footnote, weight: .medium).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Holding52WeekBar(positions: week52.positions)
                }
            } else if case let .holding(holding, _) = item {
                HoldingMetrics(holding: holding, performance: item.performance, period: performancePeriod,
                               alignment: .leading, compact: false)
            } else {
                amount
                subtitle
                HoldingPerformanceLabel(performance: item.performance)
            }
        }
    }

    private var logo: some View {
        AssetLogo(ticker: item.ticker, logoSymbol: item.logoSymbol, size: 44, cornerRadius: 12)
            .securityDetailLogoSource(item.ticker, in: zoomOrigin)
    }

    @ViewBuilder
    private var amount: some View {
        let text = Text(item.displayedMarketValue)
            .appNumber(.callout, weight: .semibold)
            .foregroundStyle(CatfolioTheme.primaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        if case .holding = item { text.numericTransition(item.marketValue) }
        else { text }
    }

    private var subtitle: some View {
        Group {
            switch item {
            case let .holding(holding, _):
                HStack(spacing: 2) {
                    Text(DisplayFormat.listShares(holding.shares, locale: appLocale))
                        .appNumber(.footnote, weight: .medium, monospaced: false)
                    Text(holding.ticker).appText(.footnote, weight: .medium)
                    SecurityClassBadges(markers: holding.classMarkers)
                }
            case let .exposure(row, _, total, _):
                let ticker = row.ticker == "ETF 其他" ? L10n.text("ETF 其他") : row.ticker
                let weight = total.isFinite && total > 0 && row.totalUSD.isFinite
                    ? DisplayFormat.percent(row.totalUSD / total * 100, signed: false) : "—"
                Text("\(ticker) · \(weight)")
                    .appText(.footnote, weight: .medium)
                    .accessibilityLabel(L10n.text("\(ticker)，") + L10n.text("\(weight) · 组合占比"))
            }
        }
        .foregroundStyle(Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255))
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var profitDescription: String {
        guard let performance = item.performance else { return L10n.text("暂无数据") }
        return "\(DisplayFormat.money(performance.amount, signed: true, fractionDigits: 2)) · \(DisplayFormat.percent(performance.percent))"
    }

    private func price(_ value: Double?, currency: String?, isCost: Bool) -> some View {
        Text(priceText(value, currency: currency))
            .appNumber(isCost ? .footnote : .callout, weight: isCost ? .medium : .semibold)
            .foregroundStyle(isCost ? Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255) : CatfolioTheme.primaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func priceText(_ value: Double?, currency: String?) -> String {
        guard let value, let currency else { return "—" }
        return DisplayFormat.money(value, currency: currency)
    }

    private func volumeDescription(_ prices: HoldingVolumePrices) -> String {
        var parts = [L10n.text("现价") + " " + priceText(prices.current, currency: prices.currency),
                     L10n.text("成本价") + " " + priceText(prices.cost, currency: prices.currency)]
        if let range = prices.range {
            parts.append(L10n.text("成交密集区") + " " + priceText(range.valueAreaLow, currency: range.currency)
                + " – " + priceText(range.valueAreaHigh, currency: range.currency))
            parts.append(L10n.text("成交最密集") + " " + priceText(range.pointOfControl, currency: range.currency))
        } else {
            parts.append(L10n.text("成交量分布暂无数据"))
        }
        return parts.joined(separator: "，")
    }

    private func week52Description(_ prices: Holding52WeekPrices) -> String {
        var parts = [L10n.text("现价") + " " + priceText(prices.current, currency: prices.currency),
                     L10n.text("成本价") + " " + priceText(prices.cost, currency: prices.currency)]
        if let range = prices.range {
            parts.append(L10n.text("52 周范围") + " " + priceText(range.low, currency: range.currency)
                + " – " + priceText(range.high, currency: range.currency))
            if let start = range.startPrice {
                parts.append(L10n.text("期初价") + " " + priceText(start, currency: range.currency))
            }
        } else {
            parts.append(L10n.text("52 周范围暂无数据"))
        }
        return parts.joined(separator: "，")
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

struct SecurityDisplayName: View {
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

/// Whether a listing's exchange is in its regular session now, from the
/// ticker's market suffix. Weekends count as closed; exchange holidays are
/// not known here and read as open.
enum MarketHours {
    private struct Session {
        let timeZone: String
        let open: Int   // minutes after midnight, local
        let close: Int
    }

    private static func session(for ticker: String) -> Session {
        let symbol = ticker.uppercased()
        func local(_ zone: String, _ open: (Int, Int), _ close: (Int, Int)) -> Session {
            Session(timeZone: zone, open: open.0 * 60 + open.1, close: close.0 * 60 + close.1)
        }
        if symbol.hasSuffix(".L") { return local("Europe/London", (8, 0), (16, 30)) }
        if symbol.hasSuffix(".DE") || symbol.hasSuffix(".F") { return local("Europe/Berlin", (9, 0), (17, 30)) }
        if symbol.hasSuffix(".PA") || symbol.hasSuffix(".AS") || symbol.hasSuffix(".BR") || symbol.hasSuffix(".LS") {
            return local("Europe/Paris", (9, 0), (17, 30))
        }
        if symbol.hasSuffix(".MI") { return local("Europe/Rome", (9, 0), (17, 30)) }
        if symbol.hasSuffix(".MC") { return local("Europe/Madrid", (9, 0), (17, 30)) }
        if symbol.hasSuffix(".SW") { return local("Europe/Zurich", (9, 0), (17, 30)) }
        if symbol.hasSuffix(".CO") { return local("Europe/Copenhagen", (9, 0), (17, 0)) }
        if symbol.hasSuffix(".ST") { return local("Europe/Stockholm", (9, 0), (17, 30)) }
        if symbol.hasSuffix(".HK") { return local("Asia/Hong_Kong", (9, 30), (16, 0)) }
        if symbol.hasSuffix(".T") { return local("Asia/Tokyo", (9, 0), (15, 30)) }
        if symbol.hasSuffix(".TO") { return local("America/Toronto", (9, 30), (16, 0)) }
        return local("America/New_York", (9, 30), (16, 0))
    }

    static func isOpen(ticker: String, at date: Date = Date()) -> Bool {
        let session = session(for: ticker)
        guard let zone = TimeZone(identifier: session.timeZone) else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, (2...6).contains(weekday) else { return false }
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return minute >= session.open && minute < session.close
    }
}

/// Outside the listing's trading session: a moon, in the class badge's shape,
/// purple on a pale purple ground. Checks again every minute.
struct MarketClosedBadge: View {
    let ticker: String
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var badgeHeight: CGFloat = 18
    private let purple = Color(red: 0.545, green: 0.361, blue: 0.965)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if !MarketHours.isOpen(ticker: ticker, at: context.date) {
                HStack(spacing: 2) {
                    Image(systemName: "moon.fill").font(.system(size: 9, weight: .semibold))
                    Text(L10n.text("休市")).appText(.caption, weight: .medium)
                }
                .foregroundStyle(purple)
                .padding(.horizontal, 4)
                .frame(height: badgeHeight)
                .background(purple.opacity(colorScheme == .dark ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: 3))
                .fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.text("非交易时段"))
            }
        }
    }
}
