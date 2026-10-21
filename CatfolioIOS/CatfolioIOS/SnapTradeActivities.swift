import Foundation

/// Keep holdings and historical fills on the same exchange-qualified ticker.
enum SnapTradeSecurity {
    static func ticker(raw: String, exchange: String) throws -> String {
        guard !raw.isEmpty, raw == raw.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw SnapTradeError.unsupported(raw)
        }
        switch exchange.uppercased() {
        case "XNAS", "XNYS", "ARCX", "BATS", "XASE", "IEXG", "NAS", "NYSE", "NASDAQ", "NYSEARCA":
            return raw.replacingOccurrences(of: ".", with: "-")
        case "XTSE": return raw.replacingOccurrences(of: ".", with: "-") + ".TO"
        case "XTSX": return raw + ".V"
        case "XLON": return raw + ".L"
        case "XHKG":
            guard let code = Int(raw), code > 0 else { throw SnapTradeError.unsupported(raw) }
            return String(format: "%04d.HK", code)
        default: throw SnapTradeError.unsupported(raw)
        }
    }
}

struct SnapTradeActivityHistory {
    var transactions: [LocalTransactionRecord] = []
    var skipped = 0
}

struct SnapTradeActivityPage: Decodable {
    let data: [SnapTradeActivity]
    let pagination: Pagination

    struct Pagination: Decodable {
        let offset: Int
        let limit: Int
        let total: Int
    }
}

struct SnapTradeActivity: Decodable {
    let id: String
    let type: String
    private let symbol: Symbol?
    private let hasOption: Bool
    private let hasSecurityCurrency: Bool
    private let units: SnapTradeDecimal?
    private let price: SnapTradeDecimal?
    private let currency: Currency?
    private let tradeDate: String?

    private struct Symbol: Decodable {
        let raw_symbol: String?
        let exchange: Exchange?
        let type: SecurityType?
        struct Exchange: Decodable { let mic_code: String? }
        struct SecurityType: Decodable { let code: String? }
    }
    private struct Currency: Decodable { let code: String? }

    private enum CodingKeys: String, CodingKey {
        case id, type, symbol, option_symbol, currency_universal_symbol, units, price, currency, trade_date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type).uppercased()
        hasOption = try container.contains(.option_symbol) && !container.decodeNil(forKey: .option_symbol)
        hasSecurityCurrency = try container.contains(.currency_universal_symbol)
            && !container.decodeNil(forKey: .currency_universal_symbol)
        // Non-equity activities have different payloads. Do not decode their
        // amounts or interpret an option's underlying as an equity fill.
        if ["BUY", "SELL"].contains(type), !hasOption, !hasSecurityCurrency {
            symbol = try container.decodeIfPresent(Symbol.self, forKey: .symbol)
            units = try container.decodeIfPresent(SnapTradeDecimal.self, forKey: .units)
            price = try container.decodeIfPresent(SnapTradeDecimal.self, forKey: .price)
            currency = try container.decodeIfPresent(Currency.self, forKey: .currency)
            tradeDate = try container.decodeIfPresent(String.self, forKey: .trade_date)
        } else {
            symbol = nil; units = nil; price = nil; currency = nil; tradeDate = nil
        }
    }

    var isTrade: Bool { ["BUY", "SELL"].contains(type) }

    func transaction(account: SnapTradeAccount) throws -> LocalTransactionRecord? {
        guard isTrade, !hasOption, !hasSecurityCurrency,
              let symbol, let code = symbol.type?.code?.lowercased(),
              ["cs", "ad", "et", "cef", "oef"].contains(code),
              let raw = symbol.raw_symbol, let exchange = symbol.exchange?.mic_code else { return nil }
        let ticker: String
        do { ticker = try SnapTradeSecurity.ticker(raw: raw, exchange: exchange) }
        catch { return nil }
        guard let units = units?.value, units != 0, let price = price?.value, price > 0,
              (abs(units) * price).isFinite,
              let code = currency?.code, !code.isEmpty,
              let tradeDate else { throw SnapTradeError.malformed }
        let currency = code == "GBp" ? "GBX" : code.uppercased()
        _ = try LocalPortfolioEngine.usd(1, currency: currency)
        let day = String(tradeDate.prefix(10))
        guard day.count == 10, let date = DayDateCodec.date(from: day),
              DayDateCodec.string(from: date) == day else { throw SnapTradeError.malformed }
        var executedAt: String?
        if tradeDate.count > 10 {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard formatter.date(from: tradeDate) != nil || ISO8601DateFormatter().date(from: tradeDate) != nil else {
                throw SnapTradeError.malformed
            }
            // Midnight is how date-only broker data is encoded. Do not
            // invent an intraday fill from that placeholder timestamp.
            if String(tradeDate.dropFirst(11).prefix(8)) != "00:00:00" { executedAt = tradeDate }
        }
        return LocalTransactionRecord(date: day, action: type, ticker: ticker, quantity: abs(units),
            price: price, currency: currency, source: "SnapTrade", accountID: account.id,
            accountName: account.displayName, tradeID: id, executedAt: executedAt)
    }
}
