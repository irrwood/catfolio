import SwiftUI
import Charts
import CryptoKit

struct OIContract: Codable {
    struct Details: Codable {
        let ticker: String
        let contract_type: String
        let expiration_date: String
        let strike_price: Double
        let shares_per_contract: Double?
    }
    let details: Details
    let open_interest: Double?
}

struct OISnapshot: Codable {
    let contracts: [OIContract]
    let fetchedAt: Date
    let from: String
    let through: String
    let excluded: Int
}

struct OIDistribution {
    struct Row: Identifiable {
        var id: Double { strike }
        let strike: Double
        var call: Double = 0
        var put: Double = 0
    }
    let rows: [Row]
    let callWalls: [Row]
    let putWalls: [Row]
    let concentration: ClosedRange<Double>?

    init(contracts: [OIContract]) {
        var grouped: [Double: Row] = [:]
        var seen = Set<String>()
        for contract in contracts {
            guard seen.insert(contract.details.ticker).inserted,
                  let oi = contract.open_interest, oi.isFinite, oi >= 0,
                  contract.details.strike_price.isFinite, contract.details.strike_price > 0,
                  ["call", "put"].contains(contract.details.contract_type) else { continue }
            let strike = contract.details.strike_price
            var row = grouped[strike] ?? Row(strike: strike)
            if contract.details.contract_type == "call" { row.call += oi } else { row.put += oi }
            grouped[strike] = row
        }
        rows = grouped.values.sorted { $0.strike < $1.strike }
        let callMax = rows.map(\.call).max() ?? 0
        let putMax = rows.map(\.put).max() ?? 0
        callWalls = callMax > 0 ? rows.filter { $0.call == callMax } : []
        putWalls = putMax > 0 ? rows.filter { $0.put == putMax } : []
        let total = rows.reduce(0) { $0 + $1.call + $1.put }
        if total > 0 {
            var cumulative = 0.0
            var low: Double?
            var high: Double?
            for row in rows {
                cumulative += row.call + row.put
                if low == nil && cumulative >= total * 0.15 { low = row.strike }
                if high == nil && cumulative >= total * 0.85 { high = row.strike }
            }
            concentration = low.flatMap { lower in high.map { lower...$0 } }
        } else { concentration = nil }
    }
}

// Yahoo contract timestamps encode the expiry DATE at UTC midnight, not New York midnight.
enum YahooOIError: LocalizedError {
    case incomplete
    var errorDescription: String? { L10n.text("Yahoo 期权链缺少有效 OI 或合约信息，未更新持仓墙。") }
}

struct YahooOIResponse: Decodable {
    struct Envelope: Decodable {
        struct ProviderError: Decodable { let code: String? }
        let result: [Chain]?
        let error: ProviderError?
    }
    struct Chain: Decodable {
        let underlyingSymbol: String
        let expirationDates: [Int]
        let options: [Expiry]
    }
    struct Expiry: Decodable {
        let expirationDate: Int
        let calls: [Contract]
        let puts: [Contract]
    }
    struct Contract: Decodable {
        let contractSymbol: String
        let strike: Double
        let expiration: Int
        let openInterest: Double?
        let contractSize: String?
        let currency: String?
    }
    let optionChain: Envelope

