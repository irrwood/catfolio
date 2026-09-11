"""Account-scoped connections and preview/commit synchronization.

Credentials stay in the OS keychain. A preview is immutable and short lived;
committing it never re-fetches data or replaces another account's snapshot.
"""
from __future__ import annotations

import base64
from copy import deepcopy
import importlib
import json
import secrets
import sys
import threading
import time
import urllib.request

from app import data_store
from app.cache import clear_all
from app.settings import ROOT, V2_DIR
from .service import SUPPORTED_BROKERS, _atomic_json, _broker_portfolio
from .ibkr import IBKRAdapter, IBKRConfig
from .moomoo import MoomooAdapter, MoomooConfig

STORE = V2_DIR / 'accounts.json'
_LOCK = threading.RLock()
_PREVIEWS = {}
FIELDS = {
    'trading212': ('api_key', 'api_secret'),
    'moomoo': ('host', 'port', 'markets', 'account_id'),
    'ibkr': ('base_url', 'account_id'),
    'csv': (),
}


def _read():
    if not STORE.exists():
        return {'accounts': {}, 'revision': 0}
    # Never silently replace a damaged account registry with an empty one.
    return json.loads(STORE.read_text(encoding='utf-8'))


def _save(store):
    store['revision'] += 1
    _atomic_json(STORE, store)
    clear_all()


def _secret_name(account_id):
    return 'CATFOLIO_ACCOUNT_' + account_id


def _public(account):
    raw = account.get('snapshot') or {}
    positions = raw.get('positions') or []
    values = [data_store.usd_equivalent(p.get('market_value_native'), p.get('currency') or 'USD') for p in positions]
    market_value = sum(values) if all(v is not None for v in values) else None
    return {key: account.get(key) for key in ('id', 'name', 'provider', 'selected', 'updated_at')} | {
        'positions': len(positions),
        'currency': next(iter(raw.get('account_info', {}).values()), {}).get('currencyCode'),
        'configured': account.get('configured', False),
        'market_value_usd': market_value,
        'transactions': len(raw.get('import_transactions', [])),
    }


def list_accounts():
    with _LOCK:
        return [_public(a) for a in _read()['accounts'].values()]


def save_connection(account_id, name, provider, config, replaces_account=None):
    if provider not in FIELDS:
        raise ValueError('不支持的券商。')
    name = str(name).strip()
    if not name or len(name) > 80:
        raise ValueError('账户名称须为 1–80 个字符。')
    if not isinstance(config, dict) or set(config) - set(FIELDS[provider]):
        raise ValueError('连接配置无效。')
    with _LOCK:
        store = _read()
        if account_id and account_id not in store['accounts']:
            raise ValueError('账户不存在。')
        account_id = account_id or secrets.token_hex(16)
        old = store['accounts'].get(account_id, {})
        if old and old['provider'] != provider:
            raise ValueError('已有账户不能更换券商。')
        if name in legacy_accounts() and replaces_account != name:
            raise ValueError('同名持仓已存在，请关联原账户或使用不同名称。')
        if replaces_account and replaces_account not in legacy_accounts():
            raise ValueError('原账户不存在。')
        if old.get('snapshot') and replaces_account != old.get('replaces_account'):
            raise ValueError('已同步账户不能更改关联。')
        if replaces_account and any(a.get('replaces_account') == replaces_account and a['id'] != account_id for a in store['accounts'].values()):
            raise ValueError('原账户已关联到其他连接。')
        if any(a['name'].casefold() == name.casefold() and a['id'] != account_id for a in store['accounts'].values()):
            raise ValueError('请使用不同的账户名称。')
        previous = {} if provider == 'csv' else json.loads(data_store.secret_value(_secret_name(account_id)) or '{}')
        config = previous | {k: str(v).strip() for k, v in config.items() if str(v).strip()}
        if provider == 'trading212' and not all(config.get(k) for k in FIELDS[provider]):
            raise ValueError('请填写 API Key 和对应的 API Secret。')
        if provider == 'ibkr':
            IBKRConfig(base_url=config.get('base_url') or 'https://localhost:5000/v1/api', account_id=config.get('account_id', ''))
        if provider == 'moomoo':
            MoomooConfig(host=config.get('host') or '127.0.0.1', port=int(config.get('port') or 11111))
        if provider != 'csv' and not data_store.save_secret(_secret_name(account_id), json.dumps(config)):
            raise ValueError('无法保存到系统凭证库；账户未保存。')
        account = old | {'id': account_id, 'name': name, 'provider': provider, 'configured': True,
                         'replaces_account': replaces_account, 'selected': old.get('selected', True), 'version': old.get('version', 0) + 1}
        store['accounts'][account_id] = account
        _save(store)
        return _public(account)


