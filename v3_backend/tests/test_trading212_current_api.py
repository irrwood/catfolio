"""Desktop connection contracts for current and legacy Trading 212 APIs."""
import base64
import importlib
import io
import json
from pathlib import Path
import ssl
import urllib.error

import pytest

from app.brokers import accounts


@pytest.fixture
def api(monkeypatch):
    monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[2] / 'scripts'))
    module = importlib.import_module('enrich_trading212_data')
    monkeypatch.setattr(module, 'KNOWN_PRICE_CURRENCY', {'SIE': 'GBP'})
    return module


def summary():
    return {'id': 98765, 'currency': 'EUR', 'cash': {
        'availableToTrade': 100, 'reservedForOrders': 0, 'inPies': 5},
        'investments': {'totalCost': 200, 'currentValue': 220,
                        'unrealizedProfitLoss': 20, 'realizedProfitLoss': 0},
        'totalValue': 325}


def position():
    return {'instrument': {'ticker': 'SIEd_EQ', 'name': 'Siemens', 'currency': 'EUR'},
            'quantity': 2, 'averagePricePaid': 100, 'currentPrice': 110,
            'createdAt': '2026-08-01T10:00:00Z',
            'walletImpact': {'currency': 'EUR', 'unrealizedProfitLoss': 20, 'fxImpact': 0}}


def fail(path, code):
    raise urllib.error.HTTPError('https://live.trading212.com/api/v0' + path,
                                 code, 'test-secret-do-not-expose', {},
                                 io.BytesIO(b'test-secret-do-not-expose'))


def test_current_german_account_uses_summary_and_positions(api, monkeypatch):
    paths = []
    def get(path, auth):
        paths.append(path)
        assert auth == 'Basic ' + base64.b64encode(b'test-key:test-secret').decode()
        if path == '/equity/account/summary': return summary()
        if path == '/equity/positions': return [position()]
        pytest.fail('Current account must not call retired endpoints')
    monkeypatch.setattr(api, 'open_json', get)
    raw = accounts._fetch('trading212', {'api_key': 'test-key', 'api_secret': 'test-secret'})
    assert paths == ['/equity/account/summary', '/equity/positions']
    label = 'Trading 212 · 98765'
    assert raw['account_info'][label] == {'id': 98765, 'currencyCode': 'EUR'}
    assert raw['account_cash'][label]['total'] == 325
    assert raw['account_cash'][label]['result'] == 0
    row = raw['positions'][0]
    assert row['currency'] == row['account_currency'] == 'EUR'
    assert row['ppl'] == 20 and row['fx_ppl'] == 0
    assert row['cost_native'] == 200 and row['market_value_native'] == 220
    assert row['initial_fill_date'] == '2026-08-01T10:00:00Z'


def test_legacy_fallback_only_when_endpoint_is_missing(api, monkeypatch):
    paths = []
    def get(path, auth):
        paths.append(path)
        if path in ['/equity/account/summary', '/equity/positions']: fail(path, 404)
        return {'/equity/account/info': {'id': 123, 'currencyCode': 'GBP'},
                '/equity/account/cash': {'total': 100},
                '/equity/portfolio': []}[path]
    monkeypatch.setattr(api, 'open_json', get)
    raw = accounts._fetch('trading212', {'api_key': 'test-key', 'api_secret': 'test-secret'})
    assert raw['positions'] == []
    assert raw['account_info']['Trading 212 · 123']['currencyCode'] == 'GBP'
    assert paths == ['/equity/account/summary', '/equity/account/info',
                     '/equity/account/cash', '/equity/positions', '/equity/portfolio']


@pytest.mark.parametrize('code', [400, 401, 403, 429, 500])
@pytest.mark.parametrize('method,path', [('fetch_account_details', '/equity/account/summary'),
                                       ('fetch_positions', '/equity/positions')])
def test_failed_requests_are_not_retried_against_legacy_endpoints(api, monkeypatch, code, method, path):
    paths = []
    def get(actual, auth):
        paths.append(actual)
        fail(actual, code)
    monkeypatch.setattr(api, 'open_json', get)
    with pytest.raises(urllib.error.HTTPError) as error:
        getattr(api, method)('Basic dummy')
    assert paths == [path]
    text = api.request_error_message(error.value)
    assert path in text and f'HTTP {code}' in text
    assert 'test-secret' not in text


def test_preview_reports_endpoint_and_retains_saved_data(api, monkeypatch, tmp_path):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient
    from app.routes import accounts as routes
    store = {'accounts': {'test': {'id': 'test', 'provider': 'trading212',
                                  'snapshot': {'positions': [{'quantity': 7}]}}}}
    monkeypatch.setattr(accounts, 'STORE', tmp_path / 'accounts.json')
    accounts.STORE.write_text(json.dumps(store))
    before = accounts.STORE.read_bytes()
    monkeypatch.setattr(accounts, '_PREVIEWS', {})
    monkeypatch.setattr(accounts.data_store, 'secret_value', lambda _: json.dumps(
        {'api_key': 'test-key', 'api_secret': 'test-secret'}))
    monkeypatch.setattr(api, 'open_json', lambda path, auth: fail(path, 400))
    monkeypatch.setattr(routes, 'demo_mode', lambda: False)
    monkeypatch.setattr(routes, 'public_demo_mode', lambda: False)
    app = FastAPI(); app.include_router(routes.router)
    with TestClient(app) as client:
        response = client.post('/api/accounts/test/preview')
    assert response.status_code == 400
    assert '/equity/account/summary' in response.json()['detail']
    assert 'HTTP 400' in response.json()['detail']
    assert 'test-secret' not in response.text and 'test-key' not in response.text
    assert accounts.STORE.read_bytes() == before
    assert accounts._PREVIEWS == {}


def test_legacy_refresh_also_uses_current_api(api, monkeypatch):
    monkeypatch.setattr(api, 'auth_header', lambda _: 'Basic dummy')
    monkeypatch.setattr(api, 'auth_mode_label', lambda _: 'basic_key_secret')
    paths = []
    def get(path, auth):
        paths.append(path)
        return summary() if path == '/equity/account/summary' else [position()]
    monkeypatch.setattr(api, 'open_json', get)
    result = api.fetch_account('default', {'account_info': {'id': 'old', 'currencyCode': 'GBP'}})
    assert result['warnings'] == []
    assert result['account_info']['currencyCode'] == 'EUR'
    assert result['positions'][0]['ppl'] == 20
    assert paths == ['/equity/account/summary', '/equity/positions']


def test_current_response_missing_currency_is_rejected(api, monkeypatch):
    payload = summary(); del payload['currency']
    monkeypatch.setattr(api, 'open_json', lambda *args: payload)
    with pytest.raises(accounts.Trading212ConnectionError):
        accounts._fetch('trading212', {'api_key': 'test-key', 'api_secret': 'test-secret'})


def test_request_keeps_tls_verification_enabled(api, monkeypatch):
    calls = []
    def urlopen(request, timeout, context):
        calls.append(request)
        assert context.verify_mode == ssl.CERT_REQUIRED
        assert context.check_hostname is True
        assert request.get_header('Accept') == 'application/json'
        raise urllib.error.URLError(ssl.SSLCertVerificationError('certificate failed'))
    monkeypatch.setattr(api.urllib.request, 'urlopen', urlopen)
    with pytest.raises(urllib.error.URLError):
        api.open_json('/equity/positions', 'Basic dummy')
    assert len(calls) == 1
