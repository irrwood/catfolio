from .cache import cached

# These analytics are pure functions of the snapshot. The snapshot is itself
# cached (~10s) and re-keyed by its loaded_at timestamp, so caching on that
# timestamp lets the parallel /api/* calls a single page fires — plus the home
# alert check and every AI call — reuse one computation instead of rebuilding
# the same result. clear_all() on any data refresh invalidates these too.
_snap_key = lambda snapshot, *a, **kw: snapshot.get("loaded_at", "")

SP500_ETF_TICKERS = {"VUAG", "VUSA"}

SECTOR_BY_TICKER = {
    "AAPL": "Technology",
    "AVGO": "Technology",
    "CHKP": "Technology",
    "GOOG": "Communication Services",
    "GOOGL": "Communication Services",
    "META": "Communication Services",
    "MRVL": "Technology",
    "MSFT": "Technology",
    "NVDA": "Technology",
    "ORCL": "Technology",
    "PANW": "Technology",
    "QCOM": "Technology",
    "SNOW": "Technology",
    "ZS": "Technology",
    "BARC": "Financials",
    "BATS": "Consumer Staples",
    "BRK.B": "Financials",
    "BRK-B": "Financials",
    "CEG": "Utilities",
    "CLS": "Technology",
    "EQGB": "ETF / Multi-Asset",
    "FTNT": "Technology",
    "GAW": "Consumer Discretionary",
    "GSK": "Healthcare",
    "LGEN": "Financials",
    "LLOY": "Financials",
    "MNG": "Financials",
    "NG": "Utilities",
    "NXT": "Consumer Discretionary",
    "OKTA": "Technology",
    "OSB": "Financials",
    "PHNX": "Financials",
    "PHP": "Real Estate",
    "RR": "Industrials",
    "RWE": "Utilities",
    "SGLN": "Commodities",
    "SIE": "Industrials",
    "SILG": "Commodities",
    "VUAG": "ETF / S&P 500",
    "VUSA": "ETF / S&P 500",
    "VHVG": "ETF / Global Equity",
    "VEUA": "ETF / Europe Equity",
    "XUSE": "ETF / S&P 500",
    "NOK": "Communication Equipment",
    "GEV": "Industrials",
    "AES": "Utilities",
    "ANAE": "ETF / Clean Energy",
    "ANRJ": "ETF / Clean Energy",
    "AV": "Financials",
    "CNA": "Utilities",
    "CNX1": "ETF / Nasdaq 100",
    "CUKX": "ETF / UK Equity",
    "ENL1": "Utilities",
    "ENR": "Industrials",
    "FPP": "Consumer Discretionary",
    "IBEE": "ETF / Clean Energy",
    "IITU": "ETF / Technology",
    "SOHO": "Real Estate",
    "SPGP": "Commodities",
    "SSLN": "Commodities",
    "VIEP": "ETF / Europe Equity",
}

