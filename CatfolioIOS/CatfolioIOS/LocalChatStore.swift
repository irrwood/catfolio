import Foundation

/// One conversation in the library.
///
/// `title` is optional and stays nil until the first thing the person asks
/// names it. It is deliberately not filled in with a localised placeholder at
/// save time: the file would then carry whatever language the app happened to
/// be in when the conversation started, and would still say it after the
/// person switched languages. The placeholder belongs to the view.
struct AIConversation: Identifiable, Sendable {
    let id: UUID
    var title: String?
    var messages: [ChatMessage]
    var attentionReports: [UUID: PortfolioAttentionReport]
    var updatedAt: Date
    var securityDebate: SecurityDebate?
    var securityDebateMessageID: UUID?

    init(
        id: UUID = UUID(),
        title: String? = nil,
        messages: [ChatMessage] = [],
        attentionReports: [UUID: PortfolioAttentionReport] = [:],
        updatedAt: Date = .now,
        securityDebate: SecurityDebate? = nil,
        securityDebateMessageID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.attentionReports = attentionReports
        self.updatedAt = updatedAt
        self.securityDebate = securityDebate
        self.securityDebateMessageID = securityDebateMessageID
            ?? (securityDebate == nil ? nil : messages.first(where: { $0.role == .assistant })?.id)
    }

    var isEmpty: Bool { messages.isEmpty }

    /// A title taken from the first thing the person asked.
    ///
    /// Only the user's own words. An assistant reply opens with whatever the
    /// model felt like saying, which makes a list of them unreadable, and the
    /// attention report has no prose at all.
    static func derivedTitle(from messages: [ChatMessage]) -> String? {
        guard let first = messages.first(where: { $0.role == .user }) else { return nil }
        let line = first.text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        guard line.count > 40 else { return line }
        return line.prefix(40).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Every conversation on this device, and which one was open last.
struct LocalChatLibrary: Sendable {
    var conversations: [AIConversation]
    var activeID: UUID?
    /// Keep import identities after deletion so a removed analysis stays removed.
    var importedSecurityDebateKeys: Set<String> = []

    @discardableResult
    mutating func importSecurityDebates(_ debates: [SecurityDebate]) -> Bool {
        var changed = false
        for debate in debates where !debate.questions.isEmpty {
            guard importedSecurityDebateKeys.insert(debate.conversationKey).inserted else { continue }
            conversations.append(AIConversation(
                title: "\(debate.ticker) · \(L10n.text("个股关键变化"))",
                messages: [
                    ChatMessage(role: .user, text: "\(debate.name) (\(debate.ticker)) · \(L10n.text("个股关键变化"))", createdAt: debate.generatedAt),
                    ChatMessage(role: .assistant, text: debate.conversationMarkdown, createdAt: debate.generatedAt)
                ],
                updatedAt: debate.generatedAt,
                securityDebate: debate
            ))
            changed = true
        }
        return changed
    }

    static let empty = LocalChatLibrary(conversations: [], activeID: nil)

    /// Newest first, which is the order the sidebar reads in.
    var sortedByRecency: [AIConversation] {
        conversations.sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
    }

    var active: AIConversation? {
        guard let activeID else { return nil }
        return conversations.first { $0.id == activeID }
    }
}

/// Kept for the single-conversation callers that have not moved yet.
struct LocalChatHistory: Sendable {
    let messages: [ChatMessage]
    let attentionReports: [UUID: PortfolioAttentionReport]
}

/// The library as it was last read or written, so the assistant opens on
/// its conversation at once instead of waiting on the file each time. Only
/// the assistant writes the library, and it updates this as it saves.
@MainActor
enum LocalChatLibraryCache {
    static var library: LocalChatLibrary?

    /// Reads the library ahead of the first open. Off the main thread: the
    /// store is an actor.
    static func warm() async {
        guard library == nil, let loaded = try? await LocalChatStore.shared.loadLibrary() else { return }
        if library == nil { library = loaded }
    }
}

actor LocalChatStore {
    private struct StoredAttentionReport: Codable {
        let messageID: UUID
        let report: PortfolioAttentionReport
    }

    private struct StoredConversation: Codable {
        let id: UUID
        let title: String?
        let messages: [ChatMessage]
        let attentionReports: [StoredAttentionReport]?
        let updatedAt: Date
        var securityDebate: SecurityDebate? = nil
        var securityDebateMessageID: UUID? = nil
    }

    /// Schema 3 holds a library. Schemas 1 and 2 held exactly one
    /// conversation at the top level, and those fields are still read so an
    /// existing chat survives the upgrade — see `migrated(from:)`.
    private struct Document: Codable {
        let schemaVersion: Int
        let messages: [ChatMessage]?
        let attentionReports: [StoredAttentionReport]?
        let conversations: [StoredConversation]?
        let activeConversationID: UUID?
        var importedSecurityDebateKeys: [String]? = nil
    }

    static let shared = LocalChatStore()

    private let fileManager: FileManager
    private let fileURL: URL
    private let maximumMessageCount = 500
    /// Bounded so the file cannot grow without limit. The oldest conversation
    /// is dropped, never the one currently open.
    private let maximumConversationCount = 50

    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.fileURL = fileURL ?? root
            .appendingPathComponent("Catfolio", isDirectory: true)
            .appendingPathComponent("ai-chat-history.json", isDirectory: false)
    }

    func loadLibrary() throws -> LocalChatLibrary {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: data)

        if let stored = document.conversations {
            let conversations = stored.map { conversation in
                AIConversation(
                    id: conversation.id,
                    title: conversation.title,
                    messages: conversation.messages,
                    attentionReports: Dictionary(
                        uniqueKeysWithValues: (conversation.attentionReports ?? [])
                            .map { ($0.messageID, $0.report) }
                    ),
                    updatedAt: conversation.updatedAt,
                    securityDebate: conversation.securityDebate,
                    securityDebateMessageID: conversation.securityDebateMessageID
                )
            }
            let activeID = document.activeConversationID.flatMap { id in
                conversations.contains { $0.id == id } ? id : nil
            }
            return LocalChatLibrary(conversations: conversations, activeID: activeID,
                importedSecurityDebateKeys: Set(document.importedSecurityDebateKeys ?? []))
        }

        return migrated(from: document)
    }

