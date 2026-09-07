import Foundation

/// Low-frequency reference facts only. Holdings, returns and risk estimates
/// belong to dated Core snapshots and are not decoded from this package.
struct ETFReferenceCatalog: Decodable, Sendable {
    enum Status: String, Decodable, Sendable {
        case verified = "VERIFIED", estimated = "ESTIMATED"
        case unknown = "UNKNOWN", conflict = "CONFLICT"
    }

    struct Field<Value: Decodable & Sendable>: Decodable, Sendable {
        let value: Value?
        let status: Status
        let sources: [String]
        var verifiedValue: Value? { status == .verified ? value : nil }
    }

    struct Product: Decodable, Sendable {
        let id: String
        let name, issuer, isin, domicile, assetClass, benchmark: Field<String>
        let ucits: Field<Bool>
        let distributionPolicy: Field<String>
        /// Fraction: 0.002 means 0.20% annually.
        let expenseRatio, leverage: Field<Double>
        let currencyHedged: Field<Bool>
        let website, inceptionDate, exposureRegion, exposureCountry, subAssetClass: Field<String>
        /// Which figure the ratio is: a reported TER is not the same promise
        /// as a gross expense ratio, so the label travels with the number.
        let expenseRatioType: Field<String>
        let expenseRatioAsOf: Field<String>
    }

    struct Listing: Decodable, Sendable {
        let id: String
        let productId, ticker, exchange, mic, currency, quoteUnit: Field<String>
        let priceScale: Field<Double>
        let providerAliases: Field<[String: String]>
    }

    struct Source: Decodable, Sendable {
        let source: String
        let sourceURL, retrievedAt, effectiveDate: String?
        let contentHash, confidence: String
    }

    let schemaVersion: Int
    let temporalBasis, productIdentity, expenseRatioUnit: String
    let products: [String: Product]
    let listings: [String: Listing]
    let sources: [String: Source]

    enum CatalogError: Error { case missingResource, invalidCatalog }
    static let bundled = Result { try load() }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "etf_reference", withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.schemaVersion == 2, result.productIdentity == "ISIN_SHARE_CLASS",
              result.temporalBasis == "SNAPSHOT_ONLY", result.expenseRatioUnit == "FRACTION",
              result.products.allSatisfy({ key, p in key == p.id && key == "ISIN:" + (p.isin.verifiedValue ?? "") }),
              result.listings.allSatisfy({ key, l in
                  key == l.id && (l.productId.verifiedValue == nil || result.products[l.productId.verifiedValue!] != nil)
              }) else { throw CatalogError.invalidCatalog }
        return result
    }

    /// Exchange scopes bare tickers. RIC and Bloomberg aliases remain separate
    /// namespaces; no suffix stripping or implicit conversion between providers.
    func matches(symbol: String, exchange: String? = nil, provider: String? = nil) -> [Listing] {
        let symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty else { return [] }
        return listings.values.filter { listing in
            if let exchange, listing.exchange.verifiedValue != exchange && listing.mic.verifiedValue != exchange { return false }
            if let provider { return listing.providerAliases.verifiedValue?[provider]?.uppercased() == symbol }
            return listing.ticker.verifiedValue?.uppercased() == symbol
        }.sorted { $0.id < $1.id }
    }

    /// Ambiguity is unresolved, never the first dictionary entry.
    func listing(symbol: String, exchange: String? = nil, provider: String? = nil) -> Listing? {
        let candidates = matches(symbol: symbol, exchange: exchange, provider: provider)
        return candidates.count == 1 ? candidates[0] : nil
    }

    func product(for listing: Listing) -> Product? {
        listing.productId.verifiedValue.flatMap { products[$0] }
    }

    /// Listing markets under the exchange-suffix convention brokers report
    /// tickers in, as published by Yahoo Finance. A suffix *narrows* the
    /// search to those exchanges; it is never stripped and retried, because
    /// the whole point is that `VUSA.L` and a bare `VUSA` are not
    /// interchangeable.
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

    /// The listing a broker's ticker refers to, or nil where that is
    /// genuinely ambiguous — two products sharing a ticker on one market
    /// resolve to neither.
    func listing(brokerSymbol: String) -> Listing? {
        let raw = brokerSymbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !raw.isEmpty else { return nil }

        let markets: Set<String>
        let symbol: String
        if let dot = raw.lastIndex(of: "."),
           let mapped = Self.exchangesForSuffix[String(raw[dot...])] {
            markets = mapped
            symbol = String(raw[..<dot])
        } else if raw.contains(".") {
            return nil
        } else {
            markets = Self.usExchanges
            symbol = raw
        }

        let candidates = matches(symbol: symbol).filter {
            markets.contains($0.exchange.verifiedValue ?? "")
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// What the fund charges, for a ticker in the shape a broker reports it.
    ///
    /// Only funds have one. A share in a company has no expense ratio, and a
    /// ticker this package does not carry returns nil rather than zero —
    /// "0.00%" would read as a free fund.
    func expenseRatio(brokerSymbol: String) -> (rate: Double, product: Product)? {
        guard let listing = listing(brokerSymbol: brokerSymbol),
              let product = product(for: listing),
              let rate = product.expenseRatio.verifiedValue,
              rate >= 0, rate < 0.5 else { return nil }
        return (rate, product)
    }

    func search(_ text: String, limit: Int = 30) -> [Product] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, limit > 0 else { return [] }
        let ids = Set(matches(symbol: text).compactMap { $0.productId.verifiedValue })
        return products.values.filter { product in
            ids.contains(product.id) || product.name.verifiedValue?.localizedCaseInsensitiveContains(text) == true
                || product.isin.verifiedValue?.localizedCaseInsensitiveContains(text) == true
        }.sorted { a, b in
            if ids.contains(a.id) != ids.contains(b.id) { return ids.contains(a.id) }
            return a.id < b.id
        }.prefix(min(limit, 200)).map { $0 }
    }
}
