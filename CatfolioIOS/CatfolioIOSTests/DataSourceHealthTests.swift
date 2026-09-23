import Foundation
import XCTest
@testable import CatfolioIOS

final class DataSourceHealthTests: XCTestCase {
    func testKnownAndUnknownHostsDoNotRetainPathsOrQueries() throws {
        let first = try XCTUnwrap(DataSource.of(URL(string: "https://data.sec.gov/api/x?api_key=secret")))
        let second = try XCTUnwrap(DataSource.of(URL(string: "https://efts.sec.gov/search?q=private")))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id, "sec")

        let unknown = try XCTUnwrap(DataSource.of(URL(string: "https://example.invalid/path/to/holding?token=secret")))
        XCTAssertEqual(unknown.id, "host:example.invalid")
        XCTAssertEqual(unknown.title, "example.invalid")
        XCTAssertNil(DataSource.of(URL(fileURLWithPath: "/tmp/private.json")))
    }

    @MainActor func testLatestResultTracksRecoveryEvenWhenEventsArriveOutOfOrder() throws {
        let source = try XCTUnwrap(DataSource.named("sec"))
        let health = DataSourceHealth()
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)

        health.apply(.success, for: source, at: late)
        health.apply(.httpStatus(403), for: source, at: early)
        let status = try XCTUnwrap(health.statuses[source])
        XCTAssertEqual(status.successCount, 1)
        XCTAssertEqual(status.failureCount, 1)
        XCTAssertEqual(status.lastEvent?.outcome, .success)
        XCTAssertEqual(status.lastSuccess, late)
        XCTAssertFalse(status.isFailing)
    }

    @MainActor func testHistoryAndSourcesAreBoundedAndDetailsArePrivate() throws {
        let source = try XCTUnwrap(DataSource.named("sec"))
        let health = DataSourceHealth()
        for index in 0..<15 {
            health.apply(.httpStatus(500), for: source, subject: "SOFI", at: Date(timeIntervalSince1970: Double(index)))
        }
        let status = try XCTUnwrap(health.statuses[source])
        XCTAssertEqual(status.failureCount, 15)
        XCTAssertEqual(status.recentFailures.count, 12)
        XCTAssertEqual(status.recentFailures.first?.date, Date(timeIntervalSince1970: 14))
        XCTAssertNil(status.lastEvent?.subject)

        health.apply(.unusable("https://example.com/?api_key=secret"), for: source)
        XCTAssertEqual(health.statuses[source]?.lastEvent?.outcome, .unusable("返回格式无法识别"))
        health.apply(.transport("Bearer secret"), for: source)
        XCTAssertEqual(health.statuses[source]?.lastEvent?.outcome, .transport("其他连接错误"))

        for index in 0..<105 {
            let unknown = DataSource(id: "host:\(index).invalid", title: "\(index).invalid", kind: .other)
            health.apply(.success, for: unknown, at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(health.statuses.count, 100)
        XCTAssertNotNil(health.statuses[source])
    }

    func testErrorClassificationSkipsCancellationAndNeverUsesErrorDescription() {
        XCTAssertNil(DataSourceHealth.outcome(for: CancellationError()))
        XCTAssertNil(DataSourceHealth.outcome(for: URLError(.cancelled)))
        XCTAssertEqual(DataSourceHealth.outcome(for: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(DataSourceHealth.outcome(for: URLError(.timedOut)), .timedOut)
        XCTAssertEqual(DataSourceHealth.outcome(for: PrivateError()), .transport("其他连接错误"))
    }

    @MainActor func testRecordedDataPreservesResponsesAndReportsFailures() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HealthURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let sourceURL = try XCTUnwrap(URL(string: "https://health-wrapper-test.invalid/ok?api_key=secret"))
        let source = try XCTUnwrap(DataSource.of(sourceURL))

        let (data, response) = try await session.recordedData(from: sourceURL)
        DataSourceHealth.flushPendingReports()
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(DataSourceHealth.shared.statuses[source]?.lastEvent?.outcome, .success)

        var uploadRequest = URLRequest(url: sourceURL)
        uploadRequest.httpMethod = "POST"
        let (_, uploadResponse) = try await session.recordedUpload(for: uploadRequest, from: Data("body".utf8))
        DataSourceHealth.flushPendingReports()
        XCTAssertEqual((uploadResponse as? HTTPURLResponse)?.statusCode, 200)

        var failureURL = try XCTUnwrap(URL(string: "https://health-wrapper-test.invalid/server-error?token=secret"))
        let (_, failureResponse) = try await session.recordedData(from: failureURL)
        DataSourceHealth.flushPendingReports()
        XCTAssertEqual((failureResponse as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(DataSourceHealth.shared.statuses[source]?.lastEvent?.outcome, .httpStatus(503))

        failureURL = try XCTUnwrap(URL(string: "https://health-wrapper-test.invalid/timeout?token=secret"))
        do {
            _ = try await session.recordedData(from: failureURL)
            XCTFail("The URL protocol should fail this request")
        } catch {
            DataSourceHealth.flushPendingReports()
            XCTAssertEqual(DataSourceHealth.shared.statuses[source]?.lastEvent?.outcome, .timedOut)
        }
        XCTAssertEqual(DataSourceHealth.shared.statuses[source]?.successCount, 2)
        XCTAssertEqual(DataSourceHealth.shared.statuses[source]?.failureCount, 2)
        XCTAssertEqual(source.title, "health-wrapper-test.invalid")
    }

    @MainActor func testDeferredReportsRetainCountsAndOnlyAuditedDetails() throws {
        let source = try XCTUnwrap(DataSource.of(URL(string: "https://health-burst.invalid/private?token=secret")))
        for _ in 0..<30 {
            DataSourceHealth.reportUnusable(source, "https://private.example/?api_key=secret")
        }
        DataSourceHealth.flushPendingReports()

        let status = try XCTUnwrap(DataSourceHealth.shared.statuses[source])
        XCTAssertEqual(status.failureCount, 30)
        XCTAssertEqual(status.recentFailures.count, 12)
        XCTAssertEqual(status.lastEvent?.outcome, .unusable("返回格式无法识别"))
        XCTAssertNil(status.lastEvent?.subject)
    }

    @MainActor func testDeferredAndDirectReportsMergeByCompletionTime() throws {
        let url = try XCTUnwrap(URL(string: "https://health-interleave.invalid/quote"))
        let source = try XCTUnwrap(DataSource.of(url))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503,
                                                     httpVersion: "HTTP/1.1", headerFields: nil))

        DataSourceHealth.enqueue(url, response: response)
        let later = Date().addingTimeInterval(60)
        DataSourceHealth.shared.apply(.success, for: source, at: later)
        DataSourceHealth.flushPendingReports()

        let status = try XCTUnwrap(DataSourceHealth.shared.statuses[source])
        XCTAssertEqual(status.successCount, 1)
        XCTAssertEqual(status.failureCount, 1)
        XCTAssertEqual(status.lastEvent?.outcome, .success)
        XCTAssertEqual(status.lastSuccess, later)
    }

    @MainActor func testDeferredCancellationDoesNotCreateStatus() throws {
        let url = try XCTUnwrap(URL(string: "https://health-cancel.invalid/quote"))
        let source = try XCTUnwrap(DataSource.of(url))
        DataSourceHealth.enqueue(url, error: CancellationError())
        DataSourceHealth.enqueue(url, error: URLError(.cancelled))
        DataSourceHealth.flushPendingReports()
        XCTAssertNil(DataSourceHealth.shared.statuses[source])
    }

    @MainActor func testDeferredSourcesStayBoundedAndKnownProvidersSurvive() throws {
        let known = try XCTUnwrap(DataSource.named("sec"))
        DataSourceHealth.shared.apply(.success, for: known)
        for index in 0..<105 {
            let url = try XCTUnwrap(URL(string: "https://health-bounded-\(index).invalid/private?token=secret"))
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                                                         httpVersion: "HTTP/1.1", headerFields: nil))
            DataSourceHealth.enqueue(url, response: response)
        }
        DataSourceHealth.flushPendingReports()

        let newest = try XCTUnwrap(DataSource.of(URL(string: "https://health-bounded-104.invalid/")))
        XCTAssertEqual(DataSourceHealth.shared.statuses.count, 100)
        XCTAssertNotNil(DataSourceHealth.shared.statuses[known])
        XCTAssertNotNil(DataSourceHealth.shared.statuses[newest])
    }

    @MainActor func testDeferredReportsPublishWithoutExplicitFlush() async throws {
        let source = try XCTUnwrap(DataSource.of(URL(string: "https://health-ui-update.invalid/quote")))
        DataSourceHealth.reportUnusable(source, issue: .emptyResult)
        let deadline = Date().addingTimeInterval(1)
        while DataSourceHealth.shared.statuses[source] == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(DataSourceHealth.shared.statuses[source]?.lastEvent?.outcome,
                       .unusable(DataSourceDataIssue.emptyResult.description))
    }

    private struct PrivateError: Error {
        var localizedDescription: String { "https://private.example/?token=secret" }
    }
}

private final class HealthURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "health-wrapper-test.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/timeout" {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let status = url.path == "/server-error" ? 503 : 200
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
