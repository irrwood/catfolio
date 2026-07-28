"""Lightweight, dependency-free backtest engine for the Strategy Lab.

A user writes a Python `strategy(ctx)` function that returns target weights at each
rebalance date. The engine simulates holding those weights (with drift between
rebalances), applies turnover fees, and reports an equity curve, a benchmark
buy-&-hold curve, summary metrics and the per-rebalance target weights.

Execution is in-process (no subprocess / numpy / pandas), which keeps it bundle-
friendly for the planned desktop app. A wall-clock budget guards against slow
strategies; a pathological infinite loop inside a single strategy() call is a known
MVP limitation (single-user, local, own code — see docs/strategy-backtest-plan.md).
"""

import ast
import time

from .lab import fetch_history
from .data_store import load_json
from .settings import V2_DIR

PRICE_CACHE = V2_DIR / "strategy_prices.json"
PRICE_TTL_SECONDS = 60 * 60 * 12  # 12h
RUN_BUDGET_SECONDS = 20  # soft wall-clock guard for the whole simulation
MAX_STRATEGY_CODE_CHARS = 12_000

REBALANCE_FREQS = {"daily", "weekly", "monthly"}

SAFE_BUILTINS = {
    "abs": abs,
    "all": all,
    "any": any,
    "bool": bool,
    "dict": dict,
    "enumerate": enumerate,
    "float": float,
    "int": int,
    "len": len,
    "list": list,
    "max": max,
    "min": min,
    "range": range,
    "round": round,
    "set": set,
    "sorted": sorted,
    "sum": sum,
    "tuple": tuple,
    "zip": zip,
}

SAFE_CTX_ATTRIBUTES = {"universe", "date", "i", "price", "history", "sma", "momentum"}
SAFE_CALL_NAMES = set(SAFE_BUILTINS)
BLOCKED_NAMES = {
    "__builtins__",
    "__import__",
    "breakpoint",
    "compile",
    "eval",
    "exec",
    "globals",
    "input",
    "locals",
    "open",
    "vars",
}


