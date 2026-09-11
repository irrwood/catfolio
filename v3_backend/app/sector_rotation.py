"""Versioned, immutable end-of-day sector observations. Not JdK RRG or signals."""
from contextlib import closing
from datetime import date, datetime, timedelta, timezone
from functools import lru_cache
import json
import math
from pathlib import Path
import sqlite3
import ssl
import certifi
from statistics import median, correlation
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo

from app.settings import DATA_DIR

VERSION = 2
DB_PATH = DATA_DIR / 'sector_rotation.sqlite'
SECTORS = (
    ('XLK', 'Technology', '科技'), ('XLF', 'Financials', '金融'),
    ('XLE', 'Energy', '能源'), ('XLV', 'Health Care', '医疗'),
    ('XLY', 'Consumer Discretionary', '可选消费'), ('XLP', 'Consumer Staples', '必需消费'),
    ('XLI', 'Industrials', '工业'), ('XLB', 'Materials', '原材料'),
    ('XLU', 'Utilities', '公用事业'), ('XLRE', 'Real Estate', '房地产'),
    ('XLC', 'Communication Services', '通信服务'),
)
SYMBOLS = ('SPY',) + tuple(s[0] for s in SECTORS)
LABELS = dict(leading='领先', weakening='减弱', lagging='落后', improving='改善', neutral='中性')
PRESET = {'trendWindow': [63, 21], 'momentumWindow': [21, 0], 'smoothing': 5}
DISCLAIMER = '展示板块相对 SPY 的趋势和动量，仅供市场观察，不构成投资建议。'


@lru_cache(maxsize=1)
def calendar():
    import exchange_calendars
    return exchange_calendars.get_calendar('XNYS')


def expected_session(now=None):
    now = now or datetime.now(timezone.utc)
    sessions = calendar().sessions_in_range((now - timedelta(days=14)).date().isoformat(), now.date().isoformat())
    # A fixed 23:45 UTC daily batch is later than this readiness allowance in both seasons.
    ready = [s for s in sessions if calendar().session_close(s).to_pydatetime() + timedelta(hours=2, minutes=30) <= now]
    return ready[-1].date().isoformat()


def normalize(values):
    med = median(values)
    scale = 1.4826 * median(abs(v - med) for v in values)
    return [0.0 if scale < 1e-8 else 2.5 * math.tanh(((v - med) / scale) / 2) for v in values]


def quadrant(x, y):
    if abs(x) < .25 and abs(y) < .25:
        return 'neutral'
    return ('leading' if y >= 0 else 'weakening') if x >= 0 else ('improving' if y >= 0 else 'lagging')


def label_state(candidate, previous=None, consecutive=True):
    if not previous:
        return {'quadrant': candidate, 'candidate': candidate, 'candidateDays': 1}
    count = previous['candidateDays'] + 1 if consecutive and previous['candidate'] == candidate else 1
    # Neutral is an immediate dead zone. Exiting it, like any new quadrant, needs two sessions.
    stable = candidate if candidate == 'neutral' or count >= 2 else previous['quadrant']
    return {'quadrant': stable, 'candidate': candidate, 'candidateDays': count}


def compute(prices):
    """Pure forward calculation over the strict 12-symbol date intersection."""
    valid = {s: {d: p for d, p in prices[s].items() if isinstance(p, (int, float)) and math.isfinite(p) and p > 0} for s in SYMBOLS}
    days = sorted(set.intersection(*(set(valid[s]) for s in SYMBOLS)))
    smooth = {}
    for symbol, _, _ in SECTORS:
        rs = [math.log(valid[symbol][d]) - math.log(valid['SPY'][d]) for d in days]
        smooth[symbol] = [None] * 4 + [sum(rs[t-4:t+1]) / 5 for t in range(4, len(days))]
    for t in range(67, len(days)):
        xr = [smooth[s][t-21] - smooth[s][t-63] for s, _, _ in SECTORS]
        yr = [smooth[s][t] - smooth[s][t-21] for s, _, _ in SECTORS]
        xs, ys = normalize(xr), normalize(yr)
        yield days[t], [dict(symbol=s, name=n, nameZh=zh, x=xs[i], y=ys[i], xRaw=xr[i], yRaw=yr[i],
                            relativeTrend=math.expm1(xr[i]), relativeMomentum=math.expm1(yr[i]))
                        for i, (s, n, zh) in enumerate(SECTORS)]


