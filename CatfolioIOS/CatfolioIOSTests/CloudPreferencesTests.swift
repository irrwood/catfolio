import XCTest
@testable import CatfolioIOS

/// What is allowed to travel between a person's devices, and what is not.
final class CloudPreferencesTests: XCTestCase {

    /// The whole point of this feature request. Demo data switched on to show
    /// someone the app must never reach another device and replace a real
    /// portfolio with invented numbers.
    func testDemoAndInvestorModesNeverSync() {
        for key in [
            "catfolio.fakeDataMode",
            "catfolio.fakeDataSelectedAccounts",
            "catfolio.fakeDataSelectsAllAccounts",
            PublicInvestorPreferences.enabledKey,
            "catfolio.publicSelectedAccounts",
            "catfolio.publicSelectsAllAccounts",
        ] {
            XCTAssertFalse(CloudPreferences.synchronised.contains(key), key)
        }
    }

    /// The key the app actually reads, not a similar-looking string. A
    /// hand-written deny-list that drifts from the real constant protects
    /// nothing.
    func testTheInvestorKeyMatchesTheOneTheAppUses() {
        XCTAssertTrue(
            CloudPreferences.deliberatelyLocal.contains(PublicInvestorPreferences.enabledKey),
            "deny-list names \(CloudPreferences.deliberatelyLocal) but the app reads \(PublicInvestorPreferences.enabledKey)"
        )
    }

    /// Account ids are minted per device as brokers connect, so a synced
    /// selection can name accounts the other device has never heard of and
    /// resolve to nothing at all.
    func testAccountSelectionStaysLocal() {
        XCTAssertFalse(CloudPreferences.synchronised.contains("catfolio.selectedAccounts"))
        XCTAssertFalse(CloudPreferences.synchronised.contains("catfolio.selectsAllAccounts"))
    }

    /// A key cannot be in both lists: one of them would be a lie.
    func testTheTwoListsDoNotOverlap() {
        XCTAssertTrue(
            CloudPreferences.synchronised.isDisjoint(with: CloudPreferences.deliberatelyLocal)
        )
    }

    /// Nothing that could be a credential. Deliberately narrow: an earlier
    /// version of this test also rejected "holding" and "portfolio", which
    /// caught `portfolio.holdings.sortField` — a sort order, not a holding.
    /// A check that flags safe keys gets loosened or deleted, so it only
    /// names words that cannot appear in a display preference.
    func testNoCredentialLikeKeyIsOnTheList() {
        let forbidden = ["secret", "token", "password", "credential", "apikey", "auth"]
        for key in CloudPreferences.synchronised {
            for word in forbidden {
                XCTAssertFalse(
                    key.lowercased().replacingOccurrences(of: ".", with: "").contains(word),
                    "\(key) contains '\(word)' and should not be synced"
                )
            }
        }
    }

    /// The substantive version of the same worry: every synced value is a
    /// scalar or a short string, never a collection of records. Anything
    /// describing what is owned would arrive as an array or dictionary.
    func testEverySyncedValueIsASimplePreference() {
        let defaults = UserDefaults.standard
        for key in CloudPreferences.synchronised {
            guard let value = defaults.object(forKey: key) else { continue }
            XCTAssertFalse(value is [Any], "\(key) syncs a collection")
            XCTAssertFalse(value is [String: Any], "\(key) syncs a dictionary")
        }
    }

    /// Values arriving from iCloud are filtered by the same list. Another
    /// version of the app can write keys into that store, and nothing outside
    /// the list should be able to change this device by appearing there.
    func testPullIgnoresKeysOutsideTheList() {
        let key = "catfolio.fakeDataMode"
        let suite = "cloud-allowlist-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: key)
        CloudPreferences.applyRemoteValues([key: true], keys: [key], to: defaults)
        XCTAssertFalse(
            defaults.bool(forKey: key),
            "a value outside the allow-list was applied from iCloud"
        )
    }

    /// A preference that large is not a preference, and the store caps out at
    /// 1 MB in total.
    func testTheValueSizeCapIsWellUnderTheStoreLimit() {
        XCTAssertLessThanOrEqual(CloudPreferences.maximumValueBytes, 1024 * 1024 / 4)
    }

    /// Everything on the list is a display or sorting preference, so the
    /// whole set has to stay small enough to never crowd the store.
    func testTheListStaysSmall() {
        XCTAssertLessThan(CloudPreferences.synchronised.count, 32)
    }

