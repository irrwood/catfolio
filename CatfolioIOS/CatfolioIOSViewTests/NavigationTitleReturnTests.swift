import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class NavigationTitleReturnTests: XCTestCase {
    func testExpandedAccountTitleDoesNotJumpWhenOpeningInlineSubpages() async throws {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            for investorPage in [false, true] {
                try await checkReturn(appearance: appearance, parentScrolled: false,
                                      investorPage: investorPage, checksPush: true)
            }
        }
    }

    func testScrolledChildReturnsWithoutMovingTheExpandedAccountTitle() async throws {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            try await checkReturn(appearance: appearance, parentScrolled: false)
        }
    }

    func testScrolledAccountKeepsItsCompactTitleAndReadingPositionOnReturn() async throws {
        for appearance in [UIUserInterfaceStyle.light, .dark] {
            try await checkReturn(appearance: appearance, parentScrolled: true)
        }
    }

    private func checkReturn(appearance: UIUserInterfaceStyle, parentScrolled: Bool,
                             investorPage: Bool = false, checksPush: Bool = false) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "navigation-title-return-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "catfolio.fakeDataMode")
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        let document = FakePortfolioGenerator.make()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { document })
        await model.refreshPortfolio(refreshMarketData: false)
        let route = Route()
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = appearance
        let host = UIHostingController(rootView: TabView {
            Tab("Account", systemImage: "person") {
                RootPageNavigation {
                    SettingsView().ownsTabBar()
                        .navigationDestination(isPresented: Binding(
                            get: { route.showsChild }, set: { route.showsChild = $0 }
                        )) {
                            if investorPage { PublicInvestorSelectionView() }
                            else { AppSettingsView() }
                        }
                }
            }
            Tab("Other", systemImage: "circle") { Text("Other") }
        }.environment(model).defaultAppStorage(defaults))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(500))
        let navigation = try XCTUnwrap(findNavigation(host))
        let root = try XCTUnwrap(navigation.topViewController)
        let rootScroll = try XCTUnwrap(root.contentScrollView(for: .top))
        let title = L10n.text("账户")
        if parentScrolled {
            let maximum = rootScroll.contentSize.height - rootScroll.bounds.height + rootScroll.adjustedContentInset.bottom
            let offset = min(maximum, -rootScroll.adjustedContentInset.top + 140)
            rootScroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertLessThan(navigation.navigationBar.bounds.height, 70)
        }
        let initialOffset = rootScroll.contentOffset
        let initialBarHeight = navigation.navigationBar.bounds.height
        let initialTitle = parentScrolled ? nil : try XCTUnwrap(largeTitle(title, in: root.view))
        let expectedTitle = initialTitle.map { $0.convert($0.bounds, to: window) }

        // Exercise a scrolled child on the first return, then an unscrolled
        // child. Reusing an already-returned title used to mask the first jump.
        for childOffset in checksPush ? [CGFloat(300)] : [CGFloat(300), 0] {
            let outgoingTitle = parentScrolled ? nil : try XCTUnwrap(largeTitle(title, in: root.view))
            route.showsChild = true
            if checksPush, let outgoingTitle, let expectedTitle {
                var frames: [CGRect] = []
                var activeTitle = outgoingTitle
                for tick in 0..<30 {
                    try await Task.sleep(for: .milliseconds(20))
                    if activeTitle.window == nil, let replacement = largeTitle(title, in: root.view) {
                        activeTitle = replacement
                    }
                    guard activeTitle.window != nil else { continue }
                    let layer = activeTitle.layer.presentation() ?? activeTitle.layer
                    frames.append(layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer))
                    if tick == 5 {
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                        }
                        try image.pngData()?.write(to: URL(fileURLWithPath:
                            "/tmp/catfolio-title-push-\(appearance.rawValue)-\(investorPage).png"))
                    }
                }
                XCTAssertGreaterThan(frames.count, 5)
                let drift = frames.map { abs($0.minY - expectedTitle.minY) }.max() ?? .infinity
                XCTAssertLessThanOrEqual(drift, 2,
                    "Opening an inline page must not pull the outgoing large title up: \(frames.map(\.minY))")
            } else {
                try await Task.sleep(for: .milliseconds(600))
            }
            let child = try XCTUnwrap(navigation.topViewController)
            XCTAssertFalse(child === root)
            let scroll = try XCTUnwrap(child.contentScrollView(for: .top))
            scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top + childOffset), animated: false)
            try await Task.sleep(for: .milliseconds(200))
            navigation.popViewController(animated: true)
            var activeLabel: UILabel?
            var titleFrames: [CGRect] = []
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(20))
                if !parentScrolled {
                    // Native titles are rebuilt on return. Search only the
                    // incoming page, then retain that label while sampling.
                    if activeLabel?.window == nil { activeLabel = largeTitle(title, in: root.view) }
                    if let label = activeLabel {
                        let layer = label.layer.presentation() ?? label.layer
                        titleFrames.append(layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer))
                    }
                }
            }
            if let expectedTitle {
                XCTAssertGreaterThan(titleFrames.count, 15)
                let drift = titleFrames.map { abs($0.minY - expectedTitle.minY) }.max() ?? .infinity
                XCTAssertLessThanOrEqual(drift, 2,
                    "The title must keep its vertical position throughout the native horizontal return")
                XCTAssertEqual(try XCTUnwrap(titleFrames.last).minX, expectedTitle.minX, accuracy: 1)
            }
            XCTAssertTrue(navigation.topViewController === root)
            XCTAssertTrue(root.contentScrollView(for: .top) === rootScroll)
            XCTAssertEqual(rootScroll.contentOffset.y, initialOffset.y, accuracy: 1)
            XCTAssertEqual(navigation.navigationBar.bounds.height, initialBarHeight, accuracy: 1)
        }
    }

    @Observable final class Route { var showsChild = false }

    private func findNavigation(_ controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap(findNavigation).first
    }

    private func largeTitle(_ title: String, in view: UIView) -> UILabel? {
        if let label = view as? UILabel, label.text == title, label.font.pointSize >= 30 { return label }
        return view.subviews.lazy.compactMap { self.largeTitle(title, in: $0) }.first
    }
}
