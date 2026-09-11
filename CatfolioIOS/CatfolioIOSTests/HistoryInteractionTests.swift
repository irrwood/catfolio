import SwiftUI
import XCTest
@testable import CatfolioIOS

final class HistoryInteractionTests: XCTestCase {
    private func entry(_ action: String, date: String = "2026-04-06", account: String = "one",
                       id: String = UUID().uuidString, price: Double = 100) -> LocalTransactionRecord {
        LocalTransactionRecord(date: date, action: action, ticker: "TEST", quantity: 1, price: price,
                               currency: "USD", source: "CSV", accountID: account, accountName: account,
                               tradeID: id)
    }

    private func ledger(_ transactions: [LocalTransactionRecord]) -> PortfolioActivityLedger {
        let accounts = Dictionary(grouping: transactions, by: \.accountKey).map { key, rows in
            PortfolioAccount(id: key, accountID: rows[0].accountID, source: "CSV", name: key,
                             baseCurrency: "USD", positionCount: 0, transactionCount: rows.count,
                             manualTransactionCount: 0, hasCSVImport: true, marketValueUSD: 0)
        }
        return PortfolioActivityLedger(accounts: accounts, transactions: transactions, securityNames: ["TEST": "Test"])
    }

    private func prepare(_ ledger: PortfolioActivityLedger, accounts: Set<String>? = nil) throws -> HistoryPreparedLedger {
        try HistoryPreparedLedger.build(ledger: ledger, accountIDs: accounts ?? Set(ledger.accounts.map(\.id)),
                                        locale: Locale(identifier: "en_GB"))
    }

    func testCachedPagesPreserveCategoryScopeOrderAndTotals() throws {
        let input = ledger([
            entry("BUY", date: "2025-12-31", id: "buy"), entry("SELL", id: "sell", price: 110),
            entry("DIVIDEND", id: "dividend", price: 2), entry("INTEREST", id: "interest", price: 3),
            entry("DEPOSIT", id: "deposit"), entry("WITHDRAWAL", id: "withdraw"),
            entry("TRANSFER", id: "transfer"), entry("DIVIDEND", account: "two", id: "other", price: 9)
        ])
        let prepared = try prepare(input, accounts: [input.transactions[0].accountKey])
        let all = prepared.page(category: .all, basis: .calendar, year: nil)
        XCTAssertEqual(all.activities.count, 4)
        XCTAssertEqual(all.groups.map(\.id), ["2026-04-06", "2025-12-31"])
        XCTAssertEqual(all.groups.flatMap(\.activities).map(\.id), all.activities.map(\.id))
        XCTAssertTrue(all.activities.last?.kind == .buy)
        XCTAssertEqual(prepared.page(category: .orders, basis: .calendar, year: nil).activities.count, 2)
        XCTAssertEqual(prepared.page(category: .dividends, basis: .calendar, year: nil).totalUSD, 2)
        XCTAssertEqual(prepared.page(category: .interest, basis: .calendar, year: nil).totalUSD, 3)
        XCTAssertTrue(prepared.page(category: .fees, basis: .calendar, year: nil).activities.isEmpty)
    }

    func testYearFiltersDoNotDropEarlierAcquisitionCosts() throws {
        let input = ledger([entry("BUY", date: "2025-01-01", price: 80), entry("SELL", price: 120)])
        let prepared = try prepare(input)
        XCTAssertEqual(prepared.realisedTotal, RealisedProfitCalculator.summarize(transactions: input.transactions))
        for basis in TaxYearBasis.allCases {
            let expected = RealisedProfitCalculator.summarize(transactions: input.transactions, basis: basis)
            XCTAssertEqual(prepared.realisedByTaxYear[basis]?.map(\.label), expected.map(\.label))
            XCTAssertEqual(prepared.realisedByTaxYear[basis]?.map(\.summary), expected.map(\.summary))
            XCTAssertEqual(prepared.realisedByTaxYear[basis]?.first?.summary.estimatedUSD, 40)
        }
        XCTAssertEqual(prepared.page(category: .orders, basis: .calendar, year: "2026").activities.count, 1)
    }

    func testUKBoundaryAndEmptyScope() throws {
        let input = ledger([entry("DIVIDEND", date: "2026-04-05", price: 4),
                            entry("DIVIDEND", date: "2026-04-06", price: 6)])
        let prepared = try prepare(input)
        XCTAssertEqual(prepared.page(category: .dividends, basis: .uk, year: "2025/26").totalUSD, 4)
        XCTAssertEqual(prepared.page(category: .dividends, basis: .uk, year: "2026/27").totalUSD, 6)
        XCTAssertEqual(prepared.page(category: .dividends, basis: .calendar, year: "2026").totalUSD, 10)
        let empty = try prepare(input, accounts: [])
        XCTAssertTrue(empty.page(category: .all, basis: .calendar, year: nil).activities.isEmpty)
        XCTAssertEqual(empty.realisedTotal.saleCount, 0)
    }

