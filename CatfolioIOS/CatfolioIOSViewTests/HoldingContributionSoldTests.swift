import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

/// 收益来源 with 包含已卖出 on: a security sold outright is in the chart while
/// it is held and has no share of it from the day of the sale.
@MainActor
final class HoldingContributionSoldTests: XCTestCase {
    private func trade(_ date: String, _ action: String, _ ticker: String, _ quantity: Double, _ price: Double,
                       id: String) -> LocalTransactionRecord {
        LocalTransactionRecord(date: date, action: action, ticker: ticker, quantity: quantity, price: price,
                               currency: "USD", source: "Test", accountID: "A", accountName: "A", tradeID: id)
    }

    private func position(_ ticker: String, shares: Double, cost: Double) -> LocalPositionRecord {
        LocalPositionRecord(ticker: ticker, name: ticker, shares: shares, averageCost: cost, currency: "USD",
                            quotePrice: 100, quoteCurrency: "USD", source: "Test", openedDate: "2026-01-05",
                            accountID: "A", accountName: "A", accountCurrency: "USD", brokerPnl: nil,
                            brokerPnlCurrency: nil, brokerFxPnl: nil, brokerFxPnlCurrency: nil, fxPnl: nil,
                            fxPnlCurrency: nil, fxPnlStatus: nil, fxPnlSource: nil)
    }

    /// A held all along; B bought with it, rising, and sold outright at the
    /// fortieth day.
    private func history() -> HoldingValueHistory {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = DayDateCodec.date(from: "2026-01-05")!
        let days = (0..<60).map { DayDateCodec.string(from: calendar.date(byAdding: .day, value: $0, to: start)!) }
        let closesA = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element, 100 + Double($0.offset)) })
        let closesB = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($0.element, 100 + 2 * Double($0.offset)) })
        let plans = ActualHoldingHistory.plans(positions: [position("A", shares: 50, cost: 100)], transactions: [
            trade(days[0], "BUY", "A", 50, 100, id: "1"),
            trade(days[0], "BUY", "B", 50, 100, id: "2"),
            trade(days[40], "SELL", "B", 50, closesB[days[40]]!, id: "3"),
        ], splitAdjustment: { _, _ in 1 })
        return ActualHoldingHistory.build(plans: plans, closes: ["A": closesA, "B": closesB], scales: [:],
                                          usdRate: { $0 == "USD" ? 1 : nil }, splitAdjustment: { _, _ in 1 })
    }

    func testASoldSecurityHasNoShareFromItsSale() {
        let history = history()
        let rows = history.rows
        XCTAssertEqual(rows[39].gain("B"), 50 * 78, accuracy: 0.001, "Held: its gain is in the chart")
        XCTAssertEqual(rows[40].gain("B"), 0, "Sold: nothing of it is left")
        XCTAssertNil(rows[59].values["B"])
        XCTAssertEqual(rows[39].cost, 10_000, accuracy: 0.001)
        XCTAssertEqual(rows[40].cost, 5_000, accuracy: 0.001, "Its cost leaves the principal with it")

        // The stack is everything held that day: A and B before the sale,
        // A alone from it.
        let stack = HoldingContributionStack(history: history)
        XCTAssertEqual(stack.rows[39].bands.reduce(0, +), 50 * 139 + 50 * 178, accuracy: 0.001)
        XCTAssertEqual(stack.rows[40].bands.reduce(0, +), 50 * 140, accuracy: 0.001)
    }

    func testCaptureTheChartAcrossTheSale() async throws {
        let history = history()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack {
            HoldingContributionChart(fetchHistory: { _ in history })
                .navigationTitle(L10n.text("收益来源"))
                .navigationBarTitleDisplayMode(.inline)
        }
        .environment(AppModel())
        .preferredColorScheme(.dark))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(1500))
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "gain-sources-sold"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
