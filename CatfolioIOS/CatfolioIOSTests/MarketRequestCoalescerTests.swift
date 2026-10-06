import Foundation
import XCTest
@testable import CatfolioIOS

final class MarketRequestCoalescerTests: XCTestCase {
    private actor Fetches {
        var count = 0
        var fails = false
        func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
            count += 1
            let failure = fails
            try await Task.sleep(for: .milliseconds(80))
            if failure { throw URLError(.cannotConnectToHost) }
            return (Data((request.url!.absoluteString + (request.value(forHTTPHeaderField: "Authorization") ?? "")).utf8),
                    URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        }
        func fail(_ value: Bool) { fails = value }
    }

    private let url = URL(string: "https://example.com/chart/AAA?interval=1d")!

    func testSimultaneousReadsShareOneFetchButLaterReadFetchesAgain() async throws {
        let fetches = Fetches()
        let coalescer = MarketRequestCoalescer { request, _ in try await fetches.load(request) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url)
        let values = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<12 {
                group.addTask { try await coalescer.data(for: request, session: session).0 }
            }
            var values: [Data] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(Set(values).count, 1)
        let sharedCount = await fetches.count
        XCTAssertEqual(sharedCount, 1)
        _ = try await coalescer.data(for: request, session: session)
        let laterCount = await fetches.count
        XCTAssertEqual(laterCount, 2, "The coalescer must not become another response cache")
    }

    func testDifferentCredentialsAndSessionsDoNotShare() async throws {
        let fetches = Fetches()
        let coalescer = MarketRequestCoalescer { request, _ in try await fetches.load(request) }
        let firstSession = URLSession(configuration: .ephemeral)
        let secondSession = URLSession(configuration: .ephemeral)
        defer { firstSession.invalidateAndCancel(); secondSession.invalidateAndCancel() }
        var first = URLRequest(url: url)
        first.setValue("first", forHTTPHeaderField: "Authorization")
        var second = first
        second.setValue("second", forHTTPHeaderField: "Authorization")
        let firstRequest = first, secondRequest = second
        async let a = coalescer.data(for: firstRequest, session: firstSession)
        async let b = coalescer.data(for: secondRequest, session: firstSession)
        async let c = coalescer.data(for: firstRequest, session: secondSession)
        let values = try await (a, b, c)
        XCTAssertNotEqual(values.0.0, values.1.0)
        let count = await fetches.count
        XCTAssertEqual(count, 3)
    }

    func testFailedFetchIsRemovedAndCanBeRetried() async throws {
        let fetches = Fetches()
        await fetches.fail(true)
        let coalescer = MarketRequestCoalescer { request, _ in try await fetches.load(request) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url)
        do { _ = try await coalescer.data(for: request, session: session); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error is URLError) }
        await fetches.fail(false)
        _ = try await coalescer.data(for: request, session: session)
        let count = await fetches.count
        XCTAssertEqual(count, 2)
    }

    func testCancellingOneWaiterDoesNotCancelTheOther() async throws {
        let fetches = Fetches()
        let coalescer = MarketRequestCoalescer { request, _ in try await fetches.load(request) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: url)
        let cancelled = Task { try await coalescer.data(for: request, session: session) }
        // Wait until the underlying operation has started before joining it.
        while await fetches.count == 0 { await Task.yield() }
        let surviving = Task { try await coalescer.data(for: request, session: session) }
        cancelled.cancel()
        _ = try await surviving.value
        do { _ = try await cancelled.value; XCTFail("Cancelled caller must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await fetches.count
        XCTAssertEqual(count, 1)
    }

    func testWritesAreNeverCoalesced() async throws {
        let fetches = Fetches()
        let coalescer = MarketRequestCoalescer { request, _ in try await fetches.load(request) }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var draft = URLRequest(url: url)
        draft.httpMethod = "POST"
        let request = draft
        async let a = coalescer.data(for: request, session: session)
        async let b = coalescer.data(for: request, session: session)
        _ = try await (a, b)
        let count = await fetches.count
        XCTAssertEqual(count, 2)
    }
}
