import CloudKit
import Foundation

struct CloudPortfolioRemoteRecord {
    var payload: Data
    var systemFields: Data?
}

@MainActor
protocol CloudPortfolioTransport {
    func fetch(account: String) async throws -> CloudPortfolioRemoteRecord?
    func save(_ payload: Data, replacing: CloudPortfolioRemoteRecord?, account: String) async throws
}

/// CloudKit sees an opaque encrypted asset and its normal record metadata.
/// CAS on the single record makes simultaneous writers retry the logical merge.
@MainActor
final class CloudKitPortfolioTransport: CloudPortfolioTransport {
    private var database: CKDatabase {
        CKContainer(identifier: CloudSyncAccount.containerIdentifier).privateCloudDatabase
    }
    private func recordID(account: String) -> CKRecord.ID {
        // If the system switches accounts while a request is in flight, it
        // cannot overwrite the new account's vault under a shared fixed name.
        CKRecord.ID(recordName: "portfolio.v1." + account)
    }

    func fetch(account: String) async throws -> CloudPortfolioRemoteRecord? {
        let recordID = recordID(account: account)
        let record: CKRecord
        do { record = try await database.record(for: recordID) }
        catch let error as CKError where error.code == .unknownItem { return nil }
        guard let asset = record["encryptedPayload"] as? CKAsset, let url = asset.fileURL else {
            throw CloudPortfolioSyncError.invalidPayload
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= CloudPortfolioCrypto.maximumBytes * 2 else { throw CloudPortfolioSyncError.tooLarge }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return CloudPortfolioRemoteRecord(payload: try Data(contentsOf: url), systemFields: archiver.encodedData)
    }

    func save(_ payload: Data, replacing previous: CloudPortfolioRemoteRecord?, account: String) async throws {
        let recordID = recordID(account: account)
        let record: CKRecord
        if let fields = previous?.systemFields {
            let decoder = try NSKeyedUnarchiver(forReadingFrom: fields)
            decoder.requiresSecureCoding = true
            defer { decoder.finishDecoding() }
            guard let restored = CKRecord(coder: decoder), restored.recordID == recordID else { throw CloudPortfolioSyncError.invalidPayload }
            record = restored
        } else {
            record = CKRecord(recordType: "CatfolioEncryptedPortfolio", recordID: recordID)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catfolio-vault-\(UUID()).encrypted")
        defer { try? FileManager.default.removeItem(at: url) }
        try payload.write(to: url, options: [.atomic, .completeFileProtection])
        record["encryptedPayload"] = CKAsset(fileURL: url)
        do {
            let results = try await database.modifyRecords(saving: [record], deleting: [],
                savePolicy: .ifServerRecordUnchanged, atomically: false)
            guard let saved = results.saveResults[recordID] else { throw CloudPortfolioSyncError.unavailable }
            _ = try saved.get()
        } catch let error as CKError where error.code == .serverRecordChanged {
            throw CloudPortfolioSyncError.conflict
        }
    }
}
