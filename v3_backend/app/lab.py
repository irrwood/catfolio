import csv
import json
import math
import random
import ssl
import time
import urllib.request
from collections import defaultdict
from statistics import mean, stdev
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

from .analytics import _num, exposure_value_usd, holdings_by_ticker, market_by_ticker
from .cache import cached
from .data_store import current_snapshot, demo_mode, load_json
from .settings import LAB_HISTORY_CACHE, LAB_HISTORY_TTL_SECONDS, ROOT, V2_DIR

BENCHMARKS = {
    "SPY": "S&P 500",
    "QQQ": "Nasdaq 100",
    "VTI": "US Total Market",
    "VOO": "Vanguard S&P 500",
    "DIA": "Dow Jones 30",
    "IWM": "US Small Cap",
    "VEU": "World ex-US",
    "GLD": "Gold",
}

BENCHMARK_CN = {
    "SPY": "标普500",
    "QQQ": "纳斯达克100",
    "VTI": "美国全市场",
    "VOO": "先锋标普500",
    "DIA": "道琼斯30",
    "IWM": "罗素2000",
    "VEU": "全球除美",
    "GLD": "黄金",
}

ASSET_ALIASES = {
    "VUAG.L": "S&P 500 Fund",
    "VUSA.L": "S&P 500 Fund",
}

SOURCE_FILES = []

def _init_source_files():
    """Load transaction CSV files from CATFOLIO_DATA_DIR or default locations."""
    import os
    import glob as _glob

    def csv_sources(data_dir):
        if not data_dir or not os.path.isdir(data_dir):
            return []
        csv_files = sorted(_glob.glob(os.path.join(data_dir, "*.csv")))
        result = []
        for f in csv_files:
            basename = os.path.basename(f)
            # Extract account label from filename: "账户 A-from_2023..."
            account = "A" if "A" in basename.split("-")[0] else "B"
            result.append((account, f))
        return result

    env_keys = ("CATFOLIO_DATA_DIR", "HELM_DATA_DIR", "PORTFOLIO_DATA_DIR", "TRADING212_DATA_DIR", "STOCK_DATA_DIR")
    for key in env_keys:
        result = csv_sources(os.environ.get(key, ""))
        if result:
            return result

    # Fallback: try common locations
    candidates = [
        str(ROOT),
        os.path.expanduser("~/Documents/股票分析"),
        os.path.expanduser("~/Documents/股票"),
        os.path.expanduser("~/Library/Mobile Documents/com~apple~CloudDocs/Documents/股票"),
        os.path.expanduser("~/Downloads"),
    ]
    for cand in candidates:
        result = csv_sources(cand)
        if result:
            return result
    
    return []

SOURCE_FILES = _init_source_files()

BUY_ACTIONS = {"Market buy", "Limit buy"}
SELL_ACTIONS = {"Market sell"}
REPORT_FX_TO_USD = {
    "USD": Decimal("1"),
    "GBP": Decimal("1.3460"),
    "GBX": Decimal("0.013460"),
    "EUR": Decimal("1.1630"),
}


def _open_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return json.loads(response.read().decode("utf-8"))
    except Exception as exc:
        if "CERTIFICATE_VERIFY_FAILED" not in str(exc):
            raise
        with urllib.request.urlopen(req, timeout=20, context=ssl._create_unverified_context()) as response:
            return json.loads(response.read().decode("utf-8"))


def _dec(value):
    if value is None or value == "":
        return Decimal("0")
    try:
        return Decimal(str(value).replace(",", ""))
    except InvalidOperation:
        return Decimal("0")


def _trade_usd(row):
    total = _dec(row.get("Total"))
    currency = row.get("Currency (Total)") or row.get("Currency (Price / share)") or ""
    rate = REPORT_FX_TO_USD.get(currency)
    if rate is None:
        return 0.0
    fee = _dec(row.get("Currency conversion fee"))
    fee_currency = row.get("Currency (Currency conversion fee)") or "GBP"
    fee_rate = REPORT_FX_TO_USD.get(fee_currency, Decimal("0"))
    return float((total * rate) + (fee * fee_rate))


def _yahoo_symbol(ticker, currency):
    overrides = {
        "BRK.B": "BRK-B",
        "ENR": "ENR.DE",
        "RWE": "RWE.DE",
        "VUAG": "VUAG.L",
        "VUSA": "VUSA.L",
        "BARC": "BARC.L",
    }
    if ticker in overrides:
        return overrides[ticker]
    if currency in {"GBP", "GBX"} and "." not in ticker:
        return f"{ticker}.L"
    return ticker


def _parse_datetime(time_str):
    if not time_str:
        return None
    time_str = time_str.strip()
    if " +" in time_str:
        time_str = time_str.split(" +")[0]
    if " UTC" in time_str:
        time_str = time_str.replace(" UTC", "")
        
    for fmt in ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S.%f", "%d/%m/%Y %H:%M:%S", "%Y/%m/%d %H:%M:%S", "%Y-%m-%d", "%d/%m/%Y"]:
        try:
            return datetime.strptime(time_str, fmt)
        except ValueError:
            continue
            
    try:
        if len(time_str) >= 10:
            if time_str[4] == "-" and time_str[7] == "-":
                return datetime.strptime(time_str[:10], "%Y-%m-%d")
            elif time_str[2] == "/" and time_str[5] == "/":
                return datetime.strptime(time_str[:10], "%d/%m/%Y")
    except Exception:
        pass
    return None


