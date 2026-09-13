import Foundation

/// How far a value sits below its own high, day by day: the underwater
/// curve. The high is the highest value so far *within the window*, so a
/// month's chart shows the month's drawdowns rather than one from years ago.
struct UnderwaterSeries: Sendable {
    struct Point: Sendable {
        let dateText: String
        let date: Date
        let value: Double
        /// The highest value up to and including this day.
        let peak: Double
        let peakDateText: String
        /// Zero at a high, negative below it.
        var drawdown: Double { peak > 0 ? value / peak - 1 : 0 }
    }

    let points: [Point]

    init(dates: [(text: String, date: Date)], values: [Double]) {
        var peak = -Double.infinity, peakText = ""
        var points: [Point] = []
        points.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            if value >= peak { peak = value; peakText = dates[index].text }
            points.append(Point(dateText: dates[index].text, date: dates[index].date, value: value, peak: peak, peakDateText: peakText))
        }
        self.points = points
    }

    /// The deepest point, the earliest if two are equal.
    var trough: Point? {
        points.min { $0.drawdown == $1.drawdown ? $0.date < $1.date : $0.drawdown < $1.drawdown }
    }

    var maxDrawdown: Double { min(0, trough?.drawdown ?? 0) }

    /// The first day after the deepest point that climbed back to the high
    /// before it. Nil while the value is still under it.
    var recovery: Point? {
        guard let trough, trough.drawdown < 0 else { return nil }
        return points.first { $0.date > trough.date && $0.value >= trough.peak }
    }

    /// Calendar days from the last high to the end, when the window ends
    /// underwater.
    var daysUnderwater: Int {
        guard let last = points.last, last.drawdown < 0,
              let high = points.last(where: { $0.dateText == last.peakDateText }) else { return 0 }
        return Calendar(identifier: .gregorian).dateComponents([.day], from: high.date, to: last.date).day ?? 0
    }

    /// The longest stretch spent below a high, in calendar days, whether it
    /// ended or is still going.
    var longestUnderwaterDays: Int {
        var longest = 0, start: Date?
        for point in points {
            if point.drawdown < 0 {
                if start == nil { start = points.last(where: { $0.dateText == point.peakDateText })?.date ?? point.date }
            } else if let began = start {
                longest = max(longest, Calendar(identifier: .gregorian).dateComponents([.day], from: began, to: point.date).day ?? 0)
                start = nil
            }
        }
        if let began = start, let last = points.last {
            longest = max(longest, Calendar(identifier: .gregorian).dateComponents([.day], from: began, to: last.date).day ?? 0)
        }
        return longest
    }

    /// The rise that would take a value back to its high: a 20% fall needs
    /// a 25% gain.
    static func gainToRecover(_ drawdown: Double) -> Double {
        drawdown > -1 ? 1 / (1 + drawdown) - 1 : .infinity
    }
}

/// The portfolio's underwater curve taken apart by holding. On any day the
/// fall from the high is the sum of each holding's own change since that
/// high, because the share counts do not change — so each holding's part is
/// exact, not an estimate.
///
/// The holdings that pulled hardest at the deepest point get their own band,
/// the rest are one band together. Bands only ever show a pull downward; a
/// holding that rose since the high offsets the others, which is why the
/// portfolio's line can sit above the bands.
struct UnderwaterStack: Sendable {
    struct Band: Sendable, Equatable {
        /// Nil for the others together.
        let ticker: String?
        let title: String
        let subtitle: String
        /// Place in the palette, by rank at the deepest point.
        let colour: Int
    }

    struct Row: Sendable {
        let dateText: String
        let date: Date
        /// The portfolio's own drawdown: the line.
        let drawdown: Double
        /// Each band's pull, zero or negative, in `bands` order.
        let bands: [Double]
        /// Every holding's part of the drawdown, as a share of the high.
        let parts: [String: Double]
        /// The high's value and date the day is measured from.
        let peak: Double
        let peakDateText: String
        let value: Double

        /// The bands' bottom: how deep the pulling holdings alone would go.
        var gross: Double { bands.reduce(0, +) }
    }

    static let maximumNamed = 6
    static let minimumShare = 0.06

