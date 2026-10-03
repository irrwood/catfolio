import Foundation

/// The US Treasury's own daily par yield curve: the official figures the
/// market's ^TNX quotes approximate. No key; one CSV per calendar year.
struct TreasuryYieldCurve: Equatable, Sendable {
    enum Maturity: String, CaseIterable, Codable, Sendable {
        case oneMonth = "1 Mo", twoMonths = "2 Mo", threeMonths = "3 Mo", fourMonths = "4 Mo", sixMonths = "6 Mo"
        case oneYear = "1 Yr", twoYears = "2 Yr", threeYears = "3 Yr", fiveYears = "5 Yr", sevenYears = "7 Yr"
        case tenYears = "10 Yr", twentyYears = "20 Yr", thirtyYears = "30 Yr"

        /// Years to maturity, for spacing the curve.
        var years: Double {
            switch self {
            case .oneMonth: 1.0 / 12
            case .twoMonths: 2.0 / 12
            case .threeMonths: 0.25
            case .fourMonths: 4.0 / 12
            case .sixMonths: 0.5
            case .oneYear: 1
            case .twoYears: 2
            case .threeYears: 3
            case .fiveYears: 5
            case .sevenYears: 7
            case .tenYears: 10
            case .twentyYears: 20
            case .thirtyYears: 30
            }
        }

        var label: String {
            switch self {
            case .oneMonth: "1M"
            case .twoMonths: "2M"
            case .threeMonths: "3M"
            case .fourMonths: "4M"
            case .sixMonths: "6M"
            case .oneYear: "1Y"
            case .twoYears: "2Y"
            case .threeYears: "3Y"
            case .fiveYears: "5Y"
            case .sevenYears: "7Y"
            case .tenYears: "10Y"
            case .twentyYears: "20Y"
            case .thirtyYears: "30Y"
            }
        }
    }

    struct Day: Equatable, Sendable, Codable {
        let date: String
        /// Percent, as published: 4.25 is 4.25%.
        let yields: [Maturity: Double]
    }

    /// Oldest first.
    let days: [Day]

    var latest: Day? { days.last }

    /// The last published day on or before `date`.
    func day(onOrBefore date: String) -> Day? {
        days.last { $0.date <= date }
    }

    /// One maturity's history as dated closes, the shape the market charts use.
    func history(_ maturity: Maturity) -> [String: Double] {
        Dictionary(days.compactMap { day in day.yields[maturity].map { (day.date, $0) } },
                   uniquingKeysWith: { _, last in last })
    }

    /// The published CSV: `Date,"1 Mo",…` with MM/dd/yyyy dates, newest first.
    static func parse(_ text: String) -> [Day] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first?.split(separator: ",").map({
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }) else { return [] }
        let maturities = header.map { Maturity(rawValue: $0) }
        return lines.dropFirst().compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
            guard let raw = fields.first, let date = isoDate(raw) else { return nil }
            var yields: [Maturity: Double] = [:]
            for (index, field) in fields.enumerated() {
                guard index < maturities.count, let maturity = maturities[index],
                      let value = Double(field), value.isFinite else { continue }
                yields[maturity] = value
            }
            return yields.isEmpty ? nil : Day(date: date, yields: yields)
        }.sorted { $0.date < $1.date }
    }

    private static func isoDate(_ text: String) -> String? {
        let parts = text.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return String(format: "%04d-%02d-%02d", parts[2], parts[0], parts[1])
    }
}

