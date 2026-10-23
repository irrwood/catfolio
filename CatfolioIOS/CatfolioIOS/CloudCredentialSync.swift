import Foundation
import Observation
import CryptoKit

/// A connection is one Keychain item, so a token never travels independently
/// of its account ID or second half. OAuth sessions and setup drafts are absent.
struct CloudCredentialConnection: Codable, Equatable {
    var secrets: [String: String]
    var configuration: [String: String]
    /// Stable portfolio identity, carried with a T212 pair across rotations.
    var portfolioBinding: String? = nil

    var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data())
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct CloudCredentialRecord: Codable, Equatable {
    var version = 1
    var revision = UUID().uuidString
    /// nil is a tombstone. Removing a shared credential must reach devices
    /// that are offline when it is removed.
    var connection: CloudCredentialConnection?
}

/// Isolated storage boundary: tests never touch a user's Keychain or iCloud.
@MainActor
protocol CloudCredentialStorage: AnyObject {
    func localValues() throws -> [String: String]
    func writeLocal(_ value: String, for key: String) throws
    func remoteRecords(account: String) throws -> [String: CloudCredentialRecord]
    func writeRemote(_ record: CloudCredentialRecord, id: String, account: String) throws
}

@MainActor
final class KeychainCredentialStorage: CloudCredentialStorage {
    func localValues() throws -> [String: String] {
        try KeychainStore.allData(service: KeychainStore.service, synchronizable: false)
            .compactMapValues { String(data: $0, encoding: .utf8) }
    }
    func writeLocal(_ value: String, for key: String) throws { try KeychainStore.setLocal(value, for: key) }
    func remoteRecords(account: String) throws -> [String: CloudCredentialRecord] {
        try KeychainStore.allData(service: cloudService(account), synchronizable: true)
            .mapValues { try JSONDecoder().decode(CloudCredentialRecord.self, from: $0) }
    }
    func writeRemote(_ record: CloudCredentialRecord, id: String, account: String) throws {
        try KeychainStore.setData(JSONEncoder().encode(record), for: id,
                                 service: cloudService(account), synchronizable: true)
    }
    private func cloudService(_ account: String) -> String {
        "\(KeychainStore.service).cloud-credentials.v1.\(account)"
    }
}

/// Explicit allow-list shared by capture and import. A remote item cannot
/// overwrite an OAuth token, pending broker setup, or arbitrary defaults key.
enum CloudCredentialPolicy {
    static let serviceKeys: [String: String] = [
        "service.fmp": LocalServiceKeys.fmp,
        "service.massive": LocalServiceKeys.massive,
        "service.deepseek": LocalServiceKeys.deepSeek,
        "service.openrouter": LocalServiceKeys.openRouter,
        "service.claude": LocalServiceKeys.claude,
        "service.finnhub": LocalServiceKeys.finnhub,
        "service.cloudflare": LocalServiceKeys.cloudflareAIToken,
    ]

    static func secretKeys(for id: String) -> [String]? {
        if let key = serviceKeys[id] { return [key] }
        if id.hasPrefix("trading212.account-"),
           let slot = Int(id.dropFirst("trading212.account-".count)), slot > 0,
           id == "trading212.account-\(slot)" {
            return ["\(id).api-key", "\(id).api-secret"]
        }
        if id.hasPrefix("ibkr.flex.account.") {
            let accountID = String(id.dropFirst("ibkr.flex.account.".count))
            guard !accountID.isEmpty, accountID.count <= 128,
                  accountID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            return [IBKRFlexKeys.token(accountID: accountID), IBKRFlexKeys.queryID(accountID: accountID)]
        }
        return nil
    }

    static func configurationKeys(for id: String) -> [String] {
        switch id {
        case "service.cloudflare": [LocalServiceKeys.cloudflareAccountIDKey]
        case "service.deepseek": [LocalServiceKeys.deepSeekModel]
        case "service.openrouter": [LocalServiceKeys.openRouterModel]
        case "service.claude": [LocalServiceKeys.claudeModel]
        default: []
        }
    }

