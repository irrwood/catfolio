from copy import deepcopy
import json

import pytest

from app.brokers import accounts


@pytest.fixture
def isolated(monkeypatch, tmp_path):
    monkeypatch.setattr(accounts, 'STORE', tmp_path / 'accounts.json')
    monkeypatch.setattr(accounts, 'V2_DIR', tmp_path)
    monkeypatch.setattr(accounts, '_PREVIEWS', {})
    secrets = {}
    monkeypatch.setattr(accounts.data_store, 'secret_value', lambda name: secrets.get(name))
    monkeypatch.setattr(accounts.data_store, 'save_secret', lambda name, value: secrets.update({name: value}) is None)
    monkeypatch.setattr(accounts.data_store, 'delete_secret', lambda name: secrets.pop(name, None) is not None)
    return tmp_path, secrets


def raw(identity='U123', shares=2, warnings=None):
    return {'provider': 'ibkr', 'positions': [{'ticker': 'AAPL', 'normalized_ticker': 'AAPL',
        'quantity': shares, 'average_price_paid': 180, 'current_price': 210,
        'market_value_native': shares * 210, 'currency': 'USD', 'account': 'Broker Main',
        'account_currency': 'USD', 'ppl': shares * 30}],
        'account_info': {'Broker Main': {'id': identity, 'currencyCode': 'USD'}},
        'account_cash': {'Broker Main': {'currencyCode': 'USD', 'total': 100}}, 'warnings': warnings or []}


def create(name='My account', source=None):
    return accounts.save_connection(None, name, 'ibkr', {'account_id': 'U123'}, source)


def synced(monkeypatch, name='My account', identity='U123', shares=2, source=None):
    account = create(name, source)
    monkeypatch.setattr(accounts, '_fetch', lambda *args: raw(identity, shares))
    preview = accounts.preview(account['id'])
    accounts.commit(account['id'], preview['token'])
    return account


def snapshot():
    return {'portfolio': {'summary': {}, 'holdings': [], 'holdings_by_account': []},
            'market': {'rows': []}, 'broker': {}, 'fundamentals': {}}


def test_preview_does_not_change_holdings_or_persist_secrets(isolated, monkeypatch):
    account = create()
    monkeypatch.setattr(accounts, '_fetch', lambda *args: raw())
    before = accounts.STORE.read_bytes()
    preview = accounts.preview(account['id'])
    assert len(preview['positions']) == 1
    assert accounts.STORE.read_bytes() == before
    assert 'account_id' not in accounts.STORE.read_text()
    assert not accounts.apply_accounts(snapshot())['portfolio']['holdings']


def test_two_accounts_same_stock_scope_and_idempotent_sync(isolated, monkeypatch):
    first = synced(monkeypatch)
    second = synced(monkeypatch, 'Second', 'U456', 3)
    merged = accounts.apply_accounts(snapshot())
    assert merged['portfolio']['holdings'][0]['shares'] == 5
    assert merged['portfolio']['summary']['total_cost_usd_standard'] == 900
    token = accounts.preview(second['id'])['token']
    accounts.commit(second['id'], token)
    with pytest.raises(ValueError, match='失效'):
        accounts.commit(second['id'], token)
    assert accounts.apply_accounts(snapshot())['portfolio']['holdings'][0]['shares'] == 5
    accounts.update_account(first['id'], selected=False)
    assert accounts.apply_accounts(snapshot())['portfolio']['holdings'][0]['shares'] == 3
    accounts.update_account(second['id'], selected=False)
    assert accounts.apply_accounts(snapshot())['market']['rows'] == []


def test_partial_response_failure_keeps_existing_snapshot(isolated, monkeypatch):
    first = synced(monkeypatch)
    before = accounts.STORE.read_bytes()
    monkeypatch.setattr(accounts, '_fetch', lambda *args: raw(warnings=['failed account']))
    with pytest.raises(ValueError, match='不完整'):
        accounts.preview(first['id'])
    assert accounts.STORE.read_bytes() == before


