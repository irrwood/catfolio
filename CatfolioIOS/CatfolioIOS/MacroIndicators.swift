import SwiftUI
import Charts

/// FRED's public series, read as the CSV its charts download — no key.
struct FREDClient {
    static func url(series: String, since: String) -> URL {
        URL(string: "https://fred.stlouisfed.org/graph/fredgraph.csv?id=\(series)&cosd=\(since)")!
    }

    /// Dated values, oldest first; FRED's "." for a missing day is left out.
    func observations(_ series: String, since: String) async throws -> [(date: String, value: Double)] {
        let request = URLRequest(url: Self.url(series: series, since: since), timeoutInterval: 25)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else { throw LocalServiceError.invalidResponse }
        let rows = Self.parse(text)
        guard !rows.isEmpty else { throw LocalServiceError.invalidResponse }
        return rows
    }

    static func parse(_ text: String) -> [(date: String, value: Double)] {
        text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2, let value = Double(fields[1].trimmingCharacters(in: .whitespaces)),
                  value.isFinite else { return nil }
            return (String(fields[0]).trimmingCharacters(in: .whitespaces), value)
        }.sorted { $0.date < $1.date }
    }

    /// Year-on-year change of a monthly index, in percent, from the first
    /// month that has the same month a year before.
    static func yearOnYear(_ rows: [(date: String, value: Double)]) -> [(date: String, value: Double)] {
        let byMonth = Dictionary(rows.map { (String($0.date.prefix(7)), $0.value) }, uniquingKeysWith: { _, last in last })
        return rows.compactMap { row in
            let parts = row.date.split(separator: "-").compactMap { Int($0) }
            guard parts.count >= 2,
                  let earlier = byMonth[String(format: "%04d-%02d", parts[0] - 1, parts[1])], earlier > 0 else { return nil }
            return (row.date, (row.value / earlier - 1) * 100)
        }
    }
}

/// The ECB's SDMX API as CSV: one series by flow and key, no key needed.
struct ECBClient {
    func observations(flow: String, key: String, since: String) async throws -> [(date: String, value: Double)] {
        let url = URL(string: "https://data-api.ecb.europa.eu/service/data/\(flow)/\(key)?format=csvdata&startPeriod=\(since)")!
        let text = try await MacroHTTP.text(url)
        let rows = Self.parse(text)
        guard !rows.isEmpty else { throw LocalServiceError.invalidResponse }
        return rows
    }

    /// Columns are read by name: the ECB's CSV carries a few dozen.
    static func parse(_ text: String) -> [(date: String, value: Double)] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first?.split(separator: ",", omittingEmptySubsequences: false).map(String.init),
              let dateIndex = header.firstIndex(of: "TIME_PERIOD"),
              let valueIndex = header.firstIndex(of: "OBS_VALUE") else { return [] }
        return lines.dropFirst().compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > max(dateIndex, valueIndex), let value = Double(fields[valueIndex]), value.isFinite
            else { return nil }
            return (MacroHTTP.dayText(String(fields[dateIndex])), value)
        }.sorted { $0.date < $1.date }
    }
}

/// Eurostat's dissemination API in JSON-stat: one series, every other
/// dimension fixed by the query, so values index straight into time.
struct EurostatClient {
    func observations(dataset: String, query: [String: String], since: String) async throws -> [(date: String, value: Double)] {
        var components = URLComponents(string: "https://ec.europa.eu/eurostat/api/dissemination/statistics/1.0/data/\(dataset)")!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "sinceTimePeriod", value: since)]
        let data = try await MacroHTTP.data(components.url!)
        let rows = try Self.parse(data)
        guard !rows.isEmpty else { throw LocalServiceError.invalidResponse }
        return rows
    }

    static func parse(_ data: Data) throws -> [(date: String, value: Double)] {
        struct Payload: Decodable {
            struct Dimension: Decodable { struct Category: Decodable { let index: [String: Int] }; let category: Category }
            let value: [String: Double]
            let dimension: [String: Dimension]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let time = payload.dimension["time"]?.category.index else { return [] }
        let periods = Dictionary(uniqueKeysWithValues: time.map { ($0.value, $0.key) })
        return payload.value.compactMap { key, value in
            guard let index = Int(key), let period = periods[index], value.isFinite else { return nil }
            return (MacroHTTP.dayText(period), value)
        }.sorted { $0.date < $1.date }
    }
}

