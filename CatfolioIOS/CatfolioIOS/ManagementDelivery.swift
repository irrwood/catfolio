import Foundation

enum ManagementDeliveryStatus: String, Codable, CaseIterable, Sendable {
    case delivered, partial, missed, pending

    var title: String {
        switch self {
        case .delivered: L10n.text("已兑现")
        case .partial: L10n.text("部分兑现")
        case .missed: L10n.text("未兑现")
        case .pending: L10n.text("待验证")
        }
    }

    /// Partial means some independently testable targets passed and some failed.
    /// Missing evidence never counts as failure or earns partial credit.
    static func aggregate(_ values: [Self]) -> Self {
        guard !values.isEmpty, !values.contains(.pending) else { return .pending }
        if values.allSatisfy({ $0 == .delivered }) { return .delivered }
        if values.allSatisfy({ $0 == .missed }) { return .missed }
        return .partial
    }
}

struct ManagementDocument: Codable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case transcript, financials }
    let id: String
    let kind: Kind
    let fiscalYear: Int
    let period: String
    let published: String // ISO calendar date, never a guessed filing date
    let title: String
    let url: URL
    let text: String
    let facts: [ManagementFact]
    var rawFinancialJSON: Data? = nil
}

struct ManagementFact: Codable, Identifiable, Sendable {
    let id: String
    let metric: String
    let fiscalYear: Int
    let period: String
    let periodEnd: String
    let currency: String
    let value: Double
    let sourceID: String
    let quote: String
}

/// The model extracts target language; the rule engine reads numeric literals
/// itself. No model-produced actual value or numeric verdict is accepted.
struct ManagementTarget: Codable, Sendable {
    let metric: String
    let fiscalYear: Int
    let period: String
    let currency: String
    let basis: String
    let scope: String
    let comparison: String // atLeast, atMost, between
    let lower: String // exact numeric token from the quote, empty if absent
    let upper: String
    let scale: String // units, million, billion
}

struct ManagementPromise: Codable, Identifiable, Sendable {
    var id: String
    var sourceID: String
    let title: String
    let quote: String
    let deadline: String // explicit ISO deadline; empty if not resolvable
    let numeric: Bool
    let targets: [ManagementTarget]
}

struct ManagementEvidence: Codable, Sendable {
    let sourceID: String
    let quote: String
    let explanation: String
}

struct ManagementAssessment: Codable, Identifiable, Sendable {
    var id: String { promise.id }
    let promise: ManagementPromise
    let status: ManagementDeliveryStatus
    let explanation: String
    let evidence: [ManagementEvidence]
    let method: String // rules or localAI
}

struct ManagementDeliveryReport: Codable, Sendable {
    let ticker: String
    let language: String
    let generatedAt: Date
    let requestedQuarters: Int
    let transcriptCount: Int
    let summary: String
    let assessments: [ManagementAssessment]
    let warnings: [String]
}

struct ManagementDeliveryArchive: Codable, Sendable {
    var schemaVersion = 1
    let ticker: String
    let downloadedAt: Date
    let requestedQuarters: Int
    let documents: [ManagementDocument]
    var report: ManagementDeliveryReport?
}

enum ManagementDeliveryRules {
    static let numericMetrics: Set<String> = ["revenue", "grossProfit", "operatingIncome", "netIncome", "eps", "epsDiluted", "operatingCashFlow", "freeCashFlow"]

    static func metricTitle(_ metric: String) -> String {
        switch metric {
        case "revenue": L10n.text("收入")
        case "grossProfit": L10n.text("毛利润")
        case "operatingIncome": L10n.text("营业利润")
        case "netIncome": L10n.text("净利润")
        case "eps": L10n.text("每股收益")
        case "epsDiluted": L10n.text("稀释每股收益")
        case "operatingCashFlow": L10n.text("经营现金流")
        case "freeCashFlow": L10n.text("自由现金流")
        default: metric
        }
    }
    static func isEligible(_ holding: Holding) -> Bool {
        guard HoldingSecurityKind.classify(holding) != .fund,
              let entry = (try? CompanyReferenceCatalog.bundled.get())?.entry(brokerSymbol: holding.ticker)
        else { return false }
        return entry.market == "US" && ["COMPANY_SECURITY", "EQUITY_SECURITY"].contains(entry.instrumentType.uppercased())
    }