def test_empty_verified_snapshot_requires_confirmation_and_clears_only_target(isolated, monkeypatch):
    first = synced(monkeypatch)
    synced(monkeypatch, 'Second', 'U456', 3)
    empty = raw(); empty['positions'] = []
    monkeypatch.setattr(accounts, '_fetch', lambda *args: empty)
    preview = accounts.preview(first['id'])
    assert preview['empty'] is True
    assert accounts.apply_accounts(snapshot())['portfolio']['holdings'][0]['shares'] == 5
    accounts.commit(first['id'], preview['token'])
    assert accounts.apply_accounts(snapshot())['portfolio']['holdings'][0]['shares'] == 3


def test_identity_change_duplicate_and_stale_preview_rejected(isolated, monkeypatch):
    first = synced(monkeypatch)
    token = accounts.preview(first['id'])['token']
    accounts.update_account(first['id'], name='Renamed')
    with pytest.raises(ValueError, match='修改'):
        accounts.commit(first['id'], token)
    second = create('Duplicate')
    token = accounts.preview(second['id'])['token']
    with pytest.raises(ValueError, match='已经存在'):
        accounts.commit(second['id'], token)
    monkeypatch.setattr(accounts, '_fetch', lambda *args: raw('OTHER'))
    with pytest.raises(ValueError, match='另一个'):
        accounts.preview(first['id'])


def test_expired_preview_rejected(isolated, monkeypatch):
    account = create()
    monkeypatch.setattr(accounts, '_fetch', lambda *args: raw())
    token = accounts.preview(account['id'])['token']
    accounts._PREVIEWS[token]['expires'] = 0
    with pytest.raises(ValueError, match='失效'):
        accounts.commit(account['id'], token)


def test_legacy_association_preserves_other_accounts_and_history(isolated, monkeypatch):
    from app.brokers.service import _broker_portfolio
    original = snapshot()
    old_raw = raw()
    old_raw['positions'][0]['account'] = 'Old'
    original['portfolio'] = _broker_portfolio(old_raw)['portfolio']
    original['portfolio']['holdings_by_account'][0]['account'] = 'Old'
    original['portfolio']['import_transactions'] = [{'account': 'Old', 'ticker': 'AAPL'}]
    (isolated[0] / 'portfolio_analysis.json').write_text(json.dumps(original['portfolio']))
    before = deepcopy(original)
    account = synced(monkeypatch, source='Old', shares=4)
    merged = accounts.apply_accounts(original)
    assert merged['portfolio']['holdings'][0]['shares'] == 4
    assert merged['portfolio']['import_transactions'] == before['portfolio']['import_transactions']
    assert original == before
    accounts.delete_account(account['id'])
    assert not accounts.apply_accounts(original)['portfolio']['holdings']
    assert not accounts.account_state()['legacy']


def test_demo_api_never_touches_account_store(isolated, monkeypatch):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from app.routes import accounts as routes
    monkeypatch.setattr(routes, 'demo_mode', lambda: True)
    monkeypatch.setattr(accounts, '_read', lambda: pytest.fail('demo read local data'))
    app = FastAPI(); app.include_router(routes.router)
    with TestClient(app) as client:
        assert client.get('/api/accounts').json()['demo'] is True
        assert client.post('/api/accounts/a/preview').status_code == 403
        assert client.delete('/api/accounts/a').status_code == 403


def test_settings_uses_shared_shell_and_account_dialog(isolated, monkeypatch):
    from app.routes import settings
    from starlette.requests import Request
    monkeypatch.setattr(settings, 'demo_mode', lambda: False)
    monkeypatch.setattr(settings, 'secret_value', lambda name: None)
    request = Request({'type': 'http', 'method': 'GET', 'path': '/settings', 'headers': [], 'query_string': b'ui=v5'})
    html = settings.settings_page(request).body.decode()
    assert 'id="settings-accounts"' in html
    assert 'id="accountDialog"' in html
    assert '/static/accounts.js' in html
    assert 'design-system.css' in html


