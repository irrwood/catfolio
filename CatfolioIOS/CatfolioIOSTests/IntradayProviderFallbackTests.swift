import Foundation
import XCTest
@testable import CatfolioIOS

final class IntradayProviderFallbackTests: XCTestCase {
    private func bars(_ hour: String = "08:00:00", price: Double = 105) -> [MarketIntradayBar] {
        [.init(timestamp: ISO8601DateFormatter().date(from: "2026-10-12T\(hour)-04:00")!, close: price)]
    }

    private func cache() -> LocalIntradayPriceCache {
        LocalIntradayPriceCache(cacheURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("intraday-fallback-\(UUID()).json"), writeData: { _, _ in })
    }

    func testExtendedHoursPrefersYahooWithoutCallingMassive() async throws {
        let expected = bars()
        let result = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL",
            includingExtendedHours: true, cache: cache(), yahoo: { expected }, massive: {
                XCTFail("A healthy Yahoo response should not spend a Massive request")
                return []
            })
        XCTAssertEqual(result.map(\.close), [105])
        XCTAssertEqual(result.first?.marketSession, .preMarket)
    }

    func testYahooRequestAndDecodingFailuresFallBackToMassive() async throws {
        let errors: [Error] = [URLError(.timedOut), URLError(.cannotConnectToHost),
            LocalServiceError.remote("Yahoo HTTP 429"), LocalServiceError.remote("Yahoo HTTP 503"),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid Yahoo JSON"))]
        for error in errors {
            for (hour, session) in [("08:00:00", USMarketSession.preMarket), ("17:00:00", .postMarket)] {
                let fallback = bars(hour)
                var calls: [String] = []
                let result = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL",
                    includingExtendedHours: true, cache: cache(), yahoo: {
                        calls.append("Yahoo")
                        throw error
                    }, massive: {
                        calls.append("Massive")
                        return fallback
                    })
                XCTAssertEqual(calls, ["Yahoo", "Massive"])
                XCTAssertEqual(result.map(\.close), [105])
                XCTAssertEqual(result.first?.marketSession, session)
                XCTAssertEqual(result.first?.timestamp, fallback.first?.timestamp)
            }
        }
    }

    func testEmptyInvalidAndOutOfSessionYahooBarsReachMassive() async throws {
        let fallback = bars()
        for unusable in [[], bars(price: .nan), bars(price: 0), bars("21:00:00")] {
            var usedMassive = false
            let result = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL",
                includingExtendedHours: true, cache: cache(), yahoo: { unusable }, massive: {
                    usedMassive = true
                    return fallback
                })
            XCTAssertTrue(usedMassive)
            XCTAssertEqual(result.map(\.close), [105])
        }
    }

    func testMassiveFallbackCacheIsReusedWithoutYahooSessionMetadata() async throws {
        let cache = cache()
        let fallback = bars("17:00:00")
        _ = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL",
            includingExtendedHours: true, cache: cache,
            yahoo: { throw URLError(.timedOut) }, massive: { fallback })
        let hit = await cache.lookup(symbol: "AAPL")
        XCTAssertEqual(hit?.includesExtendedHours, true)
        XCTAssertNil(hit?.bars.first?.sessionWindow)

        let reused = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL",
            includingExtendedHours: true, cache: cache, yahoo: {
                XCTFail("Fresh Massive coverage must not retry the failed Yahoo request")
                return []
            }, massive: {
                XCTFail("Fresh fallback bars must be reused")
                return []
            })
        XCTAssertEqual(reused.first?.timestamp, fallback.first?.timestamp)
        XCTAssertEqual(reused.map(\.close), [105])

        let recovered = bars("17:05:00", price: 106)
        let refreshed = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL", forceRefresh: true,
            includingExtendedHours: true, cache: cache, yahoo: { recovered }, massive: {
                XCTFail("A forced refresh must return to Yahoo when it recovers")
                return []
            })
        XCTAssertEqual(refreshed.map(\.close), [106])
    }

    func testRegularOnlyCacheDoesNotHideExtendedHoursRequest() async throws {
        let cache = cache()
        await cache.save(symbol: "AAPL", bars: bars("10:00:00", price: 100))
        let extended = bars("17:00:00")
        var calls: [String] = []
        let result = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL",
            includingExtendedHours: true, cache: cache, yahoo: {
                calls.append("Yahoo")
                throw URLError(.timedOut)
            }, massive: {
                calls.append("Massive")
                return extended
            })
        XCTAssertEqual(calls, ["Yahoo", "Massive"])
        XCTAssertEqual(result.first?.marketSession, .postMarket)
    }

    func testBothProvidersFailBeforeUsingExistingCache() async throws {
        let cache = cache()
        let saved = bars()
        await cache.save(symbol: "AAPL", bars: saved, includesExtendedHours: true)
        var calls: [String] = []
        let result = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL", forceRefresh: true,
            includingExtendedHours: true, cache: cache, yahoo: {
                calls.append("Yahoo")
                throw URLError(.timedOut)
            }, massive: {
                calls.append("Massive")
                throw LocalServiceError.remote("Massive unavailable")
            })
        XCTAssertEqual(calls, ["Yahoo", "Massive"])
        XCTAssertEqual(result.first?.timestamp, saved.first?.timestamp)
        XCTAssertEqual(result.map(\.close), [105])

        do {
            _ = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL", forceRefresh: true,
                allowsStaleFallback: false, includingExtendedHours: true, cache: cache,
                yahoo: { throw URLError(.timedOut) }, massive: { throw URLError(.cannotConnectToHost) })
            XCTFail("Callers requiring a live fetch must receive the failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cannotConnectToHost)
        }
    }

    func testCachedOnlyDoesNotContactEitherProvider() async throws {
        let cache = cache()
        let saved = bars()
        await cache.save(symbol: "AAPL", bars: saved, includesExtendedHours: true)
        let result = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL", cachedOnly: true,
            includingExtendedHours: true, cache: cache,
            yahoo: { XCTFail("Cache-only must stay offline"); return [] },
            massive: { XCTFail("Cache-only must stay offline"); return [] })
        XCTAssertEqual(result.map(\.close), [105])
    }

    func testRegularRequestsKeepMassivePriorityAndExcludeExtendedPrices() async throws {
        let all = bars() + bars("10:00:00", price: 100) + bars("17:00:00", price: 110)
        let result = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL", cache: cache(),
            yahoo: { XCTFail("Regular U.S. requests still prefer Massive"); return [] }, massive: { all })
        XCTAssertEqual(result.map(\.close), [100])
    }

    func testInternationalRequestsDoNotUseMassiveStockFallback() async throws {
        let expected = bars()
        let result = try await LocalMarketDataClient.loadIntradayBars(symbol: "VUAG.L",
            includingExtendedHours: true, cache: cache(), yahoo: { expected },
            massive: { XCTFail("Massive stock fallback is U.S. only"); return [] })
        XCTAssertEqual(result.map(\.close), [105])
    }

    func testCancellationDoesNotTriggerFallback() async throws {
        for error: Error in [CancellationError(), URLError(.cancelled)] {
            do {
                _ = try await LocalMarketDataClient.loadIntradayBars(symbol: "AAPL",
                    includingExtendedHours: true, cache: cache(), yahoo: { throw error }, massive: {
                        XCTFail("Leaving a page must not initiate a fallback request")
                        return []
                    })
                XCTFail("Cancellation must reach the caller")
            } catch {
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
            }
        }
    }
}
