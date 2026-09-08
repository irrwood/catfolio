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
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original { defaults.set(original, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }

        defaults.set(false, forKey: key)
        NSUbiquitousKeyValueStore.default.set(true, forKey: key)
        CloudPreferences.pullFromCloud(keys: [key])
        XCTAssertFalse(
            defaults.bool(forKey: key),
            "a value outside the allow-list was applied from iCloud"
        )
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
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
}
