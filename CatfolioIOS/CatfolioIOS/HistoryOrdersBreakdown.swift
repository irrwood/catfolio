import Foundation

/// Presentation indexes over already-priced sales. FIFO still runs once over
/// the full account history, before the year and security filters are applied.
struct HistoryOrdersBreakdown {
    struct Row: Identifiable {
        let ticker: String
        let name: String
        let calculation: RealisedProfitSummary
        let dates: [ActivityDateGroup]
        var id: String { ticker }
        var orderCount: Int { dates.reduce(0) { $0 + $1.activities.count } }
        var amountUSD: Double? {
            guard calculation.saleCount > 0, calculation.isComplete,
                  calculation.combinedUSD.isFinite else { return nil }
            return calculation.combinedUSD
        }
    }

    var rows: [Row] = []
    var magnitudeUSD: Double = 0
    var isComplete = true
    var hasLosses: Bool { rows.contains { ($0.amountUSD ?? 0) < 0 } }

    func share(for row: Row) -> Double? {
        guard isComplete, magnitudeUSD.isFinite, magnitudeUSD > 0,
              let amount = row.amountUSD else { return nil }
        return min(1, max(0, abs(amount) / magnitudeUSD))
    }

    static func build(_ activities: [PortfolioActivity], sales: [String: RealisedSale],
                      dateTitles: [String: String]) -> Self {
        let orders = activities.filter { $0.kind == .buy || $0.kind == .sell }
        let groups = Dictionary(grouping: orders) {
            $0.transaction.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        let rows = groups.map { ticker, entries in
            let priced = entries.filter { $0.kind == .sell }.map { activity in
                sales[activity.transaction.id] ?? RealisedSale(date: activity.transaction.date,
                    outcome: .unavailable, transactionID: activity.transaction.id)
            }
            let byDate = Dictionary(grouping: entries) { $0.transaction.date }
            let dates = byDate.keys.sorted(by: >).map { date in
                ActivityDateGroup(id: date, title: dateTitles[date] ?? date,
                                  activities: (byDate[date] ?? []).sorted { $0.id > $1.id })
            }
            return Row(ticker: ticker, name: entries.first?.displayTitle ?? ticker,
                       calculation: RealisedProfitCalculator.summarize(sales: priced), dates: dates)
        }.sorted {
            let a = abs($0.amountUSD ?? 0), b = abs($1.amountUSD ?? 0)
            return a == b ? $0.ticker < $1.ticker : a > b
        }
        let magnitude = rows.reduce(0) { $0 + abs($1.amountUSD ?? 0) }
        return Self(rows: rows, magnitudeUSD: magnitude,
                    isComplete: magnitude.isFinite && rows.allSatisfy {
                        $0.calculation.isComplete && $0.calculation.combinedUSD.isFinite
                    })
    }
}
