import SwiftUI
import Charts
import UniformTypeIdentifiers

/// Values are exported by Core; the native client never recomputes sentiment scores.
struct IndustrySentimentSnapshot: Decodable {
    struct Day: Decodable, Identifiable {
        let date: String
        let close: Double
        let ma20: Double?
        let volume: Double?
        var id: String { date }
        var timestamp: Date { IndustrySentimentSnapshot.dateFormatter.date(from: date)! }
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
    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let value = try decoder.decode(Self.self, from: data)
        guard value.sector == "semiconductors", value.volatilitySymbol == "VXSMH", value.priceSymbol == "SMH",
              Self.dateFormatter.date(from: value.asOf) != nil,
              value.score.map({ (0...100).contains($0) }) ?? true,
              value.sampleCount > 0, value.sampleCount <= 252,
              !value.history.isEmpty, value.history.last?.date == value.asOf,
              value.history.map(\.date) == value.history.map(\.date).sorted(),
              Set(value.history.map(\.date)).count == value.history.count,
              value.history.allSatisfy({ Self.dateFormatter.date(from: $0.date) != nil && $0.close > 0 && $0.close.isFinite && ($0.volume.map { $0 >= 0 && $0.isFinite } ?? true) })
        else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}

struct IndustrySentimentView: View {
    @Environment(AppModel.self) private var model
    @State private var snapshot: IndustrySentimentSnapshot?
    @State private var range = 63
    @State private var selectedDate: Date?
    @State private var importing = false
    @State private var error: String?
    private let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("industry-sentiment.json")

    var body: some View {
        SettingsPage(bottomInset: 32, topInset: SettingsTemplate.sectionSpacing) {
            if let snapshot {
                gaugeCard(snapshot)
                trendCard(snapshot)
                portfolioInsight(snapshot)
            } else {
                ContentUnavailableView(L10n.text("暂无行情数据"), systemImage: "chart.xyaxis.line")
            }
            if let error { SettingsFootnote(error) }
        }
        .softTopScrollEdge()
        .navigationTitle(L10n.text("行业情绪"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                    .accessibilityLabel(L10n.text("导入行情快照"))
            }
        }
        .task { load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count <= 5_000_000 else { throw CocoaError(.fileReadTooLarge) }
                let incoming = try IndustrySentimentSnapshot.decode(data)
                guard snapshot.map({ incoming.asOf >= $0.asOf }) ?? true else { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: cacheURL, options: .atomic)
                snapshot = incoming
                selectedDate = nil
                error = nil
            } catch { self.error = L10n.text("无法导入，请选择有效且更新的行情快照。") }
        }
    }

    private func load() {
        let bundled = Bundle.main.url(forResource: "industry_sentiment", withExtension: "json")
        let candidates = [cacheURL, bundled].compactMap { $0 }.compactMap { url -> IndustrySentimentSnapshot? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? IndustrySentimentSnapshot.decode(data)
        }
        snapshot = candidates.max { $0.asOf < $1.asOf }
        if snapshot == nil { error = L10n.text("暂无行情数据") }
    }