CN_NAME_BY_TICKER = {
    "AES": "爱依斯",
    "ANAE": "新能源ETF",
    "ANRJ": "全球氢能ETF",
    "AV": "英杰华",
    "BARC": "巴克莱",
    "BATS": "英美烟草",
    "BRK.B": "伯克希尔哈撒韦B",
    "BRK-B": "伯克希尔哈撒韦B",
    "CEG": "星座能源",
    "CHKP": "Check Point 网络安全",
    "CLS": "天弘科技",
    "CNA": "森特理克",
    "CNX1": "纳斯达克100ETF",
    "CUKX": "富时100ETF",
    "ENL1": "德国综合能源",
    "ENR": "西门子能源",
    "EQGB": "纳斯达克100ETF",
    "FPP": "波兰服装零售",
    "FTNT": "飞塔",
    "GAW": "战锤母公司",
    "GEV": "GE Vernova 能源",
    "GOOG": "谷歌C",
    "GSK": "葛兰素史克",
    "IBEE": "清洁能源ETF",
    "IITU": "标普500科技ETF",
    "LGEN": "英杰华法通",
    "LLOY": "劳埃德银行",
    "META": "Meta 平台",
    "MNG": "M&G 资产管理",
    "MRVL": "美满电子",
    "MSFT": "微软",
    "NG": "英国国家电网",
    "NOK": "诺基亚",
    "NVDA": "英伟达",
    "NXT": "Next 零售",
    "OKTA": "Okta 身份云",
    "ORCL": "甲骨文",
    "OSB": "OSB 银行",
    "PANW": "Palo Alto 网络安全",
    "PHNX": "凤凰集团",
    "PHP": "Primary Health 医疗地产",
    "QCOM": "高通",
    "RR": "劳斯莱斯",
    "RWE": "莱茵集团",
    "SGLN": "实物黄金ETF",
    "SIE": "西门子",
    "SILG": "白银矿业ETF",
    "SNOW": "Snowflake 云数据",
    "SOHO": "社会住房REIT",
    "SPGP": "黄金矿商ETF",
    "SSLN": "实物白银ETF",
    "VEUA": "发达欧洲ETF",
    "VHVG": "发达市场ETF",
    "VIEP": "欧洲股息ETF",
    "VUAG": "标普500累积型",
    "VUSA": "标普500派息型",
    "XUSE": "全球除美国ETF",
    "ZS": "Zscaler 零信任安全",
}

SP500_WEIGHTS = [
    ("NVDA", "Nvidia", 7.87),
    ("AAPL", "Apple", 6.47),
    ("MSFT", "Microsoft", 4.92),
    ("AMZN", "Amazon", 4.20),
    ("GOOGL", "Alphabet Class A", 3.63),
    ("META", "Meta Platforms", 3.21),
    ("AVGO", "Broadcom", 2.90),
    ("GOOG", "Alphabet Class C", 2.17),
    ("BRK.B", "Berkshire Hathaway Class B", 1.74),
    ("TSLA", "Tesla", 1.41),
    ("JPM", "JPMorgan Chase", 1.25),
    ("WMT", "Walmart", 1.20),
    ("LLY", "Eli Lilly", 1.05),
    ("V", "Visa", 0.94),
    ("ORCL", "Oracle", 0.94),
    ("MA", "Mastercard", 0.94),
    ("NFLX", "Netflix", 0.90),
    ("XOM", "Exxon Mobil", 0.90),
    ("COST", "Costco", 0.73),
    ("JNJ", "Johnson & Johnson", 0.72),
    ("HD", "Home Depot", 0.67),
    ("ABBV", "AbbVie", 0.66),
    ("PLTR", "Palantir", 0.64),
    ("PG", "Procter & Gamble", 0.61),
    ("BAC", "Bank of America", 0.59),
]


def _num(value):
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def market_by_ticker(snapshot):
    return {row.get("ticker"): row for row in snapshot["market"].get("rows", []) if row.get("ticker")}


def holdings_by_ticker(snapshot):
    return {row.get("ticker"): row for row in snapshot["portfolio"].get("holdings", []) if row.get("ticker")}


def exposure_value_usd(ticker, snapshot, basis="market"):
    holdings = holdings_by_ticker(snapshot)
    market = market_by_ticker(snapshot)
    if basis == "market":
        row = market.get(ticker, {})
        if row.get("market_value_usd") is not None:
            return _num(row.get("market_value_usd"))
        holding = holdings.get(ticker, {})
        if holding.get("api_market_value_usd") is not None:
            return _num(holding.get("api_market_value_usd"))
    return _num(holdings.get(ticker, {}).get("cost_usd_standard"))


def portfolio_summary(snapshot):
    summary = dict(snapshot["portfolio"].get("summary", {}))
    market_total = sum(_num(row.get("market_value_usd")) for row in snapshot["market"].get("rows", []))
    cost_total = _num(summary.get("total_cost_usd_standard"))
    summary.update(
        {
            "market_value_usd": market_total,
            "unrealized_usd": market_total - cost_total,
            "trading212_positions": snapshot["trading212"].get("summary", {}).get("positions"),
            "cash": snapshot["trading212"].get("account_cash", {}),
        }
    )
    return summary


