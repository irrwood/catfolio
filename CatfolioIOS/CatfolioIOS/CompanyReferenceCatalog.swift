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
              }) else { throw CatalogError.invalidCatalog }
        return catalog
    }

    func entry(symbol: String, market: String) -> Entry? {
        let key = "\(market.uppercased()):\(symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())"
        return entries[aliases[key] ?? key]
    }

    /// Exact symbols rank first, then prefixes, then company-name matches.
    /// Call from a background task for a large catalog; no network is used.
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
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .prefix(min(limit, 200)).map { $0.2 }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
