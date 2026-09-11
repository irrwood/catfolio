import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]/'CatfolioIOS'

def test_snapshot_counts_and_targets():
    entries=json.loads((ROOT/'CatfolioIOS/Resources/analyst_history_catalog.json').read_text())['entries']
    assert len(entries)>70
    for key,d in entries.items():
        assert d['symbol']==key
        assert len({p['date'] for p in d['points']})==len(d['points'])
        for p in d['points']:
            assert p['price'] is None or p['price']>0
            if p['low'] is not None:assert p['low']<=p['mean']<=p['high']
            else:assert p['mean'] is None and p['high'] is None
    assert entries['AAPL']['points']!=entries['MSFT']['points']
    assert entries['RR']['status']=='UNSUPPORTED_LISTING'

def test_native_history_resource_and_entry():
    project=(ROOT/'CatfolioIOS.xcodeproj/project.pbxproj').read_text()
    assert 'analyst_history_catalog.json in Resources' in project
    view=(ROOT/'CatfolioIOS/AnalystHistoryView.swift').read_text()
    assert 'chartXSelection' in view and 'price / priceCeiling' in view
    assert 'position: .trailing' in view and '127.0.0.1' not in view
    assert 'catalog[symbol.uppercased()]' in view
    entry=(ROOT/'CatfolioIOS/AnalystConsensusView.swift').read_text()
    assert 'analyst-history-entry' in entry
    assert 'if symbol.uppercased() == "AAPL"' not in entry
