"""Call tracker: score dated bullish/bearish calls from any source against later prices.

A call is (source, date, ticker, stance) plus an optional reason and link. Each call is
observed over 5, 21 and 63 market sessions, starting from the stock's first close after the
call date (calls carry a date but no time, so the call-day close could be look-ahead).
Directional calls are scored against SPY over the same window; bearish calls score the
negated return. Pending windows and calls without prices never enter a denominator. Reads
never fetch prices; only ``compute_outcomes`` does.
"""
from bisect import bisect_left, bisect_right
from contextlib import closing
from datetime import date, datetime, timedelta, timezone
from functools import lru_cache
import json
import math
from pathlib import Path
import random
import re
import sqlite3
from statistics import median
from zoneinfo import ZoneInfo

from app.settings import V2_DIR

DB_PATH = V2_DIR / 'call_tracker.db'
HORIZONS = (5, 21, 63)
DEFAULT_HORIZON = 21
RANK_HORIZON = 63
BENCHMARK = 'SPY'
MIN_SAMPLE = 10
PAGE_SIZE = 20
ENTRY_GRACE_DAYS = 10  # max calendar days from a call to the first session after it
STALE_DAYS = 7  # a series ending this long before the newest data counts as interrupted
MAX_IMPORT_BYTES = 20 * 1024 * 1024
IMPORT_SUFFIXES = ('.jsonl', '.ndjson', '.json', '.txt')

SCHEMA = '''
CREATE TABLE IF NOT EXISTS calls (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    source TEXT NOT NULL,
    call_date TEXT NOT NULL,
    ticker TEXT NOT NULL,
    yahoo_symbol TEXT NOT NULL,
    name TEXT,
    stance TEXT NOT NULL CHECK (stance IN ('bullish', 'bearish', 'neutral')),
    reason TEXT,
    url TEXT,
    imported_at TEXT NOT NULL,
    dedupe_key TEXT NOT NULL UNIQUE
);
CREATE TABLE IF NOT EXISTS outcomes (
    call_id INTEGER NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
    horizon_days INTEGER NOT NULL CHECK (horizon_days IN (5, 21, 63)),
    status TEXT NOT NULL,
    entry_date TEXT, entry_close REAL, exit_date TEXT, exit_close REAL,
    ret REAL, bench_ret REAL, excess REAL,
    hit INTEGER CHECK (hit IN (0, 1)),
    PRIMARY KEY (call_id, horizon_days)
);
CREATE TABLE IF NOT EXISTS prices (
    symbol TEXT NOT NULL, date TEXT NOT NULL, close REAL NOT NULL,
    PRIMARY KEY (symbol, date)
);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
'''
OUTCOME_FIELDS = ('status', 'entry_date', 'entry_close', 'exit_date', 'exit_close', 'ret', 'bench_ret', 'excess', 'hit')
CALL_FIELDS = ('id', 'source', 'call_date', 'ticker', 'yahoo_symbol', 'name', 'stance', 'reason', 'url', 'imported_at')

_STANCES = {
    'bullish': 'bullish', 'long': 'bullish', 'buy': 'bullish', '看多': 'bullish', '看涨': 'bullish',
    'bearish': 'bearish', 'short': 'bearish', 'sell': 'bearish', '看空': 'bearish', '看跌': 'bearish',
    'neutral': 'neutral', 'hold': 'neutral', '中性': 'neutral',
}
_SYMBOL = re.compile(r'\^?[A-Z0-9][A-Z0-9.=-]{0,23}')
_US_LISTING = re.compile(r'[A-Z][A-Z0-9]*(-[A-Z])?')  # plain US tickers, incl. class shares like BRK-B
_VIDEO_ID = re.compile(r'[A-Za-z0-9_-]{6,20}')
# Calls name coins by their bare ticker, but on Yahoo "BTC" is a US-listed fund (Grayscale
# Bitcoin Mini Trust ETF), not bitcoin itself; ETH and XRP are funds too, and SOL and DOGE do not
# exist. The coins trade as the -USD pairs.
_CRYPTO_USD = {'BTC': 'BTC-USD', 'ETH': 'ETH-USD', 'SOL': 'SOL-USD', 'DOGE': 'DOGE-USD', 'XRP': 'XRP-USD'}