def _read_trade_transactions():
    global SOURCE_FILES
    rows = []
    if not SOURCE_FILES:
        SOURCE_FILES = _init_source_files()
    for account, file_path in SOURCE_FILES:
        path = Path(file_path)
        if not path.exists():
            continue
        with path.open("r", encoding="utf-8-sig", newline="") as handle:
            reader = csv.DictReader(handle)
            for row in reader:
                action = row.get("Action")
                ticker = row.get("Ticker") or row.get("Symbol") or ""
                if action not in BUY_ACTIONS | SELL_ACTIONS or not ticker:
                    continue
                row["Account"] = account
                row["Source file"] = path.name
                time_val = row.get("Time") or row.get("Date") or ""
                dt = _parse_datetime(time_val)
                if not dt:
                    continue
                row["dt"] = dt
                row["date"] = dt.strftime("%Y-%m-%d")
                rows.append(row)
    rows.sort(key=lambda row: (row["dt"], row["Account"], row.get("ID", "")))
    return rows


def fetch_history(symbol, years=5):
    period2 = int(time.time())
    period1 = period2 - int(years * 365.25 * 24 * 60 * 60)
    url = f"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?period1={period1}&period2={period2}&interval=1d"
    payload = _open_json(url)
    result = payload.get("chart", {}).get("result") or []
    if not result:
        return []
    data = result[0]
    timestamps = data.get("timestamp") or []
    closes = (data.get("indicators", {}).get("adjclose", [{}])[0].get("adjclose") or data.get("indicators", {}).get("quote", [{}])[0].get("close") or [])
    rows = []
    for ts, close in zip(timestamps, closes):
        if close is None:
            continue
        rows.append({"date": time.strftime("%Y-%m-%d", time.gmtime(int(ts))), "close": float(close)})
    return rows


def history_cache_age_seconds():
    data = load_json(LAB_HISTORY_CACHE, None)
    if not data or not data.get("as_of_unix"):
        return None
    return max(0, int(time.time()) - int(data["as_of_unix"]))


def lab_symbols(snapshot, max_symbols=35):
    holdings = snapshot["portfolio"].get("holdings", [])
    ranked = sorted(holdings, key=lambda row: exposure_value_usd(row.get("ticker"), snapshot, basis="market"), reverse=True)
    symbols = []
    for row in ranked:
        symbol = row.get("yahoo_symbol") or row.get("ticker")
        if symbol and symbol not in symbols:
            symbols.append(symbol)
        if len(symbols) >= max_symbols:
            break
    for symbol in BENCHMARKS:
        if symbol not in symbols:
            symbols.append(symbol)
    return symbols


def refresh_history(force=False, years=5):
    if demo_mode():
        from .demo_data import DEMO_LAB_HISTORY
        return {"ok": True, "cached": True, "age_seconds": 0, "history": DEMO_LAB_HISTORY}

    age = history_cache_age_seconds()
    if not force and age is not None and age < LAB_HISTORY_TTL_SECONDS:
        return {"ok": True, "cached": True, "age_seconds": age, "history": load_json(LAB_HISTORY_CACHE, {})}

    snapshot = current_snapshot()
    symbols = lab_symbols(snapshot)
    prices = {}
    warnings = []
    started = time.time()
    for symbol in symbols:
        try:
            rows = fetch_history(symbol, years=years)
            if rows:
                prices[symbol] = rows
            else:
                warnings.append(f"Yahoo history empty: {symbol}")
        except Exception as exc:
            warnings.append(f"Yahoo history failed {symbol}: {type(exc).__name__} {str(exc)[:100]}")
        time.sleep(0.08)
    history = {
        "as_of_unix": int(time.time()),
        "duration_seconds": round(time.time() - started, 2),
        "years": years,
        "symbols": symbols,
        "prices": prices,
        "benchmarks": BENCHMARKS,
        "warnings": warnings,
        "source": "Yahoo Finance chart endpoint",
    }
    LAB_HISTORY_CACHE.parent.mkdir(parents=True, exist_ok=True)
    LAB_HISTORY_CACHE.write_text(json.dumps(history, ensure_ascii=False, indent=2), encoding="utf-8")
    return {"ok": True, "cached": False, "age_seconds": 0, "history": history}


def get_history():
    if demo_mode():
        from .demo_data import DEMO_LAB_HISTORY
        return DEMO_LAB_HISTORY

    data = load_json(LAB_HISTORY_CACHE, None)
    if data:
        return data
    return refresh_history(force=True)["history"]


def get_history_cached():
    """Cached lab history only — never triggers a network fetch (empty if no cache).

    Used by views that must stay fast on a cold cache (home alerts, heatmap),
    where a synchronous fetch of ~35 symbols would block the page for seconds.
    """
    return load_json(LAB_HISTORY_CACHE, None) or {"prices": {}}


