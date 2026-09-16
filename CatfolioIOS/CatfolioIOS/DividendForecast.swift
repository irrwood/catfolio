import Foundation
import CryptoKit
import FoundationModels
import OSLog

/// The last comparison computed for each portfolio scope, kept on disk. The
/// page opens on it rather than on a placeholder, and a portfolio whose
/// trades, positions and benchmarks have not changed since earlier the same
/// day is not rebuilt at all — the rebuild fetches every holding's history
/// and can take minutes for a long account.
enum ComparisonSnapshotCache {
    struct Entry: Codable {
        let fingerprint: String
        let computedAt: Date
        let response: ComparisonResponse
    }

    /// Everything the comparison is computed from except prices, which the
    /// daily history cache governs on its own. The day is part of it, so the
    /// first visit each day rebuilds behind the saved result.
    private struct Inputs: Encodable {
        let version = 1
        let day: String
        let language: String
        let benchmarks: [String]
        let source: String
        let isSynthetic: Bool?
        let transactions: [LocalTransactionRecord]
        let positions: [String]
        let snapshots: [LocalPortfolioSnapshotRecord]
    }

    static func fingerprint(for document: LocalPortfolioDocument) -> String {
        let inputs = Inputs(
            day: DayDateCodec.string(from: Date()),
            language: ContentLanguage.current,
            benchmarks: ComparisonBenchmarkCatalog.symbols,
            source: document.source,
            isSynthetic: document.isSynthetic,
            transactions: document.transactions ?? [],
            positions: document.positions.map { "\($0.accountKey)|\($0.ticker)|\($0.shares)|\($0.openedDate ?? "")" }.sorted(),
            snapshots: document.isPublicDisclosure ? document.snapshots : []
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? encoder.encode(inputs) else { return UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func load(scope: String) -> Entry? {
        guard let data = try? Data(contentsOf: url(for: scope)) else { return nil }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try? decoder.decode(Entry.self, from: data)
    }

    static func save(_ response: ComparisonResponse, fingerprint: String, scope: String) {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        guard let data = try? encoder.encode(Entry(fingerprint: fingerprint, computedAt: Date(), response: response)) else { return }
        let url = url(for: scope)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func url(for scope: String) -> URL {
        let name = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("catfolio-comparison-v1", isDirectory: true)
            .appendingPathComponent(name + ".json")
    }
}

/// This year's dividends, before they have all been paid: what has arrived,
/// plus what the holdings paid over the same weeks last year.
enum DividendForecast {
    struct Payment: Equatable, Sendable {
        let exDate: String
        let perShare: Double
        let currency: String
    }

    /// About how long a dividend takes from its ex-date to the account.
    static let payLag: TimeInterval = 21 * 86_400

    /// One holding's remaining payments this year: last year's with ex-dates
    /// a year before the payments still to come — after today less the pay
    /// lag, and before the year's end less it.
    static func remaining(shares: Double, payments: [Payment], today: Date) -> (amount: Double, currency: String) {
        guard shares > 0, let year = Int(DayDateCodec.string(from: today).prefix(4)),
              let yearEnd = DayDateCodec.date(from: String(format: "%04d-12-31", year)) else { return (0, "USD") }
        let from = DayDateCodec.string(from: oneYearBefore(today).addingTimeInterval(-payLag))
        let through = DayDateCodec.string(from: oneYearBefore(yearEnd).addingTimeInterval(-payLag))
        let due = payments.filter { $0.exDate > from && $0.exDate <= through }
        return (due.reduce(0) { $0 + $1.perShare } * shares, due.first?.currency ?? payments.first?.currency ?? "USD")
    }

    private static func oneYearBefore(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .year, value: -1, to: date) ?? date
    }
}

actor DividendScheduleCache {
    static let shared = DividendScheduleCache()
    private var entries: [String: (fetched: Date, payments: [DividendForecast.Payment])] = [:]

    func lookup(_ symbol: String) -> [DividendForecast.Payment]? {
        guard let entry = entries[symbol], Date().timeIntervalSince(entry.fetched) < 12 * 3_600 else { return nil }
        return entry.payments
    }

    func save(_ payments: [DividendForecast.Payment], for symbol: String) {
        entries[symbol] = (Date(), payments)
    }
}
