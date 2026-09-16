import Foundation

/// The figures every screen has to agree on.
///
/// A number the reader compares across two screens — today's move, what a
/// holding cost, how far below its high the portfolio sits — has exactly one
/// implementation here. The same formula written twice drifts: the home page
/// and the 今日 page each carried their own copy of today's contribution and
/// disagreed on a holding that had fallen by more than its value.
///
/// Everything here is pure and returns `nil` rather than a wrong number when
/// the inputs cannot produce one.
enum PortfolioMath {
    /// What the holding was worth at yesterday's close, from its value now and
    /// today's move: `MV / (1 + change/100)`.
    ///
    /// A move of −100% or worse leaves no previous value to divide by — the
    /// holding would have been worth nothing or less — so there is no answer.
    static func previousValue(marketValue: Double, changePercent: Double) -> Double? {
        guard marketValue.isFinite, changePercent.isFinite else { return nil }
        let factor = 1 + changePercent / 100
        guard factor > 0 else { return nil }
        let previous = marketValue / factor
        return previous.isFinite ? previous : nil
    }

    /// The part of a holding's current value that today's move accounts for:
    /// its value now less its value at yesterday's close.
    static func dayContribution(marketValue: Double, changePercent: Double) -> Double? {
        guard let previous = previousValue(marketValue: marketValue, changePercent: changePercent) else {
            return nil
        }
        let amount = marketValue - previous
        return amount.isFinite ? amount : nil
    }

    /// What the reader paid for what they still hold, from the value now and
    /// the gain in it. The ledger's own cost — shares × average cost, in the
    /// position's currency — is the source; this is the same figure read back
    /// out of a presented holding, for a view that has no position to hand.
    static func costBasis(marketValue: Double, unrealized: Double) -> Double? {
        guard marketValue.isFinite, unrealized.isFinite else { return nil }
        let cost = marketValue - unrealized
        return cost.isFinite ? cost : nil
    }

    /// How far a value sits below the high it has reached: zero at the high,
    /// negative below it, as a fraction rather than a percentage.
    static func drawdown(value: Double, peak: Double) -> Double {
        guard value.isFinite, peak.isFinite, peak > 0 else { return 0 }
        let drawdown = value / peak - 1
        return drawdown.isFinite ? min(0, drawdown) : 0
    }

    /// The gain needed to climb back out of a drawdown. A total loss cannot
    /// be recovered, so it has no finite answer.
    static func gainToRecover(drawdown: Double) -> Double {
        guard drawdown.isFinite, drawdown > -1 else { return .infinity }
        return 1 / (1 + drawdown) - 1
    }
}
