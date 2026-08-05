"""Demo snapshot — activated by CATFOLIO_DEMO=1.

No API keys or broker account needed. Returns a static, realistic-looking
portfolio so that anyone can `git clone && CATFOLIO_DEMO=1 run` and see
a fully-populated dashboard without setting up any external services.
"""

import math
from datetime import date, datetime, timedelta, timezone

_AS_OF_DATE = date(2026, 8, 4)
_AS_OF_ISO = _AS_OF_DATE.isoformat()
_AS_OF = int(datetime(2026, 8, 4, 20, 0, tzinfo=timezone.utc).timestamp())
_DEMO_ACCOUNT = "Demo Account"

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

# A deterministic first-fill date for every synthetic position.  These fields
# mirror the Trading 212 portfolio response closely enough for every view to
# exercise the same history pipeline as a real workspace.
_FILL_DATES = {
    "AAPL": "2022-03-14",
    "MSFT": "2022-09-06",
    "NVDA": "2023-01-20",
    "GOOGL": "2023-05-08",
    "META": "2023-09-18",
    "AMZN": "2024-01-12",
    "BRK.B": "2024-04-22",
    "SPY": "2024-07-15",
    "V": "2024-10-07",
    "JNJ": "2025-01-21",
    "LLOY.L": "2025-05-12",
    "BP.L": "2025-09-08",
    "VUAG.L": "2026-01-19",
}

_MARKET_META = {
    "AAPL": (58_400_000, 52_100_000, 3_080_000_000_000, 237.49, 164.08),
    "MSFT": (21_800_000, 24_700_000, 3_180_000_000_000, 468.35, 344.77),
    "NVDA": (312_000_000, 284_000_000, 2_220_000_000_000, 974.00, 392.30),
    "GOOGL": (27_600_000, 30_900_000, 2_270_000_000_000, 191.75, 120.21),
    "META": (13_900_000, 16_800_000, 1_440_000_000_000, 638.40, 414.50),
    "AMZN": (38_500_000, 41_200_000, 2_190_000_000_000, 242.52, 151.61),
    "BRK.B": (3_600_000, 4_100_000, 975_000_000_000, 491.67, 396.35),
    "SPY": (54_000_000, 62_000_000, 493_000_000_000, 613.23, 493.86),
    "V": (7_400_000, 8_100_000, 570_000_000_000, 321.61, 252.70),
    "JNJ": (6_900_000, 7_600_000, 350_000_000_000, 168.85, 140.68),
    "LLOY.L": (118_000_000, 135_000_000, 42_000_000_000, 64.20, 49.10),
    "BP.L": (26_000_000, 31_000_000, 78_000_000_000, 539.40, 379.70),
    "VUAG.L": (180_000, 210_000, 8_900_000_000, 10_180.00, 7_820.00),
}

_FX = {"USD": 1.0, "GBP": 1.346, "GBX": 0.01346}  # GBX = pence → USD


def _usd(amount, ccy):
    return round(amount * _FX.get(ccy, 1.0), 2)