    /// Folds a pre-library document into a one-conversation library.
    ///
    /// The upgrade must not look like a lost chat, so the existing messages
    /// become the first conversation rather than being dropped on the floor.
    private func migrated(from document: Document) -> LocalChatLibrary {
        let messages = document.messages ?? []
        guard !messages.isEmpty else { return .empty }
        let conversation = AIConversation(
            title: AIConversation.derivedTitle(from: messages),
            messages: messages,
            attentionReports: Dictionary(
                uniqueKeysWithValues: (document.attentionReports ?? [])
                    .map { ($0.messageID, $0.report) }
            ),
            // The old format never recorded a time. Now is wrong but harmless
            // — it is the only conversation, so nothing sorts against it.
            updatedAt: .now
        )
        return LocalChatLibrary(conversations: [conversation], activeID: conversation.id)
    }

    /// Kept so callers that only want the open conversation still compile.
    func load() throws -> LocalChatHistory {
        let library = try loadLibrary()
        let conversation = library.active ?? library.sortedByRecency.first
        return LocalChatHistory(
            messages: conversation?.messages ?? [],
            attentionReports: conversation?.attentionReports ?? [:]
        )
    }

    func save(_ library: LocalChatLibrary) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Trim oldest-first, but never the open conversation: a person who
        // has 50 chats and opens the oldest should not watch it vanish as
        // soon as they type into it.
        var kept = library.sortedByRecency
        if kept.count > maximumConversationCount {
            let survivors = kept.prefix(maximumConversationCount)
            var trimmed = Array(survivors)
            if let activeID = library.activeID,
               !trimmed.contains(where: { $0.id == activeID }),
               let active = kept.first(where: { $0.id == activeID }) {
                trimmed.removeLast()
                trimmed.append(active)
            }
            kept = trimmed
        }

        let stored = kept.map { conversation -> StoredConversation in
            let messages = Array(conversation.messages.suffix(maximumMessageCount))
            let ids = Set(messages.map(\.id))
            return StoredConversation(
                id: conversation.id,
                title: conversation.title,
                messages: messages,
                attentionReports: conversation.attentionReports
                    .filter { ids.contains($0.key) }
                    .map { StoredAttentionReport(messageID: $0.key, report: $0.value) }
                    .sorted { $0.messageID.uuidString < $1.messageID.uuidString },
                updatedAt: conversation.updatedAt,
                securityDebate: ids.contains(conversation.securityDebateMessageID ?? UUID()) ? conversation.securityDebate : nil,
                securityDebateMessageID: conversation.securityDebateMessageID
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let document = Document(
            schemaVersion: 3,
            messages: nil,
            attentionReports: nil,
            conversations: stored,
            activeConversationID: library.activeID.flatMap { id in
                stored.contains { $0.id == id } ? id : nil
            },
            importedSecurityDebateKeys: library.importedSecurityDebateKeys.sorted()
        )
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        var protectedURL = fileURL
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try protectedURL.setResourceValues(resourceValues)
    }

}