def ensure_history_symbols(symbols, years=5, max_fetch=180):
    history = get_history()
    prices = history.setdefault("prices", {})
    warnings = history.setdefault("warnings", [])
    missing = [symbol for symbol in sorted(set(symbols)) if symbol and symbol not in prices]
    if not missing:
        return history
    started = time.time()
    fetched = 0
    for symbol in missing[:max_fetch]:
        try:
            rows = fetch_history(symbol, years=years)
            if rows:
                prices[symbol] = rows
                fetched += 1
            else:
                warnings.append(f"Yahoo history empty: {symbol}")
        except Exception as exc:
            warnings.append(f"Yahoo history failed {symbol}: {type(exc).__name__} {str(exc)[:100]}")
        time.sleep(0.04)
    history["as_of_unix"] = int(time.time())
    history["duration_seconds"] = round(float(history.get("duration_seconds") or 0) + time.time() - started, 2)
    history["symbols"] = sorted(set(history.get("symbols", [])) | set(prices))
    history["trade_history_backfill"] = {
        "requested": len(missing),
        "fetched": fetched,
        "capped": len(missing) > max_fetch,
        "max_fetch": max_fetch,
    }
    LAB_HISTORY_CACHE.write_text(json.dumps(history, ensure_ascii=False, indent=2), encoding="utf-8")
    return history


def returns_from_prices(price_rows):
    returns = {}
    previous = None
    for row in price_rows:
        close = row.get("close")
        if previous and close:
            returns[row["date"]] = float(close) / previous - 1
        if close:
            previous = float(close)
    return returns


def canonical_symbol(symbol):
    return ASSET_ALIASES.get(symbol, symbol)


def holding_values_by_symbol(snapshot, symbols):
    market_rows = market_by_ticker(snapshot)
    holdings = holdings_by_ticker(snapshot)
    wanted = set(symbols)
    values = {}
    for ticker, holding in holdings.items():
        symbol = holding.get("yahoo_symbol") or ticker
        if symbol not in wanted:
            continue
        value = _num(market_rows.get(ticker, {}).get("market_value_usd")) or _num(holding.get("api_market_value_usd")) or _num(holding.get("cost_usd_standard"))
        if value <= 0:
            continue
        values[symbol] = values.get(symbol, 0.0) + value
    return values


def grouped_universe(snapshot, history, max_symbols=35, exclude_benchmarks=False):
    raw_symbols = [symbol for symbol in lab_symbols(snapshot, max_symbols=max_symbols) if symbol in history.get("prices", {})]
    if exclude_benchmarks:
        raw_symbols = [symbol for symbol in raw_symbols if symbol not in BENCHMARKS]
    raw_values = holding_values_by_symbol(snapshot, raw_symbols)
    groups = {}
    for symbol in raw_symbols:
        value = raw_values.get(symbol, 0.0)
        if value <= 0:
            continue
        canonical = canonical_symbol(symbol)
        group = groups.setdefault(canonical, {"value": 0.0, "members": {}})
        group["value"] += value
        group["members"][symbol] = group["members"].get(symbol, 0.0) + value

    total = sum(group["value"] for group in groups.values())
    weights = {symbol: group["value"] / total for symbol, group in groups.items()} if total else {}
    returns_by_symbol = {}
    for symbol, group in groups.items():
        member_returns = {member: returns_from_prices(history.get("prices", {}).get(member, [])) for member in group["members"]}
        member_dates = [set(rows) for rows in member_returns.values() if rows]
        common_member_dates = sorted(set.intersection(*member_dates)) if member_dates else []
        member_total = sum(group["members"].values()) or 1.0
        returns_by_symbol[symbol] = {
            date: sum(member_returns[member][date] * (value / member_total) for member, value in group["members"].items() if date in member_returns[member])
            for date in common_member_dates
        }

    common_dates = None
    for rows in returns_by_symbol.values():
        dates = set(rows)
        common_dates = dates if common_dates is None else common_dates & dates
    dates = sorted(common_dates or [])
    matrix = {symbol: [returns_by_symbol[symbol][date] for date in dates] for symbol in weights}
    return {
        "symbols": list(weights),
        "weights": weights,
        "dates": dates,
        "matrix": matrix,
        "groups": {
            symbol: {
                "members": group["members"],
                "weight": weights.get(symbol, 0.0),
            }
            for symbol, group in groups.items()
        },
    }


def current_weights(snapshot, symbols):
    market_rows = market_by_ticker(snapshot)
    holdings = holdings_by_ticker(snapshot)
    symbol_weights = {}
    total = 0.0
    for ticker, holding in holdings.items():
        symbol = holding.get("yahoo_symbol") or ticker
        if symbol not in symbols:
            continue
        value = _num(market_rows.get(ticker, {}).get("market_value_usd")) or _num(holding.get("api_market_value_usd")) or _num(holding.get("cost_usd_standard"))
        if value <= 0:
            continue
        symbol_weights[symbol] = symbol_weights.get(symbol, 0.0) + value
        total += value
    if not total:
        return {}
    return {symbol: value / total for symbol, value in symbol_weights.items()}


def aligned_returns(history, symbols):
    returns_by_symbol = {symbol: returns_from_prices(history.get("prices", {}).get(symbol, [])) for symbol in symbols}
    common_dates = None
    for symbol, rows in returns_by_symbol.items():
        dates = set(rows)
        common_dates = dates if common_dates is None else common_dates & dates
    dates = sorted(common_dates or [])
    matrix = {symbol: [returns_by_symbol[symbol][date] for date in dates] for symbol in symbols}
    return dates, matrix


def portfolio_returns(matrix, weights):
    if not matrix or not weights:
        return []
    length = min(len(matrix[symbol]) for symbol in weights if symbol in matrix)
    rows = []
    for i in range(length):
        rows.append(sum(matrix[symbol][i] * weight for symbol, weight in weights.items() if symbol in matrix))
    return rows