/// Reads and keeps the curve: this year and last, refreshed at most every
/// few hours — the Treasury publishes once a business day.
actor TreasuryYieldClient {
    static let shared = TreasuryYieldClient()

    private var cached: (curve: TreasuryYieldCurve, at: Date)?
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func url(year: Int) -> URL {
        URL(string: "https://home.treasury.gov/resource-center/data-chart-center/interest-rates/daily-treasury-rates.csv/\(year)/all?type=daily_treasury_yield_curve&field_tdr_date_value=\(year)&page&_format=csv")!
    }

    func curve(now: Date = Date()) async throws -> TreasuryYieldCurve {
        if let cached, now.timeIntervalSince(cached.at) < 3 * 3600 { return cached.curve }
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        async let current = text(year: year)
        async let previous = text(year: year - 1)
        let texts = try await [previous, current]
        let days = texts.flatMap(TreasuryYieldCurve.parse)
        guard !days.isEmpty else { throw LocalServiceError.invalidResponse }
        var unique: [String: TreasuryYieldCurve.Day] = [:]
        for day in days { unique[day.date] = day }
        let curve = TreasuryYieldCurve(days: unique.values.sorted { $0.date < $1.date })
        cached = (curve, now)
        return curve
    }

    private func text(year: Int) async throws -> String {
        var request = URLRequest(url: Self.url(year: year), timeoutInterval: 45)
        request.setValue("Mozilla/5.0 Catfolio", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { throw LocalServiceError.invalidResponse }
        return text
    }
}

import SwiftUI

/// The curve on its own page: today's, a month ago and a year ago, then the
/// 10-year less 2-year spread and every maturity's yield.
struct TreasuryYieldCurveView: View {
    @State private var curve: TreasuryYieldCurve?
    @State private var error: String?
    @State private var hidden: Set<String> = []
    @State private var selectedDate: Date?

    private struct Line: Identifiable {
        let id: String
        let title: String
        let day: TreasuryYieldCurve.Day
        let color: Color
        let isNow: Bool
    }

    private var lines: [Line] {
        guard let curve, let latest = curve.latest else { return [] }
        func ago(_ component: Calendar.Component, _ value: Int) -> TreasuryYieldCurve.Day? {
            guard let date = DayDateCodec.date(from: latest.date),
                  let back = Calendar(identifier: .gregorian).date(byAdding: component, value: -value, to: date)
            else { return nil }
            return curve.day(onOrBefore: DayDateCodec.string(from: back))
        }
        var lines = [Line(id: "now", title: L10n.text("最新"), day: latest, color: .primary, isNow: true)]
        if let month = ago(.month, 1) {
            lines.append(Line(id: "month", title: L10n.text("1 个月前"), day: month,
                              color: Color(red: 0.204, green: 0.459, blue: 1.000), isNow: false))
        }
        if let year = ago(.year, 1) {
            lines.append(Line(id: "year", title: L10n.text("1 年前"), day: year,
                              color: Color(red: 1.000, green: 0.584, blue: 0.000), isNow: false))
        }
        return lines
    }

    private static let maturities = TreasuryYieldCurve.Maturity.allCases

    /// Maturities sit evenly along the axis; only their order matters.
    private static func date(_ index: Int) -> Date { Date(timeIntervalSinceReferenceDate: Double(index) * 86_400) }

    var body: some View {
        SettingsPage(bottomInset: 32, topInset: SettingsTemplate.sectionSpacing) {
            if let curve, curve.latest != nil {
                chart
                    .frame(height: 280)
                legend
                if let spread = spread(curve.latest!) {
                    SettingsSection(L10n.text("期限利差")) {
                        // Below zero the curve is inverted, which the title says.
                        SettingsValueRow(icon: .symbol("arrow.left.and.right"),
                                         title: spread < 0 ? L10n.text("10 年 − 2 年 · 倒挂") : L10n.text("10 年 − 2 年"),
                                         value: basisPoints(spread))
                    }
                }
                SettingsSection(L10n.text("各期限收益率")) {
                    ForEach(Self.maturities.reversed(), id: \.self) { maturity in
                        if let value = curve.latest?.yields[maturity] {
                            SettingsValueRow(icon: nil, title: maturity.label, value: percent(value),
                                             valueIsNumeric: true)
                        }
                    }
                }
            } else if let error {
                ContentUnavailableView(L10n.text("暂时读不到收益率曲线"), systemImage: "chart.line.uptrend.xyaxis",
                                       description: Text(L10n.message(error)))
            } else {
                StandardLineChartSkeleton(axisWidth: 44, topInset: 8, seriesCount: 3, lineWidths: [2.5, 2, 2],
                                          appearanceID: "treasury-curve")
                    .frame(height: 280)
            }
        }
        .navigationTitle(L10n.text("美债收益率曲线"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .task { await load() }
        .refreshable { await load() }
    }

    private var chart: some View {
        let visible = lines.filter { !hidden.contains($0.id) }
        let values = visible.flatMap { $0.day.yields.values }
        let low = max(0, floor((values.min() ?? 0) * 2) / 2 - 0.25)
        let high = ceil((values.max() ?? 5) * 2) / 2 + 0.25
        let series = visible.map { line in
            StandardLineChartSeries(
                id: line.id,
                points: Self.maturities.enumerated().compactMap { index, maturity in
                    line.day.yields[maturity].map {
                        StandardLineChartPoint(id: "\(line.id)|\(maturity.rawValue)", date: Self.date(index), value: $0)
                    }
                },
                color: line.color, lineWidth: line.isNow ? 2.5 : 2,
                selectionRadius: line.isNow ? 3.6 : 2.8, latestPointRadius: line.isNow ? 5 : nil,
                latestPointUsesGlass: false)
        }
        return StandardLineChart(
            series: series,
            interactionDates: Self.maturities.indices.map(Self.date),
            domain: low...high,
            yTicks: stride(from: low, through: high, by: max(0.5, ((high - low) / 4 * 2).rounded() / 2)).map { $0 },
            axisWidth: 44,
            transitionKey: hidden.sorted().joined(separator: ","),
            appearanceID: "treasury-curve",
            selectedDate: selectedDate,
            selectionIndicatorLabel: selectedDate.map { maturityLabel(at: $0) },
            selectionSeriesIDs: Set(series.map(\.id)),
            yAxisLabel: { percent($0) },
            xAxisLabel: { maturityLabel(at: $0) },
            onSelect: { selectedDate = $0 },
            onInteractionEnded: { _ in selectedDate = nil }
        )
        .accessibilityLabel(L10n.text("美债收益率曲线，按期限从 1 个月到 30 年"))
    }

    /// One row per curve with its yield at the maturity being read — the
    /// 10-year at rest. A tap shows or hides the curve.
    private var legend: some View {
        let maturity = selectedDate.map(maturity(at:)) ?? .tenYears
        return VStack(spacing: 12) {
            ForEach(lines) { line in
                let isShown = !hidden.contains(line.id)
                Button {
                    if isShown { hidden.insert(line.id) } else { hidden.remove(line.id) }
                } label: {
                    HStack(spacing: 12) {
                        Circle().fill(line.color).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.title).font(.system(size: 16, weight: .semibold, design: .rounded))
                            Text(line.day.date).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("\(maturity.label) " + (line.day.yields[maturity].map(percent) ?? "—"))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(CatfolioTheme.primaryText)
                    .padding(.horizontal, 16)
                    .frame(height: 60)
                    .background { ReturnsGlassCardSurface() }
                    .opacity(isShown ? 1 : 0.2)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityValue(isShown ? L10n.text("已显示") : L10n.text("已隐藏"))
            }
        }
    }

    private func maturity(at date: Date) -> TreasuryYieldCurve.Maturity {
        let index = Int((date.timeIntervalSinceReferenceDate / 86_400).rounded())
        return Self.maturities[min(Self.maturities.count - 1, max(0, index))]
    }

    private func maturityLabel(at date: Date) -> String { maturity(at: date).label }

    private func spread(_ day: TreasuryYieldCurve.Day) -> Double? {
        guard let ten = day.yields[.tenYears], let two = day.yields[.twoYears] else { return nil }
        return ten - two
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2))) + "%"
    }

    private func basisPoints(_ value: Double) -> String {
        let bp = (value * 100).rounded()
        return (bp > 0 ? "+" : "") + bp.formatted(.number.precision(.fractionLength(0))) + " bp"
    }

    private func load() async {
        do {
            curve = try await TreasuryYieldClient.shared.curve()
            error = nil
        } catch {
            if curve == nil { self.error = error.localizedDescription }
        }
    }
}
