import SwiftUI

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
struct StreamingAnswerView: View {
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
struct ReasoningDisclosure: View {
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
struct ShimmerText: View {
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
