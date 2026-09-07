import SwiftUI
import Charts
import CryptoKit

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

struct ResearchView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var holdingZoom
    @State private var query = ""
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

    private static let benchmarks = [("^GSPC", "S&P 500"), ("^IXIC", "NASDAQ"), ("^VIX", "VIX 波动率"), ("^TNX", "美国 10 年期国债收益率")]

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
    /// A sector is read by how far it moved, not by the level of its proxy
    /// ETF, so these cells lead with the change and keep the ticker as a
    /// caption — the mirror of the benchmark cells above.
    private static func sectorGlyph(_ symbol: String) -> (name: String, tint: Color) {
        switch symbol {
        case "XLK": ("cpu", CatfolioPalette.blue500)
        case "XLV": ("cross.case.fill", CatfolioPalette.rose500)
        case "XLF": ("banknote.fill", CatfolioPalette.teal500)
        case "XLE": ("fuelpump.fill", CatfolioPalette.coral500)
        case "XLI": ("gearshape.fill", CatfolioPalette.sky700)
        case "XLY": ("cart.fill", CatfolioPalette.violet500)
        case "XLP": ("basket.fill", CatfolioPalette.green500)
        case "XLU": ("bolt.fill", CatfolioPalette.yellow300)
        case "XLRE": ("house.fill", CatfolioPalette.magenta500)
        case "XLB": ("cube.fill", CatfolioPalette.teal400)
        case "XLC": ("antenna.radiowaves.left.and.right", CatfolioPalette.violet700)
        default: ("square.grid.2x2.fill", CatfolioTheme.neutralIcon)
        }
    }

    private static let sectors = [("XLK", "科技"), ("XLV", "医疗"), ("XLF", "金融"), ("XLE", "能源"), ("XLI", "工业"), ("XLY", "可选消费"), ("XLP", "必需消费"), ("XLU", "公用事业"), ("XLRE", "房地产"), ("XLB", "材料"), ("XLC", "通信")]

    private var accountScope: String {
        let keys = [model.isFakeDataMode ? "demo" : "real"] + model.selectedAccountKeys.sorted()
        return keys.map { "\($0.utf8.count):\($0)" }.joined()
    }
    private func matches(_ text: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || text.localizedCaseInsensitiveContains(needle)
    }
    private var movers: [(holding: Holding, change: Double)] {
        model.holdings.compactMap { holding in
            guard matches("\(holding.ticker) \(holding.displayName)"),
                  let change = model.holdingDailyChanges[holding.ticker.uppercased()] ?? holding.todayChangePercent,
                  change.isFinite else { return nil }
            return (holding, change)
        }
    }
    private var analysisRows: [PortfolioAttentionHolding] {
        Array((report?.attentionRows ?? []).filter {
            matches("\($0.ticker) \($0.name)") && (!highAttentionOnly || $0.attention == .high)
        }.prefix(maximumResults))
    }

    var body: some View {
        ScrollViewReader { scroll in
        List {
            Section {
                if isLoading && markets.isEmpty {
                    ProgressView("读取市场数据…")
                } else {
                    // Health groups related figures into one card and lays them
                    // out two up, label above value, rather than as a stack of
                    // equal-weight list rows.
                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)],
                        alignment: .leading,
                        spacing: 24
                    ) {
                        ForEach(Self.benchmarks.filter { matches("\($0.0) \($0.1)") }, id: \.0) { symbol, title in
                            marketCell(symbol: symbol, title: title)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } header: {
                Text("关键指标")
            } footer: {
                Text("最近可用收盘，非盘中实时行情。账户范围沿用设置中的选择。")
            }
            .headerProminence(.increased)
            Section {
                moversSection(positive: true)
            } header: { Text("持仓涨幅榜") } footer: {
                Text("仅当前账户持仓，不代表全市场；沿用持仓行情更新时间。")
            }
            .headerProminence(.increased)
            Section("持仓跌幅榜") { moversSection(positive: false) }
                .headerProminence(.increased)
            Section {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)],
                    alignment: .leading,
                    spacing: 22
                ) {
                    ForEach(Self.sectors.filter { matches("\($0.0) \($0.1)") }, id: \.0) { symbol, title in
                        sectorCell(symbol: symbol, title: title)
                    }
                }
                .padding(.vertical, 6)
            } header: { Text("板块表现").headerProminence(.increased) } footer: {
                Text("行业 ETF 作为美国板块代理；数值为最近两个可用收盘价的变化，非盘中实时行情。来源：现有 Yahoo 行情服务及本机缓存。每项分别显示数据日期。")
            }
            Section {
                if isAnalyzing { ProgressView("正在分析所选账户…") }
                if let analysisError { Text(analysisError).foregroundStyle(.secondary) }
                if let report {
                    Text("分析于 \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(report.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    if analysisRows.isEmpty { Text("当前筛选下没有分析结果").foregroundStyle(.secondary) }
                } else if !isAnalyzing {
                    Text("点击分析，使用已配置的 AI 服务研究当前持仓。未经来源验证的内容不会被视为已确认事实。")
                        .foregroundStyle(.secondary)
                }
                Button(report == nil ? "分析持仓" : "刷新分析", systemImage: "arrow.clockwise", action: analyze)
                    .disabled(isAnalyzing || isRestoringReport || model.holdings.isEmpty)
            } header: { Text("AI 持仓分析").headerProminence(.increased) } footer: {
                Text("保留上次分析，点击刷新才重新生成。AI 分析仅供研究参考。")
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
        .navigationTitle("研究")
        .navigationBarTitleDisplayMode(.large)
        .toolbarVisibility(.visible, for: .navigationBar)
        .searchable(text: $query, prompt: "搜索指标、板块或持仓")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新市场", systemImage: "arrow.clockwise") { Task { await refreshMarkets() } }
                    .disabled(isLoading)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑规则", systemImage: "slider.horizontal.3") { showsRules = true }
            }
        }
        .sheet(isPresented: $showsRules) {
            NavigationStack {
                Form {
                    Section("分析结果筛选") {
                        Toggle("仅显示高关注", isOn: $highAttentionOnly)
                        Picker("最多显示", selection: $maximumResults) {
                            Text("3 项").tag(3)
                            Text("6 项").tag(6)
                            Text("12 项").tag(12)
                        }
                    }
                    Section {
                        Text("规则保存在本机，仅控制结果展示；不更改模型结论和置信度。账户范围在设置中选择。")
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("研究规则")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsRules = false }
                } }
            }
        }
        .task { await refreshMarkets() }
        .refreshable { await refreshMarkets() }
        .task(id: accountScope) {
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
        .onDisappear { analysisTask?.cancel(); analysisRequestID = UUID(); isAnalyzing = false }
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
    private func marketCell(symbol: String, title: String) -> some View {
        let snapshot = markets.first { $0.id == symbol }
        let tint = trendColor(symbol: symbol, change: snapshot?.changePercent)
        let glyph = Self.benchmarkGlyph(symbol)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: glyph.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(glyph.tint)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            if let value = snapshot?.latest?.value {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value / (symbol == "^TNX" ? 1 : 1), format: .number.precision(.fractionLength(2)))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if symbol == "^TNX" {
                        Text("%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("暂无数据").font(.title3).foregroundStyle(.secondary)
            }

            if let snapshot {
                if symbol == "^TNX", let change = snapshot.changeBasisPoints {
                    Text("\(change >= 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1)))) bps")
                        .font(.footnote.weight(.medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if let change = snapshot.changePercent {
                    Text(DisplayFormat.percent(change, signed: true))
                        .font(.footnote.weight(.medium)).monospacedDigit()
                        .foregroundStyle(tint)
                }

                if snapshot.points.count > 1 {
                    Chart(snapshot.points) { point in
                        LineMark(x: .value("日期", point.id), y: .value("收盘", point.value))
                            .foregroundStyle(tint)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                    .chartXAxis(.hidden).chartYAxis(.hidden)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 32)
                    .padding(.top, 2)
                    .accessibilityLabel("\(title)最近收盘走势")
                }

                if let latest = snapshot.latest {
                    Text(latest.id).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectorCell(symbol: String, title: String) -> some View {
        let snapshot = markets.first { $0.id == symbol }
        let glyph = Self.sectorGlyph(symbol)
        let change = snapshot?.changePercent
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: glyph.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(glyph.tint)
                    .frame(width: 18, alignment: .leading)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let change {
                Text(DisplayFormat.percent(change, signed: true))
                    .font(.title3.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(change >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("暂无数据").font(.subheadline).foregroundStyle(.secondary)
            }

            Text(snapshot?.latest.map { "\(symbol) · \($0.id)" } ?? symbol)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                    Text("暂无数据").font(.title3).foregroundStyle(.secondary)
                }

                if let snapshot {
                    if symbol == "^TNX", let change = snapshot.changeBasisPoints {
                        Text("\(change >= 0 ? "+" : "")\(change.formatted(.number.precision(.fractionLength(1)))) bps")
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if let change = snapshot.changePercent {
                        Text(DisplayFormat.percent(change, signed: true))
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                            .foregroundStyle(tint)
                    }
                }
                Spacer(minLength: 0)
            }

            if sparkline, let snapshot, snapshot.points.count > 1 {
                // No area fill: the y-domain is deliberately narrow, so a fill
                // reaches the frame edge and reads as a solid block that hides
                // the very shape the row exists to show.
                Chart(snapshot.points) { point in
                    LineMark(x: .value("日期", point.id), y: .value("收盘", point.value))
                        .foregroundStyle(tint)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 44)
                .accessibilityLabel("\(title)最近收盘走势")
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

    @ViewBuilder private func moversSection(positive: Bool) -> some View {
        let rows = Array(movers.filter { positive ? $0.change > 0 : $0.change < 0 }
            .sorted { positive ? $0.change > $1.change : $0.change < $1.change }.prefix(3))
        if rows.isEmpty { Text("暂无符合条件的持仓行情").foregroundStyle(.secondary) }
        ForEach(rows, id: \.holding.ticker) { row in
            NavigationLink {
                HoldingDetailView(holding: row.holding)
                    .navigationTransition(.zoom(sourceID: row.holding.ticker, in: holdingZoom))
            } label: {
                LabeledContent(row.holding.ticker) {
                    Text(DisplayFormat.percent(row.change, signed: true)).monospacedDigit()
                        .foregroundStyle(positive ? Color.green : Color.red)
                }
            }
            .matchedTransitionSource(id: row.holding.ticker, in: holdingZoom)
        }
    }

    @MainActor private func refreshMarkets() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -14, to: end) ?? end
        let definitions = Self.benchmarks + Self.sectors
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
        let requestID = UUID()
        analysisRequestID = requestID
        analysisTask = Task {
            defer { if analysisRequestID == requestID { isAnalyzing = false } }
            do {
                let response = try await model.portfolioAttention()
                guard !Task.isCancelled, scope == accountScope, analysisRequestID == requestID else { return }
                report = response
                try await ResearchAnalysisCache.shared.save(response, scope: scope)
            } catch {
                guard !Task.isCancelled, scope == accountScope, analysisRequestID == requestID else { return }
                analysisError = "分析或缓存更新失败，已保留现有结果：\(error.localizedDescription)"
            }
        }
    }
}
