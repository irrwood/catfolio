import Foundation
import Observation

struct PublicInvestorCatalog: Decodable, Sendable {
    let schemaVersion: Int
    let releaseId: String
    let asOf: String
    let investors: [PublicInvestor]

    static let loaded: Result<PublicInvestorCatalog, Error> = Result {
        guard let url = Bundle.main.url(forResource: "public_investors", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        guard catalog.schemaVersion == 1,
              Set(catalog.investors.map(\.id)).count == catalog.investors.count else {
            throw CocoaError(.coderReadCorrupt)
        }
        return catalog
    }
}

/// A light observable handle for the bundled disclosure directory. The JSON
/// is decoded once off the main actor; headers and Settings can show a
/// loading state instead of blocking a scroll or navigation transition.
@MainActor @Observable
final class PublicInvestorCatalogState {
    static let shared = PublicInvestorCatalogState()

    private(set) var result: Result<PublicInvestorCatalog, Error>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    func loadIfNeeded() {
        guard result == nil, loadTask == nil else { return }
        loadTask = Task(priority: .utility) {
            do {
                let catalog = try await Task.detached(priority: .utility) {
                    try PublicInvestorCatalog.loaded.get()
                }.value
                result = .success(catalog)
            } catch {
                result = .failure(error)
            }
            loadTask = nil
        }
    }

    func get() async throws -> PublicInvestorCatalog {
        loadIfNeeded()
        await loadTask?.value
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}

enum PublicInvestorPreferences {
    static let enabledKey = "catfolio.publicInvestorMode"
    static let selectionKey = "catfolio.publicInvestorSelection"
    static let defaultSelection = "pelosi"

    /// The invented portfolio, offered alongside the real filers.
    ///
    /// It is not in `public_investors.json` and must not be: that file is
    /// generated from SEC and House disclosures, and a fabricated company has
    /// no place in it. It is a app-provided entry in the same picker, because
    /// from the reader's point of view demo data and someone else's portfolio
    /// are the same kind of thing — a portfolio that is not theirs.
    static let demoID = "demo"

    /// Invented data cannot be blended with disclosed data: a total mixing
    /// the two would describe nothing. Choosing the demo clears the filers,
    /// and choosing a filer clears the demo.
    static func selecting(_ id: String, in raw: String) -> String {
        // Choosing the demo while it is already chosen turns it off, leaving
        // nothing selected. Without this the row could be switched on and
        // never off, because the result equalled the current value and the
        // caller's change check swallowed it.
        if id == demoID { return isDemo(raw) ? "" : demoID }
        var ids = selectedIDs(raw)
        ids.remove(demoID)
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        return ids.sorted().joined(separator: ",")
    }

    static func isDemo(_ raw: String) -> Bool {
        selectedIDs(raw) == [demoID]
    }

    static func setting(_ id: String, isSelected: Bool, in raw: String) -> String {
        let current = id == demoID ? isDemo(raw) : selectedIDs(raw).contains(id)
        guard current != isSelected else { return raw }
        return selecting(id, in: raw)
    }

    private static let migrationKey = "catfolio.demoSelectionMigrated"

    /// Points the selection at the demo for anyone upgrading from the build
    /// where it was a separate switch.
    ///
    /// Without it the mode is on but the selection still names a filer, so
    /// the row reads "南希·佩洛西" while the app shows invented data.
    ///
    /// One shot, at launch, recorded in defaults. An earlier version ran this
    /// from the settings section's `.task`, which re-fires whenever that row
    /// is rebuilt — and since the mode flag is only cleared asynchronously,
    /// it kept stamping the selection back to the demo and no other portfolio
    /// could be chosen at all.
    static func migrateDemoSelectionIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: migrationKey)
        guard defaults.bool(forKey: "catfolio.fakeDataMode") else { return }
        defaults.set(demoID, forKey: selectionKey)
    }

