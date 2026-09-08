import Foundation

/// Mirrors a named set of preferences to iCloud, so a second device starts
/// configured rather than blank.
///
/// Only preferences. The portfolio document is not synced and is not meant to
/// be: every one of this ledger's 1,977 transactions came from a broker, so a
/// device holding the same API keys rebuilds it exactly. Syncing it would be
/// syncing a cache — and syncing it *as a file* would be worse than useless,
/// because a 600 KB document is last-writer-wins, so two devices that both
/// refreshed would silently drop one device's transactions and leave a ledger
/// where every remaining row still looks correct.
///
/// The list is an allow-list rather than a deny-list. A preference added
/// later stays on its own device until someone decides otherwise, which is
/// the safe direction to be wrong in.
enum CloudPreferences {

    /// What travels between a person's devices.
    ///
    /// Everything here is a small scalar describing how the app should look
    /// or sort. Nothing here identifies an account, holds a credential, or
    /// says anything about what is owned.
    static let synchronised: Set<String> = [
        "catfolio.displayCurrency",
        "catfolio.appearance",
        "catfolio.companyNameDisplay",
        "catfolio.haptics",
        "history.taxYearBasis",
        "portfolio.holdings.sortField",
        "portfolio.holdings.sortAscending",
        "research.maximumResults",
        "research.highAttentionOnly",
        "screener.rules",
        "screener.prompt",
    ]

    /// Deliberately absent, and why — so a later reader does not "fix" it.
    ///
    /// - Demo and public-investor state (`catfolio.fakeDataMode`,
    ///   `catfolio.public*`): these swap the whole app onto invented or
    ///   third-party data. A demo switched on to show someone the app must
    ///   never turn another device's real portfolio into a demo.
    /// - Account selection (`catfolio.selectedAccounts`): account ids are
    ///   minted per device as brokers connect, so a synced selection can
    ///   resolve to no accounts at all on the other side.
    /// - `catfolio.currentFX.v1`: a cache, refetched in seconds.
    /// - Broker credentials: Keychain, and deliberately
    ///   `WhenUnlockedThisDeviceOnly`. Changing that is a security decision,
    ///   not a sync one.
    static let deliberatelyLocal: Set<String> = [
        "catfolio.fakeDataMode",
        "catfolio.fakeDataSelectedAccounts",
        "catfolio.fakeDataSelectsAllAccounts",
        "catfolio.publicInvestorMode",
        "catfolio.publicSelectedAccounts",
        "catfolio.publicSelectsAllAccounts",
        "catfolio.selectedAccounts",
        "catfolio.selectsAllAccounts",
        "catfolio.currentFX.v1",
    ]

    /// iCloud's key-value store caps a single value at 1 MB and the whole
    /// store at 1 MB. A preference that large is not a preference, so it is
    /// left behind rather than allowed to crowd out everything else.
    static let maximumValueBytes = 64 * 1024

    private static let defaults = UserDefaults.standard
    private static let cloud = NSUbiquitousKeyValueStore.default
    /// Set while applying a remote change, so writing it into `UserDefaults`
    /// does not immediately look like a local edit and bounce straight back.
    nonisolated(unsafe) private static var isApplyingRemoteChange = false
    nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []

    /// Starts mirroring. Safe to call more than once.
    static func start() {
        guard observers.isEmpty else { return }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            pullFromCloud(keys: changed.map(Set.init) ?? synchronised)
        })

        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main
        ) { _ in pushToCloud() })

        cloud.synchronize()
        // A device that has never synced has nothing local worth keeping, so
        // whatever iCloud already holds wins on first run. After that both
        // directions are live and the last edit wins, which is the right
        // answer for a scalar nobody edits on two devices at once.
        pullFromCloud(keys: synchronised)
        pushToCloud()
    }

    static func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Copies allow-listed values out to iCloud.
    static func pushToCloud() {
        guard !isApplyingRemoteChange else { return }
        var didChange = false
        for key in synchronised {
            guard let value = defaults.object(forKey: key) else {
                if cloud.object(forKey: key) != nil {
                    cloud.removeObject(forKey: key)
                    didChange = true
                }
                continue
            }
            guard isSmallEnough(value) else { continue }
            guard !equal(cloud.object(forKey: key), value) else { continue }
            cloud.set(value, forKey: key)
            didChange = true
        }
        if didChange { cloud.synchronize() }
    }

    /// Copies values in from iCloud, ignoring anything not on the list.
    ///
    /// The filter matters: another version of the app, or a future one, can
    /// put keys in this store, and nothing outside the list should be able to
    /// change this device's behaviour just by appearing there.
    static func pullFromCloud(keys: Set<String>) {
        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }
        for key in keys.intersection(synchronised) {
            guard let value = cloud.object(forKey: key) else {
                defaults.removeObject(forKey: key)
                continue
            }
            guard !equal(defaults.object(forKey: key), value) else { continue }
            defaults.set(value, forKey: key)
        }
    }

    private static func isSmallEnough(_ value: Any) -> Bool {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: value, format: .binary, options: 0
        ) else { return false }
        return data.count <= maximumValueBytes
    }

    /// Property-list values compare cheaply through `NSObject`, and comparing
    /// before writing is what stops the two observers echoing each other.
    private static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (left as NSObject, right as NSObject): left.isEqual(right)
        default: false
        }
    }
}
