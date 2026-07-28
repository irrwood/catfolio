import pytest


def test_quote_currency_uses_broker_value_to_correct_gbx_mislabeled_as_usd():
    from app.data_store import resolve_quote_currency

    holding = {
        "price_currency": "GBX",
        "cost_currency": "GBX",
        "api_market_value_usd": 3.68,
    }
    assert resolve_quote_currency(holding, "USD", 340.55, 0.79035948) == "GBX"


def test_quote_currency_keeps_reported_currency_when_it_matches_broker_value():
    from app.data_store import resolve_quote_currency

    holding = {
        "price_currency": "GBX",
        "cost_currency": "GBX",
        "api_market_value_usd": 269.16,
    }
    assert resolve_quote_currency(holding, "USD", 340.55, 0.79035948) == "USD"


def test_reconcile_market_currencies_recomputes_value_and_pnl():
    from app.data_store import reconcile_market_currencies

    portfolio = {
        "holdings": [{
            "ticker": "TEST",
            "shares": 2,
            "price_currency": "GBX",
            "cost_currency": "GBX",
            "cost_usd_standard": 8,
            "api_market_value_usd": 10.768,
        }]
    }
    market = {
        "rows": [{
            "ticker": "TEST",
            "shares": 2,
            "quote_price": 400,
            "quote_currency": "USD",
            "cost_usd_standard": 8,
            "market_value_usd": 800,
        }]
    }
    row = reconcile_market_currencies(portfolio, market)["rows"][0]
    assert row["quote_currency"] == "GBX"
    assert row["market_value_usd"] == pytest.approx(10.768)
    assert row["unrealized_usd"] == pytest.approx(2.768)
    assert row["price_unrealized_usd"] == pytest.approx(2.768)
    assert row["pnl_basis"] == "price_difference"


def test_holdings_detail_uses_market_company_name():
    from app.analytics import holdings_detail

    snapshot = {
        "loaded_at": "company-name-test",
        "portfolio": {
            "holdings": [{
                "ticker": "NVDA",
                "name": "NVDA",
                "yahoo_symbol": "NVDA",
                "shares": 1,
                "cost_usd_standard": 100,
            }]
        },
        "market": {
            "rows": [{
                "ticker": "NVDA",
                "name": "NVIDIA Corporation",
                "company_name": "NVIDIA Corporation",
                "market_value_usd": 150,
            }]
        },
    }

    row = holdings_detail(snapshot)["rows"][0]
    assert row["company_name"] == "NVIDIA Corporation"


def test_trading212_ppl_is_primary_unrealized_pnl_and_fx_is_not_added_twice():
    from app.analytics import holdings_detail, portfolio_summary

    snapshot = {
        "loaded_at": "broker-ppl-including-fx-test",
        "portfolio": {
            "summary": {"total_cost_usd_standard": 100},
            "holdings": [{
                "ticker": "TEST",
                "name": "Test Holding",
                "shares": 1,
                "cost_usd_standard": 100,
            }],
        },
        "market": {"rows": [{"ticker": "TEST", "market_value_usd": 120}]},
        "trading212": {
            "summary": {"positions": 1},
            "account_cash": {"Trading212 API": {"currencyCode": "GBP"}},
            "account_info": {},
            "positions": [{
                "normalized_ticker": "TEST",
                "account": "Trading212 API",
                "ppl": 10,
                "fx_ppl": 3,
            }],
        },
    }

    row = holdings_detail(snapshot)["rows"][0]
    assert row["unrealized_usd"] == pytest.approx(13.46)
    assert row["broker_unrealized_usd"] == pytest.approx(13.46)
    assert row["broker_fx_ppl_usd"] == pytest.approx(4.038)
    assert row["broker_fx_ppl_percent"] == pytest.approx(4.038)
    assert row["price_unrealized_usd"] == pytest.approx(20)
    assert row["broker_ppl_includes_fx"] is True

    summary = portfolio_summary(snapshot)
    assert summary["unrealized_usd"] == pytest.approx(13.46)
    assert summary["price_unrealized_usd"] == pytest.approx(20)
    assert summary["unrealized_source"] == "trading212_ppl"
    assert summary["unrealized_includes_fx"] is True


def test_persisted_broker_pnl_survives_on_another_desktop_without_raw_api_cache():
    from app.analytics import holdings_detail

    snapshot = {
        "loaded_at": "portable-broker-ppl-test",
        "portfolio": {
            "summary": {"total_cost_usd_standard": 100},
            "holdings": [{
                "ticker": "TEST",
                "shares": 1,
                "cost_usd_standard": 100,
                "broker_unrealized_usd": 12.5,
                "broker_fx_ppl_usd": -2.5,
                "broker_unrealized_currency": "GBP",
                "broker_ppl_includes_fx": True,
            }],
        },
        "market": {"rows": [{"ticker": "TEST", "market_value_usd": 180}]},
        "trading212": {"summary": {}, "account_cash": {}, "positions": []},
    }

    row = holdings_detail(snapshot)["rows"][0]
    assert row["unrealized_usd"] == pytest.approx(12.5)
    assert row["broker_fx_ppl_usd"] == pytest.approx(-2.5)
    assert row["price_unrealized_usd"] == pytest.approx(80)