class CallImportError(ValueError):
    """Import failure with a stable code the page can translate."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


# ── parsing ────────────────────────────────────────────────────────────────────

def normalize_stance(value):
    key = str(value or '').strip()
    stance = _STANCES.get(key) or _STANCES.get(key.lower())
    if not stance:
        raise ValueError('stance')
    return stance


def normalize_symbol(value):
    """Return (ticker, yahoo_symbol). US tickers pass through, class shares show as BRK.B and
    price as Yahoo's BRK-B, HK codes use Yahoo's 4-digit form (700.HK -> 0700.HK) and bare
    crypto tickers become Yahoo's -USD pairs (BTC -> BTC-USD)."""
    symbol = str(value or '').strip().upper().lstrip('$')
    if symbol.endswith('.US'):
        symbol = symbol[:-3]
    symbol = _CRYPTO_USD.get(symbol, symbol)
    if symbol.endswith('.HK') and symbol[:-3].isdigit():
        symbol = f'{int(symbol[:-3]):04d}.HK'
    share_class = re.fullmatch(r'([A-Z]+)[.-]([AB])', symbol)
    if share_class:
        return f'{share_class[1]}.{share_class[2]}', f'{share_class[1]}-{share_class[2]}'
    if not _SYMBOL.fullmatch(symbol):
        raise ValueError('symbol')
    return symbol, symbol


def _clip(value, limit):
    text = ' '.join(str(value).split()) if value is not None else ''
    return text[:limit] or None


def parse_call(row, source_field='channel'):
    """Validate one imported record. Accepts the finfluencer digest calls.jsonl fields."""
    if not isinstance(row, dict):
        raise ValueError('object')
    source = _clip(row.get(source_field) or row.get('source') or row.get('channel'), 120)
    if not source:
        raise ValueError('source')
    raw_date = str(row.get('date') or row.get('call_date') or '').strip()
    try:
        call_date = date.fromisoformat(raw_date[:10]).isoformat()
    except ValueError:
        raise ValueError('date') from None
    ticker, yahoo_symbol = normalize_symbol(row.get('symbol') or row.get('ticker'))
    stance = normalize_stance(row.get('stance'))
    url = str(row.get('url') or '').strip()
    video_id = str(row.get('video_id') or '').strip()
    if not url and _VIDEO_ID.fullmatch(video_id):
        url = f'https://www.youtube.com/watch?v={video_id}'
    if not re.match(r'https?://', url, re.I):
        url = ''
    return dict(source=source, call_date=call_date, ticker=ticker, yahoo_symbol=yahoo_symbol,
                name=_clip(row.get('name'), 120), stance=stance, reason=_clip(row.get('reason'), 2000),
                url=url[:500] or None)


def dedupe_key(call):
    return '|'.join((call['source'], call['call_date'], call['ticker']))


# ── storage ────────────────────────────────────────────────────────────────────

def connect(path=None):
    path = Path(path or DB_PATH)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute('PRAGMA foreign_keys=ON')
    conn.executescript(SCHEMA)
    return conn


def _now_iso(now=None):
    return (now or datetime.now(timezone.utc)).astimezone(timezone.utc).replace(microsecond=0).isoformat()


def _set_meta(conn, **values):
    conn.executemany('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', values.items())


def _normalise_stored_symbols(conn):
    """Re-apply the symbol rules to calls stored before them (BTC -> BTC-USD); the caller commits.

    The de-duplication key moves with the ticker, so re-importing the same file adds nothing;
    if both spellings were stored, the earlier call wins. Outcomes of rewritten calls priced the
    wrong instrument, so they are dropped until the next recalculation."""
    marks = ', '.join('?' * len(_CRYPTO_USD))
    rows = conn.execute(f'SELECT id, source, call_date, ticker FROM calls WHERE ticker IN ({marks}) ORDER BY id',
                        tuple(_CRYPTO_USD)).fetchall()
    for row in rows:
        ticker, yahoo_symbol = normalize_symbol(row['ticker'])
        key = dedupe_key(dict(source=row['source'], call_date=row['call_date'], ticker=ticker))
        twin = conn.execute('SELECT id FROM calls WHERE dedupe_key = ?', (key,)).fetchone()
        if twin and twin['id'] < row['id']:
            conn.execute('DELETE FROM calls WHERE id = ?', (row['id'],))
            continue
        if twin:
            conn.execute('DELETE FROM calls WHERE id = ?', (twin['id'],))
        conn.execute('UPDATE calls SET ticker = ?, yahoo_symbol = ?, dedupe_key = ? WHERE id = ?',
                     (ticker, yahoo_symbol, key, row['id']))
        conn.execute('DELETE FROM outcomes WHERE call_id = ?', (row['id'],))
    return len(rows)


def _read_lines(path_or_lines):
    if isinstance(path_or_lines, (str, Path)):
        path = Path(path_or_lines).expanduser()
        if not path.exists():
            raise CallImportError('not_found')
        if not path.is_file():
            raise CallImportError('not_a_file')
        if path.suffix.lower() not in IMPORT_SUFFIXES:
            raise CallImportError('bad_suffix')
        if path.stat().st_size > MAX_IMPORT_BYTES:
            raise CallImportError('too_large')
        path_or_lines = path.read_bytes()
    if isinstance(path_or_lines, (bytes, bytearray)):
        if len(path_or_lines) > MAX_IMPORT_BYTES:
            raise CallImportError('too_large')
        try:
            return bytes(path_or_lines).decode('utf-8-sig').splitlines()
        except UnicodeDecodeError:
            raise CallImportError('not_utf8') from None
    return [line.decode('utf-8-sig') if isinstance(line, bytes) else str(line) for line in path_or_lines]


