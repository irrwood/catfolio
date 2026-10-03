import SwiftUI

/// Every cycle of a chosen length, laid over the others from its own start:
/// how far this stretch of the calendar has come against the same stretch
/// before it.
///
/// Cycles begin on 1 January of a year divisible by their length — the
/// decade for ten years, as the decennial pattern counts them — so the
/// current one is part-way through. Portfolio cycles also retain partial
/// history; complete cycles use the last close before they began.
struct CycleComparison: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        /// How far through the cycle, from 0 to 1.
        let fraction: Double
        /// Percent from the cycle's start.
        let value: Double
    }

    struct Cycle: Equatable, Sendable, Identifiable {
        let startYear: Int
        let length: Int
        let points: [Point]
        let isCurrent: Bool
        /// The month each cycle begins in; 1 for calendar years.
        var startMonth = 1
        /// The first day of a history that began after the cycle did; the
        /// line is measured from there.
        var joined: String? = nil
        /// A historical cycle whose available history stops before year-end.
        var ended: String? = nil
        var id: Int { startYear }

        var isComplete: Bool {
            !isCurrent && joined == nil && points.first?.fraction == 0 && points.last?.fraction == 1
        }

        var coverageLabel: String {
            let since = joined.map { L10n.text("（\(String($0.dropFirst(5))) 起）") } ?? ""
            let until = ended.map { L10n.text("（截至 \(String($0.dropFirst(5)))）") } ?? ""
            return since + until
        }

        var title: String {
            // A year starting in April runs into the next: 2025/26.
            let endYear = startYear + length - (startMonth == 1 ? 1 : 0)
            if endYear == startYear { return "\(startYear)" }
            return length == 1 && startMonth != 1
                ? "\(startYear)/\(String(endYear).suffix(2))"
                : "\(startYear)–\(String(endYear).suffix(2))"
        }
    }

    /// Samples per cycle: eight to each of the chart's twelve columns.
    static let steps = 96

    let cycles: [Cycle]

    var current: Cycle? { cycles.first(where: \.isCurrent) }

    /// Partial years use a different baseline and must not enter the mean.
    var completePastCycles: [Cycle] { cycles.filter(\.isComplete) }

    /// - Parameters:
    ///   - closes: a value by day — closes for an index, the unit value for
    ///     the portfolio.
    ///   - lookback: years before the current cycle a past cycle must start
    ///     within.
    ///   - allowsLateStart: retains partial portfolio cycles, starting on
    ///     the first available day and ending where the history ends.
    ///   - startMonth: the month every cycle begins in, 1 to 12.
    static func make(closes: [String: Double], length: Int, lookback: Int, today: Date = Date(),
                     allowsLateStart: Bool = false, startMonth: Int = 1) -> CycleComparison {
        let dates = closes.keys.sorted()
        guard length > 0, let latest = dates.last, let year = Int(DayDateCodec.string(from: today).prefix(4)) else {
            return CycleComparison(cycles: [])
        }
        let last = min(latest, DayDateCodec.string(from: today))

        /// The latest day on or before `day` (strictly before, if asked).
        func index(onOrBefore day: String, strictly: Bool = false) -> Int? {
            var low = 0, high = dates.count
            while low < high {
                let middle = (low + high) / 2
                if strictly ? dates[middle] < day : dates[middle] <= day { low = middle + 1 } else { high = middle }
            }
            return low > 0 ? low - 1 : nil
        }

        let month = min(12, max(1, startMonth))
        let todayMonth = Int(DayDateCodec.string(from: today).dropFirst(5).prefix(2)) ?? 1
        // Before this year's start month, the running cycle began last year.
        let cycleYear = todayMonth < month ? year - 1 : year
        let currentStart = cycleYear - ((cycleYear % length) + length) % length
        let pastStarts = stride(from: currentStart - length, through: currentStart - lookback, by: -length).reversed()
        var cycles: [Cycle] = []
        for start in Array(pastStarts) + [currentStart] {
            let isCurrent = start == currentStart
            let startText = String(format: "%04d-%02d-01", start, month)
            guard let startDate = DayDateCodec.date(from: startText),
                  let endDate = DayDateCodec.date(from: String(format: "%04d-%02d-01", start + length, month)) else { continue }
            let span = endDate.timeIntervalSince(startDate)
            let before = index(onOrBefore: startText, strictly: true)
            let base: Double
            var joined: String?
            var first = 0.0
            if let before, let baseDay = DayDateCodec.date(from: dates[before]),
               startDate.timeIntervalSince(baseDay) <= 10 * 86_400,
               let value = closes[dates[before]], value > 0 {
                base = value
            } else if allowsLateStart {
                let firstIndex = (before ?? -1) + 1
                guard firstIndex < dates.count, dates[firstIndex] <= last,
                      let value = closes[dates[firstIndex]], value > 0,
                      let firstDay = DayDateCodec.date(from: dates[firstIndex]),
                      firstDay >= startDate, firstDay < endDate else { continue }
                base = value
                joined = dates[firstIndex]
                first = firstDay.timeIntervalSince(startDate) / span
            } else {
                continue
            }
            var points = [Point(fraction: first, value: 0)]
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                guard fraction > first else { continue }
                let day = DayDateCodec.string(from: startDate.addingTimeInterval(span * fraction))
                guard day <= last else { break }
                guard let at = index(onOrBefore: day), let value = closes[dates[at]] else { continue }
                points.append(Point(fraction: fraction, value: (value / base - 1) * 100))
            }
            var ended: String?
            if isCurrent || allowsLateStart {
                // The line ends on the latest close, not the last whole step.
                if let lastDay = DayDateCodec.date(from: last), let value = closes[last] {
                    let fraction = lastDay.timeIntervalSince(startDate) / span
                    if fraction > (points.last?.fraction ?? 0), fraction < 1 {
                        points.append(Point(fraction: fraction, value: (value / base - 1) * 100))
                    }
                    if !isCurrent, fraction < 1 { ended = last }
                }
                guard points.count > 1 else { continue }
            } else {
                // A past cycle is drawn whole or not at all.
                guard points.count == steps + 1 else { continue }
            }
            var cycle = Cycle(startYear: start, length: length, points: points, isCurrent: isCurrent,
                              joined: joined, ended: ended)
            cycle.startMonth = month
            cycles.append(cycle)
        }
        return CycleComparison(cycles: cycles)
    }

    /// One of the four steps each side of zero on the axis: a round number
    /// that fits the widest move in view.
    static func axisStep(for cycles: [Cycle]) -> Double {
        let widest = cycles.flatMap(\.points).map { abs($0.value) }.max() ?? 0
        return roundStep(widest / 4)
    }

    static func roundStep(_ raw: Double) -> Double {
        guard raw.isFinite, raw > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(raw)))
        for multiple in [1, 2, 2.5, 5, 10] where multiple * magnitude >= raw {
            return max(1, multiple * magnitude)
        }
        return max(1, 10 * magnitude)
    }
}

