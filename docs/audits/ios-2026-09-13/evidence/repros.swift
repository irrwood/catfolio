import Foundation
import CryptoKit
struct LocalTransactionRecord {
 var date: String; var action: String; var ticker: String; var quantity: Double; var price: Double; var currency: String; var source: String; var accountID: String?; var accountName: String?
 var tradeID: String? = nil; var entryMethod: String? = nil; var realisedProfitLoss: Double? = nil; var realisedProfitLossCurrency: String? = nil; var executedAt: String? = nil; var cashPostings: [DailyTimeWeightedReturn.Cash]? = nil
 var id: String { "\(accountKey)|\(tradeID ?? date + action)" }; var accountKey: String { "\(source)|\(accountID ?? "default")" }
}
struct LocalPositionRecord { var ticker: String; var name: String; var shares: Double; var averageCost: Double; var currency: String; var quotePrice: Double; var quoteCurrency: String; var source: String; var openedDate: String? }
struct CSVImportedHolding { var ticker: String; var name: String; var shares: Double; var averageCost: Double; var currency: String }
struct CSVImportResult { var ok: Bool; var holdingsCount: Int; var transactionsCount: Int?; var backupCreated: Bool; var warnings: [String]; var holdings: [CSVImportedHolding] }
enum LocalPortfolioError: Error { case invalidCSV(String) }
enum L10n { static var listSeparator: String { ", " }; static func text(_ s: String) -> String { s } }
enum Trading212Position { static func catfolioTicker(_ s: String) -> String { s }; static func currency(_ s: String?, rawTicker: String) -> String { s ?? "USD" } }
enum DayDateFormatter { static let shared: DateFormatter = { let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.timeZone=TimeZone(secondsFromGMT:0); f.dateFormat="yyyy-MM-dd"; return f }() }
enum DayDateCodec { static func date(from s:String)->Date? { DayDateFormatter.shared.date(from:s) }; static func string(from d:Date)->String { DayDateFormatter.shared.string(from:d) } }
enum LocalPortfolioEngine { static func usdRate(for s:String)->Double? { ["USD":1.0, "GBP":1.2][s] } }

import Foundation

/// Local, deterministic trade-date ledger. Inputs use contemporaneous prices
/// and quantities. Income/fees are internal; only investor flows change capital.
enum DailyTimeWeightedReturn {
    struct Cash: Codable, Equatable, Sendable {
        var currency: String
        var amount: Decimal
    }

    struct Event: Sendable {
        var id: String
        var date: String
        var account: String
        var symbol: String?
        var quantity: Decimal = 0
        var cash: [Cash]
        var external = false
        // Matched transfers inside the selected perimeter have the same ID.
        var transferID: String? = nil
    }

    struct Split: Codable, Sendable {
        var date: String
        var symbol: String
        var factor: Decimal
    }

    struct Quote: Sendable {
        var price: Decimal
        var currency: String
    }

    struct Day: Sendable {
        var date: String
        var quotes: [String: Quote]
        var usdRates: [String: Decimal]
    }

    struct Point: Codable, Sendable {
        var date: String
        var value: Decimal
        var cashUSD: Decimal
        var inflow: Decimal
        var outflow: Decimal
        var nav: Decimal
    }

    struct Result: Sendable {
        var points: [Point]
        var cash: [String: [String: Decimal]]
        var holdings: [String: [String: Decimal]]
        /// Days whose move the prices could not explain, with the growth the
        /// day would otherwise have had. Only with `implausibleGrowth`.
        var neutralized: [(date: String, growth: Decimal)] = []
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Opening balances are zero; a truncated ledger must supply an explicit
    /// opening funding/position event, never inferred from today's positions.
    ///
    /// - Parameter implausibleGrowth: for ledgers rebuilt on assumptions. A
    ///   day on which the whole account grows by more than this factor, or
    ///   shrinks by more than its inverse, is a gap in the data rather than a
    ///   return: the difference is taken as an unrecorded transfer, the day
    ///   counts as flat, and it is listed in `neutralized`. Early in an
    ///   account, when a few hundred dollars are the base, one such gap
    ///   would otherwise multiply every return after it.
    static func calculate(events: [Event], days: [Day], splits: [Split] = [], implausibleGrowth: Decimal? = nil) throws -> Result {
        func fail(_ message: String) -> Failure { Failure(message: message) }
        guard !events.isEmpty, !days.isEmpty else { throw fail("TWR：缺少完整资金流水或估值日期。") }
        guard Set(events.map(\.id)).count == events.count else { throw fail("TWR：存在重复流水。") }
        let sortedDays = days.sorted { $0.date < $1.date }
        guard Set(sortedDays.map(\.date)).count == days.count else { throw fail("TWR：估值日期重复。") }
        let daySet = Set(days.map(\.date))
        guard events.allSatisfy({ daySet.contains($0.date) }) else { throw fail("TWR：流水日期缺少估值。") }
        let byDate = Dictionary(grouping: events, by: \.date)
        let splitDates = Dictionary(grouping: splits, by: \.date)
        var cash: [String: [String: Decimal]] = [:]
        var holdings: [String: [String: Decimal]] = [:]
        var points: [Point] = []
        var previous: Decimal = 0
        var nav: Decimal = 1
        var started = false
        var neutralized: [(date: String, growth: Decimal)] = []
        for day in sortedDays {
            func usd(_ amount: Decimal, _ currency: String) throws -> Decimal {
                if currency == "USD" { return amount }
                guard let rate = day.usdRates[currency], !rate.isNaN, rate > 0 else {
                    throw fail("TWR：\(day.date) 缺少 \(currency) 汇率。")
                }
                return amount * rate
            }
            for split in splitDates[day.date] ?? [] {
                guard !split.factor.isNaN, split.factor > 0 else { throw fail("TWR：拆股比例无效。") }
                for account in Array(holdings.keys) {
                    if let quantity = holdings[account]?[split.symbol] {
                        holdings[account]?[split.symbol] = quantity * split.factor
                    }
                }
            }
            var inflow: Decimal = 0
            var outflow: Decimal = 0
            let eventsToday = byDate[day.date] ?? []
            let transfers = Dictionary(grouping: eventsToday.filter { $0.transferID != nil }, by: { $0.transferID! })
            var internalTransfers = Set<String>()
            for (id, legs) in transfers where legs.count > 1 {
                var balance: [String: Decimal] = [:]
                for leg in legs {
                    guard leg.symbol == nil else { throw fail("TWR：证券转账需要显式估值。") }
                    for posting in leg.cash { balance[posting.currency, default: 0] += posting.amount }
                }
                guard Set(legs.map(\.account)).count > 1, balance.values.allSatisfy({ $0 == 0 }) else {
                    throw fail("TWR：内部转账无法配对。")
                }
                internalTransfers.insert(id)
            }
            for event in eventsToday {
                guard !event.quantity.isNaN, event.cash.allSatisfy({ !$0.amount.isNaN }) else {
                    throw fail("TWR：流水金额无效。")
                }
                if let symbol = event.symbol {
                    holdings[event.account, default: [:]][symbol, default: 0] += event.quantity
                }
                for posting in event.cash {
                    cash[event.account, default: [:]][posting.currency, default: 0] += posting.amount
                    if event.external && !internalTransfers.contains(event.transferID ?? "") {
                        let amount = try usd(posting.amount, posting.currency)
                        if amount >= 0 { inflow += amount } else { outflow -= amount }
                    }
                }
            }
            var cashValue: Decimal = 0
            var value: Decimal = 0
            for balances in cash.values {
                for (currency, amount) in balances where amount != 0 {
                    guard amount >= Decimal(string: "-0.01")! else { throw fail("TWR：\(day.date) 现金为负，请补齐入金、换汇或期初余额。") }
                    cashValue += try usd(amount, currency)
                }
            }
            value = cashValue
            for positions in holdings.values {
                for (symbol, quantity) in positions where quantity != 0 {
                    guard quantity >= 0 else { throw fail("TWR：\(symbol) 历史持仓不足。") }
                    guard let quote = day.quotes[symbol], !quote.price.isNaN, quote.price > 0 else {
                        throw fail("TWR：\(day.date) 缺少 \(symbol) 价格。")
                    }
                    value += try usd(quantity * quote.price, quote.currency)
                }
            }
            let capital = previous + inflow
            if capital > 0 {
                let growth = (value + outflow) / capital
                if let limit = implausibleGrowth, previous > 0, growth > limit || growth < 1 / limit {
                    let gap = value + outflow - capital
                    if gap > 0 { inflow += gap } else { outflow -= gap }
                    neutralized.append((day.date, growth))
                } else {
                    nav *= growth
                }
                started = true
            } else if value != 0 || outflow != 0 {
                throw fail("TWR：缺少期初资金，无法确定收益分母。")
            }
            guard !nav.isNaN, nav >= 0 else { throw fail("TWR：净值无效。") }
            if started { points.append(Point(date: day.date, value: value, cashUSD: cashValue, inflow: inflow, outflow: outflow, nav: nav)) }
            previous = value
        }
        guard !points.isEmpty else { throw fail("TWR：没有可计算的已注资区间。") }
        return Result(points: points, cash: cash, holdings: holdings, neutralized: neutralized)
    }
}

import Foundation

/// Daily GBP reference rates, for valuing a foreign-currency position in
/// sterling on the day it was bought.
///
/// Rates read `1 GBP = rate units of the quote currency`, so a foreign amount
/// becomes sterling by dividing. The package states that direction itself
/// rather than leaving it to be inferred from a field name, and this reader
/// refuses to load one that states anything else — getting the direction
/// backwards is the kind of mistake that produces plausible numbers.
struct GBPFXRates: Decodable, Sendable {
    /// How close the rate is to the day that was asked for.
    enum Match: Sendable {
        /// The ECB published a rate on exactly that date.
        case exact
        /// The date had no observation — a weekend, a holiday — and this is
        /// the most recent published rate before it, `daysBack` days earlier.
        case carriedForward(daysBack: Int)
    }