    static func isoDate(_ text: String) -> String? {
        let day = String(text.prefix(10))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: day), formatter.string(from: date) == day else { return nil }
        return day
    }

    static func today(_ date: Date) -> String {
        String(ISO8601DateFormatter().string(from: date).prefix(10))
    }

    static func containsQuote(_ quote: String, in text: String) -> Bool {
        let normalize: (String) -> String = { $0.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ") }
        let candidate = normalize(quote)
        return candidate.count >= 12 && normalize(text).contains(candidate)
    }

    static func number(_ token: String, quote: String, scale: String) -> Double? {
        guard !token.isEmpty,
              token.range(of: #"^-?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?$"#, options: .regularExpression) != nil,
              quote.range(of: "(?<![0-9.,+-])" + NSRegularExpression.escapedPattern(for: token) + "(?![0-9]|[.,][0-9])", options: .regularExpression) != nil,
              let value = Double(token.replacingOccurrences(of: ",", with: "")), value.isFinite else { return nil }
        let multiplier: Double
        switch scale {
        case "units": multiplier = 1
        case "million":
            guard quote.range(of: #"(?i)\bmillion\b"#, options: .regularExpression) != nil else { return nil }
            multiplier = 1e6
        case "billion":
            guard quote.range(of: #"(?i)\bbillion\b"#, options: .regularExpression) != nil else { return nil }
            multiplier = 1e9
        default: return nil
        }
        return value * multiplier
    }

    static func evaluate(_ promise: ManagementPromise, documents: [ManagementDocument], now: Date = .now) -> ManagementAssessment {
        func pending(_ message: String) -> ManagementAssessment {
            .init(promise: promise, status: .pending, explanation: message, evidence: [], method: "rules")
        }
        guard let original = documents.first(where: { $0.id == promise.sourceID && $0.kind == .transcript }),
              containsQuote(promise.quote, in: original.text) else {
            return pending(L10n.text("原话无法在下载的文字稿中核对。"))
        }
        guard promise.numeric, !promise.targets.isEmpty else {
            return pending(L10n.text("尚无可按相同口径核对的数字目标。"))
        }
        var statuses: [ManagementDeliveryStatus] = []
        var evidence: [ManagementEvidence] = []
        for target in promise.targets {
            // Standard statements cannot verify adjusted EPS, constant-currency
            // growth, segments, or a different accounting basis.
            guard target.basis == "GAAP", target.scope == "company",
                  numericMetrics.contains(target.metric),
                  ["Q1", "Q2", "Q3", "Q4", "FY"].contains(target.period),
                  !target.currency.isEmpty else { statuses.append(.pending); continue }
            if ["eps", "epsDiluted"].contains(target.metric), target.scale != "units" {
                statuses.append(.pending); continue
            }
            let candidates = documents.filter { $0.kind == .financials && $0.published > original.published && $0.published <= today(now) }
                .flatMap { doc in doc.facts.filter {
                    $0.metric == target.metric && $0.fiscalYear == target.fiscalYear && $0.period == target.period
                        && $0.currency == target.currency && $0.periodEnd > original.published && $0.value.isFinite
                }.map { (doc, $0) } }
            // Conflicting amended/duplicate values need review, not arbitrary selection.
            guard let (document, fact) = candidates.first,
                  candidates.allSatisfy({ $0.1.value == fact.value }) else { statuses.append(.pending); continue }
            if !promise.deadline.isEmpty {
                guard let deadline = isoDate(promise.deadline), deadline >= fact.periodEnd else { statuses.append(.pending); continue }
            }
            let lower = number(target.lower, quote: promise.quote, scale: target.scale)
            let upper = number(target.upper, quote: promise.quote, scale: target.scale)
            let met: Bool
            switch target.comparison {
            case "atLeast": guard let lower else { statuses.append(.pending); continue }; met = fact.value >= lower
            case "atMost": guard let upper else { statuses.append(.pending); continue }; met = fact.value <= upper
            case "between":
                guard let lower, let upper, lower <= upper else { statuses.append(.pending); continue }
                met = fact.value >= lower && fact.value <= upper
            default: statuses.append(.pending); continue
            }
            statuses.append(met ? .delivered : .missed)
            func amount(_ value: Double) -> String {
                if ["eps", "epsDiluted"].contains(target.metric) {
                    return "\(value.formatted(.number.precision(.fractionLength(0...4)))) \(fact.currency)"
                }
                return DisplayFormat.compactMoney(value, currency: fact.currency, precision: .statement)
            }
            let bound: String
            switch target.comparison {
            case "atLeast": bound = "≥ \(amount(lower!))"
            case "atMost": bound = "≤ \(amount(upper!))"
            default: bound = "\(amount(lower!)) – \(amount(upper!))"
            }
            evidence.append(.init(sourceID: document.id, quote: fact.quote,
                explanation: L10n.text("\(metricTitle(target.metric))实际为 \(amount(fact.value))，原目标为 \(bound)。")
                    + " FY\(target.fiscalYear) \(target.period) · \((met ? ManagementDeliveryStatus.delivered : .missed).title)"))
        }
        let status = ManagementDeliveryStatus.aggregate(statuses)
        return .init(promise: promise, status: status,
            explanation: status == .pending ? L10n.text("期限未到、资料缺失或口径不一致；暂不判定。") : L10n.text("按原始数字目标与同财年、同期间、同币种的财报结果逐项核对。"),
            evidence: evidence, method: "rules")
    }
}
