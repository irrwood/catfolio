import SwiftUI

/// Concrete changes, conditional interpretation and observable follow-up.
struct SecurityDebateSection: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let debate: SecurityDebate
    var title: String? = nil
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title ?? L10n.text("关键变化"))
                    .appText(.heading, weight: .semibold)
                Spacer(minLength: 8)
                Text(L10n.text("\(debate.sources.count) 个已引用来源"))
                    .appText(.caption)
                    .foregroundStyle(.secondary)
            }

            if debate.questions.isEmpty {
                Text(L10n.text("暂未找到证据充分的关键变化。部分来源可能无法读取正文，可稍后重试。"))
                    .appText(.footnote)
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

            Text(L10n.text("事实附原文摘录；影响解读和观察项是分析，不代表已发生。"))
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
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
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
                VStack(alignment: .leading, spacing: 16) {
                    detail("发生了什么", text: question.whatChanged)
                    SecurityDebateSourceChip(sources: debate.sources(for: question), evidence: question.evidence)
                    detail("为什么重要 · 分析", text: question.whyItMatters)
                    detail("接下来观察", text: question.watchNext)
                    if !question.uncertainty.isEmpty {
                        detail("尚不确定", text: question.uncertainty)
                    }
                }
                .padding(14)
            }
        }
    }

    private func detail(_ title: L10n.Message, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(title)).appText(.caption, weight: .semibold).foregroundStyle(.secondary)
            Text(text).appText(.footnote).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A frozen, public quote window. Chart scrubbing never starts this task;
/// only presenting this native sheet from the explicit action does.
struct SecurityPriceMoveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var appLocale
    let context: SecurityPriceMoveContext
    var store: SecurityPriceMoveStore = .shared

    private var progress: SecurityDebateStore.Progress { store.progress(for: context) }
    private var result: SecurityDebate? { progress.debate ?? store.lastResult(for: context) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(context.name + " · " + context.ticker).appText(.heading, weight: .semibold)
                    Text(context.rangeLabel + " · " + context.intervalText)
                        .appText(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("price-move-interval")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        FinancialText(DisplayFormat.money(context.startPrice, currency: context.currency) + " → "
                            + DisplayFormat.money(context.endPrice, currency: context.currency))
                            .appNumber(.subheading).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        FinancialText(DisplayFormat.percent(context.changePercent)).appNumber(.subheading)
                            .foregroundStyle(context.changePercent >= 0 ? CatfolioTheme.gainDefault : CatfolioTheme.lossDefault)
                    }
                    Text(L10n.text("按图表所选区间分析，不默认代表今日涨跌。"))
                        .appText(.caption).foregroundStyle(.secondary)
                }
                status
                if let result {
                    SecurityDebateSection(debate: result, title: L10n.text("可能相关的因素"))
                    Text(L10n.text("生成于 \(result.generatedAt.formatted(date: .abbreviated, time: .shortened))"))
                        .appText(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.text("仅分析可核对的公开资料。资料覆盖可能不完整，相关事件不等于已证明的涨跌原因。"))
                    .appText(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemBackground))
        .softTopScrollEdge()
        .navigationTitle(context.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            HoldingDetailCloseToolbar { dismiss() }
            if result != nil, !progress.isWorking {
                ToolbarItem(placement: .primaryAction) {
                    Button { store.start(context, force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel(L10n.text("重新分析"))
                }
            }
        }
        .task(id: context.key(language: appLocale.identifier)) {
            await store.restore()
            guard !Task.isCancelled else { return }
            store.start(context)
        }
    }

    @ViewBuilder private var status: some View {
        switch progress {
        case .collecting, .reasoning:
            HStack(spacing: 12) {
                ProgressView()
                Text(L10n.text(progress == .collecting ? "正在收集区间内的公开资料" : "正在核对可能相关的因素"))
                    .appText(.footnote).frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.text("取消")) { store.cancel(context) }.appText(.footnote)
            }
        case .failed(let message), .empty(let message):
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.message(message)).appText(.footnote).foregroundStyle(.secondary)
                if result != nil {
                    Text(L10n.text("已有分析仍保留在下方。"))
                        .appText(.caption).foregroundStyle(.secondary)
                }
                Button(L10n.text("重试")) { store.start(context, force: true) }.buttonStyle(.bordered)
            }
        case .idle:
            Button(L10n.text("开始分析")) { store.start(context) }.buttonStyle(.bordered)
        case .ready:
            EmptyView()
        }
    }
}