    func testCancelledPreparationDoesNotPublishASnapshot() async {
        let input = ledger([entry("INTEREST")])
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try prepare(input)
        }
        do { _ = try await worker.value; XCTFail("Cancelled work must be discarded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTenThousandRowsHaveConstantTimeCategoryLookups() throws {
        let input = ledger((0..<10_000).map { entry($0.isMultiple(of: 2) ? "INTEREST" : "DIVIDEND", id: String($0)) })
        let prepared = try prepare(input)
        let start = CFAbsoluteTimeGetCurrent()
        var count = 0
        for _ in 0..<1_000 {
            for category in HistoryCategory.allCases {
                count += prepared.page(category: category, basis: .calendar, year: nil).activities.count
            }
        }
        XCTAssertEqual(count, 20_000_000)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 0.15,
                          "Selection must read a prepared page, not rescan the ledger")
    }

    @MainActor
    func testPagerAcceptsHorizontalFlicksWithoutAReleaseDistanceThreshold() {
        XCTAssertTrue(HistoryPagingScrollView.shouldBeginPan(startX: 180, velocity: CGPoint(x: -900, y: 20)))
        XCTAssertTrue(HistoryPagingScrollView.shouldBeginPan(startX: 180, velocity: CGPoint(x: 40, y: 2)))
    }

    @MainActor
    func testPagerLeavesVerticalScrollingAndNavigationEdgeFree() {
        XCTAssertFalse(HistoryPagingScrollView.shouldBeginPan(startX: 180, velocity: CGPoint(x: 90, y: 160)))
        XCTAssertFalse(HistoryPagingScrollView.shouldBeginPan(startX: 12, velocity: CGPoint(x: 900, y: 0)))
        XCTAssertFalse(HistoryPagingScrollView.shouldBeginPan(startX: 30, velocity: CGPoint(x: -900, y: 0)))
    }

