import SwiftUI

struct AIView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AIProviderPreference.storageKey) private var aiProviderRaw = AIProviderPreference.automatic.rawValue
    let isEmbedded: Bool
    let loadsHistoryOnAppear: Bool
    let showsComposer: Bool
    @State private var messages: [ChatMessage] = []
    @State private var attentionReports: [UUID: PortfolioAttentionReport] = [:]
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
            } else {
                NavigationStack {
                    conversation
                        .navigationTitle("AI")
                        .toolbar {
                            if !messages.isEmpty {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("清空对话", systemImage: "trash") {
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
        .confirmationDialog("清空本机 AI 对话？", isPresented: $showsClearConfirmation) {
            Button("清空对话", role: .destructive, action: clearConversation)
        } message: {
            Text("此操作只会删除保存在这台 iPhone 上的聊天记录。")
        }
    }

    private var conversation: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(spacing: 12) {
                    if isRestoringHistory {
                        ProgressView("正在读取本机对话…")
                            .frame(minHeight: isEmbedded ? 300 : 420)
                    } else if messages.isEmpty && !isSending && errorMessage == nil {
                        ContentUnavailableView(
                            "AI 投资助手",
                            systemImage: "sparkles",
                            description: Text("询问组合风险、持仓集中度或近期表现。当前模型：\(selectedAIProvider.title)。")
                        )
                        .frame(minHeight: isEmbedded ? 300 : 420)
                    }

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
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .padding(16)
            .opacity(showsScrollToBottomButton ? 1 : 0)
            .scaleEffect(showsScrollToBottomButton ? 1 : 0.86)
            .allowsHitTesting(showsScrollToBottomButton)
            .accessibilityHidden(!showsScrollToBottomButton)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.2),
                value: showsScrollToBottomButton
            )
            .accessibilityLabel("回到最新对话")
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
        "\(loadsHistoryOnAppear)-\(model.isFakeDataMode)"
    }

    private var loadingMessage: String {
        switch selectedAIProvider {
        case .automatic: "正在选择模型并分析组合…"
        case .apple: "正在使用 Apple 本地模型分析…"
        case .codex: "正在使用 ChatGPT Codex 分析…"
        case .deepSeek: "正在使用 DeepSeek 分析…"
        }
    }

    private func restoreHistory() async {
        guard !didRestoreHistory else { return }
        didRestoreHistory = true
        defer { isRestoringHistory = false }

        if model.isFakeDataMode {
            let history = FakeAIContent.initialHistory()
            messages = history.messages
            attentionReports = history.attentionReports
            lastAttentionContext = FakeAIContent.attentionReport.contextSummary
            errorMessage = nil
            return
        }

        do {
            let history = try await LocalChatStore.shared.load()
            messages = history.messages
            attentionReports = history.attentionReports
            lastAttentionContext = history.messages.reversed().compactMap { message in
                history.attentionReports[message.id]?.contextSummary
            }.first
        } catch {
            errorMessage = "无法读取本机对话：\(error.localizedDescription)"
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

            if model.isFakeDataMode {
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

    private func persistMessages() async {
        guard !model.isFakeDataMode else { return }
        do {
            try await LocalChatStore.shared.save(messages, attentionReports: attentionReports)
        } catch {
            errorMessage = "无法保存本机对话：\(error.localizedDescription)"
        }
    }

    private func clearConversation() {
        if model.isFakeDataMode {
            messages = []
            attentionReports = [:]
            lastAttentionContext = nil
            errorMessage = nil
            return
        }

        Task {
            do {
                try await LocalChatStore.shared.clear()
                messages = []
                attentionReports = [:]
                lastAttentionContext = nil
                errorMessage = nil
            } catch {
                errorMessage = "无法清空本机对话：\(error.localizedDescription)"
            }
        }
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
                        PortfolioAttentionSignal(kind: "daily_move", label: "+4.8% 单日涨幅", direction: "positive", value: 4.8),
                        PortfolioAttentionSignal(kind: "volume", label: "成交量 1.9×", direction: "positive", value: 1.9),
                    ],
                    fundamentals: PortfolioFundamentalSnapshot(
                        source: "演示财务数据",
                        latestPeriod: "FY 2026 Q1",
                        revenueGrowthYoY: 8.7,
                        operatingIncomeGrowthYoY: 11.2,
                        freeCashFlowGrowthYoY: 6.4
                    ),
                    thesis: PortfolioAttentionThesis(
                        stance: .strengthening,
                        confidence: .high,
                        whatChanged: "演示行情显示股价放量上行，并接近模拟的 52 周高位。",
                        whyItMatters: "ORCL 是演示组合中权重较高的科技持仓，短期动量增强会明显影响组合表现。",
                        supportingEvidence: ["60 日模拟收益为 +12.6%", "价格位于模拟 200 日均线之上 18.4%"],
                        counterEvidence: ["接近阶段高位后，短线波动可能放大"],
                        risks: ["估值扩张速度快于演示盈利增速"],
                        watchNext: ["观察后续成交量能否维持", "关注回撤是否跌破短期趋势"],
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
                        PortfolioAttentionSignal(kind: "pullback", label: "距高点 -12.4%", direction: "negative", value: -12.4),
                        PortfolioAttentionSignal(kind: "trend", label: "仍高于 200 日线", direction: "positive", value: 3.1),
                    ],
                    fundamentals: nil,
                    thesis: PortfolioAttentionThesis(
                        stance: .maintaining,
                        confidence: .medium,
                        whatChanged: "演示价格自阶段高位回落，但长期趋势尚未破坏。",
                        whyItMatters: "这类高波动半导体设备持仓容易放大组合的科技周期风险。",
                        supportingEvidence: ["模拟价格仍在 200 日均线上方", "仓位权重控制在 5%以内"],
                        counterEvidence: ["60 日模拟收益仍为负值"],
                        risks: ["行业资本开支周期可能带来进一步波动"],
                        watchNext: ["观察 200 日均线支撑", "关注半导体板块相对强弱"],
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
                        PortfolioAttentionSignal(kind: "daily_drop", label: "-5.6% 单日回撤", direction: "negative", value: -5.6),
                        PortfolioAttentionSignal(kind: "elevated_volume", label: "成交量 1.6×", direction: "negative", value: 1.6),
                    ],
                    fundamentals: nil,
                    thesis: PortfolioAttentionThesis(
                        stance: .maintaining,
                        confidence: .medium,
                        whatChanged: "演示行情出现放量回撤，但中期累计表现仍为正。",
                        whyItMatters: "单日波动与成交量同时放大，值得确认这是短期获利回吐还是趋势转弱。",
                        supportingEvidence: ["60 日模拟收益仍为 +5.8%", "价格仍高于模拟 200 日均线"],
                        counterEvidence: ["单日跌幅显著高于组合其他持仓"],
                        risks: ["高波动成长股可能继续拖累短期收益"],
                        watchNext: ["观察未来三个交易日能否收复跌幅", "关注成交量是否恢复正常"],
                        riskFlags: []
                    ),
                    sources: []
                ),
            ],
            warnings: ["以上卡片为假数据模式的演示分析，不代表实时行情或投资建议。"]
        )
    }

    static func answer(to question: String) -> String {
        let normalized = question.lowercased()
        if normalized.contains("集中") || normalized.contains("风险") {
            return """
            ## 演示组合风险摘要

            - **指数重叠：** VOO、VUAG 与 EQQQ 的大型科技敞口存在部分重叠。
            - **科技周期：** ORCL、AMD 与 ASML 合计形成较明显的成长风格暴露。
            - **汇率波动：** 演示账户同时包含 USD、GBP、EUR、HKD、JPY 与 SGD 资产。

            > 以上内容完全由独立假数据生成，不包含你的真实持仓。
            """
        }
        if normalized.contains("表现") || normalized.contains("收益") {
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
                .font(.body)
        }
    }

}

