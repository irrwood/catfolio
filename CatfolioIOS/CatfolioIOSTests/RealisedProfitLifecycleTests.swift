import XCTest
@testable import CatfolioIOS

@MainActor
final class RealisedProfitLifecycleTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "RealisedProfitLifecycleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func fixture() -> LocalPortfolioDocument {
        let positions = ["A", "B"].map { account in
            LocalPositionRecord(ticker: "RESULT_TEST", name: "Result fixture", shares: 1,
                averageCost: 100, currency: "USD", quotePrice: 120, quoteCurrency: "USD",
                source: "CSV", openedDate: nil, accountID: account, accountName: account)
        }
        let rows: [LocalTransactionRecord] = [("A", 25.0), ("B", 80.0)].flatMap { account, result -> [LocalTransactionRecord] in
            [sale(account: account, result: result, id: "reported"),
             sale(account: account, result: nil, id: "missing")]
        }
        return LocalPortfolioDocument(source: "CSV", updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            positions: positions, snapshots: [], transactions: rows)
    }

    private func sale(account: String, result: Double?, id: String) -> LocalTransactionRecord {
        LocalTransactionRecord(date: "2026-05-01", action: "SELL", ticker: "RESULT_TEST",
            quantity: 1, price: 125, currency: "USD", source: "CSV", accountID: account,
            accountName: account, tradeID: id, realisedProfitLoss: result,
            realisedProfitLossCurrency: result == nil ? nil : "USD")
    }

    private func cachedSnapshot(for document: LocalPortfolioDocument) throws -> PortfolioPresentationSnapshot {
        let presentation = try LocalPortfolioEngine.presentation(for: document)
        let chart = PortfolioChartResponse(positionCount: document.positions.count,
            positionHistory: .init(available: true, rows: []),
            currentPoint: .init(dateText: "2026-05-01", marketValue: 120, cost: 100), warning: nil)
        return PortfolioPresentationSnapshot(overview: presentation.0, chart: chart, holdings: presentation.2,
            dailyChanges: [:], benchmark: nil, updatedAt: document.updatedAt,
            savedAt: Date(timeIntervalSince1970: 1_780_000_100))
    }

    func testColdCacheRestoreRecomputesResultsForSelectedAccounts() async throws {
        let input = fixture()
        let accountKeys: Set<String> = ["CSV|A"]
        defaults.set(try JSONEncoder().encode(Array(accountKeys)), forKey: "catfolio.selectedAccounts")
        let cache = PortfolioPresentationCache(directory: directory)
        let snapshot = try cachedSnapshot(for: input.scoped(to: accountKeys))
        try await cache.save(snapshot, document: input,
            context: .init(source: .personal, accountKeys: accountKeys, language: ContentLanguage.current))

        let model = AppModel(defaults: defaults, personalDocumentLoader: { input }, presentationCache: cache)
        await model.refreshPortfolio(refreshMarketData: false)

        XCTAssertEqual(model.portfolioCachedAt, snapshot.savedAt, "This must exercise the disk-cache path")
        XCTAssertEqual(model.selectedAccountKeys, accountKeys)
        XCTAssertEqual(model.realisedProfit, 25)
        XCTAssertEqual(model.realisedProfitGaps, 1)
    }

    func testSourceSwitchClearsResultsAndWarmRestoreUsesItsOwnLedger() async throws {
        let input = fixture()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { input },
            personalDocumentResetter: { nil }, presentationCache: PortfolioPresentationCache(directory: directory))
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.realisedProfit, 105)
        XCTAssertEqual(model.realisedProfitGaps, 2)

        // Both transitions are synchronous: the incoming source has not had
        // an opportunity to finish a background refresh and hide stale state.
        model.setPortfolioMode(enabled: true, selection: "demo")
        XCTAssertTrue(model.holdings.isEmpty)
        XCTAssertTrue(model.realisedProfit.isNaN)
        XCTAssertEqual(model.realisedProfitGaps, 0)

        model.setPortfolioMode(enabled: false, selection: "demo")
        XCTAssertFalse(model.holdings.isEmpty)
        XCTAssertEqual(model.realisedProfit, 105)
        XCTAssertEqual(model.realisedProfitGaps, 2)
        // Cancel the scheduled mode refresh before it can make a network call.
        try await model.resetLocalPortfolio()
    }

    func testSuccessfulResetClearsResultsAndPreservesOriginalLedgerInBackup() async throws {
        let input = fixture()
        let portfolioURL = directory.appendingPathComponent("portfolio.json")
        let store = LocalPortfolioStore(fileURL: portfolioURL)
        _ = try await store.replace(positions: input.positions, source: input.source, transactions: input.transactions)
        let model = AppModel(defaults: defaults, personalDocumentLoader: { try await store.load() },
            personalDocumentResetter: { try await store.resetPortfolio() },
            presentationCache: PortfolioPresentationCache(directory: directory.appendingPathComponent("cache")))
        await model.refreshPortfolio(refreshMarketData: false)
        XCTAssertEqual(model.realisedProfit, 105)
        XCTAssertEqual(model.realisedProfitGaps, 2)

        try await model.resetLocalPortfolio()

        XCTAssertTrue(model.realisedProfit.isNaN)
        XCTAssertEqual(model.realisedProfitGaps, 0)
        XCTAssertTrue(model.accounts.isEmpty)
        let reset = try await store.load()
        XCTAssertTrue(reset.positions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: portfolioURL.path))
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("portfolio-reset-") })
        let recovered = try await LocalPortfolioStore(fileURL: backup).load()
        XCTAssertEqual(recovered.transactions?.count, input.transactions?.count)
    }

    func testFailedResetKeepsDisplayedResults() async throws {
        let input = fixture()
        let model = AppModel(defaults: defaults, personalDocumentLoader: { input },
            personalDocumentResetter: { throw CocoaError(.fileWriteNoPermission) },
            presentationCache: PortfolioPresentationCache(directory: directory))
        await model.refreshPortfolio(refreshMarketData: false)

        do {
            try await model.resetLocalPortfolio()
            XCTFail("A failed archive must fail the reset")
        } catch {
            XCTAssertEqual(model.realisedProfit, 105)
            XCTAssertEqual(model.realisedProfitGaps, 2)
            XCTAssertFalse(model.accounts.isEmpty)
        }
    }
}
