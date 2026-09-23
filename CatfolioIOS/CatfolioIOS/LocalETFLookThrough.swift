import Foundation
import CryptoKit
import FoundationModels
import OSLog

enum LocalETFLookThrough {
    /// Exact offline directory membership; does not expand positions or fetch holdings.
    static func isKnownFund(symbol: String) -> Bool {
        funds[symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()] != nil
    }
    private struct FundDefinition {
        let resource: String
        let label: String
    }

    private struct Dataset: Decodable {
        let benchmark: String?
        let asOf: String?
        let source: String?
        let sourceURL: String?
        let rows: [Constituent]

        enum CodingKeys: String, CodingKey {
            case rows, source, benchmark
            case asOf = "as_of"
            case sourceURL = "source_url"
        }
    }

    private struct Constituent: Decodable {
        let ticker: String
        let name: String
        let sector: String?
        let weight: Double

        enum CodingKeys: String, CodingKey {
            case ticker, name, sector
            case weight = "weight_percent"
        }
    }

    private struct AggregatedExposure {
        var name: String
        var sector: String?
        var fromETFUSD: Double
        var costUSD: Double? = 0
        var fundMarketValues: [String: Double] = [:]
    }

    private struct HoldingsCatalog: Decodable {
        let schemaVersion: Int
        let funds: [String: Dataset]
    }

