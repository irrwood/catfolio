"""Call tracker tests. Everything runs offline; prices come from fakes or the fictional demo."""
from datetime import date, datetime, timedelta, timezone
import json
from pathlib import Path
import re

import pytest
from fastapi.testclient import TestClient

from app import call_tracker as ct

NOW = datetime(2026, 6, 30, 22, 0, tzinfo=timezone.utc)
STATIC = Path(__file__).parents[1] / 'app' / 'static'
DIGEST_ROW = {'date': '2026-01-02', 'channel': '示例频道', 'video_id': 'abcDEF12345', 'symbol': 'NVDA',
              'name': '英伟达', 'stance': '看多', 'reason': '需求强劲'}


def sessions(start='2026-01-05', count=80):
    days, day = [], date.fromisoformat(start)
    while len(days) < count:
        if day.weekday() < 5:
            days.append(day.isoformat())
        day += timedelta(days=1)
    return days


def rows(closes, start='2026-01-05'):
    return list(zip(sessions(start, len(closes)), closes))


def call(i, source='A', stance='bullish', day='2026-01-05'):
    return dict(id=i, source=source, call_date=day, ticker=f'T{i}', yahoo_symbol=f'T{i}', name=None,
                stance=stance, reason=None, url=None, imported_at='')


def outcome(status, ret=None, excess=None, hit=None):
    return dict(dict.fromkeys(ct.OUTCOME_FIELDS), status=status, ret=ret, excess=excess, hit=hit)


def line(**changes):
    return json.dumps({**DIGEST_ROW, **changes}, ensure_ascii=False)


# ── parsing ────────────────────────────────────────────────────────────────────

@pytest.mark.parametrize('raw, expected', [
    ('aapl', 'AAPL'), (' $tsla ', 'TSLA'), ('700.HK', '0700.HK'), ('00700.hk', '0700.HK'),
    ('9988.HK', '9988.HK'), ('AAPL.US', 'AAPL'), ('VOD.L', 'VOD.L'),
])
def test_symbols_normalise_to_the_yahoo_form(raw, expected):
    assert ct.normalize_symbol(raw) == (expected, expected)


@pytest.mark.parametrize('raw', ['BRK.B', 'brk-b', 'BRK.B.US'])
def test_class_shares_display_with_a_dot_and_price_with_a_dash(raw):
    assert ct.normalize_symbol(raw) == ('BRK.B', 'BRK-B')


@pytest.mark.parametrize('raw, expected', [('BTC', 'BTC-USD'), ('$eth', 'ETH-USD')])
def test_bare_crypto_tickers_map_to_yahoo_usd_pairs(raw, expected):
    assert ct.normalize_symbol(raw) == (expected, expected)  # Yahoo's bare BTC is a fund


@pytest.mark.parametrize('raw', ['', None, '腾讯', 'A B', 'X' * 30])
def test_invalid_symbols_are_rejected(raw):
    with pytest.raises(ValueError):
        ct.normalize_symbol(raw)


def test_stances_accept_the_digest_chinese_labels_and_english():
    assert [ct.normalize_stance(s) for s in ('看多', '看空', '中性', 'Bullish', 'bearish', 'neutral')] == [
        'bullish', 'bearish', 'neutral', 'bullish', 'bearish', 'neutral']
    with pytest.raises(ValueError):
        ct.normalize_stance('观望')


def test_digest_rows_map_channel_to_source_and_video_id_to_a_link():
    assert ct.parse_call(DIGEST_ROW) == dict(
        source='示例频道', call_date='2026-01-02', ticker='NVDA', yahoo_symbol='NVDA', name='英伟达',
        stance='bullish', reason='需求强劲', url='https://www.youtube.com/watch?v=abcDEF12345')
    assert ct.parse_call({**DIGEST_ROW, 'url': 'https://example.com/a'})['url'] == 'https://example.com/a'
    assert ct.parse_call({**DIGEST_ROW, 'url': 'javascript:alert(1)', 'video_id': ''})['url'] is None
    generic = {'date': '2026-01-02T09:30:00', 'source': 'My notes', 'ticker': '700.HK', 'stance': 'bearish'}
    assert ct.parse_call(generic)['source'] == 'My notes'
    assert ct.parse_call(generic)['ticker'] == '0700.HK'
    for bad, code in (({**DIGEST_ROW, 'channel': ' '}, 'source'), ({**DIGEST_ROW, 'date': '22/09/2026'}, 'date'),
                      ({**DIGEST_ROW, 'symbol': ''}, 'symbol'), ({**DIGEST_ROW, 'stance': '?'}, 'stance')):
        with pytest.raises(ValueError, match=code):
            ct.parse_call(bad)


