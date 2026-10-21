import XCTest
@testable import CatfolioIOS

final class ScreenshotImportTests: XCTestCase {
    private func box(_ text: String, _ x: Double, _ y: Double, width: Double = 0.1) -> ScreenshotTextBox {
        .init(text: text, x: x, y: y, width: width, height: 0.02)
    }

    func testEnglishAndChineseTablesUseColumnLabelsRatherThanNumberOrder() throws {
        for headers in [
            ["Ticker", "Quantity", "Average cost", "Current price", "Currency"],
            ["股票代码", "持仓数量", "每股成本", "现价", "币种"]
        ] {
            let columns = [0.02, 0.25, 0.45, 0.65, 0.85]
            var boxes = zip(headers, columns).map { box($0.0, $0.1, 0.1) }
            boxes += zip(["AAPL", "1,234.5", "150.25", "180.50", "USD"], columns).map { box($0.0, $0.1, 0.2) }
            boxes += zip(["0700.HK", "100", "300", "320", "HKD"], columns).map { box($0.0, $0.1, 0.3) }
            boxes += zip(["TOTAL", "1,334.5", "999999", "999999", "USD"], columns).map { box($0.0, $0.1, 0.4) }
            let drafts = ScreenshotImportParser.parse(boxes.shuffled())
            XCTAssertEqual(drafts.map(\.ticker), ["AAPL", "0700.HK"])
            let positions = try ScreenshotImport.positions(drafts, accountID: "test", accountName: "Test")
            XCTAssertEqual(positions[0].shares, 1234.5)
            XCTAssertEqual(positions[0].averageCost, 150.25)
            XCTAssertEqual(positions[0].quotePrice, 180.5)
            XCTAssertEqual(positions[1].currency, "HKD")
            XCTAssertNil(positions[0].openedDate, "A screenshot does not reveal a purchase date")
            XCTAssertNil(positions[0].quoteObservedAt, "Import time is not quote time")
        }
    }

    func testLabelledCardsAndHorizontalMetrics() throws {
        let drafts = ScreenshotImportParser.parse([
            box("AAPL", 0.1, 0.1), box("USD", 0.6, 0.1),
            box("Shares", 0.1, 0.2), box("2.5", 0.6, 0.2),
            box("Average", 0.1, 0.3), box("cost", 0.22, 0.3),
            box("$100", 0.6, 0.3),
            box("Current price", 0.1, 0.4), box("$120", 0.6, 0.4),
            box("MSFT", 0.1, 0.5), box("USD", 0.7, 0.5),
            box("Shares", 0.1, 0.6), box("Avg cost", 0.4, 0.6), box("Price", 0.7, 0.6),
            box("3", 0.1, 0.7), box("200", 0.4, 0.7), box("210", 0.7, 0.7)
        ])
        XCTAssertEqual(drafts.count, 2)
        XCTAssertNil(drafts.first?.problem)
        XCTAssertEqual(drafts.first?.shares, "2.5")
        XCTAssertEqual(drafts.last?.averageCost, "200")
        XCTAssertEqual(drafts.last?.price, "210")
    }

