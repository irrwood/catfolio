"""Read-only bridge to the shared Core engine and its external daily snapshot."""
import json
import sys
from pathlib import Path

CORE = Path(__file__).resolve().parents[2] / 'core'
if str(CORE.parent) not in sys.path:
    sys.path.insert(0, str(CORE.parent))
from core.volatility import VolatilityRegimeEngine, SEMICONDUCTORS

DATA = Path('/Volumes/T7/CatData/core/storage/volatility/current.json')
# Explicit MVP universe; this is direct exposure, not a full classification database.


def snapshot(holdings=None):
    try:
        payload = json.loads(DATA.read_text())
        engine = VolatilityRegimeEngine()
        result = engine.evaluate(payload['volatility'], payload['prices'])
        result.update({'status': 'stale' if result['stale'] else 'ok', 'fetched_at': payload['fetched_at'], 'sources': payload['sources'],
                       'exposure_pct': engine.exposure(holdings or [], SEMICONDUCTORS), 'sector': '半导体'})
        return result
    except (OSError, ValueError, KeyError, TypeError):
        return {'status': 'unavailable', 'score': None, 'regime': 'Unknown', 'history': [], 'exposure_pct': None}
