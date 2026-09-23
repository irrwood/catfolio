import Foundation
import CoreFoundation

struct EarningsObservation: Codable, Identifiable, Equatable, Sendable {
    let date: String
    /// Provider's period label, when available. Report dates are never called fiscal quarters.
    let period: String?
    let epsActual: Double?
    let epsEstimated: Double?
    let revenueActual: Double?
    let revenueEstimated: Double?
    var id: String { date }

    /// Calendar quarter of the reported period, falling back to announcement date.
    var quarterLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM yyyy"
        let periodDate = period.flatMap { formatter.date(from: $0) }
        formatter.dateFormat = "yyyy-MM-dd"
        guard let value = periodDate ?? formatter.date(from: date) else { return "—" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let month = calendar.component(.month, from: value)
        let year = calendar.component(.year, from: value) % 100
        return String(format: "Q%d’%02d", (month - 1) / 3 + 1, year)
    }

    func values(revenue: Bool) -> (actual: Double?, estimate: Double?) {
        revenue ? (revenueActual, revenueEstimated) : (epsActual, epsEstimated)
    }

    static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        let parsed: Double?
        if let n = value as? NSNumber {
            guard CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            parsed = n.doubleValue
        }
        else if let s = value as? String {
            parsed = Double(s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces))
        } else { parsed = nil }
        return parsed.flatMap { $0.isFinite ? $0 : nil }
    }

    static func validDate(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    static func fmp(_ rows: [[String: Any]], symbol: String) -> [Self] {
        var seen = Set<String>()
        return rows.sorted { ($0["lastUpdated"] as? String ?? "") > ($1["lastUpdated"] as? String ?? "") }.compactMap { row in
            guard (row["symbol"] as? String)?.uppercased() == symbol.uppercased(),
                  let date = row["date"] as? String, validDate(date), !seen.contains(date) else { return nil }
            let point = Self(date: date, period: nil,
                epsActual: number(row["epsActual"]), epsEstimated: number(row["epsEstimated"]),
                revenueActual: number(row["revenueActual"]), revenueEstimated: number(row["revenueEstimated"]))
            guard [point.epsActual, point.epsEstimated, point.revenueActual, point.revenueEstimated].contains(where: { $0 != nil }) else { return nil }
            seen.insert(date)
            return point
        }.sorted { $0.date < $1.date }
    }

    static func nasdaq(_ data: Data) throws -> [Self] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = root["status"] as? [String: Any],
              let code = status["rCode"] as? Int, (200..<300).contains(code) else {
            throw ScreenFailure.message(L10n.text("Nasdaq 未返回盈利历史。"))
        }
        if root["data"] is NSNull { return [] }
        guard let body = root["data"] as? [String: Any],
              let table = body["earningsSurpriseTable"] as? [String: Any],
              let rows = table["rows"] as? [[String: Any]] else {
            throw ScreenFailure.message(L10n.text("Nasdaq 未返回盈利历史。"))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "M/d/yyyy"
        formatter.isLenient = false
        let output = DateFormatter()
        output.locale = formatter.locale
        output.timeZone = formatter.timeZone
        output.dateFormat = "yyyy-MM-dd"
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let raw = row["dateReported"] as? String, let parsed = formatter.date(from: raw) else { return nil }
            let date = output.string(from: parsed)
            guard seen.insert(date).inserted else { return nil }
            let actual = number(row["eps"]), estimate = number(row["consensusForecast"])
            guard actual != nil || estimate != nil else { return nil }
            return Self(date: date, period: row["fiscalQtrEnd"] as? String,
                epsActual: actual, epsEstimated: estimate, revenueActual: nil, revenueEstimated: nil)
        }.sorted { $0.date < $1.date }
    }
}

struct EarningsSnapshot: Codable, Sendable {
    let observations: [EarningsObservation]
    let source: String
    let fetchedAt: Date
    let note: String?