def _fetch(provider, config):
    if provider == 'ibkr':
        return IBKRAdapter(IBKRConfig(base_url=config.get('base_url') or 'https://localhost:5000/v1/api', account_id=config.get('account_id', ''))).fetch_snapshot()
    if provider == 'moomoo':
        return MoomooAdapter(MoomooConfig(host=config.get('host') or '127.0.0.1', port=int(config.get('port') or 11111),
            markets=tuple((config.get('markets') or 'US,HK').upper().split(',')), account_id=int(config.get('account_id') or 0))).fetch_snapshot()
    # Use the same normalization as the existing pipeline, without its writes or
    # process-global credential environment mutations.
    scripts = str(ROOT / 'scripts')
    if scripts not in sys.path:
        sys.path.insert(0, scripts)
    normalize = importlib.import_module('enrich_trading212_data').summarize_position
    authorization = base64.b64encode(f"{config['api_key']}:{config['api_secret']}".encode()).decode()
    def get(path):
        request = urllib.request.Request('https://live.trading212.com/api/v0/equity/' + path,
            headers={'Authorization': 'Basic ' + authorization, 'Accept': 'application/json'})
        with urllib.request.urlopen(request, timeout=25) as response:
            return json.load(response)
    info = get('account/info')
    cash = get('account/cash')
    positions = get('portfolio')
    if not isinstance(info, dict) or not info.get('id') or not isinstance(cash, dict) or not isinstance(positions, list):
        raise ValueError('券商返回的数据不完整。')
    label = 'Trading 212 · ' + str(info['id'])
    return {'provider': provider, 'positions': [normalize(row) | {'account': label, 'account_key': str(info['id']), 'account_currency': info.get('currencyCode')} for row in positions],
            'account_info': {label: info}, 'account_cash': {label: cash}, 'warnings': []}


def preview(account_id, csv_text=None):
    with _LOCK:
        account = deepcopy(_read()['accounts'].get(account_id))
    if not account:
        raise ValueError('账户不存在。')
    if account['provider'] == 'csv':
        raw = _csv_snapshot(account_id, csv_text)
    else:
        raw = None
    config = {} if account['provider'] == 'csv' else json.loads(data_store.secret_value(_secret_name(account_id)) or '{}')
    try:
        if raw is None:
            raw = _fetch(account['provider'], config)
    except Exception:
        # Provider exceptions can contain URLs or credential material.
        raise ValueError('连接失败，请检查凭证和本机网关后重试。现有数据已保留。') from None
    if raw.get('warnings'):
        raise ValueError('券商返回的数据不完整，请检查连接后重新预览。现有数据已保留。')
    info = raw.get('account_info') or {}
    if len(info) != 1:
        raise ValueError('请在连接配置中指定一个账户 ID，每个 Catfolio 账户对应一个券商账户。')
    source_label, source_info = next(iter(info.items()))
    identity = str(source_info.get('id') or '')
    if not identity:
        raise ValueError('券商未返回可验证的账户 ID。')
    identity = account['provider'] + ':' + identity
    if account.get('identity') and account['identity'] != identity:
        raise ValueError('连接返回了另一个券商账户；请通过添加账户导入。')
    raw = deepcopy(raw)
    raw['provider'] = account['provider']
    raw['label'] = SUPPORTED_BROKERS.get(account['provider'], 'CSV')
    raw['as_of_unix'] = int(time.time())
    _build(raw)  # Validate normalization before offering confirmation.
    token = secrets.token_urlsafe(32)
    with _LOCK:
        for key, value in list(_PREVIEWS.items()):
            if value['expires'] < time.time():
                del _PREVIEWS[key]
        if len(_PREVIEWS) >= 100:
            raise ValueError('待确认的预览过多，请稍后重试。')
        _PREVIEWS[token] = {'account_id': account_id, 'version': account['version'], 'raw': raw,
                            'identity': identity, 'source_label': source_label, 'expires': time.time() + 900}
    old = {p.get('normalized_ticker') or p.get('ticker') for p in (account.get('snapshot') or {}).get('positions', [])}
    new = {p.get('normalized_ticker') or p.get('ticker') for p in raw.get('positions', [])}
    return {'token': token, 'positions': raw.get('positions', []), 'currency': source_info.get('currencyCode'),
            'source_account': account['name'] if account['provider'] == 'csv' else source_label, 'added': len(new - old), 'removed': len(old - new),
            'empty': not new, 'expires_in': 900}


