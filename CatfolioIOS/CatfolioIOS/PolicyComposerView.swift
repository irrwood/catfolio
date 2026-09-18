import SwiftUI

/// Presented from Performance. Reads the accounts the rest of the app has
/// selected; the editor itself never widens them.
struct PolicyComposerEntry: View {
    @Environment(AppModel.self) private var model
    @State private var qaAccountIDs: [String]?

    var body: some View {
        PolicyComposerView(
            accountIDs: qaAccountIDs ?? model.selectedAccountKeys.sorted(),
            runsOnRealAccounts: qaAccountIDs != nil || (!model.isFakeDataMode && !model.isPublicInvestorMode)
        )
        #if DEBUG && targetEnvironment(simulator)
        .task { await prepareQAAccount() }
        #endif
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Acceptance runs in the simulator: a CSV account of public tickers with
    /// made-up share counts, created only when the ledger holds nothing else.
    private func prepareQAAccount() async {
        guard LaunchArguments.contains("--policy-qa-account") else { return }
        let name = "QA 策略验收（合成数量与成本）"
        do {
            let current = try await LocalPortfolioStore.shared.load()
            // The design preview ledger is simulator-only fixture data too.
            guard current.accounts.allSatisfy({ $0.name == name }) || current.source == "Design QA Preview" else { return }
            if current.accounts.isEmpty {
                let tickers = ["AAPL", "MSFT", "NVDA", "AMD", "PLTR", "TSLA", "KO", "XOM", "JPM", "COST"]
                let csv = "Date,Action,Ticker,Quantity,Price,Currency\n"
                    + tickers.map { "2026-01-05,BUY,\($0),1,100,USD" }.joined(separator: "\n") + "\n"
                _ = try await model.importCSV(Data(csv.utf8), filename: "QA-synthetic-account.csv", accountID: "policy-qa",
                                              accountName: name, source: "CSV", replacingAccountsOnly: true)
            }
            qaAccountIDs = try await LocalPortfolioStore.shared.load().accounts.map(\.id)
        } catch {
            qaAccountIDs = nil
        }
    }
    #endif
}

/// The strategy editor, laid out as Apple's Shortcuts lays out a shortcut:
/// the sentence it came from, then one card per action, each a sentence with
/// its blanks as tokens, then what the last run did. A field at the bottom
/// takes the next request for the AI; the play button runs it here.
struct PolicyComposerView: View {
    let accountIDs: [String]
    let runsOnRealAccounts: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @AppStorage("policy.aiConsentAccepted") private var aiConsentAccepted = false
    @AppStorage("policy.lastBudget") private var lastBudget = ""
    @State private var store = PolicyComposerStore()
    @State private var input = ""
    @FocusState private var inputFocused: Bool
    @State private var sheet: Sheet?
    @State private var pendingInstruction: String?
    @State private var pendingDeletion: String?
    @State private var renaming = false
    @State private var draftName = ""
    @State private var runTaps = 0

