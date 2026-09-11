import importlib.util
import json
from pathlib import Path


def _load_enricher():
    script = Path(__file__).resolve().parents[2] / "scripts" / "enrich_trading212_data.py"
    spec = importlib.util.spec_from_file_location("test_enrich_trading212_data", script)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_enricher_load_json_tolerates_missing_and_corrupt_cache(tmp_path):
    enrich = _load_enricher()
    fallback = {"accounts": []}

    assert enrich.load_json(tmp_path / "missing.json", fallback) is fallback

    corrupt = tmp_path / "corrupt.json"
    corrupt.write_text("{not-json", encoding="utf-8")
    assert enrich.load_json(corrupt, fallback) is fallback


def test_enricher_reuses_recent_account_info_during_incremental_refresh(tmp_path, monkeypatch):
    enrich = _load_enricher()
    output = tmp_path / "trading212_data.json"
    output.write_text(
        json.dumps(
            {
                "as_of_unix": 9_900,
                "accounts": [
                    {
                        "account_key": "default",
                        "account_info": {"id": "redacted-1234", "currencyCode": "GBP"},
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    captured = {}

    def fake_fetch(account, cached_account=None):
        captured[account] = cached_account
        return {
            "account": "Trading212 API",
            "account_key": account,
            "account_info": dict((cached_account or {}).get("account_info") or {}),
            "account_cash": {},
            "positions": [],
            "summary": {"auth_mode": "basic_key_secret", "account_info_cached": bool(cached_account)},
            "warnings": [],
        }

    monkeypatch.setattr(enrich, "OUTPUT", output)
    monkeypatch.setattr(enrich, "configured_accounts", lambda: ["default"])
    monkeypatch.setattr(enrich, "fetch_account", fake_fetch)
    monkeypatch.setattr(enrich.time, "time", lambda: 10_000)

    enrich.main()

    assert captured["default"]["account_info"]["currencyCode"] == "GBP"
    refreshed = json.loads(output.read_text(encoding="utf-8"))
    assert refreshed["summary"]["account_info_cache_hits"] == 1
    assert refreshed["accounts"][0]["account_info"]["id"] == "redacted-1234"
