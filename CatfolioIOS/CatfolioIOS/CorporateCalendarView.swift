import SwiftUI

/// Earnings and dividend dates for the listings the portfolio holds.
enum CorporateCalendarMode: String, CaseIterable, Identifiable {
    case earnings, dividends

    var id: String { rawValue }
    var title: String { L10n.text(self == .earnings ? "财报" : "股息") }

    func includes(_ kind: CorporateEvent.Kind) -> Bool {
        self == .earnings ? kind == .earnings : kind.isDividend
    }
}

private extension CorporateEvent {
    var kindTitle: String {
        switch kind {
        case .earnings: L10n.text(isEstimate ? "财报（预计）" : "财报")
        case .exDividend: L10n.text(isEstimate ? "预计除息" : "除息")
        case .dividendPayment: L10n.text("派息")
        }
    }

    var tint: Color {
        switch kind {
        case .earnings: Color(red: 0.52, green: 0.47, blue: 0.95).opacity(0.18)
        case .exDividend: Color(red: 0.58, green: 0.66, blue: 0.27).opacity(0.22)
        case .dividendPayment: Color(red: 0.58, green: 0.66, blue: 0.27).opacity(0.12)
        }
    }

    /// What the holding's shares get from this dividend, in USD.
    func incomeUSD(shares: Double) -> Double? {
        guard kind.isDividend, let amount, let currency, shares > 0,
              let rate = LocalPortfolioEngine.usdRate(for: currency) else { return nil }
        return amount * shares * rate
    }
}

private struct CorporateCalendarHoldings {
    let byTicker: [String: Holding]

    init(_ holdings: [Holding]) {
        byTicker = Dictionary(holdings.filter { $0.shares > 0 }.map { ($0.ticker.uppercased(), $0) },
                              uniquingKeysWith: { first, _ in first })
    }

    var tickers: [String] { byTicker.keys.sorted() }
    func holding(_ event: CorporateEvent) -> Holding? { byTicker[event.ticker.uppercased()] }
}

private enum CorporateCalendarDay {
    static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A yyyy-MM-dd key as a local date, for formatting only.
    static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

// MARK: - Card

/// The next few dates on the portfolio's calendar, with the whole calendar
/// a tap away.
struct CorporateEventsCard: View {
    let holdings: [Holding]
    private let store = CorporateEventsStore.shared
    private static let limit = 3

    private var scope: CorporateCalendarHoldings { CorporateCalendarHoldings(holdings) }

    private var upcoming: [CorporateEvent] {
        let today = CorporateCalendarDay.key(Date(), calendar: .current)
        return store.events(for: Set(scope.tickers)).filter { $0.date >= today }.prefix(Self.limit).map { $0 }
    }

    var body: some View {
        let scope = scope
        // Titled like the security page's entry cards; the title opens the
        // calendar, and the next dates sit under it.
        VStack(alignment: .leading, spacing: 0) {
            NavigationLink { CorporateCalendarView(holdings: holdings) } label: {
                HoldingDetailCardHeader(title: L10n.text("公司日历"), subtitle: L10n.text("财报、除息与派息日期"),
                    symbol: "chevron.right", isLoading: store.isLoading && upcoming.isEmpty)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("corporate-calendar.open")

            if !upcoming.isEmpty {
                VStack(spacing: 12) {
                    ForEach(upcoming) { event in
                        CorporateEventCardRow(event: event, holding: scope.holding(event))
                    }
                }
                .padding(.horizontal, HoldingDetailCardStyle.contentInset)
                .padding(.bottom, HoldingDetailCardStyle.contentInset)
            } else if !store.isLoading {
                Text(L10n.text("近期没有财报或除息"))
                    .appText(.callout)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .padding(.horizontal, HoldingDetailCardStyle.contentInset)
                    .padding(.bottom, HoldingDetailCardStyle.contentInset)
            }
        }
        .holdingDetailCard()
        .accessibilityIdentifier("corporate-calendar.card")
        .task(id: scope.tickers.joined(separator: ",")) { await store.load(tickers: scope.tickers) }
    }
}

private struct CorporateEventCardRow: View {
    let event: CorporateEvent
    let holding: Holding?
    var body: some View {
        let date = CorporateCalendarDay.date(event.date, calendar: .current) ?? Date()
        HStack(spacing: 12) {
            CorporateEventDateTile(date: date, day: Int(event.date.suffix(2)) ?? 0)

            HStack(spacing: 12) {
                AssetLogo(ticker: event.ticker, logoSymbol: holding?.logoSymbol, size: 40, cornerRadius: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(holding?.shortName ?? event.ticker)
                        .appText(.body, weight: .medium)
                        .foregroundStyle(CatfolioTheme.primaryText)
                        .lineLimit(1)
                    Text(event.kindTitle)
                        .appText(.footnote)
                        .foregroundStyle(SettingsTemplate.secondaryText)
                }
                Spacer(minLength: 0)
                if let income = event.incomeUSD(shares: holding?.shares ?? 0) {
                    Text(DisplayFormat.money(income))
                        .appNumber(.footnote, weight: .medium)
                        .foregroundStyle(CatfolioTheme.primaryText)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Calendar

struct CorporateCalendarView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    let holdings: [Holding]
    private let store = CorporateEventsStore.shared
    @State private var mode: CorporateCalendarMode = .earnings
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var selectedDay: String?

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = appLocale
        calendar.firstWeekday = 2
        return calendar
    }
    private var scope: CorporateCalendarHoldings { CorporateCalendarHoldings(holdings) }
    private var todayKey: String { CorporateCalendarDay.key(Date(), calendar: calendar) }

    private var monthDays: [String] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        return range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: month).map { CorporateCalendarDay.key($0, calendar: calendar) }
        }
    }

