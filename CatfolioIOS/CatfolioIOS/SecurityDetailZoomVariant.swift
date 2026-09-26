import SwiftUI

/// The native-zoom control for the security page, for measuring against A
/// (`SecurityDetailSnapshotTransition`) with the transition as the only
/// variable. Nothing here is used unless the flag is on, so A is untouched.
///
///     --security-detail-native-zoom
///
/// The transition itself is the two modifiers below. Everything A does by hand
/// — the flight, the hand-off, the backdrop, the edge pan — is what the system
/// already does for a matched source, and none of it is attached here.
enum SecurityDetailNativeZoom {
    static let launchArgument = "--security-detail-native-zoom"
    static let preferenceKey = "securityDetail.nativeZoom"

    static var isEnabled: Bool {
        // `ProcessInfo`, not `LaunchArguments`: the comparison runs in Release,
        // where `LaunchArguments` answers no to everything by design. Opt-in
        // only, so a shipped app cannot be talked into this path.
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }
}

extension View {
    /// The row the page grows out of. The namespace is optional because this
    /// card is also built where the page is presented without a zoom.
    @ViewBuilder
    func securityDetailNativeZoomSource(_ id: some Hashable,
                                        in namespace: Namespace.ID?,
                                        enabled: Bool) -> some View {
        if enabled, let namespace {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// The page itself. No opening card, no snapshot, no hand-off.
    @ViewBuilder
    func securityDetailNativeZoomDestination(_ id: some Hashable,
                                             in namespace: Namespace.ID,
                                             enabled: Bool) -> some View {
        if enabled {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}
