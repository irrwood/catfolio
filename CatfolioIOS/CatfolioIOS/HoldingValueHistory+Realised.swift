import Foundation

extension HoldingValueHistory {
    /// One sale's realised result, in USD, on the day it was made.
    struct RealisedSale: Equatable, Sendable {
        let ticker: String
        let date: String
        let usd: Double
    }

    /// The history with what has been sold put back in: each sale's realised
    /// result is added to its security's value from the sale's day on.
    ///
    /// The history itself is today's holdings only, so a security sold
    /// outright was missing from it altogether and a part-sold one carried
    /// none of what its sold shares made. Here a security still held gains its
    /// realised result on top of its own; one no longer held becomes a holding
    /// of its own, worth its realised result at no cost, ranked by it like any
    /// other. The principal stays the cost of what is held now.
    func includingRealised(_ sales: [RealisedSale], names extraNames: [String: String] = [:]) -> HoldingValueHistory {
        let ordered = sales.filter { $0.usd.isFinite }.sorted { $0.date < $1.date }
        guard !ordered.isEmpty, !rows.isEmpty else { return self }
        var realised: [String: Double] = [:]
        var next = 0
        let merged = rows.map { row -> Row in
            while next < ordered.count, ordered[next].date <= row.dateText {
                realised[ordered[next].ticker.uppercased(), default: 0] += ordered[next].usd
                next += 1
            }
            guard !realised.isEmpty else { return row }
            var values = row.values
            var costs = row.costs
            for (ticker, amount) in realised {
                if let held = values[ticker] {
                    // Its own gain is kept: the cost stands where it was.
                    if costs[ticker] == nil { costs[ticker] = held }
                    values[ticker] = held + amount
                } else {
                    values[ticker] = amount
                    costs[ticker] = 0
                }
            }
            return Row(dateText: row.dateText, cost: row.cost, values: values, costs: costs)
        }
        var allCosts = costs
        for ticker in realised.keys where allCosts[ticker] == nil { allCosts[ticker] = 0 }
        var allNames = names
        for (ticker, name) in extraNames where allNames[ticker.uppercased()] == nil {
            allNames[ticker.uppercased()] = name
        }
        return HoldingValueHistory(rows: merged, costs: allCosts, names: allNames)
    }
}
