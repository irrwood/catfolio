import SwiftUI

private typealias HoldingDetailTypography = LegacyType

struct HoldingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    let holding: Holding

    @State private var profile: VolumeProfile?
    @State private var errorMessage: String?
    @State private var priceHistory: SecurityPriceHistory?
    @State private var priceHistoryError: String?
    @State private var priceSelection: SecurityPriceSelection?
    @State private var accountContext: HoldingDetailAccountContext?
    @State private var selectedAccountKeys: Set<String> = []
    @State private var presentationReady = false

    private var displayedHolding: Holding {
        accountContext?.holding(for: selectedAccountKeys) ?? holding
    }

    private var hasSelectedDetailAccounts: Bool {
        accountContext == nil || !selectedAccountKeys.isEmpty
    }

    private var pageBackground: Color {
        colorScheme == .dark ? .black : .white
    }

    private var showsInitialLoadingPlaceholder: Bool {
        if ProcessInfo.processInfo.arguments.contains("--show-security-detail-loading") {
            return true
        }
        let priceIsLoading = priceHistory == nil && priceHistoryError == nil
        let profileIsLoading = profile == nil && errorMessage == nil
        return priceIsLoading || profileIsLoading
    }

    private var showsDataDesignPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("--show-security-data")
    }

    private var showsVolumeFocusedPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--show-volume-focused")
        #else
        false
        #endif
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if showsDataDesignPreview {
                    HoldingPositionDetails(holding: displayedHolding)
                        .padding(.horizontal, 24)
                        .padding(.top, 40)
                        .padding(.bottom, 72)
                } else if showsInitialLoadingPlaceholder {
                    HoldingDetailLoadingPlaceholder()
                } else {
                    LazyVStack(spacing: 0) {
                    if !showsVolumeFocusedPreview {
                        VStack(spacing: 0) {
                            HoldingDetailHeader(
                                holding: displayedHolding,
                                marketTodayChange: profile?.todayChangePercent,
                                selectedPrice: priceSelection?.price,
                                selectedReturn: priceSelection?.returnPercent
                            )

                            if let priceHistory {
                                SecurityPriceChart(
                                    history: priceHistory,
                                    averageCost: averageCostInQuoteCurrency,
                                    selectedAccountKeys: selectedAccountKeys,
                                    onSelectionChange: { priceSelection = $0 }
                                )
                            } else if let priceHistoryError {
                                SecurityPriceChartState(
                                    title: "暂无价格走势",
                                    message: priceHistoryError,
                                    isLoading: false
                                )
                            } else if presentationReady {
                                SecurityPriceChartState(
                                    title: "正在读取价格走势",
                                    message: "正在整理历史行情与买卖记录",
                                    isLoading: true
                                )
                            } else {
                                Color.clear
                                    .frame(height: SecurityPriceChartState.fixedHeight)
                                    .accessibilityHidden(true)
                            }

                            if let accountContext, accountContext.options.count > 1 {
                                HoldingDetailAccountSelector(
                                    options: accountContext.options,
                                    selectedAccountKeys: selectedAccountKeys,
                                    onSelectAll: selectAllDetailAccounts,
                                    onToggleAccount: toggleDetailAccount
                                )
                            }
                        }
                        .padding(.top, 15)
                        .background(pageBackground)
                    }

                    LazyVStack(spacing: 64) {
                        if let profile {
                            VolumePriceChart(
                                profile: profile,
                                holding: displayedHolding,
                                showsHoldingCost: hasSelectedDetailAccounts
                            )

                            if let high = profile.fiftyTwoWeekHigh,
                               let low = profile.fiftyTwoWeekLow,
                               high > low {
                                FiftyTwoWeekRange(
                                    low: low,
                                    high: high,
                                    current: displayedHolding.quotePrice,
                                    periodStart: profile.fiftyTwoWeekStartPrice,
                                    currency: profile.currency
                                )
                            }
                        } else if let errorMessage {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Volume Profile")
                                    .font(HoldingDetailTypography.medium(19, relativeTo: .headline))
                                StatusNotice(text: errorMessage, kind: .info)
                            }
                        } else if presentationReady {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("正在读取成交量与 52 周数据…")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                        } else {
                            Color.clear
                                .frame(height: 72)
                                .accessibilityHidden(true)
                        }

                        if hasSelectedDetailAccounts {
                            HoldingPositionDetails(holding: displayedHolding)
                        }

                        AnalystConsensusView(symbol: holding.ticker, currency: holding.quoteCurrency, price: holding.quotePrice)

                        if CompanyFinancialsView.supports(holding) {
                            HoldingFinancialCard(holding: holding)
                                .padding(.horizontal, -8)
                        }

                        if PolymarketMarketsSection.supports(holding) {
                            HoldingPredictionMarketsCard(holding: holding)
                                .padding(.horizontal, -8)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, showsVolumeFocusedPreview ? 28 : 40)
                    .padding(.bottom, 72)
                    }
                }
            }
            .background(pageBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .background {
                PresentationDidAppearReader {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { presentationReady = true }
                }
            }
            .task(id: presentationReady) {
                guard presentationReady, profile == nil, errorMessage == nil else { return }
                await Task.yield()
                do {
                    let loaded = try await model.volumeProfile(for: holding.ticker)
                    guard !Task.isCancelled else { return }
                    profile = loaded
                } catch {
                    guard !Task.isCancelled else { return }
                    errorMessage = error.localizedDescription
                }
            }
            .task(id: presentationReady) {
                guard presentationReady,
                      accountContext == nil,
                      priceHistory == nil,
                      priceHistoryError == nil else { return }
                await Task.yield()
                do {
                    let context = try await model.holdingDetailAccountContext(for: holding.ticker)
                    guard !Task.isCancelled else { return }
                    let allAccountKeys = context.allAccountKeys
                    accountContext = context
                    selectedAccountKeys = allAccountKeys
                    let loaded = try await model.securityPriceHistory(
                        for: holding.ticker,
                        accountKeys: allAccountKeys
                    )
                    guard !Task.isCancelled else { return }
                    priceHistory = loaded
                } catch {
                    guard !Task.isCancelled else { return }
                    priceHistoryError = error.localizedDescription
                }
            }
        }
        .background(pageBackground.ignoresSafeArea())
        .overlay(alignment: .top) {
            HoldingDetailModalHandle()
        }
    }

    private var averageCostInQuoteCurrency: Double? {
        guard hasSelectedDetailAccounts else { return nil }
        let holding = displayedHolding
        guard holding.averageCost.isFinite, holding.averageCost > 0 else { return nil }
        let costCurrency = (holding.costCurrency ?? holding.quoteCurrency ?? "USD").uppercased()
        let quoteCurrency = (holding.quoteCurrency ?? costCurrency).uppercased()
        guard costCurrency != quoteCurrency else { return holding.averageCost }
        guard let costUSD = LocalPortfolioEngine.usdRate(for: costCurrency),
              let quoteUSD = LocalPortfolioEngine.usdRate(for: quoteCurrency),
              quoteUSD > 0 else { return nil }
        return holding.averageCost * costUSD / quoteUSD
    }

    private func selectAllDetailAccounts() {
        guard let accountContext else { return }
        selectedAccountKeys = accountContext.allAccountKeys
        priceSelection = nil
    }

    private func toggleDetailAccount(_ accountKey: String) {
        guard let accountContext else { return }
        guard accountContext.allAccountKeys.contains(accountKey) else { return }

        if selectedAccountKeys.contains(accountKey) {
            selectedAccountKeys.remove(accountKey)
        } else {
            selectedAccountKeys.insert(accountKey)
        }
        priceSelection = nil
    }
}

private struct HoldingDetailAccountSelector: View {
    @Environment(\.colorScheme) private var colorScheme

    let options: [HoldingDetailAccountOption]
    let selectedAccountKeys: Set<String>
    let onSelectAll: () -> Void
    let onToggleAccount: (String) -> Void

    private var allAccountKeys: Set<String> {
        Set(options.map(\.id))
    }

    private var allMarketValue: Double {
        options.reduce(0) { $0 + $1.marketValue }
    }

    private var displayCurrency: String {
        options.first?.currency ?? "USD"
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                accountButton(
                    id: "all",
                    title: "All",
                    marketValue: allMarketValue,
                    currency: displayCurrency,
                    isSelected: selectedAccountKeys == allAccountKeys,
                    action: onSelectAll
                )

                ForEach(options) { option in
                    accountButton(
                        id: option.id,
                        title: conciseAccountName(option.displayName),
                        marketValue: option.marketValue,
                        currency: option.currency,
                        isSelected: selectedAccountKeys.contains(option.id),
                        action: { onToggleAccount(option.id) }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.hidden)
        .frame(height: 92)
        .accessibilityElement(children: .contain)
    }

    private func accountButton(
        id: String,
        title: String,
        marketValue: Double,
        currency: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .lineLimit(1)
                Text(DisplayFormat.money(marketValue, currency: currency, fractionDigits: 0))
                    .appNumber(.caption)
                    .foregroundStyle(Color.primary.opacity(0.50))
                    .lineLimit(1)
            }
            .font(HoldingDetailTypography.medium(14, relativeTo: .subheadline))
            .textCase(.uppercase)
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 24)
            .frame(minWidth: 116, minHeight: 64, alignment: .leading)
            .modifier(AccountGlassSurface(isSelected: isSelected, colorScheme: colorScheme))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("holding-detail-account-\(id)")
        .accessibilityLabel(
            "\(title)，持仓市值 \(DisplayFormat.money(marketValue, currency: currency))"
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func conciseAccountName(_ value: String) -> String {
        guard let component = value.components(separatedBy: "·").last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !component.isEmpty else { return value }
        return component
    }

    private struct AccountGlassSurface: ViewModifier {
        let isSelected: Bool
        let colorScheme: ColorScheme

        private var tint: Color {
            if isSelected {
                return Color(red: 0, green: 0.92, blue: 1).opacity(colorScheme == .dark ? 0.25 : 0.22)
            }
            return Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.05)
        }

        @ViewBuilder
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular.tint(tint).interactive(), in: Capsule())
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(tint, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.06), lineWidth: 0.75)
                    }
            }
        }
    }
}

