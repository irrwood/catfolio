import UIKit

/// UIKit still drives the interactive zoom and its cancellation. Only decide
/// who owns the gesture: a held chart, or the page's normal dismissal.
@MainActor
enum SecurityDetailDismissal {
    static func shouldBegin(in page: UIView, velocity: CGVector, systemAllows: Bool) -> Bool {
        guard !ChartInteractionOverlay.isInspecting(in: page) else { return false }
        // A clearly rightward swipe works at any scroll position. Keep the
        // system's rules for vertical pulls, pinches and other directions.
        let swipesRight = velocity.dx > 0 && velocity.dx > abs(velocity.dy) * 1.2
        return systemAllows || swipesRight
    }
}
