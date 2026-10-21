import CryptoKit
import Foundation
import Security

protocol PortfolioEncryptionKeyStore {
    func read(id: String, account: String) throws -> Data?
    func write(_ data: Data, id: String, account: String) throws
}

/// Separate from API-key sync: the portfolio switch alone enables this vault's
/// encryption keys. No encryption key is ever put in a CloudKit record.
struct PortfolioKeychainKeys: PortfolioEncryptionKeyStore {
    private func query(id: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.catfolio.ios.portfolio-vault.v1",
         kSecAttrAccount as String: account + "." + id,
         kSecAttrSynchronizable as String: true]
    }

    func read(id: String, account: String) throws -> Data? {
        var attributes = query(id: id, account: account)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CloudPortfolioSyncError.locked
        }
        return data
    }

    func write(_ data: Data, id: String, account: String) throws {
        var attributes = query(id: id, account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(attributes as CFDictionary, nil)
        // UUID identities are immutable: never replace a key for existing data.
        if status == errSecDuplicateItem,
           try read(id: id, account: account) == data { return }
        guard status == errSecSuccess else { throw CloudPortfolioSyncError.locked }
    }
}

struct CloudPortfolioCrypto {
    struct Envelope: Codable {
        var version: Int
        var keyID: String
        var ciphertext: Data
    }
    static let maximumBytes = 20 * 1024 * 1024
    let keys: any PortfolioEncryptionKeyStore

    init(keys: any PortfolioEncryptionKeyStore = PortfolioKeychainKeys()) { self.keys = keys }

    func seal(_ document: LocalPortfolioDocument, account: String, keyID: String? = nil) throws -> Data {
        guard PortfolioDocumentMerge.isUploadable(document) else { throw CloudPortfolioSyncError.invalidPayload }
        guard (1...4).contains(document.schemaVersion) else { throw CloudPortfolioSyncError.unsupportedVersion }
        // Reject an unencodable/oversized document before creating any
        // synchronizable key. Automatic retries must not litter the vault.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(document)
        guard plaintext.count <= Self.maximumBytes else { throw CloudPortfolioSyncError.tooLarge }
        let id = keyID ?? UUID().uuidString
        let key: Data
        if let keyID {
            guard let existing = try keys.read(id: keyID, account: account) else { throw CloudPortfolioSyncError.missingKey }
            key = existing
        } else {
            key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try keys.write(key, id: id, account: account)
        }
        guard key.count == 32 else { throw CloudPortfolioSyncError.invalidPayload }
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key),
            authenticating: associatedData(account: account, keyID: id))
        guard let combined = sealed.combined else { throw CloudPortfolioSyncError.invalidPayload }
        return try JSONEncoder().encode(Envelope(version: 1, keyID: id, ciphertext: combined))
    }

    func open(_ data: Data, account: String) throws -> (document: LocalPortfolioDocument, keyID: String) {
        guard data.count <= Self.maximumBytes * 2 else { throw CloudPortfolioSyncError.tooLarge }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw CloudPortfolioSyncError.invalidPayload }
        guard envelope.version == 1 else { throw CloudPortfolioSyncError.unsupportedVersion }
        guard UUID(uuidString: envelope.keyID) != nil else { throw CloudPortfolioSyncError.invalidPayload }
        guard let key = try keys.read(id: envelope.keyID, account: account) else {
            // The record may arrive before the Keychain item. Never generate a
            // replacement, overwrite the cloud, or discard local data here.
            throw CloudPortfolioSyncError.missingKey
        }
        guard key.count == 32 else { throw CloudPortfolioSyncError.invalidPayload }
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key),
                authenticating: associatedData(account: account, keyID: envelope.keyID))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(LocalPortfolioDocument.self, from: plaintext)
            guard PortfolioDocumentMerge.isUploadable(document), (1...4).contains(document.schemaVersion) else {
                throw CloudPortfolioSyncError.unsupportedVersion
            }
            return (document, envelope.keyID)
        } catch let error as CloudPortfolioSyncError { throw error }
        catch { throw CloudPortfolioSyncError.invalidPayload }
    }

    private func associatedData(account: String, keyID: String) -> Data {
        Data("catfolio.portfolio.v1|\(account)|\(keyID)".utf8)
    }
}
