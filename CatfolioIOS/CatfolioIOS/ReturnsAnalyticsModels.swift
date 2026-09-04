import Foundation

struct DrawdownPoint: Identifiable, Equatable, Sendable {
    let dateText: String
    let drawdown: Double

    var id: String { dateText }
    var date: Date { DayDateCodec.date(from: dateText) ?? .distantPast }
}

struct DrawdownSeries: Equatable, Sendable {
    let rows: [DrawdownPoint]
    let maxDrawdown: Double
    let warnings: [String]

    static let empty = DrawdownSeries(rows: [], maxDrawdown: 0, warnings: [])
}

struct ValuationBubble: Identifiable, Equatable, Sendable {
    let ticker: String
    let displayName: String
    let sector: String
    let pe: Double
    let growthPercent: Double
    let growthSource: String
    let weight: Double

    var id: String { ticker }
}

struct ValuationMatrix: Equatable, Sendable {
    let rows: [ValuationBubble]
    let warnings: [String]

    static let empty = ValuationMatrix(rows: [], warnings: [])
}

struct ReturnsAnalyticsResponse: Equatable, Sendable {
    let drawdown: DrawdownSeries
    let valuation: ValuationMatrix
    let warnings: [String]
}

enum ReturnsAnalyticsPart: Hashable, Sendable {
    case drawdown
    case valuation
}
