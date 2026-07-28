"""Page route: api."""
import json
import re
import ssl
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import certifi
from fastapi import APIRouter, Body, HTTPException, Query
from fastapi.responses import FileResponse, HTMLResponse

from app.cache import clear_all, cached
from app.data_store import current_snapshot, refresh_after_hours, refresh_fundamentals, refresh_market_quotes, refresh_trading212
from app.analytics import chart_exposure, chart_pnl, etf_lookthrough, holdings_detail, holdings_heatmap, pnl_contribution, portfolio_summary, sector_concentration
from app.lab import BENCHMARKS, BENCHMARK_CN, backtest, correlation_matrix, cumulative_multi_benchmark, cumulative_vs_benchmark, drawdown_curve, efficient_frontier, factor_analysis, fifty_two_week_position, income_summary, lab_history_summary, monte_carlo, monthly_contribution_waterfall, monthly_return_heatmap, refresh_history, return_distribution, cash_flow_mirror_vs_benchmark
from app.settings import DATA_DIR

from app.returns_twr import compute_twr_returns
from app.ai import ai_analysis, ask, overlap_analysis, performance_explanation, portfolio_briefing, returns_explanation, risk_diagnosis, what_if

router = APIRouter(prefix="/api", tags=["api"])

_ASSET_LOGO_DIR = DATA_DIR / "asset_logos"
_ASSET_LOGO_SYMBOL = re.compile(r"^[A-Z0-9][A-Z0-9._-]{0,31}$")
_ASSET_LOGO_MAX_BYTES = 1024 * 1024


def _normalize_asset_logo_symbol(symbol: str) -> str:
    normalized = str(symbol or "").strip().upper()
    if not _ASSET_LOGO_SYMBOL.fullmatch(normalized):
        raise HTTPException(status_code=404, detail="Asset logo not found")
    return normalized


def _asset_logo_file_response(path):
    return FileResponse(
        path,
        media_type="image/png",
        headers={"Cache-Control": "public, max-age=604800, immutable"},
    )


def _req_lang(req: dict | None) -> str:
    return "en" if str((req or {}).get("lang", "")).lower().startswith("en") else "zh"


@router.get("/portfolio/summary")
def api_summary():
    return portfolio_summary(current_snapshot())


@router.get("/holdings")
def api_holdings():
    snapshot = current_snapshot()
    return {
        "summary": portfolio_summary(snapshot),
        "rows": snapshot["portfolio"].get("holdings", []),
    }


@router.get("/holdings/detail")
def api_holdings_detail():
    """Detailed positions without loading historical portfolio analytics."""
    snapshot = current_snapshot()
    return {
        "summary": portfolio_summary(snapshot),
        "rows": holdings_detail(snapshot).get("rows", []),
    }


@router.get("/holdings/heatmap")
@cached(ttl=60 * 60 * 12)
def api_holdings_heatmap():
    """Focused heatmap payload; avoids constructing the analytics command center."""
    return holdings_heatmap(current_snapshot())


@router.get("/asset-logo/{symbol}")
def api_asset_logo(symbol: str):
    """Fetch a public asset logo once, then serve it from the local cache."""
    normalized = _normalize_asset_logo_symbol(symbol)
    _ASSET_LOGO_DIR.mkdir(parents=True, exist_ok=True)
    cache_path = _ASSET_LOGO_DIR / f"{normalized}.png"
    if cache_path.is_file() and cache_path.stat().st_size:
        return _asset_logo_file_response(cache_path)

    encoded = urllib.parse.quote(normalized, safe=".-_")
    request = urllib.request.Request(
        f"https://financialmodelingprep.com/image-stock/{encoded}.png",
        headers={"User-Agent": "Catfolio/1.0 asset-logo-cache"},
    )
    try:
        tls_context = ssl.create_default_context(cafile=certifi.where())
        with urllib.request.urlopen(request, timeout=8, context=tls_context) as response:
            content_type = str(response.headers.get("Content-Type") or "").lower()
            payload = response.read(_ASSET_LOGO_MAX_BYTES + 1)
    except Exception as exc:
        raise HTTPException(status_code=404, detail="Asset logo not found") from exc

    if not content_type.startswith("image/") or not payload or len(payload) > _ASSET_LOGO_MAX_BYTES:
        raise HTTPException(status_code=404, detail="Asset logo not found")
    cache_path.write_bytes(payload)
    return _asset_logo_file_response(cache_path)


