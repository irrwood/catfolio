import XCTest
@testable import CatfolioIOS

/// The heatmap plane's run-in: it leaves the cruise speed, runs faster, and
/// settles back into the cruise without a jolt at either end.
final class HeatmapHeroDriftTests: XCTestCase {
    func testTheRunInSpeedsUpAndSettlesBackToTheCruise() {
        let start = Date(timeIntervalSince1970: 1_000)
        var drift = HeatmapHeroDrift()
        drift.beginIntro(at: start)
        let duration = HeatmapHeroDrift.introDuration
        func extra(_ t: Double) -> Double { drift.introTravel(at: start.addingTimeInterval(t)) }

        XCTAssertEqual(extra(0), 0)
        XCTAssertEqual(extra(duration), HeatmapHeroDrift.introBoost * HeatmapHeroDrift.speed * duration / 2,
                       accuracy: 0.001)
        XCTAssertEqual(extra(duration + 5), extra(duration), "Afterwards only the cruise moves it")

        let step = 0.01
        func speed(at t: Double) -> Double { (extra(t + step) - extra(t)) / step }
        XCTAssertLessThan(speed(at: 0), 1, "No jolt as it starts")
        XCTAssertLessThan(speed(at: duration - step), 1, "No jolt as it settles")
        XCTAssertGreaterThan(speed(at: duration / 2), HeatmapHeroDrift.speed * 5, "Fastest in the middle")
        var previous = -1.0
        for t in stride(from: 0, through: duration, by: 0.1) {
            XCTAssertGreaterThanOrEqual(extra(t), previous, "It never runs backwards")
            previous = extra(t)
        }
    }

    func testOnlyTheFirstRunInCounts() {
        let start = Date(timeIntervalSince1970: 1_000)
        var once = HeatmapHeroDrift()
        once.beginIntro(at: start)
        var twice = once
        twice.beginIntro(at: start.addingTimeInterval(1))
        let later = start.addingTimeInterval(0.5)
        XCTAssertEqual(twice.introTravel(at: later), once.introTravel(at: later))
    }
}
