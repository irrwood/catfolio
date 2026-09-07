import Foundation

/// One canonical sector vocabulary.
///
/// Two bundled sources disagree: the company reference uses FMP's names
/// ("Technology", "Healthcare", "Consumer Cyclical") and the ETF constituent
/// snapshots use GICS ("Information Technology", "Health Care", "Consumer
/// Discretionary"). Left alone, the same company lands in two different
/// buckets depending on whether it was held directly or through a fund.
enum PortfolioSector: String, CaseIterable, Hashable, Sendable {
    case technology
    case healthcare
    case financials
    case consumerCyclical
    case consumerDefensive
    case industrials
    case energy
    case materials
    case realEstate
    case utilities
    case communication

    var displayName: String {
        switch self {
        case .technology: "科技"
        case .healthcare: "医疗保健"
        case .financials: "金融"
        case .consumerCyclical: "可选消费"
        case .consumerDefensive: "必需消费"
        case .industrials: "工业"
        case .energy: "能源"
        case .materials: "基础材料"
        case .realEstate: "房地产"
        case .utilities: "公用事业"
        case .communication: "通信服务"
        }
    }

    var symbolName: String {
        switch self {
        case .technology: "cpu"
        case .healthcare: "cross.case.fill"
        case .financials: "banknote.fill"
        case .consumerCyclical: "cart.fill"
        case .consumerDefensive: "basket.fill"
        case .industrials: "gearshape.fill"
        case .energy: "fuelpump.fill"
        case .materials: "cube.fill"
        case .realEstate: "house.fill"
        case .utilities: "bolt.fill"
        case .communication: "antenna.radiowaves.left.and.right"
        }
    }

    /// Accepts either vocabulary. Anything unrecognised stays `nil` rather
    /// than being folded into a neighbouring sector.
    init?(sourceName raw: String?) {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "technology", "information technology": self = .technology
        case "healthcare", "health care": self = .healthcare
        case "financial services", "financials": self = .financials
        case "consumer cyclical", "consumer discretionary": self = .consumerCyclical
        case "consumer defensive", "consumer staples": self = .consumerDefensive
        case "industrials": self = .industrials
        case "energy": self = .energy
        case "basic materials", "materials": self = .materials
        case "real estate": self = .realEstate
        case "utilities": self = .utilities
        case "communication services": self = .communication
        default: return nil
        }
    }
}

/// How one holding's money is spread across sectors.
///
/// A single stock is one sector at full weight. A fund is spread by the
/// sector composition of its own constituent snapshot — an approximation,
/// because the fund's move was not uniform across its holdings, but a
/// defensible one when per-constituent returns are not available.
struct SectorSplit: Sendable {
    /// Fractions summing to at most 1. The remainder is unclassified.
    let weights: [PortfolioSector: Double]
    let isLookThrough: Bool

    var classifiedFraction: Double { weights.values.reduce(0, +) }
    var unclassifiedFraction: Double { max(0, 1 - classifiedFraction) }

    static let unclassified = SectorSplit(weights: [:], isLookThrough: false)
}

enum SectorAttribution {
    /// Splits for every ticker the caller asks about.
    ///
    /// Direct holdings resolve against the bundled US company reference; funds
    /// resolve against their constituent snapshot. Neither source covers
    /// non-US listings, so those come back unclassified and must be shown as
    /// such — a sector breakdown that quietly drops half the portfolio is
    /// worse than none.
    static func split(ticker: String, name: String) -> SectorSplit {
        let symbol = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let fund = fundComposition(for: symbol) { return fund }

        // The generated reference wins, so a hand-assigned sector is dropped
        // the moment a covering entry ships rather than shadowing it.
        if let catalog = try? CompanyReferenceCatalog.bundled.get(),
           let entry = catalog.entry(symbol: symbol, market: "US"),
           let sector = PortfolioSector(sourceName: entry.sector) {
            return SectorSplit(weights: [sector: 1], isLookThrough: false)
        }
        if let sector = SectorOverrides.shared.sector(for: symbol) {
            return SectorSplit(weights: [sector: 1], isLookThrough: false)
        }
        return .unclassified
    }

