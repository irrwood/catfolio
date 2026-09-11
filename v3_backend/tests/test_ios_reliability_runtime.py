"""Run production Foundation/Network code on macOS without an iOS test host.

The store's presentation/migration dependencies are replaced with a minimal
Codable fixture; file recovery, reset, currency rules and OAuth listener code
are extracted verbatim from the application, not reimplemented here.
"""
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2] / "CatfolioIOS" / "CatfolioIOS"


@pytest.mark.skipif(sys.platform != "darwin" or not shutil.which("swiftc"), reason="Requires macOS Swift/Network")
def test_file_recovery_currency_units_and_oauth_lifecycle(tmp_path):
    store = (ROOT / "LocalPortfolioStore.swift").read_text()
    oauth = (ROOT / "MoomooOAuthClient.swift").read_text()
    rules = store[store.index("enum InstrumentCurrencyRules {"):store.index("struct LocalPositionRecord:")]
    recovery = store[store.index("actor LocalPortfolioStore {"):store.index("    func replace(", store.index("actor LocalPortfolioStore {"))]
    listener = oauth[oauth.index("private final class MoomooLoopbackListener:"):oauth.index("private struct MoomooRegistration:")]
    fixture = '''
import Foundation
import Network
struct LocalPortfolioDocument: Codable, Equatable {
    var source: String
    static let empty = Self(source: "empty")
}
enum MoomooOpenAPIError: Error {
    case authorizationFailed(String), authorizationCancelled
}
'''
    recovery += '''
    private func migrateKnownInstrumentCurrencies(in document: LocalPortfolioDocument) throws -> LocalPortfolioDocument { document }
    private func save(_ document: LocalPortfolioDocument) throws { fatalError("Unexpected migration") }
}
'''
    main = r'''
extension MoomooLoopbackListener {
    var testPort: NWEndpoint.Port { listener.port! }
}
@main struct ReliabilityChecks {
    static func send(_ text: String, to port: NWEndpoint.Port) async throws {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    })
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            connection.start(queue: .global())
        }
        // Keep the connection alive while the server reads it.
        try await Task.sleep(nanoseconds: 100_000_000)
        connection.cancel()
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = root.appendingPathComponent("portfolio.json")
        let store = LocalPortfolioStore(fileURL: file)
        let missing = try await store.load()
        precondition(missing == .empty)

        let corrupt = Data("{truncated".utf8)
        try corrupt.write(to: file)
        let recovered = try await store.load()
        precondition(recovered == .empty)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("portfolio-corrupt-") }
        precondition(backups.count == 1)
        let savedBytes = try Data(contentsOf: backups[0])
        precondition(savedBytes == corrupt)
        let secondLoad = try await store.load()
        precondition(secondLoad == .empty)

        let valid = Data(#"{"source":"original"}"#.utf8)
        try valid.write(to: file)
        let decoded = try await store.load()
        precondition(decoded.source == "original")
        let backup = try await store.resetPortfolio()!
        let resetBytes = try Data(contentsOf: backup)
        precondition(resetBytes == valid)
        let resetLoad = try await store.load()
        precondition(resetLoad == .empty)
        let noBackup = try await store.resetPortfolio()
        precondition(noBackup == nil)

        // I/O failure must not be classified as corrupt JSON or moved away.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { _ = try await store.load(); fatalError("Expected read failure") } catch {}
        precondition(FileManager.default.fileExists(atPath: file.path))

        precondition(InstrumentCurrencyRules.marketPriceScale(symbol: "AAPL", targetCurrency: "GBP") == 1)
        precondition(InstrumentCurrencyRules.marketPriceScale(symbol: "UNKNOWN.L", targetCurrency: "GBP") == 1)
        precondition(InstrumentCurrencyRules.marketPriceScale(symbol: "EQQU.L", targetCurrency: "GBP") == 1)
        precondition(InstrumentCurrencyRules.marketPriceScale(symbol: "EQQQ.L", targetCurrency: "GBP") == 0.01)
        precondition(InstrumentCurrencyRules.marketPriceScale(symbol: "EQQQ.L", targetCurrency: "GBX") == 1)
        precondition(InstrumentCurrencyRules.marketPriceScale(symbol: "VUAG.L", targetCurrency: "GBX") == 100)
        precondition(InstrumentCurrencyRules.providerPriceScale(symbol: "VUAG.L", sourceCurrency: "GBp") == 0.01)
        precondition(InstrumentCurrencyRules.providerPriceScale(symbol: "VUAG.L", sourceCurrency: "GBP") == 1)
        precondition(InstrumentCurrencyRules.providerPriceScale(symbol: "EQQQ.L", sourceCurrency: "GBP") == 100)
        precondition(InstrumentCurrencyRules.providerPriceScale(symbol: "EQQQ.L", sourceCurrency: nil) == nil)
        precondition(InstrumentCurrencyRules.providerPriceScale(symbol: "EQQU.L", sourceCurrency: "GBP") == nil)

        // Ephemeral ports avoid interfering with the user's real OAuth flow.
        let timed = try MoomooLoopbackListener(port: 0)
        try await timed.start()
        do { _ = try await timed.waitForCallback(timeout: 0.02); fatalError("Expected timeout") } catch {}

        let cancelled = try MoomooLoopbackListener(port: 0)
        try await cancelled.start()
        let task = Task { try await cancelled.waitForCallback(timeout: 30) }
        task.cancel()
        do { _ = try await task.value; fatalError("Expected cancellation") } catch is CancellationError {}

        // Completion before continuation installation must also be delivered.
        let early = try MoomooLoopbackListener(port: 0)
        early.cancel(with: MoomooOpenAPIError.authorizationCancelled)
        do { _ = try await early.waitForCallback(timeout: 1); fatalError("Expected early cancellation") } catch {}

        let oversized = try MoomooLoopbackListener(port: 0)
        try await oversized.start()
        async let oversizedSend: Void = send("GET /callback?" + String(repeating: "x", count: 20_000), to: oversized.testPort)
        do {
            _ = try await oversized.waitForCallback(timeout: 2)
            fatalError("Expected oversized callback failure")
        } catch MoomooOpenAPIError.authorizationFailed(let message) {
            precondition(message.contains("请求过大"))
        }
        try await oversizedSend

        let success = try MoomooLoopbackListener(port: 0)
        try await success.start()
        async let successSend: Void = send("GET /callback?code=test&state=test HTTP/1.1\r\nHost: localhost\r\n\r\n", to: success.testPort)
        let callback = try await success.waitForCallback(timeout: 2)
        precondition(callback.query == "code=test&state=test")
        try await successSend
        print("Recovery, reset, price units, timeout, cancellation and HTTP callbacks passed")
    }
}
'''
    source = tmp_path / "ReliabilityChecks.swift"
    source.write_text(fixture + rules + recovery + listener + main)
    executable = tmp_path / "checks"
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(executable)], check=True, capture_output=True, text=True, timeout=90)
    subprocess.run([str(executable), str(tmp_path)], check=True, capture_output=True, text=True, timeout=15)
