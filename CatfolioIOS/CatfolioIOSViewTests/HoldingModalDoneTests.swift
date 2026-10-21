import SwiftUI
import UIKit
import Vision
import XCTest
@testable import CatfolioIOS

@MainActor
final class HoldingModalDoneTests: XCTestCase {
    func testStockSheetsRenderCloseOnTheLeftAndDismissInBothAppearances() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let question = SecurityDebateQuestion(question: "Reported growth", whatChanged: "Fixture facts",
            whyItMatters: "Fixture analysis", watchNext: "Next report", uncertainty: "", evidence: [])
        let debate = SecurityDebate(ticker: "TEST", name: "Fixture", generatedAt: .now,
            questions: [question], sources: [])
        let income = try XCTUnwrap(DividendIncome(payments: [
            .init(exDate: "2026-09-01", perShare: 0.25, currency: "USD")
        ], today: try XCTUnwrap(DayDateCodec.date(from: "2026-10-01"))))
        let row = ETFLookThroughRow(ticker: "NVDA", logoSymbol: "NVDA", name: "NVIDIA",
            directUSD: 100, fromETFUSD: 20, totalUSD: 120, etfWeightPercent: 5,
            sector: "Technology", allocatedCostUSD: 80, fundMarketValues: ["SPY": 20])
        let pages: [(String, AnyView)] = [
            ("analyst", AnyView(NavigationStack { AnalystHistoryView(symbol: "AAPL") })),
            ("dividends", AnyView(DividendIncomeCalculatorView(income: income, heldShares: 10))),
            ("amounts", AnyView(HoldingAmountSourcesPage(ticker: "NVDA", initialRow: row).environment(AppModel()))),
            ("ai-detail", AnyView(SecurityDebateQuestionSheet(question: question, debate: debate)))
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, page) in pages {
                let probe = ModalProbe()
                let host = UIHostingController(rootView: ModalFixture(probe: probe, page: page)
                    .preferredColorScheme(scheme))
                fixture.window.rootViewController = host
                try await Task.sleep(for: .milliseconds(100))
                probe.presented = true
                try await waitUntil { host.presentedViewController != nil }
                let modal = try XCTUnwrap(host.presentedViewController)
                try await waitUntil { self.navigation(in: modal) != nil }
                let navigation = try XCTUnwrap(navigation(in: modal))
                let close = try await NativeToolbarTestSupport.button(in: navigation,
                    leading: true, identifier: "holding-modal-close")
                let item = try XCTUnwrap(navigation.topViewController?.navigationItem)
                let trailing = (item.rightBarButtonItems ?? []) + item.trailingItemGroups.flatMap(\.barButtonItems)
                XCTAssertFalse(trailing.contains { $0.accessibilityIdentifier == "holding-modal-close" }, name)
                try await Task.sleep(for: .milliseconds(350))
                let image = fixture.capture()
                try assertLeadingClose(close, in: modal, window: fixture.window, image: image)
                if name == "analyst" {
                    try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-modal-close-\(scheme).png"))
                }
                try close.tap()
                try await waitUntil { host.presentedViewController == nil && !probe.presented }
            }
        }
    }

    func testPaperRetainsItsCustomCloseInBothAppearances() async throws {
        let fixture = try WindowFixture()
        defer { fixture.close() }
        let context = SecurityPriceMoveContext(ticker: "TEST", name: "Fixture", currency: "USD",
            rangeLabel: "1D", startDate: .now.addingTimeInterval(-86_400), endDate: .now,
            startPrice: 100, endPrice: 105, isIntraday: false)
        let store = SecurityDailyMoveStore { _ in SecurityDailyMoveNote(text: "Fixture note", sources: []) }
        for scheme in [ColorScheme.light, .dark] {
            let host = UIHostingController(rootView: SecurityDailyMovePaper(context: context, store: store)
                .preferredColorScheme(scheme))
            fixture.window.rootViewController = host
            try await Task.sleep(for: .milliseconds(900))
            let image = fixture.capture()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
            XCTAssertFalse((request.results ?? []).contains {
                $0.topCandidates(1).first?.string == "Done"
            }, "The paper keeps its bottom X; the sheet Done convention does not apply")
            let attachment = XCTAttachment(image: image)
            attachment.name = "Paper bottom close \(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-paper-close-\(scheme).png"))
        }
    }

    private func assertLeadingClose(_ close: NativeToolbarTestSupport.Button,
                                    in modal: UIViewController, window: UIWindow, image: UIImage) throws {
        XCTAssertNotNil(close.item.image, "Close uses an icon rather than a text button")
        XCTAssertEqual(close.item.title, "Close", "The icon retains its accessible action name")
        let frame = modal.view.convert(modal.view.bounds, to: window)
        // The toolbar helper can return a transition wrapper. Measure the
        // rendered symbol once presentation has settled, not that wrapper.
        let bar = try XCTUnwrap(navigation(in: modal)?.navigationBar)
        let symbol = try XCTUnwrap(descendants(bar).compactMap { $0 as? UIImageView }.first {
            let rect = $0.convert($0.bounds, to: window)
            return $0.image != nil && !$0.isHidden && $0.alpha > 0
                && rect.width >= 12 && rect.width <= 44 && rect.height >= 12
                && rect.midX < frame.midX
        })
        let buttonFrame = symbol.convert(symbol.bounds, to: window)
        XCTAssertLessThan(buttonFrame.maxX, frame.midX, "Close belongs on the left")
        XCTAssertGreaterThanOrEqual(buttonFrame.minY, frame.minY)
        XCTAssertLessThan(buttonFrame.maxY, frame.minY + 120, "Close belongs at the top of its sheet, including medium detents")

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        XCTAssertFalse((request.results ?? []).contains {
            $0.topCandidates(1).first?.string == "Done"
        }, "The old Done pill must not remain visible")
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func navigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigation(in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "Modal presentation or dismissal must complete")
    }

    private final class WindowFixture {
        let window: UIWindow
        let previous: UIWindow?
        let language: String?

        init() throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            previous = scene.windows.first(where: \.isKeyWindow)
            language = UserDefaults.standard.string(forKey: AppLanguage.preferenceKey)
            UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
            window = UIWindow(windowScene: scene)
            window.rootViewController = UIViewController()
            window.makeKeyAndVisible()
        }

        func capture() -> UIImage {
            window.layoutIfNeeded()
            return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
        }
    }
}

@MainActor @Observable
private final class ModalProbe {
    var presented = false
}

private struct ModalFixture: View {
    @Bindable var probe: ModalProbe
    let page: AnyView

    var body: some View {
        Color.clear.appSheet(isPresented: $probe.presented) { page }
    }
}