    struct Quote: Sendable {
        let rate: Double
        let match: Match
        let date: String
    }

    let schemaVersion: Int
    let baseCurrency: String
    let direction: String
    let nonObservationDayPolicy: String
    let lookupPolicy: String
    let status: String
    let source: String
    /// Currencies the package names but has no series for. Kept so a caller
    /// can tell "no rate exists" from "this currency was never covered".
    let unsupportedCurrencies: [String]
    /// One shared axis, ascending. Every series is parallel to it.
    let dates: [String]
    /// Currency to rate per date; nil where that currency has no observation
    /// on that date, which is preserved rather than filled.
    let rates: [String: [Double?]]

    private var indexByDate: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, baseCurrency, direction, nonObservationDayPolicy
        case lookupPolicy, status, source, unsupportedCurrencies, dates, rates
    }

    enum RatesError: Error { case missingResource, invalidPackage }

    static let bundled = Result { try load() }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "gbp_fx_daily", withExtension: "json") else {
            throw RatesError.missingResource
        }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> Self {
        var package = try JSONDecoder().decode(Self.self, from: data)
        package.indexByDate = Dictionary(
            uniqueKeysWithValues: package.dates.enumerated().map { ($0.element, $0.offset) }
        )
        guard package.schemaVersion == 1,
              package.baseCurrency == "GBP",
              package.direction.hasPrefix("GBP_TO_QUOTE"),
              package.nonObservationDayPolicy == "OMIT_NO_FORWARD_FILL",
              package.status == "VERIFIED",
              !package.dates.isEmpty,
              package.dates == package.dates.sorted(),
              package.rates.values.allSatisfy({ $0.count == package.dates.count })
        else { throw RatesError.invalidPackage }
        return package
    }

    /// The rate to use for a currency on a given day.
    ///
    /// Sterling is 1 by definition and pence is a hundredth of it; neither is
    /// in the series and neither needs to be.
    ///
    /// The package omits non-observation days rather than filling them, which
    /// is the right thing for a rate series to do and the wrong thing for a
    /// caller to inherit: a contract note dated on a Saturday still has to be
    /// valued. So a missing day walks backwards to the most recent published
    /// rate, up to `limit` days, and says how far it had to go. It never
    /// walks forward — a rate published after the trade was not knowable at
    /// the time.
    func quote(currency: String, on date: String, within limit: Int = 7) -> Quote? {
        let code = currency.uppercased()
        if code == "GBP" { return Quote(rate: 1, match: .exact, date: date) }
        if code == "GBX" || code == "GBp" { return Quote(rate: 100, match: .exact, date: date) }

        guard let series = rates[code] else { return nil }

        // An exact hit is the common case: markets trade on the days the ECB
        // publishes on.
        if let position = indexByDate[date], let rate = series[position] {
            return Quote(rate: rate, match: .exact, date: date)
        }

        // Otherwise find where the date would sit and step back from there.
        var position = dates.firstIndex { $0 > date } ?? dates.count
        var stepped = 0
        while position > 0, stepped <= limit {
            position -= 1
            stepped += 1
            if let rate = series[position] {
                return Quote(
                    rate: rate,
                    match: .carriedForward(daysBack: stepped),
                    date: dates[position]
                )
            }
        }
        return nil
    }

    /// A foreign amount in sterling on a given day.
    func sterling(_ amount: Double, currency: String, on date: String) -> (value: Double, match: Match)? {
        guard let quote = quote(currency: currency, on: date), quote.rate > 0 else { return nil }
        return (amount / quote.rate, quote.match)
    }

    /// The most recent day the package has a rate for this currency.
    func latestDate(currency: String) -> String? {
        let code = currency.uppercased()
        if code == "GBP" || code == "GBX" { return dates.last }
        guard let series = rates[code] else { return nil }
        for index in stride(from: series.count - 1, through: 0, by: -1) where series[index] != nil {
            return dates[index]
        }
        return nil
    }
}

import Foundation

