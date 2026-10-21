import XCTest
@testable import CatfolioIOS

final class CloudPortfolioCryptoTests: XCTestCase {
    func testRoundTripEncryptsFinancialContentAndUsesIndependentVaultKey() throws {
        let keys = MemoryPortfolioKeys()
        let crypto = CloudPortfolioCrypto(keys: keys)
        let document = cloudTestDocument()
        let encrypted = try crypto.seal(document, account: "account-a")
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("PRIVATE-BROKER"))
        XCTAssertEqual(keys.values.count, 1)
        let opened = try crypto.open(encrypted, account: "account-a")
        XCTAssertEqual(opened.document, document)
        let second = try crypto.seal(document, account: "account-a", keyID: opened.keyID)
        XCTAssertNotEqual(encrypted, second, "Every upload uses a fresh authenticated nonce")
        XCTAssertEqual(keys.values.count, 1)
    }

    func testOversizedDocumentDoesNotCreateKeysOnRepeatedAttempts() {
        let keys = MemoryPortfolioKeys()
        let crypto = CloudPortfolioCrypto(keys: keys)
        let document = cloudTestDocument(source: String(repeating: "X", count: CloudPortfolioCrypto.maximumBytes + 1))
        for _ in 0..<2 {
            XCTAssertThrowsError(try crypto.seal(document, account: "a")) {
                guard case CloudPortfolioSyncError.tooLarge = $0 else { return XCTFail("Unexpected error") }
            }
        }
        XCTAssertTrue(keys.values.isEmpty)
    }

    func testMissingKeyDoesNotCreateReplacement() throws {
        let keys = MemoryPortfolioKeys()
        let encrypted = try CloudPortfolioCrypto(keys: keys).seal(cloudTestDocument(), account: "a")
        let newDevice = MemoryPortfolioKeys()
        XCTAssertThrowsError(try CloudPortfolioCrypto(keys: newDevice).open(encrypted, account: "a")) {
            guard case CloudPortfolioSyncError.missingKey = $0 else { return XCTFail("Unexpected error") }
        }
        XCTAssertTrue(newDevice.values.isEmpty)
    }

    func testTamperingAndCopyingToAnotherAppleAccountFailAuthentication() throws {
        let keys = MemoryPortfolioKeys()
        let crypto = CloudPortfolioCrypto(keys: keys)
        let encrypted = try crypto.seal(cloudTestDocument(), account: "a")
        var envelope = try JSONDecoder().decode(CloudPortfolioCrypto.Envelope.self, from: encrypted)
        keys.values["b." + envelope.keyID] = keys.values["a." + envelope.keyID]
        XCTAssertThrowsError(try crypto.open(encrypted, account: "b"))
        envelope.ciphertext[envelope.ciphertext.startIndex] ^= 1
        XCTAssertThrowsError(try crypto.open(JSONEncoder().encode(envelope), account: "a"))
    }

    func testUnknownVersionAndSyntheticDocumentsAreRejected() throws {
        let crypto = CloudPortfolioCrypto(keys: MemoryPortfolioKeys())
        var document = cloudTestDocument()
        document.isSynthetic = true
        XCTAssertThrowsError(try crypto.seal(document, account: "a"))
        document.isSynthetic = nil
        document.schemaVersion = 99
        XCTAssertThrowsError(try crypto.seal(document, account: "a"))
        let envelope = CloudPortfolioCrypto.Envelope(version: 99, keyID: UUID().uuidString, ciphertext: Data())
        XCTAssertThrowsError(try crypto.open(JSONEncoder().encode(envelope), account: "a")) {
            guard case CloudPortfolioSyncError.unsupportedVersion = $0 else { return XCTFail("Unexpected error") }
        }
    }
}

