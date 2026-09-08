import SwiftUI

@main
struct CatfolioIOSApp: App {
    @State private var model = AppModel()
    @AppStorage(AppLanguage.preferenceKey) private var languageRawValue = AppLanguage.system.rawValue
    @AppStorage(AppAppearance.preferenceKey) private var appearanceRawValue = AppAppearance.system.rawValue

    private var preferredColorScheme: ColorScheme? {
        (AppAppearance(rawValue: appearanceRawValue) ?? .system).preferredColorScheme
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .fontDesign(.rounded)
                .task { ReferenceCatalogs.warm() }
                .task { CloudPreferences.start() }
                .task { PublicInvestorPreferences.migrateDemoSelectionIfNeeded() }
                .environment(model)
                .environment(\.locale, Locale(identifier: AppLanguage.resolvedIdentifier(languageRawValue)))
                .tint(CatfolioTheme.accent)
                .preferredColorScheme(preferredColorScheme)
                #if DEBUG
                .task {
                    if ProcessInfo.processInfo.arguments.contains("--run-foundation-checks") {
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
}
