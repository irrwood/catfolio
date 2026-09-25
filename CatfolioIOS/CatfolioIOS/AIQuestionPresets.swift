import SwiftUI

enum AIQuestionPreset: String, CaseIterable, Identifiable, Sendable {
    case valuation, trend, news, options, earnings, overview, market

    var id: String { rawValue }
    var requiresSecurity: Bool { self != .market }

    var title: String {
        switch self {
        case .valuation: L10n.text("估值分析")
        case .trend: L10n.text("趋势分析")
        case .news: L10n.text("新闻催化")
        case .options: L10n.text("期权结构")
        case .earnings: L10n.text("财报解读")
        case .overview: L10n.text("个股全景")
        case .market: L10n.text("市场脉搏")
        }
    }

    var summary: String {
        switch self {
        case .valuation: L10n.text("现在的价格贵不贵？")
        case .trend: L10n.text("趋势走到哪一步了？")
        case .news: L10n.text("最近什么消息值得关注？")
        case .options: L10n.text("期权市场在关注什么？")
        case .earnings: L10n.text("这份财报的重点是什么？")
        case .overview: L10n.text("快速了解一家公司")
        case .market: L10n.text("最近市场发生了什么？")
        }
    }

    var symbol: String {
        switch self {
        case .valuation: "scale.3d"
        case .trend: "chart.xyaxis.line"
        case .news: "newspaper"
        case .options: "chart.bar.xaxis"
        case .earnings: "doc.text.magnifyingglass"
        case .overview: "square.grid.2x2"
        case .market: "waveform.path.ecg"
        }
    }

    /// A stock-specific question cannot exist until a security is selected.
    func request(security: AIQuestionSecurity? = nil) -> AIResearchQuestion? {
        if requiresSecurity && security == nil { return nil }
        let target = security?.analysisName ?? ""
        let prompt: String
        switch self {
        case .valuation:
            prompt = L10n.text("请分析 \(target) 目前的估值：结合盈利、现金流、成长质量、历史估值与可比公司，解释当前价格反映了哪些预期，以及主要风险。")
        case .trend:
            prompt = L10n.text("请分析 \(target) 最近的价格趋势、成交量和关键支撑阻力，区分短期与中期走势，并说明哪些变化会使当前判断失效。")
        case .news:
            prompt = L10n.text("请梳理 \(target) 近期最值得关注的新闻和公司动作，说明事件日期、发生了什么、可能的影响与后续观察点，并附上来源。")
        case .options:
            prompt = L10n.text("请解读 \(target) 的期权结构：隐含波动率、主要到期日、看涨与看跌合约的成交量和未平仓量。区分成交与持仓，不要仅凭未平仓量推断资金方向，并注明数据时点。")
        case .earnings:
            prompt = L10n.text("请解读 \(target) 最近一期财报：收入、利润、现金流、业务变化和管理层指引。区分同比、环比与市场预期；没有一致预期数据时不要判断是否超预期。")
        case .overview:
            prompt = L10n.text("请从业务模式、财务质量、估值、近期催化和主要风险五个方面介绍 \(target)，最后总结最值得继续研究的三个问题。")
        case .market:
            prompt = L10n.text("请总结最近一个交易日的美股市场：主要指数、板块轮动、波动率、利率与宏观事件。说明市场关注点，注明交易日和数据来源。")
        }
        return AIResearchQuestion(prompt: prompt, security: security)
    }
}

/// Only a public listing identity is passed to research, never account values.
struct AIQuestionSecurity: Identifiable, Sendable {
    let ticker: String
    let name: String
    let venue: String?
    let logoSymbol: String?

    var id: String { ticker }
    var analysisName: String {
        let listing = [ticker, venue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return "\(name) (\(listing))"
    }

    init(holding: Holding) {
        ticker = holding.ticker
        name = holding.shortName
        venue = nil
        logoSymbol = holding.logoSymbol
    }

    init(result: MarketSecurityResult) {
        ticker = result.ticker
        name = result.name
        venue = result.venue
        logoSymbol = result.ticker
    }
}

struct AIResearchQuestion: Sendable {
    let prompt: String
    let security: AIQuestionSecurity?

