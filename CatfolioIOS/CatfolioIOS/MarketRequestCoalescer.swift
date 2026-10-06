import Foundation

/// Share only simultaneous, identical read requests. Completed responses still
/// follow the existing price-cache policy; this adds no second result cache.
actor MarketRequestCoalescer {
    static let shared = MarketRequestCoalescer()
    typealias Loader = @Sendable (URLRequest, URLSession) async throws -> (Data, URLResponse)

    private struct Key: Hashable {
        let request: URLRequest
        let session: ObjectIdentifier
    }
    private struct Pending {
        let id = UUID()
        let task: Task<(Data, URLResponse), Error>
    }
    private var pending: [Key: Pending] = [:]
    private let loader: Loader

    init(loader: @escaping Loader = { request, session in
        try await session.recordedData(for: request)
    }) {
        self.loader = loader
    }

    func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        // Restrict sharing to read-only requests. Headers, query parameters and
        // session identity are part of the key, including credential changes.
        guard request.httpMethod == nil || request.httpMethod == "GET" else {
            return try await loader(request, session)
        }
        let key = Key(request: request, session: ObjectIdentifier(session))
        let entry: Pending
        if let existing = pending[key] {
            entry = existing
        } else {
            let loader = loader
            entry = Pending(task: Task { try await loader(request, session) })
            pending[key] = entry
        }
        defer {
            // An older waiter must not remove a newer request for the same key.
            if pending[key]?.id == entry.id { pending.removeValue(forKey: key) }
        }
        let result = try await entry.task.value
        // Cancelling one page cannot cancel another page's shared fetch, but
        // the cancelled page must not publish the result when it arrives.
        try Task.checkCancellation()
        return result
    }
}
