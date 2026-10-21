import XCTest
@testable import CatfolioIOS

final class LocalPortfolioSyncStoreTests: XCTestCase {
    private var directory: URL!
    private var file: URL { directory.appendingPathComponent("portfolio.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PortfolioSync-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func position(_ account: String, ticker: String = "AAA") -> LocalPositionRecord {
        LocalPositionRecord(ticker: ticker, name: ticker, shares: 1, averageCost: 10, currency: "USD",
            quotePrice: 12, quoteCurrency: "USD", source: "CSV", openedDate: nil,
            accountID: account, accountName: account)
    }

    private func document(_ account: String) -> LocalPortfolioDocument {
        LocalPortfolioDocument(schemaVersion: 4, source: "CSV", updatedAt: Date(timeIntervalSince1970: 1_000),
            positions: [position(account)], snapshots: [])
    }

    func testCloudImportMergesAgainstLatestLocalCommitAndPersistsClocks() async throws {
        let store = LocalPortfolioStore(fileURL: file)
        _ = try await store.replace(positions: [position("local")], source: "CSV", replacingAccountsOnly: true)
        let merged = try await store.mergeFromCloud(document("remote"))
        XCTAssertEqual(Set(merged.accounts.map(\.id)), ["CSV|local", "CSV|remote"])
        let loaded = try await store.load()
        XCTAssertEqual(Set(loaded.accounts.map(\.id)), ["CSV|local", "CSV|remote"])
        XCTAssertEqual(loaded.syncMetadata, merged.syncMetadata)
    }

    func testCloudImportDoesNotAdvanceClocksOrRewriteIdenticalResult() async throws {
        let store = LocalPortfolioStore(fileURL: file)
        _ = try await store.mergeFromCloud(document("remote"))
        let before = try Data(contentsOf: file)
        let loaded = try await store.load()
        let after = try await store.mergeFromCloud(loaded)
        XCTAssertEqual(after, loaded)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    func testResetKeepsBackupAndRejectsStaleCloudData() async throws {
        let store = LocalPortfolioStore(fileURL: file)
        let stale = try await store.mergeFromCloud(document("remote"))
        let original = try Data(contentsOf: file)
        let backup = try await store.resetPortfolio()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup)), original)
        let merged = try await store.mergeFromCloud(stale)
        XCTAssertTrue(merged.positions.isEmpty)
        XCTAssertTrue(merged.accounts.isEmpty)
        XCTAssertNotNil(merged.syncMetadata?.deletedAccounts["CSV|remote"])
    }

    func testResetBeforeFirstDownloadStillPreventsOldCloudRestore() async throws {
        let store = LocalPortfolioStore(fileURL: file)
        let backup = try await store.resetPortfolio()
        XCTAssertNil(backup)
        let merged = try await store.mergeFromCloud(document("unknown"))
        XCTAssertTrue(merged.positions.isEmpty)
        XCTAssertTrue(merged.accounts.isEmpty)
    }

    func testRemoveAccountDoesNotReappearAndOtherAccountRemains() async throws {
        let store = LocalPortfolioStore(fileURL: file)
        let first = try await store.mergeFromCloud(document("first"))
        _ = try await store.mergeFromCloud(document("second"))
        _ = try await store.removeAccount("CSV|first")
        let merged = try await store.mergeFromCloud(first)
        XCTAssertEqual(merged.accounts.map(\.id), ["CSV|second"])
    }

    func testReplacingHistoryPersistsTransactionDeletion() async throws {
        let store = LocalPortfolioStore(fileURL: file)
        let row = LocalTransactionRecord(date: "2026-01-01", action: "BUY", ticker: "AAA", quantity: 1,
            price: 10, currency: "USD", source: "CSV", accountID: "account", accountName: "account", tradeID: "fill")
        let stale = try await store.replace(positions: [position("account")], source: "CSV", transactions: [row])
        _ = try await store.replace(positions: [position("account")], source: "CSV", transactions: [])
        let merged = try await store.mergeFromCloud(stale)
        XCTAssertTrue(merged.transactions?.isEmpty == true)
        XCTAssertNotNil(merged.syncMetadata?.deletedTransactions[row.id])
    }

    func testCommittedSavePostsNotificationAndIdenticalMergeDoesNot() async throws {
        let store = LocalPortfolioStore(fileURL: file)
        let changed = expectation(forNotification: .localPortfolioDidChange, object: store)
        _ = try await store.mergeFromCloud(document("remote"))
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let unchanged = expectation(forNotification: .localPortfolioDidChange, object: store)
        unchanged.isInverted = true
        let loaded = try await store.load()
        _ = try await store.mergeFromCloud(loaded)
        await fulfillment(of: [unchanged], timeout: 0.1)
    }

    func testFailedWriteDoesNotPublishAChange() async throws {
        let blockedParent = directory.appendingPathComponent("file-instead-of-folder")
        try Data("occupied".utf8).write(to: blockedParent)
        let store = LocalPortfolioStore(fileURL: blockedParent.appendingPathComponent("portfolio.json"))
        let changed = expectation(forNotification: .localPortfolioDidChange, object: store)
        changed.isInverted = true
        do {
            _ = try await store.mergeFromCloud(document("remote"))
            XCTFail("Expected an unwritable destination to fail")
        } catch {}
        await fulfillment(of: [changed], timeout: 0.1)
    }

    func testLegacyDocumentDecodesWithoutSyncMetadata() throws {
        let payload = Data(#"{"schemaVersion":1,"source":"local","updatedAt":"2026-01-01T00:00:00Z","positions":[],"snapshots":[]}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(LocalPortfolioDocument.self, from: payload)
        XCTAssertNil(document.syncMetadata)
        XCTAssertEqual(document.schemaVersion, 1)
    }
}

