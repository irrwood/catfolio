import Foundation

struct LocalPositionRecord: Codable, Equatable {
    let ticker: String
    let name: String
    let shares: Double
    let averageCost: Double
    let currency: String
    let quotePrice: Double
    let quoteCurrency: String
    let source: String
}

struct LocalPortfolioSnapshotRecord: Codable, Equatable {
    let date: String
    let marketValueUSD: Double
    let costUSD: Double
}

struct LocalPortfolioDocument: Codable, Equatable {
    var schemaVersion = 1
    var source: String
    var updatedAt: Date
    var positions: [LocalPositionRecord]
    var snapshots: [LocalPortfolioSnapshotRecord]

    static let empty = LocalPortfolioDocument(
        source: "local",
        updatedAt: .distantPast,
        positions: [],
        snapshots: []
    )
}

enum LocalPortfolioError: LocalizedError {
    case noPortfolio
    case invalidCSV(String)
    case unsupportedCurrency(String)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .noPortfolio:
            "手机中还没有组合数据，请先直连券商或导入 CSV"
        case let .invalidCSV(message):
            "CSV 无法导入：\(message)"
        case let .unsupportedCurrency(currency):
            "暂不支持 \(currency) 换算为 USD"
        case .writeFailed:
            "无法保存到 iPhone 本地存储"
        }
    }
}

actor LocalPortfolioStore {
    static let shared = LocalPortfolioStore()

    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        fileURL = root.appendingPathComponent("Catfolio", isDirectory: true)
            .appendingPathComponent("portfolio.json", isDirectory: false)
    }

    func load() throws -> LocalPortfolioDocument {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LocalPortfolioDocument.self, from: data)
    }

    func replace(positions: [LocalPositionRecord], source: String) throws -> LocalPortfolioDocument {
        guard !positions.isEmpty else { throw LocalPortfolioError.noPortfolio }
        let previous = (try? load()) ?? .empty
        let now = Date()
        let date = DayDateFormatter.shared.string(from: now)
        let totals = try LocalPortfolioEngine.totals(for: positions)
        let snapshot = LocalPortfolioSnapshotRecord(
            date: date,
            marketValueUSD: totals.marketValue,
            costUSD: totals.cost
        )
        var snapshots = previous.snapshots.filter { $0.date != date }
        snapshots.append(snapshot)
        snapshots.sort { $0.date < $1.date }
        if snapshots.count > 730 {
            snapshots.removeFirst(snapshots.count - 730)
        }
        let document = LocalPortfolioDocument(
            source: source,
            updatedAt: now,
            positions: positions,
            snapshots: snapshots
        )
        try save(document)
        return document
    }

    private func save(_ document: LocalPortfolioDocument) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            throw LocalPortfolioError.writeFailed
        }
    }
}

enum LocalPortfolioEngine {
    struct Totals {
        let cost: Double
        let marketValue: Double
    }

    private static let usdRates: [String: Double] = [
        "USD": 1,
        "GBP": 1.346,
        "GBX": 0.01346,
        "EUR": 1.163,
        "HKD": 0.128,
        "CAD": 0.73,
        "AUD": 0.67,
        "SGD": 0.78,
        "JPY": 0.0068,
        "CNY": 0.14,
    ]

    static func usd(_ amount: Double, currency: String) throws -> Double {
        let currency = currency.uppercased()
        guard let rate = usdRates[currency] else {
            throw LocalPortfolioError.unsupportedCurrency(currency)
        }
        return amount * rate
    }

    static func totals(for positions: [LocalPositionRecord]) throws -> Totals {
        var cost = 0.0
        var marketValue = 0.0
        for position in positions {
            cost += try usd(position.shares * position.averageCost, currency: position.currency)
            marketValue += try usd(position.shares * position.quotePrice, currency: position.quoteCurrency)
        }
        return Totals(cost: cost, marketValue: marketValue)
    }

