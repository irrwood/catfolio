import Foundation

/// Whether the transaction history adds up to the holdings it claims to explain.
///
/// A ledger can be incomplete without any single row being wrong, and nothing
/// else in the app notices. This one had 1,977 purchases and no disposals at
/// all — every row well formed, 49 securities sold in full still carrying
/// their whole cost, and no indication anywhere on screen.
///
/// It only became visible when the Section 104 pool reported £272,000 of
/// losses against a £94,000 portfolio. That is far too late: by then the
/// number is in front of someone who might act on it.
///
/// So the check runs on its own and says what it found, whether or not
/// anything is currently asking the ledger a question.
enum LedgerReconciliation {

    struct Mismatch: Equatable, Sendable {
        let ticker: String
        /// Net shares the ledger accounts for, on today's share basis.
        let ledger: Double
        /// Shares actually held.
        let held: Double

        /// Bought and never disposed of in the ledger, yet nothing is held.
        /// The disposals are missing rather than merely inconsistent.
        var isFullyDisposed: Bool { held <= 0 && ledger > 0 }
    }

    struct Report: Equatable, Sendable {
        let transactionCount: Int
        let securities: Int
        let mismatches: [Mismatch]

        var reconciles: Bool { mismatches.isEmpty }
        var fullyDisposed: Int { mismatches.filter(\.isFullyDisposed).count }

        /// True when the ledger accounts for more shares than are held, which
        /// is what missing disposals look like. The opposite — holding more
        /// than the ledger explains — is a missing acquisition, and says so
        /// separately because the remedy is the same but the reading is not.
        var hasUnexplainedDisposals: Bool {
            mismatches.contains { $0.ledger > $0.held }
        }

        var hasUnexplainedHoldings: Bool {
            mismatches.contains { $0.held > $0.ledger }
        }
    }

    /// Compares net ledger quantity against shares held, per security.
    ///
    /// Share counts are normalised for splits first, so a ten-for-one that
    /// the ledger records at the old basis is not mistaken for a discrepancy.
    /// Only trades count: dividends, interest and transfers move money rather
    /// than shares.
    static func report(
        transactions: [LocalTransactionRecord],
        holdings: [(ticker: String, shares: Double)],
        splits: StockSplitCatalog? = nil
    ) -> Report {
        var ledger: [String: Double] = [:]
        for transaction in transactions {
            let action = transaction.action.uppercased()
            guard action == "BUY" || action == "SELL" else { continue }
            let split = splits?.adjustment(ticker: transaction.ticker, from: transaction.date) ?? 1
            guard split > 0 else { continue }
            let quantity = abs(transaction.quantity) * split
            let ticker = transaction.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            ledger[ticker, default: 0] += action == "BUY" ? quantity : -quantity
        }

        // Held across every account: one security in two accounts is one
        // position as far as its transaction history is concerned.
        var held: [String: Double] = [:]
        for holding in holdings {
            let ticker = holding.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            held[ticker, default: 0] += holding.shares
        }

        let mismatches = Set(ledger.keys).union(held.keys).compactMap { ticker -> Mismatch? in
            let ledgerQuantity = ledger[ticker] ?? 0
            let heldQuantity = held[ticker] ?? 0
            // Relative, because share counts are routinely fractional, and
            // tight, because a real disposal is never a rounding difference.
            let scale = max(abs(ledgerQuantity), abs(heldQuantity), 1)
            guard abs(ledgerQuantity - heldQuantity) / scale >= 0.001 else { return nil }
            return Mismatch(ticker: ticker, ledger: ledgerQuantity, held: heldQuantity)
        }.sorted { ($0.ledger - $0.held, $0.ticker) > ($1.ledger - $1.held, $1.ticker) }

        return Report(
            transactionCount: transactions.count,
            securities: Set(ledger.keys).union(held.keys).count,
            mismatches: mismatches
        )
    }
}