# ── scoring ────────────────────────────────────────────────────────────────────

def test_entry_is_the_first_close_after_the_call_and_exit_counts_sessions():
    days = sessions(count=30)
    series = rows([100 + i for i in range(30)])
    scored = ct.score_call(days[2], 'bullish', series, series, 5, days[-1])
    assert (scored['entry_date'], scored['entry_close']) == (days[3], 103)
    assert (scored['exit_date'], scored['exit_close']) == (days[8], 108)
    assert scored['status'] == 'scored' and scored['hit'] == 1
    assert scored['ret'] == pytest.approx(108 / 103 - 1)
    assert scored['excess'] == pytest.approx(0)
    weekend = ct.score_call('2026-01-10', 'bullish', series, series, 5, days[-1])  # a Saturday
    assert weekend['entry_date'] == '2026-01-12'


def test_bearish_calls_score_the_negated_return_and_a_direction_adjusted_excess():
    stock = rows([100, 100, 95, 92, 90, 91, 90, 88])
    spy = rows([400, 400, 404, 406, 408, 404, 400, 398])
    days = [d for d, _ in stock]
    bearish = ct.score_call(days[0], 'bearish', stock, spy, 5, days[-1])
    assert bearish['ret'] == pytest.approx(-0.10) and bearish['bench_ret'] == pytest.approx(0)
    assert bearish['hit'] == 1 and bearish['excess'] == pytest.approx(0.10)
    bullish = ct.score_call(days[0], 'bullish', stock, spy, 5, days[-1])
    assert bullish['hit'] == 0 and bullish['excess'] == pytest.approx(-0.10)


def test_unchanged_price_counts_as_a_miss():
    flat = rows([50.0] * 10)
    assert ct.score_call(flat[0][0], 'bullish', flat, flat, 5, flat[-1][0])['hit'] == 0
    assert ct.score_call(flat[0][0], 'bearish', flat, flat, 5, flat[-1][0])['hit'] == 0


def test_unfinished_windows_are_pending_and_missing_prices_are_never_scored():
    series = rows([100 + i for i in range(10)])
    days = [d for d, _ in series]
    open_window = ct.score_call(days[6], 'bullish', series, series, 5, days[-1])
    assert open_window['status'] == 'pending' and open_window['entry_date'] == days[7]
    assert open_window['hit'] is None and open_window['ret'] is None
    assert ct.score_call(days[-1], 'bullish', series, series, 5, days[-1])['status'] == 'pending'
    assert ct.score_call(days[0], 'bullish', [], series, 5, days[-1])['status'] == 'missing_price'
    # A series that stopped long before the newest data is interrupted, not pending.
    assert ct.score_call(days[6], 'bullish', series, series, 5, '2026-03-31')['status'] == 'missing_price'
    # History that starts long after the call cannot price it.
    assert ct.score_call('2025-06-02', 'bullish', series, series, 5, days[-1])['status'] == 'missing_price'


def test_neutral_calls_show_the_price_change_but_are_never_scored():
    series = rows([100 + i for i in range(10)])
    neutral = ct.score_call(series[0][0], 'neutral', series, series, 5, series[-1][0])
    assert neutral['status'] == 'neutral' and neutral['ret'] == pytest.approx(106 / 101 - 1)
    assert neutral['hit'] is None and neutral['excess'] is None


def test_a_missing_benchmark_keeps_the_hit_but_not_the_excess():
    series = rows([100 + i for i in range(10)])
    scored = ct.score_call(series[0][0], 'bullish', series, [], 5, series[-1][0])
    assert scored['status'] == 'scored' and scored['hit'] == 1
    assert scored['bench_ret'] is None and scored['excess'] is None


