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
    func testPressFeedbackLiftsAndReleasesWithoutMovingDataCoordinates() throws {
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
        // Drive frames explicitly; simulator refresh scheduling is not the contract under test.
        for _ in 0..<15 { chart.advanceTouchFeedback(by: 1.0 / 60) }
        XCTAssertEqual(chart.pressedSymbol, sector.symbol)
        XCTAssertGreaterThan(chart.lift, 0.5)
        XCTAssertEqual(chart.point(x: sector.x, y: sector.y), anchor)
        XCTAssertEqual(chart.nearestSector(at: anchor)?.symbol, sector.symbol)
        XCTAssertEqual(selections, 0, "Visual touch feedback must not select or scrub data")
        attach("rotation-vector-pressed")
        chart.updateTouch(at: nil)
        for _ in 0..<48 { chart.advanceTouchFeedback(by: 1.0 / 60) }
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
        timeline.centersSelection = true
        timeline.dates = (0..<60).map(String.init)
        timeline.index = 30
        XCTAssertEqual(timeline.index(at: -500), 0)
        XCTAssertEqual(timeline.index(at: 150), 30)
        XCTAssertEqual(timeline.index(at: 159), 31)
        XCTAssertEqual(timeline.index(at: 500), 59)
        timeline.index = 0
        var selected: Int?
        timeline.onSelection = { selected = $0 }
        timeline.accessibilityIncrement()
        XCTAssertEqual(selected, 1)
        XCTAssertEqual(timeline.accessibilityValue, "1")
        timeline.accessibilityDecrement()
        timeline.accessibilityDecrement()
        XCTAssertEqual(selected, 0)
    }
    func testTimelineScrubsRelativeToStartingDateAndPausesImmediately() {
        let timeline = SectorRotationTimelineControl(frame: CGRect(x: 0, y: 0, width: 370, height: 52))
        timeline.centersSelection = true
        timeline.dates = (0..<60).map(String.init)
        timeline.index = 59
        var interactions = 0
        var selections: [Int] = []
        timeline.onInteraction = { interactions += 1 }
        timeline.onSelection = { selections.append($0) }
        timeline.beginScrubbing()
        XCTAssertEqual(interactions, 1, "Touching the ruler pauses playback even before the date changes")
        timeline.scrub(translation: 9)
        XCTAssertEqual(timeline.index, 58)
        timeline.scrub(translation: 27)
        XCTAssertEqual(timeline.index, 56, "Selection updates must not shift the drag origin")
        timeline.scrub(translation: 1000)
        XCTAssertEqual(timeline.index, 0)
        timeline.scrub(translation: -1000)
        XCTAssertEqual(timeline.index, 59)
        timeline.endScrubbing()
        XCTAssertEqual(timeline.index(at: 185), 59)
        XCTAssertEqual(selections, [58, 56, 0, 59])
        timeline.beginScrubbing()
        timeline.scrub(translation: 18)
        timeline.endScrubbing()
        XCTAssertEqual(timeline.index, 57)
        XCTAssertEqual(timeline.accessibilityValue, "57")
    }
    func testTimelineEmptyAndSingleSnapshotCannotSelectInvalidDate() {
        let timeline = SectorRotationTimelineControl(frame: CGRect(x: 0, y: 0, width: 370, height: 52))
        timeline.centersSelection = true
        var selections: [Int] = []
        timeline.onSelection = { selections.append($0) }
        timeline.beginScrubbing()
        timeline.scrub(translation: 900)
        timeline.accessibilityIncrement()
        XCTAssertTrue(selections.isEmpty)
        timeline.dates = ["2026-09-18"]
        timeline.beginScrubbing()
        timeline.scrub(translation: -900)
        timeline.endScrubbing()
        XCTAssertEqual(timeline.index(at: -900), 0)
        XCTAssertEqual(timeline.index(at: 900), 0)
        timeline.accessibilityIncrement()
        XCTAssertEqual(selections, [0])
    }
    func testTimelineHapticsOnlyFireWhenManualSelectionChanges() {
        let timeline = SectorRotationTimelineControl(frame: CGRect(x: 0, y: 0, width: 370, height: 52))
        let feedback = TimelineFeedbackSpy()
        timeline.selectionFeedback = feedback
        timeline.centersSelection = true
        timeline.dates = (0..<60).map(String.init)
        timeline.index = 59
        XCTAssertEqual(feedback.changes, 0, "Loading or playback must not vibrate")
        timeline.beginScrubbing()
        timeline.scrub(translation: 2)
        XCTAssertEqual(feedback.changes, 0)
        timeline.scrub(translation: 9)
        timeline.scrub(translation: 10)
        XCTAssertEqual(feedback.changes, 1)
        timeline.scrub(translation: -900)
        timeline.scrub(translation: -1000)
        XCTAssertEqual(feedback.changes, 2, "Holding against the boundary must not repeat feedback")
        timeline.endScrubbing()
        timeline.accessibilityDecrement()
        XCTAssertEqual(feedback.changes, 3)
    }
    func testTimelineCoastsWithEaseOutAndSnapsToADate() {
        let timeline = SectorRotationTimelineControl(frame: CGRect(x: 0, y: 0, width: 370, height: 52))
        timeline.centersSelection = true
        timeline.reducesMotion = false
        timeline.dates = (0..<60).map(String.init)
        timeline.index = 30
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        host.view.addSubview(timeline)
        defer { timeline.removeFromSuperview(); window.isHidden = true }
        var selections: [Int] = []
        timeline.onSelection = { selections.append($0) }
        timeline.beginScrubbing()
        timeline.scrub(translation: 18)
        timeline.endScrubbing(velocity: 450)
        XCTAssertTrue(timeline.isAnimating)
        XCTAssertEqual(timeline.position, 28)
        timeline.advanceAnimation(by: 0.05)
        let firstPosition = timeline.position
        let echoedIndex = timeline.index
        timeline.index = echoedIndex
        XCTAssertEqual(timeline.position, firstPosition, "SwiftUI state echoes must not interrupt the animation")
        timeline.advanceAnimation(by: 0.05)
        XCTAssertGreaterThan(28 - firstPosition, firstPosition - timeline.position, "Equal frame intervals travel less distance as the ruler slows")
        timeline.advanceAnimation(by: 1)
        XCTAssertEqual(timeline.position, 20)
        XCTAssertEqual(timeline.index, 20)
        XCTAssertEqual(selections.last, 20)
        XCTAssertFalse(timeline.isAnimating)

        timeline.beginScrubbing()
        timeline.scrub(translation: 4)
        timeline.endScrubbing(velocity: 0)
        timeline.advanceAnimation(by: 1)
        XCTAssertEqual(timeline.position, CGFloat(timeline.index), "Even a slow release settles onto a whole tick")
        timeline.index = 1
        timeline.advanceAnimation(by: 1)
        timeline.beginScrubbing()
        timeline.endScrubbing(velocity: 2000)
        timeline.advanceAnimation(by: 1)
        XCTAssertEqual(timeline.position, 0, "A fast fling must stop at the earliest date")
        timeline.index = 58
        timeline.advanceAnimation(by: 1)
        timeline.beginScrubbing()
        timeline.endScrubbing(velocity: -2000)
        timeline.advanceAnimation(by: 1)
        XCTAssertEqual(timeline.position, 59, "A fast fling must stop at the latest date")
    }
    func testTimelineMotionCanBeInterruptedAndRespectsReducedMotion() {
        let timeline = SectorRotationTimelineControl(frame: CGRect(x: 0, y: 0, width: 370, height: 52))
        timeline.centersSelection = true
        timeline.reducesMotion = false
        timeline.dates = (0..<60).map(String.init)
        timeline.index = 30
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = host
        window.isHidden = false
        host.view.addSubview(timeline)
        defer { timeline.removeFromSuperview(); window.isHidden = true }
        timeline.beginScrubbing()
        timeline.endScrubbing(velocity: 450)
        timeline.advanceAnimation(by: 0.04)
        let movingPosition = timeline.position
        timeline.beginScrubbing()
        timeline.scrub(translation: 0)
        XCTAssertEqual(timeline.position, movingPosition, "A new touch catches the moving ruler without jumping")
        XCTAssertFalse(timeline.isAnimating)
        timeline.endScrubbing(velocity: 450)
        timeline.isPlaying = true
        let resumedIndex = timeline.index
        timeline.advanceAnimation(by: 1)
        XCTAssertEqual(timeline.index, resumedIndex)
        XCTAssertFalse(timeline.isAnimating, "Resuming playback cancels the pending manual coast")
        timeline.isPlaying = false
        timeline.index = 40
        XCTAssertTrue(timeline.isAnimating)
        timeline.reducesMotion = true
        XCTAssertFalse(timeline.isAnimating)
        XCTAssertEqual(timeline.position, 40)
        timeline.beginScrubbing()
        timeline.scrub(translation: 9)
        timeline.endScrubbing(velocity: 2000)
        XCTAssertEqual(timeline.index, 39, "Reduced motion disables inertial travel")
        XCTAssertFalse(timeline.isAnimating)
        timeline.reducesMotion = false
        timeline.index = 50
        XCTAssertTrue(timeline.isAnimating)
        timeline.removeFromSuperview()
        XCTAssertFalse(timeline.isAnimating, "Leaving the page stops the display link")
    }
    func testTimelineEdgeFadesAreSymmetricInBothAppearances() {
        let timeline = SectorRotationTimelineControl(frame: CGRect(x: 0, y: 0, width: 370, height: 52))
        timeline.centersSelection = true
        timeline.dates = (0..<60).map(String.init)
        timeline.index = 30
        for x in stride(from: CGFloat(0), through: 185, by: 5) {
            XCTAssertEqual(timeline.edgeOpacity(at: x), timeline.edgeOpacity(at: 370 - x), accuracy: 0.001)
        }
        XCTAssertEqual(timeline.edgeOpacity(at: 185), 1)
        XCTAssertEqual(timeline.edgeOpacity(at: 0), 0)
        XCTAssertGreaterThan(timeline.edgeOpacity(at: 110), timeline.edgeOpacity(at: 70))
        for style in [UIUserInterfaceStyle.light, .dark] {
            timeline.overrideUserInterfaceStyle = style
            UITraitCollection(userInterfaceStyle: style).performAsCurrent {
                let image = UIGraphicsImageRenderer(bounds: timeline.bounds).image { context in
                    UIColor.systemBackground.setFill()
                    context.fill(timeline.bounds)
                    timeline.draw(timeline.bounds)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = style == .light ? "rotation-ruler-both-edges-light" : "rotation-ruler-both-edges-dark"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
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

private final class TimelineFeedbackSpy: UISelectionFeedbackGenerator {
    var changes = 0
    override func selectionChanged() { changes += 1 }
    override func prepare() {}
}
