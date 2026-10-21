import Foundation

struct LongbridgeAccountClient {
    let http: DirectBrokerHTTP
    let quoteRequest: LongbridgeMarketDataClient.Request?
    init(http: DirectBrokerHTTP = .init(), quoteRequest: LongbridgeMarketDataClient.Request? = nil) {
        self.http = http; self.quoteRequest = quoteRequest
    }
    private struct Envelope<T: Decodable>: Decodable { let code: Int; let data: T? }
    private struct Balances: Decodable {
        struct Balance: Decodable { let currency: String }
        let list: [Balance]
    }
    private struct Stocks: Decodable {
        struct Channel: Decodable { let account_channel: String; let stock_info: [Position] }
        struct Position: Decodable {
            let symbol: String
            let symbol_name: String
            let currency: String
            let market: String
            let quantity: String
            let cost_price: String?
        }
        let list: [Channel]
    }
    private func read<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = [], credentials: LongbridgeCredentials) async throws -> T {
        let raw = try await http.data(credentials.signedGET(path: path, query: query))
        let envelope = try DirectBrokerHTTP.decode(Envelope<T>.self, from: raw)
        guard envelope.code == 0 else {
            if [401003, 401004, 403201, 403203, 403205].contains(envelope.code) { throw DirectBrokerError.unauthorized }
            throw DirectBrokerError.rejected(envelope.code)
        }
        guard let data = envelope.data else { throw DirectBrokerError.incomplete }
        return data
    }
    func snapshot(credentials: DirectBrokerCredentials, now: Date = .now) async throws -> DirectBrokerSnapshot {
        guard credentials.broker == .longbridge, credentials.isComplete else { throw DirectBrokerError.credentials }
        let signed = credentials.longbridge
        let request = quoteRequest ?? LongbridgeMarketDataClient(credentials: signed).request
        // Command 4 returns the authenticated member ID. It survives token/key rotation.
        let profile = try LongbridgeProto(await request(4, LongbridgeProto.string(1, "en")))
        guard let memberID = profile.integer(1), memberID > 0 else { throw DirectBrokerError.incomplete }
        let id = String(memberID)
        // Ask the broker for a USD reporting denomination; do not infer it from a stock's currency.
        let balances = try await read(Balances.self, path: "/v1/asset/account",
                                      query: [.init(name: "currency", value: "USD")], credentials: signed)
        guard let currency = balances.list.first?.currency,
              balances.list.allSatisfy({ $0.currency == currency }),
              ["USD", "HKD", "CNY", "CNH"].contains(currency) else { throw DirectBrokerError.unsupported }
        let stocks = try await read(Stocks.self, path: "/v1/asset/stock", credentials: signed)
        var channels = Set<String>()
        var grouped: [String: [Stocks.Position]] = [:]
        for channel in stocks.list {
            guard !channel.account_channel.isEmpty, channels.insert(channel.account_channel).inserted else {
                throw DirectBrokerError.incomplete
            }
            var symbols = Set<String>()
            for row in channel.stock_info {
                let quantity = try DirectBrokerHTTP.number(row.quantity)
                guard symbols.insert(row.symbol).inserted else { throw DirectBrokerError.incomplete }
                if quantity == 0 { continue }
                guard quantity > 0 else { throw DirectBrokerError.unsupported }
                _ = try Self.ticker(symbol: row.symbol, market: row.market, currency: row.currency)
                guard let rawCost = row.cost_price, try DirectBrokerHTTP.number(rawCost) >= 0 else {
                    throw DirectBrokerError.incomplete
                }
                grouped[row.symbol, default: []].append(row)
            }
        }
        var positions: [LocalPositionRecord] = []
        let symbols = grouped.keys.sorted()
        // The quote API accepts at most 500 symbols. Small batches also bound payload size.
        for start in stride(from: 0, to: symbols.count, by: 100) {
            try Task.checkCancellation()
            let batch = Array(symbols[start..<min(start + 100, symbols.count)])
            let body = batch.reduce(into: Data()) { $0 += LongbridgeProto.string(1, $1) }
            let infos = try LongbridgeProto(await request(10, body)).messages(1)
            let quotes = try LongbridgeProto(await request(11, body)).messages(1)
            for symbol in batch {
                guard let rows = grouped[symbol], let first = rows.first,
                      infos.filter({ $0.string(1) == symbol }).count == 1,
                      quotes.filter({ $0.string(1) == symbol }).count == 1,
                      let info = infos.first(where: { $0.string(1) == symbol }),
                      let quote = quotes.first(where: { $0.string(1) == symbol }),
                      info.string(7) == first.currency,
                      rows.allSatisfy({ $0.currency == first.currency && $0.market == first.market }) else {
                    throw DirectBrokerError.incomplete
                }
                guard Self.supportedBoards.contains(info.string(17) ?? "") else { throw DirectBrokerError.unsupported }
                guard let price = quote.number(2), price.isFinite, price > 0,
                      let timestamp = quote.integer(7), timestamp > 0,
                      (-60...14 * 86400).contains(now.timeIntervalSince1970 - Double(timestamp)) else {
                    throw DirectBrokerError.incomplete
                }
                var quantity = 0.0, totalCost = 0.0
                for row in rows {
                    let shares = try DirectBrokerHTTP.number(row.quantity)
                    guard let rawCost = row.cost_price else { throw DirectBrokerError.incomplete }
                    quantity += shares
                    totalCost += shares * (try DirectBrokerHTTP.number(rawCost))
                }
                guard quantity.isFinite, totalCost.isFinite, (quantity * price).isFinite else { throw DirectBrokerError.incomplete }
                positions.append(.init(ticker: try Self.ticker(symbol: symbol, market: first.market, currency: first.currency),
                    name: first.symbol_name.isEmpty ? symbol : first.symbol_name, shares: quantity, averageCost: totalCost / quantity,
                    currency: first.currency, quotePrice: price, quoteCurrency: first.currency, source: "Longbridge", openedDate: nil,
                    accountID: id, accountName: "Longbridge", accountCurrency: currency, fxPnlStatus: "unavailable",
                    quoteObservedAt: Date(timeIntervalSince1970: Double(timestamp))))
            }
        }
        try Task.checkCancellation()
        return .init(broker: .longbridge, accountID: id, accountLabel: "Longbridge · ••••\(id.suffix(4))",
                     currency: currency, positions: positions, fetchedAt: .now)
    }
    static let supportedBoards: Set<String> = ["USMain", "USPink", "HKEquity", "SHMainConnect", "SHMainNonConnect", "SHSTAR",
                                               "SZMainConnect", "SZMainNonConnect", "SZGEMConnect", "SZGEMNonConnect"]
    static func ticker(symbol: String, market: String, currency: String) throws -> String {
        if market == "US", currency == "USD", symbol.hasSuffix(".US") {
            let ticker = String(symbol.dropLast(3))
            if ticker.range(of: "^[A-Z][A-Z0-9.\\-]{0,14}$", options: .regularExpression) != nil { return ticker.replacingOccurrences(of: ".", with: "-") }
        }
        if market == "HK", currency == "HKD", symbol.hasSuffix(".HK") {
            let code = String(symbol.dropLast(3))
            if code.range(of: "^[0-9]{1,5}$", options: .regularExpression) != nil, let number = Int(code), number > 0 {
                return String(format: "%04d.HK", number)
            }
        }
        if ["CN", "SH", "SZ"].contains(market), currency == "CNY",
           symbol.hasSuffix(".SH") || symbol.hasSuffix(".SZ"), let security = ChinaSecurity(symbol) {
            return security.ticker
        }
        throw DirectBrokerError.unsupported
    }
}