def test_benchmark_uses_the_latest_close_on_or_before_non_us_session_dates():
    hk = [('2026-01-05', 100), ('2026-01-06', 101), ('2026-01-07', 102), ('2026-01-08', 110)]
    spy = [('2026-01-05', 200), ('2026-01-07', 210)]  # no SPY close on 01-06 or 01-08
    scored = ct.score_call('2026-01-04', 'bullish', hk, spy, 3, '2026-01-08')
    assert scored['exit_date'] == '2026-01-08'
    assert scored['bench_ret'] == pytest.approx(0.05) and scored['excess'] == pytest.approx(0.05)


def test_a_missing_close_does_not_stretch_the_window():
    days = sessions(count=30)
    spy = list(zip(days, [400.0] * 30))
    stock = [(d, 100.0 + i) for i, d in enumerate(days) if i != 4]  # Yahoo returned no close for days[4]
    counted = ct.score_call(days[0], 'bullish', stock, spy, 5, days[-1], sessions=days)
    assert (counted['entry_date'], counted['exit_date'], counted['exit_close']) == (days[1], days[6], 106)
    assert ct.score_call(days[0], 'bullish', stock, spy, 5, days[-1])['exit_date'] == days[7]  # own rows only
    on_gap = ct.score_call(days[0], 'bullish', stock, spy, 3, days[-1], sessions=days)
    assert (on_gap['exit_date'], on_gap['exit_close']) == (days[4], 103)  # last close before the exit
    by_market = ct.score_all([dict(id=1, call_date=days[0], stance='bullish', yahoo_symbol='COST')],
                             {'COST': stock, 'SPY': spy})
    assert by_market[(1, 5)]['exit_date'] == days[6]
    halted = [(d, c) for d, c in stock if not days[5] <= d <= days[20]]  # no trades for three weeks
    assert ct.score_call(days[0], 'bullish', halted, spy, 10, days[-1], sessions=days)['status'] == 'missing_price'


def test_non_us_listings_count_their_own_sessions():
    days = sessions(count=12)
    spy = list(zip(days, [400.0] * 12))
    hk = [(d, 50.0 + i) for i, d in enumerate(days) if i != 4]  # a Hong Kong holiday
    scored = ct.score_all([dict(id=1, call_date=days[0], stance='bullish', yahoo_symbol='0700.HK')],
                          {'0700.HK': hk, 'SPY': spy})
    assert scored[(1, 5)]['exit_date'] == days[7]


def test_unfinished_sessions_are_dropped_until_the_market_has_closed():
    new_york_3pm = datetime(2026, 9, 24, 19, 0, tzinfo=timezone.utc)
    new_york_5pm = datetime(2026, 9, 24, 21, 0, tzinfo=timezone.utc)
    assert ct.final_session_cutoff('AAPL', new_york_3pm) == '2026-09-23'
    assert ct.final_session_cutoff('AAPL', new_york_5pm) == '2026-09-24'
    assert ct.final_session_cutoff('0700.HK', datetime(2026, 9, 24, 7, 0, tzinfo=timezone.utc)) == '2026-09-23'
    assert ct.final_session_cutoff('0700.HK', datetime(2026, 9, 24, 9, 0, tzinfo=timezone.utc)) == '2026-09-24'
    assert ct.final_session_cutoff('BTC-USD', new_york_5pm) == '2026-09-23'


def test_default_price_source_shares_the_strategy_cache_and_trims_unfinished_bars(monkeypatch, tmp_path):
    from app import strategy_engine

    requests = []

    def fake_get_prices(symbols, years=5):
        requests.append((tuple(symbols), years))
        return {'AAPL': [{'date': '2026-09-23', 'close': 1.5}, {'date': '2026-09-24', 'close': 2.0}]}, []

    cache = tmp_path / 'strategy_prices.json'
    fetched = int(datetime(2026, 9, 24, 19, 0, tzinfo=timezone.utc).timestamp())  # 15:00 in New York
    cache.write_text(json.dumps({'AAPL': {'as_of': fetched, 'rows': []}}), encoding='utf-8')
    monkeypatch.setattr(strategy_engine, 'get_prices', fake_get_prices)
    monkeypatch.setattr(strategy_engine, 'PRICE_CACHE', cache)
    prices, _ = ct.yahoo_prices(['AAPL'], start_date='2026-09-01', now=datetime(2026, 9, 25, tzinfo=timezone.utc))
    assert prices == {'AAPL': [('2026-09-23', 1.5)]}
    assert requests == [(('AAPL',), 5)]


