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
        var hasCall = false
        var hasPut = false
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
            if contract.details.contract_type == "call" { row.call += oi; row.hasCall = true }
            else { row.put += oi; row.hasPut = true }
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

/// Presentation geometry only. Vertices retain exact OI at each observed strike;
/// absent contracts and unusually wide strike gaps break the silhouette.
enum OIPlotRange: String, CaseIterable { case main, all }

enum OIPriceLabel {
    static func text(_ value: Double, locale: Locale) -> String {
        guard value.isFinite else { return "—" }
        return "$" + value.formatted(.number.precision(.fractionLength(0...4)).locale(locale))
    }
}

struct OIPlotGeometry {
    enum Side { case put, call }
    struct Vertex: Equatable { let strike: Double; let width: Double }
    let rows: [OIDistribution.Row]
    let maximum: Double
    let domain: ClosedRange<Double>
    let step: Double

    init(_ distribution: OIDistribution, markers: [Double] = [], range: OIPlotRange = .all,
         currentPrice: Double? = nil) {
        rows = distribution.rows
        maximum = max(1, rows.map { max($0.put, $0.call) }.max() ?? 1)
        let gaps = zip(rows, rows.dropFirst()).map { $1.strike - $0.strike }.filter { $0 > 0 }.sorted()
        step = gaps.isEmpty ? max(0.01, (rows.first?.strike ?? 1) * 0.01) : gaps[(gaps.count - 1) / 2]
        var low = rows.first?.strike ?? 0
        var high = rows.last?.strike ?? 1
        let total = rows.reduce(0) { $0 + $1.put + $1.call }
        if range == .main, total > 0 {
            var cumulative = 0.0
            var lower: Double?
            for row in rows {
                cumulative += row.put + row.call
                if lower == nil && cumulative >= total * 0.05 { lower = row.strike }
                if cumulative >= total * 0.95 { high = row.strike; break }
            }
            low = lower ?? low
            // Never hide a true maximum, including tied maxima.
            for wall in distribution.putWalls + distribution.callWalls {
                low = min(low, wall.strike); high = max(high, wall.strike)
            }
        }
        let span = max(step * 2, high - low)
        // Nearby quotes help orient the reader. Remote references belong in the
        // edge notice/summary, and cost never determines the OI viewport.
        if let currentPrice, currentPrice.isFinite, currentPrice > 0,
           currentPrice >= low - span * 0.25, currentPrice <= high + span * 0.25 {
            low = min(low, currentPrice); high = max(high, currentPrice)
        }
        for marker in markers where marker.isFinite && marker > 0 {
            low = min(low, marker); high = max(high, marker)
        }
        // A thin margin: the strike range, and so the waves, fill the height.
        // Never less than a wave's tapered end cap, which reaches half a
        // strike step beyond the outermost strike.
        let padding = max(step * 0.75, (high - low) * 0.04)
        domain = max(0, low - padding)...(high + padding)
    }

    var visibleRows: [OIDistribution.Row] { rows.filter { domain.contains($0.strike) } }
    var outsideFraction: Double {
        let total = rows.reduce(0) { $0 + $1.put + $1.call }
        guard total > 0 else { return 0 }
        return rows.filter { !domain.contains($0.strike) }.reduce(0) { $0 + $1.put + $1.call } / total
    }

    func nearest(to price: Double) -> OIDistribution.Row? {
        guard price.isFinite else { return nil }
        return visibleRows.min { abs($0.strike - price) < abs($1.strike - price) }
    }

    func segments(for side: Side) -> [[Vertex]] {
        var result: [[Vertex]] = []
        var run: [OIDistribution.Row] = []
        func flush() {
            guard let first = run.first, let last = run.last else { return }
            let points = run.map { Vertex(strike: $0.strike, width: (side == .put ? $0.put : $0.call) / maximum) }
            // End caps taper to zero within half a nominal strike interval.
            result.append([Vertex(strike: first.strike - step / 2, width: 0)] + points +
                          [Vertex(strike: last.strike + step / 2, width: 0)])
            run.removeAll(keepingCapacity: true)
        }
        for row in rows {
            let observed = side == .put ? row.hasPut : row.hasCall
            if !observed { flush(); continue }
            if let previous = run.last, row.strike - previous.strike > step * 1.5 { flush() }
            run.append(row)
        }
        flush()
        return result
    }

