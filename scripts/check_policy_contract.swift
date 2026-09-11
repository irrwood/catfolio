import Foundation

@main struct PolicyContractChecks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let schema = try JSONDecoder().decode(PolicyJSON.self, from: Data(contentsOf: root.appendingPathComponent("core/reference/strategy.schema.json")))
        let fixture = root.appendingPathComponent("core/reference/strategy-fixtures/return-screen.json")
        let document = try JSONDecoder().decode(PolicyJSON.self, from: Data(contentsOf: fixture))
        let text = try String(contentsOf: root.appendingPathComponent("core/reference/strategy-fixtures/return-screen.strategy.md"), encoding: .utf8)
        let parsed = try PolicyTextCodec.decode(text, schema: schema)
        precondition(parsed == document, "Shared fixture must parse exactly")
        let roundtrip = try PolicyTextCodec.decode(PolicyTextCodec.encode(document), schema: schema)
        let crlf = try PolicyTextCodec.decode(text.replacingOccurrences(of: "\n", with: "\r\n"), schema: schema)
        precondition(roundtrip == document)
        precondition(crlf == document)
        func rejects(_ text: String) {
            do { _ = try PolicyTextCodec.decode(text, schema: schema); fatalError("Invalid input accepted") }
            catch {}
        }
        rejects(text + "\n自由文字不能静默删除")
        rejects(text.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2"))
        rejects(text.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 1, \"schemaVersion\": 1"))
        rejects(text.replacingOccurrences(of: "## rank", with: "## wrong"))
        var cycle = document
        var nodes = cycle["nodes"].array
        nodes[0]["inputs"] = .object(["invalid": .object(["nodeId": .string("rank"), "port": .string("universe")])])
        cycle["nodes"] = .array(nodes)
        rejects(try PolicyTextCodec.encode(cycle))
        let blank = try PolicyTemplates.blank(accountIDs: [])
        try PolicySchemaValidator.validate(blank, schema: schema)
        let source = try PolicyTemplates.node("source", preceding: [])
        var created = blank
        created["nodes"] = .array([source])
        try PolicySchemaValidator.validate(created, schema: schema)
        precondition(PolicyCapabilities.diagnostics(document).isEmpty)
        precondition(PolicyCapabilities.diagnostics(blank).contains { $0.code == "EMPTY_GRAPH" })
        precondition(PolicyTruth.any([.yes, .unknown]) == .yes)
        precondition(PolicyTruth.any([.no, .unknown]) == .unknown)
        precondition(PolicyTruth.all([.no, .unknown]) == .no)
        precondition(PolicyTruth.all([.yes, .unknown]) == .unknown)
        precondition(PolicyExecution.indicator(metric: "sma", closes: [10, 11, 12], window: 3) == 11)
        precondition(PolicyExecution.indicator(metric: "rsi", closes: [10, 11, 10, 12], window: 3) == 75)
        precondition(PolicyExecution.indicator(metric: "rsi", closes: [10, 10, 10, 10], window: 3) == 50)
        precondition(abs(PolicyExecution.indicator(metric: "volatility", closes: [100, 110, 121], window: 2)!) < 1e-9)
        precondition(PolicyExecution.indicator(metric: "return", closes: [100, 112], window: 60) == nil)
        precondition(PolicyExecution.compare(nil, to: 10, operation: "GTE") == .unknown)
        let sessions = (0...60).map { String(format: "session-%03d", $0) }
        let snapshots = [("a", 0.2), ("b", -0.2)].map { letter, increment in
            PolicySecuritySnapshot(securityId: "fixture_security_\(letter)", listingId: "fixture_listing_\(letter)", symbol: letter, name: "Synthetic \(letter)", currency: "USD", exchangeMIC: "XNAS", prices: sessions.enumerated().map { PolicyPricePoint(day: $0.element, close: 100 + Double($0.offset) * increment) }, referenceSessions: sessions, source: "SYNTHETIC TEST ONLY", capturedAt: .now, issue: nil)
        }
        var outputs: [String: PolicyRuntimeValue] = [:]
        for node in document["nodes"].array {
            let result = try PolicyExecution.evaluate(node: node, document: document, snapshots: snapshots, outputs: outputs)
            for (port, value) in result { outputs[node["nodeId"].string + "." + port] = value }
        }
        precondition(outputs["rank.universe"]?.universe == ["fixture_security_a/fixture_listing_a"])
        precondition(abs(outputs["returns.value"]!.values["fixture_security_a/fixture_listing_a"]! - 12) < 1e-9)
        let key = snapshots[0].key
        let size = try PolicyTemplates.node("size", preceding: document["nodes"].array)
        var configuredSize = size
        configuredSize["params"]["value"] = PolicyTemplates.quantity("20", unit: "PERCENT")
        let budget = PolicyBudget(nav: 1000, currency: "USD", existingExposure: [key: 100, "unmodified": 100])
        let proposal = try PolicyExecution.evaluate(node: configuredSize, document: document, snapshots: snapshots, outputs: outputs, budget: budget)["proposal"]!
        precondition(proposal.values[key] == 200 && proposal.reasons.isEmpty)
        let unknownBudget = try PolicyExecution.evaluate(node: configuredSize, document: document, snapshots: snapshots, outputs: outputs)["proposal"]!
        precondition(unknownBudget.values.isEmpty && !unknownBudget.reasons.isEmpty)
        let overspent = try PolicyExecution.evaluate(node: configuredSize, document: document, snapshots: snapshots, outputs: outputs, budget: .init(nav: 1000, currency: "USD", existingExposure: ["unmodified": 950]))["proposal"]!
        precondition(overspent.values.isEmpty && !overspent.reasons.isEmpty)
        var risk = try PolicyTemplates.node("risk", preceding: [configuredSize])
        risk["params"]["threshold"] = PolicyTemplates.quantity("25", unit: "PERCENT")
        var proposals = outputs
        proposals[configuredSize["nodeId"].string + ".proposal"] = proposal
        let riskResult = try PolicyExecution.evaluate(node: risk, document: document, snapshots: snapshots, outputs: proposals, budget: budget)["predicate"]!
        precondition(riskResult.predicates["scalar"] == .yes)
        let guardNode = try PolicyTemplates.node("guard", preceding: [configuredSize, risk])
        proposals[risk["nodeId"].string + ".predicate"] = .init(kind: "scalarPredicate", predicates: ["scalar": .unknown])
        let blocked = try PolicyExecution.evaluate(node: guardNode, document: document, snapshots: snapshots, outputs: proposals, budget: budget)["proposal"]!
        precondition(blocked.values.isEmpty && !blocked.reasons.isEmpty)
        proposals[risk["nodeId"].string + ".predicate"] = riskResult
        let allowed = try PolicyExecution.evaluate(node: guardNode, document: document, snapshots: snapshots, outputs: proposals, budget: budget)["proposal"]!
        precondition(allowed.values[key] == 200)
        var state = try PolicyTemplates.node("state", preceding: [])
        let missingState = try PolicyExecution.evaluate(node: state, document: document, snapshots: snapshots, outputs: [:])["value"]!
        precondition(missingState.payload == .null && !missingState.reasons.isEmpty)
        state["params"]["operation"] = .string("PROPOSE_SET")
        state["params"]["value"] = .bool(true)
        state["inputs"] = .object(["condition": .object(["nodeId": risk["nodeId"], "port": .string("predicate")])])
        let delta = try PolicyExecution.evaluate(node: state, document: document, snapshots: snapshots, outputs: proposals)["delta"]!
        precondition(delta.payload?["value"] == .bool(true))
        proposals[risk["nodeId"].string + ".predicate"] = .init(kind: "scalarPredicate", predicates: ["scalar": .unknown])
        let blockedDelta = try PolicyExecution.evaluate(node: state, document: document, snapshots: snapshots, outputs: proposals)["delta"]!
        precondition(blockedDelta.payload == .null)
        let evidence: [PolicyJSON] = [.object(["id": .string("public-price-1")])]
        let validAI = PolicyExecution.thesis(raw: "{\"summary\":\"Price evidence only\",\"citations\":[\"public-price-1\"]}", evidence: evidence, universe: [key])
        precondition(validAI.reasons.isEmpty && validAI.payload?["status"].string == "CANDIDATE_REQUIRES_CONFIRMATION")
        let invalidAI = PolicyExecution.thesis(raw: "{\"summary\":\"Invented\",\"citations\":[\"made-up\"]}", evidence: evidence, universe: [key])
        precondition(!invalidAI.reasons.isEmpty && invalidAI.payload?["rawResponse"].string.contains("made-up") == true)
        let date = ISO8601DateFormatter()
        let holiday = try PolicyUSSessionCalendar.completedSessions(asOf: date.date(from: "2026-09-07T22:00:00Z")!)
        precondition(holiday.last == "2026-09-04")
        let beforeEarlyClose = try PolicyUSSessionCalendar.completedSessions(asOf: date.date(from: "2026-11-27T17:59:00Z")!)
        let afterEarlyClose = try PolicyUSSessionCalendar.completedSessions(asOf: date.date(from: "2026-11-27T18:00:00Z")!)
        precondition(beforeEarlyClose.last == "2026-11-25" && afterEarlyClose.last == "2026-11-27")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("policy-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = PolicyWorkspaceStore(directory: temporary)
        let draft = PolicyWorkspace(title: "Test", draft: "not valid; preserve me", validatedDocument: try document.data())
        let saved = try await store.save(draft)
        let reopened = try await PolicyWorkspaceStore(directory: temporary).load(saved.id)
        precondition(reopened?.draft == draft.draft && reopened?.validatedDocument == draft.validatedDocument)
        do { _ = try await store.save(draft); fatalError("Stale generation accepted") } catch PolicyWorkspaceError.conflict {}
        var conflicting = saved
        var changed = document
        changed["name"] = .string("Same revision different semantics")
        conflicting.validatedDocument = try changed.data()
        do { _ = try await store.save(conflicting); fatalError("Immutable revision overwritten") } catch PolicyWorkspaceError.conflict {}
        let difference = await PolicyContractService.shared.changes(before: document, candidate: changed)
        precondition(difference.contains("Same revision different semantics"))
        try await store.saveCandidate(workspaceID: saved.id, original: draft.draft, candidate: "candidate text", rawResponse: "injected provider response", baseRevision: 1)
        let candidateFolder = temporary.appendingPathComponent(saved.id.uuidString).appendingPathComponent("candidates")
        let candidateFiles = try FileManager.default.contentsOfDirectory(at: candidateFolder, includingPropertiesForKeys: nil)
        precondition(candidateFiles.count == 1)
        let audit = try JSONDecoder().decode(PolicyJSON.self, from: Data(contentsOf: candidateFiles[0]))
        precondition(audit["original"].string == draft.draft && audit["rawResponse"].string == "injected provider response" && audit["status"].string == "PENDING_CONFIRMATION")
        let afterCandidate = try await store.load(saved.id)
        precondition(afterCandidate?.draft == draft.draft, "Candidate must not auto-activate")
        let candidateID = try await store.candidates(saved.id)[0].id
        var adopted = saved
        changed["revision"] = .number(2)
        adopted.draft = "candidate text"
        adopted.validatedDocument = try changed.data()
        let committed = try await store.save(adopted, adoptingCandidateID: candidateID)
        let adoptedHistory = try await PolicyWorkspaceStore(directory: temporary).candidates(saved.id)
        precondition(adoptedHistory[0].record["status"].string == "ADOPTED")
        precondition(adoptedHistory[0].record["adoptedRevision"].number == 2)
        let unchangedAudit = try JSONDecoder().decode(PolicyJSON.self, from: Data(contentsOf: candidateFiles[0]))
        precondition(unchangedAudit == audit, "Original candidate evidence must remain immutable")
        do { _ = try await store.save(committed, adoptingCandidateID: candidateID); fatalError("Double adoption accepted") } catch PolicyWorkspaceError.conflict {}
        let staleID = try await store.saveCandidate(workspaceID: saved.id, original: draft.draft, candidate: "stale", rawResponse: "test", baseRevision: 1)
        do { _ = try await store.save(committed, adoptingCandidateID: staleID); fatalError("Stale candidate accepted") } catch PolicyWorkspaceError.conflict {}
        var restored = committed
        var restoredDocument = document
        restoredDocument["revision"] = .number(3)
        restored.validatedDocument = try restoredDocument.data()
        restored.draft = draft.draft
        _ = try await store.save(restored)
        let revisions = try await store.revisions(saved.id)
        precondition(revisions.map { $0["revision"].number! } == [3, 2, 1])
        precondition(revisions.last == document, "Restore must not rewrite the original revision")
        var unsupported = document
        unsupported["statePolicy"]["initialSnapshotId"] = .string("missing-snapshot")
        precondition(PolicyCapabilities.diagnostics(unsupported).contains { $0.code == "UNSUPPORTED" })
        var volume = try PolicyTemplates.node("indicator", preceding: [source])
        volume["params"]["metric"] = .string("volume")
        unsupported = document
        unsupported["nodes"] = .array([source, volume])
        precondition(PolicyCapabilities.diagnostics(unsupported).contains { $0.code == "UNSUPPORTED" && $0.nodeId == volume["nodeId"].string })
        print("PASS: shared grammar roundtrip, CRLF, duplicate keys, invalid versions, cycles, templates, persistence and conflicts")
    }
}
