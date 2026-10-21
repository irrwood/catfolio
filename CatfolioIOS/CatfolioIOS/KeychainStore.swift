import Foundation
import Security

enum KeychainStore {
    static var service: String {
        Bundle.main.bundleIdentifier ?? "com.catfolio.ios"
    }
    static let didChangeNotification = Notification.Name("CatfolioKeychainDidChange")

    /// App consumers always use a device-local working copy. Merely reading a
    /// key must never opt a device into iCloud or reopen sync after it is off.
    static func string(for key: String) -> String? {
        guard let data = try? data(for: key, service: service, synchronizable: false) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) throws {
        try setLocal(value, for: key)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func setLocal(_ value: String, for key: String) throws {
        try setData(value.isEmpty ? nil : Data(value.utf8), for: key, service: service, synchronizable: false)
    }

    static func data(for key: String, service: String, synchronizable: Bool) throws -> Data? {
        var query = baseQuery(service: service, synchronizable: synchronizable)
        query[kSecAttrAccount as String] = key
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.readFailed(status) }
        return data
    }

    static func allData(service: String, synchronizable: Bool) throws -> [String: Data] {
        var query = baseQuery(service: service, synchronizable: synchronizable)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            throw KeychainError.readFailed(status)
        }
        return Dictionary(items.compactMap { item in
            guard let key = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { return nil }
            return (key, data)
        }, uniquingKeysWith: { _, last in last })
    }

    /// Local and synchronizable records have different identities. A failed
    /// cloud write cannot destroy the existing ThisDeviceOnly credential.
    static func setData(_ data: Data?, for key: String, service: String, synchronizable: Bool) throws {
        var query = baseQuery(service: service, synchronizable: synchronizable)
        query[kSecAttrAccount as String] = key
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.deleteFailed(status)
            }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: synchronizable
                ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.writeFailed(updateStatus) }
        attributes.forEach { query[$0.key] = $0.value }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.writeFailed(status) }
    }

    private static func baseQuery(service: String, synchronizable: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrSynchronizable as String: synchronizable]
    }
}

enum KeychainError: LocalizedError {
    case readFailed(OSStatus)
    case writeFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .readFailed(status): L10n.text("无法读取 Keychain（\(status)）")
        case let .writeFailed(status): L10n.text("无法保存到 Keychain（\(status)）")
        case let .deleteFailed(status): L10n.text("无法从 Keychain 移除密钥（\(status)）")
        }
    }
}
