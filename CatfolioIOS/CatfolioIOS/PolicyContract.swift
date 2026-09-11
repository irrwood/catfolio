import Foundation

/// Typed, Sendable JSON preserves the shared contract without introducing a
/// second set of node fields. Decimal quantities remain decimal strings.
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

/// Evaluates the JSON Schema vocabulary used by the single bundled v1
/// contract. Remote refs are never fetched; unknown schema versions fail.
enum PolicySchemaValidator {
    static func validate(_ value: PolicyJSON, schema: PolicyJSON) throws {
        try check(value, schema: schema, root: schema, path: "$", depth: 0)
    }
    private static func check(_ value: PolicyJSON, schema: PolicyJSON, root: PolicyJSON, path: String, depth: Int) throws {
        guard depth < 100 else { throw PolicyContractError(message: L10n.text("规则嵌套过深")) }
        func fail(_ reason: String) throws { throw PolicyContractError(message: "\(path)：\(reason)") }
        func matches(_ child: PolicyJSON, _ rule: PolicyJSON) -> Bool {
            (try? check(child, schema: rule, root: root, path: path, depth: depth + 1)) != nil
        }
        if schema == .bool(false) { try fail(L10n.text("不允许此值")) }
        if let ref = schema.object["$ref"] {
            guard ref.string.hasPrefix("#/") else { try fail(L10n.text("不支持远程规则引用")); return }
            var resolved = root
            for part in ref.string.dropFirst(2).split(separator: "/") { resolved = resolved[String(part)] }
            guard resolved != .null else { try fail(L10n.text("规则引用不存在")); return }
            try check(value, schema: resolved, root: root, path: path, depth: depth + 1)
        }
        if let constant = schema.object["const"], value != constant { try fail(L10n.text("值不符合契约")) }
        if let choices = schema.object["enum"], !choices.array.contains(value) { try fail(L10n.text("不在允许的选项中")) }
        if let types = schema.object["type"] {
            let names = types.array.isEmpty ? [types.string] : types.array.map(\.string)
            let allowed = names.contains { name in
                switch (name, value) {
                case ("object", .object), ("array", .array), ("string", .string), ("number", .number), ("boolean", .bool), ("null", .null): true
                case ("integer", .number(let n)): n.isFinite && n.rounded() == n
                default: false
                }
            }
            if !allowed { try fail(L10n.text("数据类型错误")) }
        }
        if case .string(let text) = value {
            if let minimum = schema["minLength"].number, text.count < Int(minimum) { try fail(L10n.text("不能为空")) }
            if let pattern = schema.object["pattern"], text.range(of: pattern.string, options: .regularExpression) == nil { try fail(L10n.text("格式不合法")) }
            if schema["format"].string == "date-time", ISO8601DateFormatter().date(from: text) == nil {
                let fractional = ISO8601DateFormatter(); fractional.formatOptions.insert(.withFractionalSeconds)
                if fractional.date(from: text) == nil { try fail(L10n.text("时间格式不合法")) }
            }
        }
        if let n = value.number, let minimum = schema["minimum"].number, n < minimum { try fail(L10n.text("低于允许的最小值")) }
        if case .array(let values) = value {
            if let minimum = schema["minItems"].number, values.count < Int(minimum) { try fail(L10n.text("项目数量不足")) }
            if schema["uniqueItems"] == .bool(true) {
                for i in values.indices where values[..<i].contains(values[i]) { try fail(L10n.text("存在重复项目")) }
            }
            if let item = schema.object["items"] {
                for (i, child) in values.enumerated() { try check(child, schema: item, root: root, path: "\(path)[\(i)]", depth: depth + 1) }
            }
            if let rule = schema.object["contains"], !values.contains(where: { matches($0, rule) }) { try fail(L10n.text("缺少必需项目")) }
        }
        if case .object(let values) = value {
            for required in schema["required"].array where values[required.string] == nil { try fail(L10n.text("缺少 \(required.string)")) }
            for (key, child) in values {
                if let rule = schema["properties"].object[key] {
                    try check(child, schema: rule, root: root, path: "\(path).\(key)", depth: depth + 1)
                } else if let additional = schema.object["additionalProperties"] {
                    try check(child, schema: additional, root: root, path: "\(path).\(key)", depth: depth + 1)
                }
                if let rule = schema.object["propertyNames"] { try check(.string(key), schema: rule, root: root, path: path, depth: depth + 1) }
            }
        }
        if let rules = schema.object["oneOf"], rules.array.filter({ matches(value, $0) }).count != 1 { try fail(L10n.text("不符合任何唯一的规则类型，请检查字段")) }
        for rule in schema["allOf"].array { try check(value, schema: rule, root: root, path: path, depth: depth + 1) }
        if let rule = schema.object["not"], matches(value, rule) { try fail(L10n.text("禁止此字段组合")) }
        if let condition = schema.object["if"] {
            let branch = matches(value, condition) ? "then" : "else"
            if let rule = schema.object[branch] { try check(value, schema: rule, root: root, path: path, depth: depth + 1) }
        }
    }
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
    static func decode(_ text: String, schema: PolicyJSON) throws -> PolicyJSON {
        guard text.utf8.count <= PolicyWorkspaceStore.maximumDraftBytes else { throw PolicyWorkspaceError.oversized }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var cursor = 0
        func skipBlank() { while cursor < lines.count && lines[cursor].trimmingCharacters(in: .whitespaces).isEmpty { cursor += 1 } }
        func fencedJSON() throws -> PolicyJSON {
            skipBlank()
            guard cursor < lines.count, lines[cursor] == "```json" else { throw PolicyContractError(message: L10n.text("第 \(cursor + 1) 行：需要 json 代码块")) }
            cursor += 1
            let start = cursor
            while cursor < lines.count && lines[cursor] != "```" { cursor += 1 }
            guard cursor < lines.count else { throw PolicyContractError(message: L10n.text("JSON 代码块未结束")) }
            let raw = lines[start..<cursor].joined(separator: "\n")
            cursor += 1
            let data = Data(raw.utf8)
            try rejectDuplicateKeys(data)
            return try JSONDecoder().decode(PolicyJSON.self, from: data)
        }
        skipBlank()
        guard cursor < lines.count, lines[cursor] == "# Strategy" else { throw PolicyContractError(message: L10n.text("这是自由草稿。规范策略应以 # Strategy 开始；可先用 AI 整理，再确认。")) }
        cursor += 1
        var document = try fencedJSON()
        guard case .object = document, document.object["nodes"] == nil else { throw PolicyContractError(message: L10n.text("metadata 不能包含 nodes")) }
        var nodes: [PolicyJSON] = []
        skipBlank()
        while cursor < lines.count {
            guard lines[cursor].hasPrefix("## ") else { throw PolicyContractError(message: L10n.text("第 \(cursor + 1) 行：需要节点标题 ## nodeId")) }
            let id = String(lines[cursor].dropFirst(3))
            cursor += 1
            let node = try fencedJSON()
            guard node["nodeId"].string == id else { throw PolicyContractError(message: L10n.text("节点标题与 nodeId 不一致：\(id)")) }
            nodes.append(node)
            skipBlank()
        }
        document["nodes"] = .array(nodes)
        try PolicySchemaValidator.validate(document, schema: schema)
        try checkGraph(document)
        return document
    }

