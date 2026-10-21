import Foundation

/// The Tencent upstream also used by AKShare's stock_zh_a_hist_tx.
/// Keep JSON responses: the minute endpoint includes a Unicode quote snapshot,
/// so no executable JavaScript or GBK quote-response evaluation is needed.
struct TencentMarketDataClient {
    typealias Fetch = @Sendable (String, String, [String: String]) async throws -> Data
    let fetch: Fetch

    private func minuteData(_ security: ChinaSecurity) async throws -> Data {
        try await fetch("web.ifzq.gtimg.cn", "/appstock/app/minute/query", ["code": security.tencentSymbol])
    }

    func quote(_ security: ChinaSecurity) async throws -> ChinaMarketQuote {
        try Self.parseQuote(await minuteData(security), security: security)
    }

    func intraday(_ security: ChinaSecurity) async throws -> [MarketIntradayBar] {
        try Self.parseIntraday(await minuteData(security), security: security)
    }

    func daily(_ security: ChinaSecurity, from: String, to: String, adjusted: Bool) async throws -> [MarketDailyBar] {
        guard ChinaSecurity.date(from) != nil, let end = ChinaSecurity.date(to), from <= to else {
            throw ChinaMarketError.invalidData
        }
        // Starting just after the requested end also includes today's bar.
        // Page backwards rather than silently truncating MAX to 640 days.
        var cursor = end.addingTimeInterval(86400)
        var values: [String: MarketDailyBar] = [:]
        for _ in 0..<100 {
            try Task.checkCancellation()
            // Use AKShare's current history endpoint. The legacy fqkline
            // gateway can return an HTML challenge instead of market data.
            let data = try await fetch("proxy.finance.qq.com", "/ifzqgtimg/appstock/app/newfqkline/get", [
                "param": "\(security.tencentSymbol),day,,\(ChinaSecurity.day(cursor)),640,\(adjusted ? "qfq" : "")",
            ])
            let page = try Self.parseDailyPage(data, security: security, adjusted: adjusted)
            for bar in page.bars where bar.date >= from && bar.date <= to { values[bar.date] = bar }
            guard let first = page.firstDate else { break }
            if first <= from || page.count < 640 { break }
            guard let earliest = ChinaSecurity.date(first), earliest < cursor else { throw ChinaMarketError.invalidData }
            cursor = earliest.addingTimeInterval(-86400)
        }
        guard !values.isEmpty else { throw ChinaMarketError.noData }
        return values.values.sorted { $0.date < $1.date }
    }

    static func payload(_ data: Data, security: ChinaSecurity) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["code"] as? Int == 0,
              let all = root["data"] as? [String: Any],
              let listing = all[security.tencentSymbol] as? [String: Any] else {
            throw ChinaMarketError.invalidData
        }
        // Both the envelope's venue and the snapshot's code must agree.
        guard let qt = listing["qt"] as? [String: Any],
              let quote = qt[security.tencentSymbol] as? [String],
              quote.count > 4, quote[2] == security.code else { throw ChinaMarketError.invalidData }
        return listing
    }

    static func parseQuote(_ data: Data, security: ChinaSecurity, now: Date = .now) throws -> ChinaMarketQuote {
        let listing = try payload(data, security: security)
        guard let qt = listing["qt"] as? [String: Any], let fields = qt[security.tencentSymbol] as? [String],
              fields.count > 30, let price = Double(fields[3]), let previous = Double(fields[4]),
              price.isFinite, price > 0, previous.isFinite, previous > 0,
              let timestamp = ChinaSecurity.date(fields[30], format: "yyyyMMddHHmmss"),
              timestamp <= now.addingTimeInterval(60) else { throw ChinaMarketError.invalidData }
        return .init(price: price, previousClose: previous, observedAt: timestamp)
    }

    static func parseIntraday(_ data: Data, security: ChinaSecurity, now: Date = .now) throws -> [MarketIntradayBar] {
        let listing = try payload(data, security: security)
        guard let minute = listing["data"] as? [String: Any],
              let day = minute["date"] as? String, ChinaSecurity.date(day, format: "yyyyMMdd") != nil,
              let rows = minute["data"] as? [String] else { throw ChinaMarketError.noData }
        var values: [Date: MarketIntradayBar] = [:]
        for row in rows {
            let cells = row.split(separator: " ")
            guard cells.count >= 2,
                  let timestamp = ChinaSecurity.date(day + String(cells[0]), format: "yyyyMMddHHmm"),
                  timestamp <= now.addingTimeInterval(60),
                  let price = Double(cells[1]), price.isFinite, price > 0 else { throw ChinaMarketError.invalidData }
            // Tencent also includes post-close fixed-price prints until 15:30.
            // The existing regular-session chart ends at the 15:00 close.
            let time = String(cells[0])
            guard ("0930"..."1130").contains(time) || ("1300"..."1500").contains(time) else { continue }
            values[timestamp] = .init(timestamp: timestamp, close: price)
        }
        guard !values.isEmpty else { throw ChinaMarketError.noData }
        return values.values.sorted { $0.timestamp < $1.timestamp }
    }

    struct DailyPage {
        let bars: [MarketDailyBar]
        let firstDate: String?
        let count: Int
    }

    static func parseDailyPage(_ data: Data, security: ChinaSecurity, adjusted: Bool) throws -> DailyPage {
        let listing = try payload(data, security: security)
        // Tencent returns `day` even for qfq when no adjustments exist.
        guard let rows = (listing[adjusted ? "qfqday" : "day"] ?? (adjusted ? listing["day"] : nil)) as? [[Any]] else {
            throw ChinaMarketError.invalidData
        }
        var bars: [MarketDailyBar] = []
        var dates = Set<String>()
        for row in rows {
            guard row.count >= 6, let date = row[0] as? String, ChinaSecurity.date(date) != nil,
                  dates.insert(date).inserted,
                  let close = AKShareMarketDataClient.number(row[2]),
                  let high = AKShareMarketDataClient.number(row[3]),
                  let low = AKShareMarketDataClient.number(row[4]),
                  let volume = AKShareMarketDataClient.number(row[5]),
                  high >= low, close >= low, close <= high, volume >= 0 else { throw ChinaMarketError.invalidData }
            // Cash-dividend forward adjustment can make very old prices
            // nonpositive. Those aren't valid inputs to the app's price/
            // return model; never clamp them or silently substitute raw bars.
            if adjusted && low <= 0 { continue }
            guard low > 0 else { throw ChinaMarketError.invalidData }
            // Tencent STAR-board volume is shares; main-board/ChiNext/ETF is
            // lots. In particular, sz000001 is a stock, not a Shenzhen index.
            let shares = volume * (security.code.hasPrefix("688") && security.shanghai ? 1 : 100)
            guard shares.isFinite else { throw ChinaMarketError.invalidData }
            bars.append(.init(date: date, close: close, high: high, low: low, volume: shares))
        }
        return DailyPage(bars: bars.sorted { $0.date < $1.date }, firstDate: dates.min(), count: rows.count)
    }
}

extension ChinaSecurity {
    var tencentSymbol: String { (shanghai ? "sh" : "sz") + code }
}
