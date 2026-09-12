import Foundation

/// One insider transaction, as Nasdaq reports it from the SEC's Form 4
/// filings.
///
/// Most of what insiders file says nothing about what they think of the
/// company. A sale under a Rule 10b5-1 plan was scheduled months before it
/// happened; an option exercise, a grant vesting or shares withheld for tax
/// are pay, not decisions. What carries information is the trade an insider
/// chose to make in the open market, so `kind` sorts every row into one of
/// those groups and `isDiscretionary` is the filter the page leads with.
struct InsiderTrade: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// An open-market purchase the insider decided on.
        case buy
        /// An open-market sale not made under a 10b5-1 plan.
        case sell
        /// Nasdaq's "Automatic Buy" / "Automatic Sell": executed under a
        /// Rule 10b5-1 prearranged trading plan.
        case planBuy
        case planSell
        /// A "Sell" that two or more insiders made on the same day at the
        /// same price: one block the company sold for everyone when their
        /// shares vested, to cover the tax. Nasdaq files it as a plain sale.
        case sellToCover
        /// A "Sell" on the day the same insider exercised options: turning
        /// pay into cash, usually timed by the option, not by a view.
        case exerciseSale
        /// Exercising options: compensation, not a view.
        case exercise
        /// Grants, vesting, gifts, shares withheld for tax.
        case nonMarketAcquisition
        case nonMarketDisposition
        case other

        init(nasdaq type: String) {
            switch type.trimmingCharacters(in: .whitespaces).lowercased() {
            case "buy": self = .buy
            case "sell": self = .sell
            case "automatic buy": self = .planBuy
            case "automatic sell": self = .planSell
            case "option execute": self = .exercise
            case "acquisition (non open market)": self = .nonMarketAcquisition
            case "disposition (non open market)": self = .nonMarketDisposition
            default: self = .other
            }
        }
    }

    let id: String
    let insider: String
    let relation: String
    let date: Date
    /// Nasdaq's own label, kept so the routine-sale rules can run again
    /// over rows merged from different fetches.
    let nasdaqType: String
    let kind: Kind
    let ownType: String
    let shares: Double
    let price: Double?
    let sharesHeld: Double?

    var isDiscretionary: Bool { kind == .buy || kind == .sell }

    /// What makes a row the same row in two fetches.
    var contentKey: String {
        "\(insider)|\(Int(date.timeIntervalSince1970))|\(nasdaqType)|\(shares)|\(price ?? -1)"
    }

    func with(id: String, kind: Kind) -> InsiderTrade {
        InsiderTrade(id: id, insider: insider, relation: relation, date: date, nasdaqType: nasdaqType,
                     kind: kind, ownType: ownType, shares: shares, price: price, sharesHeld: sharesHeld)
    }
    var value: Double? { price.flatMap { $0 > 0 ? $0 * shares : nil } }
}

struct InsiderTradesSnapshot: Codable, Sendable {
    let trades: [InsiderTrade]
    /// How many Nasdaq holds in all; more than `trades.count` means the
    /// oldest months fell outside what was fetched.
    let totalRecords: Int
    let fetchedAt: Date

    /// The open-market trades insiders chose to make, in a window.
    struct Summary: Equatable {
        var buys = 0
        var sells = 0
        var sharesBought = 0.0
        var sharesSold = 0.0
        var valueBought = 0.0
        var valueSold = 0.0
        /// False when the fetched rows stop short of the window's start.
        var isComplete = true
        var netValue: Double { valueBought - valueSold }
    }

    func summary(months: Int, now: Date = .now) -> Summary {
        let start = Calendar(identifier: .gregorian).date(byAdding: .month, value: -months, to: now) ?? now
        var result = Summary()
        for trade in trades where trade.isDiscretionary && trade.date >= start {
            if trade.kind == .buy {
                result.buys += 1
                result.sharesBought += trade.shares
                result.valueBought += trade.value ?? 0
            } else {
                result.sells += 1
                result.sharesSold += trade.shares
                result.valueSold += trade.value ?? 0
            }
        }
        if totalRecords > trades.count, let oldest = trades.map(\.date).min(), oldest > start {
            result.isComplete = false
        }
        return result
    }

    /// The date the fetched rows reach back to.
    var coverageStart: Date? { trades.map(\.date).min() }
}