/// The ONS's time series pages as JSON — open, no key.
struct ONSClient {
    func observations(path: String) async throws -> [(date: String, value: Double)] {
        let data = try await MacroHTTP.data(URL(string: "https://www.ons.gov.uk/\(path)/data")!)
        let rows = try Self.parse(data)
        guard !rows.isEmpty else { throw LocalServiceError.invalidResponse }
        return rows
    }

    static func parse(_ data: Data) throws -> [(date: String, value: Double)] {
        struct Payload: Decodable { struct Row: Decodable { let date: String; let value: String }; let months: [Row] }
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        return try JSONDecoder().decode(Payload.self, from: data).months.compactMap { row in
            let parts = row.date.split(separator: " ")
            guard parts.count == 2, let year = Int(parts[0]),
                  let month = months.firstIndex(of: parts[1].uppercased()), let value = Double(row.value) else { return nil }
            return (String(format: "%04d-%02d-01", year, month + 1), value)
        }.sorted { $0.date < $1.date }
    }
}

enum MacroHTTP {
    static func data(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 25))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.invalidResponse
        }
        return data
    }

    static func text(_ url: URL) async throws -> String {
        guard let text = String(data: try await data(url), encoding: .utf8) else { throw LocalServiceError.invalidResponse }
        return text
    }

    /// Every period as the day it starts, so months, quarters and days sort
    /// and filter together: 2026-08 → 2026-08-01, 2026-Q2 → 2026-04-01.
    static func dayText(_ period: String) -> String {
        let text = period.trimmingCharacters(in: .whitespaces)
        if text.count == 7, text.dropFirst(5).first == "Q", let quarter = Int(text.suffix(1)), let year = Int(text.prefix(4)) {
            return String(format: "%04d-%02d-01", year, (quarter - 1) * 3 + 1)
        }
        if text.count == 7 { return text + "-01" }
        return text
    }
}

/// One macro figure for the research page: a rate in percent, its last move
/// in basis points, and a year of history for the line.
struct MacroIndicator: Identifiable {
    enum Source: Equatable { case fred, treasury, ecb, eurostat, ons }
    enum Format: Equatable {
        /// A rate in percent; its move in basis points.
        case percent
        /// An exchange rate; its move in percent.
        case exchangeRate
    }

    let id: String
    let title: String
    let source: Source
    /// Oldest first.
    let points: [ResearchMarketSnapshot.Point]
    /// Daily figures move a little every day; monthly ones once a month.
    let isMonthly: Bool
    var format: Format = .percent

    var changePercent: Double? {
        guard points.count >= 2, points[points.count - 2].value != 0 else { return nil }
        return (points[points.count - 1].value / points[points.count - 2].value - 1) * 100
    }

    var latest: ResearchMarketSnapshot.Point? { points.last }

    var changeBasisPoints: Double? {
        guard points.count >= 2 else { return nil }
        return (points[points.count - 1].value - points[points.count - 2].value) * 100
    }

    static func make(id: String, title: String, source: Source, rows: [(date: String, value: Double)],
                     since: String, isMonthly: Bool, format: Format = .percent) -> Self? {
        let points = rows.filter { $0.date >= since }.map { ResearchMarketSnapshot.Point(id: $0.date, value: $0.value) }
        guard points.count > 1 else { return nil }
        return Self(id: id, title: title, source: source, points: points, isMonthly: isMonthly, format: format)
    }
}

/// Loads every indicator at once and keeps them for a few hours: none of
/// them is published more than once a day.
@MainActor @Observable
final class MacroIndicatorStore {
    static let shared = MacroIndicatorStore()

    private(set) var indicators: [MacroIndicator] = []
    private(set) var isLoading = false
    private var loadedAt: Date?

    /// The order the cards are laid out in.
    static let order = ["fed-funds", "cpi", "unemployment", "high-yield", "treasury-2y", "treasury-spread",
                        "ecb-deposit", "eur-usd", "eur-gbp", "ea-inflation", "ea-gdp", "eu-unemployment",
                        "uk-cpi", "uk-unemployment"]

