import Foundation
import CryptoKit
import FoundationModels
import OSLog

/// Market data can be fetched again, so coalesce bursts of updates and keep
/// JSON encoding and the atomic file replacement off the cache actor.
private func writeMarketCache<Value: Encodable & Sendable>(
    _ snapshot: Value,
    to url: URL,
    writeData: @escaping @Sendable (Data, URL) async throws -> Void
) async -> Bool {
    await Task.detached(priority: .utility) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try await writeData(data, url)
            return true
        } catch {
            return false
        }
    }.value
}

/// Daily closes, one small file per symbol. The cache used to be a single
/// file holding every symbol's whole history: it grew past 20 MB, was decoded
/// whole before the first chart could draw and re-encoded whole whenever a
/// day was added, so launch slowed as it grew. A symbol is now read the
/// first time it is asked for, and a write touches only the symbols changed.
actor LocalHistoricalPriceCache {
    struct Hit: Sendable {
        let values: [String: Double]
        let isFresh: Bool
        /// The saved history reaches back to the requested start, so only
        /// the days after `lastDate` need fetching.
        let coversStart: Bool
        let lastDate: String?
    }

    private struct Entry: Codable, Sendable {
        var fetchedAt: Date
        var values: [String: Double]
        var requestedFrom: String?
        var requestedTo: String?
    }

    static let shared = LocalHistoricalPriceCache()

    private var entries: [String: Entry] = [:]
    /// Symbols whose file has been read, or found missing.
    private var probed: Set<String> = []
    private var dirty: Set<String> = []
    private var hasMigrated = false
    private var isWriteScheduled = false
    private let directoryOverride: URL?
    private let writeDelay: Duration
    private let writeData: @Sendable (Data, URL) async throws -> Void

    /// `cacheURL` is the directory holding the per-symbol files.
    init(
        cacheURL: URL? = nil,
        writeDelay: Duration = .seconds(1),
        writeData: @escaping @Sendable (Data, URL) async throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        directoryOverride = cacheURL
        self.writeDelay = writeDelay
        self.writeData = writeData
    }

    func lookup(symbol: String, from: String, to: String) -> Hit? {
        guard let entry = entry(for: symbol) else { return nil }
        let filtered = entry.values.filter { $0.key >= from && $0.key <= to }
        guard !filtered.isEmpty else { return nil }
        return Hit(
            values: filtered,
            isFresh: Date().timeIntervalSince(entry.fetchedAt) < 12 * 60 * 60
                && entry.requestedFrom.map { $0 <= from } == true
                && entry.requestedTo.map { $0 >= to } == true,
            coversStart: entry.requestedFrom.map { $0 <= from } == true,
            lastDate: entry.values.keys.max()
        )
    }

    /// Adds the days fetched since the last save instead of replacing the
    /// history. A dividend or split in those days re-bases every earlier
    /// adjusted close at the source; the day both sets share says by how
    /// much, and the saved days are re-based to match rather than fetched
    /// again. Nil when the two share no day, which needs a full fetch.
    func extend(symbol: String, tail: [String: Double], requestedTo: String) -> [String: Double]? {
        guard var entry = entry(for: symbol),
              let anchor = tail.keys.filter({ entry.values[$0] != nil }).min(),
              let saved = entry.values[anchor], saved > 0,
              let fetched = tail[anchor], fetched > 0 else { return nil }
        let ratio = fetched / saved
        if abs(ratio - 1) > 1e-9 {
            entry.values = entry.values.mapValues { $0 * ratio }
        }
        entry.values.merge(tail) { _, new in new }
        entry.fetchedAt = Date()
        entry.requestedTo = max(entry.requestedTo ?? requestedTo, requestedTo)
        store(entry, for: symbol)
        return entry.values
    }

    func save(symbol: String, values: [String: Double], requestedFrom: String, requestedTo: String) {
        guard !values.isEmpty else { return }
        let previous = entry(for: symbol)
        var merged = previous?.values ?? [:]
        merged.merge(values) { _, new in new }
        store(Entry(
            fetchedAt: Date(),
            values: merged,
            requestedFrom: min(previous?.requestedFrom ?? requestedFrom, requestedFrom),
            requestedTo: max(previous?.requestedTo ?? requestedTo, requestedTo)
        ), for: symbol)
    }

    private func entry(for symbol: String) -> Entry? {
        migrateLegacyFileIfNeeded()
        if let entry = entries[symbol] { return entry }
        guard !probed.contains(symbol) else { return nil }
        probed.insert(symbol)
        guard let data = try? Data(contentsOf: fileURL(for: symbol)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        entries[symbol] = entry
        return entry
    }

    private func store(_ entry: Entry, for symbol: String) {
        entries[symbol] = entry
        probed.insert(symbol)
        dirty.insert(symbol)
        scheduleWrite()
    }

    /// Saves close together share one write; a rebuild fetching hundreds of
    /// symbols writes each of them once. A process killed during the short
    /// delay may lose this disposable market cache.
    private func scheduleWrite() {
        guard !isWriteScheduled else { return }
        isWriteScheduled = true
        Task {
            try? await Task.sleep(for: writeDelay)
            await flush()
        }
    }

    private func flush() async {
        let snapshot = dirty.reduce(into: [URL: Entry]()) { files, symbol in
            if let entry = entries[symbol] { files[fileURL(for: symbol)] = entry }
        }
        dirty.removeAll()
        let directory = directoryURL
        let writeData = writeData
        await Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            for (url, entry) in snapshot {
                guard let data = try? encoder.encode(entry) else { continue }
                try? await writeData(data, url)
            }
        }.value
        isWriteScheduled = false
        if !dirty.isEmpty { scheduleWrite() }
    }

    /// The single-file cache, split once into per-symbol files so nothing
    /// has to be fetched again, then removed.
    private func migrateLegacyFileIfNeeded() {
        guard !hasMigrated else { return }
        hasMigrated = true
        guard directoryOverride == nil else { return }
        let legacy = directoryURL.deletingLastPathComponent()
            .appendingPathComponent("catfolio-market-history-units-v2.json")
        guard let data = try? Data(contentsOf: legacy) else { return }
        try? FileManager.default.removeItem(at: legacy)
        guard let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        for (symbol, entry) in decoded where entries[symbol] == nil {
            entries[symbol] = entry
            probed.insert(symbol)
            dirty.insert(symbol)
        }
        if !dirty.isEmpty { scheduleWrite() }
    }

    private var directoryURL: URL {
        if let directoryOverride { return directoryOverride }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("catfolio-market-history-v3", isDirectory: true)
    }

    /// Hashed, so symbols such as `^GSPC` or `BRK/B` make safe file names.
    private func fileURL(for symbol: String) -> URL {
        let digest = SHA256.hash(data: Data(symbol.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent("\(digest).json")
    }
}

struct MarketIntradayBar: Codable, Sendable {
    let timestamp: Date
    let close: Double
}

/// Minute bars change continuously and have a very different refresh cadence
/// from end-of-day history. Keep them in their own cache so opening a chart
/// repeatedly does not spend another vendor request, while daily history can
/// retain its longer cache lifetime.
actor LocalIntradayPriceCache {
    struct Hit: Sendable {
        let bars: [MarketIntradayBar]
        let isFresh: Bool
    }

    private struct Entry: Codable, Sendable {
        let fetchedAt: Date
        let bars: [MarketIntradayBar]
    }

    static let shared = LocalIntradayPriceCache()

    private var entries: [String: Entry] = [:]
    private var hasLoaded = false
    private var isWriteScheduled = false
    private var writeGeneration: UInt64 = 0
    private let cacheURLOverride: URL?
    private let writeDelay: Duration
    private let writeData: @Sendable (Data, URL) async throws -> Void

    init(
        cacheURL: URL? = nil,
        writeDelay: Duration = .seconds(1),
        writeData: @escaping @Sendable (Data, URL) async throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        cacheURLOverride = cacheURL
        self.writeDelay = writeDelay
        self.writeData = writeData
    }

    func lookup(symbol: String) -> Hit? {
        loadIfNeeded()
        guard let entry = entries[symbol.uppercased()], entry.bars.count > 1 else { return nil }
        return Hit(
            bars: entry.bars,
            isFresh: Date().timeIntervalSince(entry.fetchedAt) < 5 * 60
        )
    }

    func save(symbol: String, bars: [MarketIntradayBar]) {
        guard bars.count > 1 else { return }
        loadIfNeeded()
        entries[symbol.uppercased()] = Entry(fetchedAt: Date(), bars: bars)
        scheduleWrite()
    }

    private func scheduleWrite() {
        writeGeneration &+= 1
        guard !isWriteScheduled else { return }
        isWriteScheduled = true
        Task {
            try? await Task.sleep(for: writeDelay)
            await flush()
        }
    }

    private func flush() async {
        let generation = writeGeneration
        let snapshot = entries
        let url = cacheURL
        _ = await writeMarketCache(snapshot, to: url, writeData: writeData)
        isWriteScheduled = false
        if writeGeneration != generation {
            scheduleWrite()
        }
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private var cacheURL: URL {
        if let cacheURLOverride { return cacheURLOverride }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("catfolio-intraday-history-units-v2.json")
    }
}

struct MarketDailyBar: Codable, Sendable {
    let date: String
    let close: Double
    let high: Double
    let low: Double
    let volume: Double
}

struct CurrentOpenBackcastPosition {
    let position: LocalPositionRecord
    let startDate: String
}

/// Daily OHLCV changes at most once per trading day, so keep it across app
/// launches instead of spending one vendor request every time a detail opens.
actor LocalVolumeBarCache {
    struct Hit: Sendable {
        let bars: [MarketDailyBar]
        let isFresh: Bool
    }

    private struct Entry: Codable, Sendable {
        let fetchedAt: Date
        let bars: [MarketDailyBar]
    }

    static let shared = LocalVolumeBarCache()

    private var entries: [String: Entry] = [:]
    private var hasLoaded = false
    private var isWriteScheduled = false
    private var writeGeneration: UInt64 = 0
    private let cacheURLOverride: URL?
    private let writeDelay: Duration
    private let writeData: @Sendable (Data, URL) async throws -> Void

    init(
        cacheURL: URL? = nil,
        writeDelay: Duration = .seconds(1),
        writeData: @escaping @Sendable (Data, URL) async throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        cacheURLOverride = cacheURL
        self.writeDelay = writeDelay
        self.writeData = writeData
    }

    func lookup(symbol: String) -> Hit? {
        loadIfNeeded()
        guard let entry = entries[symbol.uppercased()], !entry.bars.isEmpty else { return nil }
        return Hit(
            bars: entry.bars,
            isFresh: Date().timeIntervalSince(entry.fetchedAt) < 24 * 60 * 60
        )
    }

    func save(symbol: String, bars: [MarketDailyBar]) {
        guard !bars.isEmpty else { return }
        loadIfNeeded()
        entries[symbol.uppercased()] = Entry(fetchedAt: Date(), bars: bars)
        scheduleWrite()
    }

    private func scheduleWrite() {
        writeGeneration &+= 1
        guard !isWriteScheduled else { return }
        isWriteScheduled = true
        Task {
            try? await Task.sleep(for: writeDelay)
            await flush()
        }
    }

    private func flush() async {
        let generation = writeGeneration
        let snapshot = entries
        let url = cacheURL
        _ = await writeMarketCache(snapshot, to: url, writeData: writeData)
        isWriteScheduled = false
        if writeGeneration != generation {
            scheduleWrite()
        }
    }

    private func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private var cacheURL: URL {
        if let cacheURLOverride { return cacheURLOverride }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("catfolio-volume-bars-units-v2.json")
    }
}
