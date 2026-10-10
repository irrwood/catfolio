import SwiftUI
import Charts
import CryptoKit

struct OptionsOIView: View {
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @Environment(\.locale) private var appLocale
    let symbol: String
    let currency: String?
    let price: Double?
    let costUSD: Double?
    /// The holding page's refresh count; each change forces one reread.
    var refreshRevision = 0
    var initialSnapshots: [Int: OISnapshot] = [:]
    var onSnapshot: (Int, OISnapshot) -> Void = { _, _ in }
    @State private var days = 30
    @State private var snapshot: OISnapshot?
    @State private var error: String?
    @State private var loading = false
    @State private var refreshID = 0
    @State private var handledRefreshID = 0
    @State private var snapshotKey: String?
    @State private var selectedStrike: Double?
    @State private var plotRange: OIPlotRange = .main
    @State private var showsWalls = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(symbol: String, currency: String?, price: Double?, costUSD: Double?, refreshRevision: Int = 0,
         initialSnapshots: [Int: OISnapshot] = [:], onSnapshot: @escaping (Int, OISnapshot) -> Void = { _, _ in }) {
        self.symbol = symbol
        self.currency = currency
        self.price = price
        self.costUSD = costUSD
        self.refreshRevision = refreshRevision
        self.initialSnapshots = initialSnapshots
        self.onSnapshot = onSnapshot
        _snapshot = State(initialValue: initialSnapshots[30])
        _snapshotKey = State(initialValue: "\(symbol.uppercased())|30")
    }
    private var supported: Bool { Self.supports(symbol: symbol, currency: currency) }