/// Research's cycle comparison: each of the last few calendar years of an
/// index laid over the others from 1 January, with this year running
/// through today — and the portfolio's own year on every index. The legend
/// below chooses the lines and reads them at the chosen day.
struct CycleComparisonView: View {
    enum Subject: String, CaseIterable, Identifiable {
        case portfolio = "MY", spx = "SPX", ndx = "NDX", dji = "DJI", rut = "RUT"
        var id: String { rawValue }

        /// The index itself, not a fund tracking it: price only, and decades
        /// of history.
        var symbol: String? {
            switch self {
            case .portfolio: nil
            case .spx: "^GSPC"
            case .ndx: "^NDX"
            case .dji: "^DJI"
            case .rut: "^RUT"
            }
        }

        var title: String { self == .portfolio ? L10n.text("MY") : rawValue }
    }

    /// One drawn line and its legend chip.
    private struct Line: Identifiable {
        let id: String
        let title: String
        let cycle: CycleComparison.Cycle
        let color: Color
        /// This year: drawn heavier, ending in a ring.
        let isNow: Bool
        var dash: [CGFloat] = []

        /// The line's value at a point in the year — its last before it, so
        /// this year reads its latest close past today.
        func value(at fraction: Double) -> Double? {
            cycle.points.last { $0.fraction <= fraction + 1e-9 }?.value
        }
    }

