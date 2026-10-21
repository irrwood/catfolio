import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class ChartFirstPresentationTests: XCTestCase {
    func testFirstPresentationAndDelayedDataDrawWithoutAnotherVisit() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for transition in [StandardLineChartDataTransition.morph, .viewportZoom] {
            for initiallyEmpty in [false, true] {
                let state = ChartState()
                state.ready = !initiallyEmpty
                let id = "first-presentation-\(UUID())"
                let host = UIHostingController(rootView: Fixture(state: state, id: id, transition: transition))
                window.rootViewController = host
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(100))
                state.ready = true
                try await Task.sleep(for: .milliseconds(650))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                XCTAssertGreaterThan(try bluePixels(image), 200, "\(transition), delayed data: \(initiallyEmpty)")
                try image.pngData()?.write(to: URL(fileURLWithPath:
                    "/tmp/catfolio-chart-first-\(transition)-\(initiallyEmpty).png"))
            }
        }
    }

    private func bluePixels(_ image: UIImage) throws -> Int {
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return stride(from: 0, to: bytes.count, by: 4).filter {
            Int(bytes[$0 + 2]) > Int(bytes[$0 + 1]) + 50 && Int(bytes[$0 + 2]) > Int(bytes[$0]) + 70
        }.count
    }

    @Observable final class ChartState { var ready = false }

    private struct Fixture: View {
        let state: ChartState
        let id: String
        let transition: StandardLineChartDataTransition

        var body: some View {
            let points: [StandardLineChartPoint] = state.ready ? (0..<20).map {
                .init(date: Date(timeIntervalSinceReferenceDate: Double($0) * 86_400),
                      value: 40 + sin(Double($0)) * 20)
            } : []
            StandardLineChart(series: [.init(id: "price", points: points, color: CatfolioStyle.blue,
                                            latestPointUsesGlass: false)],
                interactionDates: points.map(\.date), domain: 0...100, yTicks: [], axisWidth: 0,
                transitionKey: "same-range", appearanceID: id, dataTransition: transition,
                yAxisLabel: { _ in "" }, xAxisLabel: { _ in "" })
                .frame(height: 280).background(Color.black)
                .preferredColorScheme(.dark)
        }
    }
}
