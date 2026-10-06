from appmodel_source import read_appmodel
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SETTINGS = ROOT / "CatfolioIOS" / "CatfolioIOS" / "SettingsView.swift"
MODEL = ROOT / "CatfolioIOS" / "CatfolioIOS" / "AppModel.swift"
STORE = ROOT / "CatfolioIOS" / "CatfolioIOS" / "LocalPortfolioStore.swift"
MOOMOO = ROOT / "CatfolioIOS" / "CatfolioIOS" / "MoomooOAuthView.swift"
TRADING_212_CLIENT = ROOT / "CatfolioIOS" / "CatfolioIOS" / "Trading212Client.swift"
MOOMOO_CLIENT = ROOT / "CatfolioIOS" / "CatfolioIOS" / "MoomooOAuthClient.swift"


def test_account_management_is_backed_by_local_model_operations():
    model = read_appmodel(MODEL.parent)
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


def test_all_accounts_row_displays_the_combined_market_value():
    source = SETTINGS.read_text(encoding="utf-8")
    all_accounts = source[
        source.index("private var allAccountsRow"):
        source.index("private func accountScopeRow")
    ]

    assert "allAccountsMarketValueUSD" in all_accounts
    assert "model.accounts.reduce(0)" in all_accounts
    assert 'DisplayFormat.money(allAccountsMarketValueUSD)' in all_accounts


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


def test_sell_fill_keeps_signed_input_and_positive_ledger_magnitude():
    source = TRADING_212_CLIENT.read_text()
    assert "let signedQuantity = fill.quantity, signedQuantity != 0" in source
    assert "quantity: abs(signedQuantity)" in source
    assert "let quantity = fill.quantity, quantity > 0" not in source


def test_dividend_history_is_fetched_and_preserved_with_cached_transactions():
    client = TRADING_212_CLIENT.read_text()
    model = read_appmodel(MODEL.parent)
    assert 'appendingPathComponent("equity/history/dividends")' in client
    assert 'action: "DIVIDEND"' in client
    assert "func cachedTransactions(" in client
    assert "mergeCachedTrading212History(into: loaded," in model
