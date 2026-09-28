import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class PortfolioRefreshNoticeTests: XCTestCase {
    func testLongToastFitsNarrowScreenAtLargeText() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView:
            ToastBubble(toast: AppToast(message: "No new quotes received. Continuing to show existing data.", kind: .info),
                        maximumWidth: 288, onFinish: {})
                .environment(\.dynamicTypeSize, .accessibility3)
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(1100))
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 1000))
        XCTAssertLessThanOrEqual(size.width, 288.5)
        XCTAssertGreaterThan(size.height, 44, "Long text must wrap instead of clipping into one line")
    }

    func testRefreshResultsUseSharedToastKinds() {
        let cases: [(PortfolioRefreshResult, AppToast.Kind)] = [
            (.quotesUpdated, .success),
            (.portfolioLoaded, .success),
            (.portfolioLoadedWithoutNewQuotes, .info),
            (.unchangedQuotes, .info),
            (.unchangedContent, .info),
            (.noHeldQuotes, .info),
            (.failed(retainsData: true), .error),
            (.failed(retainsData: false), .error),
        ]
        for (result, expected) in cases {
            XCTAssertEqual(result.toastKind, expected)
            XCTAssertFalse(result.noticeText.isEmpty)
        }
    }

    func testFinishingReplacedToastDoesNotDismissCurrentToast() throws {
        let center = ToastCenter()
        defer { if let id = center.current?.id { center.finish(id) } }
        center.show(PortfolioRefreshResult.quotesUpdated.noticeText)
        let first = try XCTUnwrap(center.current)
        center.show(PortfolioRefreshResult.unchangedQuotes.noticeText, kind: .info)
        let replacement = try XCTUnwrap(center.current)
        center.finish(first.id)
        XCTAssertEqual(center.current, replacement)
        center.finish(replacement.id)
        XCTAssertNil(center.current)
    }
}
