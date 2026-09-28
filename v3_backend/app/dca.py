"""Cash-flow-aware DCA simulation; independent of the weight-rebalancing engine.

Signals use the previous available close; fills use the scheduled day's close.
The simulated portfolio consists only of the selected asset and uninvested cash.
"""
import calendar
import math
import re
from datetime import date, timedelta
from statistics import stdev
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class DCAConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)
    symbol: str = "SPY"
    start: date
    end: date
    base_amount: float = Field(default=500, ge=10, le=100000)
    initial_cash: float = Field(default=10000, ge=0, le=10000000)
    frequency: Literal["weekly", "monthly"] = "weekly"
    sma_enabled: bool = True
    price_low: float = Field(default=.85, ge=.5, le=1)
    price_high: float = Field(default=1.15, ge=1, le=1.5)
    rv_enabled: bool = True
    rv_operator: Literal["lte", "gte"] = "lte"
    rv_threshold: float = Field(default=.4, ge=.05, le=1.5)
    er_enabled: bool = True
    er_operator: Literal["lte", "gte"] = "gte"
    er_threshold: float = Field(default=.3, ge=0, le=1)
    drawdown_enabled: bool = True
    drawdown_threshold: float = Field(default=.2, ge=.1, le=.3)
    cash_reserve: float = Field(default=.3, ge=.2, le=.4)
    max_multiplier: Literal[2, 3] = 3
    min_multiplier: Literal[.25, .5] = .5
    max_position: float = Field(default=.2, ge=.1, le=.2)
    cooldown: int = Field(default=7, ge=3, le=7)

    @field_validator("symbol")
    @classmethod
    def valid_symbol(cls, value):
        value = value.strip().upper()
        if not re.fullmatch(r"[A-Z]{1,6}(?:[.-][AB])?", value):
            raise ValueError("请输入美股或美股 ETF 代码，如 SPY、NVDA、BRK-B")
        return value.replace(".", "-")

    @model_validator(mode="after")
    def valid_dates(self):
        if self.start >= self.end:
            raise ValueError("开始日期必须早于结束日期")
        if self.end > date.today():
            raise ValueError("结束日期不能晚于今天")
        if (self.end - self.start).days > 3653:
            raise ValueError("单次回测最多支持 10 年")
        if self.price_low >= self.price_high:
            raise ValueError("价格区间下限必须小于上限")
        return self


def clean_prices(rows):
    """Reject invalid input rather than fabricating prices or zero returns."""
    result = []
    seen = set()
    for row in rows:
        day = date.fromisoformat(row["date"])
        close = float(row["close"])
        if not math.isfinite(close) or close <= 0 or day in seen:
            raise ValueError("历史行情含无效价格或重复日期，请刷新行情")
        seen.add(day)
        # Today's daily bar may still be forming. Only completed prior dates.
        if day < date.today():
            result.append({"date": day.isoformat(), "close": close})
    return sorted(result, key=lambda row: row["date"])


def observations(rows):
    prices = [r["close"] for r in rows]
    if not prices:
        return dict(sma200=None, price_ratio=None, rv20=None, er20=None, drawdown=None)
    sma = sum(prices[-200:]) / 200 if len(prices) >= 200 else None
    recent = prices[-21:]
    logs = [math.log(b / a) for a, b in zip(recent, recent[1:])]
    travel = sum(abs(b - a) for a, b in zip(recent, recent[1:]))
    return {
        "sma200": sma,
        "price_ratio": prices[-1] / sma if sma else None,
        "rv20": stdev(logs) * math.sqrt(252) if len(logs) == 20 else None,
        "er20": (abs(recent[-1] - recent[0]) / travel if travel else 0.) if len(recent) == 21 else None,
        "drawdown": prices[-1] / max(prices[-252:]) - 1,
    }


def signal(config, obs):
    required = [(config.sma_enabled, "price_ratio"), (config.rv_enabled, "rv20"),
                (config.er_enabled, "er20"), (config.drawdown_enabled, "drawdown")]
    if any(enabled and obs[key] is None for enabled, key in required):
        return 0., "指标历史不足，暂停买入"
    risks = []
    if config.sma_enabled and obs["price_ratio"] >= config.price_high:
        risks.append("高于价格区间")
    for key, enabled, op, threshold, label in (
        ("rv20", config.rv_enabled, config.rv_operator, config.rv_threshold, "RV20"),
        ("er20", config.er_enabled, config.er_operator, config.er_threshold, "ER20"),
    ):
        if enabled and not (obs[key] <= threshold if op == "lte" else obs[key] >= threshold):
            risks.append(label + "未满足")
    if risks:
        return config.min_multiplier, "、".join(risks) + "，降低投入"
    boost = 1.
    reasons = []
    if config.sma_enabled and obs["price_ratio"] <= config.price_low:
        boost = 2.
        reasons.append("低于价格区间")
    if config.drawdown_enabled and obs["drawdown"] <= -config.drawdown_threshold:
        boost = max(boost, 3. if obs["drawdown"] <= -.3 else 2. if obs["drawdown"] <= -.2 else 1.5)
        reasons.append("回撤加仓")
    return min(config.max_multiplier, boost), "、".join(reasons) or "基础定投"


