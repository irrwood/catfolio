import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class HoldingContributionPreparedCacheTests: XCTestCase {
    private func history(latestA: Double = 150) -> HoldingValueHistory {
        let costs = ["A": 100.0, "B": 100.0]
        return HoldingValueHistory(rows: [
            .init(dateText: "2026-09-21", cost: 200,
                  values: ["A": 100, "B": 100], costs: costs),
            .init(dateText: "2026-09-22", cost: 200,
                  values: ["A": 130, "B": 90], costs: costs),
            .init(dateText: "2026-09-23", cost: 200,
                  values: ["A": latestA, "B": 120], costs: costs),
        ], costs: costs, names: ["A": "Alpha", "B": "Beta"])
    }

    private func holding(name: String) -> Holding {
        Holding(ticker: "A", logoSymbol: nil, displayName: name, sector: nil,
                source: "test", shares: 1, averageCost: 100, costCurrency: "USD",
                quotePrice: 150, quoteCurrency: "USD", todayChangePercent: nil,
                marketValue: 150, weight: 0.5, unrealized: 50,
                unrealizedPercent: 50, fxPnl: nil, fxPnlPercent: nil,
                fxPnlStatus: nil, fxPnlSource: nil)
    }

    func testSelectionReusesStackWindowAndSeriesWhileInputsInvalidateCorrectLayer() throws {
        let cache = HoldingContributionPreparedCache()
        let source = history()
        func prepare(history: HoldingValueHistory = source, revision: Int = 1,
                     holdings: [Holding] = [], hidden: Set<String> = [],
                     locale: Locale = Locale(identifier: "en_GB"), language: String = "en",
                     range: ChartTimeRange = .maximum, principal: Bool = false,
                     others: Bool = true, scheme: ColorScheme = .light)
            -> HoldingContributionPreparedCache.Prepared {
            cache.prepared(history: history, historyRevision: revision, holdings: holdings,
                           hiding: hidden, locale: locale, language: language,
                           range: range, showsPrincipal: principal, showsOthers: others,
                           scheme: scheme)
        }

        let initial = prepare()
        XCTAssertEqual(cache.stackRebuildCount, 1)
        XCTAssertEqual(cache.plotRebuildCount, 1)
        XCTAssertEqual(initial.series.map(\.id), ["band-A", "band-B", "band-others"])
        XCTAssertEqual(initial.series.first?.points.map(\.value), [0, 30, 70])
        XCTAssertEqual(initial.window.rows.last?.total, 270)

        // A drag supplies one of the interaction dates. Its changing value is
        // absent from the cache key, but the header still reads the right row.
        for date in initial.interactionDates {
            let reused = prepare()
            XCTAssertEqual(reused.window.row(nearest: date)?.date, date)
        }
        XCTAssertEqual(cache.stackRebuildCount, 1)
        XCTAssertEqual(cache.plotRebuildCount, 1)

        _ = prepare(range: .oneMonth)
        XCTAssertEqual(cache.stackRebuildCount, 1)
        XCTAssertEqual(cache.plotRebuildCount, 2)
        let withPrincipal = prepare(principal: true)
        XCTAssertEqual(cache.plotRebuildCount, 3)
        XCTAssertEqual(withPrincipal.series.last?.id, "principal")
        XCTAssertEqual(withPrincipal.series.first?.points.last?.value, 270)
        _ = prepare(others: false)
        XCTAssertEqual(cache.plotRebuildCount, 4)
        _ = prepare(scheme: .dark)
        XCTAssertEqual(cache.plotRebuildCount, 5)

        let hidden = prepare(hidden: ["A"])
        XCTAssertEqual(cache.stackRebuildCount, 2)
        XCTAssertEqual(hidden.stack.hidden.map(\.ticker), ["A"])
        XCTAssertFalse(hidden.series.map(\.id).contains("band-A"))
        XCTAssertEqual(hidden.window.rows.last?.total, 270,
                       "Visibility must not change the header total")

        _ = prepare(holdings: [holding(name: "A first name")])
        let renamed = prepare(holdings: [holding(name: "A new name")])
        XCTAssertEqual(renamed.stack.bands.last?.subtitle, "A new name")
        XCTAssertEqual(cache.stackRebuildCount, 4)
        _ = prepare(locale: Locale(identifier: "en_US"))
        _ = prepare(language: "zh-Hans")
        XCTAssertEqual(cache.stackRebuildCount, 6)

        let refreshed = prepare(history: history(latestA: 175), revision: 2)
        XCTAssertEqual(cache.stackRebuildCount, 7)
        XCTAssertEqual(refreshed.series.first?.points.last?.value, 95)
        XCTAssertEqual(refreshed.window.rows.last?.total, 295)
    }

    func testExactDateLookupKeepsFirstDuplicateAndNearestFallback() throws {
        let original = HoldingContributionStack(history: history()).rows
        let duplicate = HoldingContributionStack.Row(
            dateText: original[0].dateText, date: original[0].date,
            principal: 999, othersGain: 0, bands: [999], total: 999)
        let window = HoldingContributionStack.Window(rows: [original[0], duplicate, original[1]])
        XCTAssertEqual(window.row(nearest: original[0].date)?.total, original[0].total)
        let between = original[0].date.addingTimeInterval(6 * 60 * 60)
        XCTAssertEqual(window.row(nearest: between)?.total, original[0].total)
        XCTAssertNil(window.row(nearest: nil))
    }
}