@router.get("/portfolio/overview")
def api_portfolio_overview():
    """Small payload for the Portfolio landing view."""
    snapshot = current_snapshot()
    detail = holdings_detail(snapshot).get("rows", [])
    summary = portfolio_summary(snapshot)
    today_pnl = 0.0
    for row in detail:
        change = row.get("today_change_percent")
        value = row.get("market_value_usd")
        if change is None or value is None:
            continue
        rate = float(change) / 100
        if rate != -1:
            today_pnl += float(value) - float(value) / (1 + rate)
    return {
        "summary": summary,
        "today_pnl_usd": today_pnl,
        "breadth": {
            "up": sum(1 for row in detail if float(row.get("today_change_percent") or 0) > 0),
            "down": sum(1 for row in detail if float(row.get("today_change_percent") or 0) < 0),
            "flat": sum(1 for row in detail if float(row.get("today_change_percent") or 0) == 0),
        },
        "top_holdings": detail[:10],
        "sectors": sector_concentration(snapshot).get("rows", []),
    }


@router.get("/portfolio/chart")
def api_portfolio_chart():
    """Cash-flow history plus the latest broker snapshot used by the value chart."""
    result = cash_flow_mirror_vs_benchmark("SPY")
    summary = portfolio_summary(current_snapshot())
    as_of = str(summary.get("as_of") or "")
    date_match = re.match(r"^\d{4}-\d{2}-\d{2}", as_of)
    current_date = date_match.group(0) if date_match else datetime.now(timezone.utc).date().isoformat()
    return {
        "cash_flow_mirror": {
            "available": result.get("available", False),
            "rows": [
                {
                    "date": row.get("date"),
                    "adjusted_portfolio_value": row.get("adjusted_portfolio_value"),
                    "net_cash_flow": row.get("net_cash_flow"),
                }
                for row in result.get("rows", [])
            ],
        },
        "current_point": {
            "date": current_date,
            "as_of": as_of or None,
            "market_value_usd": summary.get("market_value_usd"),
            "cost_usd": summary.get("total_cost_usd_standard"),
        },
    }


@router.get("/market")
def api_market():
    return current_snapshot()["market"]


@router.get("/fundamentals")
def api_fundamentals():
    return current_snapshot()["fundamentals"]


@router.get("/market/live")
def api_market_live(force: bool = False):
    result = refresh_market_quotes(force=force)
    return {
        "refresh": {key: value for key, value in result.items() if key != "market"},
        "market": result["market"],
        "summary": portfolio_summary(current_snapshot()),
    }


@router.get("/trading212")
def api_trading212():
    return current_snapshot()["trading212"]


@router.get("/etf-lookthrough")
def api_etf_lookthrough(basis: str = "cost"):
    if basis not in {"cost", "market"}:
        raise HTTPException(status_code=400, detail="basis must be cost or market")
    return etf_lookthrough(current_snapshot(), basis=basis)


@router.get("/chart/exposure")
def api_chart_exposure():
    return chart_exposure(current_snapshot())


@router.get("/chart/pnl")
def api_chart_pnl():
    return chart_pnl(current_snapshot())