def _build_snapshot():
    holdings = []
    holdings_by_account = []
    market_rows = []
    broker_positions = []
    total_cost = 0.0
    broker_unrealized_total = 0.0
    broker_fx_total = 0.0

    for ticker, name, yahoo, ccy, shares, avg_cost, price, chg in _H:
        cost_native = shares * avg_cost
        mv_native = shares * price
        cost_usd = _usd(cost_native, ccy)
        mv_usd = _usd(mv_native, ccy)
        pnl_usd = round(mv_usd - cost_usd, 2)
        pnl_pct = round((mv_usd / cost_usd - 1) * 100, 2) if cost_usd else 0
        total_cost += cost_usd

        price_pnl_usd = round(mv_usd - cost_usd, 2)
        fx_pnl_usd = round(-cost_usd * 0.0125, 2) if ccy == "GBX" else 0.0
        broker_pnl_usd = round(price_pnl_usd + fx_pnl_usd, 2)
        api_ticker = ticker
        base_holding = {
            "ticker": ticker,
            "name": name,
            "yahoo_symbol": yahoo,
            "account": _DEMO_ACCOUNT,
            "accounts": _DEMO_ACCOUNT,
            "api_ticker": api_ticker,
            "shares": shares,
            "cost_currency": ccy,
            "avg_cost_native": round(avg_cost, 4),
            "avg_cost_usd_standard": round(cost_usd / shares, 4),
            "cost_native": round(cost_native, 4),
            "cost_usd_standard": round(cost_usd, 2),
            "api_market_value_usd": mv_usd,
            "api_unrealized_usd": broker_pnl_usd,
            "price_unrealized_usd": price_pnl_usd,
            "price_unrealized_percent": pnl_pct,
            "broker_unrealized_account": broker_pnl_usd,
            "broker_unrealized_currency": "USD",
            "broker_unrealized_usd": broker_pnl_usd,
            "broker_fx_ppl_account": fx_pnl_usd,
            "broker_fx_ppl_usd": fx_pnl_usd,
            "broker_ppl_includes_fx": True,
            "last_trade_price": price,
            "last_trade_price_currency": ccy,
            "last_trade_time": f"{_AS_OF_ISO}T20:00:00Z",
            "price_currency": ccy,
            "buys": 1,
            "sells": 0,
            "stock_dividends": 0,
        }
        holdings.append(base_holding)
        holdings_by_account.append(dict(base_holding))
        broker_unrealized_total += broker_pnl_usd
        broker_fx_total += fx_pnl_usd

        volume, avg_volume, market_cap, high_52w, low_52w = _MARKET_META[ticker]
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
            "price_unrealized_usd": price_pnl_usd,
            "price_unrealized_percent": pnl_pct,
            "pnl_basis": "price_difference",
            "change_percent": chg,
            "today_change_percent": chg,
            "trailing_pe": None,
            "forward_pe": None,
            "volume": volume,
            "avg_volume_3m": avg_volume,
            "market_cap": market_cap,
            "high_52w": high_52w,
            "low_52w": low_52w,
            "open_price": round(price / (1 + chg / 100), 4),
            "market_time": _AS_OF,
            "source": "demo",
        })

        broker_positions.append({
            "account": _DEMO_ACCOUNT,
            "account_key": "demo",
            "ticker": api_ticker,
            "normalized_ticker": ticker,
            "name": name,
            "quantity": shares,
            "quantity_available_for_trading": shares,
            "quantity_in_pies": 0,
            "average_price_paid": round(avg_cost, 4),
            "current_price": price,
            "currency": ccy,
            "invested": round(cost_usd, 2),
            "ppl": broker_pnl_usd,
            "fx_ppl": fx_pnl_usd,
            "initial_fill_date": f"{_FILL_DATES[ticker]}T14:30:00Z",
            "type": "ETF" if ticker in {"SPY", "VUAG.L"} else "STOCK",
            "result": "demo",
        })

    portfolio = {
        "summary": {
            "total_cost_usd_standard": round(total_cost, 2),
            "open_positions": len(holdings),
            "open_positions_by_account": {_DEMO_ACCOUNT: len(holdings)},
            "closed_positions": 0,
            "transactions": len(holdings),
            "dividends_usd_standard": 286.40,
            "interest_usd_standard": 42.75,
            "dividends_by_currency": {"USD": 286.40},
            "interest_by_currency": {"USD": 42.75},
            "dividends_by_account_currency": {_DEMO_ACCOUNT: {"USD": 286.40}},
            "interest_by_account_currency": {_DEMO_ACCOUNT: {"USD": 42.75}},
            "cash_movements_by_account_currency": {_DEMO_ACCOUNT: {"USD": 329.15}},
            "report_fx_to_usd": dict(_FX),
            "report_fx_source": "fixed synthetic demo rates",
            "price_pnl_basis": "current_price_minus_average_cost",
            "unrealized_pnl_basis": "broker_ppl_including_fx",
            "cost_scale_by_currency": {"USD": 1.0, "GBX": 0.01},
            "cost_scale_by_account_gbp_available": {_DEMO_ACCOUNT: True},
            "source_files": [],
            "version": 2,
            "warnings": ["Synthetic demo portfolio; no personal or broker data is used."],
            "as_of": f"{_AS_OF_ISO} 20:00:00",
        },
        "holdings": holdings,
        "holdings_by_account": holdings_by_account,
        "closed_positions": [],
        "import_transactions": [],
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
        "account_cash": {
            _DEMO_ACCOUNT: {
                "free": 2140.30,
                "blocked": 0.0,
                "invested": round(total_cost, 2),
                "ppl": round(broker_unrealized_total, 2),
                "total": round(total_cost + broker_unrealized_total + 2140.30, 2),
                "currencyCode": "USD",
                "result": "demo",
            }
        },
        "account_info": {_DEMO_ACCOUNT: {"currencyCode": "USD", "result": "demo"}},
        "positions": broker_positions,
        "warnings": [],
        "source": "demo",
    }

    return {
        "portfolio": portfolio,
        "market": market,
        "fundamentals": fundamentals,
        "trading212": trading212,
        "loaded_at": f"{_AS_OF_ISO}T20:00:00+00:00",
        "demo": True,
    }


def _trading_dates(start=date(2021, 8, 4), end=_AS_OF_DATE):
    current = start
    rows = []
    while current <= end:
        if current.weekday() < 5:
            rows.append(current.isoformat())
        current += timedelta(days=1)
    return rows


