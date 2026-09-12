import Foundation

/// Annual revenue by segment, bundled with the app.
///
/// Exported by `core/tools/export_revenue_segments.py` from the FMP Premium US
/// packs, so reading it costs no FMP quota; it is as fresh as the packs the
/// build was made from. Cleaning happens there: each year was checked against
/// the same pack's income statement, which is what `revenue`, `overlap`,
/// `unallocated` and `eliminations` record.
struct RevenueSegmentCatalog: Decodable, Sendable {
    struct Item: Decodable, Sendable, Hashable {
        let name: String
        let value: Double

        /// Stored as `[name, value]` to keep the resource small.
        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            name = try container.decode(String.self)
            value = try container.decode(Double.self)
        }

        init(name: String, value: Double) {
            self.name = name
            self.value = value
        }
    }

    struct Period: Decodable, Sendable, Identifiable {
        let fy: Int
        let date: String?
        let currency: String?
        /// The income statement's revenue for the year, when the pack had it.
        let revenue: Double?
        let items: [Item]
        /// Revenue the company did not assign to any segment.
        let unallocated: Double?
        /// Inter-segment eliminations the segments are stated before.
        let eliminations: Double?
        /// The segments overlap — a parent and its parts both reported — so
        /// they add up to more than revenue.
        let overlap: Bool?

        var id: String { "\(fy)|\(date ?? "")" }

        /// What shares are taken of: revenue, unless the segments overlap or
        /// there is no revenue to go by, then their own sum.
        var base: Double {
            let sum = items.reduce(0) { $0 + $1.value } + (unallocated ?? 0)
            guard let revenue, revenue > 0, overlap != true else { return sum }
            return eliminations == nil ? revenue : sum
        }
    }

    struct Company: Decodable, Sendable {
        let p: [Period]?
        let g: [Period]?
    }

    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case product = "产品与业务"
        case geography = "地区"
        var id: String { rawValue }
    }

    let schemaVersion: Int
    let provenance: [String: String]?
    let companies: [String: Company]

    enum CatalogError: Error { case missingResource }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "revenue_segments", withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    func periods(ticker: String, kind: Kind) -> [Period] {
        let key = ticker.uppercased().replacingOccurrences(of: "/", with: ".")
        let company = companies[key] ?? companies[key.replacingOccurrences(of: ".", with: "-")]
        return (kind == .product ? company?.p : company?.g) ?? []
    }

    /// When the data was taken, from the newer pack's name.
    var asOf: String? {
        guard let name = provenance?["rolling"] ?? provenance?["history"],
              let match = name.range(of: #"_(\d{8})_[^_]*$"#, options: .regularExpression) else { return nil }
        let digits = name[match].dropFirst().prefix(8)
        return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))"
    }
}

/// Decodes the three-megabyte catalogue once, off the main thread.
actor RevenueSegmentStore {
    static let shared = RevenueSegmentStore()
    private var catalog: RevenueSegmentCatalog?

    func catalogue() -> RevenueSegmentCatalog? {
        if catalog == nil { catalog = try? RevenueSegmentCatalog.load() }
        return catalog
    }
}
