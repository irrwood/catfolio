import SwiftUI

/// The gain-sources and loss-analysis charts, cut down to what fits on the
/// entry card: the headline figure and the bands' shapes over the range each
/// page opens on. Built from the same stacks the pages draw, so the card and
/// the page agree.
struct ReturnsSourcePreview: Codable, Equatable {
    struct Band: Codable, Equatable {
        /// The holding's place in the palette; nil for the others.
        let colour: Int?
        /// One height per sampled day, never below nothing.
        let values: [Double]
    }

    /// Gains: the gain in the range's last day. Losses: that day's total loss.
    let headline: Double
    /// Losses only: how many holdings were below their cost that day.
    let losingCount: Int
    /// Stacked from the axis outward.
    let bands: [Band]

    /// No more points than the card is wide enough to show.
    static let samples = 48

    static func sampled(_ values: [Double]) -> [Double] {
        guard values.count > samples else { return values }
        let step = Double(values.count - 1) / Double(samples - 1)
        return (0..<samples).map { values[Int((Double($0) * step).rounded())] }
    }

    /// The gains alone, without the principal under them: on a card that
    /// short the principal would flatten every gain into a line.
    static func gains(history: HoldingValueHistory, holdings: [Holding]) -> ReturnsSourcePreview? {
        let stack = HoldingContributionStack(history: history, holdings: holdings)
        let rows = stack.window(for: .yearToDate).rows
        guard rows.count > 1, let last = rows.last else { return nil }
        let bands: [Band] = stack.bands.indices.compactMap { index in
            let colour: Int?
            switch stack.bands[index].kind {
            case .principal: return nil
            case .others: colour = nil
            case let .holding(value): colour = value
            }
            return Band(colour: colour, values: sampled(rows.map { $0.bands[index] }))
        }
        return ReturnsSourcePreview(headline: last.total - last.principal, losingCount: 0, bands: bands)
    }

    static func losses(history: HoldingValueHistory, holdings: [Holding]) -> ReturnsSourcePreview? {
        let stack = HoldingLossStack(history: history, holdings: holdings, range: .oneYear)
        guard stack.rows.count > 1, let last = stack.rows.last else { return nil }
        let bands: [Band] = stack.bands.indices.map { index in
            let colour: Int?
            switch stack.bands[index].kind {
            case .others: colour = nil
            case let .holding(value): colour = value
            }
            return Band(colour: colour, values: sampled(stack.rows.map { $0.bands[index] }))
        }
        return ReturnsSourcePreview(headline: last.totalLoss, losingCount: last.losingCount, bands: bands)
    }
}

/// Keeps the two previews and where they came from.
///
/// The cards open on what was last shown for these accounts, kept on disk, so
/// a cold launch has them at once instead of a blank card. The saved prices
/// then redraw them, and fresh prices are fetched once per portfolio change —
/// not on every visit to the tab. Coming back from a chart page redraws from
/// the saved prices, which that page has just brought up to date.
@MainActor @Observable
final class ReturnsSourcePreviewStore {
    private(set) var gains: ReturnsSourcePreview?
    private(set) var losses: ReturnsSourcePreview?
    /// Figures are up and fresh prices are still coming in.
    private(set) var isRefreshing = false
    /// Nothing to show and nothing coming: no saved prices and the fetch failed.
    private(set) var isUnavailable = false

    private var shownScope: String?
    private var freshRevision: String?
    private var generation = 0

    private struct Snapshot: Codable {
        var gains: ReturnsSourcePreview?
        var losses: ReturnsSourcePreview?
    }

    private struct Saved: Codable {
        /// The scope last drawn, for the moment after launch when the
        /// accounts are not known yet.
        var latest: String?
        var scopes: [String: Snapshot] = [:]
    }

