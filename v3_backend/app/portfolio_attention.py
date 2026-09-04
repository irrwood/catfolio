"""Deterministic portfolio attention signals and structured thesis helpers.

Market calculations live here rather than in the model prompt.  The LLM may
explain the resulting evidence, but it never calculates returns, volume
multiples, moving averages, portfolio weights, or contribution.
"""

from __future__ import annotations

from datetime import date, timedelta
from statistics import mean
from typing import Any
import time
import urllib.parse

from .analytics import holdings_detail, market_by_ticker
from .data_store import open_json


ATTENTION_RANK = {"high": 2, "medium": 1, "none": 0}


def _source_tier(publisher: str) -> str:
    normalized = publisher.lower()
    if any(name in normalized for name in ("reuters", "bloomberg", "associated press", "ap news")):
        return "wire"
    if any(name in normalized for name in ("business wire", "globenewswire", "pr newswire")):
        return "primary"
    return "media"


def fetch_recent_company_events(ticker: str, company_name: str = "", limit: int = 8) -> list[dict]:
    """Fetch a small, source-labelled headline bundle for a selected holding.

    This adapter deliberately returns evidence to the thesis stage; it does not
    make a judgment or alter the deterministic signal score. Network failures
    degrade to an empty evidence bundle.
    """
    query = urllib.parse.quote_plus(f"{ticker} {company_name}".strip())
    url = f"https://query1.finance.yahoo.com/v1/finance/search?q={query}&quotesCount=0&newsCount={max(1, min(limit, 12))}"
    try:
        payload = open_json(url)
    except Exception:
        return []
    now = int(time.time())
    rows = []
    for index, item in enumerate(payload.get("news") or []):
        title = str(item.get("title") or "").strip()
        link = str(item.get("link") or "").strip()
        publisher = str(item.get("publisher") or "Unknown").strip()
        published = int(item.get("providerPublishTime") or 0)
        if not title or not link:
            continue
        rows.append({
            "id": f"{ticker.lower()}-{index + 1}",
            "title": title,
            "publisher": publisher,
            "url": link,
            "published_at_unix": published or None,
            "age_days": round(max(0, now - published) / 86400, 1) if published else None,
            "tier": _source_tier(publisher),
        })
    return rows


def _number(value: Any) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    return result


def _valid_bars(rows: list[dict]) -> list[dict]:
    bars = []
    for row in rows or []:
        close = _number(row.get("close"))
        day = str(row.get("date") or "")[:10]
        if close is None or not day:
            continue
        try:
            date.fromisoformat(day)
        except ValueError:
            continue
        bars.append({**row, "date": day, "close": close})
    return sorted(bars, key=lambda row: row["date"])


def _calendar_return(bars: list[dict], days: int = 60) -> float | None:
    if len(bars) < 2:
        return None
    try:
        latest_day = date.fromisoformat(bars[-1]["date"])
    except ValueError:
        return None
    cutoff = latest_day - timedelta(days=days)
    candidates = [row for row in bars[:-1] if date.fromisoformat(row["date"]) <= cutoff]
    if not candidates:
        return None
    past = candidates[-1]["close"]
    return (bars[-1]["close"] / past - 1) * 100 if past else None


def _volume_multiple(bars: list[dict], current_volume: Any) -> tuple[float | None, float | None]:
    completed = [_number(row.get("volume")) for row in bars[-31:-1]]
    completed = [value for value in completed if value is not None and value > 0]
    if not completed:
        return None, None
    average = mean(completed[-30:])
    current = _number(current_volume)
    if current is None and bars:
        current = _number(bars[-1].get("volume"))
    return ((current / average) if current is not None and average else None), average


def _ma_200(bars: list[dict]) -> dict:
    closes = [row["close"] for row in bars]
    if len(closes) < 200:
        return {"value": None, "position_percent": None, "cross": None}
    current_ma = mean(closes[-200:])
    position = (closes[-1] / current_ma - 1) * 100 if current_ma else None
    cross = None
    if len(closes) >= 201:
        previous_ma = mean(closes[-201:-1])
        was_above = closes[-2] >= previous_ma
        is_above = closes[-1] >= current_ma
        if was_above != is_above:
            cross = "above" if is_above else "below"
    return {"value": current_ma, "position_percent": position, "cross": cross}


