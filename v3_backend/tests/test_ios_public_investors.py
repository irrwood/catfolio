"""Disclosure delivery tests: preserve Core versions, nulls, and dates."""
import importlib.util
import copy
import json
from pathlib import Path
import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('investor_export', ROOT / 'scripts/export_ios_public_investors.py')
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)


def fixture_bundle():
    return dict(schemaVersion=1, releaseId='fixture', asOf='2026-09-07',
                investors=[dict(investorId='hh')], sources=[dict(sourceId='source', filedDate='2026-08-14', sourceURL='https://example.test/report')],
                snapshots=[], disclosedViews=[], derived={'hh': dict(latestSnapshotId=None, activityIds=['current'])},
                activities=[dict(activityId=id, investorId='hh', sourceId='source', type='INCREASED', exactDate=None, amount=None) for id in ['old-version', 'current']])


def test_export_selects_only_current_core_activity_version():
    result = export.project(fixture_bundle())['investors'][0]
    assert [row['activityId'] for row in result['activities']] == ['current']
    assert result['activities'][0]['exactDate'] is None
    assert result['activities'][0]['amount'] is None


def test_export_rejects_future_disclosures():
    bundle = fixture_bundle()
    bundle['sources'][0]['filedDate'] = '2026-10-01'
    with pytest.raises(ValueError, match='Future'):
        export.project(bundle)


def test_supplements_are_idempotent_and_preserve_core_snapshots():
    catalog = json.loads((ROOT / 'CatfolioIOS/CatfolioIOS/Resources/public_investors.json').read_text())
    update = json.loads((export.UPDATE_ROOT / 'updates/2026-10-20.json').read_text())
    base = copy.deepcopy(catalog)
    added_ids = {a['activityId'] for a in update['activities']}
    for investor in base['investors']:
        investor['activities'] = [a for a in investor['activities'] if a['activityId'] not in added_ids]
    base.pop('supplementalSources', None)
    base['releaseId'] = base.pop('coreReleaseId')
    base['asOf'] = '2026-09-09'
    once = export.apply_updates(base, [update])
    assert sum(len(i['activities']) for i in once['investors']) - sum(len(i['activities']) for i in base['investors']) == 13
    assert once['releaseId'] != base['releaseId']
    assert once == catalog
    assert export.apply_updates(once, [update]) == once
    assert once['coreSHA256'] == catalog['coreSHA256']
    assert len(once['supplementalSources']) == 2
    for before, after in zip(catalog['investors'], once['investors']):
        assert after['snapshot'] == before['snapshot']
        assert after['history'] == before['history']
        assert len({a['activityId'] for a in after['activities']}) == len(after['activities'])
    pelosi = next(i for i in once['investors'] if i['investorId'] == 'pelosi')
    private = next(a for a in pelosi['activities'] if a['activityId'] == 'house-20035553-row-1')
    assert private['ticker'] is None and private['shares'] is None and private['amount'] is None
    assert (private['amountLow'], private['amountHigh']) == (500001, 1000000)


def test_supplements_reject_tampered_archives_and_future_dates():
    catalog = json.loads((ROOT / 'CatfolioIOS/CatfolioIOS/Resources/public_investors.json').read_text())
    update = json.loads((export.UPDATE_ROOT / 'updates/2026-10-20.json').read_text())
    update['sources'][0]['sha256'] = '0' * 64
    with pytest.raises(ValueError, match='checksum'):
        export.apply_updates(catalog, [update])
    update['sources'][0]['filedDate'] = '2027-01-01'
    with pytest.raises(ValueError, match='Future'):
        export.apply_updates(catalog, [update])


def test_packaged_data_contains_no_local_paths_or_fake_musk_portfolio():
    raw = (ROOT / 'CatfolioIOS/CatfolioIOS/Resources/public_investors.json').read_text()
    assert '/Volumes/' not in raw
    bundle = json.loads(raw)
    musk = next(i for i in bundle['investors'] if i['investorId'] == 'musk')
    assert musk['snapshot'] is None
    assert musk['activities'] == []
    assert len(bundle['coreSHA256']) == 64


def test_ark_account_has_continuous_history_and_mapped_equity():
    bundle = json.loads((ROOT / 'CatfolioIOS/CatfolioIOS/Resources/public_investors.json').read_text())
    ark = next(i for i in bundle['investors'] if i['investorId'] == 'ark')
    assert ark['cik'] == '0001697748'
    assert ark['sourceType'] == 'SEC_13F'
    assert len(ark['history']) == 11
    assert ark['history'][0]['effectiveDate'] == '2023-12-31'
    assert ark['snapshot']['effectiveDate'] == '2026-06-30'
    assert all(row['sourceURL'].startswith('https://www.sec.gov/') for row in ark['history'])
    assert any(p['ticker'] == 'TSLA' and p['shares'] > 0 for p in ark['snapshot']['positions'])
    assert len(ark['activities']) > 0


def test_investor_accounts_do_not_add_disclosure_labels_to_portfolio_ui():
    app = ROOT / 'CatfolioIOS/CatfolioIOS'
    for filename in ('PortfolioView.swift', 'VolumeProfileView.swift', 'PublicInvestorView.swift'):
        source = (app / filename).read_text()
        for label in ('公开投资者账户', '披露持仓 ·', '披露市值', '按披露上限估算', '原始披露：'):
            assert label not in source
