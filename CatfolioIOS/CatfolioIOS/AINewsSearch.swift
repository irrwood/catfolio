import Foundation

/// Request-local diagnostics: unrelated background requests never explain a chat failure.
enum NewsSearchTrace {
    @TaskLocal static var current: NewsSearchFailures?
}

final class NewsSearchFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []

    func record(_ outcome: DataSourceOutcome, source: DataSource) {
        guard outcome.isFailure else { return }
        let reason: String
        switch outcome {
        case .success: return
        case .offline: reason = L10n.text("网络连接不可用")
        case .timedOut: reason = L10n.text("请求超时")
        case .rateLimited: reason = L10n.text("请求过于频繁（429），稍后重试")
        case .httpStatus(let status): reason = "HTTP \(status)"
        case .unusable: reason = L10n.text("返回格式无法识别")
        case .transport: reason = L10n.text("连接失败")
        }
        let message = "\(source.title)：\(reason)"
        lock.lock()
        defer { lock.unlock() }
        if !failures.contains(message), failures.count < 8 { failures.append(message) }
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures.sorted()
    }
}

enum AINewsSearchError: LocalizedError {
    case noProviders, invalidQuery, noResults, sourcesFailed([String])

    var errorDescription: String? {
        switch self {
        case .noProviders: L10n.text("没有可用的新闻来源，请检查设置中的新闻来源开关和凭证。")
        case .invalidQuery: L10n.text("无法确定要搜索的公开主题，请在问题中注明公司或事件。")
        case .noResults: L10n.text("未找到符合当前来源和日期规则的相关新闻。")
        case .sourcesFailed(let messages): L10n.text("新闻来源获取失败：") + messages.joined(separator: "；")
        }
    }

    static func fallbackMessage(for error: Error) -> String {
        L10n.text("新闻搜索未完成：") + error.localizedDescription + "\n"
            + L10n.text("以下回答仅基于已有数据，不包含本次实时搜索结果。") + "\n\n"
    }
}

/// Query preparation is local. Search must never wait for a model to return JSON.
/// Only the typed question is considered; account snapshots are not search input.
enum AINewsQueryPlanner {
    static func queries(for question: String, language: String) async throws -> [NewsQuery] {
        try Task.checkCancellation()
        return try localQueries(for: question, language: language)
    }

    static func localQueries(for question: String, language: String) throws -> [NewsQuery] {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AINewsSearchError.invalidQuery
        }
        let text = publicSearchText(question)
        // Exact, explicit tickers can also use Yahoo/SEC/Finnhub. Ordinary words
        // ("a", "on", "it", "stock") must not become unrelated stock symbols.
        let pattern = #"(?<![A-Za-z0-9])\$?([A-Z][A-Z0-9.-]{1,14})(?![A-Za-z0-9])"#
        var companies: [NewsQuery] = []
        if let catalog = try? CompanyReferenceCatalog.bundled.get(),
           let expression = try? NSRegularExpression(pattern: pattern) {
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let symbol = String(text[range])
                let commonWords: Set<String> = ["AI", "IT", "ON", "US", "UK", "EU", "GDP", "CPI", "ETF", "CEO", "IPO", "NEWS", "STOCK", "THE", "AND", "FOR"]
                guard !commonWords.contains(symbol), let entry = catalog.entry(brokerSymbol: symbol),
                      !companies.contains(where: { $0.ticker == symbol }) else { continue }
                companies.append(NewsQuery(ticker: symbol, name: entry.name ?? symbol, language: language))
                if companies.count == 3 { break }
            }
        }
        if !companies.isEmpty { return companies }
        // Google News accepts ordinary company names and public event keywords;
        // neither a known ticker nor a machine-generated schema is necessary.
        let topic = text.isEmpty ? (language.hasPrefix("zh") ? "股市 财经" : "stock market financial news") : text
        return [NewsQuery(ticker: "", name: topic, language: language)]
    }

    static func publicSearchText(_ question: String) -> String {
        var text = String(question.prefix(2000))
        // Strip URLs (including query-string credentials), contact details and
        // labelled secrets/account identifiers before producing an external query.
        let privatePatterns = [
            #"(?i)https?://\S+|www\.\S+|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}"#,
            #"(?i)(?:api[ _-]?key|access[ _-]?token|token|password|secret|authorization|account(?:[ _-]?(?:id|number))?|密钥|密码|账号|账户号|手机号)\s*[:：=]?\s*[^\s,，;；。]+"#,
            #"(?i)\b(?:sk|pk)[-_][A-Za-z0-9_-]+\b"#,
            #"(?i)(?:[$£€¥￥]\s*\d[\d,.]*|\d[\d,.]*\s*(?:万|亿)?\s*(?:美元|美金|英镑|人民币|元|股|手|shares?\b|USD\b|GBP\b|EUR\b))"#,
            #"\b\d{6,}\b|\b[A-Za-z0-9_-]{24,}\b"#,
        ]
        for pattern in privatePatterns {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let chineseFillers = ["请帮我搜索", "帮我搜索", "请帮我查一下", "帮我查一下", "请告诉我", "请问", "帮我看看", "帮我查查", "帮我", "搜索一下", "搜索", "查询", "查一下", "查查", "看看", "有哪些", "有什么", "有没有", "为什么", "发生了什么", "最新消息", "最新新闻", "新闻", "消息", "最近", "今天", "目前", "近期", "现在", "我的持仓", "我的股票", "持仓", "我的", "我买了", "我买入", "我持有", "我有", "请", "一下", "如何", "怎么样"]
        for filler in chineseFillers.sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: filler, with: " ")
        }
        text = text.replacingOccurrences(of: #"(?i)\b(?:please|search|find|tell|show|me|what|is|are|the|latest|recent|news|about|today|happened|to|my|holdings|portfolio|i|own|hold|bought)\b"#,
                                         with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[?!？！,，。;；:：\"“”‘’()（）]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if ["的", "吗", "呢", "了", "有什么", "有"].contains(text) { text = "" }
        return String(text.prefix(180))
    }
}

