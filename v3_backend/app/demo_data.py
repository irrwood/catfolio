"""Demo snapshot — activated by HELM_DEMO=1.

No API keys or broker account needed. Returns a static, realistic-looking
portfolio so that anyone can `git clone && HELM_DEMO=1 run` and see
a fully-populated dashboard without setting up any external services.
"""

_AS_OF = 1748779200  # 2025-06-01 12:00 UTC (fixed demo date)

# ── Holdings table (shared source of truth) ─────────────────────────
# (ticker, name, yahoo_symbol, cost_currency, shares, avg_cost_native, price_native, change_pct_today)
# UK prices in GBX (pence); USD stocks in USD
_H = [
    ("AAPL",   "Apple Inc.",                       "AAPL",    "USD", 10,   148.00, 196.45, +0.82),
    ("MSFT",   "Microsoft Corp.",                  "MSFT",    "USD",  8,   318.00, 428.30, +1.14),
    ("NVDA",   "NVIDIA Corp.",                     "NVDA",    "USD",  5,   490.00, 892.10, +2.31),
    ("GOOGL",  "Alphabet Inc.",                    "GOOGL",   "USD",  3,   138.00, 182.60, +0.55),
    ("META",   "Meta Platforms Inc.",              "META",    "USD",  6,   375.00, 568.40, +1.07),
    ("AMZN",   "Amazon.com Inc.",                  "AMZN",    "USD",  4,   162.00, 208.15, +0.93),
    ("BRK.B",  "Berkshire Hathaway Inc. B",        "BRK-B",   "USD", 15,   355.00, 452.20, +0.21),
    ("SPY",    "SPDR S&P 500 ETF Trust",           "SPY",     "USD", 12,   442.00, 538.00, +0.44),
    ("V",      "Visa Inc.",                        "V",       "USD", 10,   238.00, 288.75, +0.67),
    ("JNJ",    "Johnson & Johnson",                "JNJ",     "USD",  8,   158.00, 145.20, -0.33),
    ("LLOY.L", "Lloyds Banking Group plc",         "LLOY.L",  "GBX",500,    45.00,  55.10, +0.91),
    ("BP.L",   "BP p.l.c.",                        "BP.L",    "GBX",200,   398.00, 425.30, -0.44),
    ("VUAG.L", "Vanguard S&P 500 UCITS ETF",       "VUAG.L",  "GBX", 30,  8800.00,9248.00, +0.51),
]

_FX = {"USD": 1.0, "GBP": 1.346, "GBX": 0.01346}  # GBX = pence → USD


def _usd(amount, ccy):
    return round(amount * _FX.get(ccy, 1.0), 2)


def _build_snapshot():
    holdings = []
    market_rows = []
    total_cost = 0.0

    for ticker, name, yahoo, ccy, shares, avg_cost, price, chg in _H:
        cost_native = shares * avg_cost
        mv_native = shares * price
        cost_usd = _usd(cost_native, ccy)
        mv_usd = _usd(mv_native, ccy)
        pnl_usd = round(mv_usd - cost_usd, 2)
        pnl_pct = round((mv_usd / cost_usd - 1) * 100, 2) if cost_usd else 0
        total_cost += cost_usd

        holdings.append({
            "ticker": ticker,
            "name": name,
            "yahoo_symbol": yahoo,
            "shares": shares,
            "cost_currency": ccy,
            "avg_cost_native": round(avg_cost, 4),
            "cost_usd_standard": round(cost_usd, 2),
            "last_trade_price": price,
            "price_currency": ccy,
        })

        market_rows.append({
            "ticker": ticker,
            "name": name,
            "yahoo_symbol": yahoo,
            "shares": shares,
            "cost_currency": ccy,
            "avg_cost_native": round(avg_cost, 4),
            "cost_usd_standard": round(cost_usd, 2),
            "quote_price": price,
            "quote_currency": ccy,
            "market_value_native": round(mv_native, 2),
            "market_value_usd": mv_usd,
            "unrealized_usd": pnl_usd,
            "unrealized_percent": pnl_pct,
            "change_percent": chg,
            "today_change_percent": chg,
            "trailing_pe": None,
            "forward_pe": None,
            "volume": None,
            "avg_volume_3m": None,
            "market_cap": None,
            "high_52w": None,
            "low_52w": None,
            "open_price": None,
            "market_time": _AS_OF,
            "source": "demo",
        })

    portfolio = {
        "summary": {
            "total_cost_usd_standard": round(total_cost, 2),
            "open_positions": len(holdings),
            "as_of": "2025-06-01",
        },
        "holdings": holdings,
        "holdings_by_account": [{"account": "Demo Account", "holdings": holdings}],
    }

    market = {
        "as_of_unix": _AS_OF,
        "rows": market_rows,
        "warnings": [],
        "source": "demo",
        "ttl_seconds": 120,
    }

    # PE / valuation — US stocks only (rough 2025 estimates)
    _PE = {
        "AAPL":  (30.2, 27.8, 8.2,  7.8,  6.78, 0.09,  0.04),
        "MSFT":  (34.1, 31.5, 12.0, 12.5, 11.37, 0.15,  0.16),
        "NVDA":  (48.3, 35.2, 28.5,  4.2, 24.89, 1.42,  1.22),
        "GOOGL": (22.4, 20.1,  5.8,  5.5, 7.63,  0.12,  0.15),
        "META":  (26.8, 24.4, 10.1,  7.4,  14.52, 0.19,  0.22),
        "AMZN":  (42.1, 33.8, 3.6,  7.8,  4.39,  0.18,  0.11),
        "BRK.B": (21.0, 19.5, 2.2,  1.4,  15.60, 0.08,  0.09),
        "SPY":   (22.5, 21.0, 2.8,  4.2,  None,  None,  None),
        "V":     (29.3, 27.1, 14.8, 14.6, 9.42,  0.12,  0.10),
        "JNJ":   (15.1, 14.2, 4.2,  4.0,  5.76,  0.04,  0.03),
    }
    fund_rows = []
    for ticker, (tpe, fpe, ps, pb, eps, epsg, revg) in _PE.items():
        fund_rows.append({
            "ticker": ticker,
            "trailing_pe": tpe,
            "forward_pe": fpe,
            "price_to_sales": ps,
            "price_to_book": pb,
            "eps_ttm": eps,
            "eps_growth_yoy": epsg,
            "revenue_growth_yoy": revg,
            "source": "demo",
        })

    fundamentals = {
        "as_of_unix": _AS_OF,
        "rows": fund_rows,
        "warnings": [],
        "source": "demo",
    }

    trading212 = {
        "as_of_unix": _AS_OF,
        "summary": {"positions": len(holdings)},
        "account_cash": {"total": 2500.0, "currency": "USD"},
        "positions": [
            {
                "ticker": h["ticker"],
                "name": h["name"],
                "shares": h["shares"],
                "avg_cost_native": h["avg_cost_native"],
                "last_trade_price": h["last_trade_price"],
                "price_currency": h["price_currency"],
                "cost_currency": h["cost_currency"],
            }
            for h in holdings
        ],
        "warnings": [],
        "source": "demo",
    }

    return {
        "portfolio": portfolio,
        "market": market,
        "fundamentals": fundamentals,
        "trading212": trading212,
        "loaded_at": "2025-06-01T12:00:00+00:00",
        "demo": True,
    }


DEMO_SNAPSHOT = _build_snapshot()