    /// US-listed symbols only: Yahoo's chain is read in dollars.
    static func supports(symbol: String, currency: String?) -> Bool {
        currency?.uppercased() == "USD" && symbol.range(of: "^[A-Za-z][A-Za-z0-9.-]{0,14}$", options: .regularExpression) != nil
            && !symbol.uppercased().hasSuffix(".L")
    }
    var body: some View {
        // One glass card: title and controls on the card's inset, the plot
        // across its full width, then the walls.
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, HoldingDetailCardStyle.contentInset)
                .padding(.top, 24)
                .padding([.horizontal, .top], SettingsTemplate.cardBorderWidth)
                .padding(.bottom, 8)
            plotCard
            if supported, snapshot != nil, let error {
                Text(L10n.message(error)).appText(.caption).foregroundStyle(.secondary)
                    .padding([.horizontal, .bottom], HoldingDetailCardStyle.contentInset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .holdingDetailCard()
        .transaction { $0.animation = nil }
        .onChange(of: plotRange) { _, _ in selectedStrike = nil }
        // The page's own refresh is this section's refresh: the design has no
        // button of its own, and one request per tap is still the rule.
        .onChange(of: refreshRevision) { _, _ in if supported { refreshID += 1 } }
        .appSheet(isPresented: $showsWalls) {
            if let snapshot { wallsDetail(OIDistribution(contracts: snapshot.contracts, currentPrice: price)) }
        }
        .task(id: "\(symbol)|\(days)|\(refreshID)") {
            // A tap forces ONE request. Without one, the wall still shows by
            // default: a range with no snapshot from today's New York session
            // is read once, and a same-day cache is never re-requested.
            let forced = refreshID != handledRefreshID
            handledRefreshID = refreshID
            loading = forced
            defer { if !Task.isCancelled { loading = false } }
            let key = "\(symbol.uppercased())|\(days)"
            if snapshotKey != key { snapshot = initialSnapshots[days] }
            snapshotKey = key
            error = nil; selectedStrike = nil
            #if DEBUG
            if LaunchArguments.contains("--preview-options-oi") {
                snapshot = Self.preview
                error = L10n.text("演示数据 · 仅用于布局验证")
                return
            }
            #endif
            guard supported else { return }
            let cached = await OptionsOIClient.shared.cached(symbol: symbol.uppercased(), days: days)
            guard !Task.isCancelled else { return }
            if let cached {
                snapshot = cached
                onSnapshot(days, cached)
            }
            // A snapshot cached before `listsOptions` was recorded is read
            // once more, so a symbol with no options can drop the panel.
            let current = cached?.from == OptionsOIClient.day(Date()) && cached?.listsOptions != nil
            guard forced || !current else { return }
            loading = true
            do {
                let result = try await OptionsOIClient.shared.fetch(symbol: symbol.uppercased(), days: days)
                guard !Task.isCancelled else { return }
                snapshot = result
                onSnapshot(days, result)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = cached == nil ? error.localizedDescription : L10n.text("刷新失败，以下为旧缓存。\(error.localizedDescription)")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("期权持仓墙 OI"))
                .appText(.heading, weight: .medium, trimsLeading: true)
                .foregroundStyle(CatfolioTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .securityCardInsight(title: L10n.text("期权持仓墙 OI"), facts: { insightFacts })
                .frame(maxWidth: .infinity, alignment: .leading)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    expiryPicker.fixedSize(horizontal: true, vertical: false)
                    rangeToggle.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 12) {
                    expiryPicker
                    HStack {
                        Spacer()
                        rangeToggle.fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
    }

    private var expiryPicker: some View {
        Picker(L10n.text("到期范围"), selection: $days) {
            Text("7D").tag(7).accessibilityLabel(L10n.text("7 天内"))
            Text("30D").tag(30).accessibilityLabel(L10n.text("30 天内"))
            Text("90D").tag(90).accessibilityLabel(L10n.text("90 天内"))
        }
        .pickerStyle(.segmented).labelsHidden()
        .disabled(loading || !supported)
        .sensoryFeedback(.selection, trigger: days) { _, _ in hapticsEnabled }
    }

    #if DEBUG
    static var preview: OISnapshot {
        // A real chain's shape: clusters either side of the price and long
        // thin tails, so the two zoom levels can be told apart.
        var contracts = stride(from: 5, through: 300, by: 5).flatMap { strike in
            ["call", "put"].map { side in
                let center = side == "call" ? 120.0 : 95.0
                let oi = (200 + 120000 * exp(-pow((Double(strike) - center) / 6, 2))).rounded()
                return OIContract(details: .init(ticker: "test-\(strike)-\(side)", contract_type: side,
                    expiration_date: "2026-10-02", strike_price: Double(strike), shares_per_contract: 100), open_interest: oi)
            }
        }
        // One old block far below the price, as META carried at 140 with the
        // shares at 670: heavy, but neither support nor part of the zoom.
        contracts.append(OIContract(details: .init(ticker: "test-far-put", contract_type: "put",
            expiration_date: "2026-10-02", strike_price: 25, shares_per_contract: 100), open_interest: 150_000))
        return OISnapshot(contracts: contracts, fetchedAt: Date(), from: "2026-09-08", through: "2026-10-08", excluded: 0)
    }
    #endif

    @Environment(\.colorScheme) private var colorScheme
    private func oiText(_ value: Double, observed: Bool = true) -> String {
        observed ? value.formatted(.number.precision(.fractionLength(0)).locale(appLocale)) : "—"
    }
    private func money(_ value: Double) -> String { OIPriceLabel.text(value, locale: appLocale) }

    private var hasWalls: Bool {
        supported && snapshot.map { OIDistribution(contracts: $0.contracts, currentPrice: price).concentration != nil } == true
    }

    /// What the wall shows, for a long-press explanation. Public option-chain
    /// figures only; the holding's cost is not part of it.
    private var insightFacts: String? {
        guard supported, let snapshot else { return nil }
        let distribution = OIDistribution(contracts: snapshot.contracts, currentPrice: price)
        guard distribution.concentration != nil else { return nil }
        let total = distribution.rows.reduce(0) { $0 + $1.call + $1.put }
        let calls = distribution.rows.reduce(0) { $0 + $1.call }
        var lines = [
            "Expiries within \(days) days (\(snapshot.from) – \(snapshot.through)), \(snapshot.contracts.count) contracts",
            "Total open interest: \(oiText(total)) contracts; calls \(oiText(calls)), puts \(oiText(total - calls))",
        ]
        if let wall = distribution.putWalls.first {
            lines.append("Put wall (most put OI within 20% below the price): strike \(money(wall.strike)), \(oiText(wall.put)) contracts")
        }
        if let wall = distribution.callWalls.first {
            lines.append("Call wall (most call OI within 20% above the price): strike \(money(wall.strike)), \(oiText(wall.call)) contracts")
        }
        if let range = distribution.concentration {
            lines.append("Where most OI sits (15%–85% of cumulative OI): \(money(range.lowerBound)) – \(money(range.upperBound))")
        }
        if let price, price.isFinite {
            lines.append("Latest price: \(money(price))")
        }
        return lines.joined(separator: "\n")
    }

    private var controlFill: Color {
        colorScheme == .dark ? .white.opacity(0.06) : Color(red: 248 / 255, green: 248 / 255, blue: 248 / 255)
    }

    private var rangeTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let zoomingIn = plotRange == .main
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: zoomingIn ? 0.86 : 1.16)),
            removal: .opacity.combined(with: .scale(scale: zoomingIn ? 1.16 : 0.86)))
    }

