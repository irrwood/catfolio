#if DEBUG
import UIKit

/// Diagnostic: logs where each touch in the window lands while a security
/// page is up or flying back, next to `SecurityDetailLiveZoom.note`'s lines.
/// Passive — it never recognises, so no touch is delayed or taken.
@MainActor
final class SecurityDetailTouchProbe: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private static weak var installed: SecurityDetailTouchProbe?

    static func install(on window: UIWindow) {
        guard installed?.view !== window else { return }
        let probe = SecurityDetailTouchProbe(target: nil, action: nil)
        probe.cancelsTouchesInView = false
        probe.delaysTouchesBegan = false
        probe.delaysTouchesEnded = false
        probe.delegate = probe
        window.addGestureRecognizer(probe)
        installed = probe
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let window = view as? UIWindow else { return }
        let point = touch.location(in: window)
        let hit = window.hitTest(point, with: event)
        var chain: [String] = []
        var current = hit
        while let v = current, chain.count < 8 {
            chain.append("\(type(of: v))\(v.isUserInteractionEnabled ? "" : "(off)")")
            current = v.superview
        }
        SecurityDetailLiveZoom.note("touch at \(Int(point.x)),\(Int(point.y)) hit \(chain.joined(separator: " < "))")
        state = .failed
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
