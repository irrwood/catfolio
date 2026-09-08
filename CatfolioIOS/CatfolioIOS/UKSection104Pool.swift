import Foundation

/// The sterling cost of what is still held, and the gain or loss a disposal
/// would produce against it.
///
/// This is the number a UK holder needs and the app has never had. Realised
/// profit here is FIFO in the position's own currency, which answers "how did
/// this investment do". It is not what a disposal is measured against: that
/// is the Section 104 pool, in sterling, at the rates on the days the shares
/// were bought.
///
/// Two things make the two answers differ, often by a lot. Acquisitions
/// matched by the same-day or 30-day rules never enter the pool at all, and a
/// foreign holding's sterling cost moves with the currency — a dollar
/// position can be down in dollars and up in pounds.
///
/// It computes cost and proceeds. It does not compute tax: no rates, no
/// annual exemption, no brought-forward losses, no view on what anyone
/// should do about any of it.
enum UKSection104Pool {

    /// What a disposal produced, in sterling.
    struct Realisation: Sendable {
        let date: String
        let quantity: Double
        let proceeds: Double
        let cost: Double
        /// Positive is a gain, negative an allowable loss.
        var gain: Double { proceeds - cost }
        /// The portion matched to an acquisition rather than drawn from the
        /// pool. A disposal with any of this did not come out of the holding
        /// the way a seller would usually expect.
        let matchedToAcquisitions: Double
    }

    /// The state of a holding after every transaction has been applied.
    struct Position: Sendable {
        /// Shares in the pool, on today's share basis.
        let quantity: Double
        /// What those shares cost, in sterling.
        let cost: Double
        let realisations: [Realisation]
        /// True when every acquisition and disposal priced against a rate
        /// published on its own date. False when at least one carried a rate
        /// back from an earlier day.
        let isExact: Bool

        var costPerShare: Double { quantity > 0 ? cost / quantity : 0 }

        /// Gains and losses already realised, in sterling.
        var realisedGain: Double { realisations.reduce(0) { $0 + $1.gain } }

        /// What a disposal of the whole holding at `price` would produce.
        ///
        /// Sterling in and sterling out: the price is converted at today's
        /// rate, the cost is already at the rates that were paid. The
        /// difference between this and the app's unrealised P&L is the
        /// currency, and that difference is the point.
        func disposalNow(price: Double, rate: Double) -> (proceeds: Double, gain: Double)? {
            guard quantity > 0, rate > 0, price.isFinite else { return nil }
            let proceeds = quantity * price / rate
            return (proceeds, proceeds - cost)
        }

        /// The pool cost this holding would be left with after selling
        /// `quantity` shares.
        ///
        /// Selling to realise a loss does not make the loss go away; it moves
        /// it. The remaining shares keep their share of the old cost, and if
        /// the same shares are bought back the pool is rebuilt at the new,
        /// lower price — so the loss taken now becomes a larger gain later.
        /// Anything presenting a harvest as a saving has to show this too.
        func poolCostAfterSelling(_ sold: Double) -> Double {
            guard quantity > 0, sold > 0 else { return cost }
            return cost * max(0, quantity - sold) / quantity
        }
    }

