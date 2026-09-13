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
    /// Broker Results converted to USD at current rates, so they can join a
    /// single total. The per-currency figures above stay unconverted.
    var brokerUSD = 0.0
    /// Broker currencies with no rate available. Their Results are still
    /// reported in `brokerTotals` but cannot enter the combined total.
    var unconvertibleCurrencies: Set<String> = []

    var saleCount: Int { brokerCount + estimatedCount + unavailableCount }

    /// Everything that could be valued, in USD, ready for display in the
    /// user's chosen currency.
    ///
    /// Approximate by construction: profits realised on different dates are
    /// all converted at today's rate, so this will not tie out to the sum of
    /// the broker's own figures unless every sale settled in one currency.
    var combinedUSD: Double { brokerUSD + estimatedUSD }

    /// True when every sale was valued and every currency converted.
    var isComplete: Bool { unavailableCount == 0 && unconvertibleCurrencies.isEmpty }
}

/// One priced disposal.
///
/// Grouping by tax year happens on these, never by slicing the input first:
/// a lot bought in 2019 can settle a sale in 2024, so FIFO has to run across
/// the whole history and the year is decided by the sale's own date.
struct RealisedSale: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Exact, from the broker, in its own currency.
        case broker(value: Decimal, currency: String, usd: Double?)
        /// Reconstructed locally from a complete FIFO basis.
        case estimated(usd: Double)
        /// Neither reconcilable nor reconstructable.
        case unavailable
    }

    let date: String
    let outcome: Outcome
}

