"""Read-only adapter for the immutable Core institution track-record release."""
import json
import os
import sqlite3
from datetime import date
from contextlib import closing
from functools import lru_cache
from pathlib import Path

ROOT = Path(os.environ.get('CATFOLIO_ANALYST_ROOT', '/Volumes/T7/CatData/core/storage/analyst-track-record'))

def release_path():
    pointer = json.loads((ROOT / 'current.json').read_text())
    return ROOT / pointer['releaseId']

@lru_cache(maxsize=4)
def load_release(path):
    p = Path(path)
    return {'data': json.loads((p / 'analyst_track_record.json').read_text()), 'report': json.loads((p / 'report.json').read_text())}

def snapshot():
    return load_release(str(release_path()))

@lru_cache(maxsize=128)
def institution_events(path, institution, horizon, direction):
    positive = set(load_release(path)['data']['methodology']['positiveGrades'])
    with closing(sqlite3.connect(f'file:{path}/audit.sqlite?mode=ro', uri=True)) as conn:
        conn.row_factory = sqlite3.Row
        rows = conn.execute('''SELECT e.*,o.status,o.reason,o.result_json FROM events e
            JOIN outcomes o ON o.event_id=e.id WHERE e.institution=? AND o.horizon=?
            ORDER BY e.date DESC,e.symbol,e.id''', (institution, horizon)).fetchall()
        items = []
        for row in rows:
            e = dict(row)
            raw = json.loads(e.pop('raw_json'))[0]
            if ('BULLISH' if raw['newGrade'] in positive else 'BEARISH') != direction:
                continue
            e['rating'] = raw
            e['reviewNotes'] = []
            e['corroboration'] = None
            if institution == 'Morgan Stanley' and e['symbol'] == 'NVDA' and e['date'] == '2023-03-17':
                e['corroboration'] = {'label': '公开报道交叉核对：日期与新旧评级一致（非原研报）', 'url': 'https://www.investing.com/news/stock-market-news/morgan-stanley-upgrades-nvidia-says-stock-hard-to-ignore-amid-generative-ai-opportunity-432SI-3033430'}
            e['result'] = json.loads(e.pop('result_json'))
            ids = json.loads(e.pop('source_ids'))
            if e['result'].get('priceSourceId'):
                ids.append(e['result']['priceSourceId'])
            e['sources'] = [dict(conn.execute('SELECT * FROM sources WHERE id=?', (sid,)).fetchone()) for sid in dict.fromkeys(ids)]
            items.append(e)
        previous = {}
        for e in items:
            r = e['rating']
            key = (e['symbol'], r['previousGrade'], r['newGrade'], r['action'])
            newer = previous.get(key)
            if newer and (date.fromisoformat(newer['date']) - date.fromisoformat(e['date'])).days <= 3:
                note = '相邻日期出现相同评级变更，疑似重复，待核实；沿用 Core 原统计，尚未剔除。'
                e['reviewNotes'].append(note)
                newer['reviewNotes'].append(note)
            previous[key] = e
    return items
