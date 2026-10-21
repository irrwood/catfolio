import SwiftUI
import UIKit
import XCTest
@testable import CatfolioIOS

final class PublicInvestorHistoryViewTests: XCTestCase {
    @MainActor
    func testAllSixPortraitsCoverLargestThreeScaleAvatarWithTransparency() throws {
        let catalog = try PublicInvestorCatalog.loaded.get()
        for investor in catalog.investors {
            let asset = try XCTUnwrap(PublicInvestorPortrait.assetName(for: investor.id))
            let image = try XCTUnwrap(UIImage(named: asset), investor.id)
            let pixels = try XCTUnwrap(image.cgImage)
            // The largest avatar is 72 pt: 216 px covers a 3x iPhone.
            XCTAssertEqual(pixels.width, 216, investor.id)
            XCTAssertEqual(pixels.height, 216, investor.id)
            XCTAssertTrue([CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .first, .last].contains(pixels.alphaInfo))
        }
        XCTAssertNil(PublicInvestorPortrait.assetName(for: "demo"))
    }

    @MainActor
    func testOriginalDateGroupedRowsRemainAndOptionsUseCompactCells() async throws {
        let catalog = try await PublicInvestorCatalogState.shared.get()
        let suite = "PublicInvestorHistory.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let scene = try await foregroundScene()
        let previous = scene.windows.first(where: \.isKeyWindow)
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        UserDefaults.standard.set("zh-Hans", forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey) }
        for (investorID, scheme, typeSize) in [
            ("ark", ColorScheme.light, DynamicTypeSize.large),
            ("pelosi", .dark, .large),
            ("pelosi", .light, .accessibility2),
            ("musk", .light, .large)
        ] {
            let document = PublicInvestorAccountAdapter.document(catalog: catalog, selection: investorID)
            let records = catalog.recentActivities(investorID: investorID)
            let extra = (records.first(where: \.isOption) ?? records.first).map { [$0] } ?? []
            let date = extra.first?.historyDate ?? "2026-10-20"
            let transactions = [
                LocalTransactionRecord(date: date, action: "BUY", ticker: "NVDA", quantity: 10, price: 150,
                    currency: "USD", source: PublicInvestorAccountAdapter.source, accountID: investorID, accountName: investorID, tradeID: "original-buy"),
                LocalTransactionRecord(date: date, action: "SELL", ticker: "AAPL", quantity: 2, price: 200,
                    currency: "USD", source: PublicInvestorAccountAdapter.source, accountID: investorID, accountName: investorID, tradeID: "original-sell"),
                LocalTransactionRecord(date: "2022-01-01", action: "DIVIDEND", ticker: "AAPL", quantity: 1, price: 20,
                    currency: "USD", source: PublicInvestorAccountAdapter.source, accountID: investorID, accountName: investorID, tradeID: "original-dividend")
            ]
            let ledger = PortfolioActivityLedger(accounts: document.accounts, transactions: transactions,
                                                 securityNames: ["NVDA": "NVIDIA", "AAPL": "Apple"])
            let prepared = try HistoryPreparedLedger.build(ledger: ledger,
                accountIDs: Set(document.accounts.map(\.id)), locale: Locale(identifier: "zh_Hans"))
            let controller = UIHostingController(rootView: NavigationStack {
                HistoryView(previewLedger: ledger, prepared: prepared,
                            publicHistory: PublicInvestorHistory(records: extra))
            }.environment(model).defaultAppStorage(defaults).environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, typeSize))
            let window = UIWindow(windowScene: scene)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(500))
            let paging = try XCTUnwrap(findPaging(controller))
            XCTAssertEqual(paging.selection, .all)
            let allPage = try XCTUnwrap(paging.children.first)
            let lists = descendants(allPage.view).compactMap { $0 as? UICollectionView }
            let list = try XCTUnwrap(lists.first)
            XCTAssertEqual(list.numberOfSections, 3, "Keep the summary and original date groups")
            XCTAssertEqual(list.numberOfItems(inSection: 1), 2 + extra.count, "Original trades and the missing disclosure share one date group")
            XCTAssertEqual(list.numberOfItems(inSection: 2), 1, "Earlier history must remain visible")
            if typeSize == .large {
                for cell in list.visibleCells where list.indexPath(for: cell)?.section == 1 {
                    XCTAssertLessThan(cell.bounds.height, 100, "History uses compact cells, never disclosure cards")
                }
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "investor-activity-\(investorID)-\(scheme)-\(typeSize)"
            attachment.lifetime = .keepAlways
            add(attachment)
            try image.pngData()?.write(to: URL(fileURLWithPath: "/tmp/catfolio-restored-history-\(investorID)-\(scheme)-\(typeSize).png"))
        }
    }

    @MainActor
    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor
    private func findPaging(_ controller: UIViewController) -> HistoryPagingController? {
        if let paging = controller as? HistoryPagingController { return paging }
        return controller.children.compactMap(findPaging).first
    }

    @MainActor
    private func foregroundScene() async throws -> UIWindowScene {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        if scene.activationState != .foregroundActive {
            UIApplication.shared.requestSceneSessionActivation(scene.session, userActivity: nil, options: nil)
            for _ in 0..<100 {
                if scene.activationState == .foregroundActive { break }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        return try XCTUnwrap(scene.activationState == .foregroundActive ? scene : nil,
                            "The investor test host must be foregrounded to capture the page")
    }
}
