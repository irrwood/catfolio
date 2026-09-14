import Foundation
import Observation

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
    /// Opt-in on each device. This switch must never travel to another device.
    static let enabledKey = "catfolio.iCloudPreferencesEnabled"

    @MainActor static let shared = CloudPreferenceSync()

    @MainActor static func start() { shared.start() }

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
        enabledKey,
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

    static func applyRemoteValues(_ values: [String: Any], keys: Set<String>,
                                  to defaults: UserDefaults, allowsDeletion: Bool = false) {
        for key in keys.intersection(synchronised) {
            guard let value = values[key] else {
                if allowsDeletion { defaults.removeObject(forKey: key) }
                continue
            }
            guard isSmallEnough(value), !equal(defaults.object(forKey: key), value) else { continue }
            defaults.set(value, forKey: key)
        }
    }

    static func isSmallEnough(_ value: Any) -> Bool {
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: value, format: .binary, options: 0
        ) else { return false }
        return data.count <= maximumValueBytes
    }

    /// Property-list values compare cheaply through `NSObject`, and comparing
    /// before writing is what stops the two observers echoing each other.
    static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (left as NSObject, right as NSObject): left.isEqual(right)
        default: false
        }
    }
}

/// The small store boundary keeps tests away from a person's real iCloud.
protocol CloudPreferenceStore: AnyObject {
    var dictionaryRepresentation: [String: Any] { get }
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: CloudPreferenceStore {}

@MainActor @Observable
final class CloudPreferenceSync {
    enum Status: Equatable {
        case off, automatic, unavailable, quotaExceeded, valueTooLarge
    }

    private(set) var isEnabled: Bool
    private(set) var status: Status = .off
    /// A received notification is evidence of an incoming change, not proof
    /// that our latest edits have reached every other device.
    private(set) var lastReceivedAt: Date?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeStore: () -> any CloudPreferenceStore
    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private var store: (any CloudPreferenceStore)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var localValues: [String: Any] = [:]
    @ObservationIgnored private var isApplyingRemoteChange = false
    @ObservationIgnored private var needsInitialMerge = true

    init(defaults: UserDefaults = .standard,
         makeStore: @escaping () -> any CloudPreferenceStore = { NSUbiquitousKeyValueStore.default },
         center: NotificationCenter = .default) {
        self.defaults = defaults
        self.makeStore = makeStore
        self.center = center
        isEnabled = defaults.bool(forKey: CloudPreferences.enabledKey)
    }

    func start() {
        guard observers.isEmpty else { return }
        observers.append(center.addObserver(forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.localDefaultsChanged() }
            })
        // Register before synchronize(), which can deliver an initial change.
        observers.append(center.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let store = self.store,
                          let source = note.object as AnyObject?, source === store else { return }
                    self.receiveRemoteChange(
                        reason: note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
                        keys: note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String])
                }
            })
        if isEnabled { connect() }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: CloudPreferences.enabledKey)
        if observers.isEmpty { start() }
        else if enabled { connect() }
        else { disconnect() }
    }

    /// Called on foreground/retry, not for every keystroke. iCloud schedules
    /// uploads itself; a true return value is not an upload acknowledgment.
    func refresh() {
        guard isEnabled else { return }
        if observers.isEmpty { start(); return }
        if store == nil { connect(); return }
        guard let store else { return }
        if store.synchronize() {
            if status == .unavailable { status = .automatic }
            mergeInitialValuesIfNeeded()
            localDefaultsChanged()
        } else { status = .unavailable }
    }

    func stop() {
        observers.forEach(center.removeObserver)
        observers.removeAll()
        disconnect()
    }

    private func connect() {
        guard store == nil else { return }
        let store = makeStore()
        self.store = store
        localValues = snapshot()
        status = .automatic
        guard store.synchronize() else { status = .unavailable; return }
        mergeInitialValuesIfNeeded()
    }

    private func mergeInitialValuesIfNeeded() {
        guard needsInitialMerge else { return }
        needsInitialMerge = false
        // Existing cloud values win on enable; absent values preserve local
        // choices. Initial writes only seed missing keys, never erase a key.
        applyRemote(keys: CloudPreferences.synchronised, allowsDeletion: false)
        seedMissingValues()
    }

    private func disconnect() {
        // Turning off stops future mirroring. It does not delete local or
        // remote data, nor retract changes already handed to the system.
        store = nil
        needsInitialMerge = true
        localValues = [:]
        lastReceivedAt = nil
        status = .off
    }

    func localDefaultsChanged() {
        let enabled = defaults.bool(forKey: CloudPreferences.enabledKey)
        if enabled != isEnabled { setEnabled(enabled); return }
        guard isEnabled, let store, !isApplyingRemoteChange,
              status != .unavailable else { return }
        let values = snapshot()
        let tooLarge = values.values.contains { !CloudPreferences.isSmallEnough($0) }
        for key in CloudPreferences.synchronised {
            guard !CloudPreferences.equal(localValues[key], values[key]) else { continue }
            if let value = values[key] {
                guard CloudPreferences.isSmallEnough(value) else { continue }
                if !CloudPreferences.equal(store.object(forKey: key), value) {
                    store.set(value, forKey: key)
                }
            } else if store.object(forKey: key) != nil {
                // Only a real local deletion since the last snapshot travels.
                store.removeObject(forKey: key)
            }
            localValues[key] = values[key]
        }
        if tooLarge { status = .valueTooLarge }
        else if status == .valueTooLarge { status = .automatic }
    }

    func receiveRemoteChange(reason: Int?, keys: [String]?) {
        guard isEnabled, store != nil else { return }
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            status = .quotaExceeded
            return
        }
        guard let reason, [NSUbiquitousKeyValueStoreServerChange,
            NSUbiquitousKeyValueStoreInitialSyncChange,
            NSUbiquitousKeyValueStoreAccountChange].contains(reason) else { return }
        let changed = reason == NSUbiquitousKeyValueStoreAccountChange
            ? CloudPreferences.synchronised : Set(keys ?? Array(CloudPreferences.synchronised))
        applyRemote(keys: changed,
            allowsDeletion: reason == NSUbiquitousKeyValueStoreServerChange && keys != nil)
        status = .automatic
        if reason == NSUbiquitousKeyValueStoreAccountChange { lastReceivedAt = nil }
        else if !changed.isDisjoint(with: CloudPreferences.synchronised) { lastReceivedAt = Date() }
        if reason == NSUbiquitousKeyValueStoreInitialSyncChange { seedMissingValues() }
    }

    private func applyRemote(keys: Set<String>, allowsDeletion: Bool) {
        guard let store else { return }
        isApplyingRemoteChange = true
        defer { isApplyingRemoteChange = false }
        CloudPreferences.applyRemoteValues(store.dictionaryRepresentation, keys: keys,
            to: defaults, allowsDeletion: allowsDeletion)
        for key in keys.intersection(CloudPreferences.synchronised) {
            localValues[key] = defaults.object(forKey: key)
        }
    }

    private func seedMissingValues() {
        guard let store else { return }
        for (key, value) in snapshot() where store.object(forKey: key) == nil {
            guard CloudPreferences.isSmallEnough(value) else { status = .valueTooLarge; continue }
            store.set(value, forKey: key)
        }
    }

    private func snapshot() -> [String: Any] {
        Dictionary(uniqueKeysWithValues: CloudPreferences.synchronised.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
    }
}
