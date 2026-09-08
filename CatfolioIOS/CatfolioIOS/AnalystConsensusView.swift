import SwiftUI

struct AnalystConsensusData {
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

    /// What is already in hand, if it is still fresh. Costs no request, so a
    /// holding visited twice in an hour shows its card straight away.
    func cached(symbol: String) -> AnalystConsensusData? {
        guard let cached = cache[symbol],
              Date().timeIntervalSince(cached.fetchedAt) < 3600 else { return nil }
        return cached
    }

    func load(symbol: String, currency: String?, price: Double?) async throws -> AnalystConsensusData {
        guard Self.supports(currency: currency) else {
            throw ScreenFailure.message("暂仅支持美元报价的证券，目标价不与其他币种混用。")
        }
        if let cached = cached(symbol: symbol) { return cached }
        let client = StockScreenDataClient.shared
        let query = ["symbol": symbol]
        var warnings: [String] = []
        var rating: [String: Any] = [:]
        var target: [String: Any] = [:]
        do { rating = try await client.rows("grades-consensus", query: query).first(where: { $0["symbol"] as? String == symbol }) ?? [:] }
        catch { try Task.checkCancellation(); warnings.append("评级：\(error.localizedDescription)") }
        do { target = try await client.rows("price-target-consensus", query: query).first(where: { $0["symbol"] as? String == symbol }) ?? [:] }
        catch { try Task.checkCancellation(); warnings.append("目标价：\(error.localizedDescription)") }
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
            if let fallback = try? await nasdaqData(symbol: symbol, price: price, after: warnings) {
                cache[symbol] = fallback
                return fallback
            }
            if let reason = warnings.first { throw ScreenFailure.message(reason) }
        }
        // Do not cache entitlement failures or empty responses as valid data.
        if warnings.isEmpty && data.ratings != nil && valid { cache[symbol] = data }
        return data
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
            warnings: warnings.isEmpty ? [] : ["FMP 未返回数据，已改用 Nasdaq。"]
        )
    }
}

struct AnalystConsensusView: View {
    let symbol: String
    let currency: String?
    let price: Double?
    @State private var data: AnalystConsensusData?
    @State private var error: String?
    @State private var loading = false
    @Namespace private var zoom

