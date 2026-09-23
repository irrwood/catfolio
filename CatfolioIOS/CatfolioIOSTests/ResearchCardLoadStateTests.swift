import XCTest
@testable import CatfolioIOS

@MainActor
private final class ControlledResearchRequest<Value> {
    let started = XCTestExpectation(description: "Research request started")
    private var continuation: CheckedContinuation<Value, Error>?

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func finish(_ result: Result<Value, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

final class ResearchCardLoadStateTests: XCTestCase {
    @MainActor
    func testCancelledRequestCannotClearReplacementSpinnerOrPublishResults() async {
        for oldResult: Result<String, Error> in [.success("old"), .failure(URLError(.cancelled))] {
            let state = ResearchCardLoadState()
            let first = ControlledResearchRequest<String>()
            let second = ControlledResearchRequest<String>()
            var publications: [String] = []
            var fallbackCalls = 0
            let old = Task {
                await state.load(operation: first.value, fallback: {
                    fallbackCalls += 1
                    return "old cache"
                }, onSuccess: { publications.append($0) }, onFailure: { _, _ in
                    publications.append("old error")
                })
            }
            await fulfillment(of: [first.started], timeout: 2)
            old.cancel()
            let replacement = Task {
                await state.load(operation: second.value, onSuccess: { publications.append($0) },
                                 onFailure: { _, _ in publications.append("new error") })
            }
            await fulfillment(of: [second.started], timeout: 2)

            // A provider can return late even after SwiftUI cancels the task.
            first.finish(oldResult)
            await old.value
            XCTAssertTrue(state.isLoading, "The replacement request still owns the spinner")
            XCTAssertTrue(publications.isEmpty)
            XCTAssertEqual(fallbackCalls, 0)

            second.finish(.success("new"))
            await replacement.value
            XCTAssertFalse(state.isLoading)
            XCTAssertEqual(publications, ["new"])
        }
    }

    @MainActor
    func testSupersededSuccessfulRequestCannotOverwriteCompletedReplacement() async {
        let state = ResearchCardLoadState()
        let first = ControlledResearchRequest<String>()
        let second = ControlledResearchRequest<String>()
        var publications: [String] = []
        let old = Task {
            await state.load(operation: first.value, onSuccess: { publications.append($0) },
                             onFailure: { _, _ in publications.append("old error") })
        }
        await fulfillment(of: [first.started], timeout: 2)
        let replacement = Task {
            await state.load(operation: second.value, onSuccess: { publications.append($0) },
                             onFailure: { _, _ in publications.append("new error") })
        }
        await fulfillment(of: [second.started], timeout: 2)
        second.finish(.success("new"))
        await replacement.value
        first.finish(.success("old"))
        await old.value

        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(publications, ["new"], "A generation check is also required without cancellation")
    }

    @MainActor
    func testSupersededCacheRecoveryCannotPublishErrorOrStopNewRequest() async {
        let state = ResearchCardLoadState()
        let failedRequest = ControlledResearchRequest<String>()
        let cacheRead = ControlledResearchRequest<String>()
        let second = ControlledResearchRequest<String>()
        var publications: [String] = []
        let old = Task {
            await state.load(operation: failedRequest.value, fallback: { try? await cacheRead.value() },
                             onSuccess: { publications.append($0) }, onFailure: { _, cached in
                publications.append(cached ?? "old error")
            })
        }
        await fulfillment(of: [failedRequest.started], timeout: 2)
        failedRequest.finish(.failure(URLError(.notConnectedToInternet)))
        await fulfillment(of: [cacheRead.started], timeout: 2)
        let replacement = Task {
            await state.load(operation: second.value, onSuccess: { publications.append($0) },
                             onFailure: { _, _ in publications.append("new error") })
        }
        await fulfillment(of: [second.started], timeout: 2)

        cacheRead.finish(.success("old cached data"))
        await old.value
        XCTAssertTrue(state.isLoading)
        XCTAssertTrue(publications.isEmpty, "Cache recovery needs a second generation check after its await")

        second.finish(.success("new"))
        await replacement.value
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(publications, ["new"])
    }

    @MainActor
    func testCurrentFailurePublishesRecoveredSnapshotAndCompletesLoading() async {
        let state = ResearchCardLoadState()
        let request = ControlledResearchRequest<String>()
        var recovered: String?
        var failure: URLError.Code?
        let task = Task {
            await state.load(operation: request.value, fallback: { "saved chart" },
                             onSuccess: { _ in XCTFail("The request should fail") }, onFailure: { error, cached in
                failure = (error as? URLError)?.code
                recovered = cached
            })
        }
        await fulfillment(of: [request.started], timeout: 2)
        request.finish(.failure(URLError(.notConnectedToInternet)))
        await task.value

        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(failure, .notConnectedToInternet)
        XCTAssertEqual(recovered, "saved chart")
    }

    @MainActor
    func testCancellationWithoutReplacementEndsLoadingWithoutPublishingFailure() async {
        let state = ResearchCardLoadState()
        let request = ControlledResearchRequest<String>()
        var published = false
        let task = Task {
            await state.load(operation: request.value, onSuccess: { _ in published = true },
                             onFailure: { _, _ in published = true })
        }
        await fulfillment(of: [request.started], timeout: 2)
        task.cancel()
        request.finish(.failure(CancellationError()))
        await task.value

        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(published)
    }
}
