import SwiftUI
import UIKit

enum HoldingSortField: String, CaseIterable, Identifiable {
    case marketValue
    case unrealized
    case unrealizedPercent
    case week52Position
    case volumeArea
    case name

    var id: String { rawValue }

    /// The 52-week and volume sorts only where their column is shown.
    static func available(shows52Week: Bool, showsVolume: Bool) -> [HoldingSortField] {
        allCases.filter {
            switch $0 {
            case .week52Position: shows52Week
            case .volumeArea: showsVolume
            default: true
            }
        }
    }

    var title: String {
        switch self {
        case .marketValue: L10n.text("市值")
        case .unrealized: L10n.text("盈利")
        case .unrealizedPercent: L10n.text("收益率")
        case .week52Position: L10n.text("52 周位置")
        case .volumeArea: L10n.text("成交密集区位置")
        case .name: L10n.text("名称")
        }
    }

    var compactTitle: String {
        switch self {
        case .marketValue: L10n.text("Mkt Cap")
        case .unrealized: L10n.text("P&L")
        case .unrealizedPercent: L10n.text("Return")
        case .week52Position: L10n.text("52 周位置")
        case .volumeArea: L10n.text("成交密集区位置")
        case .name: L10n.text("Name")
        }
    }
}

enum HoldingPerformancePeriod: String, CaseIterable, Identifiable {
    case today
    case holdingPeriod

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: L10n.text("今日")
        case .holdingPeriod: L10n.text("持有期")
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .holdingPeriod: "calendar.badge.clock"
        }
    }
}

struct HeatmapPerformancePeriodMenu: View {
    @Environment(\.locale) private var appLocale
    @Binding var period: HoldingPerformancePeriod
    @Binding var groupsBySector: Bool
    @Binding var looksThroughETF: Bool
    var isToolbarItem = false

    var body: some View {
        Menu {
            Picker(L10n.text("收益时间"), selection: $period) {
                ForEach(HoldingPerformancePeriod.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Section(L10n.text("布局")) {
                Toggle(L10n.text("按板块分组"), isOn: $groupsBySector)
                Toggle(L10n.text("穿透 ETF"), isOn: $looksThroughETF)
            }
        } label: {
            if isToolbarItem {
                Image("AssistantMenu")
                    .renderingMode(.template)
                    .foregroundStyle(CatfolioTheme.primaryText)
                    .frame(width: 24, height: 24)
            } else {
                PortfolioFilterLabel()
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .menuOrder(.fixed)
        .accessibilityLabel(
            L10n.text("热力图筛选：\(period.title)，\(groupsBySector ? "按板块分组" : "不分组")，")
                + (looksThroughETF ? L10n.text("已穿透 ETF") : L10n.text("未穿透 ETF"))
        )
    }
}

struct HoldingSortMenu: View {
    @Environment(\.locale) private var appLocale
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @Binding var field: HoldingSortField
    var fields = HoldingSortField.allCases
    @Binding var ascending: Bool
    @Binding var performancePeriod: HoldingPerformancePeriod
    var iconOnly = false
    var isSidebar = false

    var body: some View {
        menu
        .buttonStyle(.plain)
        .appText(.footnote, weight: .medium)
        .foregroundStyle(.secondary)
        .sensoryFeedback(.selection, trigger: performancePeriod) { _, _ in hapticsEnabled }
        .accessibilityLabel(L10n.text("筛选：\(performancePeriod.title)；排序：\(field.title)，\(ascending ? "升序" : "降序")"))
    }

    private var menu: some View {
        Menu {
            Picker(L10n.text("收益时间"), selection: $performancePeriod) {
                ForEach(HoldingPerformancePeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Picker(L10n.text("排序方式"), selection: $field) {
                ForEach(fields) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Button {
                ascending.toggle()
            } label: {
                Label(
                    ascending ? L10n.text("改为降序") : L10n.text("改为升序"),
                    systemImage: ascending ? "arrow.down" : "arrow.up"
                )
            }
        } label: {
            Group {
                if iconOnly || isSidebar {
                    PortfolioFilterLabel(iconSize: isSidebar ? 20 : 24)
                } else {
                    HStack(spacing: 3) {
                        Text(field.compactTitle)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
            }
        }
        .menuOrder(.fixed)
    }
}

struct PortfolioFilterLabel: View {
    @Environment(\.portfolioFilterFloats) private var inBar
    var iconSize: CGFloat = 24

    var body: some View {
        Image("AssistantMenu")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(CatfolioTheme.primaryText)
            .frame(width: iconSize, height: iconSize)
            // The floating glass wrapper supplies its own 44-point target.
            .frame(width: inBar ? nil : 44, height: inBar ? nil : 44)
            .modifier(PortfolioHeaderMaterialControl())
            .contentShape(Circle())
    }
}
