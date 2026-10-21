import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

@MainActor
final class RotatingSunriseIconTests: XCTestCase {
    func testRestingCompositionMatchesTheFigmaAsset() throws {
        for name in ["SunriseSun", "SunriseRest"] {
            let image = try XCTUnwrap(UIImage(named: name))
            XCTAssertEqual(image.size, CGSize(width: 24, height: 24))
            XCTAssertEqual(image.renderingMode, .alwaysTemplate)
        }
        let composed = try render(SunriseIconFrame())
        let reference = try render(Image("SunriseRest").renderingMode(.template))
        XCTAssertLessThan(difference(composed, reference, rows: 0..<144), 0.012,
                          "The first frame must match the supplied final sunrise")
        attach(composed, name: "Sunrise-composed")
        attach(reference, name: "Sunrise-Figma-reference")
    }

    func testSunTurnsWhileHorizonAndClearGapStayFixed() throws {
        let start = try render(SunriseIconFrame())
        let turn = try render(SunriseIconFrame(angle: .degrees(22.5)))
        XCTAssertGreaterThan(difference(start, turn, rows: 0..<96), 0.04)
        XCTAssertLessThan(difference(start, turn, rows: 96..<144), 0.001)
        let pixels = try bytes(turn)
        for y in [99, 102, 105, 126, 132, 138] {
            XCTAssertTrue((0..<144).allSatisfy { pixels[(y * 144 + $0) * 4] < 4 },
                          "The sky/horizon gap and area below the line stay clear")
        }
        XCTAssertGreaterThan(pixels[(114 * 144 + 72) * 4], 250)
        attach(turn, name: "Sunrise-rotating")
    }

    func testMotionStopsOffscreenInBackgroundAndWithReduceMotion() {
        XCTAssertTrue(RotatingSunriseIcon.shouldAnimate(isVisible: true, scenePhase: .active, reduceMotion: false))
        XCTAssertFalse(RotatingSunriseIcon.shouldAnimate(isVisible: false, scenePhase: .active, reduceMotion: false))
        XCTAssertFalse(RotatingSunriseIcon.shouldAnimate(isVisible: true, scenePhase: .background, reduceMotion: false))
        XCTAssertFalse(RotatingSunriseIcon.shouldAnimate(isVisible: true, scenePhase: .inactive, reduceMotion: false))
        XCTAssertFalse(RotatingSunriseIcon.shouldAnimate(isVisible: true, scenePhase: .active, reduceMotion: true))
        XCTAssertEqual(RotatingSunriseIcon.angle(elapsed: 0).degrees, 0)
        XCTAssertEqual(RotatingSunriseIcon.angle(elapsed: 0.75).degrees, 22.5)
        XCTAssertEqual(RotatingSunriseIcon.angle(elapsed: 12).degrees, 0)
        XCTAssertEqual(RotatingSunriseIcon.angle(elapsed: 12.75).degrees, 22.5)
    }

    func testPreMarketRisesAndPostMarketSetsBehindTheSameFixedHorizon() throws {
        for (motion, times) in [(RotatingSunriseIcon.Motion.rising, [0.4, 1.4, 2.4]),
                                (.setting, [0.0, 1.0, 2.0])] {
            let frames = times.map { RotatingSunriseIcon.frame(elapsed: $0, motion: motion) }
            if motion == .rising {
                XCTAssertGreaterThan(frames[0].offset, frames[1].offset)
                XCTAssertGreaterThan(frames[1].offset, frames[2].offset)
            } else {
                XCTAssertLessThan(frames[0].offset, frames[1].offset)
                XCTAssertLessThan(frames[1].offset, frames[2].offset)
            }
            let images = try frames.map { try render(SunriseIconFrame(sunOffset: $0.offset, sunOpacity: $0.opacity)) }
            XCTAssertGreaterThan(difference(images[0], images[2], rows: 0..<96), 0.04)
            for image in images.dropFirst() {
                XCTAssertLessThan(difference(images[0], image, rows: 96..<144), 0.001,
                                  "The horizon, gap and area below it never move or fade")
            }
            for (index, image) in images.enumerated() { attach(image, name: "sun-\(motion)-\(index)") }
        }
        let preview = ImageRenderer(content: VStack(spacing: 20) {
            ForEach(0..<2) { row in
                HStack(spacing: 12) {
                    Text(row == 0 ? "盘前" : "盘后").font(.system(size: 16))
                    ForEach(0..<3) { column in
                        let motion = row == 0 ? RotatingSunriseIcon.Motion.rising : .setting
                        let time = (row == 0 ? 0.4 : 0) + Double(column)
                        let frame = RotatingSunriseIcon.frame(elapsed: time, motion: motion)
                        SunriseIconFrame(sunOffset: frame.offset, sunOpacity: frame.opacity)
                            .scaleEffect(2).frame(width: 48, height: 48)
                    }
                }
            }
        }.foregroundStyle(.black).padding(24).background(.white))
        preview.scale = 3
        let image = try XCTUnwrap(preview.uiImage)
        try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-sunrise-sunset-preview.png"))
    }

