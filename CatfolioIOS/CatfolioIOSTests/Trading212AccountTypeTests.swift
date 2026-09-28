import XCTest
@testable import CatfolioIOS

/// Trading 212's API reports an account number and a currency, never whether
/// the account is a Stocks & Shares ISA. The credential slot a key is filed
/// under used to stand in for that answer, which labelled whichever account
/// was added second as Invest — an ISA included.
final class Trading212AccountTypeTests: XCTestCase {

    private func account(
        accountID: String,
        type: Trading212AccountType? = nil
    ) -> PortfolioAccount {
        PortfolioAccount(
            id: "Trading 212|\(accountID)", accountID: accountID, source: "Trading 212",
            name: "Trading 212 · 账户 2", baseCurrency: "GBP", positionCount: 1, transactionCount: 1,
            manualTransactionCount: 0, hasCSVImport: false, marketValueUSD: 100,
            accountTypeOverride: type?.rawValue
        )
    }

    func testTheChosenTypeWinsOverTheCredentialSlot() {
        XCTAssertEqual(account(accountID: "account-2", type: .stocksISA).accountType,
                       Trading212AccountType.stocksISA.displayName)
        XCTAssertEqual(account(accountID: "account-1", type: .invest).accountType,
                       Trading212AccountType.invest.displayName)
    }

    func testAnUnsetTypeIsNeverGuessedFromTheSlot() {
        for accountID in ["account-1", "account-2"] {
            let unset = account(accountID: accountID)
            XCTAssertNil(unset.chosenAccountType)
            XCTAssertEqual(unset.accountType, "未设置")
        }
    }

    func testAnAccountStillDecodesWithoutTheTypeField() throws {
        // Accounts saved before the connection asked for a type have no field.
        let legacy = """
        {"id":"Trading 212|account-1","accountID":"account-1","source":"Trading 212",
         "name":"Trading 212 · 账户 1","baseCurrency":"GBP","positionCount":0,
         "transactionCount":0,"manualTransactionCount":0,"hasCSVImport":false,"marketValueUSD":0}
        """
        let decoded = try JSONDecoder().decode(PortfolioAccount.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.chosenAccountType)

        let encoded = try JSONEncoder().encode(account(accountID: "account-1", type: .invest))
        XCTAssertEqual(try JSONDecoder().decode(PortfolioAccount.self, from: encoded).chosenAccountType, .invest)
    }

    func testAStoredTypeReachesTheAccountListAndSurvivesARename() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trading212-account-type-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalPortfolioStore(fileURL: directory.appendingPathComponent("portfolio.json"))
        let key = "Trading 212|account-2"
        _ = try await store.registerAccount(account(accountID: "account-2"))

        _ = try await store.setAccountTypeOverride(Trading212AccountType.stocksISA.rawValue, for: key)

        var document = try await store.load()
        XCTAssertEqual(document.accounts.first?.chosenAccountType, .stocksISA)
        XCTAssertEqual(document.accounts.first?.accountType, Trading212AccountType.stocksISA.displayName)

        _ = try await store.renameAccount(key, to: "Trading 212 · 橘子 12")
        document = try await store.load()
        XCTAssertEqual(document.accounts.first?.chosenAccountType, .stocksISA)
        XCTAssertEqual(document.accounts.first?.displayName, "Trading 212 · 橘子 12")
    }
}
