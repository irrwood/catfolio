import SwiftUI

struct HistoryOrdersSecurityPage: View {
    let group: HistoryOrdersBreakdown.Row
    let activityRow: (PortfolioActivity) -> AnyView

    var body: some View {
        List {
            Section {
                HistoryRealisedSummaryCard(calculation: group.calculation)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
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
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.visible, for: .navigationBar)
        .accessibilityIdentifier("history-orders-security-page")
    }
}
