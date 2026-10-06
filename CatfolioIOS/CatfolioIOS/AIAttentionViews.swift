import SwiftUI

struct PortfolioAttentionReportView: View {
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
                Label(L10n.message(warning), systemImage: "exclamationmark.circle")
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
    /// Handed on explicitly: a pushed page does not inherit it from here.
    @Environment(\.attentionEvidenceEditor) private var editor

    var body: some View {
        Group {
            if prominent {
                Button { showsDetail = true } label: {
                    PortfolioAttentionCardContent(row: row, prominent: true)
                }
                .navigationDestination(isPresented: $showsDetail) {
                    PortfolioAttentionDetail(row: row)
                        .environment(\.attentionEvidenceEditor, editor)
                        .navigationTransition(.zoom(sourceID: row.id, in: zoom))
                }
            } else {
                NavigationLink {
                    PortfolioAttentionDetail(row: row)
                        .environment(\.attentionEvidenceEditor, editor)
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
/// Lets a reader keep their changes to a holding's evidence. Given by the
/// pages that own a saved analysis — the attention page and its preview on
/// Performance — and absent in the chat, where the reading stays as written.
struct AttentionEvidenceEditor {
    let save: (PortfolioAttentionHolding) -> Void
}

extension EnvironmentValues {
    @Entry var attentionEvidenceEditor: AttentionEvidenceEditor? = nil
}

struct PortfolioAttentionDetail: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.attentionEvidenceEditor) private var editor
    @State private var row: PortfolioAttentionHolding
    /// Evidence set aside, as edited now. Points written by hand in an
    /// earlier version are kept and sent along, but no longer added here.
    @State private var excluded: Set<String>
    @State private var notes: [String]
    @State private var isRejudging = false
    @State private var rejudgeError: String?
    /// The 追问 composer, and the question waiting for its answer.
    @State private var question = ""
    @State private var pendingQuestion: String?
    @State private var followUpError: String?
    @FocusState private var isAsking: Bool

    init(row: PortfolioAttentionHolding) {
        _row = State(initialValue: row)
        _excluded = State(initialValue: Set(row.adjustment?.excluded ?? []))
        _notes = State(initialValue: row.adjustment?.notes ?? [])
    }

    /// The model's own lists, as first written.
    private var originalSupporting: [String] { row.adjustment?.originalSupporting ?? row.thesis.supportingEvidence }
    private var originalCounter: [String] { row.adjustment?.originalCounter ?? row.thesis.counterEvidence }

    /// Whether the evidence on screen differs from what the reading was
    /// last judged on.
    private var hasPendingChanges: Bool {
        excluded != Set(row.adjustment?.excluded ?? []) || notes != (row.adjustment?.notes ?? [])
    }

    private var followUps: [PortfolioAttentionFollowUp] { row.followUps ?? [] }

    var body: some View {
        ScrollViewReader { proxy in
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
                if editor != nil {
                    EditableEvidenceList(title: L10n.text("支持证据"), values: originalSupporting, excluded: $excluded)
                    EditableEvidenceList(title: L10n.text("反方证据"), values: originalCounter, excluded: $excluded)
                    rejudgeBar
                } else {
                    ReaderList(title: L10n.text("支持证据"), values: row.thesis.supportingEvidence)
                    ReaderList(title: L10n.text("反方证据"), values: row.thesis.counterEvidence)
                }
                ReaderList(title: L10n.text("风险"), values: row.thesis.risks)
                ReaderList(title: L10n.text("接下来关注"), values: row.thesis.watchNext)
                ReaderList(title: L10n.text("Risk Flags"), values: row.thesis.riskFlags.map(PortfolioAttentionHolding.riskFlagText))

                followUpThread

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
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        // Keep the newest question and its answer in view as they arrive.
        .onChange(of: pendingQuestion) { _, pending in
            guard pending != nil else { return }
            withAnimation(.smooth) { proxy.scrollTo("follow-up-pending", anchor: .bottom) }
        }
        .onChange(of: followUps.last?.id) { _, id in
            guard let id else { return }
            withAnimation(.smooth) { proxy.scrollTo(id, anchor: .top) }
        }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            followUpComposer
                .frame(maxWidth: 600)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .softTopScrollEdge()
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .hidesTabBarWhenPushed()
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
            Text(row.displayName)
                .appText(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            // The judgement on one line, the figures behind it on the next.
            VStack(alignment: .leading, spacing: 4) {
                Text("\(row.stanceText) · \(row.confidenceText)")
                if !row.signals.isEmpty {
                    Text(row.signals.map { L10n.message($0.label) }.joined(separator: " · "))
                }
            }
            .appText(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The questions asked on this page, oldest first, each followed by its
    /// answer. Saved with the holding, so they are still here next time.
    @ViewBuilder
    private var followUpThread: some View {
        if !followUps.isEmpty || pendingQuestion != nil || followUpError != nil {
            ReaderSection(L10n.text("追问")) {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(followUps) { item in
                        followUpEntry(question: item.question) {
                            ReaderParagraph(item.answer)
                            if item.searched {
                                Label(L10n.text("已联网搜索"), systemImage: "globe")
                                    .appText(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .id(item.id)
                        .contextMenu {
                            Button(L10n.text("拷贝回答"), systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = item.answer
                            }
                            Button(L10n.text("删除这条追问"), systemImage: "trash", role: .destructive) {
                                remove(item)
                            }
                        }
                    }
                    if let pendingQuestion {
                        followUpEntry(question: pendingQuestion) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(L10n.text("正在回答…"))
                                    .appText(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .id("follow-up-pending")
                    }
                    if let followUpError {
                        Text(L10n.message(followUpError))
                            .appText(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func followUpEntry<Answer: View>(question: String,
                                             @ViewBuilder answer: () -> Answer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question)
                .appText(.subheading, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
            answer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The AI page's floating field: a glass capsule, the send button inset
    /// concentric with its end.
    private var followUpComposer: some View {
        HStack(spacing: 8) {
            TextField(
                L10n.text("追问这只持仓"),
                text: $question,
                prompt: Text(L10n.text("追问这只持仓")).foregroundStyle(Color.primary.opacity(0.62)),
                axis: .vertical
            )
            .appText(.subheading)
            .foregroundStyle(CatfolioTheme.primaryText)
            .lineLimit(1...4)
            .focused($isAsking)
            .submitLabel(.send)
            .onSubmit(ask)

            if pendingQuestion != nil {
                ProgressView()
                    .controlSize(.small)
                    .tint(.primary)
                    .frame(width: 32, height: 32)
            } else {
                Button(action: ask) {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(canAsk ? Color(uiColor: .systemBackground) : Color.primary.opacity(0.42))
                        .frame(width: 32, height: 32)
                        .background(canAsk ? Color.primary : Color.primary.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canAsk)
                .accessibilityLabel(L10n.text("发送"))
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minHeight: 48)
        .floatingGlassSurface(in: Capsule(), isInteractive: false)
    }

    private var canAsk: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingQuestion == nil
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, pendingQuestion == nil else { return }
        question = ""
        isAsking = false
        followUpError = nil
        pendingQuestion = text
        let base = row
        Task {
            defer { pendingQuestion = nil }
            do {
                let answer: (text: String, searched: Bool)
                #if DEBUG
                if LaunchArguments.contains("--demo-follow-up") {
                    // A canned answer, for looking at the thread without a model.
                    try await Task.sleep(for: .seconds(1.5))
                    answer = ("成交量是前 30 日均量的 1.9 倍，说明这次上涨有较多资金参与，不只是少量成交推动。但放量本身不说明原因：材料里没有对应的公司公告，可能来自板块或指数资金。接下来看成交量能否维持，以及价格是否守住放量当天的低点。", true)
                } else {
                    answer = try await model.followUpAttention(base, question: text, history: base.followUps ?? [])
                }
                #else
                answer = try await model.followUpAttention(base, question: text, history: base.followUps ?? [])
                #endif
                let body = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty else { throw LocalServiceError.invalidResponse }
                var updated = row
                updated.followUps = (updated.followUps ?? []) + [PortfolioAttentionFollowUp(
                    question: text, answer: body, askedAt: .now, searched: answer.searched)]
                row = updated
                editor?.save(updated)
            } catch {
                // The question goes back in the field, so it is not lost.
                if question.isEmpty { question = text }
                followUpError = L10n.text("没能回答：\(error.localizedDescription)")
            }
        }
    }

    private func remove(_ item: PortfolioAttentionFollowUp) {
        var updated = row
        updated.followUps = followUps.filter { $0.id != item.id }
        row = updated
        editor?.save(updated)
    }

    @ViewBuilder
    private var rejudgeBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hasPendingChanges || isRejudging {
                Button(action: rejudge) {
                    HStack(spacing: 8) {
                        if isRejudging { ProgressView().controlSize(.small) }
                        Text(isRejudging ? L10n.text("正在重新判断…") : L10n.text("按调整后的证据重新判断"))
                            .appText(.callout, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .disabled(isRejudging)
            } else if let date = row.adjustment?.rejudgedAt {
                Text(L10n.text("已按你的调整重新判断 · \(date.formatted(date: .abbreviated, time: .shortened))"))
                    .appText(.caption)
                    .foregroundStyle(.secondary)
            }
            if let rejudgeError {
                Text(L10n.message(rejudgeError)).appText(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("轻点证据可以去掉或恢复，再按保留的证据重新判断。调整过的判断置信度最高为中。"))
                .appText(.micro)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 24)
    }

    private func rejudge() {
        guard !isRejudging else { return }
        isRejudging = true
        rejudgeError = nil
        let supporting = originalSupporting.filter { !excluded.contains($0) }
        let counter = originalCounter.filter { !excluded.contains($0) }
        let kept = (excluded, notes)
        let base = row
        Task {
            defer { isRejudging = false }
            do {
                let thesis = try await model.rejudgeAttention(base, supporting: supporting, counter: counter, notes: kept.1)
                // From the page's current row, so an answer that arrived
                // meanwhile is kept.
                var updated = row
                updated.thesis = thesis
                updated.adjustment = PortfolioAttentionAdjustment(
                    originalSupporting: originalSupporting, originalCounter: originalCounter,
                    excluded: Array(kept.0), notes: kept.1, rejudgedAt: .now)
                row = updated
                editor?.save(updated)
            } catch {
                rejudgeError = L10n.text("没能重新判断：\(error.localizedDescription)")
            }
        }
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

/// Evidence the reader can set aside: a tap turns a point off — struck
/// through, dimmed — and on again.
struct EditableEvidenceList: View {
    let title: String
    let values: [String]
    @Binding var excluded: Set<String>

    var body: some View {
        if !values.isEmpty {
            ReaderSection(title) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(values, id: \.self) { value in
                        let isOn = !excluded.contains(value)
                        Button {
                            if isOn { excluded.insert(value) } else { excluded.remove(value) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                                    .font(.callout)
                                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                                Text(value)
                                    .appText(.subheading)
                                    .lineSpacing(7)
                                    .strikethrough(!isOn, color: .secondary)
                                    .foregroundStyle(isOn ? Color.primary.opacity(0.88) : Color.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .multilineTextAlignment(.leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .sensoryFeedback(.selection, trigger: isOn)
                        .accessibilityValue(isOn ? L10n.text("已采用") : L10n.text("已去掉"))
                        .accessibilityHint(L10n.text("轻点去掉或恢复这条证据"))
                    }
                }
            }
        }
    }
}

/// A labelled part of the reader: a small grey label, then its text.
struct ReaderSection<Content: View>: View {
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
struct ReaderParagraph: View {
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
struct ReaderList: View {
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
extension PortfolioAttentionHolding {
    var attentionText: String {
        attention == .high ? L10n.text("高关注") : L10n.text("中关注")
    }

    var attentionTint: Color {
        attention == .high ? Color.red : CatfolioStyle.blue
    }

    /// A reading that rests on a confirmed company event speaks about the
    /// investment case; one that rests on price signals speaks about the
    /// price, so a rise is never printed as the case getting stronger.
    var stanceText: String {
        if thesis.basis == .company {
            switch thesis.stance {
            case .strengthening: return L10n.text("投资逻辑增强")
            case .maintaining: return L10n.text("投资逻辑维持")
            case .weakening: return L10n.text("投资逻辑减弱")
            }
        }
        switch thesis.stance {
        case .strengthening: return L10n.text("走势偏强")
        case .maintaining: return L10n.text("走势中性")
        case .weakening: return L10n.text("走势偏弱")
        }
    }

    var confidenceText: String {
        guard thesis.basis == .company else { return L10n.text("公司面待确认") }
        switch thesis.confidence {
        case .high: return L10n.text("高置信度")
        case .medium: return L10n.text("中置信度")
        case .none: return L10n.text("低置信度")
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

struct PortfolioAttentionCardContent: View {
    static let cornerRadius: CGFloat = 24

    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model: AppModel?
    let row: PortfolioAttentionHolding
    var prominent = false

    /// The held position, for the home list's logo and name.
    private var holding: Holding? {
        model?.holdings.first { $0.ticker.caseInsensitiveCompare(row.ticker) == .orderedSame }
    }

    /// Named as the home list names it: the company, then the ticker.
    private var companyName: String {
        holding?.shortName ?? CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: prominent ? 16 : 10) {
            HStack(alignment: .center, spacing: 10) {
                AssetLogo(ticker: row.ticker, logoSymbol: holding?.logoSymbol ?? row.ticker,
                          size: prominent ? 48 : 44, cornerRadius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    SecurityDisplayName(name: companyName, scale: prominent ? .heading : .body, weight: .semibold,
                                        showsClassMarkers: false)
                    Text(row.ticker)
                        .appText(.footnote, weight: .medium)
                        .foregroundStyle(Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    // A dot and a word in the level's colour, as the reader
                    // opens with — not a bordered pill competing with the
                    // ticker for attention.
                    HStack(spacing: 5) {
                        Circle().fill(row.attentionTint).frame(width: 6, height: 6)
                        Text(row.attentionText)
                    }
                    .appText(.caption, weight: .semibold)
                    .foregroundStyle(row.attentionTint)
                    // The card opens; the chevron is all that says so.
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }

            Text("\(row.stanceText) · \(row.confidenceText)"
                 + (row.adjustment?.rejudgedAt != nil ? " · " + L10n.text("已调整证据") : ""))
                .font(.caption.weight(.semibold))

            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(row.signals) { signal in
                        Text(L10n.message(signal.label))
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
        // Fills the height it is given, so cards side by side are as tall as
        // the tallest; in a list it is only as tall as its content.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
        .modifier(AttentionCardSurface(isVisible: !prominent))
    }

}

/// The attention report's cards are Liquid Glass, like the composer below
/// them — not an opaque black slab with a hairline. Research sets the card
/// on its own page with no surface at all.
struct AttentionCardSurface: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        if isVisible {
            content.attentionGlassCard()
        } else {
            content
        }
    }
}

extension View {
    /// Glass that only shows: never interactive, which would take the touches
    /// meant for the card's link and its chips.
    func attentionGlassCard() -> some View {
        floatingGlassSurface(
            in: RoundedRectangle(cornerRadius: PortfolioAttentionCardContent.cornerRadius, style: .continuous),
            isInteractive: false
        )
    }
}