/// Share counts before a split do not describe the same thing as share counts
/// after one, so a ledger that spans a split cannot be matched lot-for-lot
/// without adjusting for it.
///
/// Covers every US split on record, not just the ones a particular portfolio
/// happens to contain: which tickers matter is the user's business, not the
/// catalogue's.
struct StockSplitCatalog: Decodable, Sendable {
    struct Event: Decodable, Sendable, Equatable {
        /// Execution date, `yyyy-MM-dd`. Holdings acquired before this need
        /// adjusting; anything after it is already on the new basis.
        let d: String
        /// Shares before.
        let f: Double
        /// Shares after.
        let t: Double

        /// Multiply a pre-split quantity by this. Below 1 for a reverse split.
        var factor: Double? {
            guard f > 0, t > 0, f.isFinite, t.isFinite else { return nil }
            let value = t / f
            return value.isFinite && value > 0 ? value : nil
        }

        var isReverse: Bool { t < f }
    }

    let schemaVersion: Int
    let splits: [String: [Event]]

    enum CatalogError: Error { case missingResource }

    static let bundled = Result { try load() }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "stock_splits", withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    /// Splits for `ticker` that executed after `date`, oldest first.
    ///
    /// Only splits after a purchase apply to it — one that happened before is
    /// already reflected in the quantity the broker reported.
    func events(ticker: String, after date: String) -> [Event] {
        guard let all = splits[Self.normalized(ticker)] else { return [] }
        return all.filter { $0.d > date }
    }

    /// Combined multiplier to bring a quantity from `date` onto today's basis.
    /// Returns 1 when nothing applies, `nil` if any event is unusable.
    func adjustment(ticker: String, from date: String) -> Double? {
        var factor = 1.0
        for event in events(ticker: ticker, after: date) {
            guard let step = event.factor else { return nil }
            factor *= step
        }
        return factor.isFinite && factor > 0 ? factor : nil
    }

    /// US listings only, so a suffixed symbol is not silently matched against
    /// a same-named US ticker — NG.L is National Grid, NG is NovaGold.
    static func normalized(_ ticker: String) -> String {
        ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var tickerCount: Int { splits.count }
    var eventCount: Int { splits.values.reduce(0) { $0 + $1.count } }
}

import Foundation

/// How much of a position's gain is the currency rather than the price.
///
/// Every position in this ledger reported no FX component at all: brokers
/// supply one only on some fills, and across 1,977 transactions not a single
/// one carried a rate. So the row read "—" on every holding, for every user
/// whose broker does the same.
///
/// The figure is reconstructed instead, from the trade dates already in the
/// ledger and a published daily rate series.
enum FXImpactCalculator {

    /// What the currency did to the money that is still invested.
    struct Result: Sendable {
        /// Signed, in the position's own quote currency.
        let amount: Double
        /// The cost the figure is computed against, same currency.
        let cost: Double
        /// True when every open lot matched a rate published on its own trade
        /// date. False when at least one had to carry a rate back from an
        /// earlier day — a weekend fill, a dated dividend reinvestment.
        let isExact: Bool
    }

    /// A buy that has not been sold yet, after FIFO matching.
    private struct OpenLot {
        let quantity: Double
        let price: Double
        let currency: String
        let date: String
    }

    /// FX impact on the lots still held.
    ///
    /// The decomposition is the one brokers report: value the position's
    /// remaining cost at the rate on each purchase date, value the same cost
    /// at today's rate, and the difference is what the currency did. The
    /// price component is deliberately not part of it — that is what
    /// unrealised P&L already says.
    ///
    ///     fx  =  Σ costᵢ × (1/rate_now − 1/rateᵢ)
    ///
    /// Returns nil rather than zero when the answer is unknowable: an
    /// uncovered currency, or no rate for the current day. A sterling-quoted
    /// position returns zero, which is a fact rather than a gap.
    static func impact(
        ticker: String,
        transactions: [LocalTransactionRecord],
        rates: GBPFXRates,
        asOf: Date = Date(),
        splits: StockSplitCatalog? = nil
    ) -> Result? {
        let lots = openLots(ticker: ticker, transactions: transactions, splits: splits)
        guard !lots.isEmpty else { return nil }

        // Mixed-currency lots on one ticker would need a separate answer per
        // currency; the row has room for one number, so it stays silent.
        let currencies = Set(lots.map { $0.currency.uppercased() })
        guard currencies.count == 1, let currency = currencies.first else { return nil }
        if currency == "GBP" || currency == "GBX" {
            let cost = lots.reduce(0) { $0 + $1.quantity * $1.price }
            return Result(amount: 0, cost: cost, isExact: true)
        }

        let today = DayDateFormatter.shared.string(from: asOf)
        guard let latest = rates.latestDate(currency: currency),
              let now = rates.quote(currency: currency, on: min(today, latest)),
              now.rate > 0 else { return nil }

        var amount = 0.0
        var cost = 0.0
        var isExact = true
        for lot in lots {
            guard let then = rates.quote(currency: lot.currency, on: lot.date), then.rate > 0 else {
                // One unpriceable lot makes the total wrong by an unknown
                // amount, so the whole figure is withheld.
                return nil
            }
            if case .carriedForward = then.match { isExact = false }
            let lotCost = lot.quantity * lot.price
            cost += lotCost
            amount += lotCost * (1 / now.rate - 1 / then.rate)
        }
        return Result(amount: amount, cost: cost, isExact: isExact)
    }

    /// Buys still open after sells are matched against them, oldest first.
    ///
    /// FIFO, matching the app's realised-profit engine. It is not the UK's
    /// tax matching, and is not used for tax anywhere — this is a display
    /// figure about the money currently invested.
    private static func openLots(
        ticker: String,
        transactions: [LocalTransactionRecord],
        splits: StockSplitCatalog?
    ) -> [OpenLot] {
        let symbol = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let ordered = transactions
            .filter { $0.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == symbol }
            .sorted { $0.date < $1.date }

        var open: [OpenLot] = []
        for transaction in ordered {
            let split = splits?.adjustment(ticker: transaction.ticker, from: transaction.date) ?? 1
            guard split > 0 else { continue }
            let quantity = abs(transaction.quantity) * split
            let price = transaction.price / split
            guard quantity > 0, price.isFinite else { continue }

            switch transaction.action.uppercased() {
            case "BUY":
                open.append(OpenLot(
                    quantity: quantity,
                    price: price,
                    currency: transaction.currency,
                    date: String(transaction.date.prefix(10))
                ))
            case "SELL":
                var remaining = quantity
                while remaining > 0, let first = open.first {
                    if first.quantity > remaining {
                        open[0] = OpenLot(
                            quantity: first.quantity - remaining,
                            price: first.price,
                            currency: first.currency,
                            date: first.date
                        )
                        remaining = 0
                    } else {
                        remaining -= first.quantity
                        open.removeFirst()
                    }
                }
            default:
                continue
            }
        }
        return open
    }
}

import Foundation

/// Which acquisitions a UK disposal is matched against.
///
/// Capital gains on shares are not worked out first-in-first-out. A disposal
/// is matched in a fixed order: acquisitions on the same day, then
/// acquisitions in the following 30 days, and only what is left comes out of
/// the Section 104 pool.
///
/// The middle rule is the one that surprises people. Sell at a loss and buy
/// the same shares back a fortnight later and the disposal is matched against
/// that repurchase, not against the pool — so the loss is not realised in the
/// way the seller assumed. It runs forward from the disposal, which means
/// whether a sale is matched can change *after* the sale, when a later
/// purchase lands inside the window.
///
/// This describes matching only. It is not a tax computation: no rates, no
/// allowances, no pool cost. The app's realised-profit figure is FIFO and
/// stays FIFO — that is a performance number, and this is a different
/// question about the same transactions.
enum UKShareMatching {