@router.get("/command-center")
# Refresh endpoints already invalidate all derived data explicitly. Keeping
# this expensive aggregate warm makes normal page navigation instantaneous.
@cached(ttl=60 * 60 * 12)
def api_command_center():
    snapshot = current_snapshot()
    history = lab_history_summary()
    summary = portfolio_summary(snapshot)
    market_value_usd = float(summary.get("market_value_usd") or 0)
    holdings_count = len(snapshot["portfolio"].get("holdings", []))
    fundamentals_rows = snapshot["fundamentals"].get("rows", [])
    fundamentals_count = len(fundamentals_rows)
    fundamentals_provider = snapshot["fundamentals"].get("provider") or snapshot["fundamentals"].get("source") or "FMP"
    twr_returns = cumulative_vs_benchmark()
    cash_flow_mirror = cash_flow_mirror_vs_benchmark()
    return {
        "data_quality": {
            "reliable": ["sector_concentration", "pnl_contribution", "holdings_detail", "holdings_heatmap"],
            "model_based": ["monthly_returns", "cumulative_vs_benchmark", "cumulative_return_modes", "waterfall", "return_distribution", "correlation_matrix", "drawdown", "fifty_two_week"],
            "unavailable": [] if fundamentals_count else ["valuation"],
            "model_note": "Historical charts use a current-weight model portfolio. They are not cash-flow adjusted account returns.",
            "history_start": history["nav"][0]["date"] if history.get("nav") else None,
            "history_end": history["nav"][-1]["date"] if history.get("nav") else None,
            "history_days": len(history.get("nav", [])),
            "sources": {
                "trading212": {
                    "as_of_unix": snapshot["trading212"].get("as_of_unix"),
                    "positions": len(snapshot["trading212"].get("positions", [])),
                },
                "market": {
                    "as_of_unix": snapshot["market"].get("as_of_unix"),
                    "rows": len(snapshot["market"].get("rows", [])),
                },
                "fundamentals": {
                    "as_of_unix": snapshot["fundamentals"].get("as_of_unix"),
                    "rows": fundamentals_count,
                    "total": holdings_count,
                    "coverage": f"{fundamentals_count}/{holdings_count}",
                    "provider": fundamentals_provider,
                    "warnings": len(snapshot["fundamentals"].get("warnings", [])),
                },
                "history": {
                    "as_of_unix": history.get("history_as_of_unix"),
                    "days": len(history.get("nav", [])),
                },
            },
        },
        "sector_concentration": sector_concentration(snapshot),
        "pnl_contribution": pnl_contribution(snapshot),
        "holdings_detail": holdings_detail(snapshot),
        "holdings_heatmap": holdings_heatmap(snapshot),
        "monthly_returns": monthly_return_heatmap(),
        "profit_calendar": _profit_calendar_payload(snapshot, history, market_value_usd),
        "cumulative_vs_benchmark": twr_returns,
        "cumulative_return_modes": {
            "default": "twr",
            "twr": twr_returns,
            "cash_flow_mirror": cash_flow_mirror,
        },
        "waterfall": monthly_contribution_waterfall(),
        "return_distribution": return_distribution(),
        "correlation_matrix": correlation_matrix(),
        "drawdown": drawdown_curve(),
        "fifty_two_week": fifty_two_week_position(),
        "fundamentals": {
            "status": "available_partial" if fundamentals_count else "unavailable",
            "provider": fundamentals_provider,
            "coverage": f"{fundamentals_count}/{holdings_count}",
            "note": f"估值数据来自 {fundamentals_provider}，当前覆盖 {fundamentals_count}/{holdings_count} 持仓；ETF 和部分非美股可能没有 fundamentals。",
        },
    }


def _profit_calendar_payload(snapshot=None, history=None, market_value_usd=None):
    snapshot = snapshot or current_snapshot()
    history = history or lab_history_summary()
    if market_value_usd is None:
        market_value_usd = float(portfolio_summary(snapshot).get("market_value_usd") or 0)
    return {
        "basis": "current-weight model daily return multiplied by current portfolio market value",
        "currency": "USD",
        "market_value_usd": market_value_usd,
        "rows": [
            {
                "date": row["date"],
                "return": row["return"],
                "pnl_usd": market_value_usd * float(row.get("return") or 0),
            }
            for row in history.get("nav", [])
        ],
        "income": income_summary(),
    }


