import Foundation
import CryptoKit

struct LongbridgeCredentials: Codable, Equatable, Sendable {
    static let keychainKey = "catfolio.longbridge.credentials"
    let appKey: String
    let appSecret: String
    let accessToken: String
    var isComplete: Bool { [appKey, appSecret, accessToken].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    static var stored: Self? {
        guard let value = KeychainStore.string(for: keychainKey),
              let data = value.data(using: .utf8),
              let result = try? JSONDecoder().decode(Self.self, from: data), result.isComplete else { return nil }
        return result
    }
    func save() throws {
        guard isComplete else { throw ChinaMarketError.missingCredentials }
        try KeychainStore.set(String(decoding: JSONEncoder().encode(self), as: UTF8.self), for: Self.keychainKey)
        ChinaMarketConfiguration.credentialsChanged()
    }
    var cacheIdentity: String {
        let data = Data([appKey, appSecret, accessToken].joined(separator: "\u{0}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func tokenRequest(at date: Date = .now) -> URLRequest {
        signedGET(path: "/v1/socket/token", at: date)
    }
    func signedGET(path: String, query: [URLQueryItem] = [], at date: Date = .now) -> URLRequest {
        var components = URLComponents(string: "https://openapi.longbridge.com")!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        // The official SDK signs Unix seconds (the prose docs also contain
        // a conflicting milliseconds example); use the SDK contract.
        let timestamp = String(Int64(date.timeIntervalSince1970))
        let headers = "authorization;x-api-key;x-timestamp"
        let values = "authorization:\(accessToken)\nx-api-key:\(appKey)\nx-timestamp:\(timestamp)\n"
        let canonical = "GET|\(path)|\(components.percentEncodedQuery ?? "")|\(values)|\(headers)|"
        let hash = Insecure.SHA1.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let digest = HMAC<SHA256>.authenticationCode(for: Data("HMAC-SHA256|\(hash)".utf8),
                                                     using: SymmetricKey(data: Data(appSecret.utf8)))
        let signature = digest.map { String(format: "%02x", $0) }.joined()
        request.setValue(accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(appKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue("HMAC-SHA256 SignedHeaders=\(headers), Signature=\(signature)", forHTTPHeaderField: "X-Api-Signature")
        return request
    }
}

/// One serial, rate-limited quote connection. No trade commands exist here.
actor LongbridgeQuoteTransport {
    static let shared = LongbridgeQuoteTransport()
    private var socket: URLSessionWebSocketTask?
    private var credentials: LongbridgeCredentials?
    private var lastRequest = Date.distantPast
    private var requestID: UInt32 = 0
    private var lastHeartbeat = Date.distantPast
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let session = URLSession(configuration: .ephemeral)

    private func lock() async {
        if locked { await withCheckedContinuation { waiters.append($0) } }
        else { locked = true }
    }
    private func unlock() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }
    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil); socket = nil; credentials = nil
    }
    func request(command: UInt8, body: Data, credentials next: LongbridgeCredentials) async throws -> Data {
        await lock()
        defer { unlock() }
        try Task.checkCancellation()
        do {
            if credentials != next || Date().timeIntervalSince(lastRequest) > 25 { disconnect() }
            if socket == nil {
                guard next.isComplete else { throw ChinaMarketError.missingCredentials }
                let (data, response) = try await session.recordedData(for: next.tokenRequest())
                guard let http = response as? HTTPURLResponse else { throw ChinaMarketError.invalidData }
                guard (200..<300).contains(http.statusCode) else { throw ChinaMarketError.rejected(http.statusCode) }
                struct Envelope: Decodable {
                    struct Token: Decodable { let otp: String }
                    let code: Int
                    let data: Token?
                }
                let payload = try JSONDecoder().decode(Envelope.self, from: data)
                guard payload.code == 0, let otp = payload.data?.otp, !otp.isEmpty else {
                    throw ChinaMarketError.rejected(payload.code)
                }
                let connection = session.webSocketTask(with: URL(string:
                    "wss://openapi-quote.longbridge.com?version=1&codec=1&platform=9")!)
                connection.maximumMessageSize = 16 * 1024 * 1024
                socket = connection; credentials = next; connection.resume()
                _ = try await exchange(command: 2, body: LongbridgeProto.string(1, otp), socket: connection)
                lastHeartbeat = .now
            }
            try await Task.sleep(for: .milliseconds(150))
            guard let socket else { throw ChinaMarketError.noData }
            if Date().timeIntervalSince(lastHeartbeat) > 15 {
                _ = try await exchange(command: 1,
                    body: LongbridgeProto.integer(1, UInt64(Date().timeIntervalSince1970)), socket: socket)
                lastHeartbeat = .now
            }
            let result = try await exchange(command: command, body: body, socket: socket)
            lastRequest = .now
            return result
        } catch {
            disconnect()
            throw error
        }
    }
    private func exchange(command: UInt8, body: Data, socket: URLSessionWebSocketTask) async throws -> Data {
        requestID &+= 1
        let id = requestID
        // Cancel the socket as well as the task so a stalled receive cannot
        // keep the structured task group alive after its deadline.
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await socket.send(.data(LongbridgePacket.request(command: command, id: id, body: body)))
                    while true {
                        try Task.checkCancellation()
                        guard case .data(let raw) = try await socket.receive() else { throw ChinaMarketError.invalidData }
                        let packet = try LongbridgePacket.decode(raw)
                        if packet.command == 0 { throw ChinaMarketError.noData }
                        guard packet.type == 2, packet.requestID == id else { continue }
                        guard packet.command == command else { throw ChinaMarketError.invalidData }
                        guard packet.status == 0 else {
                            let error = try? LongbridgeProto(packet.body)
                            throw ChinaMarketError.rejected(Int(error?.integer(1) ?? UInt64(packet.status)))
                        }
                        return packet.body
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(12))
                    socket.cancel(with: .goingAway, reason: nil)
                    throw ChinaMarketError.timeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw ChinaMarketError.noData }
                return result
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}

struct LongbridgeMarketDataClient {
    typealias Request = @Sendable (UInt8, Data) async throws -> Data
    let request: Request
    init(credentials: LongbridgeCredentials) {
        request = { command, body in
            try await LongbridgeQuoteTransport.shared.request(command: command, body: body, credentials: credentials)
        }
    }
    init(request: @escaping Request) { self.request = request }

    func quote(_ security: ChinaSecurity) async throws -> ChinaMarketQuote {
        let data = try await request(11, LongbridgeProto.string(1, security.longbridgeSymbol))
        return try Self.parseQuote(data, security: security)
    }
    static func parseQuote(_ data: Data, security: ChinaSecurity, now: Date = .now) throws -> ChinaMarketQuote {
        let rows = try LongbridgeProto(data).messages(1)
        guard let row = rows.first(where: { $0.string(1) == security.longbridgeSymbol }),
              let price = row.number(2), price > 0, let previous = row.number(3), previous > 0,
              let timestamp = row.integer(7), timestamp > 0,
              Double(timestamp) <= now.timeIntervalSince1970 + 60 else { throw ChinaMarketError.invalidData }
        return .init(price: price, previousClose: previous, observedAt: .init(timeIntervalSince1970: Double(timestamp)))
    }
    func intraday(_ security: ChinaSecurity) async throws -> [MarketIntradayBar] {
        let response = try LongbridgeProto(await request(18, LongbridgeProto.string(1, security.longbridgeSymbol)))
        guard response.string(1) == security.longbridgeSymbol else { throw ChinaMarketError.invalidData }
        let bars = try response.messages(2).map { row -> MarketIntradayBar in
            guard let price = row.number(1), price > 0, let timestamp = row.integer(2), timestamp > 0,
                  Double(timestamp) <= Date().timeIntervalSince1970 + 60 else { throw ChinaMarketError.invalidData }
            return .init(timestamp: Date(timeIntervalSince1970: Double(timestamp)), close: price)
        }
        guard !bars.isEmpty else { throw ChinaMarketError.noData }
        return bars.sorted { $0.timestamp < $1.timestamp }
    }
    func daily(_ security: ChinaSecurity, from: String, to: String, adjusted: Bool) async throws -> [MarketDailyBar] {
        guard ChinaSecurity.date(from) != nil, let end = ChinaSecurity.date(to), from <= to else {
            throw ChinaMarketError.invalidData
        }
        var cursor = end
        var values: [String: MarketDailyBar] = [:]
        // Offset paging avoids the date-range endpoint's 1,000-bar cap.
        for _ in 0..<100 {
            try Task.checkCancellation()
            let date = ChinaSecurity.day(cursor).replacingOccurrences(of: "-", with: "")
            let offset = LongbridgeProto.string(2, date) + LongbridgeProto.integer(4, 1000)
            let body = LongbridgeProto.string(1, security.longbridgeSymbol)
                + LongbridgeProto.integer(2, 1000) + LongbridgeProto.integer(3, adjusted ? 1 : 0)
                + LongbridgeProto.integer(4, 1) + LongbridgeProto.bytes(5, offset)
            let bars = try Self.parseDaily(await request(27, body), security: security)
            guard let first = bars.first else { break }
            for bar in bars where bar.date >= from && bar.date <= to { values[bar.date] = bar }
            if first.date <= from || bars.count < 1000 { break }
            guard let earliest = ChinaSecurity.date(first.date), earliest <= cursor else { throw ChinaMarketError.invalidData }
            cursor = earliest.addingTimeInterval(-86400)
        }
        guard !values.isEmpty else { throw ChinaMarketError.noData }
        return values.values.sorted { $0.date < $1.date }
    }
    static func parseDaily(_ data: Data, security: ChinaSecurity) throws -> [MarketDailyBar] {
        let response = try LongbridgeProto(data)
        guard response.string(1) == security.longbridgeSymbol else { throw ChinaMarketError.invalidData }
        var seen = Set<String>()
        return try response.messages(2).map { row -> MarketDailyBar in
            guard let close = row.number(1), let low = row.number(3), let high = row.number(4),
                  low > 0, high >= low, close >= low, close <= high,
                  let timestamp = row.integer(7), timestamp > 0 else { throw ChinaMarketError.invalidData }
            let date = ChinaSecurity.day(Date(timeIntervalSince1970: Double(timestamp)))
            guard seen.insert(date).inserted else { throw ChinaMarketError.invalidData }
            return .init(date: date, close: close, high: high, low: low, volume: Double(row.integer(5) ?? 0))
        }.sorted { $0.date < $1.date }
    }
}
