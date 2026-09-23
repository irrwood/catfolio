import Foundation
import Observation

/// Where a request went, named the way the reader knows it. Several hosts can
/// be one source (SEC serves filings from three). A host outside the catalog
/// is still recorded, under its own name, so nothing fails out of sight.
struct DataSource: Hashable, Identifiable, Sendable {
    enum Kind: Int, CaseIterable, Sendable {
        case marketData, filings, news, ai, broker, other
    }

    let id: String
    let title: String
    let kind: Kind

    private static let catalog: [(hosts: [String], source: DataSource)] = [
        (["data.sec.gov", "www.sec.gov", "efts.sec.gov"], .init(id: "sec", title: "SEC EDGAR", kind: .filings)),
        (["query1.finance.yahoo.com", "query2.finance.yahoo.com", "fc.yahoo.com"],
         .init(id: "yahoo", title: "Yahoo Finance", kind: .marketData)),
        (["api.nasdaq.com", "www.nasdaq.com", "www.nasdaqtrader.com"], .init(id: "nasdaq", title: "Nasdaq", kind: .marketData)),
        (["financialmodelingprep.com"], .init(id: "fmp", title: "Financial Modeling Prep", kind: .marketData)),
        (["api.massive.com"], .init(id: "massive", title: "Massive", kind: .marketData)),
        (["cdn.cboe.com"], .init(id: "cboe", title: "Cboe", kind: .marketData)),
        (["stockcharts.com"], .init(id: "stockcharts", title: "StockCharts", kind: .marketData)),
        (["etf.dws.com"], .init(id: "dws", title: "DWS ETF", kind: .marketData)),
        (["gamma-api.polymarket.com", "polymarket.com"], .init(id: "polymarket", title: "Polymarket", kind: .marketData)),
        (["finnhub.io"], .init(id: "finnhub", title: "Finnhub", kind: .news)),
        (["api.gdeltproject.org"], .init(id: "gdelt", title: "GDELT", kind: .news)),
        (["news.google.com"], .init(id: "google-news", title: "Google News", kind: .news)),
        (["api.openai.com", "chatgpt.com", "auth.openai.com"], .init(id: "openai", title: "ChatGPT", kind: .ai)),
        (["api.deepseek.com"], .init(id: "deepseek", title: "DeepSeek", kind: .ai)),
        (["openrouter.ai"], .init(id: "openrouter", title: "OpenRouter", kind: .ai)),
        (["api.cloudflare.com"], .init(id: "cloudflare", title: "Cloudflare Workers AI", kind: .ai)),
        (["live.trading212.com", "demo.trading212.com"], .init(id: "trading212", title: "Trading 212", kind: .broker)),
        (["api.snaptrade.com"], .init(id: "snaptrade", title: "SnapTrade", kind: .broker)),
        (["ndcdyn.interactivebrokers.com"], .init(id: "ibkr", title: "Interactive Brokers Flex", kind: .broker)),
        (["open.moomoo.com", "webapi.moomoo.com"], .init(id: "moomoo", title: "moomoo", kind: .broker)),
    ]

    /// The source behind a URL, from its host alone. Local files are not a source.
    static func of(_ url: URL?) -> DataSource? {
        guard let url, !url.isFileURL, let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if let known = catalog.first(where: { $0.hosts.contains(host) }) { return known.source }
        return DataSource(id: "host:" + host, title: host, kind: .other)
    }

    static func named(_ id: String) -> DataSource? {
        catalog.first { $0.source.id == id }?.source
    }
}

/// What one request, or one read of what it returned, came to.
enum DataSourceOutcome: Equatable, Sendable {
    case success
    /// A reply that was not 2xx. 429 is kept apart: it means wait, not broken.
    case httpStatus(Int)
    case rateLimited
    case offline
    case timedOut
    case transport(String)
    /// The request went through, but what came back could not be used — a
    /// filing without the lines a statement needs, a reply in a new shape.
    case unusable(String)

    var isFailure: Bool { self != .success }
}

/// Fixed descriptions for replies that arrived successfully but could not be
/// used. Callers never need to pass response bodies or server error messages.
enum DataSourceDataIssue: Sendable {
    case invalidFormat
    case missingRequiredFields
    case emptyResult
    case providerRejected