def connect(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, timeout=30)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.executescript('''
        CREATE TABLE IF NOT EXISTS snapshots (version INTEGER, date TEXT, payload TEXT NOT NULL, PRIMARY KEY(version,date));
        CREATE TABLE IF NOT EXISTS prices (symbol TEXT, date TEXT, adjusted_close REAL NOT NULL, PRIMARY KEY(symbol,date));
        CREATE TABLE IF NOT EXISTS runs (id INTEGER PRIMARY KEY, generated_at TEXT, target TEXT, ok INTEGER, message TEXT);
    ''')
    return conn


def fetch_adjusted(symbol, now=None):
    now = now or datetime.now(timezone.utc)
    start = int((now - timedelta(days=850)).timestamp())
    url = f'https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?period1={start}&period2={int(now.timestamp())}&interval=1d&includeAdjustedClose=true'
    with urlopen(Request(url, headers={'User-Agent': 'Mozilla/5.0'}), timeout=30, context=ssl.create_default_context(cafile=certifi.where())) as response:
        data = json.load(response)['chart']['result'][0]
    adjusted = (data.get('indicators', {}).get('adjclose') or [{}])[0].get('adjclose')
    if not adjusted:
        raise ValueError(f'{symbol}: adjusted close unavailable; raw close is not an acceptable fallback')
    rows = {}
    for ts, p in zip(data.get('timestamp', []), adjusted):
        d = datetime.fromtimestamp(ts, ZoneInfo('America/New_York')).date().isoformat()
        if p is not None and math.isfinite(p) and p > 0:
            rows[d] = float(p)
    return rows


def run_batch(path=DB_PATH, backfill=60, now=None, provider=fetch_adjusted):
    now = now or datetime.now(timezone.utc)
    generated = now.isoformat().replace('+00:00', 'Z')
    target = expected_session(now)
    with closing(connect(path)) as conn:
        try:
            prices = {s: provider(s, now) for s in SYMBOLS}
            sessions = {s.date().isoformat() for s in calendar().sessions_in_range((now - timedelta(days=850)).date().isoformat(), target)}
            prices = {s: dict(sorted((d, p) for d, p in rows.items() if d in sessions)[-400:]) for s, rows in prices.items()}
            existing = {d: json.loads(p) for d, p in conn.execute('SELECT date,payload FROM snapshots WHERE version=? ORDER BY date', (VERSION,))}
            calculated = list(compute(prices))
            if not calculated:
                raise ValueError('Insufficient common adjusted history: need 68 sessions')
            cutoff = calculated[max(0, len(calculated) - backfill)][0]
            previous = None
            previous_date = None
            added = 0
            with conn:
                # Serialize writers before reading authoritative states again.
                conn.execute('BEGIN IMMEDIATE')
                existing = {d: json.loads(p) for d, p in conn.execute('SELECT date,payload FROM snapshots WHERE version=? ORDER BY date', (VERSION,))}
                for d, sectors in calculated:
                    if d in existing:
                        previous, previous_date = existing[d]['sectors'], d
                        continue
                    if existing and d < max(existing):
                        # Never insert retroactive observations into an already published history.
                        continue
                    consecutive = previous_date is not None and calendar().previous_session(d).date().isoformat() == previous_date
                    prev = {s['symbol']: s for s in previous or []}
                    for s in sectors:
                        s.update(label_state(quadrant(s['x'], s['y']), prev.get(s['symbol']), consecutive))
                        s['quadrantLabel'] = LABELS[s['quadrant']]
                    snapshot = dict(asOf=d, asOfTimezone='America/New_York', generatedAt=generated,
                                    benchmark='SPY', calcVersion=VERSION, preset=PRESET,
                                    backfilled=d != target, source='Yahoo adjusted close', sectors=sectors)
                    if d >= cutoff:
                        conn.execute('INSERT INTO snapshots VALUES (?,?,?)', (VERSION, d, json.dumps(snapshot, allow_nan=False)))
                        added += 1
                    previous, previous_date = sectors, d
                for symbol, rows in prices.items():
                    conn.execute('DELETE FROM prices WHERE symbol=?', (symbol,))
                    conn.executemany('INSERT INTO prices VALUES (?,?,?)', ((symbol, d, p) for d, p in rows.items()))
                complete = all(target in prices[s] for s in SYMBOLS)
                conn.execute('INSERT INTO runs(generated_at,target,ok,message) VALUES (?,?,?,?)',
                             (generated, target, int(complete), 'ok' if complete else 'Missing adjusted close for target session'))
            if not complete:
                raise ValueError(f'{target}: incomplete prices; no snapshot for that date')
            return {'target': target, 'inserted': added}
        except Exception as exc:
            with conn:
                conn.execute('INSERT INTO runs(generated_at,target,ok,message) VALUES (?,?,0,?)', (generated, target, type(exc).__name__))
            raise