class StrategySafetyValidator(ast.NodeVisitor):
    """Validate the Strategy Lab script before compiling it.

    This is a deliberately small Python subset for allocation logic. It blocks
    imports, reflection, filesystem/process access through builtins, and object
    dunder traversal such as `().__class__.__mro__`.
    """

    def __init__(self):
        self._function_depth = 0

    def error(self, node, message):
        line = getattr(node, "lineno", None)
        if line:
            raise ValueError(f"策略代码不安全（第 {line} 行）：{message}")
        raise ValueError(f"策略代码不安全：{message}")

    def visit_Module(self, node):
        strategy_defs = [n for n in node.body if isinstance(n, ast.FunctionDef) and n.name == "strategy"]
        if len(strategy_defs) != 1:
            self.error(node, "必须且只能定义一个 `def strategy(ctx): ...` 函数。")
        for stmt in node.body:
            if not isinstance(stmt, (ast.FunctionDef, ast.Expr)):
                self.error(stmt, "顶层只允许函数定义和注释/字符串说明。")
            if isinstance(stmt, ast.Expr) and not isinstance(stmt.value, ast.Constant):
                self.error(stmt, "顶层只允许函数定义和字符串说明。")
            self.visit(stmt)

    def visit_FunctionDef(self, node):
        if self._function_depth:
            self.error(node, "不允许嵌套定义函数。")
        if node.name != "strategy":
            self.error(node, "只允许定义 `strategy` 函数。")
        if node.decorator_list:
            self.error(node, "不允许使用装饰器。")
        if node.returns:
            self.error(node, "不允许使用返回类型标注。")
        args = node.args
        if args.vararg or args.kwarg or args.kwonlyargs or args.defaults or args.kw_defaults:
            self.error(node, "`strategy` 只能接收一个参数：ctx。")
        if len(args.args) != 1 or args.args[0].arg != "ctx":
            self.error(node, "`strategy` 只能接收一个参数：ctx。")
        self._function_depth += 1
        for stmt in node.body:
            self.visit(stmt)
        self._function_depth -= 1

    def visit_Import(self, node):
        self.error(node, "不允许 import。")

    def visit_ImportFrom(self, node):
        self.error(node, "不允许 import。")

    def visit_ClassDef(self, node):
        self.error(node, "不允许定义 class。")

    def visit_Lambda(self, node):
        self.error(node, "不允许 lambda。")

    def visit_Global(self, node):
        self.error(node, "不允许 global。")

    def visit_Nonlocal(self, node):
        self.error(node, "不允许 nonlocal。")

    def visit_With(self, node):
        self.error(node, "不允许 with。")

    def visit_AsyncWith(self, node):
        self.error(node, "不允许 async with。")

    def visit_AsyncFunctionDef(self, node):
        self.error(node, "不允许 async 函数。")

    def visit_Await(self, node):
        self.error(node, "不允许 await。")

    def visit_Yield(self, node):
        self.error(node, "不允许 yield。")

    def visit_YieldFrom(self, node):
        self.error(node, "不允许 yield。")

    def visit_Try(self, node):
        self.error(node, "不允许 try/except。")

    def visit_Raise(self, node):
        self.error(node, "不允许 raise。")

    def visit_While(self, node):
        self.error(node, "不允许 while 循环。")

    def visit_Delete(self, node):
        self.error(node, "不允许 del。")

    def visit_Attribute(self, node):
        if node.attr.startswith("_"):
            self.error(node, "不允许访问私有或 dunder 属性。")
        if isinstance(node.value, ast.Name) and node.value.id == "ctx":
            if node.attr not in SAFE_CTX_ATTRIBUTES:
                self.error(node, f"ctx.{node.attr} 不在允许的策略 API 中。")
        elif isinstance(node.ctx, ast.Load):
            self.error(node, "只允许访问 ctx 提供的策略 API。")
        self.generic_visit(node)

    def visit_Name(self, node):
        if node.id.startswith("_") or node.id in BLOCKED_NAMES:
            self.error(node, f"不允许使用 `{node.id}`。")

    def visit_Call(self, node):
        if isinstance(node.func, ast.Name):
            if node.func.id not in SAFE_CALL_NAMES:
                self.error(node, f"不允许调用 `{node.func.id}`。")
        elif isinstance(node.func, ast.Attribute):
            if not (isinstance(node.func.value, ast.Name) and node.func.value.id == "ctx" and node.func.attr in SAFE_CTX_ATTRIBUTES):
                self.error(node, "只允许调用 ctx.price/history/sma/momentum。")
        else:
            self.error(node, "不允许动态调用。")
        self.generic_visit(node)


def _compile_strategy(code):
    """Compile a validated strategy script and return its strategy(ctx) callable."""
    if len(code) > MAX_STRATEGY_CODE_CHARS:
        raise ValueError(f"策略代码过长（>{MAX_STRATEGY_CODE_CHARS} 字符）。")
    try:
        tree = ast.parse(code, filename="<strategy>", mode="exec")
    except SyntaxError as exc:
        raise ValueError(f"策略代码语法错误：第 {exc.lineno} 行 {exc.msg}")
    StrategySafetyValidator().visit(tree)
    namespace = {}
    try:
        exec(compile(tree, "<strategy>", "exec"), {"__builtins__": SAFE_BUILTINS}, namespace)
    except Exception as exc:
        raise ValueError(f"策略代码编译失败：{type(exc).__name__}: {exc}")
    strategy_fn = namespace.get("strategy")
    if not callable(strategy_fn):
        raise ValueError("策略代码必须定义一个函数 `def strategy(ctx): ...` 并返回目标权重。")
    return strategy_fn


# ── price data (arbitrary tickers, cached per symbol) ──────────────────────────

def get_prices(symbols, years=5):
    """Return {symbol: [{date, close}, ...]} for arbitrary tickers, cached per symbol."""
    cache = load_json(PRICE_CACHE, {}) or {}
    now = int(time.time())
    out = {}
    warnings = []
    dirty = False
    for symbol in dict.fromkeys(s for s in symbols if s):
        entry = cache.get(symbol)
        if entry and entry.get("as_of") and (now - int(entry["as_of"])) < PRICE_TTL_SECONDS and entry.get("rows"):
            out[symbol] = entry["rows"]
            continue
        try:
            rows = fetch_history(symbol, years=years)
            if rows:
                out[symbol] = rows
                cache[symbol] = {"as_of": now, "rows": rows}
                dirty = True
            else:
                warnings.append(f"无历史数据：{symbol}")
        except Exception as exc:
            warnings.append(f"{symbol} 历史获取失败：{type(exc).__name__} {str(exc)[:80]}")
        time.sleep(0.05)
    if dirty:
        try:
            import json
            PRICE_CACHE.write_text(json.dumps(cache, ensure_ascii=False), encoding="utf-8")
        except Exception:
            pass
    return out, warnings


