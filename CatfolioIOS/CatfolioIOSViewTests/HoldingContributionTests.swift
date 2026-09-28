import SwiftUI
import XCTest
@testable import CatfolioIOS

/// Losses share the gains' visual surface, but rank by deepest loss in the range.
final class HoldingLossTests: XCTestCase {
    func testRangeTransitionsKeepCumulativeLayersOrderedWhenRankingsAndBandCountsChange() throws {
        let source = history()
        let recentRow = HoldingValueHistory.Row(dateText: "2026-09-16", cost: 6000,
            values: ["A": 1100, "E": 900, "C": 700, "B": 1000, "G": 1005, "F": 995], costs: source.costs)
        let input = HoldingValueHistory(rows: Array(source.rows.dropLast()) + [recentRow, source.rows.last!],
                                        costs: source.costs, names: source.names)
        let prepared = try HoldingLossRanges(history: input)
        let annual = try XCTUnwrap(prepared[.oneYear])
        let recent = try XCTUnwrap(prepared[.oneWeek])
        XCTAssertGreaterThan(recent.rows.count, 1, "Both ranges must render an actual chart")
        XCTAssertNotEqual(annual.bands.map(\.title), recent.bands.map(\.title))
        XCTAssertNotEqual(annual.bands.count, recent.bands.count)
        XCTAssertLessThan(try XCTUnwrap(annual.holdingRanks["E"]), try XCTUnwrap(annual.holdingRanks["C"]))
        XCTAssertLessThan(try XCTUnwrap(recent.holdingRanks["C"]), try XCTUnwrap(recent.holdingRanks["E"]))
        let annualSeries = LossAnalysisChart.chartSeries(stack: annual, visible: Array(annual.bands.indices), scheme: .light)
        let recentSeries = LossAnalysisChart.chartSeries(stack: recent, visible: Array(recent.bands.indices), scheme: .light)
        // Each path is a cumulative boundary, so it must retain its depth in
        // the paint order when the holdings occupying those layers change.
        XCTAssertEqual(annualSeries.map(\.id), recentSeries.map(\.id))
        guard annualSeries.map(\.id) == recentSeries.map(\.id) else { return }
        for (from, to) in [(annualSeries, recentSeries), (recentSeries, annualSeries)] {
            let paths = zip(from, to).map { StandardLineChartViewportPath(from: $0.points, to: $1.points) }
            for frame in 0...60 {
                let samples = paths.map { $0.samples(progress: CGFloat(frame) / 60) }
                assertNestedLossBoundaries(samples)
            }
            // A second tap must start from the partially drawn shape, too.
            let interrupted = paths.map { $0.samples(progress: 0.35) }
            let resumed = zip(interrupted, from).map { StandardLineChartViewportPath(from: $0, to: $1.points) }
            for frame in 0...60 {
                assertNestedLossBoundaries(resumed.map { $0.samples(progress: CGFloat(frame) / 60) })
            }
        }
    }

    private func assertNestedLossBoundaries(_ layers: [[StandardLineChartPoint]], file: StaticString = #filePath, line: UInt = #line) {
        for (outer, inner) in zip(layers, layers.dropFirst()) {
            XCTAssertEqual(outer.map(\.date), inner.map(\.date), file: file, line: line)
            for (lower, upper) in zip(outer, inner) {
                XCTAssertLessThanOrEqual(lower.value, upper.value + 0.000_001, "Loss bands must not cross during zoom", file: file, line: line)
                XCTAssertLessThanOrEqual(upper.value, 0, file: file, line: line)
            }
        }
    }

