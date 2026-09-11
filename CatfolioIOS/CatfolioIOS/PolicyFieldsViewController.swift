import UIKit

/// UIKit field editing for typed JSON, including unresolved quantities. The
/// caller validates the complete graph before committing these changes.
@MainActor
final class PolicyFieldsViewController: UITableViewController {
    private var value: PolicyJSON
    private var fields: [(path: [String], value: PolicyJSON)] = []
    private let onSave: (PolicyJSON) -> Void
    private let names = ["label": L10n.text("规则名称"), "name": L10n.text("策略名称"), "value": L10n.text("数值"), "unit": L10n.text("单位"), "metric": L10n.text("指标"), "comparison": L10n.text("比较方式"), "length": L10n.text("窗口长度"), "threshold": L10n.text("阈值"), "limit": L10n.text("最多保留"), "maxAgeDays": L10n.text("允许陈旧天数"), "asOf": L10n.text("数据截止时间"), "direction": L10n.text("排序方向"), "exchangeMIC": L10n.text("交易所代码"), "nodeId": L10n.text("来源规则"), "port": L10n.text("来源输出"), "currency": L10n.text("币种"), "calendar": L10n.text("日期口径"), "operation": L10n.text("操作"), "reason": L10n.text("待确认原因")]
    private func editable(_ path: [String]) -> Bool {
        !(["schemaVersion", "strategyId", "revision", "kind", "type", "nodeId"].contains(path.first ?? "") || ["futurePolicy", "missingPolicy", "namespace", "commitPolicy", "methodologyVersion", "tieBreak", "unknownPolicy", "failurePolicy"].contains(path.last ?? ""))
    }

