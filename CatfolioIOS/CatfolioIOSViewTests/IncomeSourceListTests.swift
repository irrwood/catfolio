import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class IncomeSourceListTests: XCTestCase {
    private func history() -> HoldingValueHistory {
        let costs = ["A": 100.0, "B": 100.0, "C": 100.0]
        return HoldingValueHistory(rows: [
            .init(dateText: "2026-01-02", cost: 300, values: costs, costs: costs),
            .init(dateText: "2026-10-09", cost: 300, values: ["A": 400, "B": 300, "C": 200], costs: costs)
        ], costs: costs, names: ["A": "Alpha", "B": "Beta", "C": "Gamma"])
    }

    func testHiddenRowRetainsIdentityRankAndFinancialTotals() throws {
        let original = HoldingContributionStack(history: history())
        let hidden = HoldingContributionStack(history: history(), hiding: ["B"])
        XCTAssertEqual(hidden.legendItems.map(\.id), original.legendItems.map(\.id))
        let before = try XCTUnwrap(original.legendItems.first { $0.id == "band-B" })
        let after = try XCTUnwrap(hidden.legendItems.first { $0.id == "band-B" })
        XCTAssertNotNil(before.index)
        XCTAssertNil(after.index)
        XCTAssertEqual(original.rank(for: before.band), hidden.rank(for: after.band))
        XCTAssertEqual(hidden.rows.map(\.total), original.rows.map(\.total))
        XCTAssertEqual(hidden.rows.map(\.principal), original.rows.map(\.principal))
        XCTAssertEqual(hidden.legendItems.map(\.id),
                       ["band-A", "band-B", "band-C", "band-others", "band-principal"])
        let restored = HoldingContributionStack(history: history())
        XCTAssertEqual(restored.legendItems.map(\.id), hidden.legendItems.map(\.id))
    }

    func testHiddenRowKeepsTheExistingFadeAppearance() throws {
        let content = VStack(spacing: 12) {
            ForEach([true, false], id: \.self) { isOn in
                ReturnsSourceListRow(rank: 2, color: .blue, title: "B", subtitle: "Beta",
                                     isOn: isOn, isOnTintedField: true) {
                    Text(isOn ? "+$200" : "Hidden")
                }
            }
        }.padding(20).frame(width: 400).background(Color.black)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        let cgImage = try XCTUnwrap(image.cgImage)
        var rgba = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(data: &rgba, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        // Sample the same empty part of each card, clear of text and badges.
        func brightness(y: Int) -> Double {
            let pixel = (y * cgImage.width + 360) * 4
            return Double(Int(rgba[pixel]) + Int(rgba[pixel + 1]) + Int(rgba[pixel + 2])) / 3
        }
        let samples = [brightness(y: 30), brightness(y: 107)].sorted()
        XCTAssertGreaterThan(samples[1], 0)
        XCTAssertEqual(samples[0] / samples[1], 0.4, accuracy: 0.08,
                       "A hidden row must keep the current 40% opacity")
        let attachment = XCTAttachment(image: image)
        attachment.name = "income-source-visible-and-hidden"
        attachment.lifetime = .keepAlways
        add(attachment)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/income-source-visible-and-hidden.png"))
    }
}