def read_snapshot(path=DB_PATH, as_of=None, now=None):
    now = now or datetime.now(timezone.utc)
    if not Path(path).exists():
        return dict(status='unavailable', stale=True, calcVersion=VERSION, sectors=[], dates=[], disclaimer=DISCLAIMER)
    with closing(sqlite3.connect(f'file:{Path(path).resolve()}?mode=ro', uri=True)) as conn:
        rows = [(d, json.loads(p)) for d, p in conn.execute('SELECT date,payload FROM snapshots WHERE version=? ORDER BY date', (VERSION,))]
        run = conn.execute('SELECT target,ok FROM runs ORDER BY id DESC LIMIT 1').fetchone()
    dates = [d for d, _ in rows]
    rows = [(d, p) for d, p in rows if as_of is None or d <= as_of]
    if not rows:
        return dict(status='unavailable', stale=True, calcVersion=VERSION, sectors=[], dates=dates, disclaimer=DISCLAIMER)
    d, payload = rows[-1]
    # Completed ISO weeks only: current + eight previous weekly observations, never duplicate current.
    week = date.fromisoformat(d).isocalendar()[:2]
    weeks = {}
    for hd, hp in rows[:-1]:
        hw = date.fromisoformat(hd).isocalendar()[:2]
        if hw < week:
            weeks[hw] = (hd, hp)
    trail_rows = sorted(weeks.values())[-8:]
    for sector in payload['sectors']:
        sector['trail'] = []
        for hd, hp in trail_rows:
            old = next(s for s in hp['sectors'] if s['symbol'] == sector['symbol'])
            sector['trail'].append(dict(date=hd, x=old['x'], y=old['y']))
        last = next((s for s in trail_rows[-1][1]['sectors'] if s['symbol'] == sector['symbol']), None) if trail_rows else None
        sector['weeklyChange'] = ('unavailable' if last is None else 'strengthening' if sector['relativeMomentum'] > last['relativeMomentum'] else 'weakening' if sector['relativeMomentum'] < last['relativeMomentum'] else 'unchanged')
        sector['previousQuadrant'] = last['quadrant'] if last else None
    try:
        expected = expected_session(now)
        stale = dates[-1] < expected or bool(run and not run[1] and run[0] >= dates[-1])
        valid_until = (calendar().session_close(calendar().next_session(d)).to_pydatetime() + timedelta(hours=2, minutes=30)).isoformat()
    except Exception:
        # Missing/out-of-range exchange calendar must never silently label old data current.
        stale = True
        valid_until = d + 'T00:00:00Z'
    payload.update(status='available', stale=stale, historical=d != dates[-1], dates=dates,
                   disclaimer=DISCLAIMER, validUntil=valid_until)
    return payload


def validate_history(path=DB_PATH):
    with closing(sqlite3.connect(path)) as conn:
        snapshots = [json.loads(p) for p, in conn.execute('SELECT payload FROM snapshots WHERE version=? ORDER BY date', (VERSION,))]
    correlations = []
    counts = {k: 0 for k in ('leading', 'weakening', 'lagging', 'improving')}
    for p in snapshots:
        xs, ys = [s['xRaw'] for s in p['sectors']], [s['yRaw'] for s in p['sectors']]
        if len(set(xs)) > 1 and len(set(ys)) > 1:
            correlations.append(correlation(xs, ys))
        for s in p['sectors']:
            q = quadrant(s['x'], s['y'])
            if q in counts:
                counts[q] += 1
    total = len(snapshots) * 11
    shares = {q: n / total if total else 0 for q, n in counts.items()}
    mean_abs = sum(map(abs, correlations)) / len(correlations) if correlations else None
    latest = correlations[-1] if correlations else None
    return dict(days=len(snapshots), dailyCorrelations=correlations, latestCorrelation=latest,
                meanAbsoluteCorrelation=mean_abs, quadrantShares=shares,
                passed=bool(len(snapshots) >= 60 and latest is not None and abs(latest) < .3 and mean_abs < .3 and min(shares.values()) >= .1),
                note='Empirical diagnostic; non-overlapping windows do not guarantee independence. No parameter fitting is performed.')
