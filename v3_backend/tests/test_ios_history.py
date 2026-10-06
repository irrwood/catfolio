from appmodel_source import read_appmodel
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HISTORY = ROOT / "CatfolioIOS" / "CatfolioIOS" / "HistoryView.swift"
MODEL = ROOT / "CatfolioIOS" / "CatfolioIOS" / "AppModel.swift"
TRADING_212 = ROOT / "CatfolioIOS" / "CatfolioIOS" / "Trading212Client.swift"
IBKR = ROOT / "CatfolioIOS" / "CatfolioIOS" / "IBKRFlexClient.swift"
STORE = ROOT / "CatfolioIOS" / "CatfolioIOS" / "LocalPortfolioStore.swift"


def test_failed_dividend_fetch_cannot_replace_complete_history():
    source = TRADING_212.read_text()
    fallback = source.split('dividendHistory = HistoricalOrdersResult(', 1)[1].split(')', 1)[0]
    assert 'isComplete: false' in fallback


def test_history_uses_native_pull_to_refresh_without_a_custom_sync_toast():
    history = HISTORY.read_text(encoding="utf-8")

    assert ".refreshable {" in history
    assert 'Label("Updating History"' not in history
    assert '.animation(.snappy, value: isSyncing)' not in history


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


def test_trading_212_realised_profit_uses_the_broker_activity_report():
    client = TRADING_212.read_text(encoding="utf-8")
    model = read_appmodel(MODEL.parent)

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
