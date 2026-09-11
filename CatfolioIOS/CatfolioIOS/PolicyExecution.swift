import Foundation

/// Bounded, reviewed exchange schedule, not an inferred calendar from missing
/// price bars. Exceptional closures remain missing-data diagnostics. Sources
/// reviewed 2026-09-10: nasdaqtrader.com/trader.aspx?id=Calendar and
/// nyse.com/trade/hours-calendars. No extrapolation beyond 2026.
enum PolicyUSSessionCalendar {
    static let sources = "https://www.nasdaqtrader.com/trader.aspx?id=Calendar ; https://www.nyse.com/trade/hours-calendars ; reviewed 2026-09-10"
    static func completedSessions(asOf: Date) throws -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        guard calendar.component(.year, from: asOf) == 2026 else { throw PolicyContractError(message: L10n.text("交易日历仅覆盖2026年，不能外推")) }
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let closed: Set<String> = ["2026-01-01", "2026-01-19", "2026-02-16", "2026-04-03", "2026-05-25", "2026-06-19", "2026-07-03", "2026-09-07", "2026-11-26", "2026-12-25"]
        let early: Set<String> = ["2026-11-27", "2026-12-24"]
        var day = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        var result: [String] = []
        while day <= asOf {
            let key = formatter.string(from: day)
            let weekday = calendar.component(.weekday, from: day)
            if weekday != 1 && weekday != 7 && !closed.contains(key),
               let close = calendar.date(bySettingHour: early.contains(key) ? 13 : 16, minute: 0, second: 0, of: day), close <= asOf { result.append(key) }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return result
    }
}

enum PolicyTruth: String, Codable, Sendable {
    case yes = "TRUE", no = "FALSE", unknown = "UNKNOWN"
    static func any(_ values: [PolicyTruth]) -> PolicyTruth {
        values.contains(.yes) ? .yes : (values.allSatisfy { $0 == .no } ? .no : .unknown)
    }
    static func all(_ values: [PolicyTruth]) -> PolicyTruth {
        values.contains(.no) ? .no : (values.allSatisfy { $0 == .yes } ? .yes : .unknown)
    }
}

struct PolicyDiagnostic: Codable, Sendable {
    let code: String
    let message: String
    let nodeId: String?
    let pointer: String
}

