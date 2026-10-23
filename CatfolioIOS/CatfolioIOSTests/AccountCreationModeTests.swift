import XCTest
@testable import CatfolioIOS

@MainActor
final class AccountCreationModeTests: XCTestCase {
    func testCreationSwitchesPublicAndDemoModesToPersonalAndKeepsTheirSelection() async throws {
        for selection in ["pelosi", "demo"] {
            let suite = "account-creation-mode-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(selection != "demo", forKey: PublicInvestorPreferences.enabledKey)
            defaults.set(selection == "demo", forKey: "catfolio.fakeDataMode")
            defaults.set(selection, forKey: PublicInvestorPreferences.selectionKey)
            let account = PortfolioAccount(id: "Trading 212|account-1", accountID: "account-1",
                source: "Trading 212", name: "Personal account", baseCurrency: "USD",
                positionCount: 0, transactionCount: 0, manualTransactionCount: 0,
                hasCSVImport: false, marketValueUSD: 0)
            var personal = LocalPortfolioDocument.empty
            personal.knownAccounts = [account]
            let input = personal
            let model = AppModel(defaults: defaults, personalDocumentLoader: { input })
            XCTAssertTrue(model.isPublicInvestorMode || model.isFakeDataMode)

            await model.prepareForAccountCreation()

            XCTAssertEqual(model.portfolioSource, .personal)
            XCTAssertFalse(model.isPublicInvestorMode)
            XCTAssertFalse(model.isFakeDataMode)
            XCTAssertFalse(defaults.bool(forKey: PublicInvestorPreferences.enabledKey))
            XCTAssertFalse(defaults.bool(forKey: "catfolio.fakeDataMode"))
            XCTAssertEqual(model.publicInvestorSelection, selection)
            XCTAssertEqual(defaults.string(forKey: PublicInvestorPreferences.selectionKey), selection)
            XCTAssertEqual(model.accounts.map(\.id), [account.id])
            XCTAssertEqual(model.fullDocument.knownAccounts, input.knownAccounts)
            XCTAssertFalse(model.isPortfolioLoading)
            XCTAssertFalse(model.isPortfolioChartLoading)
            XCTAssertNil(model.portfolioSourceTask)
        }
    }
}