    @MainActor
    func testNativePagerShowsBothLivePagesAndPillAtHalfwayThenCancels() async throws {
        let controller = HistoryPagingController(selection: .all)
        controller.updatePages(HistoryCategory.allCases.enumerated().map { index, category in
            AnyView(Color(uiColor: index.isMultiple(of: 2) ? .red : .blue)
                .overlay(Text(category.rawValue)))
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(200))
        let width = controller.pager.bounds.width
        XCTAssertGreaterThan(width, 300)
        XCTAssertTrue(controller.pager.isPagingEnabled)
        XCTAssertFalse(controller.pager.scrollsToTop)
        let first = controller.children[0].view!
        let second = controller.children[1].view!
        controller.pager.setContentOffset(CGPoint(x: width / 2, y: 0), animated: false)
        XCTAssertEqual(first.convert(first.bounds, to: controller.view).maxX, width / 2, accuracy: 1)
        XCTAssertEqual(second.convert(second.bounds, to: controller.view).minX, width / 2, accuracy: 1)
        XCTAssertEqual(controller.selection, .all, "Dragging has not committed a category")
        let bar = controller.categoryBar
        XCTAssertEqual(bar.pill.frame.minX,
                       (bar.buttons[0].frame.minX + bar.buttons[1].frame.minX) / 2, accuracy: 0.5)
        attach(controller.view, name: "History-pager-halfway")
        controller.select(.all, animated: false)
        XCTAssertEqual(controller.pageProgress, 0, accuracy: 0.001,
                       "Tapping the origin tab can interrupt an unfinished swipe")
        controller.pager.setContentOffset(CGPoint(x: width / 3, y: 0), animated: false)
        controller.pager.setContentOffset(.zero, animated: false)
        controller.scrollViewDidEndDecelerating(controller.pager)
        XCTAssertEqual(controller.selection, .all)
        XCTAssertEqual(bar.pill.frame, bar.buttons[0].frame)
        controller.select(.fees, animated: false)
        XCTAssertEqual(controller.selection, .fees)
        XCTAssertEqual(controller.pageProgress, 4, accuracy: 0.001)
        XCTAssertTrue(bar.buttons[4].accessibilityTraits.contains(.selected))
        XCTAssertTrue(first.accessibilityElementsHidden)
        XCTAssertFalse(controller.children[4].view.accessibilityElementsHidden)
    }

    @MainActor
    func testRapidTabTapsSettleOnLatestRequestAndKeepEveryListPosition() async throws {
        let actions = ["BUY", "SELL", "DIVIDEND", "INTEREST"]
        let input = ledger((0..<160).map { entry(actions[$0 % actions.count], id: String($0)) })
        let prepared = try prepare(input)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let controller = UIHostingController(rootView: NavigationStack {
            HistoryView(previewLedger: input, prepared: prepared)
        }.environment(AppModel()).preferredColorScheme(.light))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(700))
        func pager(in controller: UIViewController) -> HistoryPagingController? {
            if let result = controller as? HistoryPagingController { return result }
            return controller.children.lazy.compactMap { pager(in: $0) }.first
        }
        let paging = try XCTUnwrap(pager(in: controller))
        paging.pager.setContentOffset(CGPoint(x: paging.pager.bounds.width * 1.5, y: 0), animated: false)
        attach(controller.view, name: "History-orders-dividends-mid-swipe")
        paging.pager.setContentOffset(.zero, animated: false)
        paging.scrollViewDidEndDecelerating(paging.pager)
        let list = try XCTUnwrap(descendants(paging.children[0].view, of: UIScrollView.self).first)
        list.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        let offset = list.contentOffset
        paging.select(.orders, animated: true)
        try await Task.sleep(for: .milliseconds(50))
        paging.select(.fees, animated: true)
        try await Task.sleep(for: .milliseconds(50))
        paging.select(.dividends, animated: true)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(paging.selection, .dividends)
        XCTAssertEqual(paging.pageProgress, 2, accuracy: 0.001)
        let dividends = try XCTUnwrap(descendants(paging.children[2].view, of: UIScrollView.self).first)
        dividends.setContentOffset(CGPoint(x: 0, y: 420), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        let dividendOffset = dividends.contentOffset
        paging.select(.all, animated: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(list.contentOffset.y, offset.y, accuracy: 1)
        XCTAssertTrue(list.scrollsToTop)
        XCTAssertFalse(dividends.scrollsToTop)
        paging.select(.dividends, animated: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(dividends.contentOffset.y, dividendOffset.y, accuracy: 1)
        XCTAssertTrue(dividends.scrollsToTop)
        XCTAssertNotNil(dividends.refreshControl)
        attach(controller.view, name: "History-dividends-restored")
    }

    func testHeaderFollowsPullDownWithoutMaterial() {
        for offset in [CGFloat(-180), -80, -20, 0] {
            let position = HistoryHeaderPosition(scrollOffset: offset)
            XCTAssertEqual(position.pullDown, -offset)
            XCTAssertEqual(position.materialOpacity, 0)
        }
    }

    func testHeaderMaterialAppearsOnlyAsContentPassesUnderIt() {
        XCTAssertEqual(HistoryHeaderPosition(scrollOffset: 0).materialOpacity, 0)
        XCTAssertEqual(HistoryHeaderPosition(scrollOffset: 8).materialOpacity, 0.5)
        XCTAssertEqual(HistoryHeaderPosition(scrollOffset: 16).materialOpacity, 1)
        let pinned = HistoryHeaderPosition(scrollOffset: 16)
        XCTAssertEqual(pinned.pullDown, 0)
        for offset in [CGFloat(80), 300, 10_000] {
            XCTAssertEqual(HistoryHeaderPosition(scrollOffset: offset), pinned,
                           "Normal list scrolling must not keep updating header state")
        }
    }

    @MainActor
    func testNativeLargeTitleCollapsesAndBottomColourContinuesInLightMode() async throws {
        try await checkNativeNavigation(dark: false)
    }

    @MainActor
    func testNativeLargeTitleCollapsesAndBottomColourContinuesInDarkMode() async throws {
        try await checkNativeNavigation(dark: true)
    }

    @MainActor
    func testNativeBackTransitionHasNoTrailingLayoutReset() async throws {
        let input = ledger((0..<100).map { entry("INTEREST", id: String($0)) })
        let prepared = try prepare(input)
        let probe = HistoryNavigationProbe()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let controller = UIHostingController(rootView: HistoryNavigationFixture(
            probe: probe, ledger: input, prepared: prepared).environment(AppModel()))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        withAnimation { probe.showsHistory = true }
        try await Task.sleep(for: .milliseconds(700))
        let navigation = try XCTUnwrap(navigationController(in: controller))
        XCTAssertEqual(navigation.viewControllers.count, 2)
        let detail = try XCTUnwrap(navigation.topViewController)
        let list = try XCTUnwrap(descendants(detail.view, of: UIScrollView.self)
            .first { $0.contentSize.height > $0.bounds.height })
        list.setContentOffset(CGPoint(x: 0, y: 300), animated: false)
        try await Task.sleep(for: .milliseconds(100))
        withAnimation { probe.showsHistory = false }
        for _ in 0..<60 {
            if navigation.viewControllers.count == 1 && navigation.transitionCoordinator == nil { break }
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertEqual(navigation.viewControllers.count, 1)
        XCTAssertNil(navigation.transitionCoordinator)
        let returned = try XCTUnwrap(navigation.topViewController)
        let frame = returned.view.frame
        let barFrame = navigation.navigationBar.frame
        for _ in 0..<15 {
            try await Task.sleep(for: .milliseconds(16))
            XCTAssertEqual(returned.view.frame, frame)
            XCTAssertEqual(navigation.navigationBar.frame, barFrame)
        }
    }

    @MainActor
    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { self.navigationController(in: $0) }.first
    }

    @MainActor
    private func checkNativeNavigation(dark: Bool) async throws {
        let input = ledger((0..<200).map { entry("INTEREST", account: $0.isMultiple(of: 2) ? "one" : "two", id: String($0)) })
        let prepared = try prepare(input)
        let model = AppModel()
        // Opening History directly can precede the home model's account load.
        // The scope menu belongs to this ledger, not the home's loading state.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let controller = UIHostingController(rootView:
            NavigationStack {
                HistoryView(previewLedger: input, prepared: prepared)
            }
            .environment(model)
            .environment(\.locale, Locale(identifier: "en_GB"))
            .preferredColorScheme(dark ? .dark : .light)
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(700))
        let bar = try XCTUnwrap(descendants(controller.view, of: UINavigationBar.self).first)
        let list = try XCTUnwrap(descendants(controller.view, of: UIScrollView.self)
            .first { $0.contentSize.height > $0.bounds.height })
        let largeHeight = bar.bounds.height
        XCTAssertGreaterThan(largeHeight, 70)
        XCTAssertNotNil(list.refreshControl, "History still owns pull to refresh")
        attach(controller.view, name: "History-\(dark ? "dark" : "light")-expanded")
        let restOffset = list.contentOffset
        let barBottom = bar.convert(bar.bounds, to: controller.view).maxY
        // SwiftUI applies the category transform in its rendering layer;
        // UIScrollView.convert does not include that transform consistently.
        // Compare the rendered "All" label at the expected physical positions.
        let labelRect = CGRect(x: 34, y: barBottom + 20, width: 32, height: 24)
        let restingImage = snapshot(controller.view)

        list.setContentOffset(CGPoint(x: 0, y: restOffset.y - 80), animated: false)
        try await Task.sleep(for: .milliseconds(180))
        let actualPull = max(0, -(list.contentOffset.y + list.adjustedContentInset.top))
        XCTAssertGreaterThan(actualPull, 40)
        let nativeBarMovement = bar.convert(bar.bounds, to: controller.view).maxY - barBottom
        let pulledImage = snapshot(controller.view)
        let pulledLabelRect = labelRect.offsetBy(dx: 0, dy: nativeBarMovement + actualPull)
        XCTAssertLessThan(try patchDifference(restingImage, labelRect, pulledImage, pulledLabelRect), 3,
                          "The category label must travel by the actual rubber-band displacement")
        XCTAssertGreaterThan(try patchDifference(restingImage, labelRect, pulledImage, labelRect), 10,
                             "The category label must not remain fixed at its resting position")
        attach(controller.view, name: "History-\(dark ? "dark" : "light")-pulled")

        list.setContentOffset(restOffset, animated: false)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertLessThan(try patchDifference(restingImage, labelRect, snapshot(controller.view), labelRect), 3)
        let expanded = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let titleBottom = bar.convert(bar.bounds, to: controller.view).maxY
        let titleRect = CGRect(x: 16, y: titleBottom - 48, width: 180, height: 42)
            .applying(CGAffineTransform(scaleX: expanded.scale, y: expanded.scale))
        let titleImage = try XCTUnwrap(expanded.cgImage?.cropping(to: titleRect))
        var ink = [UInt8](repeating: 0, count: titleImage.width * titleImage.height * 4)
        let titleContext = try XCTUnwrap(CGContext(data: &ink, width: titleImage.width, height: titleImage.height,
            bitsPerComponent: 8, bytesPerRow: titleImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        titleContext.draw(titleImage, in: CGRect(x: 0, y: 0, width: titleImage.width, height: titleImage.height))
        let visibleInk = stride(from: 0, to: ink.count, by: 4).filter { dark ? ink[$0] > 160 : ink[$0] < 90 }.count
        XCTAssertGreaterThan(visibleInk, 400, "The bar material must not cover or blur the large title's ink")
        list.setContentOffset(CGPoint(x: 0, y: 300), animated: true)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertLessThan(bar.bounds.height, largeHeight - 25)
        XCTAssertTrue(list.isScrollEnabled)
        XCTAssertEqual(list.convert(list.bounds, to: controller.view).maxY, controller.view.bounds.maxY, accuracy: 2,
                       "The list must continue behind the floating account control, not stop above a bottom bar")
        let material = try XCTUnwrap(descendants(controller.view, of: UIVisualEffectView.self)
            .first { $0.accessibilityIdentifier == "history-header-material" })
        let categoryBar = try XCTUnwrap(descendants(controller.view, of: HistoryCategoryBar.self).first)
        let materialFrame = material.convert(material.bounds, to: controller.view)
        XCTAssertLessThanOrEqual(materialFrame.minY, 0)
        // Solid down to the category bar, then a deliberate fade past it so
        // rows dissolve into the header instead of meeting a hard line.
        XCTAssertEqual(materialFrame.maxY, categoryBar.convert(categoryBar.bounds, to: controller.view).maxY
                       + HistoryPagingController.headerFadeLength, accuracy: 1)
        XCTAssertEqual(material.alpha, 1)
        XCTAssertFalse(material.isUserInteractionEnabled)
        attach(controller.view, name: "History-\(dark ? "dark" : "light")-collapsed")
        let pinnedImage = snapshot(controller.view)
        let pinnedLabelRect = CGRect(x: 34, y: bar.convert(bar.bounds, to: controller.view).maxY + 20,
                                     width: 32, height: 24)
        list.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThan(try patchDifference(pinnedImage, pinnedLabelRect, snapshot(controller.view), pinnedLabelRect), 3,
                          "The category row remains pinned while reading the ledger")

        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        // Sample clear space beside, not on, the home indicator.
        let crop = try XCTUnwrap(cgImage.cropping(to: CGRect(x: 4 * image.scale,
            y: (image.size.height - 12) * image.scale, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        // The page ground itself (#EEEFEF light, black dark), carried
        // through the home-indicator area rather than a separate bottom bar.
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        SettingsTemplate.uiPageBackground
            .resolvedColor(with: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
            .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        XCTAssertEqual(Double(pixel[0]), Double(red * 255), accuracy: 2)
        XCTAssertEqual(Double(pixel[1]), Double(green * 255), accuracy: 2)
        XCTAssertEqual(Double(pixel[2]), Double(blue * 255), accuracy: 2)
    }

    @MainActor
    private func descendants<T: UIView>(_ view: UIView, of type: T.Type) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, of: type) }
    }

    @MainActor
    private func attach(_ view: UIView, name: String) {
        let attachment = XCTAttachment(image: snapshot(view))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func snapshot(_ view: UIView) -> UIImage {
        UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    private func patchDifference(_ first: UIImage, _ firstRect: CGRect,
                                 _ second: UIImage, _ secondRect: CGRect) throws -> Double {
        func pixels(_ image: UIImage, rect: CGRect) throws -> [UInt8] {
            let crop = try XCTUnwrap(image.cgImage?.cropping(to: rect.applying(
                CGAffineTransform(scaleX: image.scale, y: image.scale))))
            var data = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            let context = try XCTUnwrap(CGContext(data: &data, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return data
        }
        let a = try pixels(first, rect: firstRect)
        let b = try pixels(second, rect: secondRect)
        XCTAssertEqual(a.count, b.count)
        return zip(a, b).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(a.count)
    }
}

@Observable
private final class HistoryNavigationProbe {
    var showsHistory = false
}

private struct HistoryNavigationFixture: View {
    @Bindable var probe: HistoryNavigationProbe
    let ledger: PortfolioActivityLedger
    let prepared: HistoryPreparedLedger

    var body: some View {
        NavigationStack {
            TabView {
                Tab("Settings", systemImage: "person") {
                    SettingsPage { Text("Settings").frame(height: 1500) }
                        .navigationDestination(isPresented: $probe.showsHistory) {
                            HistoryView(previewLedger: ledger, prepared: prepared)
                        }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbarVisibility(.hidden, for: .tabBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Capsule().fill(.bar).frame(height: 56)
            }
        }
    }
}
