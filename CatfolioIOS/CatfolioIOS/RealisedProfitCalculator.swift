import Foundation

/// Realised P/L reaches Catfolio from two sources that must never be added
/// together.
///
/// A broker Result is exact and denominated in the broker's own currency.
/// A locally reconstructed sale is an estimate priced through Catfolio's
/// static rate table. Summing them would push an exact figure through those
/// rates, so the two are reported separately and labelled.
struct RealisedProfitSummary: Equatable {
    /// Exact, broker-reported, kept per currency so nothing is converted.
    var brokerTotals: [String: Decimal] = [:]
    var brokerCount = 0
    /// Sales with no broker Result but a complete imported cost basis.
    var estimatedUSD = 0.0
    var estimatedCount = 0
    /// Sales that could be neither reconciled nor reconstructed.
    var unavailableCount = 0

    var saleCount: Int { brokerCount + estimatedCount + unavailableCount }
}

/// FIFO reconstruction of closed-position profit.
///
/// Trading 212 reports an exact Result per sale, but only for fills whose
/// `walletImpact` the API returns; the rest are backfilled from the activity
/// export one 365-day period per sync. Until that catches up, a sale with a
/// complete imported purchase history can still be priced locally — reporting
/// nothing at all would be strictly less useful than reporting an estimate
/// that says so.
enum RealisedProfitCalculator {

    static func isBuy(_ action: String) -> Bool {
        ["BUY", "BUY_BACK"].contains(normalized(action))
    }

    static func isSell(_ action: String) -> Bool {
        ["SELL", "SELL_SHORT"].contains(normalized(action))
    }

    private static func normalized(_ action: String) -> String {
        action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private struct Lot {
        var quantity: Double
        let costPerShareUSD: Double
    }

    /// Ordering is decided here rather than by the caller: same-day purchases
    /// must settle before same-day sales, otherwise a buy-then-sell on one day
    /// finds no lot to match.
    static func summarize(transactions: [LocalTransactionRecord]) -> RealisedProfitSummary {
        var summary = RealisedProfitSummary()
        var lotsByPosition: [String: [Lot]] = [:]

        let ordered = transactions
            .filter { isBuy($0.action) || isSell($0.action) }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                let leftIsBuy = isBuy($0.action)
                if leftIsBuy != isBuy($1.action) { return leftIsBuy }
                return ($0.tradeID ?? "") < ($1.tradeID ?? "")
            }

        for transaction in ordered {
            let key = "\(transaction.accountKey)|\(transaction.ticker.uppercased())"
            let rate = LocalPortfolioEngine.usdRate(for: transaction.currency)

            if isBuy(transaction.action) {
                // A purchase in an unconvertible currency cannot seed a basis.
                // Dropping the lot leaves later sales short, which reports them
                // as unavailable rather than silently mispricing them.
                guard let rate, rate.isFinite else { continue }
                lotsByPosition[key, default: []].append(Lot(
                    quantity: abs(transaction.quantity),
                    costPerShareUSD: transaction.price * rate
                ))
                continue
            }

            // Every sale consumes lots, broker-reported ones included, so the
            // FIFO position stays correct for the sales that must be rebuilt.
            let saleQuantity = abs(transaction.quantity)
            var remaining = saleQuantity
            var lots = lotsByPosition[key] ?? []
            var matchedCostUSD = 0.0
            while remaining > 0.000_000_1, !lots.isEmpty {
                let matched = min(remaining, lots[0].quantity)
                matchedCostUSD += lots[0].costPerShareUSD * matched
                remaining -= matched
                lots[0].quantity -= matched
                if lots[0].quantity <= 0.000_000_1 { lots.removeFirst() }
            }
            lotsByPosition[key] = lots

            if let decimal = brokerResult(for: transaction) {
                summary.brokerTotals[decimal.currency, default: 0] += decimal.value
                summary.brokerCount += 1
                continue
            }

            // Only price a sale whose every share matched an imported purchase;
            // a partial basis would understate cost and overstate profit.
            let matchedEverything = remaining <= max(0.000_000_1, saleQuantity * 0.000_001)
            guard let rate, rate.isFinite, matchedEverything else {
                summary.unavailableCount += 1
                continue
            }
            let profit = transaction.price * rate * saleQuantity - matchedCostUSD
            guard profit.isFinite else {
                summary.unavailableCount += 1
                continue
            }
            summary.estimatedUSD += profit
            summary.estimatedCount += 1
        }

        return summary
    }

    /// A Result without a well-formed currency is unusable: it cannot be shown
    /// in its own currency and must not be assumed to be USD.
    private static func brokerResult(
        for transaction: LocalTransactionRecord
    ) -> (value: Decimal, currency: String)? {
        guard let raw = transaction.realisedProfitLoss, raw.isFinite else { return nil }
        let currency = transaction.realisedProfitLossCurrency?
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard currency.count == 3,
              currency.utf8.allSatisfy({ (65...90).contains($0) }),
              let decimal = Decimal(
                  string: String(raw),
                  locale: Locale(identifier: "en_US_POSIX")
              ) else { return nil }
        return (decimal, currency)
    }
}
