import SwiftUI

struct ReturnsBenchmarkPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var appLocale
    @AppStorage(ComparisonBenchmarkCatalog.preferenceKey) private var storedBenchmarks: String?
    @State private var query = ""
    @State private var results: [MarketSecurityResult] = []
    /// The query `results` answer, so a stale list is not mistaken for an
    /// empty one while the next search runs.
    @State private var searchedQuery = ""

    private var symbols: [String] { ComparisonBenchmarkCatalog.symbols(from: storedBenchmarks) }
    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isFull: Bool { symbols.count >= ComparisonBenchmarkCatalog.maximumCount }

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    chosen
                    recommended
                } else {
                    found
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .appPageBackground(SettingsTemplate.pageBackground)
            .navigationTitle(L10n.text("对比标的"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L10n.text("搜索指数或个股")
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.characters)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    AppModalDoneButton { dismiss() }
                }
            }
            .task(id: searchText) { await search() }
        }
    }

    private var chosen: some View {
        Section {
            if symbols.isEmpty {
                Text(L10n.text("还没有对比标的，搜索或从推荐里添加。"))
                    .appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
            ForEach(symbols, id: \.self) { symbol in
                row(symbol: symbol, name: ComparisonBenchmarkCatalog.name(for: symbol)) {
                    Button {
                        ComparisonBenchmarkCatalog.remove(symbol)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("移除 \(symbol)"))
                }
            }
            .onDelete { offsets in
                let current = symbols
                ComparisonBenchmarkCatalog.store(current.enumerated().filter { !offsets.contains($0.offset) }.map(\.element))
            }
        } header: {
            Text(L10n.text("已添加 \(symbols.count)/\(ComparisonBenchmarkCatalog.maximumCount)"))
        } footer: {
            Text(L10n.text("左滑或点 − 移除。收益对比页上长按卡片也可以移除。"))
        }
    }

    @ViewBuilder
    private var recommended: some View {
        let missing = ComparisonBenchmarkCatalog.defaults.filter { !symbols.contains($0) }
        if !missing.isEmpty {
            Section {
                ForEach(missing, id: \.self) { symbol in
                    row(symbol: symbol, name: ComparisonBenchmarkCatalog.name(for: symbol)) {
                        addButton(symbol: symbol, name: nil)
                    }
                }
            } header: {
                Text(L10n.text("推荐指数"))
            }
        }
    }

    @ViewBuilder
    private var found: some View {
        Section {
            if results.isEmpty, searchedQuery == searchText {
                Text(L10n.text("没有找到「\(searchText)」"))
                    .appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
            ForEach(results) { result in
                let symbol = Self.benchmarkSymbol(for: result)
                row(symbol: symbol, name: CompanyNameCatalog.displayName(ticker: result.ticker, fallback: result.name),
                    venue: result.venue) {
                    if symbols.contains(symbol) {
                        Button {
                            ComparisonBenchmarkCatalog.remove(symbol)
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(CatfolioTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("移除 \(symbol)"))
                    } else {
                        addButton(symbol: symbol, name: result.name)
                    }
                }
            }
        } header: {
            Text(L10n.text("证券"))
        } footer: {
            Text(L10n.text("离线证券目录：美股与主要海外市场的股票和 ETF。"))
        }
    }

    private func addButton(symbol: String, name: String?) -> some View {
        Button {
            ComparisonBenchmarkCatalog.add(symbol, name: name)
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(isFull ? Color.secondary : CatfolioTheme.accent)
        }
        .buttonStyle(.plain)
        .disabled(isFull)
        .accessibilityLabel(L10n.text("添加 \(symbol)"))
    }

    private func row(symbol: String, name: String?, venue: String? = nil,
                     @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                AssetLogo(ticker: symbol, logoSymbol: symbol, size: 36)
                if symbols.contains(symbol) {
                    // The colour the series draws in.
                    Circle()
                        .fill(ReturnsSeriesStyle.color(for: symbol))
                        .frame(width: 11, height: 11)
                        .overlay(Circle().stroke(SettingsTemplate.card, lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(symbol)
                    .appText(.body, weight: .semibold)
                    .lineLimit(1)
                if let name {
                    // The built-in names are UI keys; a directory name is not.
                    Text(ComparisonBenchmarkCatalog.names[symbol] == name ? L10n.label(name) : name)
                        .appText(.label)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let venue {
                Text(venue)
                    .appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            trailing()
        }
        .frame(minHeight: 48)
    }

    /// The symbol the price history is fetched under: the broker's ticker
    /// with the exchange suffix the quote provider needs.
    private static func benchmarkSymbol(for result: MarketSecurityResult) -> String {
        LocalMarketDataClient.yahooSymbol(ticker: result.ticker, currency: result.currency ?? "USD")
    }

    /// Off the main thread: the directory holds some twenty thousand
    /// securities, and its first use decodes it.
    @MainActor private func search() async {
        let text = searchText
        guard !text.isEmpty else {
            results = []
            searchedQuery = ""
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let found = await Task.detached(priority: .userInitiated) { () -> [MarketSecurityResult] in
            guard let catalog = try? CompanyReferenceCatalog.bundled.get() else { return [] }
            return MarketSecurityResult.search(text, in: catalog)
        }.value
        guard !Task.isCancelled else { return }
        results = found
        searchedQuery = text
    }
}
