import Foundation
import Observation

/// Runs a debate to completion regardless of where the person goes next.
///
/// The work is owned here rather than by the view that starts it. A `Task`
/// created in a `View` is cancelled when SwiftUI tears the view down, so
/// leaving the security sheet used to mean losing the request — which for
/// something that takes a research fetch plus a model call is most of the time
/// it needs. A person taps, goes back to the portfolio, and comes back to a
/// finished answer, or opens the AI tab and finds it there.
///
/// Results are kept in this store's own file rather than folded into the chat
/// library, so the conversation document's schema and migrations are left
/// alone; the AI tab reads the same store the security sheet writes.
@MainActor
@Observable
final class SecurityDebateStore {
    enum Progress: Equatable {
        case idle
        /// What it is doing, so the sheet can say more than "loading".
        case collecting
        case reasoning
        case ready(SecurityDebate)
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .collecting, .reasoning: true
            case .idle, .ready, .failed: false
            }
        }

        var debate: SecurityDebate? {
            if case let .ready(debate) = self { return debate }
            return nil
        }

        /// Hand-written because a debate carries `PortfolioAttentionSource`,
        /// which is not `Equatable`, and adding that conformance means editing
        /// a model file being reworked elsewhere. Two finished debates for the
        /// same security generated at the same instant are the same result;
        /// comparing every source would answer the same question at more cost.
        static func == (lhs: Progress, rhs: Progress) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.collecting, .collecting), (.reasoning, .reasoning):
                true
            case let (.failed(left), .failed(right)):
                left == right
            case let (.ready(left), .ready(right)):
                left.ticker == right.ticker && left.generatedAt == right.generatedAt
            default:
                false
            }
        }
    }

    static let shared = SecurityDebateStore()

    private(set) var progress: [String: Progress] = [:]
    /// Tasks are retained so nothing is cancelled by a view disappearing, and
    /// so a second tap joins the run in flight instead of starting another.
    private var tasks: [String: Task<Void, Never>] = [:]
    private let file: SecurityDebateFile

    init(file: SecurityDebateFile = SecurityDebateFile()) {
        self.file = file
    }

    func progress(for ticker: String) -> Progress {
        progress[Self.key(ticker)] ?? .idle
    }

    /// Every debate on the device, newest first — what the AI tab lists.
    var recent: [SecurityDebate] {
        progress.values.compactMap(\.debate).sorted { $0.generatedAt > $1.generatedAt }
    }

    func restore() async {
        let saved = await file.load()
        for debate in saved where progress[Self.key(debate.ticker)] == nil {
            progress[Self.key(debate.ticker)] = .ready(debate)
        }
    }

    /// Idempotent: a tap while one is running is a no-op, and a tap when one is
    /// already finished returns it. `force` is the pull-to-refresh case.
    func start(ticker: String, name: String, force: Bool = false) {
        let key = Self.key(ticker)
        if !force {
            if tasks[key] != nil { return }
            if case .ready = progress[key] { return }
        }
        tasks[key]?.cancel()
        progress[key] = .collecting

        tasks[key] = Task { [weak self] in
            guard let self else { return }
            let outcome = await Self.run(ticker: ticker, name: name) { stage in
                await MainActor.run { self.progress[key] = stage }
            }
            if Task.isCancelled { return }
            self.progress[key] = outcome
            self.tasks[key] = nil
            if let debate = outcome.debate {
                await self.file.save(debate)
            }
        }
    }

    private static func run(
        ticker: String,
        name: String,
        report: @escaping (Progress) async -> Void
    ) async -> Progress {
        let research = SecurityDebateResearch()
        async let sources = research.sources(ticker: ticker, name: name)
        async let analyst = try? NasdaqAnalystClient().consensus(symbol: ticker)
        let collected = await sources
        let consensus = await analyst

        guard !collected.isEmpty else {
            return .failed(L10n.text("没有找到可引用的新闻或申报文件"))
        }
        await report(.reasoning)

        let prompt = SecurityDebateResearch.prompt(
            ticker: ticker, name: name, sources: collected, analyst: consensus
        )
        do {
            let answer = try await LocalAIClient().researchAnswerAllowingSearch(prompt, context: "")
            guard let debate = SecurityDebateResearch.parse(
                answer.text, ticker: ticker, name: name,
                sources: collected, usedModelWebSearch: answer.searched
            ) else {
                return .failed(L10n.text("模型没有返回可解析的正反方结构"))
            }
            return .ready(debate)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func key(_ ticker: String) -> String { ticker.uppercased() }
}

/// Disk for finished debates. An actor because the store is main-actor bound
/// and writing JSON has no business happening there.
actor SecurityDebateFile {
    private let fileManager: FileManager
    private let url: URL
    /// Bounded so browsing a long watchlist cannot grow the file forever.
    private let limit = 40

    init(fileManager: FileManager = .default, url: URL? = nil) {
        self.fileManager = fileManager
        let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.url = url ?? root
            .appendingPathComponent("Catfolio", isDirectory: true)
            .appendingPathComponent("security-debates.json", isDirectory: false)
    }

    func load() -> [SecurityDebate] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SecurityDebate].self, from: data)) ?? []
    }

    func save(_ debate: SecurityDebate) {
        var all = load().filter { $0.ticker.uppercased() != debate.ticker.uppercased() }
        all.insert(debate, at: 0)
        all = Array(all.prefix(limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(all) else { return }
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? fileManager.removeItem(at: url)
    }
}