    static func capture(secrets: [String: String], defaults: UserDefaults,
                        brokerConnectionIDs: Set<String>? = nil,
                        portfolioBindings: [String: String] = [:]) -> [String: CloudCredentialConnection] {
        var ids = Set(serviceKeys.keys)
        for key in secrets.keys {
            for suffix in [".api-key", ".api-secret", ".token", ".query-id"] where key.hasSuffix(suffix) {
                let id = String(key.dropLast(suffix.count))
                if secretKeys(for: id) != nil { ids.insert(id) }
            }
        }
        var result: [String: CloudCredentialConnection] = [:]
        for id in ids {
            if serviceKeys[id] == nil, let brokerConnectionIDs, !brokerConnectionIDs.contains(id) { continue }
            guard let keys = secretKeys(for: id),
                  keys.allSatisfy({ !(secrets[$0] ?? "").isEmpty }) else { continue }
            let values = Dictionary(uniqueKeysWithValues: keys.map { ($0, secrets[$0]!) })
            let config = Dictionary(uniqueKeysWithValues: configurationKeys(for: id).map {
                ($0, defaults.string(forKey: $0) ?? "")
            })
            // A Cloudflare token without its account binding is not portable.
            if id == "service.cloudflare", config[LocalServiceKeys.cloudflareAccountIDKey]?.isEmpty != false { continue }
            var binding: String?
            if let accountKey = trading212AccountKey(for: id) {
                binding = portfolioBindings[accountKey].flatMap { isValidPortfolioBinding($0) ? $0 : nil }
                    ?? trading212PortfolioBinding(accountKey: accountKey, values: secrets)
                    ?? trading212PairHash(id: id, values: secrets)
            }
            result[id] = .init(secrets: values, configuration: config, portfolioBinding: binding)
        }
        return result
    }

    struct Trading212BindingPayload: Codable, Equatable {
        var binding: String
        var pairHash: String
    }

    static func trading212AccountKey(for id: String) -> String? {
        guard id.hasPrefix("trading212.account-"), secretKeys(for: id) != nil else { return nil }
        return "Trading 212|" + id.dropFirst("trading212.".count)
    }

    static func trading212BindingKey(for id: String) -> String? {
        trading212AccountKey(for: id) == nil ? nil : id + ".portfolio-binding"
    }

    /// Reads only a local binding whose paired keys still match. A stale
    /// marker left after editing/reusing a slot cannot identify a new account.
    static func trading212PortfolioBinding(accountKey: String, values: [String: String]) -> String? {
        let prefix = "Trading 212|"
        guard accountKey.hasPrefix(prefix) else { return nil }
        let id = "trading212." + accountKey.dropFirst(prefix.count)
        guard let markerKey = trading212BindingKey(for: id),
              let pairHash = trading212PairHash(id: id, values: values),
              let raw = values[markerKey], raw.utf8.count <= 1024,
              let payload = try? JSONDecoder().decode(Trading212BindingPayload.self, from: Data(raw.utf8)),
              payload.pairHash == pairHash, isValidPortfolioBinding(payload.binding)
        else { return nil }
        return payload.binding
    }

