import Foundation
import CryptoKit
import FoundationModels
import OSLog

struct LocalPortfolioAttentionEngine {
    private struct Candidate {
        let holding: Holding
        let return60D: Double?
        let volumeMultiple: Double?
        let distanceHigh: Double?
        let distanceLow: Double?
        let ma200Position: Double?
        let ma200Cross: String?
        let contribution: Double?
        var signals: [PortfolioAttentionSignal]
    }

    /// The reader's thresholds from 编辑规则, read once per scan.
    var rules = AttentionSignalRules.current

    func scan(document: LocalPortfolioDocument) async throws -> PortfolioAttentionReport {
        let holdings = try LocalPortfolioEngine.presentation(for: document).2
        guard !holdings.isEmpty else { throw LocalPortfolioError.noPortfolio }
        let histories = await histories(for: holdings)
        var candidates = holdings.map { holding in
            candidate(holding: holding, bars: histories[holding.ticker.uppercased()] ?? [])
        }
        let totalAbsoluteContribution = candidates.reduce(0) { partial, row in
            partial + abs(row.contribution ?? 0)
        }
        for index in candidates.indices {
            guard totalAbsoluteContribution > 0,
                  let contribution = candidates[index].contribution else { continue }
            let share = abs(contribution) / totalAbsoluteContribution
            if share >= rules.contributionShare / 100, abs(contribution) >= 0.20 {
                candidates[index].signals.append(PortfolioAttentionSignal(
                    kind: "portfolio_contribution",
                    label: "占今日组合波动 \(Int((share * 100).rounded()))%",
                    direction: contribution >= 0 ? "positive" : "negative",
                    value: share
                ))
            }
        }
        let selected = candidates.compactMap { row -> PortfolioAttentionHolding? in
            guard !row.signals.isEmpty else { return nil }
            let level: PortfolioAttentionLevel = row.signals.count >= rules.highAttentionSignals ? .high : .medium
            return PortfolioAttentionHolding(
                ticker: row.holding.ticker,
                // The company's own name: the reader's 公司名称 choice is
                // applied when the row is drawn, and a news search wants the
                // name filings and wires use.
                name: row.holding.researchName,
                attention: level,
                weight: row.holding.weight,
                portfolioContributionPercent: row.contribution,
                return60DPercent: row.return60D,
                volumeMultiple: row.volumeMultiple,
                distanceFrom52WHighPercent: row.distanceHigh,
                distanceFrom52WLowPercent: row.distanceLow,
                ma200PositionPercent: row.ma200Position,
                signals: row.signals,
                fundamentals: nil,
                thesis: fallbackThesis(for: row),
                sources: []
            )
        }.sorted {
            let lhs = $0.attention == .high ? 2 : 1
            let rhs = $1.attention == .high ? 2 : 1
            if lhs != rhs { return lhs > rhs }
            if $0.signals.count != $1.signals.count { return $0.signals.count > $1.signals.count }
            return abs($0.portfolioContributionPercent ?? 0) > abs($1.portfolioContributionPercent ?? 0)
        }
        let missingHistory = candidates.filter { histories[$0.holding.ticker.uppercased()]?.count ?? 0 < 40 }.count
        let warnings = missingHistory > 0 ? ["\(missingHistory) 只持仓历史行情不足，未由 AI 补全缺失指标。"] : []
        return PortfolioAttentionReport(
            generatedAt: Date(),
            holdingsCount: holdings.count,
            noMaterialChangeCount: holdings.count - selected.count,
            attentionRows: selected,
            warnings: warnings
        )
    }

    private func histories(for holdings: [Holding]) async -> [String: [PortfolioAttentionDailyBar]] {
        await withTaskGroup(of: (String, [PortfolioAttentionDailyBar]?).self) { group in
            for holding in holdings {
                let ticker = holding.ticker
                let currency = holding.quoteCurrency ?? "USD"
                let price = holding.quotePrice
                group.addTask {
                    let bars = try? await LocalMarketDataClient().portfolioAttentionBars(
                        ticker: ticker,
                        currency: currency,
                        referencePrice: price
                    )
                    return (ticker.uppercased(), bars)
                }
            }
            var result: [String: [PortfolioAttentionDailyBar]] = [:]
            for await (ticker, bars) in group {
                if let bars { result[ticker] = bars }
            }
            return result
        }
    }

