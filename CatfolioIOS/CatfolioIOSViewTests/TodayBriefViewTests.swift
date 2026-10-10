import SwiftUI
import XCTest
@testable import CatfolioIOS

final class TodayBriefViewTests: XCTestCase {
    @MainActor
    private final class FrameCapture {
        var frames: [String: CGRect] = [:]
    }

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
        for source in ["Invesco EQQQ Nasdaq-100 (Acc)", "英伟达（公司）上涨。"] {
            XCTAssertEqual(TodayBriefSentence.words(source).joined(), source)
        }
        XCTAssertTrue(TodayBriefSentence.words("Invesco EQQQ Nasdaq-100 (Acc)").contains("(Acc)"))
        XCTAssertFalse(TodayBriefSentence.words("英伟达（公司）").contains("（"))
    }

    func testWrappedReferenceKeepsItsTargetAndOneFullAccessibilityLabel() {
        let context = fixture()
        let name = "Invesco EQQQ Nasdaq-100 (Acc)"
        let fragments: [TodayBriefFragment] = [
            .init(text: name, target: "stock:NVDA"),
            .init(text: " -0.6% (-$13.58).", target: nil),
            .init(text: "outdated total", target: "portfolio")
        ]
        let pieces = TodayBriefSentence.pieces(from: fragments, context: context)
        let company = pieces.filter { $0.target == "stock:NVDA" }
        XCTAssertEqual(company.map(\.text).joined(), name)
        XCTAssertEqual(company.map { $0.text.trimmingCharacters(in: .whitespaces) },
                       ["Invesco", "EQQQ", "Nasdaq-100", "(Acc)"])
        XCTAssertEqual(company.compactMap(\.referenceLabel), [name])
        XCTAssertEqual(company.first?.referenceLabel, name)
        XCTAssertEqual(pieces.filter { $0.target == "portfolio" }.map(\.text).joined(),
                       context.liveLabel("outdated total", target: "portfolio"))
    }

    @MainActor
    func testLongCompanyNameFlowsIntoFollowingNumbersWithoutAMultilineButton() async throws {
        let context = fixture()
        for name in ["Invesco EQQQ Nasdaq-100 (Acc)", "景顺纳斯达克一百指数基金（累积）"] {
            let source = "followed by [[stock:NVDA|\(name)]] -0.6% (-$13.58), [[stock:AAPL|Apple]] -1.0%."
            let pieces = TodayBriefSentence.pieces(
                from: TodayBriefFragment.parse(source, allowedTargets: context.targets), context: context)
            for width: CGFloat in [280, 362] {
                for fontSize: CGFloat in [24, 48] {
                    let frames = try await measure(TodayBriefSentence(text: source, context: context, fontSize: fontSize),
                        width: width, screenshot: name.hasPrefix("Invesco") && width == 362
                            ? "Today-brief-long-name-\(Int(fontSize))" : nil)
                    for index in pieces.indices {
                        let frame = try XCTUnwrap(frames["today.brief.piece.\(index)"])
                        XCTAssertGreaterThanOrEqual(frame.minX, -0.5)
                        XCTAssertLessThanOrEqual(frame.maxX, width + 0.5)
                        XCTAssertLessThan(frame.height, fontSize * 1.5,
                                          "A name must wrap between inline pieces, not inside a tall button")
                    }
                    let companyIndices = pieces.indices.filter { pieces[$0].target == "stock:NVDA" }
                    let firstIndex = try XCTUnwrap(companyIndices.first)
                    let first = try XCTUnwrap(frames["today.brief.piece.\(firstIndex)"])
                    let logo = try XCTUnwrap(frames["today.brief.icon.\(firstIndex)"])
                    XCTAssertEqual(logo.midY, first.midY, accuracy: 0.5)
                    XCTAssertEqual(frames.keys.filter { $0.hasPrefix("today.brief.icon.") }.count, 2,
                                   "Each company keeps exactly one logo")
                    if width == 362, fontSize == 24, name.hasPrefix("Invesco") {
                        let suffixIndex = try XCTUnwrap(pieces.firstIndex { $0.text == "(Acc)" })
                        let returnIndex = try XCTUnwrap(pieces.firstIndex { $0.text.hasPrefix("-0.6%") })
                        let suffix = try XCTUnwrap(frames["today.brief.piece.\(suffixIndex)"])
                        let dailyReturn = try XCTUnwrap(frames["today.brief.piece.\(returnIndex)"])
                        XCTAssertEqual(suffix.midY, dailyReturn.midY, accuracy: 0.5,
                                       "The return should continue after the wrapped fund suffix")
                    }
                }
            }
        }
    }

    @MainActor
    private func measure<V: View>(_ view: V, width: CGFloat, screenshot: String?) async throws -> [String: CGRect] {
        let captured = FrameCapture()
        let host = UIHostingController(rootView: view
            .frame(width: width)
            .overlayPreferenceValue(ResearchCardLayoutFrames.self) { anchors in
                GeometryReader { geometry in
                    let resolved = anchors.mapValues { geometry[$0] }
                    Color.clear
                        .onAppear { captured.frames = resolved }
                        .onChange(of: resolved) { _, frames in captured.frames = frames }
                }
                .allowsHitTesting(false)
            }
            .environment(\.colorScheme, .light)
            .background(Color.white))
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let size = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        if let screenshot {
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = screenshot
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return captured.frames
    }

    private func fixture() -> TodayBriefContext {
        TodayBriefContext(sessionDate: "2026-10-02", total: 42, benchmarkChange: -0.3,
            stocks: [.init(ticker: "NVDA", name: "英伟达", logoSymbol: "NVDA", changePercent: 2, amount: 60),
                     .init(ticker: "AAPL", name: "苹果", logoSymbol: "AAPL", changePercent: -1, amount: -18)],
            sectors: [.init(id: "technology", name: "科技", icon: "cpu", amount: 42)], language: "zh_CN")
    }
}
