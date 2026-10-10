import Foundation

enum PortfolioAttentionLevel: String, Codable, Sendable {
    case high, medium, none
}

enum PortfolioThesisStance: String, Codable, Sendable {
    case strengthening, maintaining, weakening
}

/// What the direction rests on. Only a confirmed company event reads as the
/// investment case changing; everything else is the price moving, which is
/// worth a look but is not a conclusion about the company.
enum PortfolioThesisBasis: String, Codable, Sendable {
    case company
    case price
}

struct PortfolioAttentionSignal: Identifiable, Codable, Sendable {
    let kind: String
    let label: String
    let direction: String
    let value: Double

    var id: String { kind }

    /// A fact about the reader's own position rather than about the security:
    /// how much of today's portfolio move this holding accounts for. It says
    /// why the holding is worth their attention, and nothing about whether
    /// the company is doing well, so it is never supporting evidence for a
    /// stance — cited as one it only restates the move that raised the flag.
    var isPortfolioRelative: Bool { kind == "portfolio_contribution" }
}

struct PortfolioAttentionSource: Identifiable, Codable, Sendable {
    let id: String
    let title: String
    let publisher: String
    let url: URL
    let publishedAt: Date?
    let tier: String
    /// A publisher's own summary, when the feed carries one (Finnhub does).
    /// Read only when the article itself cannot be fetched.
    var summary: String? = nil
}

struct PortfolioAttentionThesis: Codable, Sendable {
    var stance: PortfolioThesisStance
    /// Absent in reports written before the distinction existed; those were
    /// read from price signals, which is what `price` means.
    var basis: PortfolioThesisBasis? = nil
    var confidence: PortfolioAttentionLevel
    var whatChanged: String
    var whyItMatters: String
    var supportingEvidence: [String]
    var counterEvidence: [String]
    var risks: [String]
    var watchNext: [String]
    var riskFlags: [String]

    /// Which way the price signals lean, for a reading that rests on them.
    /// Volume alone has no direction, so a spike on its own reads as neutral.
    /// Portfolio-relative signals do not vote. The share of the day a holding
    /// accounts for carries the sign of the move that raised it, so counting
    /// it weighed the same move twice and let position size tip the reading.
    static func priceStance(_ signals: [PortfolioAttentionSignal]) -> PortfolioThesisStance {
        let signals = signals.filter { !$0.isPortfolioRelative }
        let positive = signals.filter { $0.direction == "positive" }.count
        let negative = signals.filter { $0.direction == "negative" }.count
        if positive > negative { return .strengthening }
        return negative > positive ? .weakening : .maintaining
    }
}

struct PortfolioFundamentalSnapshot: Codable, Sendable {
    let source: String
    let latestPeriod: String?
    let revenueGrowthYoY: Double?
    let operatingIncomeGrowthYoY: Double?
    let freeCashFlowGrowthYoY: Double?
}

struct PortfolioAttentionHolding: Identifiable, Codable, Sendable {
    let ticker: String
    let name: String
    let attention: PortfolioAttentionLevel
    let weight: Double
    let portfolioContributionPercent: Double?
    let return60DPercent: Double?
    let volumeMultiple: Double?
    let distanceFrom52WHighPercent: Double?
    let distanceFrom52WLowPercent: Double?
    let ma200PositionPercent: Double?
    let signals: [PortfolioAttentionSignal]
    var fundamentals: PortfolioFundamentalSnapshot?
    var thesis: PortfolioAttentionThesis
    var sources: [PortfolioAttentionSource]
    /// The reader's changes to the evidence, once they have made any.
    var adjustment: PortfolioAttentionAdjustment? = nil
    /// Questions the reader asked about this holding, with the answers.
    var followUps: [PortfolioAttentionFollowUp]? = nil

    var id: String { ticker }

    /// `name` is the company's own name, which a news search needs. What the
    /// reader sees follows 设置 › 公司名称 as it is now, so switching to
    /// 中文简称 also renames an analysis written earlier.
    var displayName: String {
        CompanyNameCatalog.displayName(ticker: ticker, fallback: name)
    }
}

struct PortfolioAttentionFollowUp: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var question: String
    var answer: String
    var askedAt: Date
    /// The model looked things up beyond the analysis's own sources.
    var searched = false
}

/// What the reader changed about a holding's evidence: points they set aside
/// and points of their own. The model's original lists are kept, so a point
/// turned off can always be turned back on.
struct PortfolioAttentionAdjustment: Codable, Sendable, Equatable {
    var originalSupporting: [String]
    var originalCounter: [String]
    var excluded: [String] = []
    var notes: [String] = []
    var rejudgedAt: Date?
}

/// Which evidence an attention analysis may use. Set in the attention page's
/// rules; applied the next time the analysis runs.
enum AttentionEvidenceRules {
    static let maximumAgeKey = "research.evidence.maximumAgeDays"
    static let reliableOnlyKey = "research.evidence.reliableOnly"
    static let excludeAggregatorsKey = "research.evidence.excludeAggregators"
    static let ageChoices = [7, 15, 30, 90]

    static var maximumAgeDays: Int {
        let stored = UserDefaults.standard.integer(forKey: maximumAgeKey)
        return stored > 0 ? stored : 30
    }
    static var reliableOnly: Bool { UserDefaults.standard.bool(forKey: reliableOnlyKey) }
    static var excludeAggregators: Bool {
        UserDefaults.standard.object(forKey: excludeAggregatorsKey) as? Bool ?? true
    }

    /// Sites that re-write other people's reporting. They can fill in a
    /// story; they are not the source of one.
    static let aggregators = [
        "stockstory", "stocktitan", "simply wall st", "simplywall", "webull", "stockanalysis",
        "marketbeat", "tipranks", "gurufocus", "insider monkey", "investorplace", "zacks",
    ]

