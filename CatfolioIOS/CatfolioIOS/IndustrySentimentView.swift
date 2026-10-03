import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Core's export format. The phone now produces the same file itself from
/// the same public sources (`IndustrySentimentClient`, a port of Core's
/// engine); the bundled copy and a hand-imported file still load when it
/// can't.
struct IndustrySentimentSnapshot: Codable, Identifiable, Sendable {
    var id: String { sector }
    struct Day: Codable, Identifiable, Sendable {
        let date: String
        let close: Double
        let ma20: Double?
        let volume: Double?
        var id: String { date }
        // Decode once, off the main thread. Chart layout and scrubbing must
        // never invoke DateFormatter for every point on every update.
        let timestamp: Date

        private enum CodingKeys: String, CodingKey { case date, close, ma20, volume }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try container.decode(String.self, forKey: .date)
            close = try container.decode(Double.self, forKey: .close)
            ma20 = try container.decodeIfPresent(Double.self, forKey: .ma20)
            volume = try container.decodeIfPresent(Double.self, forKey: .volume)
            guard let parsed = IndustrySentimentSnapshot.dateFormatter.date(from: date) else {
                throw DecodingError.dataCorruptedError(forKey: .date, in: container,
                                                       debugDescription: "Invalid market date")
            }
            timestamp = parsed
        }
    }
    let exposureSymbols: [String]
    let sector: String
    let volatilitySymbol: String
    let priceSymbol: String
    let asOf: String
    let score: Int?
    let regime: String
    let close: Double
    let ma20: Double?
    let z20: Double?
    let percentile: Double?
    let availablePercentile: Double
    let sampleCount: Int
    let changePct: Double?
    let priceChangePct: Double?
    let history: [Day]

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()
    var stale: Bool {
        guard let date = Self.dateFormatter.date(from: asOf) else { return true }
        return Date().timeIntervalSince(date) >= 5 * 86400
    }
    /// The market this snapshot claims to be, as the shared table has it.
    var definition: IndustrySentimentEngine.Sector? { IndustrySentimentEngine.sector(sector) }
    var title: String { definition?.title ?? sector }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try validated(decoder.decode(Self.self, from: data))
    }

    /// A snapshot must name a market the app knows and carry that market's
    /// two symbols: a file may not relabel VIX as the semiconductor index.
    static func validated(_ value: Self) throws -> Self {
        guard let definition = value.definition,
              value.volatilitySymbol == definition.volatilitySymbol,
              value.priceSymbol == definition.priceSymbol,
              Self.dateFormatter.date(from: value.asOf) != nil,
              value.score.map({ (0...100).contains($0) }) ?? true,
              value.sampleCount > 0, value.sampleCount <= 252,
              !value.history.isEmpty, value.history.last?.date == value.asOf,
              value.history.map(\.date) == value.history.map(\.date).sorted(),
              Set(value.history.map(\.date)).count == value.history.count,
              value.history.allSatisfy({ $0.close > 0 && $0.close.isFinite && ($0.volume.map { $0 >= 0 && $0.isFinite } ?? true) })
        else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}

extension JSONEncoder {
    /// Writes a snapshot back in the shape Core exports it, so the page's own
    /// cache is a file the page — and Core — would accept.
    static let sentimentEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()
}

/// What a snapshot file holds: the markets Core last exported, in the table's
/// order. Files written before the page tracked more than semiconductors are
/// a bare snapshot object, and still read as a one-market file — a reader who
/// kept an older export does not lose it on upgrade.
struct IndustrySentimentFile: Sendable {
    let sectors: [IndustrySentimentSnapshot]

