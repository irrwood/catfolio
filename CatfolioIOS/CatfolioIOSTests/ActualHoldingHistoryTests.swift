import XCTest
@testable import CatfolioIOS

/// The income-sources history rebuilt from the ledger: each day's own shares.
final class ActualHoldingHistoryTests: XCTestCase {

    private func trade(_ date: String, _ action: String, _ ticker: String, _ quantity: Double, _ price: Double,
                       id: String) -> LocalTransactionRecord {
        LocalTransactionRecord(date: date, action: action, ticker: ticker, quantity: quantity, price: price,
                               currency: "USD", source: "Test", accountID: "A", accountName: "A", tradeID: id)
    }

    private func position(_ ticker: String, shares: Double, cost: Double) -> LocalPositionRecord {
        LocalPositionRecord(ticker: ticker, name: ticker, shares: shares, averageCost: cost, currency: "USD",
                            quotePrice: 10, quoteCurrency: "USD", source: "Test", openedDate: "2024-01-01",
                            accountID: "A", accountName: "A", accountCurrency: "USD", brokerPnl: nil,
                            brokerPnlCurrency: nil, brokerFxPnl: nil, brokerFxPnlCurrency: nil, fxPnl: nil,
                            fxPnlCurrency: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }

    private func build(_ positions: [LocalPositionRecord], _ trades: [LocalTransactionRecord],
                       closes: [String: [String: Double]]) -> HoldingValueHistory {
        let plans = ActualHoldingHistory.plans(positions: positions, transactions: trades, splitAdjustment: { _, _ in 1 })
        return ActualHoldingHistory.build(plans: plans, closes: closes, scales: [:],
                                          usdRate: { $0 == "USD" ? 1 : nil }, splitAdjustment: { _, _ in 1 })
    }

    private let days = ["2024-01-02": 10.0, "2024-02-01": 12.0, "2024-03-01": 15.0]

    func testAPartSoldHoldingIsDrawnAtTheSharesHeldEachDay() throws {
        let history = build([position("A", shares: 4, cost: 10)], [
            trade("2024-01-02", "BUY", "A", 10, 10, id: "1"),
            trade("2024-02-01", "SELL", "A", 6, 12, id: "2"),
        ], closes: ["A": days])
        // 10 shares on the first day, 4 after the sale; what the sale brought
        // in has left the band.
        XCTAssertEqual(history.rows.map { $0.values["A"] ?? 0 }, [100, 48, 60])
        XCTAssertEqual(history.rows.map(\.cost), [100, 40, 40])
        XCTAssertEqual(try XCTUnwrap(history.rows.last).gain("A"), 20, accuracy: 0.0001)
    }

    func testASoldOutSecurityIsThereWhileHeldAndGoneFromItsSale() {
        let history = build([position("A", shares: 10, cost: 10)], [
            trade("2024-01-02", "BUY", "A", 10, 10, id: "1"),
            trade("2024-01-02", "BUY", "B", 10, 10, id: "2"),
            trade("2024-02-01", "SELL", "B", 10, 12, id: "3"),
        ], closes: ["A": days, "B": days])
        XCTAssertEqual(history.rows.map { $0.values["B"] }, [100, nil, nil])
        XCTAssertEqual(history.rows.map { $0.values["A"] ?? 0 }, [100, 120, 150])
        XCTAssertEqual(history.rows.map(\.cost), [200, 100, 100])
    }

    func testAPositionTheLedgerCannotAccountForKeepsTodaysShares() {
        // Ten shares held, the ledger knows of three: moved in from elsewhere.
        let history = build([position("C", shares: 10, cost: 10)], [
            trade("2024-01-02", "BUY", "C", 3, 10, id: "1"),
        ], closes: ["C": days])
        XCTAssertEqual(history.rows.map { $0.values["C"] ?? 0 }, [100, 120, 150])
    }
}
