import SwiftUI
import UIKit
import Observation

/// `EnvironmentValues.refresh` is read-only. A detail reached from a refreshed
/// list (including nested heatmap sheets) can inherit its UIRefreshControl even
/// though the detail has no refresh action of its own. Remove only that native
/// control; UIKit still owns scrolling, rubber-banding and sheet dismissal.
struct HoldingDetailScrollBoundary: UIViewRepresentable {
    func makeUIView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: BoundaryView, context: Context) {
        view.removeInheritedRefreshControl()
        // SwiftUI can recreate its inherited control later in this same
        // update even when the content size does not require another layout.
        DispatchQueue.main.async { [weak view] in view?.removeInheritedRefreshControl() }
    }

    final class BoundaryView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                refreshObservation = nil
                observedScrollView = nil
            }
            removeInheritedRefreshControl()
            // SwiftUI may install its refresh control after attaching content.
            DispatchQueue.main.async { [weak self] in self?.removeInheritedRefreshControl() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            removeInheritedRefreshControl()
        }

        private var refreshObservation: NSKeyValueObservation?
        private weak var observedScrollView: UIScrollView?
        func removeInheritedRefreshControl() {
            // Found once: this runs on every layout pass, and the scroll view
            // around the page does not change while the page is up.
            if let scrollView = observedScrollView, window != nil {
                if scrollView.refreshControl != nil { scrollView.refreshControl = nil }
                return
            }
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    if scrollView.refreshControl != nil {
                        scrollView.refreshControl = nil
                    }
                    if observedScrollView !== scrollView {
                        observedScrollView = scrollView
                        // SwiftUI can restore inherited refresh when a child sheet opens.
                        refreshObservation = scrollView.observe(\.refreshControl, options: [.new]) { scroll, _ in
                            if scroll.refreshControl != nil { scroll.refreshControl = nil }
                        }
                    }
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

struct HoldingHeaderActionLabel: View {
    let title: String
    let asset: String
    var isLoading = false
    var body: some View {
        HStack(spacing: 8) {
            if isLoading { ChartSkeletonShape(width: 18, height: 18, cornerRadius: 9).frame(width: 24, height: 24).chartLoadingShimmer() }
            else { Image(asset).resizable().scaledToFit().frame(width: 24, height: 24) }
            Text(title).appText(.footnote, weight: .medium).lineLimit(1).minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Capsule())
    }
}

struct HoldingDetailCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(CatfolioTheme.primaryText)
                .frame(width: 48, height: 48)
                .background {
                    // Glass is decoration inside the label, never a separate
                    // interactive layer around the close button.
                    Group {
                        if #available(iOS 26.0, *) {
                            Circle().fill(.clear)
                                .glassEffect(.regular.tint(Color.primary.opacity(0.06)), in: Circle())
                        } else {
                            Circle().fill(.regularMaterial)
                        }
                    }
                    .allowsHitTesting(false)
                }
                // A plain image button otherwise only hits the glyph. Make
                // the whole visible circle respond, including its empty center.
                .contentShape(.interaction, Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text("关闭"))
        .accessibilityIdentifier("holding-detail-close")
    }
}

struct HoldingHeaderButtonStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.plain).foregroundStyle(CatfolioTheme.primaryText)
                .glassEffect(.regular.tint(Color.primary.opacity(0.06)).interactive(), in: Capsule())
        } else {
            content.buttonStyle(.plain).foregroundStyle(CatfolioTheme.primaryText)
                .background(.regularMaterial, in: Capsule())
        }
    }
}