    private static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("returns-source-previews.json")
    }

    /// - Parameters:
    ///   - scope: the accounts and holdings the previews describe; what the
    ///     disk copy is kept under.
    ///   - revision: changes whenever the portfolio does; fresh prices are
    ///     fetched once for each.
    ///   - isPortfolioLoaded: false in the moment after launch, before the
    ///     accounts and holdings are known.
    func load(scope: String, revision: String, holdings: [Holding], isPortfolioLoaded: Bool,
              fetch: (Bool) async throws -> HoldingValueHistory) async {
        generation &+= 1
        let request = generation
        isUnavailable = false

        // Before the portfolio has loaded, neither the accounts nor the
        // holdings are known: show what was last drawn, and run again when
        // they arrive.
        let isLoaded = isPortfolioLoaded
        if shownScope != scope {
            let saved = Self.read()
            if let snapshot = saved.scopes[scope] ?? (isLoaded ? nil : saved.latest.flatMap { saved.scopes[$0] }) {
                gains = snapshot.gains
                losses = snapshot.losses
            } else if isLoaded || shownScope != nil {
                gains = nil
                losses = nil
            }
            if isLoaded { shownScope = scope }
        }
        guard isLoaded, !holdings.isEmpty else { return }

        if let cached = try? await fetch(true), !Task.isCancelled, request == generation {
            publish(cached, holdings: holdings, scope: scope)
        }
        guard !Task.isCancelled, request == generation, freshRevision != revision else { return }

        isRefreshing = true
        defer { if request == generation { isRefreshing = false } }
        do {
            let fresh = try await fetch(false)
            guard !Task.isCancelled, request == generation else { return }
            publish(fresh, holdings: holdings, scope: scope)
            freshRevision = revision
        } catch {
            guard !Task.isCancelled, request == generation else { return }
            if gains == nil && losses == nil { isUnavailable = true }
        }
    }

    private func publish(_ history: HoldingValueHistory, holdings: [Holding], scope: String) {
        guard history.rows.count > 1 else { return }
        let nextGains = ReturnsSourcePreview.gains(history: history, holdings: holdings)
        let nextLosses = ReturnsSourcePreview.losses(history: history, holdings: holdings)
        guard nextGains != gains || nextLosses != losses else { return }
        withAnimation(.smooth(duration: 0.35)) {
            gains = nextGains
            losses = nextLosses
        }
        var saved = Self.read()
        saved.scopes[scope] = Snapshot(gains: nextGains, losses: nextLosses)
        saved.latest = scope
        // A handful of account selections is plenty; drop the rest.
        if saved.scopes.count > 6 { saved.scopes = saved.scopes.filter { $0.key == scope } }
        Self.write(saved)
    }

    private static func read() -> Saved {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return Saved() }
        return (try? JSONDecoder().decode(Saved.self, from: data)) ?? Saved()
    }

    private static func write(_ value: Saved) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// The two entry cards, side by side, each opening its chart page.
struct ReturnsSourceCards: View {
    @Environment(AppModel.self) private var model
    let store: ReturnsSourcePreviewStore

    var body: some View {
        HStack(alignment: .top, spacing: SettingsTemplate.tileSpacing) {
            NavigationLink { ReturnsChartPage(chart: .contributors) } label: {
                ReturnsSourceCard(chart: .contributors, preview: store.gains,
                                  isRefreshing: store.isRefreshing, isUnavailable: store.isUnavailable)
            }
            .accessibilityIdentifier("performance.chart.contributors")
            NavigationLink { ReturnsChartPage(chart: .losses) } label: {
                ReturnsSourceCard(chart: .losses, preview: store.losses,
                                  isRefreshing: store.isRefreshing, isUnavailable: store.isUnavailable)
            }
            .accessibilityIdentifier("performance.chart.losses")
        }
        .buttonStyle(.plain)
    }
}