private struct HoldingDetailModalHandle: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            colorScheme == .dark ? Color.black : Color.white

            Capsule()
                .fill(colorScheme == .dark ? Color.white.opacity(0.24) : Color(red: 0.94, green: 0.945, blue: 0.945))
                .frame(width: 32, height: 4)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 15)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct HoldingDetailLoadingPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme

    private var skeletonColor: Color {
        colorScheme == .dark ? .white.opacity(0.09) : Color(white: 0.957)
    }

    private var skeletonSurface: Color {
        colorScheme == .dark ? .white.opacity(0.055) : Color(white: 0.976)
    }

    private var skeletonCardBackground: Color {
        colorScheme == .dark ? .white.opacity(0.025) : .white
    }

    private var accountSkeletonColor: Color {
        colorScheme == .dark ? .white.opacity(0.075) : .white.opacity(0.72)
    }

    var body: some View {
        LazyVStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(skeletonColor)
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 7) {
                        skeletonBar(width: 64, height: 14)
                        HStack(spacing: 8) {
                            skeletonBar(width: 59, height: 10)
                            skeletonBar(width: 40, height: 10)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 7) {
                        skeletonBar(width: 70, height: 14)
                        skeletonBar(width: 82, height: 10)
                    }
                }
                .frame(height: 64)
                .padding(.horizontal, 20)

                StandardLineChartSkeleton(
                    leadingLineOverflow: 30,
                    trailingEndpointInset: 9
                )
                    .frame(height: 343)

                SecurityPriceRangePickerSkeleton()
                    .frame(height: 62)

                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 7) {
                                skeletonBar(
                                    width: index == 1 ? 53 : (index == 2 ? 24 : 28),
                                    height: 11,
                                    color: accountSkeletonColor
                                )
                                skeletonBar(width: 68, height: 11, color: accountSkeletonColor)
                            }
                            .padding(.horizontal, 24)
                            .frame(minWidth: 116, minHeight: 64, alignment: .leading)
                            .background(skeletonSurface, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
                .scrollIndicators(.hidden)
                .frame(height: 92)
            }
            .padding(.top, 15)

            LazyVStack(spacing: 64) {
                volumeProfileSkeleton
                fiftyTwoWeekSkeleton
                dataSkeleton
                financialSkeleton
                predictionMarketsSkeleton
            }
            .padding(.horizontal, 20)
            .padding(.top, 40)
            .padding(.bottom, 72)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载个股详情")
    }

    private var volumeProfileSkeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    skeletonBar(width: 142, height: 15)
                    Spacer()
                    skeletonBar(width: 89, height: 12)
                }
                .frame(height: 23)

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(skeletonSurface)

                    VStack(alignment: .leading) {
                        skeletonBar(width: 66, height: 10, color: accountSkeletonColor)
                        Spacer()
                        skeletonBar(width: 56, height: 10, color: accountSkeletonColor)
                    }
                    .padding(10)
                }
                .frame(height: 303)
            }

            VStack(alignment: .leading, spacing: 6) {
                Capsule()
                    .fill(skeletonColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
                Capsule()
                    .fill(skeletonColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 12)
            }
            .frame(height: 48, alignment: .center)
        }
        .frame(height: 410, alignment: .top)
    }

    private var fiftyTwoWeekSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                skeletonBar(width: 355, height: 15)
            }
            .frame(height: 23, alignment: .center)

            HStack(alignment: .center, spacing: 3.1) {
                ForEach(0..<51, id: \.self) { index in
                    Capsule()
                        .fill(skeletonColor)
                        .frame(width: index == 25 ? 7 : 4, height: index == 25 ? 110 : 98)
                }
            }
            .frame(height: 110)
            .padding(.top, 20)

            HStack {
                skeletonBar(width: 82, height: 11)
                Spacer()
                skeletonBar(width: 90, height: 11)
            }
            .frame(height: 16)
            .padding(.top, 7)
        }
        .frame(height: 176, alignment: .top)
    }

    private var dataSkeleton: some View {
        let rows: [(HoldingDataIcon, CGFloat, CGFloat)] = [
            (.value, 45, 40),
            (.returnValue, 56, 30),
            (.cost, 36, 30),
            (.fxImpact, 72, 49),
            (.proportion, 93, 46),
            (.unrealisedProfitLoss, 117, 143),
        ]

        return VStack(alignment: .leading, spacing: 0) {
            skeletonBar(width: 46, height: 15)
                .frame(height: 23, alignment: .center)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    dataSkeletonRow(
                        icon: row.0,
                        labelWidth: row.1,
                        valueWidth: row.2,
                        isCombinedValue: index == rows.count - 1,
                        isAlternating: index.isMultiple(of: 2) == false
                    )
                }
            }
            .padding(.top, 20)
        }
        .frame(height: 307, alignment: .top)
    }

    private var financialSkeleton: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                skeletonBar(width: 79, height: 14)
                VStack(alignment: .leading, spacing: 6) {
                    skeletonBar(width: 237, height: 10)
                    skeletonBar(width: 184, height: 10)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(skeletonColor)
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 105, maxHeight: 105, alignment: .leading)
        .background(skeletonCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(skeletonColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var predictionMarketsSkeleton: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                skeletonBar(width: 166, height: 14)
                Spacer(minLength: 8)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(skeletonColor)
                    .frame(width: 24, height: 24)
            }
            .frame(height: 24)

            VStack(spacing: 20) {
                ForEach(0..<5, id: \.self) { index in
                    predictionMarketRowSkeleton(index: index)
                }
            }
            .padding(.top, 32)

            Rectangle()
                .fill(skeletonColor)
                .frame(height: 1)
                .padding(.top, 16)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(skeletonColor)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    skeletonBar(width: 291, height: 9)
                    skeletonBar(width: 291, height: 9)
                    skeletonBar(width: 226, height: 9)
                }
            }
            .padding(.top, 15)
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, minHeight: 563, maxHeight: 563, alignment: .topLeading)
        .background(skeletonCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(skeletonColor, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func dataSkeletonRow(
        icon: HoldingDataIcon,
        labelWidth: CGFloat,
        valueWidth: CGFloat,
        isCombinedValue: Bool,
        isAlternating: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Group {
                if let assetName = icon.assetName {
                    Image(assetName)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                } else {
                    Image(systemName: icon.systemName)
                        .font(.system(size: icon.pointSize, weight: .regular))
                }
            }
            .foregroundStyle(skeletonColor)
            .frame(width: 24, height: 24)

            skeletonBar(width: labelWidth, height: 10)

            Spacer(minLength: 8)

            if isCombinedValue {
                HStack(spacing: 8) {
                    skeletonBar(width: 81, height: 10)
                    Circle()
                        .fill(skeletonColor)
                        .frame(width: 4, height: 4)
                    skeletonBar(width: 42, height: 10)
                }
            } else {
                skeletonBar(width: valueWidth, height: 10)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 44)
        .background(
            isAlternating ? skeletonSurface : .clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func predictionMarketRowSkeleton(index: Int) -> some View {
        let statWidths: [CGFloat] = [47, 53, 47, 47, 47]

        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    skeletonBar(width: 260, height: 10)
                    skeletonBar(width: 260, height: 10)
                }
                .frame(height: 36, alignment: .top)

                HStack(spacing: 8) {
                    skeletonBar(width: 63, height: 9)
                    Circle()
                        .fill(skeletonColor)
                        .frame(width: 4, height: 4)
                    skeletonBar(width: 70, height: 9)
                }
                .frame(height: 16)
            }
            .frame(width: 260, alignment: .leading)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                skeletonBar(width: statWidths[index], height: 10)
                skeletonBar(width: index == 1 ? 19 : 23, height: 9)
            }
            .frame(height: 38, alignment: .topTrailing)
        }
        .frame(height: 60, alignment: .top)
    }

    private func skeletonBar(width: CGFloat, height: CGFloat, color: Color? = nil) -> some View {
        Capsule()
            .fill(color ?? skeletonColor)
            .frame(width: width, height: height)
    }
}

private struct SecurityPriceChartState: View {
    static let fixedHeight: CGFloat = 405

    let title: String
    let message: String
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                VStack(spacing: 0) {
                    StandardLineChartSkeleton(
                        leadingLineOverflow: 30,
                        trailingEndpointInset: 9
                    )
                        .frame(height: 343)

                    SecurityPriceRangePickerSkeleton()
                        .frame(height: 62)
                }
            } else {
                VStack(spacing: 0) {
                    StandardLineChartPlaceholder(
                        title: title,
                        message: message,
                        isLoading: false,
                        maximumLines: 2
                    )
                    .frame(height: 343)

                    Color.clear
                        .frame(height: 62)
                }
            }
        }
        .frame(height: Self.fixedHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("价格走势，\(title)，\(message)")
    }
}

private struct SecurityPriceRangePickerSkeleton: View {
    @Environment(\.colorScheme) private var colorScheme

    private let widths: [CGFloat] = [12, 15, 14, 17, 20, 12, 23]

    private var skeletonColor: Color {
        colorScheme == .dark ? .white.opacity(0.09) : Color(white: 0.957)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                ZStack {
                    if index == 3 {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(skeletonColor)
                            .frame(width: 44, height: 30)
                    }

                    Capsule()
                        .fill(index == 3
                            ? (colorScheme == .dark ? Color.black.opacity(0.55) : .white)
                            : skeletonColor)
                        .frame(width: width, height: 11)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SecurityPriceSelection: Equatable {
    let price: Double
    let returnPercent: Double
}

private struct SecurityPriceChart: View {
    private static let choices = ["1D", "1W", "1M", "3M", "YTD", "1Y", "MAX"]

    let history: SecurityPriceHistory
    let selectedAccountKeys: Set<String>
    let onSelectionChange: (SecurityPriceSelection?) -> Void
    private let prepared: [String: SecurityPriceRangeData]
    @State private var range: String
    @State private var selectedDate: Date?
    @State private var measuredRange: ChartDateRange?

    init(
        history: SecurityPriceHistory,
        averageCost: Double?,
        selectedAccountKeys: Set<String>,
        onSelectionChange: @escaping (SecurityPriceSelection?) -> Void = { _ in }
    ) {
        self.history = history
        self.selectedAccountKeys = selectedAccountKeys
        self.onSelectionChange = onSelectionChange
        prepared = Dictionary(uniqueKeysWithValues: Self.choices.map {
            ($0, SecurityPriceRangeData(
                history: history,
                range: $0,
                averageCost: averageCost,
                selectedAccountKeys: selectedAccountKeys
            ))
        })
        let arguments = ProcessInfo.processInfo.arguments
        _range = State(initialValue: arguments.contains("--show-security-chart-1d")
            ? "1D"
            : arguments.contains("--show-security-chart-max") ? "MAX" : "1Y")
    }

    private var data: SecurityPriceRangeData {
        prepared[range] ?? prepared["MAX"]!
    }

    private var selectedPoint: SecurityPricePlotPoint? {
        guard let selectedDate else { return data.points.last }
        return data.nearest(to: selectedDate)
    }

    private var selectionIndicatorLabel: String? {
        if let measuredRange {
            return "\(dateLabel(measuredRange.start)) – \(dateLabel(measuredRange.end))"
        }
        guard selectedDate != nil, let selectedPoint else { return nil }
        return dateLabel(selectedPoint.date)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if data.points.count > 1 {
                    SecurityPricePlot(
                        data: data,
                        currency: history.currency,
                        transitionKey: "\(range)|\(selectionSignature)",
                        selectedPoint: selectedDate == nil && measuredRange == nil ? nil : selectedPoint,
                        measuredRange: measuredRange,
                        selectionIndicatorLabel: selectionIndicatorLabel,
                        onSelect: { date in
                            guard measuredRange != nil || selectedDate != date else { return }
                            measuredRange = nil
                            selectedDate = date
                            onSelectionChange(selection(at: date))
                        },
                        onMeasure: { measuredRange in
                            guard self.measuredRange != measuredRange else { return }
                            self.measuredRange = measuredRange
                            selectedDate = measuredRange.end
                            onSelectionChange(selection(for: measuredRange))
                        },
                        onInteractionEnded: { _ in clearInteraction() }
                    )
                } else {
                    StandardLineChartPlaceholder(
                        title: "暂无日内行情",
                        message: "Massive 与 Yahoo 暂未返回分钟级数据",
                        isLoading: false,
                        maximumLines: 2
                    )
                }
            }
            .frame(height: 343)
            .accessibilityLabel("\(history.ticker) 价格走势，买入点为绿色圆环，卖出点为黄色圆环，横向玻璃线为持仓成本")

            SecurityPriceRangePicker(
                choices: Self.choices,
                selection: $range
            )
            .frame(height: 62)
            .accessibilityLabel("价格走势时间范围")
        }
        .frame(height: SecurityPriceChartState.fixedHeight, alignment: .top)
        .onChange(of: range) { _, _ in clearInteraction() }
        .onChange(of: selectedAccountKeys) { _, _ in clearInteraction() }
        .onDisappear { onSelectionChange(nil) }
        .task(id: "\(range)|\(selectionSignature)") {
            // Publish the selected time window even when the user is not
            // touching the chart. The header then uses the same start/end
            // basis as the line currently on screen.
            await Task.yield()
            guard !Task.isCancelled, selectedDate == nil, measuredRange == nil else { return }
            onSelectionChange(rangeSelection)
        }
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--show-security-chart-1d") { range = "1D" }
            if arguments.contains("--show-security-chart-max") { range = "MAX" }
        }
    }

