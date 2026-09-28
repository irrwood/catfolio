import SwiftUI
import UIKit

/// Keeps UIKit's interactive edge-pop transition available on the comparison
/// page, which supplies its own navigation header. Restores the prior delegate
/// after leaving so other pages keep their own navigation policy.
struct ComparisonSwipeBackSupport: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.refreshWhenVisible()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.restore()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        private final class Registration {
            weak var gesture: UIGestureRecognizer?
            weak var delegate: UIGestureRecognizerDelegate?
            let enabled: Bool
            init(_ gesture: UIGestureRecognizer) {
                self.gesture = gesture
                delegate = gesture.delegate
                enabled = gesture.isEnabled
            }
        }
        private var registrations: [Registration] = []
        private var observations: [NSKeyValueObservation] = []
        private var isVisible = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            install()
            refreshWhenVisible()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isVisible = false
            restore()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if isVisible { install() }
        }

        func refreshWhenVisible() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible else { return }
                self.install()
            }
        }

        func install() {
            guard let navigationController else { return }
            var gestures = [navigationController.interactivePopGestureRecognizer].compactMap { $0 }
            if #available(iOS 26.0, *), let contentPop = navigationController.interactiveContentPopGestureRecognizer {
                gestures.append(contentPop)
            }
            for gesture in gestures {
                if !registrations.contains(where: { $0.gesture === gesture }) {
                    registrations.append(Registration(gesture))
                    observations.append(gesture.observe(\.delegate, options: [.new]) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.refreshWhenVisible() }
                    })
                    observations.append(gesture.observe(\.isEnabled, options: [.new]) { [weak self] _, _ in
                        MainActor.assumeIsolated { self?.refreshWhenVisible() }
                    })
                }
                if gesture.delegate !== self { gesture.delegate = self }
                if !gesture.isEnabled { gesture.isEnabled = true }
            }
        }

        func restore() {
            observations.removeAll()
            for registration in registrations {
                guard let gesture = registration.gesture, gesture.delegate === self else { continue }
                gesture.delegate = registration.delegate
                gesture.isEnabled = registration.enabled
            }
            registrations.removeAll()
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let navigationController else { return false }
            if let pan = gestureRecognizer as? UIPanGestureRecognizer {
                let velocity = pan.velocity(in: pan.view)
                if velocity != .zero {
                    let direction: CGFloat = navigationController.view.effectiveUserInterfaceLayoutDirection == .rightToLeft ? -1 : 1
                    guard velocity.x * direction > abs(velocity.y) else { return false }
                }
            }
            return navigationController.viewControllers.count > 1
                && navigationController.transitionCoordinator == nil
        }

        // Do not forward optional callbacks to the hidden-bar delegate: it
        // can reject touches before shouldBegin is ever reached.
    }
}
