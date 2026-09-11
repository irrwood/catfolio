import SwiftUI

struct HoldingsHeatmapView: View {
    @Environment(\.locale) private var appLocale
    static let maximumLookThroughTiles = 28
    static let maximumGroupedConstituentTiles = 36
    static let minimumGroupedConstituentFraction = 0.0025

    let holdings: [Holding]
    let dailyChanges: [String: Double]
    let isLoading: Bool
    let performancePeriod: HoldingPerformancePeriod
    let groupsBySector: Bool
    let usesETFLookThrough: Bool
    let lookThroughRows: [ETFLookThroughRow]?
    let lookThroughDailyChanges: [String: Double]
    let onSelect: (Holding) -> Void

    private let maximumHoldingTiles = 20
    private let minimumIndividualFraction = 0.008
    private let groupedScreenInset: CGFloat = 16
    private let heatmapHeight: CGFloat = 700

    var body: some View {
        let sectorGroups = groupsBySector ? makeSectorGroups() : []
        let models = groupsBySector ? sectorGroups.flatMap(\.models) : makeModels()

        VStack(alignment: .leading, spacing: 12) {
            if models.isEmpty {
                ContentUnavailableView(
                    L10n.text("暂无持仓"),
                    systemImage: "square.grid.3x3",
                    description: Text(L10n.text("同步持仓后会在这里显示资产分布。"))
                )
                .frame(minHeight: 260)
            } else {
                Group {
                    if groupsBySector {
                        GroupedHoldingsHeatmap(
                            groups: sectorGroups
                        )
                    } else {
                        HoldingsHeatmapTileCloud(models: models, onSelect: select)
                    }
                }
                .frame(height: heatmapHeight)
                .padding(
                    .horizontal,
                    groupsBySector
                        ? groupedScreenInset - CatfolioStyle.pageHorizontalInset
                        : 0
                )
                .transaction { transaction in transaction.animation = nil }
                .overlay {
                    if isLoading {
                        ProgressView()
                            .controlSize(.regular)
                            .padding(12)
                            .background(.thinMaterial, in: Circle())
                    }
                }

                if usesETFLookThrough, performancePeriod == .holdingPeriod {
                    Text(L10n.text("≈ 按当前成分权重分摊 ETF 成本与市值，并合并直接持仓；不代表成分股自身的历史收益。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func makeModels() -> [HoldingsHeatmapTile.Model] {
        if usesETFLookThrough, let lookThroughRows {
            return makeLookThroughModels(from: lookThroughRows)
        }
        return makeHoldingModels()
    }

    private func makeHoldingModels(collapsesRemainder: Bool = true) -> [HoldingsHeatmapTile.Model] {
        let valid = holdings
            .filter { $0.marketValue.isFinite && $0.marketValue > 0 }
            .sorted {
                if $0.marketValue == $1.marketValue {
                    $0.ticker.localizedStandardCompare($1.ticker) == .orderedAscending
                } else {
                    $0.marketValue > $1.marketValue
                }
            }
        let total = valid.reduce(0) { $0 + $1.marketValue }
        guard total.isFinite, total > 0 else { return [] }

        let visible = collapsesRemainder ? Array(
            valid.enumerated()
                .filter { index, holding in
                    index < 4 || holding.marketValue / total >= minimumIndividualFraction
                }
                .prefix(maximumHoldingTiles)
                .map(\.element)
        ) : valid
        let visibleTickers = Set(visible.map(\.ticker))
        let remainder = valid.filter { !visibleTickers.contains($0.ticker) }

        var models = visible.map { holding in
            HoldingsHeatmapTile.Model(
                id: holding.ticker,
                content: .holding(holding),
                marketValue: holding.marketValue,
                portfolioFraction: holding.marketValue / total,
                changePercent: changePercent(for: holding),
                performanceTitle: performancePeriod.title,
                performancePeriod: performancePeriod
            )
        }
        let remainderValue = remainder.reduce(0) { $0 + $1.marketValue }
        if remainderValue > 0 {
            models.append(
                HoldingsHeatmapTile.Model.remainder(id: "__remainder__", items: remainder.map { holding in
                    HoldingsHeatmapTile.Model(
                        id: holding.ticker, content: .holding(holding), marketValue: holding.marketValue,
                        portfolioFraction: holding.marketValue / total,
                        changePercent: changePercent(for: holding), performanceTitle: performancePeriod.title,
                        performancePeriod: performancePeriod
                    )
                })
            )
        }
        return models
    }

    private func makeLookThroughModels(
        from rows: [ETFLookThroughRow]
    ) -> [HoldingsHeatmapTile.Model] {
        let valid = rows
            .filter { $0.totalUSD.isFinite && $0.totalUSD > 0 }
            .sorted {
                if $0.totalUSD == $1.totalUSD {
                    return $0.ticker.localizedStandardCompare($1.ticker) == .orderedAscending
                }
                return $0.totalUSD > $1.totalUSD
            }
        let total = valid.reduce(0) { $0 + $1.totalUSD }
        guard total.isFinite, total > 0 else { return [] }

        let visible = Array(valid.prefix(Self.maximumLookThroughTiles))
        let visibleTickers = Set(visible.map { $0.ticker.uppercased() })
        let remainder = valid.filter { !visibleTickers.contains($0.ticker.uppercased()) }

        var models = visible.map { lookThroughModel(for: $0, portfolioTotal: total) }
        let remainderValue = remainder.reduce(0) { $0 + $1.totalUSD }
        if remainderValue > 0 {
            models.append(
                HoldingsHeatmapTile.Model.remainder(
                    id: "__look_through_remainder__",
                    items: remainder.map { lookThroughModel(for: $0, portfolioTotal: total) }
                )
            )
        }
        return models
    }

    private func makeSectorGroups() -> [HoldingsHeatmapSectorGroup] {
        if usesETFLookThrough, let lookThroughRows {
            return makeLookThroughSectorGroups(from: lookThroughRows)
        }
        return makeSectorGroups(from: makeHoldingModels(collapsesRemainder: false))
    }

    private func makeLookThroughSectorGroups(
        from rows: [ETFLookThroughRow]
    ) -> [HoldingsHeatmapSectorGroup] {
        let valid = rows.filter { $0.totalUSD.isFinite && $0.totalUSD > 0 }
        let portfolioTotal = valid.reduce(0) { $0 + $1.totalUSD }
        guard portfolioTotal.isFinite, portfolioTotal > 0 else { return [] }

        return Dictionary(grouping: valid) { row in
            sectorTitle(for: row, directHolding: holding(for: row.ticker))
        }
        .map { title, rows in
            let sortedRows = rows.sorted {
                if $0.totalUSD == $1.totalUSD {
                    return $0.ticker.localizedStandardCompare($1.ticker) == .orderedAscending
                }
                return $0.totalUSD > $1.totalUSD
            }
            let sectorValue = sortedRows.reduce(0) { $0 + $1.totalUSD }
            let detailedCount = sortedRows.prefix {
                $0.totalUSD / sectorValue >= Self.minimumGroupedConstituentFraction
            }.count
            let minimumVisibleCount = min(8, sortedRows.count)
            let visibleCount = max(
                minimumVisibleCount,
                min(detailedCount, Self.maximumGroupedConstituentTiles)
            )
            let visibleRows = sortedRows.prefix(visibleCount)
            let tailRows = sortedRows.dropFirst(visibleRows.count)
            var models = visibleRows.map {
                lookThroughModel(for: $0, portfolioTotal: portfolioTotal)
            }
            let tailValue = tailRows.reduce(0) { $0 + $1.totalUSD }
            if tailValue > 0 {
                models.append(
                    HoldingsHeatmapTile.Model.remainder(
                        id: "__sector_micro_tail__\(title)",
                        items: tailRows.map { lookThroughModel(for: $0, portfolioTotal: portfolioTotal) }
                    )
                )
            }
            return HoldingsHeatmapSectorGroup(title: title, models: models)
        }
        .sorted { left, right in
            if left.marketValue == right.marketValue {
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
            return left.marketValue > right.marketValue
        }
    }

    private func lookThroughModel(
        for row: ETFLookThroughRow,
        portfolioTotal: Double
    ) -> HoldingsHeatmapTile.Model {
        let directHolding = holding(for: row.ticker)
        return HoldingsHeatmapTile.Model(
            id: row.ticker,
            content: .exposure(row, directHolding: directHolding),
            marketValue: row.totalUSD,
            portfolioFraction: row.totalUSD / portfolioTotal,
            changePercent: changePercent(for: row, directHolding: directHolding),
            performanceTitle: performancePeriod.title,
            performancePeriod: performancePeriod,
            isEstimated: performancePeriod == .holdingPeriod && row.fromETFUSD > 0
        )
    }

    private func makeSectorGroups(
        from models: [HoldingsHeatmapTile.Model]
    ) -> [HoldingsHeatmapSectorGroup] {
        Dictionary(grouping: models, by: sectorTitle(for:))
            .map { title, models in
                HoldingsHeatmapSectorGroup(title: title, models: models)
            }
            .sorted { left, right in
                if left.marketValue == right.marketValue {
                    return left.title.localizedStandardCompare(right.title) == .orderedAscending
                }
                return left.marketValue > right.marketValue
            }
    }

    private func sectorTitle(for model: HoldingsHeatmapTile.Model) -> String {
        switch model.content {
        case let .holding(holding):
            return sectorTitle(for: holding)
        case let .exposure(row, directHolding):
            return sectorTitle(for: row, directHolding: directHolding)
        case .remainder:
            return L10n.text("其他")
        }
    }

    private func sectorTitle(
        for row: ETFLookThroughRow,
        directHolding: Holding?
    ) -> String {
        if row.sector == "ETF / Other" { return L10n.text("ETF 其他") }
        if let title = normalizedSectorTitle(row.sector) { return title }
        if let directHolding { return sectorTitle(for: directHolding) }
        return SectorAttribution.primarySector(ticker: row.ticker)?.displayName ?? L10n.text("未分类")
    }

    private func sectorTitle(for holding: Holding) -> String {
        if let title = normalizedSectorTitle(holding.sector) { return title }

        let attribution = SectorAttribution.split(ticker: holding.ticker, name: holding.displayName)
        if attribution.isLookThrough { return "ETF" }
        if attribution.weights.count == 1, let sector = attribution.weights.keys.first {
            return sector.displayName
        }
        return L10n.text("未分类")
    }

    private func normalizedSectorTitle(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }
        return PortfolioSector(sourceName: rawValue)?.displayName
    }

    private func changePercent(for holding: Holding) -> Double? {
        switch performancePeriod {
        case .today:
            return holding.todayChangePercent
                ?? dailyChanges[holding.ticker.uppercased()]
        case .holdingPeriod:
            return holding.unrealizedPercent.isFinite ? holding.unrealizedPercent : nil
        }
    }

    private func changePercent(
        for row: ETFLookThroughRow,
        directHolding: Holding?
    ) -> Double? {
        switch performancePeriod {
        case .today:
            return directHolding?.todayChangePercent
                ?? dailyChanges[row.ticker.uppercased()]
                ?? lookThroughDailyChanges[row.ticker.uppercased()]
        case .holdingPeriod:
            if row.fromETFUSD > 0 {
                return row.estimatedHoldingPeriodPercent.flatMap { $0.isFinite ? $0 : nil }
            }
            guard let directHolding else { return nil }
            return directHolding.unrealizedPercent.isFinite ? directHolding.unrealizedPercent : nil
        }
    }

    private func holding(for ticker: String) -> Holding? {
        holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
    }

    private func select(_ model: HoldingsHeatmapTile.Model) {
        if let holding = model.holding {
            onSelect(holding)
        }
    }
}

private struct HoldingsHeatmapSectorGroup: Identifiable {
    let title: String
    let models: [HoldingsHeatmapTile.Model]

    var id: String { title }
    var marketValue: Double { models.reduce(0) { $0 + $1.marketValue } }
    var constituentCount: Int {
        models.reduce(0) { count, model in
            switch model.content {
            case .holding, .exposure:
                return count + 1
            case let .remainder(remainderCount):
                return count + remainderCount
            }
        }
    }
}

private struct HoldingsHeatmapTileCloud: View {
    @Environment(\.locale) private var appLocale
    let models: [HoldingsHeatmapTile.Model]
    var tileInset: CGFloat = 2
    var isInteractive = true
    let onSelect: (HoldingsHeatmapTile.Model) -> Void
    @State private var expandedRemainder: HoldingsHeatmapTile.Model?

    var body: some View {
        GeometryReader { geometry in
            let displayModels = HoldingsHeatmapAggregation.modelsForDisplay(models, in: geometry.size)
            let placements = HoldingsTreemapLayout.layout(
                items: displayModels.map { HoldingsTreemapLayout.Item(ticker: $0.id, weight: $0.marketValue) },
                in: CGRect(origin: .zero, size: geometry.size),
                lastItemIndex: displayModels.firstIndex(where: \.isRemainder)
            )

            ZStack(alignment: .topLeading) {
                ForEach(placements, id: \.sourceIndex) { placement in
                    let effectiveInset = HoldingsHeatmapTile.inset(in: placement.frame.size, maximum: tileInset)
                    let frame = placement.frame.insetBy(dx: effectiveInset, dy: effectiveInset)
                    let model = displayModels[placement.sourceIndex]

                    HoldingsHeatmapTile(
                        model: model,
                        fraction: model.portfolioFraction,
                        size: frame.size,
                        action: isInteractive && (model.holding != nil || !model.detailItems.isEmpty) ? {
                            if model.isRemainder { expandedRemainder = model }
                            else { onSelect(model) }
                        } : nil
                    )
                    .frame(width: max(0, frame.width), height: max(0, frame.height))
                    .position(x: frame.midX, y: frame.midY)
                }

            }
        }
        .sheet(item: $expandedRemainder) { remainder in
            HoldingsHeatmapRemainderDetail(model: remainder)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct GroupedHoldingsHeatmap: View {
    @Environment(\.locale) private var appLocale
    let groups: [HoldingsHeatmapSectorGroup]
    @State private var expandedGroup: HoldingsHeatmapSectorGroup?

    var body: some View {
        GeometryReader { geometry in
            let placements = HoldingsTreemapLayout.layout(
                items: groups.map { HoldingsTreemapLayout.Item(ticker: $0.id, weight: $0.marketValue) },
                in: CGRect(origin: .zero, size: geometry.size)
            )

            ZStack(alignment: .topLeading) {
                ForEach(placements, id: \.sourceIndex) { placement in
                    let frame = placement.frame.insetBy(dx: 1.5, dy: 1.5)
                    let group = groups[placement.sourceIndex]

                    HoldingsHeatmapSectorView(
                        group: group,
                        onExpand: { expandedGroup = $0 }
                    )
                    .frame(width: max(0, frame.width), height: max(0, frame.height))
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .sheet(item: $expandedGroup) { group in
            HoldingsHeatmapSectorDetail(group: group)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(uiColor: .systemBackground))
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.arguments.contains("--expand-first-heatmap-sector") {
                expandedGroup = groups.first
            }
        }
        #endif
    }
}

private struct HoldingsHeatmapSectorView: View {
    @Environment(\.locale) private var appLocale
    let group: HoldingsHeatmapSectorGroup
    let onExpand: (HoldingsHeatmapSectorGroup) -> Void

    var body: some View {
        GeometryReader { geometry in
            let showsHeader = geometry.size.width >= 54 && geometry.size.height >= 42
            let headerHeight: CGFloat = geometry.size.height < 64 ? 20 : 24

            Button {
                onExpand(group)
            } label: {
                VStack(spacing: 0) {
                    if showsHeader {
                        // The sector names itself; the tally beside it was one
                        // more figure competing with the ones inside the block,
                        // and "其他 34" read as a holding called 其他 rather
                        // than a count. It stays in the accessibility value,
                        // where it costs no room.
                        HStack(spacing: 4) {
                            Text(group.title)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .appText(.micro, weight: .semibold)
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 7)
                        .frame(height: headerHeight)
                    }

                    // The sector is one tap target, including its company and
                    // remainder tiles. Stock selection belongs to its sheet.
                    HoldingsHeatmapTileCloud(
                        models: group.models,
                        tileInset: 2,
                        isInteractive: false,
                        onSelect: { _ in }
                    )
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("查看\(group.title)行业"))
            .accessibilityValue(Text("\(group.constituentCount)"))
        }
    }
}

private struct HoldingsHeatmapSectorDetail: View {
    let group: HoldingsHeatmapSectorGroup

    var body: some View {
        HoldingsHeatmapRemainderDetail(
            model: .remainder(id: "__sector_detail__", items: group.models),
            title: group.title
        )
    }
}

/// Consolidate the unreadable tail using actual layout dimensions. The merged
/// rectangle keeps its exact area and every constituent remains in its sheet.
enum HoldingsHeatmapAggregation {
    static func modelsForDisplay(
        _ models: [HoldingsHeatmapTile.Model], in size: CGSize
    ) -> [HoldingsHeatmapTile.Model] {
        guard size.width > 0, size.height > 0, models.count > 1 else { return models }
        let sorted = models.sorted {
            if $0.isRemainder != $1.isRemainder { return !$0.isRemainder }
            return $0.marketValue == $1.marketValue ? $0.id < $1.id : $0.marketValue > $1.marketValue
        }
        func placements(_ items: [HoldingsHeatmapTile.Model]) -> [HoldingsTreemapLayout.Tile] {
            HoldingsTreemapLayout.layout(
                items: items.map { HoldingsTreemapLayout.Item(ticker: $0.id, weight: $0.marketValue) },
                in: CGRect(origin: .zero, size: size),
                lastItemIndex: items.firstIndex(where: \.isRemainder)
            )
        }
        let tinyIndices = placements(sorted).filter {
            let inset = HoldingsHeatmapTile.inset(in: $0.frame.size)
            return !HoldingsHeatmapTile.canShowIdentifier(in: $0.frame.insetBy(dx: inset, dy: inset).size)
        }.map(\.sourceIndex)
        guard var keepCount = tinyIndices.min() else { return sorted }
        if let existingTail = sorted.firstIndex(where: \.isRemainder) {
            keepCount = min(keepCount, existingTail)
        }
        while true {
            let tail = Array(sorted.dropFirst(keepCount))
            let remainder = HoldingsHeatmapTile.Model.remainder(id: "__compact_tail__", items: tail)
            let result = Array(sorted.prefix(keepCount)) + [remainder]
            // Absorb the preceding tile when necessary to give the aggregate
            // a usable touch target, without inflating its portfolio weight.
            let updatedPlacements = placements(result)
            // Anchoring a larger aggregate can make the preceding row thin.
            // Recheck the remaining companies after each merge as well.
            if let firstUnreadable = updatedPlacements.filter({ placement in
                guard placement.sourceIndex < keepCount else { return false }
                let inset = HoldingsHeatmapTile.inset(in: placement.frame.size)
                return !HoldingsHeatmapTile.canShowIdentifier(in: placement.frame.insetBy(dx: inset, dy: inset).size)
            }).map(\.sourceIndex).min() {
                keepCount = firstUnreadable
                continue
            }
            let frame = updatedPlacements.first { $0.sourceIndex == keepCount }?.frame ?? .zero
            // Never swallow the last readable major holding just to enlarge
            // the tail. A genuinely narrow sector starts with keepCount == 0.
            if keepCount <= 1 || (frame.width >= 30 && frame.height >= 28) { return result }
            keepCount -= 1
        }
    }
}

private struct HoldingsHeatmapRemainderDetail: View {
    let model: HoldingsHeatmapTile.Model
    var title: String? = nil
    @State private var loadedChanges: [String: Double] = [:]
    @State private var completedQuoteIDs: Set<String> = []
    @State private var loadingQuotes = false
    @State private var selectedHolding: Holding?
    @Namespace private var holdingZoom
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    private var items: [HoldingsHeatmapTile.Model] {
        model.leafItems.sorted { $0.marketValue == $1.marketValue ? $0.id < $1.id : $0.marketValue > $1.marketValue }
    }

    private var summary: HoldingsHeatmapTile.Model.PerformanceSummary {
        model.performanceSummary(dailyChanges: loadedChanges)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Text(DisplayFormat.money(model.marketValue)).appNumber(.body)
                        Spacer()
                        Text(DisplayFormat.percent(model.portfolioFraction * 100, signed: false))
                            .appNumber(.body).foregroundStyle(.secondary)
                    }
                    LabeledContent(L10n.text(summary.isComplete ? "P&L" : "已知盈亏"), value:
                        summary.knownCount > 0
                            ? (summary.isEstimated ? "≈" : "") + (summary.amount > 0 ? "+" : "") + DisplayFormat.money(summary.amount)
                            : L10n.text("暂无数据"))
                        .currencyFont(.body)
                    LabeledContent(L10n.text("收益率"), value:
                        summary.percent.map { (summary.isEstimated ? "≈" : "") + DisplayFormat.percent($0) }
                            ?? L10n.text("暂无数据"))
                    if !summary.isComplete {
                        Text(L10n.text("已覆盖 \(summary.knownCount)/\(summary.totalCount) 项，缺失数据未计入盈亏"))
                            .appText(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(model.performanceTitle)
                }
                Section {
                    // Every row opens. Rows for a constituent held only inside
                    // an ETF used to render identically and do nothing, so
                    // which rows responded looked arbitrary.
                    ForEach(items) { item in
                        if let holding = item.detailHolding {
                            Button { selectedHolding = holding } label: { detailRow(item) }
                                .buttonStyle(.plain)
                                .catfolioZoomSource(holding.ticker, in: holdingZoom)
                        } else {
                            detailRow(item)
                        }
                    }
                } header: {
                    Text(model.performanceTitle)
                }

            }
            .softTopScrollEdge()
            .navigationTitle(title ?? L10n.text("其他"))
            .task { await loadMissingDailyChanges() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.text("完成")) { dismiss() }
                }
            }
        }
        // Present from the list sheet itself so UIKit keeps the first sheet
        // underneath, including its scroll position, and owns the stacked
        // presentation and interactive dismissal animations.
        .sheet(item: $selectedHolding) { holding in
            HoldingDetailView(holding: holding)
                .securityDetailSheet()
                .navigationTransition(.zoom(sourceID: holding.ticker, in: holdingZoom))
        }
        .securityDetailOpenFeedback(trigger: selectedHolding?.ticker, enabled: hapticsEnabled)
    }

    private func detailRow(_ item: HoldingsHeatmapTile.Model) -> some View {
        let identity: (ticker: String, name: String, logo: String?) = {
            switch item.content {
            case let .holding(holding): (holding.ticker, holding.shortName, holding.logoSymbol)
            case let .exposure(row, _): (row.ticker, CompanyNameCatalog.displayName(ticker: row.ticker, fallback: row.name), row.logoSymbol)
            case .remainder: (item.id, "", nil)
            }
        }()
        return HStack(spacing: 10) {
            AssetLogo(ticker: identity.ticker, logoSymbol: identity.logo)
            VStack(alignment: .leading, spacing: 4) {
                Text(identity.name).appText(.body, weight: .semibold)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(identity.ticker).appText(.caption)
                    Text("·").appText(.caption)
                    Text(DisplayFormat.percent(item.portfolioFraction * 100, signed: false))
                        .appNumber(.caption)
                }
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let change = item.changePercent ?? loadedChanges[item.id.uppercased()] {
                    Text((item.isEstimated ? "≈" : "") + DisplayFormat.percent(change))
                        .appNumber(.body)
                        .foregroundStyle(change == 0 ? Color.secondary : (change > 0 ? CatfolioTheme.gain(for: colorScheme) : CatfolioTheme.loss(for: colorScheme)))
                } else if loadingQuotes && !completedQuoteIDs.contains(item.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L10n.text("暂无数据")).appText(.caption).foregroundStyle(.secondary)
                }
                Text(DisplayFormat.money(item.marketValue)).appNumber(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func loadMissingDailyChanges() async {
        // Holding-period returns are already supplied by the portfolio pipeline.
        // Never fill a missing holding-period return with a daily quote.
        guard model.performancePeriod == .today else { return }
        let missing = items.filter { $0.changePercent == nil && !completedQuoteIDs.contains($0.id) }
        guard !missing.isEmpty else { return }
        loadingQuotes = true
        defer { loadingQuotes = false }
        let client = LocalMarketDataClient()
        // Reuse cached histories and the client's bounded concurrency. Only an
        // opened detail sheet requests quotes beyond the main heatmap's top tiles.
        for start in stride(from: 0, to: missing.count, by: 24) {
            guard !Task.isCancelled else { return }
            let batch = Array(missing[start..<min(start + 24, missing.count)])
            let holdings = batch.compactMap(\.holding)
            let directChanges = await client.dailyChanges(for: holdings)
            guard !Task.isCancelled else { return }
            loadedChanges.merge(directChanges) { _, fresh in fresh }
            let tickers = batch.filter { $0.holding == nil }.map(\.id)
            let constituentChanges = await client.dailyChanges(tickers: tickers)
            guard !Task.isCancelled else { return }
            loadedChanges.merge(constituentChanges) { _, fresh in fresh }
            completedQuoteIDs.formUnion(batch.map(\.id))
        }
    }
}