    static func presentation(
        for document: LocalPortfolioDocument
    ) throws -> (PortfolioOverview, PortfolioChartResponse, [Holding]) {
        guard !document.positions.isEmpty else { throw LocalPortfolioError.noPortfolio }
        let totals = try totals(for: document.positions)
        let unrealized = totals.marketValue - totals.cost
        let asOf = document.updatedAt == .distantPast
            ? nil
            : document.updatedAt.formatted(date: .abbreviated, time: .shortened)
        let summary = PortfolioSummary(
            totalCost: totals.cost,
            openPositions: document.positions.count,
            asOf: asOf,
            marketValue: totals.marketValue,
            unrealized: unrealized
        )
        let overview = PortfolioOverview(
            summary: summary,
            todayPnl: 0,
            breadth: Breadth(up: 0, down: 0, flat: document.positions.count)
        )
        let rows = try document.positions.map { position -> Holding in
            let costUSD = try usd(position.shares * position.averageCost, currency: position.currency)
            let marketUSD = try usd(position.shares * position.quotePrice, currency: position.quoteCurrency)
            let pnl = marketUSD - costUSD
            return Holding(
                ticker: position.ticker,
                logoSymbol: position.ticker,
                displayName: position.name.isEmpty ? position.ticker : position.name,
                sector: nil,
                source: position.source,
                shares: position.shares,
                averageCost: position.averageCost,
                costCurrency: position.currency,
                quotePrice: position.quotePrice,
                quoteCurrency: position.quoteCurrency,
                todayChangePercent: nil,
                marketValue: marketUSD,
                weight: totals.marketValue > 0 ? marketUSD / totals.marketValue : 0,
                unrealized: pnl,
                unrealizedPercent: costUSD > 0 ? pnl / costUSD * 100 : 0
            )
        }.sorted { $0.marketValue > $1.marketValue }

        let chartRows = document.snapshots.map {
            ChartPoint(dateText: $0.date, marketValue: $0.marketValueUSD, cost: $0.costUSD)
        }
        let current = chartRows.last ?? ChartPoint(
            dateText: DayDateFormatter.shared.string(from: Date()),
            marketValue: totals.marketValue,
            cost: totals.cost
        )
        let chart = PortfolioChartResponse(
            positionCount: rows.count,
            positionHistory: PositionHistory(available: !chartRows.isEmpty, rows: chartRows),
            currentPoint: current
        )
        return (overview, chart, rows)
    }

    static func comparison(for document: LocalPortfolioDocument) throws -> ComparisonResponse {
        guard let first = document.snapshots.first, first.marketValueUSD > 0 else {
            throw LocalPortfolioError.noPortfolio
        }
        let values = document.snapshots.map { Optional($0.marketValueUSD) }
        let portfolioReturn = document.snapshots.last.map { $0.marketValueUSD / first.marketValueUSD - 1 }
        let emptyBenchmark = document.snapshots.map { _ in Optional<Double>.none }
        let benchmarks = Dictionary(uniqueKeysWithValues: ["SPY", "QQQ", "VTI", "GLD"].map {
            ($0, emptyBenchmark)
        })
        return ComparisonResponse(
            available: true,
            dates: document.snapshots.map(\.date),
            portfolio: values,
            benchmarks: benchmarks,
            summary: ComparisonSummary(
                portfolioReturn: portfolioReturn,
                benchmarkReturn: nil,
                benchmarkReturns: Dictionary(uniqueKeysWithValues: ["SPY", "QQQ", "VTI", "GLD"].map {
                    ($0, Optional<Double>.none)
                })
            )
        )
    }
}

enum LocalCSVImporter {
    private struct Transaction {
        let date: Date
        let action: String
        let ticker: String
        let quantity: Double
        let price: Double
        let currency: String
        let name: String
    }