def import_jsonl(path_or_lines, source_field='channel', db_path=None, now=None):
    """Import JSONL calls (a path, bytes or an iterable of lines).

    The first record for each (source, date, ticker) wins; later repeats, within the file or
    against earlier imports, are counted as duplicates. Returns counts plus up to ten
    line-level problems as {line, code}. A local path is remembered for refresh()."""
    lines = _read_lines(path_or_lines)
    stamp = _now_iso(now)
    counts = dict(read=0, inserted=0, duplicates=0, invalid=0)
    errors = []
    with closing(connect(db_path)) as conn, conn:
        _normalise_stored_symbols(conn)
        for number, line in enumerate(lines, 1):
            text = line.strip()
            if not text:
                continue
            counts['read'] += 1
            try:
                call = parse_call(json.loads(text), source_field)
            except ValueError as exc:  # JSONDecodeError is a ValueError
                counts['invalid'] += 1
                code = 'json' if isinstance(exc, json.JSONDecodeError) else str(exc)
                if len(errors) < 10:
                    errors.append(dict(line=number, code=code))
                continue
            cursor = conn.execute(
                'INSERT OR IGNORE INTO calls (source, call_date, ticker, yahoo_symbol, name, stance, reason, url, '
                'imported_at, dedupe_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
                (call['source'], call['call_date'], call['ticker'], call['yahoo_symbol'], call['name'],
                 call['stance'], call['reason'], call['url'], stamp, dedupe_key(call)))
            counts['inserted' if cursor.rowcount else 'duplicates'] += 1
        meta = dict(imported_at=stamp)
        if isinstance(path_or_lines, (str, Path)):
            meta['source_path'] = str(Path(path_or_lines).expanduser().resolve())
        _set_meta(conn, **meta)
    return dict(counts, errors=errors)


def _empty_dataset(demo=False):
    return dict(calls=[], outcomes={}, prices={}, meta={}, demo=demo)


def load_dataset(db_path=None, with_prices=False):
    """Read everything the page needs. A missing database is an empty dataset, not an error."""
    path = Path(db_path or DB_PATH)
    if not path.exists():
        return _empty_dataset()
    with closing(connect(path)) as conn:
        calls = [dict(row) for row in conn.execute(f'SELECT {", ".join(CALL_FIELDS)} FROM calls ORDER BY id')]
        outcomes = {(row['call_id'], row['horizon_days']): {k: row[k] for k in OUTCOME_FIELDS}
                    for row in conn.execute('SELECT * FROM outcomes')}
        meta = {row['key']: row['value'] for row in conn.execute('SELECT key, value FROM meta')}
        prices = _load_prices(conn) if with_prices else {}
    return dict(calls=calls, outcomes=outcomes, prices=prices, meta=meta, demo=False)


def _load_prices(conn):
    prices = {}
    for row in conn.execute('SELECT symbol, date, close FROM prices ORDER BY symbol, date'):
        prices.setdefault(row['symbol'], []).append((row['date'], row['close']))
    return prices


def remembered_path(db_path=None):
    path = Path(db_path or DB_PATH)
    if not path.exists():
        return None
    with closing(connect(path)) as conn:
        row = conn.execute("SELECT value FROM meta WHERE key = 'source_path'").fetchone()
    return row['value'] if row else None


# ── prices ─────────────────────────────────────────────────────────────────────

def _clean_rows(rows):
    """Normalise [{date, close}] or [(date, close)] into sorted, de-duplicated finite closes."""
    clean = {}
    for row in rows or ():
        day, close = (row.get('date'), row.get('close')) if isinstance(row, dict) else (row[0], row[1])
        try:
            day = date.fromisoformat(str(day)[:10]).isoformat()
            close = float(close)
        except (TypeError, ValueError):
            continue
        if math.isfinite(close) and close > 0:
            clean[day] = close
    return sorted(clean.items())


def final_session_cutoff(symbol, fetched_at):
    """Last bar date that was already a final close when a series was fetched.

    Yahoo's daily chart includes today's unfinished bar during trading hours, so the
    current session only counts once the market has closed (plus 30 minutes). Symbols
    outside US and HK listings only use bars dated before the fetch day (UTC)."""
    if symbol.endswith('.HK'):
        zone = 'Asia/Hong_Kong'
    elif _US_LISTING.fullmatch(symbol):
        zone = 'America/New_York'
    else:
        return (fetched_at.astimezone(timezone.utc).date() - timedelta(days=1)).isoformat()
    local = fetched_at.astimezone(ZoneInfo(zone))
    closed = (local.hour, local.minute) >= (16, 30)
    return (local.date() if closed else local.date() - timedelta(days=1)).isoformat()


