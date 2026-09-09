import Foundation

// MARK: - Model

/// A security's open questions, each argued both ways.
///
/// This is deliberately not `PortfolioAttentionThesis`. That model takes one
/// stance on a holding and hangs supporting and counter evidence off it; this
/// one starts from the questions the market is actually split on and gives each
/// side its own claim and its own sources, because the useful thing about a
/// contested stock is the shape of the disagreement, not a verdict.
struct SecurityDebate: Codable, Sendable {
    var ticker: String
    var name: String
    var generatedAt: Date
    var questions: [SecurityDebateQuestion]
    /// Everything the model was given, so a claim can be traced back.
    var sources: [PortfolioAttentionSource]
    /// Whether the model reached the network itself, beyond the sources here.
    var usedModelWebSearch: Bool = false

    var id: String { ticker }
}

struct SecurityDebateQuestion: Codable, Sendable, Equatable, Identifiable {
    /// Short enough to sit on one line of a collapsed row.
    var question: String
    var bull: SecurityDebateSide
    var bear: SecurityDebateSide

    var id: String { question }
}

struct SecurityDebateSide: Codable, Sendable, Equatable {
    var claim: String
    /// Ids into `SecurityDebate.sources`. Ids rather than embedded copies so a
    /// source cited by both sides is stored once and counted correctly.
    var sourceIDs: [String]
}

extension SecurityDebate {
    func sources(for side: SecurityDebateSide) -> [PortfolioAttentionSource] {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return side.sourceIDs.compactMap { byID[$0] }
    }
}

// MARK: - Sources