def _fundamental_row(snapshot: dict, ticker: str) -> dict:
    rows = snapshot.get("fundamentals", {}).get("rows", [])
    return next((row for row in rows if str(row.get("ticker") or "").upper() == ticker.upper()), {})


def scan_portfolio(snapshot: dict, history: dict) -> dict:
    """Scan every current holding and mechanically rank material changes."""
    detail = holdings_detail(snapshot).get("rows", [])
    holdings = {
        str(row.get("ticker") or "").upper(): row
        for row in snapshot.get("portfolio", {}).get("holdings", [])
    }
    market = market_by_ticker(snapshot)
    prices = history.get("prices", {}) if isinstance(history, dict) else {}

    raw_rows = []
    for position in detail:
        ticker = str(position.get("ticker") or "").upper()
        holding = holdings.get(ticker, {})
        market_row = market.get(ticker, {})
        symbol = holding.get("yahoo_symbol") or market_row.get("yahoo_symbol") or ticker
        bars = _valid_bars(prices.get(symbol, []))
        current_price = _number(market_row.get("quote_price"))
        if current_price is None and bars:
            current_price = bars[-1]["close"]

        return_60d = _calendar_return(bars)
        volume_multiple, avg_volume_30d = _volume_multiple(bars, market_row.get("volume"))
        high_52w = _number(market_row.get("high_52w"))
        low_52w = _number(market_row.get("low_52w"))
        if bars:
            trailing = bars[-260:]
            high_52w = high_52w or max(row["close"] for row in trailing)
            low_52w = low_52w or min(row["close"] for row in trailing)
        distance_high = ((high_52w - current_price) / high_52w * 100) if high_52w and current_price is not None else None
        distance_low = ((current_price - low_52w) / low_52w * 100) if low_52w and current_price is not None else None
        ma = _ma_200(bars)
        today = _number(position.get("today_change_percent"))
        weight = _number(position.get("weight")) or 0.0
        contribution = weight * today if today is not None else None

        raw_rows.append({
            "ticker": ticker,
            "symbol": symbol,
            "name": position.get("display_name") or position.get("name") or ticker,
            "weight": weight,
            "market_value_usd": _number(position.get("market_value_usd")) or 0.0,
            "current_price": current_price,
            "today_change_percent": today,
            "portfolio_contribution_percent": contribution,
            "return_60d_percent": return_60d,
            "volume_multiple": volume_multiple,
            "volume": _number(market_row.get("volume")),
            "avg_volume_30d": avg_volume_30d,
            "high_52w": high_52w,
            "low_52w": low_52w,
            "distance_from_52w_high_percent": distance_high,
            "distance_from_52w_low_percent": distance_low,
            "ma_200": ma["value"],
            "ma_200_position_percent": ma["position_percent"],
            "ma_200_cross": ma["cross"],
            "history_sessions": len(bars),
            "fundamentals": _fundamental_row(snapshot, ticker),
        })

    total_abs_contribution = sum(abs(row["portfolio_contribution_percent"] or 0) for row in raw_rows)
    for row in raw_rows:
        signals = []
        ret = row["return_60d_percent"]
        if ret is not None and abs(ret) >= 10:
            signals.append({"kind": "price_60d", "direction": "positive" if ret > 0 else "negative", "value": ret, "label": f"60D {ret:+.1f}%"})
        volume = row["volume_multiple"]
        if volume is not None and volume >= 2:
            signals.append({"kind": "volume_spike", "direction": "neutral", "value": volume, "label": f"Volume {volume:.1f}×"})
        high = row["distance_from_52w_high_percent"]
        low = row["distance_from_52w_low_percent"]
        if high is not None and -3 <= high <= 3:
            signals.append({"kind": "near_52w_high", "direction": "positive", "value": high, "label": f"{abs(high):.1f}% from 52W high"})
        elif low is not None and -3 <= low <= 3:
            signals.append({"kind": "near_52w_low", "direction": "negative", "value": low, "label": f"{abs(low):.1f}% from 52W low"})
        today = row["today_change_percent"]
        if today is not None and abs(today) >= 5:
            signals.append({"kind": "today_move", "direction": "positive" if today > 0 else "negative", "value": today, "label": f"Today {today:+.1f}%"})
        cross = row["ma_200_cross"]
        if cross:
            signals.append({"kind": "ma_200_cross", "direction": "positive" if cross == "above" else "negative", "value": row["ma_200_position_percent"], "label": f"Crossed {cross} 200D MA"})
        share = abs(row["portfolio_contribution_percent"] or 0) / total_abs_contribution if total_abs_contribution else 0
        row["daily_move_share"] = share
        if share >= 0.4 and abs(row["portfolio_contribution_percent"] or 0) >= 0.2:
            signals.append({"kind": "portfolio_contribution", "direction": "positive" if (row["portfolio_contribution_percent"] or 0) > 0 else "negative", "value": share, "label": f"{share * 100:.0f}% of today's portfolio move"})

        row["signals"] = signals
        row["attention"] = "high" if len(signals) >= 2 else ("medium" if signals else "none")
        row["score"] = len(signals)

    raw_rows.sort(
        key=lambda row: (
            ATTENTION_RANK[row["attention"]],
            row["score"],
            abs(row["portfolio_contribution_percent"] or 0),
            row["weight"],
        ),
        reverse=True,
    )
    selected = [row for row in raw_rows if row["attention"] != "none"]
    return {
        "holdings_count": len(raw_rows),
        "attention_count": len(selected),
        "no_material_change_count": len(raw_rows) - len(selected),
        "rows": raw_rows,
        "attention_rows": selected,
        "thresholds": {
            "return_60d_percent": 10,
            "volume_multiple": 2,
            "distance_from_52w_extreme_percent": 3,
            "today_move_percent": 5,
        },
        "data_coverage": {
            "history": sum(1 for row in raw_rows if row["history_sessions"] >= 40),
            "volume": sum(1 for row in raw_rows if row["volume_multiple"] is not None),
            "fundamentals": sum(1 for row in raw_rows if row["fundamentals"]),
        },
    }