def _demo_price_path(final_price, annual_drift, daily_wave, phase):
    dates = _trading_dates()
    nav = 1.0
    raw = []
    for index, _day in enumerate(dates):
        cycle = math.sin(index / 17.0 + phase) * daily_wave
        slow_cycle = math.cos(index / 71.0 + phase / 2.0) * daily_wave * 0.55
        # Add a shorter, phase-shifted wave so demo charts have visible local
        # movement instead of reading as overly smooth trend lines. Keeping it
        # deterministic makes screenshots and tests stable across deployments.
        texture = math.sin(index / 2.8 + phase * 1.7) * daily_wave * 1.4
        shock = -daily_wave * 3.2 if index in {178, 431, 782} else 0.0
        rebound = daily_wave * 2.1 if index in {190, 447, 801} else 0.0
        ret = annual_drift / 252.0 + cycle + slow_cycle + texture + shock + rebound
        nav *= max(0.72, 1.0 + ret)
        raw.append(nav)
    scale = final_price / (raw[-1] or 1.0)
    closes = [value * scale for value in raw]
    rows = []
    previous = closes[0]
    for index, (day, close) in enumerate(zip(dates, closes)):
        open_price = previous * (1 + math.sin(index / 3.7 + phase) * daily_wave * 0.45)
        spread = max(0.0025, daily_wave * (0.85 + abs(math.cos(index / 11.0 + phase))))
        high = max(open_price, close) * (1 + spread)
        low = min(open_price, close) * (1 - spread * 0.92)
        volume = int(1_200_000 * (1.15 + abs(math.sin(index / 9.0 + phase)) * 2.8))
        rows.append({
            "date": day,
            "open": round(open_price, 4),
            "high": round(high, 4),
            "low": round(low, 4),
            "close": round(close, 4),
            "raw_close": round(close, 4),
            "volume": volume,
        })
        previous = close
    return rows


def _build_lab_history():
    profile = {
        "AAPL": (196.45, 0.13, 0.0065, 0.4),
        "MSFT": (428.30, 0.14, 0.0060, 0.9),
        "NVDA": (892.10, 0.31, 0.0120, 1.4),
        "GOOGL": (182.60, 0.12, 0.0070, 2.0),
        "META": (568.40, 0.19, 0.0090, 2.6),
        "AMZN": (208.15, 0.15, 0.0085, 3.0),
        "BRK-B": (452.20, 0.10, 0.0045, 3.4),
        "SPY": (538.00, 0.11, 0.0050, 3.8),
        "V": (288.75, 0.11, 0.0055, 4.2),
        "JNJ": (145.20, 0.04, 0.0035, 4.8),
        "LLOY.L": (55.10, 0.07, 0.0070, 5.2),
        "BP.L": (425.30, 0.05, 0.0080, 5.7),
        "VUAG.L": (9248.00, 0.10, 0.0050, 6.1),
        "QQQ": (455.00, 0.15, 0.0075, 6.6),
        "VTI": (266.00, 0.105, 0.0052, 7.0),
        "VOO": (493.00, 0.108, 0.0050, 7.4),
        "DIA": (391.00, 0.075, 0.0042, 7.8),
        "IWM": (204.00, 0.065, 0.0078, 8.2),
        "VEU": (61.00, 0.045, 0.0062, 8.6),
        "GLD": (215.00, 0.055, 0.0048, 9.0),
    }
    return {
        "as_of_unix": _AS_OF,
        "duration_seconds": 0,
        "years": 5,
        "symbols": list(profile),
        "prices": {
            symbol: _demo_price_path(final_price, drift, wave, phase)
            for symbol, (final_price, drift, wave, phase) in profile.items()
        },
        "benchmarks": {
            "SPY": "S&P 500",
            "QQQ": "Nasdaq 100",
            "VTI": "US Total Market",
            "VOO": "Vanguard S&P 500",
            "DIA": "Dow Jones 30",
            "IWM": "US Small Cap",
            "VEU": "World ex-US",
            "GLD": "Gold",
        },
        "warnings": [],
        "source": "demo offline price series",
    }


DEMO_SNAPSHOT = _build_snapshot()
DEMO_LAB_HISTORY = _build_lab_history()

DEMO_INCOME_SUMMARY = {
    "currency": "USD",
    "rows": [
        {"year": "2024", "dividends_usd": 72.15, "cash_interest_usd": 8.20},
        {"year": "2025", "dividends_usd": 126.40, "cash_interest_usd": 19.75},
        {"year": "2026", "dividends_usd": 87.85, "cash_interest_usd": 14.80},
    ],
    "monthly_rows": [
        {"month": "2026-05", "dividends_usd": 21.30, "cash_interest_usd": 3.50},
        {"month": "2026-06", "dividends_usd": 34.75, "cash_interest_usd": 3.80},
        {"month": "2026-07", "dividends_usd": 13.56, "cash_interest_usd": 4.10},
        {"month": "2026-08", "dividends_usd": 18.24, "cash_interest_usd": 3.40},
    ],
}
