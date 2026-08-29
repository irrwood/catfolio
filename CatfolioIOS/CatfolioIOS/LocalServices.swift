import Foundation

enum LocalServiceKeys {
    static let fmp = "catfolio.fmp.api-key"
    static let deepSeek = "catfolio.deepseek.api-key"
}

enum LocalServiceError: LocalizedError {
    case missingMarketKey
    case missingAIKey
    case invalidResponse
    case remote(String)
    case noMarketData
    case noSupportedETF

    var errorDescription: String? {
        switch self {
        case .missingMarketKey:
            "成交量分析需要行情数据。请在设置中填写 Financial Modeling Prep API Key。"
        case .missingAIKey:
            "AI 需要 DeepSeek API Key。请在设置中填写，Key 只保存在此 iPhone。"
        case .invalidResponse:
            "第三方服务返回了无法识别的数据"
        case let .remote(message):
            message
        case .noMarketData:
            "没有读取到这只证券的历史成交量"
        case .noSupportedETF:
            "当前组合中没有可穿透的 S&P 500 ETF（支持 VUAG、VUSA、SPY、VOO、IVV）"
        }
    }
}

struct LocalMarketDataClient {
    private struct Envelope: Decodable { let historical: [Bar] }
    private struct Bar: Decodable {
        let date: String
        let close: Double
        let high: Double
        let low: Double
        let volume: Double
    }

    func volumeProfile(ticker: String, currency: String) async throws -> VolumeProfile {
        guard let key = KeychainStore.string(for: LocalServiceKeys.fmp), !key.isEmpty else {
            throw LocalServiceError.missingMarketKey
        }
        let end = DayDateFormatter.shared.string(from: Date())
        let start = DayDateFormatter.shared.string(
            from: Calendar.current.date(byAdding: .day, value: -220, to: Date()) ?? Date()
        )
        var components = URLComponents(string: "https://financialmodelingprep.com/api/v3/historical-price-full/\(ticker)")!
        components.queryItems = [
            URLQueryItem(name: "from", value: start),
            URLQueryItem(name: "to", value: end),
            URLQueryItem(name: "apikey", value: key),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalServiceError.remote(Self.message(from: data, fallback: "行情请求失败（\(http.statusCode)）"))
        }
        guard let bars = try? JSONDecoder().decode(Envelope.self, from: data).historical,
              !bars.isEmpty else { throw LocalServiceError.noMarketData }

        let sessions = Array(bars.prefix(160))
        let minimum = sessions.map(\.low).min() ?? 0
        let maximum = sessions.map(\.high).max() ?? 0
        guard maximum > minimum else { throw LocalServiceError.noMarketData }
        let binCount = 36
        let width = (maximum - minimum) / Double(binCount)
        var bins = Array(repeating: 0.0, count: binCount)
        for bar in sessions where bar.volume > 0 {
            let typical = (bar.high + bar.low + bar.close) / 3
            let index = min(binCount - 1, max(0, Int((typical - minimum) / width)))
            bins[index] += bar.volume
        }
        guard let pocIndex = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[pocIndex] > 0 else {
            throw LocalServiceError.noMarketData
        }
        let target = bins.reduce(0, +) * 0.70
        var lowIndex = pocIndex
        var highIndex = pocIndex
        var covered = bins[pocIndex]
        while covered < target, lowIndex > 0 || highIndex < binCount - 1 {
            let lower = lowIndex > 0 ? bins[lowIndex - 1] : -1
            let upper = highIndex < binCount - 1 ? bins[highIndex + 1] : -1
            if upper >= lower {
                highIndex += 1
                covered += bins[highIndex]
            } else {
                lowIndex -= 1
                covered += bins[lowIndex]
            }
        }
        func midpoint(_ index: Int) -> Double { minimum + (Double(index) + 0.5) * width }
        return VolumeProfile(
            ticker: ticker,
            currency: currency,
            available: true,
            valueAreaHigh: midpoint(highIndex),
            pointOfControl: midpoint(pocIndex),
            valueAreaLow: midpoint(lowIndex),
            sessions: sessions.count,
            valueAreaPercent: 70,
            asOf: sessions.first?.date ?? end
        )
    }