    func testStableLossLayersPreserveAmountsAndHiddenOthersAcrossAllRanges() throws {
        for hidden: Set<String> in [[], ["A", "E"]] {
            let prepared = try HoldingLossRanges(history: history(), hiding: hidden)
            for range in ChartTimeRange.allCases {
                let stack = try XCTUnwrap(prepared[range])
                for showsOthers in [false, true] {
                    let visible = stack.bands.indices.filter { showsOthers || stack.bands[$0].kind != .others }
                    let series = LossAnalysisChart.chartSeries(stack: stack, visible: visible, scheme: .light)
                    XCTAssertEqual(series.count, HoldingContributionStack.maximumNamed + 1)
                    for rowIndex in stack.rows.indices {
                        let row = stack.rows[rowIndex]
                        XCTAssertEqual(series[0].points[rowIndex].value,
                                       -visible.reduce(0) { $0 + row.bands[$1] }, accuracy: 0.000_001)
                        for (depth, band) in visible.filter({ stack.bands[$0].kind != .others }).reversed().enumerated() {
                            // The visible thickness still represents exactly
                            // this holding, even with invisible padded layers.
                            XCTAssertEqual(series[depth + 1].points[rowIndex].value - series[depth].points[rowIndex].value,
                                           row.bands[band], accuracy: 0.000_001)
                        }
                        XCTAssertEqual(series.last?.points[rowIndex].value,
                                       showsOthers ? -row.bands[0] : 0)
                    }
                    assertNestedLossBoundaries(series.map(\.points))
                }
            }
        }
    }