    /// How long after a disposal an acquisition still matches against it.
    static let windowDays = 30

    enum Rule: Equatable, Sendable {
        /// Bought the same day it was sold.
        case sameDay
        /// Bought within the 30 days after, so matched ahead of the pool.
        case thirtyDay(acquired: String)
        /// Matched against the holding as a whole.
        case section104
    }

    struct Match: Equatable, Sendable {
        let rule: Rule
        let quantity: Double
        /// The ledger row of the acquisition this portion was matched to, so
        /// a caller costing the disposal can find what was actually paid for
        /// it. Nil for the pool portion, which has no single acquisition.
        var acquisitionID: String? = nil
    }

    struct Disposal: Equatable, Sendable {
        /// The ledger row this disposal came from, so a view can attach the
        /// result to the row the reader is looking at rather than re-deriving
        /// which sale is which.
        let sourceID: String
        let date: String
        let quantity: Double
        let matches: [Match]

        /// The last day an acquisition would still match this disposal.
        var windowEnds: String { UKShareMatching.windowEnd(after: date) ?? date }

        /// Quantity matched to a same-day or later acquisition rather than to
        /// the pool. Non-zero means the disposal did not come out of the
        /// holding the way a seller would usually expect.
        var matchedToAcquisitions: Double {
            matches.filter { $0.rule != .section104 }.reduce(0) { $0 + $1.quantity }
        }

        var isFullyFromPool: Bool { matchedToAcquisitions <= 0 }
    }

    /// The last date on which an acquisition still matches a disposal made on
    /// `date`. An acquisition the day after this one does not.
    static func windowEnd(after date: String) -> String? {
        guard let day = Self.day(date),
              let end = Self.calendar.date(byAdding: .day, value: windowDays, to: day)
        else { return nil }
        return Self.text(end)
    }

    /// Every disposal of one security, with what it was matched against.
    ///
    /// Disposals are worked in date order, and an acquisition once matched is
    /// spent — it cannot also serve a later disposal.
    static func disposals(
        ticker: String,
        transactions: [LocalTransactionRecord],
        splits: StockSplitCatalog? = nil
    ) -> [Disposal] {
        let symbol = ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        struct Entry { let id: String; let date: String; var quantity: Double; let isBuy: Bool }
        var entries: [Entry] = []
        for transaction in transactions {
            guard transaction.ticker.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == symbol
            else { continue }
            let action = transaction.action.uppercased()
            guard action == "BUY" || action == "SELL" else { continue }
            // Share counts are normalised to today's basis, so a split partway
            // through does not make a disposal look larger than the
            // acquisitions it should match against.
            let split = splits?.adjustment(ticker: transaction.ticker, from: transaction.date) ?? 1
            guard split > 0 else { continue }
            let quantity = abs(transaction.quantity) * split
            guard quantity > 0 else { continue }
            entries.append(Entry(
                id: transaction.id,
                date: String(transaction.date.prefix(10)),
                quantity: quantity,
                isBuy: action == "BUY"
            ))
        }
        guard entries.contains(where: { !$0.isBuy }) else { return [] }
        entries.sort { $0.date < $1.date }

        var acquisitions = entries.filter(\.isBuy)
            .map { (id: $0.id, date: $0.date, remaining: $0.quantity) }

        var results: [Disposal] = []
        for entry in entries where !entry.isBuy {
            var outstanding = entry.quantity
            var matches: [Match] = []
            guard let windowEnd = Self.windowEnd(after: entry.date) else { continue }

            // Same day first, then the following 30 days in date order. An
            // acquisition outside the window is never reached, however close.
            func consume(where predicate: (String) -> Bool, rule: (String) -> Rule) {
                for index in acquisitions.indices where outstanding > 0 {
                    guard acquisitions[index].remaining > 0,
                          predicate(acquisitions[index].date) else { continue }
                    let taken = min(outstanding, acquisitions[index].remaining)
                    acquisitions[index].remaining -= taken
                    outstanding -= taken
                    matches.append(Match(
                        rule: rule(acquisitions[index].date),
                        quantity: taken,
                        acquisitionID: acquisitions[index].id
                    ))
                }
            }
            consume(where: { $0 == entry.date }, rule: { _ in .sameDay })
            consume(where: { $0 > entry.date && $0 <= windowEnd }, rule: { .thirtyDay(acquired: $0) })

            if outstanding > 0 {
                matches.append(Match(rule: .section104, quantity: outstanding))
            }
            results.append(Disposal(
                sourceID: entry.id, date: entry.date,
                quantity: entry.quantity, matches: matches
            ))
        }
        return results
    }

    // MARK: - Dates

    /// UTC throughout. The window is a count of calendar days, and letting a
    /// local time zone shift a boundary date would move it by one.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func day(_ text: String) -> Date? {
        formatter.date(from: String(text.prefix(10)))
    }

    private static func text(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

import Foundation

/// Realised P/L reaches Catfolio from two sources that must never be added
/// together.
///
/// A broker Result is exact and denominated in the broker's own currency.
/// A locally reconstructed sale is an estimate priced through Catfolio's
/// static rate table. Summing them would push an exact figure through those
/// rates, so the two are reported separately and labelled.
struct RealisedProfitSummary: Equatable {
    /// Exact, broker-reported, kept per currency so nothing is converted.
    var brokerTotals: [String: Decimal] = [:]
    var brokerCount = 0
    /// Sales with no broker Result but a complete imported cost basis.
    var estimatedUSD = 0.0
    var estimatedCount = 0
    /// Sales that could be neither reconciled nor reconstructed.
    var unavailableCount = 0
    /// Broker Results converted to USD at current rates, so they can join a
    /// single total. The per-currency figures above stay unconverted.
    var brokerUSD = 0.0
    /// Broker currencies with no rate available. Their Results are still
    /// reported in `brokerTotals` but cannot enter the combined total.
    var unconvertibleCurrencies: Set<String> = []

    var saleCount: Int { brokerCount + estimatedCount + unavailableCount }

    /// Everything that could be valued, in USD, ready for display in the
    /// user's chosen currency.
    ///
    /// Approximate by construction: profits realised on different dates are
    /// all converted at today's rate, so this will not tie out to the sum of
    /// the broker's own figures unless every sale settled in one currency.
    var combinedUSD: Double { brokerUSD + estimatedUSD }

    /// True when every sale was valued and every currency converted.
    var isComplete: Bool { unavailableCount == 0 && unconvertibleCurrencies.isEmpty }
}

/// One priced disposal.
///
/// Grouping by tax year happens on these, never by slicing the input first:
/// a lot bought in 2019 can settle a sale in 2024, so FIFO has to run across
/// the whole history and the year is decided by the sale's own date.
struct RealisedSale: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Exact, from the broker, in its own currency.
        case broker(value: Decimal, currency: String, usd: Double?)
        /// Reconstructed locally from a complete FIFO basis.
        case estimated(usd: Double)
        /// Neither reconcilable nor reconstructable.
        case unavailable
    }

