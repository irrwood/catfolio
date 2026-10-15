import Foundation

struct Trading212SetupDraft: Codable, Equatable {
    var step: Trading212GuideStep
    // Retained for decoding older drafts; connections now always use live accounts.
    var environment: Trading212Environment
    var apiKey: String
    var apiSecret: String
    var accountSlot: Int
    var nickname: String
    var nicknameEdited: Bool

    /// A preview must be read again after process termination. Restoring a
    /// form must never import an account or present an old preview as fresh.
    var restoredStep: Trading212GuideStep {
        step.isTutorial ? .prepare : .credentials
    }
}

/// Only the resume flag goes into preferences. Both unfinished credentials
/// and the rest of the form stay in a separate, device-local Keychain item.
@MainActor
final class Trading212SetupStore {
    static let shared = Trading212SetupStore()
    static let presentationKey = "catfolio.trading212.setup-presented.v1"
    private let defaults: UserDefaults
    private let read: (String) -> String?
    private let write: (String, String) throws -> Void

    init(defaults: UserDefaults = .standard,
         read: @escaping (String) -> String? = { KeychainStore.string(for: $0) },
         write: @escaping (String, String) throws -> Void = { try KeychainStore.set($1, for: $0) }) {
        self.defaults = defaults
        self.read = read
        self.write = write
    }

    var shouldResumeCreation: Bool { defaults.bool(forKey: Self.presentationKey) }

    /// Whether launching the app reopens an unfinished setup. Never from the
    /// app's own defaults in a test host: there the reopened page set the flag
    /// again and was never closed, so one flag left by a test put the setup
    /// sheet over every later run — as the first-launch guide is kept out of
    /// tests too. A store with its own defaults still resumes, so the
    /// behaviour itself stays testable.
    var resumesAtLaunch: Bool {
        #if DEBUG
        if defaults === UserDefaults.standard,
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return false }
        #endif
        return shouldResumeCreation
    }

    func setCreationPresented(_ presented: Bool) {
        guard shouldResumeCreation != presented else { return }
        defaults.set(presented, forKey: Self.presentationKey)
    }

    func load(for context: AccountConnectorContext) -> Trading212SetupDraft? {
        guard let data = read(key(for: context))?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Trading212SetupDraft.self, from: data)
    }

    func save(_ draft: Trading212SetupDraft, for context: AccountConnectorContext) throws {
        let data = try JSONEncoder().encode(draft)
        try write(key(for: context), String(decoding: data, as: UTF8.self))
    }

    func clear(for context: AccountConnectorContext) throws {
        if context.isCreating { setCreationPresented(false) }
        try write(key(for: context), "")
    }

    private func key(for context: AccountConnectorContext) -> String {
        "catfolio.trading212.setup-draft.v1.\(context.account?.id ?? "new")"
    }
}
