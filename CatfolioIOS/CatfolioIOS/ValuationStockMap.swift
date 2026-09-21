import SwiftUI
import Charts
import RealityKit

struct ValuationStockMap: View {
    let matrix: ValuationMatrix
    var expanded = false
    @State private var mode = 0
    @State private var selectedTicker: String?
    @State private var showFullScreen = false
    @State private var resetID = UUID()
    @State private var showDetails = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(matrix: ValuationMatrix, expanded: Bool = false, initialMode: Int = 0, initialSelection: String? = nil) {
        self.matrix = matrix
        self.expanded = expanded
        _mode = State(initialValue: initialMode)
        _selectedTicker = State(initialValue: initialSelection)
    }

    private var plotted: [ValuationBubble] { matrix.rows.filter(\.isThreeDimensional) }
    private var twoDimensional: [ValuationBubble] { matrix.rows.filter { $0.epsGrowthPercent != nil } }
    private var selected: ValuationBubble? {
        matrix.rows.first { $0.ticker == selectedTicker } ?? plotted.first ?? twoDimensional.first ?? matrix.rows.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("估值地图"))
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                    Text("P/E · EPS Growth · ROIC")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker(L10n.text("图表视图"), selection: $mode) {
                    Text("3D").tag(0)
                    Text("2D").tag(1)
                }.pickerStyle(.segmented).frame(width: 104)
            }

            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 0.44, green: 0.56, blue: 1)).frame(width: 5, height: 5)
                    Text(L10n.text("持仓分布"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    if mode == 0 && expanded {
                        Button { resetID = UUID() } label: {
                            Image(systemName: "arrow.counterclockwise").frame(width: 36, height: 36)
                        }.accessibilityLabel(L10n.text("重置视角"))
                    }
                    Button {
                        if expanded { dismiss() } else { showFullScreen = true }
                    } label: {
                        Image(systemName: expanded ? "xmark" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .medium)).frame(width: 36, height: 36)
                            .background(.white.opacity(0.06), in: Circle()).frame(width: 44, height: 44)
                    }.accessibilityLabel(L10n.label(expanded ? "关闭" : "全屏查看"))
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 18).padding(.top, 12)

                Group {
                    if mode == 0 {
                        if plotted.isEmpty { emptyChart }
                        else {
                            StockMapScene(rows: plotted, selectedTicker: selected?.ticker,
                                          interactive: expanded, onSelect: { selectedTicker = $0 })
                                .id(resetID).accessibilityHidden(true)
                        }
                    } else if twoDimensional.isEmpty { emptyChart }
                    else { twoDimensionalChart.padding(.horizontal, 12).padding(.top, 18) }
                }
                .frame(height: expanded ? 370 : 315)
                .clipped()

                HStack(spacing: 5) {
                    Image(systemName: "circle.dotted").font(.system(size: 10))
                    Text(L10n.text("大小表示仓位"))
                    Spacer()
                    if mode == 0 {
                        Image(systemName: expanded ? "hand.draw" : "hand.tap").font(.system(size: 10))
                        Text(L10n.label(expanded ? "拖动旋转" : "点选股票"))
                    } else {
                        Text("ROIC")
                        Text(L10n.text("低"))
                        Capsule().fill(Color(red: 0.48, green: 0.53, blue: 0.65)).frame(width: 12, height: 4)
                        Capsule().fill(CatfolioStyle.blue).frame(width: 12, height: 4)
                        Text(L10n.text("高"))
                    }
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.48))
                .padding(.horizontal, 20).padding(.top, 3).padding(.bottom, 18)

                Rectangle().fill(.white.opacity(0.09)).frame(height: 0.5).padding(.horizontal, 20)
                if let selected { selectedMetrics(selected).padding(20) }
            }
            .background(Color(red: 0.045, green: 0.063, blue: 0.094))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .environment(\.colorScheme, .dark)

            DisclosureGroup(isExpanded: $showDetails) {
                details
            } label: {
                HStack(spacing: 5) {
                    Text(L10n.text("数据与计算依据"))
                    Spacer()
                    Text("\(plotted.count) / \(matrix.rows.count + matrix.unavailable.count)")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Text(L10n.text("可绘制")).foregroundStyle(.secondary)
                }.font(.system(size: 12, weight: .medium)).foregroundStyle(.primary)
            }.tint(.secondary)
        }
        .buttonStyle(.plain)
        .appFullScreenCover(isPresented: $showFullScreen) {
            NavigationStack {
                ScrollView { ValuationStockMap(matrix: matrix, expanded: true, initialMode: mode, initialSelection: selected?.ticker).padding(20) }
                    .appPageBackground(Color(.systemBackground))
            }
        }
        .onChange(of: colorScheme) { _, _ in resetID = UUID() }
        .onChange(of: matrix) { _, new in
            resetID = UUID()
            if !new.rows.contains(where: { $0.ticker == selectedTicker }) { selectedTicker = nil }
        }
    }

    private var emptyChart: some View {
        ContentUnavailableView(L10n.text("暂无完整指标"), systemImage: "chart.dots.scatter",
                               description: Text(L10n.text("缺失指标不会按零绘制，请查看下方数据明细。")))
    }
    private func selectedMetrics(_ row: ValuationBubble) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                Menu {
                    ForEach(matrix.rows) { item in
                        Button {
                            selectedTicker = item.ticker
                        } label: {
                            Label(item.ticker, systemImage: item.ticker == selected?.ticker ? "checkmark" : "circle")
                        }
                        .accessibilityLabel("\(item.ticker), P/E \(item.pe.formatted(.number.precision(.fractionLength(1)))), EPS Growth \(percent(item.epsGrowthPercent)), ROIC \(percent(item.roicPercent))")
                    }
                } label: {
                    HStack(spacing: 9) {
                        Circle().fill(StockMapAppearance.color(row.ticker, tickers: plotted.map(\.ticker))).frame(width: 8, height: 8)
                        Text(row.ticker).font(.system(size: 19, weight: .semibold, design: .rounded))
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                    }.frame(minHeight: 44)
                }
                Spacer()
                Text("\(L10n.text("仓位")) \(percent(row.weight * 100))")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            }
            HStack(alignment: .top, spacing: 8) {
                metric("P/E", row.pe.formatted(.number.precision(.fractionLength(1))) + "×")
                metric("EPS Growth", percent(row.epsGrowthPercent))
                metric("ROIC", percent(row.roicPercent))
            }
            if let reason = row.qualityReason {
                Text("ROIC: \(L10n.label(reason))").font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
            if let reason = row.quality?.epsUnavailableReason {
                Text("EPS: \(L10n.label(reason))").font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
            HStack(spacing: 4) {
                Text(L10n.text("年度 EPS / ROIC"))
                if let period = row.quality?.periodEnd { Text("· \(period)") }
            }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        }.foregroundStyle(.white)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("EPS Growth 与 ROIC 使用年度财报；P/E 的期间单独列示。"))
            if mode == 1 { Text(L10n.text("空心点：ROIC 缺失")) }
            Text(L10n.text("ROIC = 营业利润 × (1 − 有效税率) ÷ 期初期末平均投入资本。投入资本 = 权益 + 已披露有息借款 − 现金及现金等价物；不调整经营租赁、商誉或研发。"))
            Text(L10n.text("EPS Growth = 本年稀释 EPS ÷ 上年稀释 EPS − 1。上年 EPS 不为正时不计算增长率。"))
            ForEach(matrix.rows) { row in
                Divider()
                Text(row.ticker).fontWeight(.semibold)
                Text("P/E: \(row.peSource ?? "—") · \(row.pePeriod ?? L10n.text("期间未提供"))")
                if let q = row.quality {
                    Text("SEC · \(L10n.text("年度")) \(q.periodStart) – \(q.periodEnd)")
                    Text("EPS: \(decimal(q.priorDilutedEPS)) → \(decimal(q.dilutedEPS)) USD")
                    Text("\(L10n.text("有效税率")): \(percent(q.effectiveTaxRate.map { $0 * 100 }))")
                    Text("NOPAT: \(decimal(q.nopat)) USD")
                    Text("\(L10n.text("投入资本（期初 / 期末）")): \(decimal(q.openingCapital)) / \(decimal(q.closingCapital)) USD")
                    Text("\(L10n.text("申报日期")): \(q.filed)")
                    if let url = q.filingURL {
                        Link(L10n.text("查看 SEC 原始申报"), destination: url)
                            .foregroundStyle(CatfolioStyle.blue)
                    }
                    if let reason = q.epsUnavailableReason { Text(L10n.label(reason)) }
                }
                if let reason = row.qualityReason { Text(L10n.label(reason)) }
            }
            ForEach(matrix.unavailable) { row in
                Divider()
                Text("\(row.ticker) · \(L10n.label(row.reason))")
            }
            ForEach(Array(matrix.warnings.enumerated()), id: \.offset) { _, warning in
                Text(L10n.label(warning))
            }
        }.font(.caption2).foregroundStyle(.secondary).padding(.top, 10)
    }
    private var twoDimensionalChart: some View {
        Chart(twoDimensional) { row in
            PointMark(x: .value("P/E", row.pe), y: .value("EPS Growth", row.epsGrowthPercent!))
                .foregroundStyle(qualityColor(row))
                .symbol {
                    let size = max(8, 28 * sqrt(max(0, row.weight) / max(twoDimensional.map(\.weight).max() ?? 1, 0.0001)))
                    Circle().strokeBorder(qualityColor(row), lineWidth: row.roicPercent == nil ? 2 : size / 2)
                        .frame(width: size, height: size)
                }
                .annotation(position: .top) {
                    if row.ticker == selected?.ticker { Text(row.ticker).font(.caption2.weight(.semibold)) }
                }
        }
        .chartSymbolSizeScale(range: 35...450)
        .chartLegend(.hidden)
        .chartXAxisLabel("P/E (×)")
        .chartYAxisLabel("EPS Growth (%)")
        .padding(.horizontal, 8)
        .accessibilityLabel(L10n.text("P/E 与年度 EPS 增长，颜色表示 ROIC"))
    }
    private func qualityColor(_ row: ValuationBubble) -> Color {
        guard let q = row.roicPercent else { return .secondary }
        let values = plotted.compactMap(\.roicPercent)
        let low = values.min() ?? 0, high = values.max() ?? 1
        let t = high > low ? (q - low) / (high - low) : 0.5
        return Color(red: 0.64 - 0.20 * t, green: 0.66 - 0.11 * t, blue: 0.70 + 0.30 * t)
    }
    private func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) + "%" } ?? "—"
    }
    private func decimal(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—"
    }
}