struct AINewsSearch {
    var hub = NewsSourceHub()
    var readsArticles = NewsSettings.readsArticles
    var readDocuments: @Sendable ([PortfolioAttentionSource], NewsQuery) async -> [SecurityResearchDocument] = { sources, query in
        await SecurityDebateResearch().documents(sources: sources, ticker: query.ticker, name: query.name)
    }

    func evidence(for queries: [NewsQuery]) async throws -> AIWebEvidence {
        try Task.checkCancellation()
        guard !queries.isEmpty else { throw AINewsSearchError.invalidQuery }
        // Company feeds require a ticker; broad topics use the existing Google News feed.
        guard queries.contains(where: { query in hub.providers.contains { !$0.kind.requiresTicker || !query.ticker.isEmpty } }) else {
            throw AINewsSearchError.noProviders
        }
        let trace = NewsSearchFailures()
        let found = await NewsSearchTrace.$current.withValue(trace) { await hub.sources(for: queries) }
        try Task.checkCancellation()
        let all = queries.flatMap { found[$0.key] ?? [] }
        let candidates = Array(SecurityDebateResearch.candidates(all).prefix(8))
        guard !candidates.isEmpty else {
            if all.isEmpty, !trace.messages.isEmpty { throw AINewsSearchError.sourcesFailed(trace.messages) }
            throw AINewsSearchError.noResults
        }
        var documents: [SecurityResearchDocument] = []
        if readsArticles {
            for query in queries {
                let urls = Set((found[query.key] ?? []).map(\.url))
                let selected = Array(candidates.filter { urls.contains($0.url) }.prefix(3))
                guard !selected.isEmpty else { continue }
                documents += await readDocuments(selected, query)
                try Task.checkCancellation()
            }
        }
        return Self.evidence(sources: candidates, documents: documents)
    }

    static func evidence(sources: [PortfolioAttentionSource], documents: [SecurityResearchDocument]) -> AIWebEvidence {
        var links: [String] = []
        let rows = sources.map { source in
            let document = documents.first { $0.source.id == source.id }
            let cited = document?.source ?? source
            let title = cited.title.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            links.append("- [\(title)](<\(cited.url.absoluteString.replacingOccurrences(of: ">", with: "%3E"))>)")
            return """
            Title: \(source.title)
            Publisher: \(source.publisher)
            Published: \(source.publishedAt?.ISO8601Format() ?? "unknown")
            URL: \(cited.url.absoluteString)
            \(document.map { "Read article excerpt:\n" + String($0.text.prefix(5000)) }
                ?? "Headline metadata only; article body was not read. Do not infer details from this headline.")
            """
        }
        return AIWebEvidence(text: rows.joined(separator: "\n\n"), sources: links.joined(separator: "\n"), fetchedAt: Date())
    }
}
