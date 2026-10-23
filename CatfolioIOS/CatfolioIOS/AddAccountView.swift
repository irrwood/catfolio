import SwiftUI
import UIKit

/// Account creation is pushed into the caller's navigation stack. The catalog,
/// connector and optional help pages share native back and edge-swipe behavior.
struct AddAccountView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var navigation: AddAccountNavigation
    @State private var hasAppeared = false
    @State private var isReadyForCreation = false
    private let setupStore: Trading212SetupStore

    init(setupStore: Trading212SetupStore = .shared, navigation: AddAccountNavigation? = nil,
         initialProvider: AddAccountProvider? = nil) {
        self.setupStore = setupStore
        let route = navigation ?? AddAccountNavigation(resumesTrading212: setupStore.shouldResumeCreation)
        if let initialProvider { route.select(initialProvider) }
        _navigation = State(initialValue: route)
    }

    var body: some View {
        SettingsPage(bottomInset: 32, topInset: SettingsTemplate.pageInset) {
            AddAccountOptions { navigation.select($0) }
                .disabled(!isReadyForCreation)
            SettingsFootnote(L10n.text("选择券商，按照步骤完成连接；详细教程在连接页右上角。"))
        }
        .navigationTitle(L10n.text("添加账户"))
        .navigationTransition(.automatic)
        .navigationBarTitleDisplayMode(.inline)
        .background(AccountCatalogAppearance {
            if !hasAppeared { hasAppeared = true }
        }.frame(width: 0, height: 0).accessibilityHidden(true))
        .navigationDestination(isPresented: Binding(
            get: { hasAppeared && isReadyForCreation && !navigation.path.isEmpty },
            set: { if hasAppeared && isReadyForCreation && !$0 { navigation.path = [] } }
        )) {
            if let provider = navigation.path.last {
                // Pass the stack context at the destination boundary as well.
                AddAccountDestination(provider: provider, setupStore: setupStore, setupNavigation: navigation.setup)
                    .environment(\.accountFlowClose, {
                        setupStore.setCreationPresented(false)
                        dismiss()
                    })
            }
        }
        .animation(reduceMotion ? nil : .default, value: navigation.path)
        .task {
            await model.prepareForAccountCreation()
            guard !Task.isCancelled else { return }
            isReadyForCreation = true
        }
        .tint(navigation.path.last?.flowTheme.controlTint ?? CatfolioTheme.accent)
        .onChange(of: navigation.path, initial: true) { _, path in
            setupStore.setCreationPresented(path.last == .trading212)
        }
        .onDisappear {
            // Pushing a connector also hides the catalog. Only leaving the
            // catalog itself clears its resume state; backgrounding keeps it.
            if scenePhase == .active && navigation.path.isEmpty {
                setupStore.setCreationPresented(false)
            }
        }
    }
}

/// Both entry points use the same catalog and connector destinations.
struct AddAccountDestination: View {
    let provider: AddAccountProvider
    var setupStore: Trading212SetupStore = .shared
    var isFirstLaunchSetup = false
    var setupNavigation: AccountSetupNavigation? = nil

    @ViewBuilder var body: some View {
        switch provider {
        case .trading212:
            Trading212View(context: .create, setupStore: setupStore, isFirstLaunchSetup: isFirstLaunchSetup, setupNavigation: setupNavigation)
        case .longbridge: DirectBrokerAccountView(broker: .longbridge, context: .create, isFirstLaunchSetup: isFirstLaunchSetup, setupNavigation: setupNavigation ?? AccountSetupNavigation())
        case .alpaca: DirectBrokerAccountView(broker: .alpaca, context: .create, isFirstLaunchSetup: isFirstLaunchSetup, setupNavigation: setupNavigation ?? AccountSetupNavigation())
        case .ibkr: IBKRFlexView(context: .create, isFirstLaunchSetup: isFirstLaunchSetup, setupNavigation: setupNavigation)
        case .moomoo: MoomooOAuthView(context: .create, isFirstLaunchSetup: isFirstLaunchSetup)
        case .robinhood: RobinhoodConnectionView(context: .create, isFirstLaunchSetup: isFirstLaunchSetup)
        case .snaptrade: SnapTradeView(context: .create, isFirstLaunchSetup: isFirstLaunchSetup, setupNavigation: setupNavigation ?? AccountSetupNavigation())
        case .csv: CSVImportView(context: .create, isFirstLaunchSetup: isFirstLaunchSetup)
        case .screenshot: ScreenshotImportView(context: .create, isFirstLaunchSetup: isFirstLaunchSetup)
        }
    }
}

@MainActor @Observable
final class AddAccountNavigation {
    var path: [AddAccountProvider]
    var setup = AccountSetupNavigation()

    init(resumesTrading212: Bool = false) {
        path = resumesTrading212 ? [.trading212] : []
    }

    func select(_ provider: AddAccountProvider) {
        setup = AccountSetupNavigation()
        path = [provider]
    }
}

private struct AccountFlowCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// Set inside 添加账户: returns to the page that opened the catalog.
    /// A provider would otherwise only pop itself with `dismiss`.
    var accountFlowClose: (() -> Void)? {
        get { self[AccountFlowCloseKey.self] }
        set { self[AccountFlowCloseKey.self] = newValue }
    }
}

/// Standalone management sheets own a stack. Pushed creation pages reuse the
/// catalog or first-launch stack so native back and swipe gestures stay intact.
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

/// Restoring a connector waits for the catalog's native push to finish. Starting
/// both pushes during a TabView's initial layout causes repeated layout invalidation.
private struct AccountCatalogAppearance: UIViewControllerRepresentable {
    let appeared: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(appeared: appeared) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.appeared = appeared }

    final class Controller: UIViewController {
        var appeared: () -> Void
        init(appeared: @escaping () -> Void) { self.appeared = appeared; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() {
            view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            DispatchQueue.main.async { [weak self] in self?.appeared() }
        }
    }
}
