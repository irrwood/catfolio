import UIKit
import XCTest

@MainActor
enum NativeToolbarTestSupport {
    struct Button {
        let item: UIBarButtonItem
        let view: UIView

        func tap() throws {
            XCTAssertTrue(item.isEnabled)
            if let action = item.action {
                XCTAssertTrue(UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil))
            } else {
                try XCTUnwrap(view as? UIControl).sendActions(for: .touchUpInside)
            }
        }
    }

    static func button(in navigation: UINavigationController, leading: Bool,
                       identifier: String) async throws -> Button {
        let window = try XCTUnwrap(navigation.view.window)
        let navigationItem = try XCTUnwrap(navigation.topViewController?.navigationItem)
        let items = leading ? navigationItem.leftBarButtonItems : navigationItem.rightBarButtonItems
        let groups = leading ? navigationItem.leadingItemGroups : navigationItem.trailingItemGroups
        let candidates = (items ?? []) + groups.flatMap(\.barButtonItems)
        let item = try XCTUnwrap(candidates.first { $0.accessibilityIdentifier == identifier } ?? candidates.first)

        // Native toolbar transitions can outlast a fixed delay. On iOS 27 the
        // bar's UIView may also omit the SwiftUI accessibility identifier.
        for _ in 0..<60 {
            let views = descendants(navigation.navigationBar)
            let candidates = views.filter { $0.accessibilityIdentifier == identifier }
                + [item.customView].compactMap { $0 }
                + views.filter { $0 is UIControl || $0 is UIImageView }
            for view in candidates {
                let frame = view.convert(view.bounds, to: window)
                guard visible(view, in: window), frame.width >= 12, frame.height >= 10,
                      leading ? frame.midX < window.bounds.midX : frame.midX > window.bounds.midX,
                      let hit = window.hitTest(CGPoint(x: frame.midX, y: frame.midY), with: nil),
                      hit === view || hit.isDescendant(of: view)
                        || (view.isDescendant(of: hit) && hit.bounds.width <= 80) else { continue }
                return Button(item: item, view: view)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The native toolbar button must be visible and receive taps: \(identifier)")
        throw ToolbarUnavailable.button
    }

    private enum ToolbarUnavailable: Error { case button }
    private static func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
    private static func visible(_ view: UIView, in window: UIWindow) -> Bool {
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 { return false }
            ancestor = current.superview
        }
        return view.window === window
    }
}
