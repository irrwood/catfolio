import XCTest
import UIKit
@testable import CatfolioIOS

@MainActor
final class SectorRotationTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sector_rotation_history", withExtension: "json"))
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        return try XCTUnwrap(array.last)
    }
    private func decode(_ object: [String: Any]) throws -> SectorRotationSnapshot {
        try SectorRotationSnapshot.decode(JSONSerialization.data(withJSONObject: object))
    }
    func testNeutralUsesMarketStateRatherThanAnalystRating() {
        let previous = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previous, forKey: AppLanguage.preferenceKey) }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(SectorRotationSnapshot.Sector.label("neutral"), "Neutral")
    }
    func testRealSnapshotLabelsAndTrails() throws {
        let snapshot = try decode(fixture())
        XCTAssertEqual(snapshot.labeledSymbols.count, 4)
        XCTAssertEqual(snapshot.sectors.count, 11)
        XCTAssertTrue(snapshot.sectors.allSatisfy { $0.trail.count == 8 && $0.trail.allSatisfy { $0.date < snapshot.asOf } })
        XCTAssertTrue(snapshot.sectors.allSatisfy { !$0.explanation.isEmpty })
    }
    private func evaluate(_ segment: RotationTrailCurve.Segment, at t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u*u*u*segment.start.x + 3*u*u*t*segment.control1.x + 3*u*t*t*segment.control2.x + t*t*t*segment.end.x,
            y: u*u*u*segment.start.y + 3*u*u*t*segment.control1.y + 3*u*t*t*segment.control2.y + t*t*t*segment.end.y)
    }
    func testAllSavedTrailsStayWithinTheirWeeklyObservations() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sector_rotation_history", withExtension: "json"))
        let snapshots = try JSONDecoder().decode([SectorRotationSnapshot].self, from: Data(contentsOf: url))
        var checked = 0
        for snapshot in snapshots {
            for sector in snapshot.sectors {
                let points = sector.trail.map { CGPoint(x: $0.x, y: $0.y) } + [CGPoint(x: sector.x, y: sector.y)]
                let segments = RotationTrailCurve.segments(through: points)
                XCTAssertEqual(segments.count, points.count - 1)
                for (i, segment) in segments.enumerated() {
                    XCTAssertEqual(segment.start, points[i])
                    XCTAssertEqual(segment.end, points[i+1])
                    // The convex hull of a Bezier curve bounds the entire curve,
                    // including the space between the samples checked below.
                    for point in [segment.control1, segment.control2] {
                        XCTAssertGreaterThanOrEqual(point.x, min(segment.start.x, segment.end.x) - 1e-12)
                        XCTAssertLessThanOrEqual(point.x, max(segment.start.x, segment.end.x) + 1e-12)
                        XCTAssertGreaterThanOrEqual(point.y, min(segment.start.y, segment.end.y) - 1e-12)
                        XCTAssertLessThanOrEqual(point.y, max(segment.start.y, segment.end.y) + 1e-12)
                    }
                    var previous = segment.start
                    for step in 1...32 {
                        let point = evaluate(segment, at: CGFloat(step)/32)
                        XCTAssertLessThanOrEqual(abs(point.x), 2.5 + 1e-12)
                        XCTAssertLessThanOrEqual(abs(point.y), 2.5 + 1e-12)
                        XCTAssertGreaterThanOrEqual((point.x - previous.x) * (segment.end.x - segment.start.x), -1e-12)
                        XCTAssertGreaterThanOrEqual((point.y - previous.y) * (segment.end.y - segment.start.y), -1e-12)
                        previous = point
                    }
                    if i > 0 {
                        let prior = segments[i-1]
                        XCTAssertEqual(prior.end.x - prior.control2.x, segment.control1.x - segment.start.x, accuracy: 1e-12)
                        XCTAssertEqual(prior.end.y - prior.control2.y, segment.control1.y - segment.start.y, accuracy: 1e-12)
                    }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 3000)
    }
    func testCurveHandlesRepeatedPointsAndDirectionChanges() throws {
        XCTAssertTrue(RotationTrailCurve.segments(through: []).isEmpty)
        XCTAssertTrue(RotationTrailCurve.segments(through: [.zero]).isEmpty)
        let pair = try XCTUnwrap(RotationTrailCurve.segments(through: [.zero, CGPoint(x: 3, y: -3)]).first)
        XCTAssertEqual(evaluate(pair, at: 0.5), CGPoint(x: 1.5, y: -1.5))
        let points = [CGPoint(x: -1, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 1)]
        let segments = RotationTrailCurve.segments(through: points)
        for segment in segments {
            XCTAssertEqual(segment.control1.y, 1)
            XCTAssertEqual(segment.control2.y, 1)
        }
        XCTAssertEqual(segments[1].control1, points[1])
        XCTAssertEqual(segments[1].control2, points[2])
        XCTAssertEqual(segments[0].control2, points[1])
        XCTAssertEqual(segments[2].control1, points[2])
    }
    func testXLBAndXLUKnownOvershootsAreRemoved() throws {
        let snapshot = try decode(fixture())
        for (symbol, date, axis, limit) in [("XLB", "2026-08-21", "x", CGFloat(0)), ("XLU", "2026-08-07", "y", CGFloat(-2.5))] {
            let sector = try XCTUnwrap(snapshot.sectors.first { $0.symbol == symbol })
            let index = try XCTUnwrap(sector.trail.firstIndex { $0.date == date })
            let points = sector.trail.map { CGPoint(x: $0.x, y: $0.y) } + [CGPoint(x: sector.x, y: sector.y)]
            let segment = RotationTrailCurve.segments(through: points)[index]
            for step in 0...100 {
                let point = evaluate(segment, at: CGFloat(step)/100)
                if axis == "x" { XCTAssertLessThanOrEqual(point.x, limit) }
                else { XCTAssertGreaterThanOrEqual(point.y, limit) }
            }
        }
    }
    func testUIKitChartUsesNearestPointAndExposesAllSectors() throws {
        let snapshot = try decode(fixture())
        let chart = SectorRotationChartView(frame: CGRect(x: 0, y: 0, width: 370, height: 246))
        chart.configure(snapshot: snapshot, selected: nil)
        for sector in snapshot.sectors {
            XCTAssertEqual(chart.nearestSector(at: chart.point(x: sector.x, y: sector.y))?.symbol, sector.symbol)
        }
        XCTAssertNil(chart.nearestSector(at: .zero))
        XCTAssertEqual(chart.accessibilityElements?.count, 11)
    }
    func testPressFeedbackLiftsAndReleasesWithoutMovingDataCoordinates() async throws {
        let snapshot = try decode(fixture())
        let sector = try XCTUnwrap(snapshot.sectors.first)
        let chart = SectorRotationChartView(frame: CGRect(x: 0, y: 0, width: 370, height: 246))
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        host.view.addSubview(chart)
        defer { chart.clearTouch(); window.isHidden = true }
        chart.configure(snapshot: snapshot, selected: nil)
        let anchor = chart.point(x: sector.x, y: sector.y)
        var selections = 0
        chart.onSelection = { _ in selections += 1 }
        func attach(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: chart.bounds).image { renderer in
                chart.layer.render(in: renderer.cgContext)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
        }
        chart.setNeedsDisplay(); chart.layoutIfNeeded()
        attach("rotation-vector-resting")
        chart.updateTouch(at: anchor)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(chart.pressedSymbol, sector.symbol)
        XCTAssertGreaterThan(chart.lift, 0.5)
        XCTAssertEqual(chart.point(x: sector.x, y: sector.y), anchor)
        XCTAssertEqual(chart.nearestSector(at: anchor)?.symbol, sector.symbol)
        XCTAssertEqual(selections, 0, "Visual touch feedback must not select or scrub data")
        attach("rotation-vector-pressed")
        chart.updateTouch(at: nil)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(chart.lift, 0, accuracy: 0.01)
        XCTAssertNil(chart.pressedSymbol)
        XCTAssertNil(chart.touchLocation)
        chart.updateTouch(at: anchor)
        chart.removeFromSuperview()
        XCTAssertNil(chart.touchLocation, "Navigation away must release the active touch")
        XCTAssertEqual(chart.lift, 0)
    }
    func testTouchFeedbackCannotBlockScrollingOrLongPress() {
        let feedback = RotationTouchFeedbackRecognizer()
        for other in [UIPanGestureRecognizer(), UILongPressGestureRecognizer(), UITapGestureRecognizer()] {
            XCTAssertFalse(feedback.canPrevent(other))
            XCTAssertFalse(feedback.canBePrevented(by: other))
        }
        XCTAssertFalse(feedback.cancelsTouchesInView)
        XCTAssertFalse(feedback.delaysTouchesBegan)
        XCTAssertFalse(feedback.delaysTouchesEnded)
    }
    func testUIKitTimelineBoundsAndVoiceOverAdjustment() {
        let timeline = SectorRotationTimelineControl(frame: CGRect(x: 0, y: 0, width: 300, height: 52))
        timeline.dates = (0..<60).map(String.init)
        XCTAssertEqual(timeline.index(at: -100), 0)
        XCTAssertEqual(timeline.index(at: 150), 30)
        XCTAssertEqual(timeline.index(at: 400), 59)
        var selected: Int?
        timeline.onSelection = { selected = $0 }
        timeline.accessibilityIncrement()
        XCTAssertEqual(selected, 1)
        XCTAssertEqual(timeline.accessibilityValue, "1")
        timeline.accessibilityDecrement()
        timeline.accessibilityDecrement()
        XCTAssertEqual(selected, 0)
    }
    func testPerformancePreservesLastClosePairOnPartialOrOlderRefresh() throws {
        let store = SectorPerformanceStore()
        store.merge(["XLK": ["2026-09-08": 100, "2026-09-09": 102]])
        XCTAssertEqual(try XCTUnwrap(store.markets["XLK"]?.changePercent), 2, accuracy: 0.00001)
        store.merge(["XLK": ["2026-09-10": 103], "XLV": [:]])
        XCTAssertEqual(store.markets["XLK"]?.latest?.id, "2026-09-09")
        store.merge(["XLK": ["2026-09-07": 90, "2026-09-08": 100]])
        XCTAssertEqual(store.markets["XLK"]?.latest?.id, "2026-09-09")
        store.merge(["XLK": ["2026-09-09": 102, "2026-09-10": 100]])
        XCTAssertLessThan(try XCTUnwrap(store.markets["XLK"]?.changePercent), 0)
    }
    func testPerformanceReportsMixedDatesAndAllElevenSectors() {
        let definitions = SectorPerformanceDefinition.all
        XCTAssertEqual(definitions.count, 11)
        XCTAssertEqual(Set(definitions.map(\.symbol)), Set(SectorRotationSnapshot.symbols))
        let store = SectorPerformanceStore()
        XCTAssertNil(store.dateRange)
        store.merge(["XLK": ["2026-09-08": 100, "2026-09-09": 101]])
        XCTAssertEqual(store.dateRange, "2026-09-09")
        store.merge(["XLV": ["2026-09-07": 100, "2026-09-08": 99]])
        XCTAssertEqual(store.dateRange, "2026-09-08–2026-09-09")
    }
    func testRejectsIncompatibleCalculation() throws {
        var object = try fixture(); object["calcVersion"] = 1
        XCTAssertThrowsError(try decode(object))
    }
    func testRejectsDuplicateSectorsAndOutOfBoundsPositions() throws {
        var object = try fixture()
        var sectors = try XCTUnwrap(object["sectors"] as? [[String: Any]])
        sectors[0]["x"] = 9.0; object["sectors"] = sectors
        XCTAssertThrowsError(try decode(object))
        sectors[0] = sectors[1]; object["sectors"] = sectors
        XCTAssertThrowsError(try decode(object))
    }
    func testRejectsFutureTrailPoint() throws {
        var object = try fixture()
        var sectors = try XCTUnwrap(object["sectors"] as? [[String: Any]])
        sectors[0]["trail"] = [["date": "2099-01-01", "x": 0.0, "y": 0.0]]
        object["sectors"] = sectors
        XCTAssertThrowsError(try decode(object))
    }
}