    /// The newest day any market in the file was read; what "older than what
    /// is on screen" is measured against.
    var asOf: String { sectors.map(\.asOf).max() ?? "" }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        struct Payload: Decodable { let sectors: [IndustrySentimentSnapshot] }
        if let payload = try? decoder.decode(Payload.self, from: data) {
            let sectors = try payload.sectors.map { try IndustrySentimentSnapshot.validated($0) }
            guard !sectors.isEmpty,
                  Set(sectors.map(\.sector)).count == sectors.count else { throw CocoaError(.fileReadCorruptFile) }
            return Self(sectors: sectors)
        }
        return Self(sectors: [try IndustrySentimentSnapshot.decode(data)])
    }

    /// Merges an incoming file into what is on screen, market by market: a
    /// refresh of one market must not drop the other nine, and an older day
    /// never replaces a newer one.
    func merging(_ incoming: Self) -> Self {
        var byKey = Dictionary(uniqueKeysWithValues: sectors.map { ($0.sector, $0) })
        for sector in incoming.sectors where (byKey[sector.sector]?.asOf ?? "") <= sector.asOf {
            byKey[sector.sector] = sector
        }
        let order = IndustrySentimentEngine.sectors.map(\.key)
        return Self(sectors: byKey.values.sorted {
            (order.firstIndex(of: $0.sector) ?? .max) < (order.firstIndex(of: $1.sector) ?? .max)
        })
    }
}

