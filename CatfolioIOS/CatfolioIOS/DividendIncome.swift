import Foundation

/// What a number of shares would pay, from the dividends the listing paid
/// over the last year. Per share, in the listing's own quote currency.
struct DividendIncome: Equatable {
    /// The latest payment, repeated: the next one is assumed to match it.
    let nextPerShare: Double
    /// Everything paid with an ex-date in the past year.
    let trailingPerShare: Double
    /// The latest payment at the past year's pace.
    let forwardPerShare: Double
    let currency: String

    /// Nil for a listing that has paid nothing in the past year.
    init?(payments: [DividendForecast.Payment], today: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let yearAgo = DayDateCodec.string(from: calendar.date(byAdding: .year, value: -1, to: today) ?? today)
        let recent = payments.filter { $0.exDate > yearAgo && $0.perShare > 0 }.sorted { $0.exDate < $1.exDate }
        guard let latest = recent.last else { return nil }
        nextPerShare = latest.perShare
        trailingPerShare = recent.reduce(0) { $0 + $1.perShare }
        forwardPerShare = latest.perShare * Double(recent.count)
        currency = latest.currency
    }

    /// The share counts the slider stops on: single shares up to 100, then
    /// coarser steps, so a flick covers a thousand shares as easily as ten.
    /// The holding's own count is always one of them, fractions included.
    static func shareSteps(including held: Double) -> [Double] {
        var steps = Array(stride(from: 0.0, through: 100, by: 1))
        steps += stride(from: 110.0, through: 1_000, by: 10)
        steps += stride(from: 1_100.0, through: 10_000, by: 100)
        steps += stride(from: 11_000.0, through: 100_000, by: 1_000)
        if held > 0, !steps.contains(held) { steps.append(held) }
        return steps.sorted()
    }

    /// The step nearest a typed count.
    static func nearestStep(to shares: Double, in steps: [Double]) -> Int {
        steps.indices.min { abs(steps[$0] - shares) < abs(steps[$1] - shares) } ?? 0
    }
}