@router.get("/profit-calendar")
@cached(ttl=60 * 60 * 12)
def api_profit_calendar():
    """Focused calendar payload for Portfolio; substantially cheaper than command-center."""
    return {"profit_calendar": _profit_calendar_payload()}


@router.get("/analytics")
@cached(ttl=60 * 60 * 12)
def api_analytics():
    """Charts used by Analytics, without unrelated holdings and benchmark data."""
    return {
        "monthly_returns": monthly_return_heatmap(),
        "drawdown": drawdown_curve(),
        "correlation_matrix": correlation_matrix(),
        "return_distribution": return_distribution(),
        "waterfall": monthly_contribution_waterfall(),
    }


def _comparison_result(symbol: str):
    return symbol, cash_flow_mirror_vs_benchmark(symbol)


@router.get("/comparison")
@cached(ttl=60 * 60 * 12)
def api_comparison():
    """Compact, chart-ready comparison data with one shared date axis.

    Calculations are unchanged. Independent benchmark cache misses are warmed in
    parallel, and repeated portfolio/date fields are removed from the response.
    """
    symbols = list(BENCHMARKS)
    with ThreadPoolExecutor(max_workers=min(4, len(symbols))) as executor:
        results = dict(executor.map(_comparison_result, symbols))

    spy = results.get("SPY") or cash_flow_mirror_vs_benchmark("SPY")
    spy_rows = spy.get("rows") or []
    dates = [row.get("date") for row in spy_rows if row.get("date")]
    portfolio_by_date = {
        row.get("date"): row.get("adjusted_portfolio_value")
        for row in spy_rows
        if row.get("date")
    }
    benchmark_series = {}
    benchmark_returns = {}
    for symbol, result in results.items():
        rows = result.get("rows") or []
        values = {row.get("date"): row.get("adjusted_benchmark_value") for row in rows if row.get("date")}
        benchmark_series[symbol] = [values.get(date) for date in dates]
        benchmark_returns[symbol] = rows[-1].get("benchmark_return") if rows else None

    return {
        "available": bool(dates),
        "dates": dates,
        "portfolio": [portfolio_by_date.get(date) for date in dates],
        "benchmarks": benchmark_series,
        "summary": {
            "portfolio_return": spy_rows[-1].get("portfolio_return") if spy_rows else None,
            "benchmark_return": benchmark_returns.get("SPY"),
            "benchmark_returns": benchmark_returns,
        },
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }


@router.get("/returns")
@cached(ttl=90)
def api_returns():
    twr_returns = cumulative_vs_benchmark()
    cash_flow_benchmarks = {symbol: cash_flow_mirror_vs_benchmark(symbol) for symbol in BENCHMARKS}
    cash_flow_mirror = cash_flow_benchmarks.get("SPY") or cash_flow_mirror_vs_benchmark()
    multi_benchmark = cumulative_multi_benchmark()
    return {
        "default": "cash_flow_mirror",
        "twr": twr_returns,
        "cash_flow_mirror": cash_flow_mirror,
        "cash_flow_benchmarks": cash_flow_benchmarks,
        "multi_benchmark": multi_benchmark,
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }


@router.post("/refresh/trading212")
def api_refresh_trading212():
    result = refresh_trading212()
    if not result["ok"]:
        raise HTTPException(status_code=500, detail=result)
    clear_all()
    return {"refresh": result, "summary": portfolio_summary(current_snapshot())}


@router.post("/refresh/after-hours")
def api_refresh_after_hours(force: bool = False):
    return refresh_after_hours(force=force)


@router.post("/refresh/market")
def api_refresh_market(force: bool = False):
    result = refresh_market_quotes(force=force)
    if not result["ok"]:
        raise HTTPException(status_code=500, detail=result)
    if not result.get("cached"):
        clear_all()
    return {
        "refresh": {key: value for key, value in result.items() if key != "market"},
        "market": result.get("market", {}),
        "summary": portfolio_summary(current_snapshot()),
    }


