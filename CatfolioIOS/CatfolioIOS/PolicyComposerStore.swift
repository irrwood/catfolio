import Foundation
import Observation
import UIKit

/// Everything the strategy editor holds between taps: the open strategy, its
/// steps, what each step came from, the undo history and the latest run.
/// Files, validation and execution stay where they were — the workspace
/// store, the contract service and the run coordinator.
@Observable
@MainActor
final class PolicyComposerStore {
    struct Notice: Equatable {
        let text: String
        let isError: Bool
    }

    private struct Snapshot {
        let document: PolicyJSON?
        let sources: [String: String]
        let prompt: String
    }

    private(set) var workspace = PolicyWorkspace()
    private(set) var document: PolicyJSON?
    private(set) var sources: [String: String] = [:]
    /// The description the steps were made from, then each later request,
    /// one per line.
    private(set) var prompt = ""
    private(set) var library: [PolicyWorkspace] = []
    private(set) var run: PolicyRunRecord?
    private(set) var trace: PolicyRunTrace?
    private(set) var isLoaded = false
    private(set) var isGenerating = false
    /// The request the AI is working on, shown until its steps arrive.
    private(set) var pendingRequest: String?
    /// A request that did not become steps, handed back to the field.
    private(set) var failedRequest: String?
    private(set) var generationSummary: String?
    /// Steps the last AI answer added or changed, for the cards to mark.
    private(set) var changedSteps: Set<String> = []
    var notice: Notice?

    private(set) var accountIDs: [String] = []
    var runsOnRealAccounts = true

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastSaved: PolicyJSON?
    private var saveTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var isSaving = false