    static func isAggregator(_ publisher: String) -> Bool {
        let name = publisher.lowercased()
        return aggregators.contains { name.contains($0) }
    }

    /// The sources the rules allow. Undated reference data (SEC company
    /// facts) has no age to judge and is kept.
    static func allowed(_ sources: [PortfolioAttentionSource], now: Date = .now) -> [PortfolioAttentionSource] {
        let maximumAge = TimeInterval(maximumAgeDays) * 86_400
        return sources.filter { source in
            if excludeAggregators, isAggregator(source.publisher) { return false }
            if reliableOnly, !["filing", "primary", "wire"].contains(source.tier) { return false }
            if let date = source.publishedAt, now.timeIntervalSince(date) > maximumAge { return false }
            return true
        }
    }
}

/// The thresholds the attention scan flags a holding by. Kept on this
/// device; the defaults are the scan's original numbers, and resetting
/// removes the stored values so a later change of default reaches the reader.
struct AttentionSignalRules: Equatable, Sendable {
    var returnWindowDays = 60
    var returnThreshold = 10.0
    var volumeMultiple = 2.0
    var volumeBaselineDays = 30
    var nearExtremePercent = 3.0
    var todayMoveThreshold = 5.0
    var movingAverageDays = 200
    var contributionShare = 40.0
    var highAttentionSignals = 2

    static let returnWindowKey = "research.signals.returnWindowDays"
    static let returnThresholdKey = "research.signals.returnThreshold"
    static let volumeMultipleKey = "research.signals.volumeMultiple"
    static let volumeBaselineKey = "research.signals.volumeBaselineDays"
    static let nearExtremeKey = "research.signals.nearExtremePercent"
    static let todayMoveKey = "research.signals.todayMoveThreshold"
    static let movingAverageKey = "research.signals.movingAverageDays"
    static let contributionShareKey = "research.signals.contributionShare"
    static let highAttentionKey = "research.signals.highAttentionSignals"

    static let keys = [returnWindowKey, returnThresholdKey, volumeMultipleKey, volumeBaselineKey, nearExtremeKey,
                       todayMoveKey, movingAverageKey, contributionShareKey, highAttentionKey]

    /// Price history covers about 275 sessions, so every choice here can be
    /// computed from it.
    static let returnWindowChoices = [20, 60, 120, 250]
    static let volumeBaselineChoices = [10, 20, 30, 60]
    static let movingAverageChoices = [20, 50, 100, 200]

    static let defaults = AttentionSignalRules()

    static var current: AttentionSignalRules {
        let store = UserDefaults.standard
        func int(_ key: String, _ fallback: Int, in choices: [Int]? = nil) -> Int {
            guard let value = store.object(forKey: key) as? Int, value > 0 else { return fallback }
            return choices.map { $0.contains(value) ? value : fallback } ?? value
        }
        func double(_ key: String, _ fallback: Double) -> Double {
            guard let value = store.object(forKey: key) as? Double, value > 0 else { return fallback }
            return value
        }
        let base = AttentionSignalRules.defaults
        return AttentionSignalRules(
            returnWindowDays: int(returnWindowKey, base.returnWindowDays, in: returnWindowChoices),
            returnThreshold: double(returnThresholdKey, base.returnThreshold),
            volumeMultiple: double(volumeMultipleKey, base.volumeMultiple),
            volumeBaselineDays: int(volumeBaselineKey, base.volumeBaselineDays, in: volumeBaselineChoices),
            nearExtremePercent: double(nearExtremeKey, base.nearExtremePercent),
            todayMoveThreshold: double(todayMoveKey, base.todayMoveThreshold),
            movingAverageDays: int(movingAverageKey, base.movingAverageDays, in: movingAverageChoices),
            contributionShare: double(contributionShareKey, base.contributionShare),
            highAttentionSignals: int(highAttentionKey, base.highAttentionSignals)
        )
    }

    static func reset() {
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
    }
}

struct PortfolioAttentionReport: Codable, Sendable {
    let generatedAt: Date
    let holdingsCount: Int
    let noMaterialChangeCount: Int
    var attentionRows: [PortfolioAttentionHolding]
    let warnings: [String]

    var contextSummary: String {
        let rows = attentionRows.map { row in
            let signals = row.signals.map { L10n.message($0.label) }.joined(separator: L10n.listSeparator)
            return "\(row.ticker) | \(row.attention.rawValue) | \(row.thesis.stance.rawValue) | \(row.thesis.confidence.rawValue) | \(signals) | \(row.thesis.whyItMatters)"
        }.joined(separator: "\n")
        return L10n.text("Portfolio Attention 扫描了 \(holdingsCount) 只持仓，\(attentionRows.count) 只需要关注。\n\(rows)")
    }

    var markdownFallback: String {
        var blocks = [L10n.text("## 今天"), L10n.text("**\(holdingsCount) 只持仓中有 \(attentionRows.count) 只需要关注**")]
        for row in attentionRows {
            blocks.append("""
            ### \(row.ticker)
            \(row.attention.rawValue.capitalized) attention · \(row.thesis.stance.rawValue)

            \(row.signals.map { L10n.message($0.label) }.joined(separator: " · "))

            \(row.thesis.whyItMatters)

            **\(L10n.text("主要风险："))** \(row.thesis.risks.first ?? L10n.text("暂无已确认的公司级风险"))
            """)
        }
        blocks.append(L10n.text("**其他持仓**\n\(noMaterialChangeCount) 只 · 无重大变化"))
        return blocks.joined(separator: "\n\n")
    }
}
