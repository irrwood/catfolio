import Foundation

extension PortfolioChartResponse {
    /// The entire chart's cash gain, independent of any selected range, TWR
    /// or MWR. Account history already includes sales, dividends and cash:
    /// subtract net external deposits once, without dividing by a potentially
    /// tiny balance after withdrawals or adding booked income again.
    var allTimeProfitUSD: Double? {
        guard !currentPoint.dateText.isEmpty,
              currentPoint.marketValue.isFinite, currentPoint.cost.isFinite else { return nil }
        if let accountNAV {
            guard let nav = accountNAV[currentPoint.dateText], nav.isFinite, nav >= 0 else { return nil }
        } else {
            // A current-holdings placeholder has no lifetime history. Sample
            // and disclosure portfolios use their existing full-history
            // value/cost chart, the same basis as its All range.
            guard positionHistory.available, !positionHistory.rows.isEmpty else { return nil }
        }
        let amount = currentPoint.marketValue - currentPoint.cost
        return amount.isFinite ? amount : nil
    }
}
