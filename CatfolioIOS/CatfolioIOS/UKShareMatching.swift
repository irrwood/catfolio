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

        let sales = entries.filter { !$0.isBuy }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
        }
        var outstanding = sales.map(\.quantity)
        var matches = Array(repeating: [Match](), count: sales.count)
        func consume(_ sale: Int, sameDay: Bool) {
            guard let windowEnd = Self.windowEnd(after: sales[sale].date) else { return }
            for index in acquisitions.indices where outstanding[sale] > 0 {
                let date = acquisitions[index].date
                let eligible = sameDay ? date == sales[sale].date
                    : date > sales[sale].date && date <= windowEnd
                guard eligible, acquisitions[index].remaining > 0 else { continue }
                let taken = min(outstanding[sale], acquisitions[index].remaining)
                acquisitions[index].remaining -= taken
                outstanding[sale] -= taken
                matches[sale].append(Match(rule: sameDay ? .sameDay : .thirtyDay(acquired: date),
                    quantity: taken, acquisitionID: acquisitions[index].id))
            }
        }
        for index in sales.indices { consume(index, sameDay: true) }
        for index in sales.indices { consume(index, sameDay: false) }
        return sales.indices.map { index in
            if outstanding[index] > 0 {
                matches[index].append(Match(rule: .section104, quantity: outstanding[index]))
            }
            return Disposal(sourceID: sales[index].id, date: sales[index].date,
                quantity: sales[index].quantity, matches: matches[index])
        }
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
