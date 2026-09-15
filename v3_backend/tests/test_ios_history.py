from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HISTORY = ROOT / "CatfolioIOS" / "CatfolioIOS" / "HistoryView.swift"
SETTINGS = ROOT / "CatfolioIOS" / "CatfolioIOS" / "SettingsView.swift"
MODEL = ROOT / "CatfolioIOS" / "CatfolioIOS" / "APIClient.swift"
PROJECT = ROOT / "CatfolioIOS" / "CatfolioIOS.xcodeproj" / "project.pbxproj"
TRADING_212 = ROOT / "CatfolioIOS" / "CatfolioIOS" / "Trading212Client.swift"
IBKR = ROOT / "CatfolioIOS" / "CatfolioIOS" / "IBKRFlexClient.swift"
STORE = ROOT / "CatfolioIOS" / "CatfolioIOS" / "LocalPortfolioStore.swift"


def test_failed_dividend_fetch_cannot_replace_complete_history():
    source = TRADING_212.read_text()
    fallback = source.split('dividendHistory = HistoricalOrdersResult(', 1)[1].split(')', 1)[0]
    assert 'isComplete: false' in fallback


def test_closed_accounts_keep_identity_during_sync():
    source = MODEL.read_text()
    assert 'for account in loaded.accounts where account.source == "Trading 212"' in source
    assert 'syncedAccounts: snapshot.syncedAccounts.map' in source
    assert 'account.accountID.flatMap { accountNames[$0] } ?? account.name' in source
    assert 'var knownAccounts: [PortfolioAccount]?' in STORE.read_text()


def test_returns_fallback_is_lazy_and_runs_off_main_actor():
    source = MODEL.read_text()
    start = source.index('let enriched = try await LocalMarketDataClient().comparison')
    fallback = source.index('let localFallback = try await Task.detached', start)
    assert source.index('} catch {', start) < fallback
    assert 'private func apply(_ loaded: LocalPortfolioDocument, invalidatesDailyChanges: Bool = true) async throws' in source


def test_history_is_available_globally_and_for_one_account():
    settings = SETTINGS.read_text(encoding="utf-8")

    assert "HistoryView()" in settings
    assert "HistoryView(initialAccountIDs: [account.id])" in settings
    assert 'Text("History")' in settings
    assert 'Text("跨账户资产活动流水")' in settings
    assert 'historyTransition' not in settings
    assert '.navigationTransition(.zoom(sourceID: "history"' not in settings


def test_history_supports_activity_categories_account_tags_and_export():
    history = HISTORY.read_text(encoding="utf-8")

    for category in ("All", "Orders", "Dividends", "Interest"):
        assert f'= "{category}"' in history

    assert 'case transactions = "Transactions"' not in history
    assert 'return activity.kind.isCashTransfer ? nil : activity' in history

    assert 'Menu {' in history
    assert 'Label("All Accounts"' in history
    assert "selectedAccounts.count > 1" in history
    assert "accountTag(account)" in history
    assert "accountTint(" not in history
    assert "selectedAccountIDs = [account.id]" in history
    assert ".fileExporter(" in history
    assert 'contentType: .commaSeparatedText' in history
    assert 'if model.accounts.count > 1 {' in history
    assert 'accountFilter' in history
    assert 'accountFilter\n                        .listRowBackground' not in history


def test_history_uses_inline_navigation_title():
    history = HISTORY.read_text(encoding="utf-8")
    assert '.navigationTitle(L10n.text("History"))' in history
    assert '.navigationBarTitleDisplayMode(.inline)' in history
    assert '.navigationBarTitleDisplayMode(.large)' not in history


def test_history_uses_native_navigation_and_list_hierarchy_without_a_globe():
    history = HISTORY.read_text(encoding="utf-8")
    list_content = history.split('List {', 1)[1].split('if filteredActivities.isEmpty', 1)[0]

    assert '.navigationBarBackButtonHidden(true)' not in history
    assert 'ToolbarItem(placement: .topBarLeading)' not in history
    assert 'Button("Back", systemImage: "xmark")' not in history
    assert '.toolbarVisibility(.visible, for: .navigationBar)' in history
    assert 'private var historyHeader' not in history
    page = history.split('var body: some View {', 1)[1].split('.navigationTitle', 1)[0]
    assert page.index('categoryPicker') < page.index('historyList')
    assert 'ForEach(summaryMetrics)' in list_content
    assert '.listStyle(.insetGrouped)' in history
    assert '.listStyle(.plain)' not in history
    assert 'LabeledContent(metric.title)' in history
    assert 'globe' not in history.lower()