def yahoo_prices(symbols, start_date=None, now=None):
    """Default price source: Catfolio's shared Yahoo daily cache (strategy_engine.get_prices),
    trimmed to sessions that were final when each series was fetched."""
    from app.data_store import load_json
    from app.strategy_engine import PRICE_CACHE, get_prices

    now = now or datetime.now(timezone.utc)
    years = 5  # same depth as Strategy Lab, which shares this per-symbol cache
    if start_date:
        years = max(years, math.ceil((now.date() - date.fromisoformat(start_date)).days / 365.25) + 1)
    prices, warnings = get_prices(symbols, years=years)
    cache = load_json(PRICE_CACHE, {}) or {}
    trimmed = {}
    for symbol, rows in prices.items():
        as_of = (cache.get(symbol) or {}).get('as_of')
        fetched = datetime.fromtimestamp(int(as_of), timezone.utc) if as_of else now
        cutoff = final_session_cutoff(symbol, fetched)
        trimmed[symbol] = [(d, c) for d, c in _clean_rows(rows) if d <= cutoff]
    return trimmed, warnings


def _days(start, end):
    return (date.fromisoformat(end) - date.fromisoformat(start)).days


def _asof(dates, closes, day):
    """Close on or before ``day`` if it is recent enough to stand in for that day."""
    i = bisect_right(dates, day) - 1
    if i < 0 or _days(dates[i], day) > STALE_DAYS:
        return None
    return closes[i]


# ── scoring ────────────────────────────────────────────────────────────────────

def _prepare(rows):
    return [d for d, _ in rows], [c for _, c in rows]


def _score(call_date, stance, series, bench, horizon, reference_date, sessions=None):
    dates, closes = series
    out = dict.fromkeys(OUTCOME_FIELDS)
    out['status'] = 'missing_price'
    if not dates:
        return out
    sessions = sessions or dates
    stale = reference_date is not None and _days(dates[-1], reference_date) > STALE_DAYS
    waiting = 'missing_price' if stale else 'pending'
    i = bisect_right(dates, call_date)  # first close strictly after the call date
    if i == len(dates):
        out['status'] = waiting
        return out
    if _days(call_date, dates[i]) > ENTRY_GRACE_DAYS:
        return out  # no close soon after the call: a gap in the series or a later listing
    out.update(entry_date=dates[i], entry_close=closes[i])
    k = bisect_left(sessions, dates[i]) + horizon  # count market sessions, not only days with a close
    if k >= len(sessions) or sessions[k] > dates[-1]:
        out['status'] = waiting
        return out
    j = bisect_right(dates, sessions[k]) - 1  # last close on or before the exit session
    if _days(dates[j], sessions[k]) > STALE_DAYS:
        return out
    ret = closes[j] / closes[i] - 1
    out.update(exit_date=sessions[k], exit_close=closes[j], ret=ret)
    start, end = _asof(*bench, dates[i]), _asof(*bench, sessions[k])
    if start and end:
        out['bench_ret'] = end / start - 1
    if stance == 'neutral':
        out['status'] = 'neutral'
        return out
    sign = 1 if stance == 'bullish' else -1
    out.update(status='scored', hit=int(sign * ret > 0))
    if out['bench_ret'] is not None:
        out['excess'] = sign * (ret - out['bench_ret'])
    return out


def score_call(call_date, stance, rows, bench_rows, horizon, reference_date=None, sessions=None):
    """Score one call over ``horizon`` market sessions.

    ``rows`` are the stock's sorted [(date, close)]. The entry is its first close after the
    call date; the exit is ``horizon`` sessions later on ``sessions`` (default: the stock's own
    dates), valued at the last close on or before that session, so a missing Yahoo close does
    not stretch the window. status: scored, neutral (matured, not scored), pending (window
    open or no session after the call yet) or missing_price. The benchmark uses its close on
    or before the entry and exit dates."""
    return _score(call_date, stance, _prepare(rows), _prepare(bench_rows), horizon, reference_date, sessions)


def reference_day(prices, today=None):
    """Newest final session across all series; the yardstick for 'pending' vs 'interrupted'."""
    latest = [rows[-1][0] for rows in prices.values() if rows]
    return max(latest) if latest else today