    static func expiryDay(_ timestamp: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: Double(timestamp)))
    }

    func validatedChain(symbol: String) throws -> Chain {
        guard optionChain.error == nil, let results = optionChain.result, results.count == 1,
              let chain = results.first, chain.underlyingSymbol == symbol,
              Set(chain.expirationDates).count == chain.expirationDates.count,
              chain.expirationDates.allSatisfy({ $0 > 0 && $0 < 10_000_000_000 }) else {
            throw YahooOIError.incomplete
        }
        return chain
    }

    // Missing OI is not zero; reject the new snapshot instead of publishing a partial wall.
    static func normalize(_ expiry: Expiry, symbol: String) throws -> (contracts: [OIContract], excluded: Int) {
        var result: [OIContract] = []
        var seen = Set<String>()
        var excluded = 0
        let date = expiryDay(expiry.expirationDate)
        let code = String(date.replacingOccurrences(of: "-", with: "").suffix(6))
        guard !expiry.calls.isEmpty || !expiry.puts.isEmpty else { throw YahooOIError.incomplete }
        for (side, items) in [("call", expiry.calls), ("put", expiry.puts)] {
            for item in items {
                guard seen.insert(item.contractSymbol).inserted else { throw YahooOIError.incomplete }
                let prefix = symbol + code + (side == "call" ? "C" : "P")
                // Corporate-action roots/deliverables need their own reference mapping.
                guard item.contractSize == "REGULAR",
                      String(item.contractSymbol.dropLast(15)) == symbol else {
                    excluded += 1; continue
                }
                let strikeCode = String(item.contractSymbol.suffix(8))
                guard item.contractSymbol == prefix + strikeCode,
                      strikeCode.count == 8, strikeCode.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let encodedStrike = Double(strikeCode),
                      item.expiration == expiry.expirationDate, item.currency == "USD",
                      item.strike.isFinite, item.strike > 0,
                      abs(item.strike * 1000 - encodedStrike) < 0.001,
                      let oi = item.openInterest, oi.isFinite, oi >= 0,
                      oi <= 1_000_000_000_000, oi.rounded() == oi else {
                    throw YahooOIError.incomplete
                }
                result.append(OIContract(details: .init(ticker: item.contractSymbol, contract_type: side,
                    expiration_date: date, strike_price: item.strike, shares_per_contract: nil), open_interest: oi))
            }
        }
        return (result, excluded)
    }
}

actor OptionsOIClient {
    static let shared = OptionsOIClient()
    // Isolated, in-memory anonymous Yahoo cookies; never read browser/account cookies.
    private let session: URLSession
    private let cacheDirectory: URL
    private var fetching = false
    private var rateLimitedUntil: Date?
    init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 35
        self.session = session ?? URLSession(configuration: configuration)
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OptionsOI", isDirectory: true)
    }
    private func file(_ symbol: String, _ days: Int) -> URL {
        let key = SHA256.hash(data: Data("\(symbol)|\(days)".utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("options-oi-yahoo-v1-\(key).json")
    }
    func cached(symbol: String, days: Int) -> OISnapshot? {
        let destination = file(symbol, days)
        // Preserve snapshots fetched by the previous version. Never refetch
        // merely because the storage location changed.
        let legacy = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(destination.lastPathComponent)
        guard let data = (try? Data(contentsOf: destination)) ?? (try? Data(contentsOf: legacy)) else { return nil }
        if !FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        return try? JSONDecoder().decode(OISnapshot.self, from: data)
    }
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private func read(_ url: URL, cookieBootstrap: Bool = false) async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalServiceError.invalidResponse }
        if http.statusCode == 429 {
            // Stop immediately, do not switch hosts or retry around Yahoo's limit.
            let retry = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 300
            rateLimitedUntil = Date().addingTimeInterval(max(300, min(retry, 86400)))
            throw LocalServiceError.remote(L10n.text("Yahoo 请求限流，请稍后再刷新。"))
        }
        // fc.yahoo.com may issue its anonymous cookie with a 404 response.
        guard http.statusCode == 200 || (cookieBootstrap && http.statusCode == 404) else {
            throw LocalServiceError.remote(http.statusCode == 401 || http.statusCode == 403
                ? L10n.text("Yahoo 暂不允许读取期权数据，请稍后再试。")
                : L10n.text("Yahoo 期权请求失败（\(http.statusCode)）。"))
        }
        return data
    }
    private func chain(symbol: String, expiration: Int?, crumb: String) async throws -> YahooOIResponse.Chain {
        var components = URLComponents(string: "https://query2.finance.yahoo.com/v7/finance/options/\(symbol)")!
        components.queryItems = [URLQueryItem(name: "crumb", value: crumb)]
        if let expiration { components.queryItems?.append(URLQueryItem(name: "date", value: String(expiration))) }
        let data = try await read(components.url!)
        do {
            return try JSONDecoder().decode(YahooOIResponse.self, from: data).validatedChain(symbol: symbol)
        } catch { throw YahooOIError.incomplete }
    }
    func fetch(symbol: String, days: Int) async throws -> OISnapshot {
        guard symbol.range(of: "^[A-Z][A-Z0-9.-]{0,14}$", options: .regularExpression) != nil,
              [7, 30, 90].contains(days) else { throw LocalServiceError.invalidResponse }
        guard !fetching else { throw LocalServiceError.remote(L10n.text("正在读取 Yahoo 期权链，请稍后再试。")) }
        if let until = rateLimitedUntil, until > Date() {
            throw LocalServiceError.remote(L10n.text("Yahoo 仍在限流冷却期，请稍后再刷新。"))
        }
        fetching = true
        defer { fetching = false }
        let from = Self.day(Date())
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let through = Self.day(calendar.date(byAdding: .day, value: days, to: Date())!)
        _ = try await read(URL(string: "https://fc.yahoo.com")!, cookieBootstrap: true)
        let crumbData = try await read(URL(string: "https://query2.finance.yahoo.com/v1/test/getcrumb")!)
        guard let crumb = String(data: crumbData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !crumb.isEmpty, crumb.count < 100,
              !crumb.contains(where: { $0.isWhitespace || $0 == "<" || $0 == "{" }) else {
            throw LocalServiceError.remote(L10n.text("Yahoo 会话暂不可用，未更新持仓墙。"))
        }
        let inventory = try await chain(symbol: symbol, expiration: nil, crumb: crumb)
        let expirations = inventory.expirationDates.filter {
            let date = YahooOIResponse.expiryDay($0)
            return date >= from && date <= through
        }.sorted()
        guard expirations.count <= 100 else { throw YahooOIError.incomplete }
        var contracts: [OIContract] = []
        var seen = Set<String>()
        var excluded = 0
        for timestamp in expirations {
            try Task.checkCancellation()
            let response: YahooOIResponse.Chain
            if inventory.options.contains(where: { $0.expirationDate == timestamp }) {
                response = inventory
            } else {
                // Sequential, modest pacing. Never launch a burst for every expiry.
                try await Task.sleep(for: .milliseconds(350))
                response = try await chain(symbol: symbol, expiration: timestamp, crumb: crumb)
            }
            let matching = response.options.filter { $0.expirationDate == timestamp }
            guard matching.count == 1, let expiry = matching.first else { throw YahooOIError.incomplete }
            let normalized = try YahooOIResponse.normalize(expiry, symbol: symbol)
            for contract in normalized.contracts {
                guard seen.insert(contract.details.ticker).inserted else { throw YahooOIError.incomplete }
                contracts.append(contract)
            }
            excluded += normalized.excluded
        }
        guard Self.day(Date()) == from else { throw LocalServiceError.remote(L10n.text("请求跨越纽约日期，请重新刷新。")) }
        try Task.checkCancellation()
        let snapshot = OISnapshot(contracts: contracts, fetchedAt: Date(), from: from, through: through, excluded: excluded)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file(symbol, days), options: [.atomic, .completeFileProtectionUnlessOpen])
        return snapshot
    }
}