def etf_lookthrough(snapshot, basis="cost"):
    holdings = holdings_by_ticker(snapshot)
    etf_total = sum(exposure_value_usd(ticker, snapshot, basis=basis) for ticker in SP500_ETF_TICKERS)
    direct = {
        ticker: exposure_value_usd(ticker, snapshot, basis=basis)
        for ticker in holdings
        if ticker not in SP500_ETF_TICKERS
    }
    rows = []
    used_weight = 0.0
    for ticker, name, weight in SP500_WEIGHTS:
        used_weight += weight
        from_etf = etf_total * weight / 100
        direct_value = direct.get(ticker, 0.0)
        holding = holdings.get(ticker, {})
        rows.append(
            {
                "ticker": ticker,
                "name": holding.get("name") or name,
                "direct_usd": direct_value,
                "from_etf_usd": from_etf,
                "total_usd": direct_value + from_etf,
                "etf_weight_percent": weight,
            }
        )
    other_weight = max(0.0, 100 - used_weight)
    rows.append(
        {
            "ticker": "其他 S&P 500",
            "name": "其他 S&P 500 成分股",
            "direct_usd": 0.0,
            "from_etf_usd": etf_total * other_weight / 100,
            "total_usd": etf_total * other_weight / 100,
            "etf_weight_percent": other_weight,
        }
    )
    for ticker, value in direct.items():
        if ticker in {row["ticker"] for row in rows}:
            continue
        holding = holdings.get(ticker, {})
        rows.append(
            {
                "ticker": ticker,
                "name": holding.get("name") or ticker,
                "direct_usd": value,
                "from_etf_usd": 0.0,
                "total_usd": value,
                "etf_weight_percent": 0.0,
            }
        )
    rows.sort(key=lambda row: row["total_usd"], reverse=True)
    return {
        "basis": basis,
        "etf_tickers": sorted(SP500_ETF_TICKERS),
        "etf_total_usd": etf_total,
        "covered_weight_percent": used_weight,
        "other_weight_percent": other_weight,
        "rows": rows,
    }


def chart_exposure(snapshot):
    holdings = holdings_by_ticker(snapshot)
    market_lookthrough = etf_lookthrough(snapshot, basis="market")
    direct_children = [
        {
            "name": ticker,
            "value": exposure_value_usd(ticker, snapshot, basis="market"),
            "currency": holding.get("cost_currency"),
        }
        for ticker, holding in holdings.items()
        if ticker not in SP500_ETF_TICKERS
    ]
    direct_children.sort(key=lambda row: row["value"], reverse=True)
    etf_children = [
        {"name": row["ticker"], "value": row["from_etf_usd"]}
        for row in market_lookthrough["rows"]
        if row["from_etf_usd"] > 0
    ]
    return {
        "basis": "market",
        "title": "直接持仓 + S&P 500 ETF 穿透",
        "tree": [
            {"name": "直接持仓", "children": direct_children[:40]},
            {"name": "S&P 500 ETF 穿透", "children": etf_children[:40]},
        ],
        "lookthrough": market_lookthrough,
    }


def chart_pnl(snapshot):
    rows = []
    market = market_by_ticker(snapshot)
    holdings = holdings_by_ticker(snapshot)
    for ticker, holding in holdings.items():
        market_row = market.get(ticker, {})
        rows.append(
            {
                "ticker": ticker,
                "name": holding.get("name") or ticker,
                "cost_usd": _num(holding.get("cost_usd_standard")),
                "market_value_usd": _num(market_row.get("market_value_usd")),
                "unrealized_usd": _num(market_row.get("unrealized_usd")),
                "unrealized_percent": market_row.get("unrealized_percent"),
            }
        )
    rows.sort(key=lambda row: abs(row["unrealized_usd"]), reverse=True)
    return {"basis": "api_average_cost_vs_current_price", "rows": rows}


def _base_ticker(ticker):
    return (ticker or "").replace(".L", "").replace("_EQ", "")


def display_name(ticker, name):
    cn_name = CN_NAME_BY_TICKER.get(_base_ticker(ticker))
    if cn_name and name:
        return f"{cn_name} / {name}"
    if cn_name:
        return cn_name
    return name or ticker


