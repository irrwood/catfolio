import Foundation

/// Reuses an unambiguous local working copy after Keychain sync, without
/// creating an account, requesting broker data, or touching a setup draft.
enum BrokerCredentialPrefill {
    static func storedValues() -> [String: String] {
        guard let values = try? KeychainStore.allData(service: KeychainStore.service, synchronizable: false) else {
            return [:]
        }
        return values.compactMapValues { String(data: $0, encoding: .utf8) }
    }

    static func trading212(slot: Int, values: [String: String]) -> Trading212Credentials? {
        let id = "trading212.account-\(slot)"
        guard CloudCredentialPolicy.secretKeys(for: id) != nil,
              let key = values[id + ".api-key"],
              let secret = values[id + ".api-secret"] else { return nil }
        return try? Trading212Credentials(apiKey: key, apiSecret: secret)
    }

    static func ibkr(pendingToken: String, pendingQueryID: String,
                     values: [String: String]) -> IBKRFlexCredentials? {
        // Even a partial draft belongs to the reader and must remain intact.
        guard pendingToken.isEmpty, pendingQueryID.isEmpty else { return nil }
        var distinct: [IBKRFlexCredentials] = []
        for key in values.keys.sorted() where key.hasPrefix("ibkr.flex.account.") && key.hasSuffix(".token") {
            let id = String(key.dropLast(".token".count))
            guard CloudCredentialPolicy.secretKeys(for: id) != nil,
                  let token = values[key], let queryID = values[id + ".query-id"],
                  let credentials = try? IBKRFlexCredentials(token: token, queryID: queryID) else { continue }
            if !distinct.contains(credentials) { distinct.append(credentials) }
            // A multi-account report may save the same pair under several
            // account IDs. Different pairs must never be guessed between.
            if distinct.count > 1 { return nil }
        }
        return distinct.first
    }
}