private struct PortfolioAttentionReportView: View {
    let report: PortfolioAttentionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今天")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("\(report.holdingsCount) 只持仓中有 \(report.attentionRows.count) 只需要关注")
                    .font(.headline)
            }

            if report.attentionRows.isEmpty {
                Text("无重大变化")
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
                Text("其他持仓").fontWeight(.semibold)
                Spacer()
                Text("\(report.noMaterialChangeCount) 只 · 无重大变化")
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
        .accessibilityHint("放大查看持仓分析详情")
        .matchedTransitionSource(id: row.id, in: zoom)
    }
}

private struct PortfolioAttentionDetail: View {
    let row: PortfolioAttentionHolding
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            PortfolioAttentionCardContent(row: row, expanded: true)
                .padding()
                .textSelection(.enabled)
        }
        .background(Color(uiColor: .systemGroupedBackground))
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
                Text("主要风险：\(risk)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    AttentionTextSection(title: "发生了什么", text: row.thesis.whatChanged)
                    AttentionTextSection(title: "为什么值得关注", text: row.thesis.whyItMatters)
                    AttentionListSection(title: "支持证据", values: row.thesis.supportingEvidence)
                    AttentionListSection(title: "反方证据", values: row.thesis.counterEvidence)
                    AttentionListSection(title: "风险", values: row.thesis.risks)
                    AttentionListSection(title: "接下来关注", values: row.thesis.watchNext)
                    if !row.thesis.riskFlags.isEmpty {
                        AttentionListSection(title: "Risk Flags", values: row.thesis.riskFlags.map(Self.riskFlagText))
                    }
                    if !row.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("来源").font(.caption.weight(.semibold))
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
                Label("查看详情", systemImage: "arrow.up.left.and.arrow.down.right")
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
        row.attention == .high ? "高关注" : "中关注"
    }

    private var attentionBorder: Color {
        row.attention == .high ? Color.red.opacity(0.28) : CatfolioStyle.blue.opacity(0.38)
    }

    private var stanceText: String {
        switch row.thesis.stance {
        case .strengthening: "投资逻辑增强"
        case .maintaining: "投资逻辑维持"
        case .weakening: "投资逻辑减弱"
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
        case "legal_regulatory": "诉讼 / 监管"
        case "governance": "治理 / 审计"
        case "dilution": "潜在稀释"
        case "liquidity": "流动性 / 现金流"
        case "leadership": "管理层变动"
        default: value
        }
    }
}

