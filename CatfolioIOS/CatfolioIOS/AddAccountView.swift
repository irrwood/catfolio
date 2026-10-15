import SwiftUI

/// One entry for account creation; existing account rows remain management entries.
///
/// One navigation stack, as the system's own add flows are: a provider is
/// pushed onto the list with the native slide, the bar's back button and an
/// edge swipe return to it, and finishing closes the whole sheet.
struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation: AddAccountNavigation
    private let setupStore: Trading212SetupStore

    init(setupStore: Trading212SetupStore = .shared, navigation: AddAccountNavigation? = nil) {
        self.setupStore = setupStore
        _navigation = State(initialValue: navigation ?? AddAccountNavigation(resumesTrading212: setupStore.shouldResumeCreation))
    }

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack(path: $navigation.path) {
            SettingsPage(bottomInset: 32, topInset: SettingsTemplate.pageInset) {
                AddAccountOptions { navigation.select($0) }
                SettingsFootnote(L10n.text("Trading 212 和 IBKR 提供逐步连接教程。已有凭证可以直接填写。"))
            }
            .navigationTitle(L10n.text("添加账户"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if navigation.path.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        AppModalDoneButton { dismiss() }
                    }
                }
            }
            .navigationDestination(for: AddAccountProvider.self) { provider in
                AddAccountDestination(provider: provider, setupStore: setupStore)
            }
        }
        // A pushed provider's 完成 closes the sheet, not just its own page.
        .environment(\.accountFlowClose, { dismiss() })
        .tint(navigation.path.last?.flowTheme.controlTint ?? CatfolioTheme.accent)
        // The navigation path owns whether the flow is open. A destination
        // can temporarily disappear during SwiftUI updates or a cancelled
        // back gesture; that is not a request to close and reopen it.
        .onChange(of: navigation.path, initial: true) { _, path in
            setupStore.setCreationPresented(path.last == .trading212)
        }
        .onDisappear {
            if scenePhase == .active { setupStore.setCreationPresented(false) }
        }
    }

}

/// Both entry points use the same catalog and connector destinations.
struct AddAccountDestination: View {
    let provider: AddAccountProvider
    var setupStore: Trading212SetupStore = .shared
    var isFirstLaunchSetup = false

    @ViewBuilder var body: some View {
        switch provider {
        case .trading212:
            Trading212View(context: .create, setupStore: setupStore, isFirstLaunchSetup: isFirstLaunchSetup)
        case .ibkr: IBKRFlexView(context: .create, isFirstLaunchSetup: isFirstLaunchSetup)
        case .moomoo: MoomooOAuthView(context: .create, isFirstLaunchSetup: isFirstLaunchSetup)
        case .robinhood: RobinhoodConnectionView(context: .create, isFirstLaunchSetup: isFirstLaunchSetup)
        case .snaptrade: SnapTradeView(context: .create, isFirstLaunchSetup: isFirstLaunchSetup)
        case .csv: CSVImportView(context: .create, isFirstLaunchSetup: isFirstLaunchSetup)
        }
    }
}

@MainActor @Observable
final class AddAccountNavigation {
    var path: [AddAccountProvider]

    init(resumesTrading212: Bool = false) {
        path = resumesTrading212 ? [.trading212] : []
    }

    func select(_ provider: AddAccountProvider) {
        path = [provider]
    }
}

private struct AccountFlowCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Set inside 添加账户: closes the whole flow. A provider pushed there
    /// would otherwise only pop itself with `dismiss`.
    var accountFlowClose: (() -> Void)? {
        get { self[AccountFlowCloseKey.self] }
        set { self[AccountFlowCloseKey.self] = newValue }
    }
}

/// A provider's own navigation stack — unless it was pushed onto 添加账户's,
/// where a second stack inside the first would break the push and the back
/// swipe.
struct AccountFlowStack<Content: View>: View {
    @Environment(\.accountFlowClose) private var flowClose
    @ViewBuilder let content: Content

    var body: some View {
        if flowClose != nil {
            content
        } else {
            NavigationStack { content }
        }
    }
}

private struct AccountProviderBackKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Set while a provider was chosen from 添加账户: its first step returns there.
    var accountProviderBack: (() -> Void)? {
        get { self[AccountProviderBackKey.self] }
        set { self[AccountProviderBackKey.self] = newValue }
    }
}

/// The 上一步 a provider's first step shows when opened from 添加账户.
struct AccountProviderBackButton: View {
    @Environment(\.accountProviderBack) private var back

    var body: some View {
        if let back {
            Button(action: back) {
                Label(L10n.text("上一步"), systemImage: "chevron.left")
            }
            .accessibilityIdentifier("account-provider-back")
        }
    }
}
