import XCTest
import SwiftUI
@testable import CatfolioIOS

final class EarningsHistoryTests: XCTestCase {
    func testQuarterLabelsUseReportedPeriodBeforeAnnouncement() {
        let point = EarningsObservation(date: "2026-06-11", period: "May 2026", epsActual: nil, epsEstimated: nil, revenueActual: nil, revenueEstimated: nil)
        XCTAssertEqual(point.quarterLabel, "Q2’26")
        let previousQuarter = EarningsObservation(date: "2026-01-29", period: "Dec 2025", epsActual: nil, epsEstimated: nil, revenueActual: nil, revenueEstimated: nil)
        XCTAssertEqual(previousQuarter.quarterLabel, "Q4’25")
        let fallback = EarningsObservation(date: "2025-07-30", period: nil, epsActual: nil, epsEstimated: nil, revenueActual: nil, revenueEstimated: nil)
        XCTAssertEqual(fallback.quarterLabel, "Q3’25")
    }

    func testNumbersPreserveZeroNegativeAndOneButRejectBoolean() {
        XCTAssertEqual(EarningsObservation.number(NSNumber(value: 1)), 1)
        XCTAssertEqual(EarningsObservation.number(NSNumber(value: 0)), 0)
        XCTAssertEqual(EarningsObservation.number("-0.12"), -0.12)
        XCTAssertEqual(EarningsObservation.number("$1,234.5"), 1234.5)
        XCTAssertNil(EarningsObservation.number(NSNumber(value: true)))
        XCTAssertNil(EarningsObservation.number(NSNull()))
        XCTAssertNil(EarningsObservation.number("N/A"))
        XCTAssertNil(EarningsObservation.number(Double.infinity))
    }

    func testFMPFiltersIdentityDatesAndKeepsLatestRevision() {
        let rows: [[String: Any]] = [
            ["symbol": "AAPL", "date": "2025-10-30", "epsActual": 1.2, "lastUpdated": "2025-10-31"],
            ["symbol": "AAPL", "date": "2025-10-30", "epsActual": 1.3, "epsEstimated": 1, "lastUpdated": "2025-11-01"],
            ["symbol": "MSFT", "date": "2025-09-30", "epsActual": 2],
            ["symbol": "AAPL", "date": "2025-02-30", "epsActual": 2],
            ["symbol": "AAPL", "date": "2026-01-29", "epsActual": NSNull(), "epsEstimated": 2.5]
        ]
        let result = EarningsObservation.fmp(rows, symbol: "aapl")
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].epsActual, 1.3)
        XCTAssertNil(result[0].period, "An announcement date is not a fiscal quarter")
        XCTAssertNil(result[1].epsActual, "Future estimates must not become actual zeroes")
        XCTAssertEqual(result[1].epsEstimated, 2.5)
        XCTAssertNil(result[1].revenueEstimated)
    }

    func testNasdaqDecodesFiscalLabelAndMissingRevenue() throws {
        let bytes = Data(#"{"status":{"rCode":200},"data":{"earningsSurpriseTable":{"rows":[{"fiscalQtrEnd":"Jun 2026","dateReported":"7/30/2026","eps":1.91,"consensusForecast":"1.88"},{"dateReported":"4/30/2026","eps":0,"consensusForecast":"-0.01"}]}}}"#.utf8)
        let rows = try EarningsObservation.nasdaq(bytes)
        XCTAssertEqual(rows.map(\.date), ["2026-04-30", "2026-07-30"])
        XCTAssertEqual(rows[0].epsActual, 0)
        XCTAssertEqual(rows[1].period, "Jun 2026")
        XCTAssertNil(rows[1].revenueActual)
        XCTAssertThrowsError(try EarningsObservation.nasdaq(Data(#"{"status":{"rCode":400},"data":null}"#.utf8)))
    }

    func testDiskSnapshotSurvivesClientRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshots.json")
        let expected = EarningsSnapshot(observations: [], source: "test", fetchedAt: Date(), note: nil)
        try JSONEncoder().encode(["AAPL": expected]).write(to: url)
        let client = EarningsHistoryClient(cacheURL: url)
        let restored = await client.cached(symbol: "aapl")
        XCTAssertEqual(restored?.source, "test")
    }
    @MainActor
    func testRenderBothMetrics() async throws {
        var points: [EarningsObservation] = []
        for index in 0..<16 {
            let date = String(format: "%04d-%02d-25", 2023 + (index + 3) / 4, ((index + 3) % 4) * 3 + 1)
            let estimate = Double(index) / 10.0
            let actual = estimate + (index % 3 == 0 ? -0.3 : 0.3)
            points.append(EarningsObservation(date: date, period: nil, epsActual: actual, epsEstimated: estimate,
                revenueActual: Double(index + 10) * 1e9, revenueEstimated: Double(index + 11) * 1e9))
        }
        let snapshot = EarningsSnapshot(observations: points, source: "TEST FIXTURE", fetchedAt: Date(timeIntervalSince1970: 1788900000), note: nil)
        for revenue in [false, true] {
            let content = EarningsHistoryView(symbol: "TEST", initialSnapshot: snapshot, initialRevenue: revenue,
                                              initiallyExpanded: true)
                .padding(16).frame(width: 390).background(Color(uiColor: .systemBackground))
            let controller = UIHostingController(rootView: content)
            let size = controller.sizeThatFits(in: CGSize(width: 390, height: 900))
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = controller
            window.isHidden = false
            controller.view.frame = window.bounds
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            window.isHidden = true
            XCTAssertEqual(image.size.width, 390)
            let attachment = XCTAttachment(image: image)
            attachment.name = revenue ? "Earnings-Revenue" : "Earnings-EPS"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testLiveDeviceNasdaqRead() async throws {
        guard ProcessInfo.processInfo.environment["CATFOLIO_LIVE_EARNINGS"] == "1" else {
            throw XCTSkip("Opt-in live provider smoke test")
        }
        var request = URLRequest(url: URL(string: "https://api.nasdaq.com/api/company/AAPL/earnings-surprise")!)
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let points = try EarningsObservation.nasdaq(data)
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(points.contains { $0.epsActual != nil && $0.epsEstimated != nil })
    }

}
