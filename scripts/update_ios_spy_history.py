#!/usr/bin/env python3
"""Refresh the bundled SPY closing-price snapshot. No generated or interpolated prices.

Uses curl's system trust store. A failed or invalid response leaves the old file intact.
"""
import datetime as dt
import json
import math
from pathlib import Path
import subprocess
import urllib.parse

OUTPUT = Path(__file__).resolve().parents[1] / 'CatfolioIOS/CatfolioIOS/Resources/spy_daily_history.json'


def main():
    now = dt.datetime.now(dt.timezone.utc)
    start = dt.datetime(1993, 1, 29, tzinfo=dt.timezone.utc)
    # Exclusive end: never bundle the current session's unfinished daily bar.
    end = now.replace(hour=0, minute=0, second=0, microsecond=0)
    url = 'https://query1.finance.yahoo.com/v8/finance/chart/SPY?' + urllib.parse.urlencode({
        'period1': int(start.timestamp()), 'period2': int(end.timestamp()),
        'interval': '1d', 'events': 'history',
    })
    response = subprocess.run(['curl', '--fail', '--silent', '--show-error', '--max-time', '45',
                               '-A', 'Mozilla/5.0 Catfolio-iOS', url], check=True, capture_output=True, text=True)
    chart = json.loads(response.stdout)['chart']
    if chart.get('error'):
        raise ValueError(chart['error'])
    result = chart['result'][0]
    if result['meta']['symbol'] != 'SPY' or result['meta']['currency'] != 'USD':
        raise ValueError('Unexpected security or currency')
    timestamps = result['timestamp']
    closes = result['indicators']['quote'][0]['close']
    if len(timestamps) != len(closes):
        raise ValueError('Timestamps and prices differ in length')
    prices = []
    for timestamp, close in zip(timestamps, closes):
        day = dt.datetime.fromtimestamp(timestamp, dt.timezone.utc).date()
        if close is None:
            continue
        if not math.isfinite(close) or close <= 0 or not start.date() <= day < end.date():
            raise ValueError('Invalid price or date')
        prices.append({'day': day.isoformat(), 'close': close})
    days = [row['day'] for row in prices]
    if len(prices) < 8000 or days[0] != '1993-01-29' or days != sorted(set(days)):
        raise ValueError('Incomplete, duplicate or unsorted history')
    if (end.date() - dt.date.fromisoformat(days[-1])).days > 7:
        raise ValueError('Snapshot is unexpectedly stale')
    snapshot = {'schemaVersion': 1, 'symbol': 'SPY', 'currency': 'USD', 'source': 'Yahoo Finance',
                'priceBasis': 'split-adjusted-close', 'sourceURL': url,
                'retrievedAt': now.isoformat(), 'firstDay': days[0], 'asOf': days[-1],
                'count': len(prices), 'prices': prices}
    encoded = json.dumps(snapshot, ensure_ascii=False, separators=(',', ':'), allow_nan=False) + '\n'
    temporary = OUTPUT.with_suffix('.json.tmp')
    temporary.write_text(encoded)
    temporary.replace(OUTPUT)
    print(f'SPY: {len(prices)} daily closes, {days[0]} through {days[-1]}, {len(encoded.encode())} bytes')


if __name__ == '__main__':
    main()
