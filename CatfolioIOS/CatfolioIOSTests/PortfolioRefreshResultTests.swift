import XCTest
@testable import CatfolioIOS

final class PortfolioRefreshResultTests: XCTestCase {
    private func document(quoteTime: Date? = nil, shares: Double = 10) -> LocalPortfolioDocument {
        LocalPortfolioDocument(source: "CSV", updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            positions: [LocalPositionRecord(ticker: "REFRESH_TEST", name: "Refresh fixture", shares: shares,
                averageCost: 100, currency: "USD", quotePrice: 120, quoteCurrency: "USD", source: "CSV",
                openedDate: nil, accountID: "A", accountName: "A", quoteObservedAt: quoteTime)], snapshots: [])
    }

    func testOnlyNewlyAcceptedQuoteTimesCountAsUpdated() {
        let earlier = Date(timeIntervalSince1970: 1_780_000_000)
        let later = earlier.addingTimeInterval(60)
        let prior = document(quoteTime: earlier)
        let stale = document(quoteTime: earlier)
        let fresh = document(quoteTime: later)
        XCTAssertEqual(PortfolioRefreshResult.acceptedQuoteCount(before: prior, after: stale), 0)
        XCTAssertEqual(PortfolioRefreshResult.acceptedQuoteCount(before: prior, after: fresh), 1)
        XCTAssertEqual(PortfolioRefreshResult.acceptedQuoteCount(before: document(), after: fresh), 1)

        var duplicate = fresh
        duplicate.positions.append(fresh.positions[0])
        XCTAssertEqual(PortfolioRefreshResult.acceptedQuoteCount(before: prior, after: duplicate), 1,
                       "Two accounts holding one instrument are one quote update")
    }

    func testClassificationSeparatesLoadedHoldingsFromNewQuotes() {
        let prior = document()
        let edited = document(shares: 11)
        XCTAssertEqual(PortfolioRefreshResult.completed(previous: prior, loaded: edited,
            acceptedQuoteCount: 0, refreshedDisclosure: false, tracksQuotes: true), .portfolioLoadedWithoutNewQuotes)
        XCTAssertEqual(PortfolioRefreshResult.completed(previous: prior, loaded: prior,
            acceptedQuoteCount: 0, refreshedDisclosure: false, tracksQuotes: true), .unchangedQuotes)
        XCTAssertEqual(PortfolioRefreshResult.completed(previous: prior, loaded: prior,
            acceptedQuoteCount: 1, refreshedDisclosure: false, tracksQuotes: true), .quotesUpdated)
        XCTAssertEqual(PortfolioRefreshResult.completed(previous: prior, loaded: prior,
            acceptedQuoteCount: 0, refreshedDisclosure: true, tracksQuotes: false), .portfolioLoaded)
        XCTAssertEqual(PortfolioRefreshResult.completed(previous: prior, loaded: prior,
            acceptedQuoteCount: 0, refreshedDisclosure: false, tracksQuotes: false), .unchangedContent)
    }

    @MainActor
    func testFailedManualRetryKeepsExistingPresentation() async throws {
        actor Loader {
            var shouldFail = false
            let document: LocalPortfolioDocument
            init(_ document: LocalPortfolioDocument) { self.document = document }
            func fail() { shouldFail = true }
            func load() throws -> LocalPortfolioDocument {
                if shouldFail { throw LocalPortfolioError.writeFailed }
                return document
            }
        }
        let suite = "PortfolioRefreshResultTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: PublicInvestorPreferences.enabledKey)
        let loader = Loader(document())
        let model = AppModel(defaults: defaults, personalDocumentLoader: { try await loader.load() })
        await model.refreshPortfolio(refreshMarketData: false)
        let previousValue = try XCTUnwrap(model.overview?.summary.marketValue)
        await loader.fail()
        let result = await model.refreshPortfolioReportingResult(refreshMarketData: false)
        XCTAssertEqual(result, .failed(retainsData: true))
        XCTAssertEqual(model.overview?.summary.marketValue, previousValue)
        XCTAssertNotNil(model.portfolioError)
    }
}
