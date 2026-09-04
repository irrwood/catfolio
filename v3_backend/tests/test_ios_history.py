from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HISTORY = ROOT / "CatfolioIOS" / "CatfolioIOS" / "HistoryView.swift"
SETTINGS = ROOT / "CatfolioIOS" / "CatfolioIOS" / "SettingsView.swift"
MODEL = ROOT / "CatfolioIOS" / "CatfolioIOS" / "APIClient.swift"
PROJECT = ROOT / "CatfolioIOS" / "CatfolioIOS.xcodeproj" / "project.pbxproj"
TRADING_212 = ROOT / "CatfolioIOS" / "CatfolioIOS" / "Trading212Client.swift"
IBKR = ROOT / "CatfolioIOS" / "CatfolioIOS" / "IBKRFlexClient.swift"
STORE = ROOT / "CatfolioIOS" / "CatfolioIOS" / "LocalPortfolioStore.swift"


def test_history_is_available_globally_and_for_one_account():
    settings = SETTINGS.read_text(encoding="utf-8")

    assert "HistoryView()" in settings
    assert "HistoryView(initialAccountIDs: [account.id])" in settings
    assert 'Text("History")' in settings
    assert 'Text("跨账户资产活动流水")' in settings


def test_history_supports_activity_categories_account_tags_and_export():
    history = HISTORY.read_text(encoding="utf-8")

    for category in ("All", "Orders", "Dividends", "Transactions", "Interest"):
        assert f'= "{category}"' in history

    assert 'Menu {' in history
    assert 'Label("All Accounts"' in history
    assert "selectedAccounts.count > 1" in history
    assert "accountTag(account)" in history
    assert "selectedAccountIDs = [account.id]" in history
    assert ".fileExporter(" in history
    assert 'contentType: .commaSeparatedText' in history
    assert 'if ledger.accounts.count > 1 {' in history
    assert 'accountFilter' in history
    assert 'accountFilter\n                        .listRowBackground' not in history


def test_history_categories_use_scrollable_native_button_styles():
    history = HISTORY.read_text(encoding="utf-8")

    assert 'ScrollView(.horizontal, showsIndicators: false)' in history
    assert '.buttonStyle(.borderedProminent)' in history
    assert '.buttonStyle(.bordered)' in history
    assert '.buttonBorderShape(.capsule)' in history
    assert '.controlSize(.large)' in history
    assert '.contentMargins(.horizontal, 16, for: .scrollContent)' in history
    assert '.scrollTargetBehavior(.viewAligned)' in history
    assert '.scrollTargetLayout()' in history
    assert '.font(.subheadline.weight(.semibold))' in history
    assert '.fixedSize(horizontal: true, vertical: false)' in history
    assert 'case .orders: "arrow.up.arrow.down"' in history
    assert 'case .dividends: "banknote.fill"' in history
    assert 'case .transactions: "creditcard.fill"' in history
    assert 'case .interest: "percent"' in history
    assert 'GlassEffectContainer' not in history
    assert '.glassEffect(' not in history


def test_history_uses_native_navigation_and_list_hierarchy_without_a_globe():
    history = HISTORY.read_text(encoding="utf-8")
    list_content = history.split('List {', 1)[1].split('if filteredActivities.isEmpty', 1)[0]

    assert '@Environment(\\.dismiss) private var dismiss' in history
    assert '.navigationTitle("History")' in history
    assert '.navigationBarTitleDisplayMode(.large)' in history
    assert 'ToolbarItem(placement: .topBarLeading)' in history
    assert 'Button("Back", systemImage: "xmark")' in history
    assert 'ToolbarItemGroup(placement: .topBarTrailing)' in history
    assert 'dismiss()' in history
    assert 'private var historyHeader' not in history
    assert list_content.index('categoryPicker') < list_content.index('summary')
    assert 'summary' in list_content
    assert 'globe' not in history.lower()


def test_history_header_actions_are_semantic_native_toolbar_controls():
    history = HISTORY.read_text(encoding="utf-8")

    assert 'ToolbarItem(placement: .topBarLeading)' in history
    assert 'ToolbarItemGroup(placement: .topBarTrailing)' in history
    assert 'if ledger.accounts.count > 1 {' in history
    assert 'Button("Download History", systemImage: "arrow.down.doc")' in history
    assert 'Label(accountFilterTitle, systemImage: "person.2")' in history
    assert 'private func historyHeaderControl' not in history
    assert 'HistoryHeaderGlassModifier' not in history