private struct ReturnsSourceCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let chart: ReturnsChartDestination
    let preview: ReturnsSourcePreview?
    let isRefreshing: Bool
    let isUnavailable: Bool

    private var isLosses: Bool { chart == .losses }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: chart.icon)
                    .font(.footnote.weight(.semibold))
                Text(chart.title)
                    .appText(.footnote, weight: .medium)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)

            headline
                .padding(.top, 10)
            Text(subtitle)
                .appText(.caption, weight: .medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)
            }
            .padding([.horizontal, .top], 16)

            // Edge to edge: the drawing runs to the card's sides and bottom
            // and takes the card's own corners, with no inset frame around it.
            ReturnsSourceMiniChart(preview: preview, hangsDown: isLosses)
                .frame(height: 76)
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsTemplate.card)
        .clipShape(RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var headline: some View {
        if let preview {
            let amount = isLosses ? -preview.headline : preview.headline
            Text(DisplayFormat.money(amount, signed: amount != 0, fractionDigits: 0))
                .appNumber(.heading, weight: .semibold)
                .foregroundStyle(amount < 0 ? CatfolioTheme.loss(for: colorScheme)
                                 : amount > 0 ? CatfolioTheme.gain(for: colorScheme) : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText(value: amount))
                .refreshGlow(isActive: isRefreshing)
        } else {
            Text(isUnavailable ? "—" : " ")
                .appNumber(.heading, weight: .semibold)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .leading) {
                    if !isUnavailable {
                        Capsule().fill(Color.primary.opacity(0.07)).frame(width: 96, height: 18)
                    }
                }
        }
    }

    private var subtitle: String {
        if isLosses {
            guard let preview else { return L10n.text("近 1 年") }
            return preview.losingCount == 0
                ? L10n.text("没有持仓低于成本")
                : L10n.text("\(preview.losingCount) 只低于成本")
        }
        // The figure is the holdings' whole gain over their cost, as the
        // page's header has it; only the drawing is this year's.
        return L10n.text("持仓浮动收益")
    }
}

/// The bands stacked, with no axes: gains rise from the bottom edge, losses
/// hang from the top one, as they do on their pages.
private struct ReturnsSourceMiniChart: View {
    @Environment(\.colorScheme) private var colorScheme
    let preview: ReturnsSourcePreview?
    let hangsDown: Bool

    var body: some View {
        if let preview, let count = preview.bands.first?.values.count, count > 1 {
            Canvas { context, size in
                let totals = (0..<count).map { day in preview.bands.reduce(0) { $0 + $1.values[day] } }
                guard let highest = totals.max(), highest > 0.5 else {
                    // Nothing to stack — no holding below cost all year: the
                    // axis alone, where the bands would start.
                    let y: CGFloat = hangsDown ? 0.5 : size.height - 0.5
                    var axis = Path()
                    axis.move(to: CGPoint(x: 0, y: y))
                    axis.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(axis, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                    return
                }
                let peak = highest
                var floor = [Double](repeating: 0, count: count)
                func point(_ day: Int, _ height: Double) -> CGPoint {
                    let x = size.width * CGFloat(day) / CGFloat(count - 1)
                    let depth = size.height * CGFloat(height / peak)
                    return CGPoint(x: x, y: hangsDown ? depth : size.height - depth)
                }
                for band in preview.bands {
                    let ceiling = zip(floor, band.values).map { $0 + $1 }
                    var path = Path()
                    path.move(to: point(0, ceiling[0]))
                    for day in 1..<count { path.addLine(to: point(day, ceiling[day])) }
                    for day in stride(from: count - 1, through: 0, by: -1) { path.addLine(to: point(day, floor[day])) }
                    path.closeSubpath()
                    context.fill(path, with: .color(color(for: band)))
                    floor = ceiling
                }
            }
            .transition(.opacity)
        } else {
            // The card's corners clip it; it needs none of its own.
            Rectangle().fill(Color.primary.opacity(0.05))
        }
    }

    /// Each holding keeps its pages' colour. The others take the loss page's
    /// grey on both cards: the gain page's deep grey is set for its purple
    /// field and reads as a hole on a white card.
    private func color(for band: ReturnsSourcePreview.Band) -> Color {
        guard let colour = band.colour else { return LossAnalysisChart.color(for: .others, scheme: colorScheme) }
        return HoldingContributionChart.color(for: .holding(colour: colour), scheme: colorScheme)
    }
}