    func load(force: Bool = false) async {
        // Everything for three hours; with a figure missing, try again soon.
        let freshFor: TimeInterval = indicators.count == Self.order.count ? 3 * 3600 : 120
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < freshFor, !indicators.isEmpty { return }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let calendar = Calendar(identifier: .gregorian)
        let yearAgo = DayDateCodec.string(from: calendar.date(byAdding: .year, value: -1, to: Date()) ?? Date())
        let twoYearsAgo = DayDateCodec.string(from: calendar.date(byAdding: .year, value: -2, to: Date()) ?? Date())
        let client = FREDClient()

        async let fedFunds = try? client.observations("DFF", since: yearAgo)
        async let cpi = try? client.observations("CPIAUCSL", since: twoYearsAgo)
        async let unemployment = try? client.observations("UNRATE", since: yearAgo)
        async let highYield = try? client.observations("BAMLH0A0HYM2", since: yearAgo)
        async let curve = try? TreasuryYieldClient.shared.curve()
        // Europe and the UK, from their own central bank and statistics offices.
        let ecb = ECBClient(), eurostat = EurostatClient(), ons = ONSClient()
        let month = String(yearAgo.prefix(7))
        async let deposit = try? ecb.observations(flow: "FM", key: "D.U2.EUR.4F.KR.DFR.LEV", since: yearAgo)
        async let eurUSD = try? ecb.observations(flow: "EXR", key: "D.USD.EUR.SP00.A", since: yearAgo)
        async let eurGBP = try? ecb.observations(flow: "EXR", key: "D.GBP.EUR.SP00.A", since: yearAgo)
        async let hicp = try? eurostat.observations(dataset: "prc_hicp_minr",
            query: ["geo": "EA", "unit": "RCH_A", "coicop18": "TOTAL"], since: month)
        async let gdp = try? eurostat.observations(dataset: "namq_10_gdp",
            query: ["geo": "EA", "unit": "CLV_PCH_SM", "s_adj": "SCA", "na_item": "B1GQ"],
            since: String(twoYearsAgo.prefix(4)) + "-Q1")
        async let euJobs = try? eurostat.observations(dataset: "une_rt_m",
            query: ["geo": "EU27_2020", "s_adj": "SA", "age": "TOTAL", "sex": "T", "unit": "PC_ACT"], since: month)
        async let ukCPI = try? ons.observations(path: "economy/inflationandpriceindices/timeseries/d7g7/mm23")
        async let ukJobs = try? ons.observations(path: "employmentandlabourmarket/peoplenotinwork/unemployment/timeseries/mgsx/lms")
        let (funds, prices, jobs, spreads, treasury) = await (fedFunds, cpi, unemployment, highYield, curve)
        let (ecbDeposit, usd, gbp, euInflation, euGDP, euUnemployment, ukPrices, ukUnemployment)
            = await (deposit, eurUSD, eurGBP, hicp, gdp, euJobs, ukCPI, ukJobs)

        var loaded: [MacroIndicator] = []
        if let funds, let item = MacroIndicator.make(id: "fed-funds", title: L10n.text("联邦基金利率"), source: .fred,
                                                     rows: funds, since: yearAgo, isMonthly: false) { loaded.append(item) }
        if let prices, let item = MacroIndicator.make(id: "cpi", title: L10n.text("CPI 同比"), source: .fred,
                                                      rows: FREDClient.yearOnYear(prices), since: yearAgo, isMonthly: true) { loaded.append(item) }
        if let jobs, let item = MacroIndicator.make(id: "unemployment", title: L10n.text("失业率"), source: .fred,
                                                    rows: jobs, since: yearAgo, isMonthly: true) { loaded.append(item) }
        if let spreads, let item = MacroIndicator.make(id: "high-yield", title: L10n.text("高收益债利差"), source: .fred,
                                                       rows: spreads, since: yearAgo, isMonthly: false) { loaded.append(item) }
        if let treasury {
            let two = treasury.history(.twoYears).sorted { $0.key < $1.key }.map { (date: $0.key, value: $0.value) }
            if let item = MacroIndicator.make(id: "treasury-2y", title: L10n.text("2 年期美债"), source: .treasury,
                                              rows: two, since: yearAgo, isMonthly: false) { loaded.append(item) }
            let spread = treasury.days.compactMap { day -> (date: String, value: Double)? in
                guard let ten = day.yields[.tenYears], let two = day.yields[.twoYears] else { return nil }
                return (day.date, ten - two)
            }
            if let item = MacroIndicator.make(id: "treasury-spread", title: L10n.text("10 年 − 2 年利差"), source: .treasury,
                                              rows: spread, since: yearAgo, isMonthly: false) { loaded.append(item) }
        }
        let european: [(String, String, MacroIndicator.Source, [(date: String, value: Double)]?, String, Bool, MacroIndicator.Format)] = [
            ("ecb-deposit", L10n.text("欧元区存款利率"), .ecb, ecbDeposit, yearAgo, false, .percent),
            ("eur-usd", L10n.text("欧元/美元"), .ecb, usd, yearAgo, false, .exchangeRate),
            ("eur-gbp", L10n.text("欧元/英镑"), .ecb, gbp, yearAgo, false, .exchangeRate),
            ("ea-inflation", L10n.text("欧元区通胀"), .eurostat, euInflation, yearAgo, true, .percent),
            // Quarterly: two years, or the line is four points.
            ("ea-gdp", L10n.text("欧元区 GDP 同比"), .eurostat, euGDP, twoYearsAgo, true, .percent),
            ("eu-unemployment", L10n.text("欧盟失业率"), .eurostat, euUnemployment, yearAgo, true, .percent),
            ("uk-cpi", L10n.text("英国 CPI 同比"), .ons, ukPrices, yearAgo, true, .percent),
            ("uk-unemployment", L10n.text("英国失业率"), .ons, ukUnemployment, yearAgo, true, .percent),
        ]
        for (id, title, source, rows, since, monthly, format) in european {
            if let rows, let item = MacroIndicator.make(id: id, title: title, source: source, rows: rows,
                                                        since: since, isMonthly: monthly, format: format) {
                loaded.append(item)
            }
        }
        // A failed refresh keeps what was already on screen.
        guard !loaded.isEmpty else { return }
        let fresh = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var merged = Dictionary(indicators.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        merged.merge(fresh) { _, new in new }
        indicators = Self.order.compactMap { merged[$0] }
        loadedAt = Date()
    }
}

/// The research page's metric card, for a macro figure: its name, the
/// latest value, the last move in basis points and a year's line. A rate
/// going up is neither good nor bad, so the move is shown without colour.
struct MacroIndicatorCard: View {
    let indicator: MacroIndicator?
    let title: String
    let color: Color
    var isLoading = false
    @ScaledMetric(relativeTo: .subheadline) private var titleSize = 16.0
    @ScaledMetric(relativeTo: .title3) private var valueSize = 20.0
    @ScaledMetric(relativeTo: .subheadline) private var changeSize = 14.0

