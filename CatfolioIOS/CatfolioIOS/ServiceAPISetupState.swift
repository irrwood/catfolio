import Foundation
import Observation

/// Resume only unfinished API setup. Credentials never enter UserDefaults.
@MainActor @Observable
final class ServiceAPISetupState {
    static let shared = ServiceAPISetupState()
    static let storageKey = "catfolio.service-api-setup.progress.v1"

    enum Step: Hashable, Codable {
        case guide(LocalServiceProvider)
        case key(LocalServiceProvider)
        case trading212
        case ibkr
        case account(AddAccountProvider)

        var accountProvider: AddAccountProvider? {
            switch self {
            case .trading212: .trading212
            case .ibkr: .ibkr
            case .account(let provider): provider
            case .guide, .key: nil
            }
        }
    }

    var started: Bool { didSet { persist() } }
    var path: [Step] { didSet { persist() } }
    var isPresented: Bool { didSet { persist() } }
    var settingsProvider: LocalServiceProvider? { didSet { persist() } }
    /// A provider page left open when the app went away opens again at
    /// launch, where the key was being fetched from another app. A Mac app
    /// stays open beside that app, so it starts on its first page instead.
    var resumesSettingsProviderAtLaunch: Bool {
        settingsProvider != nil && !MacPlatform.isMac
    }
    @ObservationIgnored private let defaults: UserDefaults

    private struct Progress: Codable {
        var started = false
        var path: [Step] = []
        var isPresented = false
        var settingsProvider: LocalServiceProvider?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Progress.self, from: $0) } ?? Progress()
        started = saved.started
        // The acquisition guide is now optional help on the key form. Collapse
        // old guide + key routes so Back returns directly to provider selection.
        path = saved.path.last.map { step -> [Step] in
            switch step {
            case .guide(let provider), .key(let provider): [.key(provider)]
            case .trading212, .ibkr, .account: [step]
            }
        } ?? []
        isPresented = saved.isPresented
        settingsProvider = saved.settingsProvider
    }

    func finish() {
        isPresented = false
        path = []
        started = false
    }

    private func persist() {
        let progress = Progress(started: started, path: path, isPresented: isPresented,
                                settingsProvider: settingsProvider)
        if let data = try? JSONEncoder().encode(progress) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// An unfinished key is a separate Keychain item, never an active service key.
/// Keeping its saved-key baseline also prevents reviving a draft after a key
/// has been replaced or removed elsewhere.
@MainActor
final class ServiceAPIKeyDrafts {
    static let shared = ServiceAPIKeyDrafts()
    private let read: (String) -> String?
    private let write: (String, String) throws -> Void

    private struct Draft: Codable {
        let text: String
        let savedKey: String
    }

    init(read: @escaping (String) -> String? = { KeychainStore.string(for: $0) },
         write: @escaping (String, String) throws -> Void = { try KeychainStore.set($1, for: $0) }) {
        self.read = read
        self.write = write
    }

    func text(for provider: LocalServiceProvider, savedKey: String) -> String {
        guard let data = read(key(for: provider))?.data(using: .utf8),
              let draft = try? JSONDecoder().decode(Draft.self, from: data),
              draft.savedKey == savedKey else { return savedKey }
        return draft.text
    }

    func update(_ text: String, for provider: LocalServiceProvider, savedKey: String) throws {
        if text == savedKey {
            try clear(provider)
        } else {
            let data = try JSONEncoder().encode(Draft(text: text, savedKey: savedKey))
            try write(key(for: provider), String(decoding: data, as: UTF8.self))
        }
    }

    func clear(_ provider: LocalServiceProvider) throws { try write(key(for: provider), "") }

    private func key(for provider: LocalServiceProvider) -> String {
        "catfolio.service-api-draft.\(provider.rawValue)"
    }
}