    /// The page's own card, on the settings template's fill, radius and
    /// padding rather than a second set of numbers.
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20, content: content)
            .padding(SettingsTemplate.rowHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                SettingsTemplate.card,
                in: RoundedRectangle(cornerRadius: SettingsTemplate.cardRadius, style: .continuous)
            )
    }

    @ViewBuilder
    private func portfolioInsight(_ data: IndustrySentimentSnapshot) -> some View {
        let holdings = model.holdings
        let symbols = Set(data.exposureSymbols)
        let total = holdings.reduce(0) { $0 + abs($1.marketValue) }
        let exposed = holdings.filter { symbols.contains($0.ticker.uppercased()) }.reduce(0) { $0 + abs($1.marketValue) }
        if total > 0, exposed > 0, holdings.allSatisfy({ $0.marketValue.isFinite }), !data.stale {
            card {
                HStack {
                    Text("Today Insight").font(.headline)
                    Spacer()
                    if model.isFakeDataMode { Text(L10n.text("演示组合")).font(.caption).foregroundStyle(.secondary) }
                }
                Text(String(format: "%.1f%%", exposed / total * 100))
                    .font(Typography.number(.title, weight: .semibold))
                Text(L10n.text("半导体直接持仓占比"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(L10n.text("不含现金及 ETF 穿透"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func gaugeCard(_ data: IndustrySentimentSnapshot) -> some View {
        card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("半导体")).font(.headline)
                    Text(data.asOf + (data.stale ? " · " + L10n.text("已过期") : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("VXSMH / SMH").font(.caption).foregroundStyle(.secondary)
            }
            SentimentGauge(score: data.score)
            HStack {
                Text(L10n.text("市场状态")).foregroundStyle(.secondary)
                Spacer()
                Text(data.regime).fontWeight(.semibold)
            }.font(.subheadline)
            Divider()
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 20) {
                metric("VXSMH", data.close)
                metric(L10n.text("20日均值"), data.ma20)
                metric(L10n.text("20日 Z-Score"), data.z20)
                metric(L10n.text(data.percentile == nil ? "可用历史分位数" : "1年分位数"), data.percentile ?? data.availablePercentile, suffix: "%")
                metric(L10n.text("VXSMH 1日变化"), data.changePct, suffix: "%")
                metric(L10n.text("SMH 1日涨跌"), data.priceChangePct, suffix: "%")
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
        let rows = Array(data.history.suffix(range))
        let values = rows.flatMap { [$0.close, $0.ma20].compactMap { $0 } }
        let low = (values.min() ?? 0) - 2
        let high = (values.max() ?? 1) + 2
        let focused = selectedDate.flatMap { date in rows.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) } }
        return card {
            Text(L10n.text("波动率趋势")).font(.headline)
            Picker(L10n.text("时间范围"), selection: $range) {
                Text("1M").tag(21)
                Text("3M").tag(63)
                Text("1Y").tag(252)
            }.pickerStyle(.segmented)
                .onChange(of: range) { _, _ in selectedDate = nil }
            HStack(spacing: 16) {
                Label("VXSMH", systemImage: "circle.fill").foregroundStyle(CatfolioPalette.securityPriceLine)
                Label("MA20", systemImage: "minus").foregroundStyle(.secondary)
            }.font(.caption)
            if let focused {
                Text("\(focused.date)  ·  VXSMH \(String(format: "%.2f", focused.close))  ·  MA20 \(focused.ma20.map { String(format: "%.2f", $0) } ?? "—")")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            StandardLineChart(
                series: [
                    StandardLineChartSeries(id: "VXSMH", points: rows.map { .init(date: $0.timestamp, value: $0.close) }, color: CatfolioPalette.securityPriceLine),
                    StandardLineChartSeries(id: "MA20", points: rows.compactMap { row in row.ma20.map { .init(date: row.timestamp, value: $0) } }, color: .secondary, dash: [5, 4], latestPointRadius: nil)
                ],
                interactionDates: rows.map(\.timestamp), domain: low...high,
                yTicks: (0...3).map { low + (high-low) * Double($0)/3 },
                transitionKey: "sentiment-\(range)", appearanceID: "industry-sentiment", dataTransition: .viewportZoom,
                selectedDate: selectedDate, selectionSeriesIDs: ["VXSMH", "MA20"],
                yAxisLabel: { String(format: "%.1f", $0) },
                xAxisLabel: { $0.formatted(.dateTime.month(.twoDigits).day(.twoDigits)) },
                onSelect: { selectedDate = $0 }, onInteractionEnded: { _ in selectedDate = nil }
            ).frame(height: 240)
            HStack {
                Text(L10n.text("SMH 成交量"))
                Spacer()
                // Through the shared ladder, so this reads 万 and 亿 in Chinese
                // like every other abbreviated figure. See DESIGN.md.
                Text((focused ?? rows.last)?.volume.map { DisplayFormat.compact($0) } ?? "—")
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Chart(rows) { row in
                if let volume = row.volume {
                    BarMark(x: .value("Date", row.timestamp), y: .value("Volume", volume))
                        .foregroundStyle(CatfolioPalette.securityPriceLine.opacity(selectedDate == nil || row.date == focused?.date ? 0.4 : 0.15))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { _ in AxisValueLabel().font(.caption2).foregroundStyle(.secondary) } }
            .chartXScale(domain: (rows.first!.timestamp)...(rows.last!.timestamp))
            .frame(height: 70)
        }
    }
}

private struct SentimentGauge: View {
    let score: Int?
    private var label: L10n.Message {
        guard let score else { return "暂无评分" }
        switch score {
        case ..<20: return "极度恐惧"
        case ..<40: return "恐惧"
        case ...60: return "中性"
        case ...80: return "贪婪"
        default: return "极度贪婪"
        }
    }
    private let colors: [Color] = [.red, .orange, .yellow, .mint, .green]
    var body: some View {
        VStack(spacing: 12) {
            Canvas { context, size in
                let center = CGPoint(x: size.width/2, y: size.height-12)
                let radius = min(size.width/2-16, size.height-28)
                for index in 0..<5 {
                    var arc = Path()
                    arc.addArc(center: center, radius: radius, startAngle: .degrees(180 + Double(index)*36 + 1.5), endAngle: .degrees(180 + Double(index+1)*36 - 1.5), clockwise: false)
                    context.stroke(arc, with: .color(colors[index].opacity(0.8)), style: StrokeStyle(lineWidth: 16))
                }
                if let score {
                    let angle = Double(score)/100 * .pi + .pi
                    let tip = CGPoint(x: center.x + cos(angle)*(radius-22), y: center.y + sin(angle)*(radius-22))
                    var needle = Path(); needle.move(to: center); needle.addLine(to: tip)
                    context.stroke(needle, with: .color(.primary), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    context.fill(Path(ellipseIn: CGRect(x: center.x-5,y: center.y-5,width: 10,height: 10)), with: .color(.primary))
                }
            }.frame(height: 145).accessibilityHidden(true)
            Text(score.map(String.init) ?? "—").font(Typography.number(.display, weight: .semibold)).monospacedDigit()
            Text(L10n.text(label)).font(.subheadline).foregroundStyle(.secondary)
            HStack { Text(L10n.text("极度恐惧")); Spacer(); Text(L10n.text("极度贪婪")) }.font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("行业情绪"))
        .accessibilityValue("\(score.map(String.init) ?? "—") / 100，\(L10n.text(label))")
    }
}