def annualized_stats(returns, risk_free=0.0):
    if not returns:
        return {"annual_return": 0.0, "annual_volatility": 0.0, "sharpe": 0.0, "max_drawdown": 0.0}
    avg = mean(returns)
    vol = stdev(returns) if len(returns) > 1 else 0.0
    annual_return = (1 + avg) ** 252 - 1
    annual_vol = vol * math.sqrt(252)
    sharpe = (annual_return - risk_free) / annual_vol if annual_vol else 0.0
    nav = 1.0
    peak = 1.0
    max_dd = 0.0
    for ret in returns:
        nav *= 1 + ret
        peak = max(peak, nav)
        max_dd = min(max_dd, nav / peak - 1)
    return {
        "annual_return": annual_return,
        "annual_volatility": annual_vol,
        "sharpe": sharpe,
        "max_drawdown": max_dd,
    }


def nav_series(dates, returns):
    nav = 1.0
    rows = []
    for date, ret in zip(dates[-len(returns):], returns):
        nav *= 1 + ret
        rows.append({"date": date, "nav": nav, "return": ret})
    return rows


@cached(ttl=300)
def lab_history_summary():
    snapshot = current_snapshot()
    history = get_history()
    universe = grouped_universe(snapshot, history)
    weights = universe["weights"]
    dates = universe["dates"]
    matrix = universe["matrix"]
    returns = portfolio_returns(matrix, weights)
    stats = annualized_stats(returns)
    return {
        "history_as_of_unix": history.get("as_of_unix"),
        "source": history.get("source"),
        "symbols": list(weights),
        "weights": weights,
        "groups": universe["groups"],
        "stats": stats,
        "nav": nav_series(dates, returns),
        "warnings": history.get("warnings", []),
    }


@cached(ttl=300)
def efficient_frontier(samples=900):
    snapshot = current_snapshot()
    history = get_history()
    universe = grouped_universe(snapshot, history, max_symbols=16, exclude_benchmarks=True)
    symbols = universe["symbols"]
    if len(symbols) < 2:
        return {"symbols": symbols, "points": [], "optimized": {}, "warnings": ["Not enough symbols with history."]}
    matrix = universe["matrix"]
    points = []
    best_sharpe = None
    min_vol = None
    for _ in range(samples):
        raw = [random.random() ** 1.6 for _ in symbols]
        total = sum(raw) or 1
        weights = {symbol: raw[index] / total for index, symbol in enumerate(symbols)}
        returns = portfolio_returns(matrix, weights)
        stats = annualized_stats(returns)
        point = {
            "annual_return": stats["annual_return"],
            "annual_volatility": stats["annual_volatility"],
            "sharpe": stats["sharpe"],
            "max_drawdown": stats["max_drawdown"],
            "weights": weights,
        }
        points.append(point)
        if best_sharpe is None or point["sharpe"] > best_sharpe["sharpe"]:
            best_sharpe = point
        if min_vol is None or point["annual_volatility"] < min_vol["annual_volatility"]:
            min_vol = point
    current = lab_history_summary()["stats"]
    points.sort(key=lambda row: row["annual_volatility"])
    return {
        "symbols": symbols,
        "points": points,
        "optimized": {"max_sharpe": best_sharpe, "min_volatility": min_vol, "current": current},
        "note": "Long-only random frontier. Uses daily Yahoo adjusted close returns.",
    }


def _percentile(sorted_values, percentile):
    if not sorted_values:
        return 0.0
    idx = min(len(sorted_values) - 1, max(0, int((percentile / 100) * (len(sorted_values) - 1))))
    return sorted_values[idx]


@cached(ttl=300)
def monte_carlo(years=10, paths=300):
    summary = lab_history_summary()
    returns = [row["return"] for row in summary["nav"]]
    if not returns:
        return {"paths": [], "percentiles": [], "warnings": ["No returns available."]}
    mu = mean(returns)
    sigma = stdev(returns) if len(returns) > 1 else 0.0
    days = int(years * 252)
    rng = random.Random(42)
    sampled_paths = []
    finals = []
    month_values = {}
    for path_index in range(paths):
        nav = 1.0
        sparse = []
        for day in range(1, days + 1):
            nav *= 1 + rng.gauss(mu, sigma)
            if day % 21 == 0:
                month = day // 21
                sparse.append({"month": month, "nav": nav})
                month_values.setdefault(month, []).append(nav)
        finals.append(nav)
        if path_index < 20:
            sampled_paths.append({"path": path_index + 1, "points": sparse})
    finals.sort()
    percentile_paths = []
    for month in sorted(month_values):
        values = sorted(month_values[month])
        percentile_paths.append(
            {
                "month": month,
                "p5": _percentile(values, 5),
                "p25": _percentile(values, 25),
                "p50": _percentile(values, 50),
                "p75": _percentile(values, 75),
                "p95": _percentile(values, 95),
            }
        )
    return {
        "years": years,
        "paths_count": paths,
        "sampled_paths": sampled_paths,
        "percentile_paths": percentile_paths,
        "final_percentiles": {
            "p5": _percentile(finals, 5),
            "p25": _percentile(finals, 25),
            "p50": _percentile(finals, 50),
            "p75": _percentile(finals, 75),
            "p95": _percentile(finals, 95),
        },
        "assumptions": {"daily_mean": mu, "daily_volatility": sigma},
    }