# ── summaries ──────────────────────────────────────────────────────────────────

def test_metrics_keep_pending_missing_and_neutral_calls_out_of_denominators():
    pairs = [
        (call(1), outcome('scored', .10, .04, 1)),
        (call(2, stance='bearish'), outcome('scored', .05, -.02, 0)),
        (call(3), outcome('scored', .30, .20, 1)),
        (call(4), outcome('pending')),
        (call(5), outcome('missing_price')),
        (call(6, stance='neutral'), outcome('neutral', .5)),
        (call(7), None),
    ]
    m = ct.metrics(pairs)
    assert (m['calls'], m['directional'], m['neutral'], m['scored']) == (7, 6, 1, 3)
    assert (m['pending'], m['missing'], m['uncomputed']) == (1, 1, 1)
    assert m['hits'] == 2 and m['hit_rate'] == pytest.approx(2 / 3)
    assert m['avg_return'] == pytest.approx((.10 - .05 + .30) / 3)
    assert m['avg_excess'] == pytest.approx((.04 - .02 + .20) / 3)
    assert m['median_excess'] == pytest.approx(.04)
    assert m['top_contribution']['ticker'] == 'T3'
    assert m['top_contribution']['share'] == pytest.approx(.30 / .40)
    assert m['status'] == 'watch'


def test_sources_need_ten_scored_calls_before_they_leave_watch_status():
    pairs = [(call(i), outcome('scored', .01, 0, 1)) for i in range(9)] + [(call(99), outcome('pending'))]
    assert ct.metrics(pairs)['status'] == 'watch'
    assert ct.metrics(pairs + [(call(100), outcome('scored', -.01, 0, 0))])['status'] == 'ready'


def _dataset(spec):
    """spec: {source: [(stance, {horizon: hit or None})]} -> in-memory dataset."""
    calls, outcomes = [], {}
    for source, items in spec.items():
        for stance, hits in items:
            c = call(len(calls) + 1, source, stance)
            calls.append(c)
            for horizon in ct.HORIZONS:
                hit = hits.get(horizon)
                outcomes[(c['id'], horizon)] = (outcome('pending') if hit is None
                                                else outcome('scored', .05 if hit else -.05, .01 if hit else -.01, hit))
    return dict(calls=calls, outcomes=outcomes, prices={}, meta={}, demo=False)


def test_overall_table_ranks_by_63_day_hit_rate_and_puts_thin_samples_last():
    data = _dataset({
        'A': [('bullish', {5: 1, 21: 1, 63: int(i < 6)}) for i in range(10)],
        'B': [('bullish', {5: 0, 21: 0, 63: int(i < 8)}) for i in range(10)],
        'C': [('bullish', {5: 1, 21: 1, 63: 1}) for _ in range(3)],
    })
    table = ct.summary(21, data)
    assert [r['source'] for r in table['sources']] == ['B', 'A', 'C']
    assert [r['status'] for r in table['sources']] == ['ready', 'ready', 'watch']
    assert table['sources'][0]['hit_rate'] == 0 and table['sources'][0]['rank_hit_rate'] == pytest.approx(.8)
    assert table['totals']['calls'] == 23 and table['totals']['sources'] == 3


def test_without_63_day_results_the_selected_horizon_breaks_the_tie():
    data = _dataset({'A': [('bullish', {5: 0})] * 2, 'B': [('bullish', {5: 1})] * 2})
    assert [r['source'] for r in ct.summary(5, data)['sources']] == ['B', 'A']


def test_monthly_hit_rate_groups_by_the_call_month_on_a_continuous_axis():
    pairs = [
        (call(1, day='2026-01-30'), outcome('scored', .1, 0, 1)),
        (call(2, day='2026-01-02'), outcome('scored', -.1, 0, 0)),
        (call(3, day='2026-03-03'), outcome('pending')),
        (call(4, stance='neutral', day='2026-03-04'), outcome('neutral', .2)),
    ]
    months = ct.monthly_hits(pairs)
    assert [m['month'] for m in months] == ['2026-01', '2026-02', '2026-03']
    assert (months[0]['scored'], months[0]['hit_rate']) == (2, .5)
    assert (months[1]['scored'], months[1]['hit_rate']) == (0, None)
    assert (months[2]['pending'], months[2]['scored']) == (1, 0)


