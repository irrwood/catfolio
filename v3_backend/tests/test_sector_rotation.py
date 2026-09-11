from contextlib import closing
from datetime import datetime, timezone, timedelta
import json
import math
import sqlite3
import pytest
from app import sector_rotation as r

NOW = datetime(2026, 9, 10, 23, tzinfo=timezone.utc)

@pytest.fixture
def prices():
    days = [s.date().isoformat() for s in r.calendar().sessions_in_range('2024-12-01', '2026-09-10')][-400:]
    return {symbol: {d: 100 * math.exp(.0003*i + (.08*math.sin(i/24+j*.55) + .025*math.cos(i/7+j)) * (symbol != 'SPY'))
                     for i, d in enumerate(days)} for j, symbol in enumerate(r.SYMBOLS)}

def provider(prices):
    return lambda symbol, now: prices[symbol]

def test_exact_nonoverlapping_windows(prices):
    rows = list(r.compute(prices))
    d, sectors = rows[-1]
    days = sorted(prices['SPY']);t = days.index(d)
    def s(i):
        return sum(math.log(prices['XLK'][days[k]]) - math.log(prices['SPY'][days[k]]) for k in range(i-4,i+1))/5
    x,y = s(t-21)-s(t-63),s(t)-s(t-21)
    assert sectors[0]['xRaw'] == pytest.approx(x)
    assert sectors[0]['yRaw'] == pytest.approx(y)
    assert sectors[0]['relativeTrend'] == pytest.approx(math.expm1(x))
    changed = {symbol: dict(values) for symbol,values in prices.items()}
    changed['XLK'][d] *= 1.1
    new = list(r.compute(changed))[-1][1][0]
    assert new['xRaw'] == sectors[0]['xRaw']
    assert new['yRaw'] != sectors[0]['yRaw']

def test_minimum_history_and_intersection(prices):
    days=sorted(prices['SPY'])
    assert len(list(r.compute({s:{d:p for d,p in ps.items() if d in days[:68]} for s,ps in prices.items()}))) == 1
    prices['XLC'].pop(days[-2])
    prices['XLK'][days[-1]] = float('nan')
    assert not {days[-1],days[-2]} & {d for d,_ in r.compute(prices)}

def test_mad_zero_and_outlier():
    assert r.normalize([3]*11) == [0]*11
    values = r.normalize(list(range(10))+[1e5])
    assert all(-2.5 <= x <= 2.5 for x in values)
    assert values[0] < values[1] < values[8] < values[9]
    assert abs(values[0]) > .5

def test_hysteresis_and_missing_session():
    initial=r.label_state('leading')
    first=r.label_state('weakening',initial)
    assert first['quadrant']=='leading'
    assert r.label_state('weakening',first)['quadrant']=='weakening'
    assert r.label_state('weakening',first,False)['quadrant']=='leading'
    assert r.label_state('neutral',initial)['quadrant']=='neutral'
    assert r.quadrant(.249,-.249)=='neutral'
    assert r.quadrant(.25,.25)=='leading'

def test_immutable_snapshots_and_no_future(tmp_path,prices):
    db=tmp_path/'test.sqlite'
    r.run_batch(db,now=NOW,provider=provider(prices))
    with closing(sqlite3.connect(db)) as conn:
        before=conn.execute('SELECT date,payload FROM snapshots ORDER BY date').fetchall()
        assert len(before)==60
        assert conn.execute('SELECT COUNT(*) FROM prices').fetchone()[0] == 4800
    for d in prices['XLK']: prices['XLK'][d] *= .95
    assert r.run_batch(db,now=NOW,provider=provider(prices))['inserted']==0
    with closing(sqlite3.connect(db)) as conn:
        assert before==conn.execute('SELECT date,payload FROM snapshots ORDER BY date').fetchall()
    payload=r.read_snapshot(db,now=NOW)
    assert not payload['stale']
    assert all(len(s['trail'])==8 for s in payload['sectors'])
    earlier=r.read_snapshot(db,as_of=before[30][0],now=NOW)
    assert earlier['historical']
    assert all(p['date']<earlier['asOf'] for s in earlier['sectors'] for p in s['trail'])
    assert all(p['date']<'2026-09-07' for s in payload['sectors'] for p in s['trail'])

