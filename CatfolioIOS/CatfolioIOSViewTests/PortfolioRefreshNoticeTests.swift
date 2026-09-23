import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class PortfolioRefreshNoticeTests: XCTestCase {
    func testManualResultFitsNarrowHomeAtLargeText() {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let previous = scene.windows.first(where: \.isKeyWindow)
        for result: PortfolioRefreshResult in [.quotesUpdated, .unchangedQuotes, .failed(retainsData: true)] {
            let host = UIHostingController(rootView: VStack(spacing: 0) {
                PortfolioRefreshNotice(result: result).padding(.horizontal, 20)
                Spacer(minLength: 0)
            }
                .frame(width: 320, height: 300)
                .environment(\.dynamicTypeSize, .accessibility3))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            XCTAssertLessThanOrEqual(host.view.bounds.width, 320.5)
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            })
            attachment.name = "Home refresh notice - \(result)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
    }
}
