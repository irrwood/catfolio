"""Local rule-based portfolio alerts."""

from .data_store import current_snapshot


def check_alerts():
    """Return a list of alert dicts based on current portfolio data."""
    from .analytics import holdings_heatmap
    from .lab import lab_history_summary, history_cache_age_seconds

    snapshot = current_snapshot()
    alerts = []
    
    try:
        heatmap_data = holdings_heatmap(snapshot)
        rows = heatmap_data.get("rows") or []

        # 1. Single-stock concentration > 25%
        for row in rows:
            weight = float(row.get("weight", 0))
            if weight > 0.25:
                alerts.append({
                    "type": "concentration",
                    "severity": "warn",
                    "message": f"{row.get('ticker')} 仓位 {weight*100:.0f}%，超过 25% 单票集中度阈值。",
                })

        # 2. High PE (>50) with significant weight (>5%)
        for row in rows:
            pe = row.get("forward_pe") or row.get("trailing_pe")
            weight = float(row.get("weight", 0))
            if pe and float(pe) > 50 and weight > 0.05:
                alerts.append({
                    "type": "valuation",
                    "severity": "info",
                    "message": f"{row.get('ticker')} P/E={float(pe):.0f}，高估值且仓位 {weight*100:.0f}%。",
                })

        # 3. Max drawdown threshold — only if lab history is already cached. Never
        # trigger a synchronous Yahoo fetch from the home page (cold cache = slow
        # first load, e.g. on a fresh desktop-app data dir). The alert appears once
        # the user has opened Portfolio Lab.
        if history_cache_age_seconds() is not None:
            hist = lab_history_summary()
            stats = hist.get("stats") or {}
            max_dd = stats.get("max_drawdown")
            if max_dd and max_dd < -0.20:
                alerts.append({
                    "type": "drawdown",
                    "severity": "warn",
                    "message": f"组合最大回撤已达 {max_dd*100:.1f}%，超过 20% 阈值。",
                })
    except Exception:
        pass

    try:
        from .telegram_notify import maybe_push_alerts
        maybe_push_alerts(alerts)
    except Exception:
        pass

    return alerts
