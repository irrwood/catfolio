import SwiftUI
import Charts
import UniformTypeIdentifiers

struct PortfolioActivityLedger: Equatable {
    let accounts: [PortfolioAccount]
    let transactions: [LocalTransactionRecord]
    let securityNames: [String: String]
}

enum HistoryCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case orders = "Orders"
    case dividends = "Dividends"
    case interest = "Interest"
    /// Not an activity. The ledger records what was traded; a fund's charge
    /// is a property of holding it, and it is the one cost in this app that
    /// accrues without ever appearing as a transaction.
    case fees = "Fees"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .all: "tray.full"
        case .orders: "arrow.up.arrow.down"
        case .dividends: "banknote.fill"
        case .interest: "percent"
        case .fees: "creditcard"
        }
    }

    func includes(_ kind: PortfolioActivityKind) -> Bool {
        switch self {
        case .all: true
        case .orders: kind == .buy || kind == .sell
        case .dividends: kind == .dividend
        case .fees: false
        case .interest: kind == .interest
        }
    }
}

enum PortfolioActivityKind: Equatable {
    case buy
    case sell
    case dividend
    case deposit
    case withdrawal
    case transfer
    case interest
    case other

    init(action: String) {
        let normalized = action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        if normalized.contains("DIVIDEND") {
            self = .dividend
        } else if normalized.contains("INTEREST") {
            self = .interest
        } else if ["BUY", "BUY_BACK"].contains(normalized) {
            self = .buy
        } else if ["SELL", "SELL_SHORT"].contains(normalized) {
            self = .sell
        } else if ["DEPOSIT", "CASH_DEPOSIT", "FUNDING", "TRANSFER_IN"].contains(normalized) {
            self = .deposit
        } else if ["WITHDRAW", "WITHDRAWAL", "CASH_WITHDRAWAL", "TRANSFER_OUT"].contains(normalized) {
            self = .withdrawal
        } else if normalized.contains("TRANSFER") || normalized.contains("CURRENCY_EXCHANGE") {
            self = .transfer
        } else {
            self = .other
        }
    }

    var title: String {
        switch self {
        case .buy: L10n.text("Buy")
        case .sell: L10n.text("Sell")
        case .dividend: L10n.text("Dividend")
        case .deposit: L10n.text("Deposit")
        case .withdrawal: L10n.text("Withdrawal")
        case .transfer: L10n.text("Transfer")
        case .interest: L10n.text("Interest")
        case .other: L10n.text("Account activity")
        }
    }

    var systemImage: String {
        switch self {
        case .buy: "arrow.down.left"
        case .sell: "arrow.up.right"
        case .dividend: "banknote.fill"
        case .deposit: "arrow.down.to.line.compact"
        case .withdrawal: "arrow.up.from.line.compact"
        case .transfer: "arrow.left.arrow.right"
        case .interest: "percent"
        case .other: "clock.arrow.circlepath"
        }
    }

    var isCashTransfer: Bool {
        self == .deposit || self == .withdrawal || self == .transfer
    }
}

struct PortfolioActivity: Identifiable {
    let transaction: LocalTransactionRecord
    let securityName: String
    let kind: PortfolioActivityKind

    init(transaction: LocalTransactionRecord, securityName: String) {
        self.transaction = transaction
        self.securityName = securityName
        kind = PortfolioActivityKind(action: transaction.action)
    }

    var id: String { transaction.id }

    var nativeAmount: Double {
        let amount = transaction.quantity * transaction.price
        return switch kind {
        case .buy, .withdrawal:
            -abs(amount)
        case .sell, .deposit:
            abs(amount)
        default:
            amount
        }
    }

    var amountUSD: Double {
        nativeAmount * (LocalPortfolioEngine.usdRate(for: transaction.currency) ?? .nan)
    }

    var title: String {
        switch kind {
        case .interest:
            L10n.text("Interest on cash")
        case .deposit:
            L10n.text("Cash deposit")
        case .withdrawal:
            L10n.text("Cash withdrawal")
        case .transfer:
            transaction.ticker == "CASH" ? L10n.text("Cash transfer") : transaction.ticker
        case .other:
            transaction.ticker == "CASH" ? L10n.text("Account activity") : transaction.ticker
        default:
            securityName.isEmpty ? transaction.ticker : securityName
        }
    }

    var displayTitle: String {
        guard usesAssetLogo else { return title }
        if transaction.source == PublicInvestorAccountAdapter.source {
            return PublicDisclosureFormat.securityName(ticker: transaction.ticker, name: title)
        }
        return CompanyNameCatalog.displayName(ticker: transaction.ticker, fallback: title)
    }

    var usesAssetLogo: Bool {
        [.buy, .sell, .dividend].contains(kind)
            && !transaction.ticker.isEmpty
            && transaction.ticker.uppercased() != "CASH"
    }
}