def commit(account_id, token):
    with _LOCK:
        pending = _PREVIEWS.get(token)
        store = _read()
        account = store['accounts'].get(account_id)
        if not pending or pending['expires'] < time.time() or pending['account_id'] != account_id:
            raise ValueError('预览已失效，请重新预览。')
        if not account or account['version'] != pending['version']:
            raise ValueError('账户已被修改，请重新预览。')
        if any(a.get('identity') == pending['identity'] and a['id'] != account_id for a in store['accounts'].values()):
            raise ValueError('这个券商账户已经存在，请在原账户中同步。')
        account.update(snapshot=pending['raw'], identity=pending['identity'], source_label=pending['source_label'],
                       updated_at=int(time.time()), version=account['version'] + 1)
        _save(store)
        del _PREVIEWS[token]
        return _public(account)


def update_account(account_id, name=None, selected=None):
    with _LOCK:
        store = _read()
        account = store['accounts'].get(account_id)
        if not account:
            raise ValueError('账户不存在。')
        if name is not None:
            if not str(name).strip() or len(str(name).strip()) > 80:
                raise ValueError('账户名称须为 1–80 个字符。')
            if any(a['name'].casefold() == str(name).strip().casefold() and a['id'] != account_id for a in store['accounts'].values()):
                raise ValueError('请使用不同的账户名称。')
            account['name'] = str(name).strip()
        if selected is not None:
            if not isinstance(selected, bool):
                raise ValueError('账户范围无效。')
            account['selected'] = selected
        account['version'] += 1
        _save(store)
        return _public(account)


def _legacy_rows(portfolio):
    rows = portfolio.get('holdings_by_account') or portfolio.get('holdings') or []
    result = []
    for row in rows:
        if 'holdings' in row:
            result.extend(dict(h, account=row.get('account', 'Imported')) for h in row['holdings'])
        else:
            result.append(dict(row, account=row.get('account') or row.get('accounts') or '已有组合'))
    return result


def legacy_accounts():
    portfolio = data_store.load_json(V2_DIR / 'portfolio_analysis.json', {})
    names = sorted({r['account'] for r in _legacy_rows(portfolio)})
    return names


def account_state():
    with _LOCK:
        store = _read()
        replaced = {a.get('replaces_account') for a in store['accounts'].values() if a.get('snapshot')}
        legacy = [{'name': name, 'selected': store.get('legacy', {}).get(name, {}).get('selected', True)}
                  for name in legacy_accounts() if name not in replaced and not store.get('legacy', {}).get(name, {}).get('deleted')]
        return {'accounts': [_public(a) | {'replaces_account': a.get('replaces_account')} for a in store['accounts'].values()], 'legacy': legacy}


def update_legacy(name, selected):
    with _LOCK:
        if name not in legacy_accounts() or not isinstance(selected, bool):
            raise ValueError('原账户或组合范围无效。')
        store = _read()
        store.setdefault('legacy', {}).setdefault(name, {})['selected'] = selected
        _save(store)


def delete_account(account_id):
    with _LOCK:
        store = _read()
        account = store['accounts'].get(account_id)
        if not account:
            raise ValueError('账户不存在。')
        if account['provider'] != 'csv' and not data_store.delete_secret(_secret_name(account_id)):
            raise ValueError('无法删除系统凭证，请重试。账户数据已保留。')
        if account.get('replaces_account') and account.get('snapshot'):
            store.setdefault('legacy', {}).setdefault(account['replaces_account'], {})['deleted'] = True
        del store['accounts'][account_id]
        _save(store)


