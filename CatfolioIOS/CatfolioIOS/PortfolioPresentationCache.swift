import Foundation
import CryptoKit

/// Derived home-screen data only. The ledger remains the source of truth.
struct PortfolioPresentationSnapshot: Codable {
    let overview: PortfolioOverview
    let chart: PortfolioChartResponse
    let holdings: [Holding]
    let dailyChanges: [String: Double]
    let benchmark: Double?
    let updatedAt: Date?
    let savedAt: Date

    var hasUsableChart: Bool {
        chart.currentPoint.marketValue.isFinite && chart.currentPoint.cost.isFinite
    }
}

actor PortfolioPresentationCache {
    static let shared = PortfolioPresentationCache()
    private let directory: URL

    struct Context: Encodable {
        let source: String
        let accountKeys: [String]
        let language: String

        init(source: PortfolioSource, accountKeys: Set<String>, language: String) {
            switch source {
            case .personal: self.source = "personal"
            case .demo: self.source = "demo"
            case .publicInvestors(let selection): self.source = "public:" + selection
            }
            self.accountKeys = accountKeys.sorted()
            self.language = language
        }
    }

    private struct Envelope: Codable {
        let version: Int
        let documentDigest: String
        let snapshot: PortfolioPresentationSnapshot
    }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Catfolio/HomePresentation", isDirectory: true)) {
        self.directory = directory
    }

    private func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    private func file(for context: Context) throws -> URL {
        let namespace = context.source == "personal" ? "personal" : "examples"
        return directory.appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent(try digest(context)).appendingPathExtension("plist")
    }

    /// Quote refreshes also change document timestamps and daily snapshots.
    /// They must not invalidate the last display of an otherwise identical
    /// ledger. Trades, quantities, costs, currencies and account identity do.
    private func ledgerDigest(_ document: LocalPortfolioDocument) throws -> String {
        var identity = document
        identity.updatedAt = .distantPast
        identity.marketDataUpdatedAt = nil
        if document.isSynthetic != true && !document.isPublicDisclosure {
            identity.snapshots = []
            identity.positions = document.positions.map { $0.withQuotePrice(0, observedAt: .distantPast) }
        }
        return try digest(identity)
    }

    func sameLedger(_ lhs: LocalPortfolioDocument, _ rhs: LocalPortfolioDocument) -> Bool {
        guard let left = try? ledgerDigest(lhs), let right = try? ledgerDigest(rhs) else { return false }
        return left == right
    }

    func load(document: LocalPortfolioDocument, context: Context) -> PortfolioPresentationSnapshot? {
        guard let file = try? file(for: context), let data = try? Data(contentsOf: file),
              let envelope = try? PropertyListDecoder().decode(Envelope.self, from: data),
              envelope.snapshot.hasUsableChart else { return nil }
        let expected: String?
        switch envelope.version {
        case 1: expected = try? digest(document)
        case 2: expected = try? ledgerDigest(document)
        default: return nil
        }
        guard envelope.documentDigest == expected else { return nil }
        return envelope.snapshot
    }

    func save(_ snapshot: PortfolioPresentationSnapshot, document: LocalPortfolioDocument, context: Context) throws {
        guard snapshot.hasUsableChart else { return }
        let file = try file(for: context)
        var folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        // Binary plist preserves unavailable financial values (NaN), without
        // replacing them with zero or losing the account-NAV calculation basis.
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let envelope = Envelope(version: 2, documentDigest: try ledgerDigest(document), snapshot: snapshot)
        try encoder.encode(envelope).write(to: file, options: [.atomic, .completeFileProtection])
        // Bound the number of account/selection combinations kept on disk.
        let files = try FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "plist" }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
        for obsolete in files.dropFirst(12) { try? FileManager.default.removeItem(at: obsolete) }
    }

    func removePersonal() {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("personal", isDirectory: true))
    }
}
