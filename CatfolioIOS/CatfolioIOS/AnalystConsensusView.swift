import SwiftUI

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
        if !forceRefresh, let cached = cached(symbol: symbol) { return cached }
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
            if let previous { return previous }
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
    @State private var loading = false
    @State private var isExpanded = false
    @State private var showsHistory = false

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
                .sheet(isPresented: $showsHistory) {
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
            if let initialData { data = initialData }
            else { data = await AnalystConsensusClient.shared.cached(symbol: symbol.uppercased()) }
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
                AnalystConsensusContent(data: data)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button { Task { await load(forceRefresh: true) } } label: {
                        Text(L10n.text(loading ? "加载中…" : "刷新"))
                            .font(.caption).frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(loading)
                }
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                Text(error ?? L10n.text("暂无完整评级分布"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    @MainActor @discardableResult
    private func load(forceRefresh: Bool = false) async -> AnalystConsensusData? {
        // No `guard !loading` here. `.task(id:)` restarts this on re-entry, and
        // bailing out because a superseded run had not finished unwinding left
        // the card with no data, no error and no spinner — a blank box.
        loading = true
        error = nil
        defer { loading = false }
        do {
            let loaded = try await AnalystConsensusClient.shared.load(
                symbol: symbol.uppercased(),
                currency: currency,
                price: price,
                forceRefresh: forceRefresh
            )
            try Task.checkCancellation()
            data = loaded
            onAvailability(loaded.hasContent ? .available : .empty)
            return loaded
        } catch is CancellationError {
            // Superseded by a newer load; keep whatever is already on screen.
            return data
        } catch {
            guard !Task.isCancelled else { return data }
            self.error = error.localizedDescription
            // A failed manual refresh never erases the last usable snapshot.
            if data == nil {
                data = await AnalystConsensusClient.shared.cached(symbol: symbol.uppercased())
            }
            onAvailability(data?.hasContent == true ? .available : .failed)
            return data
        }
    }

}

private struct AnalystConsensusContent: View {
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
                HStack {
                    Text(ratingLabel).font(.subheadline.weight(.semibold))
                        .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Text(L10n.text("\(data.total) 份评级")).font(.subheadline).foregroundStyle(.secondary)
                }
                let totals = [ratings.bearish, ratings.neutral, ratings.bullish]
                HStack {
                    Text(L10n.text("\(totals[0]) 看跌")).foregroundStyle(.red)
                    Spacer(); Text(L10n.text("\(totals[1]) 中性")).foregroundStyle(.secondary)
                    Spacer(); Text(L10n.text("\(totals[2]) 看涨")).foregroundStyle(.green)
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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) { metrics(low: low, mean: mean, high: high) }.fixedSize(horizontal: true, vertical: false)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 16) { metrics(low: low, mean: mean, high: high) }
                }
                let minimum = min(low, data.current ?? low)
                let maximum = max(high, data.current ?? high)
                GeometryReader { geo in
                    let width = max(0, geo.size.width - 18)
                    Capsule().fill(.quaternary).frame(height: 6).offset(y: 8)
                    ForEach(Array([low, mean, high].enumerated()), id: \.offset) { item in
                        Circle().fill(item.offset == 1 ? Color.blue : Color.secondary)
                            .frame(width: 10, height: 10)
                            .offset(x: 4 + width * AnalystConsensusData.position(item.element, low: minimum, high: maximum), y: 6)
                    }
                    if let current = data.current {
                        Circle().fill(Color(uiColor: .systemBackground))
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: 3))
                            .frame(width: 18, height: 18)
                            .offset(x: width * AnalystConsensusData.position(current, low: minimum, high: maximum), y: 2)
                    }
                }.frame(height: 22).accessibilityHidden(true)
            } else { Text(L10n.text("暂无可核验的目标价区间")).foregroundStyle(.secondary) }
            Text(L10n.text("\(data.source) · 读取于 \(data.fetchedAt.formatted(date: .abbreviated, time: .shortened))"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func metrics(low: Double, mean: Double, high: Double) -> some View {
        metric(L10n.text("最低目标"), value: low)
        metric(L10n.text("当前报价"), value: data.current)
        metric(L10n.text("平均目标"), value: mean)
        metric(L10n.text("最高目标"), value: high)
    }
    private func metric(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.map { $0.formatted(.currency(code: "USD")) } ?? "—").appNumber(.callout, weight: .semibold)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