def apply_accounts(snapshot):
    """Overlay managed accounts on the legacy snapshot without rewriting it.

    Reuse the pipeline's holding aggregation; cost/P&L formulas stay unchanged.
    Original files remain intact for rollback and CSV history reconciliation.
    """
    with _LOCK:
        store = _read()
    managed = [a for a in store['accounts'].values() if a.get('snapshot')]
    if not managed and not store.get('legacy'):
        return snapshot
    snapshot = deepcopy(snapshot)
    portfolio = snapshot['portfolio']
    replaced = {a.get('replaces_account') for a in managed}
    legacy = store.get('legacy', {})
    keep = lambda name: name not in replaced and not legacy.get(name, {}).get('deleted') and legacy.get(name, {}).get('selected', True)
    rows = [r for r in _legacy_rows(portfolio) if keep(r['account'])]
    broker = deepcopy(snapshot.get('broker') or snapshot.get('trading212') or {})
    broker['positions'] = [p for p in broker.get('positions', []) if keep(p.get('account') or 'Trading212 API')]
    for key in ('account_info', 'account_cash'):
        broker[key] = {k: v for k, v in broker.get(key, {}).items() if isinstance(v, dict) and keep(k)}
    quotes = {r['ticker']: deepcopy(r) for r in snapshot['market'].get('rows', []) if r.get('ticker')}
    # Quote availability is independent of portfolio inclusion.
    for account in managed:
        for position in account['snapshot'].get('positions', []):
            ticker = position.get('normalized_ticker') or position.get('ticker')
            if position.get('current_price') is not None and not quotes.get(ticker, {}).get('quote_price'):
                quotes[ticker] = {'quote_price': position['current_price'], 'quote_currency': position.get('currency')}
    summary = portfolio.setdefault('summary', {})
    for key in ('cash_movements_by_account_currency', 'interest_by_account_currency', 'dividends_by_account_currency'):
        summary[key] = {k: v for k, v in summary.get(key, {}).items() if keep(k.rsplit('_', 1)[0])}
    for account in managed:
        if not account['selected']:
            continue
        raw = deepcopy(account['snapshot'])
        # Account names are unique; raw persisted identity stays immutable.
        label = account['name']
        raw['account_info'] = {label: next(iter(raw['account_info'].values()))}
        raw['account_cash'] = {label: next(iter(raw.get('account_cash', {}).values()), {})}
        for position in raw['positions']:
            position['account'] = label
        for position in raw['positions']:
            ticker = position.get('normalized_ticker') or position.get('ticker')
            if position.get('current_price') is not None and not quotes.get(ticker, {}).get('quote_price'):
                quotes[ticker] = {'quote_price': position['current_price'], 'quote_currency': position.get('currency')}
        built = _build(raw)
        rows.extend(built['portfolio']['holdings_by_account'])
        broker['positions'].extend(raw['positions'])
        broker['account_info'].update(raw['account_info'])
        broker['account_cash'].update(raw['account_cash'])
        summary['cash_movements_by_account_currency'].update(built['portfolio']['summary']['cash_movements_by_account_currency'])
    aggregate = _aggregate_rows
    # Older CSV rows omit API-specific numeric fields expected by aggregation.
    numeric = ('shares', 'cost_native', 'cost_gbp_available', 'cost_usd_standard', 'api_market_value_gbp',
               'api_market_value_usd', 'api_unrealized_gbp', 'api_unrealized_usd', 'api_share_diff', 'buys', 'sells', 'stock_dividends')
    for row in rows:
        if row.get('cost_native') is None:
            row['cost_native'] = float(row.get('shares') or 0) * float(row.get('avg_cost_native') or 0)
        if row.get('api_market_value_usd') is None:
            quote = quotes.get(row['ticker'], {})
            if quote.get('quote_price') is not None:
                row['api_market_value_usd'] = data_store.usd_equivalent(float(quote['quote_price']) * float(row.get('shares') or 0), quote.get('quote_currency') or row.get('cost_currency'))
        if row.get('api_unrealized_usd') is None and row.get('api_market_value_usd') is not None:
            row['api_unrealized_usd'] = float(row['api_market_value_usd']) - float(row.get('cost_usd_standard') or 0)
        if row.get('broker_unrealized_usd') is None and row.get('api_unrealized_usd') is not None:
            row['broker_unrealized_usd'] = row['api_unrealized_usd']
        row['valuation_missing'] = row.get('api_market_value_usd') is None
        for key in numeric:
            if row.get(key) is None:
                row[key] = 0
    portfolio['holdings_by_account'] = rows
    portfolio['holdings'] = aggregate(rows)
    missing_tickers = {r['ticker'] for r in rows if r.get('valuation_missing')}
    for row in portfolio['holdings']:
        row['valuation_missing'] = row['ticker'] in missing_tickers
    summary['unpriced_tickers'] = sorted(missing_tickers)
    if missing_tickers:
        summary['warnings'] = list(summary.get('warnings') or []) + ['部分持仓尚无行情，市值与盈亏暂不包含这些持仓；请刷新行情。']
    summary['total_cost_usd_standard'] = sum(float(r.get('cost_usd_standard') or 0) for r in rows)
    summary['open_positions'] = len(portfolio['holdings'])
    summary['open_positions_by_account'] = len(rows)
    summary['broker_provider'] = 'accounts'
    summary['broker_label'] = '账户组合'
    summary['cost_scale_by_account_gbp_available'] = {}
    summary['cost_scale_by_currency'] = {}
    for row in rows:
        item = summary['cost_scale_by_account_gbp_available'].setdefault(row['account'], {'positions': 0, 'cost_gbp_available': 0})
        item['positions'] += 1
        item['cost_gbp_available'] += float(row.get('cost_gbp_available') or 0)
        currency = summary['cost_scale_by_currency'].setdefault(row.get('cost_currency') or 'USD', {'positions': 0, 'cost_native': 0, 'cost_gbp_available': 0})
        currency['positions'] += 1
        currency['cost_native'] += float(row.get('cost_native') or 0)
        currency['cost_gbp_available'] += float(row.get('cost_gbp_available') or 0)
    for prefix in ('interest', 'dividends'):
        by_currency = {}
        for key, value in summary.get(prefix + '_by_account_currency', {}).items():
            currency = key.rsplit('_', 1)[-1]
            by_currency[currency] = by_currency.get(currency, 0) + float(value or 0)
        summary[prefix + '_by_currency'] = by_currency
        summary[prefix + '_usd_standard'] = sum(data_store.usd_equivalent(v, c) or 0 for c, v in by_currency.items())
    portfolio['import_transactions'] = [t for t in portfolio.get('import_transactions', []) if keep(t.get('account') or 'Imported') or any(a.get('replaces_account') == t.get('account') and a['selected'] for a in managed)]
    for account in managed:
        if account['selected']:
            portfolio['import_transactions'].extend(dict(t, account=account['name']) for t in account['snapshot'].get('import_transactions', []))
    portfolio['closed_positions'] = [r for r in portfolio.get('closed_positions', []) if keep(r.get('account') or r.get('accounts') or 'Imported')]
    summary['transactions'] = len(portfolio['import_transactions'])
    summary['closed_positions'] = len(portfolio['closed_positions'])
    market_rows = []
    for row in portfolio['holdings']:
        quote = deepcopy(quotes.get(row['ticker']) or {})
        quote.update(ticker=row['ticker'], shares=row['shares'], cost_usd_standard=row['cost_usd_standard'])
        quote['market_value_usd'] = row.get('api_market_value_usd')
        quote['unrealized_usd'] = row.get('api_unrealized_usd')
        if not quote.get('quote_price'):
            quote['quote_price'] = row.get('last_trade_price')
            quote['quote_currency'] = row.get('cost_currency')
        market_rows.append(quote)
    snapshot['market']['rows'] = market_rows
    # The normalized account rows include both broker-reported P&L and the
    # existing price-difference fallback. Prevent a partial raw broker response
    # for one ticker from masking its holdings in another (e.g. CSV) account.
    broker['normalized_account_pnl'] = True
    broker['provider'] = 'accounts'
    broker['label'] = '账户组合'
    timestamps = [a['snapshot'].get('as_of_unix') for a in managed if a['selected'] and a['snapshot'].get('as_of_unix')]
    broker['as_of_unix'] = min(timestamps) if timestamps else broker.get('as_of_unix')
    snapshot['broker'] = broker
    snapshot['trading212'] = broker
    return snapshot