    @MainActor
    func testLossRangeMotionFramesIncludingRapidRetargeting() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let prepared = try HoldingLossRanges(history: LossAnalysisChart.demoHistory())
        let directory = URL(fileURLWithPath: "/tmp/catfolio-loss-motion", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let state = LossMotionFixtureState()
            let host = UIHostingController(rootView: LossMotionFixture(state: state, prepared: prepared)
                .environment(\.colorScheme, scheme))
            host.safeAreaRegions = []
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 540)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
            for (name, range, delay) in [
                ("start", ChartTimeRange.oneYear, 100),
                ("week-mid", .oneWeek, 120),
                ("rapid-max-mid", .maximum, 90),
                ("rapid-month-mid", .oneMonth, 90),
                ("month-settled", .oneMonth, 550),
                ("year-settled", .oneYear, 550)
            ] {
                state.range = range
                try await Task.sleep(for: .milliseconds(delay))
                host.view.layoutIfNeeded()
                XCTAssertEqual(host.view.bounds.width, 393, accuracy: 1)
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                    host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
                }
                let filename = "\(scheme)-\(name)"
                let attachment = XCTAttachment(image: image)
                attachment.name = filename
                attachment.lifetime = .keepAlways
                add(attachment)
                try image.pngData()?.write(to: directory.appendingPathComponent(filename + ".png"))
            }
        }
    }

    private func history() -> HoldingValueHistory {
        let costs = Dictionary(uniqueKeysWithValues: ["A", "B", "C", "E", "F", "G"].map { ($0, 1000.0) })
        return HoldingValueHistory(rows: [
            .init(dateText: "2026-01-05", cost: 6000, values: costs, costs: costs),
            .init(dateText: "2026-04-02", cost: 6000,
                  values: ["A": 400, "E": 500, "C": 600, "B": 700, "G": 800, "F": 900], costs: costs),
            .init(dateText: "2026-09-17", cost: 6000,
                  values: ["A": 1100, "E": 800, "C": 900, "B": 1000, "G": 1005, "F": 990], costs: costs),
        ], costs: costs, names: ["A": "Alpha"])
    }

    func testLossRanksFollowHoldingsThroughHideAndRestore() {
        let original = HoldingLossStack(history: history(), range: .oneYear)
        XCTAssertEqual(original.holdingRanks, ["A": 1, "E": 2, "C": 3, "B": 4, "G": 5, "F": 6])
        XCTAssertEqual(original.bands.reversed().compactMap { original.rank(for: $0) }, [1, 2, 3, 4, 5])
        XCTAssertNil(original.rank(for: original.bands[0]), "Other losses is not a ranked holding")

        let hidden = HoldingLossStack(history: history(), range: .oneYear, hiding: ["A", "E", "B"])
        XCTAssertEqual(hidden.holdingRanks, original.holdingRanks)
        XCTAssertEqual(hidden.hidden.map(\.ticker), ["A", "E", "B"])
        XCTAssertEqual(hidden.hidden.compactMap { hidden.holdingRanks[$0.ticker] }, [1, 2, 4])
        XCTAssertEqual(hidden.bands.reversed().compactMap { hidden.rank(for: $0) }, [3, 5, 6])
        XCTAssertEqual(hidden.rows.map(\.totalLoss), original.rows.map(\.totalLoss))

        let restored = HoldingLossStack(history: history(), range: .oneYear, hiding: ["E", "B"])
        XCTAssertEqual(restored.holdingRanks, original.holdingRanks)
        XCTAssertEqual(restored.bands.reversed().compactMap { restored.rank(for: $0) }, [1, 3, 5, 6])
    }

    func testLossRankingUsesRangeDepthEvenWhenHoldingRecovered() {
        let annual = HoldingLossStack(history: history(), range: .oneYear)
        XCTAssertEqual(annual.bands.last?.title, "A", "The recovered holding had the deepest loss")
        XCTAssertEqual(annual.rows.last?.bands.last, 0)
        XCTAssertEqual(annual.rows.map(\.totalLoss), [0, 2100, 310])
        let recent = HoldingLossStack(history: history(), range: .oneWeek)
        XCTAssertNil(recent.holdingRanks["A"])
        XCTAssertEqual(recent.holdingRanks["E"], 1)
        XCTAssertEqual(recent.holdingRanks["C"], 2)
    }

    func testPreparedLossRangesPreserveDatesAmountsAndHiddenHoldings() throws {
        for hidden: Set<String> in [[], ["A", "E", "B"]] {
            let prepared = try HoldingLossRanges(history: history(), hiding: hidden)
            for range in ChartTimeRange.allCases {
                let actual = try XCTUnwrap(prepared[range])
                let expected = HoldingLossStack(history: history(), range: range, hiding: hidden)
                XCTAssertEqual(actual.rows.map(\.dateText), expected.rows.map(\.dateText))
                XCTAssertEqual(actual.rows.map(\.bands), expected.rows.map(\.bands))
                XCTAssertEqual(actual.rows.map(\.netGain), expected.rows.map(\.netGain))
                XCTAssertEqual(actual.rows.map(\.losingCount), expected.rows.map(\.losingCount))
                XCTAssertEqual(actual.bands.map(\.title), expected.bands.map(\.title))
                XCTAssertEqual(actual.holdingRanks, expected.holdingRanks)
                XCTAssertEqual(actual.hidden.map(\.ticker), expected.hidden.map(\.ticker))
            }
        }
        let refreshed = try HoldingLossRanges(history: .init(rows: [], costs: [:], names: [:]))
        XCTAssertTrue(try XCTUnwrap(refreshed[.maximum]).rows.isEmpty)
    }

    func testPreparedLossRangeLookupPerformance() throws {
        let prepared = try HoldingLossRanges(history: LossAnalysisChart.demoHistory())
        let ranges = ChartTimeRange.allCases
        measure {
            var count = 0
            for index in 0..<10_000 { count += prepared[ranges[index % ranges.count]]?.rows.count ?? 0 }
            XCTAssertGreaterThan(count, 0)
        }
    }

    func testPromotedLossKeepsItsRankInsteadOfItsReusedColour() {
        let costs = Dictionary(uniqueKeysWithValues: (1...7).map { ("G\($0)", 100.0) })
        let history = HoldingValueHistory(rows: [
            .init(dateText: "2026-01-05", cost: 700, values: costs, costs: costs),
            .init(dateText: "2026-01-06", cost: 700, values: costs.mapValues { $0 - 10 }, costs: costs),
        ], costs: costs, names: [:])
        let stack = HoldingLossStack(history: history, range: .oneYear, hiding: ["G2"])
        XCTAssertEqual(stack.bands.first { $0.title == "G7" }?.kind, .holding(colour: 1))
        XCTAssertEqual(stack.holdingRanks["G2"], 2)
        XCTAssertEqual(stack.bands.reversed().compactMap { stack.rank(for: $0) }, [1, 3, 4, 5, 6, 7])
    }

    @MainActor
    func testLossPageRendersInBothAppearances() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let value = history()
        for scheme in [ColorScheme.light, .dark] {
            let host = UIHostingController(rootView: ScrollView {
                LossAnalysisChart(fetchHistory: { _ in value })
            }.environment(AppModel()).environment(\.colorScheme, scheme))
            host.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .seconds(1))
            host.view.layoutIfNeeded()
            func scrollView(_ view: UIView) -> UIScrollView? {
                if let scroll = view as? UIScrollView { return scroll }
                return view.subviews.lazy.compactMap { scrollView($0) }.first
            }
            XCTAssertGreaterThan(try XCTUnwrap(scrollView(host.view)).contentSize.height, 600,
                                 "Loaded hero and ranked legend must replace the loading placeholder")
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "loss-sources-\(scheme == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

