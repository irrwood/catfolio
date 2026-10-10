import SwiftUI
import Charts
import CryptoKit

enum YahooOIError: LocalizedError {
    case incomplete
    var errorDescription: String? { L10n.text("Yahoo 期权链缺少有效 OI 或合约信息，未更新持仓墙。") }
}

struct YahooOIResponse: Decodable {
    struct Envelope: Decodable {
        struct ProviderError: Decodable { let code: String? }
        let result: [Chain]?
        let error: ProviderError?
    }
    struct Chain: Decodable {
        let underlyingSymbol: String
        let expirationDates: [Int]
        let options: [Expiry]
    }
    struct Expiry: Decodable {
        let expirationDate: Int
        let calls: [Contract]
        let puts: [Contract]
    }
    struct Contract: Decodable {
        let contractSymbol: String
        let strike: Double
        let expiration: Int
        let openInterest: Double?
        let contractSize: String?
        let currency: String?
    }
    let optionChain: Envelope

    static func expiryDay(_ timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
    }

    func validatedChain(symbol: String) throws -> Chain {
        guard optionChain.error == nil, let results = optionChain.result, results.count == 1,
              let chain = results.first, chain.underlyingSymbol == symbol,
              Set(chain.expirationDates).count == chain.expirationDates.count,
              chain.expirationDates.allSatisfy({ $0 > 0 && $0 < 10_000_000_000 }) else {
            throw YahooOIError.incomplete
        }
        return chain
    }

    // Missing OI is not zero; reject the new snapshot instead of publishing a partial wall.
    static func normalize(_ expiry: Expiry, symbol: String) throws -> (contracts: [OIContract], excluded: Int) {
        var result: [OIContract] = []
        var seen = Set<String>()
        var excluded = 0
        let date = expiryDay(expiry.expirationDate)
        let code = String(date.replacingOccurrences(of: "-", with: "").suffix(6))
        guard !expiry.calls.isEmpty || !expiry.puts.isEmpty else { throw YahooOIError.incomplete }
        for (side, items) in [("call", expiry.calls), ("put", expiry.puts)] {
            for item in items {
                guard seen.insert(item.contractSymbol).inserted else { throw YahooOIError.incomplete }
                let prefix = symbol + code + (side == "call" ? "C" : "P")
                // Corporate-action roots/deliverables need their own reference mapping.
                guard item.contractSize == "REGULAR",
                      String(item.contractSymbol.dropLast(15)) == symbol else {
                    excluded += 1; continue
                }
                let strikeCode = String(item.contractSymbol.suffix(8))
                guard item.contractSymbol == prefix + strikeCode,
                      strikeCode.count == 8, strikeCode.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let encodedStrike = Double(strikeCode),
                      item.expiration == expiry.expirationDate, item.currency == "USD",
                      item.strike.isFinite, item.strike > 0,
                      abs(item.strike * 1000 - encodedStrike) < 0.001,
                      let oi = item.openInterest, oi.isFinite, oi >= 0,
                      oi <= 1_000_000_000_000, oi.rounded() == oi else {
                    throw YahooOIError.incomplete
                }
                result.append(OIContract(details: .init(ticker: item.contractSymbol, contract_type: side,
                    expiration_date: date, strike_price: item.strike, shares_per_contract: nil), open_interest: oi))
            }
        }
        return (result, excluded)
    }
}