    static func selectedIDs(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    static func toggling(_ id: String, in raw: String) -> String {
        var ids = selectedIDs(raw)
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        return ids.sorted().joined(separator: ",")
    }
}

struct PublicInvestor: Decodable, Identifiable, Sendable {
    let investorId: String
    let displayName: String
    let managerName: String
    let sourceType: String
    let portfolioSource: String
    let snapshot: PublicInvestorSnapshot?
    let activities: [PublicInvestorActivity]
    let history: [PublicInvestorSnapshot]?
    var id: String { investorId }
    /// Localised. The catalogue's own `displayName` is the filer's legal name
    /// as it appears in the disclosure and stays untranslated; this is the
    /// label the reader picks from, and a Chinese name in an English build
    /// reads as an untranslated string rather than a deliberate one.
    var title: String {
        switch id {
        case "pelosi": L10n.text("南希·佩洛西")
        case "hh": L10n.text("段永平 / H&H")
        case "berkshire": L10n.text("巴菲特 / Berkshire")
        case "scion": L10n.text("Michael Burry / Scion")
        case "ark": L10n.text("石头姐 / ARK")
        case "musk": L10n.text("埃隆·马斯克")
        default: displayName
        }
    }
    var sourceLabel: String {
        switch sourceType {
        case "HOUSE_PTR": L10n.text("国会家庭披露")
        case "SEC_13F": L10n.text("机构 13F 披露")
        default: "Public Ownership"
        }
    }
    var scopeNote: String {
        switch sourceType {
        case "HOUSE_PTR": L10n.text("家庭年度证券披露与交易申报，金额可能为区间，非完整实时账户。")
        case "SEC_13F": L10n.text("机构申报持仓，不代表个人账户或每笔投资的决策者。季度变化不是成交记录；期权价值为标的申报价值。")
        default: L10n.text("仅展示公开所有权记录，非个人投资组合。目前尚无可用记录。")
        }
    }
    var sortedActivities: [PublicInvestorActivity] {
        activities.filter { $0.type != "UNCHANGED" }.sorted {
            if $0.sortDate != $1.sortDate { return $0.sortDate > $1.sortDate }
            return $0.id < $1.id
        }
    }
}

struct PublicInvestorSnapshot: Decodable, Sendable {
    let snapshotId: String?
    let completeReport: Bool?
    let confidentialOmitted: Bool?
    let effectiveDate: String
    let filedDate: String
    let currency: String
    let sourceURL: String
    let confidence: String
    let positions: [PublicInvestorPosition]
}

struct PublicInvestorOption: Decodable, Sendable {
    let putCall: String?
    let strike: Double?
    let expiry: String?
}

struct PublicInvestorPosition: Decodable, Identifiable, Sendable {
    let positionId: String
    let issuerName: String?
    let ticker: String?
    let cusip: String?
    let shares: Double?
    let reportedValue: Double?
    let reportedValueLow: Double?
    let reportedValueHigh: Double?
    let owner: String?
    let option: PublicInvestorOption?
    let confidence: String
    var id: String { positionId }
    var title: String { ticker ?? issuerName ?? cusip ?? L10n.text("未匹配证券") }
}

struct PublicInvestorActivity: Decodable, Identifiable, Sendable {
    let activityId: String
    let type: String
    let exactDate: String?
    let periodStart: String?
    let periodEnd: String?
    let filedDate: String
    let sourceURL: String
    let ticker: String?
    let issuerName: String?
    let cusip: String?
    let shares: Double?
    let sharesDelta: Double?
    let amount: Double?
    let amountLow: Double?
    let amountHigh: Double?
    let owner: String?
    let option: PublicInvestorOption?
    let eventNature: String?
    let confidence: String
    var id: String { activityId }
    var sortDate: String { exactDate ?? periodEnd ?? filedDate }
    var title: String { ticker ?? issuerName ?? cusip ?? L10n.text("未匹配证券") }
    var dateLabel: String {
        if let exactDate { return exactDate }
        return "\(periodStart ?? "—") → \(periodEnd ?? "—")"
    }
    var actionLabel: String {
        if let eventNature, eventNature != "TRADE" {
            switch eventNature {
            case "EXPIRATION": return L10n.text("期权到期")
            case "EXERCISE": return L10n.text("期权行权")
            case "GIFT": return L10n.text("赠与")
            default: break
            }
        }
        switch type {
        case "BUY": return L10n.text("披露买入")
        case "SELL": return L10n.text("披露卖出")
        case "OPTION_BUY": return L10n.text("期权买入")
        case "OPTION_SELL": return L10n.text("期权卖出")
        case "OPENED": return L10n.text("季度新增")
        case "INCREASED": return L10n.text("季度增加")
        case "DECREASED": return L10n.text("季度减少")
        case "EXITED": return L10n.text("季度退出")
        case "CLOSED": return L10n.text("披露关闭")
        default: return type
        }
    }
}

enum PublicDisclosureFormat {
    /// Presentation only. Keep the disclosure text and option identity in the ledger.
    static func securityName(ticker: String, name: String,
                             mode: CompanyNameDisplay = .current) -> String {
        var clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let assetCodes = ["ST", "OP", "OL", "OI", "MF", "PS", "EF", "RP"]
        var assetCode: String?
        for code in assetCodes where clean.hasSuffix("[\(code)]") {
            clean = String(clean.dropLast(code.count + 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            assetCode = code
            break
        }
        if !ticker.isEmpty, clean.hasSuffix("(\(ticker))") {
            clean = String(clean.dropLast(ticker.count + 2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Private business interests must keep their own name even if the source
        // supplies an unrelated listed ticker.
        let companyTicker = ["OL", "OI", "RP"].contains(assetCode ?? "") ? "" : ticker
        return CompanyNameCatalog.displayName(ticker: companyTicker, fallback: clean, mode: mode)
    }

    static func amount(_ exact: Double?, low: Double?, high: Double?, currency: String = "USD") -> String {
        func money(_ value: Double) -> String {
            value.formatted(.currency(code: currency).precision(.fractionLength(0)))
        }
        if let exact { return money(exact) }
        if let low, let high { return "\(money(low))–\(money(high))" }
        if let low { return "≥ \(money(low))" }
        if let high { return "≤ \(money(high))" }
        return L10n.text("未披露")
    }
    static func owner(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value {
        case "SP": return L10n.text("配偶")
        case "JT": return L10n.text("共同持有")
        case "DC": return L10n.text("受抚养子女")
        default: return value
        }
    }
    static func confidence(_ value: String) -> String {
        switch value {
        case "VERIFIED": L10n.text("已核验")
        case "ESTIMATED": L10n.text("估算 / 身份推定")
        default: L10n.text("资料不完整")
        }
    }
}

/// Disclosure values travel through the same account/holding models as broker
/// data. Missing execution prices and quantities are never inferred from ranges.
struct PublicAccountDisclosure: Codable, Equatable {
    var value: Double?
    var low: Double?
    var high: Double?
    var currency: String
    var reportDates: [String]
    var filedDates: [String]
    var sourceURLs: [String]
    var underlyingTicker: String?
    var instrumentLabel: String?
    var owners: [String]
    var usesUpperBoundEstimate: Bool? = nil

    var amountLabel: String {
        PublicDisclosureFormat.amount(value, low: low, high: high, currency: currency)
    }

    static func combining(_ rows: [Self]) -> Self {
        func sum(_ values: [Double?]) -> Double? {
            values.allSatisfy { $0 != nil } ? values.compactMap { $0 }.reduce(0, +) : nil
        }
        return Self(value: sum(rows.map(\.value)),
                    low: sum(rows.map { $0.low ?? $0.value }),
                    high: sum(rows.map { $0.high ?? $0.value }),
                    currency: rows.first?.currency ?? "USD",
                    reportDates: Array(Set(rows.flatMap(\.reportDates))).sorted(),
                    filedDates: Array(Set(rows.flatMap(\.filedDates))).sorted(),
                    sourceURLs: Array(Set(rows.flatMap(\.sourceURLs))).sorted(),
                    underlyingTicker: rows.first?.underlyingTicker,
                    instrumentLabel: rows.first?.instrumentLabel,
                    owners: Array(Set(rows.flatMap(\.owners))).sorted(),
                    usesUpperBoundEstimate: rows.contains { $0.usesUpperBoundEstimate == true })
    }
}

enum PublicInvestorAccountAdapter {
    static let source = "公开披露"

    static func valuation(investorID: String, reportedValue: Double?, upperBound: Double?) -> Double? {
        reportedValue ?? (investorID == "pelosi" ? upperBound : nil)
    }

    static func document(catalog: PublicInvestorCatalog, selection: String) -> LocalPortfolioDocument {
        let selected = PublicInvestorPreferences.selectedIDs(selection)
        let investors = catalog.investors.filter { selected.contains($0.id) }
        var positions: [LocalPositionRecord] = []
        var accounts: [PortfolioAccount] = []
        for investor in investors {
            let rows = investor.snapshot?.positions ?? []
            var accountPositions: [LocalPositionRecord] = []
            for row in rows {
                guard let snapshot = investor.snapshot else { continue }
                let optionLabel = row.option.map { option in
                    [option.putCall ?? "OPTION", option.expiry, option.strike.map { String($0) }]
                        .compactMap { $0 }.joined(separator: " ")
                }
                // An option is not interchangeable with its underlying equity.
                let symbol = row.ticker ?? row.cusip ?? "未匹配-\(investor.id)-\(row.id)"
                let key = optionLabel.map { "\(symbol) [\($0)]" } ?? symbol
                var position = LocalPositionRecord(
                    ticker: key, name: row.issuerName ?? symbol,
                    shares: row.option == nil ? (row.shares ?? .nan) : .nan,
                    averageCost: .nan, currency: snapshot.currency,
                    quotePrice: .nan, quoteCurrency: snapshot.currency,
                    source: source, openedDate: nil,
                    accountID: investor.id, accountName: investor.title,
                    accountCurrency: snapshot.currency
                )
                position.publicDisclosure = PublicAccountDisclosure(
                    value: valuation(investorID: investor.id, reportedValue: row.reportedValue, upperBound: row.reportedValueHigh),
                    low: row.reportedValueLow, high: row.reportedValueHigh,
                    currency: snapshot.currency, reportDates: [snapshot.effectiveDate],
                    filedDates: [snapshot.filedDate], sourceURLs: [snapshot.sourceURL],
                    underlyingTicker: row.ticker, instrumentLabel: optionLabel,
                    owners: row.owner.map { [$0] } ?? [],
                    usesUpperBoundEstimate: investor.id == "pelosi" && row.reportedValue == nil && row.reportedValueHigh != nil
                )
                accountPositions.append(position)
            }
            positions += accountPositions
            accounts.append(PortfolioAccount(
                id: "\(source)|\(investor.id)", accountID: investor.id, source: source,
                name: investor.title, baseCurrency: investor.snapshot?.currency ?? "USD",
                positionCount: accountPositions.count, transactionCount: 0,
                manualTransactionCount: 0, hasCSVImport: false,
                marketValueUSD: (try? LocalPortfolioEngine.totals(for: accountPositions).marketValue) ?? .nan
            ))
        }
        return LocalPortfolioDocument(source: source,
            updatedAt: DayDateCodec.date(from: catalog.asOf) ?? .distantPast,
            positions: positions, snapshots: [], transactions: [], knownAccounts: accounts)
    }

    static func presentation(for document: LocalPortfolioDocument) throws -> (PortfolioOverview, PortfolioChartResponse, [Holding]) {
        let grouped = Dictionary(grouping: document.positions, by: \.ticker)
        let totals = try LocalPortfolioEngine.totals(for: document.positions)
        let holdings = try grouped.keys.sorted().compactMap { key -> Holding? in
            guard let rows = grouped[key], let first = rows.first else { return nil }
            let metadata = PublicAccountDisclosure.combining(rows.compactMap(\.publicDisclosure))
            let value = try LocalPortfolioEngine.usd(metadata.value ?? .nan, currency: metadata.currency)
            var holding = Holding(ticker: key, logoSymbol: metadata.underlyingTicker,
                displayName: first.name, sector: metadata.underlyingTicker.flatMap { SectorAttribution.primarySector(ticker: $0)?.displayName },
                source: source, shares: rows.reduce(0) { $0 + $1.shares }, averageCost: .nan,
                costCurrency: first.currency, quotePrice: .nan, quoteCurrency: first.currency,
                todayChangePercent: nil, marketValue: value,
                weight: totals.marketValue.isFinite && totals.marketValue > 0 ? value / totals.marketValue : .nan,
                unrealized: .nan, unrealizedPercent: .nan, fxPnl: nil, fxPnlPercent: nil,
                fxPnlStatus: nil, fxPnlSource: nil)
            holding.publicDisclosure = metadata
            return holding
        }
        let summary = PortfolioSummary(totalCost: .nan, openPositions: holdings.count,
            asOf: document.positions.compactMap { $0.publicDisclosure?.reportDates.joined(separator: ", ") }.sorted().last,
            marketValue: document.positions.isEmpty ? .nan : totals.marketValue, unrealized: .nan)
        return (PortfolioOverview(summary: summary),
            PortfolioChartResponse(positionCount: holdings.count,
                positionHistory: PositionHistory(available: false, rows: []),
                currentPoint: ChartPoint(dateText: DayDateFormatter.shared.string(from: document.updatedAt), marketValue: summary.marketValue, cost: .nan),
                warning: L10n.text("交易记录不足，暂时无法计算收益曲线。")), holdings)
    }
}

/// Reconstructed accounts use ordinary fills, positions and daily account totals.
/// These are simulation assumptions, not claims about the managers' executions:
/// 13F snapshots rebalance on filing day; Pelosi PTR uses its transaction day and
/// upper amount. Annual reports reconcile the account on filing day. Equity
/// prices are split-adjusted by the provider; restore contemporaneous prices
/// before writing fills so the shared ledger's split rules remain applicable.
enum PublicInvestorLedger {
    struct Result {
        var document: LocalPortfolioDocument
        var issues: [String]
    }
    private struct State {
        var quantity = 0.0
        var averageCost = 0.0
        var name: String
        var opened: String?
    }
    private struct Event {
        var date: String
        var id: String
        var investor: PublicInvestor
        var snapshot: PublicInvestorSnapshot?
        var activity: PublicInvestorActivity?
    }

    static func symbols(catalog: PublicInvestorCatalog, selection: String) -> [String] {
        let selected = PublicInvestorPreferences.selectedIDs(selection)
        return Array(Set(catalog.investors.filter { selected.contains($0.id) }.flatMap { investor in
            (investor.history ?? investor.snapshot.map { [$0] } ?? []).flatMap(\.positions)
                .filter { $0.option == nil }.compactMap(\.ticker)
            + investor.activities.filter { $0.option == nil && ["BUY", "SELL"].contains($0.type) }.compactMap(\.ticker)
        })).sorted()
    }

    static func build(catalog: PublicInvestorCatalog, selection: String,
                      prices: [String: [String: Double]], splits: StockSplitCatalog?, asOf: String) -> Result {
        let investors = catalog.investors.filter { PublicInvestorPreferences.selectedIDs(selection).contains($0.id) }
        var issues: [String] = []
        let cleanPrices = prices.mapValues { history in history.filter { $0.key <= asOf && $0.value.isFinite && $0.value > 0 } }
        let days = Array(Set(cleanPrices.values.flatMap { $0.keys })).sorted()
        var events: [Event] = []
        for investor in investors {
            for snapshot in investor.history ?? investor.snapshot.map({ [$0] }) ?? [] where snapshot.filedDate <= asOf {
                events.append(Event(date: snapshot.filedDate, id: snapshot.snapshotId ?? snapshot.filedDate,
                                    investor: investor, snapshot: snapshot))
            }
            if investor.id == "pelosi" {
                for activity in investor.activities where activity.filedDate <= catalog.asOf {
                    guard ["BUY", "SELL"].contains(activity.type), activity.option == nil,
                          let date = activity.exactDate, date <= asOf else {
                        issues.append("unsupported-activity:\(activity.id)"); continue
                    }
                    events.append(Event(date: date, id: activity.id, investor: investor, activity: activity))
                }
            }
        }
        events.sort { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        var states: [String: [String: State]] = [:]
        var flows: [String: Double] = [:]
        var fills: [LocalTransactionRecord] = []
        var snapshots: [LocalPortfolioSnapshotRecord] = []
        var eventIndex = 0
        var previousDay: String?
        var latestReport: [String: String] = [:]
        var knownCUSIPs: [String: [String: Set<String>]] = [:]
        func splitFactor(_ ticker: String, after start: String, through end: String) -> Double {
            (splits?.events(ticker: ticker, after: start) ?? []).filter { $0.d <= end }
                .reduce(1) { $0 * ($1.factor ?? 1) }
        }
        // Materialize one forward-filled (maximum seven days) raw-close lookup.
        // Avoid rescanning a symbol's entire price history for every daily cell.
        var rawPrices: [String: [String: Double]] = [:]
        for (ticker, history) in cleanPrices {
            let ordered = history.keys.sorted()
            var cursor = 0
            var last: String?
            for day in days {
                while cursor < ordered.count && ordered[cursor] <= day { last = ordered[cursor]; cursor += 1 }
                guard let last, let from = DayDateCodec.date(from: last), let to = DayDateCodec.date(from: day),
                      to.timeIntervalSince(from) <= 7 * 86400, let close = history[last] else { continue }
                rawPrices[ticker, default: [:]][day] = close * splitFactor(ticker, after: day, through: asOf)
            }
        }
        func price(_ ticker: String, on day: String) -> Double? { rawPrices[ticker]?[day] }
        func trade(investor: PublicInvestor, ticker: String, name: String, delta: Double,
                   close: Double, day: String, eventID: String) {
            guard delta.isFinite, abs(delta) > 0.00000001 else { return }
            var state = states[investor.id]?[ticker] ?? State(name: name)
            let signed = delta < 0 ? -min(-delta, state.quantity) : delta
            if delta < -state.quantity - 0.00000001 { issues.append("unmatched-sale:\(eventID):\(ticker)") }
            guard abs(signed) > 0.00000001 else { return }
            if signed > 0 {
                if state.quantity < 0.00000001 { state.opened = day }
                state.averageCost = (state.quantity * state.averageCost + signed * close) / (state.quantity + signed)
            }
            state.quantity += signed
            if state.quantity < 0.00000001 { state.quantity = 0; state.averageCost = 0; state.opened = nil }
            states[investor.id, default: [:]][ticker] = state
            flows[investor.id, default: 0] += signed * close
            fills.append(LocalTransactionRecord(date: day, action: signed > 0 ? "BUY" : "SELL",
                ticker: ticker, quantity: abs(signed), price: close, currency: "USD",
                source: PublicInvestorAccountAdapter.source, accountID: investor.id, accountName: investor.title,
                tradeID: "investor-ledger-v1:\(eventID):\(ticker)", entryMethod: "investor-simulation"))
        }
        for day in days {
            if let previousDay {
                for investor in investors {
                    for ticker in Array((states[investor.id] ?? [:]).keys) {
                        let factor = splitFactor(ticker, after: previousDay, through: day)
                        if factor != 1, var state = states[investor.id]?[ticker] {
                            state.quantity *= factor; state.averageCost /= factor
                            states[investor.id]?[ticker] = state
                        }
                    }
                }
            }
            previousDay = day
            while eventIndex < events.count && events[eventIndex].date <= day {
                let event = events[eventIndex]; eventIndex += 1
                guard let eventDate = DayDateCodec.date(from: event.date), let date = DayDateCodec.date(from: day),
                      date.timeIntervalSince(eventDate) <= 7 * 86400 else {
                    issues.append("missing-event-price:\(event.id)"); continue
                }
                if let snapshot = event.snapshot {
                    let priorReport = latestReport[event.investor.id]
                    if let priorReport, snapshot.effectiveDate < priorReport {
                        issues.append("superseded-report:\(event.id)"); continue
                    }
                    let continuous: Bool = {
                        guard let priorReport, let before = DayDateCodec.date(from: priorReport),
                              let after = DayDateCodec.date(from: snapshot.effectiveDate) else { return true }
                        let distance = Calendar(identifier: .gregorian).dateComponents([.month], from: before, to: after).month ?? 0
                        return (2...3).contains(distance)
                    }()
                    latestReport[event.investor.id] = snapshot.effectiveDate
                    let validRows = snapshot.positions.filter { $0.option == nil && $0.ticker != nil }
                    for row in snapshot.positions where row.option != nil || row.ticker == nil {
                        issues.append("unsupported-position:\(event.id):\(row.id)")
                    }
                    let grouped = Dictionary(grouping: validRows, by: { $0.ticker! })
                    for ticker in grouped.keys.sorted() {
                        let rows = grouped[ticker]!
                        knownCUSIPs[event.investor.id, default: [:]][ticker, default: []].formUnion(rows.compactMap(\.cusip))
                        guard let close = price(ticker, on: day) else { issues.append("missing-price:\(event.id):\(ticker)"); continue }
                        let target: Double
                        if event.investor.id == "pelosi" {
                            let values = rows.map { PublicInvestorAccountAdapter.valuation(investorID: "pelosi", reportedValue: $0.reportedValue, upperBound: $0.reportedValueHigh) }
                            guard values.allSatisfy({ $0 != nil }) else { issues.append("missing-value:\(event.id):\(ticker)"); continue }
                            target = values.compactMap { $0 }.reduce(0, +) / close
                        } else {
                            guard rows.allSatisfy({ $0.shares != nil }) else { issues.append("missing-quantity:\(event.id):\(ticker)"); continue }
                            target = rows.compactMap(\.shares).reduce(0, +) * splitFactor(ticker, after: snapshot.effectiveDate, through: day)
                        }
                        trade(investor: event.investor, ticker: ticker, name: rows.first?.issuerName ?? ticker,
                              delta: target - (states[event.investor.id]?[ticker]?.quantity ?? 0), close: close, day: day, eventID: event.id)
                    }
                    if event.investor.sourceType == "SEC_13F", snapshot.completeReport == true, snapshot.confidentialOmitted != true, continuous {
                        let unresolvedCUSIPs = Set(snapshot.positions.filter { $0.option == nil && $0.ticker == nil }.compactMap(\.cusip))
                        for ticker in Array((states[event.investor.id] ?? [:]).keys).sorted() where grouped[ticker] == nil {
                            // One unresolved row must not keep every exited stock
                            // alive. Retain only a prior holding sharing its CUSIP.
                            guard (knownCUSIPs[event.investor.id]?[ticker] ?? []).isDisjoint(with: unresolvedCUSIPs) else { continue }
                            guard let state = states[event.investor.id]?[ticker], let close = price(ticker, on: day) else { continue }
                            trade(investor: event.investor, ticker: ticker, name: state.name, delta: -state.quantity, close: close, day: day, eventID: event.id)
                        }
                    }
                } else if let activity = event.activity, let ticker = activity.ticker {
                    guard let close = price(ticker, on: day) else { issues.append("missing-price:\(event.id):\(ticker)"); continue }
                    let amount = activity.amountHigh ?? activity.amount
                    guard let amount, amount.isFinite, amount > 0 else { issues.append("missing-amount:\(event.id)"); continue }
                    trade(investor: event.investor, ticker: ticker, name: activity.issuerName ?? ticker,
                          delta: amount / close * (activity.type == "BUY" ? 1 : -1), close: close, day: day, eventID: event.id)
                }
            }
            guard !fills.isEmpty else { continue }
            var accountTotals: [String: LocalAccountSnapshotTotals] = [:]
            var complete = true
            for investor in investors {
                var value = 0.0
                for (ticker, state) in states[investor.id] ?? [:] where state.quantity > 0 {
                    guard let close = price(ticker, on: day) else { complete = false; continue }
                    value += state.quantity * close
                }
                accountTotals["\(PublicInvestorAccountAdapter.source)|\(investor.id)"] = LocalAccountSnapshotTotals(marketValueUSD: value, costUSD: flows[investor.id] ?? 0)
            }
            if complete {
                snapshots.append(LocalPortfolioSnapshotRecord(date: day,
                    marketValueUSD: accountTotals.values.reduce(0) { $0 + $1.marketValueUSD },
                    costUSD: accountTotals.values.reduce(0) { $0 + $1.costUSD }, accountTotals: accountTotals))
            }
        }
        for event in events.dropFirst(eventIndex) { issues.append("missing-event-price:\(event.id)") }
        let lastDay = days.last ?? asOf
        var positions: [LocalPositionRecord] = []
        for investor in investors {
            for ticker in (states[investor.id] ?? [:]).keys.sorted() {
                guard let state = states[investor.id]?[ticker], state.quantity > 0 else { continue }
                guard let close = price(ticker, on: lastDay) else { issues.append("missing-current-price:\(investor.id):\(ticker)"); continue }
                positions.append(LocalPositionRecord(ticker: ticker, name: state.name, shares: state.quantity,
                    averageCost: state.averageCost, currency: "USD", quotePrice: close, quoteCurrency: "USD",
                    source: PublicInvestorAccountAdapter.source, openedDate: state.opened,
                    accountID: investor.id, accountName: investor.title, accountCurrency: "USD"))
            }
        }
        let accounts = investors.map { investor in
            PortfolioAccount(id: "\(PublicInvestorAccountAdapter.source)|\(investor.id)", accountID: investor.id,
                source: PublicInvestorAccountAdapter.source, name: investor.title, baseCurrency: "USD",
                positionCount: positions.filter { $0.accountID == investor.id }.count,
                transactionCount: fills.filter { $0.accountID == investor.id }.count, manualTransactionCount: 0,
                hasCSVImport: false, marketValueUSD: positions.filter { $0.accountID == investor.id }.reduce(0) { $0 + $1.shares * $1.quotePrice })
        }
        return Result(document: LocalPortfolioDocument(source: PublicInvestorAccountAdapter.source,
            updatedAt: DayDateCodec.date(from: lastDay) ?? .distantPast, positions: positions,
            snapshots: snapshots, transactions: fills, knownAccounts: accounts), issues: issues)
    }
}

enum PortfolioSource: Hashable, Sendable {
    case personal
    case demo
    case publicInvestors(String)
}

actor PublicInvestorSimulationStore {
    static let shared = PublicInvestorSimulationStore()
    private var pending: [String: Task<LocalPortfolioDocument, Error>] = [:]
    private var cached: [String: (Date, LocalPortfolioDocument)] = [:]
    private var lastAttempt: [String: Date] = [:]
    private let directory: URL
    private let now: @Sendable () -> Date
    private let histories: @Sendable ([String], String) async -> [String: [String: Double]]

    init(
        directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("InvestorSimulation", isDirectory: true),
        now: @escaping @Sendable () -> Date = { Date() },
        histories: @escaping @Sendable ([String], String) async -> [String: [String: Double]] = { symbols, day in
            await LocalMarketDataClient().historicalCloses(symbols: symbols, from: "2022-01-01", to: day, dividendAdjusted: false)
        }
    ) {
        self.directory = directory
        self.now = now
        self.histories = histories
    }

    private func key(catalog: PublicInvestorCatalog, selection: String) -> String {
        let selected = PublicInvestorPreferences.selectedIDs(selection)
        let names = catalog.investors.filter { selected.contains($0.id) }.map(\.id).sorted().joined(separator: "-")
        return "v2-\(catalog.releaseId)-\(names)"
    }

    /// Keep old snapshots usable, including after relaunch. Expiry never deletes
    /// a snapshot, another investor's cache, or the shared market-data cache.
    func cachedDocument(catalog: PublicInvestorCatalog, selection: String) -> LocalPortfolioDocument? {
        let key = key(catalog: catalog, selection: selection)
        if let hit = cached[key] { return hit.1 }
        let file = directory.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: file),
              let document = try? JSONDecoder().decode(LocalPortfolioDocument.self, from: data) else { return nil }
        let fetchedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        cached[key] = (fetchedAt, document)
        return document
    }

    func load(catalog: PublicInvestorCatalog, selection: String) async throws -> LocalPortfolioDocument {
        if let hit = cachedDocument(catalog: catalog, selection: selection) { return hit }
        return try await fetch(catalog: catalog, selection: selection)
    }

    /// Called by portfolio refresh after the cached presentation is on screen.
    /// One request per selection; fresh caches and recent failed attempts do not
    /// create a request on each toggle. Historical prices have their own TTL.
    func refreshIfNeeded(catalog: PublicInvestorCatalog, selection: String) async throws -> LocalPortfolioDocument? {
        let key = key(catalog: catalog, selection: selection)
        _ = cachedDocument(catalog: catalog, selection: selection)
        if let task = pending[key] { return try await task.value }
        if let hit = cached[key], now().timeIntervalSince(hit.0) < 300,
           DayDateCodec.string(from: hit.0) == DayDateCodec.string(from: now()) { return nil }
        if cached[key] != nil, let attempt = lastAttempt[key], now().timeIntervalSince(attempt) < 300 { return nil }
        return try await fetch(catalog: catalog, selection: selection)
    }

    private func fetch(catalog: PublicInvestorCatalog, selection: String) async throws -> LocalPortfolioDocument {
        let key = key(catalog: catalog, selection: selection)
        if let task = pending[key] { return try await task.value }
        let day = DayDateCodec.string(from: now())
        let previous = cachedDocument(catalog: catalog, selection: selection)
        lastAttempt[key] = now()
        let directory = directory
        let historiesProvider = histories
        let task = Task.detached(priority: .userInitiated) {
            let symbols = PublicInvestorLedger.symbols(catalog: catalog, selection: selection)
            let providerSymbols = Array(Set(symbols.map { $0.replacingOccurrences(of: ".", with: "-") })).sorted()
            let providerHistories = await historiesProvider(providerSymbols, day)
            let histories = Dictionary(uniqueKeysWithValues: symbols.compactMap { ticker in
                providerHistories[ticker.replacingOccurrences(of: ".", with: "-")].map { (ticker, $0) }
            })
            let result = PublicInvestorLedger.build(catalog: catalog, selection: selection,
                prices: histories, splits: try? StockSplitCatalog.bundled.get(), asOf: day)
            // Store diagnostics separately from the real portfolio database.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let selectedNames = catalog.investors.filter { PublicInvestorPreferences.selectedIDs(selection).contains($0.id) }.map(\.id).sorted().joined(separator: "-")
            try JSONEncoder().encode(result.issues).write(to: directory.appendingPathComponent("issues-\(selectedNames).json"), options: .atomic)
            let file = directory.appendingPathComponent("\(key).json")
            if !symbols.isEmpty && result.document.positions.isEmpty {
                throw LocalServiceError.noHistoricalPrices
            }
            try JSONEncoder().encode(result.document).write(to: file, options: [.atomic, .completeFileProtection])
            return result.document
        }
        pending[key] = task
        do {
            let document = try await task.value
            pending[key] = nil
            cached[key] = (now(), document)
            return document
        } catch {
            pending[key] = nil
            if let previous { return previous }
            throw error
        }
    }
}
