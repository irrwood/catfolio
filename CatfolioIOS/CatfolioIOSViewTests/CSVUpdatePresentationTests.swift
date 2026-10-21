import SwiftUI
import Vision
import XCTest
@testable import CatfolioIOS

final class CSVUpdatePresentationTests: XCTestCase {
    @MainActor
    func testConflictShowsBothVersionsAndRequiresAResolution() async throws {
        let old = LocalTransactionRecord(date: "2025-01-02", action: "BUY", ticker: "TEST", quantity: 10,
            price: 100, currency: "USD", source: "CSV", accountID: "A", accountName: "A",
            tradeID: "fill-1", entryMethod: "csv")
        let corrected = LocalTransactionRecord(date: old.date, action: old.action, ticker: old.ticker,
            quantity: 12, price: 110, currency: old.currency, source: old.source, accountID: old.accountID,
            accountName: old.accountName, tradeID: old.tradeID, entryMethod: "csv")
        let merged = CSVTransactionMerger.merge(existing: [old], incoming: [corrected], mode: .merge)
        XCTAssertTrue(merged.unresolved)
        XCTAssertEqual(merged.conflicts.first?.allowsReplacement, true)
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey) }
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            let text = try await render(CSVConflictSection(conflicts: merged.conflicts, onResolve: nil),
                language: language, large: false, name: "csv-conflict-\(language)")
            XCTAssertTrue(text.contains("TEST"), text)
            XCTAssertTrue(text.contains("100"), text)
            XCTAssertTrue(text.contains("110"), text)
            XCTAssertTrue(text.contains("Choose") || text.contains("请选择"), text)
        }
    }

    @MainActor
    func testUpdateHistoryAndCountsRenderAtAccessibilitySize() async throws {
        let counts = CSVImportCounts(added: 12, duplicate: 86, updated: 2)
        let info = CSVImportInfo(importedAt: Date(timeIntervalSince1970: 1_760_000_000),
            filename: "activity.csv", format: "交易记录 CSV", fileHash: "fixture",
            sourceAccountID: nil, firstDate: "2025-01-02", lastDate: "2025-10-09", counts: counts)
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey) }
        UserDefaults.standard.set("en", forKey: AppLanguage.preferenceKey)
        let text = try await render(VStack(alignment: .leading, spacing: 20) {
            CSVUpdateOptionsSection(mode: .constant(.merge), info: info)
            CSVImportCountsSection(counts: counts)
        }, language: "en", large: true, name: "csv-update-large")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("activity.csv"), text)
        XCTAssertTrue(text.contains("86"), text)
        XCTAssertTrue(text.contains("2025"), text)
    }

    @MainActor
    private func render<Content: View>(_ content: Content, language: String,
                                      large: Bool, name: String) async throws -> String {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: VStack(alignment: .leading, spacing: 16) {
            content
        }.padding(16)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, large ? .accessibility1 : .large))
        host.safeAreaRegions = []
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 10_000))
        window.frame = CGRect(origin: .zero, size: CGSize(width: 390, height: ceil(size.height)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let imageURL = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try image.pngData()?.write(to: imageURL)
        print("CSV_PREVIEW_IMAGE \(imageURL.path)")
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = language == "zh-Hans" ? ["zh-Hans", "en-US"] : ["en-US", "zh-Hans"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
