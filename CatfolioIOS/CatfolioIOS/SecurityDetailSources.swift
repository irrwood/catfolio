import SwiftUI
import UIKit

/// Weak references to the visible row and its logo used by the security page's open.
@MainActor
final class SecurityDetailSources {
    static let shared = SecurityDetailSources()

    struct SourceKey: Hashable {
        let id: AnyHashable
        let namespace: Namespace.ID
    }

    private final class WeakMarker {
        weak var view: UIView?
        init(_ view: UIView) { self.view = view }
    }

    private var sources: [SourceKey: WeakMarker] = [:]
    private var logoSources: [SourceKey: WeakMarker] = [:]

    func register(_ marker: UIView, for key: SourceKey) {
        sources[key] = WeakMarker(marker)
    }

    func unregister(_ marker: UIView, for key: SourceKey) {
        if sources[key]?.view === marker { sources[key] = nil }
    }

    func registerLogo(_ marker: UIView, for key: SourceKey) {
        logoSources[key] = WeakMarker(marker)
    }

    func unregisterLogo(_ marker: UIView, for key: SourceKey) {
        if logoSources[key]?.view === marker { logoSources[key] = nil }
    }

    /// The source's frame in its window, if it is on screen now.
    private func liveFrame(for key: SourceKey) -> (view: UIView, frame: CGRect)? {
        // The marker itself is left out: while its page zooms back into it,
        // the system hides it, and a tap on the row then opens it again.
        guard let marker = sources[key]?.view, let window = marker.window,
              !Self.isHiddenInHierarchy(marker.superview) else { return nil }
        let frame = marker.convert(marker.bounds, to: window)
        guard frame.width > 1, frame.height > 1,
              window.bounds.intersects(frame) else { return nil }
        return (marker, frame)
    }

    /// A list logo's frame in its window, only when it lies inside `row`.
    private func logoFrame(for key: SourceKey, within row: CGRect) -> CGRect? {
        guard let marker = logoSources[key]?.view, let window = marker.window,
              !Self.isHiddenInHierarchy(marker) else { return nil }
        let frame = marker.convert(marker.bounds, to: window)
        return frame.width > 1 && row.insetBy(dx: -1, dy: -1).contains(frame) ? frame : nil
    }

    /// A row on screen and its logo (when the logo sits inside it), for the
    /// live zoom, which zooms out of the row's marker itself.
    func liveSourceViews(for key: SourceKey) -> (row: UIView, logo: UIView?)? {
        guard let (marker, frame) = liveFrame(for: key) else { return nil }
        let logo = logoFrame(for: key, within: frame) == nil ? nil : logoSources[key]?.view
        return (marker, logo)
    }

    /// Hidden, or fully transparent. A row hidden for its page is hidden by
    /// colour (see `SecurityDetailLiveZoomSourceVisibility`) and counts as shown.
    private static func isHiddenInHierarchy(_ view: UIView?) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha <= 0 { return true }
            current = candidate.superview
        }
        return false
    }
}

/// Marks the view a security page opens from, by sitting behind it.
struct SecurityDetailSourceMarker: UIViewRepresentable {
    let key: SecurityDetailSources.SourceKey

    func makeUIView(context: Context) -> MarkerView { MarkerView() }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.key = key
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
        view.unregister()
    }

    final class MarkerView: UIView {
        var key: SecurityDetailSources.SourceKey? {
            didSet {
                guard key != oldValue else { return }
                if let oldValue { SecurityDetailSources.shared.unregister(self, for: oldValue) }
                registerIfVisible()
            }
        }

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { unregister() } else { registerIfVisible() }
        }

        private func registerIfVisible() {
            guard window != nil, let key else { return }
            SecurityDetailSources.shared.register(self, for: key)
        }

        func unregister() {
            guard let key else { return }
            SecurityDetailSources.shared.unregister(self, for: key)
        }
    }
}

/// Marks a list row's logo, which the zoom lines up on the page header's.
struct SecurityDetailLogoMarker: UIViewRepresentable {
    let key: SecurityDetailSources.SourceKey

    func makeUIView(context: Context) -> MarkerView { MarkerView() }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.key = key
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
        view.unregister()
    }

    final class MarkerView: UIView {
        var key: SecurityDetailSources.SourceKey? {
            didSet {
                guard key != oldValue else { return }
                if let oldValue { SecurityDetailSources.shared.unregisterLogo(self, for: oldValue) }
                registerIfVisible()
            }
        }

        init() {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isAccessibilityElement = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { unregister() } else { registerIfVisible() }
        }

        private func registerIfVisible() {
            guard window != nil, let key else { return }
            SecurityDetailSources.shared.registerLogo(self, for: key)
        }

        func unregister() {
            guard let key else { return }
            SecurityDetailSources.shared.unregisterLogo(self, for: key)
        }
    }
}

extension View {
    /// A list logo the security page's zoom lines up on the header's logo.
    @ViewBuilder
    func securityDetailLogoSource(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            background {
                SecurityDetailLogoMarker(key: .init(id: AnyHashable(id), namespace: namespace))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            self
        }
    }
}