private enum StockMapAppearance {
    static func color(_ ticker: String, tickers: [String]) -> Color {
        let colors: [Color] = [
            Color(red: 0.45, green: 0.57, blue: 1),
            Color(red: 0.35, green: 0.82, blue: 0.86),
            Color(red: 0.70, green: 0.55, blue: 1),
            Color(red: 0.94, green: 0.74, blue: 0.36),
            Color(red: 0.92, green: 0.52, blue: 0.72),
            Color(red: 0.46, green: 0.76, blue: 0.69),
            Color(red: 0.83, green: 0.66, blue: 1),
        ]
        guard let index = tickers.sorted().firstIndex(of: ticker) else { return .gray }
        return colors[index % colors.count]
    }
    static func material(_ ticker: String, tickers: [String]) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(color(ticker, tickers: tickers)))
        material.roughness = .init(floatLiteral: 0.38)
        material.metallic = .init(floatLiteral: 0.12)
        material.clearcoat = .init(floatLiteral: 0.4)
        return material
    }
}

/// Domains include negative growth / ROIC and never clip outliers into a false
/// coordinate. All three axes use the same linear, labelled mapping.
struct StockMapDomain {
    let lower: Double
    let upper: Double
    init(_ values: [Double]) {
        let finite = values.filter(\.isFinite)
        let minimum = min(0, finite.min() ?? 0)
        let maximum = max(0, finite.max() ?? 0)
        let span = max(10, maximum - minimum)
        lower = minimum < 0 ? minimum - span * 0.08 : 0
        upper = max(lower + 10, maximum + span * 0.08)
    }
    func coordinate(_ value: Double) -> Float { Float((value - lower) / (upper - lower) * 1.4 - 0.7) }
    var ticks: [Double] { (0...4).map { lower + (upper - lower) * Double($0) / 4 } }
}