def test_history_category_directional_content_transition():
    history = HISTORY.read_text(encoding="utf-8")
    assert 'guard option != category else { return }' in history
    assert 'options.firstIndex(of: option)' in history
    assert 'options.firstIndex(of: category)' in history
    assert 'categoryContentOffset = reduceMotion ? 0 : (forward ? 1 : -1)' in history
    assert '.offset(x: categoryContentOffset * geometry.size.width)' in history
    assert 'transaction.disablesAnimations = true' in history
    assert 'categoryAnimationTask?.cancel()' in history
    assert 'guard !reduceMotion else { return }' in history
    assert '.id(category)' not in history
    assert '.transition(categoryContentTransition)' not in history
    assert '.background(Color(uiColor: .systemGroupedBackground))' in history


def test_history_lets_the_native_inset_grouped_list_own_its_background():
    history = HISTORY.read_text(encoding="utf-8")

    assert '.listStyle(.insetGrouped)' in history
    assert '.scrollContentBackground(.hidden)' not in history
    assert '.background(CatfolioTheme.pageBackground' not in history
    assert 'Color(uiColor: .systemGroupedBackground)' not in history


def test_history_uses_native_pull_to_refresh_without_a_custom_sync_toast():
    history = HISTORY.read_text(encoding="utf-8")

    assert ".refreshable {" in history
    assert 'Label("Updating History"' not in history
    assert '.animation(.snappy, value: isSyncing)' not in history


def test_history_header_actions_are_semantic_native_toolbar_controls():
    history = HISTORY.read_text(encoding="utf-8")

    assert 'ToolbarItem(placement: .topBarLeading)' not in history
    assert 'ToolbarItemGroup(placement: .topBarTrailing)' not in history
    assert 'ToolbarItem(id: "history-accounts", placement: .topBarTrailing)' in history
    assert 'ToolbarItem(id: "history-export", placement: .topBarTrailing)' in history
    assert 'ToolbarSpacer(.fixed, placement: .topBarTrailing)' in history
    assert 'if model.accounts.count > 1 {' in history
    assert 'Button("Download History", systemImage: "arrow.down.doc")' in history
    assert 'Label(accountFilterTitle, systemImage: "person.2")' in history
    assert 'private func historyHeaderControl' not in history
    assert 'HistoryHeaderGlassModifier' not in history


def test_history_groups_dates_and_has_requested_summaries():
    history = HISTORY.read_text(encoding="utf-8")

    for label in (
        "Today",
        "Yesterday",
        "Total dividends",
        "Total interest",
    ):
        assert f'"{label}"' in history

    assert "Dictionary(grouping: filteredActivities)" in history
    assert "realisedProfitLossUSD" in history
    assert "已实现盈亏 · 已导入卖出 · 原币" in history


def test_realised_display_never_mixes_estimates_or_current_fx_with_results():
    history = HISTORY.read_text()
    display = history.split('private var realisedSummaryMetric:', 1)[1].split('private func summaryRow', 1)[0]
    assert 'LocalBrokerResultSummary(transactions: sales)' in display
    assert 'summary.missingCount' in display
    assert '已知已实现盈亏' in display
    assert '暂无卖出' in display
    assert 'realisedCalculation' not in display
    assert 'totalUSD' not in display
    assert 'currency: currency' in display


def test_csv_keeps_result_and_currency_and_refresh_preserves_them():
    store = STORE.read_text(encoding="utf-8")
    client = TRADING_212.read_text(encoding="utf-8")
    assert '"resultCurrency": ["currency result", "result currency"]' in store
    assert 'realisedProfitLoss: $0.realisedProfitLoss' in store
    assert 'realisedProfitLossCurrency: $0.realisedProfitLossCurrency' in store
    assert 'transaction.preservingBrokerResult(from: transactionsByKey[transaction.id])' in store
    assert 'normalized.firstIndex(of: normalizeHeader($0))' in store
    assert 'guard matches.count == 1' in client
    assert '(resultCurrency.isEmpty ? nil : resultCurrency)' in client


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
    assert 'transaction.source == "Trading 212"' in history
    assert 'result.missingBrokerResults += 1' in history
    assert 'brokerTotals' in history
    assert 'currency: currency, signed: true, fractionDigits: 2' in history
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
    assert 'let currency = Trading212Position.currency(order.instrument?.currency, rawTicker: rawTicker)' in client
    assert 'realisedProfitLoss: transaction.realisedProfitLoss' in model
    assert 'realisedProfitLossCurrency: transaction.realisedProfitLossCurrency' in model
    assert 'side == "SELL" ? fill.walletImpact?.realisedProfitLoss : nil' in client
    assert 'side == "SELL" ? fill.walletImpact?.currency?.uppercased() : nil' in client
    assert 'reference: fill.id.map { String($0) }' in client
    assert 'brokerFXRate: transaction.brokerFXRate' in model
    assert 'let source = "v4:' in client