    private var selectionSignature: String {
        selectedAccountKeys.sorted().joined(separator: "|")
    }

    private func dateLabel(_ date: Date) -> String {
        data.isIntraday
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private func selection(at date: Date) -> SecurityPriceSelection? {
        guard let point = data.nearest(to: date) else { return nil }
        return SecurityPriceSelection(price: point.price, returnPercent: point.returnPercent)
    }

    private var rangeSelection: SecurityPriceSelection? {
        guard let latest = data.points.last else { return nil }
        return SecurityPriceSelection(
            price: latest.price,
            returnPercent: latest.returnPercent
        )
    }

    private func selection(for range: ChartDateRange) -> SecurityPriceSelection? {
        guard let start = data.nearest(to: range.start),
              let end = data.nearest(to: range.end),
              start.price > 0 else { return nil }
        return SecurityPriceSelection(
            price: end.price,
            returnPercent: (end.price / start.price - 1) * 100
        )
    }

    private func clearInteraction() {
        selectedDate = nil
        measuredRange = nil
        onSelectionChange(rangeSelection)
    }
}

private struct SecurityPriceRangePicker: View {
    @Environment(\.colorScheme) private var colorScheme

    let choices: [String]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices, id: \.self) { choice in
                Button {
                    selection = choice
                } label: {
                    Text(choice)
                        .appText(.footnote, weight: .medium)
                        .foregroundStyle(foreground(for: choice))
                        .frame(width: 44, height: 30)
                        .background {
                            if selection == choice {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selectedBackground)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var selectedBackground: Color {
        colorScheme == .dark ? .white : .black.opacity(0.06)
    }

    private func foreground(for choice: String) -> Color {
        if selection == choice {
            return colorScheme == .dark ? .black : .primary
        }
        return .primary.opacity(0.40)
    }
}

private struct SecurityPriceCostLegend: View {
    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(CatfolioStyle.green)
                        .frame(width: 4, height: 2)
                }
            }
            Text("成本")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("绿色虚线为持仓成本")
    }
}

private struct SecurityPricePlot: View {
    @Environment(\.colorScheme) private var colorScheme

    let data: SecurityPriceRangeData
    let currency: String
    let transitionKey: String
    let selectedPoint: SecurityPricePlotPoint?
    let measuredRange: ChartDateRange?
    let selectionIndicatorLabel: String?
    let onSelect: (Date) -> Void
    let onMeasure: (ChartDateRange) -> Void
    let onInteractionEnded: (Int) -> Void

    var body: some View {
        let priceSeries = StandardLineChartSeries(
            id: "price",
            points: data.sampledPoints.map {
                StandardLineChartPoint(id: $0.id, date: $0.date, value: $0.price)
            },
            color: CatfolioPalette.securityPriceLine,
            lineWidth: 3,
            selectionRadius: 4,
            latestPointRadius: 5,
            latestPointColor: colorScheme == .dark ? .white : Color(red: 10 / 255, green: 11 / 255, blue: 12 / 255),
            latestPointUsesGlass: false
        )
        let costReference = data.averageCost.map {
            StandardLineChartReferenceLine(
                id: "cost",
                value: $0,
                color: CatfolioPalette.tradeBuy,
                label: axisPriceLabel($0),
                lineWidth: 2,
                minimumAxisLabelSpacing: 20
            )
        }
        StandardLineChart(
            series: [priceSeries],
            interactionDates: data.points.map(\.date),
            domain: data.domain,
            yTicks: (0..<4).map { index in
                let fraction = Double(index) / 3
                return data.domain.upperBound
                    - (data.domain.upperBound - data.domain.lowerBound) * fraction
            },
            axisWidth: 49,
            topInset: 34,
            bottomHeight: 0,
            leadingLineOverflow: 30,
            gridOpacity: 0.08,
            transitionKey: transitionKey,
            markers: data.trades.map { trade in
                StandardLineChartMarker(
                    id: trade.id,
                    point: StandardLineChartPoint(
                        id: trade.id,
                        date: trade.point.date,
                        value: trade.point.price
                    ),
                    color: trade.trade.isBuy
                        ? CatfolioPalette.tradeBuy
                        : (colorScheme == .dark
                            ? CatfolioPalette.tradeSellDark
                            : CatfolioPalette.tradeSellLight),
                    radius: 4,
                    outlineColor: nil,
                    outlineWidth: 2,
                    style: .ring
                )
            },
            referenceLines: [costReference].compactMap { $0 },
            selectedDate: selectedPoint?.date,
            measuredRange: measuredRange,
            selectionIndicatorLabel: selectionIndicatorLabel,
            selectionSeriesIDs: ["price"],
            rangeSeriesIDs: ["price"],
            rangePrimarySeriesID: "price",
            dimsFutureDuringSelection: true,
            yAxisFont: Typography.number(.footnote),
            yAxisColor: Color.primary.opacity(0.20),
            referenceAxisFont: Typography.number(.footnote, weight: .semibold),
            yAxisLabel: axisPriceLabel,
            xAxisLabel: { _ in "" },
            onSelect: onSelect,
            onMeasure: onMeasure,
            onInteractionEnded: onInteractionEnded
        )
    }

