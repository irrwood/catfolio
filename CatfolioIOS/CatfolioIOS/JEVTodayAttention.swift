import SwiftUI
import CryptoKit

// MARK: - The API

/// Where Jev is called. Both carry TypeSafe's own request and answer
/// shapes: OpenRouter's Decisions endpoint takes them as they are, Cloudflare
/// wraps them in its `input` and `result` envelope.
enum JEVProvider: String, CaseIterable, Identifiable, Codable {
    case openRouter
    case cloudflare

    static let storageKey = "catfolio.jev.provider"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .cloudflare: "Cloudflare"
        }
    }

    var model: String {
        switch self {
        // The alias that always follows the newest Jev.
        case .openRouter: "~typesafe/jev-latest"
        case .cloudflare: "typesafe/jev"
        }
    }

    var isConfigured: Bool {
        switch self {
        case .openRouter: LocalServiceKeys.hasOpenRouterKey
        case .cloudflare: LocalServiceKeys.hasJEVCredentials
        }
    }

    /// Where to set it up, for a page that is missing it.
    var setupHint: String {
        switch self {
        case .openRouter: L10n.text("在 设置 › 服务商 › OpenRouter 中填写 API Key 后即可运行。")
        case .cloudflare: L10n.text("在 设置 › 服务商 › Jev (Cloudflare) 中填写 Account ID 和 API Token 后即可运行。")
        }
    }

    /// The reader's choice; until they make one, whichever is set up,
    /// OpenRouter first.
    static var current: JEVProvider {
        if let raw = UserDefaults.standard.string(forKey: storageKey), let chosen = JEVProvider(rawValue: raw) {
            return chosen
        }
        return JEVProvider.cloudflare.isConfigured && !JEVProvider.openRouter.isConfigured ? .cloudflare : .openRouter
    }
}

/// TypeSafe's Jev: one state, several typed questions, typed answers with
/// calibrated probabilities.
struct JEVClient {
    static var model: String { JEVProvider.current.model }

    enum JEVError: LocalizedError {
        case missingKey(JEVProvider)
        case unauthorized(JEVProvider)
        /// Out of prepaid credit. On Cloudflare Jev is a third-party model,
        /// paid from AI Gateway credits (Unified Billing), not the Workers AI
        /// allowance; on OpenRouter it is the account balance.
        case noCredits(JEVProvider, String)
        case rateLimited
        case http(Int, String)
        case malformed

        var errorDescription: String? {
            switch self {
            case let .missingKey(provider): provider.setupHint
            case .unauthorized(.cloudflare): L10n.text("Cloudflare 拒绝了这个 API Token，请在 设置 › 服务商 中检查它是否有 Workers AI 权限。")
            case .unauthorized(.openRouter): L10n.text("OpenRouter 拒绝了这个 API Key，请在 设置 › 服务商 › OpenRouter 中检查。")
            case let .noCredits(.cloudflare, detail):
                L10n.text("Cloudflare 账户的 AI 额度不足（402）。Jev 是第三方模型，按 Unified Billing 从预充值额度扣费，不走 Workers AI 免费额度。请在 Cloudflare 控制台 › AI › AI Gateway › Credits Available › Manage 充值后再试。")
                    + (detail.isEmpty ? "" : "\n\(detail)")
            case let .noCredits(.openRouter, detail):
                L10n.text("OpenRouter 余额不足（402）。请在 openrouter.ai/credits 充值后再试。")
                    + (detail.isEmpty ? "" : "\n\(detail)")
            case .rateLimited: L10n.text("请求过于频繁，请稍后再试。")
            case let .http(code, message): L10n.text("Jev 服务返回错误 \(code)：\(message)")
            case .malformed: L10n.text("Jev 的回复无法解析。")
            }
        }
    }

    struct ChoiceAnswer {
        let choice: String
        let probabilities: [String: Double]
        let confidence: Double
    }

    struct ScoreAnswer {
        let score: Double
        let confidence: Double
    }

    struct Answers {
        let choices: [String: ChoiceAnswer]
        let scores: [String: ScoreAnswer]
        let nouls: [String: Double]
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 40
        return URLSession(configuration: configuration)
    }()

    let provider: JEVProvider
    var apiToken: String?
    var accountID: String

    init(provider: JEVProvider = .current, apiToken: String? = nil, accountID: String? = nil) {
        self.provider = provider
        let storedKey = provider == .cloudflare ? LocalServiceKeys.cloudflareAIToken : LocalServiceKeys.openRouter
        self.apiToken = (apiToken ?? KeychainStore.string(for: storedKey))?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountID = (accountID ?? LocalServiceKeys.cloudflareAccountID).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        !(apiToken ?? "").isEmpty && (provider == .openRouter || !accountID.isEmpty)
    }

