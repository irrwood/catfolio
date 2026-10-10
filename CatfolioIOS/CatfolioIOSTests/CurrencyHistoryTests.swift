import XCTest
@testable import CatfolioIOS

/// The home figures in a pound reader's currency: each day of the chart at
/// that day's rate, and the day's figures with what the rate did folded in,
/// so the chart's 1D and the Today card count the same thing.
final class CurrencyHistoryTests: XCTestCase {
    private let pound = CurrencyHistory(currency: "GBP", closes: [
        "2026-10-01": 1.30, "2026-10-02": 1.35,
    ])

    func testARateCarriesForwardAndTheDollarIsFlat() {
        XCTAssertEqual(pound.rate(on: "2026-10-02"), 1.35)
        XCTAssertEqual(pound.rate(on: "2026-10-04"), 1.35, "A weekend reads the last close")
        XCTAssertEqual(pound.rate(on: "2026-09-01"), 1.30, "Before the history, its first close")
        XCTAssertEqual(CurrencyHistory(currency: "USD", closes: [:]).rate(on: "2026-10-01"), 1)
        XCTAssertEqual(CurrencyHistory(currency: "GBX", closes: [:]).currency, "GBP")
    }

    /// $1,300 of US shares that never move, bought with £1,000 when the
    /// pound was at $1.30. As the pound rises to $1.40 the reader has lost
    /// money in pounds, and the pound they paid in is still one pound.
    func testTheChartReadsEachDayAtItsOwnRateAndKeepsDepositsInPounds() throws {
        let rows = ["2026-10-01", "2026-10-02", "2026-10-03"].map {
            ChartPoint(dateText: $0, marketValue: 1_300, cost: 1_300)
        }
        let chart = PortfolioChartResponse(positionCount: 1,
            positionHistory: PositionHistory(available: true, rows: rows), currentPoint: rows[2],
            warning: nil, accountNAV: ["2026-10-01": 1, "2026-10-02": 1, "2026-10-03": 1])
        let rebased = chart.rebased(to: pound, current: 1.40, today: "2026-10-03")
        let pounds = rebased.positionHistory.rows.map { $0.marketValue / 1.40 }
        XCTAssertEqual(pounds[0], 1_000, accuracy: 0.001)
        XCTAssertEqual(pounds[1], 1_300 / 1.35, accuracy: 0.001)
        XCTAssertEqual(pounds[2], 1_300 / 1.40, accuracy: 0.001, "Today reads at the rate shown everywhere")
        for row in rebased.positionHistory.rows {
            XCTAssertEqual(row.cost / 1.40, 1_000, accuracy: 0.001)
        }
        XCTAssertEqual(rebased.currentPoint, rebased.positionHistory.rows[2])
        let performance = rebased.accountPerformance(from: "2026-10-01", to: "2026-10-03")
        XCTAssertEqual(performance.amount / 1.40, 1_300 / 1.40 - 1_000, accuracy: 0.001)
        XCTAssertEqual(performance.percentage, (1.30 / 1.40 - 1) * 100, accuracy: 0.001)

        let dollars = chart.rebased(to: CurrencyHistory(currency: "USD", closes: [:]), current: 1, today: "2026-10-03")
        XCTAssertEqual(dollars.positionHistory.rows, chart.positionHistory.rows, "A dollar reader's chart is as it was")
    }

    func testTheRateMovesAHoldingByItsCurrencyAgainstTheReaders() throws {
        let moves = CurrencyDayMoves(since: "2026-10-02", display: pound,
            others: ["EUR": CurrencyHistory(currency: "EUR", closes: ["2026-10-02": 1.10])],
            now: ["GBP": 1.40, "EUR": 1.12])
        XCTAssertEqual(try XCTUnwrap(moves.factor(for: "USD")), 1.35 / 1.40, accuracy: 1e-9,
                       "A stronger pound takes from US shares")
        XCTAssertEqual(moves.factor(for: "GBP"), 1)
        XCTAssertEqual(moves.factor(for: "GBX"), 1, "London shares in pence move with the pound")
        XCTAssertEqual(try XCTUnwrap(moves.factor(for: "EUR")), (1.12 / 1.40) / (1.10 / 1.35), accuracy: 1e-9)
        XCTAssertNil(moves.factor(for: "JPY"), "No history, no guess")
        XCTAssertEqual(moves.change(2, currency: "JPY"), 2)
    }

