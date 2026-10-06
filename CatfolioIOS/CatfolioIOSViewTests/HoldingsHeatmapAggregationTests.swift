import XCTest
import SwiftUI
@testable import CatfolioIOS

final class AssetLogoLayoutTests: XCTestCase {
    @MainActor
    private func fixture(size: CGSize, background: UIColor?, mark: CGRect) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            if let background { background.setFill(); context.fill(CGRect(origin: .zero, size: size)) }
            UIColor.black.setFill()
            context.fill(mark)
        }
    }

    @MainActor
    func testWideAndTallArtworkKeepTheirPixelAspectRatio() throws {
        for size in [CGSize(width: 200, height: 40), CGSize(width: 40, height: 200)] {
            let image = fixture(size: size, background: nil, mark: CGRect(origin: .zero, size: size))
            let layout = AssetLogoLayout.resolve(image)
            XCTAssertEqual(layout.insetFraction, 0.08)
            let renderer = ImageRenderer(content: AssetLogoArtwork(image: image, layout: layout, size: 100))
            renderer.scale = 1
            let output = try XCTUnwrap(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: 100 * 100 * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: 100, height: 100,
                bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(output, in: CGRect(x: 0, y: 0, width: 100, height: 100))
            var minX = 100, maxX = -1, minY = 100, maxY = -1
            for y in 0..<100 { for x in 0..<100 {
                let index = (y * 100 + x) * 4
                if pixels[index] < 40 && pixels[index + 3] > 240 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            } }
            XCTAssertGreaterThan(maxX, minX)
            XCTAssertGreaterThan(maxY, minY)
            XCTAssertEqual(Double(maxX - minX + 1) / Double(maxY - minY + 1),
                           size.width / size.height, accuracy: 0.3)
            XCTAssertGreaterThanOrEqual(min(minX, minY), 7, "Keep artwork clear of rounded clipping")
        }
    }

    @MainActor
    func testExistingPaddingAndOpaqueBrandTilesKeepTheirOpticalSize() {
        let size = CGSize(width: 96, height: 96)
        let padded = fixture(size: size, background: .white, mark: CGRect(x: 14, y: 36, width: 68, height: 24))
        XCTAssertEqual(AssetLogoLayout.resolve(padded), .init(insetFraction: 0, usesWhiteCanvas: true))
        let branded = fixture(size: size, background: .red, mark: CGRect(x: 20, y: 20, width: 56, height: 56))
        XCTAssertEqual(AssetLogoLayout.resolve(branded), .init(insetFraction: 0, usesWhiteCanvas: false))
        let edgeToEdge = fixture(size: size, background: nil, mark: CGRect(x: 0, y: 36, width: 96, height: 24))
        XCTAssertEqual(AssetLogoLayout.resolve(edgeToEdge), .init(insetFraction: 0.08, usesWhiteCanvas: true))
    }

    @MainActor
    func testWhiteArtworkGetsContrastingBackingWithoutChangingItsPixels() {
        let whiteMark = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 8, y: 34, width: 80, height: 28))
        }
        let layout = AssetLogoLayout.resolve(whiteMark)
        XCTAssertTrue(layout.usesDarkCanvas)
        XCTAssertFalse(layout.usesWhiteCanvas)
    }

    @MainActor
    func testMixedEdgesAndTransparentSymbolsDoNotInventABackground() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let mixed = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format).image { context in
            UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 96, height: 96), cornerRadius: 12).addClip()
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 96))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 48, y: 0, width: 48, height: 96))
        }
        XCTAssertNil(AssetLogoLayout.resolve(mixed).edgeCanvas)
        let symbol = fixture(size: CGSize(width: 96, height: 96), background: nil,
                             mark: CGRect(x: 0, y: 36, width: 96, height: 24))
        XCTAssertNil(AssetLogoLayout.resolve(symbol).edgeCanvas)
    }

    @MainActor
    func testBakedWhitePaddingIsMaskedWhileBrandArtworkStaysVisible() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
            UIColor.blue.setFill(); context.fill(CGRect(x: 8, y: 8, width: 80, height: 80))
            UIColor.white.setFill(); context.fill(CGRect(x: 42, y: 26, width: 12, height: 44))
        }
        let layout = AssetLogoLayout.resolve(image)
        XCTAssertNotNil(layout.edgeCanvas)
        XCTAssertGreaterThan(try XCTUnwrap(layout.edgeTileBounds).minX, 0)
        let renderer = ImageRenderer(content: AssetLogoArtwork(image: image, layout: layout, size: 96))
        renderer.scale = 1
        let output = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: 96 * 96 * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 96, height: 96,
            bitsPerComponent: 8, bytesPerRow: 384, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(output, in: CGRect(x: 0, y: 0, width: 96, height: 96))
        XCTAssertLessThan(pixels[(48 * 96 + 2) * 4], 20, "The source's white border becomes blue, allowing downsampled edge antialiasing")
        XCTAssertGreaterThan(pixels[(48 * 96 + 2) * 4 + 2], 245)
        XCTAssertGreaterThan(pixels[(48 * 96 + 48) * 4], 245, "The white symbol itself stays white")
    }

    @MainActor
    func testLogoRuleVisualComparison() async throws {
        var examples: [(String, UIImage)] = []
        for symbol in ["MCD", "ARM", "NBIS", "VT", "TSLA", "SPOT", "ASML", "NVDA", "COST"] {
            let url = try XCTUnwrap(AssetLogoExportCatalog.imageURL(for: symbol, dark: false))
            let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
            examples.append((symbol, image.preparingForDisplay() ?? image))
        }
        let wordmark = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 60)).image { _ in
            ("WORDMARK" as NSString).draw(at: CGPoint(x: 3, y: 8), withAttributes:
                [.font: UIFont.boldSystemFont(ofSize: 36), .foregroundColor: UIColor.black])
        }
        examples.append(("Wide source", wordmark))
        let whiteMark = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 60)).image { _ in
            ("WORDMARK" as NSString).draw(at: CGPoint(x: 3, y: 8), withAttributes:
                [.font: UIFont.boldSystemFont(ofSize: 36), .foregroundColor: UIColor.white])
        }
        examples.append(("White source", whiteMark))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 382, height: 1000)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for dark in [false, true] {
            let content = VStack(spacing: 16) {
                HStack { Text("Logo").frame(width: 110); Text("Before").frame(width: 64); Text("After").frame(width: 64); Text("40pt").frame(width: 48) }
                ForEach(examples.indices, id: \.self) { index in
                    let (symbol, image) = examples[index]
                    HStack(spacing: 16) {
                        Text(symbol).frame(width: 110, alignment: .leading)
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 64, height: 64)
                            .background(Color(uiColor: .secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 64 * 2 / 7))
                        AssetLogoArtwork(image: image, layout: .resolve(image), size: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 64 * 2 / 7))
                        AssetLogoArtwork(image: image, layout: .resolve(image), size: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 40 * 2 / 7)).frame(width: 48)
                    }
                }
            }.padding(24).background(dark ? Color.black : .white)
                .foregroundStyle(dark ? .white : .black)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = UIHostingController(rootView: content.preferredColorScheme(dark ? .dark : .light))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .seconds(1))
            let rendered = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "logo-rules-\(dark ? "dark" : "light")"
            attachment.lifetime = .keepAlways
            add(attachment)
            try rendered.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-logo-rules-\(dark ? "dark" : "light").png"))
        }
    }
}