@cached(ttl=300)
def backtest():
    history = get_history()
    summary = lab_history_summary()
    portfolio_nav = summary["nav"]
    portfolio_dates = [row["date"] for row in portfolio_nav]
    benchmark_rows = []
    for symbol, label in BENCHMARKS.items():
        if symbol not in history.get("prices", {}):
            continue
        returns_by_date = returns_from_prices(history.get("prices", {}).get(symbol, []))
        dates = [date for date in portfolio_dates if date in returns_by_date]
        returns = [returns_by_date[date] for date in dates]
        benchmark_rows.append({"symbol": symbol, "label": label, "stats": annualized_stats(returns), "nav": nav_series(dates, returns)})
    return {"portfolio": {"stats": summary["stats"], "nav": portfolio_nav}, "benchmarks": benchmark_rows}


@cached(ttl=300)
def factor_analysis():
    history = get_history()
    summary = lab_history_summary()
    portfolio_by_date = {row["date"]: row["return"] for row in summary["nav"]}
    rows = []
    for symbol, label in BENCHMARKS.items():
        if symbol not in history.get("prices", {}):
            continue
        factor_by_date = returns_from_prices(history.get("prices", {}).get(symbol, []))
        dates = sorted(set(portfolio_by_date) & set(factor_by_date))
        aligned_portfolio = [portfolio_by_date[date] for date in dates]
        factor_rets = [factor_by_date[date] for date in dates]
        if len(factor_rets) < 20:
            continue
        avg_p = mean(aligned_portfolio)
        avg_f = mean(factor_rets)
        cov = sum((p - avg_p) * (f - avg_f) for p, f in zip(aligned_portfolio, factor_rets)) / len(factor_rets)
        var_f = sum((f - avg_f) ** 2 for f in factor_rets) / len(factor_rets)
        var_p = sum((p - avg_p) ** 2 for p in aligned_portfolio) / len(aligned_portfolio)
        beta = cov / var_f if var_f else 0.0
        corr = cov / math.sqrt(var_f * var_p) if var_f and var_p else 0.0
        rows.append({"factor": symbol, "label": label, "beta": beta, "correlation": corr})
    rows.sort(key=lambda row: abs(row["correlation"]), reverse=True)
    return {"method": "single-factor regression against ETF proxies", "rows": rows}


@cached(ttl=300)
def monthly_return_heatmap(years=(2025, 2026)):
    summary = lab_history_summary()
    rows = []
    month_returns = {}
    for row in summary["nav"]:
        date = row["date"]
        year = int(date[:4])
        if year not in years:
            continue
        key = date[:7]
        month_returns.setdefault(key, 1.0)
        month_returns[key] *= 1 + row["return"]
    for key, value in sorted(month_returns.items()):
        rows.append({"month": key, "return": value - 1})
    return {
        "basis": "current-weight model portfolio, not cash-flow adjusted account return",
        "date_range": {
            "start": summary["nav"][0]["date"] if summary["nav"] else None,
            "end": summary["nav"][-1]["date"] if summary["nav"] else None,
        },
        "rows": rows,
    }


@cached(ttl=300)
def cumulative_vs_benchmark(symbol="SPY"):
    bt = backtest()
    portfolio = bt["portfolio"].get("nav", [])
    benchmark = next((row for row in bt.get("benchmarks", []) if row["symbol"] == symbol), None)
    benchmark_by_date = {row["date"]: row["nav"] for row in (benchmark or {}).get("nav", [])}
    raw_rows = []
    for row in portfolio:
        date = row["date"]
        bench_nav = benchmark_by_date.get(date)
        if bench_nav is None:
            continue
        raw_rows.append(
            {
                "date": date,
                "portfolio": row["nav"],
                "benchmark": bench_nav,
            }
        )
    if not raw_rows:
        return {"benchmark": symbol, "basis": "current-weight model portfolio", "rows": []}
    portfolio_base = raw_rows[0]["portfolio"] or 1.0
    benchmark_base = raw_rows[0]["benchmark"] or 1.0
    rows = []
    for row in raw_rows:
        portfolio_nav = row["portfolio"] / portfolio_base
        benchmark_nav = row["benchmark"] / benchmark_base
        rows.append(
            {
                "date": row["date"],
                "portfolio": portfolio_nav,
                "benchmark": benchmark_nav,
                "excess": portfolio_nav / benchmark_nav - 1 if benchmark_nav else 0.0,
            }
        )
    return {
        "benchmark": symbol,
        "basis": "current-weight model portfolio, rebased to first common date",
        "label": "TWR 策略收益",
        "note": "剔除现金流影响，用于衡量策略本身表现。",
        "date_range": {"start": rows[0]["date"], "end": rows[-1]["date"]},
        "rows": rows,
    }


