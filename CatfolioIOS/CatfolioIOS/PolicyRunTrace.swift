import Foundation

/// A finished (or running) strategy read backwards into cause and effect:
/// what each step did to the list, which securities came out the end, and for
/// every one that did not, the step that let it go and why.
struct PolicyRunTrace: Sendable {
    enum StepState: Sendable {
        case waiting, running, done, incomplete, skipped, failed
    }

    struct StepOutcome: Sendable {
        let state: StepState
        /// Short, for the corner of the card: "36 → 9".
        let headline: String?
        /// A sentence, when the step has something to say: an AI summary,
        /// or why a proposal was blocked.
        let detail: String?
    }

    struct Row: Identifiable, Sendable {
        let key: String
        let symbol: String
        let name: String
        let value: String?
        /// What each step found for this security, in order.
        let trail: [String]
        var id: String { key }
    }

    struct Group: Identifiable, Sendable {
        let id: String
        let step: Int
        let title: String
        let rows: [Row]
        /// For a result that is a sentence rather than a list.
        let text: String?
    }

    struct Excluded: Identifiable, Sendable {
        let key: String
        let symbol: String
        let name: String
        let step: Int
        let reason: String
        var id: String { key }
    }

    let status: String
    let outcomes: [String: StepOutcome]
    let groups: [Group]
    let excluded: [Excluded]
    let revision: Int
    let notice: String?
    /// The last complete trading day the prices came from.
    let dataDate: String?

    var isFinished: Bool { ["SUCCEEDED", "INCOMPLETE", "FAILED", "CANCELLED"].contains(status) }
    var isActive: Bool { ["RUNNING", "QUEUED"].contains(status) }

