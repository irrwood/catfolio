import XCTest
@testable import CatfolioIOS

@MainActor
final class CloudCredentialSyncTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var storage: MemoryCredentialStorage!

    override func setUp() async throws {
        suite = "credential-sync-tests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        storage = MemoryCredentialStorage()
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func sync(identity: @escaping () async throws -> String = { "apple-account-a" }) -> CloudCredentialSync {
        CloudCredentialSync(defaults: defaults, storage: storage, center: NotificationCenter(), accountIdentity: identity,
            connectedConnectionIDs: { ["trading212.account-1", "trading212.account-2", "ibkr.flex.account.U12345"] })
    }
    private func serviceRecord(_ value: String) -> CloudCredentialRecord {
        .init(connection: .init(secrets: [LocalServiceKeys.fmp: value], configuration: [:]))
    }

    func testDefaultOffDoesNotReadLocalSecretsOrOpenCloud() async {
        let subject = sync()
        subject.start()
        await subject.refresh()
        XCTAssertFalse(subject.isEnabled)
        XCTAssertEqual(storage.localReads, 0)
        XCTAssertEqual(storage.remoteReads, 0)
        XCTAssertEqual(storage.remoteWrites, 0)
    }

    func testEnablingCopiesExistingLocalKeyAndKeepsOriginal() async {
        storage.local[LocalServiceKeys.fmp] = "local-secret"
        let subject = sync()
        await subject.setEnabled(true)
        XCTAssertEqual(storage.cloud["apple-account-a"]?["service.fmp"]?.connection?.secrets[LocalServiceKeys.fmp], "local-secret")
        XCTAssertEqual(storage.local[LocalServiceKeys.fmp], "local-secret")
        XCTAssertEqual(defaults.string(forKey: CloudCredentialSync.ownerKey), "apple-account-a")
    }

    func testFailedMigrationRetainsUsableLocalSecretAndRetries() async {
        storage.local[LocalServiceKeys.fmp] = "local-secret"
        storage.failCloudWrites = true
        let subject = sync()
        await subject.setEnabled(true)
        XCTAssertEqual(storage.local[LocalServiceKeys.fmp], "local-secret")
        XCTAssertNil(storage.cloud["apple-account-a"]?["service.fmp"])
        XCTAssertNil(defaults.dictionary(forKey: CloudCredentialSync.baselineKey)?["service.fmp"])
        storage.failCloudWrites = false
        await subject.refresh()
        XCTAssertEqual(storage.cloud["apple-account-a"]?["service.fmp"]?.connection?.secrets[LocalServiceKeys.fmp], "local-secret")
    }

    func testNewDeviceRestoresCloudflareTokenWithMatchingAccountBinding() async {
        storage.cloud["apple-account-a"] = ["service.cloudflare": .init(connection: .init(
            secrets: [LocalServiceKeys.cloudflareAIToken: "cloudflare-token"],
            configuration: [LocalServiceKeys.cloudflareAccountIDKey: "cloudflare-account"]
        ))]
        let subject = sync()
        await subject.setEnabled(true)
        XCTAssertEqual(storage.local[LocalServiceKeys.cloudflareAIToken], "cloudflare-token")
        XCTAssertEqual(defaults.string(forKey: LocalServiceKeys.cloudflareAccountIDKey), "cloudflare-account")
    }

    func testStaticBrokerPairsKeepAccountBindingAndExcludeDraftsAndSessions() async {
        storage.local = [
            "trading212.account-2.api-key": "t212-key", "trading212.account-2.api-secret": "t212-secret",
            IBKRFlexKeys.token(accountID: "U12345"): "12345678", IBKRFlexKeys.queryID(accountID: "U12345"): "123",
            IBKRFlexKeys.pendingToken: "pending-secret", IBKRFlexKeys.pendingQueryID: "pending-query",
            "trading212.setup.create": "draft-with-secret", "codex.oauth.refresh-token": "refresh-secret",
            "trading212.account-3.api-key": "incomplete-pair",
        ]
        let subject = sync()
        await subject.setEnabled(true)
        let records = storage.cloud["apple-account-a"] ?? [:]
        XCTAssertEqual(Set(records.keys), ["trading212.account-2", "ibkr.flex.account.U12345"])
        XCTAssertEqual(records["trading212.account-2"]?.connection?.secrets.count, 2)
        XCTAssertEqual(records["ibkr.flex.account.U12345"]?.connection?.secrets[IBKRFlexKeys.queryID(accountID: "U12345")], "123")
    }

    func testPreviewOnlyBrokerKeysAreNotUploadedBeforeAccountCreation() async {
        storage.local = ["trading212.account-1.api-key": "preview-key", "trading212.account-1.api-secret": "preview-secret"]
        let subject = CloudCredentialSync(defaults: defaults, storage: storage, center: NotificationCenter(),
            accountIdentity: { "apple-account-a" }, connectedConnectionIDs: { [] })
        await subject.setEnabled(true)
        XCTAssertEqual(storage.remoteWrites, 0)
        XCTAssertEqual(storage.local["trading212.account-1.api-key"], "preview-key")
    }

    func testImportedBrokerKeysSurviveWhenPortfolioSyncIsOff() async {
        let id = "trading212.account-1"
        storage.cloud["apple-account-a"] = [id: .init(connection: .init(secrets: [
            "\(id).api-key": "cloud-key", "\(id).api-secret": "cloud-secret"
        ], configuration: [:]))]
        let subject = CloudCredentialSync(defaults: defaults, storage: storage, center: NotificationCenter(),
            accountIdentity: { "apple-account-a" }, connectedConnectionIDs: { [] })
        await subject.setEnabled(true)
        await subject.refresh()
        XCTAssertEqual(storage.local["\(id).api-key"], "cloud-key")
        XCTAssertNotNil(storage.cloud["apple-account-a"]?[id]?.connection)
        // A legacy record without the optional binding is upgraded once.
        XCTAssertEqual(storage.remoteWrites, 1)
        XCTAssertNotNil(storage.cloud["apple-account-a"]?[id]?.connection?.portfolioBinding)
    }

    func testDisabledSyncKeepsLocalWorkingCopyAndStopsReadsAndWrites() async {
        storage.cloud["apple-account-a"] = ["service.fmp": serviceRecord("downloaded-secret")]
        let subject = sync()
        await subject.setEnabled(true)
        await subject.setEnabled(false)
        let reads = storage.remoteReads
        let writes = storage.remoteWrites
        storage.cloud["apple-account-a"] = ["service.fmp": serviceRecord("new-remote-secret")]
        await subject.refresh()
        XCTAssertEqual(storage.local[LocalServiceKeys.fmp], "downloaded-secret")
        XCTAssertEqual(storage.remoteReads, reads)
        XCTAssertEqual(storage.remoteWrites, writes)
    }

    func testChangedKeyPublishesAndRemoteRotationUpdatesUnchangedLocalCopy() async {
        storage.local[LocalServiceKeys.fmp] = "original"
        let subject = sync()
        await subject.setEnabled(true)
        storage.local[LocalServiceKeys.fmp] = "locally-rotated"
        await subject.refresh()
        XCTAssertEqual(storage.cloud["apple-account-a"]?["service.fmp"]?.connection?.secrets[LocalServiceKeys.fmp], "locally-rotated")
        storage.cloud["apple-account-a"]?["service.fmp"] = serviceRecord("remotely-rotated")
        await subject.refresh()
        XCTAssertEqual(storage.local[LocalServiceKeys.fmp], "remotely-rotated")
    }

    func testDeletedCredentialTravelsAsTombstoneAndDoesNotReappear() async {
        storage.local[LocalServiceKeys.fmp] = "secret"
        let subject = sync()
        await subject.setEnabled(true)
        storage.local.removeValue(forKey: LocalServiceKeys.fmp)
        await subject.refresh()
        XCTAssertNotNil(storage.cloud["apple-account-a"]?["service.fmp"])
        XCTAssertNil(storage.cloud["apple-account-a"]?["service.fmp"]?.connection)
        await subject.refresh()
        XCTAssertNil(storage.local[LocalServiceKeys.fmp])
    }

    func testAccountSwitchNeverPublishesOriginalAccountsSecretsEvenOnReenable() async {
        var account = "apple-account-a"
        storage.local[LocalServiceKeys.fmp] = "account-a-secret"
        let subject = sync { account }
        await subject.setEnabled(true)
        await subject.setEnabled(false)
        account = "apple-account-b"
        subject.invalidateAccount()
        let reads = storage.remoteReads
        let writes = storage.remoteWrites
        await subject.setEnabled(true)
        XCTAssertFalse(subject.isEnabled)
        XCTAssertEqual(storage.remoteReads, reads)
        XCTAssertEqual(storage.remoteWrites, writes)
        XCTAssertNil(storage.cloud["apple-account-b"])
        XCTAssertEqual(storage.local[LocalServiceKeys.fmp], "account-a-secret")
        XCTAssertEqual(defaults.string(forKey: CloudCredentialSync.ownerKey), "apple-account-a")
        account = "apple-account-a"
        await subject.setEnabled(true)
        XCTAssertTrue(subject.isEnabled)
    }

    func testReinstallCannotUploadRetainedKeysToAnotherAppleAccount() async {
        storage.local[LocalServiceKeys.fmp] = "account-a-secret"
        let original = sync()
        await original.setEnabled(true)
        await original.setEnabled(false)
        XCTAssertEqual(storage.local[CloudCredentialSync.ownerKey], "apple-account-a")
        defaults.removePersistentDomain(forName: suite)
        var account = "apple-account-b"
        let reinstalled = sync { account }
        let reads = storage.remoteReads
        let writes = storage.remoteWrites
        await reinstalled.setEnabled(true)
        XCTAssertFalse(reinstalled.isEnabled)
        XCTAssertEqual(storage.remoteReads, reads)
        XCTAssertEqual(storage.remoteWrites, writes)
        XCTAssertNil(storage.cloud["apple-account-b"])
        XCTAssertEqual(storage.local[LocalServiceKeys.fmp], "account-a-secret")
        XCTAssertEqual(storage.local[CloudCredentialSync.ownerKey], "apple-account-a")
        account = "apple-account-a"
        await reinstalled.setEnabled(true)
        XCTAssertTrue(reinstalled.isEnabled)
        XCTAssertEqual(defaults.string(forKey: CloudCredentialSync.ownerKey), "apple-account-a")
        let cloudKeys = Set((storage.cloud["apple-account-a"] ?? [:]).values.flatMap { $0.connection?.secrets.keys.map { $0 } ?? [] })
        XCTAssertFalse(cloudKeys.contains(CloudCredentialSync.ownerKey))
    }

    func testFailedDurableOwnerWritePreventsCloudAccess() async {
        storage.local[LocalServiceKeys.fmp] = "local-secret"
        storage.failLocalKey = CloudCredentialSync.ownerKey
        let subject = sync()
        await subject.setEnabled(true)
        XCTAssertEqual(storage.remoteReads, 0)
        XCTAssertEqual(storage.remoteWrites, 0)
        XCTAssertEqual(storage.local[LocalServiceKeys.fmp], "local-secret")
        XCTAssertNil(defaults.string(forKey: CloudCredentialSync.ownerKey))
        XCTAssertNil(storage.local[CloudCredentialSync.ownerKey])
    }

    func testDisablingDuringIdentityLookupPreventsLateCloudAccess() async {
        var continuation: CheckedContinuation<String, Never>?
        let subject = sync {
            await withCheckedContinuation { continuation = $0 }
        }
        let enabling = Task { await subject.setEnabled(true) }
        while continuation == nil { await Task.yield() }
        await subject.setEnabled(false)
        continuation?.resume(returning: "apple-account-a")
        await enabling.value
        XCTAssertFalse(subject.isEnabled)
        XCTAssertEqual(storage.localReads, 0)
        XCTAssertEqual(storage.remoteReads, 0)
        XCTAssertEqual(storage.remoteWrites, 0)
    }

    func testIdentityChangingDuringRefreshDoesNotTouchCloud() async {
        var calls = 0
        storage.local[LocalServiceKeys.fmp] = "original-account-secret"
        let subject = sync {
            calls += 1
            return calls == 1 ? "apple-account-a" : "apple-account-b"
        }
        await subject.setEnabled(true)
        XCTAssertEqual(storage.remoteReads, 0)
        XCTAssertEqual(storage.remoteWrites, 0)
        await subject.setEnabled(false)
    }

    func testTrading212RotationCarriesStablePortfolioBindingToFreshDevice() async throws {
        let id = "trading212.account-1"
        let accountKey = "Trading 212|account-1"
        storage.local = [id + ".api-key": "original-key", id + ".api-secret": "original-secret"]
        let stableBinding = try XCTUnwrap(CloudCredentialPolicy.trading212PairHash(id: id, values: storage.local))
        let original = CloudCredentialSync(defaults: defaults, storage: storage, center: NotificationCenter(),
            accountIdentity: { "apple-account-a" }, portfolioBindings: { [accountKey: stableBinding] },
            connectedConnectionIDs: { [id] })
        await original.setEnabled(true)
        storage.local[id + ".api-key"] = "rotated-key"
        storage.local[id + ".api-secret"] = "rotated-secret"
        await original.refresh()
        XCTAssertEqual(storage.cloud["apple-account-a"]?[id]?.connection?.portfolioBinding, stableBinding)
        XCTAssertEqual(CloudCredentialPolicy.trading212PortfolioBinding(accountKey: accountKey, values: storage.local), stableBinding)
        XCTAssertNotEqual(CloudCredentialPolicy.trading212PairHash(id: id, values: storage.local), stableBinding)

        let freshSuite = "credential-sync-fresh.\(UUID())"
        let freshDefaults = UserDefaults(suiteName: freshSuite)!
        defer { freshDefaults.removePersistentDomain(forName: freshSuite) }
        let freshStorage = MemoryCredentialStorage()
        freshStorage.cloud = storage.cloud
        let fresh = CloudCredentialSync(defaults: freshDefaults, storage: freshStorage, center: NotificationCenter(),
            accountIdentity: { "apple-account-a" }, connectedConnectionIDs: { [] })
        await fresh.setEnabled(true)
        await fresh.refresh()
        XCTAssertEqual(freshStorage.local[id + ".api-key"], "rotated-key")
        XCTAssertEqual(CloudCredentialPolicy.trading212PortfolioBinding(accountKey: accountKey, values: freshStorage.local), stableBinding)
        XCTAssertEqual(freshStorage.remoteWrites, 0)
        let payload = try XCTUnwrap(freshStorage.local[id + ".portfolio-binding"])
        XCTAssertFalse(payload.contains("rotated-key"))
        XCTAssertFalse(payload.contains("rotated-secret"))
    }

    func testTrading212BindingRejectsChangedOrIncompletePairAndUnknownSlot() throws {
        let id = "trading212.account-1"
        let accountKey = "Trading 212|account-1"
        var values = [id + ".api-key": "original-key", id + ".api-secret": "original-secret"]
        let binding = try XCTUnwrap(CloudCredentialPolicy.trading212PairHash(id: id, values: values))
        let connection = CloudCredentialConnection(secrets: values, configuration: [:], portfolioBinding: binding)
        values[id + ".portfolio-binding"] = try CloudCredentialPolicy.bindingPayload(connection: connection, id: id, previous: [:])
        XCTAssertEqual(CloudCredentialPolicy.trading212PortfolioBinding(accountKey: accountKey, values: values), binding)
        var changed = values
        changed[id + ".api-key"] = "another-key"
        XCTAssertNil(CloudCredentialPolicy.trading212PortfolioBinding(accountKey: accountKey, values: changed))
        changed = values
        changed.removeValue(forKey: id + ".api-secret")
        XCTAssertNil(CloudCredentialPolicy.trading212PortfolioBinding(accountKey: accountKey, values: changed))
        XCTAssertNil(CloudCredentialPolicy.trading212PortfolioBinding(accountKey: "Trading 212|account-2", values: values))
        XCTAssertNil(CloudCredentialPolicy.trading212PortfolioBinding(accountKey: "Trading 212|account-01", values: values))
    }

    func testRemoteBindingCannotTargetOtherProvidersOrArbitraryLocalKey() async {
        let binding = "credential:" + String(repeating: "a", count: 64)
        storage.cloud["apple-account-a"] = [
            "service.fmp": .init(connection: .init(secrets: [LocalServiceKeys.fmp: "secret"], configuration: [:], portfolioBinding: binding)),
            "trading212.account-1": .init(connection: .init(secrets: [
                "trading212.account-1.api-key": "key", "trading212.account-1.api-secret": "secret",
                "codex.oauth.refresh-token": "injected"
            ], configuration: [:], portfolioBinding: binding)),
            "trading212.account-2": .init(connection: .init(secrets: [
                "trading212.account-2.api-key": "key", "trading212.account-2.api-secret": "secret"
            ], configuration: [:], portfolioBinding: "invalid-binding")),
        ]
        let subject = sync()
        await subject.setEnabled(true)
        XCTAssertEqual(storage.local, [CloudCredentialSync.ownerKey: "apple-account-a"])
    }

    func testInitiallyConflictingBrokerSlotNeverOverwritesEitherConnection() async {
        storage.local = ["trading212.account-1.api-key": "local-broker-key", "trading212.account-1.api-secret": "local-secret"]
        let cloudConnection = CloudCredentialConnection(secrets: [
            "trading212.account-1.api-key": "other-broker-key", "trading212.account-1.api-secret": "other-secret"
        ], configuration: [:])
        storage.cloud["apple-account-a"] = ["trading212.account-1": .init(connection: cloudConnection)]
        let subject = sync()
        await subject.setEnabled(true)
        XCTAssertEqual(storage.local["trading212.account-1.api-key"], "local-broker-key")
        XCTAssertEqual(storage.cloud["apple-account-a"]?["trading212.account-1"]?.connection, cloudConnection)
        XCTAssertEqual(storage.remoteWrites, 0)
    }

    func testRemotePayloadCannotWriteOAuthSecretsOrUnrelatedDefaults() async {
        storage.cloud["apple-account-a"] = [
            "service.fmp": .init(connection: .init(secrets: ["codex.oauth.refresh-token": "injected"], configuration: [:])),
            "codex.oauth": .init(connection: .init(secrets: ["codex.oauth.refresh-token": "injected"], configuration: [:])),
            "service.cloudflare": .init(connection: .init(secrets: [LocalServiceKeys.cloudflareAIToken: "token"],
                                                         configuration: ["catfolio.fakeDataMode": "true"])),
        ]
        let subject = sync()
        await subject.setEnabled(true)
        XCTAssertEqual(storage.local, [CloudCredentialSync.ownerKey: "apple-account-a"])
        XCTAssertNil(defaults.object(forKey: "catfolio.fakeDataMode"))
    }

    func testIncompleteBrokerImportRollsBackAndDoesNotAcknowledgePartialPair() async {
        let id = "trading212.account-1"
        storage.cloud["apple-account-a"] = [id: .init(connection: .init(secrets: [
            "\(id).api-key": "key", "\(id).api-secret": "secret"
        ], configuration: [:]))]
        storage.failLocalKey = "\(id).api-secret"
        let subject = sync()
        await subject.setEnabled(true)
        XCTAssertNil(storage.local["\(id).api-key"])
        XCTAssertNil(storage.local["\(id).api-secret"])
        XCTAssertNil(defaults.dictionary(forKey: CloudCredentialSync.baselineKey)?[id])
    }
}

@MainActor
private final class MemoryCredentialStorage: CloudCredentialStorage {
    enum Failure: Error { case unavailable }
    var local: [String: String] = [:]
    var cloud: [String: [String: CloudCredentialRecord]] = [:]
    var localReads = 0
    var remoteReads = 0
    var remoteWrites = 0
    var failCloudWrites = false
    var failLocalKey: String?
    func localValues() throws -> [String: String] { localReads += 1; return local }
    func writeLocal(_ value: String, for key: String) throws {
        if key == failLocalKey { throw Failure.unavailable }
        if value.isEmpty { local.removeValue(forKey: key) } else { local[key] = value }
    }
    func remoteRecords(account: String) throws -> [String: CloudCredentialRecord] {
        remoteReads += 1
        return cloud[account] ?? [:]
    }
    func writeRemote(_ record: CloudCredentialRecord, id: String, account: String) throws {
        remoteWrites += 1
        if failCloudWrites { throw Failure.unavailable }
        cloud[account, default: [:]][id] = record
    }
}