def _aggregate_rows(rows):
    """Aggregate account rows without depending on the optional pipeline package."""
    grouped = {}
    accounts_by_ticker = {}
    for row in rows:
        ticker = row.get('ticker')
        if not ticker:
            continue
        accounts_by_ticker.setdefault(ticker, set()).add(row.get('account') or '账户')
        if ticker not in grouped:
            grouped[ticker] = dict(row)
            continue
        target = grouped[ticker]
        for key in ('shares', 'cost_native', 'cost_gbp_available', 'cost_usd_standard',
                    'api_market_value_gbp', 'api_market_value_usd', 'api_unrealized_gbp',
                    'api_unrealized_usd', 'api_share_diff', 'broker_unrealized_usd',
                    'broker_fx_ppl_usd', 'price_unrealized_usd'):
            target[key] = float(target.get(key) or 0) + float(row.get(key) or 0)
        for key in ('buys', 'sells', 'stock_dividends'):
            target[key] = int(target.get(key) or 0) + int(row.get(key) or 0)
    for ticker, row in grouped.items():
        shares = float(row.get('shares') or 0)
        row['accounts'] = ','.join(sorted(accounts_by_ticker[ticker]))
        row['avg_cost_native'] = float(row.get('cost_native') or 0) / shares if shares else 0
        row['avg_cost_usd_standard'] = float(row.get('cost_usd_standard') or 0) / shares if shares else 0
        row['avg_cost_gbp_available'] = float(row.get('cost_gbp_available') or 0) / shares if shares else 0
    return sorted(grouped.values(), key=lambda row: float(row.get('cost_usd_standard') or 0), reverse=True)


