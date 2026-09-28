import Foundation

struct SectorRotationSnapshot: Codable {
    struct TrailPoint: Codable, Identifiable {
        let date: String
        let x: Double
        let y: Double
        var id: String { date }
    }
    struct Sector: Codable, Identifiable {
        let symbol: String
        let name: String
        let nameZh: String
        let x: Double
        let y: Double
        let relativeTrend: Double
        let relativeMomentum: Double
        let quadrant: String
        let quadrantLabel: String
        let previousQuadrant: String?
        let weeklyChange: String
        let trail: [TrailPoint]
        var id: String { symbol }
        var displayName: String { AppLanguage.currentIdentifier == "en" ? name : nameZh }
        var displayQuadrant: String { Self.label(quadrant) }
        static func label(_ value: String) -> String {
            switch value {
            case "leading": L10n.text("领先")
            case "weakening": L10n.text("减弱")
            case "lagging": L10n.text("落后")
            case "improving": L10n.text("改善")
            default: L10n.text("轮动中性")
            }
        }
        var weeklyLabel: String {
            switch weeklyChange {
            case "strengthening": L10n.text("动量增强")
            case "weakening": L10n.text("动量减弱")
            case "unchanged": L10n.text("动量持平")
            default: L10n.text("历史不足")
            }
        }
        var explanation: String {
            let base: String
            switch quadrant {
            case "leading": base = L10n.text("中期与近月位置都高于板块中位数，相对表现保持在较强一侧。")
            case "weakening": base = L10n.text("中期位置较强，近月位置转弱，关注相对动量的变化。")
            case "lagging": base = L10n.text("中期与近月位置都低于板块中位数，相对表现仍偏弱。")
            case "improving": base = L10n.text("中期位置偏弱，近月位置较强，相对动量正在改善。")
            default: base = L10n.text("位置接近截面中心，板块之间的强弱差异尚不鲜明。")
            }
            if let previousQuadrant, previousQuadrant != quadrant {
                return L10n.text("较上周从「\(Self.label(previousQuadrant))」转为「\(displayQuadrant)」。") + " " + base
            }
            return base
        }
    }
    struct Preset: Codable {
        let trendWindow: [Int]
        let momentumWindow: [Int]
        let smoothing: Int
    }
    let asOf: String
    let asOfTimezone: String
    let generatedAt: String
    let validUntil: String
    let stale: Bool
    let benchmark: String
    let calcVersion: Int
    let preset: Preset
    let backfilled: Bool
    let dates: [String]
    let sectors: [Sector]
    static let symbols = ["XLK", "XLF", "XLE", "XLV", "XLY", "XLP", "XLI", "XLB", "XLU", "XLRE", "XLC"]
    var isExpired: Bool {
        guard let expiry = ISO8601DateFormatter().date(from: validUntil) else { return true }
        return stale || Date() >= expiry
    }
    var labeledSymbols: Set<String> {
        Set(sectors.sorted { a, b in
            let ar = a.x * a.x + a.y * a.y, br = b.x * b.x + b.y * b.y
            return ar == br ? a.symbol < b.symbol : ar > br
        }.prefix(4).map(\.symbol))
    }
    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        func validDate(_ s: String) -> Bool { formatter.date(from: s).map { formatter.string(from: $0) == s } ?? false }
        let quadrants: Set<String> = ["leading", "weakening", "lagging", "improving", "neutral"]
        guard value.calcVersion == 2, value.benchmark == "SPY", value.asOfTimezone == "America/New_York",
              value.preset.trendWindow == [63, 21], value.preset.momentumWindow == [21, 0], value.preset.smoothing == 5,
              validDate(value.asOf), ISO8601DateFormatter().date(from: value.validUntil) != nil,
              Set(value.sectors.map(\.symbol)) == Set(symbols), value.sectors.count == 11,
              value.dates == value.dates.sorted(), Set(value.dates).count == value.dates.count,
              value.dates.allSatisfy(validDate), value.dates.contains(value.asOf),
              value.sectors.allSatisfy({ s in
                  s.x.isFinite && s.y.isFinite && abs(s.x) <= 2.5 && abs(s.y) <= 2.5 &&
                  s.relativeTrend.isFinite && s.relativeMomentum.isFinite && s.relativeTrend > -1 && s.relativeMomentum > -1 &&
                  quadrants.contains(s.quadrant) && s.trail.count <= 8 &&
                  s.trail.map(\.date) == s.trail.map(\.date).sorted() && Set(s.trail.map(\.date)).count == s.trail.count &&
                  s.trail.allSatisfy { validDate($0.date) && $0.date < value.asOf && $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 2.5 && abs($0.y) <= 2.5 }
              }) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}

/// An independent snapshot reader. Never participates in account or quote refreshes.
actor SectorRotationStore {
    static let shared = SectorRotationStore()
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sector-rotation-v2", isDirectory: true)

    private var localSnapshots: [SectorRotationSnapshot]?

    func local() -> [SectorRotationSnapshot] {
        if let localSnapshots { return localSnapshots }
        var snapshots: [SectorRotationSnapshot] = []
        if let bundle = Bundle.main.url(forResource: "sector_rotation_history", withExtension: "json"),
           let data = try? Data(contentsOf: bundle),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            snapshots = array.compactMap { object in
                guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
                return try? SectorRotationSnapshot.decode(data)
            }
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            snapshots += files.filter { $0.pathExtension == "json" }.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? SectorRotationSnapshot.decode(data)
            }
        }
        var unique: [String: SectorRotationSnapshot] = [:]
        for snapshot in snapshots { unique[snapshot.asOf] = snapshot }
        let result = unique.values.sorted { $0.asOf < $1.asOf }
        localSnapshots = result
        return result
    }

    func fetch(endpoint: String, date: String? = nil) async throws -> SectorRotationSnapshot {
        guard var parts = URLComponents(string: endpoint), parts.scheme == "https", parts.host != nil,
              parts.user == nil, parts.password == nil else { throw URLError(.badURL) }
        var query = (parts.queryItems ?? []).filter { $0.name != "asOf" }
        if let date { query.append(URLQueryItem(name: "asOf", value: date)) }
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.recordedData(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard data.count < 2_000_000 else {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw URLError(.badServerResponse)
        }
        let snapshot: SectorRotationSnapshot
        do {
            snapshot = try SectorRotationSnapshot.decode(data)
        } catch {
            DataSourceHealth.reportUnusable(DataSource.of(request.url), issue: .invalidFormat)
            throw error
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(snapshot.asOf + ".json"), options: [.atomic, .completeFileProtectionUnlessOpen])
        // A successful write invalidates the actor's in-memory history.
        localSnapshots = nil
        return snapshot
    }
}
