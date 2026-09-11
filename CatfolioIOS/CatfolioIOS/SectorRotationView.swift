import SwiftUI

struct SectorRotationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("sectorRotation.endpoint") private var endpoint = ""
    @State private var sectorPerformance = SectorPerformanceStore()
    @State private var snapshots: [String: SectorRotationSnapshot] = [:]
    @State private var dates: [String] = []
    @State private var selectedDate = ""
    @State private var selectedSymbol: String? = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--rotation-preview-trail") ? "XLK" : nil
        #else
        nil
        #endif
    }()
    @State private var isLoading = false
    @State private var failed = false
    @State private var playing = false
    @State private var showSource = false
    @State private var showRules = false
    @State private var precise: SectorRotationSnapshot.Sector?
    @State private var requestID = UUID()
    private var snapshot: SectorRotationSnapshot? { snapshots[selectedDate] }
    private var selection: SectorRotationSnapshot.Sector? { snapshot?.sectors.first { $0.symbol == selectedSymbol } }
    private var index: Double { Double(dates.firstIndex(of: selectedDate) ?? max(0, dates.count - 1)) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let snapshot {
                    SectorRotationPlot(snapshot: snapshot, selected: $selectedSymbol, precise: $precise)
                        .aspectRatio(370.0 / 246.0, contentMode: .fit)
                        .accessibilityIdentifier("rotation-chart")
                    playback.padding(.top, 28)
                    if let sector = selection {
                        detail(sector).padding(.top, 20)
                    }
                    SectorPerformancePanel(store: sectorPerformance, rotation: snapshot)
                        .padding(.top, 28)
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.text("数据截至 \(snapshot.asOf)（纽约）"))
                            .monospacedDigit()
                        Spacer(minLength: 8)
                        Menu {
                            ForEach(snapshot.sectors) { sector in
                                Button("\(sector.displayName) · \(sector.symbol) · \(sector.displayQuadrant)") {
                                    selectedSymbol = sector.symbol
                                }
                            }
                            if selectedSymbol != nil {
                                Button(L10n.text("取消选择")) { selectedSymbol = nil }
                            }
                        } label: {
                            Text(L10n.text("全部板块"))
                        }
                    }
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.45))
                    .padding(.top, 14)
                    if failed || (dates.last.flatMap { snapshots[$0] }?.isExpired ?? snapshot.isExpired) {
                        Text(L10n.text("数据更新延迟，当前显示上次可用快照。"))
                            .font(.caption2).foregroundStyle(CatfolioTheme.warning).padding(.top, 8)
                    }
                    if snapshot.backfilled {
                        Text(L10n.text("回填快照")).font(.caption2).foregroundStyle(.gray).padding(.top, 4)
                    }
                    Text(L10n.text("位置相对其他板块，不是绝对涨跌。图心为板块中位数。"))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .padding(.top, 14)
                } else if isLoading {
                    ProgressView(L10n.text("读取每日快照…")).frame(maxWidth: .infinity, minHeight: 246)
                } else {
                    ContentUnavailableView(L10n.text("暂无板块轮动数据"), systemImage: "chart.xyaxis.line", description: Text(L10n.text("连接快照服务后读取每日板块数据。")))
                }
                Text(L10n.text("展示板块相对 SPY 的趋势和动量，仅供市场观察，不构成投资建议。"))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        // Solid page and bar in the system ground: white by day, black at
        // night. The bar stays opaque, as designed; it no longer forces light.
        .background(Color(uiColor: .systemBackground))
        .foregroundStyle(.primary)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .tint(.primary)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(L10n.text("如何阅读这张图"), systemImage: "info.circle") { showRules = true }
                    Button(L10n.text("快照数据源"), systemImage: "network") { showSource = true }
                } label: { Image(systemName: "ellipsis") }
                .tint(.primary)
                .accessibilityLabel(L10n.text("更多选项"))
            }
        }
        .task { await restore(); await refresh() }
        .task { await sectorPerformance.refresh() }
        .refreshable {
            playing = false
            async let prices: Void = sectorPerformance.refresh()
            await refresh()
            await prices
        }
        .task(id: playing) {
            guard playing else { return }
            if selectedDate == dates.last, let first = dates.first { await selectDate(first) }
            while playing && !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 1500 : 900)) } catch { break }
                guard let i = dates.firstIndex(of: selectedDate), i + 1 < dates.count else { playing = false; break }
                await selectDate(dates[i + 1])
                if failed { playing = false }
            }
        }
        .onDisappear { playing = false; requestID = UUID() }
        .sheet(isPresented: $showRules) {
            NavigationStack {
                List {
                    Text(L10n.text("中期窗口为第 63 至第 21 个交易日前；近月窗口为最近 21 个交易日。先计算相对 SPY 的对数差并作 5 日均值，再用当日中位数与 MAD 标准化及 tanh 压缩。"))
                    Text(L10n.text("中心 ±0.25 范围为中性。新象限连续两交易日成立才切换文字标签，文字可能暂时不同于点所在象限。百分比表示相对 SPY 的变化；坐标表示相对其他板块的位置。"))
                    Text(L10n.text("轨迹读取历史快照，每个完整 ISO 周取最后有效交易日。初始化历史使用回填时可得的复权价，可能与当时发布值略有差异。此图不使用 JdK RRG 专有计算。"))
                }.softTopScrollEdge().navigationTitle(L10n.text("如何阅读这张图"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { showRules = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSource) {
            NavigationStack {
                Form {
                    TextField("https://…/api/sector-rotation", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(L10n.text("填写已部署的 HTTPS 快照 API。未连接时保留本机快照，行情过期会明确标记。此读取不触发账户同步或行情计算。"))
                }.softTopScrollEdge().navigationTitle(L10n.text("快照数据源"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { showSource = false; Task { await refresh() } } } }
            }.presentationDetents([.medium])
        }
        .alert(L10n.text("精确值"), isPresented: Binding(get: { precise != nil }, set: { if !$0 { precise = nil } })) {
            Button(L10n.text("完成")) { precise = nil }
        } message: {
            if let precise { Text("\(precise.symbol) · \(precise.displayQuadrant)\nx: \(precise.x.formatted(.number.precision(.fractionLength(4))))  y: \(precise.y.formatted(.number.precision(.fractionLength(4))))\n\(percent(precise.relativeTrend)) / \(percent(precise.relativeMomentum))") }
        }
    }
    private func detail(_ sector: SectorRotationSnapshot.Sector) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(SectorRotationPlot.color(sector.symbol)).frame(width: 7, height: 7)
                Text("\(sector.displayName) · \(sector.symbol)").font(.subheadline.weight(.semibold))
                Spacer()
                Text(sector.displayQuadrant).font(.caption)
            }
            metric(L10n.text("中期相对强弱"), percent(sector.relativeTrend))
            metric(L10n.text("近 1 月相对动量"), percent(sector.relativeMomentum))
            metric(L10n.text("本周变化"), sector.weeklyLabel)
            Text(sector.explanation).font(.caption).foregroundStyle(.gray)
        }
        .padding(16)
        .background(RotationPalette.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var playback: some View {
        HStack(spacing: 17) {
            Button { playing.toggle() } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .offset(x: playing ? 0 : 1)
                    .frame(width: 50, height: 50)
                    .background(RotationPalette.control, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("rotation-play")
            .accessibilityLabel(playing ? L10n.text("暂停历史回放") : L10n.text("播放历史快照"))
            .disabled(dates.count < 2)
            SectorRotationTimeline(index: Int(index), dates: dates) { value in
                playing = false
                Task { await selectDate(dates[value]) }
            }
            .frame(height: 52)
        }
        .padding(.leading, 5)
        .padding(.trailing, 16)
    }
    private func metric(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.subheadline)
    }
    private func percent(_ value: Double) -> String { String(format: "%+0.1f%%", value * 100) }
    private func restore() async {
        let local = await SectorRotationStore.shared.local()
        for item in local { snapshots[item.asOf] = item }
        dates = snapshots.keys.sorted(); selectedDate = dates.last ?? ""
    }
    private func refresh() async {
        guard !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = UUID(); requestID = id; isLoading = true
        defer { if requestID == id { isLoading = false } }
        do {
            let latest = try await SectorRotationStore.shared.fetch(endpoint: endpoint)
            guard id == requestID else { return }
            snapshots[latest.asOf] = latest; dates = latest.dates; selectedDate = latest.asOf; failed = false
        } catch { if requestID == id { failed = true } }
    }
    private func selectDate(_ date: String) async {
        let id = UUID(); requestID = id; isLoading = false
        if snapshots[date] != nil { selectedDate = date; return }
        guard !endpoint.isEmpty else { return }
        do {
            let item = try await SectorRotationStore.shared.fetch(endpoint: endpoint, date: date)
            guard id == requestID else { return }
            snapshots[item.asOf] = item; selectedDate = item.asOf; failed = false
        } catch { if requestID == id { failed = true } }
    }
}