    var hasUsableObservations: Bool {
        observations.contains { point in
            EarningsObservation.validDate(point.date)
            && [point.epsActual, point.epsEstimated, point.revenueActual, point.revenueEstimated]
                .compactMap { $0 }.contains(where: \.isFinite)
        }
    }
}

actor EarningsHistoryClient {
    static let shared = EarningsHistoryClient()
    private var cache: [String: EarningsSnapshot] = [:]
    private let cacheURL: URL
    private let session: URLSession

    init(cacheURL: URL? = nil, session: URLSession = .shared) {
        self.session = session
        self.cacheURL = cacheURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EarningsHistory/snapshots-v1.json")
        if let bytes = try? Data(contentsOf: self.cacheURL),
           let stored = try? JSONDecoder().decode([String: EarningsSnapshot].self, from: bytes) { cache = stored }
    }

    func cached(symbol: String) -> EarningsSnapshot? {
        guard let value = cache[symbol.uppercased()] else { return nil }
        return value.hasUsableObservations || Date().timeIntervalSince(value.fetchedAt) < 86400 ? value : nil
    }

    func load(symbol: String, forceRefresh: Bool = false) async throws -> EarningsSnapshot {
        let key = symbol.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 30, key.range(of: "^[A-Z0-9.^=-]+$", options: .regularExpression) != nil else {
            throw ScreenFailure.message(L10n.text("证券代码无效。"))
        }
        if !forceRefresh, let hit = cache[key], Date().timeIntervalSince(hit.fetchedAt) < 86400 { return hit }
        var reason: String?
        var fmpWasEmpty = false
        do {
            let rows = try await StockScreenDataClient.shared.rows("earnings", query: ["symbol": key])
            let points = EarningsObservation.fmp(rows, symbol: key)
            if !points.isEmpty {
                return try store(EarningsSnapshot(observations: points, source: "FMP", fetchedAt: Date(), note: nil), key: key)
            }
            reason = L10n.text("FMP 暂无盈利历史覆盖。")
            fmpWasEmpty = true
        } catch {
            try Task.checkCancellation()
            reason = error.localizedDescription
        }
        // Fallback is kept as a separate snapshot, never mixed with FMP's EPS basis.
        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.nasdaq.com/api/company/\(encoded)/earnings-surprise") else {
            throw ScreenFailure.message(L10n.text("证券代码无效。"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 Catfolio-iOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.recordedData(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw ScreenFailure.message(L10n.text("盈利历史网络请求失败。"))
            }
            let points: [EarningsObservation]
            do {
                points = try EarningsObservation.nasdaq(bytes)
            } catch {
                DataSourceHealth.reportUnusable(DataSource.of(url), issue: .invalidFormat)
                throw error
            }
            if points.isEmpty, fmpWasEmpty {
                // Two successful empty responses are absence, not a network error.
                // Do not overwrite an older usable history or persist a negative cache.
                if let previous = cache[key], previous.hasUsableObservations { return previous }
                return EarningsSnapshot(observations: [], source: "FMP / Nasdaq", fetchedAt: .now, note: nil)
            }
            guard !points.isEmpty else { throw ScreenFailure.message(L10n.text("暂无盈利历史。")) }
            // Do not silently replace a full cached history with reduced fallback coverage.
            if let old = cache[key], old.source == "FMP" { throw ScreenFailure.message(reason ?? L10n.text("更新失败，保留缓存。")) }
            return try store(EarningsSnapshot(observations: points, source: "Nasdaq", fetchedAt: Date(),
                note: L10n.text("Nasdaq 仅提供最近四期 EPS；收入对比需要 FMP 盈利接口权限。")), key: key)
        } catch {
            try Task.checkCancellation()
            throw ScreenFailure.message([reason, error.localizedDescription].compactMap { $0 }.joined(separator: "\n"))
        }
    }

    private func store(_ snapshot: EarningsSnapshot, key: String) throws -> EarningsSnapshot {
        try Task.checkCancellation()
        cache[key] = snapshot
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let bytes = try? JSONEncoder().encode(cache) {
            try? bytes.write(to: cacheURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
        return snapshot
    }
}
