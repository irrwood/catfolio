import SwiftUI

/// A shared, keyboard-aware shell for welcome, connection instructions and keys.
/// Only the content scrolls; the primary action always has reserved space below it.
struct OnboardingPage<Content: View, Actions: View>: View {
    var scrollReset: AnyHashable = 0
    var progress: OnboardingProgress? = nil
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                content
            }
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, progress == nil ? 44 : 24)
            .padding(.bottom, 32)
        }
        // A new step starts at the scroll view's natural safe-area inset.
        // Scrolling an inner marker to .top can pull it under the navigation bar.
        // Ordinary form edits and scene changes keep the same identity.
        .id(scrollReset)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .top, spacing: 0) {
            if let progress {
                OnboardingStepIndicator(progress: progress)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .systemBackground))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) { actions }
                .buttonStyle(OnboardingSecondaryButtonStyle())
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
                .accessibilityIdentifier("onboarding-actions")
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .foregroundStyle(CatfolioTheme.primaryText)
        .tint(CatfolioTheme.primaryText)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

struct OnboardingProgress {
    let step: Int
    let total: Int
}

/// One segment per page in this flow, filled through the current step.
struct OnboardingStepIndicator: View {
    let progress: OnboardingProgress

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<progress.total, id: \.self) { index in
                Capsule()
                    .fill(CatfolioTheme.primaryText.opacity(index < progress.step ? 1 : 0.12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 4)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.text("第 \(progress.step) 步，共 \(progress.total) 步"))
        .accessibilityIdentifier("onboarding-progress")
    }
}

struct OnboardingHeader: View {
    let title: String
    var subtitle: String? = nil
    var eyebrow: String? = nil

    var body: some View {
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .appText(.subheading, weight: .semibold)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .background(CatfolioTheme.primaryText, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.3)
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
    let title: String
    var isDisabled = false
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isBusy { ProgressView().tint(Color(uiColor: .systemBackground)) }
                Text(title)
            }
        }
        .buttonStyle(OnboardingPrimaryButtonStyle())
        .disabled(isDisabled || isBusy)
    }
}