    func testMissingCostAndAmbiguousDollarCurrencyStayEmpty() {
        let drafts = ScreenshotImportParser.parse([
            box("AAPL", 0.1, 0.1),
            box("Shares", 0.1, 0.2), box("10", 0.6, 0.2),
            box("Market value", 0.1, 0.3), box("$2000", 0.6, 0.3),
            box("Total cost", 0.1, 0.4), box("$1500", 0.6, 0.4),
            box("Return", 0.1, 0.5), box("33.3%", 0.6, 0.5)
        ])
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].shares, "10")
        XCTAssertEqual(drafts[0].averageCost, "")
        XCTAssertEqual(drafts[0].price, "")
        XCTAssertEqual(drafts[0].currency, "")
        XCTAssertNotNil(drafts[0].problem)
    }

    func testNumbersRejectPercentagesAmbiguousSeparatorsAndOCRSubstitutions() {
        for value in ["1,23", "1.234,56", "1O0", "5%", "NaN", "inf", "1e3", "1万", ""] {
            XCTAssertNil(ScreenshotImportParser.number(value), value)
        }
        XCTAssertEqual(ScreenshotImportParser.number("HK$1,234.56"), 1234.56)
        XCTAssertEqual(ScreenshotImportParser.number("−2.5"), -2.5)
    }

    func testStackedBrokerColumnsRespectThePrintedPriceCostOrder() throws {
        for priceFirst in [true, false] {
            let drafts = ScreenshotImportParser.parse([
                box("USD", 0.1, 0.02),
                box("名称/代码", 0.05, 0.1), box("市值/数量", 0.4, 0.1),
                box(priceFirst ? "现价/成本" : "成本/现价", 0.7, 0.1),
                box("苹果", 0.05, 0.2), box("1800", 0.4, 0.2),
                box(priceFirst ? "180" : "150", 0.7, 0.2),
                box("AAPL", 0.05, 0.24), box("10", 0.4, 0.24),
                box(priceFirst ? "150" : "180", 0.7, 0.24)
            ])
            XCTAssertEqual(drafts.count, 1)
            XCTAssertEqual(drafts.first?.shares, "10")
            XCTAssertEqual(drafts.first?.price, "180")
            XCTAssertEqual(drafts.first?.averageCost, "150")
            XCTAssertNil(drafts.first?.problem)
        }
    }

    func testValidationRejectsMissingFieldsDuplicatesAndNonLongPositions() throws {
        var draft = validDraft()
        XCTAssertNil(draft.problem)
        XCTAssertThrowsError(try ScreenshotImport.positions([draft, draft], accountID: "a", accountName: "A"))
        for ticker in ["700", "600519", "USD", "AAPL 260101C100"] {
            draft.ticker = ticker
            XCTAssertNotNil(draft.problem)
        }
        draft = validDraft()
        for shares in ["-1", "0", "nan", "5%"] {
            draft.shares = shares
            XCTAssertNotNil(draft.problem)
        }
        draft = validDraft()
        draft.averageCost = ""
        XCTAssertNotNil(draft.problem)
        draft.averageCost = "0"
        XCTAssertNil(draft.problem, "An explicitly confirmed zero cost is allowed")
        draft.currency = "XYZ"
        XCTAssertNotNil(draft.problem)
    }

    func testBrokerExchangeNotationNormalizesBeforeDeduplication() throws {
        var first = validDraft()
        first.ticker = "US.AAPL"
        XCTAssertThrowsError(try ScreenshotImport.positions([first, validDraft()], accountID: "a", accountName: "A"))
        XCTAssertEqual(ScreenshotImportParser.normalizedTicker("AAPL.US"), "AAPL")
        XCTAssertEqual(ScreenshotImportParser.normalizedTicker("HK.00700"), "0700.HK")
        XCTAssertTrue(ScreenshotImportParser.isTicker("600519.SH"))
        XCTAssertEqual(ScreenshotImportParser.normalizedTicker("600519.SH"), "600519.SS")
    }

    func testSaveIsScopedBackedUpAndRepeatImportSetsRatherThanAddsShares() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = LocalPortfolioStore(fileURL: folder.appendingPathComponent("portfolio.json"))
        let other = LocalPositionRecord(ticker: "TSLA", name: "Tesla", shares: 3, averageCost: 10,
            currency: "USD", quotePrice: 20, quoteCurrency: "USD", source: "CSV",
            openedDate: "2025-01-01", accountID: "other", accountName: "Other")
        let transaction = LocalTransactionRecord(date: "2025-01-01", action: "BUY", ticker: "TSLA",
            quantity: 3, price: 10, currency: "USD", source: "CSV", accountID: "other", accountName: "Other")
        _ = try await store.replace(positions: [other], source: "CSV", transactions: [transaction])
        var second = validDraft()
        second.ticker = "MSFT"
        _ = try await store.importScreenshot([validDraft(), second], accountID: "a", accountName: "A", updating: false)
        var changed = validDraft()
        changed.shares = "12"
        let saved = try await store.importScreenshot([changed], accountID: "a", accountName: "A", updating: true)
        XCTAssertEqual(saved.positions.count, 3)
        XCTAssertEqual(saved.positions.first { $0.ticker == "AAPL" }?.shares, 12)
        XCTAssertEqual(saved.positions.first { $0.ticker == "TSLA" }, other)
        XCTAssertEqual(saved.transactions, [transaction])
        XCTAssertTrue(saved.positions.filter { $0.source == "Screenshot" }.allSatisfy { $0.quoteObservedAt == nil })
        let repeated = try await store.importScreenshot([changed], accountID: "a", accountName: "A", updating: true)
        XCTAssertEqual(repeated.positions.first { $0.ticker == "AAPL" }?.shares, 12)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .contains { $0.hasPrefix("portfolio-before-screenshot-") })
        do {
            _ = try await store.importScreenshot([changed], accountID: "a", accountName: "A", updating: false)
            XCTFail("Creation must not overwrite an existing account")
        } catch {}
        let after = try await store.load()
        XCTAssertEqual(after.positions, repeated.positions)
    }

    private func validDraft() -> ScreenshotHoldingDraft {
        .init(ticker: "AAPL", shares: "10", averageCost: "150", price: "180", currency: "USD")
    }
}
