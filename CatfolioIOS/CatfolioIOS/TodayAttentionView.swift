import SwiftUI

/// One entry on Performance; both analyses live on the pushed page.
struct TodayAttentionEntry: View {
    var body: some View {
        SettingsCard {
            SettingsNavigationRow(icon: .asset("AssistantSparkles"), title: L10n.text("今天值得关注"),
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

/// The selector belongs to the child page, above either complete report:
/// the system's segmented control.
struct TodayAttentionTabs: View {
    @Binding var selection: TodayAttentionTab
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    var body: some View {
        Picker(L10n.text("今天值得关注"), selection: $selection) {
            ForEach(TodayAttentionTab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("attention.tabs")
        .sensoryFeedback(.selection, trigger: selection) { _, _ in hapticsEnabled }
    }
}