    private func axisPriceLabel(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    private func shortDate(_ date: Date) -> String {
        if data.isIntraday {
            return date.formatted(.dateTime.hour().minute())
        }
        if data.isMaximumRange {
            return date.formatted(.dateTime.year())
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct SecurityPriceRangeData {
    struct TradePoint: Identifiable {
        let trade: SecurityTrade
        let point: SecurityPricePlotPoint
        var id: String { trade.id }
    }

    let points: [SecurityPricePlotPoint]
    let sampledPoints: [SecurityPricePlotPoint]
    let trades: [TradePoint]
    let domain: ClosedRange<Double>
    let averageCost: Double?
    let isIntraday: Bool
    let isMaximumRange: Bool

    init(
        history: SecurityPriceHistory,
        range: String,
        averageCost: Double?,
        selectedAccountKeys: Set<String>
    ) {
        let usesIntraday = range == "1D"
        isIntraday = usesIntraday
        isMaximumRange = range == "MAX"
        let source = usesIntraday ? history.intradayPoints : history.points
        let all = source.map {
            SecurityPricePlotPoint(dateText: $0.dateText, date: $0.date, price: $0.close, returnPercent: 0)
        }.sorted { $0.date < $1.date }
        let filtered = Self.filtered(all, range: range)
        let rangeBase: Double? = {
            guard usesIntraday, let sessionStart = filtered.first?.date else {
                return filtered.first?.price
            }
            let sessionDay = DayDateCodec.string(from: sessionStart)
            return history.points
                .filter { $0.dateText < sessionDay }
                .max(by: { $0.dateText < $1.dateText })?
                .close ?? filtered.first?.price
        }()
        guard let base = rangeBase, base > 0 else {
            points = []
            sampledPoints = []
            trades = []
            domain = -1...1
            self.averageCost = nil
            return
        }
        let normalizedPoints = filtered.map {
            SecurityPricePlotPoint(
                dateText: $0.dateText,
                date: $0.date,
                price: $0.price,
                returnPercent: ($0.price / base - 1) * 100
            )
        }
        let step = max(1, Int(ceil(Double(normalizedPoints.count) / 150)))
        var sampled = Array(stride(from: 0, to: normalizedPoints.count, by: step)).map { normalizedPoints[$0] }
        if sampled.last?.id != normalizedPoints.last?.id, let last = normalizedPoints.last { sampled.append(last) }

        let visibleStart = normalizedPoints.first?.date ?? .distantFuture
        let visibleEnd = normalizedPoints.last?.date ?? .distantPast
        let visibleTrades: [TradePoint] = usesIntraday ? [] : history.trades.compactMap { trade -> TradePoint? in
            guard !trade.accountKeys.isDisjoint(with: selectedAccountKeys) else { return nil }
            guard trade.date >= visibleStart, trade.date <= visibleEnd,
                  let point = Self.nearestPoint(to: trade.date, in: normalizedPoints) else { return nil }
            return TradePoint(trade: trade, point: point)
        }

        let visibleCost = averageCost.flatMap { cost -> Double? in
            guard cost.isFinite, cost > 0 else { return nil }
            return cost
        }
        let values = normalizedPoints.map(\.price) + [visibleCost].compactMap { $0 }
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let minimumSpan = max(abs(maximum) * 0.02, 0.01)
        let span = max(maximum - minimum, minimumSpan)
        let padding = span * 0.12
        points = normalizedPoints
        sampledPoints = sampled
        trades = visibleTrades
        domain = (minimum - padding)...(maximum + padding)
        self.averageCost = visibleCost
    }

    func nearest(to date: Date) -> SecurityPricePlotPoint? {
        Self.nearestPoint(to: date, in: points)
    }

    private static func filtered(
        _ points: [SecurityPricePlotPoint],
        range: String
    ) -> [SecurityPricePlotPoint] {
        guard let last = points.last?.date else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start: Date?
        switch range {
        case "1W": start = calendar.date(byAdding: .day, value: -7, to: last)
        case "1M": start = calendar.date(byAdding: .month, value: -1, to: last)
        case "3M": start = calendar.date(byAdding: .month, value: -3, to: last)
        case "YTD": start = calendar.date(from: DateComponents(year: calendar.component(.year, from: last), month: 1, day: 1))
        case "1Y": start = calendar.date(byAdding: .year, value: -1, to: last)
        default: start = nil
        }
        guard let start else { return points }
        let result = points.filter { $0.date >= start }
        return result.count > 1 ? result : Array(points.suffix(2))
    }

    private static func nearestPoint(
        to date: Date,
        in points: [SecurityPricePlotPoint]
    ) -> SecurityPricePlotPoint? {
        guard !points.isEmpty else { return nil }
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].date < date { lower = middle + 1 } else { upper = middle }
        }
        guard lower > 0 else { return points[0] }
        guard lower < points.count else { return points[points.count - 1] }
        let before = points[lower - 1]
        let after = points[lower]
        return abs(before.date.timeIntervalSince(date)) <= abs(after.date.timeIntervalSince(date)) ? before : after
    }
}

private struct SecurityPricePlotPoint: Identifiable {
    let dateText: String
    let date: Date
    let price: Double
    let returnPercent: Double

    var id: String { dateText }
}

private struct HoldingDetailHeader: View {
    let holding: Holding
    let marketTodayChange: Double?
    let selectedPrice: Double?
    let selectedReturn: Double?

    private var todayChange: Double? {
        selectedReturn ?? holding.todayChangePercent ?? marketTodayChange
    }

    private var displayedPrice: Double {
        selectedPrice ?? holding.quotePrice
    }

    private var displayName: String {
        guard let original = holding.displayName.components(separatedBy: " / ").first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !original.isEmpty else { return holding.ticker }
        return original
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AssetLogo(ticker: holding.ticker, logoSymbol: holding.logoSymbol, size: 40)

            VStack(alignment: .leading, spacing: 5) {
                Text(displayName)
                    .appText(.subheading, weight: .semibold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)

                HStack(spacing: 8) {
                    Text(DisplayFormat.shares(holding.shares))
                        .appNumber(.label, monospaced: false)
                    Text(holding.ticker.uppercased())
                        .appCaps(.label)
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Text(DisplayFormat.money(displayedPrice, currency: holding.quoteCurrency ?? "USD"))
                    .appNumber(.subheading, weight: .semibold)
                    .numericTransition(displayedPrice)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
                if let todayChangePercent = todayChange {
                    Text(DisplayFormat.percent(todayChangePercent))
                        .appNumber(.label)
                        .foregroundStyle(
                            todayChangePercent >= 0
                                ? Color(red: 1 / 255, green: 184 / 255, blue: 1 / 255)
                                : Color(red: 227 / 255, green: 0, blue: 69 / 255)
                        )
                } else {
                    Text("Return —")
                        .font(HoldingDetailTypography.medium(13, relativeTo: .caption))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 146, alignment: .trailing)
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 64)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HoldingPositionDetails: View {
    let holding: Holding

    private var costBasis: Double {
        holding.marketValue - holding.unrealized
    }

    private var profitColor: Color {
        holding.unrealized >= 0
            ? Color(red: 1 / 255, green: 184 / 255, blue: 1 / 255)
            : Color(red: 227 / 255, green: 0, blue: 69 / 255)
    }

    /// The fund's own annual charge, and what that costs on this position.
    ///
    /// A percentage alone is unreadable at this scale — 0.03% and 0.30% look
    /// alike — so the money it comes to at the current value is shown beside
    /// it. It is a run rate at today's price, not a fee already paid, and not
    /// a figure to subtract from a return that already has it deducted.
    private var expenseRatioRow: HoldingDataRow.Model? {
        guard let catalog = try? ETFReferenceCatalog.bundled.get(),
              let fee = catalog.expenseRatio(brokerSymbol: holding.ticker) else { return nil }
        let percent = fee.rate * 100
        let rate = percent.formatted(.number.precision(.fractionLength(2...4)))
        let annual = DisplayFormat.money(holding.marketValue * fee.rate, fractionDigits: 2)
        return .init(
            title: "Expense Ratio",
            icon: .expenseRatio,
            value: "\(rate)%  ·  \(annual)/yr"
        )
    }

    private var rows: [HoldingDataRow.Model] {
        [
            .init(
                title: "Value",
                icon: .value,
                value: DisplayFormat.money(holding.marketValue),
                color: Color(red: 1 / 255, green: 184 / 255, blue: 1 / 255)
            ),
            .init(
                title: "Return",
                icon: .returnValue,
                value: DisplayFormat.percent(holding.unrealizedPercent)
            ),
            .init(
                title: "Shares",
                icon: .shares,
                value: DisplayFormat.shares(holding.shares)
            ),
            .init(
                title: "Cost",
                icon: .cost,
                value: DisplayFormat.money(costBasis)
            ),
            .init(
                title: "Average Cost",
                icon: .averageCost,
                value: DisplayFormat.money(
                    holding.averageCost,
                    currency: holding.costCurrency ?? "USD"
                )
            ),
            .init(
                title: fxTitle,
                icon: .fxImpact,
                value: fxValue,
                color: fxColor
            ),
            .init(
                title: "Proportion",
                icon: .proportion,
                value: DisplayFormat.percent(holding.weight * 100, signed: false)
            ),
            .init(
                title: "Unrealised P&L",
                icon: .unrealisedProfitLoss,
                value: "\(DisplayFormat.money(holding.unrealized, signed: true))  ·  \(DisplayFormat.percent(holding.unrealizedPercent))",
                color: profitColor
            ),
        ] + [expenseRatioRow].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Data")
                .font(HoldingDetailTypography.medium(19, relativeTo: .headline))

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HoldingDataRow(model: row, isAlternating: index.isMultiple(of: 2) == false)
                }
            }
        }
    }

    private var fxTitle: String {
        let suffix: String
        switch holding.fxPnlStatus {
        case "estimated": suffix = " · EST."
        case "reconstructed": suffix = " · CALC."
        case "broker_reported": suffix = " · REPORTED"
        case "unavailable": suffix = " · UNAVAILABLE"
        case "mixed": suffix = " · MIXED"
        default: suffix = ""
        }
        return "FX Impact\(suffix)"
    }

    private var fxValue: String {
        guard let value = holding.fxPnl else {
            return holding.fxPnlStatus == "unavailable" ? "Missing data" : "—"
        }
        let amount = DisplayFormat.money(value, signed: true)
        guard let percent = holding.fxPnlPercent else { return amount }
        return "\(amount)  ·  \(DisplayFormat.percent(percent))"
    }

    private var fxColor: Color {
        guard let value = holding.fxPnl else { return .secondary }
        if value > 0 { return Color(red: 1 / 255, green: 184 / 255, blue: 1 / 255) }
        if value < 0 { return Color(red: 227 / 255, green: 0, blue: 69 / 255) }
        return .secondary
    }
}

private enum HoldingDataIcon {
    case value
    case returnValue
    case shares
    case cost
    case averageCost
    case fxImpact
    case proportion
    case unrealisedProfitLoss
    case expenseRatio

    /// Exact vector exports from the latest Figma icon source node 139:2920,
    /// as used by the Data section at node 115:5140. Rows that are not
    /// present in that frame keep their closest SF Symbol until the design
    /// supplies a dedicated glyph.
    var assetName: String? {
        switch self {
        case .value: "HoldingDataValue"
        case .returnValue: "HoldingDataReturn"
        case .cost: "HoldingDataCost"
        case .fxImpact: "HoldingDataFXImpact"
        case .proportion: "HoldingDataProportion"
        case .unrealisedProfitLoss: "HoldingDataUnrealisedPnL"
        case .shares, .averageCost, .expenseRatio: nil
        }
    }

    var systemName: String {
        switch self {
        case .value: "dollarsign"
        case .returnValue: "arrow.up.right"
        case .shares: "number"
        case .cost: "creditcard"
        case .averageCost: "divide.square"
        case .fxImpact: "arrow.left.arrow.right"
        case .proportion: "chart.pie"
        case .unrealisedProfitLoss: "chart.line.uptrend.xyaxis"
        case .expenseRatio: "percent"
        }
    }

    var pointSize: CGFloat {
        switch self {
        case .value: 22
        case .returnValue: 20
        case .shares: 21
        case .cost, .averageCost: 19
        case .fxImpact, .proportion, .unrealisedProfitLoss: 20
        case .expenseRatio: 19
        }
    }
}

private struct HoldingDataRow: View {
    struct Model {
        let title: String
        let icon: HoldingDataIcon
        let value: String
        var color: Color = .primary
    }

    @Environment(\.colorScheme) private var colorScheme

    let model: Model
    let isAlternating: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let assetName = model.icon.assetName {
                    Image(assetName)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                } else {
                    Image(systemName: model.icon.systemName)
                        .font(.system(size: model.icon.pointSize, weight: .regular))
                        .symbolRenderingMode(.monochrome)
                }
            }
            .foregroundStyle(.primary.opacity(0.50))
            .frame(width: 24, height: 24)
            .accessibilityHidden(true)

            Text(model.title.uppercased())
                .appCaps(.label)
                .foregroundStyle(.primary.opacity(0.50))
                .lineLimit(1)
                .minimumScaleFactor(0.74)

            Spacer(minLength: 8)

            Text(model.value)
                .appNumber(.label, weight: .semibold)
                .foregroundStyle(model.color)
                .lineLimit(1)
                .minimumScaleFactor(0.66)
                .layoutPriority(1)
        }
        .padding(.horizontal, 15)
        .frame(height: 44)
        .background(alternatingBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var alternatingBackground: Color {
        guard isAlternating else { return .clear }
        return colorScheme == .dark
            ? .white.opacity(0.06)
            : Color(red: 248 / 255, green: 248 / 255, blue: 248 / 255)
    }
}

private struct HoldingMetric: View {
    let title: String
    let value: String
    var detail: String? = nil
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .appNumber(.subheading, weight: .bold)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            if let detail {
                Text(detail)
                    .appNumber(.caption, weight: .semibold)
                    .foregroundStyle(color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HoldingFinancialCard: View {
    let holding: Holding

    var body: some View {
        NavigationLink {
            CompanyFinancialsView(holding: holding)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Financial")
                        .font(HoldingDetailTypography.medium(17, relativeTo: .headline))
                        .foregroundStyle(.primary)

                    Text("Profit and Loss Statement, Balance Sheet and Cash Flow")
                        .font(HoldingDetailTypography.medium(13, relativeTo: .subheadline))
                        .foregroundStyle(.primary.opacity(0.50))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 237, alignment: .leading)
                .layoutPriority(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, height: 24)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .holdingDetailGlassCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Open reported company financials")
    }
}

private struct HoldingPredictionMarketsCard: View {
    let holding: Holding

    @Environment(\.openURL) private var openURL
    @State private var markets: [PolymarketRelatedMarket] = []
    @State private var errorMessage: String?
    @State private var isLoading = true

    private var taskID: String {
        "\(holding.ticker)|\(holding.displayName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Predicting markets")
                    .font(HoldingDetailTypography.medium(17, relativeTo: .headline))

                Spacer(minLength: 8)

                Button {
                    Task { await load(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(isLoading)
                .accessibilityLabel("Refresh predicting markets")
            }

            Group {
                if isLoading {
                    predictionLoadingRows
                } else if markets.isEmpty {
                    predictionEmptyState
                } else {
                    predictionRows
                }
            }
            .padding(.top, 16)

            Divider()
                .padding(.top, 20)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 24, height: 24)

                Text("Prediction-market probabilities are based on trading prices and are not facts or investment advice.")
                    .font(HoldingDetailTypography.regular(11.5, relativeTo: .caption))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.primary.opacity(0.18))
            .padding(.top, 16)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
        .holdingDetailGlassCard()
        .task(id: taskID) {
            await load(forceRefresh: false)
        }
    }

    private var predictionRows: some View {
        VStack(spacing: 20) {
            ForEach(markets.prefix(5)) { market in
                Button {
                    if let url = market.webURL { openURL(url) }
                } label: {
                    HoldingPredictionMarketRow(market: market)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var predictionLoadingRows: some View {
        VStack(spacing: 20) {
            ForEach(0..<3, id: \.self) { index in
                HoldingPredictionMarketRow(
                    market: PolymarketRelatedMarket(
                        id: "holding-detail-placeholder-\(index)",
                        question: "Loading the most active related prediction market",
                        eventTitle: "Polymarket",
                        eventSlug: "",
                        outcome: "Yes",
                        probability: 0.62,
                        volume24Hours: 12_500,
                        totalVolume: 220_000,
                        endDate: nil
                    )
                )
                .redacted(reason: .placeholder)
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Loading prediction markets")
    }

    private var predictionEmptyState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: errorMessage == nil ? "scope" : "wifi.exclamationmark")
                .foregroundStyle(.secondary)
            Text(errorMessage ?? "No active prediction market was found for \(holding.ticker).")
                .font(HoldingDetailTypography.regular(13, relativeTo: .subheadline))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 60, alignment: .top)
    }

    @MainActor
    private func load(forceRefresh: Bool) async {
        isLoading = true
        errorMessage = nil
        do {
            let companyName = holding.displayName.components(separatedBy: " / ").first
                ?? holding.displayName
            let loaded = try await PolymarketClient.shared.relatedMarkets(
                ticker: holding.ticker,
                companyName: companyName,
                forceRefresh: forceRefresh
            )
            guard !Task.isCancelled else { return }
            markets = loaded
        } catch {
            guard !Task.isCancelled else { return }
            markets = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct HoldingPredictionMarketRow: View {
    let market: PolymarketRelatedMarket

    private var isNegativeOutcome: Bool {
        let outcome = market.outcome.lowercased()
        return outcome == "no" || outcome == "down"
    }

    private var outcomeColor: Color {
        isNegativeOutcome
            ? Color(red: 227 / 255, green: 55 / 255, blue: 245 / 255)
            : Color(red: 51 / 255, green: 88 / 255, blue: 255 / 255)
    }

    private var probabilityText: String {
        market.probability.formatted(.percent.precision(.fractionLength(0...1)))
    }

    private var activityText: String {
        let amount = market.volume24Hours > 0 ? market.volume24Hours : market.totalVolume
        let prefix = market.volume24Hours > 0 ? "24h" : "Total"
        return "\(prefix) $\(amount.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(market.question)
                    .font(HoldingDetailTypography.medium(13, relativeTo: .subheadline))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 6) {
                    Text(activityText)
                    if let endDate = market.endDate {
                        Text("·")
                        Text("Until \(endDate.formatted(.dateTime.day().month(.abbreviated)))")
                    }
                }
                .font(HoldingDetailTypography.regular(13, relativeTo: .caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: 275, alignment: .leading)
            .layoutPriority(1)

            VStack(alignment: .trailing, spacing: 3) {
                Text(probabilityText)
                    .appNumber(.body)
                    .foregroundStyle(outcomeColor)
                Text(market.outcome)
                    .font(HoldingDetailTypography.regular(13, relativeTo: .caption))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 44, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(market.question), \(market.outcome) \(probabilityText), \(activityText)")
        .accessibilityHint("Open on Polymarket")
    }
}

private struct HoldingDetailGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
    }

    private var fallbackTint: Color {
        colorScheme == .dark
            ? Color(red: 22 / 255, green: 25 / 255, blue: 28 / 255).opacity(0.88)
            : .white.opacity(0.78)
    }

    private var nativeGlassTint: Color {
        colorScheme == .dark
            ? Color(red: 22 / 255, green: 25 / 255, blue: 28 / 255).opacity(0.72)
            : .white.opacity(0.08)
    }

    private var borderColor: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.08)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.tint(nativeGlassTint), in: shape)
                .overlay { shape.stroke(borderColor, lineWidth: 1) }
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(fallbackTint, in: shape)
                .overlay { shape.stroke(borderColor, lineWidth: 1) }
        }
    }
}

private extension View {
    func holdingDetailGlassCard() -> some View {
        modifier(HoldingDetailGlassCardModifier())
    }
}

private struct FiftyTwoWeekRange: View {
    let low: Double
    let high: Double
    let current: Double
    let periodStart: Double?
    let currency: String

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @State private var selectedIndex: Int?

    private let markerCount = 45
    private let tickWidth: CGFloat = 4
    private let tickHeight: CGFloat = 98
    private let currentTickHeight: CGFloat = 110
    /// Keep the marker visually aligned at y = 0 while giving its glow room to render.
    /// Canvas clips filters to its own bounds, which otherwise flattens the top cap.
    private let markerTopOverflow: CGFloat = 12

    private var currentTickWidth: CGFloat {
        colorScheme == .dark ? 6 : 7
    }

    private var currentPosition: Double {
        normalized(current)
    }

    private var startPosition: Double? {
        periodStart.map(normalized)
    }

    private var performanceColor: Color {
        guard let periodStart else { return CatfolioStyle.blue }
        return current >= periodStart
            ? Color(red: 0, green: 1, blue: 35 / 255).opacity(0.90)
            : Color(red: 1, green: 16 / 255, blue: 89 / 255)
    }

    private var highlightedGradientColors: [Color] {
        guard let periodStart else { return [CatfolioStyle.blue.opacity(0.35), CatfolioStyle.blue] }
        if current >= periodStart {
            return colorScheme == .dark
                ? [
                    Color(red: 8 / 255, green: 123 / 255, blue: 24 / 255).opacity(0.80),
                    Color(red: 15 / 255, green: 225 / 255, blue: 44 / 255).opacity(0.80),
                ]
                : [
                    Color(red: 219 / 255, green: 1, blue: 161 / 255),
                    Color(red: 26 / 255, green: 1, blue: 57 / 255),
                ]
        }
        return colorScheme == .dark
            ? [
                Color(red: 153 / 255, green: 10 / 255, blue: 53 / 255),
                Color(red: 1, green: 16 / 255, blue: 89 / 255),
            ]
            : [
                Color(red: 249 / 255, green: 150 / 255, blue: 250 / 255),
                Color(red: 1, green: 16 / 255, blue: 89 / 255),
            ]
    }

    private var performanceGlowColor: Color {
        guard let periodStart, current < periodStart else {
            return Color(red: 128 / 255, green: 1, blue: 93 / 255)
        }
        return Color(red: 1, green: 51 / 255, blue: 122 / 255)
    }

    private var changePercent: Double? {
        guard let periodStart, periodStart > 0 else { return nil }
        return (current / periodStart - 1) * 100
    }

    private var inactiveTickColor: Color {
        colorScheme == .dark
            ? .white.opacity(0.20)
            : Color(red: 240 / 255, green: 240 / 255, blue: 240 / 255)
    }

    private var rangeLabelColor: Color {
        colorScheme == .dark
            ? .white.opacity(0.36)
            : Color(red: 190 / 255, green: 191 / 255, blue: 191 / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("52-Week Range")
                .font(HoldingDetailTypography.medium(19, relativeTo: .headline))
                .frame(height: 23, alignment: .leading)

            GeometryReader { geometry in
                rangePlot(size: geometry.size)
            }
            .frame(height: 141)
        }
        .frame(height: 184, alignment: .top)
        .animation(.snappy(duration: 0.18), value: selectedIndex)
        .sensoryFeedback(.selection, trigger: selectedIndex) { oldValue, newValue in
            hapticsEnabled && oldValue != nil && newValue != nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("按住并横向拖动可查看任意价格")
    }

    @ViewBuilder
    private func rangePlot(size: CGSize) -> some View {
        let currentIndex = markerIndex(for: currentPosition)
        let startIndex = startPosition.map(markerIndex)
        let highlightedRange = startIndex.map {
            min($0, currentIndex)...max($0, currentIndex)
        }
        let currentX = xPosition(
            for: currentIndex,
            currentIndex: currentIndex,
            width: size.width
        )
        let rangeStartX = startIndex.map {
            xPosition(for: $0, currentIndex: currentIndex, width: size.width)
        } ?? currentX
        ZStack(alignment: .topLeading) {
            Canvas { context, canvasSize in
                for index in 0..<markerCount {
                    let isCurrent = index == currentIndex
                    let isSelected = selectedIndex == index
                    let isActiveTick = isCurrent || isSelected
                    let isHighlighted = isCurrent || highlightedRange?.contains(index) == true
                    let width = isActiveTick ? currentTickWidth : tickWidth
                    let height = isActiveTick ? currentTickHeight : tickHeight
                    let rect = CGRect(
                        x: xPosition(
                            for: index,
                            currentIndex: currentIndex,
                            width: canvasSize.width
                        ) - width / 2,
                        y: markerTopOverflow + (isActiveTick ? 0 : 6),
                        width: width,
                        height: height
                    )
                    let path = Path(roundedRect: rect, cornerRadius: width / 2)
                    let fill: GraphicsContext.Shading
                    if isActiveTick {
                        fill = .color(performanceColor)
                    } else if isHighlighted {
                        fill = .linearGradient(
                            Gradient(colors: highlightedGradientColors),
                            startPoint: CGPoint(x: rangeStartX, y: 0),
                            endPoint: CGPoint(x: currentX, y: 0)
                        )
                    } else {
                        fill = .color(inactiveTickColor)
                    }
                    let showsCurrentGlow = selectedIndex == nil && isCurrent

                    if isSelected || showsCurrentGlow {
                        context.drawLayer { layer in
                            layer.addFilter(.shadow(
                                color: performanceGlowColor,
                                radius: isCurrent ? 8 : 5
                            ))
                            layer.fill(path, with: fill)
                        }
                    } else {
                        context.fill(path, with: fill)
                    }

                }
            }
            .frame(width: size.width, height: size.height + markerTopOverflow)
            .offset(y: -markerTopOverflow)

            if let selectedIndex {
                let selectedX = xPosition(
                    for: selectedIndex,
                    currentIndex: currentIndex,
                    width: size.width
                )
                let bubble = bubbleDetails(
                    for: selectedIndex,
                    currentIndex: currentIndex,
                    startIndex: startIndex
                )
                markerBubble(title: bubble.title, price: bubble.price)
                    .position(
                        x: bubbleX(selectedX, width: size.width),
                        y: -1
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .zIndex(2)
            }

            HStack(spacing: 12) {
                Text("Lowest \(DisplayFormat.money(low, currency: currency))")
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(DisplayFormat.money(high, currency: currency)) Highest")
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .appNumber(.callout)
            .foregroundStyle(rangeLabelColor)
            .frame(width: size.width)
            .position(x: size.width / 2, y: 129)

            ChartPointInteractionOverlay(
                onLocationChanged: { location in
                    let nextIndex = markerIndex(
                        at: location.x,
                        currentIndex: currentIndex,
                        width: size.width
                    )
                    guard nextIndex != selectedIndex else { return }
                    selectedIndex = nextIndex
                },
                onInteractionEnded: { selectedIndex = nil }
            )
            .frame(width: size.width, height: size.height)
            .position(x: size.width / 2, y: size.height / 2)
            .zIndex(3)
        }
    }

    private func bubbleDetails(
        for index: Int,
        currentIndex: Int,
        startIndex: Int?
    ) -> (title: String, price: Double) {
        if index == currentIndex { return ("现价", current) }
        if index == startIndex, let periodStart { return ("周期开始", periodStart) }
        let fraction = Double(index) / Double(max(markerCount - 1, 1))
        return ("价格", low + (high - low) * fraction)
    }

    @ViewBuilder
    private func markerBubble(title: String, price: Double) -> some View {
        let label = Text("\(title) \(DisplayFormat.money(price, currency: currency))")
            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 24)

        if #available(iOS 26.0, *) {
            label.glassEffect(.clear.interactive(), in: Capsule())
        } else {
            label
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(.white.opacity(0.30), lineWidth: 0.5)
                }
        }
    }

    private func bubbleX(_ rawX: CGFloat, width: CGFloat) -> CGFloat {
        let inset: CGFloat = 58
        return min(width - inset, max(inset, rawX))
    }

    private func normalized(_ price: Double) -> Double {
        guard high > low else { return 0 }
        return min(1, max(0, (price - low) / (high - low)))
    }

    private func markerIndex(for position: Double) -> Int {
        min(markerCount - 1, max(0, Int((position * Double(markerCount - 1)).rounded())))
    }

    private func markerIndex(at x: CGFloat, currentIndex: Int, width: CGFloat) -> Int {
        (0..<markerCount).min { lhs, rhs in
            abs(xPosition(for: lhs, currentIndex: currentIndex, width: width) - x)
                < abs(xPosition(for: rhs, currentIndex: currentIndex, width: width) - x)
        } ?? currentIndex
    }

    private func xPosition(
        for index: Int,
        currentIndex: Int,
        width: CGFloat
    ) -> CGFloat {
        guard markerCount > 1 else { return width / 2 }
        let currentExtraWidth = currentTickWidth - tickWidth
        let totalTickWidth = CGFloat(markerCount) * tickWidth + currentExtraWidth
        let gap = max(0.5, (width - totalTickWidth) / CGFloat(markerCount - 1))
        let itemWidth = index == currentIndex ? currentTickWidth : tickWidth
        let precedingCurrentExtra = index > currentIndex ? currentExtraWidth : 0
        return CGFloat(index) * (tickWidth + gap)
            + precedingCurrentExtra
            + itemWidth / 2
    }

    private var accessibilityText: String {
        var components = [
            "52 周最低 \(DisplayFormat.money(low, currency: currency))",
            "最高 \(DisplayFormat.money(high, currency: currency))",
            "当前价格 \(DisplayFormat.money(current, currency: currency))",
        ]
        if let periodStart {
            components.append("52 周前价格 \(DisplayFormat.money(periodStart, currency: currency))")
        }
        if let changePercent {
            components.append("52 周变化 \(DisplayFormat.percent(changePercent))")
        }
        return components.joined(separator: "，")
    }
}

enum VolumeProfileInterpretation {
    /// Product rule: "near the POC" means no farther than 10% of the
    /// selected historical value area's width. This is a presentation rule,
    /// not a market or accounting standard.
    static let pointOfControlProximityFraction = 0.10

    /// Product rule: costs within 1% of the current quote are described as
    /// broadly aligned. This is deliberately centralized for copy consistency.
    static let costParityFraction = 0.01

    enum PricePosition: Equatable {
        case below
        case inside
        case above
        case unavailable
    }

    enum CostPosition: Equatable {
        case belowCurrent
        case aligned
        case aboveCurrent
        case unavailable
    }

    struct Result: Equatable {
        let text: String
        let pricePosition: PricePosition
        let costPosition: CostPosition
        let isNearPointOfControl: Bool
        let costDifferencePercent: Double?
    }

    struct TailPresence: Equatable {
        let hasUpper: Bool
        let hasLower: Bool
    }

    struct BinSlice: Equatable {
        let priceLow: Double
        let priceHigh: Double
        let volume: Double
    }

    static func tailPresence(
        bins: [(priceLow: Double, priceHigh: Double, volume: Double)],
        valueAreaLow: Double,
        valueAreaHigh: Double
    ) -> TailPresence {
        guard valueAreaLow.isFinite,
              valueAreaHigh.isFinite,
              valueAreaHigh > valueAreaLow else {
            return TailPresence(hasUpper: false, hasLower: false)
        }
        let validBins = bins.filter {
            $0.volume.isFinite
                && $0.volume > 0
                && $0.priceLow.isFinite
                && $0.priceHigh.isFinite
                && $0.priceHigh > $0.priceLow
        }
        return TailPresence(
            hasUpper: validBins.contains { $0.priceHigh > valueAreaHigh },
            hasLower: validBins.contains { $0.priceLow < valueAreaLow }
        )
    }

    static func curveVerticalHandle(distance: Double) -> Double {
        guard distance.isFinite, distance > 0 else { return 0 }
        return distance / 3
    }

    /// Builds one continuous price profile. Real zero-volume buckets are kept as
    /// zero-width anchors, and missing price intervals receive a synthetic
    /// zero-volume anchor. The renderer can therefore keep one silhouette and
    /// taper empty regions into a narrow visual neck instead of separate islands.
    static func continuousSlices(
        bins: [(priceLow: Double, priceHigh: Double, volume: Double)],
        lowerBound: Double,
        upperBound: Double
    ) -> [BinSlice] {
        guard lowerBound.isFinite,
              upperBound.isFinite,
              upperBound > lowerBound else { return [] }

        let sortedBins = bins.filter {
            $0.volume.isFinite
                && $0.volume >= 0
                && $0.priceLow.isFinite
                && $0.priceHigh.isFinite
                && $0.priceHigh > $0.priceLow
        }.sorted { ($0.priceLow + $0.priceHigh) < ($1.priceLow + $1.priceHigh) }

        var slices: [BinSlice] = []
        var previousHigh = lowerBound
        var hasPositiveVolume = false

        for bin in sortedBins {
            let clippedLow = max(bin.priceLow, lowerBound)
            let clippedHigh = min(bin.priceHigh, upperBound)
            guard clippedHigh > clippedLow else { continue }
            let tolerance = max(0.000_000_001, max(abs(previousHigh), abs(clippedLow)) * 0.000_000_001)
            if clippedLow > previousHigh + tolerance {
                slices.append(BinSlice(priceLow: previousHigh, priceHigh: clippedLow, volume: 0))
            }
            slices.append(BinSlice(priceLow: clippedLow, priceHigh: clippedHigh, volume: bin.volume))
            hasPositiveVolume = hasPositiveVolume || bin.volume > 0
            previousHigh = max(previousHigh, clippedHigh)
        }
        let trailingTolerance = max(
            0.000_000_001,
            max(abs(previousHigh), abs(upperBound)) * 0.000_000_001
        )
        if previousHigh < upperBound - trailingTolerance {
            slices.append(BinSlice(priceLow: previousHigh, priceHigh: upperBound, volume: 0))
        }
        return hasPositiveVolume ? slices : []
    }

    static func constrainedCornerRadius(
        height: Double,
        topWidth: Double,
        bottomWidth: Double
    ) -> Double {
        guard height.isFinite,
              topWidth.isFinite,
              bottomWidth.isFinite else { return 0 }
        return max(0, min(18, min(height / 2, min(topWidth / 2, bottomWidth / 2))))
    }

    static func result(
        sessions: Int,
        quote: Double,
        valueAreaLow: Double,
        valueAreaHigh: Double,
        pointOfControl: Double?,
        cost: Double?
    ) -> Result {
        guard quote.isFinite,
              quote > 0,
              valueAreaLow.isFinite,
              valueAreaHigh.isFinite,
              valueAreaHigh > valueAreaLow else {
            return Result(
                text: "当前价格或主成交区数据暂不可用。",
                pricePosition: .unavailable,
                costPosition: .unavailable,
                isNearPointOfControl: false,
                costDifferencePercent: nil
            )
        }

        let period = sessions > 0 ? "过去\(sessions)个交易日" : "所选历史区间"
        let areaWidth = valueAreaHigh - valueAreaLow
        let isNearPointOfControl = pointOfControl.map { point in
            point.isFinite
                && point >= valueAreaLow
                && point <= valueAreaHigh
                && abs(quote - point) <= areaWidth * pointOfControlProximityFraction
        } ?? false

        let pricePosition: PricePosition
        var priceText: String
        if quote < valueAreaLow {
            pricePosition = .below
            priceText = "当前价格低于\(period)的主要成交区域，说明市场相对于所选历史成交区域处于弱势位置。"
        } else if quote > valueAreaHigh {
            pricePosition = .above
            priceText = "当前价格已高于\(period)的主要成交密集区，说明市场相对于所选历史成交区域处于较高位置。"
        } else {
            pricePosition = .inside
            priceText = "当前价格位于\(period)的主成交区内"
            priceText += isNearPointOfControl ? "，且接近成交峰值。" : "。"
        }

        guard let cost, cost.isFinite, cost > 0 else {
            return Result(
                text: priceText,
                pricePosition: pricePosition,
                costPosition: .unavailable,
                isNearPointOfControl: isNearPointOfControl,
                costDifferencePercent: nil
            )
        }

        let differenceFraction = abs(cost - quote) / quote
        let differencePercent = differenceFraction * 100
        let costPosition: CostPosition
        let costText: String
        if differenceFraction <= costParityFraction {
            costPosition = .aligned
            costText = "你的持仓成本与现价基本持平。"
        } else if cost < quote {
            costPosition = .belowCurrent
            costText = "你的持仓成本低于现价\(percentageText(differencePercent))%，目前持仓处于盈利状态。"
        } else {
            costPosition = .aboveCurrent
            costText = "你的持仓成本高于现价\(percentageText(differencePercent))%，当前持仓处于浮亏状态。"
        }

        return Result(
            text: "\(priceText)\(costText)",
            pricePosition: pricePosition,
            costPosition: costPosition,
            isNearPointOfControl: isNearPointOfControl,
            costDifferencePercent: differencePercent
        )
    }

    static func convertedPrice(
        _ value: Double,
        from sourceCurrency: String?,
        to targetCurrency: String?,
        usdRate: (String) -> Double?
    ) -> Double? {
        guard value.isFinite,
              value > 0,
              let source = normalizedCurrency(sourceCurrency),
              let target = normalizedCurrency(targetCurrency) else { return nil }
        guard source != target else { return value }
        guard let sourceRate = usdRate(source),
              let targetRate = usdRate(target),
              sourceRate.isFinite,
              targetRate.isFinite,
              sourceRate > 0,
              targetRate > 0 else { return nil }
        let converted = value * sourceRate / targetRate
        return converted.isFinite && converted > 0 ? converted : nil
    }

    private static func normalizedCurrency(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func percentageText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

private struct VolumePriceChart: View {
    let profile: VolumeProfile
    let holding: Holding
    let showsHoldingCost: Bool
    @State private var selectedPrice: Double?

    private var displayedValueArea: (low: Double, high: Double) {
        let positiveBins = (profile.bins ?? []).filter {
            $0.volume.isFinite && $0.volume > 0 && $0.priceHigh > $0.priceLow
        }
        let distributionLow = positiveBins.map(\.priceLow).min() ?? profile.valueAreaLow
        let distributionHigh = positiveBins.map(\.priceHigh).max() ?? profile.valueAreaHigh
        #if DEBUG
        let previewMode = ProcessInfo.processInfo.arguments
            .first { $0.hasPrefix("--volume-tail-preview=") }?
            .split(separator: "=", maxSplits: 1)
            .last
            .map(String.init)
        switch previewMode {
        case "none":
            return (distributionLow, distributionHigh)
        case "upper-only":
            return (distributionLow, profile.valueAreaHigh)
        case "lower-only":
            return (profile.valueAreaLow, distributionHigh)
        default:
            break
        }
        #endif
        return (profile.valueAreaLow, profile.valueAreaHigh)
    }

    private var currentPrice: Double? {
        VolumeProfileInterpretation.convertedPrice(
            holding.quotePrice,
            from: holding.quoteCurrency ?? profile.currency,
            to: profile.currency,
            usdRate: LocalPortfolioEngine.usdRate(for:)
        )
    }

    private var holdingCost: Double? {
        guard showsHoldingCost,
              holding.costCurrency?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              holding.quoteCurrency?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return VolumeProfileInterpretation.convertedPrice(
            holding.averageCost,
            from: holding.costCurrency,
            to: profile.currency,
            usdRate: LocalPortfolioEngine.usdRate(for:)
        )
    }

    private var domain: ClosedRange<Double> {
        let binValues = (profile.bins ?? []).flatMap { [$0.priceLow, $0.priceHigh] }
        var values = binValues + [
            displayedValueArea.low,
            displayedValueArea.high,
            profile.pointOfControl,
        ]
        if let currentPrice { values.append(currentPrice) }
        if let holdingCost { values.append(holdingCost) }
        values = values.filter { $0.isFinite && $0 > 0 }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.035, max(abs(high) * 0.005, 0.01))
        return max(0, low - padding)...(high + padding)
    }

    private var interpretation: VolumeProfileInterpretation.Result {
        VolumeProfileInterpretation.result(
            sessions: profile.sessions,
            quote: currentPrice ?? .nan,
            valueAreaLow: displayedValueArea.low,
            valueAreaHigh: displayedValueArea.high,
            pointOfControl: profile.pointOfControl,
            cost: holdingCost
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Volume Profile")
                    .font(HoldingDetailTypography.medium(19, relativeTo: .headline))

                Spacer(minLength: 12)

                Text("\(profile.sessions) 个交易日")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.50))
            }
            .frame(height: 23)

            VolumeDistributionPlot(
                profile: profile,
                valueAreaLow: displayedValueArea.low,
                valueAreaHigh: displayedValueArea.high,
                currentPrice: currentPrice,
                holdingCost: holdingCost,
                domain: domain,
                selectedPrice: $selectedPrice,
                onSelectionChanged: updateSelection
            )
            .frame(height: 303)
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 8) {
                Text(interpretation.text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(interpretation.text)

                Text(profile.asOf)
                    .foregroundStyle(.secondary)
            }
            .font(HoldingDetailTypography.medium(15, relativeTo: .subheadline))
            .padding(.top, 12)
        }
        .transaction { transaction in transaction.animation = nil }
    }

    private func updateSelection(_ price: Double?) {
        guard let price else {
            selectedPrice = nil
            return
        }
        guard price != selectedPrice else { return }
        selectedPrice = price

    }
}

private struct VolumeDistributionPlot: View {
    let profile: VolumeProfile
    let valueAreaLow: Double
    let valueAreaHigh: Double
    let currentPrice: Double?
    let holdingCost: Double?
    let domain: ClosedRange<Double>
    @Binding var selectedPrice: Double?
    let onSelectionChanged: (Double?) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private let verticalPlotInset: CGFloat = 0

