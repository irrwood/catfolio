import SwiftUI

struct AIView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AIProviderPreference.storageKey) private var aiProviderRaw = AIProviderPreference.automatic.rawValue
    let isEmbedded: Bool
    let usesRootTabHeader: Bool
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
        usesRootTabHeader: Bool = false,
        loadsHistoryOnAppear: Bool = true,
        showsComposer: Bool = true,
        onClose: (() -> Void)? = nil
    ) {
        self.isEmbedded = isEmbedded
        self.usesRootTabHeader = usesRootTabHeader
        self.loadsHistoryOnAppear = loadsHistoryOnAppear
        self.showsComposer = showsComposer
        self.onClose = onClose
        _isRestoringHistory = State(initialValue: loadsHistoryOnAppear)
    }

    var body: some View {
        Group {
            if usesRootTabHeader {
                embeddedConversation
                    .navigationTitle(showsSidebar ? L10n.text("对话") : "")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarVisibility(.visible, for: .navigationBar)
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .modifier(AIConversationTopEdge())
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showsSidebar ? dismissSidebar() : showSidebar()
                            } label: {
                                Label {
                                    Text(L10n.text(showsSidebar ? "回到对话" : "对话列表"))
                                } icon: {
                                    if showsSidebar {
                                        Image(systemName: "chevron.down")
                                    } else {
                                        Image("AssistantMenu").renderingMode(.template)
                                    }
                                }
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("ai.conversations.toggle")
                            // Recreate the native bar button when its role
                            // changes; reusing it can detach its glyph after
                            // returning to this tab on iOS 27.
                            .id(showsSidebar)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                startNewConversation()
                                dismissSidebar()
                            } label: {
                                Label(L10n.text("新对话"), image: "AssistantCompose")
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("ai.conversations.new")
                            .disabled(isRestoringHistory)
                        }
                    }
            } else if isEmbedded {
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
                isFocused: isComposerFocused,
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
            .padding(.top, usesRootTabHeader ? 20 : (isEmbedded ? 64 : 16))
            .padding(.bottom, 16)
            .background {
                if usesRootTabHeader {
                    NavigationBarScrollAnchor().accessibilityHidden(true)
                }
            }
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
                    .overlay {
                        if !usesRootTabHeader {
                            AIConversationTopFade().opacity(showsSidebar ? 0 : 1)
                        }
                    }
                    .background {
                        if showsSidebar { card.fill(SettingsTemplate.card) }
                    }
                    .clipShape(AIConversationCardClip(
                        radius: showsSidebar ? Self.conversationCardRadius : 0,
                        topOverflow: showsSidebar ? 0 : geometry.safeAreaInsets.top + 80
                    ))
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
                .contentMargins(.top, usesRootTabHeader ? 0 : 72, for: .scrollContent)
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
        case .claude: L10n.text("正在使用 Claude 分析…")
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
                                cleanQuestion, context: researchRequest.context, webSearch: usesWebSearch,
                                newsQueries: researchRequest.newsQueries)
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
        dismissKeyboard()
        cancelPendingAnswer()
        foldActiveConversationIntoLibrary()
        resetConversationScrollPosition()
        let conversation = AIConversation()
        activeConversationID = conversation.id
        messages = []
        question = ""
        pendingQuestionPreset = nil
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