@cached(ttl=300)
def cumulative_multi_benchmark():
    """Portfolio vs all BENCHMARKS rebased to the same start — for Vanguard-style comparison."""
    bt = backtest()
    portfolio_nav = bt["portfolio"].get("nav", [])
    if not portfolio_nav:
        return {"available": False, "message": "无可用组合历史数据", "rows": [], "benchmarks": []}

    portfolio_base = portfolio_nav[0]["nav"] or 1.0
    portfolio_by_date = {row["date"]: row["nav"] / portfolio_base for row in portfolio_nav}

    bench_data = []
    for bench in bt.get("benchmarks", []):
        symbol = bench["symbol"]
        label = bench["label"]
        nav_by_date = {row["date"]: row["nav"] for row in bench.get("nav", [])}
        common_dates = sorted(d for d in portfolio_by_date if d in nav_by_date)
        if not common_dates:
            continue
        base = nav_by_date[common_dates[0]] or 1.0
        rebased = {d: nav_by_date[d] / base for d in common_dates}
        bench_data.append({
            "symbol": symbol,
            "label": label,
            "series": rebased,
            "final_return": rebased[common_dates[-1]] - 1,
        })

    all_dates = sorted(portfolio_by_date)
    rows = []
    for date in all_dates:
        row = {"date": date, "portfolio": round(portfolio_by_date[date], 6)}
        for bench in bench_data:
            if date in bench["series"]:
                row[bench["symbol"]] = round(bench["series"][date], 6)
        rows.append(row)

    return {
        "available": bool(rows),
        "basis": "current-weight model portfolio, rebased to first common date",
        "label": "多指数对比",
        "note": "同一起跑线对比，基于当前持仓权重的模型收益（非实际交易路径）。",
        "date_range": {"start": all_dates[0], "end": all_dates[-1]} if all_dates else None,
        "portfolio_final_return": rows[-1]["portfolio"] - 1 if rows else None,
        "benchmarks": [{"symbol": b["symbol"], "label": b["label"], "final_return": b["final_return"]} for b in bench_data],
        "rows": rows,
    }


