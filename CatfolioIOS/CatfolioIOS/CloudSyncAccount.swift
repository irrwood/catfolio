import CloudKit
import CryptoKit
import Foundation

/// Both sync features bind their local working copy to this opaque identity.
/// An account switch must never upload the previous person's data.
enum CloudSyncAccount {
    static let containerIdentifier = "iCloud.com.catfolio.ios"

    static func current() async throws -> String {
        let container = CKContainer(identifier: containerIdentifier)
        guard try await container.accountStatus() == .available else {
            throw CloudPortfolioSyncError.noAccount
        }
        let user = try await container.userRecordID()
        return SHA256.hash(data: Data(user.recordName.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum CloudPortfolioSyncError: Error {
    case noAccount, accountChanged, missingKey, locked, invalidPayload, unsupportedVersion
    case conflict, cancelled, unavailable, tooLarge
}