private struct StockMapScene: View {
    let rows: [ValuationBubble]
    let selectedTicker: String?
    let interactive: Bool
    let onSelect: (String) -> Void
    @State private var yaw: Float = -0.55
    @State private var pitch: Float = 0.3
    @State private var zoom: Float = 1
    @GestureState private var drag: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1

    private var rotation: simd_quatf {
        simd_quatf(angle: min(0.9, max(-0.45, pitch + Float(drag.height) * 0.004)), axis: [1, 0, 0])
            * simd_quatf(angle: yaw + Float(drag.width) * 0.006, axis: [0, 1, 0])
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RealityView { content in
                    content.camera = .virtual
                    let root = buildScene()
                    content.add(root)
                    let camera = PerspectiveCamera()
                    camera.camera.fieldOfViewInDegrees = 42
                    camera.position = [0, 0.02, 3.55]
                    content.add(camera)
                    let light = DirectionalLight()
                    light.light.intensity = 1600
                    light.look(at: [0, 0, 0], from: [-3, 4, 4], relativeTo: nil)
                    content.add(light)
                    let fill = DirectionalLight()
                    fill.light.intensity = 450
                    fill.look(at: [0, 0, 0], from: [3, -1, 2], relativeTo: nil)
                    content.add(fill)
                    update(root)
                } update: { content in
                    if let root = content.entities.first(where: { $0.name == "stock-map" }) { update(root) }
                }
                .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
                    if value.entity.name.hasPrefix("stock:") { onSelect(String(value.entity.name.dropFirst(6))) }
                })
                .highPriorityGesture(DragGesture(minimumDistance: 8).updating($drag) { value, state, _ in
                    if interactive { state = value.translation }
                }.onEnded { value in
                    guard interactive else { return }
                    yaw += Float(value.translation.width) * 0.006
                    pitch = min(0.9, max(-0.45, pitch + Float(value.translation.height) * 0.004))
                }, including: interactive ? .all : .none)
                .simultaneousGesture(MagnifyGesture().updating($magnification) { value, state, _ in
                    if interactive { state = value.magnification }
                }.onEnded { value in
                    if interactive { zoom = min(1.5, max(0.65, zoom * Float(value.magnification))) }
                }, including: interactive ? .all : .none)
                annotations(in: geometry.size).allowsHitTesting(false)
            }
        }
    }

    private struct Annotation: Identifiable {
        let ticker: String
        let center: CGPoint
        let point: CGPoint
        let radius: CGFloat
        var id: String { ticker }
    }
    private func labelLayout(in size: CGSize) -> [Annotation] {
        let pe = StockMapDomain(rows.map(\.pe))
        let growth = StockMapDomain(rows.compactMap(\.epsGrowthPercent))
        let quality = StockMapDomain(rows.compactMap(\.roicPercent))
        let focal = size.height / (2 * tan(21 * .pi / 180))
        let scale = min(1.5, max(0.65, zoom * Float(magnification)))
        let maxWeight = max(rows.map(\.weight).max() ?? 1, 0.0001)
        let points = rows.compactMap { row -> (ValuationBubble, CGPoint, CGFloat)? in
            guard let eps = row.epsGrowthPercent, let roic = row.roicPercent else { return nil }
            let world = rotation.act(SIMD3<Float>(pe.coordinate(row.pe), quality.coordinate(roic), -growth.coordinate(eps))) * scale
            let depth = CGFloat(3.55 - world.z)
            guard depth > 0 else { return nil }
            let point = CGPoint(x: size.width / 2 + CGFloat(world.x) * focal / depth,
                                y: size.height / 2 - CGFloat(world.y - 0.02) * focal / depth)
            let radius = CGFloat(max(0.018, 0.13 * Float(cbrt(max(0, row.weight) / maxWeight))) * scale) * focal / depth
            return (row, point, radius)
        }
        var occupied: [CGRect] = []
        var result: [Annotation] = []
        let sorted = points.sorted {
            if ($0.0.ticker == selectedTicker) != ($1.0.ticker == selectedTicker) { return $0.0.ticker == selectedTicker }
            return $0.0.weight > $1.0.weight
        }
        for (index, item) in sorted.enumerated() {
            let (row, point, radius) = item
            guard index < 7 || row.ticker == selectedTicker else { continue }
            let width = CGFloat(row.ticker.count) * 7 + 12
            let gap = radius + width / 2 + 6
            let offsets: [CGPoint] = [CGPoint(x: gap, y: -12), CGPoint(x: -gap, y: -12),
                                      CGPoint(x: 0, y: -radius - 17), CGPoint(x: gap, y: 18),
                                      CGPoint(x: -gap, y: 18), CGPoint(x: 0, y: radius + 18)]
            let candidates = offsets.map { offset -> CGRect in
                let x = max(8, min(size.width - width - 8, point.x + offset.x - width / 2))
                let y = max(8, min(size.height - 26, point.y + offset.y - 10))
                return CGRect(x: x, y: y, width: width, height: 20)
            }
            func penalty(_ rect: CGRect) -> CGFloat {
                let blockers = occupied + points.map { _, p, r in
                    CGRect(x: p.x - r - 3, y: p.y - r - 3, width: 2 * r + 6, height: 2 * r + 6)
                }
                return blockers.reduce(0) { total, blocker in
                    let overlap = rect.intersection(blocker)
                    return total + (overlap.isNull ? 0 : overlap.width * overlap.height)
                }
            }
            guard let rect = candidates.min(by: { penalty($0) < penalty($1) }) else { continue }
            occupied.append(rect.insetBy(dx: -3, dy: -3))
            result.append(Annotation(ticker: row.ticker, center: CGPoint(x: rect.midX, y: rect.midY), point: point, radius: radius))
        }
        return result
    }
    private func annotations(in size: CGSize) -> some View {
        let labels = labelLayout(in: size)
        return ZStack {
            ForEach(labels) { label in
                let color = StockMapAppearance.color(label.ticker, tickers: rows.map(\.ticker))
                Path { path in
                    let dx = label.center.x - label.point.x, dy = label.center.y - label.point.y
                    let distance = max(1, hypot(dx, dy))
                    path.move(to: CGPoint(x: label.point.x + dx / distance * label.radius,
                                         y: label.point.y + dy / distance * label.radius))
                    path.addLine(to: label.center)
                }.stroke(color.opacity(0.55), lineWidth: 0.7)
                Text(label.ticker)
                    .font(.system(size: label.ticker == selectedTicker ? 11 : 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(Color(red: 0.045, green: 0.063, blue: 0.094).opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                    .position(label.center)
            }
        }
    }

    private func update(_ root: Entity) {
        root.orientation = rotation
        root.scale = SIMD3(repeating: min(1.5, max(0.65, zoom * Float(magnification))))
        for child in root.children where child.name.hasPrefix("label:") {
            child.orientation = rotation.inverse
        }
    }

    private func buildScene() -> Entity {
        let root = Entity(); root.name = "stock-map"
        let pe = StockMapDomain(rows.map(\.pe))
        let growth = StockMapDomain(rows.compactMap(\.epsGrowthPercent))
        let quality = StockMapDomain(rows.compactMap(\.roicPercent))
        let ink = UIColor(red: 0.76, green: 0.80, blue: 0.89, alpha: 1)
        let grid = UIColor(red: 0.16, green: 0.20, blue: 0.28, alpha: 1)
        func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>, strong: Bool = false, tint: UIColor? = nil) {
            let vector = b - a
            let entity = ModelEntity(mesh: .generateBox(size: [strong ? 0.006 : 0.0025, simd_length(vector), strong ? 0.006 : 0.0025]),
                                     materials: [UnlitMaterial(color: tint ?? (strong ? ink : grid))])
            entity.position = (a + b) / 2
            entity.orientation = simd_quatf(from: [0, 1, 0], to: simd_normalize(vector))
            root.addChild(entity)
        }
        func label(_ text: String, _ at: SIMD3<Float>, size: CGFloat = 0.073) {
            let mesh = MeshResource.generateText(text, extrusionDepth: 0.0001,
                                                font: .systemFont(ofSize: size, weight: .medium))
            let parent = Entity(); parent.name = "label:\(text)"; parent.position = at
            let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: ink)])
            entity.position.x = -entity.visualBounds(relativeTo: nil).extents.x / 2
            parent.addChild(entity); root.addChild(parent)
        }
        for i in 0...4 {
            let t = Float(i) * 0.35 - 0.7
            line([t, -0.7, -0.7], [t, -0.7, 0.7])
            line([-0.7, -0.7, t], [0.7, -0.7, t])
            line([t, -0.7, -0.7], [t, 0.7, -0.7])
            line([-0.7, t, -0.7], [0.7, t, -0.7])
            line([-0.7, t, -0.7], [-0.7, t, 0.7])
            line([-0.7, -0.7, t], [-0.7, 0.7, t])
            if i % 2 == 0 {
                label(String(format: "%.0f×", pe.ticks[i]), [t - 0.06, -0.75, 0.75])
                label(String(format: "%.0f%%", quality.ticks[i]), [-0.84, t, 0.72])
                label(String(format: "%.0f%%", growth.ticks[i]), [0.92, -0.72, -t - 0.06])
            }
        }
        line([-0.7, -0.7, 0.7], [0.7, -0.7, 0.7], strong: true, tint: UIColor(red: 0.44, green: 0.55, blue: 1, alpha: 1))
        line([-0.7, -0.7, 0.7], [-0.7, 0.7, 0.7], strong: true, tint: UIColor(red: 0.68, green: 0.55, blue: 1, alpha: 1))
        line([0.7, -0.7, 0.7], [0.7, -0.7, -0.7], strong: true, tint: UIColor(red: 0.30, green: 0.78, blue: 0.76, alpha: 1))
        label("P/E", [0, -1.0, 0.8], size: 0.083)
        label("ROIC", [-0.75, 0.87, 0.7], size: 0.083)
        label("EPS Growth", [0.96, -0.92, -0.22], size: 0.075)
        let maximumWeight = max(rows.map(\.weight).max() ?? 1, 0.0001)
        for row in rows {
            guard let eps = row.epsGrowthPercent, let roic = row.roicPercent else { continue }
            let radius = max(0.018, 0.13 * Float(cbrt(max(0, row.weight) / maximumWeight)))
            let sphere = ModelEntity(mesh: .generateSphere(radius: radius),
                                     materials: [StockMapAppearance.material(row.ticker, tickers: rows.map(\.ticker))])
            sphere.name = "stock:\(row.ticker)"
            sphere.position = [pe.coordinate(row.pe), quality.coordinate(roic), -growth.coordinate(eps)]
            sphere.components.set(InputTargetComponent())
            sphere.components.set(CollisionComponent(shapes: [.generateSphere(radius: max(radius, 0.055))]))
            root.addChild(sphere)

        }
        return root
    }
}

