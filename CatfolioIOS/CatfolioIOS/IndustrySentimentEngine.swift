import Foundation

/// A port of Core's `VolatilityRegimeEngine` v1.1 (`core/volatility/__init__.py`),
/// kept step for step so a snapshot the phone computes is the snapshot Core
/// would export from the same data. Changing the method here without
/// changing it there makes the two disagree; `IndustrySentimentEngineTests`
/// pins the port to outputs from the Python engine.
enum IndustrySentimentEngine {
    struct VolatilityDay: Sendable, Equatable {
        let date: String
        let close: Double
    }

    struct PriceDay: Sendable, Equatable {
        let date: String
        let open: Double
        let high: Double
        let low: Double
        let close: Double
        let volume: Double
    }

    enum EngineError: Error {
        case invalidObservation
        case duplicateDate
        case noVolatility
    }

    /// Core's `SEMICONDUCTORS` set: what counts as exposure on the page.
    static let semiconductors = ["NVDA", "AMD", "TSM", "AVGO", "QCOM", "INTC", "MU", "AMAT", "LRCX", "KLAC",
                                 "ASML", "MRVL", "NXPI", "ADI", "TXN", "MCHP", "ON", "MPWR", "SMH", "SOXX"]

    /// The exported snapshot as a JSON object with Core's snake_case keys,
    /// so it goes through `IndustrySentimentSnapshot.decode` and its checks
    /// exactly as an exported file would.
    static func evaluate(volatility: [VolatilityDay], prices: [PriceDay], asOf: String) throws -> [String: Any] {
        var vx: [String: Double] = [:]
        for row in volatility where row.date <= asOf {
            guard row.close.isFinite, row.close > 0 else { throw EngineError.invalidObservation }
            guard vx[row.date] == nil else { throw EngineError.duplicateDate }
            vx[row.date] = row.close
        }
        var smh: [String: PriceDay] = [:]
        for row in prices where row.date <= asOf {
            let values = [row.open, row.high, row.low, row.close]
            guard values.allSatisfy({ $0.isFinite && $0 > 0 }), row.volume.isFinite, row.volume >= 0,
                  row.low <= min(row.open, row.close), max(row.open, row.close) <= row.high else {
                throw EngineError.invalidObservation
            }
            guard smh[row.date] == nil else { throw EngineError.duplicateDate }
            smh[row.date] = row
        }
        let days = vx.keys.sorted()
        guard let day = days.last else { throw EngineError.noVolatility }

        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }

        var history: [[String: Any]] = []
        history.reserveCapacity(days.count)
        for (index, date) in days.enumerated() {
            let window = days[max(0, index - 19)...index].map { vx[$0]! }
            history.append([
                "date": date,
                "close": vx[date]!,
                "ma20": window.count == 20 ? mean(window) : NSNull(),
                "volume": smh[date].map { $0.volume as Any } ?? NSNull(),
            ])
        }

        let values = days.suffix(252).map { vx[$0]! }
        let last = values[values.count - 1]
        let window = Array(values.suffix(20))
        let ma: Double? = window.count == 20 ? mean(window) : nil
        let std: Double? = ma.map { average in
            // Python's `statistics.pstdev`: the population deviation.
            (window.map { ($0 - average) * ($0 - average) }.reduce(0, +) / Double(window.count)).squareRoot()
        }
        let z: Double? = {
            guard let ma else { return nil }
            if let std, std != 0 { return (last - ma) / std }
            return 0
        }()
        let below = Double(values.filter { $0 < last }.count)
        let equal = Double(values.filter { $0 == last }.count)
        let percentile = 100 * (below + 0.5 * equal) / Double(values.count)
        let delta: Double? = values.count > 1 ? last - values[values.count - 2] : nil
        let change: Double? = delta.map { $0 / values[values.count - 2] * 100 }
        // The same two sessions on both series; never mix differently dated returns.
        let paired = days.count > 1 && days.suffix(2).allSatisfy { smh[$0] != nil } && smh.keys.max() == day
        let priceChange: Double? = paired ? (smh[day]!.close / smh[days[days.count - 2]]!.close - 1) * 100 : nil
        let ready = values.count == 252

        var score: Int?
        if let z, let change {
            let raw = 100 - (0.5 * percentile + 0.3 * 50 * (1 + erf(z / 2.0.squareRoot()))
                             + 0.2 * min(100, max(0, 50 + change * 5)))
            // Python's `round` rounds halves to even.
            score = Int(min(100, max(0, raw)).rounded(.toNearestOrEven))
        }

        var regime = "Unknown"
        if paired, z != nil, let priceChange, let change {
            if priceChange < 0 && change > 0 {
                regime = percentile >= 90 && ((z ?? 0) >= 2 || change >= 10) ? "Panic" : "Fear"
            } else if priceChange >= 0 && change > 0 {
                regime = "Hedging"
            } else if priceChange > 0 && change < 0 {
                regime = "Risk-on"
            } else {
                regime = "Neutral"
            }
        }

