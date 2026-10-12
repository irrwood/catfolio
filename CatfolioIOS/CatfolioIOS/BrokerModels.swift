import Foundation

enum BrokerProvider: String, CaseIterable, Codable, Identifiable {
    case snaptrade
    case trading212
    case moomoo
    case ibkr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .trading212: "Trading 212"
        case .moomoo: "Moomoo"
        case .ibkr: "Interactive Brokers"
        case .snaptrade: "SnapTrade"
        }
    }

    var systemImage: String {
        switch self {
        case .trading212: "chart.line.uptrend.xyaxis"
        case .moomoo: "network"
        case .ibkr: "building.columns"
        case .snaptrade: "link"
        }
    }

    var setupHint: String {
        switch self {
        case .trading212:
            L10n.text("支持 iPhone 直连并合并两个账户。")
        case .moomoo:
            L10n.text("支持 iPhone OAuth 2.1 + PKCE 直连。")
        case .ibkr:
            L10n.text("支持 iPhone 直连 IBKR Flex Web Service。")
        case .snaptrade:
            L10n.text("使用个人 API 连接券商账户")
        }
    }
}

struct BrokerRefreshResult: Decodable {
    let ok: Bool
    let provider: BrokerProvider?
    let label: String?
    let holdings: Int?
    let changes: BrokerChanges?
    let warnings: [String]?
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case ok, provider, label, holdings, changes, warnings
        case durationSeconds = "duration_seconds"
    }
}

struct BrokerChanges: Decodable {
    let added: Int
    let updated: Int
    let removed: Int
    let unchanged: Int
}

struct CSVImportResult: Decodable {
    let ok: Bool
    let holdingsCount: Int
    let transactionsCount: Int?
    let backupCreated: Bool?
    let warnings: [String]
    let holdings: [CSVImportedHolding]?
    /// Rows the local importer could not read and left out. Not part of the
    /// server payload.
    var skippedRowCount = 0

    enum CodingKeys: String, CodingKey {
        case ok, warnings, holdings
        case holdingsCount = "holdings_count"
        case transactionsCount = "transactions_count"
        case backupCreated = "backup_created"
    }
}

struct CSVImportedHolding: Decodable, Identifiable {
    let ticker: String
    let name: String
    let shares: Double
    let averageCost: Double
    let currency: String

    var id: String { ticker }

    enum CodingKeys: String, CodingKey {
        case ticker, name, shares, currency
        case averageCost = "avg_cost"
    }
}