struct OptionsOIView: View {
    @Environment(\.locale) private var appLocale
    let symbol: String
    let currency: String?
    let price: Double?
    let costUSD: Double?
    @State private var days = 30
    @State private var snapshot: OISnapshot?
    @State private var error: String?
    @State private var loading = false
    @State private var refreshID = 0
    @State private var handledRefreshID = 0
    @State private var snapshotKey: String?
    @State private var showsInfo = false
    @State private var selectedStrike: Double?
    private var supported: Bool {
        currency?.uppercased() == "USD" && symbol.range(of: "^[A-Za-z][A-Za-z0-9.-]{0,14}$", options: .regularExpression) != nil
            && !symbol.uppercased().hasSuffix(".L")
    }
    var body: some View {
        PriceDistributionSection(title: L10n.text("期权持仓墙"), subtitle: "OI") {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button(L10n.text("计算说明"), systemImage: "info.circle") { showsInfo = true }.labelStyle(.iconOnly)
                Spacer()
                Button(L10n.text("刷新 OI"), systemImage: "arrow.clockwise") { refreshID += 1 }
                    .labelStyle(.iconOnly).disabled(loading || !supported)
            }
            Picker(L10n.text("到期范围"), selection: $days) {
                Text(L10n.text("7 天内")).tag(7); Text(L10n.text("30 天内")).tag(30); Text(L10n.text("90 天内")).tag(90)
            }.pickerStyle(.segmented).disabled(loading || !supported)
            if loading { ProgressView(L10n.text("读取完整期权链…")) }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if !supported {
                Text(L10n.text("首版仅支持美国上市的美元股票／ETF 期权。其他市场暂不支持。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if let snapshot {
                content(snapshot)
            } else if !loading {
                Text(L10n.text("点击刷新读取 Yahoo OI，无需 API Key。"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        } footer: {
            Text(L10n.text("未平仓量分布不代表成交量，也不保证支撑或阻力。"))
        }
        .alert(L10n.text("OI 计算口径"), isPresented: $showsInfo) {
            Button(L10n.text("知道了"), role: .cancel) {}
        } message: {
            Text(L10n.text("按所选到期范围汇总 Yahoo 返回合约的未平仓张数。Call／Put 墙分别为各自 OI 最大价位，并列峰值全部保留，不强制位于现价上下。阴影为累计 OI 的 15%–85% 等尾区间，覆盖至少 70% 已读取 OI。仅纳入 Yahoo 标记 REGULAR 且代码可核对的合约，不推断交割乘数。Yahoo 覆盖不等于交易所全部合约；缺数时保留旧缓存。OI 日期未知，不能用获取时间或最后成交时间替代。OI 不能推导方向或必然支撑阻力。"))
        }
        .task(id: "\(symbol)|\(days)|\(refreshID)") {
            // A tap authorizes ONE request, not all future range/appearance tasks.
            let shouldRefresh = refreshID != handledRefreshID
            handledRefreshID = refreshID
            loading = shouldRefresh
            defer { if !Task.isCancelled { loading = false } }
            let key = "\(symbol.uppercased())|\(days)"
            if snapshotKey != key { snapshot = nil }
            snapshotKey = key
            error = nil; selectedStrike = nil
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--preview-options-oi") {
                snapshot = Self.preview
                error = L10n.text("演示数据 · 仅用于布局验证")
                return
            }
            #endif
            guard supported else { return }
            let cached = await OptionsOIClient.shared.cached(symbol: symbol.uppercased(), days: days)
            guard !Task.isCancelled else { return }
            snapshot = cached
            guard shouldRefresh else { return }
            do {
                let result = try await OptionsOIClient.shared.fetch(symbol: symbol.uppercased(), days: days)
                guard !Task.isCancelled else { return }
                snapshot = result
            } catch {
                guard !Task.isCancelled else { return }
                self.error = cached == nil ? error.localizedDescription : L10n.text("刷新失败，以下为旧缓存。\(error.localizedDescription)")
            }
        }
    }

    #if DEBUG
    static var preview: OISnapshot {
        let contracts = (80...130).flatMap { strike in
            ["call", "put"].map { side in
                let center = side == "call" ? 120.0 : 95.0
                let oi = (1000 + 120000 * exp(-pow((Double(strike) - center) / 6, 2))).rounded()
                return OIContract(details: .init(ticker: "test-\(strike)-\(side)", contract_type: side,
                    expiration_date: "2026-10-02", strike_price: Double(strike), shares_per_contract: 100), open_interest: oi)
            }
        }
        return OISnapshot(contracts: contracts, fetchedAt: Date(), from: "2026-09-08", through: "2026-10-08", excluded: 0)
    }
    #endif

    @ViewBuilder private func content(_ snapshot: OISnapshot) -> some View {
        let distribution = OIDistribution(contracts: snapshot.contracts)
        Text(L10n.text("到期 \(snapshot.from) – \(snapshot.through) · \(snapshot.contracts.count) 份合约"))
            .font(.caption).foregroundStyle(.secondary)
        Text(L10n.text("Yahoo Finance · OI 日期未提供\n获取于 \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))"))
            .font(.caption).foregroundStyle(.secondary)
        if snapshot.excluded > 0 { Text(L10n.text("已排除 \(snapshot.excluded) 份非标准或无法确认的合约。")) .font(.caption).foregroundStyle(.secondary) }
        if let range = distribution.concentration {
            plot(distribution)
            if let selectedStrike,
               let row = distribution.rows.min(by: { abs($0.strike - selectedStrike) < abs($1.strike - selectedStrike) }) {
                Text(L10n.text("\(money(row.strike)) · Call \(Int(row.call).formatted()) 张 · Put \(Int(row.put).formatted()) 张"))
                    .font(.caption).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 12) {
                metric(L10n.text("Call OI 墙"), rows: distribution.callWalls, call: true)
                metric(L10n.text("Put OI 墙"), rows: distribution.putWalls, call: false)
                LabeledContent(L10n.text("持仓集中区 ≥70%"), value: "\(money(range.lowerBound))–\(money(range.upperBound))")
                if let price, price.isFinite, price > 0 {
                    LabeledContent(L10n.text("最近可用现价"), value: money(price))
                    Text(range.contains(price) ? L10n.text("现价位于所选范围的 OI 集中区内。") : L10n.text("现价位于所选范围的 OI 集中区\(price > range.upperBound ? L10n.text("上方") : L10n.text("下方"))。"))
                        .font(.subheadline)
                }
                if let costUSD, costUSD.isFinite, costUSD > 0 { LabeledContent(L10n.text("所选账户持仓成本"), value: money(costUSD)) }
            }.font(.caption).monospacedDigit()
            Text(L10n.text("绿色 Call · 红色 Put · 蓝线为页面现价，非期权快照同步报价。阴影为持仓集中区，不是成交量或 Gamma。"))
                .font(.caption2).foregroundStyle(.secondary)
        } else { Text(L10n.text("所选范围没有可用的正 OI，暂无持仓墙。")) .foregroundStyle(.secondary) }
    }
    private func money(_ value: Double) -> String { value.formatted(.currency(code: "USD").precision(.fractionLength(0...2))) }
    private func metric(_ title: String, rows: [OIDistribution.Row], call: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title + (rows.count > 1 ? L10n.text("（并列）") : "")).fontWeight(.semibold)
            Text(rows.isEmpty ? L10n.text("无正 OI") : rows.map { L10n.text("\(money($0.strike)) · \(Int(call ? $0.call : $0.put).formatted()) 张") }.joined(separator: "；"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func plot(_ distribution: OIDistribution) -> some View {
        let maxOI = max(1, distribution.rows.map { max($0.call, $0.put) }.max() ?? 1)
        let prices = distribution.rows.map(\.strike) + [price, costUSD].compactMap { $0 }.filter { $0.isFinite && $0 > 0 }
        let low = prices.min() ?? 0
        let high = prices.max() ?? 1
        let padding = max(1, (high - low) * 0.04)
        let gap = zip(distribution.rows.dropFirst(), distribution.rows).map { $0.strike - $1.strike }.min() ?? 1
        let barHeight = max(0.5, min(6, gap / (high - low + 2 * padding) * 250 * 0.8))
        return Chart {
            if let range = distribution.concentration {
                RectangleMark(xStart: .value("OI", -maxOI), xEnd: .value("OI", maxOI),
                    yStart: .value(L10n.text("行权价"), range.lowerBound), yEnd: .value(L10n.text("行权价"), range.upperBound))
                    .foregroundStyle(Color.secondary.opacity(0.12))
            }
            ForEach(distribution.rows) { row in
                BarMark(xStart: .value("Put OI", -row.put), xEnd: .value(L10n.text("中心"), 0), y: .value(L10n.text("行权价"), row.strike), height: .fixed(barHeight))
                    .foregroundStyle(Color.red.opacity(0.55))
                BarMark(xStart: .value(L10n.text("中心"), 0), xEnd: .value("Call OI", row.call), y: .value(L10n.text("行权价"), row.strike), height: .fixed(barHeight))
                    .foregroundStyle(Color.green.opacity(0.65))
            }
            RuleMark(x: .value(L10n.text("中心"), 0)).foregroundStyle(Color.secondary.opacity(0.3))
            if let price, price.isFinite, price > 0 { RuleMark(y: .value(L10n.text("现价"), price)).foregroundStyle(.blue) }
            if let costUSD, costUSD.isFinite, costUSD > 0 { RuleMark(y: .value(L10n.text("成本"), costUSD)).foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [4, 3])) }
            ForEach(distribution.callWalls) { row in RuleMark(y: .value(L10n.text("Call 墙"), row.strike)).foregroundStyle(.green).lineStyle(StrokeStyle(dash: [2, 3])) }
            ForEach(distribution.putWalls) { row in RuleMark(y: .value(L10n.text("Put 墙"), row.strike)).foregroundStyle(.red).lineStyle(StrokeStyle(dash: [2, 3])) }
        }
        .chartXScale(domain: -maxOI * 1.05...maxOI * 1.05)
        .chartYScale(domain: low - padding...high + padding)
        .chartYSelection(value: $selectedStrike)
        .chartYAxisLabel(L10n.text("行权价 USD"))
        .chartXAxisLabel(L10n.text("Put ← OI 合约张数 → Call"))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { value in
            AxisGridLine(); AxisValueLabel { if let number = value.as(Double.self) { Text(abs(number), format: .number.notation(.compactName)) } }
        } }
        .frame(height: 303)
        .accessibilityLabel(L10n.text("按行权价排列的 Call 与 Put 未平仓合约分布，下方提供峰值和集中区数值"))
    }
}