def score_all(calls, prices, today=None):
    """Score every call at every horizon. US listings count sessions on SPY's dates plus their
    own (Yahoo sometimes returns an empty close for a session); others use their own dates."""
    reference = reference_day(prices, today)
    series = {symbol: _prepare(rows or []) for symbol, rows in prices.items()}
    bench = series.get(BENCHMARK) or ([], [])
    calendars = {}
    for symbol, (dates, _) in series.items():
        us_listing = dates and bench[0] and _US_LISTING.fullmatch(symbol)
        calendars[symbol] = sorted(set(dates) | set(bench[0])) if us_listing else dates
    return {(call['id'], horizon): _score(call['call_date'], call['stance'], series.get(call['yahoo_symbol']) or ([], []),
                                          bench, horizon, reference, calendars.get(call['yahoo_symbol']))
            for call in calls for horizon in HORIZONS}


def compute_outcomes(price_source=None, db_path=None, now=None):
    """Recompute every outcome from fresh prices (network) and store the price snapshot.

    Everything is recomputed so adjusted-close revisions and late data stay consistent. A
    symbol the source cannot deliver this time falls back to the last stored series."""
    now = now or datetime.now(timezone.utc)
    with closing(connect(db_path)) as conn:
        with conn:
            _normalise_stored_symbols(conn)
        calls = [dict(row) for row in conn.execute(f'SELECT {", ".join(CALL_FIELDS)} FROM calls ORDER BY id')]
        stats = {str(h): dict.fromkeys(('scored', 'neutral', 'pending', 'missing_price'), 0) for h in HORIZONS}
        if not calls:
            return dict(calls=0, symbols=0, statuses=stats, missing_symbols=[], reused_symbols=[],
                        price_as_of=None, warnings=[])
        symbols = sorted({call['yahoo_symbol'] for call in calls} | {BENCHMARK})
        earliest = min(call['call_date'] for call in calls)
        if price_source is None:
            fetched = yahoo_prices(symbols, start_date=earliest, now=now)
        else:
            fetched = price_source(symbols)
        fetched, warnings = fetched if isinstance(fetched, tuple) else (fetched, [])
        stored = _load_prices(conn)
        prices, fresh, reused = {}, {}, []
        for symbol in symbols:
            rows = _clean_rows((fetched or {}).get(symbol))
            if rows:
                fresh[symbol] = rows
            elif stored.get(symbol):
                rows = stored[symbol]
                reused.append(symbol)
            prices[symbol] = rows
        outcomes = score_all(calls, prices, now.date().isoformat())
        keep_from = (date.fromisoformat(earliest) - timedelta(days=ENTRY_GRACE_DAYS + STALE_DAYS)).isoformat()
        price_as_of = reference_day(prices)
        with conn:
            conn.execute('DELETE FROM outcomes')
            conn.executemany(
                f'INSERT INTO outcomes (call_id, horizon_days, {", ".join(OUTCOME_FIELDS)}) '
                f'VALUES (?, ?, {", ".join("?" * len(OUTCOME_FIELDS))})',
                [(call_id, horizon, *(outcome[k] for k in OUTCOME_FIELDS))
                 for (call_id, horizon), outcome in outcomes.items()])
            for symbol, rows in fresh.items():
                conn.execute('DELETE FROM prices WHERE symbol = ?', (symbol,))
                conn.executemany('INSERT INTO prices (symbol, date, close) VALUES (?, ?, ?)',
                                 [(symbol, d, c) for d, c in rows if d >= keep_from])
            _set_meta(conn, computed_at=_now_iso(now), price_as_of=price_as_of or '')
    for (_, horizon), outcome in outcomes.items():
        stats[str(horizon)][outcome['status']] += 1
    return dict(calls=len(calls), symbols=len(symbols), statuses=stats,
                missing_symbols=[s for s in symbols if not prices[s]], reused_symbols=reused,
                price_as_of=price_as_of, warnings=[str(w) for w in (warnings or [])][:20])


def refresh(price_source=None, db_path=None, now=None):
    """Re-read the remembered local file (if any; duplicates are skipped) and recompute."""
    path = remembered_path(db_path)
    imported = None
    if path and Path(path).is_file():
        try:
            imported = import_jsonl(path, db_path=db_path, now=now)
        except CallImportError as exc:
            imported = dict(error=exc.code)
    return dict(imported=imported, computed=compute_outcomes(price_source, db_path, now))


# ── summaries ──────────────────────────────────────────────────────────────────

def _sign(call):
    return 1 if call['stance'] == 'bullish' else -1


def _status(outcome):
    return outcome['status'] if outcome else 'uncomputed'