    private var sourceBins: [VolumeProfileBin] {
        let bins = (profile.bins ?? [])
            .filter {
                $0.volume.isFinite
                    && $0.volume >= 0
                    && $0.priceLow.isFinite
                    && $0.priceHigh.isFinite
                    && $0.priceHigh > $0.priceLow
            }
            .sorted { $0.midpoint < $1.midpoint }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--volume-narrow-bin-preview"),
           let anchor = bins.first(where: { $0.volume > 0 }) {
            let narrowHeight = max((domain.upperBound - domain.lowerBound) * 0.000_1, 0.000_001)
            return [
                VolumeProfileBin(
                    priceLow: anchor.midpoint - narrowHeight / 2,
                    priceHigh: anchor.midpoint + narrowHeight / 2,
                    volume: anchor.volume
                )
            ]
        }
        #endif
        return bins
    }

    private var positiveBins: [VolumeProfileBin] {
        sourceBins.filter { $0.volume > 0 }
    }

    private func drawableProfile(lowerBound: Double, upperBound: Double) -> [VolumeProfileBin] {
        VolumeProfileInterpretation.continuousSlices(
            bins: sourceBins.map { ($0.priceLow, $0.priceHigh, $0.volume) },
            lowerBound: lowerBound,
            upperBound: upperBound
        ).map {
            VolumeProfileBin(priceLow: $0.priceLow, priceHigh: $0.priceHigh, volume: $0.volume)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let plotWidth = max(120, size.width - 93)
            let maximumVolume = max(positiveBins.map(\.volume).max() ?? 1, 0.000_001)
            let peakMarkerWidth = min(
                126,
                max(94, CGFloat(money(profile.pointOfControl).count) * 8 + 62)
            )
            let edgeLabelLeading: CGFloat = 6
            let peakMarkerX = edgeLabelLeading + peakMarkerWidth / 2
            let markerPriceLengths = [currentPrice, holdingCost]
                .compactMap { $0 }
                .map { money($0).count }
            let longestMarkerPrice = markerPriceLengths.max() ?? money(profile.pointOfControl).count
            let markerWidth = min(
                size.width * 0.42,
                max(100, CGFloat(longestMarkerPrice) * 8 + 62)
            )
            let markerGap: CGFloat = 6
            let hasValidValueArea = valueAreaLow.isFinite
                && valueAreaHigh.isFinite
                && valueAreaHigh > valueAreaLow
            let valueAreaHighY = hasValidValueArea
                ? yPosition(for: valueAreaHigh, height: size.height)
                : 0
            let valueAreaLowY = hasValidValueArea
                ? yPosition(for: valueAreaLow, height: size.height)
                : size.height
            let profileHigh = positiveBins.last?.priceHigh ?? valueAreaHigh
            let profileLow = positiveBins.first?.priceLow ?? valueAreaLow
            let profileTopY = yPosition(for: profileHigh, height: size.height)
            let profileBottomY = yPosition(for: profileLow, height: size.height)
            let currentY = currentPrice.map { yPosition(for: $0, height: size.height) }
            let costY = holdingCost.map { yPosition(for: $0, height: size.height) }
            let hasValidPeak = profile.pointOfControl.isFinite && profile.pointOfControl > 0
            let peakY = hasValidPeak ? yPosition(for: profile.pointOfControl, height: size.height) : 0
            let rightMarkerX = size.width - markerWidth / 2
            let markersWouldOverlap = currentY.flatMap { current in
                costY.map { abs(current - $0) < 28 }
            } ?? false
            let currentMarkerX = markersWouldOverlap
                ? rightMarkerX - markerWidth - markerGap
                : rightMarkerX
            let currentRuleEndX = currentMarkerX - markerWidth / 2 - markerGap
            let costRuleEndX = rightMarkerX - markerWidth / 2 - markerGap
            // Size the selection pill for the longest price in this chart. Keeping
            // the text at its semantic caption size avoids short integer values
            // looking larger than decimal values that previously had to shrink to
            // fit the fixed 58-point pill.
            let longestAxisPrice = max(
                money(domain.lowerBound, fractionDigits: 2).count,
                money(domain.upperBound, fractionDigits: 2).count
            )
            let axisPillWidth = min(
                size.width * 0.28,
                max(58, CGFloat(longestAxisPrice) * 7 + 18)
            )
            let axisPillX = size.width - axisPillWidth / 2

            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    let bins = drawableProfile(
                        lowerBound: domain.lowerBound,
                        upperBound: domain.upperBound
                    )
                    let silhouette = silhouettePath(
                        bins: bins,
                        maximumVolume: maximumVolume,
                        plotWidth: plotWidth,
                        height: canvasSize.height
                    )
                    let actualProfileRegion = Path(CGRect(
                        x: 0,
                        y: profileTopY,
                        width: plotWidth,
                        height: max(0, profileBottomY - profileTopY)
                    ))

                    // Prices outside the historical bins are a visual extension
                    // only. The weak fill keeps the price relationship legible;
                    // all profile calculations still use the original bins.
                    context.fill(silhouette, with: .color(volumeProfileExtensionBlue))
                    context.drawLayer { layer in
                        layer.clip(to: silhouette)
                        layer.fill(actualProfileRegion, with: .color(volumeProfileBlue))
                    }

                    if hasValidValueArea {
                        var tailRegions = Path()
                        tailRegions.addRect(CGRect(
                            x: 0,
                            y: 0,
                            width: plotWidth,
                            height: max(0, valueAreaHighY)
                        ))
                        tailRegions.addRect(CGRect(
                            x: 0,
                            y: valueAreaLowY,
                            width: plotWidth,
                            height: max(0, canvasSize.height - valueAreaLowY)
                        ))
                        context.drawLayer { layer in
                            layer.clip(to: silhouette)
                            layer.clip(to: actualProfileRegion)
                            layer.fill(tailRegions, with: .color(volumeProfileTailBlue))
                        }
                    }

                    var stripes = Path()
                    var x = -canvasSize.height
                    while x < plotWidth + canvasSize.height {
                        stripes.move(to: CGPoint(x: x, y: 0))
                        stripes.addLine(to: CGPoint(x: x + canvasSize.height, y: canvasSize.height))
                        x += 30
                    }
                    context.drawLayer { layer in
                        layer.clip(to: silhouette)
                        layer.stroke(stripes, with: .color(.white.opacity(0.12)), lineWidth: 11)
                    }
                    context.drawLayer { layer in
                        layer.clip(to: silhouette)
                        layer.clip(to: actualProfileRegion)
                        layer.stroke(stripes, with: .color(.white.opacity(0.20)), lineWidth: 11)
                    }
                }

                if let currentY {
                    glassRule(
                        color: currentPriceTint,
                        width: max(0, currentRuleEndX - edgeLabelLeading)
                    )
                    .position(
                        x: edgeLabelLeading + max(0, currentRuleEndX - edgeLabelLeading) / 2,
                        y: currentY
                    )
                    .zIndex(1)
                }

                if let costY {
                    glassRule(
                        color: volumeCostGreen,
                        width: max(0, costRuleEndX - edgeLabelLeading)
                    )
                    .position(
                        x: edgeLabelLeading + max(0, costRuleEndX - edgeLabelLeading) / 2,
                        y: costY
                    )
                    .zIndex(1)
                }

                if hasValidValueArea {
                    edgePriceLabel(price: valueAreaHigh)
                        .frame(width: 80, alignment: .leading)
                        .position(x: edgeLabelLeading + 40, y: valueAreaHighY + 14)
                }
                if hasValidValueArea {
                    edgePriceLabel(price: valueAreaLow)
                        .frame(width: 80, alignment: .leading)
                        .position(x: edgeLabelLeading + 40, y: valueAreaLowY - 14)
                }

                if let currentPrice, let currentY {
                    markerPill(
                        title: "当前价格",
                        price: currentPrice,
                        foreground: currentPriceText,
                        background: currentPriceTint,
                        width: markerWidth
                    )
                    .position(x: currentMarkerX, y: currentY)
                    .zIndex(2)
                }

                if hasValidPeak {
                    peakMarkerPill(
                        title: "成交峰值",
                        price: profile.pointOfControl,
                        width: peakMarkerWidth
                    )
                    .position(x: peakMarkerX, y: peakY)
                    .zIndex(2)
                }

                if let holdingCost, let costY {
                    markerPill(
                        title: "持仓成本",
                        price: holdingCost,
                        foreground: volumeCostText,
                        background: volumeCostGreen,
                        width: markerWidth
                    )
                    .position(x: rightMarkerX, y: costY)
                    .shadow(color: volumeCostGreen.opacity(0.42), radius: 18)
                    .zIndex(2)
                }

                if let selectedPrice {
                    let selectedRuleEndX = axisPillX - axisPillWidth / 2 - markerGap
                    let selectedRuleWidth = max(0, selectedRuleEndX - edgeLabelLeading)

                    glassRule(
                        color: volumeSelectionBlue,
                        width: selectedRuleWidth,
                        isInteractive: true
                    )
                    .position(
                        x: edgeLabelLeading + selectedRuleWidth / 2,
                        y: yPosition(for: selectedPrice, height: size.height)
                    )
                    .allowsHitTesting(false)
                    .zIndex(10)

                    axisPricePill(price: selectedPrice, width: axisPillWidth)
                        .position(x: axisPillX, y: yPosition(for: selectedPrice, height: size.height))
                        .zIndex(10)
                }

                ChartPointInteractionOverlay(
                    onLocationChanged: { location in
                        onSelectionChanged(price(at: location.y, height: size.height))
                    },
                    onInteractionEnded: { onSelectionChanged(nil) }
                )
                .zIndex(20)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = ["成交量价格分布", "成交峰值 \(money(profile.pointOfControl))"]
        if let currentPrice { parts.insert("当前价格 \(money(currentPrice))", at: 1) }
        if let holdingCost { parts.append("持仓成本 \(money(holdingCost))") }
        return parts.joined(separator: "，")
    }

