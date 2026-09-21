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
    let growthPercent: Double?
    let growthSource: String
    let weight: Double
    var quality: ValuationQuality? = nil
    var pePeriod: String? = nil
    var peSource: String? = nil

    var epsGrowthPercent: Double? { quality?.epsGrowthPercent }
    var roicPercent: Double? { isFinancial ? nil : quality?.roicPercent }
    var isFinancial: Bool {
        sector.contains("金融") || sector.contains("银行") || sector.contains("保险")
            || sector.localizedCaseInsensitiveContains("financial")
            || sector.localizedCaseInsensitiveContains("bank")
            || sector.localizedCaseInsensitiveContains("insurance")
    }
    var qualityReason: String? {
        if isFinancial { return "金融企业不适用此 ROIC 口径" }
        return quality?.roicUnavailableReason ?? (quality == nil ? "暂无可用 SEC 年度财报" : nil)
    }
    var isThreeDimensional: Bool {
        pe.isFinite && pe > 0 && epsGrowthPercent != nil && roicPercent != nil
    }

    var id: String { ticker }
}

struct ValuationMatrix: Equatable, Sendable {
    let rows: [ValuationBubble]
    var unavailable: [ValuationUnavailable] = []
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

struct ValuationUnavailable: Identifiable, Equatable, Sendable {
    let ticker: String
    let reason: String
    var id: String { ticker }
}
