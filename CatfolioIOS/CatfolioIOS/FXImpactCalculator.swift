import Foundation

/// How much of a position's gain is the currency rather than the price.
///
/// Every position in this ledger reported no FX component at all: brokers
/// supply one only on some fills, and across 1,977 transactions not a single
/// one carried a rate. So the row read "—" on every holding, for every user
/// whose broker does the same.
///
/// The figure is reconstructed instead, from the trade dates already in the
/// ledger and a published daily rate series.
enum FXImpactCalculator {

    /// What the currency did to the money that is still invested.
    struct Result: Sendable {
        /// Signed sterling amount: a quote-currency cost divided by GBP_TO_QUOTE.
        let amount: Double
        let currency = "GBP"
        /// Remaining cost in the position's quote currency (not sterling).
        let cost: Double
        /// True when every open lot matched a rate published on its own trade
        /// date. False when at least one had to carry a rate back from an
        /// earlier day — a weekend fill, a dated dividend reinvestment.
        let isExact: Bool
    }

    /// A buy that has not been sold yet, after FIFO matching.
    fileprivate struct OpenLot {
        let quantity: Double
        let price: Double
        let currency: String
        let date: String
    }

    /// Open lots for a ledger, prepared once for all of its holdings. A
    /// presentation can ask for many tickers without repeatedly scanning and
    /// sorting the complete transaction history.
    struct PreparedTransactions {
        fileprivate let lotsByTicker: [String: [OpenLot]]
    }

    private struct LotQueue {
        var lots: [OpenLot] = []
        var firstOpenIndex = 0

        mutating func sell(_ quantity: Double) {
            var remaining = quantity
            while remaining > 0, firstOpenIndex < lots.count {
                let first = lots[firstOpenIndex]
                if first.quantity > remaining {
                    lots[firstOpenIndex] = OpenLot(
                        quantity: first.quantity - remaining,
                        price: first.price,
                        currency: first.currency,
                        date: first.date
                    )
                    remaining = 0
                } else {
                    remaining -= first.quantity
                    firstOpenIndex += 1
                }
            }
        }

        var remainingLots: [OpenLot] { Array(lots.dropFirst(firstOpenIndex)) }
    }

    static func prepare(
        transactions: [LocalTransactionRecord],
        tickers: Set<String>? = nil,
        splits: StockSplitCatalog? = nil
    ) -> PreparedTransactions {
        let selected = tickers.map { Set($0.map(normalized)) }
        var byTicker: [String: [LocalTransactionRecord]] = [:]
        for transaction in transactions {
            let symbol = normalized(transaction.ticker)
            guard selected?.contains(symbol) ?? true else { continue }
            byTicker[symbol, default: []].append(transaction)
        }
        return PreparedTransactions(lotsByTicker: byTicker.mapValues {
            openLots(transactions: $0, splits: splits)
        })
    }

    /// FX impact on the lots still held.
    ///
    /// The decomposition is the one brokers report: value the position's
    /// remaining cost at the rate on each purchase date, value the same cost
    /// at today's rate, and the difference is what the currency did. The
    /// price component is deliberately not part of it — that is what
    /// unrealised P&L already says.
    ///
    ///     fx  =  Σ costᵢ × (1/rate_now − 1/rateᵢ)
    ///
    /// Returns nil rather than zero when the answer is unknowable: an
    /// uncovered currency, or no rate for the current day. A sterling-quoted
    /// position returns zero, which is a fact rather than a gap.
    static func impact(
        ticker: String,
        transactions: [LocalTransactionRecord],
        rates: GBPFXRates,
        asOf: Date = Date(),
        splits: StockSplitCatalog? = nil
    ) -> Result? {
        let symbol = normalized(ticker)
        let rows = transactions.filter { normalized($0.ticker) == symbol }
        return impact(openLots: openLots(transactions: rows, splits: splits), rates: rates, asOf: asOf)
    }

    static func impact(
        ticker: String,
        prepared: PreparedTransactions,
        rates: GBPFXRates,
        asOf: Date = Date()
    ) -> Result? {
        impact(openLots: prepared.lotsByTicker[normalized(ticker)] ?? [], rates: rates, asOf: asOf)
    }

    private static func impact(openLots lots: [OpenLot], rates: GBPFXRates, asOf: Date) -> Result? {
        guard !lots.isEmpty else { return nil }

        // Mixed-currency lots on one ticker would need a separate answer per
        // currency; the row has room for one number, so it stays silent.
        let currencies = Set(lots.map { $0.currency.uppercased() })
        guard currencies.count == 1, let currency = currencies.first else { return nil }
        if currency == "GBP" || currency == "GBX" {
            let cost = lots.reduce(0) { $0 + $1.quantity * $1.price }
            return Result(amount: 0, cost: cost, isExact: true)
        }

        let today = DayDateFormatter.shared.string(from: asOf)
        guard let now = rates.quote(currency: currency, on: today),
              now.rate > 0 else { return nil }

        var amount = 0.0
        var cost = 0.0
        var isExact = now.match == .exact
        for lot in lots {
            guard let then = rates.quote(currency: lot.currency, on: lot.date), then.rate > 0 else {
                // One unpriceable lot makes the total wrong by an unknown
                // amount, so the whole figure is withheld.
                return nil
            }
            if case .carriedForward = then.match { isExact = false }
            let lotCost = lot.quantity * lot.price
            cost += lotCost
            amount += lotCost * (1 / now.rate - 1 / then.rate)
        }
        return Result(amount: amount, cost: cost, isExact: isExact)
    }

    private static func normalized(_ ticker: String) -> String {
        ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Buys still open after sells are matched against them, oldest first.
    ///
    /// FIFO, matching the app's realised-profit engine. It is not the UK's
    /// tax matching, and is not used for tax anywhere — this is a display
    /// figure about the money currently invested.
    private static func openLots(
        transactions: [LocalTransactionRecord],
        splits: StockSplitCatalog?
    ) -> [OpenLot] {
        let ordered = LocalTransactionRecord.orderedForLotMatching(transactions)

        var byAccount: [String: LotQueue] = [:]
        for transaction in ordered {
            let key = "\(transaction.accountKey)|\(transaction.currency.uppercased())"
            let split = splits?.adjustment(ticker: transaction.ticker, from: transaction.date) ?? 1
            guard split > 0 else { continue }
            let quantity = abs(transaction.quantity) * split
            let price = transaction.price / split
            guard quantity > 0, price.isFinite else { continue }

            switch transaction.action.uppercased() {
            case "BUY":
                byAccount[key, default: LotQueue()].lots.append(OpenLot(
                    quantity: quantity,
                    price: price,
                    currency: transaction.currency,
                    date: String(transaction.date.prefix(10))
                ))
            case "SELL":
                byAccount[key, default: LotQueue()].sell(quantity)
            default:
                continue
            }
        }
        return byAccount.keys.sorted().flatMap { byAccount[$0]?.remainingLots ?? [] }
    }
}