final class HoldingsHeatmapAggregationTests: XCTestCase {
    @MainActor
    func testLogoResolutionNotifiesSnapshotOwnerAndSnapshotUsesLoadedLogo() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let resolved = expectation(description: "Logo invalidates the heatmap texture")
        var resolvedURL: URL?
        let host = UIHostingController(rootView: AssetLogo(ticker: "NVDA", logoSymbol: "NVDA", size: 96)
            .environment(\.colorScheme, .light)
            .environment(\.assetLogoDidResolve) { url in
                resolvedURL = url
                resolved.fulfill()
            })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        await fulfillment(of: [resolved], timeout: 5)
        XCTAssertEqual(resolvedURL?.lastPathComponent, "NVDA.light.png")
        XCTAssertTrue(resolvedURL?.isFileURL == true, "Bundled logos need no network")

        // ImageRenderer does not run the logo's async task. After the live
        // logo resolves, its synchronous cache must also supply the texture.
        let renderer = ImageRenderer(content: AssetLogo(ticker: "NVDA", logoSymbol: "NVDA", size: 96)
            .environment(\.colorScheme, .light))
        renderer.scale = 1
        let rendered = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: rendered)
        attachment.name = "heatmap-snapshot-resolved-logo"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(rendered.size, CGSize(width: 96, height: 96))
    }

    private func item(_ index: Int, value: Double) -> HoldingsHeatmapTile.Model {
        let row = ETFLookThroughRow(ticker: "T\(index)", logoSymbol: nil, name: "Company \(index)",
                                   directUSD: 0, fromETFUSD: value, totalUSD: value,
                                   etfWeightPercent: 1, sector: "Technology")
        return .init(id: row.ticker, content: .exposure(row, directHolding: nil),
                     marketValue: value, portfolioFraction: value / 2000,
                     changePercent: Double(index), performanceTitle: "Today")
    }

    func testTinyTailBecomesOneInspectableTileWithoutLosingValueOrMembers() throws {
        let models = [item(0, value: 1000), item(1, value: 200)] + (2..<42).map { item($0, value: 1) }
        let result = HoldingsHeatmapAggregation.modelsForDisplay(models, in: CGSize(width: 180, height: 220))
        let remainders = result.filter(\.isRemainder)
        XCTAssertEqual(remainders.count, 1)
        let tail = try XCTUnwrap(remainders.first)
        XCTAssertGreaterThan(tail.detailItems.count, 1)
        XCTAssertTrue(result.contains { $0.id == "T0" && !$0.isRemainder })
        XCTAssertEqual(result.reduce(0) { $0 + $1.marketValue }, models.reduce(0) { $0 + $1.marketValue }, accuracy: 0.00001)
        XCTAssertEqual(result.reduce(0) { $0 + $1.portfolioFraction }, models.reduce(0) { $0 + $1.portfolioFraction }, accuracy: 0.00001)
        let leaves = result.flatMap(\.leafItems)
        XCTAssertEqual(leaves.count, models.count)
        XCTAssertEqual(Set(leaves.map(\.id)), Set(models.map(\.id)))
        XCTAssertEqual(leaves.first { $0.id == "T30" }?.changePercent, 30)
        let placements = HoldingsTreemapLayout.layout(items: result.map { .init(ticker: $0.id, weight: $0.marketValue) },
                                                      in: CGRect(x: 0, y: 0, width: 180, height: 220))
        let frame = try XCTUnwrap(placements.first { $0.ticker == tail.id }?.frame)
        XCTAssertGreaterThanOrEqual(frame.width, 48)
        XCTAssertGreaterThanOrEqual(frame.height, 32)
    }

    func testPinningOtherDoesNotLeaveUnreadableCompanyStrips() {
        let models = (0..<60).map { item($0, value: 1000 / Double(($0 + 1) * ($0 + 1))) }
        let size = CGSize(width: 360, height: 320)
        let result = HoldingsHeatmapAggregation.modelsForDisplay(models, in: size)
        let placements = HoldingsTreemapLayout.layout(items: result.map { .init(ticker: $0.id, weight: $0.marketValue) },
                                                      in: CGRect(origin: .zero, size: size),
                                                      lastItemIndex: result.firstIndex(where: \.isRemainder))
        for placement in placements where !result[placement.sourceIndex].isRemainder {
            let inset = HoldingsHeatmapTile.inset(in: placement.frame.size)
            XCTAssertTrue(HoldingsHeatmapTile.canShowIdentifier(in: placement.frame.insetBy(dx: inset, dy: inset).size))
        }
        XCTAssertEqual(result.flatMap(\.leafItems).count, models.count)
    }

    func testExistingRemainderIsFlattenedIntoDetailInsteadOfDiscarded() {
        let members = (1..<50).map { item($0, value: 1) }
        let oldRemainder = HoldingsHeatmapTile.Model.remainder(id: "old-tail", items: members)
        let result = HoldingsHeatmapAggregation.modelsForDisplay(
            [item(0, value: 1000), oldRemainder], in: CGSize(width: 95, height: 90))
        XCTAssertEqual(result.flatMap(\.leafItems).count, 50)
        XCTAssertTrue(result.filter(\.isRemainder).flatMap(\.detailItems).allSatisfy { !$0.isRemainder })
    }

    func testReadableTilesRemainSeparateAndResizeDoesNotMutateSource() {
        let models = (0..<4).map { item($0, value: 100) }
        let wide = HoldingsHeatmapAggregation.modelsForDisplay(models, in: CGSize(width: 400, height: 400))
        XCTAssertEqual(wide.count, 4)
        XCTAssertFalse(wide.contains(where: \.isRemainder))
        let narrow = HoldingsHeatmapAggregation.modelsForDisplay(models, in: CGSize(width: 24, height: 60))
        XCTAssertEqual(narrow.count, 1)
        XCTAssertEqual(narrow.first?.leafItems.count, 4)
        XCTAssertEqual(models.count, 4)
        XCTAssertFalse(models.contains(where: \.isRemainder))
    }

    func testNestedDetailPreservesHoldingPeriodAndEveryReturn() {
        var first = item(1, value: 100)
        first.performancePeriod = .holdingPeriod
        first.isEstimated = true
        var second = item(2, value: 10)
        second.performancePeriod = .holdingPeriod
        let tail = HoldingsHeatmapTile.Model.remainder(id: "tail", items: [first, second])
        let sector = HoldingsHeatmapTile.Model.remainder(id: "sector", items: [tail])
        XCTAssertEqual(sector.performancePeriod, .holdingPeriod)
        XCTAssertEqual(sector.leafItems.map(\.id), ["T1", "T2"])
        XCTAssertEqual(sector.leafItems.map(\.changePercent), [1, 2])
        XCTAssertTrue(sector.leafItems[0].isEstimated)
        XCTAssertTrue(sector.leafItems.allSatisfy { $0.performancePeriod == .holdingPeriod })
    }

    func testRemainderUsesItsExactMarketShareAndStaysAtBottomRight() throws {
        for remainderValue in [10.0, 400, 2000] {
            let models = [item(1, value: 100), item(2, value: 200),
                          HoldingsHeatmapTile.Model.remainder(id: "other", items: [item(3, value: remainderValue)])]
            let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
            let tiles = HoldingsTreemapLayout.layout(items: models.map { .init(ticker: $0.id, weight: $0.marketValue) },
                                                      in: bounds, lastItemIndex: 2)
            let other = try XCTUnwrap(tiles.first { $0.ticker == "other" })
            XCTAssertEqual(other.frame.maxX, bounds.maxX, accuracy: 0.00001)
            XCTAssertEqual(other.frame.maxY, bounds.maxY, accuracy: 0.00001)
            XCTAssertEqual(other.frame.width * other.frame.height / (bounds.width * bounds.height),
                           remainderValue / (300 + remainderValue), accuracy: 0.00001)
            for left in tiles.indices {
                for right in tiles.indices where right > left {
                    let intersection = tiles[left].frame.intersection(tiles[right].frame)
                    XCTAssertTrue(intersection.isNull || intersection.width * intersection.height < 0.00001)
                }
            }
        }
    }

    private func performanceItem(_ id: String, market: Double, change: Double?, period: HoldingPerformancePeriod = .today) -> HoldingsHeatmapTile.Model {
        let row = ETFLookThroughRow(ticker: id, logoSymbol: nil, name: id, directUSD: 0,
                                   fromETFUSD: market, totalUSD: market, etfWeightPercent: 1, sector: "Technology")
        return .init(id: id, content: .exposure(row, directHolding: nil), marketValue: market,
                     portfolioFraction: market / 10000, changePercent: change,
                     performanceTitle: period.title, performancePeriod: period,
                     isEstimated: period == .holdingPeriod)
    }

    func testAggregateProfitUsesReferenceValuesInsteadOfAveragingReturns() throws {
        for period in HoldingPerformancePeriod.allCases {
            let first = performanceItem("A", market: 120, change: 20, period: period)
            let second = performanceItem("B", market: 900, change: -10, period: period)
            let other = HoldingsHeatmapTile.Model.remainder(id: "other", items: [first, second])
            let summary = other.performanceSummary()
            XCTAssertEqual(summary.amount, -80, accuracy: 0.000001)
            XCTAssertEqual(summary.referenceValue, 1100, accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(other.changePercent), -80 / 1100 * 100, accuracy: 0.000001)
            XCTAssertEqual(other.portfolioFraction, 0.102, accuracy: 0.000001)
            XCTAssertEqual(summary.isEstimated, period == .holdingPeriod)
        }
    }

    func testHoldingPeriodUsesTheExistingUnrealizedAmounts() throws {
        var document = LocalPortfolioDocument.empty
        document.positions = [
            LocalPositionRecord(ticker: "AAPL", name: "Apple", shares: 1, averageCost: 100,
                                currency: "USD", quotePrice: 120, quoteCurrency: "USD", source: "test", openedDate: nil),
            LocalPositionRecord(ticker: "MSFT", name: "Microsoft", shares: 1, averageCost: 1000,
                                currency: "USD", quotePrice: 900, quoteCurrency: "USD", source: "test", openedDate: nil),
        ]
        let holdings = try LocalPortfolioEngine.presentation(for: document).2
        let models = holdings.map { holding in
            HoldingsHeatmapTile.Model(id: holding.ticker, content: .holding(holding), marketValue: holding.marketValue,
                                      portfolioFraction: holding.weight, changePercent: holding.unrealizedPercent,
                                      performanceTitle: "Holding period", performancePeriod: .holdingPeriod)
        }
        let summary = HoldingsHeatmapTile.Model.remainder(id: "other", items: models).performanceSummary()
        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.amount, holdings.reduce(0) { $0 + $1.unrealized }, accuracy: 0.000001)
        XCTAssertEqual(summary.amount, -80, accuracy: 0.000001)
        XCTAssertFalse(summary.isEstimated)
    }

    func testMissingQuotesRemainPartialAndNewQuotesCompleteTheSummary() throws {
        let first = performanceItem("A", market: 120, change: 20)
        let missing = performanceItem("B", market: 900, change: nil)
        let other = HoldingsHeatmapTile.Model.remainder(id: "other", items: [first, missing])
        let partial = other.performanceSummary()
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.knownCount, 1)
        XCTAssertEqual(partial.amount, 20, accuracy: 0.000001)
        // Reversed deliberately: this asserted nil, so the merged block showed
        // no return at all whenever one constituent lacked a quote — and that
        // block holds the smallest holdings, the ones most often unpriced. The
        // figure now covers the priced part; `isComplete` above still says it
        // is partial, which is what the detail sheet's coverage line reads.
        XCTAssertEqual(try XCTUnwrap(other.changePercent), 20, accuracy: 0.000001)
        let complete = other.performanceSummary(dailyChanges: ["B": -10])
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(complete.amount, -80, accuracy: 0.000001)
        let nested = HoldingsHeatmapTile.Model.remainder(id: "nested", items: [other])
        XCTAssertEqual(nested.performanceSummary().amount, partial.amount)
        let held = HoldingsHeatmapTile.Model.remainder(id: "held", items: [performanceItem("B", market: 900, change: nil, period: .holdingPeriod)])
        XCTAssertEqual(held.performanceSummary(dailyChanges: ["B": -10]).knownCount, 0)
    }

    func testOnlyVeryThinElongatedTilesBecomeCapsules() {
        for size in [CGSize(width: 100, height: 8), CGSize(width: 6, height: 80), CGSize(width: 64, height: 16)] {
            XCTAssertTrue(HoldingsHeatmapTile.usesCapsule(in: size))
        }
        for size in [CGSize(width: 50, height: 22), CGSize(width: 22, height: 50),
                     CGSize(width: 18, height: 18), CGSize(width: 30, height: 14),
                     CGSize(width: 200, height: 40), .zero] {
            XCTAssertFalse(HoldingsHeatmapTile.usesCapsule(in: size))
        }
    }

    func testGuttersStayConsistentWithoutErasingVeryThinTiles() {
        for size in [CGSize(width: 100, height: 120), CGSize(width: 30, height: 35), CGSize(width: 100, height: 8)] {
            XCTAssertEqual(HoldingsHeatmapTile.inset(in: size), 2)
        }
        let sliver = CGSize(width: 3, height: 60)
        XCTAssertEqual(HoldingsHeatmapTile.inset(in: sliver), 0.75)
        XCTAssertGreaterThan(sliver.width - 2 * HoldingsHeatmapTile.inset(in: sliver), 0)
    }

    func testSmallLogoSizedTilesRemainIndividual() {
        let models = (0..<4).map { item($0, value: 100) }
        let result = HoldingsHeatmapAggregation.modelsForDisplay(models, in: CGSize(width: 64, height: 60))
        XCTAssertEqual(result.count, 4)
        XCTAssertFalse(result.contains(where: \.isRemainder))
        XCTAssertEqual(Set(result.map(\.id)), Set(models.map(\.id)))
    }
}
