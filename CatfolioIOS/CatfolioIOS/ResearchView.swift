import SwiftUI
import Charts
import CryptoKit
import Observation

/// The pushed attention page keeps its original system filter.
private struct ResearchSystemSearch: ViewModifier {
    let showsAttention: Bool
    @Binding var query: String
    @Binding var isPresented: Bool
    let holdings: [Holding]
    let onSelect: (MarketSecurityResult) -> Void
    func body(content: Content) -> some View {
        if showsAttention { content.searchable(text: $query, prompt: L10n.text("搜索持仓")) }
        else {
            content.modifier(ResearchMarketSearch(holdings: holdings, onSelect: onSelect,
                                                  isPresented: $isPresented))
        }
    }
}

struct ResearchView: View {
    var showsAttention = false
    var titleDisplayMode: NavigationBarItem.TitleDisplayMode = .large
    @Environment(\.locale) private var appLocale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppModel.self) private var model
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var query = ""
    @State private var selectedSecurity: Holding?
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
    /// Keep market loading once per mounted page, including returning from search.
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
        .navigationTitle(showsAttention ? L10n.text("今天值得关注") : ResearchMarketSearch.navigationTitle)
        .navigationBarTitleDisplayMode(showsAttention ? titleDisplayMode : .large)
        .toolbarVisibility(.visible, for: .navigationBar)
        // The pushed attention page keeps its own filter and rule controls.
        .modifier(ResearchSystemSearch(showsAttention: showsAttention, query: $query,
                                       isPresented: $isSearchPresented,
                                       holdings: model.holdings, onSelect: open))
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
                            .toolbarVisibility(.visible, for: .navigationBar)
        }
        .securityDetail(item: $selectedSecurity) { holding, close in
            HoldingDetailView(holding: holding, onClose: close)
                .environment(model)
        }
        .securityDetailOpenFeedback(trigger: selectedSecurity?.ticker, enabled: hapticsEnabled)
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
        SettingsPage(pageBackground: .clear) {
            ResearchSearchSlot()
            // The indicators sit right under the search, without a header.
            VStack(alignment: .leading, spacing: SettingsTemplate.sectionSpacing) {
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
                            .toolbarVisibility(.visible, for: .navigationBar)
                    }
                    SettingsNavigationRow(icon: .symbol("point.3.connected.trianglepath.dotted"), title: L10n.text("市场轮动 · RRG")) {
                        StockChartsRotationView()
                            .toolbarVisibility(.visible, for: .navigationBar)
                    }
                    .accessibilityIdentifier("research.stockcharts-rrg")
                    SettingsNavigationRow(icon: .symbol("gauge.with.dots.needle.50percent"), title: L10n.text("行业情绪")) {
                        IndustrySentimentView()
                            .toolbarVisibility(.visible, for: .navigationBar)
                    }
                    SettingsNavigationRow(icon: .symbol("chart.line.uptrend.xyaxis"), title: L10n.text("美债收益率曲线")) {
                        TreasuryYieldCurveView()
                            .toolbarVisibility(.visible, for: .navigationBar)
                    }
                    .accessibilityIdentifier("research.treasury-curve")
                }
                SettingsSection(L10n.text("工具")) {
                    SettingsNavigationRow(icon: .symbol("calendar.badge.clock"), title: L10n.text("定投计算器")) {
                        DCACalculatorView()
                            .toolbarVisibility(.visible, for: .navigationBar)
                    }
                    .accessibilityIdentifier("research.dca")
                    // AI 持仓筛选 and 税务计算 are in 设置 › Lab 实验室.
                }
            }
        }
        .homeTabBackground()
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
                            FinancialText((value / 100).formatted(.percent.precision(.fractionLength(2)).locale(appLocale)))
                        } else {
                            FinancialText(value.formatted(.number.precision(.fractionLength(2)).locale(appLocale)))
                        }
                    }
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                } else {
                    Text(L10n.text("暂无数据")).font(.title3).foregroundStyle(.secondary)
                }

                if let snapshot {
                    if symbol == "^TNX", let change = snapshot.changeBasisPoints {
                        FinancialText("\(change >= 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1)))) bps")
                            .appNumber(.callout, weight: .medium)
                            .foregroundStyle(.secondary)
                    } else if let change = snapshot.changePercent {
                        FinancialText(DisplayFormat.percent(change, signed: true))
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

    private func heldHolding(_ ticker: String) -> Holding? {
        model.holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
    }

    /// A held security opens with its position; anything else opens bare.
    private func open(_ result: MarketSecurityResult) {
        // The keyboard would otherwise stay up over the sheet and cover half
        // the page. The query stays, so closing the sheet returns to the list.
        let holding = heldHolding(result.ticker) ?? result.holding
        // Read the cached chart while the sheet is still opening.
        HoldingDetailContentView.prefetch(holding, model: model)
        selectedSecurity = holding
    }

    @MainActor private func refreshMarkets() async {
        guard !isLoading, !hasRefreshedMarkets else { return }
        isLoading = true
        defer { isLoading = false }
        async let macro: Void = MacroIndicatorStore.shared.load()
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
