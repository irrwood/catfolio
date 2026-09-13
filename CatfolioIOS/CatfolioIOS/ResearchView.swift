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

    static func search(_ query: String, in catalog: CompanyReferenceCatalog, limit: Int = 40) -> [Self] {
        catalog.search(query, limit: limit).map { entry in
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
    }
}

private struct ResearchSystemSearch: ViewModifier {
    let enabled: Bool
    @Binding var query: String

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $query, prompt: L10n.text("搜索持仓"))
        } else {
            content
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
    @Environment(AppModel.self) private var model
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var query = ""
    @State private var searchResults: [MarketSecurityResult] = []
    /// The query `searchResults` answer, so a stale list is not mistaken
    /// for an empty one while the next search runs.
    @State private var searchedQuery = ""
    @State private var selectedSecurity: Holding?
    @FocusState private var isSearchFocused: Bool
    @State private var markets: [ResearchMarketSnapshot] = []
    @State private var isLoading = false
    @State private var report: PortfolioAttentionReport?
    @State private var analysisTask: Task<Void, Never>?
    @State private var isAnalyzing = false
    @State private var isRestoringReport = true
    @State private var analysisRequestID = UUID()
    @State private var analysisError: String?
    @State private var showsRules = false
    @AppStorage("research.highAttentionOnly") private var highAttentionOnly = false
    @AppStorage("research.maximumResults") private var maximumResults = 6

    private static var benchmarks: [(String, String)] { [("^GSPC", "S&P 500"), ("^IXIC", "NASDAQ"), ("^VIX", L10n.text("VIX 波动率")), ("^TNX", L10n.text("美国 10 年期国债收益率"))] }

    /// Health tints the symbol beside each label and leaves the number itself
    /// in the primary colour, so the grid stays scannable while every figure
    /// keeps its own identity.
    private static func benchmarkGlyph(_ symbol: String) -> (name: String, tint: Color) {
        switch symbol {
        case "^GSPC": ("chart.line.uptrend.xyaxis", CatfolioTheme.accent)
        case "^IXIC": ("chart.bar.fill", CatfolioTheme.services)
        case "^VIX": ("waveform.path.ecg", CatfolioTheme.warning)
        case "^TNX": ("percent", CatfolioTheme.preference)
        default: ("chart.xyaxis.line", CatfolioTheme.neutralIcon)
        }
    }
    private var accountScope: String {
        let keys = [appLocale.identifier, model.isFakeDataMode ? "demo" : "real"] + model.selectedAccountKeys.sorted()
        return keys.map { "\($0.utf8.count):\($0)" }.joined()
    }
    private func matches(_ text: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || text.localizedCaseInsensitiveContains(needle)
    }
    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Research searches the whole directory; the attention page still
    /// filters its own results with the same field.
    private var isSearchingMarket: Bool { !showsAttention && !searchText.isEmpty }

    private var analysisRows: [PortfolioAttentionHolding] {
        Array((report?.attentionRows ?? []).filter {
            matches("\($0.ticker) \($0.name)") && (!highAttentionOnly || $0.attention == .high)
        }.prefix(maximumResults))
    }

    var body: some View {
        ScrollViewReader { scroll in
        List {
            if !showsAttention {
                Section { marketSearchField }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if isSearchingMarket {
                searchResultsSection
            } else if !showsAttention {
            Section {
                if isLoading && markets.isEmpty {
                    ProgressView(L10n.text("读取市场数据…"))
                } else {
                    // Two up, but a block each — the four still get their own
                    // card and their own shape rather than sharing one, which
                    // is what let the figures be figures instead of list rows.
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: SettingsTemplate.tileSpacing),
                            GridItem(.flexible(), spacing: SettingsTemplate.tileSpacing),
                        ],
                        spacing: SettingsTemplate.tileSpacing
                    ) {
                        ForEach(Self.benchmarks, id: \.0) { symbol, title in
                            SettingsCard {
                                marketCell(symbol: symbol, title: title)
                            }
                        }
                    }
                    // Zero, not the page inset: an inset-grouped section
                    // already carries its own horizontal margin, so adding one
                    // here stacked the two and left the grid narrower than
                    // every other card on the page.
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } header: {
                Text(L10n.text("关键指标"))
            } footer: {
                Text(L10n.text("最近可用收盘，非盘中实时行情。账户范围沿用设置中的选择。"))
            }
            .headerProminence(.increased)
            Section {
                NavigationLink(L10n.text("板块轮动")) { SectorRotationView() }
                NavigationLink(L10n.text("市场轮动 · RRG")) { StockChartsRotationView() }
            }
            }
            if showsAttention {
            Section {
                if isAnalyzing { ProgressView(L10n.text("正在分析所选账户…")) }
                if let analysisError { Text(analysisError).foregroundStyle(.secondary) }
                if let report {
                    Text(L10n.text("分析于 \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))"))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(report.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
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
        }
        .listStyle(.insetGrouped)
        // The list keeps its own rows — a screen with this much content should
        // stay a List and keep its recycling — but it sits on the settings
        // template's ground rather than the system's colder grouped grey.
        .scrollContentBackground(.hidden)
        .background(SettingsTemplate.pageBackground)
        .softTopScrollEdge()
        .tracksRootTabBarScroll()
        .navigationTitle(L10n.text(showsAttention ? "今天值得关注" : "研究"))
        .navigationBarTitleDisplayMode(.large)
        .toolbarVisibility(.visible, for: .navigationBar)
        // As a tab, Research sits under the root stack's bar, which never
        // sees a tab's own search or toolbar: its field is in the page
        // instead, and pull to refresh stands in for the refresh button.
        .modifier(ResearchSystemSearch(enabled: showsAttention, query: $query))
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            if showsAttention {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("编辑规则"), systemImage: "slider.horizontal.3") { showsRules = true }
            }
            }
        }
        .sheet(isPresented: $showsRules) {
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
                        Text(L10n.text("规则保存在本机，仅控制结果展示；不更改模型结论和置信度。账户范围在设置中选择。"))
                            .foregroundStyle(.secondary)
                    }
                }
                .softTopScrollEdge()
                .navigationTitle(L10n.text("研究规则"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("完成")) { showsRules = false }
                } }
            }
        }
        .sheet(item: $selectedSecurity) { holding in
            HoldingDetailView(holding: holding)
                .environment(model)
                .securityDetailSheet()
        }
        .securityDetailOpenFeedback(trigger: selectedSecurity?.ticker, enabled: hapticsEnabled)
        .task(id: showsAttention ? "" : searchText) { await searchMarket() }
        .task { if !showsAttention { await refreshMarkets() } }
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
            if ProcessInfo.processInfo.arguments.contains("--preview-research-analysis") {
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
            if ProcessInfo.processInfo.arguments.contains("--preview-research-analysis") {
                scroll.scrollTo("research-analysis", anchor: .top)
            }
        }
        #endif
        }
    }

    /// One figure in the key-indicator grid, in Health's order: what it is,
    /// then the number at a size worth reading, then the trend.
    ///
    /// The number itself stays in the primary colour. Health tints values to
    /// identify the metric, but here a tint would compete with the one colour
    /// that already carries meaning — direction — so only the change and the
    /// line take it.
    /// A tile's label: the category mark, then the name over two lines.
    ///
    /// The two lines are reserved, not merely allowed. Tiles in a row of a
    /// grid are laid out to a common height, so a name that wraps only when it
    /// needs to would make one row taller than the next and change the height
    /// of the page every time the data did. Reserving the second line costs a
    /// blank line under the short names and buys a grid that does not move.
    ///
    /// The icon is top-aligned so it sits against the first line rather than
    /// floating in the middle of a two-line block.
    private func tileLabel(
        _ title: String,
        icon: (name: String, tint: Color),
        uppercased: Bool,
        tracking: CGFloat = 0
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon.name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(icon.tint)
                // Nudged onto the cap height of the first line.
                .padding(.top, 1)
            Text(uppercased ? title.uppercased() : title)
                .appText(.label, weight: uppercased ? .semibold : .regular)
                .tracking(tracking)
                .foregroundStyle(SettingsTemplate.secondaryText)
                .multilineTextAlignment(.leading)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Two marks, kept off the two ends so neither label is clipped by the
    /// card's padding. Two rather than three because these cards are half a
    /// screen wide — a third label lands on one of its neighbours.
    private static func axisDates(_ points: [ResearchMarketSnapshot.Point]) -> [String] {
        guard points.count > 2 else { return points.map(\.id) }
        let last = points.count - 1
        return [0.2, 0.8]
            .map { Int((Double(last) * $0).rounded()) }
            .reduce(into: [Int]()) { unique, index in
                if !unique.contains(index) { unique.append(index) }
            }
            .map { points[$0].id }
    }

    /// `2026-09-08` reads as `09-08` under a chart: the year is the same for
    /// every mark on a series this short, and dropping it is what lets three
    /// labels sit side by side.
    private static func axisLabel(_ id: String) -> String {
        let parts = id.split(separator: "-")
        return parts.count == 3 ? "\(parts[1])-\(parts[2])" : id
    }

    /// One metric, one block — label, figure, then the shape the figure came
    /// from, the way a home-screen widget states a single number.
    ///
    /// The label is set small, tracked and upper-case so it reads as a caption
    /// to the figure rather than a heading competing with it, and the figure
    /// gets the room a whole card can give it.
    private func marketCell(symbol: String, title: String) -> some View {
        let snapshot = markets.first { $0.id == symbol }
        let tint = trendColor(symbol: symbol, change: snapshot?.changePercent)
        let glyph = Self.benchmarkGlyph(symbol)
        let compactTile = !dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: compactTile ? 6 : 10) {
            tileLabel(title, icon: glyph, uppercased: true, tracking: 0.6)

            // The change sits under the figure rather than beside it: half a
            // card is not wide enough for both, and squeezing them onto one
            // line is what makes a six-figure index shrink to fit.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    if let value = snapshot?.latest?.value {
                        Text(value, format: .number.precision(.fractionLength(2)))
                            .appNumber(.title, weight: .bold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        if symbol == "^TNX" {
                            Text("%")
                                .appText(.footnote)
                                .foregroundStyle(SettingsTemplate.secondaryText)
                        }
                    } else {
                        Text(L10n.text("暂无数据"))
                            .appText(.subheading)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                    }
                }

                if let snapshot {
                    if symbol == "^TNX", let change = snapshot.changeBasisPoints {
                        Text("\(change >= 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1)))) bps")
                            .appNumber(.label, weight: .medium)
                            .foregroundStyle(SettingsTemplate.secondaryText)
                    } else if let change = snapshot.changePercent {
                        Text(DisplayFormat.percent(change, signed: true))
                            .appNumber(.label, weight: .medium)
                            .foregroundStyle(tint)
                    }
                }
            }

            if let snapshot, snapshot.points.count > 1 {
                let domain = StandardLineChartEntrancePhase.domain(snapshot.points.map(\.value))
                StandardLineChartEntrance { phase in
                Chart(Array(snapshot.points.enumerated()), id: \.element.id) { item in
                    LineMark(x: .value(L10n.text("日期"), item.element.id), y: .value(L10n.text("收盘"),
                        phase.value(item.element.value, fraction: Double(item.offset) / Double(snapshot.points.count - 1), domain: domain)))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
                // The dates are shown, not hidden: a figure with a shape under
                // it is only readable if the reader can see how far back the
                // shape goes.
                //
                // The marks are named one by one rather than left to
                // `desiredCount`, which only thins a continuous axis — these
                // dates are categories, so every one of them drew a label and
                // they landed on top of each other.
                .chartXAxis {
                    AxisMarks(values: Self.axisDates(snapshot.points)) { value in
                        // Solid, not the dashed default: the rule is there to
                        // mark where a date falls, and a dash reads as a
                        // series of its own next to a 3pt line.
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                            .foregroundStyle(SettingsTemplate.separator)
                        AxisValueLabel {
                            if let raw = value.as(String.self) {
                                Text(Self.axisLabel(raw))
                                    .appText(.label, weight: .regular)
                                    .foregroundStyle(SettingsTemplate.secondaryText)
                            }
                        }
                    }
                }
                .chartYAxis(.hidden)
                .chartYScale(domain: domain)
                .frame(height: compactTile ? 52 : 64)
                .padding(.top, compactTile ? 0 : 2)
                .accessibilityLabel(L10n.text("\(title)最近收盘走势"))
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: compactTile ? 136 : 0,
            alignment: .topLeading
        )
        .padding(.horizontal, compactTile ? 14 : SettingsTemplate.rowHorizontalPadding)
        .padding(.vertical, compactTile ? 14 : SettingsTemplate.rowHorizontalPadding)
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
                StandardLineChartEntrance { phase in
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

    /// The system search bar's shape, in the page: a filled capsule with the
    /// glass, the clear button and, while typing, Cancel.
    private var marketSearchField: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L10n.text("搜索股票、ETF 或公司名"), text: $query)
                    .focused($isSearchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("research.search")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("清除"))
                }
            }
            .appText(.body)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            if isSearchFocused || !query.isEmpty {
                Button(L10n.text("取消")) {
                    query = ""
                    isSearchFocused = false
                }
                .buttonStyle(.plain)
                .appText(.body)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: isSearchFocused || !query.isEmpty)
    }

    private var searchResultsSection: some View {
        Section {
            if searchResults.isEmpty {
                Text(L10n.text(searchedQuery == searchText ? "没有找到匹配的证券" : "正在搜索…"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(searchResults) { result in
                    Button { open(result) } label: { searchRow(result) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("research.search.\(result.ticker)")
                }
            }
        } header: {
            Text(L10n.text("证券"))
        } footer: {
            Text(L10n.text("离线证券目录：美股与主要海外市场的股票和 ETF。轻点查看个股页。"))
        }
    }

    private func heldHolding(_ ticker: String) -> Holding? {
        model.holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
    }

    private func searchRow(_ result: MarketSecurityResult) -> some View {
        let held = heldHolding(result.ticker)
        return HStack(spacing: 12) {
            AssetLogo(ticker: result.ticker, logoSymbol: held?.logoSymbol ?? result.ticker, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(result.ticker)
                        .appText(.body, weight: .semibold)
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
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    /// A held security opens with its position; anything else opens bare.
    private func open(_ result: MarketSecurityResult) {
        selectedSecurity = heldHolding(result.ticker) ?? result.holding
    }

    /// Off the main thread: the directory holds some twenty thousand
    /// securities, and its first use decodes it.
    @MainActor private func searchMarket() async {
        let text = showsAttention ? "" : searchText
        guard !text.isEmpty else {
            searchResults = []
            searchedQuery = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let results = await Task.detached(priority: .userInitiated) { () -> [MarketSecurityResult] in
            guard let catalog = try? CompanyReferenceCatalog.bundled.get() else { return [] }
            return MarketSecurityResult.search(text, in: catalog)
        }.value
        guard !Task.isCancelled else { return }
        searchResults = results
        searchedQuery = text
    }

    @MainActor private func refreshMarkets() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -14, to: end) ?? end
        let definitions = Self.benchmarks
        let histories = await LocalMarketDataClient().historicalCloses(
            symbols: definitions.map(\.0), from: DayDateCodec.string(from: start), to: DayDateCodec.string(from: end)
        )
        guard !Task.isCancelled else { return }
        // A failed refresh must not erase previously available values.
        for (symbol, title) in definitions {
            guard let history = histories[symbol], !history.isEmpty else { continue }
            let snapshot = ResearchMarketSnapshot(id: symbol, title: title, history: history)
            markets.removeAll { $0.id == symbol }
            markets.append(snapshot)
        }
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