    /// Monotone cubic tangents keep a continuous derivative at observed strikes
    /// without shifting peaks, averaging widths, or overshooting the source OI.
    static func edgeSlopes(_ vertices: [Vertex]) -> [Double] {
        guard vertices.count > 1 else { return vertices.map { _ in 0 } }
        let gaps = zip(vertices, vertices.dropFirst()).map { $1.strike - $0.strike }
        let slopes = zip(vertices, vertices.dropFirst()).enumerated().map { index, pair in
            (pair.1.width - pair.0.width) / gaps[index]
        }
        var result = [slopes[0]]
        for index in 1..<(vertices.count - 1) {
            let before = slopes[index - 1], after = slopes[index]
            if before * after <= 0 { result.append(0); continue }
            let w1 = 2 * gaps[index] + gaps[index - 1]
            let w2 = gaps[index] + 2 * gaps[index - 1]
            result.append((w1 + w2) / (w1 / before + w2 / after))
        }
        result.append(slopes.last!)
        return result
    }

    /// Keep labels within a lane, separated by their full height. Rules stay at
    /// their actual strike and a short leader connects any displaced label.
    static func labelPositions(_ desired: [Double], height: Double, spacing: Double = 28) -> [Double] {
        guard !desired.isEmpty else { return [] }
        let inset = spacing / 2
        var positions = desired.map { min(height - inset, max(inset, $0)) }
        for index in positions.indices.dropFirst() { positions[index] = max(positions[index], positions[index - 1] + spacing) }
        if let last = positions.last, last > height - inset {
            positions[positions.count - 1] = height - inset
            for index in positions.indices.dropLast().reversed() {
                positions[index] = min(positions[index], positions[index + 1] - spacing)
            }
        }
        return positions
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
    @AppStorage(ChartInteractionStyle.hapticsPreferenceKey) private var hapticsEnabled = true
    @Environment(\.locale) private var appLocale
    let symbol: String
    let currency: String?
    let price: Double?
    let costUSD: Double?
    /// The holding page's refresh count; each change forces one reread.
    var refreshRevision = 0
    @State private var days = 30
    @State private var snapshot: OISnapshot?
    @State private var error: String?
    @State private var loading = false
    @State private var refreshID = 0
    @State private var handledRefreshID = 0
    @State private var snapshotKey: String?
    @State private var showsInfo = false
    @State private var selectedStrike: Double?
    @State private var plotRange: OIPlotRange = .main
    @State private var showsWalls = false
    private var supported: Bool {
        currency?.uppercased() == "USD" && symbol.range(of: "^[A-Za-z][A-Za-z0-9.-]{0,14}$", options: .regularExpression) != nil
            && !symbol.uppercased().hasSuffix(".L")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                Text(L10n.text("期权持仓墙 OI")).font(LegacyType.medium(19, relativeTo: .headline))
                Spacer(minLength: 12)
                Button { showsInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 19, weight: .regular))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary.opacity(0.20))
                .accessibilityLabel(L10n.text("计算说明"))
            }
            HStack(spacing: 16) {
                Picker(L10n.text("到期范围"), selection: $days) {
                    Text("7D").tag(7).accessibilityLabel(L10n.text("7 天内"))
                    Text("30D").tag(30).accessibilityLabel(L10n.text("30 天内"))
                    Text("90D").tag(90).accessibilityLabel(L10n.text("90 天内"))
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(loading || !supported)
                .sensoryFeedback(.selection, trigger: days) { _, _ in hapticsEnabled }
                rangeToggle
            }
            VStack(alignment: .leading, spacing: 16) {
                plotCard
                if supported, snapshot != nil, let error {
                    Text(error).appText(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .transaction { $0.animation = nil }
        .onChange(of: plotRange) { _, _ in selectedStrike = nil }
        // The page's own refresh is this section's refresh: the design has no
        // button of its own, and one request per tap is still the rule.
        .onChange(of: refreshRevision) { _, _ in if supported { refreshID += 1 } }
        .sheet(isPresented: $showsWalls) {
            if let snapshot { wallsDetail(OIDistribution(contracts: snapshot.contracts)) }
        }
        .alert(L10n.text("OI 计算口径"), isPresented: $showsInfo) {
            Button(L10n.text("知道了"), role: .cancel) {}
        } message: {
            Text(L10n.text("按所选到期范围汇总 Yahoo 返回合约的未平仓张数。Put／Call 墙为各自 OI 最大价位，并列峰值全部保留。主要分布显示累计 OI 的 5%–95% 区间及墙位，留有边距；切换全部可查看尾部。远离分布的现价与成本列在摘要，不扩展价格轴。集中区仍为累计 OI 的 15%–85% 等尾区间，覆盖至少 70% 已读取 OI。价格最多显示四位小数，省略末尾的零；坐标与选中值保留原始行权价。仅纳入 REGULAR 且代码可核对的合约。Yahoo 覆盖不等于交易所全部合约；缺数时保留旧缓存。获取时间不是 OI 数据日期。OI 不代表成交量、买卖方向或必然支撑阻力。") + infoDetails)
        }
        .task(id: "\(symbol)|\(days)|\(refreshID)") {
            // A tap forces ONE request. Without one, the wall still shows by
            // default: a range with no snapshot from today's New York session
            // is read once, and a same-day cache is never re-requested.
            let forced = refreshID != handledRefreshID
            handledRefreshID = refreshID
            loading = forced
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
            let current = cached?.from == OptionsOIClient.day(Date())
            guard forced || !current else { return }
            loading = true
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

    @Environment(\.colorScheme) private var colorScheme
    private func oiText(_ value: Double, observed: Bool = true) -> String {
        observed ? value.formatted(.number.precision(.fractionLength(0)).locale(appLocale)) : "—"
    }
    private func money(_ value: Double) -> String { OIPriceLabel.text(value, locale: appLocale) }

    private var hasWalls: Bool {
        supported && snapshot.map { OIDistribution(contracts: $0.contracts).concentration != nil } == true
    }

    private var controlFill: Color {
        colorScheme == .dark ? .white.opacity(0.06) : Color(red: 248 / 255, green: 248 / 255, blue: 248 / 255)
    }

    /// One pill with two states (Figma 300:10594). It names what a tap does:
    /// ZOOM IN narrows to the main distribution, ZOOM OUT shows every strike.
    private var rangeToggle: some View {
        let zoomsIn = plotRange == .all
        return Button { plotRange = zoomsIn ? .main : .all } label: {
            HStack(spacing: 2) {
                Image(systemName: zoomsIn ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 24, height: 24)
                // Sized to the longer label, so the pill keeps its width
                // when it flips; the shorter one sits flush left, as drawn.
                ZStack(alignment: .leading) {
                    Text(verbatim: "ZOOM OUT").hidden()
                    Text(verbatim: zoomsIn ? "ZOOM IN" : "ZOOM OUT")
                }
                .appText(.footnote, weight: .semibold)
                .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(controlFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(!hasWalls)
        .sensoryFeedback(.selection, trigger: plotRange) { _, _ in hapticsEnabled }
        .accessibilityLabel(L10n.text(zoomsIn ? "主要分布" : "全部"))
        .accessibilityIdentifier("options-oi-range")
    }

    /// One liquid-glass card, the same glass as every other card on the page:
    /// the plot and its axis on top, a hairline, then the two walls. The plot
    /// keeps a fixed height, so the card does not jump while the chain loads.
    private var plotCard: some View {
        let distribution = snapshot.map { OIDistribution(contracts: $0.contracts) }
        let showsWalls = supported && distribution?.concentration != nil
        return VStack(spacing: 0) {
            ZStack {
                if !supported {
                    plotMessage(L10n.text("首版仅支持美国上市的美元股票／ETF 期权。其他市场暂不支持。"))
                } else if let distribution {
                    if distribution.concentration != nil {
                        OptionsOIDistributionPlot(distribution: distribution, currentPrice: price, holdingCost: costUSD,
                                                  selectedStrike: $selectedStrike, range: plotRange)
                    } else {
                        plotMessage(L10n.text("所选范围没有可用的正 OI，暂无持仓墙。"))
                    }
                } else if let error, !loading {
                    VStack(spacing: 12) {
                        plotMessage(error)
                        Button(L10n.text("重试")) { refreshID += 1 }.appText(.caption, weight: .semibold)
                    }
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.text("读取完整期权链…")).appText(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 397)

            if showsWalls, let distribution {
                Rectangle()
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06))
                    .frame(height: 1)
                HStack(alignment: .top) {
                    wallSummary(distribution.putWalls, call: false)
                    wallSummary(distribution.callWalls, call: true)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: HoldingDetailCardStyle.cornerRadius, style: .continuous))
        .holdingDetailGlassCard()
    }

    private func plotMessage(_ text: String) -> some View {
        Text(text)
            .appText(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
    }

    /// What the section used to print under the plot, kept with the rest of
    /// the method in the info alert.
    private var infoDetails: String {
        guard let snapshot else { return "" }
        let distribution = OIDistribution(contracts: snapshot.contracts)
        var lines = [
            L10n.text("到期 \(snapshot.from) – \(snapshot.through) · \(snapshot.contracts.count) 份合约"),
            L10n.text("已排除 \(snapshot.excluded) 份非标准或无法确认的合约。"),
        ]
        if let range = distribution.concentration {
            lines.append(L10n.text("集中区") + " \(money(range.lowerBound))–\(money(range.upperBound))")
        }
        lines.append(L10n.text("Yahoo · 获取于 \(snapshot.fetchedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(appLocale))) · OI 日期未知"))
        return "\n\n" + lines.joined(separator: "\n")
    }

    private func wallSummary(_ rows: [OIDistribution.Row], call: Bool) -> some View {
        let alignment: HorizontalAlignment = call ? .trailing : .leading
        return VStack(alignment: alignment, spacing: 4) {
            Text(L10n.text(call ? "Call 墙" : "Put 墙").uppercased())
                .appText(.caption, weight: .medium)
                .foregroundStyle(call ? CatfolioTheme.gain(for: colorScheme) : CatfolioTheme.loss(for: colorScheme))
            Text(rows.first.map { money($0.strike) } ?? "—")
                .font(Typography.number(size: 18))
                .foregroundStyle(.primary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text((rows.first.map { oiText(call ? $0.call : $0.put) } ?? "—") + " " + L10n.text("张"))
                // Tied peaks are all walls; the count opens the full list.
                if rows.count > 1 {
                    Button("×\(rows.count)") { showsWalls = true }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.text("查看全部并列价位"))
                }
            }
            .appNumber(.caption, weight: .medium)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .top))
    }

    private func wallsDetail(_ distribution: OIDistribution) -> some View {
        NavigationStack {
            List {
                ForEach([false, true], id: \.self) { call in
                    Section(L10n.text(call ? "Call 墙" : "Put 墙")) {
                        ForEach(call ? distribution.callWalls : distribution.putWalls) { row in
                            HStack {
                                Text(money(row.strike))
                                Spacer()
                                Text(oiText(call ? row.call : row.put))
                                Text(L10n.text("张")).foregroundStyle(.secondary)
                            }.appNumber(.body)
                        }
                    }
                }
            }.softTopScrollEdge().navigationTitle(L10n.text("全部墙位"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("完成")) { showsWalls = false } } }
        }
    }


}

/// Mirrors the VolumeDistributionPlot's Canvas, diagonal grain and glass rules.
/// Reuses its native chart interaction recognizer (including cancellation/haptics).
struct OptionsOIDistributionPlot: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var appLocale
    @ScaledMetric(relativeTo: .caption2) private var markerFontSize = 11.0
    let distribution: OIDistribution
    let currentPrice: Double?
    let holdingCost: Double?
    @Binding var selectedStrike: Double?
    var range: OIPlotRange = .main
    /// Where every visible label pill was drawn, so the rules can part
    /// around them rather than run underneath the glass.
    @State private var pillFrames: [String: CGRect] = [:]
    /// The finger's x while a strike is held; its readout goes on the far side.
    @State private var touchX: CGFloat?
    private static let plotSpace = "options-oi-plot-space"

    private struct PillFramesKey: PreferenceKey {
        static let defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    private var putColor: Color { CatfolioTheme.loss(for: colorScheme) }
    private var callColor: Color { CatfolioTheme.gain(for: colorScheme) }
    private var selectionColor: Color { CatfolioTheme.accent }
    private var currentTint: Color { colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.05) }

    var body: some View {
        let geometry = OIPlotGeometry(distribution, range: range, currentPrice: currentPrice)
        VStack(spacing: 12) {
            GeometryReader { proxy in
                let size = proxy.size
                let center = size.width / 2
                let laneWidth = max(1, center - 10)
                let axisWidth = min(size.width * 0.46, max(72, CGFloat(max(priceText(geometry.domain.lowerBound).count,
                                                     priceText(geometry.domain.upperBound).count)) * 7 + 18))
                ZStack(alignment: .topLeading) {
                    Canvas { context, canvas in
                        context.clip(to: Path(CGRect(origin: .zero, size: canvas)))
                        for side in [OIPlotGeometry.Side.put, .call] {
                            let color = side == .put ? putColor : callColor
                            for segment in geometry.segments(for: side) {
                                let path = silhouette(segment, side: side, geometry: geometry, size: canvas)
                                context.fill(path, with: .color(color.opacity(0.84)))
                                if let range = distribution.concentration {
                                    let upper = y(range.upperBound, geometry, canvas.height)
                                    let lower = y(range.lowerBound, geometry, canvas.height)
                                    context.drawLayer { layer in
                                        layer.clip(to: path)
                                        layer.fill(Path(CGRect(x: 0, y: 0, width: canvas.width, height: upper)), with: .color(Color(uiColor: .systemBackground).opacity(0.35)))
                                        layer.fill(Path(CGRect(x: 0, y: lower, width: canvas.width, height: max(0, canvas.height - lower))), with: .color(Color(uiColor: .systemBackground).opacity(0.35)))
                                    }
                                }
                                var stripes = Path()
                                var x = -canvas.height
                                while x < canvas.width + canvas.height {
                                    stripes.move(to: CGPoint(x: x, y: 0))
                                    stripes.addLine(to: CGPoint(x: x + canvas.height, y: canvas.height))
                                    x += 30
                                }
                                context.drawLayer { layer in
                                    layer.clip(to: path)
                                    layer.stroke(stripes, with: .color(.white.opacity(0.20)), lineWidth: 11)
                                }
                            }
                        }
                        var axis = Path()
                        axis.move(to: CGPoint(x: center, y: 0))
                        axis.addLine(to: CGPoint(x: center, y: canvas.height))
                        context.stroke(axis, with: .color(.secondary.opacity(0.22)), lineWidth: 0.5)
                    }
                    markerRules(geometry: geometry, size: size)
                    markerLane(call: false, geometry: geometry, size: size, width: laneWidth)
                    markerLane(call: true, geometry: geometry, size: size, width: laneWidth)
                    if let selectedStrike, let row = geometry.nearest(to: selectedStrike) {
                        let selectedY = y(row.strike, geometry, size.height)
                        // The readout goes to the side the finger is not on.
                        let onLeft = (touchX ?? 0) > size.width / 2
                        let ruleWidth = max(0, size.width - axisWidth - 12)
                        glassRule(color: selectionColor, width: ruleWidth, interactive: true)
                            .position(x: onLeft ? axisWidth + 6 + ruleWidth / 2 : ruleWidth / 2 + 6, y: selectedY)
                        pill(Text(priceText(row.strike)).appNumber(.micro, weight: .semibold)
                            .foregroundStyle(.white).lineLimit(1).padding(.horizontal, 8)
                            .frame(width: axisWidth, height: 26), tint: selectionColor, interactive: true)
                            .background(pillFrameReader("selection"))
                            .position(x: onLeft ? axisWidth / 2 : size.width - axisWidth / 2,
                                      y: min(size.height - 13, max(13, selectedY)))
                    }
                    ChartPointInteractionOverlay(onLocationChanged: { location in
                        touchX = location.x
                        let fraction = 1 - min(1, max(0, location.y / max(1, size.height)))
                        let price = geometry.domain.lowerBound + Double(fraction) * (geometry.domain.upperBound - geometry.domain.lowerBound)
                        selectedStrike = geometry.nearest(to: price)?.strike
                    }, onInteractionEnded: { selectedStrike = nil; touchX = nil })
                    .accessibilityIdentifier("options-oi-interaction")
                }
                .coordinateSpace(name: Self.plotSpace)
                .onPreferenceChange(PillFramesKey.self) { pillFrames = $0 }
                .onDisappear { selectedStrike = nil; touchX = nil }
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("options-oi-plot")
                .accessibilityLabel(L10n.text("按行权价排列的 Call 与 Put 未平仓合约分布，下方提供峰值和集中区数值"))
                .accessibilityValue(selectionDescription(geometry))
                .accessibilityAdjustableAction { direction in
                    let index = geometry.visibleRows.firstIndex { $0.strike == selectedStrike } ?? geometry.visibleRows.count / 2
                    let next = direction == .increment ? index + 1 : index - 1
                    if !geometry.visibleRows.isEmpty { selectedStrike = geometry.visibleRows[min(geometry.visibleRows.count - 1, max(0, next))].strike }
                }
            }
            axisLabels(geometry)
        }
        // Inside the glass card the waves take nearly its full width; the axis
        // row stays 20pt in from each side as drawn.
        .padding(.horizontal, 2)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .transaction { $0.animation = nil }
    }

    /// At rest: the OI scale at each side and the strike span between them.
    /// While a strike is held: that strike's Put and Call OI either side of it.
    private func axisLabels(_ geometry: OIPlotGeometry) -> some View {
        let row = selectedStrike.flatMap { geometry.nearest(to: $0) }
        let scale = DisplayFormat.compact(geometry.maximum, precision: .whole)
        return HStack {
            Text(row.map { oiLabel($0.put, observed: $0.hasPut) } ?? scale)
                .foregroundStyle(row == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(putColor))
            Spacer(minLength: 8)
            Text(row.map { priceText($0.strike) }
                 ?? "\(priceText(geometry.domain.lowerBound)) - \(priceText(geometry.domain.upperBound))")
                .foregroundStyle(row == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            Spacer(minLength: 8)
            Text(row.map { oiLabel($0.call, observed: $0.hasCall) } ?? scale)
                .foregroundStyle(row == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(callColor))
        }
        .appNumber(.caption, weight: .medium)
        .lineLimit(1)
        .padding(.horizontal, 18)
        .accessibilityHidden(true)
    }

    private func oiLabel(_ value: Double, observed: Bool) -> String {
        observed ? DisplayFormat.compact(value, precision: .whole) : "—"
    }

    private struct Marker: Identifiable {
        let id: String
        let title: String
        let prices: [Double]
        let color: Color
        let foreground: Color
        var anchor: Double { prices[0] }
    }

    private func markers(call: Bool, geometry: OIPlotGeometry) -> [Marker] {
        let walls = (call ? distribution.callWalls : distribution.putWalls).filter { geometry.domain.contains($0.strike) }
        let title = call ? "Call" : "Put"
        let color = call ? callColor : putColor
        // Dense tied walls get grouped labels; every true wall still has its own
        // rule, and the unabridged list/amounts remain immediately below the plot.
        let chunkSize = max(1, Int(ceil(Double(walls.count) / 4)))
        var result: [Marker] = stride(from: 0, to: walls.count, by: chunkSize).map { start in
            Marker(id: "wall-\(start)", title: title, prices: Array(walls[start..<min(walls.count, start + chunkSize)]).map(\.strike),
                   color: color, foreground: colorScheme == .dark ? .black : .white)
        }
        let reference = call ? holdingCost : currentPrice
        if let reference, reference.isFinite, reference > 0, geometry.domain.contains(reference) {
            result.append(Marker(id: "reference", title: L10n.text(call ? "成本" : "现价"),
                                 prices: [reference], color: call ? callColor.opacity(0.55) : currentTint, foreground: .primary))
        }
        return result.sorted { $0.anchor > $1.anchor }
    }

    private func markerLane(call: Bool, geometry: OIPlotGeometry, size: CGSize, width: CGFloat) -> some View {
        let markers = markers(call: call, geometry: geometry)
        let positions = OIPlotGeometry.labelPositions(markers.map { Double(y($0.anchor, geometry, size.height)) }, height: Double(size.height))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                let x = call ? width / 2 + 6 : size.width - width / 2 - 6
                let actualY = y(marker.anchor, geometry, size.height)
                let labelY = CGFloat(positions[index])
                let obscuredBySelection = selectedStrike.map { abs(y($0, geometry, size.height) - labelY) < 28 } ?? false
                if !obscuredBySelection && abs(labelY - actualY) > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: call ? 4 : size.width - 4, y: actualY))
                        path.addLine(to: CGPoint(x: call ? 4 : size.width - 4, y: labelY))
                        path.addLine(to: CGPoint(x: x, y: labelY))
                    }.stroke(marker.color.opacity(0.7), lineWidth: 1)
                }
                pill(markerLabel(marker)
                    .padding(.horizontal, 8)
                    .frame(minWidth: min(70, width), minHeight: 24), tint: marker.color)
                    .background { if !obscuredBySelection { pillFrameReader("\(call)-\(marker.id)") } }
                    .frame(maxWidth: width, alignment: call ? .leading : .trailing)
                    .position(x: x, y: labelY)
                    .opacity(obscuredBySelection ? 0 : 1)
            }
        }.allowsHitTesting(false)
    }

    /// Every wall and reference rule, from both lanes, in one layer under the
    /// pills. A rule stops short of any pill it would otherwise pass beneath,
    /// its own included, and carries on beyond it.
    private func markerRules(geometry: OIPlotGeometry, size: CGSize) -> some View {
        let rules = [false, true].flatMap { call in
            markers(call: call, geometry: geometry).flatMap { marker in
                marker.prices.map { (id: "\(call)-\(marker.id)-\($0)", y: y($0, geometry, size.height), color: marker.color) }
            }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(rules, id: \.id) { rule in
                ForEach(Array(ruleSegments(y: rule.y, width: size.width).enumerated()), id: \.offset) { _, segment in
                    glassRule(color: rule.color, width: segment.upperBound - segment.lowerBound)
                        .position(x: (segment.lowerBound + segment.upperBound) / 2, y: rule.y)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func ruleSegments(y: CGFloat, width: CGFloat) -> [ClosedRange<CGFloat>] {
        let gap: CGFloat = 4
        var segments: [ClosedRange<CGFloat>] = [6...max(6, width - 6)]
        // A 5pt rule touches a pill when its centre is within half its width.
        for frame in pillFrames.values where y >= frame.minY - 2.5 && y <= frame.maxY + 2.5 {
            let cut = (frame.minX - gap)...(frame.maxX + gap)
            segments = segments.flatMap { run -> [ClosedRange<CGFloat>] in
                guard cut.upperBound > run.lowerBound, cut.lowerBound < run.upperBound else { return [run] }
                var parts: [ClosedRange<CGFloat>] = []
                if cut.lowerBound - run.lowerBound >= 8 { parts.append(run.lowerBound...cut.lowerBound) }
                if run.upperBound - cut.upperBound >= 8 { parts.append(cut.upperBound...run.upperBound) }
                return parts
            }
        }
        return segments
    }

    private func pillFrameReader(_ id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(key: PillFramesKey.self, value: [id: proxy.frame(in: .named(Self.plotSpace))])
        }
    }

    private func markerLabel(_ marker: Marker) -> some View {
        let value = marker.prices.count == 1 ? priceText(marker.anchor) : "×\(marker.prices.count)"
        let text = Text(marker.title + " ").font(Typography.text(size: markerFontSize, weight: .semibold))
            + Text(value).font(Typography.number(size: markerFontSize, weight: .bold))
        return ViewThatFits(in: .horizontal) {
            // Measure the complete localized label before constraining the bubble.
            text.fixedSize(horizontal: true, vertical: false)
            text.lineLimit(1).minimumScaleFactor(0.5)
        }
        .foregroundStyle(marker.foreground)
    }

    private func y(_ price: Double, _ geometry: OIPlotGeometry, _ height: CGFloat, clamped: Bool = true) -> CGFloat {
        let fraction = (price - geometry.domain.lowerBound) / (geometry.domain.upperBound - geometry.domain.lowerBound)
        return height * CGFloat(1 - (clamped ? min(1, max(0, fraction)) : fraction))
    }

    private func silhouette(_ vertices: [OIPlotGeometry.Vertex], side: OIPlotGeometry.Side,
                            geometry: OIPlotGeometry, size: CGSize) -> Path {
        let center = size.width / 2
        let sign: CGFloat = side == .put ? -1 : 1
        let ordered = Array(vertices.reversed())
        let slopes = Array(OIPlotGeometry.edgeSlopes(vertices).reversed())
        let points = ordered.map { vertex in
            CGPoint(x: center + sign * CGFloat(vertex.width) * (center - 2), y: y(vertex.strike, geometry, size.height, clamped: false))
        }
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        for index in 0..<(points.count - 1) {
            let start = ordered[index], end = ordered[index + 1]
            let gap = (end.strike - start.strike) / 3
            let control1 = CGPoint(x: center + sign * CGFloat(start.width + slopes[index] * gap) * (center - 2),
                                   y: y(start.strike + gap, geometry, size.height, clamped: false))
            let control2 = CGPoint(x: center + sign * CGFloat(end.width - slopes[index + 1] * gap) * (center - 2),
                                   y: y(end.strike - gap, geometry, size.height, clamped: false))
            path.addCurve(to: points[index + 1], control1: control1, control2: control2)
        }
        path.addLine(to: CGPoint(x: center, y: last.y))
        path.addLine(to: CGPoint(x: center, y: first.y))
        path.closeSubpath()
        return path
    }

    private func priceText(_ price: Double) -> String {
        OIPriceLabel.text(price, locale: appLocale)
    }

    private func selectionDescription(_ geometry: OIPlotGeometry) -> String {
        guard let selectedStrike, let row = geometry.nearest(to: selectedStrike) else { return "" }
        let call = row.hasCall ? row.call.formatted(.number.precision(.fractionLength(0)).locale(appLocale)) : "—"
        let put = row.hasPut ? row.put.formatted(.number.precision(.fractionLength(0)).locale(appLocale)) : "—"
        return L10n.text("\(priceText(row.strike)) · Call \(call) 张 · Put \(put) 张")
    }

    @ViewBuilder private func glassRule(color: Color, width: CGFloat, interactive: Bool = false) -> some View {
        let rule = Color.clear.frame(width: max(0, width), height: 5)
        if #available(iOS 26.0, *) {
            rule.glassEffect(glass(color, interactive), in: Capsule())
        } else {
            rule.background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().fill(color.opacity(0.72)) }
                .overlay { Capsule().stroke(.white.opacity(0.28), lineWidth: 0.5) }
        }
    }

    @ViewBuilder private func pill<Content: View>(_ content: Content, tint: Color, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            // The label rides above the glass rather than inside it, where the
            // tinted material washes into the ink: black has to read as black.
            content.hidden()
                .glassEffect(glass(tint, interactive), in: Capsule())
                .overlay { content }
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .background(tint.opacity(0.62), in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.32), lineWidth: 0.5) }
        }
    }

    @available(iOS 26.0, *) private func glass(_ tint: Color, _ interactive: Bool) -> Glass {
        let glass = Glass.clear.tint(tint)
        return interactive ? glass.interactive() : glass
    }
}