def scheduled_dates(config):
    day = config.start
    month_index = 0
    while day <= config.end:
        yield day
        if config.frequency == "weekly":
            day += timedelta(days=7)
        else:
            month_index += 1
            total = config.start.year * 12 + config.start.month - 1 + month_index
            year, month = divmod(total, 12)
            month += 1
            day = date(year, month, min(config.start.day, calendar.monthrange(year, month)[1]))


def _xirr(flows, terminal_date, terminal_value):
    if terminal_value <= 0 or not flows:
        return None
    origin = flows[0][0]
    if (terminal_date - origin).days < 30:
        return None
    # Solve in log(1+r), avoiding overflow near r=-1.
    def balance(log_rate):
        return sum(amount * math.exp(log_rate * (terminal_date - day).days / 365.25)
                   for day, amount in flows) - terminal_value
    low, high = -30., 30.
    if balance(low) * balance(high) > 0:
        return None
    for _ in range(100):
        mid = (low + high) / 2
        if balance(mid) > 0:
            high = mid
        else:
            low = mid
    return math.expm1((low + high) / 2)


def simulate(config, input_rows):
    rows = clean_prices(input_rows)
    selected = [(i, r) for i, r in enumerate(rows) if config.start.isoformat() <= r["date"] <= config.end.isoformat()]
    if len(selected) < 2:
        raise ValueError("所选区间内至少需要两个交易日的历史行情")
    cash = config.initial_cash
    baseline_cash = cash
    shares = baseline_shares = 0.
    contributed = cash
    flows = [(date.fromisoformat(selected[0][1]["date"]), cash)] if cash else []
    # Do not lump years of unavailable pre-listing contributions into day one.
    schedule_config = config.model_copy(update={"start": max(config.start, date.fromisoformat(rows[0]["date"]))})
    schedule = iter(scheduled_dates(schedule_config))
    due = next(schedule, None)
    last_boost = None
    trades, curve = [], []
    unit_value = peak_unit = 1.
    previous_value = cash
    worst_dd = 0.
    for index, row in selected:
        day = date.fromisoformat(row["date"])
        price = row["close"]
        before_flow = cash + shares * price
        if previous_value > 0:
            unit_value *= before_flow / previous_value
        peak_unit = max(peak_unit, unit_value)
        dd = unit_value / peak_unit - 1
        worst_dd = min(worst_dd, dd)
        deposit = 0.
        if due is not None and day >= due:
            # Every due contribution is retained even if dates fall in a closure.
            periods = 0
            while due is not None and day >= due:
                periods += 1
                due = next(schedule, None)
            deposit = config.base_amount * periods
            cash += deposit
            baseline_cash += deposit
            contributed += deposit
            flows.append((day, deposit))
            obs = observations(rows[:index])
            multiplier, reason = signal(config, obs)
            if multiplier > 1 and last_boost and (day - last_boost).days < config.cooldown:
                multiplier, reason = 1., "加仓冷却期，按基础金额投入"
            value = cash + shares * price
            reserve_room = max(0., cash - value * config.cash_reserve)
            position_room = max(0., value * config.max_position - shares * price)
            desired = deposit * multiplier
            spent = max(0., min(desired, reserve_room, position_room))
            if spent + 1e-8 < desired:
                reason += " · " + ("仓位上限" if position_room <= reserve_room else "现金储备")
            if spent > deposit + 1e-8:
                last_boost = day
            bought = spent / price
            shares += bought
            cash -= spent
            base_value = baseline_cash + baseline_shares * price
            base_spent = max(0., min(deposit, baseline_cash - base_value * config.cash_reserve,
                                    base_value * config.max_position - baseline_shares * price))
            baseline_shares += base_spent / price
            baseline_cash -= base_spent
            trades.append({"date": row["date"], "signal_date": rows[index-1]["date"] if index else None,
                           "price": price, "deposit": deposit, "amount": spent, "shares": bought,
                           "multiplier": spent / deposit, "target_multiplier": multiplier,
                           "cash": cash, "position": shares * price / value,
                           "reason": reason, "indicators": obs})
        previous_value = cash + shares * price
        curve.append({"date": row["date"], "contributed": contributed, "value": previous_value,
                      "holdings": shares * price, "cash": cash,
                      "baseline": baseline_cash + baseline_shares * price, "drawdown": dd})
    last = curve[-1]
    warnings = []
    if rows[0]["date"] > config.start.isoformat():
        warnings.append("开始日期早于可用行情，实际区间已按可用交易日截取。")
    if (config.end - date.fromisoformat(last["date"])).days > 4:
        warnings.append("所选结束日期晚于可用行情；结果截至 " + last["date"] + "。")
    if any(t["target_multiplier"] == 0 for t in trades):
        warnings.append("部分日期缺少指标预热历史，已保留当期入金并暂停买入。")
    return {"config": config.model_dump(mode="json"), "curve": curve, "trades": trades,
            "warnings": warnings, "start": curve[0]["date"], "end": last["date"],
            "metrics": {"contributed": contributed, "value": last["value"],
                        "profit": last["value"] - contributed,
                        "return": last["value"] / contributed - 1 if contributed else 0,
                        "xirr": _xirr(flows, date.fromisoformat(last["date"]), last["value"]),
                        "holdings": last["holdings"], "cash": cash, "shares": shares,
                        "buy_count": sum(t["amount"] > 1e-8 for t in trades),
                        "max_drawdown": worst_dd, "baseline_value": last["baseline"]}}
