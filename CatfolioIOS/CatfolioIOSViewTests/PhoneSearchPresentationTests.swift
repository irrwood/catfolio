import Observation
import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class PhoneSearchPresentationTests: XCTestCase {
    func testReferenceRowsKeepVenueOnTheTickerLine() async throws {
        let results = [
            MarketSecurityResult(ticker: "NKE", name: "NIKE, Inc.", market: "US", exchange: "NYSE",
                                 currency: "USD", sector: nil, isFund: false),
            MarketSecurityResult(ticker: "NIO", name: "NIO Inc.", market: "US", exchange: "NYSE",
                                 currency: "USD", sector: nil, isFund: false),
            MarketSecurityResult(ticker: "NIOX.L", name: "NIOX Group Plc", market: "UK", exchange: "LSE",
                                 currency: "GBp", sector: nil, isFund: false)
        ]
        for width: CGFloat in [320, 393] {
            let frames = Frames()
            let search = SecuritySearchModel(searchDelay: .zero, quoteDelay: .zero,
                directorySearch: { _, _ in results }, quoteLoader: { entries in
                    Dictionary(uniqueKeysWithValues: entries.map { entry in
                        let index = results.firstIndex { $0.ticker == entry.ticker } ?? 0
                        return (entry.id, WatchlistQuote(price: [37.30, 3.29, 68.80][index],
                                                       previousClose: [38.32, 3.31, 67.80][index], observedAt: nil))
                    })
                })
            let host = UIHostingController(rootView: RootPageNavigation {
                ResearchMarketSearchView(holdings: [results[0].holding], onSelect: { _ in },
                                         query: "NI", onDismiss: {}, searchModel: search)
                    .frame(width: width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color(uiColor: .systemBackground))
                    .environment(\.colorScheme, .dark)
                    .overlayPreferenceValue(ResearchCardLayoutFrames.self) { anchors in
                        GeometryReader { geometry in
                            let values = anchors.mapValues { geometry[$0] }
                            Color.clear.onAppear { frames.values = values }
                                .onChange(of: values) { _, value in frames.values = value }
                        }
                    }
            })
            try await withWindow(host) { window in
                try await self.wait {
                    frames.values["phone-search.name.NIOX.L"] != nil
                        && search.quote(for: results[2], holdings: [])?.price == 68.80
                }
                for result in results {
                    let button = try XCTUnwrap(frames.values["phone-search.button.\(result.id)"])
                    let row = try XCTUnwrap(frames.values["phone-search.row.\(result.id)"])
                    XCTAssertEqual(button.width, width, accuracy: 1,
                                   "The pressed background must span the full search viewport")
                    XCTAssertEqual(row.minX - button.minX, SettingsTemplate.pageInset, accuracy: 1)
                    XCTAssertEqual(button.maxX - row.maxX, SettingsTemplate.pageInset, accuracy: 1)
                    let logo = try XCTUnwrap(frames.values["phone-search.logo.\(result.id)"])
                    let header = try XCTUnwrap(frames.values["phone-search.header.\(result.id)"])
                    let name = try XCTUnwrap(frames.values["phone-search.name.\(result.id)"])
                    let price = try XCTUnwrap(frames.values["phone-search.price.\(result.id)"])
                    let change = try XCTUnwrap(frames.values["phone-search.change.\(result.id)"])
                    XCTAssertEqual(header.minY, price.minY, accuracy: 2)
                    XCTAssertEqual(name.minY, change.minY, accuracy: 2)
                    XCTAssertLessThan(header.maxX, price.minX)
                    XCTAssertEqual(logo.width, 36, accuracy: 1)
                    XCTAssertEqual(logo.height, 36, accuracy: 1)
                    if result.ticker == "NKE" {
                        let badge = try XCTUnwrap(frames.values["phone-search.held.\(result.id)"])
                        let venue = try XCTUnwrap(frames.values["phone-search.venue.\(result.id)"])
                        XCTAssertLessThanOrEqual(badge.height, venue.height)
                        XCTAssertGreaterThan(badge.minX, venue.maxX)
                        XCTAssertGreaterThanOrEqual(badge.minX, header.minX)
                        XCTAssertLessThanOrEqual(badge.maxX, header.maxX)
                        XCTAssertLessThanOrEqual(badge.maxY, name.minY)
                    } else {
                        XCTAssertNil(frames.values["phone-search.held.\(result.id)"])
                    }
                }
                if width == 393 {
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-phone-search-two-lines.png"))
                }
            }
        }
    }

    func testPhoneSearchLoadsSharedQuotesAndFitsNarrowAndLargeTextLayouts() async throws {
        let result = MarketSecurityResult(ticker: "AAPL", name: "Apple", market: "US", exchange: "NASDAQ",
                                          currency: "USD", sector: nil, isFund: false)
        for largeText in [false, true] {
            let search = SecuritySearchModel(searchDelay: .zero, quoteDelay: .zero,
                directorySearch: { _, _ in [result] }, quoteLoader: { entries in
                    Dictionary(uniqueKeysWithValues: entries.map {
                        ($0.id, WatchlistQuote(price: 123.45, previousClose: 120, observedAt: nil))
                    })
                })
            let frames = Frames()
            let host = UIHostingController(rootView: RootPageNavigation {
                ResearchMarketSearchView(holdings: [], onSelect: { _ in }, query: "AAPL", onDismiss: {},
                                         searchModel: search)
                    .frame(width: 320)
                    .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large)
                    .environment(\.colorScheme, largeText ? .dark : .light)
                    .overlayPreferenceValue(ResearchCardLayoutFrames.self) { anchors in
                        GeometryReader { geometry in
                            let values = anchors.mapValues { geometry[$0] }
                            Color.clear.onAppear { frames.values = values }
                                .onChange(of: values) { _, value in frames.values = value }
                        }
                    }
            })
            try await withWindow(host) { _ in
                try await self.wait {
                    search.quote(for: result, holdings: [])?.price == 123.45
                        && frames.values["phone-search.metrics.AAPL"] != nil
                }
                XCTAssertFalse(self.controllers(host).contains { $0 is UISplitViewController })
                let row = try XCTUnwrap(frames.values["phone-search.row.AAPL"])
                let button = try XCTUnwrap(frames.values["phone-search.button.AAPL"])
                XCTAssertEqual(button.width, 320, accuracy: 1)
                XCTAssertEqual(row.minX - button.minX, SettingsTemplate.pageInset, accuracy: 1)
                XCTAssertEqual(button.maxX - row.maxX, SettingsTemplate.pageInset, accuracy: 1)
                let identity = try XCTUnwrap(frames.values["phone-search.identity.AAPL"])
                let metrics = try XCTUnwrap(frames.values["phone-search.metrics.AAPL"])
                XCTAssertEqual(row.width, 320 - 2 * SettingsTemplate.pageInset, accuracy: 1,
                               "Flat search rows use the page inset, without an extra card inset")
                XCTAssertGreaterThanOrEqual(metrics.minX, row.minX)
                XCTAssertLessThanOrEqual(metrics.maxX, row.maxX + 1)
                XCTAssertGreaterThanOrEqual(metrics.minX, identity.maxX + 11)
                let header = try XCTUnwrap(frames.values["phone-search.header.AAPL"])
                let name = try XCTUnwrap(frames.values["phone-search.name.AAPL"])
                let price = try XCTUnwrap(frames.values["phone-search.price.AAPL"])
                let change = try XCTUnwrap(frames.values["phone-search.change.AAPL"])
                XCTAssertEqual(header.minY, price.minY, accuracy: 2)
                XCTAssertEqual(name.minY, change.minY, accuracy: 2)
                XCTAssertEqual(identity.maxY, name.maxY, accuracy: 1,
                               "The company name is the final line; venue must stay beside the ticker")
            }
        }
    }

    func testPhoneTabPushAndSheetUseTheirOwnPresentationContext() async throws {
        let route = Route()
        let host = UIHostingController(rootView: TabView {
            RootPageNavigation {
                SettingsPage(title: "Research", navigationRole: .root) {
                    Text("Content")
                    ContextProbe { route.rootPresentation = $0 }
                }
                .navigationDestination(isPresented: Binding(get: { route.pushed }, set: { route.pushed = $0 })) {
                    SettingsPage(title: "Detail", titleDisplayMode: .inline) {
                        ContextProbe { route.detailPresentation = $0 }
                    }
                }
                .workspacePage(isPresented: Binding(get: { route.sheet }, set: { route.sheet = $0 })) {
                    DetailPageNavigation {
                        SettingsPage(title: "Sheet") {
                            ContextProbe { route.sheetPresentation = $0 }
                        }
                    }
                }
            }.tabItem { Label("Research", systemImage: "magnifyingglass") }
        })
        try await withWindow(host) { _ in
            try await self.wait { route.rootPresentation != nil }
            XCTAssertEqual(route.rootPresentation, .tabs)
            XCTAssertFalse(self.controllers(host).contains { $0 is UISplitViewController })
            let navigation = try XCTUnwrap(self.controllers(host).compactMap { $0 as? UINavigationController }.first)
            let root = try XCTUnwrap(navigation.topViewController)
            route.pushed = true
            try await self.wait { navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil }
            XCTAssertEqual(route.detailPresentation, .tabs)
            XCTAssertNotNil(navigation.navigationBar.backItem)
            navigation.popViewController(animated: false)
            try await self.wait { !route.pushed && navigation.topViewController === root }
            route.sheet = true
            try await self.wait { route.sheetPresentation != nil }
            XCTAssertEqual(route.sheetPresentation, .sheet)
            XCTAssertEqual(navigation.viewControllers.count, 1)
            XCTAssertNotNil(self.presented(host))
            route.sheet = false
            try await self.wait { self.presented(host) == nil }
            XCTAssertTrue(navigation.topViewController === root)
            XCTAssertNotNil(self.controllers(host).compactMap { $0 as? UITabBarController }.first)
        }
    }

    private struct ContextProbe: View {
        @Environment(\.pageNavigationPresentation) private var presentation
        let report: (PageNavigationPresentation) -> Void
        var body: some View { Color.clear.frame(height: 1).onAppear { report(presentation) } }
    }

    @Observable fileprivate final class Route {
        var pushed = false
        var sheet = false
        var rootPresentation: PageNavigationPresentation?
        var detailPresentation: PageNavigationPresentation?
        var sheetPresentation: PageNavigationPresentation?
    }
    private final class Frames { var values: [String: CGRect] = [:] }
    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(controllers)
    }
    private func presented(_ controller: UIViewController) -> UIViewController? {
        controllers(controller).compactMap(\.presentedViewController).first
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Presentation or search did not settle")
    }
    private func withWindow(_ host: UIViewController, action: (UIWindow) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await action(window)
    }
}
