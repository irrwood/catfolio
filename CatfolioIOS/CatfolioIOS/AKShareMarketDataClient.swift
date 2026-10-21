import Foundation

/// Native access to AKShare's public upstreams; Python is not embedded.
/// Tencent serves price history and minutes; Eastmoney remains a fallback
/// and supplies the search directory.
struct AKShareMarketDataClient {
    var session: URLSession = LocalRequestSessions.ephemeral
    typealias Transport = @Sendable (URLRequest, URLSession) async throws -> (Data, URLResponse)
    var transport: Transport = { request, session in
        try await MarketRequestCoalescer.shared.data(for: request, session: session)
    }

    private var tencent: TencentMarketDataClient {
        TencentMarketDataClient { host, path, query in
            try await data(host: host, path: path, query: query)
        }
    }

    func data(host: String, path: String, query: [String: String]) async throws -> Data {
        var url = URLComponents()
        url.scheme = "https"; url.host = host; url.path = path
        url.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        guard let address = url.url else { throw ChinaMarketError.invalidData }
        var request = URLRequest(url: address, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue(host.hasSuffix("eastmoney.com") ? "https://quote.eastmoney.com/" : "https://gu.qq.com/",
                         forHTTPHeaderField: "Referer")
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let (data, response) = try await transport(request, session)
            guard let http = response as? HTTPURLResponse else { throw ChinaMarketError.invalidData }
            if attempt == 0, [502, 503, 504].contains(http.statusCode) {
                try await Task.sleep(for: .milliseconds(500))
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw ChinaMarketError.http(http.statusCode) }
            guard data.count <= 8 * 1024 * 1024 else { throw ChinaMarketError.invalidData }
            // Some public gateways return their access-control page as 200.
            // Surface it rather than treating it as a corrupt quote and
            // retrying through another upstream.
            if let text = String(data: data.prefix(1024), encoding: .utf8),
               text.lowercased().contains("<html"), text.contains("waf.tencent.com") {
                throw ChinaMarketError.http(403)
            }
            return data
        }
        throw ChinaMarketError.noData
    }

    func quote(_ security: ChinaSecurity) async throws -> ChinaMarketQuote {
        try await withPublicFallback {
            try await tencent.quote(security)
        } fallback: {
            try await eastmoneyQuote(security)
        }
    }