    var nodes: [PolicyJSON] { document?["nodes"].array ?? [] }
    var name: String { document?["name"].string ?? (workspace.title.isEmpty ? L10n.text("新策略") : workspace.title) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var issues: [String: [PolicyShortcut.StepIssue]] { document.map(PolicyShortcut.issues) ?? [:] }
    var blocker: String? {
        guard let document else { return L10n.text("先描述策略或添加步骤") }
        if !runsOnRealAccounts, !document["nodes"].array.isEmpty {
            return L10n.text("示例和公开投资者组合不能运行策略；切换到你自己的账户后再试。")
        }
        return PolicyShortcut.blocker(document)
    }
    var isRunning: Bool { trace?.isActive == true }
    /// A run of an older version of these steps: still worth showing, but
    /// labelled, because the steps above it have changed since.
    var runIsStale: Bool {
        guard let run, let document else { return false }
        return Self.steps(of: run.strategy) != Self.steps(of: document)
    }

    /// What decides a run's result: not the name, the version number or
    /// the day it ran on.
    private static func steps(of document: PolicyJSON) -> PolicyJSON {
        var document = document
        document["revision"] = .null
        document["name"] = .null
        document["dataPolicy"]["asOf"] = .null
        return document
    }
    var needsBudget: Bool {
        document?["mode"].string == "SIMULATE" && nodes.contains { ["size", "risk"].contains($0["type"].string) }
    }

    /// The accounts the rest of the app has selected. The open strategy
    /// follows them, without an undo step of its own.
    func setAccounts(_ ids: [String]) {
        accountIDs = ids
        guard let document else { return }
        let scoped = PolicyShortcut.normalized(document, accountIDs: ids)
        if scoped != document { apply(scoped, recordUndo: false) }
    }

    // MARK: Loading

    func load() async {
        guard !isLoaded else { return }
        do {
            library = try await PolicyWorkspaceStore.shared.list()
            if let first = library.first { open(first) } else { startNew() }
            setAccounts(accountIDs)
        } catch {
            startNew()
            show(error)
        }
        isLoaded = true
        await PolicyRunCoordinator.shared.observe { [weak self] record in
            await self?.receive(record)
        }
    }

    func open(_ workspace: PolicyWorkspace) {
        saveTask?.cancel()
        generationTask?.cancel()
        self.workspace = workspace
        document = workspace.validatedDocument.flatMap { try? JSONDecoder().decode(PolicyJSON.self, from: $0) }
        lastSaved = document
        sources = workspace.stepSources ?? [:]
        let draft = workspace.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = workspace.naturalLanguageDraft ?? (draft.hasPrefix("# Strategy") ? "" : draft)
        undoStack = []
        redoStack = []
        changedSteps = []
        generationSummary = nil
        isGenerating = false
        run = nil
        trace = nil
        notice = nil
        Task { await loadLatestRun() }
    }

    func startNew() {
        open(PolicyWorkspace())
    }

    func refreshLibrary() async {
        _ = await flush()
        library = (try? await PolicyWorkspaceStore.shared.list()) ?? library
    }

    private func loadLatestRun() async {
        guard let strategyID = document?["strategyId"] else { return }
        let records = (try? await PolicyRunStore.shared.list()) ?? []
        guard document?["strategyId"] == strategyID,
              let latest = records.first(where: { $0.strategy["strategyId"] == strategyID }) else { return }
        if run == nil { show(latest) }
    }

    private func receive(_ record: PolicyRunRecord) {
        guard record.strategy["strategyId"] == document?["strategyId"] else { return }
        show(record)
    }

    private func show(_ record: PolicyRunRecord) {
        run = record
        trace = PolicyRunTrace(record: record)
    }

    func showRun(_ record: PolicyRunRecord) {
        show(record)
    }

    // MARK: Editing

    private func ensureDocument() throws -> PolicyJSON {
        if let document { return document }
        return try PolicyShortcut.blank(name: L10n.text("新策略"), accountIDs: accountIDs)
    }

    private func snapshot() -> Snapshot { Snapshot(document: document, sources: sources, prompt: prompt) }

    private func apply(_ next: PolicyJSON?, sources: [String: String]? = nil, prompt: String? = nil, recordUndo: Bool = true) {
        let normalized = next.map { PolicyShortcut.normalized($0, accountIDs: accountIDs) }
        // Choosing what is already there is not an edit.
        if normalized == document, sources == nil || sources == self.sources, prompt == nil || prompt == self.prompt { return }
        if recordUndo {
            undoStack.append(snapshot())
            if undoStack.count > 100 { undoStack.removeFirst() }
            redoStack = []
        }
        document = normalized
        if let sources { self.sources = sources }
        if let prompt { self.prompt = prompt }
        let ids = Set(nodes.map { $0["nodeId"].string })
        self.sources = self.sources.filter { ids.contains($0.key) }
        changedSteps = changedSteps.intersection(ids)
        scheduleSave()
    }

    /// Every card edit comes through here: the steps change, units that
    /// depended on them follow, and the result is saved shortly after.
    func editSteps(_ change: (inout [PolicyJSON]) throws -> Void) {
        do {
            var next = try ensureDocument()
            var nodes = next["nodes"].array
            try change(&nodes)
            next["nodes"] = .array(PolicyShortcut.reconcilingThresholds(nodes))
            apply(next)
        } catch {
            show(error)
        }
    }

    func updateStep(_ nodeID: String, _ change: (PolicyJSON) -> PolicyJSON) {
        editSteps { nodes in
            guard let index = nodes.firstIndex(where: { $0["nodeId"].string == nodeID }) else { return }
            nodes[index] = change(nodes[index])
        }
    }

    func addStep(_ type: String) {
        editSteps { nodes in
            nodes.append(try PolicyTemplates.node(type, preceding: nodes))
        }
    }

    func moveSteps(from offsets: IndexSet, to destination: Int) {
        editSteps { nodes in
            nodes.move(fromOffsets: offsets, toOffset: destination)
            nodes = PolicyShortcut.rewire(nodes)
        }
    }

    func duplicateStep(_ nodeID: String) {
        editSteps { nodes in
            guard let index = nodes.firstIndex(where: { $0["nodeId"].string == nodeID }) else { return }
            var copy = nodes[index]
            copy["nodeId"] = .string("n_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10).lowercased())
            nodes.insert(copy, at: index + 1)
        }
    }

    /// The steps that would go too, because nothing else can feed them.
    func stepsRemovedWith(_ nodeID: String) -> [String] {
        var ids = [nodeID], nodes = self.nodes
        while let id = ids.last {
            let result = PolicyShortcut.removing(id, from: nodes)
            guard let orphan = result.orphans.first(where: { !ids.contains($0) }) else { break }
            nodes = result.nodes
            ids.append(orphan)
        }
        return Array(ids.dropFirst())
    }

    func deleteStep(_ nodeID: String) {
        editSteps { nodes in
            var pending = [nodeID]
            while let id = pending.popLast() {
                let result = PolicyShortcut.removing(id, from: nodes)
                nodes = result.nodes
                pending += result.orphans
            }
        }
    }

    func rename(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !trimmed.isEmpty, trimmed != self.name, var next = try? ensureDocument() else { return }
        next["name"] = .string(trimmed)
        apply(next)
    }

    func updateMaxAge(_ days: Int) {
        guard var next = document else { return }
        let quantity = PolicyTemplates.quantity(String(days), unit: "DAYS")
        guard next["dataPolicy"]["maxAgeDays"] != quantity else { return }
        next["dataPolicy"]["maxAgeDays"] = quantity
        apply(next)
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        document = previous.document
        sources = previous.sources
        prompt = previous.prompt
        changedSteps = []
        scheduleSave()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        document = next.document
        sources = next.sources
        prompt = next.prompt
        changedSteps = []
        scheduleSave()
    }

    func clearChangeMarks() {
        changedSteps = []
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            _ = await self?.flush()
        }
    }

    private static func withoutRevision(_ document: PolicyJSON?) -> PolicyJSON? {
        guard var document else { return nil }
        document["revision"] = .null
        return document
    }

    /// Writes what is on screen. A change of any kind is a new revision, so
    /// every run can say exactly which steps it ran.
    @discardableResult
    func flush() async -> Bool {
        while isSaving { try? await Task.sleep(for: .milliseconds(40)) }
        isSaving = true
        defer { isSaving = false }
        var proposed = workspace
        proposed.naturalLanguageDraft = prompt.isEmpty ? nil : prompt
        proposed.stepSources = sources.isEmpty ? nil : sources
        var saved = document
        if var next = document {
            if let lastSaved, Self.withoutRevision(lastSaved) != Self.withoutRevision(next) {
                next["revision"] = .number((lastSaved["revision"].number ?? 0) + 1)
            }
            do {
                proposed.draft = try await PolicyContractService.shared.serialize(next)
                proposed.validatedDocument = try next.data()
                proposed.title = next["name"].string
                saved = next
            } catch {
                show(PolicyContractError(message: L10n.text("这次修改没有保存：\(error.localizedDescription)")))
                return false
            }
        }
        if proposed.generation == 0, saved == nil, prompt.isEmpty { return true }
        let unchanged = proposed.generation > 0 && saved == lastSaved
            && proposed.naturalLanguageDraft == workspace.naturalLanguageDraft
            && proposed.stepSources == workspace.stepSources
        if unchanged { return true }
        do {
            let stored = try await PolicyWorkspaceStore.shared.save(proposed)
            guard stored.id == workspace.id else { return false }
            workspace = stored
            lastSaved = saved
            // Take the revision the file now has, without undoing anything
            // edited while it was being written.
            if let revision = saved?["revision"], document != nil { document?["revision"] = revision }
            if let index = library.firstIndex(where: { $0.id == stored.id }) { library[index] = stored }
            else { library.insert(stored, at: 0) }
            return true
        } catch {
            show(error)
            return false
        }
    }

    // MARK: Library

    func duplicate(_ source: PolicyWorkspace) async {
        do {
            var copy = PolicyWorkspace(title: source.title + L10n.text(" 副本"))
            copy.naturalLanguageDraft = source.naturalLanguageDraft
            copy.stepSources = source.stepSources
            if let data = source.validatedDocument, var document = try? JSONDecoder().decode(PolicyJSON.self, from: data) {
                document["strategyId"] = .string("strategy_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
                document["revision"] = .number(1)
                document["name"] = .string(copy.title)
                copy.draft = try await PolicyContractService.shared.serialize(document)
                copy.validatedDocument = try document.data()
            }
            let stored = try await PolicyWorkspaceStore.shared.save(copy)
            library.insert(stored, at: 0)
            open(stored)
        } catch {
            show(error)
        }
    }

    func delete(_ target: PolicyWorkspace) async {
        do {
            try await PolicyWorkspaceStore.shared.delete(target.id, expectedGeneration: target.generation)
            library.removeAll { $0.id == target.id }
            if workspace.id == target.id {
                if let first = library.first { open(first) } else { startNew() }
            }
        } catch {
            show(error)
        }
    }

    func revisions() async -> [PolicyJSON] {
        _ = await flush()
        return (try? await PolicyWorkspaceStore.shared.revisions(workspace.id)) ?? []
    }

    func restore(_ revision: PolicyJSON) {
        var next = revision
        next["revision"] = document?["revision"] ?? revision["revision"]
        apply(next)
    }

    func runs() async -> [PolicyRunRecord] {
        guard let strategyID = document?["strategyId"] else { return [] }
        return ((try? await PolicyRunStore.shared.list()) ?? []).filter { $0.strategy["strategyId"] == strategyID }
    }

    // MARK: AI

    /// Turns a sentence into steps, or changes the steps already there. The
    /// answer is applied at once and can be undone like any edit.
    func generate(_ instruction: String) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        generationTask?.cancel()
        isGenerating = true
        pendingRequest = text
        generationSummary = nil
        notice = nil
        let current = document
        let workspaceID = workspace.id
        generationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.workspace.id == workspaceID {
                    self.isGenerating = false
                    self.pendingRequest = nil
                }
            }
            do {
                let base = try self.ensureDocument()
                let question = PolicyShortcut.generationGuide + "\n\n" + PolicyShortcut.generationQuestion(instruction: text, current: current)
                var raw = try await Self.answer(question)
                var generated: PolicyShortcut.Generated
                var canonical: String
                do {
                    generated = try PolicyShortcut.parseGenerated(raw, base: base, accountIDs: self.accountIDs)
                    canonical = try await PolicyContractService.shared.serialize(generated.document)
                } catch {
                    // One chance to correct itself, told exactly what failed.
                    let repair = question + "\n\n上一次输出没有通过校验：\(error.localizedDescription)\n请修正后重新输出完整 JSON。上一次输出：\n\(raw)"
                    raw = try await Self.answer(repair)
                    generated = try PolicyShortcut.parseGenerated(raw, base: base, accountIDs: self.accountIDs)
                    canonical = try await PolicyContractService.shared.serialize(generated.document)
                }
                guard !Task.isCancelled, self.workspace.id == workspaceID else { return }
                let baseRevision = Int(current?["revision"].number ?? 0)
                _ = try? await PolicyWorkspaceStore.shared.saveCandidate(workspaceID: workspaceID, original: self.workspace.draft,
                                                                        candidate: canonical, rawResponse: raw, baseRevision: baseRevision)
                let isFirst = current?["nodes"].array.isEmpty ?? true
                var merged = isFirst ? [:] : self.sources
                for (id, phrase) in generated.sources { merged[id] = phrase }
                let changed = PolicyShortcut.changedSteps(from: current, to: generated.document)
                self.apply(generated.document, sources: merged, prompt: isFirst ? text : self.prompt + "\n" + text)
                self.changedSteps = isFirst ? [] : changed
                self.generationSummary = generated.summary.isEmpty ? nil : generated.summary
            } catch is CancellationError {
            } catch {
                guard self.workspace.id == workspaceID else { return }
                self.failedRequest = text
                self.show(PolicyContractError(message: L10n.text("AI 没能生成步骤：\(error.localizedDescription)")))
            }
        }
    }

    private static func answer(_ question: String) async throws -> String {
        #if DEBUG
        if LaunchArguments.contains("--policy-fixed-ai") {
            try await Task.sleep(for: .seconds(1))
            return PolicyShortcut.generationExample
        }
        #endif
        return try await LocalAIClient().researchAnswer(question, context: "", structured: true)
    }

    func takeFailedRequest() -> String? {
        defer { failedRequest = nil }
        return failedRequest
    }

    func cancelGeneration() {
        generationTask?.cancel()
        isGenerating = false
        pendingRequest = nil
    }

    // MARK: Running

    /// Runs on today's data. The data date is part of the strategy, so a run
    /// is always a run of a saved, exact revision.
    func startRun(budget: PolicyBudget?) async {
        guard runsOnRealAccounts else {
            show(PolicyContractError(message: L10n.text("示例和公开投资者组合不能运行策略；切换到你自己的账户后再试。")))
            return
        }
        guard var next = document else { return }
        if let blocker = PolicyShortcut.blocker(next) {
            show(PolicyContractError(message: blocker))
            return
        }
        next["dataPolicy"]["asOf"] = .string(ISO8601DateFormatter().string(from: .now))
        apply(next, recordUndo: false)
        saveTask?.cancel()
        guard await flush(), let saved = document else { return }
        do {
            let notify = await PolicyBackgroundService.shared.requestNotifications()
            // The permission prompt leaves the app inactive for a moment, and
            // the system only accepts background work from the foreground.
            for _ in 0..<40 where UIApplication.shared.applicationState != .active {
                try? await Task.sleep(for: .milliseconds(50))
            }
            try await PolicyRunCoordinator.shared.start(document: saved, notify: notify, foregroundOnly: false, simulationBudget: budget)
        } catch {
            show(error)
        }
    }

    func cancelRun() async {
        await PolicyRunCoordinator.shared.cancel()
    }

    // MARK: Notices

    func show(_ error: Error) {
        notice = Notice(text: error.localizedDescription, isError: true)
    }
}