        let dayFormatter = IndustrySentimentSnapshot.dateFormatter
        let staleDays = dayFormatter.date(from: asOf).flatMap { now in
            dayFormatter.date(from: day).map { Int(now.timeIntervalSince($0) / 86_400) }
        } ?? 0

        func json(_ value: Double?) -> Any { value.map { $0 as Any } ?? NSNull() }

        return [
            "version": "1.1",
            "as_of": day,
            "stale": staleDays > 4,
            "sample_count": values.count,
            "score": score.map { $0 as Any } ?? NSNull(),
            "score_status": score == nil ? "insufficient" : ready ? "complete" : "provisional",
            "regime": regime,
            "close": last,
            "ma20": json(ma),
            "z20": json(z),
            "percentile": ready ? percentile as Any : NSNull(),
            "available_percentile": percentile,
            "change": json(delta),
            "change_pct": json(change),
            "price_change_pct": json(priceChange),
            "aligned": paired,
            "history": history,
            "exposure_symbols": semiconductors.sorted(),
            "sector": "semiconductors",
            "volatility_symbol": "VXSMH",
            "price_symbol": "SMH",
        ]
    }
}

/// Fetches what Core's collector fetches — Cboe's VXSMH history and Yahoo's
/// SMH daily bars — and runs the engine on the phone.
struct IndustrySentimentClient {
    static let volatilityURL = URL(string: "https://cdn.cboe.com/api/global/us_indices/daily_prices/VXSMH_History.csv")!
    static let pricesURL = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/SMH?range=2y&interval=1d")!

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        return URLSession(configuration: configuration)
    }()

    /// The exported-file form, ready for `IndustrySentimentSnapshot.decode`
    /// and for writing to the page's cache.
    func snapshotData(now: Date = Date()) async throws -> Data {
        async let volatilityRaw = Self.get(Self.volatilityURL)
        async let pricesRaw = Self.get(Self.pricesURL)
        let (vxData, smhData) = try await (volatilityRaw, pricesRaw)

        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = newYork.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        // Core's conservative 18:00 New York cutoff: never use an intraday daily bar.
        let today = newYork.startOfDay(for: now)
        let cutoffDay = newYork.component(.hour, from: now) >= 18
            ? newYork.date(byAdding: .day, value: 1, to: today)! : today
        let cutoff = formatter.string(from: cutoffDay)

        let volatility = try Self.parseVolatility(vxData).filter { $0.date < cutoff }
        let prices = try Self.parsePrices(smhData, formatter: formatter).filter { $0.date < cutoff }
        let asOf = formatter.string(from: now)
        let object = try IndustrySentimentEngine.evaluate(volatility: volatility, prices: prices, asOf: asOf)
        let data = try JSONSerialization.data(withJSONObject: object)
        // Only hand back what the page itself would accept.
        _ = try IndustrySentimentSnapshot.decode(data)
        return data
    }

    static func parseVolatility(_ data: Data) throws -> [IndustrySentimentEngine.VolatilityDay] {
        guard var text = String(data: data, encoding: .utf8) else { throw LocalServiceError.invalidResponse }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first?.uppercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }),
              let dateIndex = header.firstIndex(of: "DATE"), let closeIndex = header.firstIndex(of: "CLOSE") else {
            throw LocalServiceError.invalidResponse
        }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "MM/dd/yyyy"
        let output = IndustrySentimentSnapshot.dateFormatter
        return lines.dropFirst().compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > max(dateIndex, closeIndex),
                  let date = parser.date(from: fields[dateIndex].trimmingCharacters(in: .whitespaces)),
                  let close = Double(fields[closeIndex].trimmingCharacters(in: .whitespaces)) else { return nil }
            return .init(date: output.string(from: date), close: close)
        }
    }

    static func parsePrices(_ data: Data, formatter: DateFormatter) throws -> [IndustrySentimentEngine.PriceDay] {
        struct Payload: Decodable {
            struct Chart: Decodable {
                struct Result: Decodable {
                    struct Meta: Decodable { let symbol: String }
                    struct Indicators: Decodable {
                        struct Quote: Decodable {
                            let open: [Double?]
                            let high: [Double?]
                            let low: [Double?]
                            let close: [Double?]
                            let volume: [Double?]
                        }
                        let quote: [Quote]
                    }
                    let meta: Meta
                    let timestamp: [Int]
                    let indicators: Indicators
                }
                let result: [Result]
            }
            let chart: Chart
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let result = payload.chart.result.first, result.meta.symbol == "SMH",
              let quote = result.indicators.quote.first else { throw LocalServiceError.invalidResponse }
        return result.timestamp.enumerated().compactMap { index, stamp in
            guard index < quote.close.count,
                  let open = quote.open[index], let high = quote.high[index], let low = quote.low[index],
                  let close = quote.close[index], let volume = quote.volume[index] else { return nil }
            return .init(date: formatter.string(from: Date(timeIntervalSince1970: TimeInterval(stamp))),
                         open: open, high: high, low: low, close: close, volume: volume)
        }
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 Catfolio", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 5_000_000 else { throw LocalServiceError.invalidResponse }
        return data
    }
}
