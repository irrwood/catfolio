import XCTest
@testable import CatfolioIOS

/// Messages recorded in Chinese and shown later — chart notes, enum labels —
/// read in English when the app is in English.
final class StoredMessageTranslationTests: XCTestCase {
    func testReturnsChartNotesReadInEnglish() {
        XCTAssertEqual(L10n.message("TWR：缺少完整资金账本和账户估值，暂不可用。", language: "en"),
                       "TWR is unavailable without a complete cash ledger and account valuations.")
        XCTAssertEqual(L10n.message("MWR：缺少完整资金账本和账户估值，暂不可用。", language: "en"),
                       "MWR is unavailable without a complete cash ledger and account valuations.")
        // One with its own date and currency in it.
        XCTAssertEqual(L10n.message("TWR：2025-01-02 缺少 GBP 汇率。", language: "en"),
                       "TWR: 2025-01-02 is missing the GBP exchange rate.")
    }

    func testTheCashFlowStatementTabReadsInEnglish() {
        XCTAssertEqual(L10n.render(L10n.Message(stringLiteral: "现金流"), language: "en"), "Cash flow")
    }
}