    /// One pill with two states (Figma 300:10594). It names what a tap does:
    /// ZOOM IN narrows to the main distribution, ZOOM OUT shows every strike.
    private var rangeToggle: some View {
        let zoomsIn = plotRange == .all
        return Button {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.38)) {
                plotRange = zoomsIn ? .main : .all
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: zoomsIn ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
                // Sized to the longer label, so the pill keeps its width
                // when it flips; the shorter one sits flush left, as drawn.
                ZStack(alignment: .leading) {
                    Text(verbatim: "ZOOM OUT").hidden()
                    Text(verbatim: zoomsIn ? "ZOOM IN" : "ZOOM OUT")
                }
                .appText(.footnote, weight: .semibold)
                .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(controlFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CatfolioTheme.primaryText)
        .disabled(!hasWalls)
        .sensoryFeedback(.selection, trigger: plotRange) { _, _ in hapticsEnabled }
        .accessibilityLabel(L10n.text(zoomsIn ? "主要分布" : "全部"))
        .accessibilityIdentifier("options-oi-range")
    }

    /// The plot and its axis, a hairline, then the two walls — inside the
    /// section's one glass card. The plot keeps a fixed height, so the card
    /// does not jump while the chain loads.
    private var plotCard: some View {
        let distribution = snapshot.map { OIDistribution(contracts: $0.contracts, currentPrice: price) }
        let showsWalls = supported && distribution?.concentration != nil
        return VStack(spacing: 0) {
            ZStack {
                if !supported {
                    plotMessage(L10n.text("首版仅支持美国上市的美元股票／ETF 期权。其他市场暂不支持。"))
                } else if let distribution {
                    if distribution.concentration != nil {
                        OptionsOIDistributionPlot(distribution: distribution, currentPrice: price, holdingCost: costUSD,
                                                  selectedStrike: $selectedStrike, range: plotRange)
                            .onAppear { ChartAppearanceHistory.record("options-oi|\(symbol)") }
                            // A zoom between the two ranges: zooming in, the
                            // old plot grows past the frame as the new one
                            // settles from small; zooming out, the reverse.
                            .id(plotRange)
                            .transition(rangeTransition)
                    } else {
                        plotMessage(L10n.text("所选范围没有可用的正 OI，暂无持仓墙。"))
                    }
                } else if let error, !loading {
                    VStack(spacing: 12) {
                        plotMessage(error)
                        Button(L10n.text("重试")) { refreshID += 1 }.appText(.caption, weight: .semibold)
                    }
                } else {
                    ChartShapeSkeleton(layout: .horizontalBars, appearanceID: "options-oi|\(symbol)")
                        .padding(.horizontal, 20)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 397)
            // The zoom between ranges stays inside the plot's own frame.
            .clipped()

            if showsWalls, let distribution {
                Rectangle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))
                    .frame(height: 1)
                HStack(alignment: .top) {
                    wallSummary(distribution.putWalls, call: false)
                    wallSummary(distribution.callWalls, call: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
        }
    }

    private func plotMessage(_ text: String) -> some View {
        Text(text)
            .appText(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
    }

    private func wallSummary(_ rows: [OIDistribution.Row], call: Bool) -> some View {
        let alignment: HorizontalAlignment = call ? .trailing : .leading
        return VStack(alignment: alignment, spacing: 4) {
            Text(L10n.text(call ? "Call 墙" : "Put 墙").uppercased())
                .appText(.caption, weight: .medium)
                .foregroundStyle(call ? CatfolioTheme.gain(for: colorScheme) : CatfolioTheme.loss(for: colorScheme))
            FinancialText(rows.first.map { money($0.strike) } ?? "—")
                .font(Typography.number(size: 18))
                .foregroundStyle(CatfolioTheme.primaryText)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text((rows.first.map { oiText(call ? $0.call : $0.put) } ?? "—") + " " + L10n.text("张"))
                // Tied peaks are all walls; the count opens the full list.
                if rows.count > 1 {
                    Button("×\(rows.count)") { showsWalls = true }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("查看全部并列价位"))
                }
            }
            .appNumber(.caption, weight: .medium)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
    }

    private func wallsDetail(_ distribution: OIDistribution) -> some View {
        NavigationStack {
            List {
                ForEach([false, true], id: \.self) { call in
                    Section(L10n.text(call ? "Call 墙" : "Put 墙")) {
                        ForEach(call ? distribution.callWalls : distribution.putWalls) { row in
                            HStack {
                                FinancialText(money(row.strike))
                                Spacer()
                                Text(oiText(call ? row.call : row.put))
                                Text(L10n.text("张")).foregroundStyle(.secondary)
                            }.appNumber(.body)
                        }
                    }
                }
            }.softTopScrollEdge().appPageBackground().navigationTitle(L10n.text("全部墙位"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { AppModalDoneButton { showsWalls = false } } }
        }
    }

}
