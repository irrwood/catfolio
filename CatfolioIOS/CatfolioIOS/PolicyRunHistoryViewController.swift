import UIKit

@MainActor
final class PolicyRunHistoryViewController: UITableViewController {
    private let records: [PolicyRunRecord]
    private let selected: (PolicyRunRecord, Bool, Bool) -> Void
    init(records: [PolicyRunRecord], selected: @escaping (PolicyRunRecord, Bool, Bool) -> Void) {
        self.records = records; self.selected = selected
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.text("运行历史")
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        if records.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = L10n.text("暂无运行记录")
            configuration.secondaryText = L10n.text("完成、失败和已取消的运行都会保存在本机。")
            contentUnavailableConfiguration = configuration
        }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { records.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let record = records[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = record.strategy["name"].string
        cell.textLabel?.font = PolicyComposerViewController.font(.headline)
        cell.detailTextLabel?.text = record.artifact["status"].string + " · " + record.updatedAt.formatted()
        cell.detailTextLabel?.numberOfLines = 0
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let record = records[indexPath.row]
        let alert = UIAlertController(title: record.strategy["name"].string, message: record.notice, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: L10n.text("查看结果"), style: .default) { _ in self.dismiss(animated: true) { self.selected(record, false, false) } })
        if ["RUNNING", "QUEUED", "FAILED", "INCOMPLETE"].contains(record.artifact["status"].string) {
            alert.addAction(UIAlertAction(title: L10n.text("从已保存进度继续"), style: .default) { _ in self.dismiss(animated: true) { self.selected(record, true, false) } })
            alert.addAction(UIAlertAction(title: L10n.text("仅前台继续"), style: .default) { _ in self.dismiss(animated: true) { self.selected(record, true, true) } })
        }
        alert.addAction(UIAlertAction(title: L10n.text("取消"), style: .cancel))
        alert.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        present(alert, animated: true)
    }
}
