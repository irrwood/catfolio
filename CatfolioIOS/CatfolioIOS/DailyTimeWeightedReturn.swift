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
