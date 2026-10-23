import SwiftUI

/// A shared, keyboard-aware shell for welcome, connection instructions and keys.
/// The footer has its own layout space; scrolling fields stop above the action,
/// including while the keyboard reduces the available height.
struct OnboardingPage<Content: View, Actions: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.hasSharedOnboardingBackground) private var sharedBackground
    @Environment(\.usesPaywallOnboardingStyle) private var paywallStyle
    @Environment(\.accountFlowTheme) private var accountTheme
    @Environment(\.isServiceAPISetupGuide) private var isFirstLaunchGuide
    var scrollReset: AnyHashable = 0
    var progress: OnboardingProgress? = nil
    var isAccountPreparation = false
    var showsActions = true
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        Group {
            if accountTheme != nil && !paywallStyle {
                AccountFlowForeground { pageContent }
            } else {
                pageContent
            }
        }
        // Lists without a footer scroll to the screen edge. Their content
        // padding still leaves room below the last item; keyboard avoidance stays on.
        .ignoresSafeArea(.container, edges: showsActions ? [] : .bottom)
        .background {
            if let accountTheme, !paywallStyle {
                AccountFlowBackdrop(theme: accountTheme, isPreparation: isAccountPreparation,
                                    sharedBackground: sharedBackground)
                    .ignoresSafeArea()
                if sharedBackground {
                    FirstLaunchNavigationBackdropAnchor().frame(width: 0, height: 0)
                }
            } else if sharedBackground {
                FirstLaunchNavigationBackdropAnchor().frame(width: 0, height: 0)
            } else if paywallStyle {
                FirstLaunchBackground(stage: .welcome).ignoresSafeArea()
            } else {
                pageBackground.ignoresSafeArea()
            }
        }
        .foregroundStyle(paywallStyle ? .white : CatfolioTheme.primaryText)
        .tint(paywallStyle ? .white : (accountTheme?.controlTint ?? CatfolioTheme.primaryText))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(paywallStyle ? .dark : nil, for: .navigationBar)
        .toolbar {
            if let progress, isFirstLaunchGuide || accountTheme != nil {
                ToolbarItem(placement: .principal) {
                    OnboardingStepIndicator(progress: progress, isCompact: true)
                        .environment(\.colorScheme, paywallStyle ? .dark : colorScheme)
                }
            }
        }
    }

    private var pageContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: paywallStyle ? 26 : (accountTheme == nil ? 28 : 16)) {
                    content
                }
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, paywallStyle ? 20 : (accountTheme == nil ? 24 : SettingsTemplate.pageInset))
                .padding(.top, accountTheme == nil ? (progress == nil ? 44 : 24) : 0)
                .padding(.bottom, 32)
            }
            // A new step starts at the scroll view's natural safe-area inset.
            // Scrolling an inner marker to .top can pull it under the navigation bar.
            // Ordinary form edits and scene changes keep the same identity.
            .id(scrollReset)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let progress, !isFirstLaunchGuide && accountTheme == nil {
                    OnboardingStepIndicator(progress: progress)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color(uiColor: .systemBackground))
                }
            }

            if showsActions {
                VStack(spacing: 8) { actions }
                    .buttonStyle(OnboardingSecondaryButtonStyle())
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, paywallStyle ? 20 : (accountTheme == nil ? 24 : SettingsTemplate.pageInset))
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                    .background((sharedBackground || paywallStyle || accountTheme != nil ? Color.clear : pageBackground).ignoresSafeArea(edges: .bottom))
                    .accessibilityIdentifier("onboarding-actions")
            }
        }
    }

    private var pageBackground: Color {
        accountTheme == nil ? Color(uiColor: .systemBackground) : CatfolioPalette.accountConnectionBackground
    }
}

struct OnboardingProgress {
    let step: Int
    let total: Int
}

/// One segment per page in this flow, filled through the current step.
struct OnboardingStepIndicator: View {
    @Environment(\.colorScheme) private var colorScheme
    let progress: OnboardingProgress
    var isCompact = false

    var body: some View {
        HStack(spacing: isCompact ? 7 : 6) {
            ForEach(0..<progress.total, id: \.self) { index in
                Capsule()
                    .fill(isCompact
                        ? (index < progress.step ? CatfolioTheme.primaryText : .white.opacity(colorScheme == .dark ? 0.3 : 1))
                        : CatfolioTheme.primaryText.opacity(index < progress.step ? 1 : 0.12))
                    .frame(width: isCompact ? 29 : nil, height: isCompact ? 5 : 4)
                    .frame(maxWidth: isCompact ? nil : .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("第 \(progress.step) 步，共 \(progress.total) 步"))
        .accessibilityIdentifier("onboarding-progress")
    }
}

struct OnboardingHeader: View {
    @Environment(\.usesPaywallOnboardingStyle) private var paywallStyle
    @Environment(\.isServiceAPISetupGuide) private var isFirstLaunchGuide
    let title: String
    var subtitle: String? = nil
    var eyebrow: String? = nil

    var body: some View {
        if isFirstLaunchGuide && paywallStyle {
            FirstLaunchIntroHeader(title: title, subtitle: subtitle)
        } else {
            standardHeader
        }
    }

    private var standardHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let eyebrow {
                Text(eyebrow).appText(.label)
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
            Text(title).appText(.display, weight: .bold)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).appText(.body)
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
    }
}

struct OnboardingFeature: View {
    let symbol: String
    let title: String
    let detail: String
    @ScaledMetric(relativeTo: .title2) private var iconSize = 26

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .frame(width: iconSize + 6, height: iconSize + 6)
                .foregroundStyle(CatfolioTheme.primaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).appText(.subheading, weight: .semibold)
                Text(detail).appText(.body)
                    .foregroundStyle(SettingsTemplate.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accountFlowTheme) private var accountTheme
    var isBusy = false

    func makeBody(configuration: Configuration) -> some View {
        let opacity = isEnabled || isBusy ? (configuration.isPressed ? 0.75 : 1.0) : 0.3
        return configuration.label
            .appText(.subheading, weight: .semibold)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(accountTheme != nil && !isEnabled && !isBusy
                ? CatfolioTheme.primaryText.opacity(0.55)
                : (accountTheme?.onAccent ?? Color(uiColor: .systemBackground)))
            .background((accountTheme?.accent ?? CatfolioTheme.primaryText)
                .opacity(accountTheme == nil ? 1 : opacity), in: Capsule())
            .opacity(accountTheme == nil ? opacity : 1)
            .contentShape(Capsule())
    }
}

private struct OnboardingSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.35)
    }
}

struct OnboardingPrimaryButton: View {
    @Environment(\.accountFlowTheme) private var accountTheme
    let title: String
    var isDisabled = false
    var isBusy = false
    var usesGlass = false
    let action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26.0, *), usesGlass || accountTheme != nil {
                button
                    .appText(.subheading, weight: .medium)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    .tint(accountTheme?.accent ?? CatfolioTheme.accent)
                    .foregroundStyle(accountTheme?.onAccent ?? .white)
            } else {
                button.buttonStyle(OnboardingPrimaryButtonStyle(isBusy: isBusy))
            }
        }
        .disabled(isDisabled || isBusy)
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isBusy { ProgressView().tint(accountTheme?.onAccent ?? Color(uiColor: .systemBackground)) }
                Text(title)
            }
            .frame(maxWidth: usesGlass || accountTheme != nil ? .infinity : nil)
        }
    }
}