# ── price panel ────────────────────────────────────────────────────────────────

def _build_panel(prices, tickers, start, end):
    """Return (dates_sorted, ffilled) where ffilled[ticker][date] is a forward-filled close."""
    all_dates = set()
    raw = {}
    for t in tickers:
        d2c = {r["date"]: float(r["close"]) for r in prices.get(t, []) if r.get("close") is not None}
        raw[t] = d2c
        all_dates.update(d2c)
    dates = sorted(d for d in all_dates if (not start or d >= start) and (not end or d <= end))
    ffilled = {}
    for t in tickers:
        d2c = raw[t]
        last = None
        col = {}
        for d in dates:
            if d in d2c:
                last = d2c[d]
            col[d] = last
        ffilled[t] = col
    return dates, ffilled


def _rebalance_dates(dates, freq):
    if freq == "daily" or not dates:
        return set(dates)
    keep = set()
    seen = set()
    for d in dates:
        if freq == "monthly":
            key = d[:7]            # YYYY-MM
        else:                       # weekly
            key = time.strftime("%Y-%W", time.strptime(d, "%Y-%m-%d"))
        if key not in seen:
            seen.add(key)
            keep.add(d)
    return keep


# ── strategy context ───────────────────────────────────────────────────────────

class Ctx:
    """Read-only view passed to the user's strategy() at each rebalance date."""

    def __init__(self, dates, ffilled, tickers, index):
        self._dates = dates
        self._ff = ffilled
        self.universe = list(tickers)
        self.i = index
        self.date = dates[index]

    def price(self, ticker):
        col = self._ff.get(ticker)
        return col.get(self.date) if col else None

    def history(self, ticker, n):
        col = self._ff.get(ticker)
        if not col:
            return []
        lo = max(0, self.i - n + 1)
        out = [col[self._dates[j]] for j in range(lo, self.i + 1)]
        return [x for x in out if x is not None]

    def sma(self, ticker, n):
        h = self.history(ticker, n)
        return sum(h) / len(h) if len(h) == n else None

    def momentum(self, ticker, n):
        h = self.history(ticker, n + 1)
        if len(h) < n + 1 or not h[0]:
            return None
        return h[-1] / h[0] - 1


def _clean_weights(raw, tickers):
    if not isinstance(raw, dict):
        return {}
    weights = {}
    for t in tickers:
        try:
            w = float(raw.get(t, 0) or 0)
        except (TypeError, ValueError):
            w = 0.0
        if w > 0:
            weights[t] = w
    total = sum(weights.values())
    if total > 1.0 and total > 0:   # never lever; scale down to 100% invested
        weights = {t: w / total for t, w in weights.items()}
    return weights


# ── metrics ──────────────────────────────────────────────────────────────────

def _metrics(nav, dates):
    if len(nav) < 2:
        return {}
    rets = [nav[i] / nav[i - 1] - 1 for i in range(1, len(nav)) if nav[i - 1]]
    n = len(rets)
    total_return = nav[-1] / nav[0] - 1
    years = max(1e-9, (len(nav)) / 252.0)
    cagr = (nav[-1] / nav[0]) ** (1 / years) - 1 if nav[0] > 0 else None
    mean = sum(rets) / n if n else 0.0
    var = sum((r - mean) ** 2 for r in rets) / n if n else 0.0
    std = var ** 0.5
    vol = std * (252 ** 0.5)
    sharpe = (mean / std * (252 ** 0.5)) if std else None
    peak = nav[0]
    max_dd = 0.0
    for v in nav:
        peak = max(peak, v)
        if peak:
            max_dd = min(max_dd, v / peak - 1)
    return {
        "total_return": total_return,
        "cagr": cagr,
        "vol": vol,
        "sharpe": sharpe,
        "max_drawdown": max_dd,
    }