    private static let additionalDatasets: [String: Dataset] = {
        guard let url = Bundle.main.url(forResource: "etf_holdings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(HoldingsCatalog.self, from: data),
              catalog.schemaVersion == 1 else { return [:] }
        return catalog.funds
    }()

    private static let funds: [String: FundDefinition] = {
        let sp500 = FundDefinition(resource: "sp500_holdings", label: "S&P 500")
        let nasdaq100 = FundDefinition(resource: "eqqq_holdings", label: "EQQQ")
        var definitions: [String: FundDefinition] = [
            "VUAG": sp500, "VUAG.L": sp500,
            "VUSA": sp500, "VUSA.L": sp500,
            "SPY": sp500, "VOO": sp500, "IVV": sp500,
            // XS2D already embeds 2x daily leverage in its price path. Allocate
            // its net position value once; multiplying the holding by 2 here
            // would overstate the portfolio's cost and market value.
            "XS2D": sp500, "XS2D.L": sp500,
            "DBPG": sp500, "DBPG.DE": sp500,
            "XS2L": sp500, "XS2L.MI": sp500,
            "EQQQ": nasdaq100, "EQQQ.L": nasdaq100,
            "EQQU": nasdaq100, "EQQU.L": nasdaq100,
        ]
        // Exact fund snapshots take precedence over the historical index proxy.
        for ticker in additionalDatasets.keys {
            definitions[ticker] = FundDefinition(resource: ticker, label: ticker)
        }
        return definitions
    }()

    static func make(document: LocalPortfolioDocument, basis: ETFLookThroughBasis) throws -> ETFLookThroughResponse {
        if document.positions.contains(where: { $0.publicDisclosure != nil }) {
            guard basis == .market,
                  document.positions.allSatisfy({ $0.publicDisclosure?.value != nil && $0.publicDisclosure?.instrumentLabel == nil }) else {
                throw LocalServiceError.remote(L10n.text("当前数据不足，暂时无法按该口径计算。"))
            }
        }
        let supported = Set(funds.keys)
        let etfs = document.positions.filter { supported.contains($0.ticker.uppercased()) }
        guard !etfs.isEmpty else { throw LocalServiceError.noSupportedETF }

        let requiredResources = Set(etfs.compactMap { funds[$0.ticker.uppercased()]?.resource })
        var datasets: [String: Dataset] = [:]
        for resource in requiredResources {
            if let dataset = additionalDatasets[resource] {
                datasets[resource] = dataset
                continue
            }
            guard let url = Bundle.main.url(forResource: resource, withExtension: "json"),
                  let dataset = try? JSONDecoder().decode(Dataset.self, from: Data(contentsOf: url)) else {
                throw LocalServiceError.invalidResponse
            }
            datasets[resource] = dataset
        }

        func etfExposure(_ position: LocalPositionRecord) throws -> Double {
            switch basis {
            case .market:
                try LocalPortfolioEngine.usd(position.publicDisclosure.map { $0.value ?? .nan } ?? (position.shares * position.quotePrice), currency: position.quoteCurrency)
            case .cost:
                try LocalPortfolioEngine.usd(position.shares * position.averageCost, currency: position.currency)
            }
        }
        func directMarketValue(_ position: LocalPositionRecord) throws -> Double {
            try LocalPortfolioEngine.usd(
                position.publicDisclosure.map { $0.value ?? .nan } ?? (position.shares * position.quotePrice),
                currency: position.quoteCurrency
            )
        }
        func positionCost(_ position: LocalPositionRecord) throws -> Double? {
            guard position.publicDisclosure == nil, position.shares.isFinite,
                  position.shares > 0, position.averageCost.isFinite,
                  position.averageCost > 0 else { return nil }
            let cost = try LocalPortfolioEngine.usd(position.shares * position.averageCost, currency: position.currency)
            return cost.isFinite && cost > 0 ? cost : nil
        }
        func estimatedPercent(market: Double, cost: Double?) -> Double? {
            guard basis == .market, let cost, cost.isFinite, cost > 0, market.isFinite else { return nil }
            let result = (market / cost - 1) * 100
            return result.isFinite ? result : nil
        }

        var etfExposures: [(position: LocalPositionRecord, amount: Double, definition: FundDefinition)] = []
        for position in etfs {
            guard let definition = funds[position.ticker.uppercased()] else { continue }
            etfExposures.append((position, try etfExposure(position), definition))
        }
        let etfTotal = etfExposures.reduce(0) { $0 + $1.amount }
        let directPositions = document.positions.filter { !supported.contains($0.ticker.uppercased()) }
        var direct: [String: (value: Double, name: String)] = [:]
        var directCosts: [String: Double] = [:]
        var missingDirectCosts: Set<String> = []
        for position in directPositions {
            let ticker = position.ticker.uppercased()
            let current = direct[ticker]?.value ?? 0
            direct[ticker] = (try current + directMarketValue(position), position.name)
            if let cost = try positionCost(position) {
                directCosts[ticker, default: 0] += cost
            } else {
                missingDirectCosts.insert(ticker)
            }
        }

        var aggregated: [String: AggregatedExposure] = [:]
        var otherFromETFUSD = 0.0
        var otherCostUSD: Double? = 0
        var otherFundValues: [String: Double] = [:]

        for exposure in etfExposures {
            guard let dataset = datasets[exposure.definition.resource] else { continue }
            let etfCost = try positionCost(exposure.position)
            var allocatedWeight = 0.0
            let fundTicker = exposure.position.ticker.uppercased()
            // Rounded provider weights can exceed 100%; never manufacture value.
            let weightTotal = dataset.rows.reduce(0.0) { $0 + ($1.weight.isFinite ? max(0, $1.weight) : 0) }
            let weightScale = 100 / max(100, weightTotal)
            for constituent in dataset.rows {
                let weight = (constituent.weight.isFinite ? max(0, constituent.weight) : 0) * weightScale
                guard weight > 0 else { continue }
                allocatedWeight += weight
                let amount = exposure.amount * weight / 100
                let ticker = constituent.ticker.uppercased()
                if ticker == "CASH" || ticker == "ETF 其他" {
                    otherFromETFUSD += amount
                    otherFundValues[fundTicker, default: 0] += amount
                    if weight > 0 {
                        otherCostUSD = otherCostUSD.flatMap { sum in etfCost.map { sum + $0 * weight / 100 } }
                    }
                    continue
                }
                var current = aggregated[ticker] ?? AggregatedExposure(
                    name: constituent.name,
                    sector: constituent.sector,
                    fromETFUSD: 0
                )
                current.fromETFUSD += amount
                current.fundMarketValues[fundTicker, default: 0] += amount
                // Use the same weights for both known fund market value and
                // cost. This allocates fund P/L; it is not a constituent's
                // historical price return and requires no extra quote request.
                if weight > 0 {
                    current.costUSD = current.costUSD.flatMap { sum in etfCost.map { sum + $0 * weight / 100 } }
                }
                if current.sector == nil { current.sector = constituent.sector }
                aggregated[ticker] = current
            }
            let unallocatedWeight = max(0, 100 - allocatedWeight)
            otherFromETFUSD += exposure.amount * unallocatedWeight / 100
            otherFundValues[fundTicker, default: 0] += exposure.amount * unallocatedWeight / 100
            if unallocatedWeight > 0 {
                otherCostUSD = otherCostUSD.flatMap { sum in etfCost.map { sum + $0 * unallocatedWeight / 100 } }
            }
        }

        var rows = aggregated.map { ticker, exposure -> ETFLookThroughRow in
            let directValue = direct.removeValue(forKey: ticker)
            let directUSD = directValue?.value ?? 0
            let combinedCost = missingDirectCosts.contains(ticker) ? nil
                : exposure.costUSD.map { $0 + (directCosts[ticker] ?? 0) }
            return ETFLookThroughRow(
                ticker: ticker,
                logoSymbol: ticker,
                name: directValue?.name.isEmpty == false ? directValue!.name : exposure.name,
                directUSD: directUSD,
                fromETFUSD: exposure.fromETFUSD,
                totalUSD: directUSD + exposure.fromETFUSD,
                etfWeightPercent: etfTotal > 0 ? exposure.fromETFUSD / etfTotal * 100 : 0,
                sector: SectorAttribution.resolvedSector(ticker: ticker, reportedSector: exposure.sector)?.displayName,
                estimatedHoldingPeriodPercent: estimatedPercent(market: directUSD + exposure.fromETFUSD, cost: combinedCost),
                allocatedCostUSD: basis == .market ? combinedCost : nil,
                fundMarketValues: basis == .market ? exposure.fundMarketValues : nil
            )
        }

        let otherWeight = etfTotal > 0 ? otherFromETFUSD / etfTotal * 100 : 0
        let covered = max(0, 100 - otherWeight)
        if otherFromETFUSD > 0 {
            rows.append(ETFLookThroughRow(
                ticker: "ETF 其他", logoSymbol: nil, name: L10n.text("基金现金、衍生品及未识别部分"),
                directUSD: 0, fromETFUSD: otherFromETFUSD,
                totalUSD: otherFromETFUSD, etfWeightPercent: otherWeight, sector: "ETF / Other",
                estimatedHoldingPeriodPercent: estimatedPercent(market: otherFromETFUSD, cost: otherCostUSD),
                allocatedCostUSD: basis == .market ? otherCostUSD : nil,
                fundMarketValues: basis == .market ? otherFundValues : nil
            ))
        }
        rows.append(contentsOf: direct.map { ticker, item in
            ETFLookThroughRow(
                ticker: ticker, logoSymbol: ticker, name: item.name.isEmpty ? ticker : item.name,
                directUSD: item.value, fromETFUSD: 0, totalUSD: item.value, etfWeightPercent: 0,
                sector: SectorAttribution.primarySector(ticker: ticker)?.displayName,
                allocatedCostUSD: missingDirectCosts.contains(ticker) ? nil : directCosts[ticker]
            )
        })
        rows.sort { $0.totalUSD > $1.totalUSD }

        let usedDefinitions = Dictionary(
            grouping: etfExposures.map(\.definition),
            by: \.resource
        ).compactMap { resource, definitions -> (FundDefinition, Dataset)? in
            guard let definition = definitions.first, let dataset = datasets[resource] else { return nil }
            return (definition, dataset)
        }.sorted { $0.0.label < $1.0.label }
        let dates = usedDefinitions.compactMap { definition, dataset in
            dataset.asOf.map { "\(definition.label) \($0)" }
        }
        let sources = Array(Set(usedDefinitions.compactMap { $0.1.source })).sorted()
        let singleDataset = usedDefinitions.count == 1 ? usedDefinitions.first?.1 : nil
        let xs2dAliases = Set(["XS2D", "XS2D.L", "DBPG", "DBPG.DE", "XS2L", "XS2L.MI"])
        let hasXS2D = etfs.contains { xs2dAliases.contains($0.ticker.uppercased()) }
        let onlyXS2D = etfs.allSatisfy { xs2dAliases.contains($0.ticker.uppercased()) }
        let sourceSummary = (sources + (hasXS2D ? [L10n.text("XS2D：S&P 500 经济暴露近似")] : []))
            .joined(separator: " · ")
        let xs2dSourceURL = "https://etf.dws.com/en-gb/AssetDownload/Index/15d381e4-a965-436a-a89e-dc706840c3cf/Overall-Factsheet.pdf"

        return ETFLookThroughResponse(
            basis: basis.rawValue,
            etfTickers: etfs.map(\.ticker).sorted(),
            etfTotalUSD: etfTotal,
            coveredWeightPercent: covered,
            otherWeightPercent: otherWeight,
            constituentCount: aggregated.count,
            holdingsAsOf: dates.joined(separator: " · "),
            holdingsSource: sourceSummary,
            holdingsSourceURL: hasXS2D ? (onlyXS2D ? xs2dSourceURL : nil) : singleDataset?.sourceURL,
            rows: rows
        )
    }
}

/// Display-only aggregation. It never changes broker shares, trades or the ledger.
extension ETFLookThroughRow {
    func mergedPerformance(for period: HoldingPerformancePeriod,
                           holdings: [String: Holding], dailyChanges: [String: Double]) -> HoldingPerformanceValues? {
        guard totalUSD.isFinite else { return nil }
        if fromETFUSD == 0 {
            guard let direct = holdings[ticker.uppercased()] else { return nil }
            return direct.performanceValues(for: period,
                dailyChangePercent: dailyChanges[ticker.uppercased()] ?? direct.todayChangePercent)
        }
        switch period {
        case .holdingPeriod:
            guard let cost = allocatedCostUSD, cost.isFinite, cost > 0 else { return nil }
            let amount = totalUSD - cost
            let percent = amount / cost * 100
            guard amount.isFinite, percent.isFinite else { return nil }
            return HoldingPerformanceValues(amount: amount, percent: percent)
        case .today:
            guard let fundMarketValues,
                  abs(fundMarketValues.values.reduce(0, +) - fromETFUSD) <= max(0.000001, abs(fromETFUSD) * 1e-9) else { return nil }
            var amount = 0.0
            if directUSD != 0 {
                guard let direct = holdings[ticker.uppercased()],
                      let change = dailyChanges[ticker.uppercased()] ?? direct.todayChangePercent,
                      let contribution = PortfolioMath.dayContribution(marketValue: directUSD, changePercent: change) else { return nil }
                amount += contribution
            }
            for (fund, value) in fundMarketValues where value != 0 {
                guard value.isFinite,
                      let change = dailyChanges[fund] ?? holdings[fund]?.todayChangePercent,
                      let contribution = PortfolioMath.dayContribution(marketValue: value, changePercent: change) else { return nil }
                amount += contribution
            }
            let opening = totalUSD - amount
            guard amount.isFinite, opening > 0 else { return nil }
            return HoldingPerformanceValues(amount: amount, percent: amount / opening * 100)
        }
    }
}
