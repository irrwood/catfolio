import SwiftUI
import XCTest
@testable import CatfolioIOS

final class TodayBriefViewTests: XCTestCase {
    @MainActor
    func testBriefRendersInlineLogosInBothAppearances() async throws {
        for dark in [false, true] {
            let context = fixture()
            let store = TodayBriefStore(generate: { request, _ in
                .init(text: request.context.seed, sources: [])
            })
            store.start(context)
            try await Task.sleep(for: .milliseconds(30))
            let host = UIHostingController(rootView:
                VStack(alignment: .leading, spacing: 28) {
                    TodayBriefView(context: context, store: store)
                    Text("今日盈亏").foregroundStyle(SettingsTemplate.secondaryText)
                    Text(DisplayFormat.money(context.total, signed: true, fractionDigits: 2))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(CatfolioTheme.positive)
                    Spacer()
                }
                .padding(20)
                .background(SettingsTemplate.pageBackground)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .preferredColorScheme(dark ? .dark : .light))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(200))
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Today-brief-\(dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(host.view.bounds.width, 300)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
    }

    @MainActor
    func testLongInlinePhrasesFitNarrowWidthAndAccessibilityFont() {
        let value = fixture()
        let host = UIHostingController(rootView: TodayBriefSentence(
            text: "Today moved [[portfolio|+$42.00]], led by [[stock:NVDA|A very long company name]] and [[sector:technology|Information Technology]].",
            context: value, fontSize: 48, generating: true))
        let size = host.sizeThatFits(in: CGSize(width: 280, height: 10_000))
        XCTAssertLessThanOrEqual(size.width, 280)
        XCTAssertGreaterThan(size.height, 100)
        XCTAssertLessThan(size.height, 2000)
    }

    func testExpansionAnimatesOnlyTheTappedReference() {
        XCTAssertTrue(TodayBriefSentence.animates(target: "stock:NVDA", activeTarget: "stock:NVDA", generating: true, reduceMotion: false))
        for target in [nil, "portfolio", "stock:AAPL"] as [String?] {
            XCTAssertFalse(TodayBriefSentence.animates(target: target, activeTarget: "stock:NVDA", generating: true, reduceMotion: false))
        }
        XCTAssertFalse(TodayBriefSentence.animates(target: "stock:NVDA", activeTarget: "stock:NVDA", generating: false, reduceMotion: false))
        XCTAssertFalse(TodayBriefSentence.animates(target: "stock:NVDA", activeTarget: "stock:NVDA", generating: true, reduceMotion: true))
    }

    func testSentenceWordWrappingPreservesTextAndPunctuation() {
        let source = "今天，NVIDIA +$42.00；科技上涨。"
        XCTAssertEqual(TodayBriefSentence.words(source).joined(), source)
        XCTAssertTrue(TodayBriefSentence.words("Today moved +$42.00.").contains("+$42.00."))
    }

    private func fixture() -> TodayBriefContext {
        TodayBriefContext(sessionDate: "2026-10-02", total: 42, benchmarkChange: -0.3,
            stocks: [.init(ticker: "NVDA", name: "英伟达", logoSymbol: "NVDA", changePercent: 2, amount: 60),
                     .init(ticker: "AAPL", name: "苹果", logoSymbol: "AAPL", changePercent: -1, amount: -18)],
            sectors: [.init(id: "technology", name: "科技", icon: "cpu", amount: 42)], language: "zh_CN")
    }
}
