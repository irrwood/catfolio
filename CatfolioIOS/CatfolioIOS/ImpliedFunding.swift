import Foundation

/// For accounts whose history was imported without its cash legs — broker
/// syncs and trade-only CSVs record what was bought, not the money that
/// moved. Such an account is rebuilt on stated assumptions rather than left
/// unavailable:
///
/// - a trade's cash is its fill, quantity × price, in the trade's currency;
/// - a day that ends short of cash was funded from outside that day;
/// - shares the trades cannot account for were transferred in at the first
///   close the window has for them, with their value as the deposit.
///
/// Every assumption adds money in at market value, so none of them creates a
/// gain. Accounts with a complete cash ledger never pass through here.
extension DailyTimeWeightedReturn {
    /// Deposit-and-buy pairs that open each position the trades alone leave
    /// short, sized so the history never sells what it does not hold and
    /// ends at today's share count.
    ///
    /// - Parameters:
    ///   - expected: today's shares by account and symbol.
    ///   - quotes: closes by symbol and date. The transfer is made at the
    ///     first close on or after `start`, or after the position's own
    ///     opening date where the broker gave one — the date and the value
    ///     both come from that close.
    static func openingTransfers(
        events: [Event],
        splits: [Split],
        expected: [String: [String: Decimal]],
        quotes: [String: [String: Quote]],
        start: String,
        openedDates: [String: [String: String]] = [:],
        accounts: Set<String>
    ) -> [Event] {
        var openings: [Event] = []
        let splitsBySymbol = Dictionary(grouping: splits, by: \.symbol)
        for account in accounts.sorted() {
            let accountEvents = events.filter { $0.account == account && $0.symbol != nil }
            let symbols = Set(accountEvents.compactMap(\.symbol)).union(expected[account]?.keys.map { $0 } ?? [])
            for symbol in symbols.sorted() {
                let from = max(start, openedDates[account]?[symbol] ?? start)
                guard let closes = quotes[symbol], let firstDate = closes.keys.filter({ $0 >= from }).min(),
                      let firstQuote = closes[firstDate] else { continue }
                let first = (date: firstDate, quote: firstQuote)
                let trades = accountEvents.filter { $0.symbol == symbol }
                let symbolSplits = splitsBySymbol[symbol] ?? []
                // End-of-day holdings from the trades alone, split-adjusted
                // the way the ledger adjusts them.
                let dates = Set(trades.map(\.date) + symbolSplits.map(\.date) + [first.date]).sorted()
                var running: Decimal = 0
                var growth: Decimal = 1
                var needed: Decimal = 0
                var feasible = true
                for date in dates {
                    for split in symbolSplits where split.date == date {
                        running *= split.factor
                        if date > first.date { growth *= split.factor }
                    }
                    running += trades.filter { $0.date == date }.reduce(0) { $0 + $1.quantity }
                    if running < 0 {
                        // Short before there is a price to transfer at: the
                        // gap cannot be filled, and the ledger will say so.
                        if date < first.date { feasible = false; break }
                        needed = max(needed, -running / growth)
                    }
                }
                guard feasible else { continue }
                let target = expected[account]?[symbol] ?? 0
                if target > running { needed = max(needed, (target - running) / growth) }
                guard needed > Decimal(string: "0.000001")! else { continue }
                let value = needed * first.quote.price
                let key = "\(account)|\(symbol)"
                openings.append(Event(id: "implied-open-funding|" + key, date: first.date, account: account,
                                      cash: [Cash(currency: first.quote.currency, amount: value)], external: true))
                openings.append(Event(id: "implied-open|" + key, date: first.date, account: account, symbol: symbol,
                                      quantity: needed, cash: [Cash(currency: first.quote.currency, amount: -value)]))
            }
        }
        return openings
    }

    /// Deposits that keep each account's cash from ending a day below zero,
    /// one per account, currency and day that falls short.
    static func fundingShortfalls(events: [Event], accounts: Set<String>) -> [Event] {
        var balances: [String: [String: Decimal]] = [:]
        var deposits: [Event] = []
        let byDate = Dictionary(grouping: events.filter { accounts.contains($0.account) }, by: \.date)
        for date in byDate.keys.sorted() {
            for event in byDate[date] ?? [] {
                for posting in event.cash {
                    balances[event.account, default: [:]][posting.currency, default: 0] += posting.amount
                }
            }
            for account in balances.keys.sorted() {
                for (currency, balance) in (balances[account] ?? [:]).sorted(by: { $0.key < $1.key }) where balance < 0 {
                    deposits.append(Event(id: "implied-funding|\(account)|\(currency)|\(date)", date: date, account: account,
                                          cash: [Cash(currency: currency, amount: -balance)], external: true))
                    balances[account]?[currency] = 0
                }
            }
        }
        return deposits
    }
}
