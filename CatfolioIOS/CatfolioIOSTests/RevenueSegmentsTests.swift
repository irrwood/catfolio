import XCTest
@testable import CatfolioIOS

/// The bundled segment catalogue and how the revenue-mix diagram reads it.
final class RevenueSegmentsTests: XCTestCase {
    private func period(_ json: String) throws -> RevenueSegmentCatalog.Period {
        try JSONDecoder().decode(RevenueSegmentCatalog.Period.self, from: Data(json.utf8))
    }

    func testTheBundledCatalogueCoversAppleAndReconciles() throws {
        let catalogue = try RevenueSegmentCatalog.load()
        let products = catalogue.periods(ticker: "AAPL", kind: .product)
        let latest = try XCTUnwrap(products.first)
        XCTAssertTrue(latest.items.contains { $0.name == "iPhone" })
        let revenue = try XCTUnwrap(latest.revenue)
        let sum = latest.items.reduce(0) { $0 + $1.value }
        XCTAssertEqual(sum / revenue, 1, accuracy: 0.02)
        XCTAssertFalse(catalogue.periods(ticker: "AAPL", kind: .geography).isEmpty)
        XCTAssertNotNil(catalogue.asOf)
    }

    func testNewestYearComesFirstAndYearsAreUnique() throws {
        let years = try RevenueSegmentCatalog.load().periods(ticker: "NVDA", kind: .product).map(\.fy)
        XCTAssertEqual(years, years.sorted(by: >))
        XCTAssertEqual(Set(years).count, years.count)
    }

    func testSharesAreOfRevenueUnlessTheSegmentsCannotBeCompared() throws {
        let plain = try period(#"{"fy":2025,"revenue":100,"items":[["A",60],["B",40]]}"#)
        XCTAssertEqual(plain.base, 100)
        let unassigned = try period(#"{"fy":2025,"revenue":100,"items":[["A",60],["B",30]],"unallocated":10}"#)
        XCTAssertEqual(unassigned.base, 100)
        let overlapping = try period(#"{"fy":2025,"revenue":100,"items":[["A",90],["B",60]],"overlap":true}"#)
        XCTAssertEqual(overlapping.base, 150)
        let eliminated = try period(#"{"fy":2025,"revenue":100,"items":[["A",70],["B",35]],"eliminations":5}"#)
        XCTAssertEqual(eliminated.base, 105)
        let noStatement = try period(#"{"fy":2026,"items":[["A",70],["B",30]]}"#)
        XCTAssertEqual(noStatement.base, 100)
    }

    func testRibbonsFillTheSpanAndNoneVanishes() {
        let thickness = SegmentFlowDiagram.thicknesses([1000, 10, 1], span: 220)
        XCTAssertEqual(thickness.reduce(0, +), 220, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(thickness.min() ?? 0, 3)
    }

    func testTheLongTailFoldsIntoOneRow() throws {
        let many = try period(#"{"fy":2025,"items":[["A",9],["B",8],["C",7],["D",6],["E",5],["F",4],["G",3],["H",2],["I",1]]}"#)
        let rows = SegmentFlowDiagram.rows(for: many)
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(rows.last?.value, 6)   // G + H + I
        XCTAssertEqual(SegmentFlowDiagram.rows(for: many, limit: .max).count, 9)
    }
}