    private var volumeCostGreen: Color {
        Color(red: 96 / 255, green: 1, blue: 52 / 255).opacity(0.8)
    }

    private var currentPriceTint: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.05)
    }

    private var currentPriceText: Color {
        colorScheme == .dark ? .white : .black
    }

    private var volumeCostText: Color {
        Color(red: 28 / 255, green: 83 / 255, blue: 13 / 255)
    }

    private var volumeProfileBlue: Color {
        Color(red: 52 / 255, green: 117 / 255, blue: 1)
    }

    private var volumeProfileTailBlue: Color {
        colorScheme == .dark
            ? Color(red: 113 / 255, green: 151 / 255, blue: 224 / 255)
            : Color(red: 188 / 255, green: 211 / 255, blue: 1)
    }

    private var volumeProfileExtensionBlue: Color {
        volumeProfileTailBlue.opacity(colorScheme == .dark ? 0.30 : 0.42)
    }

    private var volumeSelectionBlue: Color {
        Color(red: 0, green: 47 / 255, blue: 1).opacity(0.8)
    }

    private func yPosition(for price: Double, height: CGFloat) -> CGFloat {
        let top = verticalPlotInset
        let bottom = height - verticalPlotInset
        let span = max(domain.upperBound - domain.lowerBound, 0.0001)
        let ratio = min(1, max(0, (price - domain.lowerBound) / span))
        return bottom - CGFloat(ratio) * (bottom - top)
    }

