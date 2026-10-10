import Foundation

/// All's booked result: the existing realised P/L plus net cash dividends.
/// Both components have already been scoped to the same accounts and year.
struct HistoryIncomeSummary {
    let realised: RealisedProfitSummary
    let dividendsUSD: Double
    let dividendCount: Int
    let dividendsComplete: Bool

    private var hasValuedSales: Bool {
        realised.estimatedCount > 0 || (realised.brokerCount > 0 &&
            (realised.unconvertibleCurrencies.isEmpty || realised.brokerTotals.keys.contains {
                !realised.unconvertibleCurrencies.contains($0)
            }))
    }

    var amountUSD: Double? {
        guard dividendsComplete, dividendsUSD.isFinite, realised.combinedUSD.isFinite,
              dividendCount > 0 || hasValuedSales else { return nil }
        let amount = realised.combinedUSD + dividendsUSD
        return amount.isFinite ? amount : nil
    }

    var isComplete: Bool {
        realised.isComplete && dividendsComplete && dividendsUSD.isFinite && realised.combinedUSD.isFinite
            && (realised.combinedUSD + dividendsUSD).isFinite
    }
}

extension HistoryPreparedLedger {
    func incomeSummary(basis: TaxYearBasis, year: String?) -> HistoryIncomeSummary {
        let realised = year.map { year in
            realisedByTaxYear[basis]?.first { $0.label == year }?.summary ?? RealisedProfitSummary()
        } ?? realisedTotal
        let dividends = page(category: .dividends, basis: basis, year: year)
        return HistoryIncomeSummary(realised: realised, dividendsUSD: dividends.totalUSD,
            dividendCount: dividends.activities.count, dividendsComplete: dividends.dividendBreakdown.isComplete)
    }
}
