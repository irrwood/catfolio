import SwiftUI

struct WatchlistToggleButton: View {
    let holding: Holding
    let store: WatchlistStore
    var observation: SecurityMarketObservation?
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    var body: some View {
        let isSaved = store.contains(holding)
        Button {
            store.toggle(holding, observation: observation)
        } label: {
            Image(isSaved ? "WatchlistStarFilled" : "WatchlistStar")
                .renderingMode(.template)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .modifier(HoldingHeaderButtonStyle())
        .accessibilityIdentifier("holding-detail-watchlist")
        .accessibilityLabel(L10n.text(isSaved ? "移出观察列表" : "加入观察列表"))
        .accessibilityValue(L10n.text(isSaved ? "已收藏" : "未收藏"))
        .accessibilityAddTraits(isSaved ? .isSelected : [])
        .researchLayoutFrame("holding-detail.watchlist-action")
        .sensoryFeedback(.selection, trigger: isSaved) { _, _ in hapticsEnabled }
    }
}

struct WatchlistEntryCard: View {
    let store: WatchlistStore

    var body: some View {
        SettingsCard {
            SettingsNavigationRow(icon: .asset("WatchlistStar"), title: "Watchlist",
                                  subtitle: L10n.text("观察列表 · 现价与今日涨跌")) {
                WatchlistView(store: store)
            }
            .accessibilityIdentifier("performance.watchlist")
        }
    }
}

struct WatchlistView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ChinaMarketSource.preferenceKey) private var chinaSource = ChinaMarketSource.automatic.rawValue
    @AppStorage(ChinaMarketConfiguration.revisionKey) private var chinaRevision = ""
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    let store: WatchlistStore
    @State private var selectedHolding: Holding?

    private var refreshIdentity: String {
        "\(chinaSource)|\(chinaRevision)|\(scenePhase == .active)|" + store.entries.map { $0.membershipID.uuidString }.joined(separator: ",")
    }

    var body: some View {
        ScrollView {
            if store.entries.isEmpty {
                ContentUnavailableView(L10n.text("还没有观察的股票"), systemImage: "star",
                    description: Text(L10n.text("在个股页点击 AI 按钮旁的星星，即可加入观察列表。")))
                    .padding(.top, 80)
                    .accessibilityIdentifier("watchlist.empty")
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(store.entries) { entry in
                        Button { selectedHolding = entry.holding } label: {
                            WatchlistRow(entry: entry, isCached: store.failedIDs.contains(entry.id))
                        }
                        .buttonStyle(HoldingPressButtonStyle())
                        .accessibilityIdentifier("watchlist.row.\(entry.id)")
                        .contextMenu {
                            Button(L10n.text("移出观察列表"), systemImage: "star.slash", role: .destructive) {
                                store.remove(id: entry.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 24)
                if !store.failedIDs.isEmpty {
                    Text(L10n.text("部分行情未更新，下拉可重试。"))
                        .appText(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.bottom, 16)
                }
            }
        }
        .background(SecurityDetailPresentation.ground.ignoresSafeArea())
        .navigationTitle("Watchlist")
        .navigationBarTitleDisplayMode(.large)
        .softTopScrollEdge()
        .refreshable { await store.refresh(forceRefresh: true) }
        .task(id: refreshIdentity) {
            guard scenePhase == .active else { return }
            // Cached rows appear immediately; refresh only while this page is visible.
            await store.refresh(forceRefresh: true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await store.refresh(forceRefresh: true)
            }
        }
        .sheet(item: $selectedHolding) { holding in
            HoldingDetailView(holding: holding, onClose: { selectedHolding = nil })
                .environment(model)
                .securityDetailSheet()
        }
        .securityDetailOpenFeedback(trigger: selectedHolding?.ticker, enabled: hapticsEnabled)
        .accessibilityIdentifier("watchlist.page")
    }
}

/// The home list's logo, identity and two-line figures, using quote values.
struct WatchlistRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: WatchlistEntry
    var isCached = false

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    identity
                    metrics
                }
            } else {
                HStack(spacing: 10) {
                    identity
                    Spacer(minLength: 8)
                    metrics
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 0)
        .contentShape(Rectangle())
        .researchLayoutFrame("watchlist.cell.\(entry.id)")
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.text("打开个股"))
    }

    private var identity: some View {
        HStack(spacing: 10) {
            AssetLogo(ticker: entry.ticker, logoSymbol: entry.logoSymbol, size: 44, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 3) {
                SecurityDisplayName(name: entry.holding.shortName, scale: .body, weight: .semibold,
                                    singleLine: !dynamicTypeSize.isAccessibilitySize, showsClassMarkers: false)
                HStack(spacing: 5) {
                    Text(entry.ticker).appText(.footnote)
                    if isCached, entry.quote != nil {
                        Text(L10n.text("缓存")).appText(.caption)
                    }
                }
                .foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .researchLayoutFrame("watchlist.identity.\(entry.id)")
    }

    private var metrics: some View {
        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 3) {
            FinancialText(entry.quote.map { DisplayFormat.money($0.price, currency: entry.currency, fractionDigits: 2) } ?? "—")
                .appNumber(.callout, weight: .semibold)
                .foregroundStyle(CatfolioTheme.primaryText)
            if let quote = entry.quote, let amount = quote.changeAmount, let percent = quote.changePercent {
                let amountText = FinancialText(DisplayFormat.money(amount, currency: entry.currency, signed: amount != 0, fractionDigits: 2))
                    .appNumber(.footnote, weight: .medium)
                let percentText = Text(DisplayFormat.percent(percent, signed: percent != 0))
                    .appNumber(.caption, weight: .semibold, monospaced: false)
                    .padding(.horizontal, 5).frame(minHeight: 17)
                    .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { amountText; percentText }
                    VStack(alignment: .leading, spacing: 4) { amountText; percentText }
                }
                .foregroundStyle(accent)
            } else {
                Text("—").appNumber(.footnote).foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.text("暂无今日行情"))
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: false)
        .researchLayoutFrame("watchlist.metrics.\(entry.id)")
    }

    private var accent: Color {
        guard let change = entry.quote?.changeAmount, change != 0 else { return .secondary }
        return change > 0 ? CatfolioTheme.gain(for: colorScheme) : CatfolioTheme.loss(for: colorScheme)
    }
}
