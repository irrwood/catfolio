import SwiftUI

@main
struct CatfolioIOSApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(model)
                .tint(CatfolioStyle.blue)
        }
    }
}
