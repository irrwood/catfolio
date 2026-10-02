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

    /// Core's `SECTORS` table (`core/volatility/__init__.py`), in the same
    /// order, so the two agree on what a snapshot may claim to be.
    ///
    /// `exposure` is empty where matching holdings to the market is not a
    /// claim that holds up — owning gold is not owning the twenty
    /// semiconductor names — and the portfolio card stays hidden there.
    struct Sector: Sendable, Identifiable, Equatable {
        let key: String
        let volatilitySymbol: String
        let priceSymbol: String
        var exposure: [String] = []
        /// No Cboe index exists for the market: its volatility is the price's
        /// own 20-day realised volatility, annualised, in percent.
        var usesRealizedVolatility = false
        var id: String { key }
        /// Localised on read: the table is data, the wording is the page's.
        var title: String {
            switch key {
            case "semiconductors": L10n.text("半导体")
            case "nasdaq-100": L10n.text("纳斯达克 100")
            case "large-caps": L10n.text("美股大盘")
            case "small-caps": L10n.text("美股小盘")
            case "gold": L10n.text("黄金")
            case "crude-oil": L10n.text("原油")
            case "treasuries": L10n.text("长期美债")
            case "emerging-markets": L10n.text("新兴市场")
            case "china": L10n.text("中国")
            case "brazil": L10n.text("巴西")
            case "gold-miners": L10n.text("金矿股")
            case "dow": L10n.text("道琼斯")
            case "technology": L10n.text("科技")
            case "financials": L10n.text("金融")
            case "health-care": L10n.text("医疗保健")
            case "energy": L10n.text("能源")
            case "industrials": L10n.text("工业")
            case "consumer-discretionary": L10n.text("可选消费")
            case "consumer-staples": L10n.text("必需消费")
            case "utilities": L10n.text("公用事业")
            case "materials": L10n.text("原材料")
            case "real-estate": L10n.text("房地产")
            case "communication-services": L10n.text("通信服务")
            default: key
            }
        }
    }

    static let sectors: [Sector] = [
        Sector(key: "semiconductors", volatilitySymbol: "VXSMH", priceSymbol: "SMH", exposure: semiconductors.sorted()),
        Sector(key: "nasdaq-100", volatilitySymbol: "VXN", priceSymbol: "QQQ"),
        Sector(key: "large-caps", volatilitySymbol: "VIX", priceSymbol: "SPY"),
        Sector(key: "small-caps", volatilitySymbol: "RVX", priceSymbol: "IWM"),
        Sector(key: "gold", volatilitySymbol: "GVZ", priceSymbol: "GLD"),
        Sector(key: "crude-oil", volatilitySymbol: "OVX", priceSymbol: "USO"),
        Sector(key: "treasuries", volatilitySymbol: "VXTLT", priceSymbol: "TLT"),
        Sector(key: "emerging-markets", volatilitySymbol: "VXEEM", priceSymbol: "EEM"),
        Sector(key: "china", volatilitySymbol: "VXFXI", priceSymbol: "FXI"),
        Sector(key: "brazil", volatilitySymbol: "VXEWZ", priceSymbol: "EWZ"),
        Sector(key: "gold-miners", volatilitySymbol: "VXGDX", priceSymbol: "GDX"),
        Sector(key: "dow", volatilitySymbol: "VXD", priceSymbol: "DIA"),
    ] + sectorFunds.map { key, fund in
        Sector(key: key, volatilitySymbol: "\(fund) RV20", priceSymbol: fund, usesRealizedVolatility: true)
    }

    /// The eleven GICS sectors, each through its SPDR fund. Cboe publishes
    /// no volatility index for them, so these are read from realised moves.
    static let sectorFunds: [(String, String)] = [
        ("technology", "XLK"), ("financials", "XLF"), ("health-care", "XLV"), ("energy", "XLE"),
        ("industrials", "XLI"), ("consumer-discretionary", "XLY"), ("consumer-staples", "XLP"),
        ("utilities", "XLU"), ("materials", "XLB"), ("real-estate", "XLRE"), ("communication-services", "XLC"),
    ]

    /// Close-to-close volatility over the trailing 20 sessions, annualised
    /// over 252, in percent: the same scale a Cboe index is quoted on.
    static func realizedVolatility(_ prices: [PriceDay], window: Int = 20) -> [VolatilityDay] {
        let sorted = prices.sorted { $0.date < $1.date }
        guard sorted.count > window else { return [] }
        let returns = zip(sorted, sorted.dropFirst()).map { log($1.close / $0.close) }
        return (window..<sorted.count).compactMap { index in
            let slice = returns[(index - window)..<index]
            let mean = slice.reduce(0, +) / Double(window)
            let variance = slice.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(window - 1)
            let value = (variance * 252).squareRoot() * 100
            return value.isFinite && value > 0 ? VolatilityDay(date: sorted[index].date, close: value) : nil
        }
    }

    static func sector(_ key: String) -> Sector? { sectors.first { $0.key == key } }

    /// The exported snapshot as a JSON object with Core's snake_case keys,
    /// so it goes through `IndustrySentimentSnapshot.decode` and its checks
    /// exactly as an exported file would.
    static func evaluate(volatility: [VolatilityDay], prices: [PriceDay], asOf: String,
                         sector: Sector = sectors[0]) throws -> [String: Any] {
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
            "exposure_symbols": sector.exposure,
            "sector": sector.key,
            "volatility_symbol": sector.volatilitySymbol,
            "price_symbol": sector.priceSymbol,
        ]
    }
}

