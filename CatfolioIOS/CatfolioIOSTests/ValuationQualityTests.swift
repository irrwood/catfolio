import XCTest
@testable import CatfolioIOS

final class ValuationQualityTests: XCTestCase {
    typealias Facts = [String: [String: CompanyFinancialsClient.SECFact]]
    private func facts(change: (inout [String: [[String: Any]]]) -> Void = { _ in }) throws -> Facts {
        func flow(_ value: Double, start: String = "2025-01-01", end: String = "2025-12-31") -> [String: Any] {
            ["start": start, "end": end, "val": value, "filed": "2026-02-15", "form": "10-K", "accn": "0000000001-26-000001"]
        }
        func balances(_ a: Double, _ b: Double) -> [[String: Any]] {
            ["2024-12-31", "2025-12-31"].enumerated().map { i, end in
                ["end": end, "val": i == 0 ? a : b, "filed": "2026-02-15", "form": "10-K", "accn": "0000000001-26-000001"]
            }
        }
        var rows: [String: [[String: Any]]] = [
            "EarningsPerShareDiluted": [flow(3), flow(2, start: "2024-01-01", end: "2024-12-31")],
            "OperatingIncomeLoss": [flow(120)],
            "IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest": [flow(100)],
            "IncomeTaxExpenseBenefit": [flow(25)],
            "StockholdersEquity": balances(300, 400),
            "CashAndCashEquivalentsAtCarryingValue": balances(50, 50),
            "LongTermDebtCurrent": balances(10, 10),
            "LongTermDebtNoncurrent": balances(90, 90),
            "ShortTermBorrowings": balances(50, 50),
        ]
        change(&rows)
        let ns = rows.mapValues { ["units": ["USD": $0]] }
        var json = ns
        json["EarningsPerShareDiluted"] = ["units": ["USD/shares": rows["EarningsPerShareDiluted"] ?? []]]
        return try JSONDecoder().decode(Facts.self, from: JSONSerialization.data(withJSONObject: ["us-gaap": json]))
    }
    func testAnnualROICAndEPSUseMatchingPeriods() throws {
        let q = try XCTUnwrap(SECQualityCalculator.calculate(facts()))
        XCTAssertEqual(q.periodEnd, "2025-12-31")
        XCTAssertEqual(q.epsGrowthPercent, 50)
        XCTAssertEqual(q.effectiveTaxRate, 0.25)
        XCTAssertEqual(q.nopat, 90)
        XCTAssertEqual(q.openingCapital, 400)
        XCTAssertEqual(q.closingCapital, 500)
        XCTAssertEqual(q.roicPercent, 20)
    }
    func testEPSComparativesUseSameFilingNotOldSplitBasis() throws {
        let q = SECQualityCalculator.calculate(try facts { rows in
            rows["EarningsPerShareDiluted"]!.append([
                "start": "2024-01-01", "end": "2024-12-31", "val": 8,
                "form": "10-K", "filed": "2025-02-15", "accn": "0000000001-25-000001",
            ])
        })
        XCTAssertEqual(q?.epsGrowthPercent, 50)
    }
    func testQuarterAndYTDDoNotReplaceAnnualEPS() throws {
        let q = SECQualityCalculator.calculate(try facts { rows in
            rows["EarningsPerShareDiluted"]!.append([
                "start": "2026-01-01", "end": "2026-06-30", "val": 99,
                "form": "10-Q", "filed": "2026-08-01", "accn": "0000000001-26-000002",
            ])
        })
        XCTAssertEqual(q?.periodEnd, "2025-12-31")
        XCTAssertEqual(q?.epsGrowthPercent, 50)
    }
    func testEPSNegativeBaseIsUnavailableButCurrentLossIsNegativeGrowth() throws {
        let negativeBase = SECQualityCalculator.calculate(try facts { $0["EarningsPerShareDiluted"]![1]["val"] = -2 })
        XCTAssertNil(negativeBase?.epsGrowthPercent)
        XCTAssertNotNil(negativeBase?.epsUnavailableReason)
        let loss = SECQualityCalculator.calculate(try facts { $0["EarningsPerShareDiluted"]![0]["val"] = -1 })
        XCTAssertEqual(loss?.epsGrowthPercent, -150)
    }
    func testMissingTaxOrDebtIsNotZero() throws {
        for tag in ["IncomeTaxExpenseBenefit", "ShortTermBorrowings", "LongTermDebtNoncurrent", "CashAndCashEquivalentsAtCarryingValue"] {
            let q = SECQualityCalculator.calculate(try facts { $0.removeValue(forKey: tag) })
            XCTAssertNil(q?.roicPercent, tag)
            XCTAssertNotNil(q?.roicUnavailableReason, tag)
        }
    }
    func testZeroBorrowingIsValidAndDebtIsNotDoubleCounted() throws {
        let q = SECQualityCalculator.calculate(try facts { rows in
            for i in 0..<2 { rows["ShortTermBorrowings"]![i]["val"] = 0 }
            rows["LongTermDebt"] = rows["LongTermDebtNoncurrent"]!.map { row in
                var copy = row; copy["val"] = 100; return copy
            }
        })
        XCTAssertEqual(q?.openingCapital, 350)
        XCTAssertEqual(q?.closingCapital, 450)
        XCTAssertEqual(q?.roicPercent, 22.5)
    }
    func testAbnormalTaxAndNonpositiveCapitalAreUnavailable() throws {
        for tax in [-10.0, 150] {
            let q = SECQualityCalculator.calculate(try facts { $0["IncomeTaxExpenseBenefit"]![0]["val"] = tax })
            XCTAssertNil(q?.roicPercent)
        }
        let q = SECQualityCalculator.calculate(try facts { $0["StockholdersEquity"]![0]["val"] = -500 })
        XCTAssertNil(q?.roicPercent)
    }
    func testNegativeOperatingReturnIsNotClampedToZero() throws {
        let q = SECQualityCalculator.calculate(try facts { $0["OperatingIncomeLoss"]![0]["val"] = -120 })
        XCTAssertEqual(q?.roicPercent, -20)
    }
    func testNoImplicitCurrencyOrFilingMixing() throws {
        let noPrior = SECQualityCalculator.calculate(try facts { $0["EarningsPerShareDiluted"]!.removeLast() })
        XCTAssertNil(noPrior?.epsGrowthPercent)
        let otherFiling = SECQualityCalculator.calculate(try facts { $0["IncomeTaxExpenseBenefit"]![0]["accn"] = "another" })
        XCTAssertNil(otherFiling?.roicPercent)
    }
    func testFinancialCompaniesAndMissingValuesCannotBecome3DPoints() throws {
        let q = try XCTUnwrap(SECQualityCalculator.calculate(facts()))
        var row = ValuationBubble(ticker: "TEST", displayName: "Test", sector: "Technology", pe: 20,
                                  growthPercent: 50, growthSource: "EPS", weight: 0.1, quality: q)
        XCTAssertTrue(row.isThreeDimensional)
        row = ValuationBubble(ticker: "BANK", displayName: "Bank", sector: "金融", pe: 20,
                              growthPercent: 50, growthSource: "EPS", weight: 0.1, quality: q)
        XCTAssertNil(row.roicPercent)
        XCTAssertFalse(row.isThreeDimensional)
        row.quality = nil
        XCTAssertNil(row.epsGrowthPercent)
    }
    func testChartDomainsKeepNegativeAndOutlierValues() {
        let domain = StockMapDomain([-150, 0, 800, .nan, .infinity])
        XCTAssertLessThan(domain.lower, -150)
        XCTAssertGreaterThan(domain.upper, 800)
        XCTAssertGreaterThan(domain.coordinate(-150), -0.7)
        XCTAssertLessThan(domain.coordinate(800), 0.7)
        XCTAssertTrue(StockMapDomain([0, 0]).coordinate(0).isFinite)
    }
    func testFilingLinkUsesIssuerCIKNotSubmittingAgent() throws {
        let q = try XCTUnwrap(SECQualityCalculator.calculate(facts(), cik: 320193))
        XCTAssertEqual(q.filingURL?.absoluteString,
                       "https://www.sec.gov/Archives/edgar/data/320193/000000000126000001/0000000001-26-000001-index.html")
    }
    func testQualityCacheRoundTripAndLegacyDecode() throws {
        let q = try XCTUnwrap(SECQualityCalculator.calculate(facts()))
        XCTAssertEqual(try JSONDecoder().decode(ValuationQuality.self, from: JSONEncoder().encode(q)), q)
        let legacy = Data(#"{"ticker":"TEST","entityName":"Test","source":"SEC","income":[],"balance":[],"cashFlow":[],"warnings":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(CompanyFinancialsData.self, from: legacy)
        XCTAssertNil(decoded.valuationQuality)
        XCTAssertNil(decoded.valuationSchemaVersion)
    }
}


extension ValuationQualityTests {
    /// SEC 2025 AAPL 10-K, accession 0000320193-25-000079. These are
    /// reported facts (USD), not provider ROIC or contemporary share prices.
    func testApple2025AnnualFilingAgainstHandCalculation() throws {
        let data = Data(#"{"us-gaap":{"EarningsPerShareDiluted":{"units":{"USD/shares":[{"start":"2023-10-01","end":"2024-09-28","val":6.08,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"},{"start":"2024-09-29","end":"2025-09-27","val":7.46,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"}]}},"OperatingIncomeLoss":{"units":{"USD":[{"start":"2023-10-01","end":"2024-09-28","val":123216000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"},{"start":"2024-09-29","end":"2025-09-27","val":133050000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"}]}},"IncomeTaxExpenseBenefit":{"units":{"USD":[{"start":"2023-10-01","end":"2024-09-28","val":29749000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"},{"start":"2024-09-29","end":"2025-09-27","val":20719000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"}]}},"IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest":{"units":{"USD":[{"start":"2023-10-01","end":"2024-09-28","val":123485000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"},{"start":"2024-09-29","end":"2025-09-27","val":132729000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"}]}},"StockholdersEquity":{"units":{"USD":[{"end":"2024-09-28","val":56950000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"},{"end":"2025-09-27","val":73733000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"}]}},"CashAndCashEquivalentsAtCarryingValue":{"units":{"USD":[{"end":"2024-09-28","val":29943000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"},{"end":"2025-09-27","val":35934000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"}]}},"LongTermDebtCurrent":{"units":{"USD":[{"end":"2024-09-28","val":10912000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"},{"end":"2025-09-27","val":12350000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"}]}},"LongTermDebtNoncurrent":{"units":{"USD":[{"end":"2024-09-28","val":85750000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"},{"end":"2025-09-27","val":78328000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"}]}},"CommercialPaper":{"units":{"USD":[{"end":"2024-09-28","val":9967000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"},{"end":"2025-09-27","val":7979000000,"accn":"0000320193-25-000079","form":"10-K","filed":"2025-10-31"}]}}}}"#.utf8)
        let facts = try JSONDecoder().decode(Facts.self, from: data)
        let q = try XCTUnwrap(SECQualityCalculator.calculate(facts))
        XCTAssertEqual(q.periodEnd, "2025-09-27")
        XCTAssertEqual(q.openingCapital, 133_636_000_000)
        XCTAssertEqual(q.closingCapital, 136_456_000_000)
        XCTAssertEqual(try XCTUnwrap(q.epsGrowthPercent), (7.46 / 6.08 - 1) * 100, accuracy: 0.000001)
        let expectedNOPAT = 133_050_000_000.0 * (1 - 20_719_000_000.0 / 132_729_000_000.0)
        XCTAssertEqual(try XCTUnwrap(q.roicPercent), expectedNOPAT / 135_046_000_000 * 100, accuracy: 0.000001)
    }
}