def test_csv_account_preview_sync_and_repeat_preserve_broker(isolated, monkeypatch):
    synced(monkeypatch)
    csv_account = accounts.save_connection(None, 'CSV account', 'csv', {})
    source = 'Date,Action,Ticker,Quantity,Price,Currency\n2026-01-01,BUY,AAPL,3,100,USD\n2026-01-02,SELL,AAPL,1,120,USD'
    preview = accounts.preview(csv_account['id'], source)
    assert preview['positions'][0]['quantity'] == 2
    accounts.commit(csv_account['id'], preview['token'])
    result = accounts.apply_accounts(snapshot())
    assert result['portfolio']['holdings'][0]['shares'] == 4
    assert result['portfolio']['summary']['total_cost_usd_standard'] == 560
    assert len(result['portfolio']['import_transactions']) == 2
    from app.analytics import portfolio_summary
    assert portfolio_summary(result)['market_value_usd'] == 840
    assert portfolio_summary(result)['unrealized_usd'] == 280
    assert len(result['broker']['positions']) == 2
    preview = accounts.preview(csv_account['id'], source)
    accounts.commit(csv_account['id'], preview['token'])
    result = accounts.apply_accounts(snapshot())
    assert result['portfolio']['holdings'][0]['shares'] == 4
    assert len(result['portfolio']['import_transactions']) == 2
    accounts.delete_account(csv_account['id'])
    assert accounts.apply_accounts(snapshot())['portfolio']['holdings'][0]['shares'] == 2


def test_credential_failure_does_not_save_registry(isolated, monkeypatch):
    monkeypatch.setattr(accounts.data_store, 'save_secret', lambda *args: False)
    with pytest.raises(ValueError, match='凭证'):
        create()
    assert not accounts.STORE.exists()


def test_account_token_cannot_commit_another_account(isolated, monkeypatch):
    a = create(); b = create('Second')
    monkeypatch.setattr(accounts, '_fetch', lambda *args: raw())
    token = accounts.preview(a['id'])['token']
    with pytest.raises(ValueError, match='失效'):
        accounts.commit(b['id'], token)


def test_no_selected_accounts_means_zero_portfolio(isolated, monkeypatch):
    from app.analytics import portfolio_summary
    a = synced(monkeypatch)
    assert portfolio_summary(accounts.apply_accounts(snapshot()))['market_value_usd'] == 420
    accounts.update_account(a['id'], selected=False)
    summary = portfolio_summary(accounts.apply_accounts(snapshot()))
    assert summary['market_value_usd'] == 0
    assert summary['total_cost_usd_standard'] == 0


def test_csv_without_quotes_is_unpriced_not_a_total_loss(isolated):
    from app.analytics import portfolio_summary, holdings_detail, chart_pnl
    account = accounts.save_connection(None, 'Unpriced', 'csv', {})
    preview = accounts.preview(account['id'], 'Date,Action,Ticker,Quantity,Price,Currency\n2026-01-01,BUY,MSFT,2,100,USD')
    accounts.commit(account['id'], preview['token'])
    result = accounts.apply_accounts(snapshot())
    assert portfolio_summary(result)['unrealized_usd'] == 0
    assert portfolio_summary(result)['unpriced_tickers'] == ['MSFT']
    assert holdings_detail(result)['rows'][0]['market_value_usd'] is None
    assert chart_pnl(result)['rows'] == []


def test_unselected_account_quote_still_prices_selected_csv(isolated, monkeypatch):
    from app.analytics import portfolio_summary
    broker = synced(monkeypatch)
    account = accounts.save_connection(None, 'CSV', 'csv', {})
    preview = accounts.preview(account['id'], 'Date,Action,Ticker,Quantity,Price,Currency\n2026-01-01,BUY,AAPL,2,100,USD')
    accounts.commit(account['id'], preview['token'])
    accounts.update_account(broker['id'], selected=False)
    summary = portfolio_summary(accounts.apply_accounts(snapshot()))
    assert summary['market_value_usd'] == 420
    assert summary['unrealized_usd'] == 220