    init(record: PolicyRunRecord) {
        let strategy = record.strategy
        let nodes = strategy["nodes"].array
        let outputs = record.outputs
        let securities = Dictionary(record.securities.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        status = record.artifact["status"].string
        revision = Int(strategy["revision"].number ?? 0)
        notice = record.notice
        dataDate = record.securities.compactMap { $0.prices.last?.day }.max()

        func value(_ nodeID: String, _ port: String) -> PolicyRuntimeValue? { outputs[nodeID + "." + port] }
        func input(_ node: PolicyJSON, _ name: String) -> PolicyRuntimeValue? {
            let edge = node["inputs"][name]
            return outputs[edge["nodeId"].string + "." + edge["port"].string]
        }
        func symbol(_ key: String) -> String { securities[key]?.symbol ?? key.components(separatedBy: ":").last ?? key }
        func name(_ key: String) -> String { securities[key]?.name ?? "" }
        func metric(of node: PolicyJSON, input name: String) -> String {
            let indicator = nodes.first { $0["nodeId"] == node["inputs"][name]["nodeId"] }
            return PolicyShortcut.metricName(indicator?["params"]["metric"].string ?? "")
        }

        let stepStates = record.artifact["steps"].array.reduce(into: [String: String]()) {
            $0[$1["nodeId"].string] = $1["status"].string
        }

        var outcomes: [String: StepOutcome] = [:]
        for node in nodes {
            let id = node["nodeId"].string
            let state: StepState = switch stepStates[id] {
            case "RUNNING": .running
            case "SUCCEEDED": .done
            case "UNKNOWN": .incomplete
            case "SKIPPED": .skipped
            case "FAILED", "CANCELLED": .failed
            default: .waiting
            }
            var headline: String?
            var detail: String?
            switch node["type"].string {
            case "source":
                if let universe = value(id, "universe") { headline = L10n.text("\(universe.universe.count) 只") }
            case "indicator":
                if let values = value(id, "value") {
                    let missing = values.universe.filter { values.values[$0] == nil }.count
                    headline = missing == 0
                        ? L10n.text("\(values.universe.count) 只已算出")
                        : L10n.text("\(values.universe.count - missing) 只已算出 · \(missing) 只缺数据")
                }
            case "filter", "sort":
                if let before = input(node, "universe"), let after = value(id, "universe") {
                    headline = "\(before.universe.count) → \(after.universe.count)"
                }
            case "any", "all":
                if let predicate = value(id, "predicate") {
                    let passed = predicate.universe.filter { predicate.predicates[$0] == .yes }.count
                    headline = L10n.text("\(passed) 只成立")
                }
            case "if":
                if let then = value(id, "then"), let otherwise = value(id, "else") {
                    let unknown = value(id, "unknown")?.universe.count ?? 0
                    headline = L10n.text("成立 \(then.universe.count) · 不成立 \(otherwise.universe.count)")
                        + (unknown > 0 ? L10n.text(" · 未知 \(unknown)") : "")
                }
            case "size":
                if let proposal = value(id, "proposal") {
                    headline = proposal.values.isEmpty ? L10n.text("未生成目标") : L10n.text("\(proposal.values.count) 只有目标")
                    detail = proposal.reasons["budget"] ?? proposal.reasons.values.sorted().first
                }
            case "risk":
                if let predicate = value(id, "predicate") {
                    let weight = predicate.values["max_position_weight"].map { String(format: "%.1f%%", $0) }
                    let verdict = switch predicate.predicates["scalar"] {
                    case .yes?: L10n.text("通过")
                    case .no?: L10n.text("不通过")
                    default: L10n.text("无法判断")
                    }
                    headline = weight.map { L10n.text("最大仓位 \($0) · \(verdict)") } ?? verdict
                    detail = predicate.reasons["risk"]
                }
            case "guard":
                if let proposal = value(id, "proposal") {
                    headline = proposal.reasons["guard"] == nil ? L10n.text("已放行") : L10n.text("已阻断")
                    detail = proposal.reasons["guard"]
                }
            case "ai":
                if let thesis = value(id, "thesis") {
                    let summary = thesis.payload?["answer"]["summary"].string ?? ""
                    headline = summary.isEmpty ? L10n.text("没有摘要") : L10n.text("已生成摘要")
                    detail = summary.isEmpty ? thesis.reasons["ai"] : summary
                }
            default:
                break
            }
            if state == .skipped { headline = L10n.text("未用到") }
            outcomes[id] = StepOutcome(state: state, headline: headline, detail: detail)
        }
        self.outcomes = outcomes

        // What every step found for one security, as it went down the list.
        func trail(for key: String) -> [String] {
            nodes.compactMap { node -> String? in
                let id = node["nodeId"].string
                switch node["type"].string {
                case "indicator":
                    guard let values = value(id, "value"), values.universe.contains(key) else { return nil }
                    let name = PolicyShortcut.metricName(node["params"]["metric"].string)
                    guard let number = values.values[key] else { return L10n.text("\(name)：缺数据") }
                    return name + " " + Self.format(number, unit: values.unit)
                case "filter":
                    guard let predicate = value(id, "predicate"), predicate.predicates[key] == .yes else { return nil }
                    return L10n.text("满足 \(Self.comparison(node["params"]["comparison"].string)) \(PolicyShortcut.display(node["params"]["threshold"]) ?? "")")
                case "sort":
                    guard let sorted = value(id, "universe"), let rank = sorted.universe.firstIndex(of: key) else { return nil }
                    return L10n.text("按\(metric(of: node, input: "value"))排第 \(rank + 1)")
                case "if":
                    if value(id, "then")?.universe.contains(key) == true { return L10n.text("条件成立") }
                    if value(id, "else")?.universe.contains(key) == true { return L10n.text("条件不成立") }
                    return nil
                case "size":
                    guard let target = value(id, "proposal")?.values[key] else { return nil }
                    return L10n.text("目标 \(Self.format(target, unit: "CURRENCY"))")
                default:
                    return nil
                }
            }
        }

        // The figure a row leads with: whatever the last step to rank or
        // filter it compared.
        func headlineValue(for key: String) -> String? {
            for node in nodes.reversed() where ["sort", "filter"].contains(node["type"].string) {
                if let values = input(node, "value"), let number = values.values[key] {
                    return Self.format(number, unit: values.unit)
                }
            }
            for node in nodes.reversed() where node["type"].string == "indicator" {
                if let values = value(node["nodeId"].string, "value"), let number = values.values[key] {
                    return Self.format(number, unit: values.unit)
                }
            }
            return nil
        }

        var groups: [Group] = []
        let index = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1["nodeId"].string, $0) })
        let delivered = strategy["outputs"].array.sorted {
            (index[$0["nodeId"].string] ?? 0) > (index[$1["nodeId"].string] ?? 0)
        }
        for edge in delivered {
            let id = edge["nodeId"].string, port = edge["port"].string
            guard let result = value(id, port), let step = index[id], let node = nodes.first(where: { $0["nodeId"].string == id }) else { continue }
            let title = PolicyShortcut.variableName(nodeType: node["type"].string, port: port, node: node)
            var rows: [Row] = []
            var text: String?
            switch result.kind {
            case "universe", "unknownUniverse":
                rows = result.universe.map { Row(key: $0, symbol: symbol($0), name: name($0), value: headlineValue(for: $0), trail: trail(for: $0)) }
            case "values":
                rows = result.universe.map { key in
                    Row(key: key, symbol: symbol(key), name: name(key),
                        value: result.values[key].map { Self.format($0, unit: result.unit) } ?? L10n.text("缺数据"),
                        trail: result.reasons[key].map { [$0] } ?? [])
                }
            case "predicates":
                rows = result.universe.filter { result.predicates[$0] == .yes }
                    .map { Row(key: $0, symbol: symbol($0), name: name($0), value: headlineValue(for: $0), trail: trail(for: $0)) }
            case "proposal":
                rows = result.universe.map { key in
                    Row(key: key, symbol: symbol(key), name: name(key),
                        value: result.values[key].map { Self.format($0, unit: "CURRENCY") },
                        trail: trail(for: key))
                }
                if result.values.isEmpty { text = result.reasons["guard"] ?? result.reasons["budget"] ?? result.reasons.values.sorted().first }
            case "scalarPredicate":
                text = outcomes[id]?.headline
            case "thesis":
                text = result.payload?["answer"]["summary"].string ?? result.reasons["ai"]
            default:
                text = outcomes[id]?.headline
            }
            groups.append(Group(id: id + "." + port, step: step + 1, title: title, rows: rows, text: text))
        }
        self.groups = groups

        // Everyone who started and is not in the leading result, with the
        // step that let them go.
        var excluded: [Excluded] = []
        if let lead = groups.first, !lead.rows.isEmpty || lead.text == nil {
            let kept = Set(lead.rows.map(\.key))
            let started = nodes.filter { $0["type"].string == "source" }
                .flatMap { value($0["nodeId"].string, "universe")?.universe ?? [] }
            var seen = Set<String>()
            for key in started where !kept.contains(key) && seen.insert(key).inserted {
                for (step, node) in nodes.enumerated() {
                    let id = node["nodeId"].string
                    guard let before = input(node, "universe"), before.universe.contains(key) else { continue }
                    var reason: String?
                    switch node["type"].string {
                    case "filter":
                        guard value(id, "universe")?.universe.contains(key) == false else { continue }
                        let predicate = value(id, "predicate")
                        let values = input(node, "value")
                        let threshold = "\(Self.comparison(node["params"]["comparison"].string)) \(PolicyShortcut.display(node["params"]["threshold"]) ?? "")"
                        if predicate?.predicates[key] == .no, let number = values?.values[key] {
                            reason = L10n.text("\(metric(of: node, input: "value")) \(Self.format(number, unit: values?.unit ?? ""))，不满足 \(threshold)")
                        } else {
                            reason = predicate?.reasons[key] ?? values?.reasons[key] ?? L10n.text("数据不足，无法判断")
                        }
                    case "sort":
                        guard let after = value(id, "universe"), !after.universe.contains(key) else { continue }
                        let values = input(node, "value")
                        if values?.values[key] == nil {
                            reason = L10n.text("缺少\(metric(of: node, input: "value"))数据，没有参与排序")
                        } else {
                            let descending = node["params"]["direction"].string == "DESC"
                            let ranked = before.universe.filter { values?.values[$0] != nil }.sorted {
                                let a = values?.values[$0] ?? 0, b = values?.values[$1] ?? 0
                                return a == b ? $0 < $1 : (descending ? a > b : a < b)
                            }
                            let rank = (ranked.firstIndex(of: key) ?? ranked.count) + 1
                            reason = L10n.text("按\(metric(of: node, input: "value"))排第 \(rank)，只保留前 \(after.universe.count)")
                        }
                    case "if":
                        if value(id, "else")?.universe.contains(key) == true { reason = L10n.text("条件不成立") }
                        else if value(id, "unknown")?.universe.contains(key) == true { reason = L10n.text("条件无法判断") }
                        else { continue }
                    default:
                        continue
                    }
                    if let reason {
                        excluded.append(Excluded(key: key, symbol: symbol(key), name: name(key), step: step + 1, reason: reason))
                    }
                    break
                }
            }
        }
        self.excluded = excluded.sorted { $0.step == $1.step ? $0.symbol < $1.symbol : $0.step < $1.step }
    }

    static func format(_ value: Double, unit: String) -> String {
        switch unit {
        case "PERCENT": String(format: "%.1f%%", value)
        case "PRICE", "CURRENCY": "$" + value.formatted(.number.precision(.fractionLength(2)))
        case "SCORE": String(format: "%.1f", value)
        default: value.formatted(.number.precision(.fractionLength(0...2)))
        }
    }

    static func comparison(_ code: String) -> String {
        ["GTE": "≥", "GT": ">", "LTE": "≤", "LT": "<", "EQ": "=", "NE": "≠"][code] ?? code
    }
}