    @MainActor
    func testDefaultOffNeverOpensOrMutatesCloudStore() {
        withSync { sync, store, defaults, center in
            sync.start()
            sync.refresh()
            defaults.set("GBP", forKey: "catfolio.displayCurrency")
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            XCTAssertFalse(sync.isEnabled)
            XCTAssertEqual(sync.status, .off)
            XCTAssertEqual(store.synchronizeCount, 0)
            XCTAssertEqual(store.writeCount, 0)
            XCTAssertTrue(store.dictionaryRepresentation.isEmpty)
            XCTAssertFalse(CloudPreferences.synchronised.contains(CloudPreferences.enabledKey))
        }
    }

    @MainActor
    func testEnableMergesCloudAndSeedsMissingValuesWithoutDeletingUnseenKeys() {
        withSync { sync, store, defaults, center in
            defaults.set("EUR", forKey: "catfolio.displayCurrency")
            defaults.set("local rules", forKey: "screener.rules")
            defaults.set(false, forKey: "catfolio.fakeDataMode")
            store.values = ["catfolio.displayCurrency": "GBP", "catfolio.fakeDataMode": true]
            sync.setEnabled(true)
            sync.start()
            XCTAssertEqual(store.synchronizeCount, 1, "start must be idempotent")
            XCTAssertEqual(defaults.string(forKey: "catfolio.displayCurrency"), "GBP")
            XCTAssertEqual(store.values["screener.rules"] as? String, "local rules")
            XCTAssertFalse(defaults.bool(forKey: "catfolio.fakeDataMode"))
            XCTAssertNil(store.values[CloudPreferences.enabledKey])
            XCTAssertNil(sync.lastReceivedAt, "synchronize is not a delivery receipt")

            // A remote value arrived, but its notification has not yet run.
            // An unrelated defaults change must not push a stale full snapshot.
            store.values["catfolio.appearance"] = "dark"
            defaults.set("unrelated", forKey: "not-synced")
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            XCTAssertEqual(store.values["catfolio.appearance"] as? String, "dark")
        }
    }

    @MainActor
    func testTurningOffPreservesDataAndIgnoresQueuedChanges() {
        withSync { sync, store, defaults, center in
            defaults.set("GBP", forKey: "catfolio.displayCurrency")
            sync.setEnabled(true)
            let writes = store.writeCount
            sync.setEnabled(false)
            XCTAssertEqual(defaults.string(forKey: "catfolio.displayCurrency"), "GBP")
            XCTAssertEqual(store.values["catfolio.displayCurrency"] as? String, "GBP")
            defaults.set("EUR", forKey: "catfolio.displayCurrency")
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            store.values["catfolio.displayCurrency"] = "USD"
            postRemote(center, store: store, reason: NSUbiquitousKeyValueStoreServerChange,
                       keys: ["catfolio.displayCurrency"])
            sync.refresh()
            XCTAssertEqual(defaults.string(forKey: "catfolio.displayCurrency"), "EUR")
            XCTAssertEqual(store.writeCount, writes)
            XCTAssertEqual(store.synchronizeCount, 1)
            XCTAssertEqual(sync.status, .off)
            XCTAssertNil(sync.lastReceivedAt)
            sync.setEnabled(true)
            XCTAssertEqual(defaults.string(forKey: "catfolio.displayCurrency"), "USD")
        }
    }

    @MainActor
    func testRemoteNotificationsDoNotEchoAndOnlyExplicitDeletionsTravel() {
        withSync { sync, store, defaults, center in
            defaults.set("GBP", forKey: "catfolio.displayCurrency")
            defaults.set("rules", forKey: "screener.rules")
            sync.setEnabled(true)
            store.values["catfolio.displayCurrency"] = "EUR"
            let writes = store.writeCount
            postRemote(center, store: store, reason: NSUbiquitousKeyValueStoreServerChange,
                       keys: ["catfolio.displayCurrency"])
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            XCTAssertEqual(defaults.string(forKey: "catfolio.displayCurrency"), "EUR")
            XCTAssertEqual(store.writeCount, writes)
            XCTAssertNotNil(sync.lastReceivedAt)

            store.values.removeValue(forKey: "screener.rules")
            postRemote(center, store: store, reason: NSUbiquitousKeyValueStoreInitialSyncChange,
                       keys: ["screener.rules"])
            XCTAssertEqual(defaults.string(forKey: "screener.rules"), "rules")
            store.values.removeValue(forKey: "screener.rules")
            postRemote(center, store: store, reason: NSUbiquitousKeyValueStoreServerChange, keys: nil)
            XCTAssertEqual(defaults.string(forKey: "screener.rules"), "rules")
            postRemote(center, store: store, reason: NSUbiquitousKeyValueStoreServerChange,
                       keys: ["screener.rules"])
            XCTAssertNil(defaults.object(forKey: "screener.rules"))

            defaults.removeObject(forKey: "catfolio.displayCurrency")
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            XCTAssertNil(store.values["catfolio.displayCurrency"])
        }
    }