def test_follow_every_call_curve_weights_open_positions_by_value():
    prices = {
        'X': [('2026-01-05', 100), ('2026-01-06', 110), ('2026-01-07', 121)],
        'Y': [('2026-01-05', 60), ('2026-01-06', 50), ('2026-01-07', 45)],
        'SPY': [('2026-01-05', 100), ('2026-01-06', 100), ('2026-01-07', 102)],
    }
    curve = ct.follow_curve([('X', 1, '2026-01-05', '2026-01-07'), ('Y', -1, '2026-01-06', '2026-01-07')], prices)
    assert curve['dates'] == ['2026-01-05', '2026-01-06', '2026-01-07']
    assert curve['follow'] == pytest.approx([1, 1.1, 1.21])  # long X +10% twice; short Y +10% on day two
    assert curve['benchmark'] == pytest.approx([1, 1, 1])  # long SPY +2% and short SPY -2% cancel
    assert curve['calls'] == 2
    assert ct.follow_curve([], prices) == dict(dates=[], follow=[], benchmark=[], calls=0)
    gap = {'X': prices['X'][:2], 'SPY': prices['SPY']}  # no close on the exit session
    curve = ct.follow_curve([('X', 1, '2026-01-05', '2026-01-07')], gap)
    assert curve['dates'] == ['2026-01-05', '2026-01-06', '2026-01-07'] and curve['follow'] == pytest.approx([1, 1.1, 1.1])


# ── storage ────────────────────────────────────────────────────────────────────

def test_import_dedupes_by_source_date_and_ticker_and_reports_bad_lines(tmp_path):
    db = tmp_path / 'calls.db'
    lines = [line(), line(reason='重复'), line(symbol='700.HK'), line(symbol='00700.HK'),
             '{not json', line(stance='观望'), '', json.dumps([1, 2])]
    first = ct.import_jsonl(lines, db_path=db)
    assert (first['read'], first['inserted'], first['duplicates'], first['invalid']) == (7, 2, 2, 3)
    assert first['errors'] == [dict(line=5, code='json'), dict(line=6, code='stance'), dict(line=8, code='object')]
    again = ct.import_jsonl(lines, db_path=db)
    assert (again['inserted'], again['duplicates']) == (0, 4)
    data = ct.load_dataset(db)
    assert [c['ticker'] for c in data['calls']] == ['NVDA', '0700.HK']
    assert data['calls'][0]['reason'] == '需求强劲'  # the first record wins
    assert ct.load_dataset(tmp_path / 'missing.db')['calls'] == []


def test_file_imports_check_the_path_before_reading(tmp_path):
    db = tmp_path / 'calls.db'
    (tmp_path / 'calls.csv').write_text('date,symbol\n', encoding='utf-8')
    (tmp_path / 'latin.jsonl').write_bytes('{"source": "caf\xe9"}'.encode('latin-1'))
    for target, code in ((tmp_path / 'missing.jsonl', 'not_found'), (tmp_path, 'not_a_file'),
                         (tmp_path / 'calls.csv', 'bad_suffix'), (tmp_path / 'latin.jsonl', 'not_utf8')):
        with pytest.raises(ct.CallImportError) as error:
            ct.import_jsonl(target, db_path=db)
        assert error.value.code == code


def _prices_for(symbols, closes=None):
    days = sessions('2026-01-05', 80)
    series = {s: list(zip(days, closes or [100 + i for i in range(80)])) for s in symbols if s != 'UNLISTED'}
    series['SPY'] = list(zip(days, [400.0] * 80))
    return series


