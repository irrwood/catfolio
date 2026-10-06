import SwiftUI

/// A sentence with inline controls, rather than a chat or a row of chips.
struct TodayBriefView: View {
    let context: TodayBriefContext
    var store: TodayBriefStore = .shared
    @ScaledMetric(relativeTo: .title2) private var fontSize: CGFloat = 24

    var body: some View {
        let entry = store.entry(for: context)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Spacer()
                if let date = context.sessionDate {
                    Text(DataDayLabel.text(for: date, locale: Locale(identifier: context.language)))
                }
            }
            .font(.system(.caption, design: .rounded, weight: .medium))
            .foregroundStyle(SettingsTemplate.secondaryText)

            if entry.paragraphs.isEmpty {
                paragraph(context.seed, generating: false, entry: entry)
            } else {
                ForEach(entry.paragraphs) { item in
                    paragraph(item.text,
                              generating: item.isGenerating && item.target == nil || !item.isGenerating && entry.isGenerating,
                              entry: entry, activeTarget: entry.paragraphs.first(where: \.isGenerating)?.target,
                              paragraphID: item.id)
                    if !item.sources.isEmpty, !item.isGenerating {
                        sourceLinks(item.sources)
                    }
                }
            }

            Text(entry.failure ?? L10n.text("点击金额、股票或板块继续展开"))
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(SettingsTemplate.secondaryText)
                .accessibilityIdentifier("today.brief-hint")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityIdentifier("today.brief")
        .task(id: context) { store.start(context) }
    }

    private func paragraph(_ text: String, generating: Bool, entry: TodayBriefStore.Entry, activeTarget: String? = nil, paragraphID: UUID? = nil) -> some View {
        TodayBriefSentence(text: text, context: context, fontSize: fontSize, generating: generating,
                           disabled: entry.isGenerating, activeTarget: activeTarget) { target in
            store.expand(context, target: target, after: paragraphID)
        }
    }

    private func sourceLinks(_ sources: [TodayBriefSource]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(sources.prefix(2).enumerated()), id: \.element.url) { _, source in
                Link(destination: source.url) {
                    Label(source.title, systemImage: "newspaper")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(SettingsTemplate.secondaryText)
                        .lineLimit(2)
                }
            }
        }
    }
}

