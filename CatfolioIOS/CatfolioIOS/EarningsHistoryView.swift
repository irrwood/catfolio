import SwiftUI

/// Folded until tapped. Appearing reads only the local cache, to know whether
/// there is anything to offer; opening the card is what spends a request.
struct EarningsHistoryView: View {
    let symbol: String
    private let onAvailability: (HoldingResearchAvailability) -> Void

    init(symbol: String, initialSnapshot: EarningsSnapshot? = nil, initialRevenue: Bool = false,
         initiallyExpanded: Bool = false,
         onAvailability: @escaping (HoldingResearchAvailability) -> Void = { _ in }) {
        self.symbol = symbol
        self.onAvailability = onAvailability
        _snapshot = State(initialValue: initialSnapshot)
        _revenue = State(initialValue: initialRevenue)
        _isExpanded = State(initialValue: initiallyExpanded)
    }
    @State private var revenue = false
    @State private var snapshot: EarningsSnapshot?
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var isExpanded: Bool
    @State private var hasLoaded = false

    private var points: [EarningsObservation] {
        Array((snapshot?.observations ?? []).filter {
            let values = $0.values(revenue: revenue)
            return values.actual != nil || values.estimate != nil
        }.suffix(16))
    }

    var body: some View {
        Group {
            if snapshot?.hasUsableObservations != false {
                HoldingDetailDisclosureCard(
                    title: L10n.text("盈利历史"),
                    subtitle: L10n.text("每股收益与收入 · 实际对比预期"),
                    isExpanded: $isExpanded,
                    isLoading: loading
                ) {
                    content
                }
                .accessibilityIdentifier("earnings-history")
            }
        }
        .task(id: symbol) {
            if snapshot == nil { snapshot = await EarningsHistoryClient.shared.cached(symbol: symbol) }
            if let snapshot { onAvailability(snapshot.hasUsableObservations ? .available : .empty) }
        }
        // Once per visit: the client answers from its day-old cache when it
        // can, and the refresh button below is there for anything newer.
        .task(id: "\(symbol)|\(isExpanded)") {
            guard isExpanded, !hasLoaded else { return }
            await load(force: false)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            selector
            VStack(alignment: .leading, spacing: 18) {
                legend
                if !points.isEmpty {
                    GeometryReader { geometry in
                        ScrollView(.horizontal, showsIndicators: false) {
                            chart.frame(width: max(geometry.size.width, CGFloat(points.count) * 44))
                        }
                    }
                    .frame(height: 222)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    Text(errorMessage ?? L10n.text(revenue ? "暂无收入数据" : "暂无盈利历史。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
                HStack {
                    Spacer()
                    Button { Task { await load(force: true) } } label: {
                        Text(L10n.text(loading ? "加载中…" : "刷新"))
                            .font(.caption).frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(loading)
                }
            }
        }
    }

    private var selector: some View {
        Picker(L10n.text("盈利历史指标"), selection: $revenue) {
            Text(L10n.text("每股收益")).tag(false)
            Text(L10n.text("收入")).tag(true)
        }.pickerStyle(.segmented)
    }

    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { legendItems }
            VStack(alignment: .leading, spacing: 8) { legendItems }
        }
    }

    @ViewBuilder private var legendItems: some View {
        legendItem("估计", color: .secondary, hollow: true)
        legendItem("超出预期", color: CatfolioStyle.green)
        legendItem("未达到预期", color: CatfolioStyle.red)
        legendItem("匹配", color: .secondary)
    }

    private func legendItem(_ title: String, color: Color, hollow: Bool = false) -> some View {
        HStack(spacing: 4) {
            Circle().fill(hollow ? Color(uiColor: .systemBackground) : color)
                .overlay { Circle().stroke(color, lineWidth: hollow ? 1.3 : 0) }
                .frame(width: 7, height: 7)
            Text(L10n.label(title)).font(.system(size: 10)).foregroundStyle(.secondary)
        }.fixedSize()
    }

    private func color(_ values: (actual: Double?, estimate: Double?)) -> Color {
        guard let actual = values.actual, let estimate = values.estimate else { return .secondary }
        if abs(actual - estimate) <= max(1, abs(estimate)) * 1e-9 { return .secondary }
        return actual > estimate ? CatfolioStyle.green : CatfolioStyle.red
    }

    private var chart: some View {
        let all = points.flatMap { point -> [Double] in
            let value = point.values(revenue: revenue)
            return [value.actual, value.estimate].compactMap { $0 }
        }
        let low = all.min() ?? 0
        let high = all.max() ?? 1
        let span = max(high - low, max(abs(high), 1) * 0.1)
        let lower = low - span * 0.3
        let upper = high + span * 0.3
        return VStack(spacing: 20) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    ForEach(points) { point in
                        let values = point.values(revenue: revenue)
                        let height = geometry.size.height
                        let actualY = CGFloat((upper - (values.actual ?? values.estimate ?? 0)) / (upper - lower)) * height
                        let estimateY = CGFloat((upper - (values.estimate ?? values.actual ?? 0)) / (upper - lower)) * height
                        GeometryReader { cell in
                                let x = cell.size.width / 2
                                if values.actual != nil && values.estimate != nil {
                                    Path { path in
                                        path.move(to: CGPoint(x: x, y: actualY))
                                        path.addLine(to: CGPoint(x: x, y: estimateY))
                                    }.stroke(Color.secondary.opacity(0.65), lineWidth: 1)
                                }
                                if values.estimate != nil {
                                    Circle().fill(Color(uiColor: .systemBackground))
                                        .overlay { Circle().stroke(Color.secondary, lineWidth: 1.4) }
                                        .frame(width: 9, height: 9).position(x: x, y: estimateY)
                                }
                                if values.actual != nil {
                                    Circle().fill(color(values))
                                        .overlay { Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 0.7) }
                                        .frame(width: 9, height: 9).position(x: x, y: actualY)
                                }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibleLabel(point))
                    }
                }
            }.frame(height: 190)
            HStack(spacing: 0) {
                ForEach(points) { point in
                    Color.clear.frame(height: 12).overlay {
                        Text(point.quarterLabel)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }.accessibilityHidden(true)
        }
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else { return "—" }
        // Revenue goes through the shared ladder. `.localised` keeps what this
        // already showed — 万 and 亿 under zh-Hans — rather than switching the
        // convention as a side effect of routing it; whether the app should say
        // 亿 anywhere is the open question in DESIGN.md.
        return revenue
            ? DisplayFormat.compact(value, precision: .statement)
            : value.formatted(.number.precision(.fractionLength(2...3)))
    }

    private func accessibleLabel(_ point: EarningsObservation) -> String {
        let values = point.values(revenue: revenue)
        return "\(point.date), \(L10n.text("估计")) \(formatted(values.estimate)), \(L10n.text("实际")) \(formatted(values.actual))"
    }

    @MainActor private func load(force: Bool) async {
        // No `guard !loading`: folding and reopening restarts the task, and
        // bailing out while the superseded run unwound left an empty chart.
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            let value = try await EarningsHistoryClient.shared.load(symbol: symbol, forceRefresh: force)
            try Task.checkCancellation()
            snapshot = value
            hasLoaded = true
            onAvailability(value.hasUsableObservations ? .available : .empty)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            // Keep the chart and cached values when a refresh fails.
            onAvailability(snapshot?.hasUsableObservations == true ? .available : .failed)
        }
    }
}
