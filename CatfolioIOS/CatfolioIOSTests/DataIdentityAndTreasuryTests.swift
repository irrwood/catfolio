import XCTest
@testable import CatfolioIOS

final class TreasuryYieldCurveTests: XCTestCase {
    private let csv = """
    Date,"1 Mo","1.5 Month","2 Mo","3 Mo","4 Mo","6 Mo","1 Yr","2 Yr","3 Yr","5 Yr","7 Yr","10 Yr","20 Yr","30 Yr"
    10/02/2026,4.04,4.09,4.11,4.19,4.26,4.27,4.46,4.83,4.96,5.06,5.17,5.28,5.67,5.63
    10/01/2026,4.06,4.10,4.13,4.17,4.26,4.27,4.44,4.78,4.91,5.01,5.12,5.24,5.64,5.61
    """

    func testPublishedCSVParsesOldestFirstWithPercentYields() throws {
        let days = TreasuryYieldCurve.parse(csv)
        XCTAssertEqual(days.map(\.date), ["2026-10-01", "2026-10-02"])
        XCTAssertEqual(days.last?.yields[.tenYears], 5.28)
        XCTAssertEqual(days.last?.yields[.twoYears], 4.83)
        XCTAssertEqual(days.last?.yields.count, 13, "the 1.5-month column is not a tracked maturity")
        let curve = TreasuryYieldCurve(days: days)
        XCTAssertEqual(curve.history(.tenYears), ["2026-10-01": 5.24, "2026-10-02": 5.28])
        XCTAssertEqual(curve.day(onOrBefore: "2026-10-01")?.date, "2026-10-01")
        XCTAssertNil(curve.day(onOrBefore: "2026-09-30"))
    }
}

final class SecurityIdentityTests: XCTestCase {
    private func listing(_ ticker: String, _ exchange: String) -> SecurityIdentityResolver.Listing {
        .init(ticker: ticker, exchangeCode: exchange, name: nil, securityType: nil)
    }

    func testISINShape() {
        XCTAssertTrue(SecurityIdentityResolver.isISIN("IE00B3XXRP09"))
        XCTAssertTrue(SecurityIdentityResolver.isISIN(" us0378331005 "))
        XCTAssertFalse(SecurityIdentityResolver.isISIN("AAPL"))
        XCTAssertFalse(SecurityIdentityResolver.isISIN("IE00B3XXRP0X"))
    }

    func testListingFollowsTheTradeCurrencyThenTheHomeMarket() {
        let listings = [listing("VUSA", "GY"), listing("VUSA", "LN"), listing("VUSD", "LN")]
        XCTAssertEqual(SecurityIdentityResolver.preferredTicker(listings, currency: "GBP", isin: "IE00B3XXRP09"), "VUSA.L")
        XCTAssertEqual(SecurityIdentityResolver.preferredTicker(listings, currency: "EUR", isin: "IE00B3XXRP09"), "VUSA.DE")
        XCTAssertEqual(SecurityIdentityResolver.preferredTicker(listings, currency: nil, isin: "IE00B3XXRP09"), "VUSA.L")
        XCTAssertEqual(SecurityIdentityResolver.preferredTicker(
            [listing("AAPL", "GR"), listing("AAPL", "US")], currency: "USD", isin: "US0378331005"), "AAPL")
        XCTAssertNil(SecurityIdentityResolver.preferredTicker([listing("X", "ZZ")], currency: nil, isin: "XX0000000000"))
    }

    func testOpenFIGIAnswersDecodeInJobOrder() throws {
        let data = Data("""
        [{"data":[{"figi":"B","ticker":"VUSA","exchCode":"LN","name":"VANG S&P500","securityType":"ETP"}]},
         {"warning":"No identifier found."},
         {"error":"Invalid idValue format"}]
        """.utf8)
        let answers = try OpenFIGIClient.decode(data)
        XCTAssertEqual(answers.count, 3)
        XCTAssertEqual(answers[0]?.first?.ticker, "VUSA")
        XCTAssertEqual(answers[1]?.isEmpty, true, "an unknown ISIN is an empty answer, kept")
        XCTAssertNil(answers[2], "a failed job is retried next time")
    }

