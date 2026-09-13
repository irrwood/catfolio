import Foundation
import CryptoKit

enum ManagementDeliveryError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// This feature owns an isolated, protected, non-backed-up directory. Neither
/// the portfolio cloud document nor the general remote AI client sees it.
actor ManagementDeliveryFiles {
    static let shared = ManagementDeliveryFiles()
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Catfolio/ManagementDelivery", isDirectory: true)
    }

    private func url(ticker: String, quarters: Int, language: String) -> URL {
        let key = "v1|\(ticker.uppercased())|\(quarters)|\(language)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }

    func load(ticker: String, quarters: Int, language: String) -> ManagementDeliveryArchive? {
        guard let data = try? Data(contentsOf: url(ticker: ticker, quarters: quarters, language: language)),
              let archive = try? JSONDecoder().decode(ManagementDeliveryArchive.self, from: data),
              archive.schemaVersion == 1, archive.ticker == ticker.uppercased(), archive.requestedQuarters == quarters else { return nil }
        return archive
    }

    func save(_ archive: ManagementDeliveryArchive, language: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var root = directory
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        try root.setResourceValues(excluded)
        var destination = url(ticker: archive.ticker, quarters: archive.requestedQuarters, language: language)
        try JSONEncoder().encode(archive).write(to: destination, options: [.atomic, .completeFileProtection])
        try destination.setResourceValues(excluded)
    }

    func remove(ticker: String, quarters: Int, language: String) throws {
        let file = url(ticker: ticker, quarters: quarters, language: language)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}

struct ManagementDeliveryClient {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let fetch: Fetch

    init(fetch: @escaping Fetch = { request in
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        return (data, http)
    }) { self.fetch = fetch }

    struct TranscriptDate: Decodable, Sendable {
        let quarter: Int
        let fiscalYear: Int
        let date: String

        enum CodingKeys: String, CodingKey { case quarter, fiscalYear, year, date }
        init(quarter: Int, fiscalYear: Int, date: String) { self.quarter = quarter; self.fiscalYear = fiscalYear; self.date = date }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func integer(_ key: CodingKeys) throws -> Int {
                if let number = try? c.decode(Int.self, forKey: key) { return number }
                let string = try c.decode(String.self, forKey: key)
                guard let value = Int(string.replacingOccurrences(of: "Q", with: "")) else { throw LocalServiceError.invalidResponse }
                return value
            }
            quarter = try integer(.quarter)
            fiscalYear = try c.contains(.fiscalYear) ? integer(.fiscalYear) : integer(.year)
            date = try c.decode(String.self, forKey: .date)
        }
    }

    struct Transcript: Decodable {
        let symbol: String
        let quarter: Int
        let year: Int
        let date: String
        let content: String
    }

    static func selectedDates(_ dates: [TranscriptDate], quarters: Int, now: Date) -> [TranscriptDate] {
        guard [4, 6, 8].contains(quarters) else { return [] }
        var seen = Set<String>()
        return Array(dates.filter {
            (1...4).contains($0.quarter) && (1990...2100).contains($0.fiscalYear)
                && ManagementDeliveryRules.isoDate($0.date).map { $0 <= ManagementDeliveryRules.today(now) } == true
        }.sorted { $0.date > $1.date }.filter { seen.insert("\($0.fiscalYear)-\($0.quarter)").inserted }.prefix(quarters))
    }

    static func sourceURL(path: String, parameters: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "https://financialmodelingprep.com/stable/\(path)")!
        components.queryItems = parameters.filter { $0.name != "apikey" }
        return components.url!
    }

    private func get(_ path: String, parameters: [URLQueryItem], key: String) async throws -> Data {
        var parts = URLComponents(url: Self.sourceURL(path: path, parameters: parameters), resolvingAgainstBaseURL: false)!
        parts.queryItems = parameters + [URLQueryItem(name: "apikey", value: key)]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 40
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await FMPRequestLimiter.shared.waitForTurn()
        let (data, response): (Data, HTTPURLResponse)
        do { (data, response) = try await fetch(request) }
        catch is CancellationError { throw CancellationError() }
        catch { // Never reflect a credential-bearing request URL or response body into UI/cache.
            try Task.checkCancellation()
            throw ManagementDeliveryError.message(L10n.text("资料下载失败，请检查网络后重试。"))
        }
        if response.statusCode == 429 {
            await FMPRequestLimiter.shared.backOff(retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
            throw ManagementDeliveryError.message(L10n.text("资料服务限流，请稍后重试。"))
        }
        if [401, 402, 403].contains(response.statusCode) {
            throw ManagementDeliveryError.message(L10n.text("请检查 FMP 密钥及电话会文字稿、财报接口权限。"))
        }
        guard (200..<300).contains(response.statusCode), data.count <= 15_000_000 else {
            throw ManagementDeliveryError.message(L10n.text("资料服务返回异常，未更新本地结果。"))
        }
        return data
    }

    func download(ticker: String, quarters: Int, key: String, now: Date = .now,
                  progress: @escaping @Sendable (String) async -> Void) async throws -> ManagementDeliveryArchive {
        guard [4, 6, 8].contains(quarters) else { throw LocalServiceError.invalidResponse }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FMPFailure.missingKey }
        let symbol = ticker.uppercased()
        let params = [URLQueryItem(name: "symbol", value: symbol)]
        await progress(L10n.text("正在查询已有电话会文字稿…"))
        let datesData = try await get("earning-call-transcript-dates", parameters: params, key: key)
        let dates = Self.selectedDates(try JSONDecoder().decode([TranscriptDate].self, from: datesData), quarters: quarters, now: now)
        guard dates.count >= 4 else {
            throw ManagementDeliveryError.message(L10n.text("可用电话会文字稿不足 4 个季度，暂无法生成兑现记录。"))
        }
        // Reject quarter gaps: four scattered old transcripts are not the latest four quarters.
        let ordinals = dates.map { $0.fiscalYear * 4 + $0.quarter }.sorted()
        guard zip(ordinals, ordinals.dropFirst()).allSatisfy({ $1 - $0 == 1 }) else {
            throw ManagementDeliveryError.message(L10n.text("最近季度的文字稿存在缺口，暂无法生成完整记录。"))
        }
        var documents: [ManagementDocument] = []
        for (index, date) in dates.enumerated() {
            try Task.checkCancellation()
            await progress(L10n.text("下载文字稿 \(index + 1) / \(dates.count)"))
            let query = params + [URLQueryItem(name: "year", value: String(date.fiscalYear)), URLQueryItem(name: "quarter", value: String(date.quarter))]
            let data = try await get("earning-call-transcript", parameters: query, key: key)
            let rows = try JSONDecoder().decode([Transcript].self, from: data)
            guard let row = rows.first(where: { $0.symbol.uppercased() == symbol && $0.year == date.fiscalYear && $0.quarter == date.quarter }),
                  let published = ManagementDeliveryRules.isoDate(row.date), published <= ManagementDeliveryRules.today(now),
                  row.content.trimmingCharacters(in: .whitespacesAndNewlines).count >= 500 else {
                throw ManagementDeliveryError.message(L10n.text("文字稿正文缺失或季度不匹配，未更新本地结果。"))
            }
            documents.append(.init(id: "call-\(row.year)-Q\(row.quarter)", kind: .transcript,
                fiscalYear: row.year, period: "Q\(row.quarter)", published: published,
                title: "\(symbol) FY\(row.year) Q\(row.quarter) · FMP",
                url: Self.sourceURL(path: "earning-call-transcript", parameters: query), text: row.content, facts: []))
        }
        await progress(L10n.text("正在下载对应财报…"))
        for path in ["income-statement", "cash-flow-statement"] {
            for period in ["quarter", "annual"] {
                try Task.checkCancellation()
                let query = params + [URLQueryItem(name: "period", value: period), URLQueryItem(name: "limit", value: period == "quarter" ? String(quarters) : "3")]
                let data = try await get(path, parameters: query, key: key)
                documents += try Self.financialDocuments(data, symbol: symbol, path: path,
                    sourceURL: Self.sourceURL(path: path, parameters: query), now: now)
            }
        }
        // Annual reports support full-year guidance; restrict their dates to the
        // selected transcript window rather than analysing unrelated history.
        let earliest = documents.filter { $0.kind == .transcript }.map(\.published).min()!
        documents = documents.filter { $0.kind == .transcript || $0.published >= earliest }
        var documentIDs = Set<String>()
        documents = documents.filter { documentIDs.insert($0.id).inserted }
        guard documents.contains(where: { $0.kind == .financials && !$0.facts.isEmpty }) else {
            throw ManagementDeliveryError.message(L10n.text("未取得可核对的财报，请检查资料权限后重试。"))
        }
        return .init(ticker: symbol, downloadedAt: now, requestedQuarters: quarters, documents: documents, report: nil)
    }

    static func financialDocuments(_ data: Data, symbol: String, path: String, sourceURL: URL, now: Date) throws -> [ManagementDocument] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw LocalServiceError.invalidResponse }
        let metrics = path == "income-statement"
            ? ["revenue", "grossProfit", "operatingIncome", "netIncome", "eps", "epsDiluted"]
            : ["operatingCashFlow", "freeCashFlow", "capitalExpenditure"]
        return rows.compactMap { row in
            guard (row["symbol"] as? String)?.uppercased() == symbol,
                  let end = (row["date"] as? String).flatMap(ManagementDeliveryRules.isoDate),
                  let published = ((row["filingDate"] ?? row["fillingDate"] ?? row["acceptedDate"]) as? String).flatMap(ManagementDeliveryRules.isoDate),
                  published <= ManagementDeliveryRules.today(now),
                  let period = row["period"] as? String, ["Q1", "Q2", "Q3", "Q4", "FY"].contains(period),
                  let year = (row["fiscalYear"] as? Int) ?? Int(row["fiscalYear"] as? String ?? ""),
                  let currency = row["reportedCurrency"] as? String, !currency.isEmpty else { return nil }
            let raw = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            let revision = SHA256.hash(data: raw ?? Data()).prefix(8).map { String(format: "%02x", $0) }.joined()
            let id = "\(path)-\(year)-\(period)-\(published)-\(revision)"
            let facts: [ManagementFact] = metrics.compactMap { metric in
                guard let value = row[metric] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
                let quote = "\(metric): \(value.stringValue) \(currency); GAAP company; FY\(year) \(period); period ending \(end)."
                return .init(id: "\(id)-\(metric)", metric: metric, fiscalYear: year, period: period, periodEnd: end,
                    currency: currency, value: value.doubleValue, sourceID: id, quote: quote)
            }
            let originalURL = ["finalLink", "link"].compactMap { row[$0] as? String }.compactMap(URL.init(string:))
                .first { $0.scheme == "https" && $0.user == nil && $0.password == nil && $0.query == nil }
            return .init(id: id, kind: .financials, fiscalYear: year, period: period, published: published,
                title: "\(symbol) FY\(year) \(period) · \(path)", url: originalURL ?? sourceURL,
                text: facts.map(\.quote).joined(separator: "\n"), facts: facts,
                rawFinancialJSON: raw)
        }
    }
}
