import XCTest
@testable import CatfolioIOS

/// A saved analysis belongs to the accounts and data it was made from: it
/// survives a restart, and another account or demo data never reads it.
final class ResearchAnalysisCacheTests: XCTestCase {
    private func report(_ holdings: Int) -> PortfolioAttentionReport {
        PortfolioAttentionReport(generatedAt: Date(timeIntervalSince1970: 1_790_000_000), holdingsCount: holdings,
                                 noMaterialChangeCount: holdings, attentionRows: [], warnings: [])
    }

    func testPersistenceAndScopeIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResearchCache-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let first = ResearchAnalysisCache(directory: directory)
        let empty = await first.load(scope: "real-invest")
        XCTAssertNil(empty)
        try await first.save(report(3), scope: "real-invest")

        let reopened = ResearchAnalysisCache(directory: directory)
        let persisted = await reopened.load(scope: "real-invest")
        XCTAssertEqual(persisted?.holdingsCount, 3)
        let otherAccount = await reopened.load(scope: "real-isa")
        let demo = await reopened.load(scope: "demo-invest")
        XCTAssertNil(otherAccount)
        XCTAssertNil(demo)

        try await reopened.save(report(5), scope: "real-invest")
        let refreshed = await first.load(scope: "real-invest")
        XCTAssertEqual(refreshed?.holdingsCount, 5, "A refresh replaces the saved analysis")
    }
}
