import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class ToastWindowLifecycleTests: XCTestCase {
    func testToastAnimationFinishesAndReleasesItsWindow() async throws {
        try await withWindow { scene, appWindow in
            let center = ToastCenter()
            let existing = Set(scene.windows.map(ObjectIdentifier.init))
            center.show("Saved", kind: .info)
            let overlay = try XCTUnwrap(scene.windows.first { !existing.contains(ObjectIdentifier($0)) })
            defer {
                if let toast = center.current { center.finish(toast.id) }
                overlay.isHidden = true
                overlay.rootViewController = nil
            }
            for _ in 0..<80 {
                if center.current == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(center.current, "The real SwiftUI animation must reach its finish callback")
            XCTAssertTrue(overlay.isHidden)
            XCTAssertNil(overlay.rootViewController)
            XCTAssertTrue(appWindow.isKeyWindow)
        }
    }

    func testFinishingToastRemovesItsWindowWithoutChangingTheKeyWindow() async throws {
        try await withWindow { scene, appWindow in
            let center = ToastCenter()
            let existing = Set(scene.windows.map(ObjectIdentifier.init))
            center.show("Copied", kind: .info)
            let overlay = try XCTUnwrap(scene.windows.first { !existing.contains(ObjectIdentifier($0)) })
            defer { overlay.isHidden = true; overlay.rootViewController = nil }
            XCTAssertFalse(overlay.isHidden)
            XCTAssertFalse(overlay.isOpaque)
            XCTAssertFalse(overlay.canBecomeKey)
            XCTAssertTrue(appWindow.isKeyWindow)
            XCTAssertNil(overlay.hitTest(CGPoint(x: 40, y: 100), with: nil))
            center.finish(try XCTUnwrap(center.current).id)
            XCTAssertNil(center.current)
            XCTAssertTrue(overlay.isHidden, "An empty toast must not leave a visible window above the app")
            XCTAssertNil(overlay.rootViewController, "Release the full-screen hosting view and its effects")
            XCTAssertTrue(appWindow.isKeyWindow)
        }
    }

    func testBackgroundClearsToastAndTheNextToastCanShowAgain() async throws {
        try await withWindow { scene, appWindow in
            let notifications = NotificationCenter()
            let center = ToastCenter(notificationCenter: notifications)
            let existing = Set(scene.windows.map(ObjectIdentifier.init))
            center.show("Copied", kind: .info)
            let first = try XCTUnwrap(center.current)
            let overlay = try XCTUnwrap(scene.windows.first { !existing.contains(ObjectIdentifier($0)) })
            defer {
                if let toast = center.current { center.finish(toast.id) }
                overlay.isHidden = true
                overlay.rootViewController = nil
            }
            // A notification for a different scene must not dismiss this one.
            notifications.post(name: UIScene.didEnterBackgroundNotification, object: NSObject())
            XCTAssertEqual(center.current?.id, first.id)
            notifications.post(name: UIScene.didEnterBackgroundNotification, object: scene)
            XCTAssertNil(center.current)
            XCTAssertTrue(overlay.isHidden)
            XCTAssertNil(overlay.rootViewController)
            center.show("Saved", kind: .success)
            let next = try XCTUnwrap(center.current)
            center.finish(first.id)
            XCTAssertEqual(center.current?.id, next.id)
            XCTAssertEqual(scene.windows.filter { !existing.contains(ObjectIdentifier($0)) && !$0.isHidden }.count, 1)
            XCTAssertTrue(appWindow.isKeyWindow)
        }
    }

    func testReplacedToastCannotDismissTheNewToastAndRepeatedShowsDoNotAccumulateWindows() async throws {
        try await withWindow { scene, appWindow in
            let center = ToastCenter()
            let existing = Set(scene.windows.map(ObjectIdentifier.init))
            defer {
                if let toast = center.current { center.finish(toast.id) }
                for window in scene.windows where !existing.contains(ObjectIdentifier(window)) {
                    window.isHidden = true
                    window.rootViewController = nil
                }
            }
            for _ in 0..<5 {
                center.show("First", kind: .info)
                let first = try XCTUnwrap(center.current)
                center.show("Second", kind: .info)
                let second = try XCTUnwrap(center.current)
                center.finish(first.id)
                XCTAssertEqual(center.current?.id, second.id)
                let visible = scene.windows.filter { !existing.contains(ObjectIdentifier($0)) && !$0.isHidden }
                XCTAssertEqual(visible.count, 1)
                XCTAssertTrue(appWindow.isKeyWindow)
                center.finish(second.id)
                XCTAssertTrue(visible.allSatisfy(\.isHidden))
            }
        }
    }

    func testGlassRenderingRecoversAfterToastAndAppearanceChanges() async throws {
        try await withWindow { scene, appWindow in
            let center = ToastCenter()
            let existing = Set(scene.windows.map(ObjectIdentifier.init))
            defer {
                if let toast = center.current { center.finish(toast.id) }
                for window in scene.windows where !existing.contains(ObjectIdentifier(window)) {
                    window.isHidden = true
                    window.rootViewController = nil
                }
            }
            for style in [UIUserInterfaceStyle.light, .dark] {
                appWindow.overrideUserInterfaceStyle = style
                try await Task.sleep(for: .milliseconds(400))
                let before = try self.capture(appWindow, name: "glass-before-toast-\(style.rawValue)")
                center.show("Copied", kind: .info)
                try await Task.sleep(for: .milliseconds(900))
                _ = try self.capture(appWindow, name: "glass-during-toast-\(style.rawValue)")
                center.finish(try XCTUnwrap(center.current).id)
                try await Task.sleep(for: .milliseconds(400))
                let after = try self.capture(appWindow, name: "glass-after-toast-\(style.rawValue)")
                XCTAssertLessThan(self.difference(before, after), 0.01,
                                  "The same glass must render consistently after a toast")
            }
        }
    }

    private func withWindow(_ run: (UIWindowScene, UIWindow) async throws -> Void) async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Liquid Glass requires iOS 26") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: GlassLifecycleSample())
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(250))
        try await run(scene, window)
    }

    private func capture(_ window: UIWindow, name: String) throws -> [UInt8] {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/\(name).png"))
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return pixels
    }

    private func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count) / 255
    }
}

@available(iOS 26.0, *)
private struct GlassLifecycleSample: View {
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [.blue, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 24) {
                    Text("Liquid Glass").padding(30)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
                    Button("Continue") {}.buttonStyle(.glass)
                }
            }
            .ignoresSafeArea()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Add", systemImage: "plus") {} } }
        }
    }
}