    /// Walks one security's transactions and returns where it ended up.
    ///
    /// Returns nil when the sterling cost cannot be established — a currency
    /// the rate series does not carry, a trade with no rate available, or a
    /// history that does not reconcile. A partial pool cost would look like a
    /// real one.
    ///
    /// `expectedQuantity` is what the broker says is actually held. Pass it
    /// whenever it is known, because a ledger can be incomplete in a way that
    /// nothing else detects: this app's own Trading 212 sync brought back
    /// 1,977 purchases and no disposals at all, so 49 securities that had
    /// been sold in full still had their entire cost sitting in the pool.
    /// Nothing about those rows is malformed — they are simply not all of the
    /// history, and a pool built from them reports losses in the hundreds of
    /// thousands against a portfolio worth a fraction of that.
    static func position(
        ticker: String,
        transactions: [LocalTransactionRecord],
        rates: GBPFXRates,
        splits: StockSplitCatalog? = nil,
        expectedQuantity: Double? = nil
    ) -> Position? {
        let symbol = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        struct Event {
            let id: String
            let date: String
            let quantity: Double
            /// Sterling, total for the row.
            let amount: Double
            let isBuy: Bool
            let isExact: Bool
        }

        var events: [Event] = []
        for transaction in transactions {
            guard transaction.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == symbol
            else { continue }
            let action = transaction.action.uppercased()
            guard action == "BUY" || action == "SELL" else { continue }

            let split = splits?.adjustment(ticker: transaction.ticker, from: transaction.date) ?? 1
            guard split > 0 else { continue }
            let quantity = abs(transaction.quantity) * split
            let price = transaction.price / split
            guard quantity > 0, price.isFinite else { continue }

            let date = String(transaction.date.prefix(10))
            guard let sterling = rates.sterling(quantity * price, currency: transaction.currency, on: date)
            else { return nil }
            let exact: Bool
            if case .exact = sterling.match { exact = true } else { exact = false }

            events.append(Event(
                id: transaction.id, date: date, quantity: quantity,
                amount: sterling.value, isBuy: action == "BUY", isExact: exact
            ))
        }
        guard !events.isEmpty else { return nil }
        events.sort { $0.date < $1.date }

        let disposals = UKShareMatching.disposals(
            ticker: symbol, transactions: transactions, splits: splits
        )
        let matchesByDisposal = Dictionary(
            uniqueKeysWithValues: disposals.map { ($0.sourceID, $0.matches) }
        )
        let costByAcquisition = Dictionary(
            uniqueKeysWithValues: events.filter(\.isBuy).map {
                ($0.id, $0.quantity > 0 ? $0.amount / $0.quantity : 0)
            }
        )
        // Acquisitions consumed by same-day or 30-day matching are spent
        // against a disposal and never join the pool.
        let matchedQuantities = matchesByDisposal.values.flatMap { $0 }
            .reduce(into: [String: Double]()) { totals, match in
                guard let id = match.acquisitionID else { return }
                totals[id, default: 0] += match.quantity
            }

        var poolQuantity = 0.0
        var poolCost = 0.0
        var realisations: [Realisation] = []
        var isExact = events.allSatisfy(\.isExact)

        for event in events {
            if event.isBuy {
                let unused = max(0, event.quantity - (matchedQuantities[event.id] ?? 0))
                guard unused > 0, event.quantity > 0 else { continue }
                poolQuantity += unused
                poolCost += event.amount * unused / event.quantity
                continue
            }

            let unitProceeds = event.quantity > 0 ? event.amount / event.quantity : 0
            var cost = 0.0
            var matchedQuantity = 0.0
            var fromPool = event.quantity

            for match in matchesByDisposal[event.id] ?? [] {
                guard let id = match.acquisitionID, let unitCost = costByAcquisition[id] else { continue }
                cost += unitCost * match.quantity
                matchedQuantity += match.quantity
                fromPool -= match.quantity
            }

            if fromPool > 0 {
                // The pool is an average, so a part disposal takes its share
                // of the whole cost rather than any particular purchase.
                let taken = min(fromPool, poolQuantity)
                if poolQuantity > 0 {
                    let share = poolCost * taken / poolQuantity
                    cost += share
                    poolCost -= share
                    poolQuantity -= taken
                }
                if taken < fromPool {
                    // Selling more than the ledger says was ever bought. The
                    // history is incomplete, and a cost basis built on it
                    // would be wrong rather than approximate.
                    return nil
                }
            }

            realisations.append(Realisation(
                date: event.date, quantity: event.quantity,
                proceeds: event.amount, cost: cost,
                matchedToAcquisitions: matchedQuantity
            ))
        }

        // The ledger has to agree with the holding it claims to describe.
        // Tolerance is relative because share counts are fractional, and the
        // check is deliberately tight: a pool that is even slightly wrong is
        // wrong by an unknown amount of money.
        if let expectedQuantity {
            let scale = max(abs(expectedQuantity), abs(poolQuantity), 1)
            guard abs(poolQuantity - expectedQuantity) / scale < 0.001 else { return nil }
        }

        if poolQuantity <= 0 { poolCost = 0 }
        if !events.allSatisfy(\.isExact) { isExact = false }
        return Position(
            quantity: poolQuantity, cost: poolCost,
            realisations: realisations, isExact: isExact
        )
    }
}