@cached(ttl=300)
def cash_flow_mirror_vs_benchmark(symbol="SPY"):
    if demo_mode():
        return {
            "benchmark": symbol,
            "available": False,
            "status": "demo_no_trade_history",
            "basis": "buy and sell trades mirrored into the benchmark",
            "label": "现金流镜像",
            "note": "Demo data includes holdings, prices, and model history, but not private transaction CSVs.",
            "message": "Demo mode does not include real trade history, so cash-flow mirror is disabled.",
            "date_range": None,
            "rows": [],
        }

    trades = _read_trade_transactions()
    if not trades:
        return {
            "benchmark": symbol,
            "available": False,
            "status": "missing_trade_history",
            "basis": "buy and sell trades mirrored into the benchmark",
            "label": "现金流镜像",
            "note": "复制你的买入和卖出节奏，用于比较真实交易路径。",
            "message": "缺少交易流水，暂时不能计算现金流镜像。",
            "date_range": None,
            "rows": [],
        }

    symbol_currency = {}
    trade_rows = []
    for row in trades:
        ticker = row.get("Ticker") or row.get("Symbol") or ""
        currency = row.get("Currency (Price / share)") or row.get("Currency (Total)") or "USD"
        symbol_code = _yahoo_symbol(ticker, currency)
        amount_usd = _trade_usd(row)
        shares = float(_dec(row.get("No. of shares") or row.get("Quantity")))
        if amount_usd <= 0 or shares <= 0:
            continue
        symbol_currency.setdefault(symbol_code, currency)
        trade_rows.append(
            {
                "date": row["date"],
                "action": row["Action"],
                "ticker": ticker,
                "symbol": symbol_code,
                "shares": shares,
                "amount_usd": amount_usd,
                "account": row["Account"],
            }
        )

    history = ensure_history_symbols(set(symbol_currency) | {symbol})
    benchmark_prices = {row["date"]: float(row["close"]) for row in history.get("prices", {}).get(symbol, []) if row.get("close")}
    if not benchmark_prices:
        return {
            "benchmark": symbol,
            "available": False,
            "status": "missing_benchmark_history",
            "basis": "buy and sell trades mirrored into the benchmark",
            "label": "现金流镜像",
            "note": "复制你的买入和卖出节奏，用于比较真实交易路径。",
            "message": "缺少 benchmark 历史价格，暂时不能计算现金流镜像。",
            "date_range": None,
            "rows": [],
        }

    available_symbols = {
        trade["symbol"]
        for trade in trade_rows
        if trade["symbol"] in history.get("prices", {})
    }
    missing_symbols = sorted({trade["symbol"] for trade in trade_rows} - available_symbols)
    price_by_symbol = {
        sym: {row["date"]: float(row["close"]) for row in history.get("prices", {}).get(sym, []) if row.get("close")}
        for sym in available_symbols
    }
    trade_rows = [trade for trade in trade_rows if trade["symbol"] in available_symbols]
    if not trade_rows:
        return {
            "benchmark": symbol,
            "available": False,
            "status": "no_trade_symbols_with_history",
            "basis": "buy and sell trades mirrored into the benchmark",
            "label": "现金流镜像",
            "note": "复制你的买入和卖出节奏，用于比较真实交易路径。",
            "message": "交易里的股票都没有可用历史行情，暂时不能计算现金流镜像。",
            "missing_symbols": missing_symbols,
            "date_range": None,
            "rows": [],
        }

    first_trade_date = min(trade["date"] for trade in trade_rows)
    dates = sorted(date for date in benchmark_prices if date >= first_trade_date)
    # Build nearest-benchmark-price lookup for each trade date
    sorted_bm_dates = sorted(benchmark_prices)
    trade_bm_price = {}
    for trade in trade_rows:
        td = trade["date"]
        bm_date = next((d for d in sorted_bm_dates if d >= td), None)
        trade_bm_price[td] = benchmark_prices.get(bm_date) if bm_date else None

    shares_by_symbol = defaultdict(float)
    benchmark_shares = 0.0
    net_cash_flow = 0.0
    buy_total = 0.0
    sell_total = 0.0
    cumulative_sell_total = 0.0
    trade_index = 0
    rows = []
    last_close_by_symbol = {}
    symbol_value_fx = {
        "USD": 1.0,
        "GBP": float(REPORT_FX_TO_USD["GBP"]),
        "GBX": float(REPORT_FX_TO_USD["GBX"]),
        "EUR": float(REPORT_FX_TO_USD["EUR"]),
    }

    for date in dates:
        benchmark_close = benchmark_prices.get(date)
        if benchmark_close is None:
            continue

        # Process trades up to this date, each at its own benchmark price
        while trade_index < len(trade_rows) and trade_rows[trade_index]["date"] <= date:
            trade = trade_rows[trade_index]
            bm_price = trade_bm_price.get(trade["date"])
            if bm_price is None:
                trade_index += 1
                continue
            signed_amount = trade["amount_usd"] if trade["action"] in BUY_ACTIONS else -trade["amount_usd"]
            net_cash_flow += signed_amount
            if signed_amount >= 0:
                buy_total += signed_amount
            else:
                sell_total += abs(signed_amount)
                cumulative_sell_total += abs(signed_amount)
            if trade["action"] in BUY_ACTIONS:
                shares_by_symbol[trade["symbol"]] += trade["shares"]
                benchmark_shares += trade["amount_usd"] / bm_price
            else:
                shares_by_symbol[trade["symbol"]] -= trade["shares"]
                benchmark_shares -= trade["amount_usd"] / bm_price
            trade_index += 1

        portfolio_value = 0.0
        priced_symbols = 0
        for sym, shares in shares_by_symbol.items():
            if abs(shares) < 1e-10:
                continue
            close = price_by_symbol.get(sym, {}).get(date)
            if close is None:
                close = last_close_by_symbol.get(sym)
            else:
                last_close_by_symbol[sym] = close
            if close is None:
                continue
            currency = symbol_currency.get(sym, "USD")
            portfolio_value += shares * close * symbol_value_fx.get(currency, 1.0)
            priced_symbols += 1
        benchmark_value = benchmark_shares * benchmark_close

        # Return = (holdings + withdrawn) / total_invested - 1
        if buy_total > 0:
            portfolio_return = (portfolio_value + cumulative_sell_total) / buy_total - 1
            benchmark_return = (benchmark_value + cumulative_sell_total) / buy_total - 1
            rows.append(
                {
                    "date": date,
                    "portfolio_value": portfolio_value,
                    "benchmark_value": benchmark_value,
                    "adjusted_portfolio_value": portfolio_value + cumulative_sell_total,
                    "adjusted_benchmark_value": benchmark_value + cumulative_sell_total,
                    "portfolio_return": portfolio_return,
                    "benchmark_return": benchmark_return,
                    "net_cash_flow": net_cash_flow,
                    "buy_total": buy_total,
                    "cumulative_sell_total": cumulative_sell_total,
                    "priced_symbols": priced_symbols,
                }
            )

    return {
        "benchmark": symbol,
        "available": bool(rows),
        "status": "available" if rows else "no_rows",
        "basis": "buy trades are treated as cash invested; sell trades are treated as cash withdrawn; the same cash flows are mirrored into the benchmark",
        "label": "现金流镜像",
        "note": "复制你的买入和卖出节奏，用于比较真实交易路径。",
        "message": "主图使用“当前持仓价值 + 累计卖出现金”，避免卖出动作在曲线上显示成闪跌；下方柱状图保留每日买入/卖出现金流。",
        "date_range": {"start": rows[0]["date"], "end": rows[-1]["date"]} if rows else None,
        "rows": rows,
        "stats": {
            "trade_count": len(trade_rows),
            "buy_total_usd": buy_total,
            "sell_total_usd": sell_total,
            "net_cash_flow_usd": net_cash_flow,
            "final_portfolio_value_usd": rows[-1]["portfolio_value"] if rows else 0.0,
            "final_benchmark_value_usd": rows[-1]["benchmark_value"] if rows else 0.0,
            "final_adjusted_portfolio_value_usd": rows[-1]["adjusted_portfolio_value"] if rows else 0.0,
            "final_adjusted_benchmark_value_usd": rows[-1]["adjusted_benchmark_value"] if rows else 0.0,
            "final_gap_usd": (rows[-1]["portfolio_value"] - rows[-1]["benchmark_value"]) if rows else 0.0,
            "covered_symbols": len(available_symbols),
            "missing_symbols": missing_symbols,
        },
       "warnings": [
           "这是按买卖流水重建的近似交易路径，不含未投资现金余额、真实日内成交时点和可能缺失的历史行情。",
       ] + ([f"缺少历史行情的交易标的：{', '.join(missing_symbols[:12])}" + ("..." if len(missing_symbols) > 12 else "")] if missing_symbols else []),
    }
    return {
        "benchmark": symbol,
        "available": bool(rows),
        "status": "available" if rows else "no_rows",
        "basis": "buy trades are treated as cash invested; sell trades are treated as cash withdrawn; the same cash flows are mirrored into the benchmark",
        "label": "现金流镜像",
        "note": "复制你的买入和卖出节奏，用于比较真实交易路径。",
                "message": "主图使用\"当前持仓价值 + 累计卖出现金\"，避免卖出动作在曲线上显示成闪跌；下方柱状图保留每日买入/卖出现金流。",
        "date_range": {"start": rows[0]["date"], "end": rows[-1]["date"]} if rows else None,
        "rows": rows,
        "stats": {
            "trade_count": len(trade_rows),
            "buy_total_usd": buy_total,
            "sell_total_usd": sell_total,
            "net_cash_flow_usd": net_cash_flow,
            "final_portfolio_value_usd": rows[-1]["portfolio_value"] if rows else 0.0,
            "final_benchmark_value_usd": rows[-1]["benchmark_value"] if rows else 0.0,
            "final_adjusted_portfolio_value_usd": rows[-1]["adjusted_portfolio_value"] if rows else 0.0,
            "final_adjusted_benchmark_value_usd": rows[-1]["adjusted_benchmark_value"] if rows else 0.0,
            "final_gap_usd": (rows[-1]["portfolio_value"] - rows[-1]["benchmark_value"]) if rows else 0.0,
            "covered_symbols": len(available_symbols),
            "missing_symbols": missing_symbols,
        },
        "warnings": [
            "这是按买卖流水重建的近似交易路径，不含未投资现金余额、真实日内成交时点和可能缺失的历史行情。",
        ] + ([f"缺少历史行情的交易标的：{', '.join(missing_symbols[:12])}" + ("..." if len(missing_symbols) > 12 else "")] if missing_symbols else []),
    }


