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
        case .financials: "building.columns.fill"
        case .consumerCyclical: "cart.fill"
        case .consumerDefensive: "basket.fill"
        case .industrials: "building.2.fill"
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
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sector = Self.allCases.first(where: { $0.displayName == normalized || $0.rawValue.lowercased() == normalized.lowercased() }) {
            self = sector
            return
        }
        switch normalized.lowercased() {
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
        case "communication services", "communication": self = .communication
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
    /// Direct holdings resolve against the bundled company reference, which
    /// spans 42 listing markets and reads the market off the broker's ticker
    /// suffix; funds resolve against their constituent snapshot. The reference
    /// carries a sector for a subset of the securities it lists, so anything
    /// it does not classify comes back unclassified and must be shown as such
    /// — a breakdown that quietly drops part of the portfolio is worse than
    /// none.
    static func split(ticker: String, name: String) -> SectorSplit {
        let symbol = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let fund = fundComposition(for: symbol) { return fund }

        if let catalog = try? CompanyReferenceCatalog.bundled.get(),
           let entry = catalog.entry(brokerSymbol: symbol),
           let sector = PortfolioSector(sourceName: entry.sector) {
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

    /// Empty or unclassified snapshot fields must not mask known company facts.
    static func resolvedSector(ticker: String, reportedSector: String?) -> PortfolioSector? {
        PortfolioSector(sourceName: reportedSector) ?? primarySector(ticker: ticker)
    }

    private static let fundCache = FundCompositionCache()

    private static func fundComposition(for symbol: String) -> SectorSplit? {
        fundCache.composition(for: symbol)
    }
}

/// Sector composition per tracked index, with the funds that track it.
///
/// Keyed by index rather than by fund because a dozen products track the same
/// one: SPY, VOO, IVV, CSPX, VUAG.L and VUSA.L are all the S&P 500, differing
/// only by issuer, listing and share class. Holding the mapping in a resource
/// rather than in a Swift literal means widening coverage is a data change —
/// the previous hard-coded list recognised eleven tickers, all of them ones a
/// single portfolio happened to contain.
private final class FundCompositionCache: @unchecked Sendable {
    private struct Payload: Decodable {
        let indices: [String: [String: Double]]
        let aliases: [String: String]
    }

    private let lock = NSLock()
    private var loaded = false
    private var byFund: [String: SectorSplit] = [:]

    func composition(for symbol: String) -> SectorSplit? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            loaded = true
            byFund = Self.load()
        }
        return byFund[symbol.uppercased()]
    }

    private static func load() -> [String: SectorSplit] {
        guard let url = Bundle.main.url(forResource: "etf_sector_composition", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [:] }

        var splits: [String: SectorSplit] = [:]
        for (index, weights) in payload.indices {
            var mapped: [PortfolioSector: Double] = [:]
            for (raw, weight) in weights where weight > 0 {
                guard let sector = PortfolioSector(rawValue: raw) else { continue }
                mapped[sector, default: 0] += weight
            }
            guard !mapped.isEmpty else { continue }
            splits[index] = SectorSplit(weights: mapped, isLookThrough: true)
        }
        // A fund whose index has no composition resolves to nothing rather
        // than to a neighbouring index's mix.
        return payload.aliases.reduce(into: [:]) { result, pair in
            guard let split = splits[pair.value] else { return }
            result[pair.key.uppercased()] = split
        }
    }
}