struct IndustrySentimentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var inheritedColorScheme
    @State private var file: IndustrySentimentFile?
    /// The market on screen. Kept across launches so the reader's own market
    /// is what opens, not whichever one the table lists first.
    @AppStorage("industry-sentiment.sector") private var sectorKey = "semiconductors"
    @AppStorage("industry-sentiment.mechanical-dial") private var mechanicalDial = true
    @State private var range: ChartTimeRange = .yearToDate
    @State private var selectedDate: Date?
    @State private var importing = false
    @State private var error: String?
    /// The markets being read from Cboe and Yahoo right now. Per market, so
    /// a read still running for the last choice never blocks the next one.
    @State private var refreshing: Set<String> = []
    private var isRefreshing: Bool { refreshing.contains(sectorKey) }
    private let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("industry-sentiment.json")

    /// The market on screen: the one chosen, or the first the file carries.
    private var snapshot: IndustrySentimentSnapshot? {
        if let chosen = file?.sectors.first(where: { $0.sector == sectorKey }) { return chosen }
        // A known market not read yet shows its own empty dial while it
        // loads, never another market's score.
        return IndustrySentimentEngine.sector(sectorKey) == nil ? file?.sectors.first : nil
    }

    var body: some View {
        Group {
            if mechanicalDial {
                mechanicalPage
            } else {
        SettingsPage(bottomInset: 32, topInset: SettingsTemplate.sectionSpacing) {
            if let snapshot {
                sectorPicker
                gaugeCard(snapshot)
                trendCard(snapshot)
                portfolioInsight(snapshot)
            } else if file != nil {
                sectorPicker
                loadingDial(mechanical: false)
            } else {
                ContentUnavailableView(L10n.text("暂无行情数据"), systemImage: "chart.xyaxis.line")
            }
            if let error { SettingsFootnote(error) }
        }
            }
        }
        .preferredColorScheme(mechanicalDial ? .dark : nil)
        .environment(\.colorScheme, mechanicalDial ? .dark : inheritedColorScheme)
        .toolbarColorScheme(mechanicalDial ? .dark : inheritedColorScheme, for: .navigationBar)
        .toolbar(mechanicalDial ? .hidden : .automatic, for: .tabBar)
        .navigationTitle(mechanicalDial ? "" : L10n.text("行业情绪"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker(L10n.text("仪表盘样式"), selection: $mechanicalDial) {
                        Text(L10n.text("简约")).tag(false)
                        Text(L10n.text("机械")).tag(true)
                    }
                    Button(L10n.text("导入行情快照"), systemImage: "square.and.arrow.down") { importing = true }
                } label: { Image(systemName: "ellipsis") }
            }
        }
        // Reuse each market's saved snapshot on entry and when switching.
        // Pull to refresh explicitly; only fetch automatically if missing.
        .task(id: sectorKey) {
            selectedDate = nil
            if file == nil { await load() }
            guard !Task.isCancelled else { return }
            guard file?.sectors.contains(where: { $0.sector == sectorKey }) != true else { return }
            await refresh()
        }
        .refreshable { await refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count <= 5_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let incoming = try IndustrySentimentFile.decode(data)
                guard file.map({ incoming.asOf >= $0.asOf }) ?? true else { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try store(file.map { $0.merging(incoming) } ?? incoming)
                selectedDate = nil
                error = nil
            } catch { self.error = L10n.text("无法导入，请选择有效且更新的行情快照。") }
        }
    }

    /// The chosen market's dial before its first read: no needle, no score,
    /// and a spinner while the read runs.
    private func loadingDial(mechanical: Bool) -> some View {
        VStack(spacing: 12) {
            SentimentGauge(score: nil, mechanical: mechanical, headerOnly: mechanical)
            if isRefreshing { ProgressView() }
        }
        .frame(maxWidth: .infinity)
    }

    private var mechanicalPage: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    if let snapshot {
                        SentimentGauge(score: snapshot.score, mechanical: true, headerOnly: true)
                            .padding(.horizontal, 22)
                            .padding(.top, -37)
                            .padding(.bottom, -(geometry.size.width - 44) / 2 + 57)
                        mechanicalMetrics(snapshot).padding(.horizontal, 16)
                        sectorPicker.padding(.horizontal, 18).padding(.top, 12)
                        trendCard(snapshot).padding(16)
                    } else if file != nil {
                        loadingDial(mechanical: true)
                            .padding(.horizontal, 22)
                            .padding(.top, -37)
                        sectorPicker.padding(.horizontal, 18).padding(.top, 12)
                    } else {
                        ContentUnavailableView(L10n.text("暂无行情数据"), systemImage: "chart.xyaxis.line")
                    }
                    if let error { SettingsFootnote(error).padding(.horizontal, 20) }
                }
                .padding(.bottom, 32)
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func mechanicalMetrics(_ data: IndustrySentimentSnapshot) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(data.title).font(.system(size: 15)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                Text(data.score.map(String.init) ?? "—")
                    .font(.system(size: 40, weight: .light, design: .default).width(.compressed))
                    .fontDesign(.default)
                    .monospacedDigit()
                    .foregroundStyle(scoreColor(data.score))
                    .contentTransition(reduceMotion ? .identity : .numericText(value: Double(data.score ?? 0)))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: data.score)
                Text(L10n.text(SentimentGauge(score: data.score).label))
                    .font(.system(size: 15)).foregroundStyle(Color(white: 0.77))
            }
                Text(data.regime).font(.system(size: 15)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 34)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                compactMetric(data.volatilitySymbol, data.close)
                compactMetric(L10n.text("20日均值"), data.ma20)
                compactMetric(L10n.text("20日 Z-Score"), data.z20)
                compactMetric(L10n.text(data.percentile == nil ? "可用历史分位数" : "1年分位数"), data.percentile ?? data.availablePercentile, suffix: "%")
                compactMetric(L10n.text("\(data.volatilitySymbol) 1日变化"), data.changePct, suffix: "%")
                compactMetric(L10n.text("\(data.priceSymbol) 1日涨跌"), data.priceChangePct, suffix: "%")
            }
            portfolioInsight(data, embedded: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .top)
        .background { mechanicalPanelSurface }
    }

    @ViewBuilder
    private var mechanicalPanelSurface: some View {
        if #available(iOS 26.0, *) {
            RoundedRectangle(cornerRadius: 38)
                .fill(.clear)
                .glassEffect(.clear.tint(.black.opacity(0.3)), in: RoundedRectangle(cornerRadius: 38))
        } else {
            RoundedRectangle(cornerRadius: 38)
                .fill(.ultraThinMaterial)
                .overlay { RoundedRectangle(cornerRadius: 38).strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }
        }
    }

    /// Match the red → orange → green stops in the dial's Figma spectrum.
    private func scoreColor(_ score: Int?) -> Color {
        guard let score else { return Color(white: 0.65) }
        let fraction = Double(min(100, max(0, score))) / 100
        let red = Color(red: 1, green: 0, blue: 14 / 255)
        let orange = Color(red: 1, green: 118 / 255, blue: 0)
        let green = Color(red: 0, green: 228 / 255, blue: 101 / 255)
        return fraction <= 0.5
            ? red.mix(with: orange, by: fraction * 2)
            : orange.mix(with: green, by: (fraction - 0.5) * 2)
    }

    private func compactMetric(_ label: String, _ value: Double?, suffix: String = "") -> some View {
        VStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Color(white: 0.65))
            Text(value.map { String(format: "%.2f", $0) + suffix } ?? "—")
                .font(.system(size: 15, weight: .medium)).monospacedDigit()
                .foregroundStyle(Color(white: 0.85))
        }
        .frame(maxWidth: .infinity)
    }

    private var sectorPicker: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                // Every market the app knows, not only those already read:
                // choosing one that has never been read fetches it.
                ForEach(IndustrySentimentEngine.sectors) { entry in
                    let selected = entry.key == sectorKey
                    Button { sectorKey = entry.key } label: {
                        Text(entry.title)
                            .appText(.footnote, weight: .medium)
                            .foregroundStyle(mechanicalDial ? (selected ? Color.black : Color.white) : (selected ? Color.white : SettingsTemplate.secondaryText))
                            .padding(.horizontal, mechanicalDial ? 27 : 14)
                            .frame(height: mechanicalDial ? 46 : 34)
                            .background(
                                mechanicalDial ? AnyShapeStyle(Color.white.opacity(selected ? 0.7 : 0.1)) : (selected ? AnyShapeStyle(CatfolioStyle.blue) : AnyShapeStyle(SettingsTemplate.card)),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel(L10n.text("选择市场"))
    }

    /// Reads the market on screen — its Cboe index and its Yahoo fund — and
    /// runs Core's method on the phone. Only the market being shown is
    /// fetched: ten markets on every open would be twenty requests for nine
    /// charts nobody is looking at. What's on screen stays up while it runs,
    /// and stays up if it fails; only a newer or equal day replaces it.
    private func refresh() async {
        let key = sectorKey
        guard !refreshing.contains(key), let sector = IndustrySentimentEngine.sector(key)
            ?? snapshot?.definition else { return }
        refreshing.insert(key)
        defer { refreshing.remove(key) }
        do {
            let data = try await IndustrySentimentClient().snapshotData(sector: sector)
            let incoming = try await Task.detached(priority: .utility) {
                try IndustrySentimentFile.decode(data)
            }.value
            // Kept even if the reader has moved on: it is that market's data,
            // and switching back should find it.
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try store(file.map { $0.merging(incoming) } ?? incoming)
            if key == sectorKey { error = nil }
        } catch {
            guard !Task.isCancelled, key == sectorKey else { return }
            self.error = snapshot == nil
                ? L10n.text("暂无行情数据")
                : L10n.text("无法更新行情，显示的是 \(snapshot?.asOf ?? "") 的数据。下拉可重试。")
        }
    }

    /// The merged file is what is cached, so a refresh of one market never
    /// costs the reader the other nine.
    private func store(_ merged: IndustrySentimentFile) throws {
        let payload: [String: Any] = [
            "schema_version": 2,
            "sectors": try merged.sectors.map { snapshot in
                try JSONSerialization.jsonObject(with: JSONEncoder.sentimentEncoder.encode(snapshot))
            },
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: cacheURL, options: .atomic)
        file = merged
    }

    private func load() async {
        let cache = cacheURL
        let bundled = Bundle.main.url(forResource: "industry_sentiment", withExtension: "json")
        let loaded = await Task.detached(priority: .userInitiated) {
            let candidates = [cache, bundled].compactMap { $0 }.compactMap { url -> IndustrySentimentFile? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? IndustrySentimentFile.decode(data)
            }
            return candidates.dropFirst().reduce(candidates.first) { $0?.merging($1) }
        }.value
        guard !Task.isCancelled else { return }
        file = loaded
        if file == nil { error = L10n.text("暂无行情数据") }
    }

    /// The page's own card, on the settings template's fill, radius and
    /// padding rather than a second set of numbers.
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20, content: content)
            .padding(SettingsTemplate.rowHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCardSurface()
    }

    @ViewBuilder
    private func portfolioInsight(_ data: IndustrySentimentSnapshot, embedded: Bool = false) -> some View {
        let holdings = model.holdings
        let symbols = Set(data.exposureSymbols)
        let total = holdings.reduce(0) { $0 + abs($1.marketValue) }
        let exposed = holdings.filter { symbols.contains($0.ticker.uppercased()) }.reduce(0) { $0 + abs($1.marketValue) }
        if total > 0, exposed > 0, holdings.allSatisfy({ $0.marketValue.isFinite }), !data.stale {
            VStack(alignment: .leading, spacing: embedded ? 10 : 20) {
                if embedded { Divider().padding(.vertical, 8) }
                HStack {
                    Text("Today Insight").font(.headline)
                    Spacer()
                    if model.isFakeDataMode { Text(L10n.text("演示组合")).font(.caption).foregroundStyle(.secondary) }
                }
                Text(String(format: "%.1f%%", exposed / total * 100))
                    .font(Typography.number(.title, weight: .semibold))
                Text(L10n.text("\(data.title)直接持仓占比"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(L10n.text("不含现金及 ETF 穿透"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(embedded ? 0 : (mechanicalDial ? 24 : SettingsTemplate.rowHorizontalPadding))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if embedded {
                    Color.clear
                } else if mechanicalDial {
                    mechanicalPanelSurface
                } else {
                    RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous)
                        .fill(SettingsTemplate.card)
                }
            }
        }
    }

    private func gaugeCard(_ data: IndustrySentimentSnapshot) -> some View {
        card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(data.title).font(.headline)
                    Text(data.asOf + (data.stale ? " · " + L10n.text("已过期") : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(data.volatilitySymbol) / \(data.priceSymbol)").font(.caption).foregroundStyle(.secondary)
            }
            Picker(L10n.text("仪表盘样式"), selection: $mechanicalDial) {
                Text(L10n.text("简约")).tag(false)
                Text(L10n.text("机械")).tag(true)
            }.pickerStyle(.segmented)
            SentimentGauge(score: data.score, mechanical: mechanicalDial)
            HStack {
                Text(L10n.text("市场状态")).foregroundStyle(.secondary)
                Spacer()
                Text(data.regime).fontWeight(.semibold)
            }.font(.subheadline)
            Divider()
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 20) {
                metric(data.volatilitySymbol, data.close)
                metric(L10n.text("20日均值"), data.ma20)
                metric(L10n.text("20日 Z-Score"), data.z20)
                metric(L10n.text(data.percentile == nil ? "可用历史分位数" : "1年分位数"), data.percentile ?? data.availablePercentile, suffix: "%")
                metric(L10n.text("\(data.volatilitySymbol) 1日变化"), data.changePct, suffix: "%")
                metric(L10n.text("\(data.priceSymbol) 1日涨跌"), data.priceChangePct, suffix: "%")
            }
        }
    }

    private func metric(_ label: String, _ value: Double?, suffix: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.2f", $0) + suffix } ?? "—")
                .font(Typography.number(.heading, weight: .semibold)).monospacedDigit()
        }
    }

    private func trendCard(_ data: IndustrySentimentSnapshot) -> some View {
        // Snapshot validation already guarantees chronological order.
        let history = data.history
        let end = history.last?.timestamp ?? .now
        let previousDate = history.dropLast().last?.timestamp
        let rows = history.filter { range.includes($0.timestamp, through: end, previousTradingDate: previousDate) }
        let values = rows.flatMap { [$0.close, $0.ma20].compactMap { $0 } }
        let low = (values.min() ?? 0) - 2
        let high = (values.max() ?? 1) + 2
        let focused = selectedDate.flatMap { date in rows.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) } }
        return card {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("波动率趋势") + " · " + data.volatilitySymbol)
                    .appText(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text((focused ?? rows.last).map { String(format: "%.2f", $0.close) } ?? "—")
                    .font(Typography.number(.heading, weight: .medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 14) {
                    HStack(spacing: 5) {
                        Capsule().fill(.secondary).frame(width: 12, height: 2)
                        Text("MA20 " + ((focused ?? rows.last)?.ma20.map { String(format: "%.2f", $0) } ?? "—"))
                    }
                    Text(L10n.text("\(data.priceSymbol) 成交量") + " " + ((focused ?? rows.last)?.volume.map { DisplayFormat.compact($0) } ?? "—"))
                }
                .appNumber(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StandardLineChart(
                series: [
                    StandardLineChartSeries(id: "volatility", points: rows.map { .init(date: $0.timestamp, value: $0.close) }, color: CatfolioPalette.securityPriceLine, lineWidth: 2),
                    StandardLineChartSeries(id: "MA20", points: rows.compactMap { row in row.ma20.map { .init(date: row.timestamp, value: $0) } }, color: .secondary, lineWidth: 2, dash: [5, 4], latestPointRadius: nil)
                ],
                interactionDates: rows.map(\.timestamp), domain: low...high,
                yTicks: (0...3).map { low + (high-low) * Double($0)/3 },
                transitionKey: "sentiment-\(data.sector)-\(range.rawValue)", appearanceID: "industry-sentiment", dataTransition: .viewportZoom,
                selectedDate: selectedDate,
                selectionIndicatorLabel: focused?.timestamp.formatted(.dateTime.year().month(.abbreviated).day()),
                selectionSeriesIDs: ["volatility", "MA20"],
                yAxisLabel: { String(format: "%.1f", $0) },
                xAxisLabel: { $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) },
                onSelect: { selectedDate = $0 }, onInteractionEnded: { _ in selectedDate = nil }
            ).frame(height: 240)
            Chart(rows) { row in
                if let volume = row.volume {
                    // Explicit daily bounds avoid automatic widths overlapping
                    // neighbouring dates on a continuous time axis.
                    BarMark(
                        xStart: .value("Start", row.timestamp.addingTimeInterval(-0.4 * 86_400)),
                        xEnd: .value("End", row.timestamp.addingTimeInterval(0.4 * 86_400)),
                        y: .value("Volume", volume)
                    )
                    .foregroundStyle(CatfolioPalette.securityPriceLine.mix(
                        with: SettingsTemplate.card,
                        by: selectedDate == nil || row.date == focused?.date ? 0.6 : 0.85
                    ))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in AxisValueLabel().font(.caption2).foregroundStyle(.secondary) } }
            .chartXScale(domain: (rows.first?.timestamp ?? end).addingTimeInterval(-0.5 * 86_400)...end.addingTimeInterval(0.5 * 86_400))
            .frame(height: 70)
            ChartTimeRangePicker(selection: $range)
                .frame(height: 62)
                .accessibilityLabel(L10n.text("时间范围"))
        }
        .onChange(of: range) { _, _ in selectedDate = nil }
        .onChange(of: data.sector) { _, _ in selectedDate = nil }
    }
}

