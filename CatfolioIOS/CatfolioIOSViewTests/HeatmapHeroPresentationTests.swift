import SwiftUI
import UIKit
import XCTest
import Observation
@testable import CatfolioIOS

@MainActor
final class HeatmapHeroPresentationTests: XCTestCase {
    func testPullPixelsDoNotInvalidateHeroUntilAVisualBoundaryChanges() {
        let scroll = HeatmapHeroScroll()
        let state = HeatmapHeroState(isExpanded: false, pull: 0, topInset: 0,
                                    isOnScreen: true, isScrolling: false, onToggle: {}, scroll: scroll)
        scroll.geometry = .init(pull: 2, topInset: 80)
        let changes = ChangeCounter()
        withObservationTracking {
            _ = state.resolved()
        } onChange: { changes.increment() }
        for pull in 3...100 { scroll.geometry = .init(pull: CGFloat(pull), topInset: 80) }
        XCTAssertEqual(changes.value, 0, "Pulling within the same state must only move the native scroll view")
        XCTAssertEqual(scroll.geometry.pull, 100, "Release handling still needs the exact distance")
        scroll.geometry = .init(pull: 112, topInset: 80)
        XCTAssertEqual(changes.value, 1, "Crossing the threshold must update haptics")
        XCTAssertEqual(state.resolved().pull, 112)
    }

    private final class ChangeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    func testPullAndExpansionKeepFollowingContentBelowHeatmap() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        let motion = PullMotion()
        var heroFrame = CGRect.zero
        var followingFrame = CGRect.zero
        let host = UIHostingController(rootView: PullHarness(motion: motion,
            onHeroFrame: { heroFrame = $0 }, onFollowingFrame: { followingFrame = $0 }))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        // Let the actual ImageRenderer and blur pipeline prepare a texture.
        try await Task.sleep(for: .seconds(2))
        motion.isScrolling = true
        for pull in stride(from: 0.0, through: 140.0, by: 10) {
            motion.pull = pull
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertGreaterThan(heroFrame.height, 90)
            XCTAssertGreaterThanOrEqual(followingFrame.minY, heroFrame.maxY - 1)
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(hasColoredPixels(image), "The pull must keep the rendered heatmap visible")
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/heatmap-pull.png"))
        motion.pull = 0
        withAnimation(.smooth(duration: 0.7)) { motion.isExpanded = true }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(heroFrame.height, 456, accuracy: 1)
        XCTAssertGreaterThanOrEqual(followingFrame.minY, heroFrame.maxY - 1)
    }

    private func hasColoredPixels(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let width = 100, height = 200
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = buffer.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 4).filter { index in
                let channels = [bytes[index], bytes[index + 1], bytes[index + 2]]
                return Int(channels.max()!) - Int(channels.min()!) > 50
            }.count > 20
        }
    }

    func testExpandedHeatmapStartsAtToolbarInsteadOfScreenTop() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var tileFrame = CGRect.zero
        var followingFrame = CGRect.zero
        let state = HeatmapHeroState(isExpanded: true, pull: 0, topInset: 80,
            isOnScreen: true, isScrolling: true, onToggle: {})
        let host = UIHostingController(rootView: VStack(spacing: 0) {
            Color.clear.frame(height: 80)
            PerformanceHeatmapHero(state: state, renderKey: 1) { _ in
                Color.green.frame(height: 300)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tileFrame = $0 }
            }
            Color.clear.frame(height: 10)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { followingFrame = $0 }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).ignoresSafeArea())
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for _ in 0..<30 where followingFrame == .zero {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(tileFrame.minY, 36, accuracy: 1)
        XCTAssertEqual(tileFrame.height, 300, accuracy: 1)
        XCTAssertEqual(followingFrame.minY, 336, accuracy: 1)
    }
}

@MainActor
private final class PullMotion: ObservableObject {
    @Published var pull: CGFloat = 0
    @Published var isScrolling = false
    @Published var isExpanded = false
}

private struct PullHarness: View {
    @ObservedObject var motion: PullMotion
    let onHeroFrame: (CGRect) -> Void
    let onFollowingFrame: (CGRect) -> Void

    var body: some View {
        VStack(spacing: 20) {
            PerformanceHeatmapHero(state: HeatmapHeroState(
                isExpanded: motion.isExpanded, pull: motion.pull, topInset: 80,
                isOnScreen: true, isScrolling: motion.isScrolling, onToggle: {}, collapsedHeight: 100),
                renderKey: 1) { _ in
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 4) {
                        ForEach(0..<18) { index in
                            ZStack {
                                (index.isMultiple(of: 2) ? CatfolioTheme.positive : CatfolioTheme.danger)
                                Text("STOCK \(index)\n+1.2%")
                                    .font(.caption).foregroundStyle(.white)
                            }.frame(height: 80)
                        }
                    }.frame(height: 500)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onHeroFrame($0) }
            Text("Following content")
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onFollowingFrame($0) }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
        .environment(\.scenePhase, .active)
    }
}