@Observable private final class LossMotionFixtureState {
    var range = ChartTimeRange.oneYear
}

private struct LossMotionFixture: View {
    @Bindable var state: LossMotionFixtureState
    let prepared: HoldingLossRanges
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let stack = prepared[state.range]!
        let series = LossAnalysisChart.chartSeries(stack: stack, visible: Array(stack.bands.indices), scheme: scheme)
        let bottom = -max(stack.rows.map(\.totalLoss).max() ?? 0, 1) * 1.08
        ReturnsSourceChartHero(range: $state.range,
            header: Text("Loss analysis").font(.title2).frame(height: 100),
            plot: StandardLineChart(series: series, interactionDates: stack.rows.map(\.date),
                domain: bottom...0, yTicks: [], axisWidth: 0, topInset: 4, bottomHeight: 0,
                trailingEndpointInset: 0, gridOpacity: 0, transitionKey: state.range.rawValue,
                dataTransition: .viewportZoom, animatesInitialAppearance: false,
                yAxisLabel: { _ in "" }, xAxisLabel: { _ in "" }),
            axis: EmptyView())
            .background(Color(uiColor: .systemBackground))
    }
}

/// The gain-sources chart: principal at the bottom, then the others, then one
/// band per big gainer, and the stack always adds up to the day's value.
final class HoldingContributionTests: XCTestCase {
    private var previousLanguagePreference: Any?

