import SwiftUI

/// The questions a security is contested on, each argued both ways.
///
/// Collapsed by default apart from the first: the point of the list is to show
/// how many open questions there are and let the reader pick one, not to bury
/// that under the first answer.
///
/// The bull side is drawn in `gain` and the bear side in `loss`, which in this
/// app means green for up and red for down. The reference this was modelled on
/// used the opposite convention; matching it here would have made one screen
/// disagree with every other figure in the app about which colour means which
/// direction.
struct SecurityDebateSection: View {
    @Environment(\.colorScheme) private var colorScheme
    let debate: SecurityDebate
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text("关键问题"))
                    .appText(.heading, weight: .semibold)
                Spacer(minLength: 8)
                Text(debate.usedModelWebSearch
                     ? L10n.text("\(debate.sources.count) 个来源 · 含联网搜索")
                     : L10n.text("\(debate.sources.count) 个来源"))
                    .appText(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(Array(debate.questions.enumerated()), id: \.element.id) { index, question in
                    if index > 0 { Divider() }
                    questionRow(question, isFirst: index == 0)
                }
            }
            .background(CatfolioTheme.subtleFill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text(L10n.text("每个问题的两侧都按最强论点陈述，不构成建议。"))
                .appText(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func isExpanded(_ question: SecurityDebateQuestion, isFirst: Bool) -> Bool {
        expanded.contains(question.id) || (isFirst && expanded.isEmpty)
    }

    @ViewBuilder
    private func questionRow(_ question: SecurityDebateQuestion, isFirst: Bool) -> some View {
        let open = isExpanded(question, isFirst: isFirst)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    if open {
                        expanded.remove(question.id)
                        // The first row is open by default when the set is
                        // empty, so closing it has to be recorded as something
                        // other than "nothing chosen yet".
                        if isFirst, expanded.isEmpty { expanded.insert("__none__") }
                    } else {
                        expanded.remove("__none__")
                        expanded.insert(question.id)
                    }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(question.question)
                        .appText(.body, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.text(open ? "收起" : "展开"))

            if open {
                VStack(spacing: 0) {
                    side(question.bull, title: L10n.text("看涨观点"),
                         symbol: "arrow.up.right", color: CatfolioTheme.gain(for: colorScheme))
                    side(question.bear, title: L10n.text("看跌观点"),
                         symbol: "arrow.down.right", color: CatfolioTheme.loss(for: colorScheme))
                }
            }
        }
    }

    @ViewBuilder
    private func side(
        _ side: SecurityDebateSide, title: String, symbol: String, color: Color
    ) -> some View {
        let sources = debate.sources(for: side)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Text(title).appText(.caption, weight: .semibold)
                Image(systemName: symbol).font(.caption2.weight(.bold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.14))
            .clipShape(Capsule())

            Text(side.claim)
                .appText(.footnote)
                .fixedSize(horizontal: false, vertical: true)

            if sources.isEmpty {
                // Said plainly rather than left blank: a claim with nothing
                // behind it is a different thing from one the reader can check.
                Text(L10n.text("这一侧在已收集的来源中没有直接支持"))
                    .appText(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SecurityDebateSourceChip(sources: sources)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(color.opacity(0.06))
    }
}

/// The source count, expanding into the list it counts.
private struct SecurityDebateSourceChip: View {
    let sources: [PortfolioAttentionSource]
    @State private var showsList = false

    var body: some View {
        Button { showsList.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.caption2)
                Text(L10n.text("\(sources.count) 个来源")).appText(.caption)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .rotationEffect(.degrees(showsList ? 180 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(CatfolioTheme.neutralFill)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)

        if showsList {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sources) { source in
                    Link(destination: source.url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                                .appText(.caption, weight: .medium)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            HStack(spacing: 5) {
                                Text(source.publisher)
                                if let date = source.publishedAt {
                                    Text("·")
                                    Text(date.formatted(.dateTime.year().month(.abbreviated).day()))
                                }
                                if source.tier == "filing" || source.tier == "primary" {
                                    Text("·")
                                    Text(L10n.text("一手"))
                                }
                            }
                            .appText(.micro)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

/// The button that starts it, and everything the wait looks like.
struct SecurityDebateCard: View {
    let ticker: String
    let name: String
    @State private var store = SecurityDebateStore.shared

    var body: some View {
        let progress = store.progress(for: ticker)
        VStack(alignment: .leading, spacing: 14) {
            switch progress {
            case .idle:
                start
            case .collecting, .reasoning:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(progress == .collecting
                         ? L10n.text("正在收集新闻与申报文件…")
                         : L10n.text("正在整理正反方观点…"))
                        .appText(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Text(L10n.text("可以离开这个页面，完成后在 AI 标签里也能看到。"))
                    .appText(.caption)
                    .foregroundStyle(.secondary)
            case let .ready(debate):
                SecurityDebateSection(debate: debate)
                HStack(spacing: 10) {
                    Text(L10n.text("生成于 \(debate.generatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"))
                        .appText(.micro)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(L10n.text("重新生成")) {
                        store.start(ticker: ticker, name: name, force: true)
                    }
                    .appText(.caption, weight: .semibold)
                }
            case let .failed(message):
                StatusNotice(text: message, kind: .info)
                Button(L10n.text("重试")) { store.start(ticker: ticker, name: name, force: true) }
                    .appText(.caption, weight: .semibold)
            }
        }
        .task { await store.restore() }
    }

    private var start: some View {
        Button {
            store.start(ticker: ticker, name: name)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("AI 正反方分析")).appText(.body, weight: .semibold)
                    Text(L10n.text("收集新闻、申报与分析师目标价，整理出多空双方的论点"))
                        .appText(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CatfolioTheme.subtleFill)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .tint(CatfolioTheme.accent)
    }
}

/// Debates waiting in the AI tab.
///
/// A person taps the button on a security, leaves, and comes back here. The
/// store is the same one the security sheet writes to, so anything still
/// running shows its progress and anything finished is readable in place.
struct SecurityDebateInbox: View {
    @State private var store = SecurityDebateStore.shared
    @State private var opened: String?

    var body: some View {
        let running = store.progress.filter { $0.value.isWorking }.keys.sorted()
        let finished = store.recent
        if !running.isEmpty || !finished.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text("个股正反方分析"))
                    .appCaps(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)

                ForEach(running, id: \.self) { ticker in
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("\(ticker) 正在分析…")).appText(.footnote)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(CatfolioTheme.subtleFill)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                ForEach(finished, id: \.ticker) { debate in
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) {
                                opened = opened == debate.ticker ? nil : debate.ticker
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "sparkles").font(.caption)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(debate.ticker).appText(.footnote, weight: .semibold)
                                    Text(L10n.text("\(debate.questions.count) 个关键问题 · \(debate.sources.count) 个来源"))
                                        .appText(.micro)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(opened == debate.ticker ? 180 : 0))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if opened == debate.ticker {
                            SecurityDebateSection(debate: debate)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                        }
                    }
                    .background(CatfolioTheme.subtleFill)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .task { await store.restore() }
        }
    }
}
