import Foundation

/// Bearish / neutral / bullish.
///
/// FMP reports five buckets and Nasdaq three, but the card has only ever drawn
/// the three-way collapse. Storing three keeps both providers honest: padding
/// Nasdaq out to five would mean inventing the two it does not measure.
struct RatingSpread: Codable, Equatable, Sendable {
    let bearish: Int
    let neutral: Int
    let bullish: Int

    var total: Int { bearish + neutral + bullish }

    init?(bearish: Int, neutral: Int, bullish: Int) {
        guard bearish >= 0, neutral >= 0, bullish >= 0 else { return nil }
        guard bearish + neutral + bullish > 0 else { return nil }
        self.bearish = bearish
        self.neutral = neutral
        self.bullish = bullish
    }

    /// FMP order: strongSell, sell, hold, buy, strongBuy.
    init?(fiveBucket counts: [Int]) {
        guard counts.count == 5 else { return nil }
        self.init(
            bearish: counts[0] + counts[1],
            neutral: counts[2],
            bullish: counts[3] + counts[4]
        )
    }
}

enum NasdaqAnalystError: LocalizedError, Equatable {
    case unknownSymbol
    case noCoverage
    case service(String)

    var errorDescription: String? {
        switch self {
        case .unknownSymbol: "Nasdaq 没有这个代码的记录。"
        case .noCoverage: "Nasdaq 没有这只证券的分析师覆盖。"
        case let .service(message): "Nasdaq：\(message)"
        }
    }
}

/// A free, key-less fallback for analyst coverage, on the host the app already
/// uses for financial statements. Exists so the consensus card still works when
/// the FMP quota is exhausted — a 429 there used to leave the card with nothing.
actor NasdaqAnalystClient {
    static let shared = NasdaqAnalystClient()

    struct Consensus: Sendable {
        let low: Double?
        let mean: Double?
        let high: Double?
        let ratings: RatingSpread?
        let rating: String?
    }

    private var cache: [String: (value: Consensus, at: Date)] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    func consensus(symbol: String) async throws -> Consensus {
        let key = symbol.uppercased()
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 3600 { return hit.value }

        let targets = try await targetPrice(symbol: key)
        // The rating word is a nicety; losing it must not lose the targets.
        let rating = try? await meanRating(symbol: key)
        let value = Consensus(
            low: targets.low, mean: targets.mean, high: targets.high,
            ratings: targets.ratings, rating: rating
        )
        cache[key] = (value, Date())
        return value
    }

    // MARK: - Endpoints

    private struct TargetPriceEnvelope: Decodable {
        struct Data: Decodable {
            struct Overview: Decodable {
                let lowPriceTarget: Double?
                let highPriceTarget: Double?
                let priceTarget: Double?
                let buy: Int?
                let sell: Int?
                let hold: Int?
            }
            let consensusOverview: Overview?
        }
        let data: Data?
        let status: Status?
    }

    private struct RatingsEnvelope: Decodable {
        struct Data: Decodable { let meanRatingType: String? }
        let data: Data?
        let status: Status?
    }

    /// Nasdaq answers 200 for everything; the real outcome is in here. Treating
    /// the HTTP status as the result reports "查无此票" as a successful empty
    /// response, which is exactly the kind of silent wrong answer this card
    /// must not produce.
    struct Status: Decodable {
        struct Message: Decodable {
            let code: Int?
            let errorMessage: String?

            init(code: Int?, errorMessage: String? = nil) {
                self.code = code
                self.errorMessage = errorMessage
            }
        }
        let rCode: Int?
        let bCodeMessage: [Message]?

        init(rCode: Int?, bCodeMessage: [Message]?) {
            self.rCode = rCode
            self.bCodeMessage = bCodeMessage
        }
    }

    private func targetPrice(
        symbol: String
    ) async throws -> (low: Double?, mean: Double?, high: Double?, ratings: RatingSpread?) {
        let envelope: TargetPriceEnvelope = try await get(path: "analyst/\(symbol)/targetprice")
        try Self.validate(envelope.status)
        guard let overview = envelope.data?.consensusOverview else {
            throw NasdaqAnalystError.noCoverage
        }
        let ratings = RatingSpread(
            bearish: overview.sell ?? 0,
            neutral: overview.hold ?? 0,
            bullish: overview.buy ?? 0
        )
        return (overview.lowPriceTarget, overview.priceTarget, overview.highPriceTarget, ratings)
    }

    private func meanRating(symbol: String) async throws -> String? {
        let envelope: RatingsEnvelope = try await get(path: "analyst/\(symbol)/ratings")
        try Self.validate(envelope.status)
        let value = envelope.data?.meanRatingType?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    static func validate(_ status: Status?) throws {
        guard let status else { return }
        let message = status.bCodeMessage?.first
        if status.rCode == 400 || message?.code == 1001 { throw NasdaqAnalystError.unknownSymbol }
        if message?.code == 1002 { throw NasdaqAnalystError.noCoverage }
        if let rCode = status.rCode, !(200..<300).contains(rCode) {
            throw NasdaqAnalystError.service(message?.errorMessage ?? "请求失败（\(rCode)）")
        }
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.nasdaq.com/api/\(encoded)") else {
            throw NasdaqAnalystError.unknownSymbol
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NasdaqAnalystError.service("网络请求失败")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NasdaqAnalystError.service("返回格式无法识别")
        }
    }
}