    private func candidate(holding: Holding, bars: [PortfolioAttentionDailyBar]) -> Candidate {
        let ordered = bars.sorted { $0.date < $1.date }
        let latest = ordered.last
        let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -rules.returnWindowDays, to: Date()) ?? Date()
        let past = ordered.last { bar in
            guard let day = DayDateCodec.date(from: bar.date) else { return false }
            return day <= cutoff
        }
        let return60D = past.flatMap { $0.close > 0 ? (holding.quotePrice / $0.close - 1) * 100 : nil }
        let previousVolumes = ordered.dropLast().suffix(rules.volumeBaselineDays).map(\.volume).filter { $0 > 0 }
        let averageVolume = previousVolumes.isEmpty ? nil : previousVolumes.reduce(0, +) / Double(previousVolumes.count)
        let volumeMultiple: Double? = averageVolume.flatMap { average -> Double? in
            guard average > 0, let latest, latest.volume > 0 else { return nil }
            return latest.volume / average
        }
        let annual = ordered.suffix(252)
        let high = annual.map(\.high).max()
        let low = annual.map(\.low).min()
        let distanceHigh = high.flatMap { $0 > 0 ? ($0 - holding.quotePrice) / $0 * 100 : nil }
        let distanceLow = low.flatMap { $0 > 0 ? (holding.quotePrice - $0) / $0 * 100 : nil }
        let closes = ordered.map(\.close)
        let length = rules.movingAverageDays
        let ma200 = closes.count >= length ? closes.suffix(length).reduce(0, +) / Double(length) : nil
        let ma200Position = ma200.flatMap { $0 > 0 ? (holding.quotePrice / $0 - 1) * 100 : nil }
        var cross: String?
        if closes.count >= length + 1, let ma200 {
            let previousMA = closes.dropLast().suffix(length).reduce(0, +) / Double(length)
            let wasAbove = closes[closes.count - 2] >= previousMA
            let isAbove = holding.quotePrice >= ma200
            if wasAbove != isAbove { cross = isAbove ? "above" : "below" }
        }

        var signals: [PortfolioAttentionSignal] = []
        if let value = return60D, abs(value) >= rules.returnThreshold {
            signals.append(.init(kind: "price_60d", label: "\(rules.returnWindowDays)D \(Self.signedPercent(value))", direction: value >= 0 ? "positive" : "negative", value: value))
        }
        if let value = volumeMultiple, value >= rules.volumeMultiple {
            signals.append(.init(kind: "volume_spike", label: "成交量 \(String(format: "%.1f", value))×", direction: "neutral", value: value))
        }
        let near = -rules.nearExtremePercent...rules.nearExtremePercent
        if let value = distanceHigh, near.contains(value) {
            signals.append(.init(kind: "near_52w_high", label: "距 52 周高点 \(String(format: "%.1f", abs(value)))%", direction: "positive", value: value))
        } else if let value = distanceLow, near.contains(value) {
            signals.append(.init(kind: "near_52w_low", label: "距 52 周低点 \(String(format: "%.1f", abs(value)))%", direction: "negative", value: value))
        }
        if let value = holding.todayChangePercent, abs(value) >= rules.todayMoveThreshold {
            signals.append(.init(kind: "today_move", label: "今日 \(Self.signedPercent(value))", direction: value >= 0 ? "positive" : "negative", value: value))
        }
        if let cross {
            signals.append(.init(kind: "ma_200_cross", label: cross == "above" ? "突破 \(length)D 均线" : "跌破 \(length)D 均线", direction: cross == "above" ? "positive" : "negative", value: ma200Position ?? 0))
        }
        let contribution = holding.todayChangePercent.map { holding.weight * $0 }
        return Candidate(
            holding: holding,
            return60D: return60D,
            volumeMultiple: volumeMultiple,
            distanceHigh: distanceHigh,
            distanceLow: distanceLow,
            ma200Position: ma200Position,
            ma200Cross: cross,
            contribution: contribution,
            signals: signals
        )
    }

    private func fallbackThesis(for row: Candidate) -> PortfolioAttentionThesis {
        return PortfolioAttentionThesis(
            stance: PortfolioAttentionThesis.priceStance(row.signals),
            basis: .price,
            confidence: .none,
            whatChanged: row.signals.map(\.label).joined(separator: "、"),
            whyItMatters: "这一变化值得核对，但在可靠公司来源确认前，不应视为基本面结论。",
            supportingEvidence: row.signals.map(\.label),
            counterEvidence: ["信号可能来自市场或板块波动，而非公司级催化剂。"],
            risks: ["公司级催化剂尚未验证"],
            watchNext: ["公司公告与业绩", "成交量是否持续", "\(rules.movingAverageDays) 日均线"],
            riskFlags: []
        )
    }

    private static func signedPercent(_ value: Double) -> String {
        String(format: "%@%.1f%%", value >= 0 ? "+" : "", value)
    }
}