    func testLoopResetIsHiddenAndRestingStatesKeepTheOriginalIcon() throws {
        for (motion, wrap) in [(RotatingSunriseIcon.Motion.rising, 6.0), (.setting, 2.4)] {
            func at(_ time: Double) throws -> UIImage {
                let frame = RotatingSunriseIcon.frame(elapsed: time, motion: motion)
                return try render(SunriseIconFrame(angle: RotatingSunriseIcon.angle(elapsed: time),
                    sunOffset: frame.offset, sunOpacity: frame.opacity))
            }
            XCTAssertLessThan(difference(try at(wrap - 0.001), try at(wrap + 0.001), rows: 0..<144), 0.001,
                              "A repeated rise/set must not visibly jump back across the horizon")
            let resting = try render(RotatingSunriseIcon(motion: motion))
            let original = try render(Image("SunriseRest").renderingMode(.template))
            XCTAssertLessThan(difference(resting, original, rows: 0..<144), 0.001)
        }
    }

    func testHomeHeaderUsesCaptionSizedIconOnlyForItsClosedState() throws {
        for scheme in [ColorScheme.light, .dark] {
            func header(closed: Bool) throws -> UIImage {
                let renderer = ImageRenderer(content:
                    HomeHeaderLine.title("CATFOLIO", holdingsValueOnly: false, closed: closed).view
                        .foregroundStyle(.primary).fixedSize().padding(20)
                        .background(scheme == .dark ? Color.black : Color.white)
                        .environment(\.colorScheme, scheme))
                renderer.scale = 3
                return try XCTUnwrap(renderer.uiImage)
            }
            let open = try header(closed: false)
            let closed = try header(closed: true)
            XCTAssertEqual(closed.size.width - open.size.width, 15, accuracy: 0.5,
                           "The closed state adds the original 10-point moon and existing five-point spacing")
            XCTAssertEqual(closed.size.height, open.size.height, accuracy: 2)
            attach(closed, name: "Home-market-icon-\(scheme)")
        }
        XCTAssertFalse(HomeHeaderLine.sweeps(.title("CATFOLIO", holdingsValueOnly: false, closed: false),
                                            .title("CATFOLIO", holdingsValueOnly: false, closed: true)))
    }

    private func render<V: View>(_ content: V) throws -> UIImage {
        let renderer = ImageRenderer(content: content.foregroundStyle(.white)
            .frame(width: 24, height: 24).background(.black))
        renderer.scale = 6
        return try XCTUnwrap(renderer.uiImage)
    }

    private func bytes(_ image: UIImage) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 144 * 144 * 4)
        let context = try XCTUnwrap(CGContext(data: &result, width: 144, height: 144,
            bitsPerComponent: 8, bytesPerRow: 144 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 144, height: 144))
        return result
    }

    private func difference(_ lhs: UIImage, _ rhs: UIImage, rows: Range<Int>) -> Double {
        guard let a = try? bytes(lhs), let b = try? bytes(rhs) else { return 1 }
        let total = rows.reduce(0.0) { sum, y in
            sum + (0..<144).reduce(0.0) { $0 + Double(abs(Int(a[(y * 144 + $1) * 4]) - Int(b[(y * 144 + $1) * 4]))) }
        }
        return total / Double(rows.count * 144 * 255)
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
