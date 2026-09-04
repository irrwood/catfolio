from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SETTINGS = ROOT / "CatfolioIOS" / "CatfolioIOS" / "SettingsView.swift"
MODEL = ROOT / "CatfolioIOS" / "CatfolioIOS" / "APIClient.swift"
STORE = ROOT / "CatfolioIOS" / "CatfolioIOS" / "LocalPortfolioStore.swift"
TRADING_212 = ROOT / "CatfolioIOS" / "CatfolioIOS" / "Trading212View.swift"
MOOMOO = ROOT / "CatfolioIOS" / "CatfolioIOS" / "MoomooOAuthView.swift"
IBKR = ROOT / "CatfolioIOS" / "CatfolioIOS" / "IBKRFlexView.swift"
CSV_IMPORT = ROOT / "CatfolioIOS" / "CatfolioIOS" / "CSVImportView.swift"
TRADING_212_CLIENT = ROOT / "CatfolioIOS" / "CatfolioIOS" / "Trading212Client.swift"
MOOMOO_CLIENT = ROOT / "CatfolioIOS" / "CatfolioIOS" / "MoomooOAuthClient.swift"


def test_account_scope_separates_selection_from_detail_navigation():
    source = SETTINGS.read_text(encoding="utf-8")
    row = source[source.index("private func accountScopeRow"):source.index("private func accountSelectionButton")]

    assert "accountSelectionButton(selected: isSelected" in row
    assert "model.toggleAccount(account.id)" in row
    assert "NavigationLink" in row
    assert "AccountDetailView(accountID: account.id" in row
    assert row.index("accountSelectionButton(selected: isSelected") < row.index("NavigationLink")


def test_account_detail_exposes_requested_management_sections():
    source = SETTINGS.read_text(encoding="utf-8")
    detail = source[source.index("private struct AccountDetailView"):source.index("private struct SettingsSectionBlock")]

    for label in (
        "账户信息",
        "账户类型",
        "基础币种",
        "数据来源",
        "Trading 212 同步",
        "CSV 导入",
        "手动补充",
        "数据记录",
        "交易记录",
        "数据匹配与去重",
        "删除账户",
    ):
        assert label in detail

    assert 'detailActionRow(title: "重新同步")' not in detail
    assert 'SettingsSectionBlock(title: "数据管理")' not in detail


def test_account_management_is_backed_by_local_model_operations():
    model = MODEL.read_text(encoding="utf-8")
    store = STORE.read_text(encoding="utf-8")

    for operation in (
        "func transactions(for accountID:",
        "func renameAccount(_ accountID:",
        "func addHistoricalTransaction(",
        "func deduplicateTransactions(for accountID:",
        "func deleteAccount(_ accountID:",
    ):
        assert operation in model

    for operation in (
        "func renameAccount(_ accountKey:",
        "func appendHistoricalTransaction(",
        "func deduplicateTransactions(for accountKey:",
        "func removeAccount(_ accountKey:",
    ):
        assert operation in store


def test_new_account_section_is_add_only_and_uses_creation_context():
    source = SETTINGS.read_text(encoding="utf-8")
    section = source[source.index('title: "新建账户"'):source.index('SettingsSectionBlock(title: "行情与 AI"')]

    assert "券商与导入" not in source
    for label in ("Trading 212", "Moomoo", "Interactive Brokers", "CSV 导入"):
        assert label in section
    assert "这里只负责添加账户" not in section
    assert "可选任意一个或多个账户" not in source

    for connector in (
        "CSVImportView(context: .create)",
        "Trading212View(context: .create)",
        "IBKRFlexView(context: .create)",
        "MoomooOAuthView(context: .create)",
    ):
        assert connector in source


def test_settings_cards_use_spacious_rows_without_explanatory_footers():
    source = SETTINGS.read_text(encoding="utf-8")

    assert 'LazyVStack(alignment: .leading, spacing: 28)' in source
    assert '.padding(.horizontal, 18)' in source
    assert 'RoundedRectangle(cornerRadius: 24, style: .continuous)' in source
    assert '.frame(width: 36, height: 36)' in source
    assert '.frame(width: 50, height: 36)' in source
    assert '.padding(.vertical, 15)' in source


def test_account_checkmarks_share_the_connector_icon_centerline():
    source = SETTINGS.read_text(encoding="utf-8")
    selection_button = source[
        source.index("private func accountSelectionButton"):
        source.index("private func connector")
    ]

    assert '.frame(width: 50, height: 54)' in selection_button


def test_all_accounts_row_displays_the_combined_market_value():
    source = SETTINGS.read_text(encoding="utf-8")
    all_accounts = source[
        source.index("private var allAccountsRow"):
        source.index("private func accountScopeRow")
    ]

    assert "allAccountsMarketValueUSD" in all_accounts
    assert "model.accounts.reduce(0)" in all_accounts
    assert 'DisplayFormat.money(allAccountsMarketValueUSD)' in all_accounts