def test_missing_target_and_failure_keeps_previous(tmp_path,prices):
    db=tmp_path/'test.sqlite'
    previous=NOW-timedelta(days=1)
    r.run_batch(db,now=previous,provider=provider(prices))
    prices['XLC'].pop('2026-09-10')
    with pytest.raises(ValueError,match='incomplete'):
        r.run_batch(db,now=NOW,provider=provider(prices))
    result=r.read_snapshot(db,now=NOW)
    assert result['asOf']=='2026-09-09' and result['stale']
    with pytest.raises(RuntimeError):
        r.run_batch(db,now=NOW,provider=lambda *_: (_ for _ in ()).throw(RuntimeError('provider unavailable')))
    assert r.read_snapshot(db,now=NOW)['sectors']==result['sectors']

def test_calendar_holiday_dst_and_readiness():
    assert r.expected_session(datetime(2026,9,7,23,tzinfo=timezone.utc))=='2026-09-04' # Labor Day
    assert r.expected_session(datetime(2026,9,10,22,29,tzinfo=timezone.utc))=='2026-09-09'
    assert r.expected_session(datetime(2026,9,10,22,31,tzinfo=timezone.utc))=='2026-09-10'
    assert r.expected_session(datetime(2026,1,6,23,29,tzinfo=timezone.utc))=='2026-01-05'
    assert r.expected_session(datetime(2026,1,6,23,31,tzinfo=timezone.utc))=='2026-01-06'

def test_weekly_holiday_endpoint(tmp_path,prices):
    db=tmp_path/'test.sqlite'
    now=datetime(2026,7,10,23,tzinfo=timezone.utc)
    r.run_batch(db,now=now,provider=provider(prices))
    snapshot=r.read_snapshot(db,now=now)
    trail=snapshot['sectors'][0]['trail']
    assert trail[-1]['date']=='2026-07-02' # Friday July 3 is a market holiday

def test_diagnostics_report_without_fitting(tmp_path,prices):
    db=tmp_path/'test.sqlite';r.run_batch(db,now=NOW,provider=provider(prices))
    diagnostic=r.validate_history(db)
    assert diagnostic['days']==60
    assert len(diagnostic['dailyCorrelations'])==60
    assert sum(diagnostic['quadrantShares'].values()) <= 1

def test_routes_and_no_live_fetch(monkeypatch,tmp_path):
    from fastapi.testclient import TestClient
    from app.main import app
    client=TestClient(app)
    monkeypatch.setattr(r,'DB_PATH',tmp_path/'missing.sqlite')
    monkeypatch.setattr(r,'fetch_adjusted',lambda *_: pytest.fail('API must not fetch prices'))
    payload=client.get('/api/sector-rotation').json()
    assert payload['status']=='unavailable' and payload['stale']
    assert client.get('/api/sector-rotation?asOf=bad').status_code==422
    page=client.get('/rotation?ui=v5', headers={'Accept-Language':'zh-CN'})
    assert page.status_code==200
    for contract in ['v5-shell','design-system.css','rotation-plot','rotation-date','sector-rotation.js','不构成投资建议']:
        assert contract in page.text

def test_backfill_coordinates_only_use_observed_prefix(prices):
    all_rows=list(r.compute(prices));d, expected=all_rows[120]
    prefix={s:{day:p for day,p in rows.items() if day<=d} for s,rows in prices.items()}
    assert list(r.compute(prefix))[-1] == (d,expected)

def test_version_isolation(tmp_path,prices):
    db=tmp_path/'test.sqlite';r.run_batch(db,now=NOW,provider=provider(prices))
    with closing(sqlite3.connect(db)) as conn, conn:
        conn.execute("INSERT INTO snapshots SELECT 1,date,replace(payload, '\"x\":', '\"not_x\":') FROM snapshots")
    result=r.read_snapshot(db,now=NOW)
    assert result['calcVersion']==2
    assert all(len(s['trail'])==8 for s in result['sectors'])

def test_provider_rejects_raw_close_fallback(monkeypatch):
    import io
    fake={'chart': {'result': [{'timestamp': [1000000000], 'indicators': {'quote': [{'close': [100]}]}}]}}
    monkeypatch.setattr(r,'urlopen',lambda *args,**kwargs:io.StringIO(json.dumps(fake)))
    with pytest.raises(ValueError,match='adjusted close unavailable'):
        r.fetch_adjusted('XLK',NOW)

def test_calendar_failure_still_serves_stale_snapshot(tmp_path,prices,monkeypatch):
    db=tmp_path/'test.sqlite';r.run_batch(db,now=NOW,provider=provider(prices))
    monkeypatch.setattr(r,'calendar',lambda: (_ for _ in ()).throw(RuntimeError('calendar unavailable')))
    result=r.read_snapshot(db,now=NOW)
    assert result['stale'] and len(result['sectors'])==11