    /// How many earlier years are laid over this one.
    static let yearChoices = [1, 2, 3, 5, 10]
    /// Early enough for ten earlier years and the close before the first.
    private static let historyStart = "2014-12-01"
    private static let portfolioLineID = "my"
    private static let currentLineID = "current"
    private static let averageLineID = "average"

    @Environment(AppModel.self) private var model
    @Environment(\.locale) private var appLocale
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @AppStorage("research.cycle.subject") private var subjectID = Subject.spx.rawValue
    @AppStorage("research.cycle.years") private var years = 5
    /// The month every cycle starts in; dragging the month axis moves it.
    @AppStorage("research.cycle.startMonth") private var startMonth = 1
    /// The axis drag's starting month and how many columns it has moved.
    @State private var axisDragStart: Int?
    @State private var histories: [Subject: [String: Double]] = [:]
    @State private var failures: [Subject: String] = [:]
    /// Lines the reader turned off. Every line starts on.
    @State private var hidden: Set<String> = []
    @State private var selectedDate: Date?

    private var subject: Subject { Subject(rawValue: subjectID) ?? .spx }

    /// Every line for the current choices: the earlier years, earliest
    /// first, then this year, then the portfolio's on top.
    private var lines: [Line]? {
        guard let closes = histories[subject] else { return nil }
        let comparison = CycleComparison.make(closes: closes, length: 1, lookback: effectiveYears,
                                              allowsLateStart: subject == .portfolio, startMonth: startMonth)
        let past = comparison.cycles.filter { !$0.isCurrent }
        var lines = past.enumerated().map { index, cycle in
            Line(id: "\(cycle.startYear)", title: cycle.title + cycle.coverageLabel, cycle: cycle,
                 color: Self.palette[(past.count - 1 - index) % Self.palette.count], isNow: false)
        }
        // The earlier years' mean at each point of the year: the shape the
        // year has taken on average.
        let complete = comparison.completePastCycles
        if complete.count > 1 {
            let points = (0...CycleComparison.steps).map { step in
                let values = complete.map { $0.points[step].value }
                return CycleComparison.Point(fraction: Double(step) / Double(CycleComparison.steps),
                                             value: values.reduce(0, +) / Double(max(values.count, 1)))
            }
            let average = CycleComparison.Cycle(startYear: 0, length: 1, points: points, isCurrent: false)
            lines.append(Line(id: Self.averageLineID, title: L10n.text("\(complete.count) 年均值"), cycle: average,
                              color: Self.averageColor, isNow: false, dash: [6, 4]))
        }
        if let current = comparison.current {
            if subject == .portfolio {
                lines.append(portfolioLine(current))
            } else {
                lines.append(Line(id: Self.currentLineID, title: L10n.text("\(current.title) 当前"),
                                  cycle: current, color: .primary, isNow: true))
            }
        }
        if subject != .portfolio, let closes = histories[.portfolio],
           let mine = CycleComparison.make(closes: closes, length: 1, lookback: 0, allowsLateStart: true,
                                           startMonth: startMonth).current {
            lines.append(portfolioLine(mine))
        }
        return lines
    }

    /// The year counts that draw something more: up to the earlier years the
    /// history actually covers, and the first count that reaches all of them.
    /// The portfolio's own history is often only a year or two long.
    private var availableYearChoices: Set<Int> {
        guard let closes = histories[subject] else { return Set(Self.yearChoices) }
        let available = CycleComparison.make(closes: closes, length: 1, lookback: Self.yearChoices.max() ?? 10,
                                             allowsLateStart: subject == .portfolio, startMonth: startMonth)
            .cycles.filter { !$0.isCurrent }.count
        let cap = Self.yearChoices.first { $0 >= available } ?? Self.yearChoices.max() ?? 10
        return Set(Self.yearChoices.filter { $0 <= cap })
    }

