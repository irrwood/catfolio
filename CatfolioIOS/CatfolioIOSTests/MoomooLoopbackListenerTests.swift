import Network
import XCTest
@testable import CatfolioIOS

/// The Moomoo sign-in waits on a local port for the browser's callback. It
/// must give the port back on a timeout, a cancel or a bad request, and pass
/// the code through when the callback arrives. Port 0 lets the system pick
/// one, so the real sign-in port is never touched.
final class MoomooLoopbackListenerTests: XCTestCase {
    private func send(_ text: String, to port: UInt16) async throws {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            connection.start(queue: .global())
        }
        // Keep the connection open while the listener reads it.
        try await Task.sleep(for: .milliseconds(100))
    }

    func testAnAbandonedSignInTimesOut() async throws {
        let listener = try MoomooLoopbackListener(port: 0)
        try await listener.start()
        do {
            _ = try await listener.waitForCallback(timeout: 0.02)
            XCTFail("Expected a timeout")
        } catch {}
    }

    func testCancellingTheWaitEndsIt() async throws {
        let listener = try MoomooLoopbackListener(port: 0)
        try await listener.start()
        let wait = Task { try await listener.waitForCallback(timeout: 30) }
        wait.cancel()
        do {
            _ = try await wait.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testACancelBeforeTheWaitBeginsIsStillDelivered() async throws {
        let listener = try MoomooLoopbackListener(port: 0)
        listener.cancel(with: MoomooOpenAPIError.authorizationCancelled)
        do {
            _ = try await listener.waitForCallback(timeout: 1)
            XCTFail("Expected the earlier cancel")
        } catch {}
    }

    func testAnOversizedRequestFailsTheSignIn() async throws {
        let listener = try MoomooLoopbackListener(port: 0)
        try await listener.start()
        let port = try XCTUnwrap(listener.port)
        async let sent: Void = send("GET /callback?" + String(repeating: "x", count: 20_000), to: port)
        do {
            _ = try await listener.waitForCallback(timeout: 2)
            XCTFail("Expected an oversized request to fail")
        } catch let error as MoomooOpenAPIError {
            guard case .authorizationFailed = error else { return XCTFail("Unexpected \(error)") }
        }
        try await sent
    }

    func testTheCallbackCarriesTheCodeThrough() async throws {
        let listener = try MoomooLoopbackListener(port: 0)
        try await listener.start()
        let port = try XCTUnwrap(listener.port)
        async let sent: Void = send("GET /callback?code=test&state=test HTTP/1.1\r\nHost: localhost\r\n\r\n", to: port)
        let callback = try await listener.waitForCallback(timeout: 2)
        XCTAssertEqual(callback.query, "code=test&state=test")
        try await sent
    }
}