private struct SentimentGauge: View {
    let score: Int?
    var mechanical = false
    var headerOnly = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt = Date()
    @State private var fromFraction = 0.0
    @State private var targetFraction = 0.5
    @State private var isVisible = false

    var label: L10n.Message {
        guard let score else { return "暂无评分" }
        switch score {
        case ..<20: return "极度恐惧"
        case ..<40: return "恐惧"
        case ...60: return "中性"
        case ...80: return "贪婪"
        default: return "极度贪婪"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if mechanical {
                MechanicalSentimentDial(
                    headerOnly: headerOnly, score: score, label: L10n.text(label),
                    paused: reduceMotion || !isVisible || scenePhase != .active || score == nil,
                    fraction: needleFraction(at:)
                )
                .accessibilityHidden(true)
            } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60,
                                    paused: reduceMotion || !isVisible || scenePhase != .active || score == nil)) { timeline in
                GeometryReader { proxy in
                    let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height - 20)
                    let radius = min(proxy.size.width / 2 - 20, proxy.size.height - 40)
                    let angle = needleAngle(at: timeline.date)
                    ZStack {
                        Path { path in
                            path.addArc(center: center, radius: radius,
                                        startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
                        }
                        .stroke(AngularGradient(colors: [Color(red: 1, green: 0.38, blue: 0.49),
                                                         Color(red: 0.96, green: 0.67, blue: 0.55),
                                                         Color(red: 0.73, green: 0.75, blue: 0.88),
                                                         Color(red: 0.32, green: 0.77, blue: 0.87),
                                                         Color(red: 0.22, green: 0.80, blue: 0.65)],
                                                center: UnitPoint(x: 0.5, y: center.y / proxy.size.height),
                                                startAngle: .degrees(180), endAngle: .degrees(360)),
                                style: StrokeStyle(lineWidth: 26, lineCap: .round))
                        if score != nil {
                            Canvas { context, _ in
                                let length = radius - 25
                                // The common tangents of two circles form a tapered
                                // capsule. Both ends join the sides without corners.
                                let baseRadius = 4.5
                                let tipRadius = 1.8
                                let tangent = acos((baseRadius - tipRadius) / length)
                                var needle = Path()
                                needle.move(to: CGPoint(x: baseRadius * cos(tangent),
                                                        y: -baseRadius * sin(tangent)))
                                needle.addLine(to: CGPoint(x: length + tipRadius * cos(tangent),
                                                           y: -tipRadius * sin(tangent)))
                                needle.addArc(center: CGPoint(x: length, y: 0), radius: tipRadius,
                                              startAngle: .radians(-tangent), endAngle: .radians(tangent), clockwise: false)
                                needle.addLine(to: CGPoint(x: baseRadius * cos(tangent),
                                                           y: baseRadius * sin(tangent)))
                                needle.addArc(center: .zero, radius: baseRadius,
                                              startAngle: .radians(tangent), endAngle: .radians(2 * .pi - tangent), clockwise: false)
                                needle.closeSubpath()
                                needle = needle.applying(CGAffineTransform(a: cos(angle), b: sin(angle),
                                                                          c: -sin(angle), d: cos(angle),
                                                                          tx: center.x, ty: center.y))
                                context.fill(needle, with: .color(.primary))
                            }
                        }
                    }
                }
            }
            .frame(height: 180)
            .accessibilityHidden(true)
            Text(score.map(String.init) ?? "—").font(Typography.number(.display, weight: .semibold)).monospacedDigit()
            Text(L10n.text(label)).font(.subheadline).foregroundStyle(.secondary)
            HStack { Text(L10n.text("极度恐惧")); Spacer(); Text(L10n.text("极度贪婪")) }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            fromFraction = 0
            targetFraction = Double(min(100, max(0, score ?? 50))) / 100
            startedAt = .now
            isVisible = true
        }
        .onDisappear { isVisible = false }
        .onScrollVisibilityChange(threshold: 0.1) { isVisible = $0 }
        .onChange(of: score) { _, newScore in
            let now = Date()
            fromFraction = needleFraction(at: now)
            targetFraction = Double(min(100, max(0, newScore ?? 50))) / 100
            startedAt = now
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("行业情绪"))
        .accessibilityValue(L10n.text("\(score.map(String.init) ?? "—") / 100，\(L10n.text(label))"))
    }

    private func needleAngle(at date: Date) -> Double {
        .pi + needleFraction(at: date) * .pi
    }

    private func needleFraction(at date: Date) -> Double {
        guard !reduceMotion else { return targetFraction }
        let elapsed = max(0, date.timeIntervalSince(startedAt))
        // A damped spring approaches the actual score directly, overshoots
        // nearby, then rebounds. New scores start from the current position.
        let response = 1 - exp(-8 * elapsed) * (cos(10 * elapsed) + 0.8 * sin(10 * elapsed))
        let arrival = fromFraction + (targetFraction - fromFraction) * response
        let restingTime = max(0, elapsed - 1)
        let amplitude = min(0.007, min(targetFraction, 1 - targetFraction))
        let sway = amplitude * sin(restingTime * 1.7) * (1 - exp(-restingTime * 2))
        return min(1, max(0, arrival + sway))
    }
}
