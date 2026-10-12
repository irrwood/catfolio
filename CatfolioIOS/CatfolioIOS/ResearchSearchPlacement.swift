import SwiftUI
import UIKit

/// The scroll content reserves the field's normal position. UIKit moves one
/// live field above the page, so crossing into the toolbar never swaps inputs.
@MainActor
final class ResearchSearchPlacement {
    weak var slot: UIView?
    var onLayout: (() -> Void)?
}

private struct ResearchSearchPlacementKey: EnvironmentKey {
    static let defaultValue: ResearchSearchPlacement? = nil
}

extension EnvironmentValues {
    var researchSearchPlacement: ResearchSearchPlacement? {
        get { self[ResearchSearchPlacementKey.self] }
        set { self[ResearchSearchPlacementKey.self] = newValue }
    }
}

struct ResearchSearchSlot: View {
    @Environment(\.researchSearchPlacement) private var placement

    var body: some View {
        if let placement {
            Anchor(placement: placement)
                .frame(height: 44)
                .accessibilityHidden(true)
        }
    }

    private struct Anchor: UIViewRepresentable {
        let placement: ResearchSearchPlacement

        func makeUIView(context: Context) -> Slot {
            let view = Slot()
            view.isUserInteractionEnabled = false
            view.placement = placement
            placement.slot = view
            return view
        }

        func updateUIView(_ view: Slot, context: Context) { view.setNeedsLayout() }

        final class Slot: UIView {
            weak var placement: ResearchSearchPlacement?
            override func layoutSubviews() {
                super.layoutSubviews()
                placement?.onLayout?()
            }
            override func didMoveToWindow() {
                super.didMoveToWindow()
                placement?.onLayout?()
            }
        }
    }
}

@available(iOS 26.0, *)
extension ResearchToolbarSearch {
    final class PositionController: UIViewController {
        let field = Field()
        let placement: ResearchSearchPlacement
        var onResultsInset: (CGFloat) -> Void = { _ in }
        private weak var scroll: UIScrollView?
        private var scrollObservation: NSKeyValueObservation?
        private var barObservation: NSKeyValueObservation?
        private var isVisible = false
        private var lastResultsInset: CGFloat?

        init(placement: ResearchSearchPlacement) {
            self.placement = placement
            super.init(nibName: nil, bundle: nil)
            placement.onLayout = { [weak self] in self?.layoutSearch() }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            layoutSearch()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            layoutSearch()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            isVisible = false
            field.endEditing(true)
            field.removeFromSuperview()
        }

        func detach() {
            isVisible = false
            field.removeFromSuperview()
            scrollObservation = nil
            barObservation = nil
            placement.onLayout = nil
        }

        func layoutSearch() {
            guard isVisible, let navigation = navigationController,
                  let slot = placement.slot, slot.window != nil,
                  slot.window === navigation.view.window else { return }
            let container = navigation.view!
            if field.superview !== container {
                container.addSubview(field)
            }
            observeScroll(from: slot, navigation: navigation)
            let natural = slot.convert(slot.bounds, to: container)
            let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: container)
            // The first row remains below the large title. Only an upward
            // scroll can carry it into the compact navigation row.
            field.frame = CGRect(x: natural.minX, y: max(natural.minY, bar.minY),
                                 width: natural.width, height: 44)
            field.layoutIfNeeded()
            let inset = max(0, field.frame.maxY + SettingsTemplate.sectionSpacing - bar.maxY)
            if lastResultsInset != inset {
                lastResultsInset = inset
                // Avoid mutating SwiftUI state inside its UIKit layout pass.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isVisible else { return }
                    self.onResultsInset(inset)
                }
            }
        }

        private func observeScroll(from slot: UIView, navigation: UINavigationController) {
            var ancestor = slot.superview
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            guard let current = ancestor as? UIScrollView, current !== scroll else { return }
            scroll = current
            scrollObservation = current.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.layoutSearch() }
            }
            barObservation = navigation.navigationBar.observe(\.frame, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.layoutSearch() }
            }
        }
    }
}
