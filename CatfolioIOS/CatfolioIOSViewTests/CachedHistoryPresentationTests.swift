import SwiftUI
import XCTest
@testable import CatfolioIOS

final class CachedHistoryPresentationTests: XCTestCase {
    func testHomeRetainsCompleteCurveOverSnapshotOnlyRefresh() {
        let complete = prepared([
            .init(dateText: "2026-10-01", marketValue: 100, cost: 80),
            .init(dateText: "2026-10-02", marketValue: 110, cost: 80)
        ])
        let snapshot = prepared([.init(dateText: "2026-10-02", marketValue: 110, cost: 80)])
        XCTAssertFalse(CostMarketPreparedData.shouldReplace(complete, with: snapshot))
        XCTAssertTrue(CostMarketPreparedData.shouldReplace(nil, with: snapshot))
        XCTAssertTrue(CostMarketPreparedData.shouldReplace(snapshot, with: complete))
        XCTAssertEqual(snapshot.data(for: .maximum).rows.count, 1)
        XCTAssertEqual(snapshot.data(for: .maximum).rows.first?.marketValue, 110)
    }

    @MainActor
    func testSourcePagesRenderCachedSnapshotFigures() async throws {
        let history = HoldingValueHistory(rows: [.init(dateText: "2026-10-02", cost: 80,
            values: ["AAPL": 110], costs: ["AAPL": 80])], costs: ["AAPL": 80], names: ["AAPL": "Apple"])
        for loss in [false, true] {
            let host = UIHostingController(rootView: ScrollView {
                if loss { LossAnalysisChart(fetchHistory: { _ in history }) }
                else { HoldingContributionChart(fetchHistory: { _ in history }) }
            }.environment(AppModel()))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            host.view.layoutIfNeeded()
            let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = loss ? "Cached-loss-snapshot" : "Cached-income-snapshot"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(host.view.bounds.height, 300)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
    }

    private func prepared(_ rows: [ChartPoint]) -> CostMarketPreparedData {
        let response = PortfolioChartResponse(positionCount: 1,
            positionHistory: .init(available: rows.count > 1, rows: rows), currentPoint: rows.last!, warning: nil)
        return CostMarketPreparedData(source: .init(response: response))
    }
}
