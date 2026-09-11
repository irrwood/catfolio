import Foundation

/// Editor persistence is deliberately separate from the account ledger and
/// from the shared strategy document schema. Invalid free text is valuable
/// user data: it never replaces the last successfully validated document.
struct PolicyWorkspace: Codable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var draft: String
    var validatedDocument: Data?
    var generation: Int
    var updatedAt: Date
    var adoptedCandidates: [String: Int]? = nil

    init(id: UUID = UUID(), title: String = "", draft: String = "", validatedDocument: Data? = nil) {
        self.id = id
        self.title = title
        self.draft = draft
        self.validatedDocument = validatedDocument
        self.generation = 0
        self.updatedAt = .now
    }
}

enum PolicyWorkspaceError: LocalizedError {
    case conflict
    case oversized
    case corrupt(String)

    var errorDescription: String? {
        switch self {
        case .conflict: L10n.text("策略已在另一处更新，请重新打开后再编辑。草稿尚未覆盖。")
        case .oversized: L10n.text("策略文本过大，请拆分为较小的策略。")
        case .corrupt(let name): L10n.text("无法读取策略文件 \(name)。原文件已保留，未重置。")
        }
    }
}

/// All file IO and JSON encoding remain off the main actor. Each workspace
/// has its own atomic file, so a damaged entry cannot erase the library.
actor PolicyWorkspaceStore {
    static let shared = PolicyWorkspaceStore()
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    static let maximumDraftBytes = 256_000

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Catfolio/Policies", isDirectory: true)) {
        self.directory = directory
    }

    private func url(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    @discardableResult
    func saveCandidate(workspaceID: UUID, original: String, candidate: String, rawResponse: String, baseRevision: Int) throws -> String {
        let folder = directory.appendingPathComponent(workspaceID.uuidString).appendingPathComponent("candidates")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record: PolicyJSON = .object([
            "original": .string(original), "candidate": .string(candidate), "rawResponse": .string(rawResponse),
            "baseRevision": .number(Double(baseRevision)), "promptVersion": .string("policy-organize-1"),
            "provider": .string("App configured AI service; response API does not expose model identity"),
            "createdAt": .string(ISO8601DateFormatter().string(from: .now)), "status": .string("PENDING_CONFIRMATION")
        ])
        let id = UUID().uuidString
        try record.data().write(to: folder.appendingPathComponent(id + ".json"), options: [.atomic, .completeFileProtection])
        return id
    }

    func candidates(_ workspaceID: UUID) throws -> [(id: String, record: PolicyJSON)] {
        let folder = directory.appendingPathComponent(workspaceID.uuidString).appendingPathComponent("candidates")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let adopted = try load(workspaceID)?.adoptedCandidates ?? [:]
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.map { file in
            var record = try decoder.decode(PolicyJSON.self, from: Data(contentsOf: file))
            let id = file.deletingPathExtension().lastPathComponent
            if let revision = adopted[id] { record["status"] = .string("ADOPTED"); record["adoptedRevision"] = .number(Double(revision)) }
            return (id, record)
        }.sorted { $0.1["createdAt"].string > $1.1["createdAt"].string }
    }

    func revisions(_ workspaceID: UUID) throws -> [PolicyJSON] {
        let folder = directory.appendingPathComponent(workspaceID.uuidString)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("revision-") && $0.pathExtension == "json" }
            .map { try decoder.decode(PolicyJSON.self, from: Data(contentsOf: $0)) }
            .sorted { ($0["revision"].number ?? 0) > ($1["revision"].number ?? 0) }
    }

    func list() throws -> [PolicyWorkspace] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { file in
                do { return try decoder.decode(PolicyWorkspace.self, from: Data(contentsOf: file)) }
                catch { throw PolicyWorkspaceError.corrupt(file.lastPathComponent) }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(_ id: UUID) throws -> PolicyWorkspace? {
        let file = url(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do { return try decoder.decode(PolicyWorkspace.self, from: Data(contentsOf: file)) }
        catch { throw PolicyWorkspaceError.corrupt(file.lastPathComponent) }
    }

    @discardableResult
    func save(_ workspace: PolicyWorkspace, adoptingCandidateID: String? = nil) throws -> PolicyWorkspace {
        guard workspace.draft.utf8.count <= Self.maximumDraftBytes,
              (workspace.validatedDocument?.count ?? 0) <= Self.maximumDraftBytes else {
            throw PolicyWorkspaceError.oversized
        }
        let existing = try load(workspace.id)
        if let existing, existing.generation != workspace.generation {
            throw PolicyWorkspaceError.conflict
        }
        var next = workspace
        if let candidateID = adoptingCandidateID {
            guard let existing, let entry = try candidates(workspace.id).first(where: { $0.id == candidateID }), entry.record["status"].string == "PENDING_CONFIRMATION",
                  entry.record["original"].string == existing.draft else { throw PolicyWorkspaceError.conflict }
            let old = try existing.validatedDocument.map { try decoder.decode(PolicyJSON.self, from: $0) }
            guard Int(old?["revision"].number ?? 0) == Int(entry.record["baseRevision"].number ?? -1), let data = next.validatedDocument else { throw PolicyWorkspaceError.conflict }
            let revision = try decoder.decode(PolicyJSON.self, from: data)["revision"].number ?? 0
            var adopted = existing.adoptedCandidates ?? [:]
            adopted[candidateID] = Int(revision)
            next.adoptedCandidates = adopted
        }
        next.generation += 1
        next.updatedAt = .now
        let data = try encoder.encode(next)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let document = next.validatedDocument {
            let ast = try decoder.decode(PolicyJSON.self, from: document)
            let folder = directory.appendingPathComponent(next.id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let revision = folder.appendingPathComponent("revision-\(Int(ast["revision"].number ?? 0)).json")
            if FileManager.default.fileExists(atPath: revision.path) {
                let old = try decoder.decode(PolicyJSON.self, from: Data(contentsOf: revision))
                guard old == ast else { throw PolicyWorkspaceError.conflict }
            } else {
                try document.write(to: revision, options: [.atomic, .completeFileProtection])
            }
        }
        // Editor drafts do not need to be readable while the phone is locked.
        // The later run/checkpoint store has its own explicit protection policy.
        try data.write(to: url(next.id), options: [.atomic, .completeFileProtection])
        return next
    }
}
