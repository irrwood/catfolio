"""User-created portfolio alert rules."""

from __future__ import annotations

import json
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4

from .settings import V2_DIR

SUPPORTED_METRICS = {
    "single_holding_weight",
    "top_n_weight",
    "sector_exposure",
    "portfolio_qqq_correlation",
    "portfolio_beta",
    "max_drawdown",
    "sharpe",
}

SUPPORTED_OPERATORS = {">", "<", ">=", "<="}


def _rules_path() -> Path:
    return V2_DIR / "alert_rules.json"


def _percent(raw: str) -> float:
    return float(raw) / 100.0


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _load_rules() -> list[dict]:
    try:
        data = json.loads(_rules_path().read_text())
        return data if isinstance(data, list) else []
    except Exception:
        return []


def _save_rules(rules: list[dict]) -> None:
    path = _rules_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(rules, ensure_ascii=False, indent=2))


def _condition(metric: str, operator: str, value: float, label: str, **extra) -> dict:
    item = {"metric": metric, "operator": operator, "value": float(value), "label": label}
    item.update(extra)
    return item


def preview_ai_reminders(text: str) -> list[dict]:
    source = (text or "").strip()
    if not source:
        return []

    conditions: list[dict] = []

    m = re.search(r"前\s*(\d+)\s*持仓占\s*([0-9]+(?:\.[0-9]+)?)%", source)
    if m:
        n = int(m.group(1))
        value = max(0.0, _percent(m.group(2)) - 0.01)
        conditions.append(_condition("top_n_weight", ">", value, f"前 {n} 持仓超过 {value*100:.0f}%", n=n))

    m = re.search(r"科技(?:板块)?暴露\s*([0-9]+(?:\.[0-9]+)?)%", source)
    if m:
        value = max(0.0, _percent(m.group(1)) - 0.01)
        conditions.append(_condition("sector_exposure", ">", value, f"科技板块暴露超过 {value*100:.0f}%", sector="Technology"))

    m = re.search(r"QQQ相关性\s*([0-9]+(?:\.[0-9]+)?)", source, re.I)
    if m:
        value = min(float(m.group(1)), 0.85)
        conditions.append(_condition("portfolio_qqq_correlation", ">", value, f"与 QQQ 相关性超过 {value:.2f}"))

    m = re.search(r"\bbeta\s*([0-9]+(?:\.[0-9]+)?)", source, re.I)
    if m:
        value = float(m.group(1))
        conditions.append(_condition("portfolio_beta", ">", value, f"Beta 超过 {value:.2f}"))

    m = re.search(r"最大回撤\s*(-?[0-9]+(?:\.[0-9]+)?)%", source)
    if m:
        value = -abs(_percent(m.group(1)))
        conditions.append(_condition("max_drawdown", "<", value, f"最大回撤超过 {value*100:.0f}%"))

    m = re.search(r"单票权重(?:超|超过|>)\s*([0-9]+(?:\.[0-9]+)?)%", source)
    if m:
        value = _percent(m.group(1))
        conditions.append(_condition("single_holding_weight", ">", value, f"任一持仓超过 {value*100:.0f}%"))

    m = re.search(r"Sharpe\s*([0-9]+(?:\.[0-9]+)?)", source, re.I)
    if m:
        value = max(0.0, float(m.group(1)) * 0.9)
        conditions.append(_condition("sharpe", "<", value, f"Sharpe 跌破 {value:.2f}"))

    if not conditions:
        conditions = [
            _condition("single_holding_weight", ">", 0.20, "任一持仓超过 20%"),
            _condition("top_n_weight", ">", 0.75, "前 5 持仓超过 75%", n=5),
        ]

    return [{
        "title": "AI 集中风险提醒",
        "source": "ai_suggestion",
        "enabled": True,
        "logic": "any",
        "conditions": conditions,
        "message": "当前组合集中风险上升，请重新评估单票、行业和指数替代方案。",
        "source_text": source,
    }]