/// Separate from structural JSON validation: supports only implemented,
/// tested operations. A valid but unsupported node is never silently skipped.
enum PolicyCapabilities {
    static let ports: [String: [String: String]] = [
        "source": ["universe": "universe"], "indicator": ["value": "values"],
        "filter": ["universe": "universe", "predicate": "predicates"],
        "any": ["predicate": "predicates"], "all": ["predicate": "predicates"],
        "if": ["then": "universe", "else": "universe", "unknown": "unknownUniverse"],
        "sort": ["universe": "universe"], "size": ["proposal": "proposal"],
        "risk": ["predicate": "scalarPredicate"], "guard": ["proposal": "proposal"],
        "ai": ["thesis": "thesis"], "state": ["value": "stateValue", "delta": "delta"]
    ]
    static func diagnostics(_ document: PolicyJSON) -> [PolicyDiagnostic] {
        var result: [PolicyDiagnostic] = []
        func add(_ code: String, _ text: String, _ node: String? = nil, _ pointer: String = "") {
            result.append(.init(code: code, message: text, nodeId: node, pointer: pointer))
        }
        let nodes = document["nodes"].array
        let map = nodes.reduce(into: [String: PolicyJSON]()) { $0[$1["nodeId"].string] = $1 }
        if nodes.isEmpty { add("EMPTY_GRAPH", L10n.text("请添加规则")) }
        if document["outputs"].array.isEmpty { add("NO_OUTPUTS", L10n.text("请选择需要交付的输出")) }
        if document["accountScope"]["accountIds"].array.isEmpty { add("UNRESOLVED", L10n.text("请选择账户")) }
        func unresolved(_ value: PolicyJSON, path: String, node: String?) {
            if value["state"].string == "UNRESOLVED" { add("UNRESOLVED", value["reason"].string, node, path) }
            for (key, child) in value.object { unresolved(child, path: path + "/" + key, node: node) }
            for (index, child) in value.array.enumerated() { unresolved(child, path: path + "/\(index)", node: node) }
        }
        unresolved(document["dataPolicy"], path: "/dataPolicy", node: nil)
        let maxAge = document["dataPolicy"]["maxAgeDays"]
        if maxAge["state"].string == "RESOLVED", !integer(maxAge, unit: "DAYS", minimum: 0) { add("INVALID", L10n.text("允许陈旧天数必须是非负整数 DAYS")) }
        if document["dataPolicy"]["priceBasis"].string != "SPLIT_ADJUSTED" { add("UNSUPPORTED", L10n.text("当前数据适配仅支持拆股复权收盘价，不会替换价格口径")) }
        if document["statePolicy"]["initialSnapshotId"] != .null { add("UNSUPPORTED", L10n.text("尚未导入此模拟初始快照，不能代替为空状态")) }
        for (index, node) in nodes.enumerated() {
            let id = node["nodeId"].string, type = node["type"].string, p = node["params"]
            unresolved(p, path: "/nodes/\(index)/params", node: id)
            var expected: [String: String]
            switch type {
            case "source": expected = [:]
            case "indicator", "ai", "size": expected = ["universe": "universe"]
            case "filter", "sort": expected = ["universe": "universe", "value": "values"]
            case "if": expected = ["universe": "universe", "condition": "predicates"]
            case "risk": expected = ["proposal": "proposal"]
            case "guard": expected = ["proposal": "proposal", "condition": "scalarPredicate"]
            case "state": expected = p["operation"].string == "READ" ? [:] : ["condition": "scalarPredicate"]
            case "any", "all":
                let count = node["inputs"].object.count
                expected = count > 0 ? Dictionary(uniqueKeysWithValues: (1...count).map { ("p\($0)", "predicates") }) : [:]
                if count < 2 { add("INVALID", L10n.text("任一/全部需要至少两个条件"), id) }
            default: expected = [:]
            }
            if Set(node["inputs"].object.keys) != Set(expected.keys) { add("INVALID", L10n.text("输入端口与规则类型不匹配"), id) }
            for (key, edge) in node["inputs"].object {
                let parent = map[edge["nodeId"].string]
                let actual = ports[parent?["type"].string ?? ""]?[edge["port"].string]
                if actual == nil || actual != expected[key] { add("INVALID", L10n.text("\(key) 引用了不兼容的输出端口"), id) }
            }
            switch type {
            case "source":
                if p["operation"].string == "SELECTED_HOLDINGS" && !p["securities"].array.isEmpty { add("INVALID", L10n.text("当前持仓来源不能附加指定证券"), id) }
                if p["operation"].string == "EXPLICIT_SECURITIES" && p["securities"].array.isEmpty { add("UNRESOLVED", L10n.text("指定证券列表不能为空"), id) }
            case "indicator":
                let metric = p["metric"].string
                let units = ["price": "PRICE", "return": "PERCENT", "sma": "PRICE", "rsi": "SCORE", "volatility": "PERCENT"]
                if units[metric] == nil || p["methodologyVersion"].string != "1" { add("UNSUPPORTED", L10n.text("指标 \(metric)/\(p["methodologyVersion"].string) 尚未适配"), id) }
                if let unit = units[metric], p["outputUnit"].string != unit { add("INVALID", L10n.text("指标输出单位应为 \(unit)"), id) }
                if metric == "price" {
                    if p["window"] != .null { add("INVALID", L10n.text("完整日线价格不接受计算窗口"), id) }
                } else {
                    if p["window"]["calendar"].string != "TRADING_SESSIONS" { add("UNSUPPORTED", L10n.text("此指标仅支持交易日窗口"), id) }
                    let length = p["window"]["length"]
                    if length["state"].string == "RESOLVED", !integer(length, unit: "SESSIONS", minimum: metric == "volatility" ? 2 : 1) { add("INVALID", L10n.text("指标窗口应为有效整数 SESSIONS"), id) }
                    if let n = Double(length["value"].string), n > 250 { add("UNSUPPORTED", L10n.text("当前历史适配最多支持250个交易日窗口"), id) }
                }
            case "sort":
                let limit = p["limit"]
                if limit["state"].string == "RESOLVED", !integer(limit, unit: "COUNT", minimum: 1) { add("INVALID", L10n.text("最多保留必须为正整数 COUNT"), id) }
            case "size":
                let operation = p["operation"].string, q = p["value"], lot = p["lotSize"]
                let unit = operation == "TARGET_WEIGHT" ? "PERCENT" : (operation == "FIXED_AMOUNT" ? "CURRENCY" : "SHARES")
                if q["state"].string == "RESOLVED", q["unit"].string != unit || (Double(q["value"].string) ?? -1) < 0 || (operation == "TARGET_WEIGHT" && (Double(q["value"].string) ?? 101) > 100) { add("INVALID", L10n.text("配置值的单位或范围不正确"), id) }
                if p["denominator"].string != (operation == "TARGET_WEIGHT" ? "NAV" : "NOT_APPLICABLE") { add("UNSUPPORTED", L10n.text("配置分母必须明确为NAV或不适用"), id) }
                if lot["state"].string == "RESOLVED", lot["unit"].string != "SHARES" || (Double(lot["value"].string) ?? 0) <= 0 || (p["rounding"].string == "NONE" && lot["value"].string != "1") { add("INVALID", L10n.text("手数必须为正SHARES；不舍入时显式填1"), id) }
            case "risk":
                if p["metric"].string != "max_position_weight" || p["methodologyVersion"].string != "1" { add("UNSUPPORTED", L10n.text("只注册了最大单证券目标权重/1"), id) }
                if p["threshold"]["state"].string == "RESOLVED", p["threshold"]["unit"].string != "PERCENT" { add("INVALID", L10n.text("风险阈值必须为PERCENT"), id) }
            case "state":
                if document["mode"].string != "SIMULATE" { add("INVALID", L10n.text("模拟状态只允许SIMULATE模式"), id) }
                if p["operation"].string == "READ" && p["value"] != .null { add("INVALID", L10n.text("读取状态的value必须为null"), id) }
                if p["operation"].string == "PROPOSE_SET", nodes.filter({ $0["type"].string == "state" && $0["params"]["operation"].string == "PROPOSE_SET" && $0["params"]["key"] == p["key"] }).count > 1 { add("INVALID", L10n.text("多个节点写同一模拟状态键"), id) }
            case "ai":
                if p["promptTemplateId"].string != "price-evidence-thesis" || p["promptVersion"].string != "1" || p["responseSchemaId"].string != "policy-thesis-1" { add("UNSUPPORTED", L10n.text("AI仅注册price-evidence-thesis/1与policy-thesis-1；不替换未知提示方法"), id) }
            case "filter", "any", "all", "if", "guard": break
            default: add("UNSUPPORTED", L10n.text("\(PolicyTemplates.titles[type] ?? type) 尚未完成执行适配，不能生成假结果"), id)
            }
        }
        for output in document["outputs"].array {
            if ports[map[output["nodeId"].string]?["type"].string ?? ""]?[output["port"].string] == nil { add("INVALID", L10n.text("交付输出端口不存在")) }
        }
        return result
    }
    static func integer(_ quantity: PolicyJSON, unit: String, minimum: Int) -> Bool {
        guard quantity["unit"].string == unit, let n = Double(quantity["value"].string), n.isFinite, n >= Double(minimum), n <= 1_000_000, n.rounded() == n else { return false }
        return true
    }
}