    static func trading212PairHash(id: String, values: [String: String]) -> String? {
        guard trading212AccountKey(for: id) != nil,
              let key = values[id + ".api-key"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = values[id + ".api-secret"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty, !secret.isEmpty,
              let data = try? JSONEncoder().encode([key, secret]) else { return nil }
        return "credential:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidPortfolioBinding(_ binding: String) -> Bool {
        if binding.hasPrefix("credential:") {
            let digest = binding.dropFirst("credential:".count)
            return digest.count == 64 && digest.allSatisfy { $0.isHexDigit }
        }
        if binding.hasPrefix("local:") { return UUID(uuidString: String(binding.dropFirst("local:".count))) != nil }
        return false
    }

    static func bindingPayload(connection: CloudCredentialConnection, id: String, previous: [String: String]) throws -> String? {
        guard let accountKey = trading212AccountKey(for: id),
              let pairHash = trading212PairHash(id: id, values: connection.secrets) else { return nil }
        let combined = previous.merging(connection.secrets, uniquingKeysWith: { _, next in next })
        let binding = connection.portfolioBinding
            ?? trading212PortfolioBinding(accountKey: accountKey, values: combined) ?? pairHash
        let data = try JSONEncoder().encode(Trading212BindingPayload(binding: binding, pairHash: pairHash))
        return String(data: data, encoding: .utf8)
    }

    static func accepts(_ record: CloudCredentialRecord, id: String) -> Bool {
        guard record.version == 1, let keys = secretKeys(for: id) else { return false }
        guard let connection = record.connection else { return true }
        if let binding = connection.portfolioBinding {
            guard trading212AccountKey(for: id) != nil, isValidPortfolioBinding(binding) else { return false }
        }
        guard Set(connection.secrets.keys) == Set(keys),
              Set(connection.configuration.keys) == Set(configurationKeys(for: id)),
              connection.secrets.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 }),
              connection.configuration.values.allSatisfy({ $0.utf8.count <= 4096 }) else { return false }
        return id != "service.cloudflare" || connection.configuration[LocalServiceKeys.cloudflareAccountIDKey]?.isEmpty == false
    }
}

@MainActor @Observable
final class CloudCredentialSync {
    nonisolated static let enabledKey = "catfolio.iCloudCredentialsEnabled"
    nonisolated static let ownerKey = "catfolio.iCloudCredentialsOwner.v1"
    nonisolated static let baselineKey = "catfolio.iCloudCredentialsBaseline.v1"
    static let shared = CloudCredentialSync()
    static var detailText: String {
        L10n.text("同步行情和 AI API Key、Trading 212 与 IBKR Flex 静态凭证及必要连接设置。ChatGPT 登录和设备授权需在各设备重新连接。")
    }

    private(set) var isEnabled: Bool
    private(set) var isBusy = false
    private(set) var statusText = L10n.text("已关闭；现有密钥仍保留在本机。")

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storage: any CloudCredentialStorage
    @ObservationIgnored private let accountIdentity: () async throws -> String
    @ObservationIgnored private let connectedConnectionIDs: () async throws -> Set<String>
    @ObservationIgnored private let portfolioBindings: () async throws -> [String: String]
    @ObservationIgnored private let center: NotificationCenter
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var deferredRefresh: Task<Void, Never>?
    @ObservationIgnored private var isApplying = false

    init(defaults: UserDefaults = .standard,
         storage: (any CloudCredentialStorage)? = nil,
         center: NotificationCenter = .default,
         accountIdentity: @escaping () async throws -> String = { try await CloudSyncAccount.current() },
         portfolioBindings: (() async throws -> [String: String])? = nil,
         connectedConnectionIDs: @escaping () async throws -> Set<String> = {
             let document = try await LocalPortfolioStore.shared.load()
             guard PortfolioDocumentMerge.isUploadable(document) else { return [] }
             return Set(document.accounts.compactMap { account -> String? in
                 guard let id = account.accountID else { return nil }
                 if account.source == "Trading 212" { return "trading212.\(id)" }
                 if account.source == IBKRFlexKeys.source, id != IBKRFlexKeys.pendingAccountID { return "ibkr.flex.account.\(id)" }
                 return nil
             })
         }) {
        self.defaults = defaults
        self.storage = storage ?? KeychainCredentialStorage()
        self.center = center
        self.accountIdentity = accountIdentity
        self.connectedConnectionIDs = connectedConnectionIDs
        // Injected stores do not inspect the user's real portfolio in tests.
        if let portfolioBindings { self.portfolioBindings = portfolioBindings }
        else if storage != nil { self.portfolioBindings = { [:] } }
        else { self.portfolioBindings = { try await LocalPortfolioStore.shared.load().syncMetadata?.accountBindings ?? [:] } }
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if isEnabled { statusText = L10n.text("等待 iCloud 钥匙串同步；不会覆盖本机连接。") }
    }

    func start() {
        guard observers.isEmpty else { return }
        for name in [KeychainStore.didChangeNotification, UserDefaults.didChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        }
    }