@router.post("/refresh/fundamentals")
def api_refresh_fundamentals(force: bool = False):
    result = refresh_fundamentals(force=force)
    if not result.get("cached"):
        clear_all()
    return {
        "refresh": {key: value for key, value in result.items() if key != "fundamentals"},
        "fundamentals": result["fundamentals"],
    }


@router.get("/lab/history")
def api_lab_history():
    return lab_history_summary()


@router.post("/lab/refresh-history")
def api_lab_refresh_history(force: bool = False):
    clear_all()
    result = refresh_history(force=force)
    if not result["ok"]:
        raise HTTPException(status_code=500, detail=result)
    return {"refresh": {key: value for key, value in result.items() if key != "history"}, "history_as_of_unix": result["history"].get("as_of_unix")}


@router.get("/lab/efficient-frontier")
def api_lab_efficient_frontier(samples: int = 900):
    return efficient_frontier(samples=max(100, min(samples, 2500)))


@router.get("/lab/monte-carlo")
def api_lab_monte_carlo(years: int = 10, paths: int = 300):
    return monte_carlo(years=max(1, min(years, 30)), paths=max(50, min(paths, 1500)))


@router.get("/lab/backtest")
def api_lab_backtest():
    return backtest()


@router.get("/lab/factor-analysis")
def api_lab_factor_analysis():
    return factor_analysis()


@router.post("/lab/ai-analysis")
def api_lab_ai_analysis(req: dict | None = Body(None)):
    return ai_analysis(_req_lang(req))


@router.post("/ai/briefing")
def api_ai_briefing(req: dict | None = Body(None)):
    return portfolio_briefing(_req_lang(req))


@router.post("/ai/risk-diagnosis")
def api_ai_risk_diagnosis(req: dict | None = Body(None)):
    return risk_diagnosis(_req_lang(req))


@router.post("/ai/performance-explanation")
async def api_ai_performance_explanation(req: dict = Body(...)):
    return performance_explanation(req.get("question", ""), _req_lang(req))


@router.post("/ai/overlap-analysis")
def api_ai_overlap_analysis(req: dict | None = Body(None)):
    return overlap_analysis(_req_lang(req))


@router.post("/ai/what-if")
async def api_ai_what_if(req: dict = Body(...)):
    return what_if(req.get("scenario", ""), _req_lang(req))


@router.post("/ai/ask")
async def api_ai_ask(req: dict = Body(...)):
    return ask(req.get("question", ""), _req_lang(req))


@router.post("/ai/returns-explanation")
def api_ai_returns_explanation(req: dict | None = Body(None)):
    return returns_explanation(_req_lang(req))
@router.get("/returns/twr")
def api_returns_twr():
    """Simplified TWR calculation from transaction history."""
    return compute_twr_returns()

@router.get("/exposure")
def api_exposure(basis: str = "market"):
    """Unified exposure: direct holdings merged with duplicate ETFs."""
    from app.analytics import unified_exposure
    snapshot = current_snapshot()
    return unified_exposure(snapshot, basis=basis)



@router.post("/alerts/preview-ai-reminders")
async def api_preview_ai_reminders(req: dict = Body(...)):
    from app.alert_rules import preview_ai_reminders
    return {"drafts": preview_ai_reminders(req.get("text", ""))}


@router.get("/alerts")
def api_list_alert_rules():
    from app.alert_rules import list_rules
    return {"rules": list_rules()}


@router.post("/alerts")
async def api_create_alert_rule(req: dict = Body(...)):
    from app.alert_rules import create_rule
    try:
        return {"rule": create_rule(req)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@router.delete("/alerts/{rule_id}")
def api_delete_alert_rule(rule_id: str):
    from app.alert_rules import delete_rule
    return {"ok": delete_rule(rule_id)}
