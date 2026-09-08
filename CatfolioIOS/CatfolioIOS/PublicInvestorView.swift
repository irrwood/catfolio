import SwiftUI

struct PublicInvestorSettingsSection: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @AppStorage(PublicInvestorPreferences.selectionKey) private var selection = PublicInvestorPreferences.defaultSelection

    var body: some View {
        Section {
            // One switch, not two. Demo data and a public filer's portfolio
            // are the same thing to a reader — a portfolio that is not
            // theirs — and having them as separate toggles meant two ways to
            // leave your own data, each disabling the other.
            Toggle(L10n.text("佩洛西模式"), isOn: Binding(
                get: { model.isPublicInvestorMode || model.isFakeDataMode },
                set: { enabled in Task { await applyMode(enabled: enabled) } }
            ))
            .disabled(model.isPortfolioLoading)
            .accessibilityIdentifier("public-investor-mode")
            .accessibilityHint(L10n.text("开启后显示所选的公开组合或测试数据，你自己的持仓不受影响"))

            NavigationLink {
                PublicInvestorSelectionView()
            } label: {
                LabeledContent(L10n.text("选择人物"), value: selectionSummary)
            }

            if let error = model.fakeDataModeError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(CatfolioTheme.danger)
            }
        } header: {
            Text(L10n.text("账户模式"))
        }
    }

    private var selectionSummary: String {
        if PublicInvestorPreferences.isDemo(selection) { return PublicInvestorDemo.title }
        guard case .success(let catalog) = PublicInvestorCatalog.loaded else { return L10n.text("数据不可用") }
        let names = catalog.investors.filter { PublicInvestorPreferences.selectedIDs(selection).contains($0.id) }
        if names.count == 1 { return names[0].title }
        return names.isEmpty ? L10n.text("未选择") : L10n.text("已选 \(names.count) 个")
    }

    /// Routes one switch to whichever engine the current selection names.
    ///
    /// The two engines stay separate — invented data and disclosed data are
    /// built differently and must not be blended — but the reader chooses a
    /// portfolio, not an engine.
    private func applyMode(enabled: Bool) async {
        guard enabled else {
            await model.setPublicInvestorMode(false)
            await model.setFakeDataMode(false)
            return
        }
        if PublicInvestorPreferences.isDemo(selection) {
            await model.setPublicInvestorMode(false)
            await model.setFakeDataMode(true)
        } else {
            await model.setFakeDataMode(false)
            await model.setPublicInvestorMode(true)
        }
    }
}

struct PublicInvestorSelectionView: View {
    @Environment(\.locale) private var appLocale
    @Environment(AppModel.self) private var model
    @AppStorage(PublicInvestorPreferences.selectionKey) private var selection = PublicInvestorPreferences.defaultSelection

    var body: some View {
        Form {
            // Its own section, above the filers and separated from them: the
            // others are real people's disclosed holdings, this one is not
            // real at all, and the two should never look like entries in one
            // list of investors.
            Section {
                Toggle(isOn: Binding(
                    get: { PublicInvestorPreferences.isDemo(selection) },
                    set: { _ in select(PublicInvestorPreferences.demoID) }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PublicInvestorDemo.title)
                        Text(PublicInvestorDemo.subtitle)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("public-investor-demo")
            } footer: {
                Text(L10n.text("完全虚构的持仓、交易与收益，用于演示和截图。不会与真实数据混合，也不会同步到其他设备。"))
            }

            switch PublicInvestorCatalog.loaded {
            case .success(let catalog):
                Section {
                    ForEach(catalog.investors) { investor in
                        Toggle(isOn: Binding(
                            get: { PublicInvestorPreferences.selectedIDs(selection).contains(investor.id) },
                            set: { _ in select(investor.id) }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(investor.title)
                                Text(investor.snapshot == nil ? L10n.text("暂无数据") : investor.displayName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("public-investor-\(investor.id)")
                    }
                } footer: {
                    Text(L10n.text("可选择多个。选择后会取消测试数据。"))
                }
            case .failure:
                Text(L10n.text("账户数据暂时无法读取。"))
            }
        }
        .scrollContentBackground(.hidden)
        .background(CatfolioTheme.settingsBackground)
        .navigationTitle(L10n.text("选择人物"))
    }

    /// Applies a choice and points the app at the engine that serves it.
    private func select(_ id: String) {
        let next = PublicInvestorPreferences.selecting(id, in: selection)
        guard next != selection else { return }
        selection = next
        Task {
            await model.setPublicInvestorSelection(next)
            if PublicInvestorPreferences.isDemo(next) {
                await model.setPublicInvestorMode(false)
                await model.setFakeDataMode(true)
            } else if next.isEmpty {
                // Nothing chosen means back to the reader's own portfolio.
                await model.setPublicInvestorMode(false)
                await model.setFakeDataMode(false)
            } else {
                await model.setFakeDataMode(false)
                await model.setPublicInvestorMode(true)
            }
        }
    }
}

/// The invented portfolio, named where the reader chooses it.
enum PublicInvestorDemo {
    static var title: String { L10n.text("测试数据 · 测试公司") }
    static var subtitle: String { L10n.text("合成组合，非真实持仓") }
}
