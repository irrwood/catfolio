import SwiftUI

struct AIView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AIProviderPreference.storageKey) private var aiProviderRaw = AIProviderPreference.automatic.rawValue
    let isEmbedded: Bool
    let loadsHistoryOnAppear: Bool
    let showsComposer: Bool
    let onClose: (() -> Void)?
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
    /// The answer being written, while it is.
    @State private var streamingAnswer: StreamingAnswer?
    @State private var sendStartedAt: Date?
    @State private var answerTask: Task<Void, Never>?
    @State private var answerGeneration = UUID()
    @State private var isRestoringHistory = true
    @State private var didRestoreHistory = false
    @State private var errorMessage: String?
    @State private var showsClearConfirmation = false
    @State private var pendingQuestionPreset: AIQuestionPreset?
    @State private var isNearConversationBottom = true
    /// Where the conversation sits. An edge, not a message id: setting the
    /// bottom id again when it was already the target changed nothing, so a
    /// new reply or error was often left under the composer; and a lazy
    /// list's unmeasured rows put id-based positions off by their estimates.
    @State private var conversationPosition = ScrollPosition(edge: .bottom)
    @FocusState private var isComposerFocused: Bool

    private static let conversationBottomID = "ai-conversation-bottom"
    /// Messages built at a time; earlier ones wait behind a button.
    private static let messagePage = 40
    @State private var visibleMessageLimit = AIView.messagePage

    private var hiddenMessageCount: Int { max(0, messages.count - visibleMessageLimit) }

    init(
        isEmbedded: Bool = false,
        loadsHistoryOnAppear: Bool = true,
        showsComposer: Bool = true,
        onClose: (() -> Void)? = nil
    ) {
        self.isEmbedded = isEmbedded
        self.loadsHistoryOnAppear = loadsHistoryOnAppear
        self.showsComposer = showsComposer
        self.onClose = onClose
        _isRestoringHistory = State(initialValue: loadsHistoryOnAppear)
    }

    var body: some View {
        Group {
            if isEmbedded {
                conversation
                    .overlay { AIConversationTopFade() }
                    .overlay { sidebarDrawer }
                    .overlay(alignment: .top) {
                        AIConversationHeader(
                            showsConversationButton: !showsSidebar,
                            onShowConversations: showSidebar,
                            onClose: onClose
                        )
                    }
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
        .sheet(item: $pendingQuestionPreset) { preset in
            AIQuestionSecurityPicker(preset: preset) { security in
                pendingQuestionPreset = nil
                guard let request = preset.request(security: security) else { return }
                sendQuestion(request.prompt, researchRequest: request)
            }
        }
    }

    private var conversation: some View {
        ZStack(alignment: .bottomTrailing) {
            if isRestoringHistory {
                // Usually a single frame now that the library is in memory;
                // a spinner there only flickered.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(L10n.text("正在读取本机对话…"))
            } else {
                conversationScrollView
                    .id(activeConversationID)
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
                isSending: isSending || isRestoringHistory,
                isFloating: isEmbedded,
                focus: $isComposerFocused,
                hasMessages: !messages.isEmpty,
                onClear: { showsClearConfirmation = true },
                onQuickSend: { preset in
                    sendQuestion(preset)
                },
                onSelectPreset: selectQuestionPreset
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

    /// Mount with the restored messages already present.
    ///
    /// A plain stack, not a lazy one. Anchored to the bottom, a lazy stack
    /// placed its rows by estimated heights and often drew nothing until a
    /// drag made it measure them — the conversation "appeared" on the first
    /// scroll. Every row here is measured, so the bottom is exact at once; to
    /// keep a long history cheap, only the latest messages are built until
    /// the reader asks for earlier ones.
    private var conversationScrollView: some View {
        ScrollView {
            VStack(spacing: 12) {
                // The page margin goes on each row, not on the stack. The
                // scroll position is kept by row, and a row that began 16pt
                // in was brought to the viewport's leading edge when the
                // position was restored — which scrolled the whole
                // conversation 16pt sideways, flush left with a double margin
                // on the right, until the next drag. Full-width rows leave
                // it nothing to line up. A Group hands the padding to each.
                Group {
                    if messages.isEmpty && !isSending && errorMessage == nil {
                        AIQuestionPresets(onSelect: selectQuestionPreset)
                            .onAppear {
                                conversationPosition = ScrollPosition(edge: .top)
                            }
                    }

                    // Debates started from a security sheet finish in
                    // SecurityDebateStore, not in this conversation, so they
                    // are listed rather than folded into the message history —
                    // which also leaves the chat document's schema alone.
                    SecurityDebateInbox()

                    if hiddenMessageCount > 0 {
                        Button {
                            visibleMessageLimit += Self.messagePage
                        } label: {
                            Text(L10n.text("显示更早的 \(hiddenMessageCount) 条消息"))
                                .appText(.footnote, weight: .medium)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(messages.suffix(visibleMessageLimit)) { message in
                        ChatBubble(
                            message: message,
                            attentionReport: attentionReports[message.id]
                        )
                            .id(message.id.uuidString)
                    }

                    pendingAnswer

                    if let errorMessage {
                        StatusNotice(text: errorMessage)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(Self.conversationBottomID)
                }
                .padding(.horizontal, 16)
            }
            .scrollTargetLayout()
            .padding(.top, isEmbedded ? 64 : 16)
            .padding(.bottom, 16)
        }
        .background(isEmbedded ? Color.clear : Color(uiColor: .systemGroupedBackground))
        // Let messages pass beneath the fixed status-area fade.
        .scrollClipDisabled(isEmbedded)
        .defaultScrollAnchor(messages.isEmpty ? .top : .bottom)
        .scrollPosition($conversationPosition)
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
        // A failure is the last thing in the conversation; show it whole
        // rather than half under the composer.
        .onChange(of: errorMessage) { _, message in
            guard message != nil, isNearConversationBottom else { return }
            scrollToConversationBottom()
        }
        // The keyboard shrinks the view from below; a reader at the end
        // stays at the end.
        .onChange(of: isComposerFocused) { _, isFocused in
            guard isFocused, isNearConversationBottom else { return }
            scrollToConversationBottom()
        }
        // An answer being written grows the page; a reader at the end
        // follows it, one who scrolled up to read is left where they are.
        .onChange(of: streamingProgress) { _, _ in
            guard isNearConversationBottom else { return }
            scrollToConversationBottom()
        }
    }

    private func showSidebar() {
        isComposerFocused = false
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
            showsSidebar = true
        }
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

    /// The answer while it is awaited or being written.
    @ViewBuilder
    private var pendingAnswer: some View {
        if let streamingAnswer {
            VStack(alignment: .leading, spacing: 6) {
                StreamingAnswerView(answer: streamingAnswer)
                if streamingAnswer.isThinking, streamingAnswer.reasoning.isEmpty {
                    Text(loadingMessage)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        } else if isSending {
            VStack(alignment: .leading, spacing: 6) {
                ReasoningDisclosure(reasoning: "", seconds: nil, thinkingSince: sendStartedAt ?? Date())
                Text(loadingMessage)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Grows as an answer is written; the page follows it.
    private var streamingProgress: Int {
        guard let streamingAnswer else { return 0 }
        return streamingAnswer.shown + streamingAnswer.reasoning.count
    }

    private func scrollToConversationBottom() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            conversationPosition.scrollTo(edge: .bottom)
        }
    }

    private func resetConversationScrollPosition() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            // Discard any offset or user-scroll state from another conversation.
            conversationPosition = ScrollPosition(edge: .bottom)
            visibleMessageLimit = Self.messagePage
            isNearConversationBottom = true
        }
    }

    private var showsScrollToBottomButton: Bool {
        !isRestoringHistory && !isNearConversationBottom && !messages.isEmpty
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
        case .openRouter: L10n.text("正在使用 OpenRouter 分析…")
        }
    }

    private func restoreHistory() async {
        guard !didRestoreHistory else { return }
        didRestoreHistory = true
        defer {
            resetConversationScrollPosition()
            isRestoringHistory = false
        }

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
            let library: LocalChatLibrary
            if let cached = LocalChatLibraryCache.library {
                library = cached
            } else {
                library = try await LocalChatStore.shared.loadLibrary()
                LocalChatLibraryCache.library = library
            }
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

    private func selectQuestionPreset(_ preset: AIQuestionPreset) {
        guard !isSending, !isRestoringHistory else { return }
        dismissKeyboard()
        if preset.requiresSecurity {
            pendingQuestionPreset = preset
        } else if let request = preset.request() {
            sendQuestion(request.prompt, researchRequest: request)
        }
    }

    private func sendQuestion(_ preset: String? = nil, researchRequest: AIResearchQuestion? = nil) {
        let cleanQuestion = (preset ?? question).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty, !isSending, !isRestoringHistory else { return }
        // Quick questions do not consume the user's unsent draft.
        if preset == nil { question = "" }
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: cleanQuestion))
        isSending = true
        sendStartedAt = Date()

        let origin = activeConversationID
        let context = lastAttentionContext
        let generation = UUID()
        answerGeneration = generation
        answerTask = Task { @MainActor in
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && answerGeneration == generation && activeConversationID == origin
            }
            defer {
                if answerGeneration == generation {
                    isSending = false
                    answerTask = nil
                    streamingAnswer = nil
                }
            }

            if researchRequest == nil && model.isFakeDataMode && !model.isPublicInvestorMode {
                if !Self.isAttentionPreset(cleanQuestion) {
                    // The sample portfolio streams too, so the page shows what
                    // a real answer looks like without a model connected.
                    let live = StreamingAnswer()
                    streamingAnswer = live
                    try? await Task.sleep(for: .milliseconds(700))
                    for piece in FakeAIContent.pieces(of: FakeAIContent.reasoning(for: cleanQuestion)) {
                        guard isCurrent() else { live.cancel(); return }
                        live.receive(.reasoning(piece))
                        try? await Task.sleep(for: .milliseconds(28))
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                    for piece in FakeAIContent.pieces(of: FakeAIContent.answer(to: cleanQuestion)) {
                        guard isCurrent() else { live.cancel(); return }
                        live.receive(.text(piece))
                        try? await Task.sleep(for: .milliseconds(24))
                    }
                    await live.finish()
                    guard isCurrent() else { return }
                    messages.append(ChatMessage(role: .assistant, text: live.text, reasoning: live.reasoning,
                                                thinkingSeconds: live.thinkingSeconds))
                    return
                }
                try? await Task.sleep(for: .milliseconds(320))
                guard isCurrent() else { return }
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
            guard isCurrent() else { return }
            do {
                if Self.isAttentionPreset(cleanQuestion) {
                    let report = try await model.portfolioAttention()
                    guard isCurrent() else { return }
                    let message = ChatMessage(role: .assistant, text: report.markdownFallback)
                    messages.append(message)
                    attentionReports[message.id] = report
                    lastAttentionContext = report.contextSummary
                } else {
                    let live = StreamingAnswer()
                    streamingAnswer = live
                    do {
                        let events: AsyncThrowingStream<AIStreamEvent, Error>
                        if let researchRequest {
                            events = LocalAIClient().streamPublicResearch(
                                cleanQuestion, context: researchRequest.context)
                        } else {
                            events = try await model.streamAI(cleanQuestion, attentionContext: context)
                        }
                        for try await event in events {
                            guard isCurrent() else { live.cancel(); return }
                            live.receive(event)
                        }
                    } catch {
                        // Whatever arrived before the failure is kept, and the
                        // failure is said below it.
                        guard isCurrent() else { live.cancel(); return }
                        await live.finish()
                        if !live.text.isEmpty {
                            messages.append(ChatMessage(role: .assistant, text: live.text,
                                reasoning: live.reasoning.isEmpty ? nil : live.reasoning,
                                thinkingSeconds: live.thinkingSeconds))
                            await persistMessages()
                        }
                        throw error
                    }
                    await live.finish()
                    guard isCurrent() else { return }
                    messages.append(ChatMessage(role: .assistant, text: live.text,
                        reasoning: live.reasoning.isEmpty ? nil : live.reasoning,
                        thinkingSeconds: live.thinkingSeconds))
                }
                await persistMessages()
            } catch {
                guard isCurrent() else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelPendingAnswer() {
        answerGeneration = UUID()
        answerTask?.cancel()
        answerTask = nil
        streamingAnswer?.cancel()
        streamingAnswer = nil
        isSending = false
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
            let library = LocalChatLibrary(conversations: conversations, activeID: activeConversationID)
            LocalChatLibraryCache.library = library
            try await LocalChatStore.shared.save(library)
        } catch {
            errorMessage = L10n.text("无法保存本机对话：\(error.localizedDescription)")
        }
    }

    /// Opens an empty conversation. The current one is kept.
    private func startNewConversation() {
        cancelPendingAnswer()
        foldActiveConversationIntoLibrary()
        resetConversationScrollPosition()
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
        cancelPendingAnswer()
        foldActiveConversationIntoLibrary()
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        resetConversationScrollPosition()
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
            cancelPendingAnswer()
            resetConversationScrollPosition()
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
            let library = LocalChatLibrary(conversations: conversations, activeID: activeConversationID)
            LocalChatLibraryCache.library = library
            try await LocalChatStore.shared.save(library)
        } catch {
            errorMessage = L10n.text("无法保存本机对话：\(error.localizedDescription)")
        }
    }

    private func clearConversation() {
        cancelPendingAnswer()
        resetConversationScrollPosition()
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

    /// What the sample model "thinks" before it answers.
    static func reasoning(for question: String) -> String {
        L10n.text("先看问题问的是什么，再对照组合里权重最高的几只持仓。示例组合集中在科技和半导体，前五大持仓占了一半以上，所以回答要先说集中度，再说近期表现。")
            + "\n\n" + L10n.text("数字都来自 Catfolio 的组合摘要，这里只负责解释，不重新计算，最后提醒这不是投资建议。")
    }

    /// Text cut into the uneven pieces a model streams in.
    static func pieces(of text: String) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        var size = 2
        while !rest.isEmpty {
            let piece = rest.prefix(size)
            pieces.append(String(piece))
            rest = rest.dropFirst(piece.count)
            size = size % 5 + 2
        }
        return pieces
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
                    // Inverted from the page: white on the dark page, near-black
                    // on the light one.
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .foregroundStyle(Color(uiColor: .systemBackground))
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        if let attentionReport, message.role == .assistant {
            PortfolioAttentionReportView(report: attentionReport)
        } else if message.role == .assistant {
            VStack(alignment: .leading, spacing: 12) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningDisclosure(reasoning: reasoning, seconds: message.thinkingSeconds, thinkingSince: nil)
                }
                MarkdownMessageText(markdown: message.text)
            }
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text("今天"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(L10n.text("\(report.holdingsCount) 只持仓中有 \(report.attentionRows.count) 只需要关注"))
                    .font(.headline)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)

            if report.attentionRows.isEmpty {
                Text(L10n.text("无重大变化"))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .attentionGlassCard()
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
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .attentionGlassCard()

            ForEach(report.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
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
                    PortfolioAttentionCardContent(row: row, prominent: true)
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
                    PortfolioAttentionCardContent(row: row)
                        .contentShape(RoundedRectangle(cornerRadius: PortfolioAttentionCardContent.cornerRadius, style: .continuous))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.text("放大查看持仓分析详情"))
        .matchedTransitionSource(id: row.id, in: zoom)
    }
}

/// A holding's analysis, set to be read rather than scanned: one column on
/// the plain page, no card. The argument leads; what changed, the evidence
/// either way, the risks and what to watch follow under quiet labels, and
/// the sources close it.
private struct PortfolioAttentionDetail: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    let row: PortfolioAttentionHolding

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: 1)
                    .padding(.vertical, 28)

                Text(row.thesis.whyItMatters)
                    .appText(.heading, weight: .medium)
                    .lineSpacing(8)
                    .fixedSize(horizontal: false, vertical: true)

                if !row.thesis.whatChanged.isEmpty {
                    ReaderSection(L10n.text("发生了什么")) {
                        ReaderParagraph(row.thesis.whatChanged)
                    }
                }
                ReaderList(title: L10n.text("支持证据"), values: row.thesis.supportingEvidence)
                ReaderList(title: L10n.text("反方证据"), values: row.thesis.counterEvidence)
                ReaderList(title: L10n.text("风险"), values: row.thesis.risks)
                ReaderList(title: L10n.text("接下来关注"), values: row.thesis.watchNext)
                ReaderList(title: L10n.text("Risk Flags"), values: row.thesis.riskFlags.map(PortfolioAttentionHolding.riskFlagText))

                if !row.sources.isEmpty {
                    ReaderSection(L10n.text("来源")) {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(row.sources) { source in
                                Link(destination: source.url) { sourceRow(source) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .textSelection(.enabled)
            // A reading measure: on a wide screen the column stops growing.
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .softTopScrollEdge()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .overlay(alignment: .trailing) {
            // Keep the additional left-swipe gesture at the right edge so the
            // article keeps its normal scrolling gestures.
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(row.attentionTint).frame(width: 6, height: 6)
                Text(row.attentionText)
            }
            .appText(.label, weight: .semibold)
            .foregroundStyle(row.attentionTint)

            Text(row.ticker)
                .appText(.display, weight: .semibold)
                .padding(.top, 12)
            Text(row.name)
                .appText(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            // The judgement on one line, the figures behind it on the next.
            VStack(alignment: .leading, spacing: 4) {
                Text("\(row.stanceText) · \(row.confidenceText)")
                if !row.signals.isEmpty {
                    Text(row.signals.map(\.label).joined(separator: " · "))
                }
            }
            .appText(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceRow(_ source: PortfolioAttentionSource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(source.title)
                    .appText(.callout, weight: .medium)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text([source.publisher, source.publishedAt.map { $0.formatted(.dateTime.year().month().day().locale(appLocale)) }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .appText(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// A labelled part of the reader: a small grey label, then its text.
private struct ReaderSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .appText(.label, weight: .semibold)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 36)
    }
}

/// Reading text: the body size with open leading, a shade off full white.
private struct ReaderParagraph: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .appText(.subheading)
            .lineSpacing(7)
            .foregroundStyle(.primary.opacity(0.88))
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A section of points, each on a hanging indent so wrapped lines align.
private struct ReaderList: View {
    let title: String
    let values: [String]

    var body: some View {
        if !values.isEmpty {
            ReaderSection(title) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(values, id: \.self) { value in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(verbatim: "•")
                                .appText(.subheading)
                                .foregroundStyle(.tertiary)
                            ReaderParagraph(value)
                        }
                    }
                }
            }
        }
    }
}

/// The words for an attention row's level, stance and confidence, shared by
/// its card and its reader.
private extension PortfolioAttentionHolding {
    var attentionText: String {
        attention == .high ? L10n.text("高关注") : L10n.text("中关注")
    }

    var attentionTint: Color {
        attention == .high ? Color.red : CatfolioStyle.blue
    }

    var stanceText: String {
        switch thesis.stance {
        case .strengthening: L10n.text("投资逻辑增强")
        case .maintaining: L10n.text("投资逻辑维持")
        case .weakening: L10n.text("投资逻辑减弱")
        }
    }

    var confidenceText: String {
        switch thesis.confidence {
        case .high: "High confidence"
        case .medium: "Medium confidence"
        case .none: "Low confidence"
        }
    }

    static func riskFlagText(_ value: String) -> String {
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

private struct PortfolioAttentionCardContent: View {
    static let cornerRadius: CGFloat = 24

    @Environment(\.locale) private var appLocale
    let row: PortfolioAttentionHolding
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 16 : 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.ticker).font(prominent ? .title2.bold() : .headline)
                    Text(row.name).font(prominent ? .subheadline : .caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    Text(row.attentionText)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                        .overlay(Capsule().strokeBorder(attentionBorder, lineWidth: 1))
                    // The card opens; the chevron is all that says so.
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }

            Text("\(row.stanceText) · \(row.confidenceText)")
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
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(20)
        .modifier(AttentionCardSurface(isVisible: !prominent))
    }

    private var attentionBorder: Color {
        row.attention == .high ? Color.red.opacity(0.28) : CatfolioStyle.blue.opacity(0.38)
    }
}

/// The attention report's cards are Liquid Glass, like the composer below
/// them — not an opaque black slab with a hairline. Research sets the card
/// on its own page with no surface at all.
private struct AttentionCardSurface: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        if isVisible {
            content.attentionGlassCard()
        } else {
            content
        }
    }
}

private extension View {
    /// Glass that only shows: never interactive, which would take the touches
    /// meant for the card's link and its chips.
    func attentionGlassCard() -> some View {
        floatingGlassSurface(
            in: RoundedRectangle(cornerRadius: PortfolioAttentionCardContent.cornerRadius, style: .continuous),
            isInteractive: false
        )
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
    let onSelectPreset: (AIQuestionPreset) -> Void
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
            // Not interactive: interactive glass takes the touch for its own
            // press effect, and the text field inside waited seconds for it.
            standardComposer
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        } else {
            standardComposer
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private var standardComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            quickActionsMenu
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
            Section(L10n.text("个股分析")) {
                ForEach(AIQuestionPreset.allCases.filter(\.requiresSecurity)) { preset in
                    Button(preset.title, systemImage: preset.symbol) { onSelectPreset(preset) }
                }
            }
            Section(L10n.text("市场分析")) {
                Button(AIQuestionPreset.market.title, systemImage: AIQuestionPreset.market.symbol) {
                    onSelectPreset(.market)
                }
            }
            Section(L10n.text("我的组合")) {
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
        .tint(.primary)
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityLabel(L10n.text("AI 快捷操作"))
    }

    private var floatingTextField: some View {
        HStack(spacing: 8) {
            TextField(
                L10n.text("Ask AI"),
                text: $question,
                prompt: Text(L10n.text("Ask AI")).foregroundStyle(Color.primary.opacity(0.62)),
                axis: .vertical
            )
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(1...3)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit(onSend)

            if isSending {
                ProgressView()
                    .controlSize(.small)
                    .tint(.primary)
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(canSend ? Color(uiColor: .systemBackground) : Color.primary.opacity(0.42))
                        .frame(width: 32, height: 32)
                        .background(
                            canSend ? Color.primary : Color.primary.opacity(0.10),
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

    /// Glass that is only a surface. Interactive glass claims the touch for
    /// its press effect, and the text field inside it took about six seconds
    /// to become focused — the delay was the glass, not the keyboard.
    @ViewBuilder
    private var floatingTextFieldSurface: some View {
        floatingTextField
            .floatingGlassSurface(in: Capsule(), isInteractive: false)
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
        AIView(isEmbedded: true, onClose: { dismiss() })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                AIConversationGlowBackground()
                    .ignoresSafeArea()
            }
    }
}

/// The assistant's ground: opaque, so nothing of the page behind the zoom
/// shows through, in the reader's appearance.
private enum AIConversationGround {
    static func base(for scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : Color(red: 0.955, green: 0.962, blue: 0.975)
    }
}

/// A stationary blue light below the conversation. Keep the base opaque and
/// size the glow to the screen, including the area behind the keyboard. On
/// the light page the same light, weaker: a wash rather than a lamp.
private struct AIConversationGlowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 1.0 : 0.34
        GeometryReader { geometry in
            let diameter = min(geometry.size.width * 1.25, 560)

            Circle()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: Color(red: 0.08, green: 0.56, blue: 1).opacity(0.90 * strength), location: 0),
                            .init(color: Color(red: 0.035, green: 0.38, blue: 0.92).opacity(0.70 * strength), location: 0.3),
                            .init(color: Color(red: 0.02, green: 0.20, blue: 0.65).opacity(0.30 * strength), location: 0.6),
                            .init(color: .clear, location: 1),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: diameter / 2
                    )
                )
                .frame(width: diameter, height: diameter)
                .blur(radius: diameter * 0.08)
                .position(
                    x: geometry.size.width / 2,
                    y: geometry.size.height - diameter * 0.3
                )
        }
        .background(AIConversationGround.base(for: colorScheme))
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Both controls share keyboard state and fixed centres, so changing their
/// glass diameter never shifts either button or the conversation underneath.
private struct AIConversationHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isKeyboardVisible = false
    let showsConversationButton: Bool
    let onShowConversations: () -> Void
    let onClose: (() -> Void)?

    private var diameter: CGFloat { isKeyboardVisible ? 56 : 48 }

    var body: some View {
        HStack {
            control("line.3.horizontal", action: onShowConversations)
                .accessibilityLabel(L10n.text("对话列表"))
                .opacity(showsConversationButton ? 1 : 0)
                .allowsHitTesting(showsConversationButton)
                .accessibilityHidden(!showsConversationButton)
            Spacer(minLength: 0)
            if let onClose {
                control("xmark", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L10n.text("关闭 AI 投资助手"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: isKeyboardVisible)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .onDisappear { isKeyboardVisible = false }
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.primary)
                .scaleEffect(isKeyboardVisible ? 1.1 : 1)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .modifier(AIHeaderGlass())
        }
        .buttonStyle(.plain)
        .frame(width: 56, height: 56)
    }
}

private struct AIHeaderGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.clear.interactive(), in: Circle())
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75)
                }
        }
    }
}

/// The Figma fade occupies the status area (62 pt on its reference device).
/// Anchor it to the physical top, independently of the keyboard's bottom inset.
private struct AIConversationTopFade: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if !reduceTransparency {
                    AIStatusBackdropBlur()
                }
                LinearGradient(
                    colors: [AIConversationGround.base(for: colorScheme), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: max(62, geometry.safeAreaInsets.top))
            .offset(y: -geometry.safeAreaInsets.top)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AIStatusBackdropBlur: UIViewRepresentable {
    func makeUIView(context: Context) -> BlurView { BlurView() }
    func updateUIView(_ view: BlurView, context: Context) {}

    final class BlurView: UIVisualEffectView {
        private let fadeMask = UIView()
        private let gradient = CAGradientLayer()
        private var maskBounds = CGRect.null

        init() {
            super.init(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            isUserInteractionEnabled = false
            gradient.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
            gradient.locations = [0, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            fadeMask.layer.addSublayer(gradient)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds != maskBounds else { return }
            maskBounds = bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fadeMask.frame = bounds
            gradient.frame = fadeMask.bounds
            // Mask the effect view itself; masking an ancestor breaks UIKit's
            // sampling of the messages scrolling behind this layer.
            mask = fadeMask
            CATransaction.commit()
        }
    }
}

private extension View {
    @ViewBuilder
    func floatingGlassSurface<S: Shape>(in shape: S, tint: Color? = nil, isInteractive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                glassEffect(.regular.tint(tint).interactive(isInteractive), in: shape)
            } else {
                glassEffect(.regular.interactive(isInteractive), in: shape)
            }
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.primary.opacity(0.16), lineWidth: 0.75)
                }
        }
    }
}

// MARK: - Streaming answer

/// The answer being written: the model's thinking, the text received, and
/// how much of that text is on screen. Text is revealed at `SmoothReveal`'s
/// pace rather than as it lands, so a burst of tokens reads as typing.
@MainActor @Observable
private final class StreamingAnswer {
    let startedAt = Date()
    private(set) var reasoning = ""
    private(set) var text = ""
    private(set) var answerStartedAt: Date?
    /// Characters of `text` revealed so far.
    private(set) var shown = 0
    private(set) var isComplete = false
    @ObservationIgnored private var revealTask: Task<Void, Never>?

    /// Still thinking: nothing of the answer has arrived.
    var isThinking: Bool { answerStartedAt == nil }
    var visibleText: String { String(text.prefix(shown)) }
    var isRevealing: Bool { !isComplete || shown < text.count }
    var thinkingSeconds: Double { (answerStartedAt ?? Date()).timeIntervalSince(startedAt) }

    func receive(_ event: AIStreamEvent) {
        switch event {
        case let .reasoning(delta):
            reasoning += delta
        case let .text(delta):
            if answerStartedAt == nil { answerStartedAt = Date() }
            text += delta
            startRevealing()
        }
    }

    /// Marks the stream finished and waits for the typewriter to catch up.
    func finish() async {
        isComplete = true
        startRevealing()
        await revealTask?.value
    }

    func cancel() {
        revealTask?.cancel()
        revealTask = nil
    }

    private func startRevealing() {
        guard revealTask == nil else { return }
        revealTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let total = self.text.count
                if self.shown < total {
                    self.shown += SmoothReveal.step(backlog: total - self.shown)
                } else if self.isComplete {
                    return
                }
                try? await Task.sleep(for: SmoothReveal.frame)
            }
        }
    }
}

/// The answer as it is written: the thinking above, the text below it
/// appearing with a caret at its end.
private struct StreamingAnswerView: View {
    let answer: StreamingAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if answer.isThinking || !answer.reasoning.isEmpty {
                ReasoningDisclosure(
                    reasoning: answer.reasoning,
                    seconds: answer.isThinking ? nil : answer.thinkingSeconds,
                    thinkingSince: answer.isThinking ? answer.startedAt : nil
                )
            }
            if !answer.visibleText.isEmpty {
                MarkdownMessageText(
                    markdown: StreamingMarkdown.displayable(answer.visibleText) + (answer.isRevealing ? " ▍" : "")
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color.primary)
        .accessibilityElement(children: .combine)
    }
}

/// The model's thinking, collapsible. While it is thinking the header
/// shimmers and counts the seconds, and the thinking shows as it arrives;
/// once the answer starts it folds away to "Thought for N seconds", a tap
/// from being read again — the pattern of the AI Elements reasoning block.
private struct ReasoningDisclosure: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reasoning: String
    /// How long it thought, once it has finished.
    let seconds: Double?
    /// When the thinking began, while it has not finished.
    let thinkingSince: Date?
    @State private var isExpanded: Bool

    init(reasoning: String, seconds: Double?, thinkingSince: Date?) {
        self.reasoning = reasoning
        self.seconds = seconds
        self.thinkingSince = thinkingSince
        _isExpanded = State(initialValue: thinkingSince != nil)
    }

    private var isThinking: Bool { thinkingSince != nil }
    private var hasReasoning: Bool { !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .symbolEffect(.pulse, options: .repeating, isActive: isThinking && !reduceMotion)
                    if let thinkingSince {
                        ShimmerText(text: L10n.text("思考中"))
                        TimelineView(.periodic(from: thinkingSince, by: 1)) { context in
                            Text(L10n.text("\(max(0, Int(context.date.timeIntervalSince(thinkingSince)))) 秒"))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.tertiary)
                    } else {
                        Text(L10n.text("已思考 \(max(1, Int((seconds ?? 0).rounded()))) 秒"))
                    }
                    if hasReasoning {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasReasoning)
            .accessibilityLabel(isThinking ? L10n.text("思考中") : L10n.text("思考过程"))
            .accessibilityValue(isExpanded ? L10n.text("已展开") : L10n.text("已收起"))

            if isExpanded, hasReasoning {
                Text(reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 2)
                    }
                    .textSelection(.enabled)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The thinking folds away as the answer begins — at once, not with a
        // fade: fading, it lay under the answer's first lines as they arrived.
        .onChange(of: isThinking) { _, thinking in
            guard !thinking else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { isExpanded = false }
        }
    }
}

/// A label with light passing across it: the working state's shimmer.
private struct ShimmerText: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    @State private var phase: CGFloat = -1

    var body: some View {
        Text(text)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.85), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.7)
                        .offset(x: phase * geometry.size.width * 1.5)
                    }
                    .mask(Text(text))
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}
