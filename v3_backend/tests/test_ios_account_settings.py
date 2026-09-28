from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SETTINGS = ROOT / "CatfolioIOS" / "CatfolioIOS" / "SettingsView.swift"
ROOT_TABS = ROOT / "CatfolioIOS" / "CatfolioIOS" / "RootTabView.swift"
DESIGN_SYSTEM = ROOT / "CatfolioIOS" / "CatfolioIOS" / "DesignSystem.swift"
PUBLIC_INVESTOR = ROOT / "CatfolioIOS" / "CatfolioIOS" / "PublicInvestorView.swift"
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


def test_transaction_rows_use_the_records_stable_domain_identity():
    settings = SETTINGS.read_text(encoding="utf-8")
    store = STORE.read_text(encoding="utf-8")

    assert "struct LocalTransactionRecord: Codable, Equatable, Identifiable" in store
    assert "var id: String" in store
    assert "transactionsByKey[transaction.id]" in store
    assert "seen.insert(transaction.id)" in store
    assert "List(transactions) { transaction in" in settings
    assert "id: \\.offset" not in settings


def test_new_account_section_is_add_only_and_uses_creation_context():
    source = SETTINGS.read_text(encoding="utf-8")
    picker = (SETTINGS.parent / "AddAccountView.swift").read_text(encoding="utf-8")
    root = source[source.index('SettingsPage(title: L10n.text("设置"))'):]
    assert root.index('GlassPrimaryButton(title: L10n.text("添加账户")') < root.index('PublicInvestorSettingsSection()')
    assert '.appSheet(isPresented: $showsAddAccount)' in root
    assert 'AddAccountView().environment(model)' in root
    assert 'SettingsSection(L10n.text("新建账户"))' not in root
    for label in ("Trading 212", "Moomoo", "Interactive Brokers", "CSV 导入"):
        assert label in picker
    for connector in (
        "CSVImportView(context: .create)",
        "Trading212View(context: .create)",
        "IBKRFlexView(context: .create)",
        "MoomooOAuthView(context: .create)",
        "RobinhoodConnectionView(context: .create)",
        "SnapTradeView(context: .create)",
    ):
        assert connector in picker


def test_settings_root_uses_native_ios_form_sections_and_controls():
    source = SETTINGS.read_text(encoding="utf-8")
    root_body = source[source.index("    var body: some View {"):source.index("    private var appVersion:")]

    assert "Form {" in root_body
    assert ".formStyle(.grouped)" in root_body
    assert ".contentMargins(.bottom, 96, for: .scrollContent)" in root_body
    assert "NavigationStack {" not in root_body
    assert 'Section("账户范围")' in root_body
    assert 'Section("新建账户")' in root_body
    assert "Toggle(isOn: $hapticsEnabled)" in root_body
    assert "SettingsGroupCard" not in root_body
    assert "SettingsDivider" not in root_body
    assert ".background(CatfolioTheme.pageBackground" not in root_body


def test_settings_pages_share_the_native_grouped_background():
    design_system = DESIGN_SYSTEM.read_text(encoding="utf-8")
    assert "static let settingsBackground = Color(uiColor: .systemGroupedBackground)" in design_system

    for path in (SETTINGS, PUBLIC_INVESTOR, TRADING_212, MOOMOO, IBKR, CSV_IMPORT):
        source = path.read_text(encoding="utf-8")
        assert ".background(CatfolioTheme.settingsBackground)" in source
        assert "CatfolioTheme.pageBackground(for: colorScheme)" not in source


def test_sheet_rows_keep_semantic_text_colors_and_show_disclosure_arrows():
    source = SETTINGS.read_text(encoding="utf-8")
    connector = source[source.index("    private func connector("):source.index("    private func settingsValueRow(")]

    assert 'Image(systemName: "chevron.forward")' in connector
    assert ".foregroundStyle(.tertiary)" in connector
    assert ".buttonStyle(.plain)" in connector
    assert "nativeSettingsLabel(title: title, detail: detail" in connector


def test_account_checkmarks_share_the_connector_icon_centerline():
    source = SETTINGS.read_text(encoding="utf-8")
    selection_button = source[
        source.index("private func accountSelectionButton"):
        source.index("private func connector")
    ]

    assert '.frame(width: 36)' in selection_button
    assert '.frame(minHeight: 44)' in selection_button
    assert '.buttonStyle(.borderless)' in selection_button


def test_settings_selection_and_disclosure_symbols_adapt_to_dark_mode():
    source = SETTINGS.read_text(encoding="utf-8")
    selection_button = source[
        source.index("private func accountSelectionButton"):
        source.index("private func connector")
    ]

    assert ".symbolRenderingMode(.palette)" in selection_button
    assert ".foregroundStyle(.white, CatfolioTheme.accent)" in selection_button
    assert 'Image(systemName: "chevron.right")' not in source
    assert "CatfolioTheme.disclosure" not in source


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
    assert 'syncMessage = L10n.text("正在补齐 Trading 212 成交、股息与利息…")' in settings
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


def test_local_service_actions_use_native_button_styles_and_accessibility_labels():
    source = SETTINGS.read_text(encoding="utf-8")
    detail = source[source.index("private struct LocalServiceDetailView"):]

    assert ".buttonStyle(.borderedProminent)" in detail
    assert ".buttonStyle(.bordered)" in detail
    assert '.accessibilityLabel(isTesting ? "正在验证" : "保存并验证")' in detail
    assert '.accessibilityLabel("仅保存，不验证")' in detail
    assert ".opacity(trimmedKey.isEmpty || isTesting ? 0.45 : 1)" not in detail


def test_account_notice_uses_current_alert_presentation_api():
    source = SETTINGS.read_text(encoding="utf-8")
    detail = source[source.index("private struct AccountDetailView"):source.index("private struct SettingsSectionBlock")]

    assert "presenting: notice" in detail
    assert ".alert(item: $notice)" not in detail
    assert 'Button("好", role: .cancel)' in detail


def test_ai_zoom_source_declares_the_bubble_clip_shape():
    source = ROOT_TABS.read_text(encoding="utf-8")
    assistant = source[source.index('Button(action: presentAI)'):source.index('.accessibilityLabel("AI 助手")')]

    assert 'matchedTransitionSource(id: "ai-bubble"' in assistant
    assert "RoundedRectangle(cornerRadius: 28, style: .continuous)" in assistant