actor InsiderTradesClient {
    static let shared = InsiderTradesClient()
    /// Nasdaq keeps about two years; this reaches the start of the twelve-
    /// month window for even the busiest names.
    static let rowLimit = 300
    /// What an update asks for. Filed trades do not change, so an update
    /// only needs the ones newer than the cache, and they come first.
    static let pageSize = 25
    /// Form 4s are due within two business days of a trade; looking twice a
    /// day finds new ones soon enough.
    private static let checkInterval: TimeInterval = 12 * 3600

    private var cache: [String: InsiderTradesSnapshot] = [:]
    private let cacheURL: URL
    private let session: URLSession

    init(cacheURL: URL? = nil, session: URLSession = .shared) {
        self.session = session
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InsiderTrades/snapshots-v3.json")
        if let bytes = try? Data(contentsOf: self.cacheURL),
           let stored = try? JSONDecoder().decode([String: InsiderTradesSnapshot].self, from: bytes) { cache = stored }
    }

    func cached(symbol: String) -> InsiderTradesSnapshot? {
        cache[symbol.uppercased()]
    }

    /// The cache is kept for good and shown straight away. Past
    /// `checkInterval` (or when asked), one small page of the newest rows
    /// is fetched and laid on top of it; only when that page does not reach
    /// back to what is cached is the whole history fetched again.
    func load(symbol: String, forceRefresh: Bool = false) async throws -> InsiderTradesSnapshot {
        let key = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 30, key.range(of: "^[A-Z0-9.^=-]+$", options: .regularExpression) != nil else {
            throw ScreenFailure.message(L10n.text("证券代码无效。"))
        }
        let cached = cache[key]
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.fetchedAt) < Self.checkInterval { return cached }

        do {
            var snapshot: InsiderTradesSnapshot?
            if let cached, !cached.trades.isEmpty {
                let page = try await fetch(key, limit: Self.pageSize)
                if let merged = Self.merge(page: page.trades, into: cached.trades) {
                    snapshot = InsiderTradesSnapshot(
                        trades: Self.finalize(Array(merged.prefix(Self.rowLimit))),
                        totalRecords: max(page.totalRecords, min(merged.count, Self.rowLimit)),
                        fetchedAt: Date()
                    )
                }
            }
            if snapshot == nil {
                let full = try await fetch(key, limit: Self.rowLimit)
                snapshot = InsiderTradesSnapshot(
                    trades: Self.finalize(full.trades),
                    totalRecords: max(full.totalRecords, full.trades.count),
                    fetchedAt: Date()
                )
            }
            guard let snapshot else { throw ScreenFailure.message(L10n.text("内部人士交易网络请求失败。")) }
            try Task.checkCancellation()
            cache[key] = snapshot
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let encoded = try? JSONEncoder().encode(cache) {
                try? encoded.write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            }
            return snapshot
        } catch {
            try Task.checkCancellation()
            // A failed update keeps showing what was there.
            if let cached { return cached }
            throw error
        }
    }

    private func fetch(_ symbol: String, limit: Int) async throws -> (trades: [InsiderTrade], totalRecords: Int) {
        var components = URLComponents(string: "https://api.nasdaq.com/api/company/\(symbol)/insider-trades")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "type", value: "ALL"),
            URLQueryItem(name: "sortColumn", value: "lastDate"),
            URLQueryItem(name: "sortOrder", value: "DESC"),
        ]
        guard let url = components.url else { throw ScreenFailure.message(L10n.text("证券代码无效。")) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ScreenFailure.message(L10n.text("内部人士交易网络请求失败。"))
        }
        do {
            return try Self.parseRows(bytes)
        } catch {
            throw ScreenFailure.message(L10n.text("Nasdaq 返回的内部人士交易数据无法识别。"))
        }
    }

    /// The page's new rows on top of the cache, or nil when the page does
    /// not reach the newest cached row — then there may be a gap, and the
    /// whole history is fetched instead. The cached rows the page does reach
    /// have to match it in order, so a reordered or amended record also
    /// falls back to a full fetch rather than being stitched in wrong.
    static func merge(page: [InsiderTrade], into cached: [InsiderTrade]) -> [InsiderTrade]? {
        let pageKeys = page.map(\.contentKey)
        let cachedKeys = cached.map(\.contentKey)
        guard let newest = cachedKeys.first else { return nil }
        for start in pageKeys.indices where pageKeys[start] == newest {
            let overlap = min(pageKeys.count - start, cachedKeys.count)
            if Array(pageKeys[start..<(start + overlap)]) == Array(cachedKeys[0..<overlap]) {
                return Array(page[..<start]) + cached
            }
        }
        return nil
    }

    /// Kinds worked out afresh from Nasdaq's labels over the whole set, and
    /// ids that stay put when newer rows arrive on top.
    static func finalize(_ trades: [InsiderTrade]) -> [InsiderTrade] {
        let labelled = trades.map { $0.with(id: $0.id, kind: InsiderTrade.Kind(nasdaq: $0.nasdaqType)) }
        let classified = reclassifyRoutineSales(labelled)
        var seen: [String: Int] = [:]
        var result = classified
        // Counted from the oldest, so a new duplicate on top never renumbers
        // the rows already on screen.
        for index in result.indices.reversed() {
            let key = result[index].contentKey
            let occurrence = seen[key, default: 0]
            seen[key] = occurrence + 1
            result[index] = result[index].with(id: "\(key)#\(occurrence)", kind: result[index].kind)
        }
        return result
    }

    private struct Response: Decodable {
        struct DataBody: Decodable {
            struct Table: Decodable {
                struct Inner: Decodable { let rows: [[String: String?]]? }
                /// Nasdaq sends this as a string ("106"); a number is taken too.
                struct Count: Decodable {
                    let value: Int?
                    init(from decoder: Decoder) throws {
                        let container = try decoder.singleValueContainer()
                        if let number = try? container.decode(Int.self) {
                            value = number
                        } else if let text = try? container.decode(String.self) {
                            value = Int(text.replacingOccurrences(of: ",", with: ""))
                        } else {
                            value = nil
                        }
                    }
                }
                let totalRecords: Count?
                let table: Inner?
            }
            let transactionTable: Table?
        }
        let data: DataBody?
    }

    /// Plain "Sell" rows that are not decisions, found from the rows around
    /// them: see `Kind.sellToCover` and `Kind.exerciseSale`.
    static func reclassifyRoutineSales(_ trades: [InsiderTrade]) -> [InsiderTrade] {
        func day(_ date: Date) -> String { dateFormatter.string(from: date) }
        func cents(_ price: Double?) -> Int? { price.map { Int(($0 * 100).rounded()) } }

        var sellersAtPrice: [String: Set<String>] = [:]
        var exercises: Set<String> = []
        for trade in trades {
            if trade.kind == .sell, let price = cents(trade.price), price > 0 {
                sellersAtPrice["\(day(trade.date))|\(price)", default: []].insert(trade.insider)
            }
            if trade.kind == .exercise {
                exercises.insert("\(day(trade.date))|\(trade.insider)")
            }
        }
        return trades.map { trade in
            guard trade.kind == .sell else { return trade }
            var kind = trade.kind
            if let price = cents(trade.price), (sellersAtPrice["\(day(trade.date))|\(price)"]?.count ?? 0) >= 2 {
                kind = .sellToCover
            } else if exercises.contains("\(day(trade.date))|\(trade.insider)") {
                kind = .exerciseSale
            }
            return trade.with(id: trade.id, kind: kind)
        }
    }

    static func parse(_ bytes: Data, fetchedAt: Date) throws -> InsiderTradesSnapshot {
        let page = try parseRows(bytes)
        return InsiderTradesSnapshot(
            trades: finalize(page.trades),
            totalRecords: max(page.totalRecords, page.trades.count),
            fetchedAt: fetchedAt
        )
    }

    /// Nasdaq's rows as they are, labelled but not yet classified as a set.
    static func parseRows(_ bytes: Data) throws -> (trades: [InsiderTrade], totalRecords: Int) {
        let response = try JSONDecoder().decode(Response.self, from: bytes)
        let rows = response.data?.transactionTable?.table?.rows ?? []
        var trades: [InsiderTrade] = []
        for row in rows {
            func field(_ key: String) -> String { (row[key] ?? nil)?.trimmingCharacters(in: .whitespaces) ?? "" }
            guard let date = date(field("lastDate")), let shares = number(field("sharesTraded")), shares > 0 else { continue }
            let type = field("transactionType")
            trades.append(InsiderTrade(
                id: "",
                insider: field("insider"),
                relation: field("relation"),
                date: date,
                nasdaqType: type,
                kind: InsiderTrade.Kind(nasdaq: type),
                ownType: field("ownType"),
                shares: shares,
                price: number(field("lastPrice")),
                sharesHeld: number(field("sharesHeld"))
            ))
        }
        return (trades, response.data?.transactionTable?.totalRecords?.value ?? trades.count)
    }

    /// "$1,234.50", "622,239", "(5,866)" and "" as numbers.
    static func number(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "[$,()\\s]", with: "", options: .regularExpression)
        guard !cleaned.isEmpty, let value = Double(cleaned), value.isFinite else { return nil }
        return text.hasPrefix("(") ? -value : value
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "M/d/yyyy"
        return formatter
    }()

    static func date(_ text: String) -> Date? {
        dateFormatter.date(from: text)
    }
}