/// Free, keyless research feeds.
///
/// No search API and no key: Google News for breadth of commentary, SEC EDGAR
/// full-text search for the primary documents, and Yahoo's own news index,
/// which is already the one this app uses elsewhere. A dedicated search
/// product would add a subscription and a second place for outages to come
/// from, and a self-hosted engine cannot be reached from the device at all.
///
/// What this does not get is article bodies. Google News gives headlines,
/// publishers and links; the paywalls and client-rendered pages behind them are
/// not worth the fragility. EDGAR is the exception and returns real documents.
struct SecurityDebateResearch {
    /// SEC asks callers to identify themselves, and its edge rejects a
    /// User-Agent containing a URL — the obvious "Catfolio/1.0 (+https://…)"
    /// returns 403 while the bare name and version returns 200. Name and
    /// version it is, which identifies the caller without putting anybody's
    /// address into a third-party request header.
    static let userAgent = "Catfolio/1.0"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.httpAdditionalHeaders = ["Accept-Language": "en-US,en;q=0.9"]
        return URLSession(configuration: configuration)
    }()

    func sources(ticker: String, name: String) async -> [PortfolioAttentionSource] {
        async let news = googleNews(ticker: ticker, name: name)
        async let yahoo = yahooNews(ticker: ticker, name: name)
        async let filings = secFilings(ticker: ticker, name: name)
        // Wires first: the ranking the reader is shown starts from the feed
        // most likely to carry a primary claim.
        let collected = await news
        let index = await yahoo
        let documents = await filings
        return Self.deduplicated(documents + collected + index)
    }

    // MARK: Google News

    func googleNews(ticker: String, name: String) async -> [PortfolioAttentionSource] {
        var components = URLComponents(string: "https://news.google.com/rss/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\(ticker) \(name) stock analyst"),
            URLQueryItem(name: "hl", value: "en-US"),
            URLQueryItem(name: "gl", value: "US"),
            URLQueryItem(name: "ceid", value: "US:en"),
        ]
        guard let url = components.url, let data = await Self.get(url) else { return [] }
        return Self.parseRSS(data, ticker: ticker, limit: 20)
    }

    /// Minimal RSS reader. `XMLParser` rather than a regex because Google's
    /// titles carry entities and the odd stray angle bracket.
    static func parseRSS(_ data: Data, ticker: String, limit: Int) -> [PortfolioAttentionSource] {
        final class Reader: NSObject, XMLParserDelegate {
            var items: [(title: String, link: String, source: String, date: String)] = []
            private var element = ""
            private var title = "", link = "", source = "", date = ""
            private var inItem = false

            func parser(_ parser: XMLParser, didStartElement name: String,
                        namespaceURI: String?, qualifiedName: String?,
                        attributes: [String: String]) {
                element = name
                if name == "item" { inItem = true; title = ""; link = ""; source = ""; date = "" }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                guard inItem else { return }
                switch element {
                case "title": title += string
                case "link": link += string
                case "source": source += string
                case "pubDate": date += string
                default: break
                }
            }
            func parser(_ parser: XMLParser, didEndElement name: String,
                        namespaceURI: String?, qualifiedName: String?) {
                if name == "item" {
                    inItem = false
                    items.append((title.trimmed, link.trimmed, source.trimmed, date.trimmed))
                }
                element = ""
            }
        }

        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        guard parser.parse() else { return [] }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"

        return reader.items.prefix(limit).enumerated().compactMap { index, item in
            guard let url = URL(string: item.link), !item.title.isEmpty else { return nil }
            let publisher = item.source.isEmpty ? "Google News" : item.source
            // Google appends " - Publisher" to every headline; the publisher is
            // already its own element, so the suffix is noise.
            var headline = item.title
            if !item.source.isEmpty, headline.hasSuffix(" - \(item.source)") {
                headline = String(headline.dropLast(item.source.count + 3))
            }
            return PortfolioAttentionSource(
                id: "\(ticker.lowercased())-gnews-\(index + 1)",
                title: headline,
                publisher: publisher,
                url: url,
                publishedAt: formatter.date(from: item.date),
                tier: Self.tier(for: publisher)
            )
        }
    }

    // MARK: Yahoo

    func yahooNews(ticker: String, name: String) async -> [PortfolioAttentionSource] {
        struct Payload: Decodable {
            struct News: Decodable {
                let title: String
                let publisher: String?
                let link: URL
                let providerPublishTime: Int?
            }
            let news: [News]?
        }
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\(ticker) \(name)"),
            URLQueryItem(name: "quotesCount", value: "0"),
            URLQueryItem(name: "newsCount", value: "10"),
        ]
        guard let url = components.url, let data = await Self.get(url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return (payload.news ?? []).enumerated().map { index, item in
            let publisher = item.publisher ?? "Unknown"
            return PortfolioAttentionSource(
                id: "\(ticker.lowercased())-yahoo-\(index + 1)",
                title: item.title,
                publisher: publisher,
                url: item.link,
                publishedAt: item.providerPublishTime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                tier: Self.tier(for: publisher)
            )
        }
    }

    // MARK: SEC

    /// EDGAR full-text search. Official and keyless.
    ///
    /// It contributes what was filed and when, not the text of it: `efts.sec.gov`
    /// serves search results to a plain "Catfolio/1.0", but `www.sec.gov`, where
    /// the documents live, answers 403 unless the User-Agent carries a contact
    /// address. Rather than put the user's own address into an outbound header,
    /// this links to the filing and leaves the reading to Safari. A contact
    /// address in settings would let the model read the bodies too.
    func secFilings(ticker: String, name: String) async -> [PortfolioAttentionSource] {
        struct Payload: Decodable {
            struct Hits: Decodable {
                struct Hit: Decodable {
                    struct Source: Decodable {
                        let display_names: [String]?
                        let file_type: String?
                        let file_date: String?
                        let root_forms: [String]?
                    }
                    let _id: String
                    let _source: Source
                }
                let hits: [Hit]
            }
            let hits: Hits
        }
        // Full-text search ranks by relevance, which for a long-lived filer
        // surfaces a 2004 exhibit ahead of last month's results. A window keeps
        // it to filings a reader could still be reacting to.
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let now = Date()
        var components = URLComponents(string: "https://efts.sec.gov/LATEST/search-index")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "\"\(name)\""),
            URLQueryItem(name: "forms", value: "8-K,10-Q,10-K"),
            URLQueryItem(name: "dateRange", value: "custom"),
            URLQueryItem(name: "startdt", value: day.string(from: now.addingTimeInterval(-120 * 86_400))),
            URLQueryItem(name: "enddt", value: day.string(from: now)),
        ]
        guard let url = components.url, let data = await Self.get(url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }

        return payload.hits.hits.prefix(6).enumerated().compactMap { index, hit in
            // "0001045810-26-000123:doc.htm" addresses a document inside a
            // filing; the archive path wants the accession number unpunctuated.
            let parts = hit._id.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let accession = parts[0]
            guard let cik = hit._source.display_names?.first.flatMap(Self.cik) else { return nil }
            // The filing's index page, not the document inside it: it is the
            // canonical human-facing URL and lists every exhibit, which is what
            // somebody following a citation wants.
            guard let url = URL(string: "https://www.sec.gov/Archives/edgar/data/"
                + "\(cik)/\(accession.replacingOccurrences(of: "-", with: ""))/\(accession)-index.htm")
            else { return nil }
            let form = hit._source.root_forms?.first ?? hit._source.file_type ?? "SEC"
            let filed = hit._source.file_date
            return PortfolioAttentionSource(
                id: "\(ticker.lowercased())-sec-\(index + 1)",
                title: filed.map { "\(form) filed \($0)" } ?? "\(form) filing",
                publisher: "SEC EDGAR",
                url: url,
                publishedAt: filed.flatMap(day.date(from:)),
                tier: "filing"
            )
        }
    }

    /// EDGAR renders a filer as "Name (TICKER) (CIK 0001045810)".
    static func cik(from displayName: String) -> String? {
        guard let range = displayName.range(of: "CIK ") else { return nil }
        let digits = displayName[range.upperBound...].prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        return String(Int(digits) ?? 0)
    }

    // MARK: Shared

    /// Publisher classes, in the order a reader should trust them. Kept as the
    /// same strings the attention report already uses so both can share a
    /// legend, with `filing` added for primary documents.
    static func tier(for publisher: String) -> String {
        let name = publisher.lowercased()
        if ["reuters", "bloomberg", "associated press", "ap news", "financial times",
            "wall street journal"].contains(where: name.contains) { return "wire" }
        if ["business wire", "globenewswire", "pr newswire", "sec"].contains(where: name.contains) {
            return "primary"
        }
        return "media"
    }

    /// One story reaches several feeds. Headlines are compared rather than URLs
    /// because Google wraps every link in its own redirect, so the same article
    /// never shares a URL across feeds.
    static func deduplicated(_ sources: [PortfolioAttentionSource]) -> [PortfolioAttentionSource] {
        var seen = Set<String>()
        return sources.filter { source in
            let key = source.title.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .prefix(9)
                .joined(separator: " ")
            return seen.insert(key.isEmpty ? source.url.absoluteString : key).inserted
        }
    }

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Generation

