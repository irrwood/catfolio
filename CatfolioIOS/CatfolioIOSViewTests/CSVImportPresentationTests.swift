import SwiftUI
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
