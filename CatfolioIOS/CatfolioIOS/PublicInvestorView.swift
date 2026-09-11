import SwiftUI

struct PublicInvestorSettingsSection: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @AppStorage(PublicInvestorPreferences.selectionKey) private var selection = PublicInvestorPreferences.defaultSelection

    var body: some View {
        Group {
            SettingsSectionHeader(L10n.text("账户模式"))
            SettingsCard {
                // One switch, not two. Demo data and a public filer's portfolio
                // are the same thing to a reader — a portfolio that is not
                // theirs — and having them as separate toggles meant two ways to
                // leave your own data, each disabling the other.
                SettingsToggleRow(title: L10n.text("佩洛西模式"), isOn: Binding(
                    get: { model.isPublicInvestorMode || model.isFakeDataMode },
                    set: { model.setPortfolioMode(enabled: $0, selection: selection) }
                ))
                .accessibilityIdentifier("public-investor-mode")
                .accessibilityHint(L10n.text("开启后显示所选的公开组合或测试数据，你自己的持仓不受影响"))

                SettingsNavigationRow(
                    title: L10n.text("选择人物"),
                    value: selectionSummary
                ) {
                    PublicInvestorSelectionView()
                }
            }
            if let error = model.fakeDataModeError {
                SettingsFootnote(error, color: CatfolioTheme.danger)
            }
        }
    }

    private var selectionSummary: String {
        PublicInvestorNaming.title(
            selection: selection,
            isDemo: PublicInvestorPreferences.isDemo(selection),
            isInvestorMode: true
        ) ?? L10n.text("未选择")
    }

}

struct PublicInvestorSelectionView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @AppStorage(PublicInvestorPreferences.selectionKey) private var selection = PublicInvestorPreferences.defaultSelection

    var body: some View {
        SettingsPage(
            title: L10n.text("选择人物"),
            subtitle: L10n.text("可选择多个"),
            bottomInset: 32
        ) {
            // Its own card, above the filers and separated from them: the
            // others are real people's disclosed holdings, this one is not
            // real at all, and the two should never look like entries in one
            // list of investors.
            SettingsCard {
                SettingsToggleRow(
                    title: PublicInvestorDemo.title,
                    subtitle: PublicInvestorDemo.subtitle,
                    isOn: selectionBinding(for: PublicInvestorPreferences.demoID)
                )
                .toggleStyle(.switch)
                .accessibilityIdentifier("public-investor-demo")
            }
            SettingsFootnote(L10n.text("完全虚构的持仓、交易与收益，用于演示和截图。不会与真实数据混合，也不会同步到其他设备。"))

            switch PublicInvestorCatalog.loaded {
            case .success(let catalog):
                SettingsCard {
                    ForEach(catalog.investors) { investor in
                        SettingsToggleRow(
                            title: investor.title,
                            subtitle: investor.snapshot == nil ? L10n.text("暂无数据") : investor.displayName,
                            isOn: selectionBinding(for: investor.id)
                        )
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("public-investor-\(investor.id)")
                    }
                }
                SettingsFootnote(L10n.text("可选择多个。选择后会取消测试数据。"))
            case .failure:
                SettingsFootnote(L10n.text("账户数据暂时无法读取。"))
            }
        }
    }

    private func selectionBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: {
                id == PublicInvestorPreferences.demoID
                    ? PublicInvestorPreferences.isDemo(selection)
                    : PublicInvestorPreferences.selectedIDs(selection).contains(id)
            },
            set: { select(id, enabled: $0) }
        )
    }

    /// Applies the switch's requested state, not a second toggle of that state.
    private func select(_ id: String, enabled: Bool) {
        let next = PublicInvestorPreferences.setting(id, isSelected: enabled, in: selection)
        guard next != selection else { return }
        selection = next
        model.setPortfolioMode(enabled: !next.isEmpty, selection: next)
    }
}

/// The invented portfolio, named where the reader chooses it.
enum PublicInvestorDemo {
    static var title: String { L10n.text("测试数据") }
    static var subtitle: String { L10n.text("合成组合，非真实持仓") }
}

/// Names whose portfolio is on screen.
///
/// Shared so the settings row and the home header cannot drift: a header
/// still reading "CATFOLIO" over someone else's holdings is the specific
/// confusion this exists to prevent.
enum PublicInvestorNaming {
    /// Nil when the reader is looking at their own portfolio.
    static func title(selection: String, isDemo: Bool, isInvestorMode: Bool) -> String? {
        if isDemo { return PublicInvestorDemo.title }
        guard isInvestorMode, case .success(let catalog) = PublicInvestorCatalog.loaded else { return nil }
        let chosen = PublicInvestorPreferences.selectedIDs(selection)
        let names = catalog.investors.filter { chosen.contains($0.id) }
        switch names.count {
        case 0: return nil
        case 1: return names[0].title
        // Two names fit; beyond that the header would be longer than the
        // figure it labels.
        case 2: return names.map(\.title).joined(separator: L10n.text(" · "))
        default: return L10n.text("已选 \(names.count) 个")
        }
    }
}
