import Foundation

/// An equity-only account snapshot. No transactions or option contracts are
/// synthesized from this data. Unexpected or partial responses fail atomically.
struct RobinhoodAccount: Identifiable, Equatable {
    let id: String
    let name: String
    let currency: String
    var displayName: String { "\(name) · ••••\(id.suffix(4))" }

    static func decode(_ payload: Any) throws -> [Self] {
        let rows = try RobinhoodAccountSnapshot.completeRows(payload, key: "accounts")
        var seen = Set<String>()
        return try rows.map { row in
            guard let id = row["account_number"] as? String, !id.isEmpty,
                  seen.insert(id).inserted else { throw RobinhoodAccountError.incomplete }
            // Require an explicit denomination; never value an unknown account as USD.
            guard let currency = row["currency"] as? String, currency.uppercased() == "USD" else {
                throw RobinhoodAccountError.unsupported
            }
            return Self(id: id, name: row["name"] as? String ?? "Robinhood", currency: "USD")
        }
    }
}

enum RobinhoodAccountError: LocalizedError {
    case incomplete, unsupported, expired, duplicate, wrongAccount, disconnected
    var errorDescription: String? {
        switch self {
        case .incomplete: L10n.text("Robinhood 持仓或成本数据不完整，现有账户未更新。")
        case .unsupported: L10n.text("此 Robinhood 账户的币种或股票持仓暂不支持导入，现有账户未更新。")
        case .expired: L10n.text("Robinhood 预览已过期，请重新读取持仓。")
        case .duplicate: L10n.text("此 Robinhood 账户已存在，请从账户详情同步。")
        case .wrongAccount: L10n.text("Robinhood 返回的账户不匹配，现有账户未更新。")
        case .disconnected: L10n.text("Robinhood 连接已变化，请重新读取账户和持仓。")
        }
    }
}

struct RobinhoodAccountSnapshot {
    let account: RobinhoodAccount
    let positions: [LocalPositionRecord]
    let fetchedAt: Date
    let connectionGeneration: Int

    static func completeRows(_ payload: Any, key: String) throws -> [[String: Any]] {
        if let rows = payload as? [[String: Any]] { return rows }
        guard let root = payload as? [String: Any] else { throw RobinhoodAccountError.incomplete }
        for marker in ["next", "next_cursor", "nextCursor"] {
            if let value = root[marker], !(value is NSNull), String(describing: value) != "" {
                throw RobinhoodAccountError.incomplete
            }
        }
        guard root["has_more"] as? Bool != true, root["truncated"] as? Bool != true,
              let rows = (root[key] ?? root["results"]) as? [[String: Any]] else {
            throw RobinhoodAccountError.incomplete
        }
        if let count = root["count"] as? Int, count != rows.count { throw RobinhoodAccountError.incomplete }
        if let total = root["total"] as? Int, total != rows.count { throw RobinhoodAccountError.incomplete }
        return rows
    }

    static func symbols(_ payload: Any, account: RobinhoodAccount) throws -> [String] {
        if let root = payload as? [String: Any], let number = root["account_number"] as? String,
           number != account.id { throw RobinhoodAccountError.wrongAccount }
        var seen = Set<String>()
        return try completeRows(payload, key: "positions").compactMap { row in
            if let number = row["account_number"] as? String, number != account.id {
                throw RobinhoodAccountError.wrongAccount
            }
            guard let quantity = RobinhoodMCPClient.number(row["quantity"]), quantity.isFinite else {
                throw RobinhoodAccountError.incomplete
            }
            if quantity == 0 { return nil }
            guard quantity > 0, let symbol = row["symbol"] as? String,
                  RobinhoodMCPClient.isUSSymbol(symbol), seen.insert(symbol).inserted else {
                throw RobinhoodAccountError.unsupported
            }
            return symbol
        }
    }

    static func decode(_ payload: Any, account: RobinhoodAccount,
                       quotes: [String: RobinhoodMCPClient.Quote], generation: Int,
                       now: Date = Date()) throws -> Self {
        guard account.currency == "USD" else { throw RobinhoodAccountError.unsupported }
        _ = try symbols(payload, account: account)
        let positions = try completeRows(payload, key: "positions").compactMap { row -> LocalPositionRecord? in
            guard let quantity = RobinhoodMCPClient.number(row["quantity"]) else { throw RobinhoodAccountError.incomplete }
            if quantity == 0 { return nil }
            guard let symbol = row["symbol"] as? String,
                  let cost = RobinhoodMCPClient.number(row["average_buy_price"]), cost.isFinite, cost >= 0,
                  let currency = row["currency"] as? String, currency.uppercased() == "USD",
                  let quote = quotes[symbol], quote.symbol == symbol,
                  quote.price.isFinite, quote.price > 0,
                  now.timeIntervalSince(quote.observedAt) >= -60,
                  now.timeIntervalSince(quote.observedAt) <= 7 * 86400,
                  (quantity * cost).isFinite, (quantity * quote.price).isFinite else {
                throw RobinhoodAccountError.incomplete
            }
            let kind = (row["asset_type"] as? String ?? "equity").lowercased()
            guard ["equity", "stock", "etf", "adr"].contains(kind) else { throw RobinhoodAccountError.unsupported }
            return LocalPositionRecord(ticker: symbol.replacingOccurrences(of: ".", with: "-"),
                name: row["name"] as? String ?? symbol, shares: quantity, averageCost: cost,
                currency: "USD", quotePrice: quote.price, quoteCurrency: "USD", source: "Robinhood",
                openedDate: nil, accountID: account.id, accountName: account.displayName,
                accountCurrency: account.currency, fxPnlStatus: "unavailable", quoteObservedAt: quote.observedAt)
        }
        return Self(account: account, positions: positions, fetchedAt: now, connectionGeneration: generation)
    }

    func validate(context: AccountConnectorContext, existing: [PortfolioAccount], now: Date = Date()) throws {
        guard (0..<900).contains(now.timeIntervalSince(fetchedAt)) else { throw RobinhoodAccountError.expired }
        if let current = context.account {
            guard current.source == "Robinhood", current.accountID == account.id else { throw RobinhoodAccountError.wrongAccount }
        } else if existing.contains(where: { $0.source == "Robinhood" && $0.accountID == account.id }) {
            throw RobinhoodAccountError.duplicate
        }
    }

    func portfolioAccount(name: String) -> PortfolioAccount {
        PortfolioAccount(id: "Robinhood|\(account.id)", accountID: account.id, source: "Robinhood", name: name,
            baseCurrency: account.currency, positionCount: positions.count, transactionCount: 0,
            manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 0)
    }
}

extension RobinhoodMCPClient {
    func accounts() async throws -> [RobinhoodAccount] {
        try RobinhoodAccount.decode(try await read("get_accounts"))
    }

    func snapshot(account: RobinhoodAccount) async throws -> RobinhoodAccountSnapshot {
        let epoch = connectionGeneration()
        // Recheck access to the selected account after a credential refresh/change.
        guard try await accounts().contains(where: { $0.id == account.id && $0.currency == account.currency }) else {
            throw RobinhoodAccountError.wrongAccount
        }
        let payload = try await read("get_equity_positions", arguments: ["account_number": account.id])
        let symbols = try RobinhoodAccountSnapshot.symbols(payload, account: account)
        let prices = await quotes(symbols: symbols, maxAge: 7 * 86400)
        guard epoch == connectionGeneration(), isConnected() else { throw RobinhoodAccountError.disconnected }
        return try RobinhoodAccountSnapshot.decode(payload, account: account, quotes: prices, generation: epoch)
    }
}