struct TodayBriefSentence: View {
    let text: String
    let context: TodayBriefContext
    var fontSize: CGFloat = 24
    var generating = false
    var disabled = false
    var activeTarget: String? = nil
    var onExpand: (String) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let fragments = TodayBriefFragment.parse(text, allowedTargets: context.targets)
        let pieces = fragments.flatMap { fragment in
            fragment.target != nil ? [fragment] : Self.words(fragment.text).map {
                TodayBriefFragment(text: $0, target: nil)
            }
        }
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !generating || reduceMotion)) { timeline in
            let time = generating && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0
            TodayBriefFlowLayout(lineSpacing: 7) {
                ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                    if let target = piece.target {
                        Button {
                            guard !disabled else { return }
                            onExpand(target)
                        } label: {
                            HStack(spacing: 4) {
                                inlineIcon(target)
                                word(piece.text, index: index, time: time, target: piece.target)
                                    .foregroundStyle(CatfolioTheme.primaryText)
                            }
                        }
                        .buttonStyle(.plain)
                        .allowsHitTesting(!disabled)
                        .accessibilityHint(L10n.text("继续展开简报"))
                        .accessibilityIdentifier("today.brief.\(target)")
                    } else {
                        word(piece.text, index: index, time: time, target: piece.target)
                            .foregroundStyle(CatfolioTheme.primaryText.opacity(0.55))
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        // Reading one character at a time is unusable with VoiceOver. The
        // paragraph is read once; interactive phrases remain separate actions.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(fragments.map(\.text).joined())
    }

    private func word(_ text: String, index: Int, time: Double, target: String?) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .textRenderer(TodayBriefWaveRenderer(time: time, phase: Double(index) * 0.55,
                                                enabled: Self.animates(target: target, activeTarget: activeTarget,
                                                                       generating: generating, reduceMotion: reduceMotion)))
            .fixedSize(horizontal: false, vertical: true)
    }

    static func animates(target: String?, activeTarget: String?, generating: Bool, reduceMotion: Bool) -> Bool {
        generating && !reduceMotion && (activeTarget == nil || target == activeTarget)
    }

    @ViewBuilder private func inlineIcon(_ target: String) -> some View {
        if target.hasPrefix("stock:"), let stock = context.stocks.first(where: { "stock:\($0.ticker)" == target }) {
            AssetLogo(ticker: stock.ticker, logoSymbol: stock.logoSymbol, size: fontSize,
                      cornerRadius: fontSize * 0.3)
                .accessibilityHidden(true)
        } else if target == "portfolio" {
            // The major contributors form a small overlapping logo stack.
            HStack(spacing: -fontSize * 0.3) {
                if context.leaders.isEmpty {
                    Image(systemName: "chart.xyaxis.line")
                } else {
                    ForEach(Array(context.leaders.prefix(2)), id: \.ticker) { stock in
                        AssetLogo(ticker: stock.ticker, logoSymbol: stock.logoSymbol,
                                  size: fontSize, cornerRadius: fontSize * 0.3)
                            .overlay { RoundedRectangle(cornerRadius: fontSize * 0.3)
                                .stroke(SettingsTemplate.pageBackground, lineWidth: 1.5) }
                    }
                }
            }
            .accessibilityHidden(true)
        } else {
            let icon = context.sectors.first(where: { "sector:\($0.id)" == target })?.icon
                ?? "chart.line.uptrend.xyaxis"
            Image(systemName: icon)
                .font(.system(size: fontSize * 0.8, weight: .semibold))
                .foregroundStyle(CatfolioTheme.primaryText)
                .accessibilityHidden(true)
        }
    }

    /// Keep Latin words and numbers intact; Chinese wraps at character
    /// boundaries. Punctuation stays with its preceding word.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var word = ""
        func flush() { if !word.isEmpty { result.append(word); word = "" } }
        for character in text.replacingOccurrences(of: "\n", with: " ") {
            if character.isASCII && (character.isLetter || character.isNumber || ".+-/%$£€".contains(character)) {
                word.append(character)
            } else if character.isWhitespace {
                word.append(character)
                flush()
            } else if "，。；：、！？,.!?;:）)]”’".contains(character) {
                if !word.isEmpty { word.append(character); flush() }
                else if !result.isEmpty { result[result.count - 1].append(character) }
                else { result.append(String(character)) }
            } else {
                flush()
                result.append(String(character))
            }
        }
        flush()
        return result
    }
}

/// Measure long interactive phrases at the available width before wrapping.
/// This also keeps large accessibility type inside a narrow phone's margins.
private struct TodayBriefFlowLayout: Layout {
    let lineSpacing: CGFloat

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var used: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if used + size.width > width, !rows[rows.count - 1].isEmpty {
                rows.append([])
                used = 0
            }
            rows[rows.count - 1].append((index, size))
            used += size.width
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? 320)
        return CGSize(width: proposal.width ?? rows.map { $0.reduce(0) { $0 + $1.1.width } }.max() ?? 0,
                      height: rows.reduce(0) { $0 + ($1.map { $0.1.height }.max() ?? 0) }
                        + CGFloat(max(0, rows.count - 1)) * lineSpacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let height = row.map { $0.1.height }.max() ?? 0
            var x = bounds.minX
            for (index, size) in row {
                subviews[index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width
            }
            y += height + lineSpacing
        }
    }
}

/// Animate drawn glyphs, not layout: rows and inline logos do not bounce or
/// reflow while the next sentence is being generated.
struct TodayBriefWaveRenderer: TextRenderer {
    let time: Double
    let phase: Double
    let enabled: Bool

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0
        for line in layout {
            for run in line {
                for slice in run {
                    var copy = context
                    if enabled {
                        let wave = sin(time * 3.8 - phase - Double(index) * 0.5)
                        copy.translateBy(x: 0, y: wave * 1.8)
                        copy.opacity = 0.72 + (wave + 1) * 0.14
                    }
                    copy.draw(slice)
                    index += 1
                }
            }
        }
    }
}
