import Foundation

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
        if let key = brokerAliases[symbol], let entry = entries[key] { return entry }
        return entry(symbol: symbol, market: defaultMarket)
    }

    /// Exact symbols rank first, then prefixes, then company-name matches;
    /// within a rank, US listings, then shorter symbols. Call from a
    /// background task for a large catalog; no network is used.
    func search(_ query: String, market: String? = nil, limit: Int = 30) -> [Entry] {
        let query = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty, limit > 0 else { return [] }
        let exactKeys = Set(aliases.filter { Self.normalized($0.key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? "") == query }.map(\.value))
        return entries.compactMap { key, value -> (Int, String, Entry)? in
            if let market, value.market != market.uppercased() { return nil }
            let symbol = Self.normalized(value.symbol)
            let name = Self.normalized(value.name ?? "")
            let rank: Int
            if symbol == query || exactKeys.contains(key) { rank = 0 }
            else if symbol.hasPrefix(query) { rank = 1 }
            else if name.hasPrefix(query) { rank = 2 }
            else if name.contains(query) { rank = 3 }
            else { return nil }
            return (rank, key, value)
        }.sorted { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            let lhsUS = lhs.2.market == "US", rhsUS = rhs.2.market == "US"
            if lhsUS != rhsUS { return lhsUS }
            if lhs.2.symbol.count != rhs.2.symbol.count { return lhs.2.symbol.count < rhs.2.symbol.count }
            return lhs.1 < rhs.1
        }
            .prefix(min(limit, 200)).map { $0.2 }
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
