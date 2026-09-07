import SwiftUI

struct HoldingsHeatmapView: View {
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
    let onShowAll: () -> Void

    private let maximumHoldingTiles = 20
    private let minimumIndividualFraction = 0.008
    private let groupedScreenInset: CGFloat = 16
    private var heatmapHeight: CGFloat { usesETFLookThrough ? 700 : 580 }

    var body: some View {
        let sectorGroups = groupsBySector ? makeSectorGroups() : []
        let models = groupsBySector ? sectorGroups.flatMap(\.models) : makeModels()

        VStack(alignment: .leading, spacing: 12) {
            if models.isEmpty {
                ContentUnavailableView(
                    "暂无持仓",
                    systemImage: "square.grid.3x3",
                    description: Text("同步持仓后会在这里显示资产分布。")
                )
                .frame(minHeight: 260)
            } else {
                Group {
                    if groupsBySector {
                        GroupedHoldingsHeatmap(
                            groups: sectorGroups,
                            onSelect: select
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

                HStack(spacing: 7) {
                    Circle()
                        .fill(CatfolioPalette.rose500)
                        .frame(width: 7, height: 7)
                    Text("下跌")
                    Spacer()
                    Text("上涨")
                    Circle()
                        .fill(CatfolioPalette.green500)
                        .frame(width: 7, height: 7)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func makeModels() -> [HoldingsHeatmapTile.Model] {
        if usesETFLookThrough, let lookThroughRows {
            return makeLookThroughModels(from: lookThroughRows)
        }
        return makeHoldingModels()
    }

    private func makeHoldingModels() -> [HoldingsHeatmapTile.Model] {
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

        let visible = Array(
            valid.enumerated()
                .filter { index, holding in
                    index < 4 || holding.marketValue / total >= minimumIndividualFraction
                }
                .prefix(maximumHoldingTiles)
                .map(\.element)
        )
        let visibleTickers = Set(visible.map(\.ticker))
        let remainder = valid.filter { !visibleTickers.contains($0.ticker) }

        var models = visible.map { holding in
            HoldingsHeatmapTile.Model(
                id: holding.ticker,
                content: .holding(holding),
                marketValue: holding.marketValue,
                portfolioFraction: holding.marketValue / total,
                changePercent: changePercent(for: holding),
                performanceTitle: performancePeriod.title
            )
        }
        let remainderValue = remainder.reduce(0) { $0 + $1.marketValue }
        if remainderValue > 0 {
            models.append(
                HoldingsHeatmapTile.Model(
                    id: "__remainder__",
                    content: .remainder(count: remainder.count),
                    marketValue: remainderValue,
                    portfolioFraction: remainderValue / total,
                    changePercent: nil,
                    performanceTitle: performancePeriod.title
                )
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
                HoldingsHeatmapTile.Model(
                    id: "__look_through_remainder__",
                    content: .remainder(count: remainder.count),
                    marketValue: remainderValue,
                    portfolioFraction: remainderValue / total,
                    changePercent: nil,
                    performanceTitle: performancePeriod.title
                )
            )
        }
        return models
    }

    private func makeSectorGroups() -> [HoldingsHeatmapSectorGroup] {
        if usesETFLookThrough, let lookThroughRows {
            return makeLookThroughSectorGroups(from: lookThroughRows)
        }
        return makeSectorGroups(from: makeHoldingModels())
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
                    HoldingsHeatmapTile.Model(
                        id: "__sector_micro_tail__\(title)",
                        content: .remainder(count: tailRows.count),
                        marketValue: tailValue,
                        portfolioFraction: tailValue / portfolioTotal,
                        changePercent: nil,
                        performanceTitle: performancePeriod.title
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
            performanceTitle: performancePeriod.title
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
            return "其他"
        }
    }

    private func sectorTitle(
        for row: ETFLookThroughRow,
        directHolding: Holding?
    ) -> String {
        if row.sector == "ETF / Other" { return "ETF 其他" }
        if let title = normalizedSectorTitle(row.sector) { return title }
        return directHolding.map(sectorTitle(for:)) ?? "未分类"
    }

    private func sectorTitle(for holding: Holding) -> String {
        if let title = normalizedSectorTitle(holding.sector) { return title }

        let attribution = SectorAttribution.split(ticker: holding.ticker, name: holding.displayName)
        if attribution.isLookThrough { return "ETF" }
        if attribution.weights.count == 1, let sector = attribution.weights.keys.first {
            return sector.displayName
        }
        return "未分类"
    }

    private func normalizedSectorTitle(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else { return nil }
        return PortfolioSector(sourceName: rawValue)?.displayName ?? rawValue
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
            guard row.fromETFUSD <= 0.001, let directHolding else { return nil }
            return directHolding.unrealizedPercent.isFinite ? directHolding.unrealizedPercent : nil
        }
    }

    private func holding(for ticker: String) -> Holding? {
        holdings.first { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
    }

    private func select(_ model: HoldingsHeatmapTile.Model) {
        if let holding = model.holding {
            onSelect(holding)
        } else if model.isRemainder {
            onShowAll()
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
    let models: [HoldingsHeatmapTile.Model]
    var tileInset: CGFloat = 2
    let onSelect: (HoldingsHeatmapTile.Model) -> Void

    var body: some View {
        GeometryReader { geometry in
            let placements = HoldingsTreemapLayout.layout(
                items: models.map {
                    HoldingsTreemapLayout.Item(ticker: $0.id, weight: $0.marketValue)
                },
                in: CGRect(origin: .zero, size: geometry.size)
            )

            ZStack(alignment: .topLeading) {
                ForEach(placements, id: \.sourceIndex) { placement in
                    let shortestSide = min(placement.frame.width, placement.frame.height)
                    let effectiveInset = min(tileInset, max(0, shortestSide * 0.025))
                    let frame = placement.frame.insetBy(dx: effectiveInset, dy: effectiveInset)
                    let model = models[placement.sourceIndex]

                    HoldingsHeatmapTile(
                        model: model,
                        fraction: model.portfolioFraction,
                        size: frame.size,
                        action: model.holding != nil || model.isRemainder
                            ? { onSelect(model) }
                            : nil
                    )
                    .frame(width: max(0, frame.width), height: max(0, frame.height))
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
    }
}

private struct GroupedHoldingsHeatmap: View {
    let groups: [HoldingsHeatmapSectorGroup]
    let onSelect: (HoldingsHeatmapTile.Model) -> Void
    @State private var expandedGroup: HoldingsHeatmapSectorGroup?

    var body: some View {
        GeometryReader { geometry in
            let placements = HoldingsTreemapLayout.layout(
                items: groups.map {
                    HoldingsTreemapLayout.Item(ticker: $0.id, weight: $0.marketValue)
                },
                in: CGRect(origin: .zero, size: geometry.size)
            )

            ZStack(alignment: .topLeading) {
                ForEach(placements, id: \.sourceIndex) { placement in
                    let frame = placement.frame.insetBy(dx: 1.5, dy: 1.5)
                    let group = groups[placement.sourceIndex]

                    HoldingsHeatmapSectorView(
                        group: group,
                        onSelect: onSelect,
                        onExpand: { expandedGroup = $0 }
                    )
                        .frame(width: max(0, frame.width), height: max(0, frame.height))
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .sheet(item: $expandedGroup) { group in
            HoldingsHeatmapSectorDetail(
                group: group,
                onSelect: { model in
                    expandedGroup = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        onSelect(model)
                    }
                }
            )
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
    let group: HoldingsHeatmapSectorGroup
    let onSelect: (HoldingsHeatmapTile.Model) -> Void
    let onExpand: (HoldingsHeatmapSectorGroup) -> Void

    var body: some View {
        GeometryReader { geometry in
            let showsHeader = geometry.size.width >= 54 && geometry.size.height >= 42
            let showsExpandIcon = geometry.size.width >= 110
            let headerHeight: CGFloat = geometry.size.height < 64 ? 20 : 24
            let tileHeight = max(0, geometry.size.height - (showsHeader ? headerHeight : 0))
            let displayModels = modelsForDisplay(
                in: CGSize(width: geometry.size.width, height: tileHeight)
            )

            VStack(spacing: 0) {
                if showsHeader {
                    Button {
                        onExpand(group)
                    } label: {
                        HStack(spacing: 4) {
                            Text(group.title)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text("\(group.constituentCount)")
                                .appNumber(.caption)
                            if showsExpandIcon {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .imageScale(.small)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 7)
                    .frame(height: headerHeight)
                    .accessibilityLabel("放大查看\(group.title)行业")
                }

                HoldingsHeatmapTileCloud(
                    models: displayModels,
                    tileInset: 1.5,
                    onSelect: onSelect
                )
            }
        }
    }

    private func modelsForDisplay(in size: CGSize) -> [HoldingsHeatmapTile.Model] {
        let canvasArea = max(0, size.width * size.height)
        guard canvasArea > 0, group.marketValue > 0 else { return group.models }

        let firstTinyIndex = group.models.firstIndex { model in
            CGFloat(model.marketValue / group.marketValue) * canvasArea < 324
        } ?? group.models.count
        let visibleCount = max(min(6, group.models.count), firstTinyIndex)
        let visible = group.models.prefix(visibleCount)
        let tail = group.models.dropFirst(visibleCount)
        guard tail.count > 1 else { return group.models }

        let tailValue = tail.reduce(0) { $0 + $1.marketValue }
        let tailFraction = tail.reduce(0) { $0 + $1.portfolioFraction }
        let tailCount = tail.reduce(0) { count, model in
            switch model.content {
            case .holding, .exposure:
                return count + 1
            case let .remainder(remainderCount):
                return count + remainderCount
            }
        }
        let remainder = HoldingsHeatmapTile.Model(
            id: "__rendered_sector_tail__\(group.id)",
            content: .remainder(count: tailCount),
            marketValue: tailValue,
            portfolioFraction: tailFraction,
            changePercent: nil,
            performanceTitle: group.models.first?.performanceTitle ?? ""
        )
        return Array(visible) + [remainder]
    }
}

private struct HoldingsHeatmapSectorDetail: View {
    let group: HoldingsHeatmapSectorGroup
    let onSelect: (HoldingsHeatmapTile.Model) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(group.constituentCount) 项 · 面积仍代表在整个组合中的市值占比")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HoldingsHeatmapTileCloud(
                    models: group.models,
                    tileInset: 2,
                    onSelect: onSelect
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
