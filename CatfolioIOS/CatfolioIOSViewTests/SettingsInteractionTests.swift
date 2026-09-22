import SwiftUI
import XCTest
@testable import CatfolioIOS

final class SettingsInteractionTests: XCTestCase {
    @MainActor
    func testOnlyTheNearestSettingsScrollViewGetsImmediateTouches() {
        let outer = UIScrollView()
        let settings = UIScrollView()
        let nested = UIScrollView()
        let boundary = SettingsImmediateTouchFeedback.BoundaryView()
        let refresh = UIRefreshControl()
        settings.refreshControl = refresh
        outer.addSubview(settings)
        settings.addSubview(boundary)
        settings.addSubview(nested)
        let pan = settings.panGestureRecognizer
        let originalCancellation = settings.canCancelContentTouches

        boundary.configureScrollView()

        XCTAssertFalse(settings.delaysContentTouches)
        XCTAssertTrue(outer.delaysContentTouches)
        XCTAssertTrue(nested.delaysContentTouches)
        XCTAssertEqual(settings.canCancelContentTouches, originalCancellation)
        XCTAssertTrue(settings.panGestureRecognizer === pan)
        XCTAssertTrue(pan.isEnabled)
        XCTAssertTrue(settings.isScrollEnabled)
        XCTAssertTrue(settings.refreshControl === refresh)
    }

    @MainActor
    func testRemovalRestoresOriginalTouchPolicy() {
        let scroll = UIScrollView()
        let boundary = SettingsImmediateTouchFeedback.BoundaryView()
        scroll.addSubview(boundary)
        boundary.configureScrollView()
        boundary.configureScrollView()
        XCTAssertFalse(scroll.delaysContentTouches)
        boundary.restoreScrollView()
        XCTAssertTrue(scroll.delaysContentTouches)

        // Do not change a policy that already opted into immediate touches.
        scroll.delaysContentTouches = false
        boundary.configureScrollView()
        boundary.restoreScrollView()
        XCTAssertFalse(scroll.delaysContentTouches)

        scroll.delaysContentTouches = true
        boundary.configureScrollView()
        boundary.deactivate()
        // A queued SwiftUI update after dismantling cannot reapply the policy.
        boundary.configureScrollView()
        XCTAssertTrue(scroll.delaysContentTouches)
    }

    @MainActor
    func testReparentingRestoresOldScrollAndConfiguresNewScroll() {
        let first = UIScrollView()
        let second = UIScrollView()
        let boundary = SettingsImmediateTouchFeedback.BoundaryView()
        first.addSubview(boundary)
        boundary.configureScrollView()
        second.addSubview(boundary)
        boundary.configureScrollView()
        XCTAssertTrue(first.delaysContentTouches)
        XCTAssertFalse(second.delaysContentTouches)
    }

    @MainActor
    func testActualSettingsPageKeepsImmediateTouchesAfterUpdates() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let probe = SettingsTouchProbe()
        let controller = UIHostingController(rootView: SettingsTouchFixture(probe: probe))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(350))
        let scroll = try XCTUnwrap(scrollView(in: controller.view))
        XCTAssertFalse(scroll.delaysContentTouches)
        XCTAssertTrue(scroll.canCancelContentTouches)
        XCTAssertTrue(scroll.touchesShouldCancel(in: UIView()))

        probe.revision += 1
        probe.isOn.toggle()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(scroll.delaysContentTouches)
        XCTAssertTrue(scroll.isScrollEnabled)
        XCTAssertTrue(scroll.panGestureRecognizer.isEnabled)
        XCTAssertEqual(probe.buttonActions, 0)

        scroll.setContentOffset(CGPoint(x: 0, y: 250), animated: true)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(scroll.contentOffset.y, 250, accuracy: 1)
        XCTAssertEqual(probe.buttonActions, 0)
        XCTAssertFalse(scroll.delaysContentTouches)
    }

    @MainActor
    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    /// Render the production section with an isolated store so the attachments
    /// can be reviewed in both languages without contacting real iCloud.
    @MainActor
    func testCloudSettingsScreenshots() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let suite = "cloud-settings-ui-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsCloudStore()
        let sync = CloudPreferenceSync(defaults: defaults, makeStore: { store }, center: NotificationCenter())
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        let window = UIWindow(windowScene: scene)
        defer {
            sync.stop()
            defaults.removePersistentDomain(forName: suite)
            if let previousLanguage { UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: AppLanguage.preferenceKey) }
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        for (name, language, enabled, available, large) in [
            ("icloud-off-zh", "zh-Hans", false, true, false),
            ("icloud-enabled-en", "en", true, true, false),
            ("icloud-unavailable-zh", "zh-Hans", true, false, false),
            ("icloud-large-text-en", "en", true, true, true)
        ] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            store.available = available
            sync.setEnabled(enabled)
            sync.refresh()
            let controller = UIHostingController(rootView: NavigationStack {
                SettingsPage(title: L10n.text("设置")) {
                    CloudPreferencesSettingsSection(sync: sync)
                }
            }
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, large ? .accessibility1 : .large)
            .preferredColorScheme(large ? .dark : .light))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let screenshot = renderer.image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}

private final class SettingsCloudStore: CloudPreferenceStore {
    var dictionaryRepresentation: [String: Any] = [:]
    var available = true
    func object(forKey key: String) -> Any? { dictionaryRepresentation[key] }
    func set(_ value: Any?, forKey key: String) { dictionaryRepresentation[key] = value }
    func removeObject(forKey key: String) { dictionaryRepresentation.removeValue(forKey: key) }
    func synchronize() -> Bool { available }
}

@Observable
private final class SettingsTouchProbe {
    var revision = 0
    var isOn = false
    var buttonActions = 0
}

private struct SettingsTouchFixture: View {
    @Bindable var probe: SettingsTouchProbe

    var body: some View {
        NavigationStack {
            SettingsPage(title: "Settings") {
                SettingsSection {
                    SettingsButtonRow(title: "Action \(probe.revision)") { probe.buttonActions += 1 }
                    SettingsNavigationRow(title: "Detail") { Text("Detail") }
                    SettingsToggleRow(title: "Toggle", isOn: $probe.isOn)
                }
                Color.clear.frame(height: 1500)
            }
        }
    }
}
