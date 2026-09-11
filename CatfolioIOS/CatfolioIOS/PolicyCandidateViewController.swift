import UIKit

@MainActor
final class PolicyCandidateViewController: UIViewController {
    private let original: String
    private let candidate: String
    private let changes: String
    private let onConfirm: () -> Void
    private let reviewTitle: String
    private let applyTitle: String
    private let allowsApply: Bool
    private let editor = UITextView()
    private let selection = UISegmentedControl(items: [L10n.text("修改摘要"), L10n.text("原稿"), L10n.text("候选")])
    init(original: String, candidate: String, changes: String, title: String = L10n.text("确认 AI 修改"), applyTitle: String = L10n.text("应用候选"), allowsApply: Bool = true, onConfirm: @escaping () -> Void) {
        self.original = original; self.candidate = candidate; self.onConfirm = onConfirm
        self.changes = changes
        self.reviewTitle = title; self.applyTitle = applyTitle; self.allowsApply = allowsApply
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = reviewTitle
        view.backgroundColor = SettingsTemplate.uiPageBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: applyTitle, primaryAction: UIAction { [weak self] _ in self?.onConfirm() })
        navigationItem.rightBarButtonItem?.isEnabled = allowsApply
        selection.selectedSegmentIndex = 0
        selection.addTarget(self, action: #selector(change), for: .valueChanged)
        let note = UILabel()
        note.text = L10n.text("检查账户范围、规则增删、阈值与单位。确认只保存修订，不会执行策略。")
        note.font = PolicyComposerViewController.font(.body)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        note.adjustsFontForContentSizeCategory = true
        editor.isEditable = false
        editor.font = PolicyComposerViewController.font(.body)
        editor.adjustsFontForContentSizeCategory = true
        editor.text = changes
        editor.backgroundColor = SettingsTemplate.uiCard
        editor.accessibilityLabel = L10n.text("候选修改详情")
        selection.accessibilityLabel = L10n.text("修改摘要、原稿与候选切换")
        let stack = UIStackView(arrangedSubviews: [selection, note, editor])
        stack.axis = .vertical; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }
    @objc private func change() {
        editor.text = selection.selectedSegmentIndex == 0 ? changes : (selection.selectedSegmentIndex == 1 ? original : candidate)
        editor.setContentOffset(.zero, animated: false)
        UIAccessibility.post(notification: .layoutChanged, argument: editor)
    }
}

@MainActor
final class PolicyArchiveListViewController: UITableViewController {
    struct Item { let title: String; let subtitle: String; let open: () -> Void }
    private let items: [Item]
    init(title: String, items: [Item]) { self.items = items; super.init(style: .insetGrouped); self.title = title }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = SettingsTemplate.uiPageBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        if items.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.text = L10n.text("暂无记录")
            empty.secondaryText = L10n.text("保存的修订和 AI 候选会显示在这里。")
            contentUnavailableConfiguration = empty
        }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = items[indexPath.row], cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = item.title; cell.detailTextLabel?.text = item.subtitle
        cell.textLabel?.font = PolicyComposerViewController.font(.headline)
        cell.detailTextLabel?.font = PolicyComposerViewController.font(.footnote)
        cell.textLabel?.numberOfLines = 0; cell.detailTextLabel?.numberOfLines = 0
        cell.textLabel?.adjustsFontForContentSizeCategory = true; cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        dismiss(animated: true) { self.items[indexPath.row].open() }
    }
}
