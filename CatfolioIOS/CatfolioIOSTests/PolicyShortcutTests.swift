import XCTest
@testable import CatfolioIOS

/// The strategy editor's reading of a contract document: sentences and their
/// tokens, the wiring that follows moves and deletions, the AI answer, and a
/// finished run read back into cause and effect.
final class PolicyShortcutTests: XCTestCase {
    private var previousLanguagePreference: Any?

    override func setUp() {
        super.setUp()
        previousLanguagePreference = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.preferenceKey)
    }

    override func tearDown() {
        if let previousLanguagePreference {
            UserDefaults.standard.set(previousLanguagePreference, forKey: AppLanguage.preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
        }
        super.tearDown()
    }

    private func example() throws -> PolicyJSON {
        let base = try PolicyShortcut.blank(name: "测试", accountIDs: ["acct"])
        return try PolicyShortcut.parseGenerated(PolicyShortcut.generationExample, base: base, accountIDs: ["acct"]).document
    }

    private func ids(_ nodes: [PolicyJSON]) -> [String] { nodes.map { $0["nodeId"].string } }

    // MARK: AI answers

    func testTheGuideExampleIsAValidDocument() async throws {
        let base = try PolicyShortcut.blank(name: "测试", accountIDs: ["acct"])
        let generated = try PolicyShortcut.parseGenerated(PolicyShortcut.generationExample, base: base, accountIDs: ["acct"])
        _ = try await PolicyContractService.shared.serialize(generated.document)

        XCTAssertEqual(generated.document["strategyId"], base["strategyId"], "identity stays with the workspace")
        XCTAssertEqual(generated.document["accountScope"]["accountIds"].array.map(\.string), ["acct"])
        XCTAssertEqual(generated.document["name"].string, "强势持仓")
        XCTAssertEqual(generated.sources["n_up"], "涨超 5%")
        XCTAssertEqual(generated.document["outputs"].array.map { $0["nodeId"].string }, ["n_top"], "only the last step is left unused")
        XCTAssertNil(PolicyShortcut.blocker(generated.document))
    }

    func testAnswersWrappedInProseStillParseAndUnknownSourcesAreDropped() throws {
        let base = try PolicyShortcut.blank(name: "测试", accountIDs: [])
        var answer = try JSONDecoder().decode(PolicyJSON.self, from: Data(PolicyShortcut.generationExample.utf8))
        answer["sources"]["n_missing"] = .string("不存在")
        let raw = "好的，下面是结果：\n```json\n" + (try answer.text()) + "\n```"
        let generated = try PolicyShortcut.parseGenerated(raw, base: base, accountIDs: [])
        XCTAssertNil(generated.sources["n_missing"])
        XCTAssertEqual(generated.document["nodes"].array.count, 4)
    }

    func testAnAnswerWithoutStepsIsRefused() throws {
        let base = try PolicyShortcut.blank(name: "测试", accountIDs: [])
        XCTAssertThrowsError(try PolicyShortcut.parseGenerated("抱歉，我做不到。", base: base, accountIDs: []))
        XCTAssertThrowsError(try PolicyShortcut.parseGenerated(#"{"document":{"nodes":[]}}"#, base: base, accountIDs: []))
    }

    func testChangedStepsAreTheNewAndTheEdited() throws {
        let old = try example()
        var new = old
        var nodes = new["nodes"].array
        nodes[2]["params"]["threshold"] = PolicyTemplates.quantity("8", unit: "PERCENT")
        nodes.append(try PolicyTemplates.node("ai", preceding: nodes))
        new["nodes"] = .array(nodes)
        XCTAssertEqual(PolicyShortcut.changedSteps(from: old, to: new), ["n_up", nodes[4]["nodeId"].string])
    }

    // MARK: Sentences

    func testAFilterReadsAsASentenceWithItsTokens() throws {
        let document = try example()
        let nodes = document["nodes"].array
        let parts = PolicyShortcut.sentence(for: nodes[2], in: nodes)
        let tokens = parts.compactMap { part -> PolicyShortcut.Token? in
            if case .token(let token) = part { return token }
            return nil
        }
        XCTAssertEqual(tokens.count, 4)
        XCTAssertEqual(tokens[0], .variable(input: "universe", kind: "universe"))
        XCTAssertEqual(tokens[1], .variable(input: "value", kind: "values"))
        guard case let .quantity(path, rule) = tokens[3] else { return XCTFail("threshold is a quantity") }
        XCTAssertEqual(path, ["params", "threshold"])
        XCTAssertEqual(rule.unit, "PERCENT", "the unit comes from the indicator")
    }

    func testTokensKeepTheirOrderWhenATranslationMovesThem() {
        let parts = PolicyShortcut.sentence({ "B=\($0[1]) A=\($0[0])" }, [.fixed("a"), .fixed("b")])
        XCTAssertEqual(parts, [.text("B="), .token(.fixed("b")), .text(" A="), .token(.fixed("a"))])
    }

    func testChoosingAPriceMetricDropsTheWindowAndResetsItsFilters() throws {
        let document = try example()
        var nodes = document["nodes"].array
        nodes[1] = PolicyShortcut.choosing("price", at: ["params", "metric"], in: nodes[1])
        XCTAssertEqual(nodes[1]["params"]["window"], .null)
        XCTAssertEqual(nodes[1]["params"]["outputUnit"].string, "PRICE")
        nodes = PolicyShortcut.reconcilingThresholds(nodes)
        XCTAssertEqual(nodes[2]["params"]["threshold"]["state"].string, "UNRESOLVED", "a 5% threshold means nothing against a price")
        XCTAssertEqual(PolicyShortcut.thresholdRule(for: nodes[2], in: nodes).currency, "USD")
    }

    func testQuantitiesAreCheckedBeforeTheyReachTheDocument() {
        let window = PolicyShortcut.QuantityRule(unit: "SESSIONS", currency: nil, integer: true, minimum: 1, maximum: 250)
        XCTAssertEqual(try PolicyShortcut.quantity(from: "20", rule: window).get(), PolicyTemplates.quantity("20", unit: "SESSIONS"))
        XCTAssertThrowsError(try PolicyShortcut.quantity(from: "2.5", rule: window).get())
        XCTAssertThrowsError(try PolicyShortcut.quantity(from: "0", rule: window).get())
        XCTAssertThrowsError(try PolicyShortcut.quantity(from: "300", rule: window).get())
        XCTAssertThrowsError(try PolicyShortcut.quantity(from: "abc", rule: window).get())

        let price = PolicyShortcut.QuantityRule(unit: "PRICE", currency: "USD", integer: false, minimum: 0, maximum: nil)
        let parsed = try? PolicyShortcut.quantity(from: "1,250.5", rule: price).get()
        XCTAssertEqual(parsed?["value"].string, "1250.5")
        XCTAssertEqual(parsed?["currency"].string, "USD")
        XCTAssertEqual(PolicyShortcut.display(parsed ?? .null), "$1250.5")
    }

    // MARK: Wiring

    func testMovingAStepAboveWhatItUsesReconnectsWhatItCan() throws {
        var nodes = try example()["nodes"].array
        // Sort to the top, under the source: its list can come from the
        // source, its values have nothing above to come from.
        nodes.move(fromOffsets: [3], toOffset: 1)
        nodes = PolicyShortcut.rewire(nodes)
        XCTAssertEqual(nodes[1]["inputs"]["universe"]["nodeId"].string, "n_src")
        XCTAssertEqual(nodes[1]["inputs"]["value"]["nodeId"].string, "n_ret", "left pointing below, and reported")
        XCTAssertEqual(PolicyShortcut.brokenInputs(nodes)["n_top"], ["value"])
    }

    func testRemovingAStepHandsItsUsersToTheNearestResultAbove() throws {
        let nodes = try example()["nodes"].array
        let (remaining, orphans) = PolicyShortcut.removing("n_up", from: nodes)
        XCTAssertEqual(ids(remaining), ["n_src", "n_ret", "n_top"])
        XCTAssertEqual(remaining[2]["inputs"]["universe"]["nodeId"].string, "n_src")
        XCTAssertTrue(orphans.isEmpty)
    }

    func testRemovingTheOnlyIndicatorOrphansWhatNeedsIt() throws {
        let nodes = try example()["nodes"].array
        let (_, orphans) = PolicyShortcut.removing("n_ret", from: nodes)
        XCTAssertEqual(Set(orphans), ["n_up", "n_top"])
        XCTAssertEqual(PolicyShortcut.dependents(of: "n_ret", in: nodes), ["n_up", "n_top"])
    }

    func testNormalizingSetsWhatNobodyShouldHaveToChoose() throws {
        var document = try example()
        var nodes = document["nodes"].array
        nodes.append(try PolicyTemplates.node("size", preceding: nodes))
        document["nodes"] = .array(nodes)
        document["dataPolicy"]["maxAgeDays"] = PolicyTemplates.unresolved("?")
        let normalized = PolicyShortcut.normalized(document, accountIDs: ["b", "a"])
        XCTAssertEqual(normalized["mode"].string, "SIMULATE")
        XCTAssertEqual(normalized["accountScope"]["accountIds"].array.map(\.string), ["a", "b"])
        XCTAssertEqual(normalized["dataPolicy"]["maxAgeDays"], PolicyTemplates.quantity("7", unit: "DAYS"))
        XCTAssertEqual(normalized["outputs"].array.map { $0["port"].string }, ["proposal"])
        XCTAssertEqual(PolicyShortcut.blocker(normalized), L10n.text("还有 1 个空要填"), "the sizing value is never guessed")
    }

    // MARK: Runs

    private func snapshot(_ symbol: String, closes: [Double], sessions: [String], issue: String? = nil) -> PolicySecuritySnapshot {
        PolicySecuritySnapshot(
            securityId: "reference:US:" + symbol, listingId: "XNAS:" + symbol + ":USD", symbol: symbol, name: symbol + " Inc",
            currency: "USD", exchangeMIC: "XNAS",
            prices: zip(sessions.suffix(closes.count), closes).map { PolicyPricePoint(day: $0, close: $1) },
            referenceSessions: sessions, source: "test", capturedAt: .now, issue: issue
        )
    }

    /// Runs the example with the real engine on made-up prices.
    private func record(limit: String = "3") throws -> PolicyRunRecord {
        var document = try example()
        var nodes = document["nodes"].array
        nodes[1]["params"]["window"]["length"] = PolicyTemplates.quantity("2", unit: "SESSIONS")
        nodes[3]["params"]["limit"] = PolicyTemplates.quantity(limit, unit: "COUNT")
        document["nodes"] = .array(nodes)
        let sessions = ["2026-09-09", "2026-09-10", "2026-09-11"]
        let snapshots = [
            snapshot("AAA", closes: [100, 105, 120], sessions: sessions),   // +20%
            snapshot("BBB", closes: [100, 100, 108], sessions: sessions),   // +8%
            snapshot("CCC", closes: [100, 100, 101], sessions: sessions),   // +1%
            snapshot("DDD", closes: [100, 100, 110], sessions: sessions),   // +10%
            snapshot("EEE", closes: [], sessions: sessions, issue: "暂不支持：目前只支持美元计价的美股"),
        ]
        var outputs: [String: PolicyRuntimeValue] = [:]
        var steps: [PolicyJSON] = []
        for node in nodes {
            for (port, value) in try PolicyExecution.evaluate(node: node, document: document, snapshots: snapshots, outputs: outputs) {
                outputs[node["nodeId"].string + "." + port] = value
            }
            steps.append(.object(["nodeId": node["nodeId"], "status": .string("SUCCEEDED")]))
        }
        let artifact: PolicyJSON = .object(["runId": .string("run_test"), "status": .string("SUCCEEDED"), "steps": .array(steps)])
        return PolicyRunRecord(artifact: artifact, strategy: document, frozenPositions: Data(), securities: snapshots,
                               outputs: outputs, dataComplete: true, updatedAt: .now)
    }

    func testARunSaysWhatEachStepDidToTheList() throws {
        let trace = PolicyRunTrace(record: try record(limit: "2"))
        XCTAssertEqual(trace.outcomes["n_src"]?.headline, L10n.text("5 只"))
        XCTAssertEqual(trace.outcomes["n_ret"]?.headline, L10n.text("4 只已算出 · 1 只缺数据"))
        XCTAssertEqual(trace.outcomes["n_up"]?.headline, "5 → 3")
        XCTAssertEqual(trace.outcomes["n_top"]?.headline, "3 → 2")
        XCTAssertEqual(trace.dataDate, "2026-09-11")
    }

    func testEachResultCarriesItsTrailAndEachDropItsReason() throws {
        let trace = PolicyRunTrace(record: try record(limit: "2"))
        let lead = try XCTUnwrap(trace.groups.first)
        XCTAssertEqual(lead.step, 4)
        XCTAssertEqual(lead.rows.map(\.symbol), ["AAA", "DDD"])
        XCTAssertEqual(lead.rows.first?.value, "20.0%")
        XCTAssertEqual(lead.rows.first?.trail, [
            L10n.text("涨跌幅") + " 20.0%",
            L10n.text("满足 > 5%"),
            L10n.text("按涨跌幅排第 1"),
        ])

        let reasons = Dictionary(uniqueKeysWithValues: trace.excluded.map { ($0.symbol, ($0.step, $0.reason)) })
        XCTAssertEqual(reasons["CCC"]?.0, 3)
        XCTAssertEqual(reasons["CCC"]?.1, L10n.text("涨跌幅 1.0%，不满足 > 5%"))
        XCTAssertEqual(reasons["EEE"]?.1, "暂不支持：目前只支持美元计价的美股")
        XCTAssertEqual(reasons["BBB"]?.0, 4)
        XCTAssertEqual(reasons["BBB"]?.1, L10n.text("按涨跌幅排第 3，只保留前 2"))
    }
}
