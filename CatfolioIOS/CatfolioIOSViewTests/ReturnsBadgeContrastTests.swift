import XCTest
import SwiftUI
@testable import CatfolioIOS

final class ReturnsBadgeContrastTests: XCTestCase {
    func testTextRemainsReadableAcrossSeriesAndDimmedColors() {
        for scheme in [ColorScheme.light, .dark] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let colors: [Color] = [.green, .blue, .purple, .red, .yellow, .orange, .white, .black, Color(white: 0.55)]
            for color in colors {
                for dimmed in [false, true] {
                    let background = dimmed ? color.mix(with: scheme == .dark ? .black : .white, by: 0.68) : color
                    let foreground = ReturnsChartBadge.textColor(on: background, environment: environment)
                    let ratio = contrast(foreground.resolve(in: environment), background.resolve(in: environment))
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "Unreadable number in \(scheme), dimmed: \(dimmed)")
                }
            }
            XCTAssertEqual(ReturnsChartBadge.textColor(on: .white, environment: environment), .black)
            XCTAssertEqual(ReturnsChartBadge.textColor(on: .black, environment: environment), .white)
        }
    }

    private func contrast(_ first: Color.Resolved, _ second: Color.Resolved) -> Double {
        func luminance(_ color: Color.Resolved) -> Double {
            func linear(_ channel: Float) -> Double {
                let c = Double(channel)
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
