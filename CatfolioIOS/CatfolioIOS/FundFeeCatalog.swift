import Foundation

/// What a fund charges annually, for every listing the package covers.
///
/// Replaces the ETF reference package this app used to carry for the same
/// purpose. That one described 1,477 listings and could price 1,393 products,
/// which left widely held funds — QQQ, VTI, VT, ARKK, SCHD — with no fee at
/// all because their listing never linked to a product. This one covers all
/// 6,651 listings the reference knew about, at a quarter of the bytes, and
/// carries its own listing aliases so nothing else has to be shipped to
/// resolve a ticker.
struct FundFeeCatalog: Decodable, Sendable {
    struct Record: Decodable, Sendable {
        let expenseRatio: Double?
        let expenseRatioStatus: String?
        /// Which figure the number is — a reported TER is not the same promise
        /// as a gross expense ratio, so the label travels with it.
        let expenseRatioType: String?
        let expenseRatioAsOf: String?
        let name: String?
    }

    /// A fee, with how much the package is prepared to stand behind it.
    struct Fee: Sendable {
        let rate: Double
        let isVerified: Bool
        let kind: String?
        let asOf: String?
        let name: String?
    }

    let schemaVersion: Int
    let feeUnit: String
    /// An absent fee means nobody published one, never that the fund is free.
    let missingMeaning: String
    let records: [String: Record]
    let aliases: [String: String]

    /// `exchange` + `ticker` to the record that prices it.
    ///
    /// The package names listings as `LISTING:<exchange>:<ticker>:<currency>`,
    /// which is the same identity the app's own resolution produces, so the
    /// index is a straight reshape rather than a second opinion about what a
    /// ticker means. Currency is dropped: a line's fee does not depend on
    /// which currency it is quoted in, and several listings quote "?".
    private var recordKeyByListing: [String: String] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, feeUnit, missingMeaning, records, aliases
    }

    enum CatalogError: Error { case missingResource, invalidCatalog }

    static let bundled = Result { try load() }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "fund_fees", withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        var catalog = try JSONDecoder().decode(Self.self, from: data)

        var index: [String: String] = [:]
        var ambiguous: Set<String> = []
        for (alias, target) in catalog.aliases {
            let parts = alias.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[0] == "LISTING" else { continue }
            let key = Self.listingKey(exchange: String(parts[1]), ticker: String(parts[2]))
            if let existing = index[key], existing != target { ambiguous.insert(key) }
            index[key] = target
        }
        // One market, one ticker, two different funds is not something to
        // pick a winner for. Drop the pair so the lookup returns nothing.
        for key in ambiguous { index.removeValue(forKey: key) }
        catalog.recordKeyByListing = index

        guard catalog.schemaVersion == 1,
              catalog.feeUnit == "DECIMAL_FRACTION",
              catalog.missingMeaning == "UNKNOWN_NOT_ZERO",
              !catalog.records.isEmpty,
              !index.isEmpty,
              catalog.aliases.values.allSatisfy({ catalog.records[$0] != nil })
        else { throw CatalogError.invalidCatalog }
        return catalog
    }

    private static func listingKey(exchange: String, ticker: String) -> String {
        "\(exchange)\u{1}\(ticker.uppercased())"
    }

    /// Listing markets under the exchange-suffix convention brokers report
    /// tickers in, as published by Yahoo Finance. A suffix *narrows* the
    /// search to those exchanges; it is never stripped and retried, because
    /// the whole point is that `VUSA.L` and a bare `VUSA` are not
    /// interchangeable — and in this package a bare `EQQQ` is a US fund
    /// charging 1.12%, where `EQQQ.L` is the London line charging 0.30%.
    ///
    /// Exchanges the published table does not name are deliberately absent:
    /// Berne, BIVA and the legacy Chi-X venues resolve to nothing rather than
    /// to a suffix inferred from the exchange's name.
    private static let exchangesForSuffix: [String: Set<String>] = [
        ".L": ["London Stock Exchange"],
        ".IL": ["London Stock Exchange"],
        ".DE": ["Deutsche Boerse Xetra", "Xetra"],
        ".SW": ["SIX Swiss Exchange"],
        ".MI": ["Borsa Italiana"],
        ".MX": ["Bolsa Mexicana De Valores"],
        ".AS": ["Euronext Amsterdam"],
        ".PA": ["Nyse Euronext - Euronext Paris"],
        ".TA": ["Tel Aviv Stock Exchange"],
        ".SN": ["Santiago Stock Exchange"],
        ".CL": ["Bolsa De Valores De Colombia"],
        ".XD": ["Cboe Europe"],
    ]

    /// A bare ticker means a US listing. Anything else has to say which
    /// market it is, so that a London line is never answered with a US fee.
    private static let usExchanges: Set<String> = ["NYSE Arca", "NASDAQ", "NYSE", "Cboe BZX"]

    /// What the fund charges, for a ticker in the shape a broker reports it.
    ///
    /// Only funds have one. A share in a company has no expense ratio, and a
    /// ticker this package does not carry returns nil rather than zero —
    /// "0.00%" would read as a free fund, which is what `missingMeaning`
    /// exists to forbid.
    func fee(brokerSymbol: String) -> Fee? {
        let raw = brokerSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !raw.isEmpty else { return nil }

        let markets: Set<String>
        let ticker: String
        if let dot = raw.lastIndex(of: "."), let mapped = Self.exchangesForSuffix[String(raw[dot...])] {
            markets = mapped
            ticker = String(raw[..<dot])
        } else if raw.contains(".") {
            return nil
        } else {
            markets = Self.usExchanges
            ticker = raw
        }

        let keys = Set(markets.compactMap { recordKeyByListing[Self.listingKey(exchange: $0, ticker: ticker)] })
        guard keys.count == 1, let record = records[keys.first!],
              let rate = record.expenseRatio, rate >= 0, rate < 0.5 else { return nil }

        return Fee(
            rate: rate,
            isVerified: record.expenseRatioStatus == "VERIFIED",
            kind: record.expenseRatioType,
            asOf: record.expenseRatioAsOf,
            name: record.name
        )
    }
}
