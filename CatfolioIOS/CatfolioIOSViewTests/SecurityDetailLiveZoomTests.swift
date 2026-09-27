import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class SecurityDetailLiveZoomTests: XCTestCase {
    func testCloseAnimatesBackBeforeReleasingSourceAndCanOpenAgain() async throws {
        try await withSource { presenter, key, transition in
            let source = try XCTUnwrap(SecurityDetailSources.shared.liveSourceViews(for: key)?.row)
            var dismissals = 0
            for cycle in 1...2 {
                XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace, page: Self.page,
                                              didEnd: { dismissals += 1 }))
                let page = try XCTUnwrap(presenter.presentedViewController)
                try await self.waitUntil { !page.isBeingPresented && page.transitionCoordinator == nil }
                XCTAssertEqual(SecurityDetailLiveZoom.hiddenSource.key, key)

                transition.close()

                // The real modal must animate all the way back. Dismissing it
                // immediately under a fading screenshot fails these assertions.
                XCTAssertNotNil(page.preferredTransition)
                XCTAssertTrue(page.transitionCoordinator?.isAnimated == true)
                XCTAssertTrue(page.isBeingDismissed)
                XCTAssertEqual(dismissals, cycle - 1)
                XCTAssertEqual(SecurityDetailLiveZoom.hiddenSource.key, key)
                transition.close() // A repeated close must not complete twice.

                try await self.waitUntil { presenter.presentedViewController == nil && dismissals == cycle }
                XCTAssertNil(SecurityDetailLiveZoom.hiddenSource.key)
                XCTAssertTrue(source.subviews.isEmpty, "Remove the source-row image after the return completes")
                XCTAssertNotNil(SecurityDetailSources.shared.liveSourceViews(for: key))
            }
        }
    }

    func testNestedFullScreenPageDoesNotReleaseStockTransition() async throws {
        try await withSource { presenter, key, transition in
            var dismissals = 0
            XCTAssertTrue(transition.open(id: key.id, namespace: key.namespace, page: Self.page,
                                          didEnd: { dismissals += 1 }))
            let page = try XCTUnwrap(presenter.presentedViewController)
            try await self.waitUntil { !page.isBeingPresented && page.transitionCoordinator == nil }
            let child = UIViewController()
            child.modalPresentationStyle = .fullScreen
            await withCheckedContinuation { continuation in
                page.present(child, animated: false) { continuation.resume() }
            }
            XCTAssertEqual(dismissals, 0)
            XCTAssertEqual(SecurityDetailLiveZoom.hiddenSource.key, key)
            await withCheckedContinuation { continuation in
                child.dismiss(animated: false) { continuation.resume() }
            }
            XCTAssertTrue(presenter.presentedViewController === page)
            XCTAssertNotNil(page.preferredTransition)
            transition.close()
            try await self.waitUntil { presenter.presentedViewController == nil && dismissals == 1 }
            XCTAssertNil(SecurityDetailLiveZoom.hiddenSource.key)
        }
    }

    private static func page(close: @escaping () -> Void) -> AnyView {
        AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    RoundedRectangle(cornerRadius: 12).fill(.blue)
                        .frame(width: 56, height: 56).securityDetailLogoTarget()
                    Text("Test security")
                    Spacer()
                    Button("Close", action: close)
                }
                Text("Live detail content").frame(height: 1000, alignment: .top)
            }.padding(20)
        }.background(SecurityDetailPresentation.ground))
    }

    private func withSource(_ run: (UIViewController, SecurityDetailSources.SourceKey,
                                   SecurityDetailLiveZoom) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        var key: SecurityDetailSources.SourceKey?
        let presenter = UIHostingController(rootView: ZoomSourceFixture { key = $0 })
        let window = UIWindow(windowScene: scene)
        window.rootViewController = presenter
        window.makeKeyAndVisible()
        let transition = SecurityDetailLiveZoom()
        defer {
            presenter.dismiss(animated: false)
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        try await waitUntil { key.flatMap { SecurityDetailSources.shared.liveSourceViews(for: $0) } != nil }
        try await run(presenter, XCTUnwrap(key), transition)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for the live zoom lifecycle")
    }
}

private struct ZoomSourceFixture: View {
    @Namespace private var namespace
    let ready: (SecurityDetailSources.SourceKey) -> Void
    private var key: SecurityDetailSources.SourceKey { .init(id: "TEST", namespace: namespace) }

    var body: some View {
        VStack {
            Spacer().frame(height: 160)
            HStack {
                RoundedRectangle(cornerRadius: 8).fill(.blue).frame(width: 44, height: 44)
                    .securityDetailLogoSource("TEST", in: namespace)
                Text("Test security")
                Spacer()
                Text("$100")
            }
            .padding(12)
            .modifier(SecurityDetailLiveZoomSourceVisibility(key: key))
            .background { SecurityDetailSourceMarker(key: key) }
            Spacer()
        }
        .padding(20)
        .onAppear { ready(key) }
    }
}
