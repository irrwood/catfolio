import Foundation
import Observation

@MainActor @Observable
final class DCAStore {
    private static let key = "catfolio.dca.ios.v1"
    var settings: DCASettings
    private(set) var prices: [PolicyPricePoint] = []
    private(set) var result: DCAResult?
    private(set) var isRefreshing = false
    private(set) var usesBundledHistory = false
    private(set) var resultUsesBundledHistory = false
    private(set) var isLoading = false
    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var isDemo = false
    private(set) var loadedSymbol = ""
    private var requestID = UUID()
    private var runID = UUID()
    private let defaults: UserDefaults
    @ObservationIgnored private let historyLoader: @Sendable (String, String, String) async -> [PolicyPricePoint]


    init(defaults: UserDefaults = .standard,
         historyLoader: @escaping @Sendable (String, String, String) async -> [PolicyPricePoint] = { symbol, from, to in
             let history = await LocalMarketDataClient().historicalCloses(symbols: [symbol], from: from,
                 to: to, dividendAdjusted: false)
             return (history[symbol] ?? [:]).map { .init(day: $0.key, close: $0.value) }.sorted { $0.day < $1.day }
         }) {
        self.defaults = defaults
        self.historyLoader = historyLoader
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(DCASettings.self, from: data), saved.validationError == nil {
            settings = saved
        } else { settings = DCASettings() }
    }
    var isStale: Bool { result.map { $0.settings != settings } ?? false }
    var canRun: Bool { !isLoading && !isRunning && settings.validationError == nil && loadedSymbol == settings.normalizedSymbol && prices.count >= 2 }
    func save() {
        if settings.validationError == nil, let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
    func annualReturn(years: Int) -> Double? {
        guard let last = prices.last, let end = DayDateCodec.date(from: last.day),
              let start = DCASimulation.calendar.date(byAdding: .year, value: -years, to: end),
              let first = prices.last(where: { $0.day <= DayDateCodec.string(from: start) }),
              let firstDate = DayDateCodec.date(from: first.day) else { return nil }
        return pow(last.close / first.close, 365.25 * 86400 / end.timeIntervalSince(firstDate)) - 1
    }
    func load(demo: Bool) async {
        let id = UUID(); requestID = id; runID = UUID(); isRunning = false; isRefreshing = false
        let symbol = settings.normalizedSymbol
        guard symbol.range(of: #"^[A-Z]{1,6}(-[AB])?$"#, options: .regularExpression) != nil else {
            error = L10n.text("请输入美股或 ETF 代码"); prices = []; result = nil; loadedSymbol = ""; isLoading = false; return
        }
        if loadedSymbol != symbol || isDemo != demo { result = nil; prices = []; usesBundledHistory = false }
        isLoading = true; error = nil; isDemo = demo
        let end = DCASimulation.calendar.date(byAdding: .day, value: -1, to: Date())!
        let endDay = DayDateCodec.string(from: end)
        if demo {
            prices = DCASimulation.demoPrices(symbol: symbol, end: end)
            loadedSymbol = symbol; usesBundledHistory = false; isLoading = false
            if result == nil { await run() }
            return
        }
        let bundled = symbol == "SPY" ? try? DCABundledHistory.spy.get() : nil
        let local = bundled?.prices.filter { $0.day <= endDay } ?? []
        if prices.isEmpty, !local.isEmpty {
            prices = local; loadedSymbol = symbol; usesBundledHistory = true
        }
        if !prices.isEmpty {
            isLoading = false
            if result == nil { await run() }
        }
        guard requestID == id, !Task.isCancelled else { return }
        isRefreshing = !prices.isEmpty
        defer {
            if requestID == id { isLoading = false; isRefreshing = false }
        }
        let requestedStart = DCASimulation.calendar.date(byAdding: .year, value: -1, to: settings.start)!
        let sixYears = DCASimulation.calendar.date(byAdding: .year, value: -6, to: end)!
        let from = bundled?.firstDay ?? DayDateCodec.string(from: min(requestedStart, sixYears))
        let refreshed = await historyLoader(symbol, from, endDay).filter { $0.day <= endDay }
        guard requestID == id, !Task.isCancelled else { return }
        if DCABundledHistory.canReplace(prices, with: refreshed) {
            let changed = !DCABundledHistory.equal(prices, refreshed)
            prices = refreshed; loadedSymbol = symbol; usesBundledHistory = false; isLoading = false
            if result == nil || (changed && !isStale) { await run() }
        } else if prices.count < 2 {
            error = L10n.text("行情暂不可用，请重试或更换标的")
        }
    }
    func run() async {
        guard canRun else { error = settings.validationError; return }
        let id = UUID(); runID = id
        let config = settings, input = prices, bundled = usesBundledHistory
        isRunning = true; error = nil
        let task = Task.detached(priority: .userInitiated) { try DCASimulation.run(settings: config, prices: input) }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard id == runID, !Task.isCancelled else { return }
            result = value; resultUsesBundledHistory = bundled; save()
        } catch is CancellationError {
        } catch {
            if id == runID { self.error = error.localizedDescription }
        }
        if id == runID { isRunning = false }
    }
}


/// Search only instruments the USD DCA engine can price, without guessing a listing market.
enum DCAInstrumentSearch {
    static let presets = ["SPY", "QQQ", "VTI", "AAPL", "MSFT", "NVDA", "TSLA", "TSM"]

    static func search(_ query: String, in catalog: CompanyReferenceCatalog) -> [MarketSecurityResult] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let matches: [CompanyReferenceCatalog.Entry]
        if text.range(of: #"[\p{Han}]"#, options: .regularExpression) != nil {
            // Reuse established Chinese display aliases, never machine-translate a ticker.
            matches = catalog.entries.values.filter {
                $0.market == "US" && CompanyNameCatalog.displayName(ticker: $0.symbol,
                    fallback: $0.name ?? $0.symbol, mode: .chineseShort).localizedCaseInsensitiveContains(text)
            }.sorted { $0.symbol < $1.symbol }
        } else {
            matches = catalog.search(text, market: "US", limit: 200)
        }
        return Array(matches.compactMap { entry -> MarketSecurityResult? in
            let symbol = entry.symbol.uppercased().replacingOccurrences(of: ".", with: "-")
            guard entry.market == "US", (entry.currency ?? "USD").uppercased() == "USD",
                  symbol.range(of: #"^[A-Z]{1,6}(-[AB])?$"#, options: .regularExpression) != nil else { return nil }
            return MarketSecurityResult(ticker: symbol, name: entry.name ?? symbol, market: entry.market,
                exchange: entry.exchange, currency: "USD", sector: entry.sector,
                isFund: HoldingSecurityKind.classify(instrumentType: entry.instrumentType,
                    names: [entry.name ?? ""]) == .fund)
        }.prefix(40))
    }
}