    func comparison(document: LocalPortfolioDocument) async throws -> ComparisonResponse {
        guard let first = document.snapshots.first, first.marketValueUSD > 0 else {
            throw LocalPortfolioError.noPortfolio
        }
        let end = DayDateFormatter.shared.string(from: Date())
        let start = document.snapshots.first?.date ?? end
        async let spy = historicalCloses(symbol: "SPY", from: start, to: end)
        async let qqq = historicalCloses(symbol: "QQQ", from: start, to: end)
        async let vti = historicalCloses(symbol: "VTI", from: start, to: end)
        async let gld = historicalCloses(symbol: "GLD", from: start, to: end)
        let histories = try await ["SPY": spy, "QQQ": qqq, "VTI": vti, "GLD": gld]
        var series: [String: [Double?]] = [:]
        var returns = Dictionary(uniqueKeysWithValues: histories.keys.map { ($0, Optional<Double>.none) })
        for (symbol, history) in histories {
            let values = document.snapshots.map { snapshot in Self.close(onOrBefore: snapshot.date, in: history) }
            guard let initial = values.compactMap({ $0 }).first, initial > 0 else {
                series[symbol] = document.snapshots.map { _ in nil }
                continue
            }
            series[symbol] = values.map { $0.map { first.marketValueUSD * $0 / initial } }
            if let final = values.compactMap({ $0 }).last {
                returns[symbol] = final / initial - 1
            }
        }
        return ComparisonResponse(
            available: true,
            dates: document.snapshots.map(\.date),
            portfolio: document.snapshots.map { Optional($0.marketValueUSD) },
            benchmarks: series,
            summary: ComparisonSummary(
                portfolioReturn: document.snapshots.last.map { $0.marketValueUSD / first.marketValueUSD - 1 },
                benchmarkReturn: returns["SPY"] ?? nil,
                benchmarkReturns: returns
            )
        )
    }

    private func historicalCloses(symbol: String, from: String, to: String) async throws -> [String: Double] {
        guard let key = KeychainStore.string(for: LocalServiceKeys.fmp), !key.isEmpty else {
            throw LocalServiceError.missingMarketKey
        }
        var components = URLComponents(string: "https://financialmodelingprep.com/api/v3/historical-price-full/\(symbol)")!
        components.queryItems = [
            URLQueryItem(name: "from", value: from),
            URLQueryItem(name: "to", value: to),
            URLQueryItem(name: "apikey", value: key),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let bars = try? JSONDecoder().decode(Envelope.self, from: data).historical else {
            throw LocalServiceError.invalidResponse
        }
        return Dictionary(uniqueKeysWithValues: bars.map { ($0.date, $0.close) })
    }

    private static func close(onOrBefore date: String, in history: [String: Double]) -> Double? {
        if let exact = history[date] { return exact }
        return history.keys.filter { $0 <= date }.max().flatMap { history[$0] }
    }

    private static func message(from data: Data, fallback: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return fallback }
        return object["Error Message"] as? String ?? object["message"] as? String ?? fallback
    }
}

struct LocalAIClient {
    func briefing(document: LocalPortfolioDocument) async throws -> String {
        try await complete(
            question: "请生成一段简洁的中文组合简报，指出集中度、盈亏和最值得关注的风险。",
            document: document
        )
    }

    func answer(_ question: String, document: LocalPortfolioDocument) async throws -> String {
        try await complete(question: question, document: document)
    }

    private func complete(question: String, document: LocalPortfolioDocument) async throws -> String {
        guard let key = KeychainStore.string(for: LocalServiceKeys.deepSeek), !key.isEmpty else {
            throw LocalServiceError.missingAIKey
        }
        guard !document.positions.isEmpty else { throw LocalPortfolioError.noPortfolio }
        let presentation = try LocalPortfolioEngine.presentation(for: document)
        let top = presentation.2.prefix(15).map {
            "\($0.ticker): 市值 \(Int($0.marketValue)) USD，权重 \(String(format: "%.1f", $0.weight * 100))%，未实现收益 \(String(format: "%.1f", $0.unrealizedPercent))%"
        }.joined(separator: "\n")
        let context = """
        组合市值：\(Int(presentation.0.summary.marketValue)) USD
        组合成本：\(Int(presentation.0.summary.totalCost)) USD
        持仓数：\(presentation.0.summary.openPositions)
        主要持仓：
        \(top)
        """
        let payload: [String: Any] = [
            "model": "deepseek-chat",
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": "你是 Catfolio 的投资组合分析助手。只根据用户手机提供的组合摘要回答，不虚构实时新闻或行情；明确说明这不是投资建议。"],
                ["role": "user", "content": "\(context)\n\n问题：\(question)"],
            ],
        ]
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let detail = ((object?["error"] as? [String: Any])?["message"] as? String)
                ?? "AI 请求失败（\(http.statusCode)）"
            throw LocalServiceError.remote(detail)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.isEmpty else { throw LocalServiceError.invalidResponse }
        return content
    }
}

