import XCTest
@testable import CatfolioIOS

@MainActor
final class HoldingHistoryLoadingTests: XCTestCase {
    private func history(_ value: Double = 120) -> HoldingValueHistory {
        .init(rows: [
            .init(dateText: "2026-01-01", cost: 100, values: ["A": 100]),
            .init(dateText: DayDateCodec.string(from: Date()), cost: 100, values: ["A": value])
        ], costs: ["A": 100], names: ["A": "Alpha"])
    }

    func testRefreshRetainsHistoryAndDoesNotInvalidateUnchangedData() async throws {
        let state = HoldingHistoryState()
        let saved = history()
        await state.load { _ in saved }
        let revision = state.revision
        let began = expectation(description: "Cache read suspended")
        var resume: CheckedContinuation<HoldingValueHistory, Never>?
        let refresh = Task {
            await state.load { _ in
                await withCheckedContinuation { resume = $0; began.fulfill() }
            }
        }
        await fulfillment(of: [began], timeout: 2)
        XCTAssertEqual(state.history, saved, "A background read must not clear the visible curve")
        XCTAssertEqual(state.revision, revision)
        resume?.resume(returning: saved)
        await refresh.value
        XCTAssertEqual(state.revision, revision, "Identical data must not trigger another preparation")
    }

    func testFailedRefreshAndSnapshotCannotEraseCompleteHistory() async {
        let state = HoldingHistoryState()
        let saved = history()
        await state.load { _ in saved }
        await state.load(forceRefresh: true) { _ in throw LocalServiceError.noHistoricalPrices }
        XCTAssertEqual(state.history, saved)
        XCTAssertNil(state.errorMessage)
        await state.load(forceRefresh: true) { _ in
            .init(rows: [saved.rows.last!], costs: saved.costs, names: saved.names)
        }
        XCTAssertEqual(state.history, saved)
    }

    func testSupersededRequestCannotReplaceNewData() async {
        let state = HoldingHistoryState()
        let older = history(110), latest = history(180)
        let began = expectation(description: "Old request suspended")
        var resume: CheckedContinuation<HoldingValueHistory, Never>?
        let old = Task {
            await state.load { _ in
                await withCheckedContinuation { resume = $0; began.fulfill() }
            }
        }
        await fulfillment(of: [began], timeout: 2)
        await state.load { _ in latest }
        resume?.resume(returning: older)
        await old.value
        XCTAssertEqual(state.history, latest)
    }
}
