import XCTest
@testable import CatfolioIOS

/// The measurement table's grouping and export, which is what makes a phone run
/// readable. The frame numbers themselves come from a real device; these check
/// that what it records is bucketed and pasted the way the panel promises.
final class SecurityDetailMeasureTests: XCTestCase {

    private func measurement(
        _ variant: String,
        contentMs: Double?,
        worstMs: Double = 20,
        over33: Int = 0,
        over66: Int = 0,
        tag: String = "real-page",
        reason: String = "data"
    ) -> SecurityDetailMeasure.Measurement {
        SecurityDetailMeasure.Measurement(
            variant: variant, reason: reason, contentTag: tag,
            contentMs: contentMs, dataMs: contentMs, frames: 20,
            worstMs: worstMs, over16: 5, over33: over33, over66: over66, ratioPct: 25)
    }

    @MainActor
    func testFirstOpenOfEachVariantIsColdAndTheRestAreWarm() {
        SecurityDetailMeasure.reset()
        // Three opens of A, then three of the native zoom: each variant's first
        // is the cold one, so the second block is warm.
        for _ in 0..<3 {
            SecurityDetailMeasure.record(measurement("snapshot-a", contentMs: 600))
        }
        for _ in 0..<3 {
            SecurityDetailMeasure.record(measurement("native-zoom", contentMs: 100))
        }

        let summaries = SecurityDetailMeasure.summaries
        XCTAssertEqual(summaries.count, 4, "one bucket per variant and warmth")

        let aCold = summaries.first { $0.variant == "snapshot-a" && $0.group == "cold" }
        let aWarm = summaries.first { $0.variant == "snapshot-a" && $0.group == "warm" }
        let zoomCold = summaries.first { $0.variant == "native-zoom" && $0.group == "cold" }
        let zoomWarm = summaries.first { $0.variant == "native-zoom" && $0.group == "warm" }

        XCTAssertEqual(aCold?.opens, 1)
        XCTAssertEqual(aWarm?.opens, 2)
        XCTAssertEqual(zoomCold?.opens, 1)
        XCTAssertEqual(zoomWarm?.opens, 2)
    }

    @MainActor
    func testSummaryAveragesContentAndWorstCasePerBucket() {
        SecurityDetailMeasure.reset()
        // Cold: 600. Warm: 400 and 600, so the average is the point of the row.
        SecurityDetailMeasure.record(measurement("snapshot-a", contentMs: 600, worstMs: 90, over33: 2, over66: 1))
        SecurityDetailMeasure.record(measurement("snapshot-a", contentMs: 400, worstMs: 30, over33: 0))
        SecurityDetailMeasure.record(measurement("snapshot-a", contentMs: 600, worstMs: 50, over33: 1))

        let warm = SecurityDetailMeasure.summaries.first { $0.variant == "snapshot-a" && $0.group == "warm" }
        XCTAssertEqual(warm?.contentMs ?? 0, 500, accuracy: 0.01)
        XCTAssertEqual(warm?.worstMs ?? 0, 50, accuracy: 0.01, "the worst frame of the bucket, not the average")
        XCTAssertEqual(warm?.over33, 1, "hitches add up across the bucket")
        XCTAssertEqual(warm?.over66, 0)
    }

    @MainActor
    func testExportIsTabSeparatedWithAHeaderAndBlanksForMissingTimes() {
        SecurityDetailMeasure.reset()
        SecurityDetailMeasure.record(measurement("snapshot-a", contentMs: 600, worstMs: 95, over33: 2, over66: 1))
        // The 1.5s deadline can end an open before any data arrives.
        SecurityDetailMeasure.record(measurement("snapshot-a", contentMs: nil, reason: "window"))

        let lines = SecurityDetailMeasure.exportText.split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "header plus one line per open")
        XCTAssertEqual(lines[0].split(separator: "\t").count, 11)
        XCTAssertEqual(lines[1].split(separator: "\t").count, 11, "every row keeps the column count")

        let columns = lines[2].split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(columns.count, 11)
        XCTAssertEqual(columns[3], "", "a missing time is an empty cell, not a zero")
        XCTAssertEqual(columns[1], "window")
    }

    @MainActor
    func testResetEmptiesBothTheTableAndItsSummaries() {
        SecurityDetailMeasure.reset()
        SecurityDetailMeasure.record(measurement("snapshot-a", contentMs: 600))
        XCTAssertFalse(SecurityDetailMeasure.results.isEmpty)
        XCTAssertFalse(SecurityDetailMeasure.summaries.isEmpty)

        SecurityDetailMeasure.reset()
        XCTAssertTrue(SecurityDetailMeasure.results.isEmpty)
        XCTAssertTrue(SecurityDetailMeasure.summaries.isEmpty)
    }

    @MainActor
    func testMeasurementIsOffWithNoArgumentAndNoPreference() {
        // The shipped default: an ordinary install records nothing and draws
        // no panel row. Both doors are shut when neither key is present.
        let stored = UserDefaults.standard.object(forKey: SecurityDetailMeasure.preferenceKey)
        UserDefaults.standard.removeObject(forKey: SecurityDetailMeasure.preferenceKey)
        defer {
            if let stored { UserDefaults.standard.set(stored, forKey: SecurityDetailMeasure.preferenceKey) }
        }

        XCTAssertFalse(ProcessInfo.processInfo.arguments.contains(SecurityDetailMeasure.launchArgument))
        XCTAssertFalse(SecurityDetailMeasure.isEnabled, "no argument and no preference means off")
        XCTAssertFalse(SecurityDetailMeasure.isAutoDriving)
    }
}