@cached(ttl=30, key=_snap_key)
def sector_concentration(snapshot):
    market = market_by_ticker(snapshot)
    total = sum(_num(row.get("market_value_usd")) for row in market.values())
    sectors = {}
    for ticker, row in market.items():
        sector = SECTOR_BY_TICKER.get(_base_ticker(ticker), "Other / Unclassified")
        sectors[sector] = sectors.get(sector, 0.0) + _num(row.get("market_value_usd"))
    rows = [
        {"sector": sector, "market_value_usd": value, "weight": value / total if total else 0.0}
        for sector, value in sectors.items()
    ]
    rows.sort(key=lambda row: row["market_value_usd"], reverse=True)
    return {"rows": rows, "coverage_note": "Sector map is local and approximate for MVP."}


@cached(ttl=30, key=_snap_key)
def holdings_detail(snapshot):
    holdings = holdings_by_ticker(snapshot)
    market = market_by_ticker(snapshot)
    total = sum(_num(row.get("market_value_usd")) for row in market.values())
    rows = []
    for ticker, holding in holdings.items():
        market_row = market.get(ticker, {})
        market_value = _num(market_row.get("market_value_usd")) or _num(holding.get("api_market_value_usd"))
        cost = _num(holding.get("cost_usd_standard"))
        rows.append(
            {
                "ticker": ticker,
                "name": holding.get("name") or ticker,
                "display_name": display_name(ticker, holding.get("name") or ticker),
                "sector": SECTOR_BY_TICKER.get(_base_ticker(ticker), "Other / Unclassified"),
                "shares": _num(holding.get("shares")),
                "cost_usd": cost,
                "avg_cost_usd": _num(holding.get("avg_cost_usd_standard")),
                "quote_price": market_row.get("quote_price"),
                "quote_currency": market_row.get("quote_currency") or holding.get("price_currency"),
                "today_change_percent": market_row.get("change_percent"),
                "market_value_usd": market_value,
                "weight": market_value / total if total else 0.0,
                "unrealized_usd": market_value - cost,
                "unrealized_percent": (market_value / cost - 1) * 100 if cost else None,
            }
        )
    rows.sort(key=lambda row: row["market_value_usd"], reverse=True)
    return {"rows": rows}


@cached(ttl=30, key=_snap_key)
def pnl_contribution(snapshot):
    rows = chart_pnl(snapshot)["rows"]
    total_abs = sum(abs(_num(row.get("unrealized_usd"))) for row in rows)
    for row in rows:
        row["contribution_weight"] = abs(_num(row.get("unrealized_usd"))) / total_abs if total_abs else 0.0
    return {"rows": rows[:30]}


def _calc_return(prices, offset):
    if not prices or len(prices) <= offset:
        return None
    latest = float(prices[-1]["close"])
    past = float(prices[-(offset + 1)]["close"])
    return (latest / past - 1) * 100 if past else None


def _calc_ytd_return(prices):
    if not prices:
        return None
    latest_date = prices[-1]["date"]
    latest_year = int(latest_date[:4])
    past_row = None
    for row in reversed(prices):
        row_year = int(row["date"][:4])
        if row_year < latest_year:
            past_row = row
            break
    if not past_row:
        past_row = prices[0]
    latest = float(prices[-1]["close"])
    past = float(past_row["close"])
    return (latest / past - 1) * 100 if past else None


