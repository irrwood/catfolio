import SwiftUI

/// Each stage is a native destination in the caller's stack. Form state stays
/// in the connector above these pages, so a completed or cancelled swipe does
/// not discard the credentials the reader has already typed.
struct AccountFlowPage<Content: View, Next: View>: View {
    @Environment(\.accountFlowTheme) private var theme
    @Environment(\.hasSharedOnboardingBackground) private var sharedBackground
    @Environment(\.usesPaywallOnboardingStyle) private var paywallStyle
    @Environment(\.isServiceAPISetupGuide) private var firstLaunch
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var showsNext: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let next: () -> Next

    var body: some View {
        content
            .navigationTransition(.automatic)
            .navigationBarBackButtonHidden(false)
            .navigationDestination(isPresented: $showsNext) {
                next()
                    .environment(\.accountFlowTheme, theme)
                    .environment(\.hasSharedOnboardingBackground, sharedBackground)
                    .environment(\.usesPaywallOnboardingStyle, paywallStyle)
                    .environment(\.isServiceAPISetupGuide, firstLaunch)
                    .tint(theme?.controlTint ?? CatfolioTheme.accent)
            }
            // Apply the animation at the navigation boundary, including stages
            // advanced by an asynchronous broker response or a programmatic back.
            .animation(reduceMotion ? nil : .default, value: showsNext)
    }
}