def enforce_confidence(thesis: dict, source_index: dict[str, dict] | None = None) -> str:
    """Apply confidence policy in code, independent of the model's label."""
    source_index = source_index or {}
    cited = [source_index[source_id] for source_id in thesis.get("evidence_source_ids", []) if source_id in source_index]
    recent_reliable_source = any(
        source.get("tier") in {"primary", "wire"}
        and _number(source.get("age_days")) is not None
        and _number(source.get("age_days")) <= 90
        for source in cited
    )
    company_catalyst = bool(thesis.get("company_specific_catalyst"))
    confirmed = bool(thesis.get("catalyst_confirmed"))
    fresh = bool(thesis.get("catalyst_is_recent"))
    counter_checked = bool(thesis.get("counter_evidence"))
    severe_risk = bool(thesis.get("severe_unresolved_risk"))
    if company_catalyst and confirmed and fresh and recent_reliable_source and counter_checked and not severe_risk:
        return "high"
    if company_catalyst or confirmed or cited:
        return "medium"
    return "low"


def fallback_thesis(row: dict, lang: str = "zh") -> dict:
    """Safe explanation when research/model output is unavailable."""
    positive = sum(1 for signal in row.get("signals", []) if signal.get("direction") == "positive")
    negative = sum(1 for signal in row.get("signals", []) if signal.get("direction") == "negative")
    stance = "strengthening" if positive > negative else ("weakening" if negative > positive else "maintaining")
    if lang == "en":
        changed = ", ".join(signal["label"] for signal in row.get("signals", [])) or "No material market signal."
        why = "The move is worth checking, but no verified company-specific catalyst is attached to the current data."
        counter = ["The signal may reflect market or sector movement rather than a change in company fundamentals."]
        watch = ["Company filings and earnings", "Volume persistence", "200-day moving average"]
    else:
        changed = "、".join(signal["label"] for signal in row.get("signals", [])) or "暂无明显行情信号。"
        why = "这一变化值得核对，但当前数据中没有可验证的公司级催化剂。"
        counter = ["该信号可能只反映市场或板块波动，不代表公司基本面已改变。"]
        watch = ["公司公告与业绩", "成交量是否持续", "200 日均线"]
    return {
        "stance": stance,
        "confidence": "low",
        "what_changed": changed,
        "why_it_matters": why,
        "supporting_evidence": [signal["label"] for signal in row.get("signals", [])],
        "counter_evidence": counter,
        "risks": ["Unverified catalyst"],
        "watch_next": watch,
        "risk_flags": [],
        "company_specific_catalyst": False,
        "catalyst_confirmed": False,
        "catalyst_is_recent": False,
        "evidence_source_ids": [],
        "severe_unresolved_risk": False,
    }