extension LocalPortfolioSyncStoreTests {
    private func trading212Document() -> LocalPortfolioDocument {
        var value = document("account-1")
        value.positions = value.positions.map { $0.assignedAccount(id: "account-1", name: "Broker", source: "Trading 212") }
        value.source = "Trading 212"
        return value
    }

    private func writeDocument(_ document: LocalPortfolioDocument, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: destination)
    }

    func testCloudPreparationBindsSlotsWithoutAdvancingClocksAndExcludesLocalFiles() async throws {
        try writeDocument(trading212Document(), to: file)
        let credentials = ["trading212.account-1.api-key": "key", "trading212.account-1.api-secret": "secret"]
        let store = LocalPortfolioStore(fileURL: file, readCredential: { credentials[$0] })
        let before = try await store.load()
        let prepared = try await store.prepareForCloudSync()
        XCTAssertEqual(prepared.updatedAt, before.updatedAt)
        XCTAssertTrue(prepared.syncMetadata?.accountBindings?["Trading 212|account-1"]?.hasPrefix("credential:") == true)
        let backup = try await store.backupPortfolio(reason: "test")
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try XCTUnwrap(backup).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let again = try await store.prepareForCloudSync()
        XCTAssertEqual(again, prepared)
        let rotated = LocalPortfolioStore(fileURL: file, readCredential: { _ in "rotated" })
        let afterRotation = try await rotated.prepareForCloudSync()
        XCTAssertEqual(afterRotation.syncMetadata?.accountBindings, prepared.syncMetadata?.accountBindings)
    }

    func testDifferentBrokerCredentialsCannotMergeTheSameLocalSlot() async throws {
        try writeDocument(trading212Document(), to: file)
        let store = LocalPortfolioStore(fileURL: file, readCredential: { _ in "local-credential" })
        var remote = try await store.prepareForCloudSync()
        remote.syncMetadata?.accountBindings?["Trading 212|account-1"] = "credential:other"
        do {
            _ = try await store.mergeFromCloud(remote)
            XCTFail("Different accounts sharing the same slot must not merge")
        } catch LocalPortfolioSyncError.accountConflict {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testExistingCredentialsBlockIncompatibleFirstCloudDownload() async throws {
        var remote = trading212Document()
        remote.syncMetadata = LocalPortfolioSyncMetadata(accountBindings: ["Trading 212|account-1": "credential:other"])
        let store = LocalPortfolioStore(fileURL: file, readCredential: { _ in "configured" })
        do {
            _ = try await store.mergeFromCloud(remote)
            XCTFail("First download must respect configured broker credentials")
        } catch LocalPortfolioSyncError.accountConflict {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testFreshDeviceRestoresRemoteBindingWithoutCredentials() async throws {
        var remote = trading212Document()
        remote.syncMetadata = LocalPortfolioSyncMetadata(accountBindings: ["Trading 212|account-1": "credential:remote"])
        let store = LocalPortfolioStore(fileURL: file, readCredential: { _ in nil })
        let restored = try await store.mergeFromCloud(remote)
        XCTAssertEqual(restored.syncMetadata?.accountBindings, remote.syncMetadata?.accountBindings)
        XCTAssertEqual(restored.positions.count, 1)
    }

    func testFreshDeviceRestoresPortfolioAfterSyncedKeyRotation() async throws {
        let accountKey = "Trading 212|account-1"
        let binding = "credential:" + String(repeating: "a", count: 64)
        var remote = trading212Document()
        remote.syncMetadata = LocalPortfolioSyncMetadata(accountBindings: [accountKey: binding])
        var credentials = ["trading212.account-1.api-key": "rotated-key", "trading212.account-1.api-secret": "rotated-secret"]
        let pairHash = try XCTUnwrap(CloudCredentialPolicy.trading212PairHash(id: "trading212.account-1", values: credentials))
        let marker = CloudCredentialPolicy.Trading212BindingPayload(binding: binding, pairHash: pairHash)
        credentials["trading212.account-1.portfolio-binding"] = String(decoding: try JSONEncoder().encode(marker), as: UTF8.self)
        let saved = credentials
        let store = LocalPortfolioStore(fileURL: file, readCredential: { saved[$0] })
        let restored = try await store.mergeFromCloud(remote)
        XCTAssertEqual(restored.positions.count, 1)
        XCTAssertEqual(restored.syncMetadata?.accountBindings?[accountKey], binding)
    }

    func testCancelledImportDoesNotCommit() async throws {
        let store = LocalPortfolioStore(fileURL: file)
        do {
            _ = try await store.mergeFromCloud(document("remote"), canCommit: { false })
            XCTFail("Cancelled import must not commit")
        } catch LocalPortfolioSyncError.cancelled {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

extension LocalPortfolioSyncStoreTests {
    func testReusingDeletedBrokerSlotCreatesNewBindingAndBlocksOldHistory() async throws {
        try writeDocument(trading212Document(), to: file)
        let originalStore = LocalPortfolioStore(fileURL: file, readCredential: { _ in "original-account" })
        let original = try await originalStore.prepareForCloudSync()
        let deleted = try await originalStore.removeAccount("Trading 212|account-1")
        let newStore = LocalPortfolioStore(fileURL: file, readCredential: { _ in "different-account" })
        let imported = try await newStore.replace(positions: trading212Document().positions, source: "Trading 212")
        XCTAssertNil(imported.syncMetadata?.accountBindings?["Trading 212|account-1"])
        let prepared = try await newStore.prepareForCloudSync()
        XCTAssertNotEqual(prepared.syncMetadata?.accountBindings, original.syncMetadata?.accountBindings)
        for stale in [original, deleted] {
            do {
                _ = try await newStore.mergeFromCloud(stale)
                XCTFail("A reused slot must not merge even with old deletion metadata")
            } catch LocalPortfolioSyncError.accountConflict {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }
}

extension LocalPortfolioSyncStoreTests {
    func testAutomaticCloudBackupsKeepFiveAndPreserveOtherArchives() async throws {
        let store = LocalPortfolioStore(fileURL: file)
        _ = try await store.mergeFromCloud(document("remote"))
        let protectedNames = [
            "portfolio-reset-keep.json", "portfolio-corrupt-keep.json",
            "portfolio-import-keep.json", "portfolio-manual-keep.json", "unrelated.json",
        ]
        for name in protectedNames {
            try Data(name.utf8).write(to: directory.appendingPathComponent(name))
        }
        let firstBackup = try await store.backupPortfolio(reason: "cloud-merge")
        let first = try XCTUnwrap(firstBackup)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: first.path)
        var latest: URL?
        for _ in 0..<7 { latest = try await store.backupPortfolio(reason: "cloud-merge") }
        let automatic = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("portfolio-cloud-merge-") }
        XCTAssertEqual(automatic.count, 5)
        XCTAssertTrue(automatic.contains(try XCTUnwrap(latest)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        for name in protectedNames {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), Data(name.utf8))
        }
    }
}
