import SwiftUI

struct ChatBubble: View {
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

struct AIComposer: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The same choice as Settings › 默认模型: picked here, it is the default.
    @AppStorage(AIProviderPreference.storageKey) private var aiProviderRaw = AIProviderPreference.automatic.rawValue
    @Namespace private var composerSpace
    @Binding var question: String
    @Binding var webSearchEnabled: Bool
    let isSending: Bool
    let isFloating: Bool
    let focus: FocusState<Bool>.Binding
    /// Passed as a value: read through the binding, a change of focus did
    /// not reliably redraw the composer.
    let isFocused: Bool
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

    /// Small until it is wanted. At rest it is one pill — the quick actions,
    /// the prompt, the send button. Focused, or holding a draft, it opens
    /// into a card: the text on top with room to write, and under it a row of
    /// the quick actions, the model, web search and send.
    ///
    /// The text field is the same view in both, so opening and closing never
    /// takes the keyboard away; only what is around it comes and goes.
    private var isExpanded: Bool {
        isFocused || !question.isEmpty
    }

    private var floatingComposer: some View {
        let expanded = isExpanded
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 0) {
                if !expanded {
                    quickActionsMenu
                        .matchedGeometryEffect(id: "quick-actions", in: composerSpace)
                }
                floatingTextField(expanded: expanded)
                if !expanded {
                    composerActionButton
                        .padding(8)
                        .matchedGeometryEffect(id: "action", in: composerSpace)
                }
            }
            if expanded {
                HStack(spacing: 8) {
                    quickActionsMenu
                        .matchedGeometryEffect(id: "quick-actions", in: composerSpace)
                    modelMenu
                    Spacer(minLength: 4)
                    webSearchButton
                    composerActionButton
                        .matchedGeometryEffect(id: "action", in: composerSpace)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        // Glass that is only a surface, and behind the controls rather than
        // around them. Interactive glass claims the touch for its press
        // effect, and the text field inside it took about six seconds to
        // become focused; and glass blends what it holds, which turned the
        // black send circle a washed-out grey that read as disabled.
        .background {
            Color.clear
                .floatingGlassSurface(in: RoundedRectangle(cornerRadius: expanded ? 28 : 24, style: .continuous),
                                      isInteractive: false)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86), value: expanded)
    }

    private func floatingTextField(expanded: Bool) -> some View {
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
            // One line at rest; open, two lines' room to start and up to six.
            .lineLimit(expanded ? 2...6 : 1...1)
            .focused(focus)
            .submitLabel(.send)
            .onSubmit(onSend)
            .padding(.leading, expanded ? 18 : 2)
            .padding(.trailing, expanded ? 18 : 0)
            .padding(.top, expanded ? 16 : 8)
            .padding(.bottom, expanded ? 10 : 8)
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedProvider: AIProviderPreference {
        AIProviderPreference(rawValue: aiProviderRaw) ?? .automatic
    }

    /// The model, after its provider, where there is a choice inside it.
    private var providerDetail: String? {
        guard selectedProvider == .openRouter else { return nil }
        let model = LocalServiceKeys.openRouterModelID.split(separator: "/").last.map(String.init)
        return model?.isEmpty == false ? model : nil
    }

    private var modelMenu: some View {
        Menu {
            Picker(selection: $aiProviderRaw) {
                ForEach(AIProviderPreference.allCases) { provider in
                    Text(L10n.label(provider.title)).tag(provider.rawValue)
                }
            } label: {
                Text(L10n.text("模型"))
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Text(L10n.label(selectedProvider.title))
                    .foregroundStyle(CatfolioTheme.primaryText)
                if let providerDetail {
                    Text(providerDetail)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .appText(.label, weight: .medium)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .tint(.primary)
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityLabel(L10n.text("模型"))
        .accessibilityValue(L10n.label(selectedProvider.title))
        .accessibilityIdentifier("ai.model")
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
                .foregroundStyle(CatfolioTheme.primaryText)
                .frame(width: isFloating && isExpanded ? 40 : 48, height: isFloating && isExpanded ? 40 : 48)
                .background {
                    // Inside the floating composer's glass: a quiet disc when
                    // open, nothing at rest. The standard composer keeps its own.
                    if isFloating {
                        Circle().fill(Color.primary.opacity(isExpanded ? 0.06 : 0))
                    }
                }
                .contentShape(Circle())
                .modifier(StandaloneGlassCircle(isOn: !isFloating))
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
                .frame(width: isFloating ? 40 : 44, height: isFloating ? 40 : 48)
                .background(webSearchEnabled ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: isFloating ? AnyShape(Circle()) : AnyShape(Capsule()))
        }
        .buttonStyle(.plain)
        .disabled(isSending)
        .accessibilityLabel(L10n.text("联网搜索"))
        .accessibilityValue(webSearchEnabled ? L10n.text("已开启") : L10n.text("已关闭"))
        .accessibilityAddTraits(webSearchEnabled ? [.isSelected] : [])
        .accessibilityIdentifier("ai.web-search")
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
            // Larger in the open card, where it ends the row of controls.
            .frame(width: isFloating && isExpanded ? 40 : 32, height: isFloating && isExpanded ? 40 : 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(action == .empty || action == .busy)
        .animation(.easeOut(duration: 0.15), value: isFilled)
        .accessibilityLabel(L10n.text(action == .stop ? "停止生成" : "发送"))
    }
}

/// The quick-actions circle's own glass, for the standard composer, where it
/// sits outside the field.
private struct StandaloneGlassCircle: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.floatingGlassSurface(in: Circle())
        } else {
            content
        }
    }
}
