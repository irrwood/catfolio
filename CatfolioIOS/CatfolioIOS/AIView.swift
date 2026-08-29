import SwiftUI

struct AIView: View {
    @EnvironmentObject private var model: AppModel
    @State private var messages: [ChatMessage] = []
    @State private var question = ""
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if messages.isEmpty && !isSending {
                            ContentUnavailableView("AI 投资助手", systemImage: "sparkles", description: Text("询问组合风险、持仓集中度或近期表现。"))
                                .frame(minHeight: 420)
                        }

                        ForEach(messages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }

                        if isSending {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在分析组合…")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(14)
                            .id("loading")
                        }

                        if let errorMessage {
                            StatusNotice(text: errorMessage)
                        }
                    }
                    .padding(16)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
            .navigationTitle("AI")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                AIComposer(question: $question, isSending: isSending) {
                    sendQuestion()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .task {
                guard messages.isEmpty else { return }
                isSending = true
                defer { isSending = false }
                do {
                    let briefing = try await model.loadBriefing()
                    messages.append(ChatMessage(role: .assistant, text: briefing))
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func sendQuestion() {
        let cleanQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuestion.isEmpty, !isSending else { return }
        question = ""
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: cleanQuestion))
        isSending = true

        Task {
            defer { isSending = false }
            do {
                let answer = try await model.askAI(cleanQuestion)
                messages.append(ChatMessage(role: .assistant, text: answer))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 54) }
            Text(message.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .background(background, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
            if message.role == .assistant { Spacer(minLength: 36) }
        }
        .frame(maxWidth: .infinity)
    }

    private var background: some ShapeStyle {
        message.role == .user ? AnyShapeStyle(CatfolioStyle.blue) : AnyShapeStyle(Color(uiColor: .secondarySystemGroupedBackground))
    }
}

private struct AIComposer: View {
    @Binding var question: String
    let isSending: Bool
    let onSend: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                composer
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                composer
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("询问你的投资组合", text: $question, axis: .vertical)
                .lineLimit(1...4)
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
}