struct PortfolioEventResearchClient {
    /// Leads for every holding in one pass, so rate-limited feeds are asked
    /// once for the portfolio rather than once per holding.
    func recentSources(for rows: [PortfolioAttentionHolding]) async -> [String: [PortfolioAttentionSource]] {
        let language = ContentLanguage.current
        return await NewsSourceHub().sources(for: rows.map {
            NewsQuery(ticker: $0.ticker, name: $0.name, language: language)
        })
    }

    /// The opening of the two most trustworthy articles per holding, read
    /// in full rather than judged by headline. Filings are left out: their
    /// first pages are a cover sheet. A feed's own summary stands in for an
    /// article that cannot be fetched.
    func excerpts(for rows: [PortfolioAttentionHolding]) async -> [String: [SecurityResearchDocument]] {
        await withTaskGroup(of: (String, [SecurityResearchDocument]).self) { group in
            for row in rows {
                group.addTask {
                    let leads = Array(SecurityDebateResearch.candidates(row.sources)
                        .filter { $0.tier != "filing" }.prefix(4))
                    guard !leads.isEmpty else { return (row.ticker, []) }
                    var documents = await SecurityDebateResearch()
                        .documents(sources: leads, ticker: row.ticker, name: row.name)
                    for lead in leads where documents.count < 2 && !documents.contains(where: { $0.source.id == lead.id }) {
                        if let summary = lead.summary, summary.count >= 80 {
                            documents.append(SecurityResearchDocument(source: lead, text: summary))
                        }
                    }
                    return (row.ticker, documents.prefix(2).map { document in
                        SecurityResearchDocument(source: document.source, text: String(document.text.prefix(1_500)))
                    })
                }
            }
            var result: [String: [SecurityResearchDocument]] = [:]
            for await (ticker, documents) in group { result[ticker] = documents }
            return result
        }
    }

    /// The most direct and most recent first, and few enough that the
    /// model reads each one. Undated reference data is kept.
    static func leading(_ sources: [PortfolioAttentionSource], limit: Int = 24) -> [PortfolioAttentionSource] {
        let ranks = ["filing": 0, "primary": 1, "wire": 2, "media": 3]
        return Array(sources.enumerated().sorted { left, right in
            let l = ranks[left.element.tier, default: 3], r = ranks[right.element.tier, default: 3]
            if l != r { return l < r }
            let ld = left.element.publishedAt ?? .distantFuture, rd = right.element.publishedAt ?? .distantFuture
            return ld != rd ? ld > rd : left.offset < right.offset
        }.map(\.element).prefix(limit))
    }
}

struct AttentionThesisEnvelope: Decodable {
    let theses: [AttentionThesisCandidate]
}

struct AttentionThesisCandidate: Decodable {
    let ticker: String
    /// Written by older reports; the direction now comes from the catalyst.
    let stance: String?
    let catalystDirection: String?
    let whatChanged: String
    let whyItMatters: String
    let supportingEvidence: [String]
    let counterEvidence: [String]
    let risks: [String]
    let watchNext: [String]
    let riskFlags: [String]
    let companySpecificCatalyst: Bool
    let catalystConfirmed: Bool
    let catalystIsRecent: Bool
    let evidenceSourceIDs: [String]
    let severeUnresolvedRisk: Bool

    enum CodingKeys: String, CodingKey {
        case ticker, stance, risks
        case catalystDirection = "catalyst_direction"
        case whatChanged = "what_changed"
        case whyItMatters = "why_it_matters"
        case supportingEvidence = "supporting_evidence"
        case counterEvidence = "counter_evidence"
        case watchNext = "watch_next"
        case riskFlags = "risk_flags"
        case companySpecificCatalyst = "company_specific_catalyst"
        case catalystConfirmed = "catalyst_confirmed"
        case catalystIsRecent = "catalyst_is_recent"
        case evidenceSourceIDs = "evidence_source_ids"
        case severeUnresolvedRisk = "severe_unresolved_risk"
    }
}