struct PolicyPricePoint: Codable, Sendable { let day: String; let close: Double }
struct PolicySecuritySnapshot: Codable, Sendable {
    let securityId: String
    let listingId: String
    let symbol: String
    let name: String
    let currency: String
    let exchangeMIC: String
    let prices: [PolicyPricePoint]
    let referenceSessions: [String]
    let source: String
    let capturedAt: Date
    let issue: String?
    var key: String { securityId + "/" + listingId }
}

struct PolicyRuntimeValue: Codable, Sendable {
    var kind: String
    var universe: [String] = []
    var values: [String: Double] = [:]
    var predicates: [String: PolicyTruth] = [:]
    var unit: String = ""
    var currencies: [String: String] = [:]
    var reasons: [String: String] = [:]
    var payload: PolicyJSON? = nil
}

/// A complete same-currency NAV/holdings valuation is required. Absence is
/// not zero cash. Production adapters must establish this evidence first.
struct PolicyBudget: Codable, Sendable {
    let nav: Double
    let currency: String
    let existingExposure: [String: Double]
}

enum PolicyExecution {
    static func thesis(raw: String, evidence: [PolicyJSON], universe: [String]) -> PolicyRuntimeValue {
        var result = PolicyRuntimeValue(kind: "thesis", universe: universe)
        var payload = PolicyJSON.object(["status": .string("UNKNOWN"), "rawResponse": .string(raw), "evidence": .array(evidence), "promptVersion": .string("price-evidence-thesis/1"), "model": .string("configured provider; model identity unavailable")])
        do {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = trimmed.hasPrefix("```json\n") && trimmed.hasSuffix("```") ? String(trimmed.dropFirst(8).dropLast(3)) : trimmed
            let data = Data(text.utf8)
            try PolicyTextCodec.rejectDuplicateKeys(data)
            let answer = try JSONDecoder().decode(PolicyJSON.self, from: data)
            let citations = answer["citations"].array.map(\.string)
            guard !answer["summary"].string.isEmpty, !citations.isEmpty, Set(citations).isSubset(of: Set(evidence.map { $0["id"].string })), Set(answer.object.keys) == ["summary", "citations"] else { throw PolicyContractError(message: L10n.text("AI格式或引用不合法")) }
            payload["status"] = .string("CANDIDATE_REQUIRES_CONFIRMATION")
            payload["answer"] = answer
        } catch { result.reasons["ai"] = error.localizedDescription }
        result.payload = payload
        return result
    }
    static func indicator(metric: String, closes: [Double], window: Int) -> Double? {
        let required = metric == "price" ? 1 : (metric == "sma" ? window : window + 1)
        guard window >= 0, required > 0, closes.count >= required else { return nil }
        let values = Array(closes.suffix(required))
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        if metric == "price" { return values.last }
        if metric == "sma" { return values.reduce(0, +) / Double(window) }
        if metric == "return" { return 100 * (values.last! / values.first! - 1) }
        if metric == "rsi" {
            let differences = zip(values.dropFirst(), values).map(-)
            let up = differences.reduce(0) { $0 + max(0, $1) }
            let down = differences.reduce(0) { $0 + max(0, -$1) }
            if up == 0 && down == 0 { return 50 }
            return down == 0 ? 100 : 100 - 100 / (1 + up / down)
        }
        if metric == "volatility", window >= 2 {
            let returns = zip(values.dropFirst(), values).map { log($0 / $1) }
            let mean = returns.reduce(0, +) / Double(window)
            return sqrt(returns.reduce(0) { $0 + pow($1 - mean, 2) } / Double(window - 1)) * sqrt(252) * 100
        }
        return nil
    }
    static func compare(_ value: Double?, to threshold: Double, operation: String) -> PolicyTruth {
        guard let value, value.isFinite, threshold.isFinite else { return .unknown }
        switch operation {
        case "LT": return value < threshold ? .yes : .no
        case "LTE": return value <= threshold ? .yes : .no
        case "EQ": return value == threshold ? .yes : .no
        case "GTE": return value >= threshold ? .yes : .no
        case "GT": return value > threshold ? .yes : .no
        case "NE": return value != threshold ? .yes : .no
        default: return .unknown
        }
    }

