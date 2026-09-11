import SwiftUI
import Charts
import WebKit

struct StockChartsRotationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = StockChartsRRGStore()
    @State private var selected: String?
    @State private var index = -1
    @State private var playing = false
    @State private var showInfo = false
    private var response: StockChartsRRGResponse? { store.capture?.response }
    private var endIndex: Int { min(max(30, index < 0 ? (response?.rrgdata.count ?? 1) - 1 : index), (response?.rrgdata.count ?? 1) - 1) }
    private var weeks: [StockChartsRRGResponse.Week] { response?.trail(endingAt: endIndex) ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let response, let current = weeks.last, let start = weeks.first {
                    benchmark(current: current, start: start)
                    StockChartsRRGPlot(weeks: weeks, selected: $selected)
                        .frame(height: 300)
                        .accessibilityIdentifier("stockcharts-rrg-chart")
                    playback(response)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.text("六大市场指数")).font(.system(size: 17, weight: .semibold, design: .rounded))
                            Spacer()
                            if selected != nil { Button(L10n.text("取消选择")) { selected = nil }.font(.caption) }
                        }
                        Text(L10n.text("周线 · 30 周尾迹 · 基准 $SPX"))
                            .font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                        ForEach(StockChartsRRGResponse.symbols, id: \.self) { symbol in
                            if let value = current.rrgdata[symbol], let first = start.rrgdata[symbol] {
                                market(symbol, name: response.name(symbol), value: value, change: value.price / first.price - 1)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.text("来源时间：\(current.end)（纽约）"))
                        if store.isLoading {
                            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(L10n.text("正在读取 StockCharts…")) }
                        } else if store.failed {
                            Text(L10n.text("更新失败，保留上次来源快照。"))
                                .foregroundStyle(CatfolioTheme.warning)
                        }
                        Text(L10n.text("显示来源快照；最新周点可能包含未收盘行情。"))
                        Text(L10n.text("RS-Ratio 与 RS-Momentum 是以 100 为中线的指标值，不是百分比。涨跌幅对应当前显示的 30 周区间。"))
                        Link("StockCharts · Relative Rotation Graphs®", destination: StockChartsRRGResponse.loadURL)
                        Text(L10n.text("仅供市场观察，不构成投资建议。"))
                    }
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView(L10n.text("暂无 RRG 数据"), systemImage: "chart.xyaxis.line", description: Text(L10n.text("请刷新以读取 StockCharts 的公开图表。")))
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemBackground)).foregroundStyle(.primary).tint(.primary)
        .navigationTitle(L10n.text("市场轮动 · RRG"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L10n.text("刷新来源数据"), systemImage: "arrow.clockwise") { playing = false; store.refresh() }
                        .disabled(store.isLoading)
                    Button(L10n.text("如何阅读这张图"), systemImage: "info.circle") { showInfo = true }
                    Link(L10n.text("在 StockCharts 查看"), destination: StockChartsRRGResponse.loadURL)
                } label: { Image(systemName: "ellipsis") }
                .tint(.primary)
                .accessibilityLabel(L10n.text("更多选项"))
            }
        }
        // WebKit receives the same public response as the source chart. The plot,
        // timeline and all visible content above are native SwiftUI/UIKit.
        .background {
            if let browser = store.webView {
                StockChartsSourceBrowser(browser: browser)
                    .frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task { store.refresh() }
        .onChange(of: store.capture?.capturedAt) { _, _ in if !playing { index = -1 } }
        .onDisappear { playing = false; store.cancel() }
        .task(id: playing) {
            guard playing, let response else { return }
            if endIndex == response.rrgdata.count - 1 { index = 30 }
            while playing && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 1500 : 900)) } catch { break }
                guard endIndex + 1 < response.rrgdata.count else { playing = false; break }
                index = endIndex + 1
            }
        }
        .sheet(isPresented: $showInfo) {
            NavigationStack {
                List {
                    Text(L10n.text("这张对照图直接展示 StockCharts 返回的 JdK RS-Ratio 和 RS-Momentum，未套用板块轮动 v2 的计算、压缩或标签迟滞。"))
                    Text(L10n.text("30 周尾迹包含当前点和之前 30 个周点。每个点保留来源数值，拖动时间条可回看历史。"))
                    Text(L10n.text("右上领先、右下减弱、左下落后、左上改善；两轴中线均为 100。"))
                    Text(L10n.text("六个指数按来源默认列表展示，基准为 S&P 500 指数 $SPX。"))
                    Link(L10n.text("在 StockCharts 查看"), destination: StockChartsRRGResponse.loadURL)
                }
                .softTopScrollEdge()
                .navigationTitle(L10n.text("如何阅读这张图"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { showInfo = false } } }
            }.presentationDetents([.medium, .large])
        }
    }

    private func benchmark(current: StockChartsRRGResponse.Week, start: StockChartsRRGResponse.Week) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("S&P 500 · $SPX").font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                Text(current.benchmark.formatted(.number.precision(.fractionLength(2))))
                    .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            let domain = StandardLineChartEntrancePhase.domain(weeks.map(\.benchmark))
            StandardLineChartEntrance { phase in
            Chart(Array(weeks.enumerated()), id: \.element.id) { item in
                LineMark(x: .value("Date", item.element.date), y: .value("S&P 500", phase.value(item.element.benchmark,
                    fraction: Double(item.offset) / Double(max(1, weeks.count - 1)), domain: domain)))
                    .foregroundStyle(Color.primary.opacity(0.65)).lineStyle(StrokeStyle(lineWidth: 1.3))
            }.chartYScale(domain: domain).chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 42)
            }
            HStack {
                Text("\(start.date) — \(current.date)")
                Spacer()
                Text(percent(current.benchmark / start.benchmark - 1))
            }.font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func playback(_ response: StockChartsRRGResponse) -> some View {
        HStack(spacing: 17) {
            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold)).offset(x: playing ? 0 : 1)
                    .frame(width: 50, height: 50).background(RotationPalette.control, in: Circle())
            }.buttonStyle(.plain)
                .accessibilityLabel(playing ? L10n.text("暂停历史回放") : L10n.text("播放历史快照"))
                .accessibilityIdentifier("stockcharts-rrg-play")
                .disabled(response.rrgdata.count <= 31)
            SectorRotationTimeline(index: max(0, endIndex - 30), dates: Array(response.rrgdata.dropFirst(30)).map(\.date)) { value in
                playing = false; index = value + 30
            }.frame(height: 52).accessibilityIdentifier("stockcharts-rrg-timeline")
        }.padding(.leading, 5).padding(.trailing, 16)
    }

    private func market(_ symbol: String, name: String, value: StockChartsRRGResponse.Value, change: Double) -> some View {
        Button { selected = selected == symbol ? nil : symbol } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Circle().fill(Color(uiColor: StockChartsRRGChart.color(symbol))).frame(width: 8, height: 8)
                    Text(symbol).font(.system(size: 16, weight: .semibold, design: .rounded))
                    Text(name).font(.system(size: 13, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Text(SectorRotationSnapshot.Sector.label(value.quadrant)).font(.system(size: 11, design: .rounded))
                }
                HStack(spacing: 16) {
                    metric("RS-Ratio", value.jdkratio.formatted(.number.precision(.fractionLength(2))))
                    metric("RS-Momentum", value.jdkmom.formatted(.number.precision(.fractionLength(2))))
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(value.price.formatted(.number.precision(.fractionLength(2))))
                        Text(percent(change)).foregroundStyle(change >= 0 ? CatfolioTheme.positive : CatfolioTheme.danger)
                    }.font(.system(size: 12, design: .rounded)).monospacedDigit()
                }
            }
            .padding(16).background(selected == symbol ? RotationPalette.cardSelected : RotationPalette.card, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) · \(symbol)")
        .accessibilityValue("RS-Ratio \(value.jdkratio), RS-Momentum \(value.jdkmom), \(SectorRotationSnapshot.Sector.label(value.quadrant))")
        .accessibilityAddTraits(selected == symbol ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("stockcharts-rrg.\(symbol)")
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
    private func percent(_ value: Double) -> String { String(format: "%+.2f%%", value * 100) }
}

private struct StockChartsSourceBrowser: UIViewRepresentable {
    let browser: WKWebView
    func makeUIView(context: Context) -> WKWebView { browser }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
