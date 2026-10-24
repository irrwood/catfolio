import SwiftUI
import UIKit

/// This page alone uses native phone navigation; workspace presentation keeps
/// its existing toolbar and legacy non-phone presentations keep their chrome.
enum ReturnsComparisonNavigation {
    static var usesSystemBarOnPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && !MacPlatform.isMac
    }
}

struct ComparisonZeroPositionKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

struct ReturnsComparisonPanel: View {
    @Environment(\.isWorkspaceDetail) private var isWorkspaceDetail
    @Environment(\.locale) private var appLocale
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var chartMode: ReturnsChartMode = {
        let arguments = LaunchArguments.all
        if arguments.contains("--show-cash-flow") { return .cashFlowMatched }
        if arguments.contains("--show-mwr") { return .mwr }
        return .twr
    }()
    @State private var timeRange: ChartTimeRange = {
        let arguments = LaunchArguments.all
        if arguments.contains("--show-returns-1d") { return .oneDay }
        if arguments.contains("--show-returns-1w") { return .oneWeek }
        if arguments.contains("--show-returns-1m") { return .oneMonth }
        if arguments.contains("--show-returns-2m") { return .twoMonths }
        if arguments.contains("--show-returns-3m") { return .threeMonths }
        if arguments.contains("--show-returns-ytd") { return .yearToDate }
        if arguments.contains("--show-returns-6m") { return .sixMonths }
        if arguments.contains("--show-returns-2y") { return .twoYears }
        if arguments.contains("--show-returns-all")
            || arguments.contains("--show-returns-max") { return .maximum }
        // The home chart's default, and a slot the shared picker has.
        return .yearToDate
    }()
    @State private var selectedDate: Date?
    /// The one line a right swipe on its row brought forward; the rest fade.
    /// Kept here so it outlives the chart being rebuilt when a symbol leaves.
    @State private var highlightedSeries: String?
    @State private var isModeSwitcherExpanded = LaunchArguments.contains("--show-returns-mode-expanded")
    @AppStorage(ComparisonBenchmarkCatalog.preferenceKey) private var storedBenchmarks: String?
    @State private var showsBenchmarkPicker = false
    /// The list the comparison on screen was computed for.
    @State private var computedBenchmarks = ComparisonBenchmarkCatalog.symbols
    @State private var zeroPosition: CGFloat = 230
    @State private var disclosure = ReturnsChartDisclosure()

    private var chartContent: some View {
        Group {
            if let comparison = model.comparison {
                ReturnsChart(
                    comparison: comparison,
                    mode: $chartMode,
                    timeRange: $timeRange,
                    selectedDate: $selectedDate,
                    highlightedSeries: $highlightedSeries,
                    disclosure: disclosure,
                    onAddBenchmark: { showsBenchmarkPicker = true }
                )
                // A removed symbol leaves at once; an added one arrives
                // with the recomputed comparison.
                .id("\(model.comparisonRevision)|\(storedBenchmarks ?? "")")
            } else {
                ReturnsComparisonPlaceholder(
                    timeRange: $timeRange,
                    title: model.returnsError == nil
                        ? L10n.text("正在加载收益数据") : L10n.text("暂无收益记录"),
                    message: model.returnsError
                        ?? L10n.text("正在整理组合与基准的历史记录"),
                    isLoading: model.returnsError == nil,
                    disclosure: disclosure
                )
            }
        }
    }

