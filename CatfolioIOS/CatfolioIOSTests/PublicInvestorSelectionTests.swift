import XCTest
@testable import CatfolioIOS

/// Choosing between your own portfolio, a public filer's, and invented data.
final class PublicInvestorSelectionTests: XCTestCase {

    /// Invented data and disclosed data must never be blended. A total mixing
    /// a fabricated company with someone's real 13F describes nothing.
    func testChoosingDemoClearsTheFilers() {
        let next = PublicInvestorPreferences.selecting(
            PublicInvestorPreferences.demoID, in: "pelosi,berkshire"
        )
        XCTAssertEqual(next, PublicInvestorPreferences.demoID)
        XCTAssertTrue(PublicInvestorPreferences.isDemo(next))
    }

    func testChoosingAFilerClearsTheDemo() {
        let next = PublicInvestorPreferences.selecting(
            "berkshire", in: PublicInvestorPreferences.demoID
        )
        XCTAssertEqual(PublicInvestorPreferences.selectedIDs(next), ["berkshire"])
        XCTAssertFalse(PublicInvestorPreferences.isDemo(next))
    }

    /// Choosing the demo while it is already chosen turns it off. Without
    /// this the row switched on and never off: the result equalled the
    /// current value, so the caller's change check swallowed it.
    func testChoosingDemoAgainTurnsItOff() {
        let next = PublicInvestorPreferences.selecting(
            PublicInvestorPreferences.demoID, in: PublicInvestorPreferences.demoID
        )
        XCTAssertEqual(next, "")
        XCTAssertFalse(PublicInvestorPreferences.isDemo(next))
        XCTAssertTrue(PublicInvestorPreferences.selectedIDs(next).isEmpty)
    }

    /// Turning off the last filer also leaves nothing selected, which is how
    /// the reader gets back to their own portfolio.
    func testTurningOffTheLastFilerClearsTheSelection() {
        XCTAssertTrue(
            PublicInvestorPreferences.selectedIDs(
                PublicInvestorPreferences.selecting("pelosi", in: "pelosi")
            ).isEmpty
        )
    }

    /// Filers still combine with each other; only the demo is exclusive.
    func testFilersStillCombine() {
        var selection = PublicInvestorPreferences.selecting("pelosi", in: "")
        selection = PublicInvestorPreferences.selecting("berkshire", in: selection)
        XCTAssertEqual(PublicInvestorPreferences.selectedIDs(selection), ["pelosi", "berkshire"])
    }

    func testSelectingAChosenFilerRemovesIt() {
        let selection = PublicInvestorPreferences.selecting("pelosi", in: "pelosi,berkshire")
        XCTAssertEqual(PublicInvestorPreferences.selectedIDs(selection), ["berkshire"])
    }

    /// The demo is not a filer. It is app-provided, and putting it in the
    /// catalogue would mean a fabricated company in a file generated from SEC
    /// and House disclosures.
    func testTheDemoIsNotInTheDisclosureCatalogue() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        XCTAssertFalse(
            catalog.investors.contains { $0.id == PublicInvestorPreferences.demoID },
            "the invented portfolio must not appear in the disclosure catalogue"
        )
    }

    /// A demo selection is only ever exactly the demo, so a stale multi-select
    /// carried over from an older build cannot read as one.
    func testAMixedSelectionIsNotTreatedAsDemo() {
        XCTAssertFalse(PublicInvestorPreferences.isDemo("demo,pelosi"))
        XCTAssertFalse(PublicInvestorPreferences.isDemo(""))
    }

    /// The demo's own state stays off every device but this one — the same
    /// guarantee as before the two modes were merged into one control.
    func testNeitherModeSyncsToICloud() {
        XCTAssertFalse(CloudPreferences.synchronised.contains("catfolio.fakeDataMode"))
        XCTAssertFalse(CloudPreferences.synchronised.contains(PublicInvestorPreferences.enabledKey))
        XCTAssertFalse(CloudPreferences.synchronised.contains(PublicInvestorPreferences.selectionKey))
    }
}