    init(title: String, value: PolicyJSON, onSave: @escaping (PolicyJSON) -> Void) {
        self.value = value; self.onSave = onSave
        super.init(style: .insetGrouped)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = SettingsTemplate.uiPageBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .save, primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            self.view.endEditing(true)
            self.onSave(self.value)
        })
        rebuild()
    }
    private func rebuild() {
        fields = []
        func walk(_ value: PolicyJSON, path: [String]) {
            if value["state"].string == "UNRESOLVED" || value["state"].string == "RESOLVED" {
                fields.append((path, value)); return
            }
            if case .object(let values) = value {
                for key in values.keys.sorted() { walk(values[key]!, path: path + [key]) }
            } else { fields.append((path, value)) }
        }
        walk(value, path: [])
        tableView.reloadData()
    }
    private func set(_ value: PolicyJSON, path: [String], in root: inout PolicyJSON) {
        guard let key = path.first else { root = value; return }
        var child = root[key]
        set(value, path: Array(path.dropFirst()), in: &child)
        root[key] = child
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { fields.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let field = fields[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.font = PolicyComposerViewController.font(.body)
        cell.textLabel?.numberOfLines = 0
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.font = PolicyComposerViewController.font(.footnote)
        cell.textLabel?.text = field.path.map { names[$0] ?? $0 }.joined(separator: " · ")
        cell.detailTextLabel?.numberOfLines = 0
        if field.value["state"].string == "UNRESOLVED" { cell.detailTextLabel?.text = L10n.text("待确认：") + field.value["reason"].string }
        else if field.value["state"].string == "RESOLVED" { cell.detailTextLabel?.text = field.value["value"].string + " " + field.value["unit"].string }
        else { cell.detailTextLabel?.text = (try? field.value.text()) ?? "" }
        cell.accessoryType = editable(field.path) ? .disclosureIndicator : .none
        cell.selectionStyle = editable(field.path) ? .default : .none
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let field = fields[indexPath.row]
        guard editable(field.path) else { return }
        let choices: [String: [(String, String)]] = [
            "comparison": [(L10n.text("大于"), "GT"), (L10n.text("大于或等于"), "GTE"), (L10n.text("小于"), "LT"), (L10n.text("小于或等于"), "LTE"), (L10n.text("等于"), "EQ"), (L10n.text("不等于"), "NE")],
            "direction": [(L10n.text("从高到低"), "DESC"), (L10n.text("从低到高"), "ASC")],
            "mode": [(L10n.text("只读分析"), "ANALYZE"), (L10n.text("本次空状态模拟（非历史回测）"), "SIMULATE")],
            "metric": value["type"].string == "indicator" ? [(L10n.text("完整日线收盘价"), "price"), (L10n.text("区间涨跌幅"), "return"), (L10n.text("简单移动平均"), "sma"), (L10n.text("Cutler RSI · 有限窗口，非Wilder平滑"), "rsi"), (L10n.text("对数收益年化波动率 · 样本方差/252日"), "volatility")] : [],
            "rounding": [(L10n.text("不舍入"), "NONE"), (L10n.text("按手数向下舍入"), "DOWN_TO_LOT")],
            "nullPolicy": [(L10n.text("排除无数据项"), "EXCLUDE"), (L10n.text("无数据项排最后"), "LAST")]
        ]
        if let options = choices[field.path.last ?? ""], !options.isEmpty {
            let sheet = UIAlertController(title: names[field.path.last ?? ""] ?? L10n.text("选择"), message: L10n.text("选择明确的方法；不会自动填入窗口或阈值。"), preferredStyle: .actionSheet)
            for (title, raw) in options {
                sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                    guard let self else { return }
                    self.set(.string(raw), path: field.path, in: &self.value)
                    if field.path.last == "metric", self.value["type"].string == "indicator" {
                        self.value["params"]["outputUnit"] = .string(["price": "PRICE", "sma": "PRICE", "return": "PERCENT", "rsi": "SCORE", "volatility": "PERCENT"][raw]!)
                        if raw == "price" { self.value["params"]["window"] = .null }
                        else if self.value["params"]["window"] == .null { self.value["params"]["window"] = .object(["length": PolicyTemplates.unresolved(L10n.text("请确认交易日窗口")), "calendar": .string("TRADING_SESSIONS"), "exchangeMIC": .null]) }
                    }
                    self.rebuild()
                })
            }
            sheet.addAction(UIAlertAction(title: L10n.text("取消"), style: .cancel))
            sheet.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
            present(sheet, animated: true)
            return
        }
        let quantity = !field.value["state"].string.isEmpty
        let alert = UIAlertController(title: names[field.path.last ?? ""] ?? L10n.text("编辑字段"), message: quantity ? L10n.text("填写明确数值与单位；例如 60 / SESSIONS、10 / PERCENT。货币和价格必须提供币种。") : L10n.text("字符串无需引号；数组和布尔值请使用 JSON。"), preferredStyle: .alert)
        alert.addTextField { input in
            input.text = quantity ? field.value["value"].string : (field.value.string.isEmpty ? try? field.value.text() : field.value.string)
            input.placeholder = L10n.text("值")
            input.autocorrectionType = .no
            input.smartQuotesType = .no
        }
        if quantity {
            alert.addTextField { $0.text = field.value["unit"].string; $0.placeholder = L10n.text("单位：PERCENT / SESSIONS / DAYS / COUNT") }
            alert.addTextField { $0.text = field.value["currency"].string; $0.placeholder = L10n.text("币种（价格或金额必填）") }
        }
        alert.addAction(UIAlertAction(title: L10n.text("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.text("确定"), style: .default) { [weak self, weak alert] _ in
            guard let self, let alert else { return }
            let text = alert.textFields?.first?.text ?? ""
            let next: PolicyJSON
            if quantity {
                var q = PolicyTemplates.quantity(text, unit: alert.textFields?[1].text?.uppercased() ?? "")
                if let currency = alert.textFields?[2].text, !currency.isEmpty { q["currency"] = .string(currency.uppercased()) }
                next = q
            } else if case .string = field.value { next = .string(text) }
            else if let parsed = try? JSONDecoder().decode(PolicyJSON.self, from: Data(text.utf8)) { next = parsed }
            else { return }
            self.set(next, path: field.path, in: &self.value)
            self.rebuild()
        })
        present(alert, animated: true)
    }
}