    static func evaluate(node: PolicyJSON, document: PolicyJSON, snapshots: [PolicySecuritySnapshot], outputs: [String: PolicyRuntimeValue], budget: PolicyBudget? = nil) throws -> [String: PolicyRuntimeValue] {
        let p = node["params"], type = node["type"].string
        func input(_ name: String) throws -> PolicyRuntimeValue {
            let edge = node["inputs"][name]
            guard let value = outputs[edge["nodeId"].string + "." + edge["port"].string] else { throw PolicyContractError(message: L10n.text("前置规则没有产生 \(name)")) }
            return value
        }
        switch type {
        case "size":
            let universe = try input("universe").universe
            var proposal = PolicyRuntimeValue(kind: "proposal", universe: universe, unit: "CURRENCY")
            guard let budget, budget.nav.isFinite, budget.nav > 0, budget.existingExposure.values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
                proposal.reasons["budget"] = L10n.text("缺少包含现金的完整NAV及同币种持仓估值；不能用持仓市值冒充账户预算")
                return ["proposal": proposal]
            }
            var exposure = budget.existingExposure
            for key in universe {
                guard let snapshot = snapshots.first(where: { $0.key == key }), snapshot.issue == nil, snapshot.currency == budget.currency, let price = snapshot.prices.last?.close, price > 0, let amount = Double(p["value"]["value"].string), amount.isFinite, amount >= 0 else { proposal.reasons[key] = L10n.text("价格、币种或目标值不完整"); continue }
                var target: Double
                switch p["operation"].string {
                case "TARGET_WEIGHT": target = budget.nav * amount / 100
                case "FIXED_SHARES": target = price * amount
                case "FIXED_AMOUNT":
                    guard p["value"]["currency"].string == budget.currency else { proposal.reasons[key] = L10n.text("目标金额币种不匹配，未隐式换汇"); continue }
                    target = amount
                default: throw PolicyContractError(message: L10n.text("未知配置方法"))
                }
                if p["rounding"].string == "DOWN_TO_LOT" {
                    guard let lot = Double(p["lotSize"]["value"].string), lot > 0 else { proposal.reasons[key] = L10n.text("手数未知"); continue }
                    target = floor(target / price / lot) * lot * price
                }
                guard target.isFinite else { proposal.reasons[key] = L10n.text("目标数值溢出"); continue }
                exposure[key] = target
                proposal.values[key] = target; proposal.currencies[key] = budget.currency
            }
            if exposure.values.reduce(0, +) > budget.nav { proposal.reasons["budget"] = L10n.text("目标配置与未调整资产超过NAV；不会自动归一化或卖出其他资产") }
            if !proposal.reasons.isEmpty { proposal.values = [:] }
            return ["proposal": proposal]
        case "risk":
            let proposal = try input("proposal")
            var result = PolicyRuntimeValue(kind: "scalarPredicate", predicates: ["scalar": .unknown])
            guard proposal.reasons.isEmpty, let budget, budget.nav > 0, budget.nav.isFinite, let threshold = Double(p["threshold"]["value"].string) else { result.reasons["risk"] = L10n.text("提案或完整NAV缺失，风险不能判为安全"); return ["predicate": result] }
            var exposure = budget.existingExposure
            for (key, value) in proposal.values { exposure[key] = value }
            let weight = (exposure.values.max() ?? 0) / budget.nav * 100
            result.values["max_position_weight"] = weight; result.unit = "PERCENT"
            result.predicates["scalar"] = compare(weight, to: threshold, operation: p["comparison"].string)
            return ["predicate": result]
        case "guard":
            let condition = try input("condition"), proposal = try input("proposal")
            guard condition.predicates["scalar"] == .yes, proposal.reasons.isEmpty else {
                return ["proposal": .init(kind: "proposal", reasons: ["guard": condition.predicates["scalar"] == .no ? L10n.text("风险条件不通过，已阻断") : L10n.text("风险未知或提案不完整，已阻断")])]
            }
            return ["proposal": proposal]
        case "state":
            if p["operation"].string == "READ" {
                return ["value": .init(kind: "stateValue", reasons: [p["key"].string: L10n.text("明确为空的初始模拟状态中不存在此键；没有默认为false")], payload: .null)]
            }
            let condition = try input("condition")
            if condition.predicates["scalar"] == .yes {
                return ["delta": .init(kind: "delta", payload: .object(["key": p["key"], "value": p["value"], "strategyId": document["strategyId"], "initialSnapshotId": document["statePolicy"]["initialSnapshotId"], "policy": .string("RETURN_DELTA_ONLY")]))]
            }
            return ["delta": .init(kind: "delta", reasons: condition.predicates["scalar"] == .no ? [:] : ["state": L10n.text("条件未知，未提出状态更改")], payload: .null)]
        case "source":
            let keys: [String]
            if p["operation"].string == "SELECTED_HOLDINGS" { keys = snapshots.map(\.key).sorted() }
            else {
                keys = p["securities"].array.map { $0["securityId"].string + "/" + $0["listingId"].string }
                guard Set(keys).count == keys.count, Set(keys).isSubset(of: Set(snapshots.map(\.key))) else { throw PolicyContractError(message: L10n.text("指定证券尚未获得唯一挂牌映射；不会按裸代码猜测")) }
            }
            return ["universe": .init(kind: "universe", universe: keys)]
        case "indicator":
            let universe = try input("universe").universe
            var value = PolicyRuntimeValue(kind: "values", universe: universe, unit: p["outputUnit"].string)
            let length = Int(p["window"]["length"]["value"].string) ?? 0
            for key in universe {
                guard let snapshot = snapshots.first(where: { $0.key == key }) else { value.reasons[key] = L10n.text("证券输入缺失"); continue }
                value.currencies[key] = snapshot.currency
                if let issue = snapshot.issue { value.reasons[key] = issue; continue }
                let mic = p["window"]["exchangeMIC"].string
                if !mic.isEmpty && mic != snapshot.exchangeMIC { value.reasons[key] = L10n.text("交易所与窗口日历不匹配"); continue }
                let required = p["metric"].string == "price" ? 1 : (p["metric"].string == "sma" ? length : length + 1)
                let suffix = Array(snapshot.prices.suffix(required))
                let expected = Array(snapshot.referenceSessions.suffix(required))
                guard expected.count == required, suffix.map(\.day) == expected else { value.reasons[key] = L10n.text("历史长度不足或交易日存在缺口"); continue }
                if let calculated = indicator(metric: p["metric"].string, closes: suffix.map(\.close), window: length), calculated.isFinite { value.values[key] = calculated }
                else { value.reasons[key] = L10n.text("指标无法计算") }
            }
            return ["value": value]
        case "filter":
            let universe = try input("universe").universe, values = try input("value")
            guard Set(universe).isSubset(of: Set(values.universe)), p["threshold"]["unit"].string == values.unit, let threshold = Double(p["threshold"]["value"].string) else { throw PolicyContractError(message: L10n.text("筛选条件与指标的单位或证券范围不匹配")) }
            var predicate = PolicyRuntimeValue(kind: "predicates", universe: universe)
            for key in universe {
                if ["PRICE", "CURRENCY"].contains(values.unit), p["threshold"]["currency"].string != values.currencies[key] { predicate.predicates[key] = .unknown; predicate.reasons[key] = L10n.text("币种不匹配，未隐式换汇") }
                else { predicate.predicates[key] = compare(values.values[key], to: threshold, operation: p["comparison"].string); if let reason = values.reasons[key] { predicate.reasons[key] = reason } }
            }
            return ["predicate": predicate, "universe": .init(kind: "universe", universe: universe.filter { predicate.predicates[$0] == .yes }, reasons: predicate.reasons)]
        case "any", "all":
            let inputs = try node["inputs"].object.keys.sorted().map(input)
            guard let first = inputs.first, inputs.allSatisfy({ Set($0.universe) == Set(first.universe) }) else { throw PolicyContractError(message: L10n.text("条件宇宙不一致，不能隐式合并")) }
            var result = PolicyRuntimeValue(kind: "predicates", universe: first.universe)
            for key in first.universe {
                let values = inputs.map { $0.predicates[key] ?? .unknown }
                result.predicates[key] = type == "any" ? .any(values) : .all(values)
                if result.predicates[key] == .unknown { result.reasons[key] = L10n.text("条件数据不足") }
            }
            return ["predicate": result]
        case "if":
            let universe = try input("universe").universe, condition = try input("condition")
            guard Set(universe) == Set(condition.universe) else { throw PolicyContractError(message: L10n.text("条件分支证券范围不一致")) }
            return Dictionary(uniqueKeysWithValues: [("then", PolicyTruth.yes), ("else", .no), ("unknown", .unknown)].map { port, truth in
                (port, PolicyRuntimeValue(kind: port == "unknown" ? "unknownUniverse" : "universe", universe: universe.filter { (condition.predicates[$0] ?? .unknown) == truth }))
            })
        case "sort":
            let universe = try input("universe").universe, values = try input("value")
            guard Set(universe).isSubset(of: Set(values.universe)), let limit = Int(p["limit"]["value"].string), limit > 0 else { throw PolicyContractError(message: L10n.text("排序范围或数量错误")) }
            let sorted = universe.filter { values.values[$0] != nil || p["nullPolicy"].string == "LAST" }.sorted { a, b in
                switch (values.values[a], values.values[b]) {
                case (nil, nil): a < b
                case (nil, _): false
                case (_, nil): true
                case (let x?, let y?): x == y ? a < b : (p["direction"].string == "DESC" ? x > y : x < y)
                }
            }
            return ["universe": .init(kind: "universe", universe: Array(sorted.prefix(limit)), reasons: values.reasons)]
        default: throw PolicyContractError(message: L10n.text("尚不支持执行 \(type)"))
        }
    }
}
