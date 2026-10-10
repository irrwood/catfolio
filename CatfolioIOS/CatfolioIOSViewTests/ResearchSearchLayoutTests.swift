import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class ResearchSearchLayoutTests: XCTestCase {
    func testResearchOpensWithSearchAtTopAndNoTitle() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "research-search-layout-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        await model.refreshPortfolio(refreshMarketData: false)
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey)
        }
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            let host = UIHostingController(rootView: NavigationStack { ResearchView() }
                .environment(model)
                .environment(\.locale, Locale(identifier: language)))
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            host.view.layoutIfNeeded()
            let bar = try XCTUnwrap(find(UINavigationBar.self, in: host.view))
            XCTAssertEqual(bar.topItem?.title ?? "", "")
            let search = try XCTUnwrap(find(UISearchTextField.self, in: host.view))
            let frame = search.convert(search.bounds, to: window)
            XCTAssertGreaterThan(frame.width, 200)
            XCTAssertLessThan(frame.minY, window.safeAreaInsets.top + 60,
                              "Search must be the first control, without a large title above it")
            XCTAssertTrue(search.isUserInteractionEnabled)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "research-search-\(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/research-search-\(language).png"))
        }
    }

    private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }
}
