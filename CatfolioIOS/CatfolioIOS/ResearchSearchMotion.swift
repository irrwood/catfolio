import UIKit

/// Finger distance and visual travel are deliberately different: the field
/// has room to follow a long pull, with steadily increasing resistance.
enum ResearchSearchPullGeometry {
    static let threshold: CGFloat = 150
    static let maximumTravel: CGFloat = 240

    static func translation(for distance: CGFloat) -> CGFloat {
        let resisted = max(0, distance) * 0.82
        return maximumTravel * resisted / (maximumTravel + resisted)
    }

    static func scale(for distance: CGFloat) -> CGFloat {
        1 - 0.035 * min(1, max(0, distance) / 32)
    }
}

/// Update the native field directly while tracking the finger; neither the
/// dashboard nor the search results need a SwiftUI render on every move.
@MainActor
final class ResearchSearchMotion {
    weak var field: UIView?
    var reduceMotion = false
    private var generation = 0
    private var isFinishing = false

    func pull(_ distance: CGFloat) {
        guard !reduceMotion, !isFinishing else { return }
        generation &+= 1
        field?.layer.removeAllAnimations()
        let scale = ResearchSearchPullGeometry.scale(for: distance)
        field?.transform = CGAffineTransform(translationX: 0,
            y: ResearchSearchPullGeometry.translation(for: distance)).scaledBy(x: scale, y: scale)
    }

    func cancelPull() {
        guard !isFinishing else { return }
        settle(delay: 0, completion: {})
    }

    /// Hand the held transform to the positioning controller immediately.
    /// Its closing flight restores the page and the field together, without
    /// first settling the field back into the active toolbar.
    func finishPull(completion: @escaping () -> Void) {
        guard !isFinishing else { return }
        isFinishing = true
        generation &+= 1
        field?.endEditing(true)
        completion()
    }

    /// Ending the SwiftUI presentation must not reset the held geometry
    /// before UIKit can animate it into the field's original content slot.
    func presentationEnded() {
        isFinishing = false
        generation &+= 1
    }

    func reset() {
        presentationEnded()
        field?.layer.removeAllAnimations()
        field?.transform = .identity
        field?.isUserInteractionEnabled = true
    }

    private func settle(delay: TimeInterval, completion: @escaping () -> Void) {
        generation &+= 1
        let request = generation
        guard !reduceMotion else {
            field?.transform = .identity
            field?.isUserInteractionEnabled = true
            completion()
            return
        }
        UIView.animate(withDuration: 0.36, delay: delay, usingSpringWithDamping: 0.84,
                       initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.field?.transform = .identity
        } completion: { _ in
            guard self.generation == request else { return }
            self.field?.isUserInteractionEnabled = true
            completion()
        }
    }
}