    var body: some View {
        Group {
            if ReturnsComparisonNavigation.usesSystemBarOnPhone || isWorkspaceDetail {
                chartContent.toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(L10n.text("添加对比"), systemImage: "magnifyingglass") {
                            showsBenchmarkPicker = true
                        }
                        .accessibilityIdentifier("comparison.add-benchmark")
                        Picker(L10n.text("收益图表口径"), selection: $chartMode) {
                            ForEach(ReturnsChartMode.displayOrder, id: \.self) { mode in
                                Text(mode == .cashFlowMatched ? "Mirror" : mode.displayTitle).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("comparison.mode.native")
                    }
                }
            } else {
                chartContent.comparisonTopBar { header }
                    .background { ComparisonSwipeBackSupport().frame(width: 0, height: 0) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .foregroundStyle(.white)
        .coordinateSpace(name: "comparison-page")
        .onPreferenceChange(ComparisonZeroPositionKey.self) { value in
            if let value { zeroPosition = value }
        }
        .background {
            GeometryReader { geometry in
                let top = geometry.frame(in: .named("comparison-page")).minY
                let center = min(0.95, max(0.05, (zeroPosition - top) / max(1, geometry.size.height)))
                LinearGradient(stops: [
                    .init(color: Color(red: 91 / 255, green: 49 / 255, blue: 210 / 255), location: 0),
                    .init(color: Color(red: 0.025, green: 0.012, blue: 0.065), location: center),
                    .init(color: Color(red: 92 / 255, green: 50 / 255, blue: 213 / 255), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { selectDrawableModeIfNeeded() }
        .onChange(of: model.comparisonRevision) { _, _ in
            computedBenchmarks = ComparisonBenchmarkCatalog.symbols
            selectDrawableModeIfNeeded()
        }
        .onChange(of: chartMode) { _, _ in selectedDate = nil }
        .onChange(of: timeRange) { _, _ in selectedDate = nil }
        .onChange(of: showsBenchmarkPicker) { _, isShowing in
            // Recompute once for everything added while searching.
            if !isShowing { Task { await recomputeIfAdded() } }
        }
        .appSheet(isPresented: $showsBenchmarkPicker) {
            ReturnsBenchmarkPicker()
                .environment(model)
        }
        .onChange(of: storedBenchmarks) { _, _ in
            Task { await recomputeIfAdded() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            backButton.modifier(ReturnsHeaderCircleGlass())
            // The page draws its own bar, so it sets its own title; it gives
            // way while the mode switcher is open and needs the room.
            if !isModeSwitcherExpanded {
                Text(L10n.text("收益对比"))
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                    .transition(.opacity)
            }

            Spacer(minLength: 8)
            if !isModeSwitcherExpanded {
                addBenchmarkButton
                    .modifier(ReturnsHeaderCircleGlass())
                    .transition(.opacity)
            }
            modeSwitcher
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 19, weight: .regular))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("返回"))
    }

    private var addBenchmarkButton: some View {
        Button { showsBenchmarkPicker = true } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("添加对比"))
    }

    private var modeSwitcher: some View {
        Group {
            if isModeSwitcherExpanded {
                HStack(spacing: 0) {
                    ForEach(ReturnsChartMode.displayOrder, id: \.self) { mode in
                        let isSelected = chartMode == mode
                        Button {
                            chartMode = mode
                            setSwitcherExpanded(false)
                        } label: {
                            Text(mode == .cashFlowMatched ? "Mirror" : mode.displayTitle)
                                .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 90, height: 48)
                                .background {
                                    if isSelected {
                                        Capsule()
                                            .fill(.white.opacity(0.22))
                                            .overlay {
                                                Capsule().strokeBorder(Color.white.opacity(0.33), lineWidth: 1)
                                            }
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .frame(width: 270, height: 48)
                .modifier(ReturnsSwitcherGlass())
                .accessibilityIdentifier("comparison.mode.expanded")
                .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .trailing)))
            } else {
                Button { setSwitcherExpanded(true) } label: {
                    HStack(spacing: 9) {
                        Text(chartMode == .cashFlowMatched ? "Mirror" : chartMode.displayTitle)
                            .font(.system(size: 15, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.7))
                    }
                    .frame(width: 110, height: 48)
                }
                .buttonStyle(.plain)
                .modifier(ReturnsSwitcherGlass())
                .accessibilityLabel(L10n.text("收益图表口径，当前 \(chartMode.displayTitle)，展开选项"))
                .accessibilityIdentifier("comparison.mode.collapsed")
                .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .trailing)))
            }
        }
    }

    private func setSwitcherExpanded(_ expanded: Bool) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.26)) {
            isModeSwitcherExpanded = expanded
        }
    }

    /// Only an added symbol needs its history fetched; a removed one is
    /// already gone from the chart.
    private func recomputeIfAdded() async {
        let current = ComparisonBenchmarkCatalog.symbols
        let added = !Set(current).isSubset(of: Set(computedBenchmarks))
        guard added, !showsBenchmarkPicker else { return }
        computedBenchmarks = current
        await model.refreshReturns()
    }

    private func selectDrawableModeIfNeeded() {
        guard let comparison = model.comparison else { return }
        let hasActiveLine = comparison.dates.count > 1
            && comparison.portfolio.compactMap { $0 }.count > 1
        let hasTWRLine = (comparison.twrDates?.count ?? 0) > 1
            && (comparison.twrPortfolio?.compactMap { $0 }.count ?? 0) > 1
        let hasMWRLine = (comparison.mwrLedger?.dates.count ?? 0) > 1
            && (comparison.mwrPortfolio?.compactMap { $0 }.count ?? 0) > 1

        switch chartMode {
        case .cashFlowMatched where !hasActiveLine:
            break
        case .twr where !hasTWRLine:
            // Keep the requested metric visible with its missing-ledger reason.
            break
        case .mwr where !hasMWRLine:
            break
        default:
            break
        }
    }
}

private extension View {
    /// A custom top bar that the scroll edge effect treats like the system's:
    /// content scrolled under it fades and blurs instead of being cut off.
    @ViewBuilder
    func comparisonTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .top, spacing: 0) { bar().background(.bar) }
        }
    }
}

/// On the light page the faint dark-page glass would vanish: there the
/// buttons are fuller glass over a white wash.
private struct ReturnsHeaderCircleGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        if #available(iOS 26.0, *) {
            content.background {
                ZStack {
                    Circle().fill(.white.opacity(isDark ? 0.025 : 0.55))
                    Color.clear.glassEffect(.regular.interactive(), in: Circle()).opacity(isDark ? 0.16 : 1)
                    Circle().strokeBorder(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.05), lineWidth: 1)
                }
            }
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

private struct ReturnsSwitcherGlass: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        if #available(iOS 26.0, *) {
            content
                .background {
                    ZStack {
                        Capsule().fill(.white.opacity(isDark ? 0.03 : 0.45))
                        Color.clear.glassEffect(.regular.interactive(), in: Capsule()).opacity(isDark ? 0.70 : 1)
                        Capsule().strokeBorder(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 1)
                    }
                }
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
        }
    }
}
