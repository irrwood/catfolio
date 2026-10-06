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
    @State private var importedSecurityDebateKeys: Set<String> = []
    @State private var debateStore = SecurityDebateStore.shared
    @State private var activeConversationID: UUID?
    @State private var showsSidebar = false
    /// How far the peeking conversation card is being dragged, negative up.
    @State private var conversationCardDrag: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var lastAttentionContext: String?
    @State private var question = ""
    @AppStorage("ai.web-search.enabled") private var webSearchEnabled = false
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
    /// Messages built at a time; earlier ones wait behind a button. Replies
    /// run long, so a page is a screen or two, not the whole history.
    private static let messagePage = 10
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
                embeddedConversation
                    .overlay(alignment: .top) {
                        AIConversationHeader(
                            showsConversations: showsSidebar,
                            onToggleConversations: { showsSidebar ? dismissSidebar() : showSidebar() },
                            onNewConversation: {
                                startNewConversation()
                                dismissSidebar()
                            },
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
        .task(id: appLocale.identifier) { await debateStore.restore() }
        .onChange(of: debateStore.recent.map(\.conversationKey)) { _, _ in
            importSecurityDebateConversations()
        }
        .confirmationDialog(L10n.text("清空本机 AI 对话？"), isPresented: $showsClearConfirmation) {
            Button(L10n.text("清空对话"), role: .destructive, action: clearConversation)
        } message: {
            Text(L10n.text("此操作只会删除保存在这台 iPhone 上的聊天记录。"))
        }
        .appSheet(item: $pendingQuestionPreset) { preset in
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
                webSearchEnabled: $webSearchEnabled,
                isSending: isSending || isRestoringHistory,
                isFloating: isEmbedded,
                focus: $isComposerFocused,
                hasMessages: !messages.isEmpty,
                onClear: { showsClearConfirmation = true },
                onQuickSend: { preset in
                    sendQuestion(preset)
                },
                onSelectPreset: selectQuestionPreset,
                onStop: isSending ? stopAnswer : nil
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
                            attentionReport: attentionReports[message.id],
                            securityDebate: message.id == conversations.first(where: { $0.id == activeConversationID })?.securityDebateMessageID
                                ? conversations.first(where: { $0.id == activeConversationID })?.securityDebate : nil
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

    /// How much of the open conversation stays on screen, as a card, while
    /// the list is up.
    private static let conversationPeekHeight: CGFloat = 120
    private static let conversationCardRadius: CGFloat = 40

    /// The conversation list sits behind the open conversation. Showing it
    /// drops the conversation to a card peeking up from the bottom; tapping
    /// or swiping the card up brings the conversation back.
    private var embeddedConversation: some View {
        GeometryReader { geometry in
            let card = UnevenRoundedRectangle(
                topLeadingRadius: showsSidebar ? Self.conversationCardRadius : 0,
                topTrailingRadius: showsSidebar ? Self.conversationCardRadius : 0,
                style: .continuous
            )
            ZStack(alignment: .top) {
                if showsSidebar {
                    conversationList
                        .transition(.opacity)
                }
                conversation
                    .overlay { AIConversationTopFade().opacity(showsSidebar ? 0 : 1) }
                    .background {
                        if showsSidebar { card.fill(SettingsTemplate.card) }
                    }
                    .clipShape(card)
                    // Outside the clip: the card casts upwards onto the list,
                    // so it reads as the conversation lifted off it.
                    .background {
                        if showsSidebar {
                            card.fill(SettingsTemplate.card)
                                .shadow(color: .black.opacity(colorScheme == .dark ? 0.7 : 0.22), radius: 28, y: -10)
                        }
                    }
                    .allowsHitTesting(!showsSidebar)
                    .overlay(alignment: .top) {
                        if showsSidebar { conversationCardHandle }
                    }
                    .offset(y: showsSidebar
                        ? max(0, geometry.size.height - Self.conversationPeekHeight + conversationCardDrag)
                        : 0)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: showsSidebar)
        .sensoryFeedback(.impact(weight: .medium), trigger: showsSidebar) { _, _ in hapticsEnabled }
    }

    /// The whole peeking card is the control; the chevron above says which
    /// way it goes.
    private var conversationCardHandle: some View {
        VStack(spacing: 6) {
            Image(systemName: "chevron.compact.up")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
                .offset(y: -30)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: Self.conversationPeekHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: dismissSidebar)
        // The card follows the finger up, with some give downwards; a
        // short or slow drag springs back.
        // This handle moves with the card. Measuring in its own coordinate
        // space feeds that movement back into the next drag translation.
        .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                let y = value.translation.height
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    conversationCardDrag = y < 0 ? y : y * 0.25
                }
            }
            .onEnded { value in
                let opens = value.translation.height < -80 || value.predictedEndTranslation.height < -240
                if opens {
                    dismissSidebar()
                } else {
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.25)) {
                        conversationCardDrag = 0
                    }
                }
            })
        .accessibilityElement()
        .accessibilityLabel(L10n.text("回到对话"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, dismissSidebar)
    }

    private var conversationList: some View {
        Group {
            if sidebarConversations.isEmpty && debateStore.runningTickers.isEmpty {
                Text(L10n.text("还没有对话"))
                    .appText(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(debateStore.runningTickers, id: \.self) { ticker in
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(ticker) · \(L10n.text("个股关键变化"))").appText(.body)
                                Text(L10n.text("\(ticker) 正在分析…")).appText(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(20)
                        .listRowSeparator(.hidden)
                    }
                    ForEach(sidebarConversations) { conversation in
                        Button {
                            openConversation(conversation.id)
                            dismissSidebar()
                        } label: {
                            sidebarRow(conversation)
                        }
                        .buttonStyle(.plain)
                        // The open conversation — the card peeking below — is
                        // outlined; a fill a shade lighter was lost on the
                        // dark card.
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(SettingsTemplate.card)
                                .overlay {
                                    if conversation.id == activeConversationID {
                                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                                            .strokeBorder(CatfolioTheme.primaryText, lineWidth: 2)
                                    }
                                }
                                .padding(.vertical, 5)
                                .padding(.horizontal, 20)
                        )
                        .accessibilityAddTraits(conversation.id == activeConversationID ? .isSelected : [])
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
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
                .contentMargins(.top, 72, for: .scrollContent)
                .contentMargins(.bottom, Self.conversationPeekHeight + 24, for: .scrollContent)
            }
        }
    }

    private func sidebarRow(_ conversation: AIConversation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(conversation.title ?? L10n.text("新对话"))
                .appText(.body)
                .lineLimit(1)
            Group {
                if conversation.id == activeConversationID {
                    Text(L10n.text("当前对话")).fontWeight(.semibold).foregroundStyle(CatfolioTheme.primaryText)
                        + Text(" · " + Self.relativeDate.localizedString(for: conversation.updatedAt, relativeTo: .now))
                } else {
                    Text(Self.relativeDate.localizedString(for: conversation.updatedAt, relativeTo: .now))
                }
            }
            .appText(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
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
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.35)) {
            showsSidebar = false
            conversationCardDrag = 0
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
            importSecurityDebateConversations()
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
            importedSecurityDebateKeys = []
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
            importedSecurityDebateKeys = []
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
            importedSecurityDebateKeys = library.importedSecurityDebateKeys
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
        let usesWebSearch = webSearchEnabled
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
                if Self.isAttentionPreset(cleanQuestion) && !usesWebSearch {
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
                                cleanQuestion, context: researchRequest.context, webSearch: usesWebSearch)
                        } else {
                            events = try await model.streamAI(cleanQuestion, attentionContext: context, webSearch: usesWebSearch)
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

    private func stopAnswer() {
        let partial = streamingAnswer?.stoppedMessage()
        cancelPendingAnswer()
        if let partial { messages.append(partial) }
        Task { await persistMessages() }
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
            updatedAt: .now,
            securityDebate: existing?.securityDebate,
            securityDebateMessageID: existing?.securityDebateMessageID
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
            let library = LocalChatLibrary(conversations: conversations, activeID: activeConversationID,
                importedSecurityDebateKeys: importedSecurityDebateKeys)
            LocalChatLibraryCache.library = library
            try await LocalChatStore.shared.save(library)
        } catch {
            errorMessage = L10n.text("无法保存本机对话：\(error.localizedDescription)")
        }
    }

    private func importSecurityDebateConversations() {
        guard !isRestoringHistory else { return }
        foldActiveConversationIntoLibrary()
        var library = LocalChatLibrary(conversations: conversations, activeID: activeConversationID,
            importedSecurityDebateKeys: importedSecurityDebateKeys)
        guard library.importSecurityDebates(debateStore.recent) else { return }
        conversations = library.conversations
        importedSecurityDebateKeys = library.importedSecurityDebateKeys
        Task { await persistLibrary() }
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
            let library = LocalChatLibrary(conversations: conversations, activeID: activeConversationID,
                importedSecurityDebateKeys: importedSecurityDebateKeys)
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

private struct ChatBubble: View {
    @Environment(\.locale) private var appLocale
    let message: ChatMessage
    let attentionReport: PortfolioAttentionReport?
    var securityDebate: SecurityDebate? = nil

    @ViewBuilder
    var body: some View {
        if message.role == .assistant {
            messageContent
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .foregroundStyle(CatfolioTheme.primaryText)
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
        if let securityDebate, message.role == .assistant {
            SecurityDebateSection(debate: securityDebate)
        } else if let attentionReport, message.role == .assistant {
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

private struct AIComposer: View {
    @Environment(\.locale) private var appLocale
    @Binding var question: String
    @Binding var webSearchEnabled: Bool
    let isSending: Bool
    let isFloating: Bool
    let focus: FocusState<Bool>.Binding
    let hasMessages: Bool
    let onClear: () -> Void
    let onQuickSend: (String) -> Void
    let onSelectPreset: (AIQuestionPreset) -> Void
    let onStop: (() -> Void)?
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
                .overlay(alignment: .bottomTrailing) { composerActionButton.padding(6) }
        } else {
            standardComposer
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(alignment: .bottomTrailing) { composerActionButton.padding(6) }
        }
    }

    private var standardComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            quickActionsMenu
            webSearchButton
            TextField(L10n.text("询问你的投资组合"), text: $question, axis: .vertical)
                .lineLimit(1...4)
                .focused(focus)
                .padding(.leading, 14)
                .padding(.vertical, 11)
                .submitLabel(.send)
                .onSubmit(onSend)
                // Room for the send button, drawn over the surface.
                .padding(.trailing, 6 + 32 + 6)
        }
    }

    private var floatingComposer: some View {
        floatingComposerContent
    }

    private var floatingComposerContent: some View {
        HStack(alignment: .bottom, spacing: 8) {
            quickActionsMenu
                .fixedSize()
            webSearchButton
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

    private var webSearchButton: some View {
        Button { webSearchEnabled.toggle() } label: {
            Image(systemName: "globe")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(webSearchEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 44, height: 48)
                .background(webSearchEnabled ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityLabel(L10n.text("联网搜索"))
        .accessibilityValue(webSearchEnabled ? L10n.text("已开启") : L10n.text("已关闭"))
        .accessibilityAddTraits(webSearchEnabled ? [.isSelected] : [])
        .accessibilityIdentifier("ai.web-search")
    }

    private var floatingTextField: some View {
        HStack(spacing: 8) {
            TextField(
                L10n.text("Ask AI"),
                text: $question,
                prompt: Text(L10n.text("Ask AI")).foregroundStyle(Color.primary.opacity(0.62)),
                axis: .vertical
            )
                // The app's own face, not the system body font the field
                // otherwise takes.
                .appText(.subheading)
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(1...3)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit(onSend)
        }
        // Clear of the capsule's curve on the left; on the right, room for
        // the send button, which sits 8pt in all round over the glass.
        .padding(.leading, 18)
        .padding(.trailing, 8 + 32 + 8)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
    }

    /// Glass that is only a surface. Interactive glass claims the touch for
    /// its press effect, and the text field inside it took about six seconds
    /// to become focused — the delay was the glass, not the keyboard.
    @ViewBuilder
    private var floatingTextFieldSurface: some View {
        floatingTextField
            .floatingGlassSurface(in: Capsule(), isInteractive: false)
            // Over the glass, not in it: glass blends what it holds, and the
            // black circle came out a washed-out grey that read as disabled.
            .overlay(alignment: .bottomTrailing) {
                composerActionButton.padding(8)
            }
    }

    private var canSend: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    private enum ComposerAction { case empty, send, stop, busy }

    private var composerAction: ComposerAction {
        if onStop != nil { return .stop }
        if isSending { return .busy }
        return canSend ? .send : .empty
    }

    /// One circle in every state: black by day, white at night, with its
    /// glyph in the page colour; only an empty field leaves it faint.
    private var composerActionButton: some View {
        let action = composerAction
        let isFilled = action != .empty
        return Button {
            switch action {
            case .send: onSend()
            case .stop: onStop?()
            case .empty, .busy: break
            }
        } label: {
            ZStack {
                Circle().fill(isFilled ? Color.primary : Color.primary.opacity(0.10))
                if action == .busy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color(uiColor: .systemBackground))
                } else {
                    Image(systemName: action == .stop ? "stop.fill" : "arrow.up")
                        .font(.system(size: action == .stop ? 12 : 15, weight: .bold))
                        .foregroundStyle(isFilled ? Color(uiColor: .systemBackground) : Color.primary.opacity(0.42))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(action == .empty || action == .busy)
        .animation(.easeOut(duration: 0.15), value: isFilled)
        .accessibilityLabel(L10n.text(action == .stop ? "停止生成" : "发送"))
    }
}

/// The presentation host owns the zoom geometry and interactive dismissal.
struct AIAssistantPage: View {
    @Environment(\.locale) private var appLocale

    /// A root tab: nothing to close back to, so no close control.
    var body: some View {
        AIView(isEmbedded: true, onClose: nil)
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
        scheme == .dark ? .black : .white
    }
}

/// A stationary blue light below the conversation, on the dark page only;
/// the light page is plain white. Keep the base opaque and size the glow to
/// the screen, including the area behind the keyboard.
private struct AIConversationGlowBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 1.0 : 0
        GeometryReader { geometry in
            // Wider than the screen, centred on its bottom edge: half the
            // light is below the glass, and what shows is a broad rise.
            let diameter = min(geometry.size.width * 1.8, 820)

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
                    y: geometry.size.height
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
    let showsConversations: Bool
    let onToggleConversations: () -> Void
    let onNewConversation: () -> Void
    let onClose: (() -> Void)?

    private var diameter: CGFloat { isKeyboardVisible ? 56 : 48 }

    var body: some View {
        HStack {
            control(showsConversations ? "chevron.down" : "line.3.horizontal", action: onToggleConversations)
                .accessibilityLabel(L10n.text(showsConversations ? "回到对话" : "对话列表"))
            Spacer(minLength: 0)
            if showsConversations {
                control("square.and.pencil", action: onNewConversation)
                    .accessibilityLabel(L10n.text("新对话"))
            } else if let onClose {
                control("xmark", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(L10n.text("关闭 AI 投资助手"))
            }
        }
        .overlay {
            if showsConversations {
                Text(L10n.text("对话"))
                    .appText(.body, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
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
                .foregroundStyle(CatfolioTheme.primaryText)
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

extension View {
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
final class StreamingAnswer {
    let startedAt = Date()
    private(set) var reasoning = ""
    private(set) var text = ""
    private(set) var searchStatus = ""
    private(set) var answerStartedAt: Date?
    /// Characters of `text` revealed so far.
    private(set) var shown = 0
    private(set) var isComplete = false
    private(set) var isCancelled = false
    @ObservationIgnored private var revealTask: Task<Void, Never>?

    /// Still thinking: nothing of the answer has arrived.
    var isThinking: Bool { answerStartedAt == nil }
    var visibleText: String { String(text.prefix(shown)) }
    var isRevealing: Bool { !isComplete || shown < text.count }
    var thinkingSeconds: Double { (answerStartedAt ?? Date()).timeIntervalSince(startedAt) }

    func receive(_ event: AIStreamEvent) {
        guard !isCancelled else { return }
        switch event {
        case let .searchStatus(status):
            searchStatus = status
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
        guard !isCancelled else { return }
        isComplete = true
        startRevealing()
        await revealTask?.value
    }

    func cancel() {
        isCancelled = true
        isComplete = true
        shown = text.count
        revealTask?.cancel()
        revealTask = nil
    }

    func stoppedMessage() -> ChatMessage? {
        cancel()
        guard !text.isEmpty || !reasoning.isEmpty else { return nil }
        return ChatMessage(role: .assistant, text: text,
                           reasoning: reasoning.isEmpty ? nil : reasoning,
                           thinkingSeconds: thinkingSeconds)
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
            if !answer.searchStatus.isEmpty {
                Label(answer.searchStatus, systemImage: "globe")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
        .foregroundStyle(CatfolioTheme.primaryText)
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