def _validate_rule(rule: dict) -> dict:
    title = str(rule.get("title") or "AI 提醒").strip()
    conditions = rule.get("conditions") or []
    if not isinstance(conditions, list) or not conditions:
        raise ValueError("Reminder requires at least one condition")

    clean_conditions = []
    for condition in conditions:
        metric = condition.get("metric")
        operator = condition.get("operator")
        if metric not in SUPPORTED_METRICS:
            raise ValueError(f"Unsupported metric: {metric}")
        if operator not in SUPPORTED_OPERATORS:
            raise ValueError(f"Unsupported operator: {operator}")
        value = float(condition.get("value"))
        cleaned = dict(condition)
        cleaned["value"] = value
        clean_conditions.append(cleaned)

    return {
        "id": str(rule.get("id") or f"ai_{int(time.time())}_{uuid4().hex[:6]}"),
        "title": title,
        "source": str(rule.get("source") or "ai_suggestion"),
        "enabled": bool(rule.get("enabled", True)),
        "logic": "all" if rule.get("logic") == "all" else "any",
        "conditions": clean_conditions,
        "message": str(rule.get("message") or title),
        "source_text": str(rule.get("source_text") or ""),
        "created_at": str(rule.get("created_at") or _now_iso()),
    }


def create_rule(rule: dict) -> dict:
    clean = _validate_rule(rule)
    rules = [existing for existing in _load_rules() if existing.get("id") != clean["id"]]
    rules.append(clean)
    _save_rules(rules)
    return clean


def list_rules() -> list[dict]:
    return _load_rules()


def delete_rule(rule_id: str) -> bool:
    rules = _load_rules()
    kept = [rule for rule in rules if rule.get("id") != rule_id]
    _save_rules(kept)
    return len(kept) != len(rules)


def _compare(actual: float, operator: str, threshold: float) -> bool:
    if operator == ">":
        return actual > threshold
    if operator == "<":
        return actual < threshold
    if operator == ">=":
        return actual >= threshold
    if operator == "<=":
        return actual <= threshold
    return False


def _holding_rows(snapshot: dict) -> list[dict]:
    from .analytics import holdings_heatmap
    return holdings_heatmap(snapshot).get("rows") or []


def _history_stats() -> dict:
    try:
        from .lab import history_cache_age_seconds, lab_history_summary
        if history_cache_age_seconds() is None:
            return {}
        return lab_history_summary().get("stats") or {}
    except Exception:
        return {}


def _actual_for_condition(condition: dict, snapshot: dict) -> tuple[float | None, str]:
    rows = _holding_rows(snapshot)
    metric = condition["metric"]

    if metric == "single_holding_weight":
        if not rows:
            return None, "没有持仓数据"
        row = max(rows, key=lambda item: float(item.get("weight") or 0))
        actual = float(row.get("weight") or 0)
        return actual, f"{row.get('ticker')} 仓位 {actual*100:.1f}%"

    if metric == "top_n_weight":
        n = int(condition.get("n") or 5)
        actual = sum(float(row.get("weight") or 0) for row in sorted(rows, key=lambda item: float(item.get("weight") or 0), reverse=True)[:n])
        return actual, f"前 {n} 持仓 {actual*100:.1f}%"

    if metric == "sector_exposure":
        sector_target = condition.get("sector")
        sectors = {}
        for row in rows:
            sector = row.get("sector") or "Other"
            sectors[sector] = sectors.get(sector, 0.0) + float(row.get("weight") or 0)
        if not sectors:
            return None, "没有板块数据"
        if sector_target:
            actual = sectors.get(sector_target, 0.0)
            return actual, f"{sector_target} 暴露 {actual*100:.1f}%"
        sector, actual = max(sectors.items(), key=lambda item: item[1])
        return actual, f"{sector} 暴露 {actual*100:.1f}%"

    stats = _history_stats()
    stat_map = {
        "portfolio_qqq_correlation": "qqq_correlation",
        "portfolio_beta": "beta",
        "max_drawdown": "max_drawdown",
        "sharpe": "sharpe",
    }
    value = stats.get(stat_map.get(metric, ""))
    if value is None:
        return None, "历史模型数据不足"
    return float(value), f"{metric} = {float(value):.3f}"


def evaluate_rules(snapshot: dict) -> list[dict]:
    alerts = []
    for rule in list_rules():
        if not rule.get("enabled", True):
            continue
        results = []
        for condition in rule.get("conditions") or []:
            actual, detail = _actual_for_condition(condition, snapshot)
            triggered = actual is not None and _compare(actual, condition["operator"], float(condition["value"]))
            results.append({"triggered": triggered, "actual": actual, "detail": detail, "condition": condition})
        if not results:
            continue
        logic = rule.get("logic") or "any"
        fired = all(r["triggered"] for r in results) if logic == "all" else any(r["triggered"] for r in results)
        if fired:
            detail = "；".join(r["detail"] for r in results if r["triggered"])
            alerts.append({
                "type": "ai_rule",
                "ticker": rule.get("id", ""),
                "severity": "warn",
                "message": f"{rule.get('title')}: {rule.get('message')}（{detail}）",
                "rule_id": rule.get("id"),
            })
    return alerts