    let date: String
    let outcome: Outcome
}

/// Which calendar a realised gain is reported against. The UK runs 6 April to
/// 5 April; most elsewhere is the calendar year.
enum TaxYearBasis: String, CaseIterable, Identifiable, Sendable {
    case calendar
    case uk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: "日历年"
        case .uk: "英国税年 · 4/6–4/5"
        }
    }

    /// `nil` for an unparsable date rather than a guess.
    func label(for date: String) -> String? {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else {
            return nil
        }
        let (year, month, day) = (parts[0], parts[1], parts[2])
        switch self {
        case .calendar:
            return String(year)
        case .uk:
            // On or after 6 April the year that starts here; before it, the
            // year that started the previous April.
            let start = (month > 4 || (month == 4 && day >= 6)) ? year : year - 1
            return "\(start)/\(String(format: "%02d", (start + 1) % 100))"
        }
    }
}

/// FIFO reconstruction of closed-position profit.
///
/// Trading 212 reports an exact Result per sale, but only for fills whose
/// `walletImpact` the API returns; the rest are backfilled from the activity
/// export one 365-day period per sync. Until that catches up, a sale with a
/// complete imported purchase history can still be priced locally — reporting
/// nothing at all would be strictly less useful than reporting an estimate
/// that says so.
enum RealisedProfitCalculator {

    static func isBuy(_ action: String) -> Bool {
        ["BUY", "BUY_BACK"].contains(normalized(action))
    }

    static func isSell(_ action: String) -> Bool {
        ["SELL", "SELL_SHORT"].contains(normalized(action))
    }

    private static func normalized(_ action: String) -> String {
        action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private struct Lot {
        var quantity: Double
        let costPerShareUSD: Double
    }

    /// Ordering is decided here rather than by the caller: same-day purchases
    /// must settle before same-day sales, otherwise a buy-then-sell on one day
    /// finds no lot to match.
    /// Folds every disposal into one summary. Unchanged behaviour; the
    /// per-sale detail now comes from `sales(transactions:)`.
    static func summarize(transactions: [LocalTransactionRecord]) -> RealisedProfitSummary {
        summarize(sales: sales(transactions: transactions))
    }

    static func summarize(sales: [RealisedSale]) -> RealisedProfitSummary {
        var summary = RealisedProfitSummary()
        for sale in sales {
            switch sale.outcome {
            case let .broker(value, currency, usd):
                summary.brokerTotals[currency, default: 0] += value
                summary.brokerCount += 1
                if let usd { summary.brokerUSD += usd }
                else { summary.unconvertibleCurrencies.insert(currency) }
            case let .estimated(usd):
                summary.estimatedUSD += usd
                summary.estimatedCount += 1
            case .unavailable:
                summary.unavailableCount += 1
            }
        }
        return summary
    }

    /// Groups by the tax year each sale settled in. Sales whose date cannot be
    /// read are reported separately rather than dropped into an arbitrary year.
    static func summarize(
        transactions: [LocalTransactionRecord], basis: TaxYearBasis
    ) -> [(label: String, summary: RealisedProfitSummary)] {
        let grouped = Dictionary(grouping: sales(transactions: transactions)) {
            basis.label(for: $0.date) ?? "日期无法识别"
        }
        return grouped.keys.sorted(by: >).map { ($0, summarize(sales: grouped[$0] ?? [])) }
    }

    static func sales(transactions: [LocalTransactionRecord]) -> [RealisedSale] {
        var sales: [RealisedSale] = []
        var lotsByPosition: [String: [Lot]] = [:]

        let ordered = transactions
            .filter { isBuy($0.action) || isSell($0.action) }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                let leftIsBuy = isBuy($0.action)
                if leftIsBuy != isBuy($1.action) { return leftIsBuy }
                return ($0.tradeID ?? "") < ($1.tradeID ?? "")
            }

        let catalog = try? StockSplitCatalog.bundled.get()

        for transaction in ordered {
            let key = "\(transaction.accountKey)|\(transaction.ticker.uppercased())"
            let rate = LocalPortfolioEngine.usdRate(for: transaction.currency)

            // Put every row on today's share basis before matching. A purchase
            // of 100 shares that later split 4-for-1 is 400 shares at a quarter
            // the price; a sale made before that split is on the old basis too.
            // Quantity times price is unchanged, so cost basis survives intact.
            let split = catalog?.adjustment(
                ticker: transaction.ticker, from: transaction.date
            ) ?? 1
            let quantity = abs(transaction.quantity) * split
            let price = split > 0 ? transaction.price / split : transaction.price

            if isBuy(transaction.action) {
                // A purchase in an unconvertible currency cannot seed a basis.
                // Dropping the lot leaves later sales short, which reports them
                // as unavailable rather than silently mispricing them.
                guard let rate, rate.isFinite else { continue }
                lotsByPosition[key, default: []].append(Lot(
                    quantity: quantity,
                    costPerShareUSD: price * rate
                ))
                continue
            }

            // Every sale consumes lots, broker-reported ones included, so the
            // FIFO position stays correct for the sales that must be rebuilt.
            let saleQuantity = quantity
            var remaining = saleQuantity
            var lots = lotsByPosition[key] ?? []
            var matchedCostUSD = 0.0
            while remaining > 0.000_000_1, !lots.isEmpty {
                let matched = min(remaining, lots[0].quantity)
                matchedCostUSD += lots[0].costPerShareUSD * matched
                remaining -= matched
                lots[0].quantity -= matched
                if lots[0].quantity <= 0.000_000_1 { lots.removeFirst() }
            }
            lotsByPosition[key] = lots

            if let broker = brokerResult(for: transaction) {
                // Converted separately so the exact per-currency figure is
                // never overwritten by a rate-dependent one.
                let brokerRate = LocalPortfolioEngine.usdRate(for: broker.currency)
                let usd = brokerRate.flatMap { $0.isFinite ? broker.raw * $0 : nil }
                sales.append(RealisedSale(date: transaction.date, outcome: .broker(
                    value: broker.value, currency: broker.currency, usd: usd
                )))
                continue
            }

            // Only price a sale whose every share matched an imported purchase;
            // a partial basis would understate cost and overstate profit.
            let matchedEverything = remaining <= max(0.000_000_1, saleQuantity * 0.000_001)
            guard let rate, rate.isFinite, matchedEverything else {
                sales.append(RealisedSale(date: transaction.date, outcome: .unavailable))
                continue
            }
            let profit = price * rate * saleQuantity - matchedCostUSD
            guard profit.isFinite else {
                sales.append(RealisedSale(date: transaction.date, outcome: .unavailable))
                continue
            }
            sales.append(RealisedSale(date: transaction.date, outcome: .estimated(usd: profit)))
        }

        return sales
    }