def metrics(pairs):
    """Aggregate [(call, outcome)] for one source and horizon (all stances)."""
    directional = [(c, o) for c, o in pairs if c['stance'] != 'neutral']
    scored = [(c, o) for c, o in directional if _status(o) == 'scored']
    statuses = [_status(o) for _, o in directional]
    returns = [(_sign(c) * o['ret'], c) for c, o in scored]
    excess = [o['excess'] for _, o in scored if o['excess'] is not None]
    gains = [(r, c) for r, c in returns if r > 0]
    top = None
    if gains:
        best, call = max(gains, key=lambda item: item[0])
        top = dict(share=best / sum(r for r, _ in gains), ret=best, ticker=call['ticker'], call_date=call['call_date'])
    hits = sum(o['hit'] for _, o in scored)
    return dict(
        calls=len(pairs), directional=len(directional), neutral=len(pairs) - len(directional),
        scored=len(scored), pending=statuses.count('pending'), missing=statuses.count('missing_price'),
        uncomputed=statuses.count('uncomputed'), hits=hits,
        hit_rate=hits / len(scored) if scored else None,
        avg_return=sum(r for r, _ in returns) / len(returns) if returns else None,
        avg_excess=sum(excess) / len(excess) if excess else None,
        median_excess=median(excess) if excess else None,
        top_contribution=top, status='ready' if len(scored) >= MIN_SAMPLE else 'watch')


def _pairs(dataset, calls, horizon):
    return [(call, dataset['outcomes'].get((call['id'], horizon))) for call in calls]


def _by_source(dataset):
    groups = {}
    for call in dataset['calls']:
        groups.setdefault(call['source'], []).append(call)
    return groups


def _rank_key(row):
    rank = row['rank_hit_rate']
    current = row['hit_rate']
    return (row['rank_scored'] < MIN_SAMPLE, -(rank if rank is not None else -1),
            -(current if current is not None else -1), -row['calls'], row['source'])


def _meta(dataset):
    meta = dataset.get('meta') or {}
    return dict(demo=bool(dataset.get('demo')), updated_at=meta.get('computed_at') or None,
                imported_at=meta.get('imported_at') or None, price_as_of=meta.get('price_as_of') or None,
                benchmark=BENCHMARK, horizons=list(HORIZONS), rank_horizon=RANK_HORIZON, min_sample=MIN_SAMPLE)


def summary(horizon=DEFAULT_HORIZON, dataset=None):
    """Cross-source table for one horizon, ranked by the 63-session hit rate (thin samples last)."""
    dataset = dataset if dataset is not None else load_dataset()
    rows = []
    for source, calls in _by_source(dataset).items():
        row = metrics(_pairs(dataset, calls, horizon))
        rank = row if horizon == RANK_HORIZON else metrics(_pairs(dataset, calls, RANK_HORIZON))
        row.update(source=source, rank_hit_rate=rank['hit_rate'], rank_scored=rank['scored'])
        rows.append(row)
    rows.sort(key=_rank_key)
    totals = metrics(_pairs(dataset, dataset['calls'], horizon))
    totals['sources'] = len(rows)
    return dict(_meta(dataset), horizon=horizon, empty=not dataset['calls'], totals=totals, sources=rows)


def monthly_hits(pairs):
    """Hit rate by the month of the call date (directional calls only)."""
    months = {}
    for call, outcome in pairs:
        if call['stance'] == 'neutral':
            continue
        month = months.setdefault(call['call_date'][:7], dict(month=call['call_date'][:7], scored=0, hits=0,
                                                              pending=0, missing=0))
        status = _status(outcome)
        if status == 'scored':
            month['scored'] += 1
            month['hits'] += outcome['hit']
        elif status == 'missing_price':
            month['missing'] += 1
        else:
            month['pending'] += 1
    if months:  # keep the axis continuous: months without calls appear empty
        first, last = min(months), max(months)
        year, month_no = int(first[:4]), int(first[5:])
        while f'{year:04d}-{month_no:02d}' < last:
            month_no = month_no % 12 + 1
            year += month_no == 1
            key = f'{year:04d}-{month_no:02d}'
            months.setdefault(key, dict(month=key, scored=0, hits=0, pending=0, missing=0))
    for month in months.values():
        month['hit_rate'] = month['hits'] / month['scored'] if month['scored'] else None
    return [months[key] for key in sorted(months)]


def _series(prices, symbol):
    return _prepare(prices.get(symbol) or [])


def _nav(dates, legs):
    """Unitised NAV: equal money into each leg at its entry close, held (drifting) to its exit.

    Each step's return is value-weighted across the legs held over that step. A short leg's
    value is 2 - price/entry, floored at zero."""
    index = {d: k for k, d in enumerate(dates)}
    gain = [0.0] * len(dates)
    base = [0.0] * len(dates)
    for sign, entry, exit_, series in legs:
        start, end = index.get(entry), index.get(exit_)
        if start is None or end is None or end <= start:
            continue
        closes = [_asof(series[0], series[1], d) for d in dates[start:end + 1]]
        if not closes[0] or any(c is None for c in closes):
            continue
        values = [c / closes[0] if sign > 0 else max(0.0, 2 - c / closes[0]) for c in closes]
        for k in range(1, len(values)):
            if values[k - 1] > 0:
                gain[start + k] += values[k] - values[k - 1]
                base[start + k] += values[k - 1]
    nav, level = [], 1.0
    for k in range(len(dates)):
        if k and base[k] > 0:
            level *= 1 + gain[k] / base[k]
        nav.append(round(level, 6))
    return nav