    @MainActor
    func testAccountChangeKeepsLocalValuesAndClearsOldReceipt() {
        withSync { sync, store, defaults, center in
            defaults.set("GBP", forKey: "catfolio.displayCurrency")
            sync.setEnabled(true)
            postRemote(center, store: store, reason: NSUbiquitousKeyValueStoreServerChange,
                       keys: ["catfolio.displayCurrency"])
            XCTAssertNotNil(sync.lastReceivedAt)
            store.values = [:]
            let writes = store.writeCount
            postRemote(center, store: store, reason: NSUbiquitousKeyValueStoreAccountChange, keys: nil)
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            XCTAssertEqual(defaults.string(forKey: "catfolio.displayCurrency"), "GBP")
            XCTAssertEqual(store.writeCount, writes)
            XCTAssertNil(sync.lastReceivedAt)
        }
    }

    @MainActor
    func testFailedInitializationCanRetryWithoutLosingLocalSettings() {
        withSync { sync, store, defaults, _ in
            defaults.set("rules", forKey: "screener.rules")
            store.synchronizeResult = false
            sync.setEnabled(true)
            XCTAssertEqual(sync.status, .unavailable)
            XCTAssertEqual(store.writeCount, 0)
            XCTAssertEqual(defaults.string(forKey: "screener.rules"), "rules")
            store.synchronizeResult = true
            sync.refresh()
            XCTAssertEqual(sync.status, .automatic)
            XCTAssertEqual(store.values["screener.rules"] as? String, "rules")
            XCTAssertNil(sync.lastReceivedAt)
        }
    }

    @MainActor
    func testQuotaAndUnknownNotificationsNeverDeletePreferences() {
        withSync { sync, store, defaults, center in
            defaults.set("GBP", forKey: "catfolio.displayCurrency")
            sync.setEnabled(true)
            store.values = [:]
            postRemote(center, store: store, reason: NSUbiquitousKeyValueStoreQuotaViolationChange,
                       keys: ["catfolio.displayCurrency"])
            XCTAssertEqual(sync.status, .quotaExceeded)
            sync.refresh()
            XCTAssertEqual(sync.status, .quotaExceeded, "retry is not confirmation of quota recovery")
            postRemote(center, store: store, reason: 999, keys: ["catfolio.displayCurrency"])
            XCTAssertEqual(defaults.string(forKey: "catfolio.displayCurrency"), "GBP")
            XCTAssertNil(sync.lastReceivedAt)
        }
    }

    @MainActor
    func testOversizedValueStaysLocalAndRecoversWhenShortened() {
        withSync { sync, store, defaults, center in
            defaults.set(String(repeating: "x", count: 70_000), forKey: "screener.prompt")
            sync.setEnabled(true)
            XCTAssertEqual(sync.status, .valueTooLarge)
            XCTAssertNil(store.values["screener.prompt"])
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            XCTAssertEqual(sync.status, .valueTooLarge)
            defaults.set("short prompt", forKey: "screener.prompt")
            center.post(name: UserDefaults.didChangeNotification, object: defaults)
            XCTAssertEqual(store.values["screener.prompt"] as? String, "short prompt")
            XCTAssertEqual(sync.status, .automatic)
        }
    }

    @MainActor
    private func withSync(_ run: (CloudPreferenceSync, MemoryPreferenceStore, UserDefaults, NotificationCenter) -> Void) {
        let suite = "cloud-sync-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = MemoryPreferenceStore()
        let center = NotificationCenter()
        let sync = CloudPreferenceSync(defaults: defaults, makeStore: { store }, center: center)
        defer { sync.stop(); defaults.removePersistentDomain(forName: suite) }
        run(sync, store, defaults, center)
    }

    private func postRemote(_ center: NotificationCenter, store: MemoryPreferenceStore,
                            reason: Int, keys: [String]?) {
        var info: [String: Any] = [NSUbiquitousKeyValueStoreChangeReasonKey: reason]
        if let keys { info[NSUbiquitousKeyValueStoreChangedKeysKey] = keys }
        center.post(name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                    object: store, userInfo: info)
    }
}

private final class MemoryPreferenceStore: NSObject, CloudPreferenceStore {
    var values: [String: Any] = [:]
    var dictionaryRepresentation: [String: Any] { values }
    var synchronizeResult = true
    var synchronizeCount = 0
    var writeCount = 0

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value; writeCount += 1 }
    func removeObject(forKey key: String) { values.removeValue(forKey: key); writeCount += 1 }
    func synchronize() -> Bool { synchronizeCount += 1; return synchronizeResult }
}