def test_history_groups_dates_and_has_requested_summaries():
    history = HISTORY.read_text(encoding="utf-8")

    for label in (
        "Today",
        "Yesterday",
        "REALISED P/L",
        "TOTAL DIVIDENDS",
        "DEPOSITS",
        "WITHDRAWALS",
        "TOTAL INTEREST",
    ):
        assert f'"{label}"' in history

    assert "Dictionary(grouping: filteredActivities)" in history
    assert "realisedProfitLossUSD" in history


def test_history_reads_the_full_local_ledger_and_is_built():
    model = MODEL.read_text(encoding="utf-8")
    project = PROJECT.read_text(encoding="utf-8")

    assert "func activityLedger() async throws -> PortfolioActivityLedger" in model
    assert "accounts: loaded.accounts" in model
    assert "transactions: (loaded.transactions ?? [])" in model
    assert "HistoryView.swift in Sources" in project


def test_broker_sync_imports_posted_interest_without_double_counting_accruals():
    trading_212 = TRADING_212.read_text(encoding="utf-8")
    ibkr = IBKR.read_text(encoding="utf-8")

    assert 'let includeInterest = true' in trading_212
    assert 'appendingPathComponent("equity/history/exports")' in trading_212
    assert 'action: "INTEREST"' in trading_212
    assert "Trading212InterestSyncStore" in trading_212
    assert 'elementName.caseInsensitiveCompare("CashTransaction")' in ibkr
    assert 'action = "INTEREST"' in ibkr
    assert 'elementName.caseInsensitiveCompare("InterestAccrual")' not in ibkr


def test_sell_proceeds_are_not_presented_or_totalled_as_realised_profit():
    history = HISTORY.read_text(encoding="utf-8")
    store = STORE.read_text(encoding="utf-8")
    ibkr = IBKR.read_text(encoding="utf-8")

    assert 'case .buy: "Buy"' in history
    assert 'case .sell: "Sell"' in history
    assert 'if isOrder {' in history
    assert 'Text("\\(DisplayFormat.shares(activity.transaction.quantity)) shares")' in history
    assert 'orderDirectionBadge(activity.kind)' in history
    assert 'kind == .buy ? CatfolioTheme.positive : CatfolioTheme.accent' in history
    assert 'Text("Proceeds ·' not in history
    assert 'let isOrder = activity.kind == .buy || activity.kind == .sell' in history
    assert 'isOrder ? abs(activity.nativeAmount) : activity.nativeAmount' in history
    assert 'signed: !isOrder' in history
    assert 'isOrder ? Color.primary' in history
    assert 'if let brokerRealised = transaction.realisedProfitLoss' in history
    assert 'saleProfitLoss += (proceedsPerShareUSD - lots[0].costPerShareUSD) * matched' in history
    assert 'remaining <= max(0.000_000_1, saleQuantity * 0.000_001)' in history
    assert 'result.hasIncompleteCostBasis = true' in history
    assert 'transaction.source == "Trading 212"' not in history
    assert 'value: "Updating…"' not in history
    assert 'quantity: abs(transaction.quantity)' in history
    assert 'let saleQuantity = abs(transaction.quantity)' in history
    assert 'try await Task.sleep(for: .seconds(65))' in history
    assert 'let realisedProfitLoss: Double?' in store
    assert 'attributes["realizedpnl"]' in ibkr


def test_trading_212_realised_profit_uses_the_broker_activity_report():
    client = TRADING_212.read_text(encoding="utf-8")
    model = MODEL.read_text(encoding="utf-8")

    assert 'let includeOrders = true' in client
    assert 'Currency (Result)' in client
    assert 'private static func parseActivityReport(' in client
    assert 'realisedProfitLoss: realised' in client
    assert 'realisedProfitLossCurrency:' in client
    assert 'private static func applyingBrokerReport(' in client
    assert 'let currency = Trading212Position.currency(nil, rawTicker: rawTicker)' in client
    assert 'realisedProfitLoss: transaction.realisedProfitLoss' in model
    assert 'realisedProfitLossCurrency: transaction.realisedProfitLossCurrency' in model