    /// The single sector a security belongs to, for the model's own field.
    ///
    /// A fund deliberately returns `nil`: it is spread across sectors, and
    /// naming one of them on the holding would assert something false. Callers
    /// that want the spread ask for `split(ticker:name:)` instead.
    static func primarySector(ticker: String) -> PortfolioSector? {
        let symbol = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard fundComposition(for: symbol) == nil else { return nil }
        let split = split(ticker: symbol, name: "")
        guard split.weights.count == 1, let only = split.weights.first, only.value > 0.999 else {
            return nil
        }
        return only.key
    }

    private static let fundCache = FundCompositionCache()

    private static func fundComposition(for symbol: String) -> SectorSplit? {
        fundCache.composition(for: symbol)
    }
}

/// Constituent snapshots are bundled and never change at runtime, so each
/// fund's sector mix is computed once.
private final class FundCompositionCache: @unchecked Sendable {
    private struct Constituent: Decodable {
        let sector: String?
        let weight: Double

        enum CodingKeys: String, CodingKey {
            case sector
            case weight = "weight_percent"
        }
    }

    private struct Dataset: Decodable { let rows: [Constituent] }

    /// Same aliases the look-through screen already recognises.
    private static let resources: [String: String] = [
        "SPY": "sp500_holdings", "VOO": "sp500_holdings", "IVV": "sp500_holdings",
        "VUAG": "sp500_holdings", "VUAG.L": "sp500_holdings",
        "VUSA": "sp500_holdings", "VUSA.L": "sp500_holdings",
        "EQQQ": "eqqq_holdings", "EQQQ.L": "eqqq_holdings",
        "EQQU": "eqqq_holdings", "EQQU.L": "eqqq_holdings",
    ]

    private let lock = NSLock()
    private var cache: [String: SectorSplit?] = [:]

    func composition(for symbol: String) -> SectorSplit? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[symbol] { return cached }
        let value = Self.load(symbol: symbol)
        cache[symbol] = value
        return value
    }

    private static func load(symbol: String) -> SectorSplit? {
        guard let resource = resources[symbol],
              let url = Bundle.main.url(forResource: resource, withExtension: "json", subdirectory: "ETF")
                ?? Bundle.main.url(forResource: resource, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dataset = try? JSONDecoder().decode(Dataset.self, from: data) else { return nil }

        var weights: [PortfolioSector: Double] = [:]
        var total = 0.0
        for row in dataset.rows where row.weight.isFinite && row.weight > 0 {
            total += row.weight
            guard let sector = PortfolioSector(sourceName: row.sector) else { continue }
            weights[sector, default: 0] += row.weight
        }
        guard total > 0 else { return nil }
        // Normalised against the snapshot's own total, so a fund whose
        // constituents are partly unclassified reports the gap rather than
        // inflating the sectors it does know.
        return SectorSplit(
            weights: weights.mapValues { $0 / total },
            isLookThrough: true
        )
    }
}


/// Hand-assigned sectors for listings the generated US reference does not
/// cover.
///
/// These are read off the issuer's principal business, not taken from a
/// licensed classification, so they are consulted only after the generated
/// data has had its say — a covering entry appearing upstream silently
/// retires the hand-written one.
final class SectorOverrides: @unchecked Sendable {
    static let shared = SectorOverrides()

    private struct Payload: Decodable {
        struct Entry: Decodable { let sector: String }
        let entries: [String: Entry]
    }

    private let table: [String: PortfolioSector]

    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: "sector_overrides", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            table = [:]
            return
        }
        table = payload.entries.reduce(into: [:]) { result, pair in
            guard let sector = PortfolioSector(sourceName: pair.value.sector) else { return }
            result[pair.key.uppercased()] = sector
        }
    }

    func sector(for symbol: String) -> PortfolioSector? {
        table[symbol.uppercased()]
    }

    var count: Int { table.count }
}