@MainActor
final class CloudPortfolioSyncTests: XCTestCase {
    func testEncryptedSecondDeviceRestoresAccountsAndPropagatesRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storeA = LocalPortfolioStore(fileURL: root.appendingPathComponent("a/portfolio.json"))
        let storeB = LocalPortfolioStore(fileURL: root.appendingPathComponent("b/portfolio.json"))
        let suiteA = "cloud-integration-a-\(UUID())"
        let suiteB = "cloud-integration-b-\(UUID())"
        let defaultsA = UserDefaults(suiteName: suiteA)!
        let defaultsB = UserDefaults(suiteName: suiteB)!
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
            try? FileManager.default.removeItem(at: root)
        }
        let position = LocalPositionRecord(ticker: "TEST", name: "Test", shares: 2,
            averageCost: 100, currency: "USD", quotePrice: 120, quoteCurrency: "USD",
            source: "IBKR Flex", openedDate: nil, accountID: "U111", accountName: "My account")
        _ = try await storeA.replace(positions: [position], source: "IBKR Flex")
        let remote = MemoryPortfolioRemote()
        let crypto = CloudPortfolioCrypto(keys: MemoryPortfolioKeys())
        let syncA = CloudPortfolioSync(defaults: defaultsA, transport: remote, crypto: crypto,
            identity: { "a" }, load: { try await storeA.load() },
            merge: { document, lease in try await storeA.mergeFromCloud(document, canCommit: { lease.isValid }) })
        let syncB = CloudPortfolioSync(defaults: defaultsB, transport: remote, crypto: crypto,
            identity: { "a" }, load: { try await storeB.load() },
            merge: { document, lease in try await storeB.mergeFromCloud(document, canCommit: { lease.isValid }) })
        defer { syncA.stop(); syncB.stop() }
        await syncA.setEnabled(true)
        await syncB.setEnabled(true)
        XCTAssertEqual(syncA.status, .synced)
        XCTAssertEqual(syncB.status, .synced)
        let restored = try await storeB.load()
        XCTAssertEqual(restored.positions.first?.shares, 2)
        XCTAssertEqual(restored.accounts.first?.accountID, "U111")
        XCTAssertFalse(defaultsB.bool(forKey: CloudCredentialSync.enabledKey))
        _ = try await storeB.removeAccount(position.accountKey)
        await syncB.refresh()
        await syncA.refresh()
        let removed = try await storeA.load()
        XCTAssertTrue(removed.positions.isEmpty)
        XCTAssertTrue(removed.accounts.isEmpty)
    }

    func testDefaultOffNeverReadsAccountCloudOrKeys() async {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        fixture.sync.start()
        await fixture.sync.refresh()
        XCTAssertFalse(fixture.sync.isEnabled)
        XCTAssertEqual(fixture.identities, 0)
        XCTAssertEqual(fixture.remote.fetches, 0)
        XCTAssertTrue(fixture.keys.values.isEmpty)
    }

    func testPortfolioOptInWorksWithoutAPIKeyOrPreferenceOptIn() async throws {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        await fixture.sync.setEnabled(true)
        XCTAssertEqual(fixture.sync.status, .synced)
        XCTAssertFalse(fixture.defaults.bool(forKey: CloudCredentialSync.enabledKey))
        XCTAssertFalse(fixture.defaults.bool(forKey: CloudPreferences.enabledKey))
        let saved = try XCTUnwrap(fixture.remote.record)
        XCTAssertEqual(try fixture.crypto.open(saved.payload, account: "a").document, fixture.local)
        XCTAssertNotNil(fixture.sync.lastSyncedAt)
        await fixture.sync.setEnabled(false)
        let count = fixture.remote.fetches
        await fixture.sync.refresh()
        XCTAssertEqual(fixture.remote.fetches, count)
        XCTAssertNotNil(fixture.remote.record)
        XCTAssertFalse(fixture.keys.values.isEmpty)
    }

    func testFailedFirstUploadReusesPendingKeyAcrossRetriesAndRelaunch() async throws {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        fixture.remote.failuresRemaining = 2
        await fixture.sync.setEnabled(true)
        XCTAssertEqual(fixture.sync.status, .unavailable)
        let pendingID = try XCTUnwrap((fixture.defaults.dictionary(forKey: CloudPortfolioSync.pendingKeysKey) as? [String: String])?["a"])
        XCTAssertEqual(fixture.keys.values.count, 1)
        await fixture.sync.refresh()
        XCTAssertEqual(fixture.sync.status, .unavailable)
        XCTAssertEqual(fixture.keys.values.count, 1)
        fixture.sync.stop()
        let relaunched = CloudPortfolioSync(defaults: fixture.defaults, transport: fixture.remote, crypto: fixture.crypto,
            identity: { "a" }, load: { fixture.local }, merge: { document, _ in document }, center: NotificationCenter())
        defer { relaunched.stop() }
        await relaunched.refresh()
        XCTAssertEqual(relaunched.status, .synced)
        XCTAssertEqual(fixture.keys.values.count, 1)
        XCTAssertEqual(fixture.remote.attemptedKeyIDs, [pendingID, pendingID, pendingID])
        XCTAssertNil(fixture.defaults.object(forKey: CloudPortfolioSync.pendingKeysKey))
    }

    func testRemoteWinnerOverridesPendingKeyAndMissingWinnerNeverUsesPendingKey() async throws {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        fixture.remote.failuresRemaining = 1
        await fixture.sync.setEnabled(true)
        let pendingID = try XCTUnwrap((fixture.defaults.dictionary(forKey: CloudPortfolioSync.pendingKeysKey) as? [String: String])?["a"])
        fixture.sync.stop()

        let winnerKeys = MemoryPortfolioKeys()
        let winnerCrypto = CloudPortfolioCrypto(keys: winnerKeys)
        let winnerPayload = try winnerCrypto.seal(cloudTestDocument(source: "OTHER-BROKER"), account: "a")
        let winnerID = try JSONDecoder().decode(CloudPortfolioCrypto.Envelope.self, from: winnerPayload).keyID
        fixture.remote.record = .init(payload: winnerPayload, systemFields: nil)
        let retry = CloudPortfolioSync(defaults: fixture.defaults, transport: fixture.remote, crypto: fixture.crypto,
            identity: { "a" }, load: { fixture.local }, merge: { _, _ in fixture.local }, center: NotificationCenter())
        defer { retry.stop() }
        await retry.refresh()
        XCTAssertEqual(retry.status, .waitingForKey)
        XCTAssertEqual(fixture.remote.saves, 1)
        XCTAssertEqual(fixture.keys.values.count, 1)
        XCTAssertEqual((fixture.defaults.dictionary(forKey: CloudPortfolioSync.pendingKeysKey) as? [String: String])?["a"], pendingID)
        XCTAssertEqual(fixture.remote.record?.payload, winnerPayload)

        fixture.keys.values.merge(winnerKeys.values, uniquingKeysWith: { _, value in value })
        await retry.refresh()
        XCTAssertEqual(retry.status, .synced)
        XCTAssertEqual(fixture.keys.values.count, 2)
        XCTAssertEqual(fixture.remote.attemptedKeyIDs.last, winnerID)
        XCTAssertNotEqual(winnerID, pendingID)
        XCTAssertNil(fixture.defaults.object(forKey: CloudPortfolioSync.pendingKeysKey))
        let savedPayload = try XCTUnwrap(fixture.remote.record?.payload)
        XCTAssertEqual(try fixture.crypto.open(savedPayload, account: "a").keyID, winnerID)
    }

    func testPendingFirstVaultKeysAreStrictlyAccountScoped() async throws {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        let otherAccountID = UUID().uuidString
        fixture.defaults.set(["b": otherAccountID], forKey: CloudPortfolioSync.pendingKeysKey)
        await fixture.sync.setEnabled(true)
        XCTAssertEqual(fixture.sync.status, .synced)
        let payload = try XCTUnwrap(fixture.remote.record?.payload)
        XCTAssertNotEqual(try fixture.crypto.open(payload, account: "a").keyID, otherAccountID)
        XCTAssertEqual(fixture.defaults.dictionary(forKey: CloudPortfolioSync.pendingKeysKey) as? [String: String], ["b": otherAccountID])
    }

    func testOversizedPayloadReportsSizeLimitWithoutChangingEitherCopy() async {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        let original = fixture.local
        fixture.remote.fetchError = .tooLarge
        await fixture.sync.setEnabled(true)
        XCTAssertEqual(fixture.sync.status, .tooLarge)
        XCTAssertEqual(fixture.local, original)
        XCTAssertTrue(fixture.keys.values.isEmpty)
        XCTAssertEqual(fixture.remote.saves, 0)
        XCTAssertEqual(fixture.merges, 0)
    }

    func testDelayedKeyLeavesBothCopiesUntouchedThenRecovers() async throws {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        let otherKeys = MemoryPortfolioKeys()
        let payload = try CloudPortfolioCrypto(keys: otherKeys).seal(cloudTestDocument(source: "OTHER-BROKER"), account: "a")
        fixture.remote.record = .init(payload: payload, systemFields: nil)
        let original = fixture.local
        await fixture.sync.setEnabled(true)
        XCTAssertEqual(fixture.sync.status, .waitingForKey)
        XCTAssertEqual(fixture.local, original)
        XCTAssertEqual(fixture.remote.saves, 0)
        XCTAssertEqual(fixture.merges, 0)
        fixture.keys.values = otherKeys.values
        await fixture.sync.refresh()
        XCTAssertEqual(fixture.sync.status, .synced)
        XCTAssertEqual(fixture.merges, 1)
    }

    func testCorruptCloudPayloadNeverReplacesLocalOrOverwritesCloud() async {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        fixture.remote.record = .init(payload: Data("broken".utf8), systemFields: nil)
        let original = fixture.local
        await fixture.sync.setEnabled(true)
        XCTAssertEqual(fixture.sync.status, .invalidData)
        XCTAssertEqual(fixture.local, original)
        XCTAssertEqual(fixture.remote.saves, 0)
        XCTAssertEqual(fixture.merges, 0)
    }

    func testAccountSwitchBlocksEvenExplicitReenableWithOldLocalCopy() async {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        await fixture.sync.setEnabled(true)
        let saves = fixture.remote.saves
        fixture.account = "b"
        fixture.sync.invalidateAccount()
        await fixture.sync.refresh()
        XCTAssertEqual(fixture.sync.status, .accountChanged)
        XCTAssertFalse(fixture.sync.isEnabled)
        await fixture.sync.setEnabled(true)
        XCTAssertEqual(fixture.sync.status, .accountChanged)
        XCTAssertEqual(fixture.defaults.string(forKey: CloudPortfolioSync.ownerKey), "a")
        XCTAssertEqual(fixture.remote.saves, saves)
        fixture.account = "a"
        await fixture.sync.setEnabled(true)
        XCTAssertEqual(fixture.sync.status, .synced)
    }

    func testDisablingWhileDownloadAwaitsPreventsLateMergeAndUpload() async {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        fixture.remote.suspendFetch = true
        let enable = Task { await fixture.sync.setEnabled(true) }
        while fixture.remote.continuation == nil { await Task.yield() }
        await fixture.sync.setEnabled(false)
        fixture.remote.continuation?.resume()
        await enable.value
        XCTAssertFalse(fixture.sync.isEnabled)
        XCTAssertEqual(fixture.sync.status, .off)
        XCTAssertEqual(fixture.merges, 0)
        XCTAssertEqual(fixture.remote.saves, 0)
    }

    func testConflictRefetchesBeforeRetryAndRetriesAreBounded() async {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        fixture.remote.conflictsRemaining = 1
        await fixture.sync.setEnabled(true)
        XCTAssertEqual(fixture.remote.fetches, 2)
        XCTAssertEqual(fixture.sync.status, .synced)
        fixture.remote.record = nil
        fixture.remote.conflictsRemaining = 10
        await fixture.sync.refresh()
        XCTAssertEqual(fixture.remote.fetches, 5)
        XCTAssertEqual(fixture.sync.status, .unavailable)
    }

    func testIdentityChangeDuringDownloadCannotApplyOtherAccountsData() async throws {
        let fixture = PortfolioSyncFixture()
        defer { fixture.clean() }
        fixture.remote.record = .init(payload: try fixture.crypto.seal(cloudTestDocument(), account: "a"), systemFields: nil)
        fixture.remote.onFetch = { fixture.account = "b" }
        await fixture.sync.setEnabled(true)
        XCTAssertEqual(fixture.sync.status, .accountChanged)
        XCTAssertEqual(fixture.merges, 0)
        XCTAssertEqual(fixture.remote.saves, 0)
    }
}