def follow_curve(positions, prices, benchmark=BENCHMARK):
    """'Follow every call' curve for [(symbol, sign, entry_date, exit_date)] plus the same
    direction in the benchmark over the same windows."""
    legs, bench_legs, days = [], [], set()
    bench = _series(prices, benchmark)
    cache = {}
    for symbol, sign, entry, exit_ in positions:
        series = cache.get(symbol) or cache.setdefault(symbol, _series(prices, symbol))
        window = series[0][bisect_left(series[0], entry):bisect_right(series[0], exit_)]
        if not window or window[0] != entry or exit_ <= entry:
            continue
        days.update(window)
        days.add(exit_)  # the exit session may lack its own close; it is valued at the last one
        legs.append((sign, entry, exit_, series))
        bench_legs.append((sign, entry, exit_, bench))
    dates = sorted(days)
    return dict(dates=dates, follow=_nav(dates, legs), benchmark=_nav(dates, bench_legs) if bench[0] else [],
                calls=len(legs))


def source_detail(name, horizon=DEFAULT_HORIZON, dataset=None):
    dataset = dataset if dataset is not None else load_dataset(with_prices=True)
    calls = [call for call in dataset['calls'] if call['source'] == name]
    if not calls:
        raise KeyError(name)
    pairs = _pairs(dataset, calls, horizon)
    positions = [(c['yahoo_symbol'], _sign(c), o['entry_date'], o['exit_date'])
                 for c, o in pairs if c['stance'] != 'neutral' and _status(o) == 'scored']
    stances = {stance: sum(c['stance'] == stance for c in calls) for stance in ('bullish', 'bearish', 'neutral')}
    return dict(_meta(dataset), source=name, horizon=horizon, metrics=metrics(pairs),
                curve=follow_curve(positions, dataset['prices']), monthly=monthly_hits(pairs), stances=stances,
                first_call=min(c['call_date'] for c in calls), last_call=max(c['call_date'] for c in calls))


def events(source='', horizon=DEFAULT_HORIZON, page=1, dataset=None, page_size=PAGE_SIZE):
    """Calls newest first with their outcome at ``horizon``; ``page`` starts at 1."""
    dataset = dataset if dataset is not None else load_dataset()
    calls = [c for c in dataset['calls'] if not source or c['source'] == source]
    calls.sort(key=lambda c: (c['call_date'], c['id']), reverse=True)
    chunk = calls[(page - 1) * page_size:page * page_size]
    items = []
    for call in chunk:
        outcome = dataset['outcomes'].get((call['id'], horizon)) or dict(dict.fromkeys(OUTCOME_FIELDS), status='uncomputed')
        items.append(dict({k: call[k] for k in CALL_FIELDS if k not in ('yahoo_symbol', 'imported_at')},
                          outcome=outcome))
    return dict(total=len(calls), page=page, page_size=page_size,
                pages=max(1, math.ceil(len(calls) / page_size)), horizon=horizon, items=items)


# ── demo data ──────────────────────────────────────────────────────────────────

DEMO_SEED = 20260923
DEMO_START, DEMO_END = '2025-06-02', '2026-09-18'
# symbol, start price, beta to the fictional market, idiosyncratic daily volatility
DEMO_TICKERS = (
    ('AAPL', 212.0, 1.0, .012), ('MSFT', 455.0, .9, .011), ('NVDA', 132.0, 1.6, .026),
    ('AMZN', 205.0, 1.2, .016), ('GOOGL', 172.0, 1.1, .015), ('META', 640.0, 1.3, .019),
    ('TSLA', 330.0, 1.8, .032), ('AMD', 118.0, 1.7, .027), ('AVGO', 245.0, 1.4, .022),
    ('COST', 1010.0, .7, .010), ('NFLX', 1180.0, 1.0, .018), ('JPM', 262.0, .9, .012),
    ('0700.HK', 505.0, .8, .018),
)
# zh name, en name, calls, hit skill at 21 sessions, bearish share, neutral share, first/last call day
DEMO_SOURCES = (
    ('示例博主·甲', 'Sample blogger A', 44, .66, .15, .10, '2025-09-01', '2026-09-11'),
    ('示例博主·乙', 'Sample blogger B', 38, .50, .20, .13, '2025-09-15', '2026-09-11'),
    ('示例机构', 'Sample institution', 26, .58, .30, .08, '2025-10-01', '2026-08-28'),
    ('示例博主·丙', 'Sample blogger C', 12, .42, .15, .10, '2026-04-01', '2026-09-11'),
)
DEMO_REASONS = {
    'bullish': (('业绩超预期，管理层上调全年指引。', 'Results beat expectations and guidance was raised.'),
                ('估值回到近三年低位，适合分批建仓。', 'Valuation is near a three-year low; building in stages.'),
                ('新产品周期刚开始，订单能见度高。', 'A new product cycle is starting with good order visibility.'),
                ('回调到长期均线附近，风险收益比合适。', 'Pulled back to its long-term average; fair risk/reward.')),
    'bearish': (('估值偏高，增速开始放缓。', 'Valuation looks stretched while growth slows.'),
                ('竞争加剧，利润率承压。', 'Competition is rising and margins are under pressure.'),
                ('短期涨幅过大，获利回吐风险高。', 'Up too far too fast; profit-taking risk is high.')),
    'neutral': (('等财报确认方向，暂时观望。', 'Waiting for earnings to confirm the direction.'),
                ('区间震荡，没有明确信号。', 'Range-bound with no clear signal.')),
}


