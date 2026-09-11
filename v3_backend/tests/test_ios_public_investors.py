"""Disclosure delivery tests: preserve Core versions, nulls, and dates."""
import importlib.util
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


def test_packaged_data_contains_no_local_paths_or_fake_musk_portfolio():
    raw = (ROOT / 'CatfolioIOS/CatfolioIOS/Resources/public_investors.json').read_text()
    assert '/Volumes/' not in raw
    bundle = json.loads(raw)
    musk = next(i for i in bundle['investors'] if i['investorId'] == 'musk')
    assert musk['snapshot'] is None
    assert musk['activities'] == []
    assert len(bundle['coreSHA256']) == 64



def test_public_mode_uses_existing_pages_and_account_adapter():
    root = (ROOT / 'CatfolioIOS/CatfolioIOS/RootTabView.swift').read_text()
    model = (ROOT / 'CatfolioIOS/CatfolioIOS/APIClient.swift').read_text()
    assert 'PublicInvestorView(' not in root
    assert 'PortfolioView()' in root and 'ReturnsView()' in root
    assert 'publicInvestorStore.load(' in model
    assert 'catfolio.publicSelectedAccounts' in model
    assert 'guard !loaded.isPublicDisclosure else { return }' not in model


def test_investor_accounts_do_not_add_disclosure_labels_to_portfolio_ui():
    app = ROOT / 'CatfolioIOS/CatfolioIOS'
    for filename in ('PortfolioView.swift', 'VolumeProfileView.swift', 'PublicInvestorView.swift'):
        source = (app / filename).read_text()
        for label in ('公开投资者账户', '披露持仓 ·', '披露市值', '按披露上限估算', '原始披露：'):
            assert label not in source
    assert 'Text("CATFOLIO")' in (app / 'PortfolioView.swift').read_text()


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