/// Fetches what Core's collector fetches — a Cboe volatility history and the
/// matching Yahoo daily bars — and runs the engine on the phone.
struct IndustrySentimentClient {
    static func volatilityURL(_ sector: IndustrySentimentEngine.Sector) -> URL {
        URL(string: "https://cdn.cboe.com/api/global/us_indices/daily_prices/\(sector.volatilitySymbol)_History.csv")!
    }

    static func pricesURL(_ sector: IndustrySentimentEngine.Sector) -> URL {
        URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(sector.priceSymbol)?range=2y&interval=1d")!
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        return URLSession(configuration: configuration)
    }()

    /// The exported-file form, ready for `IndustrySentimentSnapshot.decode`
    /// and for writing to the page's cache.
    func snapshotData(sector: IndustrySentimentEngine.Sector = IndustrySentimentEngine.sectors[0],
                      now: Date = Date()) async throws -> Data {
        async let volatilityRaw = Self.volatilityData(sector)
        async let pricesRaw = Self.get(Self.pricesURL(sector))
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

        let prices: [IndustrySentimentEngine.PriceDay]
        do {
            prices = try Self.parsePrices(smhData, symbol: sector.priceSymbol, formatter: formatter)
                .filter { $0.date < cutoff }
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(Self.pricesURL(sector)), issue: .invalidFormat)
            throw error
        }
        let volatility: [IndustrySentimentEngine.VolatilityDay]
        if let vxData {
            do {
                volatility = try Self.parseVolatility(vxData, symbol: sector.volatilitySymbol).filter { $0.date < cutoff }
            } catch {
                DataSourceHealth.reportUnusable(DataSource.of(Self.volatilityURL(sector)), issue: .invalidFormat)
                throw error
            }
        } else {
            volatility = IndustrySentimentEngine.realizedVolatility(prices)
        }
        let asOf = formatter.string(from: now)
        let object = try IndustrySentimentEngine.evaluate(volatility: volatility, prices: prices,
                                                          asOf: asOf, sector: sector)
        let data = try JSONSerialization.data(withJSONObject: object)
        // Only hand back what the page itself would accept.
        _ = try IndustrySentimentSnapshot.decode(data)
        return data
    }

    /// Cboe publishes two layouts: OHLC, and a single close column named for
    /// the index itself (GVZ, OVX, VXTLT). Read the close by column name in
    /// either, never by position.
    static func parseVolatility(_ data: Data, symbol: String = "VXSMH") throws -> [IndustrySentimentEngine.VolatilityDay] {
        guard var text = String(data: data, encoding: .utf8) else { throw LocalServiceError.invalidResponse }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first?.uppercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }),
              let dateIndex = header.firstIndex(of: "DATE"),
              let closeIndex = header.firstIndex(of: "CLOSE") ?? header.firstIndex(of: symbol.uppercased()) else {
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

    static func parsePrices(_ data: Data, symbol: String = "SMH",
                            formatter: DateFormatter) throws -> [IndustrySentimentEngine.PriceDay] {
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
        guard let result = payload.chart.result.first, result.meta.symbol == symbol,
              let quote = result.indicators.quote.first else { throw LocalServiceError.invalidResponse }
        return result.timestamp.enumerated().compactMap { index, stamp in
            guard index < quote.close.count,
                  let open = quote.open[index], let high = quote.high[index], let low = quote.low[index],
                  let close = quote.close[index], let volume = quote.volume[index] else { return nil }
            return .init(date: formatter.string(from: Date(timeIntervalSince1970: TimeInterval(stamp))),
                         open: open, high: high, low: low, close: close, volume: volume)
        }
    }

    private static func volatilityData(_ sector: IndustrySentimentEngine.Sector) async throws -> Data? {
        sector.usesRealizedVolatility ? nil : try await get(volatilityURL(sector))
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 Catfolio", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.recordedData(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.invalidResponse
        }
        guard data.count <= 5_000_000 else {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw LocalServiceError.invalidResponse
        }
        return data
    }
}
