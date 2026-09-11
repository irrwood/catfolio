#!/usr/bin/env python3
"""Independent daily batch / read-only export / acceptance diagnostics."""
import argparse
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'v3_backend'))
from app.sector_rotation import DB_PATH, calendar, expected_session, read_snapshot, run_batch, validate_history


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--db', type=Path, default=DB_PATH)
    parser.add_argument('--backfill', type=int, default=60)
    parser.add_argument('--validate', action='store_true')
    parser.add_argument('--daily', action='store_true', help='Skip holidays, early runs and already-complete sessions')
    parser.add_argument('--export', type=Path)
    parser.add_argument('--export-history', type=Path)
    args = parser.parse_args()
    if args.daily:
        now = datetime.now(timezone.utc)
        local_date = now.astimezone(ZoneInfo('America/New_York')).date().isoformat()
        target = expected_session(now)
        latest = read_snapshot(args.db, now=now)
        if not calendar().is_session(local_date) or target != local_date:
            print(json.dumps({'skipped': 'Holiday or adjusted-price readiness time not reached'}))
            return 0
        if latest.get('asOf') == target and not latest['stale']:
            print(json.dumps({'skipped': 'Session already complete', 'target': target}))
            return 0
    if args.validate:
        result = validate_history(args.db)
    elif args.export_history:
        latest = read_snapshot(args.db)
        result = [read_snapshot(args.db, as_of=d) for d in latest['dates']]
        args.export_history.parent.mkdir(parents=True, exist_ok=True)
        temp = args.export_history.with_suffix('.tmp')
        temp.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':'), allow_nan=False))
        temp.replace(args.export_history)
        result = {'exported': len(result), 'path': str(args.export_history)}
    elif args.export:
        result = read_snapshot(args.db)
        args.export.parent.mkdir(parents=True, exist_ok=True)
        temp = args.export.with_suffix('.tmp')
        temp.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
        temp.replace(args.export)
    else:
        if args.backfill < 1:
            parser.error('--backfill must be positive')
        result = run_batch(args.db, backfill=args.backfill)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if args.validate and not result['passed']:
        return 2
    return 0

if __name__ == '__main__':
    sys.exit(main())
