import Foundation
import os

/// Offline reference facts, scoped by listing market. Missing profile fields
/// remain nil even when a security is available in the search directory.
struct CompanyReferenceCatalog: Decodable, Sendable {
    struct Entry: Decodable, Sendable {
        let symbol: String
        let market: String
        let name: String?
        let exchange: String?
        let currency: String?
        let country: String?
        let sector: String?
        let industry: String?
        let website: String?
        let cik: String?
        let cikStatus: String
        let instrumentType: String
        let profileSnapshotAt: String?
        let fieldSources: [String: String]
        let missingFields: [String]

        var verifiedCIK: Int? {
            guard cikStatus == "SEC_DIRECTORY_VERIFIED", let cik else { return nil }
            return Int(cik)
        }

        /// Some source profiles provide a bare hostname. Keep the original
        /// field intact and normalize only when the caller needs a web URL.
        var websiteURL: URL? {
            guard let website, !website.isEmpty else { return nil }
            let text = website.trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = text.contains("://") ? text : "https://" + text
            guard let parts = URLComponents(string: candidate),
                  ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
                  let host = parts.host, host.contains("."),
                  parts.user == nil, parts.password == nil else { return nil }
            return parts.url
        }
    }

    let schemaVersion: Int
    let generatedOn: String
    let scope: String
    let temporalBasis: String
    let aliases: [String: String]
    /// Broker-facing ticker to primary key, spanning markets: `NG.L` is
    /// `GB:NG`, not the US `NG`. Generated from published exchange-suffix
    /// conventions rather than queried per broker, so a symbol absent here is
    /// resolved as a US listing rather than guessed at.
    let brokerAliases: [String: String]
    let entries: [String: Entry]
    private let searchCache = SearchCache()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedOn, scope, temporalBasis, aliases, brokerAliases, entries
    }

    private struct SearchRow: Sendable {
        let key: String
        let entry: Entry
        let symbol: String
        let name: String
        let isUS: Bool
        let symbolLength: Int
    }

    private struct SearchIndex: Sendable {
        let rows: [SearchRow]
        /// Folded symbol, or the symbol half of an alias, to its rows: an
        /// exact ticker is a lookup, not a scan.
        let exactRows: [String: [Int]]
        /// Every folded symbol, and every folded name, each preceded by a
        /// newline, in one UTF-8 buffer: a prefix or substring search is one
        /// `memmem` pass over contiguous bytes instead of 22k `String` calls.
        let symbols: SearchText
        let names: SearchText
        let brokerSymbols: [String: String]

        init(entries: [String: Entry], aliases: [String: String], brokerAliases: [String: String]) {
            rows = entries.map { key, entry in
                SearchRow(key: key, entry: entry,
                          symbol: CompanyReferenceCatalog.normalized(entry.symbol),
                          name: CompanyReferenceCatalog.normalized(entry.name ?? ""),
                          isUS: entry.market == "US", symbolLength: entry.symbol.count)
            }
            symbols = SearchText(rows.map(\.symbol))
            names = SearchText(rows.map(\.name))
            let rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.key, $0) })
            var exactRows: [String: Set<Int>] = [:]
            for (offset, row) in rows.enumerated() { exactRows[row.symbol, default: []].insert(offset) }
            for (alias, target) in aliases {
                guard let row = rowIndex[target] else { continue }
                let symbol = alias.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                exactRows[CompanyReferenceCatalog.normalized(symbol), default: []].insert(row)
            }
            self.exactRows = exactRows.mapValues { Array($0) }
            var brokerSymbols: [String: String] = [:]
            for (symbol, key) in brokerAliases {
                if let existing = brokerSymbols[key], existing <= symbol { continue }
                brokerSymbols[key] = symbol
            }
            self.brokerSymbols = brokerSymbols
        }
    }

    /// Copies of the catalog share the index; it is built once, off the main
    /// thread, rather than folding every company name for every keystroke.
    private final class SearchCache: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: SearchIndex?

        func index(entries: [String: Entry], aliases: [String: String],
                   brokerAliases: [String: String]) -> SearchIndex {
            lock.lock()
            defer { lock.unlock() }
            if let stored { return stored }
            let built = SearchIndex(entries: entries, aliases: aliases, brokerAliases: brokerAliases)
            stored = built
            return built
        }

        func brokerSymbol(for key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return stored?.brokerSymbols[key]
        }
    }

    /// Rows as `\n`-led UTF-8 runs in one buffer. The folded query never
    /// holds a newline, so a match cannot straddle two rows.
    struct SearchText: Sendable {
        private let bytes: [UInt8]
        /// Offset of each row's leading newline, ascending.
        private let starts: [Int]

        init(_ values: [String]) {
            var bytes: [UInt8] = []
            var starts: [Int] = []
            starts.reserveCapacity(values.count)
            for value in values {
                starts.append(bytes.count)
                bytes.append(0x0A)
                bytes.append(contentsOf: value.utf8.filter { $0 != 0x0A })
            }
            self.bytes = bytes
            self.starts = starts
        }

        /// Calls `body` once per row containing `needle`, with whether the
        /// row starts with it; stops when `body` returns false. With
        /// `prefixOnly`, only rows that start with it.
        func forEachRow(containing needle: [UInt8], prefixOnly: Bool = false,
                        _ body: (_ row: Int, _ isPrefix: Bool) -> Bool) {
            guard !needle.isEmpty else { return }
            let pattern = prefixOnly ? [0x0A] + needle : needle
            bytes.withUnsafeBytes { haystack in
                pattern.withUnsafeBytes { pattern in
                    guard let base = haystack.baseAddress, let patternBase = pattern.baseAddress else { return }
                    var offset = 0
                    while offset < haystack.count,
                          let hit = memmem(base + offset, haystack.count - offset, patternBase, pattern.count) {
                        let position = base.distance(to: UnsafeRawPointer(hit))
                        let row = self.row(at: position)
                        let isPrefix = prefixOnly || position == starts[row] + 1
                        guard body(row, isPrefix) else { return }
                        // One call per row, however often the needle recurs.
                        offset = row + 1 < starts.count ? starts[row + 1] : haystack.count
                    }
                }
            }
        }

        private func row(at position: Int) -> Int {
            var low = 0, high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] <= position { low = mid + 1 } else { high = mid }
            }
            return low - 1
        }
    }

    /// The best `capacity` matches seen so far, kept in order, so a query
    /// matching thousands of names never sorts them all.
    private struct BoundedMatches {
        typealias Match = (rank: Int, row: SearchRow)
        let capacity: Int
        private(set) var items: [Match] = []

        var isFull: Bool { items.count >= capacity }
        var worstRank: Int? { items.last?.rank }

        static func precedes(_ lhs: Match, _ rhs: Match) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.row.isUS != rhs.row.isUS { return lhs.row.isUS }
            if lhs.row.symbolLength != rhs.row.symbolLength { return lhs.row.symbolLength < rhs.row.symbolLength }
            return lhs.row.key < rhs.row.key
        }

        mutating func insert(_ match: Match) {
            if isFull, let last = items.last, !Self.precedes(match, last) { return }
            var low = 0, high = items.count
            while low < high {
                let mid = (low + high) / 2
                if Self.precedes(items[mid], match) { low = mid + 1 } else { high = mid }
            }
            items.insert(match, at: low)
            if items.count > capacity { items.removeLast() }
        }
    }

    /// Search phases for Instruments' Points of Interest; free when not recording.
    static let searchSignposter = OSSignposter(subsystem: "Catfolio", category: .pointsOfInterest)

    /// Builds the search index ahead of the first keystroke. Call off the
    /// main thread: it folds every symbol and company name once.
    func prepareSearch() {
        _ = searchCache.index(entries: entries, aliases: aliases, brokerAliases: brokerAliases)
    }

    enum CatalogError: Error { case missingResource, invalidCatalog }

    static let bundled: Result<CompanyReferenceCatalog, Error> = Result { try load() }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "company_reference", withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1, catalog.temporalBasis == "SNAPSHOT_ONLY",
              !catalog.entries.isEmpty,
              catalog.entries.allSatisfy({ key, value in
                  key == "\(value.market):\(value.symbol)" && !(value.name ?? "").isEmpty
                      && (value.cik == nil || (value.cik?.count == 10 && (value.verifiedCIK ?? 0) > 0))
              }),
              catalog.aliases.allSatisfy({ key, target in
                  key != target && catalog.entries[key] == nil && catalog.entries[target] != nil
                      && key.split(separator: ":").first == target.split(separator: ":").first
              }),
              catalog.brokerAliases.allSatisfy({ key, target in
                  key != target && catalog.entries[key] == nil && catalog.entries[target] != nil
                      && key == key.uppercased()
              }) else { throw CatalogError.invalidCatalog }
        return catalog
    }

    func entry(symbol: String, market: String) -> Entry? {
        let key = "\(market.uppercased()):\(symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())"
        return entries[aliases[key] ?? key]
    }

    /// Resolves a ticker in the shape a broker reports it, where the listing
    /// market is carried by a suffix rather than stated: `NG.L` is National
    /// Grid in London, and must not collide with NovaGold, the US `NG`.
    ///
    /// A symbol the alias table does not carry falls through to
    /// `defaultMarket`, so the common US case stays an exact lookup instead of
    /// a market inferred from the symbol's shape.
    func entry(brokerSymbol: String, defaultMarket: String = "US") -> Entry? {
        let symbol = brokerSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // A renamed listing resolves under whichever code the snapshot used.
        for code in TickerRenames.equivalents(of: symbol) {
            if let key = brokerAliases[code], let entry = entries[key] { return entry }
        }
        return entry(symbol: symbol, market: defaultMarket)
    }

    /// Exact symbols rank first, then prefixes, then company-name matches;
    /// within a rank, US listings, then shorter symbols. Call from a
    /// background task for a large catalog; no network is used.
    func search(
        _ query: String,
        market: String? = nil,
        limit: Int = 30,
        shouldCancel: () -> Bool = { false }
    ) -> [Entry] {
        let signposter = Self.searchSignposter
        let normalizing = signposter.beginInterval("search.normalize")
        let query = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let market = market?.uppercased()
        signposter.endInterval("search.normalize", normalizing)
        guard !query.isEmpty, limit > 0 else { return [] }
        let index = searchCache.index(entries: entries, aliases: aliases, brokerAliases: brokerAliases)

        let scanning = signposter.beginInterval("search.scan")
        defer { signposter.endInterval("search.scan", scanning) }
        var best = BoundedMatches(capacity: min(limit, 200))
        let exact = Set(index.exactRows[query] ?? [])
        for row in exact where market == nil || index.rows[row].entry.market == market {
            best.insert((0, index.rows[row]))
        }
        let needle = Array(query.utf8)
        var visited = 0, cancelled = false
        func keepGoing() -> Bool {
            visited += 1
            if visited.isMultiple(of: 256) && shouldCancel() { cancelled = true }
            return !cancelled
        }
        index.symbols.forEachRow(containing: needle, prefixOnly: true) { offset, _ in
            let row = index.rows[offset]
            if !exact.contains(offset), market == nil || row.entry.market == market { best.insert((1, row)) }
            return keepGoing()
        }
        if cancelled { return [] }
        // Once the page is all ticker matches, no name match can enter it.
        if best.isFull, let worst = best.worstRank, worst < 2 { return best.items.map(\.row.entry) }
        index.names.forEachRow(containing: needle) { offset, isPrefix in
            let row = index.rows[offset]
            if !exact.contains(offset), !row.symbol.hasPrefix(query), market == nil || row.entry.market == market {
                best.insert((isPrefix ? 2 : 3, row))
            }
            return keepGoing()
        }
        if cancelled || shouldCancel() { return [] }
        return best.items.map(\.row.entry)
    }

    /// A listing's price currency when its profile carries none, from the
    /// market it trades in. London quotes in pence, as the broker suffix
    /// rule in `InstrumentCurrencyRules` has it.
    static func listingCurrency(market: String) -> String? {
        [
            "US": "USD", "JP": "JPY", "IN": "INR", "HK": "HKD", "TW": "TWD", "GB": "GBX",
            "CN": "CNY", "AU": "AUD", "KR": "KRW", "DE": "EUR", "FR": "EUR", "CH": "CHF",
            "IL": "ILS", "SA": "SAR", "BR": "BRL", "CA": "CAD", "IT": "EUR", "MY": "MYR",
            "SE": "SEK", "SG": "SGD", "TR": "TRY", "ZA": "ZAR", "TH": "THB", "NO": "NOK",
            "ES": "EUR", "NL": "EUR", "ID": "IDR", "BE": "EUR", "PL": "PLN", "FI": "EUR",
            "MX": "MXN", "DK": "DKK", "KW": "KWD", "CL": "CLP", "GR": "EUR", "QA": "QAR",
            "AT": "EUR", "AE": "AED", "IE": "EUR", "PT": "EUR", "NZ": "NZD",
        ][market.uppercased()]
    }

    /// The ticker the rest of the app and its quote sources use for an entry:
    /// the bare symbol in the US, the broker's suffixed form elsewhere, so
    /// `GB:NG` opens as `NG.L` and not as the US `NG`.
    func brokerSymbol(for entry: Entry) -> String {
        guard entry.market != "US" else { return entry.symbol }
        let key = "\(entry.market):\(entry.symbol)"
        if let cached = searchCache.brokerSymbol(for: key) { return cached }
        return brokerAliases.filter { $0.value == key }.map(\.key).min() ?? entry.symbol
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Detail-page applicability only; never inferred from position size, broker,
/// sector, or the ETF that a real look-through constituent came from.
enum HoldingSecurityKind: Equatable {
    case fund, company, unknown

    static func classify(_ holding: Holding) -> Self {
        let entry = (try? CompanyReferenceCatalog.bundled.get())?.entry(brokerSymbol: holding.ticker)
        return classify(instrumentType: entry?.instrumentType,
            names: [entry?.name, holding.displayName].compactMap { $0 },
            knownFund: { LocalETFLookThrough.isKnownFund(symbol: holding.ticker) })
    }

    static func classify(instrumentType: String?, names: [String], knownFund: () -> Bool = { false }) -> Self {
        switch instrumentType?.uppercased() {
        case "ETF", "FUND", "MUTUAL_FUND", "CLOSED_END_FUND": return .fund
        case "COMPANY_SECURITY", "EQUITY_SECURITY": return .company
        default: break
        }
        // Tokens and explicit product phrases, not arbitrary FUND / INDEX
        // substrings (e.g. Fundtech, Index Systems or a fund-management company).
        let patterns = [#"(?i)\b(?:ETF|UCITS)\b"#,
                        #"(?i)\b(?:mutual|index|closed[ -]end|exchange[ -]traded)\s+fund(?=$|[\s]*[,(（-]|\s+(?:class|shares|acc|dist)\b)"#,
                        #"(?i)\binvestment\s+trust(?=$|[\s]*[,(（]|\s+(?:plc|ltd|limited)\b)"#,
                        #"(?:指数|股票型|债券型|货币|混合|证券投资)基金(?:$|[（(\s])"#]
        if names.contains(where: { name in patterns.contains { name.range(of: $0, options: .regularExpression) != nil } }) {
            return .fund
        }
        return knownFund() ? .fund : .unknown
    }
}

enum HoldingResearchModule: CaseIterable, Hashable {
    case developments, consensus, analystHistory, earnings, financials, predictionMarkets, insiders
}

enum HoldingResearchAvailability: Equatable {
    case unknown, available, empty, failed
}

/// Unknown / failed never means "permanently absent". Fund modules need actual
/// content before appearing; company entry points stay available on demand.
struct HoldingResearchVisibility {
    let kind: HoldingSecurityKind
    let currency: String?
    private(set) var availability: [HoldingResearchModule: HoldingResearchAvailability] = [:]

    func shows(_ module: HoldingResearchModule) -> Bool {
        // Analyst coverage and Form 4 insider filings are US-listed only.
        if module == .consensus || module == .insiders, currency?.uppercased() != "USD" { return false }
        let state = availability[module] ?? .unknown
        if state == .available { return true }
        if state == .empty { return false }
        if module == .analystHistory { return false } // offline snapshot, no fetch action
        return kind != .fund
    }

    var hasVisibleModules: Bool { HoldingResearchModule.allCases.contains(where: shows) }

    mutating func record(_ state: HoldingResearchAvailability, for module: HoldingResearchModule) {
        // A failed/empty refresh cannot make previously valid cached content disappear.
        guard availability[module] != .available || state == .available else { return }
        availability[module] = state
    }
}