def _csv_snapshot(account_id, text):
    from app.csv_import import parse_transactions, compute_holdings
    if not text or len(text.encode('utf-8')) > 5 * 1024 * 1024:
        raise ValueError('请选择不超过 5 MB 的 CSV 交易文件。')
    transactions, warnings = parse_transactions(text.lstrip('\ufeff'))
    if warnings or not transactions:
        raise ValueError('CSV 数据无法完整解析，请检查 Date、Action、Ticker、Quantity、Price 列。')
    import math
    if any(not math.isfinite(t['quantity']) or not math.isfinite(t['price']) or t['quantity'] < 0 or t['price'] < 0 for t in transactions):
        raise ValueError('CSV 包含无效的数量或价格。')
    holdings = compute_holdings(transactions)
    transactions = [dict(t, date=t['date'].isoformat()) for t in transactions]
    label = 'CSV · ' + account_id[:8]
    currencies = {t['currency'] for t in transactions}
    currency = next(iter(currencies)) if len(currencies) == 1 else 'MULTI'
    return {'provider': 'csv', 'csv_holdings': holdings, 'import_transactions': transactions,
            'positions': [dict(ticker=h['ticker'], normalized_ticker=h['ticker'], quantity=h['shares'],
                               average_price_paid=h['avg_cost_native'], currency=h['currency'], account=label) for h in holdings],
            'account_info': {label: {'id': account_id, 'currencyCode': currency}}, 'account_cash': {}, 'warnings': []}


def _build(raw):
    if raw.get('provider') != 'csv':
        return _broker_portfolio(raw)
    from app.csv_import import holdings_to_portfolio_json
    portfolio = holdings_to_portfolio_json(raw['csv_holdings'])
    label = next(iter(raw['account_info']))
    portfolio['holdings_by_account'] = [dict(row, account=label, accounts=label) for row in portfolio['holdings']]
    portfolio['summary']['cash_movements_by_account_currency'] = {}
    return {'portfolio': portfolio, 'market': {'rows': []}}
