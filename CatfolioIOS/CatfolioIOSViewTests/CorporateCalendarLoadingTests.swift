import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class CorporateCalendarLoadingTests: XCTestCase {
    func testFirstCalendarOpenDoesNotBuildEveryOffscreenEvent() async throws {
        let calendar = Calendar.current
        let month = try XCTUnwrap(calendar.dateInterval(of: .month, for: Date())?.start)
        let today = calendar.component(.day, from: Date())
        let eventDay = today == 1 ? 2 : 1
        let day = CorporateCalendarDay.key(try XCTUnwrap(calendar.date(byAdding: .day, value: eventDay - 1, to: month)), calendar: calendar)
        let holdings = (0..<120).map { Self.holding("CAL\($0)") }
        let schedules = Dictionary(uniqueKeysWithValues: holdings.map { holding in
            (holding.ticker, CorporateEventSchedule(events: [
                CorporateEvent(ticker: holding.ticker, kind: .earnings, date: day,
                               isEstimate: false, amount: nil, currency: nil)
            ], fetchedAt: Date()))
        })
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-perf-\(UUID()).json")
        try JSONEncoder().encode(schedules).write(to: cache)
        defer { try? FileManager.default.removeItem(at: cache) }
        let store = CorporateEventsStore(cacheURL: cache)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        // The user enters from the existing preview card: shared fonts and
        // logo infrastructure are already on screen, the calendar is not.
        let preview = CorporateEventsCardContent(holdings: holdings,
            events: holdings.prefix(3).compactMap { schedules[$0.ticker]?.events.first })
        let navigation = UINavigationController(rootViewController: UIHostingController(rootView: preview))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        let clock = FrameClock()
        defer {
            clock.stop()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(500))
        clock.start()
        try await Task.sleep(for: .milliseconds(80))
        let start = CACurrentMediaTime()
        var resolvedLogos = 0
        let host = UIHostingController(rootView: CorporateCalendarView(holdings: holdings, store: store)
            .environment(\.assetLogoDidResolve, { _ in resolvedLogos += 1 }))
        navigation.pushViewController(host, animated: true)
        try await Task.sleep(for: .milliseconds(1000))
        let elapsed = CACurrentMediaTime() - start
        clock.stop()
        XCTAssertEqual(store.schedules.count, holdings.count)
        print(String(format: "[CalendarFirstOpen] elapsed=%.2fms worstFrame=%.2fms logos=%d",
                     elapsed * 1000, (clock.gaps.max() ?? 0) * 1000, resolvedLogos))
        XCTAssertLessThan(resolvedLogos, 30, "Opening the calendar must not start every offscreen row's logo")
        XCTAssertGreaterThan(resolvedLogos, 0)
        // Record frame pacing for device-to-device comparison; enforce the
        // bounded work below rather than a simulator-dependent time threshold.
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "calendar-first-open"
        attachment.lifetime = .keepAlways
        add(attachment)
        let firstScreenLogos = resolvedLogos
        let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }
            .max(by: { $0.contentSize.height < $1.contentSize.height }))
        scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height
                                       + scroll.adjustedContentInset.bottom), animated: false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(resolvedLogos, firstScreenLogos, "Offscreen events must load when scrolled into view")
        XCTAssertLessThan(resolvedLogos, 50, "Jumping down the list must not build every skipped row")
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    private static func holding(_ ticker: String) -> Holding {
        Holding(ticker: ticker, logoSymbol: "NVDA", displayName: ticker, sector: nil, source: nil,
                shares: 10, averageCost: 100, costCurrency: "USD", quotePrice: 120,
                quoteCurrency: "USD", todayChangePercent: nil, marketValue: 1200, weight: 1,
                unrealized: 200, unrealizedPercent: 20, fxPnl: nil, fxPnlPercent: nil,
                fxPnlStatus: nil, fxPnlSource: nil)
    }

    private final class FrameClock {
        private var link: CADisplayLink?
        private var lastTime: CFTimeInterval?
        var gaps: [Double] = []
        func start() {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        func stop() { link?.invalidate(); link = nil }
        @objc private func tick() {
            let now = CACurrentMediaTime()
            if let lastTime { gaps.append(now - lastTime) }
            lastTime = now
        }
    }
}