@cached(ttl=300)
def drawdown_curve():
    summary = lab_history_summary()
    peak = 1.0
    rows = []
    max_drawdown = 0.0
    for row in summary["nav"]:
        nav = row["nav"]
        peak = max(peak, nav)
        drawdown = nav / peak - 1 if peak else 0.0
        max_drawdown = min(max_drawdown, drawdown)
        rows.append({"date": row["date"], "drawdown": drawdown})
    return {"max_drawdown": max_drawdown, "rows": rows}


@cached(ttl=300)
def return_distribution():
    summary = lab_history_summary()
    returns = [row["return"] for row in summary["nav"]]
    if not returns:
        return {"bins": [], "stats": {}}
    low = min(returns)
    high = max(returns)
    bucket_count = 20
    width = (high - low) / bucket_count if high > low else 0.01
    bins = []
    for index in range(bucket_count):
        start = low + index * width
        end = start + width
        count = sum(1 for value in returns if (start <= value < end) or (index == bucket_count - 1 and value <= end))
        bins.append({"start": start, "end": end, "mid": (start + end) / 2, "count": count})
    avg = mean(returns)
    downside = [value for value in returns if value < 0]
    return {
        "bins": bins,
        "stats": {
            "mean": avg,
            "worst": low,
            "best": high,
            "negative_days": len(downside),
            "sample_days": len(returns),
        },
    }


@cached(ttl=300)
def correlation_matrix(limit=14):
    snapshot = current_snapshot()
    history = get_history()
    universe = grouped_universe(snapshot, history, max_symbols=limit, exclude_benchmarks=True)
    symbols = universe["symbols"]
    matrix = universe["matrix"]
    rows = []
    for left in symbols:
        row = []
        left_values = matrix.get(left, [])
        for right in symbols:
            right_values = matrix.get(right, [])
            length = min(len(left_values), len(right_values))
            if length < 3:
                row.append(0.0)
                continue
            lvals = left_values[-length:]
            rvals = right_values[-length:]
            avg_l = mean(lvals)
            avg_r = mean(rvals)
            cov = sum((l - avg_l) * (r - avg_r) for l, r in zip(lvals, rvals)) / length
            var_l = sum((l - avg_l) ** 2 for l in lvals) / length
            var_r = sum((r - avg_r) ** 2 for r in rvals) / length
            row.append(cov / math.sqrt(var_l * var_r) if var_l and var_r else 0.0)
        rows.append(row)
    return {"symbols": symbols, "matrix": rows}


@cached(ttl=300)
def monthly_contribution_waterfall():
    snapshot = current_snapshot()
    history = get_history()
    universe = grouped_universe(snapshot, history, max_symbols=18, exclude_benchmarks=True)
    if not universe["dates"]:
        return {"month": None, "rows": []}
    month = universe["dates"][-1][:7]
    indexes = [idx for idx, date in enumerate(universe["dates"]) if date.startswith(month)]
    rows = []
    for symbol, returns in universe["matrix"].items():
        compounded = 1.0
        for idx in indexes:
            compounded *= 1 + returns[idx]
        contribution = universe["weights"].get(symbol, 0.0) * (compounded - 1)
        rows.append({"symbol": symbol, "contribution": contribution})
    rows.sort(key=lambda row: abs(row["contribution"]), reverse=True)
    return {"month": month, "basis": "current-weight model contribution", "rows": rows[:16]}


@cached(ttl=300)
def fifty_two_week_position():
    snapshot = current_snapshot()
    history = get_history()
    rows = []
    for holding in snapshot["portfolio"].get("holdings", []):
        symbol = holding.get("yahoo_symbol") or holding.get("ticker")
        prices = history.get("prices", {}).get(symbol, [])[-260:]
        if len(prices) < 20:
            continue
        closes = [row["close"] for row in prices if row.get("close") is not None]
        low = min(closes)
        high = max(closes)
        current = closes[-1]
        position = (current - low) / (high - low) if high > low else 0.5
        rows.append(
            {
                "ticker": holding.get("ticker"),
                "symbol": symbol,
                "name": holding.get("name") or holding.get("ticker"),
                "low": low,
                "high": high,
                "current": current,
                "position": position,
                "distance_from_low": current / low - 1 if low else None,
                "distance_from_high": current / high - 1 if high else None,
                "sample_days": len(closes),
                "start": prices[0].get("date"),
                "end": prices[-1].get("date"),
            }
        )
    rows.sort(key=lambda row: row["position"], reverse=True)
    return {"rows": rows}