    static func parse(_ data: Data) throws -> ([LocalPositionRecord], CSVImportResult) {
        guard var text = String(data: data, encoding: .utf8) else {
            throw LocalPortfolioError.invalidCSV("文件必须使用 UTF-8 编码")
        }
        text = text.replacingOccurrences(of: "\u{feff}", with: "")
        let records = parseRecords(text)
        guard let header = records.first else { throw LocalPortfolioError.invalidCSV("文件为空") }
        let normalized = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let aliases: [String: [String]] = [
            "date": ["date", "trade date", "transaction date", "time"],
            "action": ["action", "type", "transaction type", "side", "direction"],
            "ticker": ["ticker", "symbol", "instrument", "stock", "isin", "code"],
            "quantity": ["quantity", "qty", "shares", "units", "amount", "no. of shares"],
            "price": ["price", "price / share", "trade price", "unit price", "execution price"],
            "currency": ["currency", "ccy", "curr", "currency (price)", "price currency"],
            "name": ["name", "company", "description", "instrument name", "security name"],
        ]
        var columns: [String: Int] = [:]
        for (key, choices) in aliases {
            if let index = normalized.firstIndex(where: { choices.contains($0) }) { columns[key] = index }
        }
        let missing = ["date", "action", "ticker", "quantity", "price"].filter { columns[$0] == nil }
        guard missing.isEmpty else {
            throw LocalPortfolioError.invalidCSV("缺少列：\(missing.joined(separator: "、"))")
        }

        var transactions: [Transaction] = []
        var warnings: [String] = []
        for (offset, row) in records.dropFirst().enumerated() {
            do {
                func field(_ name: String) -> String {
                    guard let index = columns[name], row.indices.contains(index) else { return "" }
                    return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                let action = field("action").uppercased()
                guard ["BUY", "SELL", "DIVIDEND"].contains(action) else { continue }
                let ticker = field("ticker").uppercased()
                guard !ticker.isEmpty else { continue }
                let quantity = try number(field("quantity"))
                let price = try number(field("price"))
                let currency = field("currency").uppercased()
                transactions.append(Transaction(
                    date: try date(field("date")),
                    action: action,
                    ticker: ticker,
                    quantity: quantity,
                    price: price,
                    currency: currency.isEmpty ? "USD" : currency,
                    name: field("name")
                ))
            } catch {
                warnings.append("第 \(offset + 2) 行：\(error.localizedDescription)")
            }
        }
        guard !transactions.isEmpty else { throw LocalPortfolioError.invalidCSV("没有有效交易") }

        struct PositionState { var shares = 0.0; var average = 0.0; var currency = "USD"; var name = "" }
        var states: [String: PositionState] = [:]
        for transaction in transactions.sorted(by: { $0.date < $1.date }) {
            guard transaction.action != "DIVIDEND" else { continue }
            var state = states[transaction.ticker] ?? PositionState()
            state.currency = transaction.currency
            if !transaction.name.isEmpty { state.name = transaction.name }
            if transaction.action == "BUY" {
                let newShares = state.shares + transaction.quantity
                if newShares > 0 {
                    state.average = (state.average * state.shares + transaction.price * transaction.quantity) / newShares
                }
                state.shares = newShares
            } else {
                state.shares = max(0, state.shares - transaction.quantity)
            }
            states[transaction.ticker] = state
        }
        let positions = states.compactMap { ticker, state -> LocalPositionRecord? in
            guard state.shares > 0.001 else { return nil }
            return LocalPositionRecord(
                ticker: ticker,
                name: state.name,
                shares: state.shares,
                averageCost: state.average,
                currency: state.currency,
                quotePrice: state.average,
                quoteCurrency: state.currency,
                source: "CSV"
            )
        }.sorted { $0.ticker < $1.ticker }
        guard !positions.isEmpty else { throw LocalPortfolioError.invalidCSV("没有未平仓持仓") }
        let imported = positions.map {
            CSVImportedHolding(ticker: $0.ticker, name: $0.name, shares: $0.shares, averageCost: $0.averageCost, currency: $0.currency)
        }
        return (positions, CSVImportResult(
            ok: true,
            holdingsCount: positions.count,
            transactionsCount: transactions.count,
            backupCreated: false,
            warnings: warnings,
            holdings: imported
        ))
    }

    private static func number(_ value: String) throws -> Double {
        guard let number = Double(value.replacingOccurrences(of: ",", with: "")) else {
            throw LocalPortfolioError.invalidCSV("无效数字 \(value)")
        }
        return number
    }

    private static func date(_ value: String) throws -> Date {
        for format in ["yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "yyyy/MM/dd", "dd-MM-yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        throw LocalPortfolioError.invalidCSV("无效日期 \(value)")
    }

    private static func parseRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var insideQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if insideQuotes, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    insideQuotes.toggle()
                }
            } else if character == ",", !insideQuotes {
                record.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !insideQuotes {
                if character == "\n" || !record.isEmpty || !field.isEmpty {
                    record.append(field)
                    if record.contains(where: { !$0.isEmpty }) { records.append(record) }
                    record = []
                    field = ""
                }
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        record.append(field)
        if record.contains(where: { !$0.isEmpty }) { records.append(record) }
        return records
    }
}
