import SwiftUI

struct AIView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AIProviderPreference.storageKey) private var aiProviderRaw = AIProviderPreference.automatic.rawValue
    let isEmbedded: Bool
    let loadsHistoryOnAppear: Bool
    let showsComposer: Bool
    @State private var messages: [ChatMessage] = []
    @State private var attentionReports: [UUID: PortfolioAttentionReport] = [:]
    /// Every conversation on the device. `messages` above is the working copy
    /// of whichever one is open; it is folded back in on every save and on
    /// every switch, so the two never drift.
    @State private var conversations: [AIConversation] = []
    @State private var activeConversationID: UUID?
    @State private var showsSidebar = false
    @State private var lastAttentionContext: String?
    @State private var question = ""
    @State private var isSending = false
    @State private var isRestoringHistory = true
    @State private var didRestoreHistory = false
    @State private var errorMessage: String?
    @State private var showsClearConfirmation = false
    @State private var isNearConversationBottom = true
    @State private var conversationScrollTarget: String? = "ai-conversation-bottom"
    @FocusState private var isComposerFocused: Bool

    private static let conversationBottomID = "ai-conversation-bottom"

    init(
        isEmbedded: Bool = false,
        loadsHistoryOnAppear: Bool = true,
        showsComposer: Bool = true
    ) {
        self.isEmbedded = isEmbedded
        self.loadsHistoryOnAppear = loadsHistoryOnAppear
        self.showsComposer = showsComposer
    }

    var body: some View {
        Group {
            if isEmbedded {
                conversation
                    .overlay(alignment: .topLeading) { sidebarButton }
                    .overlay { sidebarDrawer }
            } else {
                NavigationStack {
                    conversation
                        .softTopScrollEdge()
                        .navigationTitle("AI")
                        .toolbar {
                            if !messages.isEmpty {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button(L10n.text("清空对话"), systemImage: "trash") {
                                        showsClearConfirmation = true
                                    }
                                    .labelStyle(.iconOnly)
                                    .disabled(isSending)
                                }
                            }
                        }
                }
            }
        }
        .confirmationDialog(L10n.text("清空本机 AI 对话？"), isPresented: $showsClearConfirmation) {
            Button(L10n.text("清空对话"), role: .destructive, action: clearConversation)
        } message: {
            Text(L10n.text("此操作只会删除保存在这台 iPhone 上的聊天记录。"))
        }
    }

    private var conversation: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if isRestoringHistory {
                        ProgressView(L10n.text("正在读取本机对话…"))
                            .frame(minHeight: isEmbedded ? 300 : 420)
                    } else if messages.isEmpty && !isSending && errorMessage == nil {
                        ContentUnavailableView(
                            L10n.text("AI 投资助手"),
                            systemImage: "sparkles",
                            description: Text(L10n.text("询问组合风险、持仓集中度或近期表现。当前模型：\(selectedAIProvider.title)。"))
                        )
                        .frame(minHeight: isEmbedded ? 300 : 420)
                    }

                    // Debates started from a security sheet finish in
                    // SecurityDebateStore, not in this conversation, so they
                    // are listed rather than folded into the message history —
                    // which also leaves the chat document's schema alone.
                    SecurityDebateInbox()

                    ForEach(messages) { message in
                        ChatBubble(
                            message: message,
                            attentionReport: attentionReports[message.id]
                        )
                            .id(message.id.uuidString)
                    }

                    if isSending {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(loadingMessage)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(14)
                    }

                    if let errorMessage {
                        StatusNotice(text: errorMessage)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.conversationBottomID)
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.top, isEmbedded ? 64 : 16)
                .padding(.bottom, 16)
            }
            .background(isEmbedded ? Color.clear : Color(uiColor: .systemGroupedBackground))
            .defaultScrollAnchor(.bottom)
            .scrollPosition(id: $conversationScrollTarget, anchor: .bottom)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture(perform: dismissKeyboard)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 100
            } action: { _, isNearBottom in
                isNearConversationBottom = isNearBottom
            }
            .onChange(of: messages.count) { _, _ in
                guard let lastMessage = messages.last else { return }
                if lastMessage.role == .user || isNearConversationBottom {
                    scrollToConversationBottom()
                }
            }
            .onChange(of: isSending) { _, isNowSending in
                guard isNowSending, isNearConversationBottom else { return }
                scrollToConversationBottom()
            }

            Button {
                scrollToConversationBottom()
            } label: {
                Image(systemName: "arrow.down")
                    .font(.body.weight(.medium))
                    .frame(width: 48, height: 48)
                    .contentShape(Circle())
                    .floatingGlassSurface(in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .opacity(showsScrollToBottomButton ? 1 : 0)
            .scaleEffect(showsScrollToBottomButton ? 1 : 0.86)
            .allowsHitTesting(showsScrollToBottomButton)
            .accessibilityHidden(!showsScrollToBottomButton)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.2),
                value: showsScrollToBottomButton
            )
            .accessibilityLabel(L10n.text("回到最新对话"))
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AIComposer(
                question: $question,
                isSending: isSending,
                isFloating: isEmbedded,
                focus: $isComposerFocused,
                hasMessages: !messages.isEmpty,
                onClear: { showsClearConfirmation = true },
                onQuickSend: { preset in
                    sendQuestion(preset)
                }
            ) {
                sendQuestion()
            }
            .padding(.horizontal, isEmbedded ? 14 : 12)
            .padding(.top, isEmbedded ? 0 : 8)
            .padding(.bottom, isEmbedded ? 14 : 8)
            .opacity(showsComposer ? 1 : 0)
            .blur(radius: showsComposer ? 0 : 10)
            .scaleEffect(showsComposer ? 1 : 0.96, anchor: .bottom)
            .allowsHitTesting(showsComposer)
            .accessibilityHidden(!showsComposer)
        }
        .task(id: historyTaskID) {
            guard loadsHistoryOnAppear else { return }
            didRestoreHistory = false
            isRestoringHistory = true
            await restoreHistory()
        }
    }

    private var sidebarButton: some View {
        Button {
            isComposerFocused = false
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                showsSidebar = true
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.medium))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                .floatingGlassSurface(in: Circle())
        }
        .buttonStyle(.plain)
        .padding(14)
        .accessibilityLabel(L10n.text("对话列表"))
    }

    @ViewBuilder
    private var sidebarDrawer: some View {
        if showsSidebar {
            ZStack(alignment: .leading) {
                // The scrim is what closes the drawer, so it has to cover the
                // whole page rather than only the uncovered strip.
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: dismissSidebar)
                    .transition(.opacity)
                    .accessibilityLabel(L10n.text("关闭对话列表"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, dismissSidebar)

                sidebarPanel
                    .transition(.move(edge: .leading))
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: showsSidebar)
        }
    }

    private var sidebarPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.text("对话"))
                    .appText(.heading, weight: .semibold)
                Spacer()
                Button {
                    startNewConversation()
                    dismissSidebar()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.body.weight(.medium))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.text("新对话"))
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)

            if sidebarConversations.isEmpty {
                Text(L10n.text("还没有对话"))
                    .appText(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                Spacer()
            } else {
                List {
                    ForEach(sidebarConversations) { conversation in
                        Button {
                            openConversation(conversation.id)
                            dismissSidebar()
                        } label: {
                            sidebarRow(conversation)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(
                            conversation.id == activeConversationID
                                ? Color.primary.opacity(0.10)
                                : Color.clear
                        )
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
                        .swipeActions(edge: .trailing) {
                            Button(L10n.text("删除"), systemImage: "trash", role: .destructive) {
                                deleteConversation(conversation.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .padding(.top, 6)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        // Measured against the container rather than the screen, so a split
        // view or a Stage Manager window gets a drawer proportional to the
        // window it is actually in.
        .containerRelativeFrame(.horizontal) { width, _ in
            min(320, width * 0.82)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 0.5)
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func sidebarRow(_ conversation: AIConversation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title ?? L10n.text("新对话"))
                .appText(.body)
                .lineLimit(1)
            Text(Self.relativeDate.localizedString(for: conversation.updatedAt, relativeTo: .now))
                .appText(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    /// Built once. A formatter is expensive to create, and this one would
    /// otherwise be rebuilt for every row on every render of the drawer.
    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// The open conversation is listed even before it has been saved, so the
    /// drawer shows the chat you are looking at rather than only the ones
    /// already on disk.
    private var sidebarConversations: [AIConversation] {
        var listed = conversations
        if let activeConversationID,
           !messages.isEmpty,
           !listed.contains(where: { $0.id == activeConversationID }) {
            listed.append(AIConversation(
                id: activeConversationID,
                title: AIConversation.derivedTitle(from: messages),
                messages: messages,
                attentionReports: attentionReports
            ))
        }
        return LocalChatLibrary(conversations: listed, activeID: activeConversationID).sortedByRecency
    }

    private func dismissSidebar() {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            showsSidebar = false
        }
    }

    private func scrollToConversationBottom() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            conversationScrollTarget = Self.conversationBottomID
        }
    }

    private var showsScrollToBottomButton: Bool {
        !isNearConversationBottom && !messages.isEmpty
    }

    private func dismissKeyboard() {
        isComposerFocused = false
    }

    private var selectedAIProvider: AIProviderPreference {
        AIProviderPreference(rawValue: aiProviderRaw) ?? .automatic
    }

    private var historyTaskID: String {
        "\(loadsHistoryOnAppear)-\(model.isFakeDataMode)-\(model.isPublicInvestorMode)"
    }

    private var loadingMessage: String {
        switch selectedAIProvider {
        case .automatic: L10n.text("正在选择模型并分析组合…")
        case .apple: L10n.text("正在使用 Apple 本地模型分析…")
        case .codex: L10n.text("正在使用 ChatGPT Codex 分析…")
        case .deepSeek: L10n.text("正在使用 DeepSeek 分析…")
        }
    }

    private func restoreHistory() async {
        guard !didRestoreHistory else { return }
        didRestoreHistory = true
        defer { isRestoringHistory = false }

        // Demo and public-investor modes never touch the library on disk, so
        // they run entirely in memory. They still get a conversation id: the
        // sidebar and the composer both key off one, and a mode with none
        // would silently refuse to start a second chat.
        if model.isPublicInvestorMode {
            messages = []
            attentionReports = [:]
            lastAttentionContext = nil
            conversations = []
            activeConversationID = UUID()
            return
        }

        if model.isFakeDataMode && !model.isPublicInvestorMode {
            let history = FakeAIContent.initialHistory()
            messages = history.messages
            attentionReports = history.attentionReports
            lastAttentionContext = FakeAIContent.attentionReport.contextSummary
            errorMessage = nil
            conversations = []
            activeConversationID = UUID()
            foldActiveConversationIntoLibrary()
            return
        }

        do {
            let library = try await LocalChatStore.shared.loadLibrary()
            conversations = library.conversations
            let opened = library.active ?? library.sortedByRecency.first
            // A device with no history still needs somewhere to put the first
            // message, so an empty library opens an unsaved conversation.
            activeConversationID = opened?.id ?? UUID()
            messages = opened?.messages ?? []
            attentionReports = opened?.attentionReports ?? [:]
            lastAttentionContext = messages.reversed().compactMap { message in
                attentionReports[message.id]?.contextSummary
            }.first
        } catch {
            errorMessage = L10n.text("无法读取本机对话：\(error.localizedDescription)")
            return
        }

        // Keep opening the assistant cheap. Generating a briefing here used to
        // start portfolio decoding and an AI request while the panel was still
        // animating, which made a cold launch visibly hitch.
    }

    private func sendQuestion(_ preset: String? = nil) {
        let cleanQuestion = (preset ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty, !isSending else { return }
        question = ""
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: cleanQuestion))
        isSending = true

        Task {
            defer { isSending = false }

            if model.isFakeDataMode && !model.isPublicInvestorMode {
                try? await Task.sleep(for: .milliseconds(320))
                if Self.isAttentionPreset(cleanQuestion) {
                    let report = FakeAIContent.attentionReport
                    let message = ChatMessage(role: .assistant, text: report.markdownFallback)
                    messages.append(message)
                    attentionReports[message.id] = report
                    lastAttentionContext = report.contextSummary
                } else {
                    messages.append(ChatMessage(
                        role: .assistant,
                        text: FakeAIContent.answer(to: cleanQuestion)
                    ))
                }
                return
            }

            await persistMessages()
            do {
                if Self.isAttentionPreset(cleanQuestion) {
                    let report = try await model.portfolioAttention()
                    let message = ChatMessage(role: .assistant, text: report.markdownFallback)
                    messages.append(message)
                    attentionReports[message.id] = report
                    lastAttentionContext = report.contextSummary
                } else {
                    let answer = try await model.askAI(cleanQuestion, attentionContext: lastAttentionContext)
                    messages.append(ChatMessage(role: .assistant, text: answer))
                }
                await persistMessages()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func isAttentionPreset(_ question: String) -> Bool {
        question == "今天哪些持仓值得我关注？"
            || question == "今天哪些持仓值得我关注?"
            || question.localizedCaseInsensitiveCompare("Which holdings need my attention today?") == .orderedSame
    }

    /// Folds the working copy back into the library.
    ///
    /// Called before every save and before every switch. A conversation with
    /// nothing in it is dropped rather than stored: opening the sidebar,
    /// tapping "new chat" and changing your mind should not leave a row
    /// behind, and an untitled empty chat is indistinguishable from the next
    /// one anyway.
    private func foldActiveConversationIntoLibrary() {
        guard let activeConversationID else { return }
        guard !messages.isEmpty else {
            conversations.removeAll { $0.id == activeConversationID }
            return
        }
        let existing = conversations.first { $0.id == activeConversationID }
        let updated = AIConversation(
            id: activeConversationID,
            title: existing?.title ?? AIConversation.derivedTitle(from: messages),
            messages: messages,
            attentionReports: attentionReports,
            updatedAt: .now
        )
        if let index = conversations.firstIndex(where: { $0.id == activeConversationID }) {
            conversations[index] = updated
        } else {
            conversations.append(updated)
        }
    }

    private func persistMessages() async {
        guard !model.isFakeDataMode && !model.isPublicInvestorMode else { return }
        foldActiveConversationIntoLibrary()
        do {
            try await LocalChatStore.shared.save(
                LocalChatLibrary(conversations: conversations, activeID: activeConversationID)
            )
        } catch {
            errorMessage = L10n.text("无法保存本机对话：\(error.localizedDescription)")
        }
    }

    /// Opens an empty conversation. The current one is kept.
    private func startNewConversation() {
        foldActiveConversationIntoLibrary()
        let conversation = AIConversation()
        activeConversationID = conversation.id
        messages = []
        attentionReports = [:]
        lastAttentionContext = nil
        errorMessage = nil
        Task { await persistLibrary() }
    }

    private func openConversation(_ id: UUID) {
        guard id != activeConversationID else { return }
        foldActiveConversationIntoLibrary()
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        activeConversationID = id
        messages = conversation.messages
        attentionReports = conversation.attentionReports
        lastAttentionContext = conversation.messages.reversed().compactMap {
            conversation.attentionReports[$0.id]?.contextSummary
        }.first
        errorMessage = nil
        Task { await persistLibrary() }
    }

    private func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if id == activeConversationID {
            // Land on the next most recent rather than an empty screen, which
            // is what deleting from a list usually does.
            let next = LocalChatLibrary(conversations: conversations, activeID: nil)
                .sortedByRecency.first
            activeConversationID = next?.id ?? UUID()
            messages = next?.messages ?? []
            attentionReports = next?.attentionReports ?? [:]
            lastAttentionContext = nil
        }
        Task { await persistLibrary() }
    }

    private func persistLibrary() async {
        guard !model.isFakeDataMode && !model.isPublicInvestorMode else { return }
        do {
            try await LocalChatStore.shared.save(
                LocalChatLibrary(conversations: conversations, activeID: activeConversationID)
            )
        } catch {
            errorMessage = L10n.text("无法保存本机对话：\(error.localizedDescription)")
        }
    }

    private func clearConversation() {
        if model.isFakeDataMode || model.isPublicInvestorMode {
            messages = []
            attentionReports = [:]
            lastAttentionContext = nil
            errorMessage = nil
            return
        }

        // Only the open conversation. This used to delete the whole file,
        // which was the same thing back when the file held one conversation
        // and is emphatically not now: clearing the chat you are looking at
        // must not take every other chat with it.
        let cleared = activeConversationID
        messages = []
        attentionReports = [:]
        lastAttentionContext = nil
        errorMessage = nil
        if let cleared {
            conversations.removeAll { $0.id == cleared }
        }
        Task { await persistLibrary() }
    }
}

private enum FakeAIContent {
    private static let initialMessageID = UUID(uuidString: "D3A0D10A-7A5E-49A1-9AF4-020260904001")!

    static func initialHistory() -> LocalChatHistory {
        let message = ChatMessage(
            id: initialMessageID,
            role: .assistant,
            text: attentionReport.markdownFallback,
            createdAt: Calendar.current.date(byAdding: .minute, value: -8, to: Date()) ?? Date()
        )
        return LocalChatHistory(
            messages: [message],
            attentionReports: [message.id: attentionReport]
        )
    }

    static var attentionReport: PortfolioAttentionReport {
        PortfolioAttentionReport(
            generatedAt: Calendar.current.date(byAdding: .minute, value: -8, to: Date()) ?? Date(),
            holdingsCount: 15,
            noMaterialChangeCount: 12,
            attentionRows: [
                PortfolioAttentionHolding(
                    ticker: "ORCL",
                    name: "Oracle Corporation",
                    attention: .high,
                    weight: 0.087,
                    portfolioContributionPercent: 0.40,
                    return60DPercent: 12.6,
                    volumeMultiple: 1.9,
                    distanceFrom52WHighPercent: -2.8,
                    distanceFrom52WLowPercent: 41.2,
                    ma200PositionPercent: 18.4,
                    signals: [
                        PortfolioAttentionSignal(kind: "daily_move", label: L10n.text("+4.8% 单日涨幅"), direction: "positive", value: 4.8),
                        PortfolioAttentionSignal(kind: "volume", label: L10n.text("成交量 1.9×"), direction: "positive", value: 1.9),
                    ],
                    fundamentals: PortfolioFundamentalSnapshot(
                        source: L10n.text("演示财务数据"),
                        latestPeriod: "FY 2026 Q1",
                        revenueGrowthYoY: 8.7,
                        operatingIncomeGrowthYoY: 11.2,
                        freeCashFlowGrowthYoY: 6.4
                    ),
                    thesis: PortfolioAttentionThesis(
                        stance: .strengthening,
                        confidence: .high,
                        whatChanged: L10n.text("演示行情显示股价放量上行，并接近模拟的 52 周高位。"),
                        whyItMatters: L10n.text("ORCL 是演示组合中权重较高的科技持仓，短期动量增强会明显影响组合表现。"),
                        supportingEvidence: [L10n.text("60 日模拟收益为 +12.6%"), L10n.text("价格位于模拟 200 日均线之上 18.4%")],
                        counterEvidence: [L10n.text("接近阶段高位后，短线波动可能放大")],
                        risks: [L10n.text("估值扩张速度快于演示盈利增速")],
                        watchNext: [L10n.text("观察后续成交量能否维持"), L10n.text("关注回撤是否跌破短期趋势")],
                        riskFlags: []
                    ),
                    sources: []
                ),
                PortfolioAttentionHolding(
                    ticker: "ASML.AS",
                    name: "ASML Holding N.V.",
                    attention: .medium,
                    weight: 0.070,
                    portfolioContributionPercent: -0.15,
                    return60DPercent: -4.2,
                    volumeMultiple: 1.4,
                    distanceFrom52WHighPercent: -12.4,
                    distanceFrom52WLowPercent: 24.8,
                    ma200PositionPercent: 3.1,
                    signals: [
                        PortfolioAttentionSignal(kind: "pullback", label: L10n.text("距高点 -12.4%"), direction: "negative", value: -12.4),
                        PortfolioAttentionSignal(kind: "trend", label: L10n.text("仍高于 200 日线"), direction: "positive", value: 3.1),
                    ],
                    fundamentals: nil,
                    thesis: PortfolioAttentionThesis(
                        stance: .maintaining,
                        confidence: .medium,
                        whatChanged: L10n.text("演示价格自阶段高位回落，但长期趋势尚未破坏。"),
                        whyItMatters: L10n.text("这类高波动半导体设备持仓容易放大组合的科技周期风险。"),
                        supportingEvidence: [L10n.text("模拟价格仍在 200 日均线上方"), L10n.text("仓位权重控制在 5%以内")],
                        counterEvidence: [L10n.text("60 日模拟收益仍为负值")],
                        risks: [L10n.text("行业资本开支周期可能带来进一步波动")],
                        watchNext: [L10n.text("观察 200 日均线支撑"), L10n.text("关注半导体板块相对强弱")],
                        riskFlags: []
                    ),
                    sources: []
                ),
                PortfolioAttentionHolding(
                    ticker: "UBER",
                    name: "Uber Technologies, Inc.",
                    attention: .medium,
                    weight: 0.035,
                    portfolioContributionPercent: -0.26,
                    return60DPercent: 5.8,
                    volumeMultiple: 1.6,
                    distanceFrom52WHighPercent: -7.5,
                    distanceFrom52WLowPercent: 33.6,
                    ma200PositionPercent: 9.7,
                    signals: [
                        PortfolioAttentionSignal(kind: "daily_drop", label: L10n.text("-5.6% 单日回撤"), direction: "negative", value: -5.6),
                        PortfolioAttentionSignal(kind: "elevated_volume", label: L10n.text("成交量 1.6×"), direction: "negative", value: 1.6),
                    ],
                    fundamentals: nil,
                    thesis: PortfolioAttentionThesis(
                        stance: .maintaining,
                        confidence: .medium,
                        whatChanged: L10n.text("演示行情出现放量回撤，但中期累计表现仍为正。"),
                        whyItMatters: L10n.text("单日波动与成交量同时放大，值得确认这是短期获利回吐还是趋势转弱。"),
                        supportingEvidence: [L10n.text("60 日模拟收益仍为 +5.8%"), L10n.text("价格仍高于模拟 200 日均线")],
                        counterEvidence: [L10n.text("单日跌幅显著高于组合其他持仓")],
                        risks: [L10n.text("高波动成长股可能继续拖累短期收益")],
                        watchNext: [L10n.text("观察未来三个交易日能否收复跌幅"), L10n.text("关注成交量是否恢复正常")],
                        riskFlags: []
                    ),
                    sources: []
                ),
            ],
            warnings: [L10n.text("以上卡片为假数据模式的演示分析，不代表实时行情或投资建议。")]
        )
    }

    static func answer(to question: String) -> String {
        let normalized = question.lowercased()
        if normalized.contains("集中") || normalized.contains("风险") || normalized.contains("concentration") || normalized.contains("risk") {
            return """
            ## 演示组合风险摘要

            - **指数重叠：** VOO、VUAG 与 EQQQ 的大型科技敞口存在部分重叠。
            - **科技周期：** ORCL、AMD 与 ASML 合计形成较明显的成长风格暴露。
            - **汇率波动：** 演示账户同时包含 USD、GBP、EUR、HKD、JPY 与 SGD 资产。

            > 以上内容完全由独立假数据生成，不包含你的真实持仓。
            """
        }
        if normalized.contains("表现") || normalized.contains("收益") || normalized.contains("performance") || normalized.contains("return") {
            return """
            ## 近期表现（演示）

            ORCL 与 COST 是近期主要的模拟收益来源；UBER 和 ASML 的回撤形成部分抵消。组合仍保持正收益，但短期波动有所抬升。

            > 这是演示结论，不代表实时市场数据。
            """
        }
        return """
        ## 假数据模式

        当前回答基于 Trading 212、Moomoo 与 IBKR 三个独立演示账户。可以继续询问组合风险、集中度或近期表现；所有数字和结论均为合成内容。
        """
    }
}

private struct ChatBubble: View {
    @Environment(\.locale) private var appLocale
    let message: ChatMessage
    let attentionReport: PortfolioAttentionReport?

    @ViewBuilder
    var body: some View {
        if message.role == .assistant {
            messageContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .foregroundStyle(Color.primary)
        } else {
            HStack {
                Spacer(minLength: 54)
                messageContent
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .foregroundStyle(Color.black.opacity(0.88))
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if let attentionReport, message.role == .assistant {
            PortfolioAttentionReportView(report: attentionReport)
        } else if message.role == .assistant {
            MarkdownMessageText(markdown: message.text)
        } else {
            Text(message.text)
                .currencyFont(.body)
        }
    }

}

private struct PortfolioAttentionReportView: View {
    @Environment(\.locale) private var appLocale
    let report: PortfolioAttentionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("今天"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(L10n.text("\(report.holdingsCount) 只持仓中有 \(report.attentionRows.count) 只需要关注"))
                    .font(.headline)
            }

            if report.attentionRows.isEmpty {
                Text(L10n.text("无重大变化"))
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ForEach(report.attentionRows) { row in
                    PortfolioAttentionCard(row: row)
                }
            }

            HStack {
                Text(L10n.text("其他持仓")).fontWeight(.semibold)
                Spacer()
                Text(L10n.text("\(report.noMaterialChangeCount) 只 · 无重大变化"))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            ForEach(report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PortfolioAttentionCard: View {
    @Environment(\.locale) private var appLocale
    #if DEBUG
    static var researchPreviewReport: PortfolioAttentionReport { FakeAIContent.attentionReport }
    #endif
    let row: PortfolioAttentionHolding
    var prominent = false
    @Namespace private var zoom
    @State private var showsDetail = false

    var body: some View {
        Group {
            if prominent {
                Button { showsDetail = true } label: {
                    PortfolioAttentionCardContent(row: row, expanded: false, prominent: true)
                }
                .navigationDestination(isPresented: $showsDetail) {
                    PortfolioAttentionDetail(row: row)
                        .navigationTransition(.zoom(sourceID: row.id, in: zoom))
                }
            } else {
                NavigationLink {
                    PortfolioAttentionDetail(row: row)
                        .navigationTransition(.zoom(sourceID: row.id, in: zoom))
                } label: {
                    PortfolioAttentionCardContent(row: row, expanded: false)
                        .contentShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.text("放大查看持仓分析详情"))
        .matchedTransitionSource(id: row.id, in: zoom)
    }
}

private struct PortfolioAttentionDetail: View {
    @Environment(\.locale) private var appLocale
    let row: PortfolioAttentionHolding
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            PortfolioAttentionCardContent(row: row, expanded: true)
                .padding()
                .textSelection(.enabled)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .softTopScrollEdge()
        .navigationTitle(row.ticker)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .overlay(alignment: .trailing) {
            // Keep the additional left-swipe gesture at the right edge so the
            // article and signal chips retain their normal scrolling gestures.
            Color.clear.frame(width: 24)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
                .gesture(DragGesture(minimumDistance: 24).onEnded { value in
                    let delta = value.translation
                    if delta.width < -80 && abs(delta.width) > abs(delta.height) * 2 {
                        dismiss()
                    }
                })
        }
    }
}

private struct PortfolioAttentionCardContent: View {
    @Environment(\.locale) private var appLocale
    let row: PortfolioAttentionHolding
    let expanded: Bool
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 16 : 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.ticker).font(prominent ? .title2.bold() : .headline)
                    Text(row.name).font(prominent ? .subheadline : .caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(attentionText)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    .overlay(Capsule().strokeBorder(attentionBorder, lineWidth: 1))
            }

            Text("\(stanceText) · \(confidenceText)")
                .font(.caption.weight(.semibold))

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(row.signals) { signal in
                        Text(signal.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    }
                }
            }
            .scrollIndicators(.hidden)

            Text(row.thesis.whyItMatters)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if let risk = row.thesis.risks.first {
                Text(L10n.text("主要风险：\(risk)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    AttentionTextSection(title: L10n.text("发生了什么"), text: row.thesis.whatChanged)
                    AttentionTextSection(title: L10n.text("为什么值得关注"), text: row.thesis.whyItMatters)
                    AttentionListSection(title: L10n.text("支持证据"), values: row.thesis.supportingEvidence)
                    AttentionListSection(title: L10n.text("反方证据"), values: row.thesis.counterEvidence)
                    AttentionListSection(title: L10n.text("风险"), values: row.thesis.risks)
                    AttentionListSection(title: L10n.text("接下来关注"), values: row.thesis.watchNext)
                    if !row.thesis.riskFlags.isEmpty {
                        AttentionListSection(title: L10n.text("Risk Flags"), values: row.thesis.riskFlags.map(Self.riskFlagText))
                    }
                    if !row.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("来源")).font(.caption.weight(.semibold))
                            ForEach(row.sources) { source in
                                Link(destination: source.url) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(source.title).multilineTextAlignment(.leading)
                                        Text(source.publisher).font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } else {
                Label(L10n.text("查看详情"), systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(prominent ? 20 : 15)
        .background {
            if !prominent {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            }
        }
        .overlay {
            if !prominent {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.35), lineWidth: 1)
            }
        }
    }

    private var attentionText: String {
        row.attention == .high ? L10n.text("高关注") : L10n.text("中关注")
    }

    private var attentionBorder: Color {
        row.attention == .high ? Color.red.opacity(0.28) : CatfolioStyle.blue.opacity(0.38)
    }

    private var stanceText: String {
        switch row.thesis.stance {
        case .strengthening: L10n.text("投资逻辑增强")
        case .maintaining: L10n.text("投资逻辑维持")
        case .weakening: L10n.text("投资逻辑减弱")
        }
    }

    private var confidenceText: String {
        switch row.thesis.confidence {
        case .high: "High confidence"
        case .medium: "Medium confidence"
        case .none: "Low confidence"
        }
    }

    private static func riskFlagText(_ value: String) -> String {
        switch value {
        case "legal_regulatory": L10n.text("诉讼 / 监管")
        case "governance": L10n.text("治理 / 审计")
        case "dilution": L10n.text("潜在稀释")
        case "liquidity": L10n.text("流动性 / 现金流")
        case "leadership": L10n.text("管理层变动")
        default: value
        }
    }
}

private struct AttentionTextSection: View {
    @Environment(\.locale) private var appLocale
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).fontWeight(.semibold)
            Text(text).fontWeight(.regular).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AttentionListSection: View {
    @Environment(\.locale) private var appLocale
    let title: String
    let values: [String]

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                ForEach(values, id: \.self) { value in
                    Text("• \(value)")
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MarkdownMessageText: View {
    @Environment(\.locale) private var appLocale
    let markdown: String

    var body: some View {
        let blocks = MarkdownRenderCache.blocks(of: markdown)

        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(CatfolioStyle.blue)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            inlineText(text)
                .currencyFont(.body)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            inlineText(text)
                .currencyFont(headingStyle(for: level), weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.body.weight(.bold))
                        inlineText(item)
                            .currencyFont(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .appNumber(.subheading, weight: .semibold)
                            .foregroundStyle(.secondary)
                        inlineText(item)
                            .currencyFont(.body)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color.secondary.opacity(0.55))
                    .frame(width: 3)
                inlineText(text)
                    .currencyFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .code(language, code):
            VStack(alignment: .leading, spacing: 7) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case let .table(header, rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                            inlineText(cell)
                                .currencyFont(.caption1, weight: .semibold)
                                .frame(minWidth: 88, alignment: .leading)
                        }
                    }

                    Divider()

                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inlineText(cell)
                                    .currencyFont(.caption1)
                                    .frame(minWidth: 88, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .divider:
            Divider()
        }
    }

    private func inlineText(_ source: String) -> Text {
        Text(MarkdownRenderCache.inline(source))
    }

    private func headingStyle(for level: Int) -> UIFont.TextStyle {
        switch level {
        case 1: .title3
        case 2: .headline
        default: .subheadline
        }
    }
}

private enum MarkdownBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(language: String?, code: String)
    case table(header: [String], rows: [[String]])
    case divider
}

/// Parsed markdown, kept between renders.
///
/// Both halves of rendering a message used to run inside `body`: the block
/// split, and an `AttributedString(markdown:)` for every paragraph, heading
/// and list item. SwiftUI evaluates `body` whenever anything the view depends
/// on changes, so a conversation re-parsed every visible message on every
/// state change — including the one the scroll observer writes as the list
/// moves. The assistant's replies are long, `AttributedString(markdown:)` is
/// the expensive half, and the cost arrived as text that took seconds to
/// appear and buttons that answered late.
///
/// The text of a message never changes once it is on screen, so the parse is
/// pure and its result can simply be kept. Keyed by the source string: two
/// bubbles with the same text are the same parse.
private enum MarkdownRenderCache {
    private final class Blocks { let value: [MarkdownBlock]; init(_ v: [MarkdownBlock]) { value = v } }
    private final class Inline { let value: AttributedString; init(_ v: AttributedString) { value = v } }

    // Bounded, because a long conversation would otherwise hold every string
    // it ever rendered. NSCache also evicts under memory pressure on its own.
    private static let blockCache: NSCache<NSString, Blocks> = {
        let cache = NSCache<NSString, Blocks>()
        cache.countLimit = 400
        return cache
    }()

    private static let inlineCache: NSCache<NSString, Inline> = {
        let cache = NSCache<NSString, Inline>()
        cache.countLimit = 2000
        return cache
    }()

    static func blocks(of source: String) -> [MarkdownBlock] {
        let key = source as NSString
        if let hit = blockCache.object(forKey: key) { return hit.value }
        let parsed = MarkdownBlockParser.parse(source)
        blockCache.setObject(Blocks(parsed), forKey: key)
        return parsed
    }

    static func inline(_ source: String) -> AttributedString {
        let key = source as NSString
        if let hit = inlineCache.object(forKey: key) { return hit.value }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
        inlineCache.setObject(Inline(parsed), forKey: key)
        return parsed
    }
}

private enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let rawLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(
                    language: rawLanguage.isEmpty ? nil : rawLanguage,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let header = tableCells(from: line),
               isTableSeparator(lines[index + 1], expectedColumns: header.count) {
                flushParagraph()
                index += 2
                var rows: [[String]] = []
                while index < lines.count,
                      let row = tableCells(from: lines[index]),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(normalized(row, count: header.count))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            if let item = unorderedItem(from: trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = unorderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let item = orderedItem(from: trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = orderedItem(from: lines[index].trimmingCharacters(in: .whitespaces)) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    quoteLines.append(String(quoteLine.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks.isEmpty ? [.paragraph(source)] : blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let marks = line.prefix { $0 == "#" }
        guard (1...6).contains(marks.count),
              line.dropFirst(marks.count).first == " " else { return nil }
        return (
            marks.count,
            String(line.dropFirst(marks.count + 1)).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func unorderedItem(from line: String) -> String? {
        guard line.count > 2 else { return nil }
        let prefixes = ["- ", "* ", "+ "]
        guard let prefix = prefixes.first(where: line.hasPrefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func orderedItem(from line: String) -> String? {
        guard let dot = line.firstIndex(of: "."), dot != line.startIndex else { return nil }
        let number = line[..<dot]
        let afterDot = line.index(after: dot)
        guard number.allSatisfy(\.isNumber),
              afterDot < line.endIndex,
              line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first) else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private static func tableCells(from line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells = line
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells.count >= 2 ? cells : nil
    }

    private static func isTableSeparator(_ line: String, expectedColumns: Int) -> Bool {
        guard let cells = tableCells(from: line), cells.count == expectedColumns else { return false }
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            let hyphens = trimmed.filter { $0 == "-" }.count
            return hyphens >= 3 && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func normalized(_ row: [String], count: Int) -> [String] {
        if row.count == count { return row }
        if row.count > count { return Array(row.prefix(count)) }
        return row + Array(repeating: "", count: count - row.count)
    }
}

private struct AIComposer: View {
    @Environment(\.locale) private var appLocale
    @Binding var question: String
    let isSending: Bool
    let isFloating: Bool
    let focus: FocusState<Bool>.Binding
    let hasMessages: Bool
    let onClear: () -> Void
    let onQuickSend: (String) -> Void
    let onSend: () -> Void

    var body: some View {
        Group {
            if isFloating {
                floatingComposer
            } else {
                standardComposerSurface
            }
        }
    }

    @ViewBuilder
    private var standardComposerSurface: some View {
        if #available(iOS 26.0, *) {
            standardComposer
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            standardComposer
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var standardComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(L10n.text("询问你的投资组合"), text: $question, axis: .vertical)
                .lineLimit(1...4)
                .focused(focus)
                .padding(.leading, 14)
                .padding(.vertical, 11)
                .submitLabel(.send)
                .onSubmit(onSend)

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.white)
                    .background(CatfolioStyle.blue, in: Circle())
            }
            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            .padding(5)
            .accessibilityLabel(L10n.text("发送"))
        }
    }

    private var floatingComposer: some View {
        floatingComposerContent
    }

    private var floatingComposerContent: some View {
        HStack(alignment: .bottom, spacing: 8) {
            quickActionsMenu
                .fixedSize()
            floatingTextFieldSurface
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var quickActionsMenu: some View {
        Menu {
            Button(L10n.text("今天哪些持仓值得我关注？"), systemImage: "eye") {
                onQuickSend(L10n.text("今天哪些持仓值得我关注？"))
            }

            Divider()
            Button(L10n.text("组合风险摘要"), systemImage: "shield.lefthalf.filled") {
                question = L10n.text("请总结我当前组合最重要的三个风险。")
                focus.wrappedValue = true
            }
            Button(L10n.text("持仓集中度"), systemImage: "chart.pie") {
                question = L10n.text("请分析我的持仓集中度，并指出最需要关注的风险。")
                focus.wrappedValue = true
            }
            Button(L10n.text("近期表现"), systemImage: "chart.line.uptrend.xyaxis") {
                question = L10n.text("请解读我的组合近期表现，以及主要的收益和拖累来源。")
                focus.wrappedValue = true
            }

            if hasMessages {
                Divider()
                Button(L10n.text("清空对话"), systemImage: "trash", role: .destructive, action: onClear)
            }
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.regular))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                .floatingGlassSurface(in: Circle())
        }
        // The menu's symbols take the tint, which otherwise resolves to the
        // page's accent and prints them blue against a dark sheet.
        .tint(.white)
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("AI 快捷操作"))
    }

    private var floatingTextField: some View {
        HStack(spacing: 8) {
            TextField(
                L10n.text("Ask AI"),
                text: $question,
                prompt: Text(L10n.text("Ask AI")).foregroundStyle(.white.opacity(0.82)),
                axis: .vertical
            )
                .font(.body)
                .foregroundStyle(.white)
                .lineLimit(1...3)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit(onSend)

            if isSending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(canSend ? .black : .white.opacity(0.42))
                        .frame(width: 32, height: 32)
                        .background(
                            canSend ? Color.white : Color.white.opacity(0.10),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel(L10n.text("发送"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(minHeight: 48)
    }

    @ViewBuilder
    private var floatingTextFieldSurface: some View {
        floatingTextField
            .floatingGlassSurface(in: Capsule())
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }
}

/// The presentation host owns the zoom geometry and interactive dismissal.
struct AIAssistantPage: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AIView(isEmbedded: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.medium))
                        .frame(width: 48, height: 48)
                        .contentShape(Circle())
                        .floatingGlassSurface(in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(L10n.text("关闭 AI 投资助手"))
                .padding(14)
            }
            .background {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.25828),
                        .init(
                            color: Color(red: 9.0 / 255.0, green: 117.0 / 255.0, blue: 224.0 / 255.0),
                            location: 0.83985
                        ),
                        .init(
                            color: Color(red: 131.0 / 255.0, green: 193.0 / 255.0, blue: 1)
                                .opacity(0.20),
                            location: 1
                        ),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // Composited over black, not white. The last stop is 20%
                // opacity, so over white it resolved to rgb(230, 243, 255) —
                // a near-white band across the bottom of a page that forces
                // `.preferredColorScheme(.dark)` and so draws every label in
                // a light colour. The composer and the disclaimer sit in that
                // band and were close to invisible.
                .background(.black)
                .ignoresSafeArea()
            }
            .preferredColorScheme(.dark)
    }
}
private extension View {
    @ViewBuilder
    func floatingGlassSurface<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                glassEffect(.regular.tint(tint).interactive(), in: shape)
            } else {
                glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.white.opacity(0.22), lineWidth: 0.75)
                }
        }
    }
}