# ── run ────────────────────────────────────────────────────────────────────────

def run_backtest(code, config):
    """Execute the user strategy and simulate. Returns a result dict (JSON-safe)."""
    universe = [s.strip().upper() for s in config.get("universe", []) if s and s.strip()]
    benchmark = (config.get("benchmark") or "SPY").strip().upper()
    capital = float(config.get("capital") or 10000)
    fee_bps = float(config.get("fee_bps") or 0)
    rebalance = config.get("rebalance") or "monthly"
    if rebalance not in REBALANCE_FREQS:
        rebalance = "monthly"
    start = (config.get("start") or "").strip() or None
    end = (config.get("end") or "").strip() or None
    if not universe:
        raise ValueError("请至少填写一个股票代码（universe）。")

    symbols = list(dict.fromkeys(universe + [benchmark]))
    prices, warnings = get_prices(symbols, years=int(config.get("years") or 6))
    missing = [s for s in universe if s not in prices]
    if missing:
        raise ValueError(f"无法获取历史数据：{', '.join(missing)}")

    dates, ff = _build_panel(prices, symbols, start, end)
    if len(dates) < 30:
        raise ValueError("可用历史数据太少（少于 30 个交易日），请放宽日期范围或换标的。")
    rebal = _rebalance_dates(dates, rebalance)

    strategy_fn = _compile_strategy(code)

    cash = capital
    shares = {t: 0.0 for t in universe}
    equity = []
    trade_log = []
    deadline = time.time() + RUN_BUDGET_SECONDS

    for i, d in enumerate(dates):
        if time.time() > deadline:
            raise ValueError(f"回测超时（>{RUN_BUDGET_SECONDS}s）。请简化策略或缩短区间。")
        px = {t: ff[t][d] for t in universe}
        holdings_val = sum(shares[t] * px[t] for t in universe if px[t])
        total = cash + holdings_val

        if d in rebal:
            ctx = Ctx(dates, ff, universe, i)
            try:
                raw = strategy_fn(ctx)
            except Exception as exc:
                raise ValueError(f"策略在 {d} 执行出错：{type(exc).__name__}: {exc}")
            weights = _clean_weights(raw, universe)
            turnover = sum(abs(total * weights.get(t, 0.0) - shares[t] * px[t]) for t in universe if px[t])
            total -= turnover * fee_bps / 10000.0
            for t in universe:
                shares[t] = (total * weights.get(t, 0.0) / px[t]) if px[t] else 0.0
            cash = total - sum(shares[t] * px[t] for t in universe if px[t])
            if weights:
                trade_log.append({"date": d, "weights": {t: round(w, 4) for t, w in weights.items()}})

        equity.append({"date": d, "nav": round(total, 2)})

    nav_series = [e["nav"] for e in equity]
    metrics = _metrics(nav_series, dates)

    # underwater (drawdown) curve
    drawdown = []
    peak = nav_series[0] if nav_series else 0
    for e in equity:
        peak = max(peak, e["nav"])
        drawdown.append({"date": e["date"], "dd": round(e["nav"] / peak - 1, 5) if peak else 0})

    # benchmark buy & hold
    bm_col = ff.get(benchmark, {})
    bm_first = next((bm_col[d] for d in dates if bm_col.get(d)), None)
    bench = []
    if bm_first:
        for d in dates:
            p = bm_col.get(d)
            bench.append({"date": d, "nav": round(capital * p / bm_first, 2) if p else None})
    bench_metrics = _metrics([b["nav"] for b in bench if b["nav"] is not None], dates) if bench else {}

    return {
        "ok": True,
        "metrics": metrics,
        "benchmark_metrics": bench_metrics,
        "benchmark": benchmark,
        "equity": equity,
        "benchmark_equity": bench,
        "drawdown": drawdown,
        "trades": trade_log,
        "config": {
            "universe": universe, "benchmark": benchmark, "capital": capital,
            "fee_bps": fee_bps, "rebalance": rebalance,
            "start": dates[0], "end": dates[-1], "trading_days": len(dates),
        },
        "warnings": warnings,
    }
