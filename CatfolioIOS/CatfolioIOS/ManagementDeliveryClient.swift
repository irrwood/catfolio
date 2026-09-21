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

/// Management delivery reads SEC's public filings only: each quarter's
/// earnings release for what management said, and the company's statements
/// for what followed. No key, no paid feed, and nothing a provider can
/// withdraw.
struct ManagementDeliveryClient {
    func download(ticker: String, quarters: Int, now: Date = .now,
                  progress: @escaping @Sendable (String) async -> Void) async throws -> ManagementDeliveryArchive {
        guard [4, 6, 8].contains(quarters) else { throw LocalServiceError.invalidResponse }
        return try await downloadFromSEC(ticker: ticker, quarters: quarters, now: now, progress: progress)
    }
}

// MARK: - SEC route

/// The archive from SEC's public filings. Each quarter's
/// earnings release — the 8-K filed under Item 2.02, exhibit 99.1 — stands in
/// for the call transcript: it carries management's own account of the
/// quarter and, usually, the outlook for the next. The reported figures come
/// from the company's statements in SEC Company Facts.
extension ManagementDeliveryClient {
    struct FiscalQuarter: Hashable, Comparable {
        let year: Int
        let quarter: Int
        var ordinal: Int { year * 4 + quarter }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.ordinal < rhs.ordinal }
        func advanced(by steps: Int) -> FiscalQuarter {
            let next = ordinal + steps
            let quarter = ((next - 1) % 4 + 4) % 4 + 1
            return FiscalQuarter(year: (next - quarter) / 4, quarter: quarter)
        }
    }

    /// Each statement period's place in the company's own fiscal calendar:
    /// a fiscal year is named for the year it ends in, and a quarter belongs
    /// to the fiscal year that ends next after it.
    static func fiscalCalendar(_ income: [IncomeStatementPeriod]) -> [String: FiscalQuarter] {
        let annualEnds = income.filter { $0.kind == .annual }.map(\.periodEnd).sorted()
        var result: [String: FiscalQuarter] = [:]
        for end in annualEnds { result[end] = FiscalQuarter(year: Int(end.prefix(4)) ?? 0, quarter: 4) }
        guard let latestAnnual = annualEnds.last, let latestDate = DayDateCodec.date(from: latestAnnual) else { return result }
        for period in income where period.kind == .quarterly {
            guard let end = DayDateCodec.date(from: period.periodEnd) else { continue }
            // The fiscal year this quarter falls in ends at the first annual
            // end after it; past the latest one, a year after that.
            let nextAnnual = annualEnds.compactMap(DayDateCodec.date(from:)).first { $0 >= end }
                ?? Calendar(identifier: .gregorian).date(byAdding: .year,
                    value: Int((end.timeIntervalSince(latestDate) / (365.25 * 86_400)).rounded(.up)), to: latestDate)
                ?? end
            let yearStart = Calendar(identifier: .gregorian).date(byAdding: .year, value: -1, to: nextAnnual) ?? end
            let quarter = min(3, max(1, Int((end.timeIntervalSince(yearStart) / (91.3 * 86_400)).rounded())))
            result[period.periodEnd] = FiscalQuarter(year: Calendar(identifier: .gregorian).component(.year, from: nextAnnual),
                                                     quarter: quarter)
        }
        return result
    }

    /// The fiscal quarter an earnings release filed on `filed` reports: the
    /// latest known period ending before it, stepped forward a quarter at a
    /// time when the release is about a period not in the statements yet
    /// (a fourth-quarter release comes weeks before the annual report).
    static func quarterReported(filed: String, calendar: [String: FiscalQuarter]) -> FiscalQuarter? {
        guard let filedDate = DayDateCodec.date(from: filed),
              let (end, quarter) = calendar.filter({ $0.key < filed }).max(by: { $0.key < $1.key }),
              let endDate = DayDateCodec.date(from: end) else { return nil }
        let days = filedDate.timeIntervalSince(endDate) / 86_400
        // Releases come three to ten weeks after the quarter closes.
        let steps = max(0, Int(((days - 20) / 91.3).rounded(.down)))
        return quarter.advanced(by: steps)
    }

    private struct Submissions: Decodable {
        struct Recent: Decodable {
            let accessionNumber: [String]
            let filingDate: [String]
            let form: [String]
            let items: [String]
            let primaryDocument: [String]
        }
        struct Filings: Decodable { let recent: Recent }
        let filings: Filings
    }

    /// A press-release exhibit as plain text. The news reader's extractor
    /// looks for an article or a filing's cover wording and finds neither in
    /// an exhibit, so this strips the markup directly.
    static func exhibitText(_ html: String) -> String? {
        var text = html
            .replacingOccurrences(of: "(?s)<(script|style|head)\\b[^>]*>.*?</\\1>", with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "(?i)<(br|/p|/div|/tr|/li|/h[1-6])\\b[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let named = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">",
                     "&mdash;": "—", "&ndash;": "–", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”", "&bull;": "•"]
        for (entity, character) in named { text = text.replacingOccurrences(of: entity, with: character) }
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let source = text as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: last, length: match.range.location - last))
                let isHex = source.substring(with: match.range(at: 1)) == "x"
                let digits = source.substring(with: match.range(at: 2))
                if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.unicodeScalars.append(scalar)
                }
                last = match.range.location + match.range.length
            }
            result += source.substring(from: last)
            text = result
        }
        let lines = text.components(separatedBy: "\n")
            .map { SecurityDebateResearch.normalized($0) }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        return joined.count >= 500 ? String(joined.prefix(60_000)) : nil
    }

    /// The path of exhibit 99.1 — or failing that the first exhibit 99 — in
    /// an EDGAR filing index page.
    static func exhibitPath(inIndex html: String) -> String? {
        let rows = html.components(separatedBy: "<tr").dropFirst()
        func path(in row: String) -> String? {
            guard let range = row.range(of: "href=\"([^\"]+)\"", options: .regularExpression) else { return nil }
            let href = String(row[range]).dropFirst(6).dropLast()
            return href.replacingOccurrences(of: "/ix?doc=", with: "")
        }
        let exhibits = rows.filter { $0.contains(">EX-99") }
        let preferred = exhibits.first { $0.contains(">EX-99.1<") || $0.contains(">EX-99.01<") } ?? exhibits.first
        return preferred.flatMap(path(in:))
    }

    func downloadFromSEC(ticker: String, quarters: Int, now: Date,
                         progress: @escaping @Sendable (String) async -> Void) async throws -> ManagementDeliveryArchive {
        let symbol = ticker.uppercased()
        await progress(L10n.text("正在读取 SEC 财报…"))
        let financials: CompanyFinancialsData
        do { financials = try await CompanyFinancialsClient.shared.load(ticker: symbol) }
        catch { throw ManagementDeliveryError.message(L10n.text("SEC 暂未返回这家公司的财报，请稍后重试。")) }
        guard let cik = financials.cik else {
            throw ManagementDeliveryError.message(L10n.text("SEC 暂未返回这家公司的财报，请稍后重试。"))
        }
        let calendar = Self.fiscalCalendar(financials.income)
        let language = ContentLanguage.current

        await progress(L10n.text("正在查找财报新闻稿…"))
        let submissionsURL = URL(string: "https://data.sec.gov/submissions/CIK\(String(format: "%010d", cik)).json")!
        guard let submissionsData = await SecurityDebateResearch.get(submissionsURL, language: language),
              let submissions = try? JSONDecoder().decode(Submissions.self, from: submissionsData) else {
            throw ManagementDeliveryError.message(L10n.text("SEC 公告列表暂时读取失败，请稍后重试。"))
        }
        let recent = submissions.filings.recent
        let today = ManagementDeliveryRules.today(now)
        // Each Item 2.02 8-K, newest first, one per fiscal quarter.
        var releases: [(quarter: FiscalQuarter, filed: String, accession: String, primary: String)] = []
        var seen = Set<FiscalQuarter>()
        for index in recent.form.indices where index < recent.items.count && index < recent.filingDate.count {
            guard recent.form[index] == "8-K", recent.items[index].contains("2.02"),
                  recent.filingDate[index] <= today,
                  let quarter = Self.quarterReported(filed: recent.filingDate[index], calendar: calendar),
                  seen.insert(quarter).inserted else { continue }
            releases.append((quarter, recent.filingDate[index], recent.accessionNumber[index], recent.primaryDocument[index]))
            if releases.count == quarters { break }
        }
        guard releases.count >= 4 else {
            throw ManagementDeliveryError.message(L10n.text("SEC 上可用的财报新闻稿不足 4 个季度，暂无法生成兑现记录。"))
        }
        let ordinals = releases.map(\.quarter.ordinal).sorted()
        guard zip(ordinals, ordinals.dropFirst()).allSatisfy({ $1 - $0 == 1 }) else {
            throw ManagementDeliveryError.message(L10n.text("最近季度的财报新闻稿存在缺口，暂无法生成完整记录。"))
        }

        var documents: [ManagementDocument] = []
        for (number, release) in releases.enumerated() {
            try Task.checkCancellation()
            await progress(L10n.text("下载财报新闻稿 \(number + 1) / \(releases.count)"))
            let folder = "https://www.sec.gov/Archives/edgar/data/\(cik)/\(release.accession.replacingOccurrences(of: "-", with: ""))/"
            // The filing's index page names each document's type; the release
            // is exhibit 99.1, whatever the company called the file.
            var url = URL(string: folder + release.primary)
            if let indexData = await SecurityDebateResearch.get(URL(string: folder + "\(release.accession)-index.htm")!, language: language),
               let path = Self.exhibitPath(inIndex: String(decoding: indexData, as: UTF8.self)) {
                url = URL(string: "https://www.sec.gov" + path)
            }
            guard let url,
                  let html = await SecurityDebateResearch.get(url, language: language),
                  let text = Self.exhibitText(String(decoding: html, as: UTF8.self)),
                  text.count >= 500 else {
                throw ManagementDeliveryError.message(L10n.text("财报新闻稿正文缺失，未更新本地结果。"))
            }
            let quarter = release.quarter
            documents.append(.init(id: "release-\(quarter.year)-Q\(quarter.quarter)", kind: .transcript,
                fiscalYear: quarter.year, period: "Q\(quarter.quarter)", published: release.filed,
                title: "\(symbol) FY\(quarter.year) Q\(quarter.quarter) · SEC 8-K", url: url,
                text: String(text.prefix(60_000)), facts: []))
        }

        await progress(L10n.text("正在整理对应财报…"))
        documents += Self.secFinancialDocuments(financials, calendar: calendar, symbol: symbol, cik: cik, today: today)
        let earliest = documents.filter { $0.kind == .transcript }.map(\.published).min()!
        documents = documents.filter { $0.kind == .transcript || $0.published >= earliest }
        guard documents.contains(where: { $0.kind == .financials && !$0.facts.isEmpty }) else {
            throw ManagementDeliveryError.message(L10n.text("未取得可核对的财报，请稍后重试。"))
        }
        return .init(ticker: symbol, downloadedAt: now, requestedQuarters: quarters, documents: documents, report: nil)
    }

    /// One document per fiscal period, holding the reported figures the rule
    /// engine checks targets against. Fourth quarters are the year less its
    /// first three, since SEC carries no standalone Q4.
    static func secFinancialDocuments(_ data: CompanyFinancialsData, calendar: [String: FiscalQuarter],
                                      symbol: String, cik: Int, today: String) -> [ManagementDocument] {
        struct Row { var values: [String: Double] = [:]; var end = ""; var filed = ""; var currency = "USD" }
        var rows: [String: Row] = [:] // "year|period"
        func key(_ quarter: FiscalQuarter, annual: Bool) -> String { "\(quarter.year)|\(annual ? "FY" : "Q\(quarter.quarter)")" }
        func add(_ key: String, _ metric: String, _ value: Double?, end: String, filed: String?, currency: String) {
            guard let value, value.isFinite else { return }
            var row = rows[key] ?? Row()
            row.values[metric] = value
            row.end = end
            row.filed = max(row.filed, filed ?? end)
            row.currency = currency
            rows[key] = row
        }
        for period in data.income {
            guard let quarter = calendar[period.periodEnd] else { continue }
            let k = key(quarter, annual: period.kind == .annual)
            add(k, "revenue", period.revenue, end: period.periodEnd, filed: period.filedDate, currency: period.currency)
            add(k, "grossProfit", period.grossProfit, end: period.periodEnd, filed: period.filedDate, currency: period.currency)
            add(k, "operatingIncome", period.operatingIncome, end: period.periodEnd, filed: period.filedDate, currency: period.currency)
            add(k, "netIncome", period.netIncome, end: period.periodEnd, filed: period.filedDate, currency: period.currency)
        }
        for period in data.cashFlow {
            guard let quarter = calendar[period.periodEnd] else { continue }
            let k = key(quarter, annual: period.kind == .annual)
            add(k, "operatingCashFlow", period.operatingCashFlow, end: period.periodEnd, filed: period.filedDate, currency: period.currency)
            add(k, "freeCashFlow", period.freeCashFlow, end: period.periodEnd, filed: period.filedDate, currency: period.currency)
        }
        // Q4 = FY − Q1 − Q2 − Q3, metric by metric, where all four are known.
        for (fyKey, fy) in rows where fyKey.hasSuffix("|FY") {
            let year = fyKey.split(separator: "|")[0]
            let quarters = (1...3).compactMap { rows["\(year)|Q\($0)"] }
            guard quarters.count == 3, rows["\(year)|Q4"] == nil else { continue }
            var q4 = Row(end: fy.end, filed: fy.filed, currency: fy.currency)
            for (metric, total) in fy.values {
                let parts = quarters.compactMap { $0.values[metric] }
                if parts.count == 3 { q4.values[metric] = total - parts.reduce(0, +) }
            }
            if !q4.values.isEmpty { rows["\(year)|Q4"] = q4 }
        }
        let source = URL(string: "https://data.sec.gov/api/xbrl/companyfacts/CIK\(String(format: "%010d", cik)).json")!
        return rows.compactMap { key, row in
            let parts = key.split(separator: "|")
            guard let year = Int(parts[0]), let published = ManagementDeliveryRules.isoDate(row.filed),
                  published <= today, !row.values.isEmpty else { return nil }
            let period = String(parts[1])
            let id = "sec-\(year)-\(period)"
            let facts: [ManagementFact] = row.values.sorted { $0.key < $1.key }.map { metric, value in
                let quote = "\(metric): \(value) \(row.currency); GAAP company; FY\(year) \(period); period ending \(row.end)."
                return ManagementFact(id: "\(id)-\(metric)", metric: metric, fiscalYear: year, period: period,
                                      periodEnd: row.end, currency: row.currency, value: value, sourceID: id, quote: quote)
            }
            return ManagementDocument(id: id, kind: .financials, fiscalYear: year, period: period, published: published,
                                      title: "\(symbol) FY\(year) \(period) · SEC", url: source,
                                      text: facts.map(\.quote).joined(separator: "\n"), facts: facts)
        }.sorted { $0.published > $1.published }
    }
}