private func cloudTestDocument(source: String = "PRIVATE-BROKER") -> LocalPortfolioDocument {
    LocalPortfolioDocument(schemaVersion: 4, source: source, updatedAt: Date(timeIntervalSince1970: 100),
                           positions: [], snapshots: [])
}

private final class MemoryPortfolioKeys: PortfolioEncryptionKeyStore {
    var values: [String: Data] = [:]
    func read(id: String, account: String) throws -> Data? { values[account + "." + id] }
    func write(_ data: Data, id: String, account: String) throws { values[account + "." + id] = data }
}

@MainActor
private final class MemoryPortfolioRemote: CloudPortfolioTransport {
    var record: CloudPortfolioRemoteRecord?
    var fetches = 0
    var saves = 0
    var conflictsRemaining = 0
    var failuresRemaining = 0
    var fetchError: CloudPortfolioSyncError?
    var attemptedKeyIDs: [String] = []
    var suspendFetch = false
    var continuation: CheckedContinuation<Void, Never>?
    var onFetch: (() -> Void)?
    func fetch(account: String) async throws -> CloudPortfolioRemoteRecord? {
        fetches += 1
        if let fetchError { throw fetchError }
        onFetch?()
        if suspendFetch { await withCheckedContinuation { continuation = $0 } }
        return record
    }
    func save(_ payload: Data, replacing: CloudPortfolioRemoteRecord?, account: String) async throws {
        saves += 1
        attemptedKeyIDs.append(try JSONDecoder().decode(CloudPortfolioCrypto.Envelope.self, from: payload).keyID)
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw CloudPortfolioSyncError.unavailable
        }
        if conflictsRemaining > 0 {
            conflictsRemaining -= 1
            throw CloudPortfolioSyncError.conflict
        }
        record = .init(payload: payload, systemFields: nil)
    }
}

@MainActor
private final class PortfolioSyncFixture {
    let suite = "portfolio-cloud-tests-\(UUID())"
    lazy var defaults = UserDefaults(suiteName: suite)!
    let keys = MemoryPortfolioKeys()
    let remote = MemoryPortfolioRemote()
    let center = NotificationCenter()
    var crypto: CloudPortfolioCrypto { .init(keys: keys) }
    var account = "a"
    var identities = 0
    var merges = 0
    var local = cloudTestDocument()
    lazy var sync = CloudPortfolioSync(defaults: defaults, transport: remote, crypto: crypto,
        identity: { [unowned self] in identities += 1; return account },
        load: { [unowned self] in local },
        merge: { [unowned self] document, lease in
            guard lease.isValid else { throw CloudPortfolioSyncError.cancelled }
            merges += 1
            local = document
            return local
        }, center: center)
    func clean() { sync.stop(); defaults.removePersistentDomain(forName: suite) }
}