actor OptionsOIClient {
    static let shared = OptionsOIClient()
    // Isolated, in-memory anonymous Yahoo cookies; never read browser/account cookies.
    private let session: URLSession
    private let cacheDirectory: URL
    private var fetching = false
    private var rateLimitedUntil: Date?
    init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 35
        self.session = session ?? URLSession(configuration: configuration)
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OptionsOI", isDirectory: true)
    }
    private func file(_ symbol: String, _ days: Int) -> URL {
        let key = SHA256.hash(data: Data("\(symbol)|\(days)".utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("options-oi-yahoo-v1-\(key).json")
    }
    func cached(symbol: String, days: Int) -> OISnapshot? {
        let destination = file(symbol, days)
        // Preserve snapshots fetched by the previous version. Never refetch
        // merely because the storage location changed.
        let legacy = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(destination.lastPathComponent)
        guard let data = (try? Data(contentsOf: destination)) ?? (try? Data(contentsOf: legacy)) else { return nil }
        if !FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        return try? JSONDecoder().decode(OISnapshot.self, from: data)
    }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private func read(_ url: URL, cookieBootstrap: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        if http.statusCode == 429 {
            // Stop immediately, do not switch hosts or retry around Yahoo's limit.
            let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300
            rateLimitedUntil = Date().addingTimeInterval(max(300, min(retry, 86400)))
            throw LocalServiceError.remote(L10n.text("Yahoo 请求限流，请稍后再刷新。"))
        }
        // fc.yahoo.com may issue its anonymous cookie with a 404 response.
        guard http.statusCode == 200 || (cookieBootstrap && http.statusCode == 404) else {
            throw LocalServiceError.remote(http.statusCode == 401 || http.statusCode == 403
                ? L10n.text("Yahoo 暂不允许读取期权数据，请稍后再试。")
                : L10n.text("Yahoo 期权请求失败（\(http.statusCode)）。"))
        }
        return data
    }
    private func chain(symbol: String, expiration: Int?, crumb: String) async throws -> YahooOIResponse.Chain {
        var components = URLComponents(string: "https://query2.finance.yahoo.com/v7/finance/options/\(symbol)")!
        components.queryItems = [URLQueryItem(name: "crumb", value: crumb)]
        if let expiration { components.queryItems?.append(URLQueryItem(name: "date", value: String(expiration))) }
        let data = try await read(components.url!)
        do {
            return try JSONDecoder().decode(YahooOIResponse.self, from: data).validatedChain(symbol: symbol)
        } catch { throw YahooOIError.incomplete }
    }
    func fetch(symbol: String, days: Int) async throws -> OISnapshot {
        guard symbol.range(of: "^[A-Z][A-Z0-9.-]{0,14}$", options: .regularExpression) != nil,
              [7, 30, 90].contains(days) else { throw LocalServiceError.invalidResponse }
        guard !fetching else { throw LocalServiceError.remote(L10n.text("正在读取 Yahoo 期权链，请稍后再试。")) }
        if let until = rateLimitedUntil, until > Date() {
            throw LocalServiceError.remote(L10n.text("Yahoo 仍在限流冷却期，请稍后再刷新。"))
        }
        fetching = true
        defer { fetching = false }
        let from = Self.day(Date())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let through = Self.day(calendar.date(byAdding: .day, value: days, to: Date())!)
        _ = try await read(URL(string: "https://fc.yahoo.com")!, cookieBootstrap: true)
        let crumbData = try await read(URL(string: "https://query2.finance.yahoo.com/v1/test/getcrumb")!)
        guard let crumb = String(data: crumbData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !crumb.isEmpty, crumb.count < 100,
              !crumb.contains(where: { $0.isWhitespace || $0 == "<" || $0 == "{" }) else {
            throw LocalServiceError.remote(L10n.text("Yahoo 会话暂不可用，未更新持仓墙。"))
        }
        let inventory = try await chain(symbol: symbol, expiration: nil, crumb: crumb)
        let expirations = inventory.expirationDates.filter {
            let date = YahooOIResponse.expiryDay($0)
            return date >= from && date <= through
        }.sorted()
        guard expirations.count <= 100 else { throw YahooOIError.incomplete }
        var contracts: [OIContract] = []
        var seen = Set<String>()
        var excluded = 0
        for timestamp in expirations {
            try Task.checkCancellation()
            let response: YahooOIResponse.Chain
            if inventory.options.contains(where: { $0.expirationDate == timestamp }) {
                response = inventory
            } else {
                // Sequential, modest pacing. Never launch a burst for every expiry.
                try await Task.sleep(for: .milliseconds(350))
                response = try await chain(symbol: symbol, expiration: timestamp, crumb: crumb)
            }
            let matching = response.options.filter { $0.expirationDate == timestamp }
            guard matching.count == 1, let expiry = matching.first else { throw YahooOIError.incomplete }
            let normalized = try YahooOIResponse.normalize(expiry, symbol: symbol)
            for contract in normalized.contracts {
                guard seen.insert(contract.details.ticker).inserted else { throw YahooOIError.incomplete }
                contracts.append(contract)
            }
            excluded += normalized.excluded
        }
        guard Self.day(Date()) == from else { throw LocalServiceError.remote(L10n.text("请求跨越纽约日期，请重新刷新。")) }
        try Task.checkCancellation()
        let snapshot = OISnapshot(contracts: contracts, fetchedAt: Date(), from: from, through: through, excluded: excluded,
                                  listsOptions: !inventory.expirationDates.isEmpty)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file(symbol, days), options: [.atomic, .completeFileProtectionUnlessOpen])
        return snapshot
    }
}
