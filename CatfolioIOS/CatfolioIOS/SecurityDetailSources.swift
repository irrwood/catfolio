import SwiftUI
import UIKit

/// Weak references to the visible row and logos used by the security page's open.
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
    private let pageLogos = NSHashTable<UIView>.weakObjects()

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

    func registerPageLogo(_ marker: UIView) { pageLogos.add(marker) }
    func unregisterPageLogo(_ marker: UIView) { pageLogos.remove(marker) }

    private func pageLogo(in container: UIView?) -> UIView? {
        guard let container else { return nil }
        return pageLogos.allObjects.first { $0.isDescendant(of: container) && $0.bounds.width > 1 }
    }

    /// The source's frame in its window, if it is on screen now.
    private func liveFrame(for key: SourceKey) -> (view: UIView, frame: CGRect)? {
        guard let marker = sources[key]?.view, let window = marker.window,
              !Self.isHiddenInHierarchy(marker) else { return nil }
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

    /// Where the header's logo sits in a page, if the page has laid it out.
    func pageLogoFrame(in page: UIView) -> CGRect? {
        pageLogo(in: page).map { $0.convert($0.bounds, to: page) }
    }

    private static func isHiddenInHierarchy(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden || candidate.alpha < 0.01 { return true }
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

/// Marks a logo that flies with the security page: a list row's logo (with
/// the row's key), or the page header's own, where the flight lands.
struct SecurityDetailLogoMarker: UIViewRepresentable {
    enum Role: Equatable {
        case source(SecurityDetailSources.SourceKey)
        case page
    }

    let role: Role

    func makeUIView(context: Context) -> MarkerView { MarkerView() }

    func updateUIView(_ view: MarkerView, context: Context) {
        view.role = role
    }

    static func dismantleUIView(_ view: MarkerView, coordinator: ()) {
        view.unregister()
    }

    final class MarkerView: UIView {
        var role: Role? {
            didSet {
                guard role != oldValue else { return }
                unregister(oldValue)
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
            guard window != nil, let role else { return }
            switch role {
            case .source(let key): SecurityDetailSources.shared.registerLogo(self, for: key)
            case .page: SecurityDetailSources.shared.registerPageLogo(self)
            }
        }

        func unregister(_ role: Role? = nil) {
            switch role ?? self.role {
            case .source(let key): SecurityDetailSources.shared.unregisterLogo(self, for: key)
            case .page: SecurityDetailSources.shared.unregisterPageLogo(self)
            case nil: break
            }
        }
    }
}

extension View {
    /// A list logo the security page's logo flies out of and back into.
    @ViewBuilder
    func securityDetailLogoSource(_ id: String, in namespace: Namespace.ID?) -> some View {
        if let namespace {
            background {
                SecurityDetailLogoMarker(role: .source(.init(id: AnyHashable(id), namespace: namespace)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            self
        }
    }

    /// The security page header's logo, where a flying logo lands.
    func securityDetailLogoTarget() -> some View {
        background {
            SecurityDetailLogoMarker(role: .page)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