def test_compute_stores_outcomes_and_reuses_saved_prices_when_a_fetch_fails(tmp_path):
    db = tmp_path / 'calls.db'
    ct.import_jsonl([line(symbol='AAA'), line(symbol='UNLISTED'), line(symbol='BBB', stance='看空')], db_path=db)
    stats = ct.compute_outcomes(lambda symbols: (_prices_for(symbols), []), db_path=db, now=NOW)
    assert stats['calls'] == 3 and stats['missing_symbols'] == ['UNLISTED']
    assert stats['statuses']['63'] == dict(scored=2, neutral=0, pending=0, missing_price=1)
    data = ct.load_dataset(db, with_prices=True)
    assert data['outcomes'][(1, 63)]['hit'] == 1 and data['outcomes'][(3, 63)]['hit'] == 0
    assert data['meta']['price_as_of'] == data['prices']['SPY'][-1][0]
    assert data['meta']['computed_at'] == '2026-06-30T22:00:00+00:00'
    retry = ct.compute_outcomes(lambda symbols: ({}, ['network down']), db_path=db, now=NOW)
    assert retry['reused_symbols'] == ['AAA', 'BBB', 'SPY']
    assert retry['statuses'] == stats['statuses']
    assert ct.load_dataset(db)['outcomes'] == data['outcomes']


def test_stored_bare_crypto_calls_are_renamed_so_reimports_add_no_duplicates(tmp_path):
    db, source = tmp_path / 'calls.db', tmp_path / 'calls.jsonl'
    source.write_text(line(symbol='BTC', name='比特币') + '\n', encoding='utf-8')
    conn = ct.connect(db)
    with conn:  # as an earlier version stored them: bare BTC, plus a BTC-USD twin imported later
        for ticker in ('BTC', 'BTC-USD'):
            conn.execute('INSERT INTO calls (source, call_date, ticker, yahoo_symbol, stance, imported_at, dedupe_key) '
                         "VALUES ('示例频道', '2026-01-02', ?, ?, 'bullish', '', ?)",
                         (ticker, ticker, f'示例频道|2026-01-02|{ticker}'))
        conn.execute("INSERT INTO outcomes (call_id, horizon_days, status) VALUES (1, 5, 'scored')")
    conn.close()
    first = ct.import_jsonl(source, db_path=db)
    assert (first['inserted'], first['duplicates']) == (0, 1)
    data = ct.load_dataset(db)
    assert [(c['id'], c['ticker'], c['yahoo_symbol']) for c in data['calls']] == [(1, 'BTC-USD', 'BTC-USD')]
    assert data['outcomes'] == {}  # they priced the fund; the next recalculation redoes them
    fetched = []

    def prices(symbols):
        fetched.append(list(symbols))
        return _prices_for(symbols), []

    again = ct.refresh(prices, db_path=db, now=NOW)
    assert (again['imported']['inserted'], again['imported']['duplicates']) == (0, 1)
    assert fetched == [['BTC-USD', 'SPY']]
    data = ct.load_dataset(db)
    assert len(data['calls']) == 1 and data['outcomes'][(1, 63)]['status'] == 'scored'


def test_refresh_rereads_the_remembered_file(tmp_path):
    db, source = tmp_path / 'calls.db', tmp_path / 'calls.jsonl'
    source.write_text(line() + '\n', encoding='utf-8')
    assert ct.import_jsonl(source, db_path=db)['inserted'] == 1
    with source.open('a', encoding='utf-8') as handle:
        handle.write(line(date='2026-01-05') + '\n')
    result = ct.refresh(lambda symbols: (_prices_for(symbols), []), db_path=db, now=NOW)
    assert result['imported']['inserted'] == 1 and result['computed']['calls'] == 2


# ── demo ───────────────────────────────────────────────────────────────────────

def test_demo_is_deterministic_offline_and_fictional(monkeypatch):
    monkeypatch.setattr(ct, 'yahoo_prices', lambda *args, **kwargs: pytest.fail('demo must not fetch prices'))
    ct._demo_base.cache_clear()
    ct.demo_dataset.cache_clear()
    first = ct.demo_dataset('zh')
    ct._demo_base.cache_clear()
    ct.demo_dataset.cache_clear()
    assert ct.demo_dataset('zh') == first
    assert len(first['calls']) == 120
    assert {c['source'] for c in first['calls']} == {'示例博主·甲', '示例博主·乙', '示例博主·丙', '示例机构'}
    assert {c['source'] for c in ct.demo_dataset('en')['calls']} == {
        'Sample blogger A', 'Sample blogger B', 'Sample blogger C', 'Sample institution'}
    assert all(c['url'] is None for c in first['calls'])
    assert {'scored', 'pending', 'neutral'} <= {o['status'] for o in first['outcomes'].values()}
    table = ct.summary(63, first)
    assert table['demo'] and table['sources'][-1]['status'] == 'watch'
    lead = ct.summary(21, first)['sources'][0]
    assert (lead['source'], lead['hits'], lead['scored']) == ('示例博主·甲', 25, 35)