    /// A Result without a well-formed currency is unusable: it cannot be shown
    /// in its own currency and must not be assumed to be USD.
    private static func brokerResult(
        for transaction: LocalTransactionRecord
    ) -> (value: Decimal, currency: String, raw: Double)? {
        guard let raw = transaction.realisedProfitLoss, raw.isFinite else { return nil }
        let currency = transaction.realisedProfitLossCurrency?
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        guard currency.count == 3,
              currency.utf8.allSatisfy({ (65...90).contains($0) }),
              let decimal = Decimal(
                  string: String(raw),
                  locale: Locale(identifier: "en_US_POSIX")
              ) else { return nil }
        return (decimal, currency, raw)
    }
}

/// Reuses the history calculation with the detail page's security/account scope.

enum LocalCSVImporter {
    private struct Transaction {
        let date: Date
        let action: String
        let ticker: String
        let quantity: Double
        let price: Double
        let currency: String
        let name: String
        let reference: String?
        let realisedProfitLoss: Double?
        let realisedProfitLossCurrency: String?
        let cashPostings: [DailyTimeWeightedReturn.Cash]?
    }

    static let aliases: [String: [String]] = [
        "total": ["total"],
        "totalCurrency": ["currency total"],
        "netCash": ["net cash amount"],
        "cashCurrency": ["cash currency"],
        "result": ["result", "realised profit loss", "realized profit loss"],
        "resultCurrency": ["currency result", "result currency"],
        "reference": ["id", "reference", "trade id"],
        "date": [
            "date", "trade date", "transaction date", "time", "date time", "datetime",
            "timestamp", "execution time", "executed at", "created at", "closing time",
            "fill time", "filled at",
            "日期", "时间", "交易日期", "交易时间", "成交时间", "日期时间",
        ],
        "action": [
            "action", "type", "transaction type", "side", "direction",
            "操作", "类型", "交易类型", "方向",
        ],
        "ticker": [
            "ticker", "symbol", "instrument", "stock", "isin", "code",
            "代码", "股票代码", "标的代码", "证券代码",
        ],
        "quantity": [
            "quantity", "qty", "shares", "units", "amount", "no of shares",
            "数量", "股数", "成交数量",
        ],
        "price": [
            "price", "price share", "price per share", "trade price", "unit price", "execution price",
            "fill price", "filled price",
            "价格", "每股价格", "成交价", "执行价格",
        ],
        "currency": [
            "currency price share", "price currency", "currency price", "currency", "ccy", "curr",
            "price currency", "货币", "币种", "价格币种",
        ],
        "name": [
            "name", "company", "description", "instrument name", "security name",
            "名称", "公司名称", "证券名称",
        ],
    ]

    static let requiredColumnKeys = ["date", "action", "ticker", "quantity", "price"]

