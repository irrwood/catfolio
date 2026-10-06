import SwiftUI
import Charts
import CryptoKit
import Observation

actor ResearchAnalysisCache {
    static let shared = ResearchAnalysisCache()
    private let directory: URL

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("research-analysis-v1", isDirectory: true)) {
        self.directory = directory
    }

    private func file(for scope: String) -> URL {
        let key = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key).appendingPathExtension("json")
    }

    func load(scope: String) -> PortfolioAttentionReport? {
        guard let data = try? Data(contentsOf: file(for: scope)) else { return nil }
        return try? JSONDecoder().decode(PortfolioAttentionReport.self, from: data)
    }

    /// The account scope a report is saved under: the language, demo or real
    /// data, and the selected accounts. Shared by the attention page and its
    /// preview on the Performance tab, so both read the same report.
    @MainActor static func scope(locale: Locale, model: AppModel) -> String {
        let keys = [locale.identifier, model.isFakeDataMode ? "demo" : "real"] + model.selectedAccountKeys.sorted()
        return keys.map { "\($0.utf8.count):\($0)" }.joined()
    }

    func save(_ report: PortfolioAttentionReport, scope: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: file(for: scope), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

/// Research is read-only: market context and selected-account holdings never
/// write into the portfolio ledger. Historical closes are not live quotes.
struct ResearchMarketSnapshot: Identifiable {
    struct Point: Identifiable {
        let id: String
        let value: Double
    }
    let id: String
    let title: String
    let points: [Point]
    var latest: Point? { points.last }
    var changeBasisPoints: Double? {
        guard points.count >= 2 else { return nil }
        return (points[points.count - 1].value - points[points.count - 2].value) * 100
    }
    var changePercent: Double? {
        guard points.count >= 2, points[points.count - 2].value > 0 else { return nil }
        return (points[points.count - 1].value / points[points.count - 2].value - 1) * 100
    }

    init(id: String, title: String, history: [String: Double]) {
        self.id = id
        self.title = title
        points = history.filter { $0.value.isFinite && $0.value > 0 }
            .sorted { $0.key < $1.key }.map { Point(id: $0.key, value: $0.value) }
    }
}

/// Figma 264:13428: a coloured title, one quote row, and a 53pt sparkline.
/// Series colours identify the metric; the badge and change express direction.
struct ResearchMetricCard: View {
    let symbol: String
    let title: String
    let snapshot: ResearchMarketSnapshot?
    var isLoading = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var titleSize = 16.0
    @ScaledMetric(relativeTo: .title3) private var valueSize = 20.0
    @ScaledMetric(relativeTo: .subheadline) private var changeSize = 14.0

    private var seriesColor: Color {
        switch symbol {
        case "^GSPC": CatfolioTheme.accent
        case "^IXIC": CatfolioTheme.services
        case "^VIX": CatfolioTheme.warning
        // This card's purple is specified directly in the Figma reference.
        default: Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255)
        }
    }
    private var displayTitle: String {
        symbol == "^TNX" ? L10n.text("美国 10 年期国债") : title
    }
    private var showsSkeleton: Bool { isLoading && snapshot == nil }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(displayTitle)
                    .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(seriesColor)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.8)
                    .redacted(reason: showsSkeleton ? .placeholder : [])
                    .chartLoadingShimmer(active: showsSkeleton, appearanceID: "research-metric|\(symbol)")

                // Set like the macro cards below: the value, then its move
                // in quiet grey on the same baseline.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    quote
                    change
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .chartLoadingShimmer(active: showsSkeleton, appearanceID: "research-metric|\(symbol)")

                sparkline
                    .frame(height: 53)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("research-metric-\(symbol)")
    }

    @ViewBuilder private var quote: some View {
        if let value = snapshot?.latest?.value {
            Text(symbol == "^TNX"
                 ? (value / 100).formatted(.percent.precision(.fractionLength(2)))
                 : value.formatted(.number.precision(.fractionLength(2))))
                .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        } else if showsSkeleton {
            ChartSkeletonShape(width: 82, height: valueSize)
        } else {
            Text(L10n.text("暂无数据"))
                .font(.system(size: changeSize, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var change: some View {
        if showsSkeleton {
            ChartSkeletonShape(width: 42, height: changeSize)
        } else if let value = snapshot?.changePercent {
            Text(DisplayFormat.percent(value, signed: true))
                .font(.system(size: changeSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    @ViewBuilder private var sparkline: some View {
        if let snapshot, snapshot.points.count > 1 {
            let domain = StandardLineChartEntrancePhase.domain(snapshot.points.map(\.value))
            StandardLineChartEntrance(appearanceID: "research-metric|\(symbol)") { phase in
                Chart(Array(snapshot.points.enumerated()), id: \.element.id) { item in
                    LineMark(x: .value(L10n.text("日期"), item.offset),
                             y: .value(L10n.text("收盘"), phase.value(item.element.value,
                                fraction: Double(item.offset) / Double(snapshot.points.count - 1), domain: domain)))
                        .foregroundStyle(seriesColor)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: 0...(snapshot.points.count - 1))
                .chartYScale(domain: domain)
                .padding(.horizontal, 3)
                .padding(.vertical, 5)
                .accessibilityLabel(L10n.text("\(title)最近收盘走势"))
                .accessibilityValue("\(snapshot.points.first?.id ?? "") – \(snapshot.latest?.id ?? "")")
            }
        } else if showsSkeleton {
            StandardLineChartSkeleton(axisWidth: 0, topInset: 5, bottomHeight: 5,
                lineWidths: [3], appearanceID: "research-metric|\(symbol)")
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }
}

/// One security from the offline directory, ready to open in the detail
/// sheet whether or not anything is held.
struct MarketSecurityResult: Identifiable, Equatable, Sendable {
    let ticker: String
    let name: String
    let market: String
    let exchange: String?
    let currency: String?
    let sector: String?
    let isFund: Bool
    var id: String { ticker }

    /// Where it trades, short: the exchange in the US, the market elsewhere,
    /// whose own exchange names run too long for a row.
    var venue: String {
        let place = market == "US" ? exchange ?? market : market
        return isFund ? "ETF · \(place)" : place
    }

    static func search(
        _ query: String,
        in catalog: CompanyReferenceCatalog,
        limit: Int = 40,
        shouldCancel: () -> Bool = { false }
    ) -> [Self] {
        catalog.search(query, limit: limit, shouldCancel: shouldCancel).map { entry in
            Self(
                ticker: catalog.brokerSymbol(for: entry),
                name: entry.name ?? entry.symbol,
                market: entry.market,
                exchange: entry.exchange,
                currency: entry.currency ?? CompanyReferenceCatalog.listingCurrency(market: entry.market),
                sector: entry.sector,
                isFund: HoldingSecurityKind.classify(instrumentType: entry.instrumentType, names: [entry.name ?? ""]) == .fund
            )
        }
    }

    /// No shares and no cost, the same shape as an ETF look-through
    /// constituent: the detail sheet leaves its position blocks out rather
    /// than showing zeros.
    var holding: Holding {
        Holding(
            ticker: ticker,
            logoSymbol: ticker,
            displayName: name,
            sector: sector,
            source: nil,
            shares: 0,
            averageCost: 0,
            costCurrency: nil,
            quotePrice: 0,
            quoteCurrency: currency,
            todayChangePercent: nil,
            marketValue: 0,
            weight: 0,
            unrealized: 0,
            unrealizedPercent: 0,
            fxPnl: nil,
            fxPnlPercent: nil,
            fxPnlStatus: nil,
            fxPnlSource: nil
        )
    }
}

struct TodayAttentionView: View {
    var body: some View {
        ResearchView(showsAttention: true)
            .hidesTabBarWhenPushed()
    }
}

/// Today's attention, on the Performance tab itself: the last analysis's
/// three most pressing holdings — high attention first — under a heading
/// whose "更多" opens the full attention page.
struct TodayAttentionPreview: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @State private var report: PortfolioAttentionReport?
    @State private var hasLoaded = false
    /// Off when a tabbed header above it already names the section.
    var showsHeader = true

    private static let limit = 3

    /// High attention before medium, each in the report's own order.
    private var rows: [PortfolioAttentionHolding] {
        let rows = report?.attentionRows ?? []
        return Array((rows.filter { $0.attention == .high } + rows.filter { $0.attention != .high })
            .prefix(Self.limit))
    }

    var body: some View {
        Group {
            if showsHeader {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("今天值得关注"))
                    .appText(.body, weight: .medium)
                    .foregroundStyle(SettingsTemplate.sectionHeader)
                Spacer(minLength: 12)
                NavigationLink {
                    TodayAttentionView()
                } label: {
                    HStack(spacing: 3) {
                        Text(L10n.text("更多"))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .appText(.footnote, weight: .medium)
                    .foregroundStyle(SettingsTemplate.sectionHeader)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("performance.today-attention")
            }
            .padding(.top, SettingsTemplate.sectionHeaderTopSpacing)
            } else {
                // Without its header the group can be empty until the report
                // loads, and an empty group carries no task to load it.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }

            if !rows.isEmpty {
                // A row of cards, one screen wide less a glimpse of the next,
                // snapping card by card. It runs to the screen's edges and
                // keeps the page's margin as its content margin, so the first
                // card lines up with everything else and the last can be
                // scrolled fully into view.
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(rows) { row in
                            PortfolioAttentionCard(row: row)
                                .containerRelativeFrame(.horizontal) { width, _ in
                                    rows.count > 1 ? width - SettingsTemplate.pageInset * 2 - 28
                                                   : width - SettingsTemplate.pageInset * 2
                                }
                                .frame(maxHeight: .infinity, alignment: .top)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, SettingsTemplate.pageInset, for: .scrollContent)
                // Always opens on the first — the most pressing — card.
                .defaultScrollAnchor(.leading)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                // The glass's rim and shadow reach past each card.
                .scrollClipDisabled()
                .padding(.horizontal, -SettingsTemplate.pageInset)
            } else if hasLoaded {
                // Nothing analysed yet for these accounts: the way in is the
                // same page "更多" opens.
                SettingsCard {
                    SettingsNavigationRow(icon: .symbol("sparkles"), title: L10n.text("还没有今天的分析"),
                                          subtitle: L10n.text("在更多里分析持仓")) {
                        TodayAttentionView()
                    }
                }
            }
        }
        .environment(\.attentionEvidenceEditor, AttentionEvidenceEditor { updated in
            guard var current = report,
                  let index = current.attentionRows.firstIndex(where: { $0.id == updated.id }) else { return }
            current.attentionRows[index] = updated
            report = current
            let scope = ResearchAnalysisCache.scope(locale: appLocale, model: model)
            Task { try? await ResearchAnalysisCache.shared.save(current, scope: scope) }
        })
        // Again on every return, so an analysis run on the full page shows.
        .task(id: ResearchAnalysisCache.scope(locale: appLocale, model: model)) {
            let scope = ResearchAnalysisCache.scope(locale: appLocale, model: model)
            var loaded = await ResearchAnalysisCache.shared.load(scope: scope)
            #if DEBUG
            // The demo only where nothing is saved, so a follow-up asked on
            // the demo is still there on return.
            if LaunchArguments.contains("--preview-research-analysis"), loaded == nil {
                loaded = PortfolioAttentionCard.researchPreviewReport
            }
            #endif
            guard !Task.isCancelled else { return }
            report = loaded
            hasLoaded = true
        }
    }
}

/// The system search field for both pages. Research keeps it under the
/// large title, where tapping it collapses the title and moves the glass
/// field to the top; the attention page filters with the default placement.
private struct ResearchSystemSearch: ViewModifier {
    let showsAttention: Bool
    @Binding var query: String
    @Binding var isPresented: Bool
    var isFocused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if showsAttention {
            content.searchable(text: $query, prompt: L10n.text("搜索持仓"))
        } else {
            content
                .searchable(text: $query, isPresented: $isPresented,
                            placement: .navigationBarDrawer(displayMode: .always),
                            prompt: L10n.text("搜索股票、ETF 或公司名"))
                .searchFocused(isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

private struct ResearchMarketRefreshModifier: ViewModifier {
    let enabled: Bool
    let refresh: () async -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.refreshable { await refresh() }
        } else {
            content
        }
    }
}

struct ResearchView: View {
    var showsAttention = false
    @Environment(\.locale) private var appLocale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var query = ""
    @State private var searchResults: [MarketSecurityResult] = []
    /// The query `searchResults` answer, so a stale list is not mistaken
    /// for an empty one while the next search runs.
    @State private var searchedQuery = ""
    /// Whether the directory has more matches than `searchResults` shows.
    @State private var hasMoreSearchResults = false
    /// A query the reader asked to see more of, and how many rows it shows.
    /// Any other query starts from one page, so a keystroke never builds
    /// more rows than a screen holds.
    @State private var expandedSearch: ExpandedSearch?
    @State private var selectedSecurity: Holding?
    @FocusState private var isSearchFocused: Bool
    @State private var isSearchPresented = false
    @State private var markets: [ResearchMarketSnapshot] = []
    @State private var isLoading = false
    @State private var report: PortfolioAttentionReport?
    @State private var analysisTask: Task<Void, Never>?
    @State private var isAnalyzing = false
    @State private var isRestoringReport = true
    @State private var analysisRequestID = UUID()
    @State private var analysisError: String?
    @State private var showsRules = false
    @State private var showsDCA = false
    /// The first refresh is the page opening; later ones are pulls.
    @State private var hasRefreshedMarkets = false
    @AppStorage("research.highAttentionOnly") private var highAttentionOnly = false
    @AppStorage("research.maximumResults") private var maximumResults = 6
    @AppStorage(AttentionEvidenceRules.maximumAgeKey) private var evidenceMaximumAge = 30
    @AppStorage(AttentionEvidenceRules.reliableOnlyKey) private var evidenceReliableOnly = false
    @AppStorage(AttentionEvidenceRules.excludeAggregatorsKey) private var evidenceExcludesAggregators = true

    private static var benchmarks: [(String, String)] { [("^GSPC", "S&P 500"), ("^IXIC", "NASDAQ"), ("^VIX", L10n.text("VIX 波动率")), ("^TNX", L10n.text("美国 10 年期国债收益率"))] }

    private var accountScope: String {
        ResearchAnalysisCache.scope(locale: appLocale, model: model)
    }
    private func matches(_ text: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || text.localizedCaseInsensitiveContains(needle)
    }
    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Research searches the whole directory; the attention page still
    /// filters its own results with the same field.
    private var isSearchingMarket: Bool { !showsAttention && !searchText.isEmpty }
    private struct ExpandedSearch: Equatable { let query: String; let limit: Int }
    private static let searchPageSize = 15
    private static let searchPageStep = 25
    private var searchLimit: Int {
        expandedSearch.flatMap { $0.query == searchText ? $0.limit : nil } ?? Self.searchPageSize
    }

    private var analysisRows: [PortfolioAttentionHolding] {
        Array((report?.attentionRows ?? []).filter {
            matches("\($0.ticker) \($0.name)") && (!highAttentionOnly || $0.attention == .high)
        }.prefix(maximumResults))
    }

    var body: some View {
        ScrollViewReader { scroll in
        Group {
            if showsAttention {
                attentionList
            } else {
                researchPage
            }
        }
        // A holding's evidence, adjusted on its reading page, is kept in the
        // saved analysis the page shows.
        .environment(\.attentionEvidenceEditor, showsAttention ? AttentionEvidenceEditor { updated in
            guard var current = report,
                  let index = current.attentionRows.firstIndex(where: { $0.id == updated.id }) else { return }
            current.attentionRows[index] = updated
            report = current
            let scope = accountScope
            Task { try? await ResearchAnalysisCache.shared.save(current, scope: scope) }
        } : nil)
        .tracksRootTabBarScroll()
        .navigationTitle(L10n.text(showsAttention ? "今天值得关注" : "研究"))
        .navigationBarTitleDisplayMode(.large)
        .toolbarVisibility(.visible, for: .navigationBar)
        // Research searches the market from the bar; the pushed attention
        // page filters its own results and keeps its rule controls.
        .modifier(ResearchSystemSearch(showsAttention: showsAttention, query: $query,
                                       isPresented: $isSearchPresented, isFocused: $isSearchFocused))
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            if showsAttention {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("编辑规则"), systemImage: "slider.horizontal.3") { showsRules = true }
            }
            }
        }
        .appSheet(isPresented: $showsRules) {
            NavigationStack {
                Form {
                    Section(L10n.text("分析结果筛选")) {
                        Toggle(L10n.text("仅显示高关注"), isOn: $highAttentionOnly)
                        Picker(L10n.text("最多显示"), selection: $maximumResults) {
                            Text(L10n.text("3 项")).tag(3)
                            Text(L10n.text("6 项")).tag(6)
                            Text(L10n.text("12 项")).tag(12)
                        }
                    }
                    Section {
                        Picker(L10n.text("证据最长时效"), selection: $evidenceMaximumAge) {
                            ForEach(AttentionEvidenceRules.ageChoices, id: \.self) { days in
                                Text(L10n.text("\(days) 天")).tag(days)
                            }
                        }
                        Toggle(L10n.text("只用一手来源和通讯社"), isOn: $evidenceReliableOnly)
                        Toggle(L10n.text("排除转述网站"), isOn: $evidenceExcludesAggregators)
                    } header: {
                        Text(L10n.text("证据规则"))
                    } footer: {
                        Text(L10n.text("一手来源指公司公告、SEC 文件和新闻稿通道；通讯社指路透、彭博、美联社等。转述网站如 StockStory、StockTitan、Simply Wall St，只会转写别人的报道。下次刷新分析时生效。"))
                    }
                    AttentionSignalRulesSections()
                    Section {
                        Text(L10n.text("规则保存在本机。结果筛选只控制显示；证据规则决定下次分析能用哪些资料，所以会影响结论和置信度。账户范围在设置中选择，新闻来源和屏蔽网站在 设置 › 新闻 中选择。"))
                            .foregroundStyle(.secondary)
                    }
                }
                .softTopScrollEdge()
                .appPageBackground().navigationTitle(L10n.text("研究规则"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    AppModalDoneButton { showsRules = false }
                } }
            }
        }
        .navigationDestination(isPresented: $showsDCA) {
            DCACalculatorView()
                .hidesTabBarWhenPushed()
        }
        .sheet(item: $selectedSecurity) { holding in
            HoldingDetailView(holding: holding, onClose: { selectedSecurity = nil })
                .environment(model)
                .securityDetailSheet()
        }
        .securityDetailOpenFeedback(trigger: selectedSecurity?.ticker, enabled: hapticsEnabled)
        .task(id: showsAttention ? "" : "\(searchLimit)|\(searchText)") { await searchMarket() }
        .task {
            // The first keystroke would otherwise wait on folding every name
            // in the directory.
            guard !showsAttention else { return }
            await Task.detached(priority: .utility) {
                (try? CompanyReferenceCatalog.bundled.get())?.prepareSearch()
            }.value
        }
        .task { if !showsAttention { await refreshMarkets() } }
        #if DEBUG
        .task {
            if !showsAttention && LaunchArguments.contains("--show-dca") { showsDCA = true }
        }
        #endif
        .modifier(ResearchMarketRefreshModifier(enabled: !showsAttention, refresh: refreshMarkets))
        .task(id: accountScope) {
            guard showsAttention else { return }
            let scope = accountScope
            analysisTask?.cancel()
            analysisRequestID = UUID()
            isAnalyzing = false
            isRestoringReport = true
            report = nil
            analysisError = nil
            let cached = await ResearchAnalysisCache.shared.load(scope: scope)
            guard !Task.isCancelled, scope == accountScope else { return }
            report = cached
            #if DEBUG
            if LaunchArguments.contains("--preview-research-analysis"), report == nil {
                report = PortfolioAttentionCard.researchPreviewReport
            }
            #endif
            isRestoringReport = false
        }
        .onDisappear {
            analysisTask?.cancel()
            analysisRequestID = UUID()
            isAnalyzing = false
        }
        #if DEBUG
        .onChange(of: report?.generatedAt) { _, _ in
            if LaunchArguments.contains("--preview-research-analysis") {
                scroll.scrollTo("research-analysis", anchor: .top)
            }
        }
        #endif
        }
    }

    private var researchPage: some View {
        SettingsPage {
            if isSearchingMarket {
                // Until the first answer for this query, nothing: a
                // "searching" row there lasted a frame and read as a flash.
                if !searchResults.isEmpty || searchedQuery == searchText {
                    searchResultsSection
                }
            } else {
                SettingsSectionHeader(L10n.text("关键指标"))
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: SettingsTemplate.tileSpacing),
                                   count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                    spacing: SettingsTemplate.tileSpacing
                ) {
                    ForEach(Self.benchmarks, id: \.0) { symbol, title in
                        ResearchMetricCard(symbol: symbol, title: title,
                                           snapshot: markets.first { $0.id == symbol }, isLoading: isLoading)
                    }
                }
                MacroIndicatorSection()
                SettingsSection(L10n.text("行情")) {
                    SettingsNavigationRow(icon: .symbol("chart.xyaxis.line"), title: L10n.text("板块轮动")) {
                        SectorRotationView()
                    }
                    SettingsNavigationRow(icon: .symbol("point.3.connected.trianglepath.dotted"), title: L10n.text("市场轮动 · RRG")) {
                        StockChartsRotationView()
                    }
                    .accessibilityIdentifier("research.stockcharts-rrg")
                    SettingsNavigationRow(icon: .symbol("gauge.with.dots.needle.50percent"), title: L10n.text("行业情绪")) {
                        IndustrySentimentView()
                    }
                    SettingsNavigationRow(icon: .symbol("chart.line.uptrend.xyaxis"), title: L10n.text("美债收益率曲线")) {
                        TreasuryYieldCurveView()
                    }
                    .accessibilityIdentifier("research.treasury-curve")
                }
                SettingsSection(L10n.text("工具")) {
                    SettingsNavigationRow(icon: .symbol("calendar.badge.clock"), title: L10n.text("定投计算器")) {
                        DCACalculatorView()
                    }
                    .accessibilityIdentifier("research.dca")
                    // AI 持仓筛选, 策略编曲家 and 税务计算 are in 设置 › Lab 实验室.
                }
            }
        }
        // Search open with nothing typed: the page frosts behind the field,
        // as the system search does, and a tap on it closes the search.
        .overlay {
            if isSearchPresented && searchText.isEmpty {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isSearchPresented = false }
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        // Fades as search opens and closes only. The first letter swaps the
        // page for results at once; fading the frost out over that swap
        // flashed the metrics through it.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isSearchPresented)
    }

    private var attentionList: some View {
        List {
            Section {
                if isAnalyzing { ProgressView(L10n.text("正在分析所选账户…")) }
                if let analysisError { Text(L10n.message(analysisError)).foregroundStyle(.secondary) }
                if let report {
                    Text(L10n.text("分析于 \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))"))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(report.warnings, id: \.self) { Text(L10n.message($0)).font(.caption).foregroundStyle(.secondary) }
                    if analysisRows.isEmpty { Text(L10n.text("当前筛选下没有分析结果")).foregroundStyle(.secondary) }
                } else if !isAnalyzing {
                    Text(L10n.text("点击分析，使用已配置的 AI 服务研究当前持仓。未经来源验证的内容不会被视为已确认事实。"))
                        .foregroundStyle(.secondary)
                }
                Button(report == nil ? L10n.text("分析持仓") : L10n.text("刷新分析"), systemImage: "arrow.clockwise", action: analyze)
                    .disabled(isAnalyzing || isRestoringReport || model.holdings.isEmpty)
            } footer: {
                Text(L10n.text("保留上次分析，点击刷新才重新生成。AI 分析仅供研究参考。"))
            }
            .id("research-analysis")
            ForEach(analysisRows) { row in
                Section {
                    PortfolioAttentionCard(row: row, prominent: true)
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SettingsTemplate.pageBackground)
        .softTopScrollEdge()
    }

    private func marketRow(symbol: String, title: String, sparkline: Bool) -> some View {
        let snapshot = markets.first { $0.id == symbol }
        let tint = trendColor(symbol: symbol, change: snapshot?.changePercent)
        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let value = snapshot?.latest?.value {
                    Group {
                        if symbol == "^TNX" {
                            Text(value / 100, format: .percent.precision(.fractionLength(2)))
                        } else {
                            Text(value, format: .number.precision(.fractionLength(2)))
                        }
                    }
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                } else {
                    Text(L10n.text("暂无数据")).font(.title3).foregroundStyle(.secondary)
                }

                if let snapshot {
                    if symbol == "^TNX", let change = snapshot.changeBasisPoints {
                        Text("\(change >= 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1)))) bps")
                            .appNumber(.callout, weight: .medium)
                            .foregroundStyle(.secondary)
                    } else if let change = snapshot.changePercent {
                        Text(DisplayFormat.percent(change, signed: true))
                            .appNumber(.callout, weight: .medium)
                            .foregroundStyle(tint)
                    }
                }
                Spacer(minLength: 0)
            }

            if sparkline, let snapshot, snapshot.points.count > 1 {
                // No area fill: the y-domain is deliberately narrow, so a fill
                // reaches the frame edge and reads as a solid block that hides
                // the very shape the row exists to show.
                let domain = StandardLineChartEntrancePhase.domain(snapshot.points.map(\.value))
                StandardLineChartEntrance(appearanceID: "research-market|\(symbol)") { phase in
                Chart(Array(snapshot.points.enumerated()), id: \.element.id) { item in
                    LineMark(x: .value(L10n.text("日期"), item.element.id), y: .value(L10n.text("收盘"),
                        phase.value(item.element.value, fraction: Double(item.offset) / Double(snapshot.points.count - 1), domain: domain)))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: domain)
                .frame(height: 44)
                .accessibilityLabel(L10n.text("\(title)最近收盘走势"))
                }
            }

            if let latest = snapshot?.latest {
                Text(latest.id).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    /// VIX rising is not good news, so it stays neutral rather than green.
    private func trendColor(symbol: String, change: Double?) -> Color {
        guard symbol != "^VIX", symbol != "^TNX", let change else { return .secondary }
        return change >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger
    }

    private var searchResultsSection: some View {
        Group {
            SettingsSection(L10n.text("证券")) {
                if searchResults.isEmpty {
                    SettingsRowContainer {
                        Text(L10n.text("没有找到匹配的证券"))
                            .appText(.subheading)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                    }
                } else {
                    ForEach(searchResults) { result in
                        Button { open(result) } label: {
                            SettingsRowContainer { searchRow(result) }
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                        .accessibilityIdentifier("research.search.\(result.ticker)")
                    }
                    if hasMoreSearchResults {
                        Button {
                            expandedSearch = ExpandedSearch(query: searchText,
                                                            limit: searchLimit + Self.searchPageStep)
                        } label: {
                            SettingsRowContainer {
                                Text(L10n.text("显示更多"))
                                    .appText(.subheading)
                                    .foregroundStyle(SettingsTemplate.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .buttonStyle(SettingsRowButtonStyle())
                        .accessibilityIdentifier("research.search.more")
                    }
                }
            }
        }
    }

    private func heldHolding(_ ticker: String) -> Holding? {
        model.holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
    }

    private func searchRow(_ result: MarketSecurityResult) -> some View {
        let held = heldHolding(result.ticker)
        return HStack(spacing: SettingsTemplate.iconSpacing) {
            AssetLogo(ticker: result.ticker, logoSymbol: held?.logoSymbol ?? result.ticker, size: SettingsTemplate.iconSize)
            VStack(alignment: .leading, spacing: SettingsTemplate.subtitleSpacing) {
                HStack(spacing: 6) {
                    Text(result.ticker)
                        .appText(.subheading)
                        .lineLimit(1)
                    if held != nil {
                        Text(L10n.text("已持有"))
                            .appText(.caption, weight: .semibold)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.primary.opacity(0.07)))
                    }
                }
                Text(held?.shortName ?? CompanyNameCatalog.displayName(ticker: result.ticker, fallback: result.name))
                    .appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(result.venue)
                .appText(.label)
                .foregroundStyle(SettingsTemplate.secondaryText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            SettingsChevron()
        }
        .contentShape(Rectangle())
    }

    /// A held security opens with its position; anything else opens bare.
    private func open(_ result: MarketSecurityResult) {
        // The keyboard would otherwise stay up over the sheet and cover half
        // the page. The query stays, so closing the sheet returns to the list.
        isSearchFocused = false
        let holding = heldHolding(result.ticker) ?? result.holding
        // Read the cached chart while the sheet is still opening.
        HoldingDetailContentView.prefetch(holding, model: model)
        selectedSecurity = holding
    }

    /// Off the main thread: the directory holds some twenty thousand
    /// securities, and its first use decodes it.
    @MainActor private func searchMarket() async {
        let text = showsAttention ? "" : searchText
        guard !text.isEmpty else {
            searchResults = []
            searchedQuery = ""
            hasMoreSearchResults = false
            expandedSearch = nil
            return
        }
        let limit = searchLimit
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let worker = Task.detached(priority: .userInitiated) { () -> [MarketSecurityResult] in
            guard let catalog = try? CompanyReferenceCatalog.bundled.get() else { return [] }
            // One past the page says whether "more" has anything to show.
            return MarketSecurityResult.search(text, in: catalog, limit: limit + 1,
                                               shouldCancel: { Task.isCancelled })
        }
        let results = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        let applying = CompanyReferenceCatalog.searchSignposter.beginInterval("search.apply")
        searchResults = Array(results.prefix(limit))
        hasMoreSearchResults = results.count > limit
        searchedQuery = text
        CompanyReferenceCatalog.searchSignposter.endInterval("search.apply", applying)
    }

    @MainActor private func refreshMarkets() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // Macro figures refresh with the page, on a pull; their own cache
        // keeps an ordinary visit from asking again.
        async let macro: Void = MacroIndicatorStore.shared.load(force: hasRefreshedMarkets)
        defer { hasRefreshedMarkets = true }
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -14, to: end) ?? end
        let definitions = Self.benchmarks
        let histories = await LocalMarketDataClient().historicalCloses(
            symbols: definitions.map(\.0), from: DayDateCodec.string(from: start), to: DayDateCodec.string(from: end)
        )
        // The 10-year from the Treasury's own published curve where it can be
        // read; Yahoo's ^TNX stands in when it cannot.
        var official: [String: Double] = [:]
        if let curve = try? await TreasuryYieldClient.shared.curve() {
            let since = DayDateCodec.string(from: start)
            official = curve.history(.tenYears).filter { $0.key >= since }
        }
        guard !Task.isCancelled else { return }
        // A failed refresh must not erase previously available values.
        for (symbol, title) in definitions {
            let history = symbol == "^TNX" && official.count > 1 ? official : histories[symbol]
            guard let history, !history.isEmpty else { continue }
            let snapshot = ResearchMarketSnapshot(id: symbol, title: title, history: history)
            markets.removeAll { $0.id == symbol }
            markets.append(snapshot)
        }
        await macro
    }

    @MainActor private func analyze() {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        analysisError = nil
        let scope = accountScope
        let language = AppLanguage.currentIdentifier
        let requestID = UUID()
        analysisRequestID = requestID
        analysisTask = Task {
            defer { if analysisRequestID == requestID { isAnalyzing = false } }
            do {
                let response = try await ContentLanguage.$requested.withValue(language) {
                    try await model.portfolioAttention()
                }
                guard !Task.isCancelled, scope == accountScope, analysisRequestID == requestID else { return }
                report = response
                try await ResearchAnalysisCache.shared.save(response, scope: scope)
            } catch {
                guard !Task.isCancelled, scope == accountScope, analysisRequestID == requestID else { return }
                analysisError = L10n.text("分析或缓存更新失败，已保留现有结果：\(error.localizedDescription)")
            }
        }
    }
}

/// The scan's thresholds, in 编辑规则. A holding is listed when it crosses
/// any one of them and marked 高关注 when it crosses several.
private struct AttentionSignalRulesSections: View {
    private typealias Rules = AttentionSignalRules
    @AppStorage(Rules.returnWindowKey) private var returnWindow = Rules.defaults.returnWindowDays
    @AppStorage(Rules.returnThresholdKey) private var returnThreshold = Rules.defaults.returnThreshold
    @AppStorage(Rules.volumeMultipleKey) private var volumeMultiple = Rules.defaults.volumeMultiple
    @AppStorage(Rules.volumeBaselineKey) private var volumeBaseline = Rules.defaults.volumeBaselineDays
    @AppStorage(Rules.nearExtremeKey) private var nearExtreme = Rules.defaults.nearExtremePercent
    @AppStorage(Rules.todayMoveKey) private var todayMove = Rules.defaults.todayMoveThreshold
    @AppStorage(Rules.movingAverageKey) private var movingAverage = Rules.defaults.movingAverageDays
    @AppStorage(Rules.contributionShareKey) private var contributionShare = Rules.defaults.contributionShare
    @AppStorage(Rules.highAttentionKey) private var highAttention = Rules.defaults.highAttentionSignals
    @State private var confirmsReset = false

    private var isDefault: Bool {
        Rules.current == Rules.defaults
    }

    var body: some View {
        Section {
            Picker(L10n.text("涨跌幅周期"), selection: $returnWindow) {
                ForEach(Rules.returnWindowChoices, id: \.self) { Text("\($0)D").tag($0) }
            }
            stepper(L10n.text("涨跌幅阈值"), value: $returnThreshold, in: 3...40, step: 1, text: "±\(Int(returnThreshold))%")
            Picker(L10n.text("均线"), selection: $movingAverage) {
                ForEach(Rules.movingAverageChoices, id: \.self) { Text("MA\($0)").tag($0) }
            }
            stepper(L10n.text("接近 52 周高低点"), value: $nearExtreme, in: 0.5...10, step: 0.5,
                    text: L10n.text("\(Self.number(nearExtreme))% 以内"))
        } header: {
            Text(L10n.text("价格信号"))
        } footer: {
            Text(L10n.text("涨跌幅是现价相对 N 天前收盘的变化；均线信号在现价上穿或下穿均线的那天出现。"))
        }

        Section {
            stepper(L10n.text("放量倍数"), value: $volumeMultiple, in: 1.5...5, step: 0.5, text: "\(Self.number(volumeMultiple))×")
            Picker(L10n.text("放量基准"), selection: $volumeBaseline) {
                ForEach(Rules.volumeBaselineChoices, id: \.self) { Text(L10n.text("\($0) 日均量")).tag($0) }
            }
            stepper(L10n.text("今日异动"), value: $todayMove, in: 1...15, step: 0.5, text: "±\(Self.number(todayMove))%")
            stepper(L10n.text("占今日组合波动"), value: $contributionShare, in: 20...80, step: 5, text: "\(Int(contributionShare))%")
        } header: {
            Text(L10n.text("成交与异动"))
        }

        Section {
            Stepper(value: $highAttention, in: 1...4) {
                row(L10n.text("高关注至少"), L10n.text("\(highAttention) 个信号"))
            }
            Button(L10n.text("恢复默认参数"), role: .destructive) { confirmsReset = true }
                .disabled(isDefault)
                .confirmationDialog(L10n.text("恢复默认参数？"), isPresented: $confirmsReset, titleVisibility: .visible) {
                    Button(L10n.text("恢复默认"), role: .destructive) { reset() }
                    Button(L10n.text("取消"), role: .cancel) {}
                } message: {
                    Text(L10n.text("60D ±10%、MA200、52 周高低点 3% 以内、2× 30 日均量、今日 ±5%、占组合波动 40%、2 个信号为高关注。"))
                }
        } footer: {
            Text(L10n.text("满足任一信号即列入今天值得关注，满足设定个数为高关注。阈值调低会列出更多持仓。下次刷新分析时生效。"))
        }
    }

    private func stepper(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                         step: Double, text: String) -> some View {
        Stepper(value: value, in: range, step: step) { row(title, text) }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// Writing the defaults back, not only removing the keys, so every
    /// control on screen updates at once.
    private func reset() {
        let base = Rules.defaults
        returnWindow = base.returnWindowDays
        returnThreshold = base.returnThreshold
        volumeMultiple = base.volumeMultiple
        volumeBaseline = base.volumeBaselineDays
        nearExtreme = base.nearExtremePercent
        todayMove = base.todayMoveThreshold
        movingAverage = base.movingAverageDays
        contributionShare = base.contributionShare
        highAttention = base.highAttentionSignals
        Rules.reset()
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
