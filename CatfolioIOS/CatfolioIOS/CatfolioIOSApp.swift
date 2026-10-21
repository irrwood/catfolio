import SwiftUI
import CloudKit

@main
struct CatfolioIOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppLanguage.preferenceKey) private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.preferenceKey) private var appearanceRawValue = AppAppearance.system.rawValue

    init() {
        Typography.configureNavigationTitles()
        SimulatedOffline.install()
        _ = NetworkReachability.shared
    }

    private var preferredColorScheme: ColorScheme? {
        (AppAppearance(rawValue: appearanceRawValue) ?? .system).preferredColorScheme
    }

    var body: some Scene {
        WindowGroup {
            if isIsolatedResearchTestHost {
                Color.clear
            } else {
                #if DEBUG
                if LaunchArguments.contains("--preview-valuation-map") {
                    ValuationMapPreview()
                } else {
                    appContent
                }
                #else
                appContent
                #endif
            }
        }
        .commands { CatfolioCommands(model: model) }
    }

    /// Opt-in XCTest host: public-news checks must not start portfolio refresh,
    /// account migration or cloud preferences on a person's physical device.
    private var isIsolatedResearchTestHost: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["CATFOLIO_RESEARCH_TEST_HOST"] == "1"
        #else
        false
        #endif
    }

    private var appContent: some View {
            RootTabView()
                .modifier(ServiceAPIOnboardingPresenter())
                .fontDesign(.rounded)
                .task { ReferenceCatalogs.warm() }
                .onAppear { MacPlatform.configureWindowScenes() }
                .task {
                    if model.isPublicInvestorMode { PublicInvestorCatalogState.shared.loadIfNeeded() }
                }
                .task { CloudPreferences.start() }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    CloudCredentialSync.shared.start()
                    CloudPortfolioSync.shared.start()
                    // Also receives updates when the other device is the only
                    // writer. Foreground polling needs no push entitlement and
                    // naturally stops when this scene goes into the background.
                    while !Task.isCancelled {
                        await CloudCredentialSync.shared.refresh()
                        await CloudPortfolioSync.shared.refresh()
                        do { try await Task.sleep(for: .seconds(60)) }
                        catch { break }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                    CloudCredentialSync.shared.invalidateAccount()
                    CloudPortfolioSync.shared.invalidateAccount()
                    Task {
                        await CloudCredentialSync.shared.refresh()
                        await CloudPortfolioSync.shared.refresh()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .cloudPortfolioDidReceive)) { _ in
                    Task {
                        await model.reloadPortfolioAfterSync()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { CloudPreferences.shared.refresh() }
                }
                .task { PublicInvestorPreferences.migrateDemoSelectionIfNeeded() }
                .environment(model)
                .environment(\.locale, Locale(identifier: AppLanguage.resolvedIdentifier(languageRawValue)))
                .tint(CatfolioTheme.accent)
                .preferredColorScheme(preferredColorScheme)
                .allowedDynamicRange(.standard)
                #if DEBUG
                .task {
                    if LaunchArguments.contains("--run-foundation-checks") {
                        let report = await Task.detached {
                            do { return try FoundationRegressionChecks.run() }
                            catch { return "FAILED: \(error.localizedDescription)" }
                        }.value
                        let path = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("foundation-regression.txt")
                        try? Data(report.utf8).write(to: path, options: .atomic)
                    }
                }
                #endif
    }
}
