import SwiftUI

/// One entry on Performance; both analyses live on the pushed page.
struct TodayAttentionEntry: View {
    var body: some View {
        SettingsCard {
            SettingsNavigationRow(icon: .symbol("sparkles"), title: L10n.text("今天值得关注"),
                                  subtitle: L10n.text("持仓分析 · JEV 行情解读")) {
                TodayAttentionView()
            }
            .accessibilityIdentifier("performance.today-attention")
        }
    }
}

struct TodayAttentionView: View {
    @AppStorage("performance.attention.tab") private var tabRawValue = TodayAttentionTab.analysis.rawValue

    private var selection: Binding<TodayAttentionTab> {
        Binding(get: { TodayAttentionTab(rawValue: tabRawValue) ?? .analysis },
                set: { tabRawValue = $0.rawValue })
    }

    var body: some View {
        Group {
            switch selection.wrappedValue {
            case .analysis: ResearchView(showsAttention: true, titleDisplayMode: .inline)
            case .jev: JEVTodayAttentionView(titleDisplayMode: .inline)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            TodayAttentionTabs(selection: selection)
                .padding(.horizontal, SettingsTemplate.pageInset)
                .padding(.vertical, 4)
                .background(SettingsTemplate.pageBackground)
        }
    }
}

enum TodayAttentionTab: String, CaseIterable {
    case analysis, jev

    var title: String {
        switch self {
        case .analysis: L10n.text("今天值得关注")
        case .jev: "JEV"
        }
    }
}

/// The selector belongs to the child page, above either complete report.
struct TodayAttentionTabs: View {
    @Binding var selection: TodayAttentionTab
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    var body: some View {
        HStack(spacing: 20) {
            ForEach(TodayAttentionTab.allCases, id: \.self) { tab in
                Button { selection = tab } label: {
                    Text(tab.title)
                        .appText(.body, weight: selection == tab ? .semibold : .medium)
                        .foregroundStyle(selection == tab ? CatfolioTheme.primaryText : SettingsTemplate.sectionHeader)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
                .accessibilityIdentifier("attention.tab.\(tab.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .sensoryFeedback(.selection, trigger: selection) { _, _ in hapticsEnabled }
    }
}