    /// `state` and `questions` are JSON objects in TypeSafe's own shape.
    func ask(state: [String: Any], questions: [String: Any]) async throws -> Answers {
        guard isConfigured, let apiToken else { throw JEVError.missingKey(provider) }
        let url: URL?
        let payload: [String: Any]
        switch provider {
        case .openRouter:
            // The Decisions endpoint sits beside the API's /v1, not under it.
            url = URL(string: "https://openrouter.ai/api/alpha/decisions")
            payload = ["model": provider.model, "state": state, "questions": questions]
        case .cloudflare:
            url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountID)/ai/run")
            payload = ["model": provider.model, "input": ["state": state, "questions": questions]]
        }
        guard let url else { throw JEVError.missingKey(provider) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider == .openRouter {
            request.setValue("https://catfolio.app", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Catfolio", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await Self.session.recordedData(for: request)
        guard let http = response as? HTTPURLResponse else { throw JEVError.malformed }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw JEVError.unauthorized(provider)
        case 402: throw JEVError.noCredits(provider, Self.errorMessage(body) ?? "")
        case 429: throw JEVError.rateLimited
        default:
            throw JEVError.http(http.statusCode, Self.errorMessage(body) ?? String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        guard let body else {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw JEVError.malformed
        }
        if body["success"] as? Bool == false {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .providerRejected)
            throw JEVError.http(http.statusCode, Self.errorMessage(body) ?? "")
        }
        do {
            return try Self.answers(from: body)
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .missingRequiredFields)
            throw error
        }
    }

    /// The typed answers out of a reply. Cloudflare's REST envelope puts the
    /// model's answer under `result`; a Worker binding returns it bare.
    static func answers(from body: [String: Any]?) throws -> Answers {
        let result = (body?["result"] as? [String: Any]) ?? body
        guard let answers = result?["answers"] as? [String: Any] else { throw JEVError.malformed }
        var choices: [String: ChoiceAnswer] = [:]
        var scores: [String: ScoreAnswer] = [:]
        var nouls: [String: Double] = [:]
        for (name, value) in answers {
            guard let answer = value as? [String: Any], let type = answer["type"] as? String else { continue }
            switch type {
            case "choice":
                guard let choice = answer["choice"] as? String else { continue }
                let probabilities = (answer["probabilities"] as? [String: Any] ?? [:])
                    .compactMapValues { ($0 as? NSNumber)?.doubleValue }
                choices[name] = ChoiceAnswer(choice: choice, probabilities: probabilities,
                                             confidence: (answer["confidence"] as? NSNumber)?.doubleValue ?? 0)
            case "score":
                guard let score = (answer["score"] as? NSNumber)?.doubleValue else { continue }
                scores[name] = ScoreAnswer(score: score,
                                           confidence: (answer["confidence"] as? NSNumber)?.doubleValue ?? 0)
            case "noul":
                if let noul = (answer["noul"] as? NSNumber)?.doubleValue { nouls[name] = noul }
            default:
                continue
            }
        }
        return Answers(choices: choices, scores: scores, nouls: nouls)
    }

    private static func errorMessage(_ body: [String: Any]?) -> String? {
        // OpenRouter: {"error": {"code", "message"}}.
        if let error = body?["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        // Cloudflare: {"errors": [{"code", "message"}]}.
        if let errors = body?["errors"] as? [[String: Any]], !errors.isEmpty {
            return errors.compactMap { $0["message"] as? String }.joined(separator: "；")
        }
        return (body?["detail"] as? String) ?? (body?["message"] as? String)
    }

    /// A one-question call, for the check in 服务商.
    func test() async throws {
        _ = try await ask(state: ["message": "Connection check."],
                          questions: ["ok": ["type": "noul", "instructions": "This is a connection check."]])
    }
}

// MARK: - What Jev is shown

/// Where the options market is positioned: the heaviest put strike below
/// the price (support), the heaviest call strike above it (resistance), and
/// the balance between the two, over the next 30 days of expiries.
struct JEVOptionsFacts: Codable, Equatable {
    var callWall: Double?
    var putWall: Double?
    /// Percent from the price to the wall; positive is above the price.
    var callWallDistance: Double?
    var putWallDistance: Double?
    /// Total put open interest over total call open interest.
    var putCallRatio: Double?
    var asOf: String
}

/// The past year's volume profile: the price that traded most (POC) and the
/// band holding 70% of the volume (the value area).
struct JEVVolumeFacts: Codable, Equatable {
    var pointOfControl: Double
    var valueAreaHigh: Double
    var valueAreaLow: Double
    var priceVersusPOC: Double
    /// "above", "inside" or "below" the value area.
    var position: String
}

/// Valuation worked out from the company's own SEC filings and today's
/// price: no paid feed, and nothing to rate-limit beyond SEC's own fair use.
struct JEVValuationFacts: Codable, Equatable {
    /// Market value over the last twelve months' net income; nil when the
    /// company made a loss.
    var pe: Double?
    /// Market value over the last twelve months' revenue.
    var ps: Double?
    var growthPercent: Double?
    /// "net income" or "revenue": which line the growth is measured on.
    var growthBasis: String
    /// P/E over growth, when both are positive.
    var peg: Double?
    /// The latest period the filings cover.
    var throughPeriod: String

    /// From SEC statements: trailing twelve months = the latest fiscal year,
    /// plus the quarters reported since, less the same quarters a year
    /// earlier. The market value is today's price times the diluted shares.
    static func make(_ financials: CompanyFinancialsData, price: Double) -> JEVValuationFacts? {
        guard price > 0, let shares = financials.sharesOutstanding, shares > 0 else { return nil }
        let usd = financials.income.filter { $0.currency.uppercased() == "USD" }
        guard let revenue = trailing(usd, \.revenue), revenue.current > 0 else { return nil }
        let marketValue = price * shares
        let netIncome = trailing(usd) { $0.netIncome }
        let pe = netIncome.flatMap { $0.current > 0 ? marketValue / $0.current : nil }
        let growth: (Double, String)? = {
            if let netIncome, let prior = netIncome.prior, prior > 0, netIncome.current > 0 {
                return ((netIncome.current / prior - 1) * 100, "net income")
            }
            if let prior = revenue.prior, prior > 0 {
                return ((revenue.current / prior - 1) * 100, "revenue")
            }
            return nil
        }()
        return JEVValuationFacts(
            pe: pe,
            ps: marketValue / revenue.current,
            growthPercent: growth?.0,
            growthBasis: growth?.1 ?? "revenue",
            peg: pe.flatMap { pe in growth.flatMap { $0.0 > 0 ? pe / $0.0 : nil } },
            throughPeriod: revenue.through
        )
    }

    private static func consecutiveQuarters(_ quarters: [IncomeStatementPeriod],
                                            _ line: (IncomeStatementPeriod) -> Double?)
        -> (current: Double, prior: Double?, through: String)? {
        func isRun(_ run: ArraySlice<IncomeStatementPeriod>) -> Bool {
            let dates = run.compactMap { DayDateCodec.date(from: $0.periodEnd) }
            guard dates.count == run.count, run.count == 4 else { return false }
            return zip(dates, dates.dropFirst()).allSatisfy { later, earlier in
                (70...110).contains(later.timeIntervalSince(earlier) / 86_400)
            }
        }
        let latestFour = quarters.prefix(4)
        guard isRun(latestFour), let latest = latestFour.first else { return nil }
        let values = latestFour.compactMap(line)
        guard values.count == 4 else { return nil }
        let earlierFour = quarters.dropFirst(4).prefix(4)
        var prior: Double?
        if isRun(earlierFour), let bridge = DayDateCodec.date(from: latestFour.last!.periodEnd),
           let next = DayDateCodec.date(from: earlierFour.first!.periodEnd),
           (70...110).contains(bridge.timeIntervalSince(next) / 86_400) {
            let earlierValues = earlierFour.compactMap(line)
            if earlierValues.count == 4 { prior = earlierValues.reduce(0, +) }
        }
        return (values.reduce(0, +), prior, latest.periodEnd)
    }

    /// The last twelve months of one line, and the twelve months before.
    static func trailing(_ income: [IncomeStatementPeriod],
                         _ line: (IncomeStatementPeriod) -> Double?) -> (current: Double, prior: Double?, through: String)? {
        let annual = income.filter { $0.kind == .annual }.sorted { $0.periodEnd > $1.periodEnd }
        let quarters = income.filter { $0.kind == .quarterly }.sorted { $0.periodEnd > $1.periodEnd }
        // Four back-to-back quarters, where a source reports every quarter
        // including the fourth: add them up, and the four before for the
        // year earlier.
        if let summed = consecutiveQuarters(quarters, line) { return summed }
        guard let latest = annual.first, let latestValue = line(latest) else { return nil }
        func yearBefore(_ period: IncomeStatementPeriod, in list: [IncomeStatementPeriod]) -> IncomeStatementPeriod? {
            guard let end = DayDateCodec.date(from: period.periodEnd) else { return nil }
            return list.first { candidate in
                guard let other = DayDateCodec.date(from: candidate.periodEnd) else { return false }
                return abs(end.timeIntervalSince(other) - 365 * 86_400) <= 20 * 86_400
            }
        }
        // Quarters since the fiscal year, each matched to its quarter a year
        // earlier; one unmatched and the year alone stands.
        let since = quarters.filter { $0.periodEnd > latest.periodEnd }
        let earlier = since.map { yearBefore($0, in: quarters) }
        let priorAnnual = yearBefore(latest, in: annual).flatMap(line)
        guard !since.isEmpty, earlier.allSatisfy({ $0 != nil }) else {
            return (latestValue, priorAnnual, latest.periodEnd)
        }
        let sinceValues = since.compactMap(line)
        let earlierValues = earlier.compactMap { $0.flatMap(line) }
        guard sinceValues.count == since.count, earlierValues.count == since.count else {
            return (latestValue, priorAnnual, latest.periodEnd)
        }
        let current = latestValue + sinceValues.reduce(0, +) - earlierValues.reduce(0, +)
        // The year before, the same way: its fiscal year, plus those earlier
        // quarters, less theirs a year before again.
        let twoBack = earlier.map { yearBefore($0!, in: quarters) }
        var prior: Double?
        if let priorAnnual, twoBack.allSatisfy({ $0 != nil }) {
            let twoBackValues = twoBack.compactMap { $0.flatMap(line) }
            if twoBackValues.count == since.count {
                prior = priorAnnual + earlierValues.reduce(0, +) - twoBackValues.reduce(0, +)
            }
        }
        return (current, prior, since.first?.periodEnd ?? latest.periodEnd)
    }
}

/// The semiconductor sentiment page's reading, for the holdings it covers.
struct JEVSectorFacts: Codable, Equatable {
    var score: Int?
    var regime: String
    var volatilityChangePercent: Double?
    var priceChangePercent: Double?
    var asOf: String
}

/// The backdrop every holding shares, fetched once per run.
struct JEVMarketFacts: Codable, Equatable {
    var vix: Double?
    var vix20DAverage: Double?
    /// Where today's VIX sits in its past year, 0 to 100.
    var vixPercentile1Y: Double?
    var sp500Return20D: Double?
    var sp500Return60D: Double?
    var sp500VersusMA200: Double?
    var tenYearYield: Double?
    var tenYearChange20DBasisPoints: Double?

    var state: [String: Any] {
        [
            "vix": JEVHoldingFacts.rounded(vix),
            "vix_20d_average": JEVHoldingFacts.rounded(vix20DAverage),
            "vix_percentile_1y": JEVHoldingFacts.rounded(vixPercentile1Y),
            "sp500_return_20d_pct": JEVHoldingFacts.rounded(sp500Return20D),
            "sp500_return_60d_pct": JEVHoldingFacts.rounded(sp500Return60D),
            "sp500_vs_200d_average_pct": JEVHoldingFacts.rounded(sp500VersusMA200),
            "us_10y_yield_pct": JEVHoldingFacts.rounded(tenYearYield),
            "us_10y_yield_change_20d_bp": JEVHoldingFacts.rounded(tenYearChange20DBasisPoints),
        ]
    }

    static let definitions: [String: String] = [
        "vix": "The S&P 500 implied volatility index. Around 12–16 is calm, above 25 is stressed.",
        "vix_percentile_1y": "Where today's VIX sits within its past year, 0 lowest to 100 highest.",
        "sp500_vs_200d_average_pct": "How far the S&P 500 is above (positive) or below (negative) its 200-day average.",
        "us_10y_yield_change_20d_bp": "Change in the 10-year Treasury yield over 20 sessions, in basis points. Rising yields tighten conditions.",
    ]

    /// VIX and 10-year yield from their closes by day, the S&P 500 from its
    /// daily bars.
    static func make(vix: [String: Double], tenYear: [String: Double], sp500: [PortfolioAttentionDailyBar]) -> JEVMarketFacts {
        let vixCloses = vix.sorted { $0.key < $1.key }.map(\.value)
        let yields = tenYear.sorted { $0.key < $1.key }.map(\.value)
        let spy = sp500.sorted { $0.date < $1.date }.map(\.close)
        func back(_ values: [Double], _ sessions: Int) -> Double? {
            guard values.count > sessions, let last = values.last, values[values.count - 1 - sessions] > 0 else { return nil }
            return (last / values[values.count - 1 - sessions] - 1) * 100
        }
        let lastVIX = vixCloses.last
        let year = vixCloses.suffix(252)
        let percentile = lastVIX.flatMap { value -> Double? in
            guard !year.isEmpty else { return nil }
            return Double(year.filter { $0 < value }.count) / Double(year.count) * 100
        }
        let ma200 = spy.count >= 200 ? spy.suffix(200).reduce(0, +) / 200 : nil
        // ^TNX quotes the yield times ten on some feeds; a value above 20 is that.
        let scale = (yields.last ?? 0) > 20 ? 0.1 : 1
        return JEVMarketFacts(
            vix: lastVIX,
            vix20DAverage: vixCloses.count >= 20 ? vixCloses.suffix(20).reduce(0, +) / 20 : nil,
            vixPercentile1Y: percentile,
            sp500Return20D: back(spy, 20),
            sp500Return60D: back(spy, 60),
            sp500VersusMA200: ma200.flatMap { m in spy.last.map { ($0 / m - 1) * 100 } },
            tenYearYield: yields.last.map { $0 * scale },
            tenYearChange20DBasisPoints: yields.count > 20 ? (yields[yields.count - 1] - yields[yields.count - 21]) * scale * 100 : nil
        )
    }
}

/// One holding's numbers, as Jev reads them. Percentages throughout; nothing
/// that identifies the account, and no amounts or share counts.
struct JEVHoldingFacts: Codable, Equatable {
    var ticker: String
    var name: String
    var sector: String?
    var weightPercent: Double
    var unrealizedGainPercent: Double
    var todayChangePercent: Double?
    var return5D: Double?
    var return20D: Double?
    var return60D: Double?
    var return120D: Double?
    var return250D: Double?
    var versusMA20: Double?
    var versusMA50: Double?
    var versusMA200: Double?
    var ma50AboveMA200: Bool?
    var rsi14: Double?
    var volatility20DAnnualized: Double?
    var fromHigh52W: Double?
    var fromLow52W: Double?
    var maxDrawdown1Y: Double?
    var volumeVersus20DAverage: Double?
    var relativeTo60DSPY: Double?
    var sessions: Int
    var options: JEVOptionsFacts?
    var volume: JEVVolumeFacts?
    var valuation: JEVValuationFacts?
    var sectorSentiment: JEVSectorFacts?
    var market: JEVMarketFacts?

    /// Two decimals written as decimals: a Double serialises 56.26 as
    /// 56.259999999999998, which is noise for the model to read.
    static func rounded(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return NSDecimalNumber(string: String(format: "%.2f", value))
    }

    static func make(holding: Holding, bars: [PortfolioAttentionDailyBar], spy: [PortfolioAttentionDailyBar]) -> JEVHoldingFacts {
        let ordered = bars.sorted { $0.date < $1.date }
        // Today's quote stands for the last close, as the attention scan does.
        var closes = ordered.map(\.close)
        if holding.quotePrice > 0, !closes.isEmpty { closes[closes.count - 1] = holding.quotePrice }
        let price = closes.last ?? holding.quotePrice

        func back(_ sessions: Int) -> Double? {
            guard closes.count > sessions, price > 0 else { return nil }
            let then = closes[closes.count - 1 - sessions]
            return then > 0 ? (price / then - 1) * 100 : nil
        }
        func versusAverage(_ length: Int) -> Double? {
            guard closes.count >= length else { return nil }
            let average = closes.suffix(length).reduce(0, +) / Double(length)
            return average > 0 ? (price / average - 1) * 100 : nil
        }
        let ma50 = closes.count >= 50 ? closes.suffix(50).reduce(0, +) / 50 : nil
        let ma200 = closes.count >= 200 ? closes.suffix(200).reduce(0, +) / 200 : nil

        // Wilder's RSI over 14 sessions.
        var rsi: Double?
        if closes.count > 15 {
            let changes = zip(closes.dropFirst(), closes).map { $0 - $1 }
            var gain = changes.prefix(14).map { max($0, 0) }.reduce(0, +) / 14
            var loss = changes.prefix(14).map { max(-$0, 0) }.reduce(0, +) / 14
            for change in changes.dropFirst(14) {
                gain = (gain * 13 + max(change, 0)) / 14
                loss = (loss * 13 + max(-change, 0)) / 14
            }
            rsi = loss == 0 ? 100 : 100 - 100 / (1 + gain / loss)
        }

        var volatility: Double?
        if closes.count > 21 {
            let recent = Array(closes.suffix(21))
            let returns = zip(recent.dropFirst(), recent).compactMap { $1 > 0 && $0 > 0 ? log($0 / $1) : nil }
            if returns.count > 2 {
                let mean = returns.reduce(0, +) / Double(returns.count)
                let variance = returns.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(returns.count - 1)
                volatility = variance.squareRoot() * 252.0.squareRoot() * 100
            }
        }

        let year = ordered.suffix(252)
        let high = year.map(\.high).max()
        let low = year.map(\.low).min()
        var peak = 0.0
        var drawdown = 0.0
        for close in closes.suffix(252) {
            peak = max(peak, close)
            if peak > 0 { drawdown = min(drawdown, (close / peak - 1) * 100) }
        }

        let volumes = ordered.map(\.volume)
        var volumeMultiple: Double?
        if volumes.count > 21, let last = volumes.last, last > 0 {
            let baseline = volumes.dropLast().suffix(20).filter { $0 > 0 }
            if !baseline.isEmpty { volumeMultiple = last / (baseline.reduce(0, +) / Double(baseline.count)) }
        }

        let spyCloses = spy.sorted { $0.date < $1.date }.map(\.close)
        var relative: Double?
        if let own = back(60), spyCloses.count > 60, let last = spyCloses.last, spyCloses[spyCloses.count - 61] > 0 {
            relative = own - (last / spyCloses[spyCloses.count - 61] - 1) * 100
        }

        return JEVHoldingFacts(
            ticker: holding.ticker,
            name: holding.researchName,
            sector: holding.sector,
            weightPercent: holding.weight * 100,
            unrealizedGainPercent: holding.unrealizedPercent,
            todayChangePercent: holding.todayChangePercent,
            return5D: back(5), return20D: back(20), return60D: back(60), return120D: back(120), return250D: back(250),
            versusMA20: versusAverage(20), versusMA50: versusAverage(50), versusMA200: versusAverage(200),
            ma50AboveMA200: ma50.flatMap { a in ma200.map { a > $0 } },
            rsi14: rsi,
            volatility20DAnnualized: volatility,
            fromHigh52W: high.flatMap { $0 > 0 ? (price / $0 - 1) * 100 : nil },
            fromLow52W: low.flatMap { $0 > 0 ? (price / $0 - 1) * 100 : nil },
            maxDrawdown1Y: closes.count > 20 ? drawdown : nil,
            volumeVersus20DAverage: volumeMultiple,
            relativeTo60DSPY: relative,
            sessions: ordered.count
        )
    }

    /// The state as Jev is sent it: English field names with their units, the
    /// language it reads best, and figures rounded to what matters.
    var state: [String: Any] {
        func round(_ value: Double?) -> Any { Self.rounded(value) }
        var metrics: [String: Any] = [
            "change_today_pct": round(todayChangePercent),
            "return_5d_pct": round(return5D),
            "return_20d_pct": round(return20D),
            "return_60d_pct": round(return60D),
            "return_120d_pct": round(return120D),
            "return_1y_pct": round(return250D),
            "price_vs_20d_average_pct": round(versusMA20),
            "price_vs_50d_average_pct": round(versusMA50),
            "price_vs_200d_average_pct": round(versusMA200),
            "rsi_14": round(rsi14),
            "volatility_20d_annualized_pct": round(volatility20DAnnualized),
            "distance_from_52w_high_pct": round(fromHigh52W),
            "distance_above_52w_low_pct": round(fromLow52W),
            "max_drawdown_1y_pct": round(maxDrawdown1Y),
            "latest_volume_vs_20d_average_x": round(volumeVersus20DAverage),
            "return_60d_minus_sp500_pct": round(relativeTo60DSPY),
            "trading_sessions_of_history": sessions,
        ]
        metrics["50d_average_above_200d_average"] = ma50AboveMA200.map { $0 as Any } ?? NSNull()
        // Jev reads English best; a sector name in another script is left out
        // rather than sent in a language it reads less well.
        let englishSector = sector.flatMap { $0.allSatisfy(\.isASCII) ? $0 : nil }
        var state: [String: Any] = [
            "as_of": DayDateCodec.string(from: Date()),
            "context": "One holding in a long-only personal stock portfolio. Figures are computed from daily closing prices; null means not enough history.",
            // What each figure means and which way its sign points, so a
            // negative number is not read as bad news by default.
            "definitions": Self.definitions.merging(JEVMarketFacts.definitions) { first, _ in first },
            "security": ["ticker": ticker, "name": name, "sector": englishSector.map { $0 as Any } ?? NSNull()],
            "position": [
                "portfolio_weight_pct": round(weightPercent),
                "unrealized_gain_pct": round(unrealizedGainPercent),
            ],
            "price_metrics": metrics,
        ]
        if let options {
            state["options_open_interest"] = [
                "call_wall_strike": round(options.callWall),
                "call_wall_distance_pct": round(options.callWallDistance),
                "put_wall_strike": round(options.putWall),
                "put_wall_distance_pct": round(options.putWallDistance),
                "put_call_open_interest_ratio": round(options.putCallRatio),
                "expiries": "next 30 days, as of \(options.asOf)",
            ]
        }
        if let volume {
            state["volume_profile"] = [
                "point_of_control": round(volume.pointOfControl),
                "value_area_high": round(volume.valueAreaHigh),
                "value_area_low": round(volume.valueAreaLow),
                "price_vs_point_of_control_pct": round(volume.priceVersusPOC),
                "price_position_in_value_area": volume.position,
            ]
        }
        if let valuation {
            state["valuation"] = [
                "pe_trailing_12m": round(valuation.pe),
                "price_to_sales_trailing_12m": round(valuation.ps),
                "growth_yoy_pct": round(valuation.growthPercent),
                "growth_basis": valuation.growthBasis,
                "peg": round(valuation.peg),
                "filings_through": valuation.throughPeriod,
            ]
        }
        if let sectorSentiment {
            state["semiconductor_sector_sentiment"] = [
                "score_0_fear_to_100_greed": sectorSentiment.score.map { $0 as Any } ?? NSNull(),
                "regime": sectorSentiment.regime,
                "sector_volatility_change_pct": round(sectorSentiment.volatilityChangePercent),
                "sector_etf_change_pct": round(sectorSentiment.priceChangePercent),
                "as_of": sectorSentiment.asOf,
            ]
        }
        if let market { state["market"] = market.state }
        return state
    }

    static let definitions: [String: String] = [
        "return_*_pct": "Price change over the period in percent. Positive means the price rose.",
        "price_vs_*_average_pct": "How far the current price is above (positive) or below (negative) that moving average, in percent.",
        "50d_average_above_200d_average": "True when the 50-day average is above the 200-day average, a long-term uptrend signal.",
        "distance_from_52w_high_pct": "Percent below the 52-week high. 0 means at the high; -5 means 5% below it.",
        "distance_above_52w_low_pct": "Percent above the 52-week low.",
        "max_drawdown_1y_pct": "The largest peak-to-trough fall within the past year, in percent. It is history, not a current move.",
        "rsi_14": "14-day relative strength index. Above 70 is overbought, below 30 is oversold, around 50 is neutral.",
        "volatility_20d_annualized_pct": "Annualized volatility of the last 20 daily returns.",
        "latest_volume_vs_20d_average_x": "The latest session's volume as a multiple of the 20-day average.",
        "return_60d_minus_sp500_pct": "The stock's 60-day return minus the S&P 500's. Positive means it beat the market.",
        "portfolio_weight_pct": "Share of the whole portfolio this position makes up.",
        "call_wall_strike": "The strike above the price with the most call open interest; it often acts as resistance.",
        "put_wall_strike": "The strike below the price with the most put open interest; it often acts as support.",
        "*_wall_distance_pct": "Percent from the current price to that strike; positive is above the price.",
        "put_call_open_interest_ratio": "Total put open interest divided by total call open interest. Above 1 leans defensive, below 0.7 leans bullish.",
        "point_of_control": "The price with the most trading volume over the past year.",
        "value_area_high": "Top of the band holding 70% of the past year's volume.",
        "value_area_low": "Bottom of that band.",
        "price_position_in_value_area": "Whether the price is above, inside or below the value area.",
        "pe_trailing_12m": "Market value over the last twelve months' net income, from SEC filings. Null when the company made a loss.",
        "price_to_sales_trailing_12m": "Market value over the last twelve months' revenue.",
        "peg": "P/E divided by growth. Around 1 is fair for the growth; well above 2 is expensive for it.",
        "score_0_fear_to_100_greed": "The semiconductor sector sentiment score: low is fear, high is complacency.",
        "unrealized_gain_pct": "Gain on the position against what was paid for it.",
    ]
}

// MARK: - What Jev is asked

/// Jev describes; it does not decide. Asked straight out whether to buy or
/// sell, it drifted between reading a move as a trend to follow and as an
/// excess to fade, and its verdicts contradicted its own outlook. So it now
/// rates four independent sides of each stock on described scales — TypeSafe's
/// composite-scoring pattern — and the app puts them together in code, as a
/// description of where the stock stands rather than an instruction.
enum JEVDimension: String, CaseIterable, Identifiable, Codable {
    case trend
    case momentum
    case stretch
    case risk
    /// Asked only when the holding has an options chain.
    case options
    /// Asked only when the holding has P/E and growth.
    case valuation

    var id: String { rawValue }

    /// The four asked of every holding.
    static let core: [JEVDimension] = [.trend, .momentum, .stretch, .risk]

    var instructions: String {
        switch self {
        case .trend:
            "The stock's long-term trend, judged from its price against the 50- and 200-day averages and whether the 50-day average is above the 200-day."
        case .momentum:
            "The stock's recent momentum over the last one to three months, judged from its 20- and 60-day returns and its 60-day return against the S&P 500."
        case .stretch:
            "How stretched the price is after its recent move, judged from RSI, distance from the 52-week high and low, distance from the 20-day average, and where the price sits against the volume profile's value area."
        case .risk:
            "How risky the stock's recent price behaviour is, judged from volatility, the past year's drawdown and any sign of a breakdown, taking the market backdrop into account."
        case .options:
            "What options open interest implies for the stock: where the heaviest put strike (support) and call strike (resistance) sit against the price, and the put/call balance."
        case .valuation:
            "How expensive the stock looks for its growth, judged from its trailing P/E (or price to sales when it has no earnings) against its net income or revenue growth and the PEG."
        }
    }

    /// Low to high, each described so the level can be matched rather than
    /// guessed; TypeSafe scores these 0 to 4.
    var levels: [String] {
        switch self {
        case .trend:
            ["Clear downtrend: below both long-term averages, 50-day under 200-day",
             "Weakening: below the long-term averages or losing them",
             "Sideways: no clear long-term direction",
             "Uptrend: above the long-term averages",
             "Strong, established uptrend: well above both, 50-day over 200-day"]
        case .momentum:
            ["Sharply negative: large recent losses, well behind the market",
             "Negative: recent losses or lagging the market",
             "Flat: little recent movement either way",
             "Positive: recent gains or beating the market",
             "Sharply positive: large recent gains, well ahead of the market"]
        case .stretch:
            ["Deeply oversold: sharp fall, RSI very low, near the 52-week low",
             "Somewhat oversold: below its usual range",
             "Normal: within its usual range",
             "Somewhat extended: above its usual range",
             "Very overextended: sharp run-up, RSI very high, at the 52-week high"]
        case .risk:
            ["Calm: low volatility, shallow drawdowns",
             "Normal: ordinary volatility for a stock",
             "Somewhat elevated: choppier than usual or a notable drawdown",
             "High: very volatile or a deep drawdown",
             "Very high: breaking down or extremely volatile"]
        case .options:
            ["Bearish: put-heavy open interest, price near or below the main put strike",
             "Leaning bearish: more put than call interest near the price",
             "Balanced: no clear lean in open interest",
             "Leaning bullish: more call than put interest, room below the main call strike",
             "Bullish: call-heavy open interest with support well below"]
        case .valuation:
            ["Very cheap for its growth",
             "Cheap for its growth",
             "Fairly valued for its growth",
             "Expensive for its growth",
             "Very expensive for its growth"]
        }
    }

    var title: String {
        switch self {
        case .trend: L10n.text("趋势")
        case .momentum: L10n.text("动量")
        case .stretch: L10n.text("位置")
        case .risk: L10n.text("风险")
        case .options: L10n.text("期权")
        case .valuation: L10n.text("估值")
        }
    }

    /// The level nearest the score, in words.
    func label(for score: Double) -> String {
        let names: [String] = switch self {
        case .trend: [L10n.text("明确下跌"), L10n.text("走弱"), L10n.text("横盘"), L10n.text("上升"), L10n.text("稳固上升")]
        case .momentum: [L10n.text("大幅走弱"), L10n.text("走弱"), L10n.text("平淡"), L10n.text("走强"), L10n.text("大幅走强")]
        case .stretch: [L10n.text("深度超跌"), L10n.text("偏超跌"), L10n.text("正常"), L10n.text("偏过热"), L10n.text("严重过热")]
        case .risk: [L10n.text("平稳"), L10n.text("正常"), L10n.text("偏高"), L10n.text("高"), L10n.text("很高")]
        case .options: [L10n.text("明显偏空"), L10n.text("偏空"), L10n.text("均衡"), L10n.text("偏多"), L10n.text("明显偏多")]
        case .valuation: [L10n.text("很便宜"), L10n.text("偏便宜"), L10n.text("合理"), L10n.text("偏贵"), L10n.text("很贵")]
        }
        return names[min(4, max(0, Int(score.rounded())))]
    }
}

enum JEVQuestions {
    static func question(_ dimension: JEVDimension) -> [String: Any] {
        ["type": "score", "instructions": dimension.instructions, "criteria": dimension.levels]
    }

    /// Every dimension; a holding is asked only those it has data for.
    static var all: [String: Any] {
        Dictionary(uniqueKeysWithValues: JEVDimension.allCases.map { ($0.rawValue, question($0)) })
    }

    static func questions(for facts: JEVHoldingFacts) -> [String: Any] {
        var dimensions = JEVDimension.core
        if facts.options != nil { dimensions.append(.options) }
        if facts.valuation != nil { dimensions.append(.valuation) }
        return Dictionary(uniqueKeysWithValues: dimensions.map { ($0.rawValue, question($0)) })
    }

    /// Asked once per run, of the market facts alone.
    static let market: [String: Any] = [
        "market": [
            "type": "score",
            "instructions": "How supportive the overall US stock market backdrop is right now, from the S&P 500's trend, the VIX and Treasury yields.",
            "criteria": [
                "Hostile: falling market, high and rising volatility",
                "Weak: soft market or elevated volatility",
                "Mixed: no clear direction",
                "Supportive: rising market, calm volatility",
                "Very supportive: strong market, low and falling volatility",
            ],
        ] as [String: Any],
    ]

    static func marketLabel(_ score: Double) -> String {
        [L10n.text("恶劣"), L10n.text("偏弱"), L10n.text("中性"), L10n.text("有利"), L10n.text("很有利")][min(4, max(0, Int(score.rounded())))]
    }
}

// MARK: - The result

struct JEVScore: Codable, Equatable {
    /// 0 to 4 along the dimension's levels.
    let score: Double
    let confidence: Double
}

/// The view Jev's scores add up to, put together in code: trend and
/// momentum set how bullish or bearish it reads, on five steps. Stretch and
/// risk do not change that; they are shown beside it as qualifiers.
enum JEVState: String, Codable, CaseIterable {
    case strongBearish, bearish, neutral, bullish, strongBullish, unclear

    var title: String {
        switch self {
        case .strongBearish: L10n.text("强烈看空")
        case .bearish: L10n.text("看空")
        case .neutral: L10n.text("中性")
        case .bullish: L10n.text("看多")
        case .strongBullish: L10n.text("强烈看多")
        case .unclear: L10n.text("信号不清")
        }
    }

    /// Which way it reads, for the tally and colour.
    var direction: Int {
        switch self {
        case .bullish, .strongBullish: 1
        case .bearish, .strongBearish: -1
        default: 0
        }
    }

    /// Below this Jev is saying it cannot tell; TypeSafe's advice for low
    /// confidence is not to read the answer as a finding.
    static let decisiveConfidence = 0.4

    /// Trend and momentum together, 0 (bearish) to 4 (bullish).
    static func direction(_ scores: [String: JEVScore]) -> Double? {
        guard let trend = scores[JEVDimension.trend.rawValue],
              let momentum = scores[JEVDimension.momentum.rawValue] else { return nil }
        return (trend.score + momentum.score) / 2
    }

    static func make(_ scores: [String: JEVScore]) -> JEVState {
        guard let trend = scores[JEVDimension.trend.rawValue],
              let momentum = scores[JEVDimension.momentum.rawValue],
              let direction = direction(scores) else { return .unclear }
        if (trend.confidence + momentum.confidence) / 2 < decisiveConfidence { return .unclear }
        switch direction {
        case ..<0.75: return .strongBearish
        case ..<1.6: return .bearish
        case ..<2.4: return .neutral
        case ..<3.25: return .bullish
        default: return .strongBullish
        }
    }

    /// What stretch and risk add, in a word or two each; empty when neither
    /// is out of the ordinary.
    static func qualifiers(_ scores: [String: JEVScore]) -> [String] {
        var words: [String] = []
        if let stretch = scores[JEVDimension.stretch.rawValue]?.score {
            if stretch >= 3 { words.append(L10n.text("过热")) } else if stretch <= 1 { words.append(L10n.text("超跌")) }
        }
        if let risk = scores[JEVDimension.risk.rawValue]?.score, risk >= 3 {
            words.append(L10n.text("高风险"))
        }
        if let options = scores[JEVDimension.options.rawValue]?.score {
            if options >= 3 { words.append(L10n.text("期权偏多")) } else if options <= 1 { words.append(L10n.text("期权偏空")) }
        }
        if let valuation = scores[JEVDimension.valuation.rawValue]?.score {
            if valuation >= 3 { words.append(L10n.text("估值偏贵")) } else if valuation <= 1 { words.append(L10n.text("估值便宜")) }
        }
        return words
    }
}

struct JEVCall: Codable, Identifiable, Equatable {
    var id: String { ticker }
    let ticker: String
    let name: String
    let logoSymbol: String?
    let facts: JEVHoldingFacts
    /// Jev's four scores, keyed by `JEVDimension`.
    let scores: [String: JEVScore]
    let error: String?
    /// The selected AI's reading of the scores, asked for on the card; not
    /// Jev's own reasoning, which it does not produce.
    var explanation: String?

    var state: JEVState { JEVState.make(scores) }

    /// How sure Jev is of the direction: the confidence of the two scores
    /// the view is built from.
    var directionConfidence: Double? {
        guard let trend = score(.trend), let momentum = score(.momentum) else { return nil }
        return (trend.confidence + momentum.confidence) / 2
    }

    /// How sure Jev is, then stretch and risk in words, then the position's size.
    var note: String {
        let confidence = directionConfidence.map { [JEVLabels.confidence($0)] } ?? []
        return (confidence + JEVState.qualifiers(scores) + [L10n.text("仓位\(concentration)")]).joined(separator: " · ")
    }

    func score(_ dimension: JEVDimension) -> JEVScore? { scores[dimension.rawValue] }

    /// Worked out from the weight rather than asked: a percentage needs no
    /// model to read it.
    var concentration: String {
        switch facts.weightPercent {
        case 25...: L10n.text("很重")
        case 12..<25: L10n.text("较重")
        case 5..<12: L10n.text("适中")
        default: L10n.text("较轻")
        }
    }

    /// How much this stock asks for a look, for ordering the list: a clear
    /// direction, an extreme reading or high risk first, an unclear one last.
    var salience: Double {
        guard error == nil, state != .unclear else { return -1 }
        let direction = ((score(.trend)?.score ?? 2) + (score(.momentum)?.score ?? 2)) / 2
        let stretch = score(.stretch)?.score ?? 2
        let risk = score(.risk)?.score ?? 2
        return abs(direction - 2) + max(0, abs(stretch - 2) - 1) + max(0, risk - 2)
            + (facts.weightPercent >= 25 ? 0.5 : 0)
    }
}

struct JEVReport: Codable, Equatable {
    let generatedAt: Date
    let model: String
    var calls: [JEVCall]
    /// The shared backdrop and Jev's one score of it.
    var market: JEVMarketFacts?
    var marketScore: JEVScore?

    var counts: (bullish: Int, neutral: Int, bearish: Int, unclear: Int) {
        let answered = calls.filter { $0.error == nil }
        return (answered.filter { $0.state.direction > 0 }.count,
                answered.filter { $0.state.direction == 0 && $0.state != .unclear }.count,
                answered.filter { $0.state.direction < 0 }.count,
                answered.filter { $0.state == .unclear }.count)
    }
}

/// The last report for each account selection, kept so the page opens on it
/// rather than on a blank list; a run is always the reader's choice. Reports
/// from the earlier buy/sell questions no longer decode and are simply not
/// shown.
enum JEVReportCache {
    private static func url(scope: String) -> URL? {
        let hash = SHA256.hash(data: Data(scope.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("jev-today", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(hash).json")
    }

    static func load(scope: String) -> JEVReport? {
        guard let url = url(scope: scope), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(JEVReport.self, from: data)
    }

    static func save(_ report: JEVReport, scope: String) {
        guard let url = url(scope: scope) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: url, options: .atomic)
    }

    @MainActor static func scope(model: AppModel) -> String {
        "\(model.isFakeDataMode ? "demo" : "real")|\(model.selectedAccountKeys.sorted().joined(separator: ","))"
    }
}

// MARK: - The run

@MainActor @Observable
final class JEVRunner {
    private(set) var report: JEVReport?
    private(set) var isRunning = false
    private(set) var progress: (done: Int, total: Int) = (0, 0)
    /// What is being read before Jev is asked anything.
    private(set) var phase: String?
    private(set) var errorMessage: String?
    private(set) var explaining: Set<String> = []
    private(set) var explanationErrors: [String: String] = [:]
    private var scope: String?

    func restore(scope: String) {
        guard self.scope != scope else { return }
        self.scope = scope
        report = JEVReportCache.load(scope: scope)
        errorMessage = nil
    }

    func run(holdings: [Holding], scope: String) async {
        guard !isRunning else { return }
        let client = JEVClient()
        guard client.isConfigured else {
            errorMessage = JEVClient.JEVError.missingKey(client.provider).localizedDescription
            return
        }
        isRunning = true
        errorMessage = nil
        progress = (0, holdings.count)
        defer { isRunning = false }

        let (facts, market) = await gather(holdings)
        let marketScore = try? await client.ask(
            state: ["as_of": DayDateCodec.string(from: Date()), "market": market.state,
                    "definitions": JEVMarketFacts.definitions],
            questions: JEVQuestions.market
        ).scores["market"].map { JEVScore(score: $0.score, confidence: $0.confidence) }

        // Then Jev, eight holdings in flight at a time: each call is a
        // fraction of a second, and a steady window keeps clear of rate limits
        // without waiting on the slowest of a batch.
        var calls: [JEVCall] = []
        var stopMessage: String?
        await withTaskGroup(of: JEVCall.self) { group in
            var pending = facts.makeIterator()
            for _ in 0..<min(Self.jevConcurrency, facts.count) {
                guard let (holding, fact) = pending.next() else { break }
                group.addTask { await Self.call(client: client, holding: holding, facts: fact) }
            }
            while let result = await group.next() {
                calls.append(result)
                progress = (calls.count, holdings.count)
                // A problem with the account — the token, the credit balance —
                // fails every call the same way: say so once and stop asking.
                let first = Array(calls.prefix(3))
                if first.count == min(3, facts.count), let message = first.first?.error,
                   first.allSatisfy({ $0.error == message }) {
                    stopMessage = message
                    group.cancelAll()
                    break
                }
                if let (holding, fact) = pending.next() {
                    group.addTask { await Self.call(client: client, holding: holding, facts: fact) }
                }
            }
        }
        if let stopMessage, calls.allSatisfy({ $0.error != nil }) {
            errorMessage = stopMessage
            return
        }
        let next = JEVReport(generatedAt: Date(), model: "\(client.provider.title) · \(client.provider.model)",
                             calls: calls.sorted { $0.salience > $1.salience },
                             market: market, marketScore: marketScore ?? nil)
        withAnimation(.smooth) { report = next }
        JEVReportCache.save(next, scope: scope)
    }

    /// Everything Jev is shown for these holdings, and the market once.
    func gather(_ holdings: [Holding]) async -> (facts: [(Holding, JEVHoldingFacts)], market: JEVMarketFacts) {
        // Everything at once: prices, the market, volume profiles, valuations
        // and options walls do not wait on each other. Options and valuations
        // run against a time budget; what misses it goes without this time.
        phase = L10n.text("正在读取行情、期权与估值…")
        async let spyBars = try? LocalMarketDataClient().portfolioAttentionBars(ticker: "SPY", currency: "USD", referencePrice: 0)
        async let marketCloses = Self.marketCloses()
        async let barsByTicker = Self.bars(holdings)
        async let profiles = Self.volumeProfiles(holdings)
        async let valuations = Self.valuations(holdings)
        async let optionsResult = Self.options(holdings, budget: Self.optionsBudget)
        let sector = Self.sectorSentiment()

        let spy = await spyBars ?? []
        let closes = await marketCloses
        let market = JEVMarketFacts.make(vix: closes.vix, tenYear: closes.tenYear, sp500: spy)
        let bars = await barsByTicker
        let volume = await profiles
        let valuationResult = await valuations
        let valuation = valuationResult.facts
        let options = await optionsResult
        phase = nil

        // What the budget left out is fetched quietly afterwards, one chain at
        // a time, so the next run finds it saved.
        if !options.missing.isEmpty {
            let missing = options.missing
            Task.detached(priority: .utility) { await Self.warmOptions(missing) }
        }
        if !valuationResult.missing.isEmpty {
            let missing = valuationResult.missing
            Task.detached(priority: .utility) { await Self.warmFilings(missing) }
        }

        let facts = holdings.map { holding -> (Holding, JEVHoldingFacts) in
            let ticker = holding.ticker.uppercased()
            var fact = JEVHoldingFacts.make(holding: holding, bars: bars[ticker] ?? [], spy: spy)
            fact.market = market
            fact.volume = volume[ticker]
            fact.valuation = valuation[ticker]
            fact.options = options.facts[ticker]
            if IndustrySentimentEngine.semiconductors.contains(ticker) { fact.sectorSentiment = sector }
            return (holding, fact)
        }
        return (facts, market)
    }

    #if DEBUG
    /// `--demo-jev-report`: made-up scores on the real holdings' figures, to
    /// look at each state of the card without an API key.
    func loadDemo(holdings: [Holding]) {
        func scores(_ values: [Double], _ confidence: Double) -> [String: JEVScore] {
            Dictionary(uniqueKeysWithValues: zip(JEVDimension.allCases, values).map {
                ($0.rawValue, JEVScore(score: $1, confidence: confidence))
            })
        }
        let samples: [([Double], Double, String?)] = [
            ([3.6, 3.2, 3.4, 1.8], 0.8, nil),
            ([0.6, 0.8, 0.7, 3.4], 0.7, nil),
            ([2.1, 2.0, 2.2, 1.5], 0.3, nil),
        ]
        let calls = zip(holdings, samples).map { holding, sample in
            JEVCall(ticker: holding.ticker, name: holding.shortName, logoSymbol: holding.logoSymbol,
                    facts: JEVHoldingFacts.make(holding: holding, bars: [], spy: []),
                    scores: scores(sample.0, sample.1), error: nil, explanation: sample.2)
        }
        report = JEVReport(generatedAt: Date(), model: "Demo", calls: calls.sorted { $0.salience > $1.salience })
    }
    #endif

    /// Asks the AI chosen in settings to read one stock's scores back in
    /// words. Jev gives numbers only; this is an interpretation of them, kept
    /// with the report so it is not asked for twice.
    func explain(_ ticker: String) async {
        guard let current = report, let index = current.calls.firstIndex(where: { $0.ticker == ticker }),
              !explaining.contains(ticker) else { return }
        let readiness = AIProviderPreference.current.readiness
        guard readiness.isReady else {
            explanationErrors[ticker] = readiness.message
            return
        }
        explaining.insert(ticker)
        explanationErrors[ticker] = nil
        defer { explaining.remove(ticker) }
        do {
            let text = try await LocalAIClient().researchAnswer(
                Self.explanationQuestion(current.calls[index]),
                context: Self.explanationContext
            )
            guard var latest = report, let row = latest.calls.firstIndex(where: { $0.ticker == ticker }) else { return }
            latest.calls[row].explanation = text.trimmingCharacters(in: .whitespacesAndNewlines)
            withAnimation(.smooth) { report = latest }
            if let scope { JEVReportCache.save(latest, scope: scope) }
        } catch {
            explanationErrors[ticker] = error.localizedDescription
        }
    }

    private static let explanationContext = """
    You explain scores produced by Jev, a model that returns only numbers, never reasoning.
    You did not produce the scores. Read them against the data and say, plainly and briefly, what the combination describes.
    Use only the supplied figures. Do not invent news, fundamentals or prices. Do not tell the reader to buy or sell.
    """

    private static func explanationQuestion(_ call: JEVCall) -> String {
        var scores: [String: Any] = [:]
        for dimension in JEVDimension.allCases {
            guard let score = call.score(dimension) else { continue }
            scores[dimension.rawValue] = ["score_0_to_4": score.score, "confidence": score.confidence,
                                          "levels_low_to_high": dimension.levels]
        }
        func json(_ value: Any) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
            return String(decoding: data, as: UTF8.self)
        }
        let language = ContentLanguage.current.hasPrefix("zh") ? "简体中文" : "English"
        return """
        Data Jev was given: \(json(call.facts.state))
        Jev's scores: \(json(scores))

        In \(language), in 3 to 5 short sentences:
        1. What the four scores describe together, citing the figures behind the most telling ones.
        2. Where the scores pull against each other (for example a strong trend with an overextended price), say so.
        3. What a holder might watch next in the price data. If any confidence is below 0.4, say that score is unreliable.
        Plain text, no headings or lists. No buy or sell instruction.
        """
    }

    // MARK: Reading the extra data

    static let jevConcurrency = 8
    /// Seconds a run waits for options chains before it asks Jev without
    /// them. Valuations are read from the saved fundamentals alone.
    static let optionsBudget: Double = 12
    /// A saved chain this recent is used as it is, without asking Yahoo.
    nonisolated static let optionsFreshDays = 4

    private nonisolated static func withTimeout<T: Sendable>(_ seconds: Double,
                                                              _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private nonisolated static func bars(_ holdings: [Holding]) async -> [String: [PortfolioAttentionDailyBar]] {
        await withTaskGroup(of: (String, [PortfolioAttentionDailyBar]).self) { group in
            for holding in holdings {
                let ticker = holding.ticker, currency = holding.quoteCurrency ?? "USD", price = holding.quotePrice
                group.addTask {
                    let bars = try? await LocalMarketDataClient().portfolioAttentionBars(
                        ticker: ticker, currency: currency, referencePrice: price)
                    return (ticker.uppercased(), bars ?? [])
                }
            }
            var result: [String: [PortfolioAttentionDailyBar]] = [:]
            for await (ticker, rows) in group { result[ticker] = rows }
            return result
        }
    }

    private nonisolated static func marketCloses() async -> (vix: [String: Double], tenYear: [String: Double]) {
        let end = Date()
        let start = Calendar.current.date(byAdding: .day, value: -400, to: end) ?? end
        let closes = await LocalMarketDataClient().historicalCloses(
            symbols: ["^VIX", "^TNX"], from: DayDateCodec.string(from: start), to: DayDateCodec.string(from: end),
            dividendAdjusted: false
        )
        return (closes["^VIX"] ?? [:], closes["^TNX"] ?? [:])
    }

    /// From the same daily bars the prices came from, so it costs no fetch
    /// when they are already cached.
    private nonisolated static func volumeProfiles(_ holdings: [Holding]) async -> [String: JEVVolumeFacts] {
        await withTaskGroup(of: (String, JEVVolumeFacts?).self) { group in
            for holding in holdings {
                let ticker = holding.ticker, currency = holding.quoteCurrency ?? "USD", price = holding.quotePrice
                group.addTask {
                    guard let profile = try? await LocalMarketDataClient().volumeProfile(
                        ticker: ticker, currency: currency, referencePrice: price),
                          profile.available, profile.pointOfControl > 0, price > 0 else { return (ticker.uppercased(), nil) }
                    let position = price > profile.valueAreaHigh ? "above" : price < profile.valueAreaLow ? "below" : "inside"
                    return (ticker.uppercased(), JEVVolumeFacts(
                        pointOfControl: profile.pointOfControl, valueAreaHigh: profile.valueAreaHigh,
                        valueAreaLow: profile.valueAreaLow,
                        priceVersusPOC: (price / profile.pointOfControl - 1) * 100, position: position))
                }
            }
            var result: [String: JEVVolumeFacts] = [:]
            for await (ticker, facts) in group { if let facts { result[ticker] = facts } }
            return result
        }
    }

    /// A run waits this long for filings it has not saved yet.
    static let filingsBudget: Double = 6

    private nonisolated static func valuationListed(_ holdings: [Holding]) -> [Holding] {
        holdings.filter {
            ($0.quoteCurrency ?? "").uppercased() == "USD" && !$0.ticker.contains(".") && $0.quotePrice > 0
        }
    }

    /// From SEC filings the app already keeps for the 财务 page. Saved
    /// filings are used as they are — they change once a quarter — and the
    /// missing ones are fetched for a few seconds, the rest afterwards.
    private nonisolated static func valuations(_ holdings: [Holding]) async -> (facts: [String: JEVValuationFacts], missing: [String]) {
        let listed = valuationListed(holdings)
        var filings: [String: CompanyFinancialsData] = [:]
        var missing: [String] = []
        for holding in listed {
            let ticker = holding.ticker.uppercased()
            if let saved = await CompanyFinancialsClient.shared.cached(ticker: ticker), saved.sharesOutstanding != nil {
                filings[ticker] = saved
            } else {
                missing.append(ticker)
            }
        }
        if !missing.isEmpty {
            let requestedTickers = Array(missing.prefix(6))
            let fetched = await withTimeout(filingsBudget) { () -> [String: CompanyFinancialsData] in
                await withTaskGroup(of: (String, CompanyFinancialsData?).self) { group in
                    for ticker in requestedTickers {
                        group.addTask { (ticker, try? await CompanyFinancialsClient.shared.load(ticker: ticker, forceRefresh: true)) }
                    }
                    var result: [String: CompanyFinancialsData] = [:]
                    for await (ticker, data) in group { if let data { result[ticker] = data } }
                    return result
                }
            } ?? [:]
            filings.merge(fetched) { _, new in new }
            missing.removeAll { fetched[$0] != nil }
        }
        var result: [String: JEVValuationFacts] = [:]
        for holding in listed {
            let ticker = holding.ticker.uppercased()
            if let filing = filings[ticker], let facts = JEVValuationFacts.make(filing, price: holding.quotePrice) {
                result[ticker] = facts
            }
        }
        return (result, missing)
    }

    /// Saves the filings a run's budget skipped, for the next run.
    private nonisolated static func warmFilings(_ tickers: [String]) async {
        for ticker in tickers {
            _ = try? await CompanyFinancialsClient.shared.load(ticker: ticker, forceRefresh: true)
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    /// The sentiment page's last saved reading; the page itself refreshes it.
    private nonisolated static func sectorSentiment() -> JEVSectorFacts? {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("industry-sentiment.json"),
              let data = try? Data(contentsOf: url),
              let snapshot = try? IndustrySentimentSnapshot.decode(data) else { return nil }
        return JEVSectorFacts(score: snapshot.score, regime: snapshot.regime,
                              volatilityChangePercent: snapshot.changePct, priceChangePercent: snapshot.priceChangePct,
                              asOf: snapshot.asOf)
    }

    /// How far from the price a wall may sit and still be sent.
    nonisolated static let wallReach = 0.3

    private nonisolated static func optionsListed(_ holdings: [Holding]) -> [Holding] {
        holdings.filter {
            ($0.quoteCurrency ?? "").uppercased() == "USD" && !$0.ticker.uppercased().hasSuffix(".L")
                && $0.ticker.range(of: "^[A-Za-z][A-Za-z0-9.-]{0,14}$", options: .regularExpression) != nil
        }
    }

    /// Whether a saved chain is recent enough to use without asking Yahoo.
    private nonisolated static func isFresh(_ snapshot: OISnapshot?) -> Bool {
        guard let snapshot,
              let saved = DayDateCodec.date(from: snapshot.from),
              let today = DayDateCodec.date(from: OptionsOIClient.day(Date())) else { return false }
        return today.timeIntervalSince(saved) <= Double(optionsFreshDays) * 86_400
    }

    /// Options walls for US listings. Yahoo builds a chain from several
    /// requests and takes one chain at a time, so saved chains from the last
    /// few days are used as they are, and only the rest are fetched — one by
    /// one, for at most `budget` seconds, stopping the moment Yahoo pushes
    /// back. What is left over is returned as `missing`.
    private nonisolated static func options(_ holdings: [Holding], budget: Double)
        async -> (facts: [String: JEVOptionsFacts], missing: [String]) {
        let listed = optionsListed(holdings)
        var result: [String: JEVOptionsFacts] = [:]
        var missing: [String] = []
        var canFetch = true
        let deadline = Date().addingTimeInterval(budget)
        var snapshots: [String: OISnapshot] = [:]
        var stale: [Holding] = []
        for holding in listed {
            let symbol = holding.ticker.uppercased()
            let cached = await OptionsOIClient.shared.cached(symbol: symbol, days: 30)
            if let cached { snapshots[symbol] = cached }
            if !isFresh(cached) { stale.append(holding) }
        }
        for holding in stale {
            let symbol = holding.ticker.uppercased()
            guard canFetch, Date() < deadline, !Task.isCancelled else { missing.append(symbol); continue }
            do {
                snapshots[symbol] = try await OptionsOIClient.shared.fetch(symbol: symbol, days: 30)
            } catch {
                canFetch = false
                missing.append(symbol)
            }
        }
        for holding in listed {
            let symbol = holding.ticker.uppercased()
            guard let snapshot = snapshots[symbol], holding.quotePrice > 0 else { continue }
            let distribution = OIDistribution(contracts: snapshot.contracts, currentPrice: holding.quotePrice)
            let calls = distribution.rows.reduce(0) { $0 + $1.call }
            let puts = distribution.rows.reduce(0) { $0 + $1.put }
            guard calls + puts > 0 else { continue }
            let price = holding.quotePrice
            // A wall far from the price is old open interest, not support or
            // resistance; the chart widens its search to always name one, but
            // Jev is only told about walls within reach.
            func nearby(_ strike: Double?) -> Double? {
                strike.flatMap { abs($0 / price - 1) <= Self.wallReach ? $0 : nil }
            }
            let callWall = nearby(distribution.callWalls.first?.strike)
            let putWall = nearby(distribution.putWalls.first?.strike)
            result[symbol] = JEVOptionsFacts(
                callWall: callWall, putWall: putWall,
                callWallDistance: callWall.map { ($0 / price - 1) * 100 },
                putWallDistance: putWall.map { ($0 / price - 1) * 100 },
                putCallRatio: calls > 0 ? puts / calls : nil,
                asOf: snapshot.from)
        }
        return (result, missing)
    }

    /// Fills in the chains a run's budget skipped, for the next run: one at
    /// a time with a pause between, stopping if Yahoo pushes back.
    private nonisolated static func warmOptions(_ symbols: [String]) async {
        for symbol in symbols {
            guard (try? await OptionsOIClient.shared.fetch(symbol: symbol, days: 30)) != nil else { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private nonisolated static func call(client: JEVClient, holding: Holding, facts: JEVHoldingFacts) async -> JEVCall {
        do {
            let answers = try await client.ask(state: facts.state, questions: JEVQuestions.questions(for: facts))
            let scores = answers.scores.mapValues { JEVScore(score: $0.score, confidence: $0.confidence) }
            return JEVCall(ticker: holding.ticker, name: holding.shortName, logoSymbol: holding.logoSymbol,
                           facts: facts, scores: scores, error: nil)
        } catch {
            return JEVCall(ticker: holding.ticker, name: holding.shortName, logoSymbol: holding.logoSymbol,
                           facts: facts, scores: [:], error: error.localizedDescription)
        }
    }
}

// MARK: - Labels

enum JEVLabels {
    static func stateColor(_ state: JEVState, scheme: ColorScheme) -> Color {
        switch state.direction {
        case 1: CatfolioTheme.gain(for: scheme)
        case -1: CatfolioTheme.loss(for: scheme)
        default: .secondary
        }
    }

    /// Confidence in three bands, as TypeSafe suggests reading it.
    static func confidence(_ value: Double?) -> String {
        guard let value else { return "" }
        if value >= 0.7 { return L10n.text("把握高") }
        if value >= JEVState.decisiveConfidence { return L10n.text("把握中") }
        return L10n.text("把握低")
    }
}

// MARK: - The page

struct JEVTodayAttentionView: View {
    @Environment(AppModel.self) private var model
    @State private var runner = JEVRunner()
    @State private var expanded: Set<String> = []
    @AppStorage(JEVProvider.storageKey) private var providerRaw = ""
    /// Keychain reads are not observed; bumped on appearing so a key added in
    /// 服务商 counts at once.
    @State private var keysRevision = 0

    private var provider: JEVProvider { JEVProvider(rawValue: providerRaw) ?? .current }
    private var hasKey: Bool { _ = keysRevision; return provider.isConfigured }

    var body: some View {
        SettingsPage(title: nil, bottomInset: 48, topInset: SettingsTemplate.sectionSpacing) {
            summaryCard

            if let report = runner.report {
                ForEach(report.calls) { call in
                    JEVCallCard(
                        call: call,
                        isExpanded: expanded.contains(call.id),
                        isExplaining: runner.explaining.contains(call.id),
                        explanationError: runner.explanationErrors[call.id],
                        toggle: {
                            withAnimation(.snappy) {
                                if expanded.contains(call.id) { expanded.remove(call.id) } else { expanded.insert(call.id) }
                            }
                        },
                        explain: { Task { await runner.explain(call.id) } }
                    )
                }
            }

            SettingsFootnote([
                L10n.text("JEV 是 TypeSafe 的 System One 模型，经你在 OpenRouter 或 Cloudflare 的账户调用。每只持仓的行情指标（涨跌、均线、RSI、波动、52 周位置、成交量、相对标普 500）、期权持仓墙、成交量分布、估值（需 FMP Key），以及仓位占比、浮动盈亏百分比和市场环境会发送给所选服务；不含账户、股数或金额。"),
                L10n.text("JEV 不给买卖结论：它在趋势、动量、位置、风险四个方面各打一个分。看多看空由趋势和动量合成，位置和风险作为附注。它只看这些数字，不读新闻和财报，不构成投资建议。"),
            ])
        }
        .navigationTitle(L10n.text("JEV 今日关注"))
        .navigationBarTitleDisplayMode(.large)
        .toolbarVisibility(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("运行"), systemImage: "arrow.clockwise") { start() }
                    .disabled(runner.isRunning || model.holdings.isEmpty || !hasKey)
            }
        }
        .task(id: JEVReportCache.scope(model: model)) {
            runner.restore(scope: JEVReportCache.scope(model: model))
            #if DEBUG
            if LaunchArguments.contains("--demo-jev-report") {
                runner.loadDemo(holdings: model.holdings)
                expanded = Set(runner.report?.calls.prefix(1).map(\.id) ?? [])
            }
            #endif
        }
        .onAppear { keysRevision &+= 1 }
    }

    private func start() {
        let scope = JEVReportCache.scope(model: model)
        runner.restore(scope: scope)
        Task { await runner.run(holdings: model.holdings, scope: scope) }
    }

    @ViewBuilder
    private var summaryCard: some View {
        SettingsCard {
            SettingsRowContainer {
                VStack(alignment: .leading, spacing: 12) {
                    // Jev is served by both; the reader picks whose account
                    // pays for it.
                    Picker(L10n.text("通过"), selection: Binding(
                        get: { provider },
                        set: { providerRaw = $0.rawValue }
                    )) {
                        ForEach(JEVProvider.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .disabled(runner.isRunning)

                    if !hasKey {
                        Label(L10n.text("需要 \(provider.title) 凭证"), systemImage: "key")
                            .appText(.body, weight: .semibold)
                        Text(provider.setupHint)
                            .appText(.callout)
                            .foregroundStyle(.secondary)
                    } else if runner.isRunning {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(runner.phase
                                 ?? (runner.progress.total > 0 && runner.progress.done > 0
                                     ? L10n.text("JEV 正在判断… \(runner.progress.done)/\(runner.progress.total)")
                                     : L10n.text("正在读取行情…")))
                                .appText(.callout, weight: .medium)
                        }
                    } else if let report = runner.report {
                        let counts = report.counts
                        HStack(spacing: 18) {
                            tally(counts.bullish, L10n.text("看多"))
                            tally(counts.neutral, L10n.text("中性"))
                            tally(counts.bearish, L10n.text("看空"))
                            tally(counts.unclear, L10n.text("信号不清"))
                        }
                        if let market = report.market {
                            marketLine(market, score: report.marketScore)
                        }
                        Text(L10n.text("判断于 \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))") + " · " + report.model)
                            .appText(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.text("把每只持仓的行情指标交给 JEV，让它从趋势、动量、位置、风险四个方面描述这只股票现在的状态。"))
                            .appText(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let message = runner.errorMessage {
                        Text(message)
                            .appText(.callout)
                            .foregroundStyle(CatfolioTheme.warning)
                    }
                    if hasKey && !runner.isRunning {
                        GlassPrimaryButton(
                            title: runner.report == nil ? L10n.text("运行 JEV") : L10n.text("重新判断"),
                            systemImage: "bolt.fill",
                            isDisabled: model.holdings.isEmpty
                        ) { start() }
                    }
                }
            }
        }
    }

    /// Jev's read of the backdrop, and the figures behind it.
    private func marketLine(_ market: JEVMarketFacts, score: JEVScore?) -> some View {
        var parts: [String] = []
        if let vix = market.vix { parts.append("VIX \(String(format: "%.1f", vix))") }
        if let spx = market.sp500Return20D { parts.append(L10n.text("标普 20 日 \(DisplayFormat.percent(spx))")) }
        if let yield = market.tenYearYield { parts.append(L10n.text("10 年期") + " " + String(format: "%.2f%%", yield)) }
        return HStack(spacing: 6) {
            Text(L10n.text("市场环境")).appText(.caption, weight: .medium).foregroundStyle(.secondary)
            if let score {
                Text(JEVQuestions.marketLabel(score.score))
                    .appText(.caption, weight: .semibold)
                    .opacity(score.confidence >= JEVState.decisiveConfidence ? 1 : 0.5)
            }
            Text(parts.joined(separator: " · ")).appNumber(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func tally(_ count: Int, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").appNumber(.heading, weight: .semibold)
            Text(title).appText(.caption, weight: .medium).foregroundStyle(.secondary)
        }
    }
}

private struct JEVCallCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let call: JEVCall
    let isExpanded: Bool
    let isExplaining: Bool
    let explanationError: String?
    let toggle: () -> Void
    let explain: () -> Void

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: toggle) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            AssetLogo(ticker: call.ticker, logoSymbol: call.logoSymbol, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(call.name).appText(.body, weight: .semibold).lineLimit(1)
                                Text(call.ticker).appText(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if call.error == nil {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(call.state.title)
                                        .appText(.body, weight: .bold)
                                        .foregroundStyle(JEVLabels.stateColor(call.state, scheme: colorScheme))
                                    Text(call.note)
                                        .appText(.caption, weight: .medium)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }

                        if let error = call.error {
                            Text(L10n.message(error)).appText(.caption).foregroundStyle(CatfolioTheme.warning)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(JEVDimension.allCases) { dimension in
                                    if let score = call.score(dimension) {
                                        JEVScoreRow(dimension: dimension, score: score)
                                    }
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded && call.error == nil {
                    explanation
                    details
                }
            }
            .padding(.horizontal, SettingsTemplate.rowHorizontalPadding)
            .padding(.vertical, SettingsTemplate.rowVerticalPadding)
        }
    }

    /// The selected AI's reading of the scores, on request, marked as that.
    @ViewBuilder
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = call.explanation {
                Label(L10n.text("AI 对 Jev 评分的解读"), systemImage: "sparkles")
                    .appText(.caption, weight: .semibold)
                    .foregroundStyle(.secondary)
                Text(text)
                    .appText(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("这是设置中所选 AI 对 Jev 输出的事后解读，不是 Jev 自己的推理。"))
                    .appText(.micro, weight: .regular)
                    .foregroundStyle(.tertiary)
            } else {
                Button(action: explain) {
                    HStack(spacing: 8) {
                        if isExplaining { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                        Text(isExplaining ? L10n.text("正在解释…") : L10n.text("让 AI 解释这组评分"))
                            .appText(.callout, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .disabled(isExplaining)
            }
            if let explanationError {
                Text(L10n.message(explanationError))
                    .appText(.caption)
                    .foregroundStyle(CatfolioTheme.warning)
            }
        }
        .padding(.top, 4)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("发给 Jev 的数据")).appText(.caption, weight: .semibold).padding(.top, 4)
            let facts = call.facts
            factRow(L10n.text("今日 · 20 日 · 60 日"), [facts.todayChangePercent, facts.return20D, facts.return60D])
            factRow(L10n.text("距 50 日 · 200 日均线"), [facts.versusMA50, facts.versusMA200])
            factRow(L10n.text("距 52 周高点 · 低点"), [facts.fromHigh52W, facts.fromLow52W])
            factRow(L10n.text("60 日相对标普 500"), [facts.relativeTo60DSPY])
            HStack {
                Text(L10n.text("RSI · 仓位 · 浮盈")).appText(.caption).foregroundStyle(.secondary)
                Spacer()
                Text([facts.rsi14.map { String(format: "%.0f", $0) } ?? "—",
                      DisplayFormat.percent(facts.weightPercent, signed: false),
                      DisplayFormat.percent(facts.unrealizedGainPercent)].joined(separator: " · "))
                    .appNumber(.caption, weight: .medium)
            }
            if let options = facts.options {
                textRow(L10n.text("期权墙 put · call"), [options.putWall, options.callWall].map {
                    $0.map { String(format: "%.0f", $0) } ?? "—"
                }.joined(separator: " · ") + (options.putCallRatio.map { " · P/C \(String(format: "%.2f", $0))" } ?? ""))
            }
            if let volume = facts.volume {
                textRow(L10n.text("成交分布 · 距 POC"), [
                    volume.position == "above" ? L10n.text("价值区上方") : volume.position == "below" ? L10n.text("价值区下方") : L10n.text("价值区内"),
                    DisplayFormat.percent(volume.priceVersusPOC),
                ].joined(separator: " · "))
            }
            if let valuation = facts.valuation {
                textRow(L10n.text("市盈率 · 市销率 · 增速"), [
                    valuation.pe.map { String(format: "%.1f", $0) } ?? L10n.text("亏损"),
                    valuation.ps.map { String(format: "%.1f", $0) } ?? "—",
                    valuation.growthPercent.map { DisplayFormat.percent($0) } ?? "—",
                ].joined(separator: " · "))
            }
            if let sector = facts.sectorSentiment {
                textRow(L10n.text("半导体情绪"), [sector.score.map(String.init) ?? "—", sector.regime].joined(separator: " · "))
            }
        }
    }

    private func textRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).appText(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).appNumber(.caption, weight: .medium).lineLimit(1)
        }
    }

    private func factRow(_ title: String, _ values: [Double?]) -> some View {
        HStack {
            Text(title).appText(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(values.map { $0.map { DisplayFormat.percent($0) } ?? "—" }.joined(separator: " · "))
                .appNumber(.caption, weight: .medium)
        }
    }
}

/// One dimension: its name, a five-step track with Jev's score marked on it,
/// and the level in words. A low-confidence score is drawn faint.
private struct JEVScoreRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let dimension: JEVDimension
    let score: JEVScore

    private var isReliable: Bool { score.confidence >= JEVState.decisiveConfidence }

    /// Trend, momentum and options read good-high; stretch is best in the
    /// middle; risk reads bad-high; valuation reads expensive-high.
    private var tint: Color {
        switch dimension {
        case .trend, .momentum, .options:
            score.score >= 2.5 ? CatfolioTheme.gain(for: colorScheme)
                : score.score <= 1.5 ? CatfolioTheme.loss(for: colorScheme) : .secondary
        case .stretch:
            abs(score.score - 2) >= 1 ? CatfolioTheme.warning : .secondary
        case .risk:
            score.score >= 2.5 ? CatfolioTheme.loss(for: colorScheme) : .secondary
        case .valuation:
            score.score >= 2.5 ? CatfolioTheme.warning
                : score.score <= 1.5 ? CatfolioTheme.gain(for: colorScheme) : .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(dimension.title)
                .appText(.caption, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 4)
                    Circle()
                        .fill(tint)
                        .frame(width: 10, height: 10)
                        .offset(x: max(0, min(width - 10, width * score.score / 4 - 5)))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 12)
            Text(dimension.label(for: score.score))
                .appText(.caption, weight: .semibold)
                .foregroundStyle(tint)
                .frame(width: 64, alignment: .trailing)
        }
        .opacity(isReliable ? 1 : 0.45)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(dimension.title) \(dimension.label(for: score.score)) \(JEVLabels.confidence(score.confidence))")
    }
}

/// The entry on the 收益 page: the last report's tally, or how to start.
struct JEVTodayAttentionEntry: View {
    @Environment(AppModel.self) private var model
    /// Off when a tabbed header above it already names the section.
    var showsHeader = true

    var body: some View {
        if showsHeader {
            SettingsSection(L10n.text("JEV 今日关注")) { row }
        } else {
            SettingsCard { row }
        }
    }

    private var row: some View {
        let report = JEVReportCache.load(scope: JEVReportCache.scope(model: model))
        return Group {
            SettingsNavigationRow(
                icon: .symbol("bolt.fill"),
                title: report.map { report in
                    let counts = report.counts
                    return L10n.text("\(counts.bullish) 看多 · \(counts.neutral) 中性 · \(counts.bearish) 看空")
                } ?? L10n.text("让 JEV 描述每只持仓的状态"),
                subtitle: report.map { L10n.text("判断于 \($0.generatedAt.formatted(date: .abbreviated, time: .shortened))") }
                    ?? (JEVProvider.current.isConfigured ? L10n.text("基于行情指标的结构化判断")
                                                          : L10n.text("需要在 服务商 中填写 OpenRouter 或 Cloudflare 凭证"))
            ) {
                JEVTodayAttentionView()
            }
            .accessibilityIdentifier("performance.jev-attention")
        }
    }
}

/// Today's attention and JEV's, as two tabs of one section: the analysis's
/// cards, or JEV's structured call on each holding.
struct TodayAttentionTabs: View {
    enum Tab: String { case analysis, jev }
    @AppStorage("performance.attention.tab") private var tabRawValue = Tab.analysis.rawValue
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true

    private var tab: Tab { Tab(rawValue: tabRawValue) ?? .analysis }

    var body: some View {
        Group {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                tabButton(.analysis, title: L10n.text("今天值得关注"))
                tabButton(.jev, title: "JEV")
                Spacer(minLength: 12)
                NavigationLink {
                    if tab == .jev { JEVTodayAttentionView() } else { TodayAttentionView() }
                } label: {
                    HStack(spacing: 3) {
                        Text(L10n.text("更多"))
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .appText(.footnote, weight: .medium)
                    .foregroundStyle(SettingsTemplate.sectionHeader)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("performance.today-attention")
            }
            .padding(.top, SettingsTemplate.sectionHeaderTopSpacing)

            switch tab {
            case .analysis: TodayAttentionPreview(showsHeader: false)
            case .jev: JEVTodayAttentionEntry(showsHeader: false)
            }
        }
        .sensoryFeedback(.selection, trigger: tabRawValue) { _, _ in hapticsEnabled }
    }

    private func tabButton(_ value: Tab, title: String) -> some View {
        let isSelected = tab == value
        return Button { tabRawValue = value.rawValue } label: {
            Text(title)
                .appText(.body, weight: isSelected ? .semibold : .medium)
                .foregroundStyle(isSelected ? CatfolioTheme.primaryText : SettingsTemplate.sectionHeader)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