    private func price(at y: CGFloat, height: CGFloat) -> Double {
        let top = verticalPlotInset
        let bottom = height - verticalPlotInset
        let clamped = min(bottom, max(top, y))
        let ratio = Double((bottom - clamped) / max(bottom - top, 1))
        return domain.lowerBound + ratio * (domain.upperBound - domain.lowerBound)
    }

    private func silhouettePath(
        bins: [VolumeProfileBin],
        maximumVolume: Double,
        plotWidth: CGFloat,
        height: CGFloat
    ) -> Path {
        var path = Path()
        guard let first = bins.first, let last = bins.last else { return path }

        let widths = smoothedProfileWidths(
            bins: bins,
            maximumVolume: maximumVolume,
            plotWidth: plotWidth
        )
        let topY = yPosition(for: last.priceHigh, height: height)
        let bottomY = yPosition(for: first.priceLow, height: height)
        let topWidth = widths.last ?? plotWidth * 0.2
        let bottomWidth = widths.first ?? plotWidth * 0.2
        let profilePoints = zip(bins.reversed(), widths.reversed()).map { bin, width in
            CGPoint(x: width, y: yPosition(for: bin.midpoint, height: height))
        }

        let realHeight = max(0, bottomY - topY)
        let cornerRadius = CGFloat(
            VolumeProfileInterpretation.constrainedCornerRadius(
                height: Double(realHeight),
                topWidth: Double(topWidth),
                bottomWidth: Double(bottomWidth)
            )
        )
        let topRadius = min(cornerRadius, topWidth / 2)
        let bottomRadius = min(cornerRadius, bottomWidth / 2)

        path.move(to: CGPoint(x: 0, y: topY + cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: cornerRadius, y: topY),
            control: CGPoint(x: 0, y: topY)
        )
        path.addLine(to: CGPoint(x: max(cornerRadius, topWidth - topRadius), y: topY))
        addSmoothProfileEdge(
            to: &path,
            points: profilePoints,
            topY: topY,
            topWidth: topWidth,
            topRadius: topRadius,
            bottomY: bottomY,
            bottomWidth: bottomWidth,
            bottomRadius: bottomRadius
        )
        path.addLine(to: CGPoint(x: cornerRadius, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: 0, y: bottomY - cornerRadius),
            control: CGPoint(x: 0, y: bottomY)
        )
        path.closeSubpath()
        #if DEBUG
        let bounds = path.boundingRect
        let boundaryTolerance: CGFloat = 0.01
        assert(
            bounds.minY >= topY - boundaryTolerance
                && bounds.maxY <= bottomY + boundaryTolerance,
            "Volume profile curve escaped its real price band"
        )
        #endif
        return path
    }

