import Foundation
import XCTest
@testable import CatfolioIOS

final class LocalPriceCachePersistenceTests: XCTestCase {
    func testHistoricalCachePersistsLatestMergedHistory() async throws {
        let url = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = LocalHistoricalPriceCache(cacheURL: url, writeDelay: .milliseconds(20))

        await cache.save(
            symbol: "AAA",
            values: ["2025-01-01": 100, "2025-01-02": 101],
            requestedFrom: "2025-01-01",
            requestedTo: "2025-01-02"
        )
        let merged = await cache.extend(
            symbol: "AAA",
            tail: ["2025-01-02": 101, "2025-01-03": 102],
            requestedTo: "2025-01-03"
        )
        XCTAssertEqual(merged?["2025-01-03"], 102)
        await cache.save(
            symbol: "BBB",
            values: ["2025-01-01": 50],
            requestedFrom: "2025-01-01",
            requestedTo: "2025-01-01"
        )

        // One file per symbol, written together after the short delay.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            if files.filter({ $0.hasSuffix(".json") }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(50))

        let restored = LocalHistoricalPriceCache(cacheURL: url)
        let hit = await restored.lookup(symbol: "AAA", from: "2025-01-01", to: "2025-01-03")
        XCTAssertEqual(hit?.values.count, 3)
        XCTAssertEqual(hit?.lastDate, "2025-01-03")
        XCTAssertEqual(hit?.coversStart, true)
    }

    func testIntradayCachePersistsLatestBarsForEverySymbol() async throws {
        let url = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = LocalIntradayPriceCache(cacheURL: url, writeDelay: .milliseconds(20))
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = [MarketIntradayBar(timestamp: base, close: 100),
                     MarketIntradayBar(timestamp: base.addingTimeInterval(60), close: 101)]
        let newer = older + [MarketIntradayBar(timestamp: base.addingTimeInterval(120), close: 102)]

        await cache.save(symbol: "aaa", bars: older)
        await cache.save(symbol: "AAA", bars: newer)
        await cache.save(symbol: "BBB", bars: older)

        try await waitForCache(at: url) { json in
            let aaa = json["AAA"] as? [String: Any]
            let bars = aaa?["bars"] as? [[String: Any]]
            return bars?.count == 3 && json["BBB"] != nil
        }

        let restored = LocalIntradayPriceCache(cacheURL: url)
        let hit = await restored.lookup(symbol: "aaa")
        XCTAssertEqual(hit?.bars.map(\.close), [100, 101, 102])
    }

    func testSaveDuringInFlightWritePersistsNewerSnapshotLast() async throws {
        let url = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = FirstWriteGate()
        let cache = LocalIntradayPriceCache(
            cacheURL: url,
            writeDelay: .milliseconds(10),
            writeData: { data, url in try await gate.write(data, to: url) }
        )
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = [MarketIntradayBar(timestamp: base, close: 100),
                     MarketIntradayBar(timestamp: base.addingTimeInterval(60), close: 101)]
        let newer = older + [MarketIntradayBar(timestamp: base.addingTimeInterval(120), close: 102)]

        await cache.save(symbol: "AAA", bars: older)
        await gate.waitForFirstWrite()
        await cache.save(symbol: "AAA", bars: newer)
        await cache.save(symbol: "BBB", bars: older)
        await gate.releaseFirstWrite()

        try await waitForCache(at: url) { json in
            let aaa = json["AAA"] as? [String: Any]
            let bars = aaa?["bars"] as? [[String: Any]]
            return bars?.count == 3 && json["BBB"] != nil
        }
        let restored = LocalIntradayPriceCache(cacheURL: url)
        let hit = await restored.lookup(symbol: "AAA")
        XCTAssertEqual(hit?.bars.map(\.close), [100, 101, 102])
        let writeCount = await gate.writeCount
        XCTAssertEqual(writeCount, 2)
    }

    func testVolumeCachePersistsLatestBarsForEverySymbol() async throws {
        let url = temporaryCacheURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cache = LocalVolumeBarCache(cacheURL: url, writeDelay: .milliseconds(20))
        let older = MarketDailyBar(date: "2025-01-01", close: 100, high: 101, low: 99, volume: 1000)
        let newer = MarketDailyBar(date: "2025-01-02", close: 102, high: 103, low: 100, volume: 2000)

        await cache.save(symbol: "aaa", bars: [older])
        await cache.save(symbol: "AAA", bars: [older, newer])
        await cache.save(symbol: "BBB", bars: [older])

        try await waitForCache(at: url) { json in
            let aaa = json["AAA"] as? [String: Any]
            let bars = aaa?["bars"] as? [[String: Any]]
            return bars?.count == 2 && json["BBB"] != nil
        }

        let restored = LocalVolumeBarCache(cacheURL: url)
        let hit = await restored.lookup(symbol: "aaa")
        XCTAssertEqual(hit?.bars.map(\.date), ["2025-01-01", "2025-01-02"])
    }

    private func temporaryCacheURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catfolio-cache-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cache.json")
    }

    private func waitForCache(
        at url: URL,
        matching matches: ([String: Any]) -> Bool
    ) async throws {
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               matches(json) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The latest market cache snapshot was not persisted")
    }
}

private actor FirstWriteGate {
    private(set) var writeCount = 0
    private var firstWriteStarted = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedWrite: CheckedContinuation<Void, Never>?

    func waitForFirstWrite() async {
        if firstWriteStarted { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseFirstWrite() {
        blockedWrite?.resume()
        blockedWrite = nil
    }

    func write(_ data: Data, to url: URL) async throws {
        writeCount += 1
        if writeCount == 1 {
            firstWriteStarted = true
            for waiter in startedWaiters { waiter.resume() }
            startedWaiters.removeAll()
            await withCheckedContinuation { continuation in
                blockedWrite = continuation
            }
        }
        try data.write(to: url, options: .atomic)
    }
}