    private var showsSkeleton: Bool { isLoading && indicator == nil }

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: titleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let value = indicator?.latest?.value {
                        Text(indicator?.format == .exchangeRate
                             ? value.formatted(.number.precision(.fractionLength(4)))
                             : value.formatted(.number.precision(.fractionLength(2))) + "%")
                            .font(.system(size: valueSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if let change = changeText {
                            Text(change)
                                .font(.system(size: changeSize, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    } else if showsSkeleton {
                        ChartSkeletonShape(width: 82, height: valueSize)
                    } else {
                        Text(L10n.text("暂无数据"))
                            .font(.system(size: changeSize, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartLoadingShimmer(active: showsSkeleton, appearanceID: "macro|\(title)")
                sparkline.frame(height: 53)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var sparkline: some View {
        if let indicator, indicator.points.count > 1 {
            let values = indicator.points.map(\.value)
            let low = values.min() ?? 0, high = values.max() ?? 1
            let pad = max((high - low) * 0.12, 0.01)
            Chart(Array(indicator.points.enumerated()), id: \.element.id) { item in
                LineMark(x: .value(L10n.text("日期"), item.offset), y: .value(L10n.text("数值"), item.element.value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(indicator.isMonthly ? .monotone : .linear)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartXScale(domain: 0...(indicator.points.count - 1))
            .chartYScale(domain: (low - pad)...(high + pad))
            .padding(.horizontal, 3)
            .padding(.vertical, 5)
            .accessibilityLabel(L10n.text("\(title)最近一年走势"))
        } else if showsSkeleton {
            StandardLineChartSkeleton(axisWidth: 0, topInset: 5, bottomHeight: 5, lineWidths: [3],
                                      appearanceID: "macro|\(title)")
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    /// A rate's move in basis points; an exchange rate's in percent.
    private var changeText: String? {
        guard let indicator else { return nil }
        if indicator.format == .exchangeRate {
            return indicator.changePercent.map { DisplayFormat.percent($0, signed: true) }
        }
        return indicator.changeBasisPoints.map(basisPoints)
    }

    private func basisPoints(_ value: Double) -> String {
        let bp = value.rounded()
        return (bp > 0 ? "+" : "") + bp.formatted(.number.precision(.fractionLength(0))) + " bp"
    }
}

/// The research page's macro section: FRED and the Treasury, as cards in
/// the key-metric grid's shape. The Treasury's open the yield curve.
struct MacroIndicatorSection: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let store = MacroIndicatorStore.shared

    private static let unitedStates: [(id: String, title: String, color: Color)] = [
        ("fed-funds", L10n.text("联邦基金利率"), Color(red: 0.204, green: 0.459, blue: 1.000)),
        ("cpi", L10n.text("CPI 同比"), Color(red: 0.890, green: 0.000, blue: 0.271)),
        ("unemployment", L10n.text("失业率"), Color(red: 0.000, green: 0.620, blue: 0.540)),
        ("high-yield", L10n.text("高收益债利差"), Color(red: 1.000, green: 0.584, blue: 0.000)),
        ("treasury-2y", L10n.text("2 年期美债"), Color(red: 139 / 255, green: 92 / 255, blue: 246 / 255)),
        ("treasury-spread", L10n.text("10 年 − 2 年利差"), Color(red: 0.400, green: 0.400, blue: 0.450)),
    ]

    private static let europe: [(id: String, title: String, color: Color)] = [
        ("ecb-deposit", L10n.text("欧元区存款利率"), Color(red: 0.204, green: 0.459, blue: 1.000)),
        ("ea-inflation", L10n.text("欧元区通胀"), Color(red: 0.890, green: 0.000, blue: 0.271)),
        ("ea-gdp", L10n.text("欧元区 GDP 同比"), Color(red: 0.000, green: 0.620, blue: 0.540)),
        ("eu-unemployment", L10n.text("欧盟失业率"), Color(red: 1.000, green: 0.584, blue: 0.000)),
        ("uk-cpi", L10n.text("英国 CPI 同比"), Color(red: 0.780, green: 0.000, blue: 0.910)),
        ("uk-unemployment", L10n.text("英国失业率"), Color(red: 0.000, green: 0.540, blue: 0.760)),
        ("eur-usd", L10n.text("欧元/美元"), Color(red: 0.400, green: 0.400, blue: 0.450)),
        ("eur-gbp", L10n.text("欧元/英镑"), Color(red: 0.600, green: 0.470, blue: 0.250)),
    ]

    var body: some View {
        group(L10n.text("宏观 · 美国"), cards: Self.unitedStates)
        group(L10n.text("宏观 · 欧洲与英国"), cards: Self.europe)
            .task { await store.load() }
    }

    @ViewBuilder
    private func group(_ title: String, cards: [(id: String, title: String, color: Color)]) -> some View {
        SettingsSectionHeader(title)
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: SettingsTemplate.tileSpacing),
                           count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
            spacing: SettingsTemplate.tileSpacing
        ) {
            ForEach(cards, id: \.id) { card in
                let indicator = store.indicators.first { $0.id == card.id }
                let tile = MacroIndicatorCard(indicator: indicator, title: card.title, color: card.color,
                                              isLoading: store.isLoading)
                if card.id.hasPrefix("treasury") {
                    NavigationLink { TreasuryYieldCurveView() } label: { tile }
                        .buttonStyle(.plain)
                } else {
                    tile
                }
            }
        }
    }
}
