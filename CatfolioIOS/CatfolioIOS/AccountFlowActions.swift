import SwiftUI

/// The scroll view reserves this space, including when the keyboard appears.
/// Actions stay reachable without covering the last fields or preview rows.
struct AccountFlowActions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 12) { content }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, SettingsTemplate.pageInset)
            .padding(.vertical, 16)
            .background(.regularMaterial)
            .accessibilityIdentifier("account-flow-actions")
    }
}

extension View {
    func accountFlowActions<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) { AccountFlowActions(content: actions) }
    }
}
