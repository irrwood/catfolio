import XCTest
@testable import CatfolioIOS

final class Trading212InteractionTests: XCTestCase {
    private func request(_ environment: Trading212Environment, key: String = "original") throws -> Trading212RequestConfiguration {
        .init(accounts: [.init(slot: 1, credentials: try .init(apiKey: key, apiSecret: "test-secret"))],
              environment: environment)
    }

    private var snapshot: Trading212Snapshot {
        .init(accountCount: 1, positions: [], transactions: [],
              hasCompleteTransactionHistory: false, transactionHistoryStatus: nil)
    }

    @MainActor
    func testResponseRetainsRequestedEnvironmentAndCredentialsWhenDraftChanges() async throws {
        let operation = Trading212Operation()
        let started = expectation(description: "request started")
        var reply: CheckedContinuation<Trading212Snapshot, Error>?
        var draft = try request(.live)
        let original = draft
        var fetchedRequest: Trading212RequestConfiguration?
        var appliedRequest: Trading212RequestConfiguration?
        let task = try XCTUnwrap(operation.start(request: draft, fetch: { request in
            fetchedRequest = request
            return try await withCheckedThrowingContinuation { reply = $0; started.fulfill() }
        }, apply: { request, _ in
            appliedRequest = request
        }, onError: { XCTFail("Unexpected error: \($0)") }))
        await fulfillment(of: [started], timeout: 2)

        draft = try request(.demo, key: "replacement")
        reply?.resume(returning: snapshot)
        await task.value

        XCTAssertEqual(fetchedRequest, original)
        XCTAssertEqual(appliedRequest, original)
        XCTAssertNotEqual(appliedRequest, draft)
        XCTAssertFalse(operation.isRunning)
    }

    @MainActor
    func testClosingSheetDiscardsLateResponseBeforeImportOrHistoryRetry() async throws {
        let operation = Trading212Operation()
        let started = expectation(description: "request started")
        var reply: CheckedContinuation<Trading212Snapshot, Error>?
        var imports = 0
        var historyRetries = 0
        let task = try XCTUnwrap(operation.start(request: request(.live), fetch: { _ in
            // Model a network client that returns successfully after cancellation.
            try await withCheckedThrowingContinuation { reply = $0; started.fulfill() }
        }, apply: { _, result in
            imports += 1
            if !result.hasCompleteTransactionHistory { historyRetries += 1 }
        }, onError: { XCTFail("Cancellation is not a visible error: \($0)") }))
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        reply?.resume(returning: snapshot)
        await task.value

        XCTAssertEqual(imports, 0)
        XCTAssertEqual(historyRetries, 0)
        XCTAssertFalse(operation.isRunning)
    }

    @MainActor
    func testLateCancelledRequestCannotClearNewRequestOrPublishItsError() async throws {
        let operation = Trading212Operation()
        let firstStarted = expectation(description: "first request started")
        let secondStarted = expectation(description: "second request started")
        var firstReply: CheckedContinuation<Trading212Snapshot, Error>?
        var secondReply: CheckedContinuation<Trading212Snapshot, Error>?
        var applied: [Trading212Environment] = []
        var errors = 0
        let first = try XCTUnwrap(operation.start(request: request(.live), fetch: { _ in
            try await withCheckedThrowingContinuation { firstReply = $0; firstStarted.fulfill() }
        }, apply: { request, _ in applied.append(request.environment) }, onError: { _ in errors += 1 }))
        await fulfillment(of: [firstStarted], timeout: 2)
        operation.cancel()
        let second = try XCTUnwrap(operation.start(request: request(.demo), fetch: { _ in
            try await withCheckedThrowingContinuation { secondReply = $0; secondStarted.fulfill() }
        }, apply: { request, _ in applied.append(request.environment) }, onError: { _ in errors += 1 }))
        await fulfillment(of: [secondStarted], timeout: 2)

        firstReply?.resume(throwing: URLError(.timedOut))
        await first.value
        XCTAssertTrue(operation.isRunning)
        XCTAssertEqual(errors, 0)
        XCTAssertTrue(applied.isEmpty)

        secondReply?.resume(returning: snapshot)
        await second.value
        XCTAssertEqual(applied, [.demo])
        XCTAssertFalse(operation.isRunning)
    }

    @MainActor
    func testDuplicateStartAndCancellationBeforeStartDoNotFetchOrImport() async throws {
        let operation = Trading212Operation()
        var fetches = 0
        var imports = 0
        let result = snapshot
        let configuration = try request(.live)
        let fetch: @MainActor (Trading212RequestConfiguration) async throws -> Trading212Snapshot = { _ in
            fetches += 1
            return result
        }
        let apply: @MainActor (Trading212RequestConfiguration, Trading212Snapshot) async throws -> Void = { _, _ in
            imports += 1
        }
        let task = try XCTUnwrap(operation.start(request: configuration, fetch: fetch, apply: apply,
                                                onError: { XCTFail("Unexpected error: \($0)") }))
        XCTAssertNil(operation.start(request: configuration, fetch: fetch, apply: apply,
                                     onError: { XCTFail("Unexpected error: \($0)") }))
        operation.cancel()
        await task.value

        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(imports, 0)
        XCTAssertFalse(operation.isRunning)
    }
}