enum LocalETFLookThrough {
    private struct Dataset: Decodable {
        let asOf: String?
        let source: String?
        let sourceURL: String?
        let rows: [Constituent]

        enum CodingKeys: String, CodingKey {
            case rows, source
            case asOf = "as_of"
            case sourceURL = "source_url"
        }
    }

    private struct Constituent: Decodable {
        let ticker: String
        let name: String
        let sector: String?
        let weight: Double

        enum CodingKeys: String, CodingKey {
            case ticker, name, sector
            case weight = "weight_percent"
        }
    }

    static func make(document: LocalPortfolioDocument, basis: ETFLookThroughBasis) throws -> ETFLookThroughResponse {
        let supported = Set(["VUAG", "VUAG.L", "VUSA", "VUSA.L", "SPY", "VOO", "IVV"])
        let etfs = document.positions.filter { supported.contains($0.ticker.uppercased()) }
        guard !etfs.isEmpty else { throw LocalServiceError.noSupportedETF }
        guard let url = Bundle.main.url(forResource: "sp500_holdings", withExtension: "json"),
              let dataset = try? JSONDecoder().decode(Dataset.self, from: Data(contentsOf: url)) else {
            throw LocalServiceError.invalidResponse
        }
        func exposure(_ position: LocalPositionRecord) throws -> Double {
            switch basis {
            case .market:
                try LocalPortfolioEngine.usd(position.shares * position.quotePrice, currency: position.quoteCurrency)
            case .cost:
                try LocalPortfolioEngine.usd(position.shares * position.averageCost, currency: position.currency)
            }
        }
        let etfTotal = try etfs.reduce(0.0) { try $0 + exposure($1) }
        let directPositions = document.positions.filter { !supported.contains($0.ticker.uppercased()) }
        var direct: [String: (value: Double, name: String)] = [:]
        for position in directPositions {
            let ticker = position.ticker.uppercased()
            let current = direct[ticker]?.value ?? 0
            direct[ticker] = (try current + exposure(position), position.name)
        }
        var covered = 0.0
        var rows = dataset.rows.map { constituent -> ETFLookThroughRow in
            covered += constituent.weight
            let directValue = direct.removeValue(forKey: constituent.ticker.uppercased())
            let indirect = etfTotal * constituent.weight / 100
            return ETFLookThroughRow(
                ticker: constituent.ticker,
                logoSymbol: constituent.ticker,
                name: directValue?.name.isEmpty == false ? directValue!.name : constituent.name,
                directUSD: directValue?.value ?? 0,
                fromETFUSD: indirect,
                totalUSD: (directValue?.value ?? 0) + indirect,
                etfWeightPercent: constituent.weight,
                sector: constituent.sector
            )
        }
        let otherWeight = max(0, 100 - covered)
        if otherWeight > 0.001 {
            rows.append(ETFLookThroughRow(
                ticker: "ETF 其他", logoSymbol: nil, name: "基金现金及衍生品",
                directUSD: 0, fromETFUSD: etfTotal * otherWeight / 100,
                totalUSD: etfTotal * otherWeight / 100, etfWeightPercent: otherWeight, sector: "ETF / Other"
            ))
        }
        rows.append(contentsOf: direct.map { ticker, item in
            ETFLookThroughRow(
                ticker: ticker, logoSymbol: ticker, name: item.name.isEmpty ? ticker : item.name,
                directUSD: item.value, fromETFUSD: 0, totalUSD: item.value, etfWeightPercent: 0, sector: nil
            )
        })
        rows.sort { $0.totalUSD > $1.totalUSD }
        return ETFLookThroughResponse(
            basis: basis.rawValue,
            etfTickers: etfs.map(\.ticker).sorted(),
            etfTotalUSD: etfTotal,
            coveredWeightPercent: covered,
            otherWeightPercent: otherWeight,
            constituentCount: dataset.rows.count,
            holdingsAsOf: dataset.asOf,
            holdingsSource: dataset.source,
            holdingsSourceURL: dataset.sourceURL,
            rows: rows
        )
    }
}
