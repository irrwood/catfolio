import ImageIO
import Observation
import SwiftUI
import UIKit

/// How a security page is presented, and what it stands on.
///
/// One definition for every place that opens `HoldingDetailView`, because each
/// used to set its own background, corners and indicator, and none of them
/// agreed with the design (Figma `282:2003`).
///
/// The rule the whole thing rests on: the page draws **no background of its
/// own**. The ground is the sheet's `presentationBackground`, which the system
/// clips to the sheet's rounded shape in every frame — at rest, through the
/// zoom morph and while the reader drags it down. A background drawn inside
/// the page is not under that clip the whole time, and every square corner
/// that showed during a drag or a morph was one of those.
enum SecurityDetailPresentation {
    /// The sheet's top corners. The design drew 38, but the moment a back or
    /// dismiss swipe begins, the zoom transition takes the card over at its
    /// own radius of about 50pt, measured on an iPhone 17 Pro recording — so
    /// at 38 the corners jumped outward under the finger. At rest the sheet
    /// now matches what the swipe will use.
    static let cornerRadius: CGFloat = 50

    /// The shade behind an open security page. A 28% black over the white
    /// home page turned it a dirty grey; in light mode it is kept light enough
    /// to read as depth rather than a stain.
    static let backdropColor = UIColor { trait in
        UIColor.black.withAlphaComponent(trait.userInterfaceStyle == .dark ? 0.5 : 0.35)
    }

    /// Shared ground for the security page and its presentation.
    static let uiGround = UIColor { trait in
        trait.userInterfaceStyle == .dark ? .black : .white
    }

    static var ground: Color { Color(uiColor: uiGround) }

    /// The open is confirmed with a click, not a thud — a rigid impact, which
    /// is the crisp one — and at the instant the row is let go, not when the
    /// sheet finishes arriving.
    static let openFeedback = SensoryFeedback.impact(flexibility: .rigid, intensity: 0.8)
}

struct SecurityDetailZoomOriginKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var securityDetailZoomOrigin: Namespace.ID? {
        get { self[SecurityDetailZoomOriginKey.self] }
        set { self[SecurityDetailZoomOriginKey.self] = newValue }
    }
}

extension View {
    /// Presents a security page as a sheet: the designed ground, the designed
    /// corners, no grabber.
    func securityDetailSheet() -> some View {
        // A sheet has no status-bar safe area above the stock header. Keep
        // this inset on the presentation container so content, placeholders
        // and the close overlay move together; full-screen zoom geometry stays intact.
        safeAreaPadding(.top, 16)
            .presentationDetents([.large])
            .environment(\.isAppModal, false)
            // The system coordinates dimming, touch blocking and the slide
            // in both directions, including a cancelled drag to dismiss.
            .presentationBackgroundInteraction(.disabled)
            .presentationDragIndicator(.hidden)
            .presentationCornerRadius(SecurityDetailPresentation.cornerRadius)
            .presentationBackground { SecurityDetailPresentation.ground }
    }

    /// Ground for a full-screen security page without a visible source row.
    func securityDetailFullScreen() -> some View {
        environment(\.isAppModal, false)
            .presentationBackground { SecurityDetailPresentation.ground }
    }

    /// The same ground for a security page pushed onto a navigation stack,
    /// where there is no sheet to carry it.
    func securityDetailPushedBackground() -> some View {
        background(SecurityDetailPresentation.ground.ignoresSafeArea())
    }

    /// Marks the view a zoom grows out of.
    ///
    /// Deliberately without a `clipShape` configuration. That configuration
    /// does not only shape the transition — it clips the source view at rest,
    /// all the time. Clipping every holding row to the sheet's 38pt corner cut
    /// the trailing figures off each row and shaved the corners off each logo
    /// on the home page. The square corners that showed mid-morph came from
    /// the page's own backgrounds, which the sheet's single ground now
    /// replaces; the sources did not need reshaping.
    func catfolioZoomSource(_ id: some Hashable, in namespace: Namespace.ID) -> some View {
        let key = SecurityDetailSources.SourceKey(id: AnyHashable(id), namespace: namespace)
        // Where the row is and whether it is on screen; the zoom itself grows
        // out of the row's logo (`securityDetailLogoSource`) when it has one.
        return background {
            SecurityDetailSourceMarker(key: key)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Clicks when a security page is asked for — in the same run-loop turn
    /// as the tap that set `trigger`, before the sheet starts sliding in.
    /// Nothing fires on the way back: the reader already feels the drag.
    func securityDetailOpenFeedback<ID: Equatable>(trigger: ID?, enabled: Bool) -> some View {
        sensoryFeedback(SecurityDetailPresentation.openFeedback, trigger: trigger) { _, new in
            enabled && new != nil
        }
    }
}
