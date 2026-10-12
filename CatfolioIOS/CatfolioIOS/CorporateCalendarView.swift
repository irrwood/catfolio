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

extension CorporateEvent {
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

struct CorporateCalendarHoldings {
    let byTicker: [String: Holding]

    init(_ holdings: [Holding]) {
        byTicker = Dictionary(holdings.filter { $0.shares > 0 }.map { ($0.ticker.uppercased(), $0) },
                              uniquingKeysWith: { first, _ in first })
    }

    var tickers: [String] { byTicker.keys.sorted() }
    func holding(_ event: CorporateEvent) -> Holding? { byTicker[event.ticker.uppercased()] }
}

enum CorporateCalendarDay {
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

struct CorporateCalendarSummaryItem {
    let text: String
    let symbol: String?
    let accessibilityText: String
}

struct CorporateCalendarHeader: View {
    let month: Date
    let items: [CorporateCalendarSummaryItem]
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                titleAndSummary.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                navigation
            }
            VStack(alignment: .leading, spacing: 6) {
                titleAndSummary
                HStack { Spacer(); navigation }
            }
        }
    }

    private var titleAndSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(month, format: .dateTime.year().month(.wide))
                .appText(.title, weight: .bold)
                .foregroundStyle(CatfolioTheme.primaryText)
                .contentTransition(.numericText())
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { index in
                        if index > 0 { Text("·").accessibilityHidden(true) }
                        summaryItem(items[index])
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items.indices, id: \.self) { summaryItem(items[$0]) }
                }
            }
            .appText(.caption)
            .foregroundStyle(SettingsTemplate.secondaryText)
            .contentTransition(.numericText())
        }
    }

    private func summaryItem(_ item: CorporateCalendarSummaryItem) -> some View {
        HStack(spacing: 3) {
            if let symbol = item.symbol { Image(systemName: symbol) }
            Text(item.text).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityText)
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            monthButton("chevron.left", label: L10n.text("上个月"), action: previous)
            monthButton("chevron.right", label: L10n.text("下个月"), action: next)
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
}

// MARK: - Calendar

struct CorporateCalendarView: View {
    @Environment(\.locale) private var appLocale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    private let scope: CorporateCalendarHoldings
    private let store: CorporateEventsStore
    @State private var mode: CorporateCalendarMode = .earnings
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @State private var selectedDay: String? = CorporateCalendarDay.key(Date(), calendar: .current)

    init(holdings: [Holding], store: CorporateEventsStore? = nil) {
        self.scope = CorporateCalendarHoldings(holdings)
        self.store = store ?? .shared
    }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.locale = appLocale
        calendar.firstWeekday = 2
        return calendar
    }
    private var todayKey: String { CorporateCalendarDay.key(Date(), calendar: calendar) }

    private var monthDays: [String] {
        let calendar = calendar
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        return range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: month).map { CorporateCalendarDay.key($0, calendar: calendar) }
        }
    }

    /// Blank cells before the first, so it falls under its weekday.
    private var leadingBlanks: Int {
        (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
    }

    private func monthEvents(_ days: [String]) -> [CorporateEvent] {
        guard let first = days.first, let last = days.last else { return [] }
        return store.events(for: Set(scope.tickers), during: first...last).filter { mode.includes($0.kind) }
    }

    var body: some View {
        let days = monthDays
        let today = todayKey
        let events = monthEvents(days)
        let byDay = Dictionary(grouping: events, by: \.date)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Picker(L10n.text("类型"), selection: $mode) {
                    ForEach(CorporateCalendarMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                header(events)

                CorporateCalendarGrid(days: days, calendar: calendar, leadingBlanks: leadingBlanks,
                                      today: today, byDay: byDay, scope: scope, selectedDay: $selectedDay)
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
        CorporateCalendarHeader(month: month, items: summary(events),
                                previous: { shiftMonth(-1) }, next: { shiftMonth(1) })
    }

    private func summary(_ events: [CorporateEvent]) -> [CorporateCalendarSummaryItem] {
        switch mode {
        case .earnings:
            let count = Set(events.map(\.ticker)).count
            return [.init(text: String(count), symbol: "doc.text",
                          accessibilityText: count == 0 ? L10n.text("本月没有持仓公司发布财报")
                            : L10n.text("\(count) 家公司发布财报"))]
        case .dividends:
            let exDates = events.filter { $0.kind == .exDividend }.count
            let payments = events.filter { $0.kind == .dividendPayment }
            // Money arrives on the payment date; until one is announced, the
            // ex-dates stand in for it.
            let counted = payments.isEmpty ? events.filter { $0.kind == .exDividend } : payments
            let income = counted.compactMap { $0.incomeUSD(shares: scope.holding($0)?.shares ?? 0) }.reduce(0, +)
            var parts: [CorporateCalendarSummaryItem] = []
            if income > 0 {
                parts.append(.init(text: "≈ " + DisplayFormat.money(income), symbol: nil,
                                   accessibilityText: L10n.text("约 \(DisplayFormat.money(income))")))
            }
            if exDates > 0 {
                parts.append(.init(text: String(exDates), symbol: "calendar.badge.minus",
                                   accessibilityText: L10n.text("\(String(exDates)) 次除息")))
            }
            if !payments.isEmpty {
                parts.append(.init(text: String(payments.count), symbol: "banknote",
                                   accessibilityText: L10n.text("\(String(payments.count)) 次派息")))
            }
            return parts.isEmpty
                ? [.init(text: "0", symbol: "calendar", accessibilityText: L10n.text("本月没有除息或派息"))]
                : parts
        }
    }

    @ViewBuilder
    private func eventList(_ events: [CorporateEvent]) -> some View {
        if events.isEmpty {
            if store.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, 12)
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(events) { event in
                    CorporateCalendarEventRow(event: event, holding: scope.holding(event), calendar: calendar)
                    if event.id != events.last?.id { ContentPanelSeparator() }
                }
            }
            .settingsCardSurface()
        }
    }

    private func shiftMonth(_ step: Int) {
        guard let next = calendar.date(byAdding: .month, value: step, to: month) else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
            month = next
            selectedDay = monthDays.contains(todayKey) ? todayKey : nil
        }
    }
}