    var context: String {
        let subject = security?.analysisName ?? "US equity market"
        return """
        本次为公开证券／市场研究，分析对象：\(subject)。这不是用户的持仓组合问题。
        请求时间：\(Date.now.ISO8601Format())。
        这里只提供了分析对象，没有提供实时行情、期权链、估值数据或财报。
        能检索时，请先核对公司与上市地点、资料日期和原始来源，再分析；区分事实、推断与缺失数据。
        无法取得必要资料时，简短说明缺少什么并向用户询问，不要编造价格、财务数字、新闻、引文或来源，也不要把训练知识当作最新数据。
        \(L10n.responseLanguageInstruction)
        """
    }
}

struct AIQuestionPresets: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let onSelect: (AIQuestionPreset) -> Void

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("从一个问题开始"))
                    .font(.title2.weight(.semibold))
                Text(L10n.text("选择一个方向，一起看得更清楚。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(AIQuestionPreset.allCases) { preset in
                    Button { onSelect(preset) } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: preset.symbol)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(CatfolioStyle.blue)
                            Text(preset.title)
                                .font(.subheadline.weight(.semibold))
                            Text(preset.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, minHeight: 102, alignment: .topLeading)
                        .padding(16)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(preset.requiresSecurity
                        ? L10n.text("先选择要分析的股票") : L10n.text("发送市场分析问题"))
                    .accessibilityIdentifier("ai-preset-\(preset.rawValue)")
                }
            }
        }
        .padding(.vertical, 12)
    }
}

struct AIQuestionSecurityPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    let preset: AIQuestionPreset
    let onSelect: (AIQuestionSecurity) -> Void
    @State private var query = ""
    @State private var results: [AIQuestionSecurity] = []
    @State private var completedQuery: String?
    @State private var searchFailed = false
    @State private var didSelect = false

    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matchingHoldings: [AIQuestionSecurity] {
        model.holdings.filter {
            searchText.isEmpty || $0.ticker.localizedCaseInsensitiveContains(searchText)
                || $0.shortName.localizedCaseInsensitiveContains(searchText)
                || $0.displayName.localizedCaseInsensitiveContains(searchText)
        }.map(AIQuestionSecurity.init(holding:))
    }
    private var directoryResults: [AIQuestionSecurity] {
        guard completedQuery == searchText else { return [] }
        let held = Set(matchingHoldings.map { $0.ticker.uppercased() })
        return results.filter { !held.contains($0.ticker.uppercased()) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("你想分析哪只股票？"))
                            .font(.title2.weight(.semibold))
                        Text(L10n.text("选择持仓，或搜索股票代码和公司名。"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }

                if !matchingHoldings.isEmpty {
                    Section(L10n.text("持仓证券")) {
                        ForEach(matchingHoldings) { security in row(security) }
                    }
                }

                if !searchText.isEmpty {
                    Section(L10n.text("搜索结果")) {
                        if completedQuery != searchText {
                            ProgressView(L10n.text("正在搜索…"))
                        } else if searchFailed {
                            Text(L10n.text("证券目录暂时不可用，请稍后重试。"))
                                .foregroundStyle(.secondary)
                        } else if directoryResults.isEmpty && matchingHoldings.isEmpty {
                            Text(L10n.text("没有找到匹配的证券"))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(directoryResults) { security in row(security) }
                        }
                    }
                } else if matchingHoldings.isEmpty {
                    Text(L10n.text("不需要先持有股票，搜索后即可选择。"))
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .searchable(text: $query, prompt: L10n.text("搜索股票、ETF 或公司名"))
            .appPageBackground().navigationTitle(preset.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("取消")) { dismiss() }
                }
            }
            .task(id: searchText) { await search() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ security: AIQuestionSecurity) -> some View {
        Button {
            guard !didSelect else { return }
            didSelect = true
            onSelect(security)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                AssetLogo(ticker: security.ticker, logoSymbol: security.logoSymbol, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(security.ticker).font(.body.weight(.semibold))
                    Text(security.name).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let venue = security.venue {
                    Text(venue).font(.caption).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(CatfolioTheme.primaryText)
            .contentShape(Rectangle())
        }
        .disabled(didSelect)
    }

    private func search() async {
        let text = searchText
        guard !text.isEmpty else {
            results = []
            completedQuery = nil
            searchFailed = false
            return
        }
        do { try await Task.sleep(for: .milliseconds(160)) }
        catch { return }
        let matches = await Task.detached(priority: .userInitiated) { () -> [AIQuestionSecurity]? in
            guard let catalog = try? CompanyReferenceCatalog.bundled.get() else { return nil }
            return MarketSecurityResult.search(text, in: catalog).map(AIQuestionSecurity.init(result:))
        }.value
        guard !Task.isCancelled, searchText == text else { return }
        results = matches ?? []
        searchFailed = matches == nil
        completedQuery = text
    }
}
