import UIKit

/// A decorative close, independent of the controller's presentation lifetime.
/// The real page is dismissed immediately; this picture never receives touches.
@MainActor
final class SecurityDetailQuickClose {
    static let shared = SecurityDetailQuickClose()
    static let duration: TimeInterval = 0.20
    private(set) var overlay: UIView?

    func removeOverlay() {
        overlay?.layer.removeAllAnimations()
        overlay?.removeFromSuperview()
        overlay = nil
    }

    func dismiss(_ controller: UIViewController, completion: @escaping () -> Void = {}) {
        guard controller.presentingViewController != nil, !controller.isBeingDismissed else { return }
        removeOverlay()
        guard let view = controller.view else { return }
        let picture: UIView?
        if !UIAccessibility.isReduceMotionEnabled, let window = view.window,
           let snapshot = view.snapshotView(afterScreenUpdates: false) {
            snapshot.bounds = view.bounds
            snapshot.center = view.superview?.convert(view.center, to: window)
                ?? CGPoint(x: window.bounds.midX, y: window.bounds.midY)
            snapshot.transform = view.transform
            snapshot.layer.cornerRadius = SecurityDetailPresentation.cornerRadius
            snapshot.clipsToBounds = true
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            window.addSubview(snapshot)
            overlay = snapshot
            picture = snapshot
        } else {
            picture = nil
        }
        // No native reverse zoom, spring settling, or deferred row tap.
        controller.preferredTransition = nil
        controller.dismiss(animated: false, completion: completion)
        guard let picture else { return }
        UIView.animate(withDuration: Self.duration, delay: 0, options: [.curveEaseOut]) {
            picture.transform = picture.transform.translatedBy(x: 0, y: 24).scaledBy(x: 0.94, y: 0.94)
            picture.alpha = 0
        } completion: { [weak self, weak picture] _ in
            picture?.removeFromSuperview()
            if self?.overlay === picture { self?.overlay = nil }
        }
    }
}

/// Keeps down/edge swipes cancellable without invoking the system's reverse zoom.
@MainActor
final class SecurityDetailCloseGesture: NSObject, UIGestureRecognizerDelegate {
    private weak var controller: UIViewController?
    private weak var scroll: UIScrollView?
    private var scrollWasEnabled = true
    private var originalTransform = CGAffineTransform.identity
    private var horizontal = false
    private var dragging = false
    private let close: () -> Void

    init(controller: UIViewController, close: @escaping () -> Void) {
        self.controller = controller
        self.close = close
        super.init()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        controller.view.addGestureRecognizer(pan)
    }

    static func shouldFinish(distance: CGFloat, velocity: CGFloat) -> Bool {
        distance >= 64 || (distance >= 12 && velocity >= 650)
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let controller, !controller.isBeingPresented, !controller.isBeingDismissed,
              controller.presentedViewController == nil,
              let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
        let velocity = pan.velocity(in: view)
        let start = pan.location(in: view).x - pan.translation(in: view).x
        horizontal = start <= 32 && velocity.x > abs(velocity.y)
        scroll = Self.pageScroll(in: view)
        if horizontal { return true }
        guard velocity.y > abs(velocity.x) else { return false }
        return scroll.map { $0.contentOffset.y <= -$0.adjustedContentInset.top + 1 } ?? true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other is UIPanGestureRecognizer
    }

    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        guard let view = controller?.view, let window = view.window else { return }
        let translation = pan.translation(in: window)
        let distance = max(0, horizontal ? translation.x : translation.y)
        switch pan.state {
        case .began:
            dragging = true
            originalTransform = view.transform
            scrollWasEnabled = scroll?.isScrollEnabled ?? true
            scroll?.isScrollEnabled = false
        case .changed:
            let scale = UIAccessibility.isReduceMotionEnabled ? 1 : 1 - min(distance / 1000, 0.08)
            view.transform = originalTransform
                .translatedBy(x: horizontal ? distance : 0, y: horizontal ? 0 : distance)
                .scaledBy(x: scale, y: scale)
        case .ended, .cancelled, .failed:
            guard dragging else { return }
            dragging = false
            scroll?.isScrollEnabled = scrollWasEnabled
            let velocity = pan.velocity(in: window)
            if pan.state == .ended,
               Self.shouldFinish(distance: distance, velocity: horizontal ? velocity.x : velocity.y) {
                close()
            } else {
                UIView.animate(withDuration: 0.16, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
                    view.transform = self.originalTransform
                }
            }
        default: break
        }
    }

    private static func pageScroll(in root: UIView) -> UIScrollView? {
        var queue = [root]
        var index = 0
        while index < queue.count, index < 400 {
            let view = queue[index]
            index += 1
            if let scroll = view as? UIScrollView, scroll.bounds.height > root.bounds.height * 0.5 {
                return scroll
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