    /// Ten US shares from $100 to $102 and a hundred London shares from £10
    /// to £10.10, while the pound goes from $1.35 to $1.40: the chart's 1D
    /// and the Today card's total come to the same amount.
    func testTheChartsDayAndTheTodayCardAgree() throws {
        let rows = [
            ChartPoint(dateText: "2026-10-02", marketValue: 10 * 100 + 100 * 10 * 1.35, cost: 2_000),
            ChartPoint(dateText: "2026-10-05", marketValue: 10 * 102 + 100 * 10.1 * 1.40, cost: 2_000),
        ]
        var chart = PortfolioChartResponse(positionCount: 2,
            positionHistory: PositionHistory(available: true, rows: rows), currentPoint: rows[1],
            warning: nil, accountNAV: ["2026-10-02": 1, "2026-10-05": 1.01])
        chart.marketDates = ["2026-10-02", "2026-10-05"]
        let rebased = chart.rebased(to: pound, current: 1.40, today: "2026-10-05")
        let chartDay = rebased.accountPerformance(from: "2026-10-02", to: "2026-10-05").amount

        let moves = CurrencyDayMoves(since: "2026-10-02", display: pound, others: [:], now: ["GBP": 1.40])
        let card = try [(value: 10 * 102.0, change: 2.0, currency: "USD"),
                        (value: 100 * 10.1 * 1.40, change: 1.0, currency: "GBX")].map { holding in
            try XCTUnwrap(PortfolioMath.dayContribution(marketValue: holding.value,
                changePercent: moves.change(holding.change, currency: holding.currency)))
        }.reduce(0, +)
        XCTAssertEqual(card, chartDay, accuracy: 1e-6)
        XCTAssertLessThan(card, 0, "The pound's rise outweighs both prices")
    }

    /// Ten in the morning in London: VUSA has traded today, New York has not
    /// opened. The day's figure for the US shares is what the pound did since
    /// last night's close — not their move of the day before — and the chart's
    /// 1D says the same.
    @MainActor
    func testAMarketNotYetOpenAddsOnlyWhatTheRateDid() throws {
        let us = ["2026-10-06": 100.0, "2026-10-07": 102.0]
        let london = ["2026-10-06": 10.0, "2026-10-07": 10.0, "2026-10-08": 10.1]
        XCTAssertEqual(try XCTUnwrap(AppModel.change(in: us, since: "2026-10-07")), 0, "Not traded since")
        XCTAssertEqual(try XCTUnwrap(AppModel.change(in: us, since: "2026-10-06")), 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(AppModel.change(in: london, since: "2026-10-07")), 1, accuracy: 1e-9)
        XCTAssertNil(AppModel.change(in: us, since: "2026-10-01"), "Nothing to read from before the closes")

        let pound = CurrencyHistory(currency: "GBP", closes: ["2026-10-07": 1.35])
        let rows = [
            ChartPoint(dateText: "2026-10-07", marketValue: 10 * 102 + 100 * 10 * 1.35, cost: 2_000),
            ChartPoint(dateText: "2026-10-08", marketValue: 10 * 102 + 100 * 10.1 * 1.40, cost: 2_000),
        ]
        var chart = PortfolioChartResponse(positionCount: 2,
            positionHistory: PositionHistory(available: true, rows: rows), currentPoint: rows[1],
            warning: nil, accountNAV: ["2026-10-07": 1, "2026-10-08": 1.01])
        chart.marketDates = ["2026-10-07", "2026-10-08"]
        let chartDay = chart.rebased(to: pound, current: 1.40, today: "2026-10-08")
            .accountPerformance(from: "2026-10-07", to: "2026-10-08").amount
        let moves = CurrencyDayMoves(since: "2026-10-07", display: pound, others: [:], now: ["GBP": 1.40])
        let holdings: [(value: Double, closes: [String: Double], currency: String)] = [
            (10 * 102, us, "USD"), (100 * 10.1 * 1.40, london, "GBP"),
        ]
        var card = 0.0
        for holding in holdings {
            let change = try XCTUnwrap(AppModel.change(in: holding.closes, since: "2026-10-07"))
            card += try XCTUnwrap(PortfolioMath.dayContribution(marketValue: holding.value,
                changePercent: moves.change(change, currency: holding.currency)))
        }
        XCTAssertEqual(card, chartDay, accuracy: 1e-6)
    }
}
