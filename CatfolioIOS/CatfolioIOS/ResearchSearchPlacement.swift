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
        /// Where the page sat before search lifted it, so closing returns
        /// the field and the large title to the same place.
        private var offsetBeforeSearch: CGPoint?
        private var frameBeforeSearch: CGRect?
        private var isReturning = false
        private var flightGeneration = 0

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
            // The page's native large-title expansion has its own layout
            // samples. During closing, the field flies directly to its saved
            // slot instead of following those intermediate positions.
            guard !isReturning else { return }
            let natural = slot.convert(slot.bounds, to: container)
            let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: container)
            // The first row remains below the large title. Only an upward
            // scroll can carry it into the compact navigation row; an open
            // search always holds it there.
            let y = field.isPresented ? bar.minY : max(natural.minY, bar.minY)
            field.setPinned(natural.minY <= bar.minY)
            field.frame = CGRect(x: natural.minX, y: y,
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

        /// Opening flies the field to the navigation row and scrolls the page
        /// with it, so the large title collapses instead of sitting between
        /// the field and the results. Closing flies both back.
        func setPresented(_ presented: Bool) {
            guard presented != field.isPresented else {
                field.setPresented(presented)
                return
            }
            let animated = isVisible && !UIAccessibility.isReduceMotionEnabled
            flightGeneration &+= 1
            let request = flightGeneration
            if presented {
                if !isReturning { frameBeforeSearch = field.frame }
                isReturning = false
            } else {
                isReturning = true
            }
            field.setPresented(presented, animated: animated)
            let flight = {
                if presented {
                    self.liftPage()
                    self.layoutSearch()
                } else {
                    self.lowerPage()
                    if let frame = self.frameBeforeSearch { self.field.frame = frame }
                    self.field.movingContent.transform = .identity
                    self.field.layoutIfNeeded()
                }
                self.navigationController?.view.layoutIfNeeded()
            }
            let finish = { (_: Bool) in
                guard self.flightGeneration == request, !presented else { return }
                self.isReturning = false
                self.frameBeforeSearch = nil
                self.layoutSearch()
            }
            guard animated else { flight(); finish(true); return }
            UIView.animate(withDuration: ResearchToolbarSearch.flightDuration, delay: 0,
                           usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: flight, completion: finish)
        }

        private func liftPage() {
            guard let navigation = navigationController, let slot = placement.slot,
                  slot.window != nil, let scroll else { return }
            let container = navigation.view!
            let natural = slot.convert(slot.bounds, to: container)
            let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: container)
            guard natural.minY - bar.minY > 0.5 else { offsetBeforeSearch = nil; return }
            offsetBeforeSearch = scroll.contentOffset
            align(slot, to: bar.minY, in: scroll, container: container)
        }

        /// Runs inside the field's flight, so the page and the field share
        /// one spring back to where they started.
        private func lowerPage() {
            guard let start = offsetBeforeSearch, let scroll else { return }
            offsetBeforeSearch = nil
            scroll.setContentOffset(start, animated: false)
            guard let container = navigationController?.view,
                  let frame = frameBeforeSearch, let slot = placement.slot else { return }
            align(slot, to: frame.minY, in: scroll, container: container)
        }

        /// Collapsing or expanding the large title changes the scroll inset,
        /// and UIKit keeps the distance scrolled past the top, so a single
        /// offset change lands the page a title's height away from the field.
        /// Settle the bar, then correct by whatever the slot missed.
        private func align(_ slot: UIView, to y: CGFloat, in scroll: UIScrollView, container: UIView) {
            for _ in 0..<3 {
                container.layoutIfNeeded()
                let miss = slot.convert(slot.bounds, to: container).minY - y
                guard abs(miss) > 0.5 else { return }
                let top = -scroll.adjustedContentInset.top
                let bottom = max(top, scroll.contentSize.height - scroll.bounds.height
                    + scroll.adjustedContentInset.bottom)
                let offset = scroll.contentOffset
                let target = min(max(offset.y + miss, top), bottom)
                guard abs(target - offset.y) > 0.5 else { return }
                scroll.setContentOffset(CGPoint(x: offset.x, y: target), animated: false)
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
