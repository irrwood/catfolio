import Foundation

/// Original disclosures shown in All History. Keep them separate from the
/// simulated fills used to reconstruct portfolio performance.
struct PublicInvestorHistory {
    var records: [PublicInvestorActivityItem] = []

    func scoped(accountIDs: Set<String>, ticker: String? = nil,
                basis: TaxYearBasis = .calendar, year: String? = nil) -> [PublicInvestorActivityItem] {
        let symbol = ticker?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return records.filter { record in
            accountIDs.contains("\(PublicInvestorAccountAdapter.source)|\(record.investor.id)")
                && (symbol == nil || record.historyTicker?.uppercased() == symbol)
                && (year == nil || basis.label(for: record.historyDate) == year)
        }
    }

    func years(accountIDs: Set<String>, ticker: String? = nil, basis: TaxYearBasis) -> [String] {
        Set(scoped(accountIDs: accountIDs, ticker: ticker)
            .compactMap { basis.label(for: $0.historyDate) }).sorted(by: >)
    }

    /// Keep every existing ledger row. Only supplement disclosures that did
    /// not produce a row (for example, options and private investments).
    func supplemental(to transactions: [LocalTransactionRecord]) -> Self {
        let existing = Set(transactions.compactMap { transaction in
            transaction.tradeID.map { "\(transaction.accountKey)|\($0)" }
        })
        return Self(records: records.filter { record in
            guard !record.isOption, let ticker = record.historyTicker else { return true }
            var events = [record.activity.id]
            if record.activity.exactDate == nil {
                events += (record.investor.history ?? record.investor.snapshot.map { [$0] } ?? []).filter {
                    $0.filedDate == record.activity.filedDate
                }.map { $0.snapshotId ?? $0.filedDate }
            }
            return !events.contains {
                existing.contains("\(PublicInvestorAccountAdapter.source)|\(record.investor.id)|investor-ledger-v1:\($0):\(ticker)")
            }
        })
    }

    static let exportHeader = ["Date", "Account", "Broker", "Type", "Name", "Ticker", "Amount", "Quantity", "Price", "Currency",
        "Amount Low", "Amount High", "Disclosure Date", "Period Start", "Period End", "Fund", "Option", "Source"]

    static func exportRow(_ record: PublicInvestorActivityItem) -> [String] {
        let activity = record.activity
        return [record.historyDate, record.investor.title, PublicInvestorAccountAdapter.source,
                activity.actionLabel, record.securityName, record.historyTicker ?? "",
                number(activity.amount), number(activity.sharesDelta ?? activity.shares), "", record.investor.snapshot?.currency ?? "USD",
                number(activity.amountLow), number(activity.amountHigh), activity.filedDate,
                activity.periodStart ?? "", activity.periodEnd ?? "", activity.fund ?? "",
                activity.option.map { [$0.putCall ?? "OPTION", $0.expiry, $0.strike.map { String($0) }]
                    .compactMap { $0 }.joined(separator: " ") } ?? "", activity.sourceURL]
    }

    private static func number(_ value: Double?) -> String {
        value.map { String($0) } ?? ""
    }
}

extension PublicInvestorActivityItem {
    var historyDate: String { activity.exactDate ?? activity.filedDate }
    var isOption: Bool { activity.option != nil || activity.type.hasPrefix("OPTION_") }

    var historyTicker: String? {
        activity.ticker ?? (investor.history ?? investor.snapshot.map { [$0] } ?? [])
            .reversed().lazy.flatMap(\.positions).first {
                activity.cusip != nil && $0.cusip == activity.cusip
            }?.ticker
    }

    var historySubtitle: String {
        var parts = isOption ? [L10n.text("期权")] : []
        parts.append(activity.actionLabel)
        if let shares = activity.sharesDelta ?? activity.shares {
            parts.append(L10n.text("\(DisplayFormat.shares(shares)) shares"))
        }
        parts.append(investor.title)
        return parts.joined(separator: " · ")
    }

    var historyAmount: String {
        guard activity.amount != nil || activity.amountLow != nil || activity.amountHigh != nil else { return "—" }
        return PublicDisclosureFormat.amount(activity.amount, low: activity.amountLow, high: activity.amountHigh)
    }
}

/// A presentation-only timeline. Disclosures never enter FIFO, P&L or the
/// stored transaction ledger, and cannot erase an existing transaction.
struct HistoryTimeline {
    enum Entry: Identifiable {
        case transaction(PortfolioActivity)
        case disclosure(PublicInvestorActivityItem)

        var id: String {
            switch self {
            case .transaction(let activity): "transaction:\(activity.id)"
            case .disclosure(let record): "disclosure:\(record.id)"
            }
        }
        var date: String {
            switch self {
            case .transaction(let activity): activity.transaction.date
            case .disclosure(let record): record.historyDate
            }
        }
    }

    struct Group: Identifiable {
        let id: String
        let entries: [Entry]
    }

    private var allGroups: [Group] = []
    private var years: [TaxYearBasis: [String: [Group]]] = [:]

    init(activities: [PortfolioActivity] = [], disclosures: [PublicInvestorActivityItem] = []) {
        let entries = activities.map(Entry.transaction) + disclosures.map(Entry.disclosure)
        allGroups = Dictionary(grouping: entries, by: \.date).map { date, rows in
            Group(id: date, entries: rows.sorted { $0.id > $1.id })
        }.sorted { $0.id > $1.id }
        for basis in TaxYearBasis.allCases {
            for group in allGroups {
                if let year = basis.label(for: group.id) { years[basis, default: [:]][year, default: []].append(group) }
            }
        }
    }

    func groups(basis: TaxYearBasis, year: String?) -> [Group] {
        year.map { years[basis]?[$0] ?? [] } ?? allGroups
    }

    func yearLabels(basis: TaxYearBasis) -> [String] {
        Array((years[basis] ?? [:]).keys).sorted(by: >)
    }
}
