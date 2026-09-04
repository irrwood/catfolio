import SwiftUI

@main
struct CatfolioIOSApp: App {
    @State private var model = AppModel()
    @AppStorage(AppAppearance.preferenceKey) private var appearanceRawValue = AppAppearance.system.rawValue

    private var preferredColorScheme: ColorScheme? {
        (AppAppearance(rawValue: appearanceRawValue) ?? .system).preferredColorScheme
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(model)
                .tint(CatfolioTheme.accent)
                .preferredColorScheme(preferredColorScheme)
        }
    }
}
