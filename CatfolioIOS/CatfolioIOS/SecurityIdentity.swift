import Foundation

/// The identity layer: what a broker, a statement or a CSV calls a security,
/// turned into the one ticker every other part of Catfolio keys on.
///
/// Backed by OpenFIGI, which needs no key and is always on. A mapping is
/// stable — an ISIN names the same listing tomorrow — so every answer is kept
/// on disk and each identifier is asked about once. Nothing here is a price
/// source, and a failed lookup leaves the identifier as it was.
actor SecurityIdentityResolver {
    static let shared = SecurityIdentityResolver()

    /// One listing OpenFIGI returned.
    struct Listing: Codable, Equatable, Sendable {
        let ticker: String
        let exchangeCode: String
        let name: String?
        let securityType: String?
    }

    private var cache: [String: [Listing]] = [:]
    private var loaded = false
    private let fetch: @Sendable ([OpenFIGIClient.Job]) async throws -> [[Listing]?]
    private let cacheURL: URL?

    init(fetch: @escaping @Sendable ([OpenFIGIClient.Job]) async throws -> [[Listing]?] = { try await OpenFIGIClient().map($0) },
         cacheURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("security-identity.json")) {
        self.fetch = fetch
        self.cacheURL = cacheURL
    }

    static func isISIN(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard text.count == 12 else { return false }
        let characters = Array(text)
        return characters[0...1].allSatisfy { $0.isLetter && $0.isASCII }
            && characters[2...10].allSatisfy { ($0.isLetter || $0.isNumber) && $0.isASCII }
            && characters[11].isNumber
    }

    /// ISIN → Catfolio ticker, choosing the listing in the currency the
    /// trade was made in. Unresolvable ISINs are left out of the result.
    func tickers(forISINs requests: [(isin: String, currency: String?)]) async -> [String: String] {
        loadIfNeeded()
        let isins = Array(Set(requests.map { $0.isin.uppercased() }.filter(Self.isISIN))).sorted()
        let missing = isins.filter { cache["ISIN:\($0)"] == nil }
        if !missing.isEmpty, let answers = try? await fetch(missing.map { .isin($0) }) {
            for (isin, listings) in zip(missing, answers) {
                // An empty answer is remembered too: the ISIN is unknown, not
                // worth asking again. A failed request is not: it asks again.
                if let listings { cache["ISIN:\(isin)"] = listings }
            }
            save()
        }
        var currencies: [String: String] = [:]
        for request in requests where currencies[request.isin.uppercased()] == nil {
            if let currency = request.currency, !currency.isEmpty { currencies[request.isin.uppercased()] = currency }
        }
        var result: [String: String] = [:]
        for isin in isins {
            guard let listings = cache["ISIN:\(isin)"], !listings.isEmpty,
                  let ticker = Self.preferredTicker(listings, currency: currencies[isin], isin: isin) else { continue }
            result[isin] = ticker
        }
        return result
    }

    /// The listing to trade: the exchange of the trade's currency, else the
    /// security's home market by its ISIN prefix, else the US, else any
    /// listing Catfolio can price.
    static func preferredTicker(_ listings: [Listing], currency: String?, isin: String) -> String? {
        let priced = listings.compactMap { listing -> (Listing, String)? in
            catfolioTicker(listing).map { (listing, $0) }
        }
        guard !priced.isEmpty else { return nil }
        let byCurrency = currency.flatMap { exchangeCodes(forCurrency: $0.uppercased()) } ?? []
        let byCountry = exchangeCodes(forCountry: String(isin.prefix(2)))
        for preference in [byCurrency, byCountry, usExchanges] where !preference.isEmpty {
            for code in preference {
                if let match = priced.first(where: { $0.0.exchangeCode == code }) { return match.1 }
            }
        }
        return priced.first?.1
    }

    /// Catfolio's tickers are Yahoo's: bare for US listings, suffixed elsewhere.
    static func catfolioTicker(_ listing: Listing) -> String? {
        let base = listing.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .replacingOccurrences(of: "/", with: ".")
            .replacingOccurrences(of: " ", with: "-")
        guard !base.isEmpty else { return nil }
        if usExchanges.contains(listing.exchangeCode) { return base }
        guard let suffix = suffixes[listing.exchangeCode] else { return nil }
        return base + suffix
    }

    private static let usExchanges = ["US", "UN", "UW", "UQ", "UA", "UP", "UR", "UV"]
    private static let suffixes: [String: String] = [
        "LN": ".L", "GY": ".DE", "GR": ".F", "FP": ".PA", "NA": ".AS", "IM": ".MI",
        "SW": ".SW", "SE": ".SW", "SM": ".MC", "DC": ".CO", "SS": ".ST", "NO": ".OL", "FH": ".HE",
        "BB": ".BR", "ID": ".IR", "AV": ".VI", "PL": ".LS", "CN": ".TO", "CT": ".TO", "HK": ".HK",
        "JT": ".T", "AT": ".AX",
    ]

    private static func exchangeCodes(forCurrency currency: String) -> [String]? {
        switch currency {
        case "USD": usExchanges
        case "GBP", "GBX", "GBp": ["LN"]
        case "EUR": ["GY", "NA", "FP", "IM", "SM", "ID", "BB", "AV", "FH", "PL", "GR"]
        case "CHF": ["SW", "SE"]
        case "DKK": ["DC"]
        case "SEK": ["SS"]
        case "NOK": ["NO"]
        case "CAD": ["CN", "CT"]
        case "HKD": ["HK"]
        case "JPY": ["JT"]
        case "AUD": ["AT"]
        default: nil
        }
    }

    private static func exchangeCodes(forCountry country: String) -> [String] {
        switch country.uppercased() {
        case "US": usExchanges
        case "GB": ["LN"]
        case "DE": ["GY", "GR"]
        case "FR": ["FP"]
        case "NL": ["NA"]
        case "IT": ["IM"]
        case "ES": ["SM"]
        case "CH": ["SW", "SE"]
        case "DK": ["DC"]
        case "SE": ["SS"]
        case "IE": ["LN", "GY", "NA"]
        case "LU": ["LN", "GY", "FP"]
        case "CA": ["CN", "CT"]
        case "HK": ["HK"]
        default: []
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let stored = try? JSONDecoder().decode([String: [Listing]].self, from: data) else { return }
        cache = stored
    }

    private func save() {
        guard let cacheURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}

/// OpenFIGI's mapping endpoint. Without a key it takes ten jobs a request and
/// a few requests a minute, so jobs are sent in tens and a 429 waits once.
struct OpenFIGIClient {
    enum Job: Sendable {
        case isin(String)

        var body: [String: String] {
            switch self {
            case let .isin(value): ["idType": "ID_ISIN", "idValue": value]
            }
        }
    }

    private static let url = URL(string: "https://api.openfigi.com/v3/mapping")!
    private static let batchSize = 10

    /// One answer per job, in order: its listings, or nil where the request
    /// for it failed.
    func map(_ jobs: [Job]) async throws -> [[SecurityIdentityResolver.Listing]?] {
        var answers: [[SecurityIdentityResolver.Listing]?] = []
        for start in stride(from: 0, to: jobs.count, by: Self.batchSize) {
            let batch = Array(jobs[start..<min(jobs.count, start + Self.batchSize)])
            do {
                answers += try await send(batch, retries: 1)
            } catch {
                answers += Array(repeating: nil, count: batch.count)
            }
        }
        return answers
    }

    private func send(_ batch: [Job], retries: Int) async throws -> [[SecurityIdentityResolver.Listing]?] {
        var request = URLRequest(url: Self.url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: batch.map(\.body))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 429, retries > 0 {
            try await Task.sleep(for: .seconds(7))
            return try await send(batch, retries: retries - 1)
        }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return try Self.decode(data)
    }

    static func decode(_ data: Data) throws -> [[SecurityIdentityResolver.Listing]?] {
        struct Answer: Decodable {
            struct Item: Decodable {
                let ticker: String?
                let exchCode: String?
                let name: String?
                let securityType: String?
            }
            let data: [Item]?
            let warning: String?
            let error: String?
        }
        return try JSONDecoder().decode([Answer].self, from: data).map { answer in
            if answer.error != nil { return nil }
            return (answer.data ?? []).compactMap { item in
                guard let ticker = item.ticker, let exchange = item.exchCode else { return nil }
                return .init(ticker: ticker, exchangeCode: exchange, name: item.name, securityType: item.securityType)
            }
        }
    }
}