    func setEnabled(_ enabled: Bool) async {
        start()
        generation += 1
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            deferredRefresh?.cancel()
            statusText = L10n.text("已关闭；现有密钥仍保留在本机。")
            // Keep the owner and baseline: an Apple account switch must not
            // turn retained working copies into another account's upload.
            return
        }
        await refresh()
    }

    /// Called immediately on CKAccountChanged. The next refresh must verify
    /// identity again before opening the account's synchronizable namespace.
    func invalidateAccount() {
        generation += 1
        deferredRefresh?.cancel()
        if isEnabled { statusText = L10n.text("等待 iCloud 钥匙串同步；不会覆盖本机连接。") }
    }

    func refresh() async {
        guard isEnabled, !isBusy else { return }
        let requestGeneration = generation
        isBusy = true
        statusText = L10n.text("正在同步钥匙串…")
        defer {
            isBusy = false
            if isEnabled, generation != requestGeneration { scheduleRefresh() }
        }
        do {
            let account = try await accountIdentity()
            guard isEnabled, generation == requestGeneration else { return }
            guard try acceptAccount(account) else { return }
            // A T212 preview can save final slot keys before an account exists.
            // Only completed local connections (or earlier cloud imports)
            // may become initial broker uploads.
            let connectedIDs = try await connectedConnectionIDs()
            let bindings = try await portfolioBindings()
            // Recheck immediately before touching cloud data. Invalidation
            // during either await prevents a stale account from publishing.
            let verifiedAccount = try await accountIdentity()
            guard isEnabled, generation == requestGeneration else { return }
            guard account == verifiedAccount else { invalidateAccount(); return }
            var baseline = defaults.dictionary(forKey: Self.baselineKey) as? [String: String] ?? [:]
            let managedIDs = Set(baseline.filter { $0.value != "deleted" }.keys)
            let rawLocal = try storage.localValues()
            let local = CloudCredentialPolicy.capture(secrets: rawLocal, defaults: defaults,
                brokerConnectionIDs: connectedIDs.union(managedIDs), portfolioBindings: bindings)
            let remote = try storage.remoteRecords(account: account).filter { CloudCredentialPolicy.accepts($0.value, id: $0.key) }
            var conflicts = false
            isApplying = true
            defer { isApplying = false }
            for id in Set(local.keys).union(remote.keys).union(baseline.keys).sorted() {
                guard CloudCredentialPolicy.secretKeys(for: id) != nil else { continue }
                let localValue = local[id]
                let localFingerprint = localValue?.fingerprint ?? "deleted"
                let previous = baseline[id]
                let remoteRecord = remote[id]
                // Preview-only or incomplete credentials still belong to the
                // local setup flow. A cloud import cannot replace that draft.
                if previous == nil, localValue == nil, remoteRecord != nil,
                   CloudCredentialPolicy.secretKeys(for: id)?.contains(where: { !(rawLocal[$0] ?? "").isEmpty }) == true {
                    conflicts = true
                    continue
                }
                // Existing connections on two previously independent devices
                // can occupy the same T212 slot. Never silently replace one.
                if previous == nil, let localValue, let remoteRecord {
                    guard let cloudValue = remoteRecord.connection else { conflicts = true; continue }
                    if localValue.secrets != cloudValue.secrets || localValue.configuration != cloudValue.configuration
                        || (localValue.portfolioBinding != nil && cloudValue.portfolioBinding != nil
                            && localValue.portfolioBinding != cloudValue.portfolioBinding) {
                        conflicts = true
                        continue
                    }
                }
                if let previous, localFingerprint != previous {
                    try persistBinding(localValue, id: id)
                    try storage.writeRemote(.init(connection: localValue), id: id, account: account)
                    baseline[id] = localFingerprint
                } else if let remoteRecord {
                    try apply(remoteRecord.connection, id: id)
                    baseline[id] = remoteRecord.connection?.fingerprint ?? "deleted"
                } else if let localValue {
                    // A previously observed cloud item being temporarily
                    // absent is not a deletion. Its tombstone must arrive.
                    if previous == nil {
                        try persistBinding(localValue, id: id)
                        try storage.writeRemote(.init(connection: localValue), id: id, account: account)
                        baseline[id] = localFingerprint
                    }
                }
                // Persist only after each successful write/import. A partial
                // failure retries the remaining connection without losing it.
                if (defaults.dictionary(forKey: Self.baselineKey) as? [String: String] ?? [:]) != baseline {
                    defaults.set(baseline, forKey: Self.baselineKey)
                }
            }
            statusText = conflicts
                ? L10n.text("部分密钥与 iCloud 中的连接不同；已保留本机配置。请核对连接后重试。")
                : L10n.text("已保存到 iCloud 钥匙串，其他设备会在系统同步后收到。")
        } catch {
            guard isEnabled, generation == requestGeneration else { return }
            // Keychain/CloudKit errors may carry account metadata. The UI
            // intentionally exposes a useful generic message, never payloads.
            statusText = L10n.text("暂时无法同步密钥，请检查 iCloud 和钥匙串设置后重试。")
        }
    }

    private func acceptAccount(_ account: String) throws -> Bool {
        guard !account.isEmpty else { throw KeychainError.readFailed(-1) }
        // Device Keychain items can outlive an app uninstall, while defaults
        // do not. Keep their ownership beside them, outside the sync allow-list.
        let durableOwner = try storage.localValues()[Self.ownerKey]
        let preferenceOwner = defaults.string(forKey: Self.ownerKey)
        if [durableOwner, preferenceOwner].compactMap({ $0 }).contains(where: { $0 != account }) {
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
            statusText = L10n.text("Apple 账户已改变；为保护原账户密钥，请切回原 Apple 账户再开启同步。")
            return false
        }
        // A failed ownership write must prevent the first cloud transfer.
        // Never delete or replace another account's durable marker.
        if durableOwner == nil { try storage.writeLocal(account, for: Self.ownerKey) }
        if preferenceOwner == nil { defaults.set(account, forKey: Self.ownerKey) }
        return true
    }

    private func apply(_ connection: CloudCredentialConnection?, id: String) throws {
        guard let keys = CloudCredentialPolicy.secretKeys(for: id) else { return }
        // All writes are local. Turning off later retains this working copy.
        let previous = try storage.localValues()
        var changes = Dictionary(uniqueKeysWithValues: keys.map { ($0, connection?.secrets[$0] ?? "") })
        if let bindingKey = CloudCredentialPolicy.trading212BindingKey(for: id) {
            changes[bindingKey] = try connection.flatMap { try CloudCredentialPolicy.bindingPayload(connection: $0, id: id, previous: previous) } ?? ""
        }
        var written: [String] = []
        do {
            // Credentials precede their marker; failure restores both.
            let order = keys + [CloudCredentialPolicy.trading212BindingKey(for: id)].compactMap { $0 }
            for key in order where (previous[key] ?? "") != changes[key] {
                try storage.writeLocal(changes[key] ?? "", for: key)
                written.append(key)
            }
        } catch {
            // Recover the old pair if the second write fails (for example,
            // the device locks). The cloud record remains intact for retry.
            for key in written { try? storage.writeLocal(previous[key] ?? "", for: key) }
            throw error
        }
        for key in CloudCredentialPolicy.configurationKeys(for: id) {
            if let value = connection?.configuration[key] {
                if defaults.string(forKey: key) != value { defaults.set(value, forKey: key) }
            } else if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
        }
    }

    private func persistBinding(_ connection: CloudCredentialConnection?, id: String) throws {
        guard let key = CloudCredentialPolicy.trading212BindingKey(for: id) else { return }
        let previous = try storage.localValues()
        let value = try connection.flatMap { try CloudCredentialPolicy.bindingPayload(connection: $0, id: id, previous: previous) } ?? ""
        if (previous[key] ?? "") != value { try storage.writeLocal(value, for: key) }
    }

    private func scheduleRefresh() {
        guard isEnabled, !isApplying else { return }
        deferredRefresh?.cancel()
        deferredRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
}