    var description: String {
        switch self {
        case .invalidFormat: "返回格式无法识别"
        case .missingRequiredFields: "缺少必需字段"
        case .emptyResult: "没有可用数据"
        case .providerRejected: "数据源拒绝了请求"
        }
    }
}

struct DataSourceEvent: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let outcome: DataSourceOutcome
    /// Retained for the status-row API. Subjects are intentionally never
    /// stored: even a ticker may reveal what the reader owns or researched.
    let subject: String?
}

struct DataSourceStatus: Sendable {
    var lastSuccess: Date?
    var lastEvent: DataSourceEvent?
    /// Newest first, a handful: enough to tell one bad reply from a pattern.
    var recentFailures: [DataSourceEvent] = []
    var successCount = 0
    var failureCount = 0

    var isFailing: Bool { lastEvent?.outcome.isFailure ?? false }
}

/// Every source's last word, this launch. Only the source, outcome and time
/// are kept — never a URL, query, subject or response body, which may
/// contain the reader's API key or portfolio data.
///
/// Before this, a source could fail for weeks without anyone knowing: SEC
/// refused every request over a bad User-Agent and the app quietly used
/// Nasdaq; SoFi's statements came back empty with no reason given.
@MainActor @Observable
final class DataSourceHealth {
    static let shared = DataSourceHealth()

    private(set) var statuses: [DataSource: DataSourceStatus] = [:]
    private static let failuresKept = 12
    private static let sourcesKept = 100

    /// Only fixed, audited labels may reach the UI. This also protects direct
    /// `apply` calls, not only the request wrapper.
    private static func safeOutcome(_ outcome: DataSourceOutcome) -> DataSourceOutcome {
        switch outcome {
        case .transport(let detail):
            if detail == "非 HTTP 响应" { return outcome }
            if detail.range(of: #"^URLError -?[0-9]{1,5}$"#, options: .regularExpression) != nil {
                return .transport(detail)
            }
            return .transport("其他连接错误")
        case .unusable(let reason):
            let allowed: Set<String> = [
                DataSourceDataIssue.invalidFormat.description,
                DataSourceDataIssue.missingRequiredFields.description,
                DataSourceDataIssue.emptyResult.description,
                DataSourceDataIssue.providerRejected.description,
                // Older call sites that already use fixed, audited wording.
                "Company Facts 的格式无法识别",
                "申报里没有能组成报表的标签",
                "返回里的状态码拒绝了请求",
                "没有这只证券的报表",
            ]
            return .unusable(allowed.contains(reason) ? reason : DataSourceDataIssue.invalidFormat.description)
        default:
            return outcome
        }
    }

    func apply(_ outcome: DataSourceOutcome, for source: DataSource, subject: String? = nil, at date: Date = Date()) {
        let outcome = Self.safeOutcome(outcome)
        var status = statuses[source] ?? DataSourceStatus()
        let event = DataSourceEvent(date: date, outcome: outcome, subject: nil)
        // Recording can arrive on the main actor in a different order from
        // network completion. Older events still count, but cannot overwrite
        // the newest result or make a recovered source look broken again.
        if status.lastEvent == nil || date >= status.lastEvent!.date {
            status.lastEvent = event
        }
        if outcome.isFailure {
            status.failureCount += 1
            status.recentFailures.append(event)
            status.recentFailures.sort { $0.date > $1.date }
            status.recentFailures = Array(status.recentFailures.prefix(Self.failuresKept))
        } else {
            status.successCount += 1
            if status.lastSuccess == nil || date > status.lastSuccess! { status.lastSuccess = date }
        }
        statuses[source] = status
        if statuses.count > Self.sourcesKept {
            // Keep known providers in preference to unknown, older hosts.
            let victim = statuses.keys.min { lhs, rhs in
                let lhsKnown = !lhs.id.hasPrefix("host:")
                let rhsKnown = !rhs.id.hasPrefix("host:")
                if lhsKnown != rhsKnown { return !lhsKnown }
                return (statuses[lhs]?.lastEvent?.date ?? .distantPast)
                    < (statuses[rhs]?.lastEvent?.date ?? .distantPast)
            }
            if let victim { statuses.removeValue(forKey: victim) }
        }
    }

