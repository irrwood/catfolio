import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class ReturnsScrollPerformanceTests: XCTestCase {
    func testHeaderScrollAndPullFramePacing() async throws {
        let suite = "ReturnsScrollTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "catfolio.fakeDataMode")
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        let document = FakePortfolioGenerator.make()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { document })
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertFalse(model.holdings.isEmpty)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack {
            ReturnsView().environment(model)
                .environment(\.scenePhase, .active)
                .environment(\.locale, Locale(identifier: "en"))
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .seconds(3))
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        let scroll = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UIScrollView }
            .max(by: { $0.contentSize.height < $1.contentSize.height }))
        let clock = FrameClock()
        defer { clock.stop() }
        for (name, amplitude) in [("scroll", 350.0), ("pull", -95.0)] {
            clock.start()
            for frame in 0..<120 {
                let offset = amplitude * sin(.pi * Double(frame) / 119)
                scroll.setContentOffset(CGPoint(x: 0, y: offset - scroll.adjustedContentInset.top), animated: false)
                await clock.nextFrame()
            }
            clock.stop()
            let gaps = clock.gaps.sorted()
            XCTAssertGreaterThan(gaps.count, 100)
            print(String(format: "[ReturnsScrollPerf] %@ p50=%.2fms p95=%.2fms worst=%.2fms", name,
                         gaps[gaps.count / 2] * 1000, gaps[Int(Double(gaps.count) * 0.95)] * 1000,
                         (gaps.last ?? 0) * 1000))
            XCTAssertEqual(scroll.contentOffset.y + scroll.adjustedContentInset.top, 0, accuracy: 1)
        }
        for scheme in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = scheme
            try await Task.sleep(for: .milliseconds(700))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let name = "returns-scroll-\(scheme == .light ? "light" : "dark")"
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        }
    }

    @MainActor private final class FrameClock {
        private var link: CADisplayLink?
        private var waiter: CheckedContinuation<Void, Never>?
        private var lastTime: CFTimeInterval?
        var gaps: [Double] = []

        func start() {
            gaps = []
            lastTime = nil
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        func stop() {
            link?.invalidate()
            link = nil
            waiter?.resume()
            waiter = nil
        }

        @objc private func tick() {
            let now = CACurrentMediaTime()
            if let lastTime { gaps.append(now - lastTime) }
            lastTime = now
            let pending = waiter
            waiter = nil
            pending?.resume()
        }

        func nextFrame() async {
            await withCheckedContinuation { waiter = $0 }
        }
    }
}
