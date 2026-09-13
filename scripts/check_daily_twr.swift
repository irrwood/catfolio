import Foundation

// Compile with DailyTimeWeightedReturn.swift; no app, network or Core required.
@main struct CheckDailyTWR {
    typealias T = DailyTimeWeightedReturn
    static func event(_ id: String, _ day: String, _ amount: Decimal, external: Bool = false,
                      symbol: String? = nil, quantity: Decimal = 0, account: String = "A",
                      transfer: String? = nil, currency: String = "USD") -> T.Event {
        T.Event(id: id, date: day, account: account, symbol: symbol, quantity: quantity,
            cash: [.init(currency: currency, amount: amount)], external: external, transferID: transfer)
    }
    static func day(_ date: String, _ price: Decimal = 100) -> T.Day {
        T.Day(date: date, quotes: ["X": .init(price: price, currency: "USD")], usdRates: [:])
    }
    static func equal(_ actual: Decimal, _ expected: Decimal, _ name: String) {
        precondition(abs(NSDecimalNumber(decimal: actual - expected).doubleValue) < 1e-10, "\(name): \(actual) != \(expected)")
    }
    static func rejects(_ name: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected failure: \(name)") } catch { }
    }
    static func main() throws {
        let a = "2026-01-01", b = "2026-01-02", c = "2026-01-03"
        let funding = event("fund", a, 100, external: true)
        let buy = event("buy", a, -100, symbol: "X", quantity: 1)
        var result = try T.calculate(events: [funding, event("more", b, 100, external: true)], days: [day(a), day(b)])
        equal(result.points.last!.nav, 1, "deposits do not earn returns")
        result = try T.calculate(events: [funding, buy], days: [day(a), day(b, 110), day(c, 121)])
        equal(result.points.last!.nav, Decimal(string: "1.21")!, "geometric linking")
        result = try T.calculate(events: [funding, buy, event("sale", b, 110, symbol: "X", quantity: -1)], days: [day(a), day(b, 110), day(c, 500)])
        equal(result.points.last!.nav, Decimal(string: "1.1")!, "closed stock stops contributing")
        result = try T.calculate(events: [funding, buy, event("dividend", b, 5)], days: [day(a), day(b, 95)])
        equal(result.points.last!.nav, 1, "dividend and ex-div price counted once")
        result = try T.calculate(events: [funding, event("fee", b, -2)], days: [day(a), day(b)])
        equal(result.points.last!.nav, Decimal(string: ".98")!, "fee reduces return")
        result = try T.calculate(events: [funding, event("out", b, -100, external: true), event("restart", c, 50, external: true)], days: [day(a), day(b), day(c)])
        equal(result.points.last!.nav, 1, "full withdrawal and restart")
        result = try T.calculate(events: [funding, buy], days: [day(a), day(b, 50)], splits: [.init(date: b, symbol: "X", factor: 2)])
        equal(result.points.last!.nav, 1, "split preserves value")
        equal(result.holdings["A"]!["X"]!, 2, "split shares")
        result = try T.calculate(events: [funding, buy], days: [day(a), day(b, 200)], splits: [.init(date: b, symbol: "X", factor: Decimal(string: ".5")!)])
        equal(result.points.last!.nav, 1, "reverse split preserves value")
        result = try T.calculate(events: [funding,
            event("transfer-out", b, -50, external: true, transfer: "t"),
            event("transfer-in", b, 50, external: true, account: "B", transfer: "t")], days: [day(a), day(b)])
        equal(result.points.last!.inflow, 0, "internal transfers cancel")
        equal(result.points.last!.outflow, 0, "internal transfers cancel out")
        result = try T.calculate(events: [event("gbp", a, 100, external: true, currency: "GBP")], days: [
            .init(date: a, quotes: [:], usdRates: ["GBP": 1]), .init(date: b, quotes: [:], usdRates: ["GBP": Decimal(string: "1.1")!])])
        equal(result.points.last!.nav, Decimal(string: "1.1")!, "cash FX earns reporting-currency return")
        rejects("missing opening funding") { _ = try T.calculate(events: [buy], days: [day(a)]) }
        rejects("missing quote") { _ = try T.calculate(events: [funding, buy], days: [.init(date: a, quotes: [:], usdRates: [:])]) }
        rejects("duplicate transaction") { _ = try T.calculate(events: [funding, funding], days: [day(a)]) }
        rejects("missing cashflow day") { _ = try T.calculate(events: [funding], days: [day(b)]) }
        rejects("missing FX") { _ = try T.calculate(events: [event("gbp", a, 100, external: true, currency: "GBP")], days: [day(a)]) }
        rejects("negative shares") { _ = try T.calculate(events: [funding, event("sell", a, 100, symbol: "X", quantity: -1)], days: [day(a)]) }
        print("PASS: 16 ledger cases (cash, trades, dividends, fees, splits, transfers, FX and invalid inputs)")

        // Optional read-only Core fixture verification. The synthetic account
        // holds one share; its independent expected NAV is raw close / first.
        if let path = CommandLine.arguments.dropFirst().first {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let queries = root["queries"] as! [[String: Any]]
            var count = 0
            for query in queries {
                let payload = query["result"] as! [String: Any]
                let raw = payload["rows"] as! [[String: Any]]
                let rows = raw.sorted { ($0["trade_date"] as! String) < ($1["trade_date"] as! String) }
                func date(_ row: [String: Any]) -> String { row["trade_date"] as! String }
                guard let first = rows.first, let initial = Decimal(string: first["close"] as! String) else { continue }
                precondition(rows.allSatisfy { $0["price_basis"] as? String == "UNADJUSTED" && $0["quote_currency"] as? String == "USD" })
                let dates = rows.map { day(date($0), Decimal(string: $0["close"] as! String)!) }
                let actual = try T.calculate(events: [event("fund", date(first), initial, external: true), event("buy", date(first), -initial, symbol: "X", quantity: 1)], days: dates)
                for (point, row) in zip(actual.points, rows) { equal(point.nav, Decimal(string: row["close"] as! String)! / initial, "Core daily NAV") }
                count += rows.count
            }
            print("PASS: Core raw daily price replay, \(count) valuations; synthetic test account only")
        }
    }
}