    private func eastmoneyQuote(_ security: ChinaSecurity) async throws -> ChinaMarketQuote {
        do {
            let data = try await data(host: "push2.eastmoney.com", path: "/api/qt/stock/get", query: [
                "secid": security.eastmoneyID, "fltt": "2", "invt": "2",
                "fields": "f43,f57,f58,f59,f60,f86",
            ])
            return try Self.parseQuote(data, security: security)
        } catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw error }
            if case ChinaMarketError.http(let code) = error, [401, 403, 429].contains(code) { throw error }
            // The quote gateway and historical gateway sometimes fail
            // independently. A minute observation remains a dated quote,
            // never relabelled with this request's wall-clock time.
            return try Self.parseMinuteQuote(await trendsData(security, days: 1), security: security)
        }
    }

    func daily(_ security: ChinaSecurity, from: String, to: String, adjusted: Bool) async throws -> [MarketDailyBar] {
        try await withPublicFallback {
            try await tencent.daily(security, from: from, to: to, adjusted: adjusted)
        } fallback: {
            try await eastmoneyDaily(security, from: from, to: to, adjusted: adjusted)
        }
    }

    private func eastmoneyDaily(_ security: ChinaSecurity, from: String, to: String,
                               adjusted: Bool) async throws -> [MarketDailyBar] {
        let data = try await data(host: "push2his.eastmoney.com", path: "/api/qt/stock/kline/get", query: [
            "secid": security.eastmoneyID, "klt": "101", "fqt": adjusted ? "1" : "0",
            "beg": from.replacingOccurrences(of: "-", with: ""),
            "end": to.replacingOccurrences(of: "-", with: ""),
            "fields1": "f1,f2,f3,f4,f5,f6", "fields2": "f51,f52,f53,f54,f55,f56",
        ])
        return try Self.parseDaily(data, security: security).filter { $0.date >= from && $0.date <= to }
    }

    func intraday(_ security: ChinaSecurity) async throws -> [MarketIntradayBar] {
        try await withPublicFallback {
            try await tencent.intraday(security)
        } fallback: {
            try Self.parseIntraday(await trendsData(security, days: 5), security: security)
        }
    }

    private func withPublicFallback<T>(_ primary: () async throws -> T,
                                      fallback: () async throws -> T) async throws -> T {
        do { return try await primary() }
        catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            if case ChinaMarketError.http(let code) = error, [401, 403, 429].contains(code) { throw error }
            return try await fallback()
        }
    }
    private func trendsData(_ security: ChinaSecurity, days: Int) async throws -> Data {
        try await data(host: "push2his.eastmoney.com", path: "/api/qt/stock/trends2/get", query: [
            "secid": security.eastmoneyID, "ndays": String(days), "iscr": "0",
            "fields1": "f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13",
            "fields2": "f51,f52,f53,f54,f55,f56,f57,f58",
        ])
    }

    func search(_ query: String) async throws -> [MarketSecurityResult] {
        let data = try await data(host: "searchapi.eastmoney.com", path: "/api/suggest/get",
                                  query: ["input": query, "type": "14", "count": "20"])
        return try Self.parseSearch(data)
    }

    static func payload(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["rc"] as? Int) == 0, let payload = object["data"] as? [String: Any] else {
            throw ChinaMarketError.invalidData
        }
        return payload
    }
    static func number(_ value: Any?) -> Double? {
        let value = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
    static func parseQuote(_ data: Data, security: ChinaSecurity, now: Date = .now) throws -> ChinaMarketQuote {
        let row = try payload(data)
        guard row["f57"] as? String == security.code,
              let price = number(row["f43"]), price > 0,
              let previous = number(row["f60"]), previous > 0,
              let timestamp = number(row["f86"]), timestamp > 0,
              timestamp <= now.timeIntervalSince1970 + 60 else { throw ChinaMarketError.invalidData }
        return .init(price: price, previousClose: previous, observedAt: Date(timeIntervalSince1970: timestamp))
    }
    static func verify(_ row: [String: Any], security: ChinaSecurity) throws {
        guard row["code"] as? String == security.code,
              number(row["market"]) == (security.shanghai ? 1 : 0) else { throw ChinaMarketError.invalidData }
    }
    static func parseDaily(_ data: Data, security: ChinaSecurity) throws -> [MarketDailyBar] {
        let row = try payload(data)
        try verify(row, security: security)
        guard let lines = row["klines"] as? [String] else { throw ChinaMarketError.noData }
        var bars: [String: MarketDailyBar] = [:]
        for line in lines {
            let cells = line.components(separatedBy: ",")
            guard cells.count >= 6, ChinaSecurity.date(cells[0]) != nil,
                  let close = Double(cells[2]), let high = Double(cells[3]),
                  let low = Double(cells[4]), let lots = Double(cells[5]),
                  [close, high, low, lots].allSatisfy(\.isFinite),
                  low > 0, high >= low, close >= low, close <= high, lots >= 0,
                  bars[cells[0]] == nil else { throw ChinaMarketError.invalidData }
            bars[cells[0]] = .init(date: cells[0], close: close, high: high, low: low, volume: lots * 100)
        }
        guard !bars.isEmpty else { throw ChinaMarketError.noData }
        return bars.values.sorted { $0.date < $1.date }
    }
    static func parseIntraday(_ data: Data, security: ChinaSecurity, now: Date = .now) throws -> [MarketIntradayBar] {
        let row = try payload(data)
        try verify(row, security: security)
        guard let lines = row["trends"] as? [String] else { throw ChinaMarketError.noData }
        var bars: [Date: MarketIntradayBar] = [:]
        for line in lines {
            let cells = line.components(separatedBy: ",")
            guard cells.count >= 3, let date = ChinaSecurity.date(cells[0], format: "yyyy-MM-dd HH:mm"),
                  date <= now.addingTimeInterval(60),
                  let close = Double(cells[2]), close.isFinite, close > 0 else { throw ChinaMarketError.invalidData }
            bars[date] = .init(timestamp: date, close: close)
        }
        guard !bars.isEmpty else { throw ChinaMarketError.noData }
        return bars.values.sorted { $0.timestamp < $1.timestamp }
    }
    static func parseMinuteQuote(_ data: Data, security: ChinaSecurity, now: Date = .now) throws -> ChinaMarketQuote {
        let bars = try parseIntraday(data, security: security, now: now)
        guard let last = bars.last, let previous = number(try payload(data)["preClose"]), previous > 0 else {
            throw ChinaMarketError.noData
        }
        return .init(price: last.close, previousClose: previous, observedAt: last.timestamp)
    }
    static func parseSearch(_ data: Data) throws -> [MarketSecurityResult] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = root["QuotationCodeTable"] as? [String: Any],
              let rows = table["Data"] as? [[String: Any]] else { throw ChinaMarketError.invalidData }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let code = row["Code"] as? String,
                  let market = number(row["MktNum"]), [0, 1].contains(market),
                  let security = ChinaSecurity(code + (market == 1 ? ".SS" : ".SZ")),
                  let name = row["Name"] as? String, !name.isEmpty,
                  seen.insert(security.ticker).inserted else { return nil }
            return MarketSecurityResult(ticker: security.ticker, name: name, market: "CN",
                exchange: security.shanghai ? "SSE" : "SZSE", currency: "CNY", sector: nil, isFund: security.isFund)
        }
    }
}