#if DEBUG
/// Opt-in, visibly labelled fixtures; never part of the portfolio data pipeline.
struct ValuationMapPreview: View {
    static let matrix = ValuationMatrix(rows: [
        row("ALFA", pe: 28, growth: 12, roic: 28, weight: 0.24),
        row("BETA", pe: 32, growth: 16, roic: 22, weight: 0.18),
        row("GAMMA", pe: 72, growth: 36, roic: 34, weight: 0.28),
        row("DELTA", pe: 24, growth: -18, roic: 16, weight: 0.12),
        row("EPSLN", pe: 50, growth: 24, roic: 12, weight: 0.10),
        ValuationBubble(ticker: "MISSING", displayName: "Missing metrics", sector: "Other", pe: 20,
                        growthPercent: 10, growthSource: "Revenue", weight: 0.08),
    ], warnings: [])
    private static func row(_ ticker: String, pe: Double, growth: Double, roic: Double, weight: Double) -> ValuationBubble {
        ValuationBubble(ticker: ticker, displayName: ticker, sector: "Technology", pe: pe,
                        growthPercent: growth, growthSource: "EPS", weight: weight,
                        quality: ValuationQuality(periodStart: "2025-01-01", periodEnd: "2025-12-31", filed: "2026-02-15", accession: nil,
                                                  dilutedEPS: 2 * (1 + growth / 100), priorDilutedEPS: 2,
                                                  operatingIncome: roic / 0.75, pretaxIncome: 100, incomeTax: 25,
                                                  openingCapital: 100, closingCapital: 100),
                        pePeriod: "2026-06-30", peSource: "SEC")
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.text("界面验证 · 示例数据")).font(.caption).foregroundStyle(.secondary)
                ValuationStockMap(matrix: Self.matrix,
                                  expanded: LaunchArguments.contains("--valuation-expanded"),
                                  initialMode: LaunchArguments.contains("--valuation-2d") ? 1 : 0,
                                  initialSelection: LaunchArguments.value(forFlag: "--valuation-select="))
            }.padding(20)
        }.background(Color(.systemBackground))
            .preferredColorScheme(LaunchArguments.contains("--valuation-dark") ? .dark : .light)
    }
}
#endif
