import Foundation
import CryptoKit

actor ChinaDailyCache {
    static let shared = ChinaDailyCache()
    struct Entry: Codable {
        let from: String
        let to: String
        let fetchedAt: Date
        let bars: [MarketDailyBar]
        var fresh: Bool { Date().timeIntervalSince(fetchedAt) < 1800 }
    }
    private let directory: URL
    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("china-daily-v1")) { self.directory = directory }
    private func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
    func load(_ key: String, from: String, to: String) -> Entry? {
        guard let data = try? Data(contentsOf: file(key)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.from <= from else { return nil }
        return entry
    }
    func save(_ key: String, from: String, to: String, bars: [MarketDailyBar]) {
        let entry = Entry(from: from, to: to, fetchedAt: .now, bars: bars)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(key), options: .atomic)
    }
}

struct ChinaMarketDataClient {
    var selection: ChinaMarketSource = .current
    var credentials: LongbridgeCredentials? = .stored
    var publicClient = AKShareMarketDataClient()
    var longbridgeClient: LongbridgeMarketDataClient?
    var dailyCache = ChinaDailyCache.shared
    var intradayCache = LocalIntradayPriceCache.shared
    var providers: [ChinaMarketSource] { selection.providers(hasLongbridge: credentials != nil) }

    private func longbridge() throws -> LongbridgeMarketDataClient {
        if let longbridgeClient { return longbridgeClient }
        guard let credentials else { throw ChinaMarketError.missingCredentials }
        return LongbridgeMarketDataClient(credentials: credentials)
    }

    struct Series<Bar: Sendable>: Sendable {
        let bars: [Bar]
        let attribution: ChinaMarketAttribution
    }

    struct History: Sendable {
        let daily: [MarketDailyBar]
        let intraday: [MarketIntradayBar]
        let attribution: ChinaMarketAttribution
    }

    private func providerCacheKey(_ source: ChinaMarketSource) -> String {
        source == .longbridge ? "longbridge-v2|\(credentials?.cacheIdentity ?? "missing")" : "akshare-v2"
    }

    /// One provider owns the whole chart. Its attribution travels with the
    /// returned values instead of being read from mutable, global quote status.
    func history(_ security: ChinaSecurity, from: String, to: String,
                 forceRefresh: Bool = false, cachedOnly: Bool = false) async throws -> History {
        try await Self.firstAvailable(providers) { source in
            var selected = self
            selected.selection = source
            let client = selected
            async let daily = client.dailySeries(security, from: from, to: to, adjusted: true,
                                                  forceRefresh: forceRefresh, cachedOnly: cachedOnly)
            async let minutes = client.intradaySeries(security, forceRefresh: forceRefresh, cachedOnly: cachedOnly)
            let days = try await daily
            let intraday = try? await minutes
            try Task.checkCancellation()
            return History(daily: days.bars, intraday: intraday?.bars ?? [],
                attribution: .init(source: source,
                    observedAt: intraday?.attribution.observedAt ?? days.attribution.observedAt,
                    cached: days.attribution.cached || (intraday?.attribution.cached ?? false)))
        }
    }

