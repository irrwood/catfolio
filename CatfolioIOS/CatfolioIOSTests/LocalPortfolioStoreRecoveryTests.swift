import XCTest
@testable import CatfolioIOS

/// The portfolio file is the only copy of an imported ledger: an unreadable
/// one is set aside byte for byte, never overwritten, and a read failure is
/// not mistaken for corruption.
final class LocalPortfolioStoreRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortfolioRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func backups(_ reason: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("portfolio-\(reason)-") }
    }

    func testCorruptFileIsSetAsideAndAnEmptyPortfolioOpens() async throws {
        let file = root.appendingPathComponent("portfolio.json")
        let store = LocalPortfolioStore(fileURL: file)
        let missing = try await store.load()
        XCTAssertEqual(missing, .empty)

        let corrupt = Data("{truncated".utf8)
        try corrupt.write(to: file)
        let recovered = try await store.load()
        XCTAssertEqual(recovered, .empty)
        let saved = try backups("corrupt")
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(try Data(contentsOf: saved[0]), corrupt, "The unreadable bytes are kept as they were")
        let notice = await store.recoveryNotice
        XCTAssertNotNil(notice)
        let again = try await store.load()
        XCTAssertEqual(again, .empty)
        XCTAssertEqual(try backups("corrupt").count, 1, "A second open does not archive again")
    }

    func testResetKeepsTheOldFileAndOnlyWhenThereIsOne() async throws {
        let file = root.appendingPathComponent("portfolio.json")
        let store = LocalPortfolioStore(fileURL: file)
        var document = LocalPortfolioDocument.empty
        document.source = "original"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let valid = try encoder.encode(document)
        try valid.write(to: file)
        let loaded = try await store.load()
        XCTAssertEqual(loaded.source, "original")

        let backup = try await store.resetPortfolio()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup)), valid)
        let afterReset = try await store.load()
        XCTAssertEqual(afterReset, .empty)
        let nothingToKeep = try await store.resetPortfolio()
        XCTAssertNil(nothingToKeep)
    }

    func testAReadFailureIsNotTreatedAsCorruption() async throws {
        let file = root.appendingPathComponent("portfolio.json")
        // A directory where the file should be: reading fails, decoding never runs.
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let store = LocalPortfolioStore(fileURL: file)
        do {
            _ = try await store.load()
            XCTFail("Expected the read to fail")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Nothing is moved away")
        XCTAssertTrue(try backups("corrupt").isEmpty)
    }
}