private struct AttentionTextSection: View {
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
    let markdown: String

    var body: some View {
        let blocks = MarkdownBlockParser.parse(markdown)

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
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, text):
            inlineText(text)
                .font(headingFont(for: level))
                .fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(.body.weight(.bold))
                        inlineText(item)
                            .font(.body)
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
                            .font(.body)
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
                    .font(.callout)
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
                                .font(.caption.weight(.semibold))
                                .frame(minWidth: 88, alignment: .leading)
                        }
                    }

                    Divider()

                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                inlineText(cell)
                                    .font(.caption)
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
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let attributed = try? AttributedString(markdown: source, options: options) else {
            return Text(source)
        }
        return Text(attributed)
    }

    private func headingFont(for level: Int) -> Font {
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
            TextField("询问你的投资组合", text: $question, axis: .vertical)
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
            .accessibilityLabel("发送")
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
            Button("今天哪些持仓值得我关注？", systemImage: "eye") {
                onQuickSend("今天哪些持仓值得我关注？")
            }

            Divider()
            Button("组合风险摘要", systemImage: "shield.lefthalf.filled") {
                question = "请总结我当前组合最重要的三个风险。"
                focus.wrappedValue = true
            }
            Button("持仓集中度", systemImage: "chart.pie") {
                question = "请分析我的持仓集中度，并指出最需要关注的风险。"
                focus.wrappedValue = true
            }
            Button("近期表现", systemImage: "chart.line.uptrend.xyaxis") {
                question = "请解读我的组合近期表现，以及主要的收益和拖累来源。"
                focus.wrappedValue = true
            }

            if hasMessages {
                Divider()
                Button("清空对话", systemImage: "trash", role: .destructive, action: onClear)
            }
        } label: {
            Image(systemName: "plus")
                .font(.title3.weight(.regular))
                .frame(width: 48, height: 48)
                .contentShape(Circle())
                .floatingGlassSurface(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("AI 快捷操作")
    }

    private var floatingTextField: some View {
        HStack(spacing: 8) {
            TextField(
                "Ask AI",
                text: $question,
                prompt: Text("Ask AI").foregroundStyle(.white.opacity(0.82)),
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
                .accessibilityLabel("发送")
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
                .accessibilityLabel("关闭 AI 投资助手")
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
                .background(.white)
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
