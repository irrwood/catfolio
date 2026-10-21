import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class HoldingResearchNavigationTests: XCTestCase {
    func testChildPageKeepsEntryAndParentScrollStableAcrossOpenAndReturn() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let probe = ResearchNavigationProbe()
        let host = UIHostingController(rootView: ResearchNavigationFixture(probe: probe))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await waitUntil { probe.entryHeight > 0 }
        let parent = try XCTUnwrap(scrollView(in: host.view))
        let height = probe.entryHeight
        let contentHeight = parent.contentSize.height
        parent.setContentOffset(CGPoint(x: 0, y: 320), animated: false)
        let offset = parent.contentOffset
        XCTAssertEqual(probe.visits, 0, "Rendering an entry must not load its child page")

        for visit in 1...2 {
            probe.isPresented = true
            try await waitUntil { host.presentedViewController != nil && probe.visits == visit }
            let page = try XCTUnwrap(host.presentedViewController)
            try await waitUntil { self.scrollView(in: page.view) != nil }
            let child = try XCTUnwrap(scrollView(in: page.view))
            XCTAssertFalse(child === parent)
            XCTAssertEqual(probe.entryHeight, height, accuracy: 0.5)
            XCTAssertEqual(parent.contentSize.height, contentHeight, accuracy: 0.5)
            child.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
            XCTAssertEqual(parent.contentOffset.y, offset.y, accuracy: 1)

            if visit == 1 {
                // A development's detail must present from the open child,
                // rather than competing with it on the holding page.
                probe.nested = true
                try await waitUntil { page.presentedViewController != nil }
                let nestedPage = try XCTUnwrap(page.presentedViewController)
                try await waitUntil { self.navigation(in: nestedPage) != nil }
                let nestedNavigation = try XCTUnwrap(navigation(in: nestedPage))
                let nestedDone = try await NativeToolbarTestSupport.button(in: nestedNavigation,
                    leading: true, identifier: "holding-modal-close")
                try nestedDone.tap()
                try await waitUntil { page.presentedViewController == nil }
                XCTAssertFalse(probe.nested)
                XCTAssertTrue(host.presentedViewController === page)
            }

            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            })
            attachment.name = "holding-research-child-page-\(visit)"
            attachment.lifetime = .keepAlways
            add(attachment)

            let navigation = try XCTUnwrap(navigation(in: page))
            let done = try await NativeToolbarTestSupport.button(in: navigation,
                leading: true, identifier: "holding-modal-close")
            try done.tap()
            try await waitUntil { host.presentedViewController == nil && probe.dismissals == visit }
            XCTAssertFalse(probe.isPresented)
            XCTAssertEqual(probe.entryHeight, height, accuracy: 0.5)
            XCTAssertEqual(parent.contentOffset.y, offset.y, accuracy: 1)
        }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func navigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigation(in: $0) }.first
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(condition(), "The native presentation must finish")
    }
}

@MainActor @Observable
private final class ResearchNavigationProbe {
    var isPresented = false
    var nested = false
    var entryHeight: CGFloat = 0
    var visits = 0
    var dismissals = 0
}

private struct ResearchNavigationFixture: View {
    @Bindable var probe: ResearchNavigationProbe

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Color.clear.frame(height: 400)
                HoldingDetailChildPageCard(title: "Research", subtitle: "Open the complete analysis",
                    isPresented: $probe.isPresented, onDismiss: { probe.dismissals += 1 }) {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("Research details").appText(.heading)
                        ForEach(0..<20) { index in
                            Text("Development \(index + 1)").frame(height: 60)
                        }
                    }
                    .onAppear { probe.visits += 1 }
                    .appSheet(isPresented: $probe.nested) {
                        HoldingDetailChildPage(title: "Development") { Text("Development details") }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.entryHeight = $0 }
                Color.clear.frame(height: 1200)
            }
            .padding(16)
        }
    }
}