/// Which calendar a realised gain is reported against. The UK runs 6 April to
/// 5 April; most elsewhere is the calendar year.
enum TaxYearBasis: String, CaseIterable, Identifiable, Sendable {
    case calendar
    case uk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "日历年"
        case .uk: "英国税年 · 4/6–4/5"
        }
    }

    /// `nil` for an unparsable date rather than a guess.
    func label(for date: String) -> String? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
            return nil
        }
        let (year, month, day) = (parts[0], parts[1], parts[2])
        switch self {
        case .calendar:
            return String(year)
        case .uk:
            // On or after 6 April the year that starts here; before it, the
            // year that started the previous April.
            let start = (month > 4 || (month == 4 && day >= 6)) ? year : year - 1
            return "\(start)/\(String(format: "%02d", (start + 1) % 100))"
        }
    }
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
    /// Folds every disposal into one summary. Unchanged behaviour; the
    /// per-sale detail now comes from `sales(transactions:)`.
    static func summarize(transactions: [LocalTransactionRecord]) -> RealisedProfitSummary {
        summarize(sales: sales(transactions: transactions))
    }

    static func summarize(sales: [RealisedSale]) -> RealisedProfitSummary {
        var summary = RealisedProfitSummary()
        for sale in sales {
            switch sale.outcome {
            case let .broker(value, currency, usd):
                summary.brokerTotals[currency, default: 0] += value
                summary.brokerCount += 1
                if let usd { summary.brokerUSD += usd }
                else { summary.unconvertibleCurrencies.insert(currency) }
            case let .estimated(usd):
                summary.estimatedUSD += usd
                summary.estimatedCount += 1
            case .unavailable:
                summary.unavailableCount += 1
            }
        }
        return summary
    }

    /// Groups by the tax year each sale settled in. Sales whose date cannot be
    /// read are reported separately rather than dropped into an arbitrary year.
    static func summarize(
        transactions: [LocalTransactionRecord], basis: TaxYearBasis
    ) -> [(label: String, summary: RealisedProfitSummary)] {
        let grouped = Dictionary(grouping: sales(transactions: transactions)) {
            basis.label(for: $0.date) ?? "日期无法识别"
        }
        return grouped.keys.sorted(by: >).map { ($0, summarize(sales: grouped[$0] ?? [])) }
    }

    static func sales(transactions: [LocalTransactionRecord]) -> [RealisedSale] {
        var sales: [RealisedSale] = []
        var lotsByPosition: [String: [Lot]] = [:]

        let ordered = transactions
            .filter { isBuy($0.action) || isSell($0.action) }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                let leftIsBuy = isBuy($0.action)
                if leftIsBuy != isBuy($1.action) { return leftIsBuy }
                return ($0.tradeID ?? "") < ($1.tradeID ?? "")
            }

        let catalog = try? StockSplitCatalog.bundled.get()

        for transaction in ordered {
            let key = "\(transaction.accountKey)|\(transaction.ticker.uppercased())"
            let rate = LocalPortfolioEngine.usdRate(for: transaction.currency)

            // Put every row on today's share basis before matching. A purchase
            // of 100 shares that later split 4-for-1 is 400 shares at a quarter
            // the price; a sale made before that split is on the old basis too.
            // Quantity times price is unchanged, so cost basis survives intact.
            let split = catalog?.adjustment(
                ticker: transaction.ticker, from: transaction.date
            ) ?? 1
            let quantity = abs(transaction.quantity) * split
            let price = split > 0 ? transaction.price / split : transaction.price

            if isBuy(transaction.action) {
                // A purchase in an unconvertible currency cannot seed a basis.
                // Dropping the lot leaves later sales short, which reports them
                // as unavailable rather than silently mispricing them.
                guard let rate, rate.isFinite else { continue }
                lotsByPosition[key, default: []].append(Lot(
                    quantity: quantity,
                    costPerShareUSD: price * rate
                ))
                continue
            }

            // Every sale consumes lots, broker-reported ones included, so the
            // FIFO position stays correct for the sales that must be rebuilt.
            let saleQuantity = quantity
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

            if let broker = brokerResult(for: transaction) {
                // Converted separately so the exact per-currency figure is
                // never overwritten by a rate-dependent one.
                let brokerRate = LocalPortfolioEngine.usdRate(for: broker.currency)
                let usd = brokerRate.flatMap { $0.isFinite ? broker.raw * $0 : nil }
                sales.append(RealisedSale(date: transaction.date, outcome: .broker(
                    value: broker.value, currency: broker.currency, usd: usd
                )))
                continue
            }

            // Only price a sale whose every share matched an imported purchase;
            // a partial basis would understate cost and overstate profit.
            let matchedEverything = remaining <= max(0.000_000_1, saleQuantity * 0.000_001)
            guard let rate, rate.isFinite, matchedEverything else {
                sales.append(RealisedSale(date: transaction.date, outcome: .unavailable))
                continue
            }
            let profit = price * rate * saleQuantity - matchedCostUSD
            guard profit.isFinite else {
                sales.append(RealisedSale(date: transaction.date, outcome: .unavailable))
                continue
            }
            sales.append(RealisedSale(date: transaction.date, outcome: .estimated(usd: profit)))
        }

        return sales
    }

    /// A Result without a well-formed currency is unusable: it cannot be shown
    /// in its own currency and must not be assumed to be USD.
    private static func brokerResult(
        for transaction: LocalTransactionRecord
    ) -> (value: Decimal, currency: String, raw: Double)? {
        guard let raw = transaction.realisedProfitLoss, raw.isFinite else { return nil }
        let currency = transaction.realisedProfitLossCurrency?
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard currency.count == 3,
              currency.utf8.allSatisfy({ (65...90).contains($0) }),
              let decimal = Decimal(
                  string: String(raw),
                  locale: Locale(identifier: "en_US_POSIX")
              ) else { return nil }
        return (decimal, currency, raw)
    }
}

/// Reuses the history calculation with the detail page's security/account scope.
struct HoldingDetailRealisedProfitRequest: Equatable {
    let context: HoldingDetailAccountContext?
    let accountKeys: Set<String>

    func summary() -> RealisedProfitSummary? {
        guard let context else { return nil }
        let keys = accountKeys.intersection(context.allAccountKeys)
        guard !keys.isEmpty else { return nil }
        let transactions = (context.document.transactions ?? []).filter {
            keys.contains($0.accountKey)
                && $0.ticker.caseInsensitiveCompare(context.ticker) == .orderedSame
        }
        let sales = RealisedProfitCalculator.sales(transactions: transactions)
        let hasValue = sales.contains { sale in
            switch sale.outcome {
            case let .broker(_, _, usd): return usd?.isFinite == true
            case let .estimated(usd): return usd.isFinite
            case .unavailable: return false
            }
        }
        guard hasValue else { return nil }
        let summary = RealisedProfitCalculator.summarize(sales: sales)
        return summary.combinedUSD.isFinite ? summary : nil
    }
}