    /// Sources that have been used this launch, failing first.
    var ordered: [(source: DataSource, status: DataSourceStatus)] {
        statuses.map { ($0.key, $0.value) }.sorted { lhs, rhs in
            if lhs.status.isFailing != rhs.status.isFailing { return lhs.status.isFailing }
            if lhs.source.kind != rhs.source.kind { return lhs.source.kind.rawValue < rhs.source.kind.rawValue }
            return lhs.source.title < rhs.source.title
        }
    }

    var failingCount: Int { statuses.values.filter(\.isFailing).count }

    // MARK: Recording from anywhere

    /// For a problem found after the request succeeded: the reply was read and
    /// could not be used.
    nonisolated static func reportUnusable(_ source: DataSource?, issue: DataSourceDataIssue, subject: String? = nil) {
        guard let source else { return }
        let date = Date()
        Task { @MainActor in shared.apply(.unusable(issue.description), for: source, at: date) }
    }

    /// Compatibility for fixed messages already used by financial parsers.
    /// Unknown strings become a generic issue so response text cannot leak.
    nonisolated static func reportUnusable(_ source: DataSource?, _ reason: String, subject: String? = nil) {
        guard let source else { return }
        let date = Date()
        Task { @MainActor in shared.apply(.unusable(reason), for: source, at: date) }
    }

    nonisolated static func record(_ url: URL?, response: URLResponse) async {
        guard let source = DataSource.of(url) else { return }
        let outcome: DataSourceOutcome
        switch (response as? HTTPURLResponse)?.statusCode {
        case .none: outcome = .transport("非 HTTP 响应")
        case .some(200...299), .some(304): outcome = .success
        case .some(429): outcome = .rateLimited
        case .some(let status): outcome = .httpStatus(status)
        }
        let date = Date()
        await shared.apply(outcome, for: source, at: date)
    }

    nonisolated static func record(_ url: URL?, error: Error) async {
        guard let source = DataSource.of(url), let outcome = outcome(for: error) else { return }
        let date = Date()
        await shared.apply(outcome, for: source, at: date)
    }

    /// Cancellation is not a failure: a page that closes cancels its requests.
    nonisolated static func outcome(for error: Error) -> DataSourceOutcome? {
        if error is CancellationError { return nil }
        guard let urlError = error as? URLError else { return .transport("其他连接错误") }
        switch urlError.code {
        case .cancelled: return nil
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut: return .timedOut
        default: return .transport("URLError \(urlError.code.rawValue)")
        }
    }
}

extension URLSession {
    /// `data(for:)`, with the outcome recorded against its source. The reply
    /// and any error are passed through unchanged; callers still decide what
    /// a status means for them.
    func recordedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let result = try await data(for: request)
            await DataSourceHealth.record(request.url, response: result.1)
            return result
        } catch {
            await DataSourceHealth.record(request.url, error: error)
            throw error
        }
    }

    func recordedData(from url: URL) async throws -> (Data, URLResponse) {
        try await recordedData(for: URLRequest(url: url))
    }

    func recordedUpload(for request: URLRequest, from bodyData: Data) async throws -> (Data, URLResponse) {
        do {
            let result = try await upload(for: request, from: bodyData)
            await DataSourceHealth.record(request.url, response: result.1)
            return result
        } catch {
            await DataSourceHealth.record(request.url, error: error)
            throw error
        }
    }

    func recordedUpload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        do {
            let result = try await upload(for: request, fromFile: fileURL)
            await DataSourceHealth.record(request.url, response: result.1)
            return result
        } catch {
            await DataSourceHealth.record(request.url, error: error)
            throw error
        }
    }

    /// Streaming replies: the status is recorded when the headers arrive.
    func recordedBytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do {
            let result = try await bytes(for: request)
            await DataSourceHealth.record(request.url, response: result.1)
            return result
        } catch {
            await DataSourceHealth.record(request.url, error: error)
            throw error
        }
    }
}
