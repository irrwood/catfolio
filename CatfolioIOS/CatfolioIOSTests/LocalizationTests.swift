import Foundation
import SwiftUI
import XCTest
@testable import CatfolioIOS

final class LocalizationTests: XCTestCase {
    func testPredictionEventRetainsThreeOptionsWithIndividualVolume() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalizedMarketProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let client = PolymarketClient(session: session, cacheURL: cache)
        let markets = try await client.relatedMarkets(ticker: "FED", companyName: "FED", language: "en")
        let event = try XCTUnwrap(PolymarketRelatedEvent.grouped(markets).first)
        XCTAssertEqual(markets.count, 3)
        XCTAssertEqual(event.visibleMarkets.map(\.totalVolume), [100, 200, 300])
        XCTAssertEqual(event.visibleMarkets.map(\.id), ["fed-0", "fed-1", "fed-2"])
        XCTAssertEqual(markets.first?.probability, 0.93)
        XCTAssertEqual(markets.first?.oneDayPriceChange, 0.003)
        XCTAssertEqual(markets.first?.groupItemTitle, "0 (0 bps)")
    }

    func testPredictionProbabilityRoundsDisplayOnlyAndOldCachesDecode() throws {
        let data = Data(#"{"id":"old","question":"Old question","eventTitle":"Old event","eventSlug":"old-event","outcome":"Yes","probability":0.9349,"volume24Hours":42,"totalVolume":100}"#.utf8)
        let market = try JSONDecoder().decode(PolymarketRelatedMarket.self, from: data)
        XCTAssertEqual(market.probabilityText(locale: Locale(identifier: "en_US")), "93%")
        XCTAssertEqual(market.probability, 0.9349)
        XCTAssertNil(market.oneDayPriceChange)
        XCTAssertEqual(PolymarketRelatedEvent.grouped([market, market]).first?.markets.count, 1)
    }

    func testPredictionMarketLanguageChangesPreserveQuotesAndSeparateCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalizedMarketProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let client = PolymarketClient(session: session, cacheURL: cache)
        let chinese = try await client.relatedMarkets(ticker: "NVDA", companyName: "NVDA", language: "zh-Hans")
        let english = try await client.relatedMarkets(ticker: "NVDA", companyName: "NVDA", language: "en")
        let restored = PolymarketClient(session: session, cacheURL: cache)
        let cachedChinese = try await restored.relatedMarkets(ticker: "NVDA", companyName: "NVDA", language: "zh-Hans")
        XCTAssertEqual(chinese.first?.question, "英伟达会创新高吗？")
        XCTAssertEqual(english.first?.question, "Will Nvidia reach a record high?")
        XCTAssertEqual(cachedChinese.first?.question, chinese.first?.question)
        for market in chinese + english {
            XCTAssertEqual(market.id, "123")
            XCTAssertEqual(market.outcome, "Yes")
            XCTAssertEqual(market.probability, 0.25, accuracy: 0.001)
            XCTAssertEqual(market.volume24Hours, 42)
            XCTAssertEqual(market.eventSlug, "nvidia-record")
        }
        XCTAssertEqual(chinese.first?.localizedOutcome, "是")
    }

    func testNewsRequestsSelectMatchingEditionAndRejectWrongLanguage() throws {
        for (language, hl, edition) in [("en", "en-US", "US:en"), ("zh-Hans", "zh-CN", "CN:zh-Hans")] {
            let url = ContentLanguage.newsURL(ticker: "NVDA", name: "NVIDIA & Co", language: language)
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(items.first { $0.name == "hl" }?.value, hl)
            XCTAssertEqual(items.first { $0.name == "ceid" }?.value, edition)
            XCTAssertTrue(items.first { $0.name == "q" }!.value!.contains("NVIDIA & Co"))
        }
        XCTAssertTrue(ContentLanguage.acceptsHeadline("英伟达公布财报", language: "zh-Hans"))
        XCTAssertFalse(ContentLanguage.acceptsHeadline("Nvidia reports earnings", language: "zh-Hans"))
        XCTAssertTrue(ContentLanguage.acceptsHeadline("Nvidia reports earnings", language: "en"))
        XCTAssertFalse(ContentLanguage.acceptsHeadline("英伟达公布财报", language: "en"))
    }

    func testAIJobKeepsCapturedLanguageAcrossChildTasks() async {
        await ContentLanguage.$requested.withValue("en") {
            await Task.yield()
            let instruction = await Task { L10n.responseLanguageInstruction }.value
            XCTAssertTrue(instruction.contains("Respond in English"))
            let prompt = SecurityDebateResearch.prompt(ticker: "NVDA", name: "Nvidia", documents: [])
            XCTAssertTrue(prompt.contains("Respond in English"))
        }
        ContentLanguage.$requested.withValue("zh-Hans") {
            XCTAssertTrue(L10n.responseLanguageInstruction.contains("简体中文"))
        }
    }

    func testDebateDiskRetainsBothLanguagesForSameTicker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = SecurityDebateFile(url: directory.appendingPathComponent("debates.json"))
        let quote = "Nvidia reported quarterly results and increased its revenue guidance for the next quarter."
        let document = SecurityResearchDocument(source: PortfolioAttentionSource(id: "fixture", title: "Results",
            publisher: "Fixture", url: URL(string: "https://example.com/results")!, publishedAt: .now, tier: "primary"), text: quote)
        let question = SecurityDebateQuestion(question: "Guidance increased", whatChanged: quote,
            whyItMatters: "Revenue growth could support earnings.", watchNext: "Watch next quarter's revenue.", uncertainty: "",
            evidence: [SecurityResearchCitation(sourceID: "fixture", quote: quote)])
        let json = String(decoding: try JSONEncoder().encode(["questions": [question]]), as: UTF8.self)
        for language in ["en", "zh-Hans", "en"] {
            let debate = ContentLanguage.$requested.withValue(language) {
                SecurityDebateResearch.parse(json, ticker: "NVDA", name: "Nvidia", documents: [document])
            }
            await file.save(try XCTUnwrap(debate))
        }
        let saved = await file.load()
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(Set(saved.compactMap(\.language)), ["en", "zh-Hans"])
        XCTAssertNotEqual(ContentLanguage.cacheKey("NVDA", language: "en"), ContentLanguage.cacheKey("NVDA", language: "zh-Hans"))
    }

    func testEnglishSentenceJoinsDoNotLeakChinesePunctuation() {
        XCTAssertEqual(L10n.sentences(["First fragment", "Second sentence."], language: "en"), "First fragment. Second sentence.")
        XCTAssertEqual(L10n.sentences(["第一句", "第二句。"], language: "zh-Hans"), "第一句。第二句。")
        XCTAssertEqual(L10n.sentences([], language: "en"), "")
    }

    func testSettingsDataSourcesAndErrorsUseTheSelectedLanguage() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AppLanguage.preferenceKey)
        defer {
            if let original { defaults.set(original, forKey: AppLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(L10n.label("假数据（Trading 212 + Moomoo + IBKR）"), "Demo data (Trading 212 + Moomoo + IBKR)")
        XCTAssertEqual(L10n.label("演示账户"), "Demo account")
        let messages = [Trading212Error.invalidAPIKey.localizedDescription,
                        IBKRFlexError.invalidToken.localizedDescription,
                        LocalPortfolioError.noPortfolio.localizedDescription]
        for message in messages {
            XCTAssertNil(message.range(of: "[一-鿿。；、，：！？（）]", options: .regularExpression), message)
        }
        XCTAssertEqual(L10n.listSeparator, ", ")
        XCTAssertEqual(L10n.clauseSeparator, "; ")
        defaults.set("zh-Hans", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(Trading212Error.invalidAPIKey.localizedDescription, "API Key 不能为空，且不能包含冒号")
    }

    func testLanguageResolutionAndFallback() {
        XCTAssertEqual(AppLanguage.resolvedIdentifier("en", preferredLanguages: ["zh-CN"]), "en")
        XCTAssertEqual(AppLanguage.resolvedIdentifier("zh-Hans", preferredLanguages: ["en-GB"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.resolvedIdentifier("system", preferredLanguages: ["zh-TW"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.resolvedIdentifier(nil, preferredLanguages: ["en-GB"]), "en")
        XCTAssertEqual(AppLanguage.resolvedIdentifier("invalid", preferredLanguages: []), "en")
        XCTAssertEqual(AppLanguage.resolvedIdentifier("system", preferredLanguages: ["fr-FR", "zh-CN"]), "zh-Hans")
    }

    func testBothLanguagesAreBundledAndHaveMatchingPlaceholders() throws {
        func catalog(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: language))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
        }
        let english = try catalog("en")
        let chinese = try catalog("zh-Hans")
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        XCTAssertGreaterThan(english.count, 950)
        for (key, value) in english {
            XCTAssertEqual(key.components(separatedBy: "%@").count, value.components(separatedBy: "%@").count, key)
            XCTAssertEqual(key.components(separatedBy: "%@").count, chinese[key]?.components(separatedBy: "%@").count, key)
        }
    }

    func testSwitchingDoesNotCacheThePreviousLanguage() {
        XCTAssertEqual(L10n.render("设置", language: "en"), "Settings")
        XCTAssertEqual(L10n.render("设置", language: "zh-Hans"), "设置")
        XCTAssertEqual(L10n.render("设置", language: "en"), "Settings")
        XCTAssertEqual(L10n.render("Performance", language: "zh-Hans"), "收益表现")
    }

    func testSavedLanguageChangesAffectTheNextRender() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: AppLanguage.preferenceKey)
        defer {
            if let original { defaults.set(original, forKey: AppLanguage.preferenceKey) }
            else { defaults.removeObject(forKey: AppLanguage.preferenceKey) }
        }
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(L10n.text("语言"), "Language")
        XCTAssertEqual(L10n.text("MY"), "MY")
        defaults.set("zh-Hans", forKey: AppLanguage.preferenceKey)
        XCTAssertEqual(L10n.text("语言"), "语言")
        XCTAssertEqual(L10n.text("MY"), "我的")
    }

    func testInterpolationPreservesUserDataAndPercentSigns() {
        let account = "我的账户 %@ 100% AAPL"
        XCTAssertEqual(L10n.render("不计入\(account)", language: "en"), "Exclude \(account)")
        XCTAssertEqual(L10n.render("不计入\(account)", language: "zh-Hans"), "不计入\(account)")
        XCTAssertEqual(L10n.render("已同步 \(12) 个持仓\(" · GBP")", language: "en"), "Synced 12 holdings · GBP")
    }

    func testAccountNicknamesFollowLanguageWithStablePrefixesAndSuffixes() {
        XCTAssertEqual(L10n.accountName("IBKR · 全球账户", language: "en"), "IBKR · Global account")
        XCTAssertEqual(L10n.accountName("Moomoo · 美股账户", language: "en"), "Moomoo · US stocks account")
        XCTAssertEqual(L10n.accountName("Trading 212 · 橘子 12", language: "en"), "Trading 212 · Orange 12")
        XCTAssertEqual(L10n.accountName("CSV · Blueberry", language: "zh-Hans"), "CSV · 蓝莓")
        XCTAssertEqual(L10n.accountName("演示账户 1", language: "en"), "Demo account 1")
        XCTAssertEqual(L10n.accountName("IBKR · 全球账户", language: "zh-Hans"), "IBKR · 全球账户")
    }

    func testCustomAccountNamesAreNotPartiallyReplaced() {
        for name in ["IBKR · 我的橘子养老计划", "Trading 212 · ISA", "CSV · Team · 橘子", "Moomoo · ", "", "IBKR · 100% %@"] {
            XCTAssertEqual(L10n.accountName(name, language: "en"), name)
        }
    }

    func testUnknownKeysAndFormattedInterpolationRemainReadable() {
        XCTAssertEqual(L10n.render("unknown \(42)", language: "en"), "unknown 42")
        XCTAssertEqual(L10n.render("test \(1.234, specifier: "%.2f")", language: "en"), "test 1.23")
    }

    func testPreferencePersistsWithoutChangingFinancialPreferences() throws {
        let suite = "catfolio.localization.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("GBP", forKey: DisplayCurrency.preferenceKey)
        defaults.set("en", forKey: AppLanguage.preferenceKey)
        let reloaded = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(AppLanguage.resolvedIdentifier(reloaded.string(forKey: AppLanguage.preferenceKey)), "en")
        XCTAssertEqual(reloaded.string(forKey: DisplayCurrency.preferenceKey), "GBP")
        XCTAssertEqual(CompanyNameDisplay.original.rawValue, "原始名称")
        XCTAssertEqual(ChartTimeRange.oneMonth.rawValue, "1M")
    }
}

final class PredictionMarketLayoutTests: XCTestCase {
    @MainActor
    func testReferenceEventLayoutInLightAndDarkAppearance() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let markets = (0..<3).map { index in
            PolymarketRelatedMarket(id: "fed-\(index)", question: "Will there be \(index) rate cuts?",
                eventTitle: "How many Fed rate cuts in 2026?", eventSlug: "fed-cuts-2026", outcome: "Yes",
                probability: [0.93, 0.06, 0.01][index], volume24Hours: 42,
                totalVolume: [42_190_000, 7_000_000, 3_000_000][index], endDate: nil,
                groupItemTitle: "\(index) (\(index * 25) bps)", oneDayPriceChange: [0.003, 0.001, -0.002][index])
        }
        let event = try XCTUnwrap(PolymarketRelatedEvent.grouped(markets).first)
        XCTAssertEqual(event.visibleMarkets.count, 3)
        for dark in [false, true] {
            let host = UIHostingController(rootView: PolymarketEventCard(event: event)
                .padding(16)
                .frame(width: 402, alignment: .topLeading)
                .background(Color(uiColor: .systemBackground))
                .environment(\.locale, Locale(identifier: "en_US"))
                .environment(\.colorScheme, dark ? .dark : .light))
            // Measure the card itself, not the test window's status/home areas.
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(120))
            let size = host.sizeThatFits(in: CGSize(width: 402, height: 1000))
            XCTAssertLessThan(size.height, 240, "Three aligned options should stay compact")
            host.view.bounds = CGRect(origin: .zero, size: size)
            host.view.layoutIfNeeded()
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            })
            attachment.name = dark ? "prediction-event-dark" : "prediction-event-light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        previous?.makeKeyAndVisible()
    }
}

