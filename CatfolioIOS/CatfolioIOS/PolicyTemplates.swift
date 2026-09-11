import Foundation

enum PolicyTemplates {
    static var titles: [String: String] { ["source": L10n.text("选择证券"), "indicator": L10n.text("计算指标"), "filter": L10n.text("筛选条件"), "any": L10n.text("满足任一条件"), "all": L10n.text("满足全部条件"), "if": L10n.text("条件分支"), "sort": L10n.text("排序"), "size": L10n.text("目标配置"), "risk": L10n.text("风险检查"), "guard": L10n.text("执行保护"), "ai": L10n.text("AI 研究"), "state": L10n.text("模拟状态")] }
    static func summary(_ node: PolicyJSON) -> String {
        let p = node["params"]
        func quantity(_ q: PolicyJSON) -> String {
            if q["state"].string == "UNRESOLVED" { return L10n.text("待确认：") + q["reason"].string }
            let units = ["SESSIONS": L10n.text("个交易日"), "PERCENT": "%", "DAYS": L10n.text("天"), "COUNT": L10n.text("项"), "SHARES": L10n.text("股"), "SCORE": L10n.text("分")]
            return q["value"].string + (units[q["unit"].string] ?? q["unit"].string) + " " + q["currency"].string
        }
        switch node["type"].string {
        case "source": return p["operation"].string == "SELECTED_HOLDINGS" ? L10n.text("使用已确认账户中的当前持仓") : L10n.text("仅分析指定的 \(p["securities"].array.count) 个挂牌证券")
        case "indicator":
            let metrics = ["return": L10n.text("区间涨跌幅"), "price": L10n.text("完整日线收盘价"), "sma": L10n.text("简单移动平均"), "rsi": L10n.text("Cutler RSI（非 Wilder）"), "volatility": L10n.text("年化波动率（对数收益，252日）"), "volume": L10n.text("完整日线成交股数")]
            return (metrics[p["metric"].string] ?? p["metric"].string) + (p["window"] == .null ? "" : L10n.text("\n窗口：") + quantity(p["window"]["length"]))
        case "filter": return (["GTE": L10n.text("大于或等于"), "GT": L10n.text("大于"), "LTE": L10n.text("小于或等于"), "LT": L10n.text("小于"), "EQ": L10n.text("等于"), "NE": L10n.text("不等于")][p["comparison"].string] ?? L10n.text("比较")) + " " + quantity(p["threshold"])
        case "sort": return (p["direction"].string == "DESC" ? L10n.text("从高到低") : L10n.text("从低到高")) + L10n.text("；保留 ") + quantity(p["limit"])
        case "any": return L10n.text("任一条件成立即可；全部不成立才排除，缺数据会保留未知状态。")
        case "all": return L10n.text("所有条件成立才通过；缺数据不等于通过。")
        case "if": return L10n.text("分别输出成立、不成立和未知分支；未知不会进入否则分支。")
        case "size": return L10n.text("每只证券目标：") + quantity(p["value"]) + "\n" + (p["denominator"].string == "NAV" ? L10n.text("以明确的总预算为分母；未调整资产也占预算。") : L10n.text("目标值不是增量订单。"))
        case "risk": return L10n.text("最大单证券权重 ") + p["comparison"].string + " " + quantity(p["threshold"])
        case "guard": return L10n.text("仅整体风险通过时放行；不通过或未知均阻断。")
        case "state": return L10n.text("模拟状态 ") + p["key"].string + " · " + p["operation"].string + L10n.text("\n只返回本次提案，不修改账户。")
        case "ai": return L10n.text("依据冻结价格证据形成待确认摘要；不推断公司基本面，不自动交易。")
        default: return L10n.text("检查参数与依赖后执行；不支持的规则会明确拦截。")
        }
    }
    static func unresolved(_ reason: String) -> PolicyJSON { .object(["state": .string("UNRESOLVED"), "reason": .string(reason)]) }
    static func quantity(_ value: String, unit: String) -> PolicyJSON { .object(["state": .string("RESOLVED"), "value": .string(value), "unit": .string(unit)]) }
    static func blank(accountIDs: [String]) throws -> PolicyJSON {
        return .object([
            "kind": .string("STRATEGY_DOCUMENT"), "schemaVersion": .number(1),
            "strategyId": .string("strategy_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")),
            "revision": .number(1), "name": .string(L10n.text("新策略")), "mode": .string("ANALYZE"),
            "accountScope": .object(["kind": .string("SELECTED_ACCOUNTS"), "accountIds": .array(accountIDs.sorted().map(PolicyJSON.string))]),
            "dataPolicy": .object(["asOf": .string(ISO8601DateFormatter().string(from: .now)), "futurePolicy": .string("REJECT"), "missingPolicy": .string("UNKNOWN"), "maxAgeDays": unresolved(L10n.text("请确认允许的数据陈旧天数")), "priceBasis": .string("SPLIT_ADJUSTED"), "etfProxyPolicy": .string("REJECT")]),
            "statePolicy": .object(["namespace": .string("SIMULATION"), "initialSnapshotId": .null, "commitPolicy": .string("RETURN_DELTA_ONLY")]),
            "nodes": .array([]), "outputs": .array([])
        ])
    }
    static func node(_ type: String, preceding: [PolicyJSON]) throws -> PolicyJSON {
        let id = "n_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
        var inputs: [String: PolicyJSON] = [:]
        func connect(_ input: String, port: String, types: [String]) throws {
            guard let parent = preceding.last(where: { types.contains($0["type"].string) }) else { throw PolicyContractError(message: L10n.text("请先添加\(input == "value" ? L10n.text("指标") : L10n.text("证券范围"))规则。")) }
            inputs[input] = .object(["nodeId": parent["nodeId"], "port": .string(port)])
        }
        let params: PolicyJSON
        switch type {
        case "source": params = .object(["operation": .string("SELECTED_HOLDINGS"), "securities": .array([])])
        case "indicator":
            try connect("universe", port: "universe", types: ["source", "filter", "sort"])
            params = .object(["metric": .string("return"), "methodologyVersion": .string("1"), "window": .object(["length": unresolved(L10n.text("请填写交易日数量")), "calendar": .string("TRADING_SESSIONS"), "exchangeMIC": .null]), "outputUnit": .string("PERCENT")])
        case "filter":
            try connect("universe", port: "universe", types: ["source", "filter", "sort"])
            try connect("value", port: "value", types: ["indicator"])
            params = .object(["comparison": .string("GTE"), "threshold": unresolved(L10n.text("请填写筛选阈值与单位"))])
        case "sort":
            try connect("universe", port: "universe", types: ["source", "filter", "sort"])
            try connect("value", port: "value", types: ["indicator"])
            params = .object(["direction": .string("DESC"), "nullPolicy": .string("EXCLUDE"), "tieBreak": .string("SECURITY_ID_THEN_LISTING_ID"), "limit": unresolved(L10n.text("请填写最多保留数量"))])
        case "any", "all":
            let predicates = preceding.filter { ["filter", "any", "all"].contains($0["type"].string) }.suffix(2)
            guard predicates.count == 2 else { throw PolicyContractError(message: L10n.text("请先添加至少两个筛选条件。")) }
            for (i, node) in predicates.enumerated() { inputs["p\(i + 1)"] = .object(["nodeId": node["nodeId"], "port": .string("predicate")]) }
            params = .object([:])
        case "if":
            try connect("condition", port: "predicate", types: ["filter", "any", "all"])
            try connect("universe", port: "universe", types: ["source", "filter", "sort"])
            params = .object(["unknownPolicy": .string("BLOCK")])
        case "size":
            try connect("universe", port: "universe", types: ["source", "filter", "sort"])
            params = .object(["operation": .string("TARGET_WEIGHT"), "value": unresolved(L10n.text("每只证券的目标NAV百分比")), "denominator": .string("NAV"), "rounding": .string("NONE"), "lotSize": quantity("1", unit: "SHARES")])
        case "risk":
            try connect("proposal", port: "proposal", types: ["size", "guard"])
            params = .object(["metric": .string("max_position_weight"), "methodologyVersion": .string("1"), "comparison": .string("LTE"), "threshold": unresolved(L10n.text("最大单证券目标权重百分比"))])
        case "guard":
            try connect("proposal", port: "proposal", types: ["size", "guard"])
            try connect("condition", port: "predicate", types: ["risk"])
            params = .object(["unknownPolicy": .string("BLOCK"), "failurePolicy": .string("BLOCK")])
        case "state":
            params = .object(["operation": .string("READ"), "key": .string("user_confirmed_key"), "value": .null, "namespace": .string("SIMULATION"), "commitPolicy": .string("RETURN_DELTA_ONLY")])
        case "ai":
            try connect("universe", port: "universe", types: ["source", "filter", "sort"])
            params = .object(["operation": .string("THESIS"), "promptTemplateId": .string("price-evidence-thesis"), "promptVersion": .string("1"), "responseSchemaId": .string("policy-thesis-1"), "evidencePolicy": .string("REQUIRE_CITATIONS"), "approvalPolicy": .string("CANDIDATE_REQUIRES_CONFIRMATION")])
        default: throw PolicyContractError(message: L10n.text("未知规则类型"))
        }
        return .object(["nodeId": .string(String(id)), "type": .string(type), "inputs": .object(inputs), "params": params])
    }
}
