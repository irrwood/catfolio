import Foundation

/// Typed, Sendable JSON for the DCA calculator's AI conditions, which arrive
/// as JSON the model wrote and are checked before they are used.
indirect enum PolicyJSON: Codable, Sendable, Equatable {
    case object([String: PolicyJSON]), array([PolicyJSON]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let x = try? value.decode(Bool.self) { self = .bool(x) }
        else if let x = try? value.decode(String.self) { self = .string(x) }
        else if let x = try? value.decode(Double.self) { self = .number(x) }
        else if let x = try? value.decode([String: PolicyJSON].self) { self = .object(x) }
        else { self = .array(try value.decode([PolicyJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let x): try value.encode(x)
        case .array(let x): try value.encode(x)
        case .string(let x): try value.encode(x)
        case .number(let x): try value.encode(x)
        case .bool(let x): try value.encode(x)
        case .null: try value.encodeNil()
        }
    }
    subscript(_ key: String) -> PolicyJSON {
        get { object[key] ?? .null }
        set { var copy = object; copy[key] = newValue; self = .object(copy) }
    }
    var object: [String: PolicyJSON] { if case .object(let x) = self { return x }; return [:] }
    var array: [PolicyJSON] { if case .array(let x) = self { return x }; return [] }
    var string: String { if case .string(let x) = self { return x }; return "" }
    var number: Double? { if case .number(let x) = self { return x }; return nil }
    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    func text() throws -> String { String(decoding: try data(), as: UTF8.self) }
}

struct PolicyContractError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum PolicyTextCodec {
    /// JSONDecoder otherwise silently accepts duplicate keys, losing user data.
    static func rejectDuplicateKeys(_ data: Data) throws {
        let bytes = Array(data)
        var i = 0
        func whitespace() { while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
        func string() throws -> String {
            let start = i
            guard i < bytes.count, bytes[i] == 34 else { throw PolicyContractError(message: L10n.text("JSON 字段名格式错误")) }
            i += 1
            while i < bytes.count {
                if bytes[i] == 92 { i += 2; continue }
                if bytes[i] == 34 {
                    i += 1
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<i]))
                }
                i += 1
            }
            throw PolicyContractError(message: L10n.text("JSON 字符串未结束"))
        }
        func value(_ depth: Int) throws {
            guard depth < 80 else { throw PolicyContractError(message: L10n.text("JSON 嵌套过深")) }
            whitespace()
            guard i < bytes.count else { throw PolicyContractError(message: L10n.text("JSON 不完整")) }
            if bytes[i] == 34 { _ = try string(); return }
            if bytes[i] == 123 {
                i += 1; whitespace()
                var keys = Set<String>()
                while i < bytes.count && bytes[i] != 125 {
                    let key = try string()
                    guard keys.insert(key).inserted else { throw PolicyContractError(message: L10n.text("JSON 字段重复：\(key)")) }
                    whitespace()
                    guard i < bytes.count, bytes[i] == 58 else { throw PolicyContractError(message: L10n.text("JSON 缺少冒号")) }
                    i += 1; try value(depth + 1); whitespace()
                    if i < bytes.count && bytes[i] == 44 { i += 1; whitespace() } else { break }
                }
                guard i < bytes.count, bytes[i] == 125 else { throw PolicyContractError(message: L10n.text("JSON 对象未结束")) }
                i += 1; return
            }
            if bytes[i] == 91 {
                i += 1; whitespace()
                while i < bytes.count && bytes[i] != 93 {
                    try value(depth + 1); whitespace()
                    if i < bytes.count && bytes[i] == 44 { i += 1 } else { break }
                }
                guard i < bytes.count, bytes[i] == 93 else { throw PolicyContractError(message: L10n.text("JSON 数组未结束")) }
                i += 1; return
            }
            while i < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[i]) { i += 1 }
        }
        try value(0)
    }
}