    let bands: [Band]
    let rows: [Row]
    let total: UnderwaterSeries
    /// Each holding's own underwater curve over the same window.
    let holdings: [String: UnderwaterSeries]
    let names: [String: String]

    init(history: HoldingValueHistory, range: ChartTimeRange, names extra: [String: String] = [:]) {
        var names = history.names
        for (ticker, name) in extra { names[ticker] = name }
        self.names = names

        let all = history.rows
        let window: [HoldingValueHistory.Row]
        if let last = all.last?.date {
            let previous = all.dropLast().last?.date
            window = all.filter { range.includes($0.date, through: last, previousTradingDate: previous) }
        } else {
            window = []
        }
        let dates = window.map { (text: $0.dateText, date: $0.date) }
        let tickers = Set(window.flatMap(\.values.keys)).sorted()
        let total = UnderwaterSeries(dates: dates, values: window.map(\.total))
        self.total = total
        holdings = Dictionary(uniqueKeysWithValues: tickers.map { ticker in
            (ticker, UnderwaterSeries(dates: dates, values: window.map { $0.values[ticker] ?? 0 }))
        })

        // Every holding's part on every day, against the day's high.
        var parts: [[String: Double]] = []
        var peakIndex = 0
        for (index, row) in window.enumerated() {
            if row.total >= window[peakIndex].total { peakIndex = index }
            let high = window[peakIndex]
            let base = high.total
            parts.append(Dictionary(uniqueKeysWithValues: tickers.map { ticker in
                (ticker, base > 0 ? ((row.values[ticker] ?? 0) - (high.values[ticker] ?? 0)) / base : 0)
            }))
        }

        // Named: the biggest pulls at the deepest point, while each is a fair
        // share of everything pulling there.
        let troughIndex = total.points.indices.min { total.points[$0].drawdown < total.points[$1].drawdown } ?? 0
        let atTrough = parts.indices.contains(troughIndex) ? parts[troughIndex] : [:]
        let pulling = atTrough.filter { $0.value < 0 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }
        let named = Array(pulling.prefix(Self.namedCount(pulling.map { -$0.value })).map(\.key))
        let others = Set(tickers).subtracting(named)

        // Nearest the axis first: the others, then the named from the
        // smallest pull to the largest, so the largest is deepest.
        var bands = [Band(ticker: nil, title: L10n.text("其他持仓"), subtitle: L10n.text("\(others.count) 项持仓合计"), colour: -1)]
        for (rank, ticker) in named.enumerated().reversed() {
            bands.append(Band(ticker: ticker, title: ticker, subtitle: names[ticker] ?? ticker, colour: rank))
        }
        self.bands = bands

        rows = window.indices.map { index in
            let part = parts[index]
            let othersNet = others.reduce(0) { $0 + (part[$1] ?? 0) }
            let point = total.points[index]
            return Row(
                dateText: window[index].dateText,
                date: window[index].date,
                drawdown: point.drawdown,
                bands: [min(0, othersNet)] + named.reversed().map { min(0, part[$0] ?? 0) },
                parts: part,
                peak: point.peak,
                peakDateText: point.peakDateText,
                value: point.value
            )
        }
    }

    /// How many of the pulls, largest first, get their own band.
    static func namedCount(_ pulls: [Double]) -> Int {
        let positive = pulls.filter { $0 > 0 }.sorted(by: >)
        let total = positive.reduce(0, +)
        guard total > 0 else { return 0 }
        var count = 0
        for pull in positive.prefix(maximumNamed) {
            guard count == 0 || pull / total >= minimumShare else { break }
            count += 1
        }
        return count
    }

    func row(nearest date: Date?) -> Row? {
        guard let date else { return nil }
        return rows.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    /// The others' net part: a pull, or an offset when they rose.
    func othersPart(_ row: Row) -> Double {
        let named = Set(bands.compactMap(\.ticker))
        return row.parts.filter { !named.contains($0.key) }.values.reduce(0, +)
    }

    /// Holdings from the deepest pull at the trough to the largest offset.
    var rankedAtTrough: [(ticker: String, part: Double)] {
        guard let trough = total.trough, let row = rows.first(where: { $0.dateText == trough.dateText }) else { return [] }
        return row.parts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }.map { ($0.key, $0.value) }
    }
}
