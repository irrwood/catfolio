import XCTest
@testable import CatfolioIOS

final class SecurityNamePartsTests: XCTestCase {
    func testDistributionClassesSplitOnlyWhenTheyAreTrailingNameLabels() {
        assertName("NVIDIA ACC", primary: "NVIDIA", markers: ["A"])
        assertName("Global UCITS ETF (Dist)", primary: "Global UCITS ETF", markers: ["D"])
        assertName("Global UCITS ETF Accumulating", primary: "Global UCITS ETF", markers: ["A"])
        assertName("Global UCITS ETF Distributing", primary: "Global UCITS ETF", markers: ["D"])
        assertName("Treasury Bond UCITS ETF USD (Acc) B", primary: "Treasury Bond UCITS ETF USD", markers: ["A B"])
        assertName("Accenture", primary: "Accenture", markers: [])
        assertName("Distributing Ladder ETF", primary: "Distributing Ladder ETF", markers: [])
    }

    func testShareClassesBecomeLetterBadgesWithoutChangingOrdinaryNames() {
        assertName("Alphabet Inc. Class A", primary: "Alphabet Inc.", markers: ["A"])
        assertName("Berkshire Hathaway Inc. Class B", primary: "Berkshire Hathaway Inc.", markers: ["B"])
        assertName("Example Corp (Class C)", primary: "Example Corp", markers: ["C"])
        assertName("CoreWeave, Inc. Class Z Common Stock", primary: "CoreWeave, Inc.", markers: ["Z"])
        assertName("Example Corp - Cl D", primary: "Example Corp", markers: ["D"])
        assertName("Class Action Inc.", primary: "Class Action Inc.", markers: [])
        assertName("Example Class AB", primary: "Example Class AB", markers: [])
        assertName("Class A", primary: "Class A", markers: [])
    }

    func testDistributionAndShareClassesKeepTheirSourceOrder() {
        assertName("Global ETF (Acc) Class B", primary: "Global ETF", markers: ["A", "B"])
        assertName("Global ETF Class B (Dist)", primary: "Global ETF", markers: ["B", "D"])
    }

    /// The security page writes the classes out; "A" alone could be either.
    func testClassLabelsSpellOutWhatTheBadgeAbbreviates() {
        XCTAssertEqual(SecurityNameParts("Global UCITS ETF (Acc)").classLabels, ["Acc"])
        XCTAssertEqual(SecurityNameParts("Global UCITS ETF Distributing").classLabels, ["Dist"])
        XCTAssertEqual(SecurityNameParts("Alphabet Inc. Class A").classLabels, ["Class A"])
        XCTAssertEqual(SecurityNameParts("Treasury Bond UCITS ETF USD (Acc) B").classLabels, ["Acc B"])
        XCTAssertEqual(SecurityNameParts("Global ETF (Acc) Class B").classLabels, ["Acc", "Class B"])
        XCTAssertEqual(SecurityNameParts("Accenture").classLabels, [])
    }

    func testHoldingKeepsClassMarkerWhenDisplayNameIsShortened() {
        let holding = Holding(
            ticker: "GOOGL", logoSymbol: nil, displayName: "Alphabet Inc. Class A", sector: nil, source: nil,
            shares: 1, averageCost: 1, costCurrency: "USD", quotePrice: 1, quoteCurrency: "USD",
            todayChangePercent: nil, marketValue: 1, weight: 1, unrealized: 0, unrealizedPercent: 0,
            fxPnl: nil, fxPnlPercent: nil, fxPnlStatus: nil, fxPnlSource: nil
        )
        XCTAssertEqual(holding.classMarkers, ["A"])
    }

    private func assertName(_ name: String, primary: String, markers: [String]) {
        let parts = SecurityNameParts(name)
        XCTAssertEqual(parts.primary, primary)
        XCTAssertEqual(parts.classMarkers, markers)
    }
}