    static func decodedText(from data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    static func columns(in header: [String]) -> [String: Int] {
        let normalized = header.map(normalizeHeader)
        var result: [String: Int] = [:]
        for (key, choices) in aliases {
            // Prefer exact column names. "Result" must never resolve to
            // "Currency (Result)" just because that column occurs first.
            if let exact = choices.compactMap({ normalized.firstIndex(of: normalizeHeader($0)) }).first {
                result[key] = exact
                continue
            }
            for choice in choices {
                let alias = normalizeHeader(choice)
                if let index = normalized.firstIndex(where: { headerMatches($0, alias: alias) }) {
                    result[key] = index
                    break
                }
            }
        }
        return result
    }

    static func headerRowIndex(in records: [[String]]) -> Int? {
        records.prefix(25).enumerated()
            .filter { !$0.element.isEmpty && !isSeparatorDirective($0.element) }
            .max { lhs, rhs in
                columns(in: lhs.element).count < columns(in: rhs.element).count
            }?
            .offset
    }

    static func missingRequiredColumns(in header: [String]) -> [String] {
        let resolved = columns(in: header)
        if resolved["total"] != nil || resolved["netCash"] != nil {
            return ["date", "action"].filter { resolved[$0] == nil }
        }
        return requiredColumnKeys.filter { resolved[$0] == nil }
    }

    static func parse(_ data: Data) throws -> ([LocalPositionRecord], [LocalTransactionRecord], CSVImportResult) {
        guard var text = decodedText(from: data) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("文件编码无法识别，请使用 UTF-8 或 UTF-16"))
        }
        text = text.replacingOccurrences(of: "\u{feff}", with: "")
        let records = parseRecords(text)
        guard !records.isEmpty else { throw LocalPortfolioError.invalidCSV(L10n.text("文件为空")) }
        guard let headerIndex = headerRowIndex(in: records) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("没有找到可识别的表头"))
        }
        let header = records[headerIndex]
        let columns = columns(in: header)
        let missing = missingRequiredColumns(in: header)
        guard missing.isEmpty else {
            throw LocalPortfolioError.invalidCSV(L10n.text("缺少列：\(missing.joined(separator: L10n.listSeparator))"))
        }

        var transactions: [Transaction] = []
        var warnings: [String] = []
        var ledgerIncomplete = false
        var rowOccurrences: [String: Int] = [:]
        for (offset, row) in records.dropFirst(headerIndex + 1).enumerated() {
            do {
                func field(_ name: String) -> String {
                    guard let index = columns[name], row.indices.contains(index) else { return "" }
                    return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !field("action").isEmpty else { continue }
                let action = normalizedAction(field("action")) ?? "UNSUPPORTED: \(field("action"))"
                let isTrade = action == "BUY" || action == "SELL"
                let rawTicker = field("ticker")
                let ticker = rawTicker.isEmpty && !isTrade ? "CASH" : Trading212Position.catfolioTicker(rawTicker)
                guard !ticker.isEmpty else { throw LocalPortfolioError.invalidCSV("交易缺少股票代码") }
                let quantity = isTrade ? abs(try number(field("quantity"))) : 1
                let price = isTrade ? try number(field("price")) : (numericValue(field("total")) ?? numericValue(field("netCash")) ?? numericValue(field("price")) ?? 0)
                var postings: [DailyTimeWeightedReturn.Cash]? = nil
                let locale = Locale(identifier: "en_US_POSIX")
                if let net = Decimal(string: field("netCash").replacingOccurrences(of: ",", with: ""), locale: locale), !field("cashCurrency").isEmpty {
                    postings = [.init(currency: field("cashCurrency").uppercased(), amount: net)]
                } else if let total = Decimal(string: field("total").replacingOccurrences(of: ",", with: ""), locale: locale), !field("totalCurrency").isEmpty {
                    // Total semantics vary across broker exports. Fee-bearing
                    // rows need an explicit signed net cash amount; do not guess
                    // whether a fee column was already included in Total.
                    let hasCharges = header.enumerated().contains { index, name in
                        let key = name.lowercased()
                        let currencyLabel = key.hasPrefix("currency (") || key.hasPrefix("currency currency ") || key.hasSuffix(" currency")
                        guard !currencyLabel, key.contains("fee") || key.contains("tax") || key.contains("commission"),
                              row.indices.contains(index), !row[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                        guard let amount = numericValue(row[index]), amount.isFinite else { return true }
                        return amount != 0
                    }
                    if !hasCharges {
                        let magnitude = total < 0 ? -total : total
                        let debit = ["BUY", "WITHDRAWAL", "FEE", "TAX"].contains(action)
                        postings = [.init(currency: field("totalCurrency").uppercased(), amount: debit ? -magnitude : magnitude)]
                    }
                }
                let reportedCurrency = field("currency")
                let currency = Trading212Position.currency(
                    reportedCurrency.isEmpty ? nil : reportedCurrency,
                    rawTicker: rawTicker
                )
                let result = action == "SELL" ? numericValue(field("result")) : nil
                let resultCurrency = field("resultCurrency").uppercased()
                let canonical = [field("date"), action, ticker, String(quantity), String(price), currency].joined(separator: "|")
                let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
                rowOccurrences[digest, default: 0] += 1
                if result != nil && resultCurrency.isEmpty {
                    warnings.append(L10n.text("第 \(headerIndex + offset + 2) 行：Result 缺少币种，不计入券商已实现盈亏。"))
                }
                transactions.append(Transaction(
                    date: try date(field("date")),
                    action: action,
                    ticker: ticker,
                    quantity: quantity,
                    price: price,
                    currency: currency.isEmpty ? "USD" : currency,
                    name: field("name"),
                    reference: field("reference").isEmpty ? "csv-\(digest)-\(rowOccurrences[digest]!)" : field("reference"),
                    realisedProfitLoss: result,
                    realisedProfitLossCurrency: resultCurrency.isEmpty ? nil : resultCurrency,
                    cashPostings: postings
                ))
            } catch {
                ledgerIncomplete = true
                warnings.append(L10n.text("第 \(headerIndex + offset + 2) 行：\(error.localizedDescription)"))
            }
        }
        guard !transactions.isEmpty else { throw LocalPortfolioError.invalidCSV(L10n.text("没有有效交易")) }

        struct PositionState {
            var shares = 0.0
            var average = 0.0
            var currency = "USD"
            var name = ""
            var openedDate: Date?
        }
        var states: [String: PositionState] = [:]
        for transaction in transactions.sorted(by: { $0.date < $1.date }) {
            guard transaction.action == "BUY" || transaction.action == "SELL" else { continue }
            var state = states[transaction.ticker] ?? PositionState()
            state.currency = transaction.currency
            if !transaction.name.isEmpty { state.name = transaction.name }
            if transaction.action == "BUY" {
                if state.shares <= 0.001 {
                    state.openedDate = transaction.date
                }
                let newShares = state.shares + transaction.quantity
                if newShares > 0 {
                    state.average = (state.average * state.shares + transaction.price * transaction.quantity) / newShares
                }
                state.shares = newShares
            } else {
                state.shares = max(0, state.shares - transaction.quantity)
                if state.shares <= 0.001 {
                    state.openedDate = nil
                }
            }
            states[transaction.ticker] = state
        }
        let positions = states.compactMap { ticker, state -> LocalPositionRecord? in
            guard state.shares > 0.001 else { return nil }
            return LocalPositionRecord(
                ticker: ticker,
                name: state.name,
                shares: state.shares,
                averageCost: state.average,
                currency: state.currency,
                quotePrice: state.average,
                quoteCurrency: state.currency,
                source: "CSV",
                openedDate: state.openedDate.map { DayDateFormatter.shared.string(from: $0) }
            )
        }.sorted { $0.ticker < $1.ticker }
        let imported = positions.map {
            CSVImportedHolding(ticker: $0.ticker, name: $0.name, shares: $0.shares, averageCost: $0.averageCost, currency: $0.currency)
        }
        let storedTransactions = transactions.map {
            LocalTransactionRecord(
                date: DayDateCodec.string(from: $0.date),
                action: $0.action,
                ticker: $0.ticker,
                quantity: $0.quantity,
                price: $0.price,
                currency: $0.currency,
                source: "CSV",
                accountID: nil,
                accountName: "CSV",
                tradeID: $0.reference,
                entryMethod: "csv",
                realisedProfitLoss: $0.realisedProfitLoss,
                realisedProfitLossCurrency: $0.realisedProfitLossCurrency,
                executedAt: ISO8601DateFormatter().string(from: $0.date),
                cashPostings: ledgerIncomplete ? nil : $0.cashPostings
            )
        }
        return (positions, storedTransactions, CSVImportResult(
            ok: true,
            holdingsCount: positions.count,
            transactionsCount: transactions.count,
            backupCreated: false,
            warnings: warnings,
            holdings: imported
        ))
    }

    private static func number(_ value: String) throws -> Double {
        guard let number = numericValue(value) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("无效数字 \(value)"))
        }
        return number
    }

    private static func date(_ value: String) throws -> Date {
        guard let parsed = parsedDate(value) else {
            throw LocalPortfolioError.invalidCSV(L10n.text("无效日期 \(value)"))
        }
        return parsed
    }

    static func parsedDate(_ value: String) -> Date? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: cleaned) { return date }
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss.SSSSSS", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm", "yyyy-MM-dd, HH:mm:ss", "yyyy/MM/dd HH:mm:ss",
            "MM/dd/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm:ss", "dd-MM-yyyy HH:mm:ss",
            "yyyy-MM-dd", "MM/dd/yyyy", "dd/MM/yyyy", "yyyy/MM/dd", "dd-MM-yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.isLenient = false
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    static func numericValue(_ value: String) -> Double? {
        var cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{00a0}", with: "")
            .replacingOccurrences(of: " ", with: "")
        let negative = cleaned.hasPrefix("(") && cleaned.hasSuffix(")")
        if negative { cleaned = String(cleaned.dropFirst().dropLast()) }
        cleaned = String(cleaned.filter { $0.isNumber || "+-.,eE".contains($0) })

        if let comma = cleaned.lastIndex(of: ","), let dot = cleaned.lastIndex(of: ".") {
            if comma > dot {
                cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: "")
            }
        } else if let comma = cleaned.lastIndex(of: ",") {
            let fractionalDigits = cleaned.distance(from: cleaned.index(after: comma), to: cleaned.endIndex)
            if fractionalDigits == 3 && cleaned.filter({ $0 == "," }).count == 1 {
                cleaned.remove(at: comma)
            } else {
                cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            }
        }
        guard let number = Double(cleaned) else { return nil }
        return negative ? -number : number
    }

    static func normalizedAction(_ value: String) -> String? {
        let action = normalizeHeader(value)
        if action == "deposit" || action == "入金" { return "DEPOSIT" }
        if action == "withdrawal" || action == "withdraw" || action == "出金" { return "WITHDRAWAL" }
        if action.contains("interest") { return "INTEREST" }
        if action == "fee" { return "FEE" }
        if action == "tax" { return "TAX" }
        if action.contains("buy") || action.contains("买入") { return "BUY" }
        if action.contains("sell") || action.contains("卖出") { return "SELL" }
        if action.contains("dividend") || action.contains("股息") || action.contains("红利") {
            return "DIVIDEND"
        }
        return nil
    }

    /// RFC 4180-style records shared by the manual importer and broker CSV
    /// downloads. Keeping the parser local means downloaded statements never
    /// need to leave the iPhone for conversion.
    static func parseRecords(_ text: String) -> [[String]] {
        let delimiter = detectedDelimiter(in: text)
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var insideQuotes = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if insideQuotes, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    insideQuotes.toggle()
                }
            } else if character == delimiter, !insideQuotes {
                record.append(field)
                field = ""
            } else if (character == "\n" || character == "\r"), !insideQuotes {
                if character == "\n" || !record.isEmpty || !field.isEmpty {
                    record.append(field)
                    if record.contains(where: { !$0.isEmpty }) { records.append(record) }
                    record = []
                    field = ""
                }
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        record.append(field)
        if record.contains(where: { !$0.isEmpty }) { records.append(record) }
        if let first = records.first, isSeparatorDirective(first) {
            records.removeFirst()
        }
        return records
    }

    private static func normalizeHeader(_ value: String) -> String {
        let folded = value
            .replacingOccurrences(of: "\u{feff}", with: "")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : " "
        }.joined()
        return scalars.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func headerMatches(_ value: String, alias: String) -> Bool {
        value == alias || value.hasPrefix("\(alias) ") || value.hasSuffix(" \(alias)")
    }

    private static func isSeparatorDirective(_ row: [String]) -> Bool {
        row.joined().trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("sep=")
    }

    private static func detectedDelimiter(in text: String) -> Character {
        let candidates: [Character] = [",", ";", "\t"]
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(12)

        if let directive = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           directive.hasPrefix("sep="), let separator = directive.last, candidates.contains(separator) {
            return separator
        }

        return candidates.max { lhs, rhs in
            lines.map { delimiterCount(in: String($0), delimiter: lhs) }.max() ?? 0
                < lines.map { delimiterCount(in: String($0), delimiter: rhs) }.max() ?? 0
        } ?? ","
    }

    private static func delimiterCount(in line: String, delimiter: Character) -> Int {
        var insideQuotes = false
        var count = 0
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if insideQuotes, next < line.endIndex, line[next] == "\"" {
                    index = next
                } else {
                    insideQuotes.toggle()
                }
            } else if character == delimiter, !insideQuotes {
                count += 1
            }
            index = line.index(after: index)
        }
        return count
    }
}


