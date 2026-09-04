import Foundation

struct LocalChatHistory: Sendable {
    let messages: [ChatMessage]
    let attentionReports: [UUID: PortfolioAttentionReport]
}

actor LocalChatStore {
    private struct StoredAttentionReport: Codable {
        let messageID: UUID
        let report: PortfolioAttentionReport
    }

    private struct Document: Codable {
        let schemaVersion: Int
        let messages: [ChatMessage]
        let attentionReports: [StoredAttentionReport]?
    }

    static let shared = LocalChatStore()

    private let fileManager: FileManager
    private let fileURL: URL
    private let maximumMessageCount = 500

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.fileURL = fileURL ?? root
            .appendingPathComponent("Catfolio", isDirectory: true)
            .appendingPathComponent("ai-chat-history.json", isDirectory: false)
    }

    func load() throws -> LocalChatHistory {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return LocalChatHistory(messages: [], attentionReports: [:])
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data)
        let reports = Dictionary(
            uniqueKeysWithValues: (document.attentionReports ?? []).map { ($0.messageID, $0.report) }
        )
        return LocalChatHistory(messages: document.messages, attentionReports: reports)
    }

    func save(
        _ messages: [ChatMessage],
        attentionReports: [UUID: PortfolioAttentionReport] = [:]
    ) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let savedMessages = Array(messages.suffix(maximumMessageCount))
        let savedMessageIDs = Set(savedMessages.map(\.id))
        let savedReports = attentionReports
            .filter { savedMessageIDs.contains($0.key) }
            .map { StoredAttentionReport(messageID: $0.key, report: $0.value) }
            .sorted { $0.messageID.uuidString < $1.messageID.uuidString }
        let document = Document(
            schemaVersion: 2,
            messages: savedMessages,
            attentionReports: savedReports
        )
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        var protectedURL = fileURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try protectedURL.setResourceValues(resourceValues)
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }
}