private final class LocalizedMarketProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body: String
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let isFed = items.contains { ($0.name == "q" && $0.value == "FED") || ($0.name == "id" && $0.value?.hasPrefix("fed-") == true) }
        if isFed {
            let markets: [[String: Any]] = (0..<13).map { index in
                let probabilities: [Double] = [0.93, 0.06, 0.01]
                let probability: Double = index < probabilities.count ? probabilities[index] : 0
                let prices: [Double] = [probability, 1 - probability]
                let changes: [Double] = [0.003, 0.001, -0.002]
                return ["id": "fed-\(index)", "question": "Will there be \(index) Fed rate cuts in 2026?",
                 "groupItemTitle": "\(index) (\(index * 25) bps)", "outcomes": "[\"Yes\",\"No\"]",
                 "outcomePrices": prices,
                 "oneDayPriceChange": changes[min(index, 2)],
                 "volume": (index + 1) * 100, "volume24hr": 42,
                 "events": [["title": "How many Fed rate cuts in 2026?"]]]
            }
            let payload: [String: Any] = url.path == "/public-search"
                ? ["events": [["id": "fed", "slug": "fed-cuts-2026", "title": "How many Fed rate cuts in 2026?", "volume": 52_190_000, "markets": markets]]]
                : ["markets": markets]
            body = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        } else if url.path == "/public-search" {
            body = #"{"events":[{"id":"1","slug":"nvidia-record","title":"Nvidia record","markets":[{"id":"123","question":"Will Nvidia reach a record high?","outcomes":"[\"Yes\",\"No\"]","outcomePrices":"[\"0.25\",\"0.75\"]","volume24hr":42,"volume":100}]}]}"#
        } else {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(url.path, "/markets/keyset")
            XCTAssertEqual(query.first { $0.name == "id" }?.value, "123")
            let chinese = query.first { $0.name == "locale" }?.value == "zh"
            body = chinese
                ? #"{"markets":[{"id":"123","question":"英伟达会创新高吗？","outcomes":"[\"是\",\"否\"]","outcomePrices":"[0.9,0.1]","events":[{"title":"英伟达新高"}]}]}"#
                : #"{"markets":[{"id":"123","question":"Will Nvidia reach a record high?","outcomes":"[\"Yes\",\"No\"]","events":[{"title":"Nvidia record"}]}]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
