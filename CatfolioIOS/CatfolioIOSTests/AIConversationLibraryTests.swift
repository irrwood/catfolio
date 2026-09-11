import XCTest
@testable import CatfolioIOS

/// The conversation library, and the upgrade from the single-chat file.
///
/// The migration is the part worth testing hardest. Everyone who already uses
/// the assistant has a schema-2 file, and the failure mode is not a crash —
/// it is an empty sidebar where their chat used to be.
final class AIConversationLibraryTests: XCTestCase {

    private var directory: URL!
    private var fileURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("ai-chat-history.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store() -> LocalChatStore {
        LocalChatStore(fileURL: fileURL)
    }

    private func message(_ role: ChatMessage.Role, _ text: String) -> ChatMessage {
        ChatMessage(role: role, text: text)
    }

    // MARK: - Titles

    func testTitleComesFromTheFirstThingTheUserAsked() {
        let title = AIConversation.derivedTitle(from: [
            message(.assistant, "Here is today's briefing."),
            message(.user, "How concentrated am I?"),
            message(.user, "And in what?"),
        ])
        XCTAssertEqual(title, "How concentrated am I?")
    }

    func testAConversationWithNoUserMessageHasNoTitle() {
        // The attention report opens a conversation on its own. Naming it
        // after the assistant's first line would fill the sidebar with rows
        // that all start the same way.
        XCTAssertNil(AIConversation.derivedTitle(from: [
            message(.assistant, "15 holdings, 3 need attention"),
        ]))
    }

    func testALongQuestionIsTruncated() throws {
        let question = String(repeating: "a", count: 120)
        let title = try XCTUnwrap(AIConversation.derivedTitle(from: [message(.user, question)]))
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertEqual(title.count, 41)
    }

    func testTheTitleIsTheFirstNonEmptyLine() {
        let title = AIConversation.derivedTitle(from: [
            message(.user, "\n\n  Summarise my risks  \nand rank them"),
        ])
        XCTAssertEqual(title, "Summarise my risks")
    }

    // MARK: - Round trip

    func testALibraryRoundTrips() async throws {
        let first = AIConversation(
            title: "Risks",
            messages: [message(.user, "risks?")],
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let second = AIConversation(
            title: "Fees",
            messages: [message(.user, "fees?")],
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let store = self.store()
        try await store.save(LocalChatLibrary(conversations: [first, second], activeID: first.id))

        let loaded = try await store.loadLibrary()
        XCTAssertEqual(loaded.conversations.count, 2)
        XCTAssertEqual(loaded.activeID, first.id)
        // Newest first, which is the order the sidebar draws.
        XCTAssertEqual(loaded.sortedByRecency.map(\.title), ["Fees", "Risks"])
        XCTAssertEqual(loaded.active?.messages.first?.text, "risks?")
    }

    func testAnActiveIDThatNoLongerExistsIsDropped() async throws {
        let conversation = AIConversation(messages: [message(.user, "hello")])
        let store = self.store()
        try await store.save(
            LocalChatLibrary(conversations: [conversation], activeID: UUID())
        )
        let loaded = try await store.loadLibrary()
        XCTAssertNil(loaded.activeID)
        XCTAssertEqual(loaded.conversations.count, 1)
    }

    func testAMissingFileIsAnEmptyLibraryRatherThanAnError() async throws {
        let loaded = try await store().loadLibrary()
        XCTAssertTrue(loaded.conversations.isEmpty)
        XCTAssertNil(loaded.activeID)
    }

    // MARK: - Migration

    /// Writes the exact shape the app shipped before the library existed.
    private func writeSchemaTwoDocument() throws {
        let json = """
        {
          "schemaVersion": 2,
          "messages": [
            {
              "createdAt": "2026-09-01T10:00:00Z",
              "id": "\(UUID().uuidString)",
              "role": "user",
              "text": "Which holdings need my attention?"
            },
            {
              "createdAt": "2026-09-01T10:00:05Z",
              "id": "\(UUID().uuidString)",
              "role": "assistant",
              "text": "Three of them."
            }
          ]
        }
        """
        try json.data(using: .utf8)!.write(to: fileURL)
    }

    func testAnExistingSingleConversationSurvivesTheUpgrade() async throws {
        try writeSchemaTwoDocument()
        let loaded = try await store().loadLibrary()

        XCTAssertEqual(loaded.conversations.count, 1)
        XCTAssertEqual(loaded.conversations.first?.messages.count, 2)
        XCTAssertEqual(loaded.activeID, loaded.conversations.first?.id)
        // It is named from the question, so it does not appear as "New chat".
        XCTAssertEqual(loaded.conversations.first?.title, "Which holdings need my attention?")
    }

    func testTheUpgradedConversationIsWrittenBackAsALibrary() async throws {
        try writeSchemaTwoDocument()
        let store = self.store()
        let migrated = try await store.loadLibrary()
        try await store.save(migrated)

        let reloaded = try await store.loadLibrary()
        XCTAssertEqual(reloaded.conversations.count, 1)
        XCTAssertEqual(reloaded.conversations.first?.messages.count, 2)
    }

    func testAnEmptyLegacyDocumentMigratesToNothing() async throws {
        try #"{"schemaVersion": 2, "messages": []}"#.data(using: .utf8)!.write(to: fileURL)
        let loaded = try await store().loadLibrary()
        XCTAssertTrue(loaded.conversations.isEmpty)
    }

    // MARK: - Bounds

    func testTheOpenConversationIsNeverTrimmedAway() async throws {
        // The oldest conversation is also the open one: opening an old chat
        // and typing into it must not delete it.
        var conversations: [AIConversation] = []
        for index in 0..<60 {
            conversations.append(AIConversation(
                title: "chat \(index)",
                messages: [message(.user, "q\(index)")],
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
        let oldest = try XCTUnwrap(conversations.first)
        let store = self.store()
        try await store.save(LocalChatLibrary(conversations: conversations, activeID: oldest.id))

        let loaded = try await store.loadLibrary()
        XCTAssertEqual(loaded.conversations.count, 50)
        XCTAssertEqual(loaded.activeID, oldest.id)
        XCTAssertTrue(loaded.conversations.contains { $0.id == oldest.id })
    }

    func testLegacyLoadReturnsTheOpenConversation() async throws {
        let older = AIConversation(
            title: "older",
            messages: [message(.user, "old")],
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = AIConversation(
            title: "newer",
            messages: [message(.user, "new")],
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )
        let store = self.store()
        try await store.save(
            LocalChatLibrary(conversations: [older, newer], activeID: older.id)
        )

        let history = try await store.load()
        XCTAssertEqual(history.messages.first?.text, "old")
    }
}
