"""Page route: api."""
from fastapi import APIRouter, Body, HTTPException, Query
from fastapi.responses import HTMLResponse
import json
import time
from datetime import datetime, timezone
from app.cache import clear_all, cached
from app.data_store import current_snapshot, refresh_after_hours, refresh_fundamentals, refresh_market_quotes, refresh_trading212
from app.analytics import chart_exposure, chart_pnl, etf_lookthrough, holdings_detail, holdings_heatmap, pnl_contribution, portfolio_summary, sector_concentration
from app.lab import BENCHMARKS, BENCHMARK_CN, backtest, correlation_matrix, cumulative_multi_benchmark, cumulative_vs_benchmark, drawdown_curve, efficient_frontier, factor_analysis, fifty_two_week_position, lab_history_summary, monte_carlo, monthly_contribution_waterfall, monthly_return_heatmap, refresh_history, return_distribution, cash_flow_mirror_vs_benchmark

from app.returns_twr import compute_twr_returns
from app.ai import ai_analysis, ask, overlap_analysis, performance_explanation, portfolio_briefing, returns_explanation, risk_diagnosis, what_if

router = APIRouter(prefix="/api", tags=["api"])


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
@cached(ttl=120)
def api_command_center():
    snapshot = current_snapshot()
    history = lab_history_summary()
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
def api_lab_ai_analysis():
    return ai_analysis()


@router.post("/ai/briefing")
def api_ai_briefing():
    return portfolio_briefing()


@router.post("/ai/risk-diagnosis")
def api_ai_risk_diagnosis():
    return risk_diagnosis()


@router.post("/ai/performance-explanation")
async def api_ai_performance_explanation(req: dict = Body(...)):
    return performance_explanation(req.get("question", ""))


@router.post("/ai/overlap-analysis")
def api_ai_overlap_analysis():
    return overlap_analysis()


@router.post("/ai/what-if")
async def api_ai_what_if(req: dict = Body(...)):
    return what_if(req.get("scenario", ""))


@router.post("/ai/ask")
async def api_ai_ask(req: dict = Body(...)):
    return ask(req.get("question", ""))


@router.post("/ai/returns-explanation")
def api_ai_returns_explanation():
    return returns_explanation()
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