@lru_cache(maxsize=1)
def _demo_base():
    """Fictional sources, calls and price paths from a fixed seed. Only Random.random() is used:
    its sequence for an integer seed is stable across Python versions."""
    rng = random.Random(DEMO_SEED)
    uniform = rng.random

    def normal():
        return math.sqrt(-2 * math.log(1 - uniform())) * math.cos(2 * math.pi * uniform())

    def pick(items):
        return items[min(len(items) - 1, int(uniform() * len(items)))]

    sessions, day = [], date.fromisoformat(DEMO_START)
    while day.isoformat() <= DEMO_END:
        if day.weekday() < 5:
            sessions.append(day.isoformat())
        day += timedelta(days=1)
    market = [normal() for _ in sessions]
    prices = {BENCHMARK: []}
    level = 560.0
    for day, shock in zip(sessions, market):
        level *= math.exp(.0003 + .0085 * shock)
        prices[BENCHMARK].append((day, round(level, 2)))
    for symbol, start, beta, vol in DEMO_TICKERS:
        level, rows = start, []
        for day, shock in zip(sessions, market):
            level *= math.exp(.0001 + beta * .0085 * shock + vol * normal())
            rows.append((day, round(level, 2)))
        prices[symbol] = rows
    closes = {symbol: [c for _, c in rows] for symbol, rows in prices.items()}
    symbols = [t[0] for t in DEMO_TICKERS]
    calls, seen = [], set()
    for zh, en, count, skill, bearish, neutral, first, last in DEMO_SOURCES:
        window = [i for i, d in enumerate(sessions) if first <= d <= last]
        made = 0
        while made < count:
            i = pick(window)
            roll = uniform()
            stance = 'neutral' if roll < neutral else 'bearish' if roll < neutral + bearish else 'bullish'
            wants_hit = uniform() < skill
            entry, exit_ = i + 1, i + 22  # plant the skill on the 21-session outcome
            pool = symbols
            if stance != 'neutral' and exit_ < len(sessions):
                rises = (stance == 'bullish') == wants_hit
                pool = [s for s in symbols if (closes[s][exit_] > closes[s][entry]) == rises] or symbols
            ticker = pick(pool)
            reason = int(uniform() * len(DEMO_REASONS[stance]))
            if (zh, sessions[i], ticker) in seen:
                continue
            seen.add((zh, sessions[i], ticker))
            calls.append(dict(source=(zh, en), call_date=sessions[i], ticker=ticker, stance=stance, reason=reason))
            made += 1
    calls.sort(key=lambda c: (c['call_date'], c['source'][0], c['ticker']))
    return calls, prices


@lru_cache(maxsize=2)
def demo_dataset(lang='zh'):
    """Deterministic, offline demo: 4 fictional sources, 120 calls, fictional prices."""
    base_calls, prices = _demo_base()
    column = 1 if lang == 'en' else 0
    calls = [dict(id=number, source=call['source'][column], call_date=call['call_date'], ticker=call['ticker'],
                  yahoo_symbol=call['ticker'], name=None, stance=call['stance'],
                  reason=DEMO_REASONS[call['stance']][call['reason']][column], url=None,
                  imported_at=DEMO_END + 'T21:00:00+00:00')
             for number, call in enumerate(base_calls, 1)]
    meta = dict(computed_at=DEMO_END + 'T21:30:00+00:00', imported_at=DEMO_END + 'T21:00:00+00:00',
                price_as_of=DEMO_END)
    return dict(calls=calls, outcomes=score_all(calls, prices, DEMO_END), prices=prices, meta=meta, demo=True)