/// The source count, expanding into the list it counts.
private struct SecurityDebateSourceChip: View {
    @Environment(\.locale) private var appLocale
    let sources: [PortfolioAttentionSource]
    let evidence: [SecurityResearchCitation]
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
            SecurityDebateSourceList(sources: sources, evidence: evidence)
                .padding(.top, 2)
        }
    }
}

/// Each cited source, its quoted evidence, publisher and date; tapping opens it.
private struct SecurityDebateSourceList: View {
    let sources: [PortfolioAttentionSource]
    let evidence: [SecurityResearchCitation]

    var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sources) { source in
                    Link(destination: source.url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                                .appText(.caption, weight: .medium)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            ForEach(evidence.filter { $0.sourceID == source.id }, id: \.quote) { citation in
                                Text("“\(citation.quote)”")
                                    .appText(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
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
    }
}

/// Folded until tapped, like the analyst and earnings cards. Appearing only
/// restores what is on the device; opening the card shows a saved result as
/// it is and starts reading only for a stock that has nothing yet.
struct SecurityDebateCard: View {
    @Environment(\.locale) private var appLocale
    let ticker: String
    let name: String
    @State private var store = SecurityDebateStore.shared
    @State private var isPresented = false

    var body: some View {
        SecurityDebateCardContent(
            progress: store.progress(for: ticker),
            onStart: { store.start(ticker: ticker, name: name) },
            onRegenerate: { store.start(ticker: ticker, name: name, force: true) },
            previousResult: store.lastResult(for: ticker),
            isPresented: $isPresented
        )
        .task(id: appLocale.identifier) { await store.restore() }
        .onChange(of: isPresented) { _, open in
            guard open else { return }
            Task {
                // A tap straight after the page opens must not outrun the
                // restore and pay for a result that is already saved.
                await store.restore()
                let progress = store.progress(for: ticker)
                guard progress.debate == nil, store.lastResult(for: ticker) == nil, !progress.isWorking else { return }
                store.start(ticker: ticker, name: name)
            }
        }
    }
}

/// State-specific content without owning requests. Every stage keeps the
/// same entry card; each development opens from within the child page.
struct SecurityDebateCardContent: View {
    let progress: SecurityDebateStore.Progress
    let onStart: () -> Void
    let onRegenerate: () -> Void
    var previousResult: SecurityDebate?
    @Binding var isPresented: Bool
    @State private var opened: SecurityDebateQuestion?

    init(progress: SecurityDebateStore.Progress, onStart: @escaping () -> Void,
         onRegenerate: @escaping () -> Void, previousResult: SecurityDebate? = nil,
         isPresented: Binding<Bool> = .constant(false)) {
        self.progress = progress
        self.onStart = onStart
        self.onRegenerate = onRegenerate
        self.previousResult = previousResult
        _isPresented = isPresented
    }

    private var shown: SecurityDebate? { progress.debate ?? previousResult }

    private var subtitle: String {
        switch progress {
        case .collecting: return L10n.text("正在收集新闻与申报文件…")
        case .reasoning: return L10n.text("正在核对变化与原文证据…")
        default:
            guard let shown else { return L10n.text("阅读新闻与申报正文，提取重要变化、影响和观察项") }
            return L10n.text("\(shown.questions.count) 个关键变化 · \(shown.sources.count) 个来源")
        }
    }

    var body: some View {
        HoldingDetailChildPageCard(
            title: L10n.text("AI 关键变化"),
            subtitle: subtitle,
            isPresented: $isPresented,
            isLoading: progress.isWorking
        ) {
            pageContent
                .workspacePage(item: $opened) { question in
                    if let debate = shown {
                        SecurityDebateQuestionSheet(question: question, debate: debate)
                    }
                }
        }
        .accessibilityIdentifier("holding-ai-developments-card")
    }

    @ViewBuilder private var pageContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch progress {
            case .collecting, .reasoning:
                HStack(spacing: 10) {
                    ProgressView()
                    Text(progress == .collecting
                         ? L10n.text("正在收集新闻与申报文件…")
                         : L10n.text("正在核对变化与原文证据…"))
                        .appText(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                Text(L10n.text("可以离开这个页面，完成后在 AI 标签里也能看到。"))
                    .appText(.caption)
                    .foregroundStyle(.secondary)
            case let .failed(message), let .empty(message):
                StatusNotice(text: message, kind: .info)
                if shown == nil {
                    Button(L10n.text("重试"), action: onRegenerate)
                        .appText(.caption, weight: .semibold)
                }
            case .idle:
                if shown == nil {
                    Button(L10n.text("开始分析"), action: onStart)
                        .appText(.caption, weight: .semibold)
                }
            case .ready:
                EmptyView()
            }

            if let shown {
                if progress.debate == nil {
                    Text(L10n.text("保留的上次结果"))
                        .appText(.caption)
                        .foregroundStyle(.secondary)
                }
                if shown.questions.isEmpty {
                    Text(L10n.text("暂未找到证据充分的关键变化。部分来源可能无法读取正文，可稍后重试。"))
                        .appText(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    questionList(shown)
                }
                HStack(spacing: 10) {
                    Text(L10n.text("生成于 \(shown.generatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"))
                        .appText(.micro)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if !progress.isWorking {
                        Button(L10n.text("重新生成"), action: onRegenerate)
                            .appText(.caption, weight: .semibold)
                    }
                }
            }
        }
    }

    /// One row per development: its question and the first lines of what
    /// happened. The whole of it is one tap away, in its own sheet.
    private func questionList(_ debate: SecurityDebate) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(debate.questions.enumerated()), id: \.element.id) { index, question in
                if index > 0 { Divider() }
                Button { opened = question } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(question.question)
                                .appText(.footnote, weight: .semibold)
                                .foregroundStyle(CatfolioTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(question.whatChanged)
                                .appText(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The second-level sheet for one development: what happened, why it matters,
/// what to watch, what is unsure, and the sources that back it.
struct SecurityDebateQuestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let question: SecurityDebateQuestion
    let debate: SecurityDebate

    var body: some View {
        DetailPageNavigation {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(question.question)
                        .appText(.heading, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                    section("发生了什么", text: question.whatChanged)
                    section("为什么重要 · 分析", text: question.whyItMatters)
                    section("接下来观察", text: question.watchNext)
                    if !question.uncertainty.isEmpty {
                        section("尚不确定", text: question.uncertainty)
                    }
                    let sources = debate.sources(for: question)
                    if !sources.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L10n.text("来源")).appText(.caption, weight: .semibold).foregroundStyle(.secondary)
                            SecurityDebateSourceList(sources: sources, evidence: question.evidence)
                        }
                    }
                    Text(L10n.text("事实附原文摘录；影响解读和观察项是分析，不代表已发生。"))
                        .appText(.micro, weight: .regular)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .padding(.bottom, 24)
            }
            .softTopScrollEdge()
            .appPageBackground().navigationTitle(L10n.text("AI 关键变化"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                HoldingDetailCloseToolbar { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func section(_ title: L10n.Message, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text(title)).appText(.caption, weight: .semibold).foregroundStyle(.secondary)
            Text(text).appText(.body).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