# ── API and page ───────────────────────────────────────────────────────────────

def fake_yahoo(symbols, start_date=None, now=None):
    return _prices_for(symbols), []


@pytest.fixture
def real_client(monkeypatch, tmp_path):
    from app.main import app
    from app.routes import call_tracker as route

    monkeypatch.delenv('CATFOLIO_PUBLIC_DEMO', raising=False)
    monkeypatch.setattr(ct, 'DB_PATH', tmp_path / 'call_tracker.db')
    monkeypatch.setattr(ct, 'yahoo_prices', fake_yahoo)
    monkeypatch.setattr(route, 'demo_mode', lambda: False)
    return TestClient(app)


def test_api_imports_computes_and_pages_calls(real_client, tmp_path):
    assert real_client.get('/api/calls/summary').json()['empty'] is True
    source = tmp_path / 'calls.jsonl'
    source.write_text('\n'.join([line(), line(), line(symbol='AAPL', channel='A/B 资本'), line(symbol='MSFT', stance='中性')]),
                      encoding='utf-8')
    imported = real_client.post('/api/calls/import', json={'path': str(source)}).json()
    assert (imported['ok'], imported['inserted'], imported['duplicates']) == (True, 3, 1)
    upload = real_client.post('/api/calls/import', files={'file': ('more.jsonl', line(symbol='TSLA').encode(), 'application/json')})
    assert upload.json()['inserted'] == 1
    before = real_client.get('/api/calls/summary').json()
    assert before['totals']['calls'] == 4 and before['totals']['uncomputed'] == 3 and before['updated_at'] is None
    refreshed = real_client.post('/api/calls/refresh').json()
    assert refreshed['imported']['inserted'] == 0 and refreshed['computed']['calls'] == 4
    table = real_client.get('/api/calls/summary?horizon=5').json()
    assert table['totals']['scored'] == 3 and table['totals']['neutral'] == 1 and table['price_as_of']
    assert {r['source'] for r in table['sources']} == {'示例频道', 'A/B 资本'}
    detail = real_client.get('/api/calls/source/A%2FB%20%E8%B5%84%E6%9C%AC', params={'horizon': 21}).json()
    assert detail['source'] == 'A/B 资本' and detail['metrics']['scored'] == 1 and detail['curve']['calls'] == 1
    events = real_client.get('/api/calls/events', params={'source': '示例频道', 'horizon': 63}).json()
    assert events['total'] == 3 and [e['ticker'] for e in events['items']] == ['TSLA', 'MSFT', 'NVDA']
    assert events['items'][2]['url'] == 'https://www.youtube.com/watch?v=abcDEF12345'
    assert real_client.get('/api/calls/events', params={'page': 9}).json()['items'] == []


@pytest.mark.parametrize('path, status', [
    ('/api/calls/summary?horizon=7', 422), ('/api/calls/events?page=0', 422),
    ('/api/calls/source/nobody', 404), ('/api/calls/source/nobody?horizon=10', 422),
])
def test_api_validates_parameters(real_client, path, status):
    assert real_client.get(path).status_code == status


@pytest.mark.parametrize('payload, code', [
    ({'path': 'calls.jsonl'}, 'relative_path'), ({'path': '/no/such/calls.jsonl'}, 'not_found'),
    ({}, 'no_file'), ([], 'no_file'),
])
def test_import_errors_carry_codes_the_page_can_translate(real_client, payload, code):
    response = real_client.post('/api/calls/import', json=payload)
    assert response.status_code == 400 and response.json()['detail']['code'] == code


def test_oversized_uploads_are_refused(real_client, monkeypatch):
    monkeypatch.setattr(ct, 'MAX_IMPORT_BYTES', 10)
    response = real_client.post('/api/calls/import', files={'file': ('calls.jsonl', line().encode(), 'application/json')})
    assert response.status_code == 400 and response.json()['detail']['code'] == 'too_large'


