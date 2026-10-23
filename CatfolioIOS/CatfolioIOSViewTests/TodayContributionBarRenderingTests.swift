import SwiftUI
import XCTest
@testable import CatfolioIOS

@MainActor
final class TodayContributionBarRenderingTests: XCTestCase {
    func testAmountInkStaysWhiteDuringAnimatedQuoteUpdates() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        let state = BarState()
        window.rootViewController = UIHostingController(rootView: Fixture(state: state))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(200))

        for dark in [false, true] {
            state.dark = dark
            for isGain in [true, false] {
                state.isGain = isGain
                try await Task.sleep(for: .milliseconds(80))
                // Exercise full figures, the compact fallback, and changes in
                // digit count on the same live SwiftUI view identity.
                for amount in [88.0, 123_456_789, 0.64, 1_111] {
                    withAnimation(.easeInOut(duration: 0.18)) { state.amount = amount }
                    for frame in 0..<6 {
                        try await Task.sleep(for: .milliseconds(25))
                        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                        }
                        try assertWhiteInk(image, label: "dark=\(dark), gain=\(isGain), amount=\(amount), frame=\(frame)")
                    }
                }
            }
        }
    }

    func testGrowingBarsDoNotRenderBlackAmountInk() throws {
        for dark in [false, true] {
            for isGain in [true, false] {
                for growth: CGFloat in [0.45, 0.7, 1] {
                    let renderer = ImageRenderer(content: bar(amount: 88, isGain: isGain, growth: growth)
                        .background(dark ? Color.black : Color.white)
                        .environment(\.colorScheme, dark ? .dark : .light))
                    renderer.scale = 3
                    let image = try XCTUnwrap(renderer.uiImage)
                    let counts = try inkCounts(image, top: 146 * (1 - growth) + 14)
                    XCTAssertEqual(counts.black, 0, "dark=\(dark), gain=\(isGain), growth=\(growth)")
                    if growth == 1 { XCTAssertGreaterThan(counts.white, 30) }
                }
            }
        }
    }

    private func assertWhiteInk(_ image: UIImage, label: String) throws {
        let counts = try inkCounts(image, top: 14)
        if counts.black > 0 || counts.white < 30 {
            let attachment = XCTAttachment(image: image)
            attachment.name = label
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(counts.black, 0, label)
        XCTAssertGreaterThan(counts.white, 30, label)
    }

    private func inkCounts(_ image: UIImage, top: CGFloat) throws -> (white: Int, black: Int) {
        // This interior strip contains the amount and saturated bar colour,
        // excluding the rounded corners, fading foot, and company logo.
        let crop = CGRect(x: 6 * image.scale, y: top * image.scale,
                          width: 60 * image.scale, height: 16 * image.scale)
        let bitmap = try XCTUnwrap(image.cgImage?.cropping(to: crop))
        var pixels = [UInt8](repeating: 0, count: bitmap.width * bitmap.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: bitmap.width, height: bitmap.height,
            bitsPerComponent: 8, bytesPerRow: bitmap.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(bitmap, in: CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        var white = 0, black = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[index] > 230 && pixels[index + 1] > 230 && pixels[index + 2] > 230 { white += 1 }
            let channels = pixels[index..<(index + 3)]
            let low = Int(channels.min()!), high = Int(channels.max()!)
            // Fading red/green bars can be dark; only neutral dark ink is
            // the regression. Saturated stripe pixels are not black text.
            if high < 50 && high - low < 10 { black += 1 }
        }
        return (white, black)
    }

    @Observable fileprivate final class BarState {
        var amount = 88.0
        var isGain = true
        var dark = false
    }

    private struct Fixture: View {
        let state: BarState
        var body: some View {
            bar(amount: state.amount, isGain: state.isGain, growth: 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(state.dark ? Color.black : Color.white)
                .environment(\.colorScheme, state.dark ? .dark : .light)
                .ignoresSafeArea()
        }
    }
}

@MainActor private func bar(amount: Double, isGain: Bool, growth: CGFloat) -> some View {
    TodayContributionBar(
        holding: Holding(ticker: "AAPL", logoSymbol: "AAPL", displayName: "Apple", sector: nil,
            source: nil, shares: 1, averageCost: 100, costCurrency: "USD", quotePrice: 150,
            quoteCurrency: "USD", todayChangePercent: 1, marketValue: 150, weight: 1,
            unrealized: 50, unrealizedPercent: 50, fxPnl: nil, fxPnlPercent: nil,
            fxPnlStatus: nil, fxPnlSource: nil),
        amount: amount, relativeHeight: 1, isGain: isGain, growth: growth, action: {}
    ).frame(width: 72, height: 167)
}
