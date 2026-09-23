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

    func lookup(symbol: String, from: String, to: String) -> Hit? {
        loadIfNeeded()
        guard let entry = entries[symbol] else { return nil }
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
        loadIfNeeded()
        guard var entry = entries[symbol],
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
        entries[symbol] = entry
        scheduleWrite()
        return entry.values
    }

    func save(symbol: String, values: [String: Double], requestedFrom: String, requestedTo: String) {
        guard !values.isEmpty else { return }
        loadIfNeeded()
        var merged = entries[symbol]?.values ?? [:]
        merged.merge(values) { _, new in new }
        let previous = entries[symbol]
        entries[symbol] = Entry(
            fetchedAt: Date(),
            values: merged,
            requestedFrom: min(previous?.requestedFrom ?? requestedFrom, requestedFrom),
            requestedTo: max(previous?.requestedTo ?? requestedTo, requestedTo)
        )
        scheduleWrite()
    }

    /// The file holds every symbol's whole history. Writing it after each
    /// save made a rebuild fetching hundreds of symbols re-encode the file
    /// hundreds of times; saves close together now share one write. A process
    /// killed during the short delay may lose this disposable market cache.
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
        return root.appendingPathComponent("catfolio-market-history-units-v2.json")
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
