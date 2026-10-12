import SwiftUI
import UIKit
import Vision
import XCTest
@testable import CatfolioIOS

@MainActor
final class ResearchSearchLayoutTests: XCTestCase {
    func testPullClosesEmptySearchAndKeyboardThenCanReopen() async throws {
        let pull = ResearchSearchPullToDismiss.Observer()
        try await withResearch(pullObserver: pull) { window, host in
            let navigation = try XCTUnwrap(self.controller(UINavigationController.self, in: host))
            let search = try self.searchController(in: navigation)
            let field = search.searchBar.searchTextField
            let origin = field.convert(field.bounds, to: window)
            try await self.activate(search, in: window)
            try await Task.sleep(for: .milliseconds(450))
            let point = CGPoint(x: window.bounds.midX, y: field.convert(field.bounds, to: window).maxY + 70)
            let hit = try XCTUnwrap(window.hitTest(point, with: nil))
            let activeFrame = field.convert(field.bounds, to: window)
            pull.beginTouch(at: point, in: hit)
            pull.moveTouch(to: CGPoint(x: point.x, y: point.y + 35))
            if #available(iOS 26.0, *) {
                XCTAssertLessThan(field.convert(field.bounds, to: window).width, activeFrame.width)
            }
            XCTAssertTrue(search.isActive)
            XCTAssertTrue(field.isFirstResponder)
            pull.moveTouch(to: CGPoint(x: point.x, y: point.y + 180))
            XCTAssertTrue(search.isActive, "The detent must wait for release")
            if #available(iOS 26.0, *) {
                XCTAssertGreaterThan(field.convert(field.bounds, to: window).minY, activeFrame.minY + 60)
            }
            try await Task.sleep(for: .milliseconds(80))
            if #available(iOS 26.0, *) {
                XCTAssertGreaterThan(field.convert(field.bounds, to: window).minY, activeFrame.minY + 60,
                                     "Toolbar layout must not reset the held field")
            }
            try self.capture(window, name: "research-search-held-at-detent")
            let releasedFrame = self.presentationFrame(of: field, in: window)
            pull.endTouch()
            // Sample the visible flight, not the model layer's final frame:
            // a return through the toolbar can still finish at the right place.
            for _ in 0..<45 {
                try await Task.sleep(for: .milliseconds(16))
                if #available(iOS 26.0, *) {
                    let frame = self.presentationFrame(of: field, in: window)
                    XCTAssertGreaterThanOrEqual(frame.minY, min(releasedFrame.minY, origin.minY) - 4,
                                               "The field must return directly, without detouring through the toolbar")
                    XCTAssertLessThanOrEqual(frame.minY, max(releasedFrame.minY, origin.minY) + 4)
                }
            }
            XCTAssertFalse(search.isActive)
            XCTAssertFalse(field.isFirstResponder)
            XCTAssertEqual(field.text, "")
            XCTAssertEqual(field.convert(field.bounds, to: window).minY, origin.minY, accuracy: 1)
            if let backdrop = self.find(UIVisualEffectView.self, in: window, identifier: "research.search.backdrop") {
                XCTAssertFalse(self.isVisible(backdrop))
            }
            try await self.activate(search, in: window)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(field.isFirstResponder)
            try await self.cancel(search, in: window)
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertFalse(search.isActive)
        }
    }

    func testPullReturnsDirectlyToPartiallyScrolledAndPinnedOrigins() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("The movable field uses iOS 26") }
        for offset: CGFloat in [20, 400] {
            let pull = ResearchSearchPullToDismiss.Observer()
            try await withResearch(pullObserver: pull) { window, host in
                let navigation = try XCTUnwrap(self.controller(UINavigationController.self, in: host))
                let scroll = try XCTUnwrap(navigation.topViewController?.contentScrollView(for: .top))
                scroll.setContentOffset(CGPoint(x: 0, y: offset - scroll.adjustedContentInset.top), animated: false)
                try await Task.sleep(for: .milliseconds(300))
                let originalOffset = scroll.contentOffset.y
                let search = try self.searchController(in: navigation)
                let field = search.searchBar.searchTextField
                let origin = field.convert(field.bounds, to: window)
                try await self.activate(search, in: window)
                try await Task.sleep(for: .milliseconds(550))
                let point = CGPoint(x: window.bounds.midX, y: field.convert(field.bounds, to: window).maxY + 70)
                let hit = try XCTUnwrap(window.hitTest(point, with: nil))
                pull.beginTouch(at: point, in: hit)
                pull.moveTouch(to: CGPoint(x: point.x, y: point.y + 180))
                // Let the held transform reach the presentation layer before
                // using its visible position as the flight's starting point.
                try await Task.sleep(for: .milliseconds(80))
                let released = self.presentationFrame(of: field, in: window)
                pull.endTouch()
                for _ in 0..<45 {
                    try await Task.sleep(for: .milliseconds(16))
                    let frame = self.presentationFrame(of: field, in: window)
                    XCTAssertGreaterThanOrEqual(frame.minY, min(released.minY, origin.minY) - 4)
                    XCTAssertLessThanOrEqual(frame.minY, max(released.minY, origin.minY) + 4)
                }
                XCTAssertFalse(search.isActive)
                XCTAssertFalse(field.isFirstResponder)
                XCTAssertEqual(field.convert(field.bounds, to: window).minY, origin.minY, accuracy: 1)
                XCTAssertEqual(scroll.contentOffset.y, originalOffset, accuracy: 1)
                try self.assertSearchGlass(in: window, visible: offset == 400)
            }
        }
    }

    func testPullClosesResultsOnlyWhenTheDragStartsAtTop() async throws {
        let pull = ResearchSearchPullToDismiss.Observer()
        try await withResearch(pullObserver: pull) { window, host in
            let navigation = try XCTUnwrap(self.controller(UINavigationController.self, in: host))
            let search = try self.searchController(in: navigation)
            let field = search.searchBar.searchTextField
            try await self.activate(search, in: window)
            try await Task.sleep(for: .milliseconds(450))
            field.insertText("a")
            try await Task.sleep(for: .milliseconds(650))
            let point = CGPoint(x: window.bounds.midX, y: field.convert(field.bounds, to: window).maxY + 100)
            let hit = try XCTUnwrap(window.hitTest(point, with: nil))
            var ancestor: UIView? = hit
            while ancestor != nil, !(ancestor is UIScrollView) { ancestor = ancestor?.superview }
            let scroll = try XCTUnwrap(ancestor as? UIScrollView, "The gesture must reach the result list")
            let top = -scroll.adjustedContentInset.top
            scroll.setContentOffset(CGPoint(x: 0, y: top + 160), animated: false)
            try await Task.sleep(for: .milliseconds(100))
            pull.beginTouch(at: point, in: hit)
            scroll.setContentOffset(CGPoint(x: 0, y: top), animated: false)
            pull.moveTouch(to: CGPoint(x: point.x, y: point.y + 100))
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(search.isActive, "Returning through results must not close search")
            XCTAssertEqual(field.text, "a")
            pull.beginTouch(at: point, in: hit)
            pull.moveTouch(to: CGPoint(x: point.x, y: point.y + 180))
            XCTAssertTrue(search.isActive, "The detent must wait for release")
            pull.endTouch()
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertFalse(search.isActive)
            XCTAssertFalse(field.isFirstResponder)
            XCTAssertEqual(field.text, "")
        }
    }

    func testSystemSearchActivationResultsCancelAndReopen() async throws {
        try await withResearch { window, host in
            let navigation = try XCTUnwrap(self.controller(UINavigationController.self, in: host))
            let search = try self.searchController(in: navigation)
            let field = search.searchBar.searchTextField
            let origin = field.convert(field.bounds, to: window)
            XCTAssertFalse(search.isActive)
            XCTAssertNil(self.find(UIRefreshControl.self, in: host.view))
            try await self.activate(search, in: window)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertTrue(search.isActive)
            XCTAssertTrue(field.isFirstResponder)
            if #available(iOS 26.0, *) {
                try self.assertSearchGlass(in: window, visible: true)
                let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window)
                XCTAssertLessThan(field.convert(field.bounds, to: window).minY, origin.minY - 30,
                                  "Opening search must fly the field to the top")
                XCTAssertLessThanOrEqual(field.convert(field.bounds, to: window).maxY, bar.maxY + 1)
            } else {
                XCTAssertLessThanOrEqual(field.convert(field.bounds, to: window).minY, origin.minY)
            }
            let backdrop = try XCTUnwrap(self.find(UIVisualEffectView.self, in: window,
                                                   identifier: "research.search.backdrop"))
            let blur = try XCTUnwrap(backdrop.effect as? UIBlurEffect)
            try self.capture(window, name: "research-system-search-active")
            field.insertText("MSFT")
            field.selectAll(nil)
            field.insertText("AAPL")
            try await Task.sleep(for: .milliseconds(650))
            XCTAssertEqual(field.text, "AAPL")
            XCTAssertTrue(try self.visibleText(in: window).contains { $0.uppercased().contains("NASDAQ") })
            XCTAssertTrue(backdrop.effect === blur)
            try self.capture(window, name: "research-system-search-results")
            field.selectAll(nil)
            field.insertText("zzzz-no-security")
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertFalse(try self.visibleText(in: window).contains { $0.contains("NASDAQ") })
            field.selectAll(nil)
            field.deleteBackward()
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(field.text, "")
            XCTAssertTrue(backdrop.effect === blur)
            try await self.cancel(search, in: window)
            try await Task.sleep(for: .milliseconds(750))
            XCTAssertFalse(search.isActive)
            XCTAssertFalse(field.isFirstResponder)
            XCTAssertEqual(field.convert(field.bounds, to: window).minY, origin.minY, accuracy: 1)
            try self.capture(window, name: "research-system-search-cancelled")
            if let backdrop = self.find(UIVisualEffectView.self, in: window, identifier: "research.search.backdrop") {
                XCTAssertFalse(self.isVisible(backdrop), "Cancellation must reveal the dashboard")
            }

            // Return and interactive keyboard dismissal must not strand search.
            try await self.activate(search, in: window)
            try await Task.sleep(for: .milliseconds(350))
            field.insertText("AAPL")
            field.resignFirstResponder()
            try await Task.sleep(for: .milliseconds(150))
            try await self.cancel(search, in: window)
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertFalse(search.isActive)
            XCTAssertEqual(field.text, "")
            try await self.activate(search, in: window)
            try await Task.sleep(for: .milliseconds(80))
            try await self.cancel(search, in: window)
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertFalse(search.isActive)
            XCTAssertFalse(field.isFirstResponder)
            XCTAssertTrue(try self.searchController(in: navigation).searchBar === search.searchBar)
        }
    }

    func testSearchStartsBelowTitleAndPinsOnlyAfterScrolling() async throws {
        try await withResearch { window, host in
            let navigation = try XCTUnwrap(self.controller(UINavigationController.self, in: host))
            let item = try XCTUnwrap(navigation.topViewController?.navigationItem)
            let search = try self.searchController(in: navigation)
            let field = search.searchBar.searchTextField
            try self.capture(window, name: "research-title-initial")
            let titleFrame = try RootTabTitleTestSupport.frame(title: L10n.text("研究"), window: window)
            let origin = field.convert(field.bounds, to: window)
            XCTAssertEqual(item.title, L10n.text("研究"))
            try self.assertSearchGlass(in: window, visible: false)
            XCTAssertGreaterThan(origin.minY, titleFrame.maxY,
                                 "Search must start below the large title, not in the toolbar")
            let scroll = try XCTUnwrap(navigation.topViewController?.contentScrollView(for: .top))
            let initialOffset = scroll.contentOffset
            try self.capture(window, name: "research-system-search-idle")
            scroll.setContentOffset(CGPoint(x: 0, y: initialOffset.y + 20), animated: false)
            try await Task.sleep(for: .milliseconds(220))
            let movingFrame = field.convert(field.bounds, to: window)
            XCTAssertLessThan(movingFrame.minY, origin.minY)
            XCTAssertGreaterThan(movingFrame.minY, window.safeAreaInsets.top + 20,
                                 "A small scroll must not immediately pin the search")
            try self.assertSearchGlass(in: window, visible: false)
            var pinnedY: CGFloat?
            for offset: CGFloat in [200, 400, 700] {
                scroll.setContentOffset(CGPoint(x: 0, y: offset - scroll.adjustedContentInset.top), animated: false)
                try await Task.sleep(for: .milliseconds(220))
                let frame = field.convert(field.bounds, to: window)
                if #available(iOS 26.0, *) {
                    try self.assertSearchGlass(in: window, visible: true)
                    let barFrame = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window)
                    XCTAssertGreaterThan(frame.height, 30)
                    XCTAssertGreaterThan(frame.width, window.bounds.width * 0.75)
                    XCTAssertLessThanOrEqual(frame.maxY, barFrame.maxY + 1)
                    XCTAssertLessThan(frame.minY, origin.minY - 30)
                    XCTAssertFalse(try self.visibleText(in: window).contains { $0 == L10n.text("研究") },
                                   "The pinned toolbar contains search without a second title")
                } else {
                    XCTAssertLessThan(frame.minY, origin.minY)
                }
                XCTAssertGreaterThanOrEqual(frame.minY, window.safeAreaInsets.top)
                if let pinnedY { XCTAssertEqual(frame.minY, pinnedY, accuracy: 1) }
                pinnedY = frame.minY
                let hit = try XCTUnwrap(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil))
                XCTAssertTrue(hit.isDescendant(of: search.searchBar))
            }
            try self.capture(window, name: "research-system-search-pinned")
            try await self.activate(search, in: window)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(field.isFirstResponder)
            try await self.cancel(search, in: window)
            try await Task.sleep(for: .milliseconds(750))
            XCTAssertEqual(field.convert(field.bounds, to: window).minY, try XCTUnwrap(pinnedY), accuracy: 1,
                           "Closing search while scrolled must keep its pinned position")
            try self.assertSearchGlass(in: window, visible: true)
            // Scroll back to the top as a reader's scroll-to-top does, so the
            // large title expands again. An instant jump to the expanded
            // offset under a collapsed bar leaves the title collapsed or not
            // depending on the page's height.
            scroll.setContentOffset(initialOffset, animated: true)
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertEqual(field.convert(field.bounds, to: window).minY, origin.minY, accuracy: 1)
            XCTAssertTrue(try self.searchController(in: navigation).searchBar === search.searchBar)
            try self.assertSearchGlass(in: window, visible: false)
            try self.capture(window, name: "research-search-restored-below-title")
        }
    }

    func testSearchLeavesPushedPagesAndReturnsBelowTitle() async throws {
        try await withResearch { window, host in
            let navigation = try XCTUnwrap(self.controller(UINavigationController.self, in: host))
            let search = try self.searchController(in: navigation)
            let field = search.searchBar.searchTextField
            let origin = field.convert(field.bounds, to: window)
            let detail = UIViewController()
            detail.view.backgroundColor = .systemBackground
            navigation.pushViewController(detail, animated: false)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertNil(self.find(UISearchBar.self, in: navigation.view, identifier: "research.search.bar"),
                         "The search field must not float over a pushed page")
            navigation.popViewController(animated: false)
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(try self.searchController(in: navigation).searchBar === search.searchBar)
            XCTAssertEqual(field.convert(field.bounds, to: window).minY, origin.minY, accuracy: 1)
            try await self.activate(search, in: window)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertTrue(field.isFirstResponder)
            try await self.cancel(search, in: window)
        }
    }

    func testNativeSearchSurvivesRepeatedTabSwitches() async throws {
        try await withResearch(rootTabs: true) { window, host in
            let tabs = try XCTUnwrap(self.controller(UITabBarController.self, in: host))
            for index in [2, 3, 2, 0, 2] {
                tabs.selectedIndex = index
                tabs.delegate?.tabBarController?(tabs, didSelect: try XCTUnwrap(tabs.selectedViewController))
                try await Task.sleep(for: .milliseconds(400))
                let navigation = try XCTUnwrap(self.controller(UINavigationController.self,
                                                     in: try XCTUnwrap(tabs.selectedViewController)))
                guard index == 2 else {
                    XCTAssertNil(navigation.topViewController?.navigationItem.searchController,
                                 "The market search belongs to Research only")
                    XCTAssertNil(self.find(UISearchBar.self, in: navigation.view, identifier: "research.search.bar"))
                    continue
                }
                let search = try self.searchController(in: navigation)
                try await self.activate(search, in: window)
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertTrue(search.searchBar.searchTextField.isFirstResponder)
                search.searchBar.searchTextField.insertText("AAPL")
                try await Task.sleep(for: .milliseconds(200))
                try await self.cancel(search, in: window)
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertFalse(search.isActive)
                XCTAssertEqual(search.searchBar.text, "")
            }
        }
    }

    func testSearchResultsFitNarrowScreenAtAccessibilitySize() async throws {
        try await withResearch(size: CGSize(width: 320, height: 852), largeType: true) { window, host in
            let navigation = try XCTUnwrap(self.controller(UINavigationController.self, in: host))
            let search = try self.searchController(in: navigation)
            try await self.activate(search, in: window)
            try await Task.sleep(for: .milliseconds(350))
            let field = search.searchBar.searchTextField
            field.insertText("AAPL")
            try await Task.sleep(for: .milliseconds(500))
            let text = try self.visibleText(in: window)
            XCTAssertTrue(text.contains { $0.contains("AAPL") })
            XCTAssertTrue(text.contains { $0.contains("NASDAQ") })
            let frame = field.convert(field.bounds, to: window)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThanOrEqual(frame.maxX, window.bounds.maxX)
            try self.capture(window, name: "research-system-search-accessibility")
        }
    }

    func testDarkSearchCanOpenAndClose() async throws {
        try await withResearch { window, host in
            window.overrideUserInterfaceStyle = .dark
            try await Task.sleep(for: .milliseconds(300))
            let navigation = try XCTUnwrap(self.controller(UINavigationController.self, in: host))
            let search = try self.searchController(in: navigation)
            try self.capture(window, name: "research-system-search-dark-idle")
            try await self.activate(search, in: window)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertTrue(search.searchBar.searchTextField.isFirstResponder)
            try self.capture(window, name: "research-system-search-dark")
            try await self.cancel(search, in: window)
            try await Task.sleep(for: .milliseconds(800))
            XCTAssertFalse(search.isActive)
            XCTAssertFalse(search.searchBar.searchTextField.isFirstResponder)
            try self.assertSearchGlass(in: window, visible: false)
            let scroll = try XCTUnwrap(navigation.topViewController?.contentScrollView(for: .top))
            scroll.setContentOffset(CGPoint(x: 0, y: 400 - scroll.adjustedContentInset.top), animated: false)
            try await Task.sleep(for: .milliseconds(300))
            try self.assertSearchGlass(in: window, visible: true)
            try self.capture(window, name: "research-system-search-dark-pinned")
            try await self.activate(search, in: window)
            try await Task.sleep(for: .milliseconds(450))
            try await self.cancel(search, in: window)
            try await Task.sleep(for: .milliseconds(750))
            try self.assertSearchGlass(in: window, visible: true)
        }
    }

    func testReducedTransparencyUsesSolidBackdrop() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: ResearchSearchBackdrop(reduceTransparency: true))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(100))
        let backdrop = try XCTUnwrap(find(UIVisualEffectView.self, in: host.view,
                                          identifier: "research.search.backdrop"))
        XCTAssertNil(backdrop.effect)
        XCTAssertNotEqual(backdrop.backgroundColor, UIColor.clear)
    }

    private func withResearch(size: CGSize? = nil, rootTabs: Bool = false, largeType: Bool = false,
                              pullObserver: ResearchSearchPullToDismiss.Observer? = nil,
                              run: (UIWindow, UIViewController) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let suite = "research-native-search-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, personalDocumentLoader: { .empty })
        await model.refreshPortfolio(refreshMarketData: false)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        if let size { window.frame = CGRect(origin: .zero, size: size) }
        let content = Group {
            if let pullObserver { SearchFixture(pullObserver: pullObserver) }
            else if rootTabs { RootTabView() }
            else { NavigationStack { ResearchView() } }
        }
        .environment(model)
        .environment(\.dynamicTypeSize, largeType ? .accessibility2 : .large)
        .defaultAppStorage(defaults)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(500))
        try await run(window, host)
    }

    /// Exercise the production search modifier and native controller without
    /// depending on SwiftUI's private gesture-recognizer hierarchy.
    private struct SearchFixture: View {
        let pullObserver: ResearchSearchPullToDismiss.Observer
        @State private var presented = false
        var body: some View {
            NavigationStack {
                SettingsPage {
                    ResearchSearchSlot()
                    Text("Research").frame(maxWidth: .infinity, minHeight: 1200, alignment: .top)
                }
                .navigationTitle(ResearchMarketSearch.navigationTitle)
                .navigationBarTitleDisplayMode(.large)
                .modifier(ResearchMarketSearch(holdings: [], onSelect: { _ in },
                                               isPresented: $presented, pullObserver: pullObserver))
            }
        }
    }

    private struct SearchControl {
        let searchBar: UISearchBar
        var isActive: Bool {
            if #available(iOS 26.0, *), let field = searchBar.superview?.superview as? ResearchToolbarSearch.Field {
                return field.isPresented
            }
            return searchBar.showsCancelButton
        }
    }

    private func searchController(in navigation: UINavigationController) throws -> SearchControl {
        let bar: UISearchBar
        if #available(iOS 26.0, *) {
            bar = try XCTUnwrap(find(UISearchBar.self, in: navigation.view,
                                    identifier: "research.search.bar"))
        } else {
            bar = try XCTUnwrap(navigation.topViewController?.navigationItem.searchController).searchBar
        }
        return SearchControl(searchBar: bar)
    }

    private func activate(_ search: SearchControl, in window: UIWindow) async throws {
        let field = search.searchBar.searchTextField
        for _ in 0..<40 {
            let frame = field.convert(field.bounds, to: window)
            let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)
            if hit?.isDescendant(of: search.searchBar) == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let frame = field.convert(field.bounds, to: window)
        let hit = try XCTUnwrap(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil))
        XCTAssertTrue(hit.isDescendant(of: search.searchBar), "The native field must receive touches")
        XCTAssertTrue(field.becomeFirstResponder())
    }

    private func cancel(_ search: SearchControl, in window: UIWindow) async throws {
        // Wait for the visible UIKit control after the toolbar lays out.
        for _ in 0..<30 {
            if let button = descendants(search.searchBar.superview ?? search.searchBar).compactMap({ $0 as? UIButton }).first(where: {
                !$0.isDescendant(of: search.searchBar.searchTextField) && isVisible($0)
            }) {
                let frame = button.convert(button.bounds, to: window)
                if window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil)?.isDescendant(of: button) == true {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let button = try XCTUnwrap(descendants(search.searchBar.superview ?? search.searchBar).compactMap { $0 as? UIButton }.first {
            !$0.isDescendant(of: search.searchBar.searchTextField) && isVisible($0)
        }, "The search toolbar must expose its cancel button")
        XCTAssertTrue(button.isEnabled)
        let frame = button.convert(button.bounds, to: window)
        let hit = try XCTUnwrap(window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil))
        XCTAssertTrue(hit.isDescendant(of: button),
                      "System cancel must remain tappable: hit \(type(of: hit)) at \(frame)")
        button.sendActions(for: .touchUpInside)
    }

    private func assertSearchGlass(in window: UIWindow, visible: Bool,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        guard #available(iOS 26.0, *) else { return }
        let glass = try XCTUnwrap(find(UIVisualEffectView.self, in: window,
                                       identifier: "research.search.glass"), file: file, line: line)
        if visible {
            XCTAssertTrue(glass.effect is UIGlassEffect, "Floating search must use liquid glass",
                          file: file, line: line)
            XCTAssertEqual(glass.alpha, 1, file: file, line: line)
        } else {
            XCTAssertNil(glass.effect, "Inline search returns to the page's panel material",
                         file: file, line: line)
        }
    }

    private func capture(_ window: UIWindow, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
    }

    private func presentationFrame(of view: UIView, in window: UIWindow) -> CGRect {
        let layer = view.layer.presentation() ?? view.layer
        return layer.convert(layer.bounds, to: window.layer.presentation() ?? window.layer)
    }

    private func isVisible(_ view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0.01 else { return false }
        return view.superview.map(isVisible) ?? true
    }
    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func controller<T: UIViewController>(_ type: T.Type, in parent: UIViewController) -> T? {
        if let match = parent as? T { return match }
        return parent.children.lazy.compactMap { self.controller(type, in: $0) }.first
    }
    private func find<T: UIView>(_ type: T.Type, in view: UIView, identifier: String? = nil) -> T? {
        if let match = view as? T, identifier == nil || match.accessibilityIdentifier == identifier { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0, identifier: identifier) }.first
    }
    private func visibleText(in window: UIWindow) throws -> [String] {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
}
