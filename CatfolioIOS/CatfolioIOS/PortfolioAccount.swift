import Foundation
import CryptoKit

enum AccountConnectorContext {
    case create
    case manage(PortfolioAccount)

    var isCreating: Bool {
        if case .create = self { return true }
        return false
    }

    var account: PortfolioAccount? {
        if case let .manage(account) = self { return account }
        return nil
    }
}

enum AccountNaming {
    static let generatedNicknames = [
        "橘子", "蓝莓", "水獭", "熊猫", "柚子", "樱桃", "松鼠", "海豚",
    ]

    static func providerName(for source: String) -> String {
        switch source {
        case "IBKR Flex": "IBKR"
        default: source
        }
    }

    static func displayName(provider: String, nickname rawNickname: String) -> String {
        let nickname = rawNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nickname.isEmpty else { return provider }
        let prefix = "\(provider) · "
        return nickname.hasPrefix(prefix) ? nickname : prefix + nickname
    }

    static func nickname(from displayName: String, provider: String) -> String {
        let prefix = "\(provider) · "
        return displayName.hasPrefix(prefix) ? String(displayName.dropFirst(prefix.count)) : displayName
    }
}

struct PortfolioAccount: Identifiable, Equatable, Codable {
    let id: String
    let accountID: String?
    let source: String
    let name: String
    let baseCurrency: String
    let positionCount: Int
    let transactionCount: Int
    let manualTransactionCount: Int
    let hasCSVImport: Bool
    let marketValueUSD: Double
    /// The broker product the person chose when connecting this account,
    /// stored as a `Trading212AccountType` raw value.
    ///
    /// Trading 212 reports an account number and a currency, never whether the
    /// account is an ISA, so the choice cannot be derived and has to survive
    /// every sync, merge and reset of the positions around it.
    var accountTypeOverride: String? = nil

    /// Registered but never synced.
    ///
    /// Derived rather than stored: an account only reaches `knownAccounts`
    /// with no positions and no transactions when it was created ahead of its
    /// first sync, and the flag clears itself the moment anything lands.
    /// SnapTrade accounts are created only after a confirmed complete preview,
    /// so an empty SnapTrade account has already synced successfully.
    var awaitsFirstSync: Bool {
        !["SnapTrade", "Robinhood"].contains(source) && positionCount == 0 && transactionCount == 0
    }

    var brokerName: String {
        switch source {
        case "IBKR Flex": "IBKR"
        case "CSV": "CSV"
        case "公开披露": name
        default: source
        }
    }

    var accountType: String {
        if let chosen = chosenAccountType { return chosen.displayName }
        return switch source {
        case "Trading 212":
            // The credential slot an account was added under used to decide
            // this, which labelled a second Invest account as an ISA. The slot
            // is a local key index, so an account with no chosen type says so
            // rather than guessing.
            "未设置"
        case "IBKR Flex": "Individual"
        case "Moomoo": "Individual"
        case "CSV": "手动账户"
        case "假数据": "演示账户"
        case "公开披露": "投资账户"
        default: "投资账户"
        }
    }

    var chosenAccountType: Trading212AccountType? {
        accountTypeOverride.flatMap(Trading212AccountType.init(rawValue:))
    }

    var displayName: String {
        if source == "IBKR Flex", name.hasPrefix("IBKR · ••••") {
            return "IBKR · Individual"
        }
        return name
    }

    var localizedDisplayName: String { L10n.accountName(displayName) }

    var syncedSourceTitle: String {
        switch source {
        case "Trading 212": "Trading 212 API / 同步数据"
        case "IBKR Flex": "IBKR Flex / 同步数据"
        case "Moomoo": "Moomoo API / 同步数据"
        case "CSV": "CSV 导入"
        case "假数据": "本机演示数据"
        default: "本机数据"
        }
    }
}

struct HoldingDetailAccountOption: Identifiable, Equatable {
    let id: String
    let displayName: String
    let marketValue: Double
    let currency: String
    let marketValueUSD: Double
    /// Existing engine P&L converted to the card's quote currency. Public
    /// disclosures without a cost basis leave this unknown, never zero.
    var unrealized: Double? = nil

    static func unrealizedPercent(marketValue: Double, unrealized: Double?) -> Double? {
        guard marketValue.isFinite, let unrealized, unrealized.isFinite else { return nil }
        let cost = marketValue - unrealized
        guard cost > 0 else { return nil }
        let percent = unrealized / cost * 100
        return percent.isFinite ? percent : nil
    }
}

struct HoldingDetailAccountContext: Equatable {
    let ticker: String
    let document: LocalPortfolioDocument
    let options: [HoldingDetailAccountOption]
    /// Accounts that traded this security and have since sold all of it.
    /// They hold no position, so they are not options to pick, but their
    /// trades are still this security's history.
    let closedAccountKeys: Set<String>

    init(ticker: String, document: LocalPortfolioDocument, options: [HoldingDetailAccountOption]) {
        self.ticker = ticker
        self.document = document
        self.options = options
        let holding = Set(options.map(\.id))
        closedAccountKeys = Set((document.transactions ?? []).lazy
            .filter { $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame }
            .map(\.accountKey))
            .subtracting(holding)
    }

    var allAccountKeys: Set<String> {
        Set(options.map(\.id))
    }

    func holding(for accountKeys: Set<String>) -> Holding? {
        let effectiveKeys = accountKeys.intersection(allAccountKeys)
        guard !effectiveKeys.isEmpty,
              let presentation = try? LocalPortfolioEngine.presentation(
                for: document.scoped(to: effectiveKeys)
              ) else { return nil }
        return presentation.2.first {
            $0.ticker.caseInsensitiveCompare(ticker) == .orderedSame
        }
    }

    func document(for accountKeys: Set<String>) -> LocalPortfolioDocument {
        document.scoped(to: accountKeys.intersection(allAccountKeys))
    }

    /// Whose trades to show for a selection: with every holding account
    /// selected, the closed accounts' trades too; a narrower pick is only
    /// those accounts.
    func tradeAccountKeys(for accountKeys: Set<String>) -> Set<String> {
        let selected = accountKeys.intersection(allAccountKeys)
        guard !selected.isEmpty, selected == allAccountKeys else { return selected }
        return selected.union(closedAccountKeys)
    }
}