    /// Blank cells before the first, so it falls under its weekday.
    private var leadingBlanks: Int {
        (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
    }

    private var monthEvents: [CorporateEvent] {
        let days = Set(monthDays)
        return store.events(for: Set(scope.tickers)).filter { mode.includes($0.kind) && days.contains($0.date) }
    }

    var body: some View {
        let events = monthEvents
        let byDay = Dictionary(grouping: events, by: \.date)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker(L10n.text("类型"), selection: $mode) {
                    ForEach(CorporateCalendarMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                header(events)

                VStack(spacing: 6) {
                    weekdayRow
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(0..<leadingBlanks, id: \.self) { _ in Color.clear.frame(height: 64) }
                        ForEach(monthDays, id: \.self) { day in
                            dayCell(day, events: byDay[day] ?? [])
                        }
                    }
                }
                .id(month)
                .transition(.opacity)
                .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    shiftMonth(value.translation.width < 0 ? 1 : -1)
                })

                // A day with nothing on it lists the whole month instead.
                eventList(selectedDay.flatMap { byDay[$0] } ?? events)
            }
            .padding(SettingsTemplate.pageInset)
            .padding(.bottom, 24)
        }
        .appPageBackground(SettingsTemplate.pageBackground)
        .navigationTitle(L10n.text("公司日历"))
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: mode) { _, _ in hapticsEnabled }
        .sensoryFeedback(.selection, trigger: selectedDay) { _, _ in hapticsEnabled }
        .onAppear { selectedDay = monthDays.contains(todayKey) ? todayKey : nil }
        .task(id: scope.tickers.joined(separator: ",")) { await store.load(tickers: scope.tickers) }
        .accessibilityIdentifier("corporate-calendar")
    }

    private func header(_ events: [CorporateEvent]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text(month, format: .dateTime.year().month(.wide))
                    .appText(.title, weight: .bold)
                    .foregroundStyle(CatfolioTheme.primaryText)
                    .contentTransition(.numericText())
                Spacer()
                monthButton("chevron.left", label: L10n.text("上个月")) { shiftMonth(-1) }
                monthButton("chevron.right", label: L10n.text("下个月")) { shiftMonth(1) }
            }
            Text(summary(events))
                .appText(.footnote)
                .foregroundStyle(SettingsTemplate.secondaryText)
                .contentTransition(.numericText())
        }
    }

    private func summary(_ events: [CorporateEvent]) -> String {
        switch mode {
        case .earnings:
            let count = Set(events.map(\.ticker)).count
            return count == 0 ? L10n.text("本月没有持仓公司发布财报") : L10n.text("\(count) 家公司发布财报")
        case .dividends:
            let exDates = events.filter { $0.kind == .exDividend }.count
            let payments = events.filter { $0.kind == .dividendPayment }
            // Money arrives on the payment date; until one is announced, the
            // ex-dates stand in for it.
            let counted = payments.isEmpty ? events.filter { $0.kind == .exDividend } : payments
            let income = counted.compactMap { $0.incomeUSD(shares: scope.holding($0)?.shares ?? 0) }.reduce(0, +)
            var parts: [String] = []
            if income > 0 { parts.append(L10n.text("约 \(DisplayFormat.money(income))")) }
            if exDates > 0 { parts.append(L10n.text("\(String(exDates)) 次除息")) }
            if !payments.isEmpty { parts.append(L10n.text("\(String(payments.count)) 次派息")) }
            return parts.isEmpty ? L10n.text("本月没有除息或派息") : parts.joined(separator: " · ")
        }
    }

    private func monthButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CatfolioTheme.primaryText)
                .frame(width: 44, height: 44)
                .background(SettingsTemplate.card, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var weekdayRow: some View {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let ordered = Array(symbols[(calendar.firstWeekday - 1)...] + symbols[..<(calendar.firstWeekday - 1)])
        return HStack(spacing: 6) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .appText(.caption, weight: .medium)
                    .foregroundStyle(SettingsTemplate.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ day: String, events: [CorporateEvent]) -> some View {
        let isToday = day == todayKey
        let isSelected = day == selectedDay
        let tickers = events.map(\.ticker).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selectedDay = isSelected ? nil : day }
        } label: {
            VStack(spacing: 4) {
                Text(String(Int(day.suffix(2)) ?? 0))
                    .appNumber(.caption, weight: isToday ? .bold : .medium)
                    .foregroundStyle(isToday ? CatfolioTheme.primaryText : SettingsTemplate.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                if let first = tickers.first {
                    AssetLogo(ticker: first, logoSymbol: scope.byTicker[first.uppercased()]?.logoSymbol,
                              size: 26, cornerRadius: 8)
                }
                Text(tickers.count > 1 ? "+\(tickers.count - 1)" : " ")
                    .appNumber(.nano, weight: .medium)
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .frame(height: 76)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.primary.opacity(0.1) : SettingsTemplate.card,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(CatfolioTheme.primaryText, lineWidth: 1.5)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(CorporateCalendarDay.date(day, calendar: calendar) ?? Date(),
                                 format: .dateTime.month().day()))
        .accessibilityValue(tickers.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func eventList(_ events: [CorporateEvent]) -> some View {
        if events.isEmpty {
            if store.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
            }
        } else {
            SettingsCard {
                ForEach(events) { event in eventRow(event) }
            }
        }
    }

    private func eventRow(_ event: CorporateEvent) -> some View {
        let holding = scope.holding(event)
        let date = CorporateCalendarDay.date(event.date, calendar: calendar) ?? Date()
        return HStack(spacing: 12) {
            AssetLogo(ticker: event.ticker, logoSymbol: holding?.logoSymbol, size: 36, cornerRadius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(holding?.shortName ?? event.ticker)
                    .appText(.body, weight: .medium)
                    .foregroundStyle(CatfolioTheme.primaryText)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(date, format: .dateTime.month(.abbreviated).day())
                    Text("·")
                    Text(event.kindTitle)
                }
                .appText(.footnote)
                .foregroundStyle(SettingsTemplate.secondaryText)
            }
            Spacer(minLength: 8)
            if let income = event.incomeUSD(shares: holding?.shares ?? 0) {
                Text(DisplayFormat.money(income, fractionDigits: 2))
                    .appNumber(.callout, weight: .medium)
                    .foregroundStyle(CatfolioTheme.primaryText)
            }
        }
        .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func shiftMonth(_ step: Int) {
        guard let next = calendar.date(byAdding: .month, value: step, to: month) else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            month = next
            selectedDay = monthDays.contains(todayKey) ? todayKey : nil
        }
    }
}

/// The date as a calendar icon: a small tile with the month in red over the
/// day, the way a calendar app marks a day.
private struct CorporateEventDateTile: View {
    @Environment(\.locale) private var appLocale
    let date: Date
    let day: Int

    private static let monthRed = Color(red: 0.78, green: 0.24, blue: 0.24)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated).locale(appLocale)).uppercased(with: appLocale))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Self.monthRed)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(String(day))
                .appNumber(.title, weight: .medium)
                .foregroundStyle(CatfolioTheme.primaryText)
                .lineLimit(1)
        }
        .frame(width: 52, height: 56)
        .background(SettingsTemplate.card, in: shape)
        .overlay { shape.strokeBorder(SettingsTemplate.cardBorder, lineWidth: SettingsTemplate.cardBorderWidth) }
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .accessibilityHidden(true)
    }
}
