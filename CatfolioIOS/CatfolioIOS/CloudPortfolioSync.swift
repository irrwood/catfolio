import CloudKit
import Foundation
import Observation

extension Notification.Name {
    static let cloudPortfolioDidReceive = Notification.Name("catfolio.cloudPortfolioDidReceive")
}

/// A synchronous actor commit can check this without hopping back to the UI.
/// Disabling sync invalidates queued downloads before they touch local storage.
final class CloudSyncLease: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func invalidate() { lock.lock(); active = false; lock.unlock() }
}

@MainActor @Observable
final class CloudPortfolioSync {
    static let shared = CloudPortfolioSync()
    static let enabledKey = "catfolio.iCloudPortfolioEnabled"
    static let ownerKey = "catfolio.iCloudPortfolioOwner.v1"
    /// Nonsecret UUID references only, scoped by the account identity hash.
    /// Keep failed first-upload keys across retries and app relaunches.
    static let pendingKeysKey = "catfolio.iCloudPortfolioPendingKeys.v1"

    enum Status: Equatable {
        case off, syncing, synced, waitingForKey, noAccount, accountChanged
        case unavailable, quotaExceeded, unsupported, invalidData, notConfigured, locked, accountConflict, tooLarge
    }
    private(set) var isEnabled: Bool
    private var isSyncing = false
    private var isPreparing = false
    var isBusy: Bool { isSyncing || isPreparing }
    private(set) var status: Status = .off
    private(set) var lastSyncedAt: Date?
    private let defaults: UserDefaults
    private let transport: any CloudPortfolioTransport
    private let crypto: CloudPortfolioCrypto
    private let identity: () async throws -> String
    private let load: () async throws -> LocalPortfolioDocument
    private let merge: (LocalPortfolioDocument, CloudSyncLease) async throws -> LocalPortfolioDocument
    private let center: NotificationCenter
    private var generation = 0
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    private var refreshRequested = false
    private var lease = CloudSyncLease()

    init(defaults: UserDefaults = .standard,
         transport: (any CloudPortfolioTransport)? = nil,
         crypto: CloudPortfolioCrypto = CloudPortfolioCrypto(),
         identity: @escaping () async throws -> String = { try await CloudSyncAccount.current() },
         load: @escaping () async throws -> LocalPortfolioDocument = { try await LocalPortfolioStore.shared.prepareForCloudSync() },
         merge: @escaping (LocalPortfolioDocument, CloudSyncLease) async throws -> LocalPortfolioDocument = { document, lease in
             try await LocalPortfolioStore.shared.mergeFromCloud(document, canCommit: { lease.isValid })
         }, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.transport = transport ?? CloudKitPortfolioTransport()
        self.crypto = crypto
        self.identity = identity
        self.load = load
        self.merge = merge
        self.center = center
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    var statusText: String {
        switch status {
        case .off: L10n.text("未开启")
        case .syncing: L10n.text("正在同步…")
        case .synced: L10n.text("已同步")
        case .waitingForKey: L10n.text("等待钥匙串中的解密密钥")
        case .noAccount: L10n.text("请登录 iCloud")
        case .accountChanged: L10n.text("Apple 账户已更改，请切回原账户")
        case .unavailable: L10n.text("暂时无法同步，请重试")
        case .quotaExceeded: L10n.text("iCloud 空间不足")
        case .unsupported: L10n.text("此版本无法读取云端数据")
        case .invalidData: L10n.text("云端数据校验失败")
        case .notConfigured: L10n.text("iCloud 尚未配置")
        case .locked: L10n.text("需要解锁设备后重试")
        case .accountConflict: L10n.text("设备上的券商账户不一致，请先核对账户连接")
        case .tooLarge: L10n.text("组合数据超过当前同步大小限制")
        }
    }

    func start() {
        guard observer == nil else { return }
        observer = center.addObserver(forName: .localPortfolioDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleRefresh() }
        }
    }

    func stop() {
        generation += 1
        isPreparing = false
        lease.invalidate()
        pending?.cancel()
        pending = nil
        if let observer { center.removeObserver(observer) }
        observer = nil
    }

    func setEnabled(_ enabled: Bool) async {
        generation += 1
        lease.invalidate()
        pending?.cancel()
        isEnabled = false
        isPreparing = enabled
        defaults.set(false, forKey: Self.enabledKey)
        lastSyncedAt = nil
        if !enabled { status = .off; return }
        let operation = generation
        defer { if generation == operation { isPreparing = false } }
        status = .syncing
        do {
            let account = try await identity()
            guard generation == operation else { return }
            if let owner = defaults.string(forKey: Self.ownerKey), owner != account {
                throw CloudPortfolioSyncError.accountChanged
            }
            // Retain ownership even when disabled. Explicitly turning the switch
            // back on cannot silently publish account A's local data to B.
            defaults.set(account, forKey: Self.ownerKey)
            defaults.set(true, forKey: Self.enabledKey)
            isEnabled = true
            isPreparing = false
            await refresh()
        } catch {
            guard generation == operation else { return }
            apply(error)
        }
    }

    func invalidateAccount() {
        generation += 1
        isPreparing = false
        lease.invalidate()
        pending?.cancel()
        lastSyncedAt = nil
        if isEnabled { status = .noAccount }
        // Keep opt-in, but every subsequent operation must revalidate identity.
    }

