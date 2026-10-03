import SwiftUI
import Observation

#if DEBUG
/// Anchors are read by the snapshot fixture using the displayed components.
struct ResearchCardLayoutFrames: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
#endif

extension View {
    @ViewBuilder
    func researchLayoutFrame(_ id: String?) -> some View {
        #if DEBUG
        if let id {
            transformAnchorPreference(key: ResearchCardLayoutFrames.self, value: .bounds) { frames, anchor in
                frames[id] = anchor
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}

/// Folding and reopening a research card can start its replacement request
/// before the cancelled request returns. Only the latest request owns the
/// spinner and may publish a value, error, or recovered cache entry.
@MainActor @Observable
final class ResearchCardLoadState {
    private(set) var isLoading = false
    private(set) var revision = UUID()

    func canPublish(_ request: UUID) -> Bool {
        request == revision && !Task.isCancelled
    }

    func load<Value>(
        operation: () async throws -> Value,
        fallback: () async -> Value? = { nil },
        onSuccess: (Value) -> Void,
        onFailure: (Error, Value?) -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        revision = request
        isLoading = true
        defer { if revision == request { isLoading = false } }
        do {
            let value = try await operation()
            guard canPublish(request) else { return }
            onSuccess(value)
        } catch is CancellationError {
            // An intentional stop keeps the existing result and error state.
        } catch {
            guard canPublish(request) else { return }
            let cached = await fallback()
            guard canPublish(request) else { return }
            onFailure(error, cached)
        }
    }
}

struct AnalystConsensusData: Codable, Sendable {
    let ratings: RatingSpread?
    let consensus: String?
    let low: Double?
    let mean: Double?
    let high: Double?
    let current: Double?
    /// Which provider answered, so the card can say so rather than implying
    /// every number comes from the same place.
    let source: String
    let fetchedAt: Date
    let warnings: [String]
    var total: Int { ratings?.total ?? 0 }
    var hasContent: Bool { total > 0 || Self.validTargets(low: low, mean: mean, high: high) }

    /// Ratings and targets can outlive the quote saved with them. The value
    /// labelled current always comes from this presentation's holding quote;
    /// an unavailable or incompatible quote must not revive the cached price.
    func withCurrentQuote(_ price: Double?, currency: String?) -> Self {
        let quote = currency?.uppercased() == "USD"
            ? price.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            : nil
        return Self(ratings: ratings, consensus: consensus, low: low, mean: mean, high: high,
                    current: quote, source: source, fetchedAt: fetchedAt, warnings: warnings)
    }

    static func ratingCounts(_ row: [String: Any]) -> [Int]? {
        let keys = ["strongSell", "sell", "hold", "buy", "strongBuy"]
        let counts = keys.compactMap { key -> Int? in
            guard let n = row[key] as? NSNumber, n.doubleValue.isFinite,
                  n.doubleValue >= 0, n.doubleValue <= 1_000_000,
                  n.doubleValue.rounded() == n.doubleValue else { return nil }
            return n.intValue
        }
        return counts.count == keys.count ? counts : nil
    }
    static func validTargets(low: Double?, mean: Double?, high: Double?) -> Bool {
        guard let low, let mean, let high else { return false }
        return low.isFinite && mean.isFinite && high.isFinite && low > 0 && low <= mean && mean <= high
    }
    static func position(_ value: Double, low: Double, high: Double) -> Double {
        guard high > low else { return 0.5 }
        return min(1, max(0, (value - low) / (high - low)))
    }
}

actor AnalystConsensusClient {
    static let shared = AnalystConsensusClient()
    private var cache: [String: AnalystConsensusData] = [:]
    private let cacheURL: URL

    init(cacheURL: URL? = nil) {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("AnalystConsensus", isDirectory: true)
        self.cacheURL = cacheURL ?? directory.appendingPathComponent("analyst-consensus-v1.json")
        if let stored = try? Data(contentsOf: self.cacheURL),
           let decoded = try? JSONDecoder().decode(
               [String: AnalystConsensusData].self,
               from: stored
           ) {
            cache = decoded
        }
    }

    /// The caller already knows the holding's quote currency and price, so the
    /// `profile` request this used to make was a third of the page's FMP budget
    /// spent re-deriving them — and on a shared quota that is what tips the
    /// other cards into 429. A non-USD holding is now rejected without
    /// spending a request at all.
    /// An unknown currency is not assumed to be USD: comparing a target price
    /// against a quote in another unit is worse than showing nothing. Exposed
    /// so the card can say so without offering a button that cannot work.
    nonisolated static func supports(currency: String?) -> Bool {
        currency?.uppercased() == "USD"
    }

    /// Analyst snapshots remain available until the user explicitly refreshes
    /// that analyst page. Opening/closing a sheet, view reconstruction and app
    /// relaunches must not silently discard a result the user already fetched.
    func cached(symbol: String) -> AnalystConsensusData? {
        guard let value = cache[symbol.uppercased()], value.hasContent else { return nil }
        return value
    }

    func load(
        symbol: String,
        currency: String?,
        price: Double?,
        forceRefresh: Bool = false
    ) async throws -> AnalystConsensusData {
        guard Self.supports(currency: currency) else {
            throw ScreenFailure.message(L10n.text("暂仅支持美元报价的证券，目标价不与其他币种混用。"))
        }
        let symbol = symbol.uppercased()
        if !forceRefresh, let cached = cached(symbol: symbol) {
            return cached.withCurrentQuote(price, currency: currency)
        }
        let previous = cache[symbol]
        let client = StockScreenDataClient.shared
        let query = ["symbol": symbol]
        var warnings: [String] = []
        var rating: [String: Any] = [:]
        var target: [String: Any] = [:]
        do { rating = try await client.rows("grades-consensus", query: query).first(where: { $0["symbol"] as? String == symbol }) ?? [:] }
        catch { try Task.checkCancellation(); warnings.append(L10n.text("评级：\(error.localizedDescription)")) }
        do { target = try await client.rows("price-target-consensus", query: query).first(where: { $0["symbol"] as? String == symbol }) ?? [:] }
        catch { try Task.checkCancellation(); warnings.append(L10n.text("目标价：\(error.localizedDescription)")) }
        let low = StockScreenDataClient.number(target, "targetLow")
        let mean = StockScreenDataClient.number(target, "targetConsensus")
        let high = StockScreenDataClient.number(target, "targetHigh")
        let valid = AnalystConsensusData.validTargets(low: low, mean: mean, high: high)
        // The holding's own quote, so the current-price marker agrees with the
        // price shown at the top of the same sheet.
        let price = price.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let data = AnalystConsensusData(
            ratings: AnalystConsensusData.ratingCounts(rating).flatMap(RatingSpread.init(fiveBucket:)),
            consensus: rating["consensus"] as? String,
            low: valid ? low : nil, mean: valid ? mean : nil, high: valid ? high : nil,
            current: price, source: "FMP", fetchedAt: Date(), warnings: warnings)
        // Both sub-requests are caught rather than thrown so one missing
        // entitlement cannot hide the other half. But when neither returned
        // anything usable, reporting "暂无数据" would bury the actual cause —
        // a missing key or a 429 reads as if the analysts simply had no view.
        if data.ratings == nil, !valid {
            // FMP gave nothing usable — an exhausted quota, a missing
            // entitlement, or genuinely no coverage. Nasdaq publishes the same
            // two figures without a key, so try there before giving up.
            do {
                let fallback = try await nasdaqData(symbol: symbol, price: price, after: warnings)
                store(fallback, symbol: symbol)
                return fallback
            } catch {
                // A transport/provider error is not confirmation of no coverage.
                if error as? NasdaqAnalystError != .noCoverage { warnings.append(error.localizedDescription) }
            }
            if let reason = warnings.first { throw ScreenFailure.message(reason) }
            if let previous { return previous.withCurrentQuote(price, currency: currency) }
        }
        // Preserve every usable partial snapshot too. A missing target endpoint
        // must not make a valid rating disappear on the next presentation.
        if data.ratings != nil || valid { store(data, symbol: symbol) }
        return data
    }

    private func store(_ data: AnalystConsensusData, symbol: String) {
        cache[symbol.uppercased()] = data
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let encoded = try? JSONEncoder().encode(cache) else { return }
        try? encoded.write(
            to: cacheURL,
            options: [.atomic, .completeFileProtectionUnlessOpen]
        )
    }

    private func nasdaqData(
        symbol: String, price: Double?, after warnings: [String]
    ) async throws -> AnalystConsensusData {
        let consensus = try await NasdaqAnalystClient.shared.consensus(symbol: symbol)
        let valid = AnalystConsensusData.validTargets(
            low: consensus.low, mean: consensus.mean, high: consensus.high
        )
        guard consensus.ratings != nil || valid else { throw NasdaqAnalystError.noCoverage }
        // Nasdaq measures three buckets, not five. The card only ever drew
        // three, so nothing is lost — but the source is named so the numbers
        // are not read as the provider the other cards used.
        return AnalystConsensusData(
            ratings: consensus.ratings,
            consensus: consensus.rating,
            low: valid ? consensus.low : nil,
            mean: valid ? consensus.mean : nil,
            high: valid ? consensus.high : nil,
            current: price,
            source: "Nasdaq",
            fetchedAt: Date(),
            warnings: warnings.isEmpty ? [] : [L10n.text("FMP 未返回数据，已改用 Nasdaq。")]
        )
    }
}

struct AnalystConsensusView: View {
    @Environment(\.locale) private var appLocale
    let symbol: String
    let currency: String?
    let price: Double?
    var showsConsensus = true
    var showsHistoryEntry: Bool? = nil
    var initialData: AnalystConsensusData? = nil
    var onAvailability: (HoldingResearchAvailability) -> Void = { _ in }
    @State private var data: AnalystConsensusData?
    @State private var error: String?
    @State private var loadState = ResearchCardLoadState()
    @State private var isExpanded = false
    @State private var showsHistory = false
    private var loading: Bool { loadState.isLoading }

    /// One line saying what the analysts think, for the collapsed row.
    private var summary: String? {
        guard let data else { return nil }
        var parts: [String] = []
        if let consensus = AnalystConsensusContent.ratingLabel(for: data.consensus) { parts.append(consensus) }
        if data.total > 0 { parts.append(L10n.text("\(data.total) 份评级")) }
        if let mean = data.mean, mean.isFinite {
            parts.append(L10n.text("均价 ") + DisplayFormat.money(mean, currency: "USD"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var subtitle: String {
        if let error { return error }
        if let summary { return summary }
        guard AnalystConsensusClient.supports(currency: currency) else {
            return L10n.text("暂仅支持美元报价的证券，目标价不与其他币种混用。")
        }
        return L10n.text("评级、目标价与分析师覆盖 · 按需读取")
    }

    var body: some View {
        VStack(spacing: HoldingDetailCardStyle.spacing) {
            if showsConsensus { consensusRow }
            if showsHistoryEntry ?? Self.hasHistory(symbol: symbol) {
                Button { showsHistory = true } label: {
                    HoldingDetailActionCardLabel(
                        title: L10n.text("分析师历史回顾"),
                        subtitle: L10n.text("目标价、推荐建议与股价 · 本地快照")
                    )
                }.buttonStyle(.plain)
                .accessibilityIdentifier("analyst-history-entry")
                .appSheet(isPresented: $showsHistory) {
                    NavigationStack { AnalystHistoryView(symbol: symbol) }
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }

    static func hasHistory(symbol: String) -> Bool {
        AnalystHistorySnapshot.load(symbol: symbol)?.points.contains {
            $0.validTargets || ($0.hasRatings && $0.counts.reduce(0, +) > 0)
        } == true
    }

    /// Opens in place on the holding page; there is no analyst sheet. Same
    /// title size, secondary line and glass as the Financial row beside it.
    private var consensusRow: some View {
        HoldingDetailDisclosureCard(
            title: L10n.text("分析师一致预期"),
            subtitle: subtitle,
            isExpanded: $isExpanded,
            isLoading: loading,
            isEnabled: AnalystConsensusClient.supports(currency: currency)
        ) {
            expandedContent
        }
        .accessibilityHint(data == nil ? L10n.text("读取并查看分析师评级与目标价") : L10n.text("查看分析师评级与目标价"))
        // Appearing costs nothing. Every holding detail firing a request as it
        // opened spent the page's shared FMP budget on a card most visits
        // never look at, and scrolling past a holding spent it too.
        .task(id: symbol) {
            let revision = loadState.revision
            let cached: AnalystConsensusData?
            if let initialData { cached = initialData }
            else { cached = await AnalystConsensusClient.shared.cached(symbol: symbol.uppercased()) }
            guard loadState.canPublish(revision) else { return }
            data = cached
            if let data { onAvailability(data.hasContent ? .available : .empty) }
        }
        // Opening the card is the request.
        .task(id: "\(symbol)|\(isExpanded)") {
            guard isExpanded, data == nil else { return }
            await load()
        }
    }

    @ViewBuilder private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let data {
                AnalystConsensusContent(data: data.withCurrentQuote(price, currency: currency))
                    .onAppear { ChartAppearanceHistory.record("analyst-consensus|\(symbol)") }
                if let error {
                    Text(L10n.message(error)).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button { Task { await load(forceRefresh: true) } } label: {
                        Text(L10n.text("刷新"))
                            .redacted(reason: loading ? .placeholder : [])
                            .chartLoadingShimmer(active: loading)
                            .font(.caption).frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(loading)
                }
            } else if loading {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { ChartSkeletonShape(width: 85, height: 20); Spacer(); ChartSkeletonShape(width: 55, height: 14) }
                    ChartSkeletonShape(height: 24, cornerRadius: 8)
                    HStack { ChartSkeletonShape(width: 65); Spacer(); ChartSkeletonShape(width: 65); Spacer(); ChartSkeletonShape(width: 65) }
                    ChartSkeletonShape(height: 8)
                }
                .frame(minHeight: 120)
                .chartLoadingShimmer(appearanceID: "analyst-consensus|\(symbol)")
            } else {
                Text(error ?? L10n.text("暂无完整评级分布"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    @MainActor @discardableResult
    private func load(forceRefresh: Bool = false) async -> AnalystConsensusData? {
        guard !Task.isCancelled else { return data }
        error = nil
        await loadState.load {
            try await AnalystConsensusClient.shared.load(
                symbol: symbol.uppercased(),
                currency: currency,
                price: price,
                forceRefresh: forceRefresh
            )
        } fallback: {
            if let data { return data }
            return await AnalystConsensusClient.shared.cached(symbol: symbol.uppercased())
        } onSuccess: { loaded in
            data = loaded
            onAvailability(loaded.hasContent ? .available : .empty)
        } onFailure: { failure, cached in
            error = failure.localizedDescription
            // A failed manual refresh never erases the last usable snapshot.
            if data == nil { data = cached }
            onAvailability(data?.hasContent == true ? .available : .failed)
        }
        return data
    }

}

struct AnalystConsensusContent: View {
    @Environment(\.locale) private var appLocale
    let data: AnalystConsensusData

    /// Returns nil for a consensus the provider did not give, so the caller
    /// can leave it out of a summary line rather than print a placeholder.
    static func ratingLabel(for consensus: String?) -> String? {
        switch consensus?.lowercased() {
        case "strong buy", "strongbuy": L10n.text("强烈买入")
        case "buy": L10n.text("买入")
        case "hold", "neutral": L10n.text("中性")
        case "sell": L10n.text("卖出")
        case "strong sell", "strongsell": L10n.text("强烈卖出")
        default: nil
        }
    }

    private var ratingLabel: String {
        Self.ratingLabel(for: data.consensus) ?? L10n.text("评级分布")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let ratings = data.ratings, data.total > 0 {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        ratingBadge
                        Spacer(minLength: 12)
                        ratingCount
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ratingBadge
                        ratingCount
                    }
                }
                let totals = [ratings.bearish, ratings.neutral, ratings.bullish]
                ViewThatFits(in: .horizontal) {
                    HStack {
                        rating(totals[0], index: 0)
                        Spacer()
                        rating(totals[1], index: 1)
                        Spacer()
                        rating(totals[2], index: 2)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        rating(totals[0], index: 0)
                        rating(totals[1], index: 1)
                        rating(totals[2], index: 2)
                    }
                }.appNumber(.callout)
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(0..<3) { index in
                            [Color.red, Color.gray, Color.green][index]
                                .frame(width: geo.size.width * Double(totals[index]) / Double(data.total))
                        }
                    }.clipShape(Capsule())
                }.frame(height: 7).accessibilityHidden(true)
            } else { Text(L10n.text("暂无完整评级分布")).foregroundStyle(.secondary) }
            if let low = data.low, let mean = data.mean, let high = data.high {
                AnalystMetricsLayout {
                    metrics(low: low, mean: mean, high: high)
                }
                AnalystTargetBar(low: low, mean: mean, high: high, current: data.current)
            } else { Text(L10n.text("暂无可核验的目标价区间")).foregroundStyle(.secondary) }
            Text(L10n.text("\(data.source) · 读取于 \(data.fetchedAt.formatted(date: .abbreviated, time: .shortened))"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .researchLayoutFrame("analyst.source")
        }
    }
    private var ratingBadge: some View {
        Text(ratingLabel).font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: true, vertical: false)
            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var ratingCount: some View {
        Text(L10n.text("\(data.total) 份评级")).font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func rating(_ count: Int, index: Int) -> some View {
        let title = index == 0 ? L10n.text("\(count) 看跌")
            : index == 1 ? L10n.text("\(count) 中性") : L10n.text("\(count) 看涨")
        return Text(title)
            .foregroundStyle(index == 0 ? Color.red : index == 1 ? Color.secondary : Color.green)
            .fixedSize(horizontal: true, vertical: false)
            .researchLayoutFrame("analyst.rating.\(index == 0 ? "bearish" : index == 1 ? "neutral" : "bullish")")
    }

    @ViewBuilder private func metrics(low: Double, mean: Double, high: Double) -> some View {
        metric(L10n.text("最低目标"), value: low, marker: .range)
        metric(L10n.text("当前报价"), value: data.current, marker: .current)
        metric(L10n.text("平均目标"), value: mean, marker: .mean)
        metric(L10n.text("最高目标"), value: high, marker: .range)
    }
    private func metric(_ title: String, value: Double?, marker: AnalystTargetBar.Marker) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.map { $0.formatted(.currency(code: "USD")) } ?? "—").appNumber(.callout, weight: .semibold)
                .lineLimit(1).minimumScaleFactor(0.8)
                .researchLayoutFrame("analyst.value.\(title)")
            // The round legend is the mark this figure has on the line below.
            HStack(spacing: 5) {
                AnalystTargetBar.legend(marker)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Four metrics keep their existing row or equal-width two-column arrangement
/// while they fit. Their measured text selects a single column when necessary.
private struct AnalystMetricsLayout: Layout {
    private struct Plan {
        let columns: Int
        let widths: [CGFloat]
        let rowHeights: [CGFloat]
        let spacing: CGFloat
        let width: CGFloat
        var height: CGFloat { rowHeights.reduce(0, +) + CGFloat(max(0, rowHeights.count - 1)) * 16 }
    }

    private func plan(proposal: ProposedViewSize, subviews: Subviews) -> Plan {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let rowWidth = ideal.reduce(0, +) + CGFloat(max(0, ideal.count - 1)) * 18
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? rowWidth
        let columns = rowWidth <= width ? max(1, ideal.count)
            : (ideal.max() ?? 0) * 2 + 16 <= width ? 2 : 1
        let spacing: CGFloat = columns > 2 ? 18 : 16
        let widths = columns > 2 ? ideal
            : Array(repeating: max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)), count: columns)
        var heights: [CGFloat] = []
        for index in subviews.indices {
            let row = index / columns
            if heights.count <= row { heights.append(0) }
            heights[row] = max(heights[row], subviews[index].sizeThatFits(
                .init(width: widths[index % columns], height: nil)).height)
        }
        return Plan(columns: columns, widths: widths, rowHeights: heights, spacing: spacing, width: width)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = plan(proposal: proposal, subviews: subviews)
        return CGSize(width: layout.width, height: layout.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = plan(proposal: .init(width: bounds.width, height: nil), subviews: subviews)
        for index in subviews.indices {
            let column = index % layout.columns
            let row = index / layout.columns
            let x = layout.widths.prefix(column).reduce(0, +) + CGFloat(column) * layout.spacing
            let y = layout.rowHeights.prefix(row).reduce(0, +) + CGFloat(row) * 16
            subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), anchor: .topLeading,
                                 proposal: .init(width: layout.widths[column], height: layout.rowHeights[row]))
        }
    }
}

/// The home list's 52-week bar, laid on its side: a grey track, the targets'
/// span from lowest to highest in blue, the current quote as the dark dot
/// and the mean target as the white one.
struct AnalystTargetBar: View {
    enum Marker { case range, current, mean }

    let low: Double
    let mean: Double
    let high: Double
    let current: Double?

    static let rangeColor = Color(red: 52 / 255, green: 117 / 255, blue: 1)
    private static let height: CGFloat = 8

    var body: some View {
        let minimum = min(low, current ?? low)
        let maximum = max(high, current ?? high)
        func x(_ value: Double, in width: CGFloat) -> CGFloat {
            CGFloat(AnalystConsensusData.position(value, low: minimum, high: maximum)) * max(0, width - Self.height)
        }
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(CatfolioTheme.primaryText.opacity(0.10))
                let start = x(low, in: width), end = x(high, in: width)
                Capsule().fill(Self.rangeColor)
                    .frame(width: end - start + Self.height)
                    .offset(x: start)
                Circle().fill(.white)
                    .frame(width: 4, height: 4)
                    .offset(x: x(mean, in: width) + 2)
                if let current {
                    Circle().fill(CatfolioPalette.blue900)
                        .frame(width: 6, height: 6)
                        .offset(x: x(current, in: width) + 1)
                }
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    /// The entry's mark, at legend size.
    @ViewBuilder static func legend(_ marker: Marker) -> some View {
        switch marker {
        case .range:
            Circle().fill(rangeColor).frame(width: 8, height: 8)
        case .current:
            Circle().fill(CatfolioPalette.blue900).frame(width: 8, height: 8)
        case .mean:
            Circle().fill(.white)
                .overlay(Circle().strokeBorder(rangeColor, lineWidth: 2))
                .frame(width: 8, height: 8)
        }
    }
}