    static func encode(_ document: PolicyJSON) throws -> String {
        var metadata = document.object
        metadata.removeValue(forKey: "nodes")
        var text = "# Strategy\n\n```json\n\(try PolicyJSON.object(metadata).text())\n```\n"
        for node in document["nodes"].array {
            text += "\n## \(node["nodeId"].string)\n\n```json\n\(try node.text())\n```\n"
        }
        return text
    }

    static func checkGraph(_ document: PolicyJSON) throws {
        let nodes = document["nodes"].array
        let ids = nodes.map { $0["nodeId"].string }
        guard Set(ids).count == ids.count else { throw PolicyContractError(message: L10n.text("节点 ID 重复")) }
        let map = Dictionary(uniqueKeysWithValues: zip(ids, nodes))
        var visiting = Set<String>(), visited = Set<String>()
        func walk(_ id: String) throws {
            guard !visiting.contains(id) else { throw PolicyContractError(message: L10n.text("规则存在循环：\(id)")) }
            guard let node = map[id] else { throw PolicyContractError(message: L10n.text("找不到引用的规则：\(id)")) }
            if visited.contains(id) { return }
            visiting.insert(id)
            for edge in node["inputs"].object.values { try walk(edge["nodeId"].string) }
            visiting.remove(id); visited.insert(id)
        }
        for id in ids { try walk(id) }
        for output in document["outputs"].array { try walk(output["nodeId"].string) }
    }
}