    func refresh() async {
        guard isEnabled else { return }
        if isSyncing { refreshRequested = true; return }
        isSyncing = true
        lease = CloudSyncLease()
        let currentLease = lease
        let operation = generation
        status = .syncing
        defer {
            isSyncing = false
            if refreshRequested {
                refreshRequested = false
                scheduleRefresh()
            }
        }
        do {
            let account = try await identity()
            try check(operation)
            guard defaults.string(forKey: Self.ownerKey) == account else {
                throw CloudPortfolioSyncError.accountChanged
            }
            for attempt in 0..<3 {
                let remote = try await transport.fetch(account: account)
                try await validate(account, operation: operation)
                let previous = try await load()
                try check(operation)
                guard PortfolioDocumentMerge.isUploadable(previous) else {
                    throw CloudPortfolioSyncError.invalidPayload
                }
                var keyID: String?
                var remoteDocument: LocalPortfolioDocument?
                if let remote {
                    let opened = try crypto.open(remote.payload, account: account)
                    keyID = opened.keyID
                    // A readable remote record establishes the winner. Never
                    // fall back to a pending key when its key has not arrived.
                    clearPendingKey(account: account)
                    remoteDocument = opened.document
                    try await validate(account, operation: operation)
                    let merged = try await merge(opened.document, currentLease)
                    try check(operation)
                    if merged != previous { center.post(name: .cloudPortfolioDidReceive, object: nil) }
                }
                // Read again: edits while a download awaited must be included.
                let current = try await load()
                try check(operation)
                if current != remoteDocument {
                    let encryptionKeyID: String?
                    if remote == nil { encryptionKeyID = try pendingKey(account: account) }
                    else { encryptionKeyID = keyID }
                    let encrypted = try crypto.seal(current, account: account, keyID: encryptionKeyID)
                    if remote == nil {
                        // Persist before the first suspension/upload. A failed
                        // or ambiguous save reuses this exact key on retry.
                        let envelope = try JSONDecoder().decode(CloudPortfolioCrypto.Envelope.self, from: encrypted)
                        rememberPendingKey(envelope.keyID, account: account)
                    }
                    try await validate(account, operation: operation)
                    do { try await transport.save(encrypted, replacing: remote, account: account) }
                    catch CloudPortfolioSyncError.conflict where attempt < 2 { continue }
                    try await validate(account, operation: operation)
                    clearPendingKey(account: account)
                }
                lastSyncedAt = Date()
                status = .synced
                return
            }
        } catch {
            guard generation == operation else { return }
            apply(error)
        }
    }

    private func pendingKey(account: String) throws -> String? {
        guard let id = (defaults.dictionary(forKey: Self.pendingKeysKey) as? [String: String])?[account] else { return nil }
        guard UUID(uuidString: id) != nil else { throw CloudPortfolioSyncError.invalidPayload }
        return id
    }

    private func rememberPendingKey(_ id: String, account: String) {
        var pendingKeys = defaults.dictionary(forKey: Self.pendingKeysKey) as? [String: String] ?? [:]
        guard pendingKeys[account] != id else { return }
        pendingKeys[account] = id
        defaults.set(pendingKeys, forKey: Self.pendingKeysKey)
    }

    private func clearPendingKey(account: String) {
        var pendingKeys = defaults.dictionary(forKey: Self.pendingKeysKey) as? [String: String] ?? [:]
        guard pendingKeys.removeValue(forKey: account) != nil else { return }
        if pendingKeys.isEmpty { defaults.removeObject(forKey: Self.pendingKeysKey) }
        else { defaults.set(pendingKeys, forKey: Self.pendingKeysKey) }
    }

    private func scheduleRefresh() {
        guard isEnabled else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await self?.refresh()
        }
    }

    private func check(_ operation: Int) throws {
        guard operation == generation, isEnabled, !Task.isCancelled else {
            throw CloudPortfolioSyncError.cancelled
        }
    }

    private func validate(_ account: String, operation: Int) async throws {
        try check(operation)
        guard try await identity() == account else { throw CloudPortfolioSyncError.accountChanged }
        try check(operation)
    }

    private func apply(_ error: Error) {
        switch error {
        case CloudPortfolioSyncError.noAccount: status = .noAccount
        case CloudPortfolioSyncError.accountChanged:
            status = .accountChanged
            isEnabled = false
            defaults.set(false, forKey: Self.enabledKey)
        case CloudPortfolioSyncError.missingKey: status = .waitingForKey
        case CloudPortfolioSyncError.locked: status = .locked
        case CloudPortfolioSyncError.unsupportedVersion: status = .unsupported
        case CloudPortfolioSyncError.invalidPayload: status = .invalidData
        case CloudPortfolioSyncError.tooLarge: status = .tooLarge
        case LocalPortfolioSyncError.accountConflict: status = .accountConflict
        case LocalPortfolioSyncError.cancelled: break
        case LocalPortfolioSyncError.unsupportedDocument: status = .unsupported
        case CloudPortfolioSyncError.cancelled: break
        case let error as CKError:
            switch error.code {
            case .notAuthenticated: status = .noAccount
            case .quotaExceeded: status = .quotaExceeded
            case .badContainer, .missingEntitlement, .permissionFailure, .serverRejectedRequest: status = .notConfigured
            default: status = .unavailable
            }
        default: status = .unavailable
        }
    }
}