    private var effectiveYears: Int {
        let choices = availableYearChoices
        return choices.contains(years) ? years : choices.filter { $0 < years }.max() ?? years
    }

    private func portfolioLine(_ cycle: CycleComparison.Cycle) -> Line {
        return Line(id: Self.portfolioLineID, title: L10n.text("MY") + cycle.coverageLabel, cycle: cycle,
                    color: Self.portfolioColor, isNow: true)
    }

    /// The day the legend reads: the one pressed, or today.
    private var readFraction: Double {
        if let selectedDate { return Self.fraction(for: selectedDate) }
        return fraction(ofCycleAt: Date())
    }

    var body: some View {
        let lines = self.lines
        ScrollView {
            VStack(spacing: 0) {
                chart(lines ?? [])
                    .frame(height: 510)
                    .padding(.top, 16)

                // The charts' own range strip, counted in years.
                // A count the history cannot fill shows as the largest it can;
                // the stored choice stays for the indices with longer history.
                CycleYearsPicker(selection: Binding(get: { effectiveYears }, set: { years = $0 }),
                                 choices: Self.yearChoices, enabled: availableYearChoices)
                    .frame(height: 62)

                if let lines, !lines.isEmpty {
                    legend(lines)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }

                Color.clear.frame(height: 40)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(L10n.text("周期对比"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbar {
            // What the years are measured on, picked from the corner.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(L10n.text("对比对象"), selection: $subjectID) {
                        ForEach(Subject.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(subject.title).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    }
                }
                .accessibilityLabel(L10n.text("对比对象"))
                .accessibilityValue(subject.title)
            }
        }
        .onChange(of: years) { _, _ in selectedDate = nil }
        .onChange(of: startMonth) { _, _ in selectedDate = nil }

        .sensoryFeedback(.selection, trigger: startMonth) { _, _ in hapticsEnabled }
        .onChange(of: subjectID) { _, _ in
            hidden = []
            selectedDate = nil
        }
        .task(id: subject) {
            await load(subject)
            // The portfolio's line is drawn on every index.
            if subject != .portfolio { await load(.portfolio) }
        }
        .onChange(of: model.comparisonRevision) { _, _ in
            updatePortfolioHistory()
        }
        .onChange(of: model.isReturnsLoading) { _, isLoading in
            if !isLoading { updatePortfolioHistory() }
        }
        .sensoryFeedback(.selection, trigger: hidden) { _, _ in hapticsEnabled }
    }

    // MARK: Chart

    private func chart(_ lines: [Line]) -> some View {
        let visible = lines.filter { !hidden.contains($0.id) }
        return GeometryReader { geometry in
            let height = geometry.size.height
            ZStack(alignment: .topLeading) {
                columns
                // The half below zero sits a shade darker, fading downward.
                LinearGradient(
                    stops: [.init(color: .primary, location: 0.14), .init(color: .primary.opacity(0), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                .opacity(0.05)
                .frame(height: height / 2)
                .offset(y: height / 2)

                if !visible.isEmpty {
                    let step = CycleComparison.axisStep(for: visible.map(\.cycle))
                    plot(visible, step: step)
                    yLabels(step: step, height: height)
                        .frame(width: 23)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 5)
                } else {
                    placeholder(hasLines: !lines.isEmpty)
                }

                xLabels
                    .frame(height: 30)
                    .offset(y: height - 30)
            }
            .clipped()
        }
    }

    /// Twelve months, every other one shaded and fading at both ends.
    private var columns: some View {
        HStack(spacing: 0) {
            ForEach(0..<12, id: \.self) { index in
                if index.isMultiple(of: 2) {
                    Color.clear
                } else {
                    LinearGradient(
                        stops: [
                            .init(color: .primary.opacity(0), location: 0),
                            .init(color: .primary, location: 0.3),
                            .init(color: .primary, location: 0.7),
                            .init(color: .primary.opacity(0), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                    .opacity(0.05)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Four steps each side of zero occupy the middle three quarters of the
    /// height; the lines may still run past them.
    private static let labelledShare = 192.0 / 255.0

    private func plot(_ lines: [Line], step: Double) -> some View {
        let half = 4 * step / Self.labelledShare
        let series = lines.map { line in
            StandardLineChartSeries(
                id: line.id,
                points: line.cycle.points.map {
                    StandardLineChartPoint(id: "\(line.id)|\($0.fraction)", date: Self.date(for: $0.fraction), value: $0.value)
                },
                color: line.color,
                lineWidth: line.isNow || line.id == Self.averageLineID ? 2.5 : 2,
                dash: line.dash,
                selectionRadius: line.isNow ? 3.6 : 2.8,
                latestPointRadius: line.isNow ? 5 : nil,
                latestPointUsesGlass: false
            )
        }
        return StandardLineChart(
            series: series,
            interactionDates: (0...CycleComparison.steps).map { Self.date(for: Double($0) / Double(CycleComparison.steps)) },
            domain: -half...half,
            yTicks: [0],
            axisWidth: 0,
            topInset: 0,
            bottomHeight: 0,
            leadingLineOverflow: 0,
            trailingEndpointInset: 0,
            gridOpacity: 0,
            transitionKey: "\(subject.rawValue)|\(years)|\(hidden.sorted().joined(separator: ","))",
            appearanceID: "cycle-\(subject.rawValue)",
            animatesInitialAppearance: true,
            selectedDate: selectedDate,
            selectionIndicatorLabel: selectedDate.map { dayText(for: Self.fraction(for: $0)) },
            selectionSeriesIDs: Set(series.map(\.id)),
            yAxisLabel: { _ in "" },
            xAxisLabel: { _ in "" },
            onSelect: { selectedDate = $0 },
            onInteractionEnded: { _ in selectedDate = nil }
        )
        .accessibilityLabel(L10n.text("\(subject.title) 最近 \(years) 年的逐年走势对比"))
    }

    private func yLabels(step: Double, height: CGFloat) -> some View {
        let unit = height / 2 * Self.labelledShare / 4
        return ZStack {
            ForEach(-4...4, id: \.self) { index in
                Text(Self.axisText(Double(index) * step))
                    .font(Typography.number(size: 14, weight: .medium))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .position(x: 11.5, y: height / 2 - CGFloat(index) * unit)
            }
        }
        .allowsHitTesting(false)
    }

    /// The months, from the one the cycles start in. Drag them sideways to
    /// start the cycles a month earlier or later — a fiscal year, say.
    private var xLabels: some View {
        GeometryReader { geometry in
            let column = geometry.size.width / 12
            HStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { offset in
                    let month = (startMonth - 1 + offset) % 12 + 1
                    Text("\(month)")
                        .font(Typography.number(size: 14, weight: offset == 0 ? .semibold : .medium))
                        .tracking(0.7)
                        .foregroundStyle(offset == 0 ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 6)
                .onChanged { value in
                    let start = axisDragStart ?? startMonth
                    if axisDragStart == nil { axisDragStart = start }
                    // Dragging left brings later months to the front.
                    let steps = Int((-value.translation.width / column).rounded())
                    let month = ((start - 1 + steps) % 12 + 12) % 12 + 1
                    if month != startMonth { startMonth = month }
                }
                .onEnded { _ in axisDragStart = nil })
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.text("周期起始月份"))
        .accessibilityValue(L10n.text("\(startMonth) 月"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: startMonth = startMonth % 12 + 1
            case .decrement: startMonth = (startMonth + 10) % 12 + 1
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private func placeholder(hasLines: Bool) -> some View {
        Group {
            if hasLines {
                ContentUnavailableView(L10n.text("没有选中的曲线"), systemImage: "line.3.horizontal.decrease",
                                       description: Text(L10n.text("在下方轻点曲线把它加回来。")))
            } else if let failure = failures[subject] {
                ContentUnavailableView(L10n.text("暂无周期数据"), systemImage: "chart.xyaxis.line", description: Text(failure))
            } else if histories[subject] != nil {
                ContentUnavailableView(L10n.text("暂无周期数据"), systemImage: "chart.xyaxis.line",
                                       description: Text(L10n.text("还没有可用的组合收益历史。")))
            } else {
                StandardLineChartSkeleton(axisWidth: 0, topInset: 0, seriesCount: 3,
                    lineWidths: [2.5, 2.5, 2], appearanceID: "cycle-\(subject.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Legend

    /// One row per line, ranked by its move to the day being read — the
    /// same rows as the returns comparison. A tap shows or hides the line.
    private func legend(_ lines: [Line]) -> some View {
        let fraction = readFraction
        let ranked = lines.map { (line: $0, value: $0.value(at: fraction)) }.sorted {
            ($0.value ?? -.infinity) > ($1.value ?? -.infinity)
        }
        return VStack(spacing: 12) {
            ForEach(Array(ranked.enumerated()), id: \.element.line.id) { index, entry in
                row(entry.line, value: entry.value, rank: index + 1)
            }
        }
    }

    private func row(_ line: Line, value: Double?, rank: Int) -> some View {
        let isShown = !hidden.contains(line.id)
        return Button {
            if isShown { hidden.insert(line.id) } else { hidden.remove(line.id) }
            selectedDate = nil
        } label: {
            HStack(spacing: 16) {
                ReturnsRankBadge(rank: rank, color: line.color, isPortfolio: line.id == Self.portfolioLineID)
                Text(line.title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                if let value {
                    HStack(spacing: 0) {
                        Text("\(value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1))))")
                        Text("%").foregroundStyle(.primary.opacity(0.3))
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                } else {
                    Text("—").font(.system(size: 15, weight: .semibold, design: .rounded))
                }
            }
            .foregroundStyle(CatfolioTheme.primaryText)
            .padding(.horizontal, 16)
            .frame(height: 65)
            .background { ReturnsGlassCardSurface() }
            .opacity(isShown ? 1 : 0.2)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(line.title)
        .accessibilityValue((isShown ? L10n.text("已显示") : L10n.text("已隐藏")) + " · "
            + (value.map { DisplayFormat.percent($0) } ?? "—"))
    }

    // MARK: Values

    private static let portfolioColor = Color(red: 0.204, green: 0.780, blue: 0.349)
    private static let averageColor = Color(red: 1.000, green: 0.769, blue: 0.169)
    /// Earlier years, most recent first.
    private static let palette: [Color] = [
        Color(red: 1.000, green: 0.584, blue: 0.000),
        Color(red: 0.204, green: 0.459, blue: 1.000),
        Color(red: 0.627, green: 0.804, blue: 1.000),
        Color(red: 0.890, green: 0.000, blue: 0.271),
        Color(red: 0.780, green: 0.000, blue: 0.910),
        Color(red: 0.776, green: 0.800, blue: 0.000),
        Color(red: 1.000, green: 0.824, blue: 0.741),
        Color(red: 0.000, green: 0.882, blue: 0.698),
        Color(red: 1.000, green: 0.431, blue: 0.702),
        Color(red: 0.722, green: 0.600, blue: 1.000),
    ]

    /// Positions on the shared axis. Only their spacing matters.
    private static func date(for fraction: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: fraction * 1_000_000)
    }

    private static func fraction(for date: Date) -> Double {
        date.timeIntervalSinceReferenceDate / 1_000_000
    }

    /// The running cycle's first day: this year's start month, or last
    /// year's before it comes round.
    private func currentCycleStart(_ date: Date = Date()) -> (start: Date, end: Date)? {
        let text = DayDateCodec.string(from: date)
        guard let year = Int(text.prefix(4)), let month = Int(text.dropFirst(5).prefix(2)) else { return nil }
        let startYear = month < startMonth ? year - 1 : year
        guard let start = DayDateCodec.date(from: String(format: "%04d-%02d-01", startYear, startMonth)),
              let end = DayDateCodec.date(from: String(format: "%04d-%02d-01", startYear + 1, startMonth))
        else { return nil }
        return (start, end)
    }

    /// How far through its cycle a day is.
    private func fraction(ofCycleAt date: Date) -> Double {
        guard let cycle = currentCycleStart(date) else { return 0 }
        return min(1, max(0, date.timeIntervalSince(cycle.start) / cycle.end.timeIntervalSince(cycle.start)))
    }

    /// A point in the cycle as a month and day of the running one.
    private func dayText(for fraction: Double) -> String {
        guard let cycle = currentCycleStart() else { return "" }
        let day = cycle.start.addingTimeInterval(cycle.end.timeIntervalSince(cycle.start) * fraction)
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().locale(appLocale)
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return day.formatted(style)
    }

    static func axisText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : value.formatted(.number.precision(.fractionLength(1)))
    }

    // MARK: Loading

    private func load(_ subject: Subject) async {
        failures[subject] = nil
        if let symbol = subject.symbol {
            guard histories[subject] == nil else { return }
            let today = DayDateCodec.string(from: Date())
            let fetched = await LocalMarketDataClient().historicalCloses(symbols: [symbol], from: Self.historyStart, to: today)
            guard !Task.isCancelled else { return }
            if let closes = fetched[symbol], closes.count > 1 {
                histories[subject] = closes
            } else {
                failures[subject] = L10n.text("\(subject.rawValue) 的历史行情暂时读不到，稍后再试。")
            }
            return
        }
        // The portfolio's own unit value, from the comparison the returns
        // page already computes and keeps.
        if model.comparison == nil, !model.isReturnsLoading {
            await model.refreshReturns()
        }
        guard !Task.isCancelled else { return }
        updatePortfolioHistory()
    }

    /// The returns page may finish rebuilding after this page has opened.
    /// Replace the local copy on every revision, including an empty result
    /// after an account change, so the previous account cannot linger.
    private func updatePortfolioHistory() {
        var closes: [String: Double] = [:]
        if let comparison = model.comparison, let dates = comparison.twrDates, let navs = comparison.twrPortfolio {
            for (date, nav) in zip(dates, navs) {
                if let nav, nav.isFinite, nav > 0 { closes[date] = nav }
            }
        }
        if closes.count > 1 {
            histories[.portfolio] = closes
            failures[.portfolio] = nil
        } else {
            histories[.portfolio] = nil
            failures[.portfolio] = model.isReturnsLoading ? nil : L10n.text("还没有可用的组合收益历史。")
        }
    }
}

/// The shared range strip's look — 44 × 30 pills on the page's subtle fill —
/// for a choice counted in years.
struct CycleYearsPicker: View {
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    @Binding var selection: Int
    let choices: [Int]
    /// Counts beyond the history there is show, greyed, but cannot be chosen.
    var enabled: Set<Int>? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.self) { years in
                let isSelected = selection == years
                let isEnabled = enabled?.contains(years) ?? true
                Button { selection = years } label: {
                    Text(L10n.text("\(years)年"))
                        .appText(.footnote, weight: isSelected ? .semibold : .medium)
                        .foregroundStyle(isSelected ? (colorScheme == .light ? Color.black : Color.white)
                                         : isEnabled ? Color.secondary : Color.secondary.opacity(0.35))
                        .lineLimit(1)
                        .frame(width: 44, height: 30)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CatfolioTheme.subtleFill)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
        .sensoryFeedback(.selection, trigger: selection) { _, _ in hapticsEnabled }
        .accessibilityLabel(L10n.text("对比年数"))
    }
}
