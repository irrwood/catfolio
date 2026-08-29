import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var overview: PortfolioOverview?
    @Published var portfolioChart: PortfolioChartResponse?
    @Published var holdings: [Holding] = []
    @Published var comparison: ComparisonResponse?
    @Published var isPortfolioLoading = false
    @Published var isReturnsLoading = false
    @Published var portfolioError: String?
    @Published var returnsError: String?
    @Published var activeBroker: BrokerProvider?
    @Published var localSource = "尚未导入"
    @Published var localUpdatedAt: Date?

    private var document = LocalPortfolioDocument.empty
    private static let brokerKey = "catfolio.activeBroker"

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.brokerKey) {
            activeBroker = BrokerProvider(rawValue: raw)
        }
    }

    func refreshPortfolio() async {
        isPortfolioLoading = true
        portfolioError = nil
        defer { isPortfolioLoading = false }
        do {
            let loaded = try await LocalPortfolioStore.shared.load()
            try apply(loaded)
        } catch {
            overview = nil
            portfolioChart = nil
            holdings = []
            portfolioError = error.localizedDescription
        }
    }

    func refreshReturns() async {
        isReturnsLoading = true
        returnsError = nil
        defer { isReturnsLoading = false }
        do {
            let loaded = try await LocalPortfolioStore.shared.load()
            document = loaded
            if KeychainStore.string(for: LocalServiceKeys.fmp)?.isEmpty == false {
                if let enriched = try? await LocalMarketDataClient().comparison(document: loaded) {
                    comparison = enriched
                } else {
                    comparison = try LocalPortfolioEngine.comparison(for: loaded)
                }
            } else {
                comparison = try LocalPortfolioEngine.comparison(for: loaded)
            }
        } catch {
            comparison = nil
            returnsError = error.localizedDescription
        }
    }

    func volumeProfile(for ticker: String) async throws -> VolumeProfile {
        let currency = holdings.first(where: { $0.ticker == ticker })?.quoteCurrency ?? "USD"
        return try await LocalMarketDataClient().volumeProfile(ticker: ticker, currency: currency)
    }

    func loadBriefing() async throws -> String {
        let loaded = try await LocalPortfolioStore.shared.load()
        return try await LocalAIClient().briefing(document: loaded)
    }

    func askAI(_ question: String) async throws -> String {
        let loaded = try await LocalPortfolioStore.shared.load()
        return try await LocalAIClient().answer(question, document: loaded)
    }

    func selectBroker(_ provider: BrokerProvider) {
        activeBroker = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.brokerKey)
    }

    func loadETFLookThrough(basis: ETFLookThroughBasis) async throws -> ETFLookThroughResponse {
        let loaded = try await LocalPortfolioStore.shared.load()
        return try LocalETFLookThrough.make(document: loaded, basis: basis)
    }

    func importCSV(_ data: Data, filename _: String) async throws -> CSVImportResult {
        let (positions, result) = try LocalCSVImporter.parse(data)
        let saved = try await LocalPortfolioStore.shared.replace(positions: positions, source: "CSV")
        try apply(saved)
        return result
    }

    func importTrading212(_ snapshot: Trading212Snapshot) async throws -> CSVImportResult {
        var warnings: [String] = []
        let positions = snapshot.positions.compactMap { position -> LocalPositionRecord? in
            guard position.quantity > 0 else { return nil }
            guard let average = position.averagePricePaid, average > 0 else {
                warnings.append("\(position.rawTicker) 缺少平均成本，已跳过")
                return nil
            }
            return LocalPositionRecord(
                ticker: position.ticker, name: position.name, shares: position.quantity,
                averageCost: average, currency: position.currency,
                quotePrice: position.currentPrice ?? average, quoteCurrency: position.currency,
                source: "Trading 212"
            )
        }
        return try await replace(positions, source: "Trading 212", warnings: warnings)
    }

    func importMoomoo(_ snapshot: MoomooSnapshot) async throws -> CSVImportResult {
        var warnings: [String] = []
        let positions = snapshot.positions.compactMap { position -> LocalPositionRecord? in
            guard position.positionSide.uppercased() != "SHORT", position.quantityValue > 0 else { return nil }
            guard let average = position.costPriceValue, average > 0 else {
                warnings.append("\(position.code) 缺少有效成本价，已跳过")
                return nil
            }
            return LocalPositionRecord(
                ticker: Self.moomooTicker(position.code), name: position.stockName,
                shares: position.quantityValue, averageCost: average,
                currency: position.currency.uppercased(), quotePrice: position.nominalPriceValue ?? average,
                quoteCurrency: position.currency.uppercased(), source: "Moomoo"
            )
        }
        return try await replace(positions, source: "Moomoo", warnings: warnings)
    }

    func importIBKR(_ snapshot: IBKRFlexSnapshot) async throws -> CSVImportResult {
        var warnings: [String] = []
        let positions = snapshot.positions.compactMap { position -> LocalPositionRecord? in
            guard position.quantity > 0 else { return nil }
            let category = position.assetCategory.uppercased()
            guard category.isEmpty || category == "STK" else {
                warnings.append("已跳过不受支持的 \(category) 持仓 \(position.symbol)")
                return nil
            }
            guard let average = position.averageCost, average > 0 else {
                warnings.append("\(position.symbol) 缺少平均成本，已跳过")
                return nil
            }
            let currency = position.currency.isEmpty ? "USD" : position.currency.uppercased()
            let quote = position.markPrice ?? position.marketValue.map { $0 / position.quantity } ?? average
            return LocalPositionRecord(
                ticker: position.symbol.uppercased(), name: position.name, shares: position.quantity,
                averageCost: average, currency: currency, quotePrice: quote,
                quoteCurrency: currency, source: "IBKR Flex"
            )
        }
        return try await replace(positions, source: "IBKR Flex", warnings: warnings)
    }

    private func replace(_ rawPositions: [LocalPositionRecord], source: String, warnings: [String]) async throws -> CSVImportResult {
        let positions = Self.merge(rawPositions)
        let saved = try await LocalPortfolioStore.shared.replace(positions: positions, source: source)
        try apply(saved)
        return CSVImportResult(
            ok: true, holdingsCount: positions.count, transactionsCount: nil,
            backupCreated: false, warnings: warnings,
            holdings: positions.map {
                CSVImportedHolding(ticker: $0.ticker, name: $0.name, shares: $0.shares, averageCost: $0.averageCost, currency: $0.currency)
            }
        )
    }

    private func apply(_ loaded: LocalPortfolioDocument) throws {
        let presentation = try LocalPortfolioEngine.presentation(for: loaded)
        document = loaded
        overview = presentation.0
        portfolioChart = presentation.1
        holdings = presentation.2
        localSource = loaded.source
        localUpdatedAt = loaded.updatedAt
        comparison = try? LocalPortfolioEngine.comparison(for: loaded)
    }

    private static func merge(_ positions: [LocalPositionRecord]) -> [LocalPositionRecord] {
        var grouped: [String: LocalPositionRecord] = [:]
        for position in positions {
            let key = position.ticker.uppercased()
            guard let existing = grouped[key], existing.currency == position.currency,
                  existing.quoteCurrency == position.quoteCurrency else {
                grouped[key] = position
                continue
            }
            let shares = existing.shares + position.shares
            guard shares > 0 else { continue }
            grouped[key] = LocalPositionRecord(
                ticker: key, name: existing.name.isEmpty ? position.name : existing.name, shares: shares,
                averageCost: (existing.averageCost * existing.shares + position.averageCost * position.shares) / shares,
                currency: existing.currency,
                quotePrice: (existing.quotePrice * existing.shares + position.quotePrice * position.shares) / shares,
                quoteCurrency: existing.quoteCurrency, source: existing.source
            )
        }
        return grouped.values.sorted { $0.ticker < $1.ticker }
    }

    private static func moomooTicker(_ value: String) -> String {
        let parts = value.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return value.uppercased() }
        let market = parts[0].uppercased()
        var code = parts[1].uppercased()
        if market == "HK", code.count == 5, code.first == "0" { code.removeFirst() }
        let suffixes = [
            "US": "", "HK": ".HK", "SG": ".SI", "JP": ".T", "JA": ".T",
            "AU": ".AX", "CA": ".TO", "SH": ".SS", "SZ": ".SZ", "BMS": ".KL",
        ]
        return suffixes[market].map { code + $0 } ?? value.uppercased()
    }
}
