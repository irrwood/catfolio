import Foundation

struct AlpacaAccountClient {
    let http: DirectBrokerHTTP
    init(http: DirectBrokerHTTP = .init()) { self.http = http }

    func snapshot(credentials: DirectBrokerCredentials) async throws -> DirectBrokerSnapshot {
        guard credentials.broker == .alpaca, credentials.isComplete else { throw DirectBrokerError.credentials }
        let account = try await http.data(Self.request(path: "/v2/account", credentials: credentials))
        let positions = try await http.data(Self.request(path: "/v2/positions", credentials: credentials))
        return try Self.decode(account: account, positions: positions, environment: credentials.environment)
    }
    static func request(path: String, credentials: DirectBrokerCredentials) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(credentials.environment.host)\(path)")!, timeoutInterval: 20)
        request.setValue(credentials.key, forHTTPHeaderField: "APCA-API-KEY-ID")
        request.setValue(credentials.secret, forHTTPHeaderField: "APCA-API-SECRET-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private struct Account: Decodable {
        let id: String
        let account_number: String
        let currency: String
        let status: String
    }
    private struct Position: Decodable {
        let symbol: String
        let asset_class: String
        let qty: String
        let avg_entry_price: String
        let current_price: String?
        let side: String
    }
    static func decode(account data: Data, positions positionData: Data,
                       environment: AlpacaEnvironment, now: Date = .now) throws -> DirectBrokerSnapshot {
        let account = try DirectBrokerHTTP.decode(Account.self, from: data)
        guard UUID(uuidString: account.id) != nil, !account.account_number.isEmpty,
              !account.status.isEmpty, !["CLOSED", "REJECTED"].contains(account.status) else {
            throw DirectBrokerError.incomplete
        }
        guard account.currency == "USD" else { throw DirectBrokerError.unsupported }
        let id = "\(environment.rawValue):\(account.id.lowercased())"
        let label = "Alpaca · \(environment.title) · ••••\(account.account_number.suffix(4))"
        let rows = try DirectBrokerHTTP.decode([Position].self, from: positionData)
        var seen = Set<String>()
        let positions = try rows.compactMap { row -> LocalPositionRecord? in
            let quantity = try DirectBrokerHTTP.number(row.qty)
            if quantity == 0 { return nil }
            guard row.asset_class == "us_equity", row.side == "long", quantity > 0,
                  row.symbol.range(of: "^[A-Z][A-Z0-9.\\-]{0,14}$", options: .regularExpression) != nil else {
                throw DirectBrokerError.unsupported
            }
            guard seen.insert(row.symbol).inserted, let quote = row.current_price else { throw DirectBrokerError.incomplete }
            let cost = try DirectBrokerHTTP.number(row.avg_entry_price)
            let price = try DirectBrokerHTTP.number(quote)
            guard cost >= 0, price > 0, (cost * quantity).isFinite, (price * quantity).isFinite else {
                throw DirectBrokerError.incomplete
            }
            return LocalPositionRecord(ticker: row.symbol.replacingOccurrences(of: ".", with: "-"), name: row.symbol, shares: quantity, averageCost: cost,
                currency: "USD", quotePrice: price, quoteCurrency: "USD", source: "Alpaca", openedDate: nil,
                accountID: id, accountName: label, accountCurrency: "USD", fxPnlStatus: "unavailable")
            // Positions API has no exchange timestamp. Do not fabricate one from the request time.
        }
        return .init(broker: .alpaca, accountID: id, accountLabel: label, currency: "USD", positions: positions, fetchedAt: now)
    }
}