func tx(_ id:String,_ date:String,_ action:String,_ qty:Double,_ price:Double,_ account:String="A",_ time:String?=nil)->LocalTransactionRecord {
 LocalTransactionRecord(date:date,action:action,ticker:"TEST",quantity:qty,price:price,currency:"USD",source:"audit",accountID:account,accountName:account,tradeID:id,executedAt:time)
}
let fxData = Data(#"{"schemaVersion":1,"baseCurrency":"GBP","direction":"GBP_TO_QUOTE","nonObservationDayPolicy":"OMIT_NO_FORWARD_FILL","lookupPolicy":"","status":"VERIFIED","source":"fixture","unsupportedCurrencies":[],"dates":["2024-01-02","2024-01-03"],"rates":{"USD":[1.5,1.2]}}"#.utf8)
let fx = try GBPFXRates.decode(fxData)
let fxResult = FXImpactCalculator.impact(ticker:"TEST", transactions:[tx("buy","2024-01-02","BUY",100,100)],rates:fx,asOf:DayDateCodec.date(from:"2024-01-03")!)!
print("FX_UNITS raw=\(fxResult.amount)GBP; caller displays=\(fxResult.amount)USD; expected USD=\(fxResult.amount * 1.2)")
let stale = fx.quote(currency:"USD",on:"2026-09-13",within:7)!
print("FX_STALE returned \(stale.date) for 2026-09-13 within 7 days; match=\(stale.match)")
let across = FXImpactCalculator.impact(ticker:"TEST",transactions:[tx("a-buy","2024-01-02","BUY",100,100,"A"),tx("b-buy","2024-01-03","BUY",100,200,"B"),tx("b-sell","2024-01-03","SELL",100,200,"B")],rates:fx,asOf:DayDateCodec.date(from:"2024-01-03")!)!
print("FX_ACCOUNT FIFO remainingCost=\(across.cost), expected=10000; fx=\(across.amount), expectedGBP=\(fxResult.amount)")
let matches=UKShareMatching.disposals(ticker:"TEST",transactions:[tx("pool","2023-01-02","BUY",100,90),tx("s1","2024-01-02","SELL",10,100),tx("b2","2024-01-10","BUY",10,110),tx("s2","2024-01-10","SELL",10,120)])
for m in matches { print("UK_PRIORITY \(m.sourceID) -> \(m.matches.map { String(describing:$0.rule) })") }
let tEvents:[DailyTimeWeightedReturn.Event]=[.init(id:"fund",date:"2024-01-02",account:"A",cash:[.init(currency:"USD",amount:100)],external:true),.init(id:"buy",date:"2024-01-02",account:"A",symbol:"TEST",quantity:1,cash:[.init(currency:"USD",amount:-100)])]
let tDays:[DailyTimeWeightedReturn.Day]=[.init(date:"2024-01-02",quotes:["TEST":.init(price:100,currency:"USD")],usdRates:[:]),.init(date:"2024-01-03",quotes:["TEST":.init(price:160,currency:"USD")],usdRates:[:])]
let twr=try DailyTimeWeightedReturn.calculate(events:tEvents,days:tDays,implausibleGrowth:Decimal(string:"1.5"))
print("TWR_REAL_MOVE nav=\(twr.points.last!.nav), expected=1.6; inventedInflow=\(twr.points.last!.inflow)")
let csv="Date,Action,Ticker,Quantity,Price,Currency\n2024-06-07,BUY,NVDA,10,1000,USD\n2024-06-11,SELL,NVDA,50,110,USD\n"
let imported=try LocalCSVImporter.parse(Data(csv.utf8))
print("CSV_SPLIT remaining=\(imported.0.map { $0.shares }), expected=[50.0]; warnings=\(imported.2.warnings)")
let windowsCSV="Date,Action,Ticker,Quantity,Price,Currency\r\n2024-01-02,BUY,TEST,10,100,USD\r\n"
print("CSV_CRLF records=\(LocalCSVImporter.parseRecords(windowsCSV).count)")
do { let x=try LocalCSVImporter.parse(Data(windowsCSV.utf8)); print("CSV_CRLF parsed \(x.0.count)") } catch { print("CSV_CRLF failed: \(error)") }
let intradaySales=RealisedProfitCalculator.sales(transactions:[tx("z-early-buy","2024-01-02","BUY",10,100,"A","2024-01-02T09:00:00Z"),tx("sale","2024-01-02","SELL",10,200,"A","2024-01-02T10:00:00Z"),tx("a-late-buy","2024-01-02","BUY",10,50,"A","2024-01-02T11:00:00Z")])
print("FIFO_TIME outcomes=\(intradaySales.map { $0.outcome }); expectedProfit=1000")