    /// One line saying what the analysts think, for the collapsed row.
    private var summary: String? {
        guard let data else { return nil }
        var parts: [String] = []
        if let consensus = AnalystConsensusContent.ratingLabel(for: data.consensus) { parts.append(consensus) }
        if data.total > 0 { parts.append("\(data.total) 份评级") }
        if let mean = data.mean, mean.isFinite {
            parts.append("均价 " + DisplayFormat.money(mean, currency: "USD"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var subtitle: String {
        if let error { return error }
        if let summary { return summary }
        guard AnalystConsensusClient.supports(currency: currency) else {
            return "暂仅支持美元报价的证券，目标价不与其他币种混用。"
        }
        return "评级、目标价与分析师覆盖 · 按需读取"
    }

    var body: some View {
        Group {
            if let data {
                NavigationLink {
                    AnalystConsensusDetails(data: data, symbol: symbol)
                        .navigationTransition(.zoom(sourceID: symbol, in: zoom))
                } label: { card }
                .buttonStyle(.plain)
                .matchedTransitionSource(id: symbol, in: zoom)
                .accessibilityHint("查看分析师评级与目标价")
            } else {
                Button { Task { await load() } } label: { card }
                    .buttonStyle(.plain)
                    .disabled(loading || !AnalystConsensusClient.supports(currency: currency))
                    .accessibilityHint("读取分析师评级与目标价")
            }
        }
        // Appearing costs nothing. Every holding detail firing a request as it
        // opened spent the page's shared FMP budget on a card most visits
        // never look at, and scrolling past a holding spent it too.
        .task(id: symbol) {
            data = await AnalystConsensusClient.shared.cached(symbol: symbol.uppercased())
        }
    }

    /// Deliberately the same shape as the Financial row beside it: same
    /// title size, same secondary line, same chevron, same glass. Two rows
    /// offering the same thing should not look like two different features.
    private var card: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("分析师一致预期")
                    .appText(.subheading, weight: .medium)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .appText(.label, weight: .medium)
                    .foregroundStyle(.primary.opacity(0.50))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 237, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 0)

            if loading {
                ProgressView().controlSize(.small).frame(width: 12, height: 24)
            } else if data != nil || AnalystConsensusClient.supports(currency: currency) {
                Image(systemName: data == nil ? "arrow.down.circle" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 24)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .holdingDetailGlassCard()
    }

    @MainActor private func load() async {
        // No `guard !loading` here. `.task(id:)` restarts this on re-entry, and
        // bailing out because a superseded run had not finished unwinding left
        // the card with no data, no error and no spinner — a blank box.
        loading = true
        error = nil
        defer { loading = false }
        do {
            let loaded = try await AnalystConsensusClient.shared.load(
                symbol: symbol.uppercased(), currency: currency, price: price
            )
            try Task.checkCancellation()
            data = loaded
        } catch is CancellationError {
            // Superseded by a newer load; keep whatever is already on screen.
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            data = nil
        }
    }
}

private struct AnalystConsensusContent: View {
    let data: AnalystConsensusData

    /// Returns nil for a consensus the provider did not give, so the caller
    /// can leave it out of a summary line rather than print a placeholder.
    static func ratingLabel(for consensus: String?) -> String? {
        switch consensus?.lowercased() {
        case "strong buy", "strongbuy": "强烈买入"
        case "buy": "买入"
        case "hold", "neutral": "中性"
        case "sell": "卖出"
        case "strong sell", "strongsell": "强烈卖出"
        default: nil
        }
    }

    private var ratingLabel: String {
        Self.ratingLabel(for: data.consensus) ?? "评级分布"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let ratings = data.ratings, data.total > 0 {
                HStack {
                    Text(ratingLabel).font(.subheadline.weight(.semibold))
                        .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Text("\(data.total) 份评级").font(.subheadline).foregroundStyle(.secondary)
                }
                let totals = [ratings.bearish, ratings.neutral, ratings.bullish]
                HStack {
                    Text("\(totals[0]) 看跌").foregroundStyle(.red)
                    Spacer(); Text("\(totals[1]) 中性").foregroundStyle(.secondary)
                    Spacer(); Text("\(totals[2]) 看涨").foregroundStyle(.green)
                }.appNumber(.callout)
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(0..<3) { index in
                            [Color.red, Color.gray, Color.green][index]
                                .frame(width: geo.size.width * Double(totals[index]) / Double(data.total))
                        }
                    }.clipShape(Capsule())
                }.frame(height: 7).accessibilityHidden(true)
            } else { Text("暂无完整评级分布").foregroundStyle(.secondary) }
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
            } else { Text("暂无可核验的目标价区间").foregroundStyle(.secondary) }
            Text("\(data.source) · 读取于 \(data.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func metrics(low: Double, mean: Double, high: Double) -> some View {
        metric("最低目标", value: low)
        metric("当前报价", value: data.current)
        metric("平均目标", value: mean)
        metric("最高目标", value: high)
    }
    private func metric(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.map { $0.formatted(.currency(code: "USD")) } ?? "—").appNumber(.callout, weight: .semibold)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AnalystConsensusDetails: View {
    let data: AnalystConsensusData
    let symbol: String
    var body: some View {
        List {
            Section { AnalystConsensusContent(data: data) }
            if let ratings = data.ratings {
                // Three buckets, not five: Nasdaq does not distinguish
                // strong from ordinary, and showing it as "强烈买入 0" would
                // be an invented number rather than a missing one.
                Section("评级细分") {
                    LabeledContent("看跌", value: "\(ratings.bearish)")
                    LabeledContent("中性", value: "\(ratings.neutral)")
                    LabeledContent("看涨", value: "\(ratings.bullish)")
                    LabeledContent("合计", value: "\(ratings.total)")
                }
            }
            Section("数据口径") {
                Text("来源为 FMP 覆盖的评级样本，不代表所有分析师；评级与目标价来自不同汇总接口，样本数不可混用。")
                Text("全部金额为美元。现价取同一证券的 FMP 可用报价，可能延迟；读取时间不是评级发布日期。接口未提供统一报告日期或逐位分析师名单。")
                Text("目标价是分析师观点，不是收益承诺或 Catfolio 的买卖建议。")
                ForEach(data.warnings, id: \.self) { Text($0).foregroundStyle(.secondary) }
                Link("FMP 目标价数据说明", destination: URL(string: "https://site.financialmodelingprep.com/developer/docs/stable/price-target-consensus")!)
            }.font(.subheadline)
        }
        .navigationTitle("\(symbol) · 分析师")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
    }
}