    /// Draws the exposed edge as one continuous cubic curve. Using a shared
    /// derivative at every bin removes the small horizontal/vertical "feet"
    /// produced by giving each segment its own vertical tangent.
    private func addSmoothProfileEdge(
        to path: inout Path,
        points: [CGPoint],
        topY: CGFloat,
        topWidth: CGFloat,
        topRadius: CGFloat,
        bottomY: CGFloat,
        bottomWidth: CGFloat,
        bottomRadius: CGFloat
    ) {
        let edgePoints = points.filter { $0.y > topY && $0.y < bottomY }
        guard !edgePoints.isEmpty else {
            path.addCurve(
                to: CGPoint(x: max(0, bottomWidth - bottomRadius), y: bottomY),
                control1: CGPoint(x: topWidth, y: topY),
                control2: CGPoint(x: bottomWidth, y: bottomY)
            )
            return
        }

        let slopes = smoothEdgeSlopes(for: edgePoints)
        let first = edgePoints[0]
        let topVerticalHandle = CGFloat(
            VolumeProfileInterpretation.curveVerticalHandle(
                distance: Double(first.y - topY)
            )
        )
        path.addCurve(
            to: first,
            control1: CGPoint(x: topWidth, y: topY),
            control2: CGPoint(
                x: first.x - slopes[0] * topVerticalHandle,
                y: first.y - topVerticalHandle
            )
        )

        if edgePoints.count > 1 {
            for index in 0..<(edgePoints.count - 1) {
                let start = edgePoints[index]
                let end = edgePoints[index + 1]
                let verticalHandle = CGFloat(
                    VolumeProfileInterpretation.curveVerticalHandle(
                        distance: Double(end.y - start.y)
                    )
                )
                path.addCurve(
                    to: end,
                    control1: CGPoint(
                        x: start.x + slopes[index] * verticalHandle,
                        y: start.y + verticalHandle
                    ),
                    control2: CGPoint(
                        x: end.x - slopes[index + 1] * verticalHandle,
                        y: end.y - verticalHandle
                    )
                )
            }
        }

        let last = edgePoints[edgePoints.count - 1]
        let bottomVerticalHandle = CGFloat(
            VolumeProfileInterpretation.curveVerticalHandle(
                distance: Double(bottomY - last.y)
            )
        )
        path.addCurve(
            to: CGPoint(x: max(0, bottomWidth - bottomRadius), y: bottomY),
            control1: CGPoint(
                x: last.x + slopes[slopes.count - 1] * bottomVerticalHandle,
                y: last.y + bottomVerticalHandle
            ),
            control2: CGPoint(x: bottomWidth, y: bottomY)
        )
    }

    /// Monotone cubic slopes for x as a function of y. At local peaks and
    /// valleys the tangent settles to zero instead of overshooting, while all
    /// other joins retain one continuous direction.
    private func smoothEdgeSlopes(for points: [CGPoint]) -> [CGFloat] {
        guard points.count > 1 else { return [0] }

        let segmentSlopes = (0..<(points.count - 1)).map { index -> CGFloat in
            let deltaY = max(points[index + 1].y - points[index].y, 0.001)
            return (points[index + 1].x - points[index].x) / deltaY
        }
        var slopes = Array(repeating: CGFloat.zero, count: points.count)
        slopes[0] = segmentSlopes[0]
        slopes[points.count - 1] = segmentSlopes[segmentSlopes.count - 1]

        if points.count > 2 {
            for index in 1..<(points.count - 1) {
                let previous = segmentSlopes[index - 1]
                let next = segmentSlopes[index]
                guard previous * next > 0 else {
                    slopes[index] = 0
                    continue
                }
                slopes[index] = 2 * previous * next / (previous + next)
            }
        }
        return slopes
    }

    /// Keeps the profile faithful to the source bins while removing tiny visual spikes.
    /// The continuous values feed the cubic edge directly; quantising them would recreate
    /// the deliberate-looking ledges that the smoothing is meant to remove.
    private func smoothedProfileWidths(
        bins: [VolumeProfileBin],
        maximumVolume: Double,
        plotWidth: CGFloat
    ) -> [CGFloat] {
        guard !bins.isEmpty else { return [] }

        let safeMaximum = max(maximumVolume, 0.000_001)
        let normalized = bins.map { max(0, $0.volume / safeMaximum) }
        let kernel: [Double] = [1, 2, 3, 4, 3, 2, 1]
        let radius = kernel.count / 2
        let filtered = normalized.indices.map { index in
            var weightedValue = 0.0
            var totalWeight = 0.0
            for offset in -radius...radius {
                let neighbor = min(normalized.count - 1, max(0, index + offset))
                let weight = kernel[offset + radius]
                weightedValue += normalized[neighbor] * weight
                totalWeight += weight
            }
            return weightedValue / max(totalWeight, 1)
        }

        var displayValues = filtered
        if let peakIndex = bins.indices.max(by: { bins[$0].volume < bins[$1].volume }) {
            // Preserve the profile's true scale against the global maximum.
            displayValues[peakIndex] = normalized[peakIndex]
        }

        return displayValues.indices.map { index in
            if normalized[index] == 0 {
                // The smoothed value forms a narrow visual neck across empty
                // buckets. Four points is only a topology floor: it keeps the
                // silhouette visibly whole without suggesting material volume.
                return min(plotWidth, max(4, plotWidth * CGFloat(displayValues[index])))
            }
            return plotWidth * CGFloat(max(0, displayValues[index]))
        }
    }

    private func money(_ price: Double, fractionDigits: Int? = nil) -> String {
        DisplayFormat.money(
            price,
            currency: profile.currency,
            fractionDigits: fractionDigits
        )
    }

    private func markerPill(
        title: String,
        price: Double,
        foreground: Color,
        background: Color,
        width: CGFloat
    ) -> some View {
        tintedGlassPill(
            markerPillLabel(title: title, price: price, foreground: foreground)
                .frame(width: width),
            tint: background
        )
    }

    private func peakMarkerPill(title: String, price: Double, width: CGFloat) -> some View {
        tintedGlassPill(
            markerPillLabel(title: title, price: price, foreground: .white)
                .frame(width: width, alignment: .leading),
            tint: volumeSelectionBlue.opacity(0.45)
        )
    }

    private func markerPillLabel(
        title: String,
        price: Double,
        foreground: Color
    ) -> some View {
        (
            Text(title)
                .font(Typography.text(.micro, weight: .semibold))
            + Text(" \(money(price))")
                .font(Typography.number(.micro, weight: .bold))
        )
        .foregroundStyle(foreground)
        .lineLimit(1)
        .minimumScaleFactor(0.58)
        .allowsTightening(true)
        .padding(.horizontal, 8)
        .frame(height: 24)
    }

    private func edgePriceLabel(price: Double) -> some View {
        Text(money(price))
            .appNumber(.micro, weight: .semibold)
            .fontDesign(.rounded)
            .foregroundStyle(.white)
            .lineLimit(1)
    }

    private func axisPricePill(price: Double, width: CGFloat) -> some View {
        let label = Text(money(price, fractionDigits: 2))
            .appNumber(.micro, weight: .semibold)
            .fontDesign(.rounded)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: width, height: 26)

        return tintedGlassPill(label, tint: volumeSelectionBlue, isInteractive: true)
    }

    @ViewBuilder
    private func glassRule(
        color: Color,
        width: CGFloat,
        isInteractive: Bool = false
    ) -> some View {
        let rule = Color.clear
            .frame(width: width, height: 5)

        if #available(iOS 26.0, *) {
            rule.glassEffect(glass(tint: color, isInteractive: isInteractive), in: Capsule())
        } else {
            rule
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().fill(color.opacity(0.72)) }
                .overlay { Capsule().stroke(.white.opacity(0.28), lineWidth: 0.5) }
        }
    }

    @ViewBuilder
    private func tintedGlassPill<Content: View>(
        _ content: Content,
        tint: Color,
        isInteractive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(glass(tint: tint, isInteractive: isInteractive), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .background(tint.opacity(0.62), in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.32), lineWidth: 0.5) }
        }
    }

    @available(iOS 26.0, *)
    private func glass(tint: Color, isInteractive: Bool) -> Glass {
        let material = Glass.clear.tint(tint)
        return isInteractive ? material.interactive() : material
    }

}
