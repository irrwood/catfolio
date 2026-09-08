"""Exposure lookups share one ticker index instead of rebuilding it per call.

``exposure_value_usd`` used to rebuild both ticker dicts on every call, which
made ``etf_lookthrough``, ``chart_exposure`` and ``lab_symbols`` quadratic in
the number of holdings. These tests pin the results (the refactor must not move
a single number) and count index construction so the pattern cannot come back.
"""


def _snapshot(tickers):
    return {
        "loaded_at": "2026-01-01T00:00:00+00:00",
        "portfolio": {
            "summary": {},
            "holdings": [
                {
                    "ticker": t,
                    "yahoo_symbol": t,
                    "cost_currency": "USD",
                    "cost_usd_standard": 100.0 + i,
                    "shares": 1,
                }
                for i, t in enumerate(tickers)
            ],
        },
        "market": {
            "rows": [
                {"ticker": t, "market_value_usd": 200.0 + i, "shares": 1}
                for i, t in enumerate(tickers)
            ],
        },
        "fundamentals": {"rows": []},
        "broker": {},
        "trading212": {"summary": {}, "positions": [], "account_cash": {}},
    }


def test_prebuilt_index_returns_the_same_value_as_building_it_per_call():
    from app import analytics

    snap = _snapshot(["AAPL", "MSFT", "VUSA"])
    index = analytics.snapshot_index(snap)

    for basis in ("market", "cost"):
        for ticker in ("AAPL", "MSFT", "VUSA", "ABSENT"):
            assert analytics.exposure_value_usd(ticker, snap, basis=basis, index=index) == \
                analytics.exposure_value_usd(ticker, snap, basis=basis)


def test_etf_lookthrough_builds_each_ticker_index_a_constant_number_of_times(monkeypatch):
    from app import analytics

    counts = {"holdings": 0, "market": 0}
    real_holdings = analytics.holdings_by_ticker
    real_market = analytics.market_by_ticker

    def counted_holdings(snapshot):
        counts["holdings"] += 1
        return real_holdings(snapshot)

    def counted_market(snapshot):
        counts["market"] += 1
        return real_market(snapshot)

    monkeypatch.setattr(analytics, "holdings_by_ticker", counted_holdings)
    monkeypatch.setattr(analytics, "market_by_ticker", counted_market)

    small = dict(counts)
    analytics.etf_lookthrough(_snapshot([f"T{i}" for i in range(5)]), basis="market")
    small = {k: counts[k] - small[k] for k in counts}

    large = dict(counts)
    analytics.etf_lookthrough(_snapshot([f"T{i}" for i in range(120)]), basis="market")
    large = {k: counts[k] - large[k] for k in counts}

    # 24x the holdings must not mean 24x the index rebuilds.
    assert small == large, f"index rebuilds scale with holdings: {small} vs {large}"
    assert large["holdings"] <= 2 and large["market"] <= 2


def test_lab_symbols_does_not_rebuild_the_index_per_holding(monkeypatch):
    from app import analytics, lab

    counts = {"n": 0}
    real = analytics.snapshot_index

    def counted(snapshot):
        counts["n"] += 1
        return real(snapshot)

    monkeypatch.setattr(lab, "snapshot_index", counted)

    lab.lab_symbols(_snapshot([f"T{i}" for i in range(60)]))

    assert counts["n"] == 1, f"expected one index build, got {counts['n']}"


def test_etf_lookthrough_keeps_every_direct_holding_exactly_once():
    from app import analytics

    # Two direct holdings that are not S&P constituents, plus a held ETF.
    snap = _snapshot(["ZZZA", "ZZZB", "VUSA"])
    rows = analytics.etf_lookthrough(snap, basis="market")["rows"]

    tickers = [row["ticker"] for row in rows]
    assert tickers.count("ZZZA") == 1
    assert tickers.count("ZZZB") == 1
    assert len(tickers) == len(set(tickers)), "look-through emitted a duplicate ticker"
