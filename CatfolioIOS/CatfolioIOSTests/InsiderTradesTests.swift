import XCTest
@testable import CatfolioIOS

/// Insider trades are only worth reading once the noise is out: a 10b5-1 plan
/// sale was scheduled months ahead, and exercises, grants and tax withholding
/// are pay. None of those may count as a decision.
final class InsiderTradesTests: XCTestCase {
    /// Nasdaq's own shape: `totalRecords` arrives as a string.
    private func payload(_ rows: [[String: String]], total: Int? = nil) -> Data {
        let body: [String: Any] = [
            "data": [
                "transactionTable": [
                    "totalRecords": String(total ?? rows.count),
                    "table": ["rows": rows],
                ],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    private func row(_ type: String, date: String, shares: String = "1,000", price: String = "$100.00") -> [String: String] {
        ["insider": "COOK TIMOTHY D", "relation": "Officer", "lastDate": date, "transactionType": type,
         "ownType": "Direct", "sharesTraded": shares, "lastPrice": price, "sharesHeld": "3,280,180"]
    }

    func testNasdaqTypesSortIntoDecisionsAndNoise() {
        XCTAssertEqual(InsiderTrade.Kind(nasdaq: "Buy"), .buy)
        XCTAssertEqual(InsiderTrade.Kind(nasdaq: "Sell"), .sell)
        XCTAssertEqual(InsiderTrade.Kind(nasdaq: "Automatic Sell"), .planSell)
        XCTAssertEqual(InsiderTrade.Kind(nasdaq: "Automatic Buy"), .planBuy)
        XCTAssertEqual(InsiderTrade.Kind(nasdaq: "Option Execute"), .exercise)
        XCTAssertEqual(InsiderTrade.Kind(nasdaq: "Acquisition (Non Open Market)"), .nonMarketAcquisition)
        XCTAssertEqual(InsiderTrade.Kind(nasdaq: "Disposition (Non Open Market)"), .nonMarketDisposition)
        XCTAssertEqual(InsiderTrade.Kind(nasdaq: "Something New"), .other)
    }

    func testOnlyOpenMarketTradesWithoutAPlanAreDiscretionary() throws {
        let snapshot = try InsiderTradesClient.parse(payload([
            row("Buy", date: "9/01/2026"),
            row("Sell", date: "9/01/2026"),
            row("Automatic Sell", date: "9/01/2026"),
            row("Automatic Buy", date: "9/01/2026"),
            row("Option Execute", date: "8/01/2026", price: ""),
            row("Disposition (Non Open Market)", date: "9/01/2026"),
            row("Acquisition (Non Open Market)", date: "9/01/2026", price: "$0.00"),
        ]), fetchedAt: .now)
        XCTAssertEqual(snapshot.trades.filter(\.isDiscretionary).map(\.kind), [.buy, .sell])
    }

    func testSummaryCountsOnlyDiscretionaryTradesInTheWindow() throws {
        let now = try XCTUnwrap(InsiderTradesClient.date("9/12/2026"))
        let snapshot = try InsiderTradesClient.parse(payload([
            row("Buy", date: "9/01/2026", shares: "2,000", price: "$50.00"),       // 100K, in 3M
            row("Sell", date: "5/01/2026", shares: "1,000", price: "$300.00"),     // 300K, 12M only
            row("Automatic Sell", date: "8/01/2026", shares: "9,000", price: "$300.00"),
            row("Disposition (Non Open Market)", date: "8/15/2026", shares: "5,000"),
            row("Sell", date: "1/01/2025", shares: "1,000", price: "$10.00"),      // outside 12M
        ]), fetchedAt: now)

        let recent = snapshot.summary(months: 3, now: now)
        XCTAssertEqual(recent.buys, 1)
        XCTAssertEqual(recent.sells, 0)
        XCTAssertEqual(recent.valueBought, 100_000, accuracy: 0.01)

        let year = snapshot.summary(months: 12, now: now)
        XCTAssertEqual(year.buys, 1)
        XCTAssertEqual(year.sells, 1)
        XCTAssertEqual(year.valueSold, 300_000, accuracy: 0.01)
        XCTAssertEqual(year.netValue, -200_000, accuracy: 0.01)
        XCTAssertTrue(year.isComplete)
    }

    func testAWindowTheRowsDoNotReachIsMarkedIncomplete() throws {
        let now = try XCTUnwrap(InsiderTradesClient.date("9/12/2026"))
        let snapshot = try InsiderTradesClient.parse(
            payload([row("Sell", date: "6/01/2026")], total: 500),
            fetchedAt: now
        )
        XCTAssertTrue(snapshot.summary(months: 3, now: now).isComplete)
        XCTAssertFalse(snapshot.summary(months: 12, now: now).isComplete)
    }

    func testANumericRecordCountIsAcceptedToo() throws {
        let body: [String: Any] = ["data": ["transactionTable": [
            "totalRecords": 42,
            "table": ["rows": [row("Buy", date: "9/01/2026")]],
        ]]]
        let snapshot = try InsiderTradesClient.parse(try JSONSerialization.data(withJSONObject: body), fetchedAt: .now)
        XCTAssertEqual(snapshot.totalRecords, 42)
    }

    func testTheRealNasdaqResponseParses() throws {
        let body = """
        {"data":{"title":null,"transactionTable":{"totalRecords":"306","table":{"headers":{"insider":"Insider"},
        "rows":[{"insider":"STEVENS MARK A","relation":"Director","lastDate":"9/04/2026","transactionType":"Sell",
        "ownType":"Indirect","sharesTraded":"622,239","lastPrice":"$230.40","sharesHeld":"17,354,281",
        "url":"/market-activity/insiders/stevens-mark-a-389755"}]}},"filerTransactionTable":null},
        "message":null,"status":{"rCode":200}}
        """
        let snapshot = try InsiderTradesClient.parse(Data(body.utf8), fetchedAt: .now)
        XCTAssertEqual(snapshot.totalRecords, 306)
        XCTAssertEqual(snapshot.trades.first?.kind, .sell)
        XCTAssertEqual(snapshot.trades.first?.shares, 622_239)
        XCTAssertEqual(snapshot.trades.first?.price, 230.40)
    }

    /// Twist's pattern: several officers "selling" on one day at one price
    /// is the company selling for everyone to cover tax on vesting shares.
    func testSameDaySamePriceSalesByTwoInsidersAreTaxCover() throws {
        func sale(_ name: String, _ date: String, _ price: String) -> [String: String] {
            var r = row("Sell", date: date, price: price); r["insider"] = name; return r
        }
        let snapshot = try InsiderTradesClient.parse(payload([
            sale("WERNER ROBERT F.", "9/08/2026", "$122.62"),
            sale("GREEN PAULA", "9/08/2026", "$122.62"),
            sale("CHO DENNIS", "9/08/2026", "$122.62"),
            sale("BLAKE KATRYN", "8/12/2026", "$122.88"),
            sale("WERNER ROBERT F.", "6/08/2026", "$69.07"),
            sale("LEPROUST EMILY M.", "6/08/2026", "$69.84"),
        ]), fetchedAt: .now)
        XCTAssertEqual(snapshot.trades.map(\.kind), [.sellToCover, .sellToCover, .sellToCover, .sell, .sell, .sell])
        XCTAssertEqual(snapshot.trades.filter(\.isDiscretionary).count, 3)
    }

    func testASaleOnTheDayOfAnExerciseIsNotADecision() throws {
        var exercise = row("Option Execute", date: "6/15/2026", shares: "26,137", price: "$23.33")
        exercise["insider"] = "GREEN PAULA"
        var sale = row("Sell", date: "6/15/2026", shares: "26,137", price: "$81.62")
        sale["insider"] = "GREEN PAULA"
        var other = row("Sell", date: "6/15/2026", price: "$80.00")
        other["insider"] = "SOMEONE ELSE"
        let snapshot = try InsiderTradesClient.parse(payload([exercise, sale, other]), fetchedAt: .now)
        XCTAssertEqual(snapshot.trades.map(\.kind), [.exercise, .exerciseSale, .sell])
    }

    /// An update fetches one small page and lays its new rows on the cache.
    func testANewPageIsLaidOnTopOfTheCache() throws {
        let cached = try InsiderTradesClient.parseRows(payload([
            row("Sell", date: "9/01/2026", shares: "100"),
            row("Buy", date: "8/01/2026", shares: "200"),
            row("Sell", date: "7/01/2026", shares: "300"),
        ])).trades
        let page = try InsiderTradesClient.parseRows(payload([
            row("Buy", date: "9/10/2026", shares: "50"),
            row("Sell", date: "9/01/2026", shares: "100"),
            row("Buy", date: "8/01/2026", shares: "200"),
        ])).trades
        let merged = try XCTUnwrap(InsiderTradesClient.merge(page: page, into: cached))
        XCTAssertEqual(merged.map(\.shares), [50, 100, 200, 300])
    }

    func testAPageWithNothingNewLeavesTheCacheAsItIs() throws {
        let rows = try InsiderTradesClient.parseRows(payload([
            row("Sell", date: "9/01/2026", shares: "100"),
            row("Buy", date: "8/01/2026", shares: "200"),
        ])).trades
        XCTAssertEqual(InsiderTradesClient.merge(page: rows, into: rows)?.map(\.shares), [100, 200])
    }

    /// A page made entirely of new rows might have skipped some: fetch it all.
    func testAPageThatDoesNotReachTheCacheAsksForAFullFetch() throws {
        let cached = try InsiderTradesClient.parseRows(payload([row("Sell", date: "6/01/2026", shares: "100")])).trades
        let page = try InsiderTradesClient.parseRows(payload([
            row("Buy", date: "9/10/2026", shares: "50"),
            row("Buy", date: "9/09/2026", shares: "60"),
        ])).trades
        XCTAssertNil(InsiderTradesClient.merge(page: page, into: cached))
    }

    /// The same-day, same-price rule has to see new rows beside cached ones.
    func testMergedRowsAreClassifiedAgainAsOneSet() throws {
        var first = row("Sell", date: "9/08/2026", price: "$122.62"); first["insider"] = "GREEN PAULA"
        var second = row("Sell", date: "9/08/2026", price: "$122.62"); second["insider"] = "CHO DENNIS"
        let cached = InsiderTradesClient.finalize(try InsiderTradesClient.parseRows(payload([first])).trades)
        XCTAssertEqual(cached.first?.kind, .sell)
        let page = try InsiderTradesClient.parseRows(payload([second, first])).trades
        let merged = InsiderTradesClient.finalize(try XCTUnwrap(InsiderTradesClient.merge(page: page, into: cached)))
        XCTAssertEqual(merged.map(\.kind), [.sellToCover, .sellToCover])
    }

    func testIdsStayPutWhenNewerRowsArrive() throws {
        let old = InsiderTradesClient.finalize(try InsiderTradesClient.parseRows(payload([
            row("Sell", date: "9/01/2026"), row("Sell", date: "9/01/2026"),
        ])).trades)
        let page = try InsiderTradesClient.parseRows(payload([
            row("Buy", date: "9/10/2026"), row("Sell", date: "9/01/2026"), row("Sell", date: "9/01/2026"),
        ])).trades
        let merged = InsiderTradesClient.finalize(try XCTUnwrap(InsiderTradesClient.merge(page: page, into: old)))
        XCTAssertEqual(Array(merged.dropFirst()).map(\.id), old.map(\.id))
        XCTAssertEqual(Set(merged.map(\.id)).count, 3)
    }

    func testNasdaqNumbersParse() {
        XCTAssertEqual(InsiderTradesClient.number("$1,234.50"), 1234.5)
        XCTAssertEqual(InsiderTradesClient.number("622,239"), 622_239)
        XCTAssertEqual(InsiderTradesClient.number("(5,866)"), -5866)
        XCTAssertNil(InsiderTradesClient.number(""))
    }

    func testRowsWithoutADateOrSharesAreDropped() throws {
        let snapshot = try InsiderTradesClient.parse(payload([
            row("Buy", date: ""),
            row("Buy", date: "9/01/2026", shares: ""),
            row("Buy", date: "9/01/2026"),
        ]), fetchedAt: .now)
        XCTAssertEqual(snapshot.trades.count, 1)
        XCTAssertEqual(snapshot.trades.first?.value ?? 0, 100_000, accuracy: 0.01)
    }

    func testInsiderTradesAreUSOnlyAndNotForFunds() {
        XCTAssertTrue(HoldingResearchVisibility(kind: .company, currency: "USD").shows(.insiders))
        XCTAssertFalse(HoldingResearchVisibility(kind: .company, currency: "GBP").shows(.insiders))
        XCTAssertFalse(HoldingResearchVisibility(kind: .fund, currency: "USD").shows(.insiders))
    }
}