def test_account_detail_opens_connectors_in_management_context():
    source = SETTINGS.read_text(encoding="utf-8")
    detail = source[source.index("private struct AccountDetailView"):source.index("private struct SettingsSectionBlock")]

    for connector in (
        "Trading212View(context: .manage(account))",
        "MoomooOAuthView(context: .manage(account))",
        "IBKRFlexView(context: .manage(account))",
        "CSVImportView(context: .manage(account))",
    ):
        assert connector in detail


def test_every_new_account_flow_collects_a_nickname():
    for path in (TRADING_212, MOOMOO, IBKR, CSV_IMPORT):
        source = path.read_text(encoding="utf-8")
        assert 'TextField("账户昵称"' in source
        assert "model.suggestedAccountNickname()" in source

    model = MODEL.read_text(encoding="utf-8")
    store = STORE.read_text(encoding="utf-8")
    assert "func suggestedAccountNickname(" in model
    assert "AccountNaming.generatedNicknames" in model
    for nickname in ("橘子", "蓝莓", "水獭", "熊猫"):
        assert nickname in store


def test_creating_same_broker_accounts_replaces_only_incoming_accounts():
    model = MODEL.read_text(encoding="utf-8")
    store = STORE.read_text(encoding="utf-8")

    assert "replacingAccountsOnly: Bool = false" in model
    assert "replacingAccountsOnly: Bool = false" in store
    assert "incomingAccountKeys" in store
    assert "!incomingAccountKeys.contains(position.accountKey)" in store


def test_trading_212_accounts_use_dynamic_credential_slots_without_a_fixed_cap():
    view = TRADING_212.read_text(encoding="utf-8")
    client = TRADING_212_CLIENT.read_text(encoding="utf-8")

    assert "while usedSlots.contains(availableSlot)" in view
    assert '"trading212.account-\\(slot).api-key"' in view
    assert '"trading212.account-\\(slot).api-secret"' in view
    assert "[1, 2].first" not in view
    assert "isAccountSlotUnavailable" not in view
    assert 'var label: String { "账户 \\(slot)" }' in client
    assert "incompleteSecondAccount" not in client


def test_trading_212_history_preserves_negative_sell_fills():
    client = TRADING_212_CLIENT.read_text(encoding="utf-8")

    assert "let signedQuantity = fill.quantity, signedQuantity != 0" in client
    assert "quantity: abs(signedQuantity)" in client
    assert 'let source = "v3:' in client
    assert "let quantity = fill.quantity, quantity > 0" not in client


def test_trading_212_history_imports_dividends_and_transaction_screen_syncs_it():
    client = TRADING_212_CLIENT.read_text(encoding="utf-8")
    settings = SETTINGS.read_text(encoding="utf-8")

    assert 'appendingPathComponent("equity/history/dividends")' in client
    assert 'action: "DIVIDEND"' in client
    assert "Trading212DividendSyncStore" in client
    assert "synchronizeTrading212History()" in settings
    assert 'syncMessage = "正在补齐 Trading 212 成交、分红与利息…"' in settings
    assert 'transaction.action.uppercased() == "DIVIDEND"' in settings
    assert "transactions: transactions" in client

    model = MODEL.read_text(encoding="utf-8")
    store = STORE.read_text(encoding="utf-8")
    assert "mergeTransactions(transactions)" in model
    assert "func mergeTransactions(_ incoming:" in store
    assert "mergeCachedTrading212History(into: loaded)" in model
    assert "func cachedTransactions(" in client


def test_moomoo_credentials_are_stored_and_loaded_per_account():
    view = MOOMOO.read_text(encoding="utf-8")
    client = MOOMOO_CLIENT.read_text(encoding="utf-8")

    assert '"moomoo.oauth.account.\\(accountID).tokens"' in client
    assert "static func tokenSet(for accountID:" in client
    assert "fallbackToLegacy: Bool = true" in client
    assert "static func migrateLegacyToken(to accountIDs:" in client
    assert "credentialAccountID: String? = nil" in client
    assert "MoomooCredentialStore.save(tokenSet: refreshed, for: credentialAccountID)" in client
    assert "authorizationSession.authorize(accountID: context.account?.accountID)" in view
    assert "MoomooCredentialStore.migrateLegacyToken" in view
    assert "persistCredentials(for: result.accounts.map(\\.accountID))" in view
    assert "clearTokens(for: context.account?.accountID)" in view


def test_ibkr_credentials_are_stored_and_loaded_per_account():
    view = IBKR.read_text(encoding="utf-8")

    assert '"ibkr.flex.account.\\(accountID).token"' in view
    assert '"ibkr.flex.account.\\(accountID).query-id"' in view
    assert "saveCredentials(credentials, accountIDs: resultAccountIDs(result))" in view
    assert "Self.tokenKey(accountID: accountID)" in view
    assert "Self.queryIDKey(accountID: accountID)" in view
    assert "legacyTokenKey" in view
    assert "legacyQueryIDKey" in view