extension SecurityDebateResearch {
    /// What the model is asked for, and the shape it must answer in.
    ///
    /// The sources are numbered rather than pasted in full so a claim can cite
    /// `[3]` and be resolved back to a real row afterwards. A model that
    /// invents an id simply loses that citation — see
    /// `SecurityDebate.sources(for:)` — which is better than a claim that
    /// silently carries a fabricated link.
    static func prompt(
        ticker: String,
        name: String,
        sources: [PortfolioAttentionSource],
        analyst: NasdaqAnalystClient.Consensus?
    ) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        for source in sources {
            let when = source.publishedAt.map { " (\(day.string(from: $0)))" } ?? ""
            lines.append("- id=\(source.id) [\(source.tier)] \(source.publisher)\(when): \(source.title)")
        }

        var context = "Ticker: \(ticker)\nCompany: \(name)\n\nSources:\n" + lines.joined(separator: "\n")
        if let analyst {
            // The spread between the extremes is usually the most concrete
            // evidence that the market is split, so it is stated separately
            // rather than left for the model to infer from headlines.
            let parts = [
                analyst.low.map { "low \($0)" },
                analyst.mean.map { "mean \($0)" },
                analyst.high.map { "high \($0)" },
                analyst.rating.map { "consensus rating \($0)" },
            ].compactMap { $0 }
            if !parts.isEmpty {
                context += "\n\nAnalyst price targets: " + parts.joined(separator: ", ")
            }
        }

        return """
        \(context)

        Identify the 3 to 5 questions about this security that informed \
        investors currently disagree about. For each, give the strongest \
        version of the bullish case and the strongest version of the bearish \
        case. Argue each side as its best advocate would; do not hedge, do not \
        conclude, and do not recommend buying or selling.

        Rules:
        - Ground every claim in the sources above. Cite by id.
        - A side with no support in the sources gets an empty sourceIDs list \
        rather than an invented id.
        - Name the analysts, firms or filings the claim comes from where the \
        sources make that possible.
        - Question titles are at most 8 words.
        - Claims are 1 to 3 sentences.

        Return JSON only, no prose and no code fence:
        {"questions":[{"question":"...","bull":{"claim":"...","sourceIDs":["..."]},"bear":{"claim":"...","sourceIDs":["..."]}}]}
        """
    }

    /// Parse the model's answer. Tolerant of a code fence and of leading prose,
    /// because a model told twice not to add either still sometimes does.
    static func parse(
        _ text: String,
        ticker: String,
        name: String,
        sources: [PortfolioAttentionSource],
        usedModelWebSearch: Bool = false
    ) -> SecurityDebate? {
        struct Payload: Decodable { let questions: [SecurityDebateQuestion] }
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = body.firstIndex(of: "{"), let end = body.lastIndex(of: "}"), start < end {
            body = String(body[start...end])
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(body.utf8)),
              !payload.questions.isEmpty else { return nil }
        let known = Set(sources.map(\.id))
        // Drop citations the model made up rather than carrying them into a
        // source count the reader would then look for and not find.
        let questions = payload.questions.map { question in
            SecurityDebateQuestion(
                question: question.question,
                bull: SecurityDebateSide(claim: question.bull.claim,
                                         sourceIDs: question.bull.sourceIDs.filter(known.contains)),
                bear: SecurityDebateSide(claim: question.bear.claim,
                                         sourceIDs: question.bear.sourceIDs.filter(known.contains))
            )
        }
        return SecurityDebate(
            ticker: ticker, name: name, generatedAt: .now,
            questions: questions, sources: sources,
            usedModelWebSearch: usedModelWebSearch
        )
    }
}