@cached(ttl=30, key=_snap_key)
def holdings_heatmap(snapshot):
    detail = holdings_detail(snapshot)["rows"]
    holdings = holdings_by_ticker(snapshot)
    fundamentals = snapshot.get("fundamentals", {})
    valuation = {row.get("ticker"): row for row in fundamentals.get("rows", [])}
    valuation_as_of_unix = fundamentals.get("as_of_unix")

    try:
        from .lab import get_history_cached
        history = get_history_cached()  # never fetch from this shared view (keeps home/heatmap fast)
    except Exception:
        history = {"prices": {}}
    prices_map = history.get("prices", {})

    rows = []
    for row in detail:
        holding = holdings.get(row["ticker"], {})
        yahoo_symbol = holding.get("yahoo_symbol") or row["ticker"]
        prices = prices_map.get(yahoo_symbol, [])
        rows.append(
            {
                "ticker": row["ticker"],
                "name": row["name"],
                "display_name": row.get("display_name") or display_name(row["ticker"], row["name"]),
                "sector": row.get("sector"),
                "weight": row["weight"],
                "shares": row.get("shares"),
                "cost_usd": row.get("cost_usd"),
                "avg_cost_usd": row.get("avg_cost_usd"),
                "quote_price": row.get("quote_price"),
                "quote_currency": row.get("quote_currency"),
                "market_value_usd": row["market_value_usd"],
                "today_change_percent": row["today_change_percent"],
                "unrealized_usd": row.get("unrealized_usd"),
                "unrealized_percent": row.get("unrealized_percent"),
                "trailing_pe": valuation.get(row["ticker"], {}).get("trailing_pe") or row.get("trailing_pe"),
                "forward_pe": valuation.get(row["ticker"], {}).get("forward_pe") or row.get("forward_pe"),
                "price_to_sales": valuation.get(row["ticker"], {}).get("price_to_sales"),
                "price_to_book": valuation.get(row["ticker"], {}).get("price_to_book"),
                "eps_growth_yoy": valuation.get(row["ticker"], {}).get("eps_growth_yoy"),
                "revenue_growth_yoy": valuation.get(row["ticker"], {}).get("revenue_growth_yoy"),
                "volume": row.get("volume"),
                "avg_volume_3m": row.get("avg_volume_3m"),
                "market_cap": row.get("market_cap"),
                "high_52w": row.get("high_52w"),
                "low_52w": row.get("low_52w"),
                "valuation_as_of_unix": valuation_as_of_unix,
                "return_1w": _calc_return(prices, 5),
                "return_1m": _calc_return(prices, 21),
                "return_3m": _calc_return(prices, 63),
                "return_6m": _calc_return(prices, 126),
                "return_ytd": _calc_ytd_return(prices),
                "return_1y": _calc_return(prices, 252),
            }
        )
    return {"rows": rows}


def unified_exposure(snapshot, basis="market"):
    """Unified exposure: merge duplicate ETFs + compute per-ticker total.

    Layer 1: merge VUAG+VUSA etc -> single fund entry
    Layer 2: compute market_value or cost for each entry
    """
    from .analytics import _num, holdings_by_ticker, market_by_ticker

    ASSET_ALIASES = {
        "VUAG": "S&P 500 Fund (VUAG/VUSA)",
        "VUSA": "S&P 500 Fund (VUAG/VUSA)",
    }

    holdings = holdings_by_ticker(snapshot)
    market = market_by_ticker(snapshot)

    merged = {}
    for ticker, holding in holdings.items():
        alias = ASSET_ALIASES.get(ticker)
        key = alias if alias else ticker
        existing = merged.get(key)
        if existing:
            mkt_row = market.get(ticker, {})
            existing["cost_usd"] += _num(holding.get("cost_usd_standard"))
            existing["market_value_usd"] += _num(mkt_row.get("market_value_usd")) or _num(holding.get("cost_usd_standard"))
            existing["components"].append(ticker)
        else:
            mkt_row = market.get(ticker, {})
            merged[key] = {
                "ticker": key,
                "name": holding.get("name") or key if not alias else alias,
                "cost_usd": _num(holding.get("cost_usd_standard")),
                "market_value_usd": _num(mkt_row.get("market_value_usd")) or _num(holding.get("cost_usd_standard")),
                "is_direct": True,
                "is_merged": bool(alias),
                "components": [ticker],
            }

    rows = sorted(merged.values(), key=lambda r: r["market_value_usd"], reverse=True)
    total = sum(r["market_value_usd"] for r in rows)
    for r in rows:
        r["weight"] = r["market_value_usd"] / total if total else 0.0

    return {"rows": rows, "total_market_value_usd": total, "basis": basis}