    func testResolverAsksOnceAndCSVImportUsesTheListing() async throws {
        let calls = Counter()
        let resolver = SecurityIdentityResolver(fetch: { jobs in
            await calls.add(jobs.count)
            return jobs.map { _ in [.init(ticker: "VUSA", exchangeCode: "LN", name: nil, securityType: nil)] }
        }, cacheURL: nil)
        let first = await resolver.tickers(forISINs: [("IE00B3XXRP09", "GBP")])
        let second = await resolver.tickers(forISINs: [("IE00B3XXRP09", "GBP")])
        XCTAssertEqual(first, ["IE00B3XXRP09": "VUSA.L"])
        XCTAssertEqual(second, first)
        let asked = await calls.value
        XCTAssertEqual(asked, 1)

        let csv = "Date,Action,ISIN,Quantity,Price,Currency\n2026-01-02,BUY,IE00B3XXRP09,10,90,GBP\n"
        XCTAssertEqual(LocalCSVImporter.isinRequests(in: Data(csv.utf8)).map(\.isin), ["IE00B3XXRP09"])
        let (_, rows, _) = try LocalCSVImporter.parse(Data(csv.utf8), resolvedISINs: first)
        XCTAssertEqual(rows.first?.ticker, "VUSA.L")
        let (_, unresolved, _) = try LocalCSVImporter.parse(Data(csv.utf8))
        XCTAssertEqual(unresolved.first?.ticker, "IE00B3XXRP09")
    }
}

private actor Counter {
    var value = 0
    func add(_ n: Int) { value += n }
}

final class FREDTests: XCTestCase {
    func testCSVSkipsMissingDaysAndYearOnYearUsesTheSameMonth() {
        let rows = FREDClient.parse("observation_date,CPIAUCSL\n2025-08-01,320.0\n2025-09-01,.\n2026-08-01,329.6\n")
        XCTAssertEqual(rows.map(\.date), ["2025-08-01", "2026-08-01"])
        let yoy = FREDClient.yearOnYear(rows)
        XCTAssertEqual(yoy.map(\.date), ["2026-08-01"])
        XCTAssertEqual(yoy.first?.value ?? 0, 3.0, accuracy: 1e-9)
    }
}

final class OpenRouterWebCitationTests: XCTestCase {
    func testNestedURLCitationsBecomeSourceLinks() {
        let data = Data("""
        {"choices":[{"message":{"content":"NVDA reported.","annotations":[
          {"type":"url_citation","url_citation":{"url":"https://example.com/a","title":"Example A"}},
          {"type":"url_citation","url_citation":{"url":"https://example.com/a","title":"Duplicate"}}]}}]}
        """.utf8)
        XCTAssertEqual(AIWebSearch.sourceLinks(in: data), "- [Example A](<https://example.com/a>)")
    }
}

final class EuropeanMacroParsingTests: XCTestCase {
    func testECBCSVIsReadByColumnName() {
        let csv = "KEY,FREQ,TIME_PERIOD,OBS_VALUE,TITLE\nFM.D,D,2026-10-02,2.5,x\nFM.D,D,2026-10-01,2.25,x\n"
        let rows = ECBClient.parse(csv)
        XCTAssertEqual(rows.map(\.date), ["2026-10-01", "2026-10-02"])
        XCTAssertEqual(rows.last?.value, 2.5)
    }

    func testEurostatJSONStatMapsValuesOntoTimeAndQuartersOntoDays() throws {
        let data = Data("""
        {"value":{"0":1.2,"1":0.6},"dimension":{"time":{"category":{"index":{"2026-Q1":0,"2026-Q2":1}}}}}
        """.utf8)
        let rows = try EurostatClient.parse(data)
        XCTAssertEqual(rows.map(\.date), ["2026-01-01", "2026-04-01"])
        XCTAssertEqual(rows.map(\.value), [1.2, 0.6])
        XCTAssertEqual(MacroHTTP.dayText("2026-09"), "2026-09-01")
    }

    func testONSMonthsBecomeDays() throws {
        let data = Data("""
        {"years":[],"months":[{"date":"2026 JUL","value":"2.9"},{"date":"2026 AUG","value":"3.1"}]}
        """.utf8)
        let rows = try ONSClient.parse(data)
        XCTAssertEqual(rows.map(\.date), ["2026-07-01", "2026-08-01"])
        XCTAssertEqual(rows.last?.value, 3.1)
    }
}