actor PolicyContractService {
    static let shared = PolicyContractService()
    private var cachedSchema: PolicyJSON?
    func schema() throws -> PolicyJSON {
        if let cachedSchema { return cachedSchema }
        guard let url = Bundle.main.url(forResource: "strategy.schema", withExtension: "json") else { throw PolicyContractError(message: L10n.text("共享策略契约未包含在此构建中，无法安全编辑或执行")) }
        let schema = try JSONDecoder().decode(PolicyJSON.self, from: Data(contentsOf: url))
        cachedSchema = schema
        return schema
    }
    func parse(_ draft: String) throws -> PolicyJSON { try PolicyTextCodec.decode(draft, schema: schema()) }
    func decodeData(_ data: Data) throws -> PolicyJSON {
        try PolicyTextCodec.rejectDuplicateKeys(data)
        return try JSONDecoder().decode(PolicyJSON.self, from: data)
    }
    func documentData(_ document: PolicyJSON) throws -> Data { try document.data() }
    func schemaText() throws -> String { try schema().text() }
    func changes(original: String, candidate: PolicyJSON) -> String {
        changes(before: try? parse(original), candidate: candidate)
    }
    func changes(before old: PolicyJSON?, candidate: PolicyJSON) -> String {
        var lines: [String] = old == nil ? [L10n.text("原稿不是合法结构文本；下面为新生成的规则，请逐项确认。")] : []
        func walk(_ a: PolicyJSON, _ b: PolicyJSON, _ path: String) {
            guard a != b else { return }
            if !a.object.isEmpty || !b.object.isEmpty {
                for key in Set(a.object.keys).union(b.object.keys).sorted() { walk(a[key], b[key], path + "/" + key) }
            } else {
                lines.append("\(path)\n  \((try? a.text()) ?? "null") → \((try? b.text()) ?? "null")")
            }
        }
        for key in candidate.object.keys.sorted() where key != "nodes" && key != "revision" {
            walk(old?[key] ?? .null, candidate[key], key)
        }
        let previous = (old?["nodes"].array ?? []).reduce(into: [String: PolicyJSON]()) { $0[$1["nodeId"].string] = $1 }
        let next = candidate["nodes"].array.reduce(into: [String: PolicyJSON]()) { $0[$1["nodeId"].string] = $1 }
        for id in Set(previous.keys).union(next.keys).sorted() {
            if previous[id] == nil { lines.append(L10n.text("新增规则 \(id)：\(PolicyTemplates.summary(next[id]!))")) }
            else if next[id] == nil { lines.append(L10n.text("删除规则 \(id)")) }
            else { walk(previous[id]!, next[id]!, L10n.text("规则/") + id) }
        }
        let diagnostics = PolicyCapabilities.diagnostics(candidate)
        if !diagnostics.isEmpty { lines.append(L10n.text("待处理：\n") + diagnostics.map { "\($0.nodeId ?? L10n.text("策略"))：\($0.message)" }.joined(separator: "\n")) }
        return lines.isEmpty ? L10n.text("没有语义变化") : lines.joined(separator: "\n\n")
    }
    func validateRun(_ artifact: PolicyJSON) throws {
        let contract = try schema()
        try PolicySchemaValidator.validate(artifact, schema: .object(["$ref": .string("#/$defs/runArtifact"), "$defs": contract["$defs"]]))
    }
    func serialize(_ document: PolicyJSON) throws -> String {
        try PolicySchemaValidator.validate(document, schema: schema())
        try PolicyTextCodec.checkGraph(document)
        return try PolicyTextCodec.encode(document)
    }
}