    private enum Sheet: String, Identifiable {
        case actions, library, history, settings, budget
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                List {
                    headerSection
                    stepsSection
                    if let trace = store.trace {
                        PolicyResultSection(trace: trace, isStale: store.runIsStale, onCancel: { Task { await store.cancelRun() } })
                            .id("results")
                    }
                    Color.clear.frame(height: 24)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .environment(\.defaultMinListRowHeight, 0)
                .background(SettingsTemplate.pageBackground)
                .onChange(of: store.trace?.isFinished) { wasFinished, isFinished in
                    guard wasFinished == false, isFinished == true else { return }
                    withAnimation(reduceMotion ? nil : .smooth) { scroll.scrollTo("results", anchor: .top) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composerBar }
            .overlay(alignment: .bottom) { noticeBanner }
            .navigationTitle(store.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu { titleMenu }
            .toolbar { toolbar }
        }
        .tint(CatfolioTheme.accent)
        .task {
            store.setAccounts(accountIDs)
            store.runsOnRealAccounts = runsOnRealAccounts
            await store.load()
        }
        .onChange(of: accountIDs) { _, ids in store.setAccounts(ids) }
        .onChange(of: runsOnRealAccounts) { _, real in store.runsOnRealAccounts = real }
        .onChange(of: store.failedRequest) { _, failed in
            if failed != nil, input.isEmpty, let text = store.takeFailedRequest() { input = text }
        }
        .task(id: store.changedSteps) {
            guard !store.changedSteps.isEmpty else { return }
            try? await Task.sleep(for: .seconds(8))
            withAnimation(.smooth) { store.clearChangeMarks() }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .actions: PolicyActionLibrary { type in store.addStep(type) }
            case .library: PolicyLibrarySheet(store: store)
            case .history: PolicyHistorySheet(store: store)
            case .settings: PolicySettingsSheet(store: store, accountCount: accountIDs.count)
            case .budget: PolicyBudgetSheet(initial: lastBudget) { amount in
                lastBudget = PolicyShortcut.format(amount)
                Task { await store.startRun(budget: PolicyBudget(nav: amount, currency: "USD", existingExposure: [:])) }
            }
            }
        }
        .alert(L10n.text("把这段话交给 AI？"), isPresented: Binding(get: { pendingInstruction != nil }, set: { if !$0 { pendingInstruction = nil } })) {
            Button(L10n.text("继续")) {
                aiConsentAccepted = true
                if let text = pendingInstruction { send(text) }
                pendingInstruction = nil
            }
            Button(L10n.text("取消"), role: .cancel) { pendingInstruction = nil }
        } message: {
            Text(L10n.text("会发送你写的这段话和现有步骤给设置里选的 AI 服务，不会发送持仓、股数、成本或账户。"))
        }
        .alert(L10n.text("重命名策略"), isPresented: $renaming) {
            TextField(L10n.text("策略名称"), text: $draftName)
            Button(L10n.text("完成")) { store.rename(draftName) }
            Button(L10n.text("取消"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.text("后面有步骤只能用这一步的结果"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.text("一起删除"), role: .destructive) {
                if let id = pendingDeletion { withAnimation(.snappy) { store.deleteStep(id) } }
                pendingDeletion = nil
            }
        } message: {
            if let id = pendingDeletion {
                Text(L10n.text("删除它会连带删除第 \(store.stepsRemovedWith(id).compactMap { dependent in store.nodes.firstIndex { $0["nodeId"].string == dependent }.map { String($0 + 1) } }.joined(separator: "、")) 步。"))
            }
        }
        .sensoryFeedback(.success, trigger: store.trace?.status == "SUCCEEDED") { wasDone, isDone in hapticsEnabled && !wasDone && isDone }
        .sensoryFeedback(.impact(weight: .medium), trigger: runTaps) { _, _ in hapticsEnabled }
    }

    // MARK: Header

    @ViewBuilder
    private var headerSection: some View {
        Group {
            if store.nodes.isEmpty && store.prompt.isEmpty && !store.isGenerating {
                PolicyEmptyState(
                    onExample: { example in input = example; inputFocused = true },
                    onAddAction: { sheet = .actions }
                )
            } else {
                PolicyPromptCard(
                    prompt: store.prompt,
                    pending: store.pendingRequest,
                    summary: store.generationSummary,
                    isGenerating: store.isGenerating,
                    onCancel: store.cancelGeneration
                )
            }
        }
        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: Steps

    @ViewBuilder
    private var stepsSection: some View {
        let nodes = store.nodes
        let issues = store.issues
        ForEach(Array(nodes.enumerated()), id: \.element["nodeId"].string) { index, node in
            let id = node["nodeId"].string
            PolicyStepCard(
                index: index,
                node: node,
                nodes: nodes,
                source: store.sources[id],
                issues: issues[id] ?? [],
                outcome: store.runIsStale ? nil : store.trace?.outcomes[id],
                isChanged: store.changedSteps.contains(id),
                onChange: { next in store.updateStep(id) { _ in next } },
                onDuplicate: { withAnimation(.snappy) { store.duplicateStep(id) } },
                onDelete: { delete(id) }
            )
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .swipeActions(edge: .trailing) {
                Button(L10n.text("删除"), systemImage: "trash", role: .destructive) { delete(id) }
            }
        }
        .onMove { offsets, destination in
            withAnimation(.snappy) { store.moveSteps(from: offsets, to: destination) }
        }

        if !nodes.isEmpty || !store.prompt.isEmpty {
            Button { sheet = .actions } label: {
                Label(L10n.text("添加动作"), systemImage: "plus")
                    .appText(.callout, weight: .semibold)
                    .foregroundStyle(CatfolioTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(CatfolioTheme.accent.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .moveDisabled(true)
        }
    }

    private func delete(_ id: String) {
        if store.stepsRemovedWith(id).isEmpty {
            withAnimation(.snappy) { store.deleteStep(id) }
        } else {
            pendingDeletion = id
        }
    }

    // MARK: Bottom bar

    private var composerBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    store.nodes.isEmpty ? L10n.text("用一句话描述你的策略") : L10n.text("告诉 AI 要改什么"),
                    text: $input, axis: .vertical
                )
                .lineLimit(1...5)
                .appText(.body)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit { submit() }
                .padding(.vertical, 12)
                .accessibilityIdentifier("policy.input")
                if store.isGenerating {
                    ProgressView().frame(width: 32, height: 44)
                } else if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(CatfolioTheme.accent)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("交给 AI"))
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(minHeight: 52)
            .policyGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))

            runButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var runButton: some View {
        Button {
            runTaps += 1
            if store.isRunning {
                Task { await store.cancelRun() }
            } else if let blocker = store.blocker {
                store.notice = .init(text: blocker, isError: false)
            } else if store.needsBudget {
                sheet = .budget
            } else {
                Task { await store.startRun(budget: nil) }
            }
        } label: {
            ZStack {
                Circle().fill(store.blocker == nil || store.isRunning ? CatfolioTheme.accent : Color(uiColor: .tertiarySystemFill))
                Image(systemName: store.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(store.blocker == nil || store.isRunning ? Color.white : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.isRunning ? L10n.text("停止运行") : L10n.text("运行策略"))
        .accessibilityHint(store.blocker ?? "")
        .accessibilityIdentifier("policy.run")
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !store.isGenerating else { return }
        if aiConsentAccepted { send(text) } else { pendingInstruction = text }
    }

    private func send(_ text: String) {
        input = ""
        inputFocused = false
        store.generate(text)
    }

    @ViewBuilder
    private var noticeBanner: some View {
        if let notice = store.notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .foregroundStyle(notice.isError ? CatfolioTheme.warning : CatfolioTheme.accent)
                Text(notice.text)
                    .appText(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(SettingsTemplate.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 80)
            .onTapGesture { withAnimation { store.notice = nil } }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: notice) {
                // An error stays until it is read and tapped away.
                guard !notice.isError else { return }
                try? await Task.sleep(for: .seconds(4))
                withAnimation { if store.notice == notice { store.notice = nil } }
            }
            .accessibilityAddTraits(.isStaticText)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                Task {
                    await store.flush()
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(L10n.text("关闭"))
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { withAnimation(.snappy) { store.undo() } } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!store.canUndo)
                .accessibilityLabel(L10n.text("撤销"))
            Button { withAnimation(.snappy) { store.redo() } } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!store.canRedo)
                .accessibilityLabel(L10n.text("重做"))
            Menu {
                Button(L10n.text("策略库"), systemImage: "square.stack") { sheet = .library }
                Button(L10n.text("运行记录与旧版本"), systemImage: "clock.arrow.circlepath") { sheet = .history }
                Button(L10n.text("数据与账户"), systemImage: "slider.horizontal.3") { sheet = .settings }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel(L10n.text("更多"))
        }
    }

    @ViewBuilder
    private var titleMenu: some View {
        Button(L10n.text("重命名"), systemImage: "pencil") {
            draftName = store.name
            renaming = true
        }
        Button(L10n.text("新建策略"), systemImage: "plus") {
            Task {
                await store.flush()
                store.startNew()
            }
        }
        Button(L10n.text("策略库"), systemImage: "square.stack") { sheet = .library }
    }
}

// MARK: - Header

private struct PolicyEmptyState: View {
    let onExample: (String) -> Void
    let onAddAction: () -> Void

    private var examples: [String] {
        [
            L10n.text("从我的持仓里，选出过去 20 个交易日涨超 5% 的，按涨幅取前 3"),
            L10n.text("找出 RSI 低于 30 的持仓"),
            L10n.text("持仓里波动率最高的 5 只"),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(CatfolioTheme.accent)
                Text(L10n.text("用一句话描述你的策略"))
                    .appText(.title, weight: .semibold)
                Text(L10n.text("AI 会把它整理成一步一步的动作。每一步都能改、能拖动，然后在手机上直接运行。不会下单。"))
                    .appText(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("试试这些"))
                    .appText(.footnote, weight: .semibold)
                    .foregroundStyle(.secondary)
                ForEach(examples, id: \.self) { example in
                    Button { onExample(example) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "text.quote").foregroundStyle(CatfolioTheme.accent)
                            Text(example).appText(.callout).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .background(SettingsTemplate.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Button(action: onAddAction) {
                Label(L10n.text("或者自己添加动作"), systemImage: "square.grid.2x2")
                    .appText(.callout, weight: .semibold)
            }
            .buttonStyle(.borderless)
        }
        .padding(.top, 12)
    }
}

private struct PolicyPromptCard: View {
    let prompt: String
    let pending: String?
    let summary: String?
    let isGenerating: Bool
    let onCancel: () -> Void

    var body: some View {
        let lines = (prompt.split(separator: "\n").map(String.init)) + (pending.map { [$0] } ?? [])
        VStack(alignment: .leading, spacing: 8) {
            if let first = lines.first {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "quote.opening")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(CatfolioTheme.accent)
                        .padding(.top, 3)
                    Text(first)
                        .appText(.body, weight: .medium)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 3)
                    Text(line).appText(.callout).foregroundStyle(.secondary)
                }
            }
            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("AI 正在整理步骤…")).appText(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("停止"), action: onCancel)
                        .appText(.footnote, weight: .semibold)
                        .buttonStyle(.borderless)
                }
            } else if let summary {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(CatfolioTheme.warning)
                    Text(summary).appText(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CatfolioTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Step card

extension PolicyShortcut.Category {
    var color: Color {
        switch self {
        case .data: CatfolioTheme.preference
        case .logic: CatfolioTheme.services
        case .sizing: CatfolioTheme.positive
        case .ai: CatfolioTheme.warning
        case .state: Color(uiColor: .systemGray)
        }
    }
}

struct PolicyActionIcon: View {
    let type: String
    var size: CGFloat = 26

    var body: some View {
        let action = PolicyShortcut.action(type)
        Image(systemName: action.symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(action.category.color, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct PolicyStepCard: View {
    let index: Int
    let node: PolicyJSON
    let nodes: [PolicyJSON]
    let source: String?
    let issues: [PolicyShortcut.StepIssue]
    let outcome: PolicyRunTrace.StepOutcome?
    let isChanged: Bool
    let onChange: (PolicyJSON) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var pulse = false

    var body: some View {
        let action = PolicyShortcut.action(node["type"].string)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                PolicyActionIcon(type: action.type)
                Text("\(index + 1)  \(action.title)")
                    .appText(.footnote, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                outcomeBadge
                Menu {
                    Button(L10n.text("复制这一步"), systemImage: "plus.square.on.square", action: onDuplicate)
                    Button(L10n.text("删除这一步"), systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 26)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.text("步骤操作"))
            }

            PolicySentenceView(node: node, nodes: nodes, index: index, onChange: onChange)

            if let source {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "text.quote")
                        .font(.system(size: 11, weight: .semibold))
                    Text(L10n.text("来自“\(source)”"))
                        .appText(.caption)
                }
                .foregroundStyle(.secondary)
            }
            ForEach(Array(issues.filter { $0.level == .problem }.enumerated()), id: \.offset) { _, issue in
                Label(issue.message, systemImage: "exclamationmark.circle.fill")
                    .appText(.caption)
                    .foregroundStyle(CatfolioTheme.danger)
            }
            if let detail = outcome?.detail, !detail.isEmpty {
                Text(detail)
                    .appText(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(14)
        .background(SettingsTemplate.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isRunning || isChanged ? 2 : 0)
                .opacity(isRunning ? (pulse ? 1 : 0.35) : 1)
        }
        .onChange(of: isRunning) { _, running in
            if running {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                pulse = false
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var isRunning: Bool { outcome?.state == .running }
    private var borderColor: Color { isRunning ? CatfolioTheme.accent : CatfolioTheme.warning }

    @ViewBuilder
    private var outcomeBadge: some View {
        if let outcome {
            switch outcome.state {
            case .running:
                ProgressView().controlSize(.small)
            case .waiting:
                EmptyView()
            default:
                if let headline = outcome.headline {
                    Text(headline)
                        .appNumber(.caption, weight: .semibold)
                        .foregroundStyle(outcome.state == .failed ? CatfolioTheme.danger : CatfolioTheme.accent)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((outcome.state == .failed ? CatfolioTheme.danger : CatfolioTheme.accent).opacity(0.1), in: Capsule())
                }
            }
        }
    }
}

// MARK: - Sentence

private struct PolicySentenceView: View {
    let node: PolicyJSON
    let nodes: [PolicyJSON]
    let index: Int
    let onChange: (PolicyJSON) -> Void

    var body: some View {
        let parts = PolicyShortcut.sentence(for: node, in: nodes)
        PolicyFlowLayout(lineSpacing: 6) {
            ForEach(Array(atoms(parts).enumerated()), id: \.offset) { _, atom in
                switch atom {
                case .text(let text):
                    Text(text).appText(.body)
                case .token(let token):
                    tokenView(token)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Words wrap as Chinese wraps — between any two characters — and a
    /// Latin word stays whole.
    private func atoms(_ parts: [PolicyShortcut.Part]) -> [PolicyShortcut.Part] {
        parts.flatMap { part -> [PolicyShortcut.Part] in
            guard case .text(let text) = part else { return [part] }
            var result: [String] = [], word = ""
            for character in text {
                if character.isASCII && !character.isWhitespace {
                    word.append(character)
                } else {
                    if !word.isEmpty { result.append(word); word = "" }
                    if character.isWhitespace, let last = result.popLast() { result.append(last + " ") }
                    else if !character.isWhitespace { result.append(String(character)) }
                }
            }
            if !word.isEmpty { result.append(word) }
            return result.map { .text($0) }
        }
    }

    @ViewBuilder
    private func tokenView(_ token: PolicyShortcut.Token) -> some View {
        switch token {
        case let .choice(path, value, options):
            Menu {
                ForEach(options, id: \.value) { option in
                    Button {
                        onChange(PolicyShortcut.choosing(option.value, at: path, in: node))
                    } label: {
                        if option.value == value { Label(option.label, systemImage: "checkmark") } else { Text(option.label) }
                    }
                }
            } label: {
                PolicyTokenLabel(text: options.first { $0.value == value }?.label ?? value, style: .normal, chevron: true)
            }
        case let .quantity(path, rule):
            PolicyQuantityToken(quantity: PolicyShortcut.value(at: path, in: node), rule: rule) { quantity in
                onChange(PolicyShortcut.setting(quantity, at: path, in: node))
            }
        case let .variable(input, kind):
            let current = PolicyShortcut.source(of: node["inputs"][input], in: nodes)
            let valid = current.map { $0.step - 1 < index } ?? false
            let options = PolicyShortcut.sources(kind: kind, before: index, in: nodes)
            Menu {
                if options.isEmpty {
                    Text(L10n.text("上面还没有能用的结果"))
                }
                ForEach(options) { option in
                    Button {
                        var next = node
                        next["inputs"][input] = PolicyShortcut.edge(option)
                        onChange(next)
                    } label: {
                        Label(L10n.text("第 \(option.step) 步 · \(option.name)"), systemImage: PolicyShortcut.action(option.nodeType).symbol)
                    }
                }
            } label: {
                if let current, valid {
                    PolicyTokenLabel(text: current.name, style: .variable, symbol: PolicyShortcut.action(current.nodeType).symbol)
                } else {
                    PolicyTokenLabel(text: L10n.text("选择结果"), style: .missing)
                }
            }
        case .fixed(let text):
            PolicyTokenLabel(text: text, style: .fixed)
        }
    }
}

struct PolicyTokenLabel: View {
    enum Style { case normal, variable, fixed, missing }
    let text: String
    let style: Style
    var symbol: String? = nil
    var chevron = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            }
            Text(text).appText(.body, weight: .medium).lineLimit(1)
            if chevron {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            switch style {
            case .missing:
                shape.strokeBorder(CatfolioTheme.warning, style: StrokeStyle(lineWidth: 1.3, dash: [4, 3]))
            case .fixed:
                shape.fill(Color(uiColor: .tertiarySystemFill))
            default:
                shape.fill(tint.opacity(0.14))
            }
        }
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
    }

    private var tint: Color { style == .variable ? CatfolioTheme.services : CatfolioTheme.accent }

    private var foreground: Color {
        switch style {
        case .missing: CatfolioTheme.warning
        case .fixed: .primary
        default: tint
        }
    }
}

private struct PolicyQuantityToken: View {
    let quantity: PolicyJSON
    let rule: PolicyShortcut.QuantityRule
    let onCommit: (PolicyJSON) -> Void
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            if let text = PolicyShortcut.display(quantity) {
                PolicyTokenLabel(text: text, style: .normal)
            } else {
                PolicyTokenLabel(text: placeholder, style: .missing)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $editing, arrowEdge: .top) {
            PolicyQuantityEditor(quantity: quantity, rule: rule) { value in
                onCommit(value)
                editing = false
            }
            .presentationCompactAdaptation(.popover)
        }
        .accessibilityHint(quantity["reason"].string)
    }

    private var placeholder: String {
        switch rule.unit {
        case "PERCENT": "？%"
        case "PRICE", "CURRENCY": "$？"
        default: "？ " + PolicyShortcut.unitSuffix(rule)
        }
    }
}

private struct PolicyQuantityEditor: View {
    let quantity: PolicyJSON
    let rule: PolicyShortcut.QuantityRule
    let onCommit: (PolicyJSON) -> Void
    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !quantity["reason"].string.isEmpty {
                Text(quantity["reason"].string)
                    .appText(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if rule.unit == "PRICE" || rule.unit == "CURRENCY" {
                    Text("$").appNumber(.title)
                }
                // The current number is the placeholder: typing replaces it,
                // and an empty field keeps it.
                TextField(current ?? L10n.text("数字"), text: $text)
                    .appNumber(.title)
                    .keyboardType(rule.minimum < 0 ? .numbersAndPunctuation : (rule.integer ? .numberPad : .decimalPad))
                    .focused($focused)
                    .onSubmit(commit)
                    .onChange(of: text) { _, _ in error = nil }
                if rule.unit != "PRICE" && rule.unit != "CURRENCY" {
                    Text(PolicyShortcut.unitSuffix(rule)).appText(.body).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).appText(.caption).foregroundStyle(CatfolioTheme.danger)
            }
            Button(action: commit) {
                Text(L10n.text("完成")).appText(.callout, weight: .semibold).frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 260)
        .onAppear { focused = true }
    }

    private var current: String? {
        quantity["state"].string == "RESOLVED" ? quantity["value"].string : nil
    }

    private func commit() {
        if text.trimmingCharacters(in: .whitespaces).isEmpty, current != nil {
            onCommit(quantity)
            return
        }
        switch PolicyShortcut.quantity(from: text, rule: rule) {
        case .success(let value): onCommit(value)
        case .failure(let failure): error = failure.message
        }
    }
}

/// Lays its children out like text: left to right, wrapping when a line is
/// full, each line centred on its tallest item.
struct PolicyFlowLayout: Layout {
    var lineSpacing: CGFloat = 6

    private func lines(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [[(index: Int, size: CGSize)]] {
        let width = proposal.width ?? .infinity
        var lines: [[(Int, CGSize)]] = [[]], lineWidth: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let fitted = CGSize(width: min(size.width, width), height: size.height)
            if lineWidth + fitted.width > width, !lines[lines.count - 1].isEmpty {
                lines.append([])
                lineWidth = 0
            }
            lines[lines.count - 1].append((index, fitted))
            lineWidth += fitted.width
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = lines(proposal, subviews)
        let width = lines.map { $0.reduce(0) { $0 + $1.size.width } }.max() ?? 0
        let height = lines.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(ProposedViewSize(width: bounds.width, height: nil), subviews) {
            let height = line.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for item in line {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width
            }
            y += height + lineSpacing
        }
    }
}

// MARK: - Results

private struct PolicyResultSection: View {
    let trace: PolicyRunTrace
    let isStale: Bool
    let onCancel: () -> Void
    @State private var showsAllExcluded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("运行结果")).appText(.heading, weight: .semibold)
                Spacer()
                statusLabel
            }
            if isStale {
                Label(L10n.text("步骤改过了，这是改之前的结果。再运行一次看新结果。"), systemImage: "clock.arrow.circlepath")
                    .appText(.caption)
                    .foregroundStyle(CatfolioTheme.warning)
            }
            if trace.isActive {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.text("正在本机运行，结果会一步一步出现在上面。")).appText(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("停止"), action: onCancel).buttonStyle(.borderless).appText(.footnote, weight: .semibold)
                }
            }
            ForEach(trace.groups) { group in
                PolicyResultGroupCard(group: group)
            }
            if !trace.excluded.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("没入选的 \(trace.excluded.count) 只，和原因"))
                        .appText(.callout, weight: .semibold)
                    ForEach(showsAllExcluded ? trace.excluded : Array(trace.excluded.prefix(6))) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(item.symbol).appText(.callout, weight: .semibold).frame(minWidth: 56, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.text("第 \(item.step) 步：\(item.reason)"))
                                    .appText(.footnote)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !item.name.isEmpty {
                                    Text(item.name).appText(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                    }
                    if trace.excluded.count > 6 {
                        Button(showsAllExcluded ? L10n.text("收起") : L10n.text("显示全部 \(trace.excluded.count) 只")) {
                            withAnimation(.snappy) { showsAllExcluded.toggle() }
                        }
                        .buttonStyle(.borderless)
                        .appText(.footnote, weight: .semibold)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SettingsTemplate.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            if trace.isFinished {
                Text(footnote).appText(.caption).foregroundStyle(.secondary)
            }
        }
        .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .moveDisabled(true)
    }

    /// Failures explain themselves; a finished run says what it read.
    private var footnote: String {
        if ["FAILED", "CANCELLED"].contains(trace.status), let notice = trace.notice { return notice }
        let date = trace.dataDate.map { L10n.text("用 \($0) 的收盘价") } ?? L10n.text("用最近的收盘价")
        return date + L10n.text("在本机计算。只读结果，不会下单。")
    }

    @ViewBuilder
    private var statusLabel: some View {
        let (text, color): (String, Color) = switch trace.status {
        case "SUCCEEDED": (L10n.text("完成"), CatfolioTheme.positive)
        case "INCOMPLETE": (L10n.text("部分数据缺失"), CatfolioTheme.warning)
        case "FAILED": (L10n.text("没有跑完"), CatfolioTheme.danger)
        case "CANCELLED": (L10n.text("已停止"), Color.secondary)
        case "QUEUED": (L10n.text("排队中"), Color.secondary)
        default: (L10n.text("运行中"), CatfolioTheme.accent)
        }
        Text(text).appText(.footnote, weight: .semibold).foregroundStyle(color)
    }
}

private struct PolicyResultGroupCard: View {
    let group: PolicyRunTrace.Group

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.text("第 \(group.step) 步 · \(group.title)"))
                    .appText(.callout, weight: .semibold)
                Spacer()
                if !group.rows.isEmpty {
                    Text(L10n.text("\(group.rows.count) 只")).appNumber(.footnote).foregroundStyle(.secondary)
                }
            }
            if let text = group.text {
                Text(text).appText(.footnote).foregroundStyle(.secondary)
            }
            if group.rows.isEmpty && group.text == nil {
                Text(L10n.text("没有证券满足条件")).appText(.footnote).foregroundStyle(.secondary)
            }
            ForEach(group.rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.symbol).appText(.body, weight: .semibold)
                        Text(row.name).appText(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        if let value = row.value {
                            Text(value).appNumber(.body, weight: .semibold)
                        }
                    }
                    if !row.trail.isEmpty {
                        Text(row.trail.joined(separator: " · "))
                            .appText(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsTemplate.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(CatfolioTheme.accent.opacity(0.35), lineWidth: 1)
        }
    }
}

// MARK: - Sheets

private struct PolicyActionLibrary: View {
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(PolicyShortcut.Category.allCases, id: \.self) { category in
                    let actions = PolicyShortcut.actions.filter { $0.category == category && !$0.isAdvanced && matches($0) }
                    if !actions.isEmpty {
                        Section(category.title) { ForEach(actions) { row($0) } }
                    }
                }
                let advanced = PolicyShortcut.actions.filter { $0.isAdvanced && matches($0) }
                if !advanced.isEmpty {
                    Section {
                        ForEach(advanced) { row($0) }
                    } header: {
                        Text(L10n.text("高级"))
                    } footer: {
                        Text(L10n.text("风险检查和执行保护只作用于模拟配置，不会下单。"))
                    }
                }
            }
            .searchable(text: $query, prompt: L10n.text("搜索动作"))
            .navigationTitle(L10n.text("添加动作"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func matches(_ action: PolicyShortcut.Action) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || action.title.localizedCaseInsensitiveContains(needle) || action.subtitle.localizedCaseInsensitiveContains(needle)
    }

    private func row(_ action: PolicyShortcut.Action) -> some View {
        Button {
            onPick(action.type)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                PolicyActionIcon(type: action.type, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).appText(.body, weight: .medium).foregroundStyle(.primary)
                    Text(action.subtitle).appText(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct PolicyLibrarySheet: View {
    let store: PolicyComposerStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: PolicyWorkspace?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.library) { entry in
                    Button {
                        Task {
                            await store.flush()
                            store.open(entry)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title.isEmpty ? L10n.text("未命名策略") : entry.title)
                                    .appText(.body, weight: .medium).foregroundStyle(.primary)
                                Text(subtitle(entry)).appText(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if entry.id == store.workspace.id {
                                Image(systemName: "checkmark").foregroundStyle(CatfolioTheme.accent)
                            }
                        }
                    }
                    .swipeActions {
                        Button(L10n.text("删除"), systemImage: "trash", role: .destructive) { pendingDelete = entry }
                        Button(L10n.text("复制"), systemImage: "plus.square.on.square") {
                            Task { await store.duplicate(entry); dismiss() }
                        }
                        .tint(CatfolioTheme.accent)
                    }
                }
            }
            .overlay {
                if store.library.isEmpty {
                    ContentUnavailableView(L10n.text("还没有保存的策略"), systemImage: "square.stack",
                                           description: Text(L10n.text("描述一个策略后会自动保存在这里。")))
                }
            }
            .navigationTitle(L10n.text("策略库"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.text("新建"), systemImage: "plus") {
                        Task {
                            await store.flush()
                            store.startNew()
                            dismiss()
                        }
                    }
                }
            }
            .task { await store.refreshLibrary() }
            .confirmationDialog(L10n.text("删除这个策略？"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button(L10n.text("删除"), role: .destructive) {
                    if let target = pendingDelete { Task { await store.delete(target) } }
                    pendingDelete = nil
                }
            } message: {
                Text(L10n.text("它的旧版本也会一起删除，运行记录会保留。"))
            }
        }
    }

    private func subtitle(_ entry: PolicyWorkspace) -> String {
        let steps = entry.validatedDocument.flatMap { try? JSONDecoder().decode(PolicyJSON.self, from: $0) }?["nodes"].array.count ?? 0
        return L10n.text("\(steps) 步 · \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

private struct PolicyHistorySheet: View {
    let store: PolicyComposerStore
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [PolicyRunRecord] = []
    @State private var revisions: [PolicyJSON] = []
    @State private var pendingRestore: PolicyJSON?

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.text("运行记录")) {
                    if runs.isEmpty {
                        Text(L10n.text("还没有运行过")).foregroundStyle(.secondary)
                    }
                    ForEach(runs) { record in
                        Button {
                            store.showRun(record)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(record.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .appText(.body, weight: .medium).foregroundStyle(.primary)
                                Text(L10n.text("版本 \(Int(record.strategy["revision"].number ?? 0)) · \(status(record))"))
                                    .appText(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    ForEach(Array(revisions.enumerated()), id: \.offset) { _, revision in
                        Button { pendingRestore = revision } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(L10n.text("版本 \(Int(revision["revision"].number ?? 0))"))
                                    .appText(.body, weight: .medium).foregroundStyle(.primary)
                                Text(revision["nodes"].array.map { PolicyShortcut.action($0["type"].string).title }.joined(separator: " → "))
                                    .appText(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                } header: {
                    Text(L10n.text("旧版本"))
                } footer: {
                    Text(L10n.text("恢复旧版本会成为一个新版本，可以撤销。"))
                }
            }
            .navigationTitle(L10n.text("运行记录与旧版本"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { dismiss() } } }
            .task {
                runs = await store.runs()
                revisions = await store.revisions()
            }
            .confirmationDialog(L10n.text("恢复到这个版本？"), isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }), titleVisibility: .visible) {
                Button(L10n.text("恢复")) {
                    if let revision = pendingRestore { store.restore(revision) }
                    pendingRestore = nil
                    dismiss()
                }
            }
        }
    }

    private func status(_ record: PolicyRunRecord) -> String {
        switch record.artifact["status"].string {
        case "SUCCEEDED": L10n.text("完成")
        case "INCOMPLETE": L10n.text("部分数据缺失")
        case "FAILED": L10n.text("没有跑完")
        case "CANCELLED": L10n.text("已停止")
        default: L10n.text("运行中")
        }
    }
}

private struct PolicySettingsSheet: View {
    let store: PolicyComposerStore
    let accountCount: Int
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var maxAge = 7

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("名称")) {
                    TextField(L10n.text("策略名称"), text: $name)
                        .onSubmit { store.rename(name) }
                }
                Section {
                    LabeledContent(L10n.text("账户"), value: L10n.text("\(accountCount) 个"))
                } footer: {
                    Text(L10n.text("跟随设置里选中的账户。策略只读取这些账户的持仓，不会下单，也不连接券商下单接口。"))
                }
                Section {
                    Stepper(value: $maxAge, in: 0...30) {
                        LabeledContent(L10n.text("行情最多允许旧"), value: L10n.text("\(maxAge) 天"))
                    }
                } footer: {
                    Text(L10n.text("运行时用今天之前最近一个完整交易日的收盘价。行情比这更旧时，运行会停下并说明原因。"))
                }
            }
            .navigationTitle(L10n.text("数据与账户"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("完成")) {
                        store.rename(name)
                        store.updateMaxAge(maxAge)
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = store.name
                maxAge = Int(store.document?["dataPolicy"]["maxAgeDays"]["value"].string ?? "") ?? 7
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PolicyBudgetSheet: View {
    let initial: String
    let onStart: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("$").appNumber(.title)
                        TextField(L10n.text("总金额"), text: $text)
                            .appNumber(.title)
                            .keyboardType(.decimalPad)
                    }
                    if let error {
                        Text(error).appText(.caption).foregroundStyle(CatfolioTheme.danger)
                    }
                } footer: {
                    Text(L10n.text("配置步骤按这个模拟总额计算目标仓位，已选持仓也占用它。只用于这次模拟，不会写回账户，也不会下单。目前只支持美元。"))
                }
            }
            .navigationTitle(L10n.text("模拟总额"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("运行")) {
                        let cleaned = text.replacingOccurrences(of: ",", with: "")
                        guard let amount = Double(cleaned), amount.isFinite, amount > 0 else {
                            error = L10n.text("请输入大于 0 的金额")
                            return
                        }
                        onStart(amount)
                        dismiss()
                    }
                }
            }
            .onAppear { text = initial }
        }
        .presentationDetents([.height(280)])
    }
}

// MARK: - Glass

extension View {
    @ViewBuilder
    func policyGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            // Not interactive: it holds the composer's text field, and
            // interactive glass takes the touch for its press effect first —
            // the AI page's field took about six seconds to focus that way.
            softShadowGlass(in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