    /// A failed selected provider is explicit. Only automatic mode falls back.
    /// Cancellation never triggers another provider request.
    static func firstAvailable<T>(_ providers: [ChinaMarketSource],
                                  fetch: (ChinaMarketSource) async throws -> T) async throws -> T {
        var lastError: Error = ChinaMarketError.noData
        for provider in providers {
            try Task.checkCancellation()
            do {
                let result = try await fetch(provider)
                try Task.checkCancellation()
                return result
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    func quote(_ security: ChinaSecurity) async throws -> ChinaMarketQuote {
        try await Self.firstAvailable(providers) { source in
            let result: ChinaMarketQuote
            if source == .longbridge { result = try await longbridge().quote(security) }
            else { result = try await publicClient.quote(security) }
            await ChinaMarketStatus.shared.record(security.ticker, source: source, observedAt: result.observedAt)
            return result
        }
    }

    func daily(_ security: ChinaSecurity, from: String, to: String, adjusted: Bool,
               forceRefresh: Bool = false, cachedOnly: Bool = false) async throws -> [MarketDailyBar] {
        try await dailySeries(security, from: from, to: to, adjusted: adjusted,
                              forceRefresh: forceRefresh, cachedOnly: cachedOnly).bars
    }

    private func dailySeries(_ security: ChinaSecurity, from: String, to: String, adjusted: Bool,
                             forceRefresh: Bool, cachedOnly: Bool) async throws -> Series<MarketDailyBar> {
        guard ChinaSecurity.date(from) != nil, ChinaSecurity.date(to) != nil, from <= to else {
            throw ChinaMarketError.invalidData
        }
        var old: Series<MarketDailyBar>?
        do {
            return try await Self.firstAvailable(providers) { source in
                let key = "\(providerCacheKey(source))|\(security.ticker)|\(adjusted ? "forward" : "raw")"
                if let cached = await dailyCache.load(key, from: from, to: to) {
                    let bars = cached.bars.filter { $0.date >= from && $0.date <= to }
                    if !bars.isEmpty {
                        let result = Series(bars: bars, attribution: .init(source: source,
                            observedAt: bars.last.flatMap { ChinaSecurity.date($0.date) }, cached: true))
                        if old == nil { old = result }
                        if cachedOnly || (!forceRefresh && cached.fresh && cached.to >= to) {
                            return result
                        }
                    }
                }
                guard !cachedOnly else { throw ChinaMarketError.noData }
                let bars: [MarketDailyBar]
                if source == .longbridge {
                    bars = try await longbridge().daily(security, from: from, to: to, adjusted: adjusted)
                } else {
                    bars = try await publicClient.daily(security, from: from, to: to, adjusted: adjusted)
                }
                guard !bars.isEmpty else { throw ChinaMarketError.noData }
                // Replace the entire adjusted series: new corporate actions
                // can change every old price, so never splice provider tails.
                await dailyCache.save(key, from: from, to: to, bars: bars)
                return Series(bars: bars, attribution: .init(source: source,
                    observedAt: bars.last.flatMap { ChinaSecurity.date($0.date) }, cached: false))
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            if let old { return old }
            throw error
        }
    }

    func intraday(_ security: ChinaSecurity, forceRefresh: Bool = false,
                  cachedOnly: Bool = false, allowsStaleFallback: Bool = true) async throws -> [MarketIntradayBar] {
        let result = try await intradaySeries(security, forceRefresh: forceRefresh,
            cachedOnly: cachedOnly, allowsStaleFallback: allowsStaleFallback)
        await ChinaMarketStatus.shared.record(security.ticker, source: result.attribution.source,
            observedAt: result.attribution.observedAt, cached: result.attribution.cached)
        return result.bars
    }

    private func intradaySeries(_ security: ChinaSecurity, forceRefresh: Bool = false,
                               cachedOnly: Bool = false,
                               allowsStaleFallback: Bool = true) async throws -> Series<MarketIntradayBar> {
        var old: Series<MarketIntradayBar>?
        do {
            return try await Self.firstAvailable(providers) { source in
                let key = "china-v3|\(providerCacheKey(source))|\(security.ticker)"
                if let cached = await intradayCache.lookup(symbol: key), !cached.bars.isEmpty {
                    let result = Series(bars: cached.bars, attribution: .init(source: source,
                        observedAt: cached.bars.last?.timestamp, cached: true))
                    if old == nil { old = result }
                    if cachedOnly || (!forceRefresh && cached.isFresh) {
                        return result
                    }
                }
                guard !cachedOnly else { throw ChinaMarketError.noData }
                let bars: [MarketIntradayBar]
                if source == .longbridge { bars = try await longbridge().intraday(security) }
                else { bars = try await publicClient.intraday(security) }
                guard !bars.isEmpty else { throw ChinaMarketError.noData }
                let selected = try LocalMarketDataClient.latestMarketSession(from: bars, symbol: security.ticker)
                await intradayCache.save(symbol: key, bars: selected)
                return Series(bars: selected, attribution: .init(source: source,
                    observedAt: selected.last?.timestamp, cached: false))
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            if allowsStaleFallback, let old {
                return old
            }
            throw error
        }
    }

    static func shouldSearch(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && (text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
            || ChinaSecurity(text, currency: "CNY") != nil)
    }
}
