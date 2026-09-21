import XCTest
import SwiftUI
@testable import CatfolioIOS

final class DCAAIConditionsTests: XCTestCase {
    private static let answer = #"{"schemaVersion":1,"summary":"Pause when volatile; otherwise buy twice below the SMA.","rules":[{"id":"rv","enabled":true,"join":"all","conditions":[{"metric":"rv","window":20,"comparison":"GT","threshold":40}],"multiplier":0},{"id":"sma","enabled":true,"join":"all","conditions":[{"metric":"sma_ratio","window":200,"comparison":"LT","threshold":0.85}],"multiplier":2}],"fallbackMultiplier":null,"questions":[],"unsupported":[]}"#
    private func rows(_ closes: [Double]) -> ArraySlice<PolicyPricePoint> {
        ArraySlice(closes.enumerated().map { .init(day: "2024-01-\($0.offset + 1)", close: $0.element) })
    }
    private func rule(_ id: String = "one", threshold: Double = 90, multiplier: Double = 2) -> DCAConditionRule {
        .init(id: id, enabled: true, join: .all, conditions: [.init(metric: .price, window: 1, comparison: .lt, threshold: threshold)], multiplier: multiplier)
    }
    func testParseKeepsUnitsOrderAndNoImplicitFallback() throws {
        let parsed = try DCAConditionCompiler.parse(Self.answer, source: "Test")
        XCTAssertEqual(parsed.rules.map(\.id), ["rv", "sma"])
        XCTAssertEqual(parsed.rules[0].conditions[0].threshold, 40)
        XCTAssertEqual(parsed.rules[1].conditions[0].threshold, 0.85)
        XCTAssertNil(parsed.fallbackMultiplier)
        XCTAssertTrue(parsed.issues.isEmpty)
    }
    func testRejectsMalformedAndUnsupportedAIResponses() {
        for raw in ["not JSON", Self.answer.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":1,"schemaVersion":1"#),
                    Self.answer.replacingOccurrences(of: #""metric":"rv""#, with: #""metric":"news""#),
                    Self.answer.replacingOccurrences(of: #""threshold":40"#, with: #""threshold":true"#),
                    Self.answer.replacingOccurrences(of: #""threshold":0.85"#, with: #""threshold":-1"#),
                    Self.answer.replacingOccurrences(of: #""window":200"#, with: #""window":0"#),
                    Self.answer.replacingOccurrences(of: #""multiplier":2"#, with: #""multiplier":4"#),
                    Self.answer.replacingOccurrences(of: #""summary":""#, with: #""execute":"buy","summary":""#),
                    Self.answer.replacingOccurrences(of: #""id":"sma""#, with: #""id":"rv""#)] {
            XCTAssertThrowsError(try DCAConditionCompiler.parse(raw, source: "Test"))
        }
    }
    func testPredicateUsesComposerUnitsAndWindows() {
        XCTAssertEqual(DCAConditionPredicate(metric: .smaRatio, window: 2, comparison: .lt, threshold: 0.9).evaluate([100, 70]), .yes)
        XCTAssertEqual(DCAConditionPredicate(metric: .drawdown, window: 3, comparison: .lte, threshold: -20).evaluate([100, 90, 70]), .yes)
        XCTAssertEqual(DCAConditionPredicate(metric: .er, window: 2, comparison: .gte, threshold: 0.5).evaluate([100, 90, 70]), .yes)
        XCTAssertEqual(DCAConditionPredicate(metric: .priceReturn, window: 2, comparison: .lt, threshold: -20).evaluate([100, 90, 70]), .yes)
        XCTAssertEqual(DCAConditionPredicate(metric: .rv, window: 20, comparison: .gt, threshold: 40).evaluate([100, 90]), .unknown)
    }
    func testPriorityDisabledAndFallback() {
        var plan = DCAConditionPlan(rules: [rule("pause", multiplier: 0), rule("buy", multiplier: 2)])
        XCTAssertEqual(plan.decision(priorPrices: rows([80]))?.multiplier, 0)
        plan.rules[0].enabled = false
        XCTAssertEqual(plan.decision(priorPrices: rows([80]))?.multiplier, 2)
        XCTAssertNil(plan.decision(priorPrices: rows([100])))
        plan.fallbackMultiplier = 0.5
        XCTAssertEqual(plan.decision(priorPrices: rows([100]))?.multiplier, 0.5)
    }
    func testUnknownPriorityPausesButBooleanShortCircuitWorks() {
        var first = rule()
        first.conditions.append(.init(metric: .smaRatio, window: 200, comparison: .lt, threshold: 1))
        var plan = DCAConditionPlan(rules: [first, rule("later", threshold: 200)])
        XCTAssertEqual(plan.decision(priorPrices: rows([80]))?.branch, .unknown)
        // False AND unknown skips the first rule; true OR unknown matches it.
        XCTAssertEqual(plan.decision(priorPrices: rows([100]))?.multiplier, 2)
        plan.rules[0].join = .any
        XCTAssertEqual(plan.decision(priorPrices: rows([80]))?.branch, .add)
    }
    func testCustomRulesOverrideFixedDefaultWithoutLookaheadOrChangingBaseline() throws {
        var c = DCASettings()
        c.start = DayDateCodec.date(from: "2024-01-08")!; c.end = DayDateCodec.date(from: "2024-01-12")!
        let input: [PolicyPricePoint] = [.init(day: "2023-12-29", close: 100), .init(day: "2024-01-05", close: 80), .init(day: "2024-01-08", close: 200), .init(day: "2024-01-12", close: 210)]
        let original = try DCASimulation.run(settings: c, prices: input)
        XCTAssertEqual(original.trades.first?.decision.multiplier, 1)
        c.conditionPlan = .init(rules: [rule()])
        let custom = try DCASimulation.run(settings: c, prices: input)
        XCTAssertEqual(custom.trades.first?.decision.multiplier, 2)
        XCTAssertEqual(custom.final.baseline, original.final.baseline)
        XCTAssertEqual(custom.final.contributed, 1000)
        XCTAssertEqual(original.final.contributed, 500)
        XCTAssertEqual(custom.final.baselineContributed, original.final.baselineContributed)
        XCTAssertEqual(custom.trades.first?.signalDate, "2024-01-05")
        c.conditionPlan = .init(rules: [rule(threshold: 50)])
        let unmatched = try DCASimulation.run(settings: c, prices: input)
        XCTAssertEqual(unmatched.trades.first?.decision.multiplier, 1)
        XCTAssertEqual(unmatched.final.value, unmatched.final.baseline)
    }
    func testSavedPlanRoundTripsAndOlderSettingsDecode() throws {
        var c = DCASettings(); c.conditionPlan = try DCAConditionCompiler.parse(Self.answer, source: "Test").plan(source: "Test")
        XCTAssertEqual(try JSONDecoder().decode(DCASettings.self, from: JSONEncoder().encode(c)), c)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as? [String: Any])
        json.removeValue(forKey: "conditionPlan")
        XCTAssertNil(try JSONDecoder().decode(DCASettings.self, from: JSONSerialization.data(withJSONObject: json)).conditionPlan)
    }
    @MainActor
    private func finish(_ draft: DCAConditionDraftStore) async throws {
        for _ in 0..<100 {
            if !draft.isGenerating { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Generation did not finish")
    }
    @MainActor
    func testGeneratedDraftRequiresReviewAndChangedInputCannotApply() async throws {
        let draft = DCAConditionDraftStore(plan: nil, answer: { _ in Self.answer })
        draft.input = "Pause if RV20 > 40%; buy twice if SMA200 ratio < .85"
        XCTAssertFalse(draft.canApply)
        draft.generate(); try await finish(draft)
        XCTAssertTrue(draft.canApply)
        XCTAssertEqual(draft.draft.rules.count, 2)
        XCTAssertFalse(draft.visibleSummary.isEmpty)
        draft.draft.rules[0].multiplier = 0.5
        XCTAssertTrue(draft.visibleSummary.isEmpty, "AI prose must not contradict manually edited rules")
        draft.input += "; revised"
        XCTAssertFalse(draft.canApply)
        draft.clear(); XCTAssertTrue(draft.canApply); XCTAssertTrue(draft.draft.rules.isEmpty)
    }
    @MainActor
    func testUnresolvedQuestionsBlockApplication() async throws {
        let draft = DCAConditionDraftStore(plan: nil, answer: { _ in Self.answer.replacingOccurrences(of: #""questions":[]"#, with: #""questions":["Which drawdown window?"]"#) })
        draft.input = "Drawdown strategy"; draft.generate(); try await finish(draft)
        XCTAssertFalse(draft.canApply); XCTAssertEqual(draft.issues.count, 1)
    }
    @MainActor
    func testCancelledOrEditedRequestCannotReplaceDraft() async throws {
        let draft = DCAConditionDraftStore(plan: nil, answer: { _ in
            try? await Task.sleep(for: .milliseconds(30))
            return Self.answer
        })
        draft.input = "Original"; draft.generate(); draft.input = "New"
        try await finish(draft)
        XCTAssertFalse(draft.hasDraft)
        draft.generate(); draft.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(draft.hasDraft); XCTAssertFalse(draft.isGenerating)
    }
    @MainActor
    func testProviderFailureDoesNotCreateOrApplyRules() async throws {
        let draft = DCAConditionDraftStore(plan: nil, answer: { _ in throw DCAError(message: "offline") })
        draft.input = "Test"; draft.generate(); try await finish(draft)
        XCTAssertEqual(draft.error, "offline"); XCTAssertFalse(draft.hasDraft); XCTAssertFalse(draft.canApply)
    }
    @MainActor
    func testDeletedRuleBindingsCannotEditNeighbourOrResurrectLastRule() {
        let first = rule("first"), second = rule("second", threshold: 200)
        let editor = DCAConditionDraftStore(plan: .init(rules: [first, second]))
        let removed = editor.binding(for: first)
        let retained = editor.binding(for: second)
        // Retain a text-field binding as SwiftUI can during row removal.
        let threshold = removed.conditions[0].threshold
        editor.removeRule(id: first.id)
        XCTAssertEqual(threshold.wrappedValue, first.conditions[0].threshold)
        threshold.wrappedValue = 999
        removed.enabled.wrappedValue = false
        XCTAssertEqual(editor.draft.rules, [second])
        retained.multiplier.wrappedValue = 0.5
        XCTAssertEqual(editor.draft.rules[0].multiplier, 0.5)
        editor.removeRule(id: second.id)
        retained.multiplier.wrappedValue = 3
        XCTAssertTrue(editor.draft.rules.isEmpty)
        XCTAssertTrue(editor.canApply, "Deleting the last rule can be applied without regenerating")
    }
    @MainActor
    func testReorderingKeepsBindingsAttachedToRuleIDs() {
        let first = rule("first"), second = rule("second")
        let editor = DCAConditionDraftStore(plan: .init(rules: [first, second]))
        let binding = editor.binding(for: first)
        editor.moveRule(id: first.id, offset: 1)
        binding.conditions[0].threshold.wrappedValue = 123
        XCTAssertEqual(editor.draft.rules.map(\.id), [second.id, first.id])
        XCTAssertEqual(editor.draft.rules[0], second)
        XCTAssertEqual(editor.draft.rules[1].conditions[0].threshold, 123)
    }
    @MainActor
    func testClearAndRegenerationInvalidateOldBindingsWithReusedIDs() async throws {
        let initial = rule("rv")
        let editor = DCAConditionDraftStore(plan: .init(rules: [initial]), answer: { _ in Self.answer })
        let stale = editor.binding(for: initial)
        editor.clear()
        stale.multiplier.wrappedValue = 3
        XCTAssertTrue(editor.draft.rules.isEmpty)
        editor.input = "New rules"; editor.generate(); try await finish(editor)
        let generated = editor.draft
        stale.multiplier.wrappedValue = 3
        XCTAssertEqual(editor.draft, generated)
        let fresh = editor.binding(for: editor.draft.rules[0])
        editor.generate(); try await finish(editor)
        fresh.multiplier.wrappedValue = 2
        XCTAssertEqual(editor.draft, generated)
    }
    @MainActor
    func testEditorRendersAfterDeletingFirstLastAndClearingRules() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let editor = DCAConditionDraftStore(plan: .init(rules: [rule("first"), rule("last")]))
        let host = UIHostingController(rootView: DCAAIConditionsView(editor: editor, onApply: { _ in }))
        window.rootViewController = host; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(200))
        editor.removeRule(id: "first")
        try await Task.sleep(for: .milliseconds(100)); host.view.layoutIfNeeded()
        editor.removeRule(id: "last")
        try await Task.sleep(for: .milliseconds(100)); host.view.layoutIfNeeded()
        editor.clear()
        try await Task.sleep(for: .milliseconds(100)); host.view.layoutIfNeeded()
        XCTAssertTrue(editor.canApply)
        XCTAssertTrue(editor.draft.rules.isEmpty)
        XCTAssertGreaterThan(host.view.bounds.height, 0)
    }
}
