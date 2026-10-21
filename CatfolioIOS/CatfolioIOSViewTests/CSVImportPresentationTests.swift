import SwiftUI
import Vision
import XCTest
@testable import CatfolioIOS

final class CSVImportPresentationTests: XCTestCase {
    func testHeaderOnlyFileHasNoImportableRows() throws {
        let file = try SelectedCSVFile(url: URL(fileURLWithPath: "/tmp/empty.csv"),
            data: Data("Date,Action,Ticker,Quantity,Price,Currency\n".utf8))
        XCTAssertFalse(file.hasDataRows)
        XCTAssertEqual(file.dataRowCount, 0)
    }

    /// Render the real completion component with parser-produced warnings,
    /// including a narrow screen and accessibility text. The warning report
    /// must take up space instead of silently showing a clean success state.
    @MainActor
    func testPartialImportWarningsRemainVisibleInBothLanguages() async throws {
        let previousLanguage = UserDefaults.standard.object(forKey: AppLanguage.preferenceKey)
        defer { UserDefaults.standard.set(previousLanguage, forKey: AppLanguage.preferenceKey) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let csv = "Date,Action,Ticker,Quantity,Price,Currency\n2024-01-02,BUY,TEST,10,100,USD\ninvalid,BUY,TEST,5,110,USD\ninvalid,SELL,TEST,2,120,USD\n"
        for language in ["zh-Hans", "en"] {
            UserDefaults.standard.set(language, forKey: AppLanguage.preferenceKey)
            let (_, transactions, result) = try LocalCSVImporter.parse(Data(csv.utf8))
            XCTAssertEqual(transactions.count, 1)
            XCTAssertEqual(result.warnings.count, 2)
            let clean = CSVImportResult(ok: result.ok, holdingsCount: result.holdingsCount,
                transactionsCount: result.transactionsCount, backupCreated: result.backupCreated,
                warnings: [], holdings: result.holdings)
            for large in [false, true] {
                let cleanHeight = try await render(clean, language: language, large: large,
                    in: window, capture: false)
                let warningHeight = try await render(result, language: language, large: large,
                    in: window, capture: true)
                XCTAssertGreaterThan(warningHeight, cleanHeight + 100,
                    "Both skipped-row notices must be rendered after a successful partial import")
            }
        }
    }

    /// Before anything is written, the preview shows each skipped row and
    /// each holding the import would remove, so a partly unreadable file
    /// cannot quietly drop a position.
    @MainActor
    func testPreviewShowsSkippedRowsAndRemovalsBeforeImporting() async throws {
        let csv = "Date,Action,Ticker,Quantity,Price,Currency\n2025-01-02,BUY,AAPL,10,150,USD\n2025-01-03,BUY,MSFT,abc,300,USD\n"
        let (incoming, transactions, result) = try LocalCSVImporter.parse(Data(csv.utf8))
        let previous = [incoming[0], LocalPositionRecord(ticker: "MSFT", name: "MSFT", shares: 4, averageCost: 300,
            currency: "USD", quotePrice: 300, quoteCurrency: "USD", source: "CSV", openedDate: "2025-01-03",
            accountID: nil, accountName: nil, accountCurrency: nil, brokerPnl: nil, brokerPnlCurrency: nil,
            brokerFxPnl: nil, brokerFxPnlCurrency: nil, fxPnl: nil, fxPnlCurrency: nil, fxPnlStatus: nil,
            fxPnlSource: nil)]
        let comparison = CSVImportPreview.changes(previous: previous, incoming: incoming)
        let preview = CSVImportPreview(positions: incoming, transactions: transactions, result: result,
                                       accountKey: "CSV|default", changes: comparison.changes,
                                       unchangedCount: comparison.unchanged)
        let host = UIHostingController(rootView: VStack(alignment: .leading, spacing: 16) {
            CSVImportPreviewSection(preview: preview)
        }.padding(16))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 900)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        XCTAssertEqual(preview.removedCount, 1)
        XCTAssertTrue(text.contains { $0.contains("MSFT") }, "The holding the import removes is listed: \(text)")
        // The skipped row's own line, with its row number.
        XCTAssertTrue(text.contains {
            let compact = $0.filter { !$0.isWhitespace }
            return compact.contains("Row3") || compact.contains("第3行")
        }, "The unreadable row and its reason are shown: \(text)")
        XCTAssertFalse(text.contains { $0.contains("accounts") }, "Holding counts read as holdings: \(text)")
    }

    @MainActor
    private func render(_ result: CSVImportResult, language: String, large: Bool,
                        in window: UIWindow, capture: Bool) async throws -> CGFloat {
        let host = UIHostingController(rootView:
            VStack(alignment: .leading, spacing: 16) {
                CSVImportResultSection(result: result)
            }
            .padding(16)
            .background(Color(uiColor: .systemGroupedBackground))
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, large ? .accessibility1 : .large)
            .environment(\.colorScheme, large ? .dark : .light))
        window.rootViewController = host
        window.makeKeyAndVisible()
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 10_000))
        window.frame = CGRect(origin: .zero, size: CGSize(width: 320, height: ceil(size.height)))
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        if capture {
            let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "csv-warnings-\(language)-\(large ? "large-dark" : "regular-light")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return size.height
    }
}