def test_demo_mode_serves_fictional_data_and_refuses_writes(monkeypatch):
    from app.main import app
    from app.routes import call_tracker as route

    monkeypatch.delenv('CATFOLIO_PUBLIC_DEMO', raising=False)
    monkeypatch.setattr(route, 'demo_mode', lambda: True)
    monkeypatch.setattr(ct, 'load_dataset', lambda *args, **kwargs: pytest.fail('demo must not read local calls'))
    client = TestClient(app)
    table = client.get('/api/calls/summary', headers={'Cookie': 'catfolio_lang=zh'}).json()
    assert table['demo'] and len(table['sources']) == 4
    assert client.get('/api/calls/source/Sample blogger A', headers={'Cookie': 'catfolio_lang=en'}).status_code == 200
    for path in ('/api/calls/import', '/api/calls/refresh'):
        response = client.post(path, json={'path': '/tmp/calls.jsonl'})
        assert response.status_code == 409 and response.json()['detail']['code'] == 'demo'


def test_public_demo_blocks_imports(monkeypatch, tmp_path):
    from app import data_store
    from app.main import app

    monkeypatch.setenv('CATFOLIO_PUBLIC_DEMO', '1')
    monkeypatch.setattr(data_store, '_DEMO_FLAG', tmp_path / 'demo_mode.flag')
    client = TestClient(app)
    assert client.get('/api/calls/summary').json()['demo'] is True
    for path in ('/api/calls/import', '/api/calls/refresh'):
        response = client.post(path, json={})
        assert response.status_code == 403
        assert response.json()['error'] == 'This public Catfolio demo is read-only.'


def _main(html):
    return html[html.index('<main class="calls-page"'):html.index('</main>')]


def test_real_page_renders_in_chinese_and_english(real_client):
    zh = real_client.get('/calls', headers={'Cookie': 'catfolio_lang=zh'})
    assert zh.status_code == 200
    for contract in ('v5-shell', 'design-system.css', 'call-tracker.css', 'call-tracker.js', '观点记分牌',
                     '仅供复盘，不构成投资建议。', 'id="calls-import-form"', 'data-demo="0"',
                     'class="v5-nav-link active" href="/calls"'):
        assert contract in zh.text
    en = real_client.get('/calls', headers={'Cookie': 'catfolio_lang=en'})
    assert '<title>Call tracker · Catfolio</title>' in en.text
    assert 'For review only. Not investment advice.' in en.text and 'Import and calculate' in en.text
    assert not re.findall(r'[\u4e00-\u9fff]', _main(en.text))


def test_demo_page_has_no_import_form_and_is_fully_translated(monkeypatch):
    from starlette.requests import Request
    from app.routes import call_tracker as route

    monkeypatch.setattr(route, 'demo_mode', lambda: True)
    for lang in ('zh', 'en'):
        request = Request({'type': 'http', 'method': 'GET', 'path': '/calls', 'query_string': b'',
                           'headers': [(b'cookie', f'catfolio_lang={lang}'.encode())]})
        html = route.page(request).body.decode('utf-8')
        assert 'data-demo="1"' in html and 'calls-import-form' not in html
        assert ('Turn off demo mode' in html) if lang == 'en' else ('固定随机种子' in html)
    assert not re.findall(r'[\u4e00-\u9fff]', _main(html))


def test_sidebar_lists_the_call_tracker_after_strategy_lab():
    from app.components import _V5_NAV_GROUPS

    items = _V5_NAV_GROUPS[0][1]
    hrefs = [href for href, _, _ in items]
    assert items[hrefs.index('/strategy') + 1] == ('/calls', '观点记分牌', 'list-view.svg')


def test_page_script_marks_user_data_as_untranslated():
    script = (STATIC / 'call-tracker.js').read_text(encoding='utf-8')
    assert script.count("translate: 'no'") >= 3  # source names, company names and reasons


# ── client-side i18n ───────────────────────────────────────────────────────────

def test_client_i18n_leaves_translate_no_content_alone():
    script = (STATIC / 'client_i18n.js').read_text(encoding='utf-8')
    assert 'const KEEP = "[translate=\'no\']";' in script
    assert 'root.parentElement.closest(KEEP)' in script
    assert 'root.closest && root.closest(KEEP)' in script
    assert 'parent.closest(KEEP)' in script
