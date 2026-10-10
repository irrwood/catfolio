import SwiftUI

struct HistoryDividendSecurityGroup: Identifiable {
    let security: HistoryDividendBreakdown.Row
    let dates: [ActivityDateGroup]
    var id: String { security.ticker }

    static func build(_ activities: [PortfolioActivity], locale: Locale) -> [Self] {
        let dividends = activities.filter { $0.kind == .dividend }
        let byTicker = Dictionary(grouping: dividends) {
            let ticker = $0.transaction.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return ticker.isEmpty ? "CASH" : ticker
        }
        return HistoryDividendBreakdown.build(dividends).rows.map { security in
            let entries = Dictionary(grouping: byTicker[security.ticker] ?? []) { String($0.transaction.date.prefix(10)) }
            let dates = entries.keys.sorted(by: >).map { date in
                ActivityDateGroup(id: date, title: HistoryPreparedLedger.dateGroupTitle(date, locale: locale),
                    activities: (entries[date] ?? []).sorted { $0.id > $1.id })
            }
            return Self(security: security, dates: dates)
        }
    }
}

struct HistoryDividendSecurityPage: View {
    let group: HistoryDividendSecurityGroup
    let activityRow: (PortfolioActivity) -> AnyView

    var body: some View {
        List {
            ForEach(group.dates) { date in
                Section {
                    ForEach(Array(date.activities.enumerated()), id: \.element.id) { index, activity in
                        activityRow(activity)
                            .settingsListRow(isFirst: index == 0, isLast: index == date.activities.count - 1)
                    }
                } header: {
                    Text(date.title).textCase(nil)
                }
                .headerProminence(.increased)
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(SettingsTemplate.sectionSpacing)
        .scrollContentBackground(.hidden)
        .background { SettingsTemplate.pageBackground.ignoresSafeArea() }
        .hardTopScrollEdge()
        .navigationTitle(group.security.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .accessibilityIdentifier("history-dividend-security-page")
    }
}