    override func setUp() {
        super.setUp()
        previousLanguagePreference = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.preferenceKey)
    }

    override func tearDown() {
        if let previousLanguagePreference {
            UserDefaults.standard.set(previousLanguagePreference, forKey: AppLanguage.preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey)
        }
        super.tearDown()
    }

    private static let tickers = ["A", "B", "C", "D", "E", "F"]
    private static let costs = Dictionary(uniqueKeysWithValues: tickers.map { ($0, 100.0) })

    private func history() -> HoldingValueHistory {
        HoldingValueHistory(
            rows: [
                .init(dateText: "2026-01-02", cost: 600,
                      values: Dictionary(uniqueKeysWithValues: Self.tickers.map { ($0, 100.0) }), costs: Self.costs),
                .init(dateText: "2026-09-11", cost: 600,
                      values: ["A": 400, "B": 150, "C": 300, "D": 90, "E": 200, "F": 120], costs: Self.costs),
            ],
            costs: Self.costs,
            names: ["A": "Alpha", "C": "Gamma"]
        )
    }

    func testBandIdentitySurvivesRepeatedHideRestoreAndPromotion() {
        var identities: [String: String] = [:]
        let changes: [Set<String>] = [[], ["A"], ["A", "C"], ["C"], [], ["A", "E", "B"], []]
        for _ in 0..<10 {
            for hidden in changes {
                let stack = HoldingContributionStack(history: history(), hiding: hidden)
                XCTAssertEqual(Set(stack.bands.map(\.id)).count, stack.bands.count)
                for band in stack.bands {
                    if let previous = identities[band.title] {
                        XCTAssertEqual(band.id, previous, "Reordering must not recycle another holding's row")
                    }
                    identities[band.title] = band.id
                    XCTAssertEqual(HoldingContributionChart.seriesID(band), band.id)
                }
            }
        }
    }

    @MainActor
    func testIncomeShadesRemainOrderedAfterHidingHoldings() {
        let environment = EnvironmentValues()
        for hiding: Set<String> in [[], ["A"], ["A", "E", "B"]] {
            let stack = HoldingContributionStack(history: history(), hiding: hiding)
            var previous: Float = 2
            for index in stack.bands.indices {
                let color = HoldingContributionChart.incomeFillColor(for: stack.bands[index].kind,
                    scheme: .light, rankFromTop: stack.bands.count - 1 - index).resolve(in: environment)
                let brightness = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
                XCTAssertLessThanOrEqual(brightness, previous, "Upper bands must be darker")
                previous = brightness
            }
        }
        var previous: Float = -1
        for rank in (0..<6).reversed() {
            let color = HoldingContributionChart.incomeFillColor(for: .holding(colour: rank), scheme: .light)
                .resolve(in: environment)
            let brightness = color.red + color.green + color.blue
            if previous >= 0 { XCTAssertLessThan(brightness, previous) }
            previous = brightness
        }
    }

    @MainActor
    func testTintedRankBadgesKeepTwoDigitWidthForLongRanks() async throws {
        let ranks = [1, 12, 99, 100, 999, 1000]
        for rank in ranks {
            let host = UIHostingController(rootView: ReturnsRankBadge(rank: rank, color: .blue,
                isPortfolio: false, usesTintedGlass: true))
            let size = host.sizeThatFits(in: CGSize(width: 300, height: 100))
            XCTAssertEqual(size.width, 36, accuracy: 0.5)
            XCTAssertEqual(size.height, 28, accuracy: 0.5)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: VStack(spacing: 20) {
            ForEach(ranks, id: \.self) { rank in
                HStack(spacing: 20) {
                    Text(String(rank)).frame(width: 50, alignment: .trailing)
                    ReturnsRankBadge(rank: rank, color: Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255),
                                     isPortfolio: false, usesTintedGlass: true)
                    ReturnsRankBadge(rank: rank, color: ReturnsSourceChartStyle.incomeBase,
                                     isPortfolio: false, usesTintedGlass: true)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ReturnsSourceChartStyle.incomeFooter))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(400))
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "tinted-rank-badges"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testIncomeHighlightBrightensBandAndMatchesLegend() throws {
        let cache = HoldingContributionPreparedCache()
        func prepared(_ highlighted: String?) -> HoldingContributionPreparedCache.Prepared {
            cache.prepared(history: history(), historyRevision: 1, holdings: [], hiding: [],
                           locale: Locale(identifier: "en_US"), language: "en", range: .yearToDate,
                           showsPrincipal: true, showsOthers: true, highlighted: highlighted, scheme: .light)
        }
        let normal = prepared(nil)
        let band = try XCTUnwrap(normal.stack.bands.first { if case .holding = $0.kind { true } else { false } })
        let id = HoldingContributionChart.seriesID(band)
        let highlighted = prepared(id)
        let before = try XCTUnwrap(normal.series.first { $0.id == id })
        let after = try XCTUnwrap(highlighted.series.first { $0.id == id })
        let environment = EnvironmentValues()
        let base = try XCTUnwrap(before.areaFill).resolve(in: environment)
        let bright = try XCTUnwrap(after.areaFill).resolve(in: environment)
        XCTAssertGreaterThan(bright.red + bright.green + bright.blue, base.red + base.green + base.blue)
        let legend = HoldingContributionChart.incomeDisplayColor(for: band.kind, scheme: .light,
                                                                 isHighlighted: true, isFaded: false)
        XCTAssertEqual(bright, legend.resolve(in: environment))
        XCTAssertEqual(bright, ReturnsSourceChartStyle.incomeBase.resolve(in: environment))
        for rank in 0..<6 {
            let selected = HoldingContributionChart.incomeDisplayColor(for: .holding(colour: rank),
                scheme: .light, isHighlighted: true, isFaded: false).resolve(in: environment)
            XCTAssertEqual(selected, bright, "Every highlighted band gets the brightest shade")
        }
        XCTAssertEqual(before.points.map(\.value), after.points.map(\.value))
        let restored = try XCTUnwrap(prepared(nil).series.first { $0.id == id })
        XCTAssertEqual(restored.areaFill?.resolve(in: environment), base)

        let renderer = ImageRenderer(content: VStack(spacing: 16) {
            ForEach([false, true], id: \.self) { selected in
                let color = HoldingContributionChart.incomeDisplayColor(for: band.kind, scheme: .light,
                                                                        isHighlighted: selected, isFaded: false)
                ReturnsSourceListRow(rank: 1, color: color, title: selected ? "Highlighted" : "Normal",
                                     subtitle: "Matching band and legend", isOn: true, isOnBlueField: true,
                                     isHighlighted: selected) { Text("+$300") }
                Rectangle().fill(color).frame(height: 40)
            }
        }.padding(24).frame(width: 402).background(ReturnsSourceChartStyle.incomeFooter))
        let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
        attachment.name = "income-legend-highlight"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testHistoryCacheHitDoesNotRequestNetwork() async throws {
        let state = HoldingHistoryState()
        let value = history()
        var requests: [Bool] = []
        await state.load { cachedOnly in
            requests.append(cachedOnly)
            return value
        }
        XCTAssertEqual(requests, [true])
        XCTAssertEqual(state.history?.rows.count, value.rows.count)
    }

    @MainActor
    func testExplicitHistoryRefreshStillRequestsNetwork() async throws {
        let state = HoldingHistoryState()
        let value = history()
        var requests: [Bool] = []
        await state.load(forceRefresh: true) { cachedOnly in
            requests.append(cachedOnly)
            return value
        }
        XCTAssertEqual(requests, [true, false])
    }

    @MainActor
    func testLoadingRetriesWhilePortfolioArrivesAndPreservesCosts() async throws {
        let state = HoldingHistoryState()
        let value = history()
        var networkAttempts = 0
        await state.load { cachedOnly in
            if cachedOnly { throw LocalPortfolioError.noPortfolio }
            networkAttempts += 1
            if networkAttempts == 1 { throw LocalPortfolioError.noPortfolio }
            return value
        }
        XCTAssertEqual(networkAttempts, 2)
        XCTAssertNil(state.errorMessage)
        let loaded = try XCTUnwrap(state.history)
        let stack = HoldingContributionStack(history: loaded)
        XCTAssertEqual(stack.rows.last?.principal, 600)
        XCTAssertEqual(stack.rows.last?.total, 1260)
        XCTAssertEqual(loaded.costs, Self.costs)
    }

    @MainActor
    func testChartReplacesLoadingPlaceholderWithVisibleContent() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var resume: CheckedContinuation<HoldingValueHistory, Never>?
        let requested = expectation(description: "History requested by the chart")
        let value = history()
        let host = UIHostingController(rootView: ScrollView {
            HoldingContributionChart(fetchHistory: { cachedOnly in
                if cachedOnly { throw LocalServiceError.noHistoricalPrices }
                return await withCheckedContinuation {
                    resume = $0
                    requested.fulfill()
                }
            })
        }.environment(AppModel()))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            resume?.resume(returning: value)
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [requested], timeout: 5)
        host.view.layoutIfNeeded()
        func scrollView(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView($0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(host.view))
        let loadingHeight = scroll.contentSize.height
        XCTAssertGreaterThanOrEqual(loadingHeight, 300)
        resume?.resume(returning: value)
        resume = nil
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            if scroll.contentSize.height > loadingHeight + 150 { break }
        }
        XCTAssertGreaterThan(scroll.contentSize.height, loadingHeight + 150,
                             "Loaded chart, range selector and legend must replace the placeholder")
        // Include the completed chart reveal, not its grey transition frame.
        try await Task.sleep(for: .seconds(1))
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "holding-contribution-loaded"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBigGainersGetBandsUntilTheNextIsASmallShare() {
        let stack = HoldingContributionStack(history: history())
        // Gains: A 300, C 200, E 100, B 50, F 20, D -10. F is 3% of the 670
        // gained, under the 6% bar, so it and D stay in the others.
        XCTAssertEqual(stack.bands.map(\.title), [L10n.text("本金"), L10n.text("其他收益"), "B", "E", "C", "A"])
        XCTAssertEqual(stack.bands[0].kind, .principal)
        XCTAssertEqual(stack.bands[1].kind, .others)
        XCTAssertEqual(stack.bands.last?.kind, .holding(colour: 0))
        XCTAssertEqual(stack.bands.last?.subtitle, "Alpha")
        XCTAssertTrue(stack.hidden.isEmpty)
    }

    func testBandsAddUpToEachDaysValue() throws {
        let stack = HoldingContributionStack(history: history())
        for (row, source) in zip(stack.rows, history().rows) {
            XCTAssertEqual(row.total, source.total, accuracy: 0.0001)
            XCTAssertEqual(row.principal, source.cost)
        }
        let last = try XCTUnwrap(stack.rows.last)
        XCTAssertEqual(last.bands, [600, 10, 50, 100, 200, 300])
        XCTAssertEqual(last.othersGain, 20 - 10, accuracy: 0.0001)
    }

    func testAHiddenHoldingLeavesTheChartAndTheNextTakesItsPlace() throws {
        let stack = HoldingContributionStack(history: history(), hiding: ["A"])
        // Without A: C 200, E 100, B 50, F 20 of 370 gained. F is 5.4%, still
        // under the bar.
        XCTAssertEqual(stack.bands.map(\.title), [L10n.text("本金"), L10n.text("其他收益"), "B", "E", "C"])
        // The rest keep their colours: C 1, E 2, B 3.
        XCTAssertEqual(stack.bands.dropFirst(2).map(\.kind), [.holding(colour: 3), .holding(colour: 2), .holding(colour: 1)])
        XCTAssertEqual(stack.hidden.map(\.ticker), ["A"])
        XCTAssertEqual(stack.hidden.first?.name, "Alpha")
        let last = try XCTUnwrap(stack.rows.last)
        XCTAssertEqual(last.othersGain, 20 - 10, accuracy: 0.0001)
        XCTAssertEqual(last.bands, [600, 10, 50, 100, 200])
        XCTAssertEqual(last.bands.reduce(0, +), 960, accuracy: 0.0001)
        XCTAssertEqual(stack.bands[1].subtitle, L10n.text("2 项持仓合计"))
        XCTAssertEqual(last.total, 1260, accuracy: 0.0001)
    }

    func testHiddenLossAndHiddenSmallGainAreExcludedFromOthers() throws {
        let hiddenGain = HoldingContributionStack(history: history(), hiding: ["F"])
        let gainRow = try XCTUnwrap(hiddenGain.rows.last)
        XCTAssertEqual(gainRow.othersGain, -10)
        XCTAssertEqual(gainRow.bands.reduce(0, +), 1240)
        let hiddenLoss = HoldingContributionStack(history: history(), hiding: ["D"])
        let lossRow = try XCTUnwrap(hiddenLoss.rows.last)
        XCTAssertEqual(lossRow.othersGain, 20)
        XCTAssertEqual(lossRow.bands.reduce(0, +), 1270)
        XCTAssertEqual(lossRow.total, 1260, "Visibility must not change the portfolio header")
    }

    func testHidingAllHoldingsLeavesNoOtherGainsAndRestoreRecoversBands() throws {
        let original = HoldingContributionStack(history: history())
        let hidden = HoldingContributionStack(history: history(), hiding: Set(Self.tickers))
        XCTAssertEqual(hidden.bands.count, 2)
        XCTAssertEqual(hidden.hidden.count, 6)
        XCTAssertEqual(hidden.bands[1].subtitle, L10n.text("0 项持仓合计"))
        for row in hidden.rows {
            XCTAssertEqual(row.othersGain, 0)
            XCTAssertEqual(row.bands, [row.principal, 0])
        }
        let restored = HoldingContributionStack(history: history(), hiding: [])
        XCTAssertEqual(restored.rows.map(\.bands), original.rows.map(\.bands))
        XCTAssertEqual(restored.bands.map(\.title), original.bands.map(\.title))
    }

    @MainActor
    func testOtherGainsLegendMatchesStripedAreaInBothAppearances() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let view = VStack(alignment: .leading, spacing: 20) {
                HStack {
                    ReturnsSourceLegendSwatch(color: .gray, isOn: true, isOtherGains: true)
                    Text("其他收益")
                    Spacer()
                    Text("+$10")
                }
                HStack {
                    ReturnsSourceLegendSwatch(color: .gray, isOn: false, isOtherGains: true)
                    Text("其他收益 · 已隐藏")
                }
                ForEach([DynamicTypeSize.large, .accessibility1], id: \.self) { size in
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach([1, 9, 10, 11, 99, 100], id: \.self) { rank in
                            HStack(spacing: 12) {
                                ReturnsSourceRankLabel(rank: rank, maximumRank: 100)
                                ReturnsSourceLegendSwatch(color: .blue, isOn: true)
                                Text("META").lineLimit(1)
                            }
                        }
                        HStack(spacing: 12) {
                            ReturnsSourceRankLabel(rank: nil, maximumRank: 100)
                            ReturnsSourceLegendSwatch(color: .gray, isOn: true, isOtherGains: true)
                            Text("Other").lineLimit(1)
                        }
                    }.environment(\.dynamicTypeSize, size)
                }
            }.padding(24).frame(width: 350)
                .foregroundStyle(scheme == .dark ? Color.white : .black)
                .background(scheme == .dark ? Color.black : .white)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
            attachment.name = "other-gains-legend-\(scheme == .dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testAHoldingSteppingInTakesTheFreedColour() {
        // Seven even gainers: the six-band cap leaves G7 out until G2 is hidden.
        let tickers = (1...7).map { "G\($0)" }
        let costs = Dictionary(uniqueKeysWithValues: tickers.map { ($0, 100.0) })
        let even = HoldingValueHistory(rows: [
            .init(dateText: "2026-01-02", cost: 700, values: costs, costs: costs),
            .init(dateText: "2026-01-05", cost: 700, values: costs.mapValues { $0 + 10 }, costs: costs),
        ], costs: costs, names: [:])
        XCTAssertFalse(HoldingContributionStack(history: even).bands.map(\.title).contains("G7"))

        let stack = HoldingContributionStack(history: even, hiding: ["G2"])
        let colours = Dictionary(uniqueKeysWithValues: stack.bands.dropFirst(2).map { ($0.title, $0.kind) })
        XCTAssertEqual(colours["G7"], .holding(colour: 1), "G7 takes G2's colour")
        XCTAssertEqual(colours["G1"], .holding(colour: 0))
        XCTAssertEqual(colours["G3"], .holding(colour: 2))
        XCTAssertNil(colours["G2"])
        XCTAssertEqual(stack.holdingRanks["G2"], 2, "The hidden holding keeps its original rank")
        XCTAssertEqual(stack.holdingRanks["G7"], 7, "A promoted holding keeps its rank, not the freed colour's rank")
        XCTAssertEqual(stack.bands.reversed().compactMap { stack.rank(for: $0) }, [1, 3, 4, 5, 6, 7])
    }

    func testGainRanksFollowHoldingsThroughHideAndRestore() {
        let original = HoldingContributionStack(history: history())
        XCTAssertEqual(original.bands.reversed().compactMap { original.rank(for: $0) }, [1, 2, 3, 4])
        XCTAssertNil(original.rank(for: original.bands[0]), "Principal is not a ranked holding")
        XCTAssertNil(original.rank(for: original.bands[1]), "Other gains is an aggregate")

        let hidden = HoldingContributionStack(history: history(), hiding: ["A", "E", "B"])
        XCTAssertEqual(hidden.holdingRanks, original.holdingRanks)
        XCTAssertEqual(hidden.hidden.map(\.ticker), ["A", "E", "B"], "Hidden rows retain gain order, not ticker order")
        XCTAssertEqual(hidden.hidden.compactMap { hidden.holdingRanks[$0.ticker] }, [1, 3, 4])
        XCTAssertEqual(hidden.bands.reversed().compactMap { hidden.rank(for: $0) }, [2, 5])

        let restored = HoldingContributionStack(history: history(), hiding: ["E", "B"])
        XCTAssertEqual(restored.holdingRanks, original.holdingRanks)
        XCTAssertEqual(restored.bands.reversed().compactMap { restored.rank(for: $0) }, [1, 2])
    }

    func testHidingSomethingNotHeldChangesNothing() {
        let stack = HoldingContributionStack(history: history(), hiding: ["ZZZ"])
        XCTAssertTrue(stack.hidden.isEmpty)
        XCTAssertEqual(stack.bands.count, 6)
    }

    func testTheOthersLossesComeOutOfThePrincipalBand() throws {
        let losing = HoldingValueHistory(rows: [
            .init(dateText: "2026-01-02", cost: 200, values: ["A": 100, "B": 100], costs: ["A": 100, "B": 100]),
            .init(dateText: "2026-01-05", cost: 200, values: ["A": 200, "B": 50], costs: ["A": 100, "B": 100]),
        ], costs: ["A": 100, "B": 100], names: [:])
        let stack = HoldingContributionStack(history: losing)
        XCTAssertEqual(stack.bands.map(\.title), [L10n.text("本金"), L10n.text("其他收益"), "A"])
        let last = try XCTUnwrap(stack.rows.last)
        XCTAssertEqual(last.bands, [150, 0, 100])
        XCTAssertEqual(last.principal, 200)
        XCTAssertEqual(last.othersGain, -50)
        XCTAssertEqual(last.total, 250)
    }

    func testNamedCount() {
        XCTAssertEqual(HoldingContributionStack.namedCount([]), 0)
        XCTAssertEqual(HoldingContributionStack.namedCount([-5, 0]), 0)
        XCTAssertEqual(HoldingContributionStack.namedCount([1, 100]), 1, "The first always counts; 1% does not")
        XCTAssertEqual(HoldingContributionStack.namedCount(Array(repeating: 10, count: 10)), 6)
    }
}
