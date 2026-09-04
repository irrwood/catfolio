import json
import ssl
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .analytics import etf_lookthrough, holdings_detail, pnl_contribution, portfolio_summary, sector_concentration
from .data_store import current_snapshot, demo_mode, secret_value
from .lab import backtest, cumulative_multi_benchmark, cumulative_vs_benchmark, drawdown_curve, efficient_frontier, factor_analysis, get_history, lab_history_summary, monte_carlo, monthly_return_heatmap
from .portfolio_attention import enforce_confidence, fallback_thesis, fetch_recent_company_events, scan_portfolio

ROOT = Path(__file__).resolve().parent.parent.parent

# ── AI provider registry ────────────────────────────────────────────────────
# DeepSeek and xAI/Grok are both OpenAI-compatible (POST /chat/completions with
# a Bearer key and the same request/response shape), so one code path drives
# both — only base URL, key name, and model differ. The active provider is
# stored as the AI_PROVIDER secret; each provider's model can be overridden via
# its *_MODEL secret, otherwise the default below is used.
PROVIDERS = {
    "deepseek": {
        "label": "DeepSeek",
        "base": "https://api.deepseek.com/v1",
        "key": "DEEPSEEK_API_KEY",
        "model_key": "DEEPSEEK_MODEL",
        "default_model": "deepseek-chat",
        "hint": "性价比高，中文友好（platform.deepseek.com）",
    },
    "grok": {
        "label": "Grok (xAI)",
        "base": "https://api.x.ai/v1",
        "key": "XAI_API_KEY",
        "model_key": "XAI_MODEL",
        "default_model": "grok-4",
        "hint": "xAI Grok（console.x.ai）",
    },
    "openai": {
        "label": "OpenAI",
        "base": "https://api.openai.com/v1",
        "key": "OPENAI_API_KEY",
        "model_key": "OPENAI_MODEL",
        "default_model": "gpt-4o",
        "hint": "GPT 系列（platform.openai.com）",
    },
    "gemini": {
        "label": "Google Gemini",
        "base": "https://generativelanguage.googleapis.com/v1beta/openai",
        "key": "GEMINI_API_KEY",
        "model_key": "GEMINI_MODEL",
        "default_model": "gemini-2.0-flash",
        "hint": "Gemini（aistudio.google.com）",
    },
    "moonshot": {
        "label": "Moonshot Kimi",
        "base": "https://api.moonshot.cn/v1",
        "key": "MOONSHOT_API_KEY",
        "model_key": "MOONSHOT_MODEL",
        "default_model": "moonshot-v1-32k",
        "hint": "月之暗面 Kimi（platform.moonshot.cn）",
    },
    "zhipu": {
        "label": "智谱 GLM",
        "base": "https://open.bigmodel.cn/api/paas/v4",
        "key": "ZHIPU_API_KEY",
        "model_key": "ZHIPU_MODEL",
        "default_model": "glm-4-plus",
        "hint": "智谱清言 GLM（bigmodel.cn）",
    },
    "qwen": {
        "label": "通义千问 Qwen",
        "base": "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "key": "QWEN_API_KEY",
        "model_key": "QWEN_MODEL",
        "default_model": "qwen-plus",
        "hint": "阿里通义千问（dashscope，兼容模式）",
    },
    "openrouter": {
        "label": "OpenRouter",
        "base": "https://openrouter.ai/api/v1",
        "key": "OPENROUTER_API_KEY",
        "model_key": "OPENROUTER_MODEL",
        "default_model": "openai/gpt-4o-mini",
        "hint": "聚合多家模型，一个 key 通用（openrouter.ai）",
    },
}
DEFAULT_PROVIDER = "deepseek"


def _normalize_lang(lang: str | None = None) -> str:
    return "en" if str(lang or "").lower().startswith("en") else "zh"


def _language_system_message(lang: str | None = None) -> str | None:
    if _normalize_lang(lang) != "en":
        return None
    return (
        "Respond in English. If the user asks for JSON, keep the requested JSON keys "
        "exactly as specified, but write all human-readable string values in English."
    )


def _demo_ai_text(messages, lang: str | None = None):
    """Deterministic demo-mode response.

    Demo mode must not read local secrets or call external AI providers. This
    keeps the UI usable for screenshots/open-source demos while making it clear
    that real AI analysis requires leaving demo mode and configuring a key.
    """
    joined = "\n".join(str(m.get("content", "")) for m in messages if isinstance(m, dict))
    is_en = _normalize_lang(lang) == "en"
    if '"risk_level"' in joined or "risk_level" in joined:
        if is_en:
            return json.dumps({
                "risk_level": "Demo",
                "risk_tags": ["sample data", "no external AI call"],
                "findings": [
                    "Demo data mode is active. Catfolio did not read a local AI key or call an external model.",
                    "This is a fixed sample response for open-source demos and screenshots.",
                    "Turn off demo data mode and configure an AI provider to generate real AI analysis.",
                ],
            }, ensure_ascii=False)
        else:
            return json.dumps({
                "risk_level": "Demo",
                "risk_tags": ["示例数据", "未调用外部 AI"],
                "findings": [
                    "当前处于假数据模式，Catfolio 没有读取本机 AI Key，也没有调用外部模型。",
                    "这里展示的是固定示例说明，用于开源演示和截图。",
                    "关闭假数据模式并配置 AI Provider 后，才会生成真实 AI 分析。",
                ],
            }, ensure_ascii=False)
    if is_en:
        return (
            "Demo data mode is active. This is a fixed sample analysis. Catfolio did not read a local AI key "
            "or call an external AI provider. Turn off demo data mode and configure an AI key in Settings to "
            "generate real portfolio analysis."
        )
    return (
        "当前处于假数据模式：这是一段固定示例分析，没有读取本机 AI Key，也没有调用外部 AI Provider。"
        "关闭假数据模式并在设置里配置 AI Key 后，Catfolio 才会根据真实组合生成 AI 分析。"
    )


def active_provider():
    """Return (name, config) of the currently selected AI provider."""
    name = (secret_value("AI_PROVIDER") or DEFAULT_PROVIDER).strip().lower()
    if name not in PROVIDERS:
        name = DEFAULT_PROVIDER
    return name, PROVIDERS[name]


def _chat(messages, temperature=0.3, max_tokens=2048, lang: str | None = None):
    """Send a chat completion to the active provider, return the text response."""
    if demo_mode():
        return _demo_ai_text(messages, lang)
    _name, cfg = active_provider()
    api_key = secret_value(cfg["key"])
    if not api_key:
        raise RuntimeError(
            f"{cfg['key']} 未设置（当前 AI 提供方：{cfg['label']}）。"
            f"请在设置页填入 {cfg['label']} 的 API Key，或切换到已配置好的提供方。"
        )
    model = secret_value(cfg["model_key"]) or cfg["default_model"]
    language_message = _language_system_message(lang)
    if language_message:
        messages = [{"role": "system", "content": language_message}] + list(messages)

    body = json.dumps({
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
    }, ensure_ascii=False).encode("utf-8")

    req = urllib.request.Request(
        f"{cfg['base']}/chat/completions",
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "portfolio-analysis-v3/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:
        if "CERTIFICATE_VERIFY_FAILED" in str(exc):
            with urllib.request.urlopen(req, timeout=120, context=ssl._create_unverified_context()) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        else:
            raise

    if "choices" in data and len(data["choices"]) > 0:
        return data["choices"][0]["message"]["content"]
    raise RuntimeError(f"{cfg['label']} 返回异常: {json.dumps(data, ensure_ascii=False)[:300]}")


# Backwards-compatible alias: existing call sites and strategy.py use _deepseek,
# which now routes through whichever provider is active.
_deepseek = _chat


def _fmt_pct(value):
    """Format a decimal ratio as percentage (e.g. 0.15 -> 15.0%)."""
    if value is None:
        return "—"
    return f"{float(value) * 100:.1f}%"


def _fmt_pct_direct(value):
    """Format an already-percent value (e.g. -3.73 -> -3.7%)."""
    if value is None:
        return "—"
    return f"{float(value):.1f}%"


def _fmt_num(value):
    if value is None:
        return "—"
    return f"{float(value):.3f}"


def _build_data_summary(lang: str | None = None):
    """Collect raw analysis data (numbers only, no programmatic conclusions)."""
    is_en = _normalize_lang(lang) == "en"
    bt = backtest()
    ef = efficient_frontier()
    mc = monte_carlo(years=5, paths=500)
    fa = factor_analysis()
    hist = lab_history_summary()

    stats = hist.get("stats") or {}
    current_weights = hist.get("weights") or {}
    symbols = hist.get("symbols") or []

    # -- backtest data --
    pf = bt.get("portfolio") or {}
    pf_stats = pf.get("stats") or {}
    bt_benchmarks = bt.get("benchmarks") or []
    bench_lines = []
    for b in bt_benchmarks:
        bs = b.get("stats") or {}
        bench_lines.append(
            f"  {b.get('symbol')} ({b.get('label')}): 年化收益={_fmt_pct(bs.get('annual_return'))}, "
            f"年化波动={_fmt_pct(bs.get('annual_volatility'))}, "
            f"最大回撤={_fmt_pct(bs.get('max_drawdown'))}, Sharpe={_fmt_num(bs.get('sharpe'))}"
        )

    # -- frontier data --
    points = ef.get("points") or []
    opt = ef.get("optimized") or {}
    max_sharpe = opt.get("max_sharpe") or {}
    min_vol = opt.get("min_volatility") or {}
    current = opt.get("current") or {}

    frontier_summary = f"有效前沿: {len(points)} 个随机组合。\n"
    frontier_summary += f"  当前组合: 收益={_fmt_pct(current.get('annual_return'))}, 波动={_fmt_pct(current.get('annual_volatility'))}, Sharpe={_fmt_num(current.get('sharpe'))}\n"
    frontier_summary += f"  最大夏普: 收益={_fmt_pct(max_sharpe.get('annual_return'))}, 波动={_fmt_pct(max_sharpe.get('annual_volatility'))}, Sharpe={_fmt_num(max_sharpe.get('sharpe'))}\n"
    frontier_summary += f"  最小波动: 收益={_fmt_pct(min_vol.get('annual_return'))}, 波动={_fmt_pct(min_vol.get('annual_volatility'))}, Sharpe={_fmt_num(min_vol.get('sharpe'))}"

    # -- monte carlo data --
    fp = mc.get("final_percentiles") or {}
    assumptions = mc.get("assumptions") or {}
    mc_summary = (
        f"蒙特卡洛 ({mc.get('years', 5)}年/{mc.get('paths_count', 500)}条路径):\n"
        f"  最终净值分位数: p5={_fmt_num(fp.get('p5'))}x, p25={_fmt_num(fp.get('p25'))}x, "
        f"p50={_fmt_num(fp.get('p50'))}x, p75={_fmt_num(fp.get('p75'))}x, p95={_fmt_num(fp.get('p95'))}x\n"
        f"  假设: 日均收益={_fmt_num(assumptions.get('daily_mean'))}, 日波动={_fmt_num(assumptions.get('daily_volatility'))}"
    )

    # -- factor data --
    factor_rows = fa.get("rows") or []
    factor_lines = ["因子暴露 (单因子回归):"]
    for r in factor_rows[:5]:
        factor_lines.append(
            f"  {r.get('factor')} ({r.get('label')}): beta={_fmt_num(r.get('beta'))}, 相关系数={_fmt_num(r.get('correlation'))}"
        )

    # -- weights (top holdings) --
    weight_items = sorted(current_weights.items(), key=lambda x: x[1], reverse=True)[:15]
    weight_lines = ["前15大持仓权重:"]
    for sym, w in weight_items:
        weight_lines.append(f"  {sym}: {_fmt_pct(w)}")

    summary = f"""## 组合概况
持仓数: {len(symbols)}
当前组合: 年化收益={_fmt_pct(stats.get('annual_return'))}, 年化波动={_fmt_pct(stats.get('annual_volatility'))}, 最大回撤={_fmt_pct(stats.get('max_drawdown'))}, Sharpe={_fmt_num(stats.get('sharpe'))}

{chr(10).join(weight_lines)}

## 回测 (Backtest)
组合: 年化收益={_fmt_pct(pf_stats.get('annual_return'))}, 年化波动={_fmt_pct(pf_stats.get('annual_volatility'))}, 最大回撤={_fmt_pct(pf_stats.get('max_drawdown'))}, Sharpe={_fmt_num(pf_stats.get('sharpe'))}
基准:
{chr(10).join(bench_lines)}

## {frontier_summary}

## {mc_summary}

## {chr(10).join(factor_lines)}
"""

    if is_en:
        programmatic = {
            "backtest": f"Portfolio annualized return is {_fmt_pct(pf_stats.get('annual_return'))}; max drawdown is {_fmt_pct(pf_stats.get('max_drawdown'))}.",
            "frontier": f"The portfolio ranks above about {_compute_sharpe_rank(points, current)}% of simulated portfolios. The max-Sharpe portfolio has return {_fmt_pct(max_sharpe.get('annual_return'))} and volatility {_fmt_pct(max_sharpe.get('annual_volatility'))}.",
            "monte_carlo": f"The 5-year simulation median is about {_fmt_num(fp.get('p50'))}x; the pessimistic p5 case is about {_fmt_num(fp.get('p5'))}x.",
            "factors": f"Closest factor is {factor_rows[0].get('label')} with beta {_fmt_num(factor_rows[0].get('beta'))} and correlation {_fmt_num(factor_rows[0].get('correlation'))}." if factor_rows else "Factor sample is insufficient.",
        }
    else:
        programmatic = {
            "backtest": f"组合年化 {_fmt_pct(pf_stats.get('annual_return'))}，最大回撤 {_fmt_pct(pf_stats.get('max_drawdown'))}。",
            "frontier": f"组合好于约 {_compute_sharpe_rank(points, current)}% 的模拟组合。最大夏普组合收益={_fmt_pct(max_sharpe.get('annual_return'))}，波动={_fmt_pct(max_sharpe.get('annual_volatility'))}。",
            "monte_carlo": f"5年模拟中位数约 {_fmt_num(fp.get('p50'))}x，悲观 p5 约 {_fmt_num(fp.get('p5'))}x。",
            "factors": f"最接近 {factor_rows[0].get('label')}，beta {_fmt_num(factor_rows[0].get('beta'))}，相关 {_fmt_num(factor_rows[0].get('correlation'))}。" if factor_rows else "因子样本不足。",
        }

    return {"data_summary": summary, "programmatic": programmatic}


def _compute_sharpe_rank(points, current):
    if not points or current.get('sharpe') is None:
        return "—"
    try:
        current_sharpe = float(current['sharpe'])
        better = sum(1 for p in points if float(p.get('sharpe', 0)) <= current_sharpe)
        return round(better / len(points) * 100)
    except (TypeError, ZeroDivisionError):
        return "—"


def ai_analysis(lang: str | None = None):
    """Run AI analysis on backtest, frontier, monte carlo, and factor results.

    Returns a dict with 'ai' (AI's independent analysis) and 'programmatic'
    (the current programmatic conclusions) for frontend comparison.
    """
    summary = _build_data_summary(lang)
    data_text = summary["data_summary"]
    prog = summary["programmatic"]

    # Prompt: give raw data only, ask AI to independently interpret
    analysis_prompt = f"""你是一位资深的量化投资分析师。请基于以下投资组合分析数据，独立作出你的专业解读。

{data_text}

请从以下四个维度给出你的分析，每个维度用 2-3 句话，用中文，直接说结论不要客套话：

1. **回测表现**：组合与基准相比表现如何？风险调整收益是否合理？
2. **有效前沿**：当前组合在有效前沿上的位置是否理想？优化空间大吗？
3. **蒙特卡洛**：未来收益分布的健康程度如何？极端风险需要注意什么？
4. **因子暴露**：组合主要受哪些因子驱动？是否存在隐性集中风险？

请严格按照以下 JSON 格式回复，不要输出其他内容：
{{
  "backtest": "你对回测的分析",
  "frontier": "你对有效前沿的分析",
  "monte_carlo": "你对蒙特卡洛的分析",
  "factors": "你对因子暴露的分析"
}}"""

    ai_text = _deepseek([
        {"role": "system", "content": "你是量化投资分析师。请严格按照要求的 JSON 格式回复，只输出 JSON。"},
        {"role": "user", "content": analysis_prompt},
    ], temperature=0.3, max_tokens=1024, lang=lang)

    # Parse AI's JSON response
    ai_json = _parse_ai_json(ai_text)

    # Second pass: ask AI to review the programmatic conclusions
    review_prompt = f"""以下是同一份投资组合数据，程序自动生成的结论：

回测结论: {prog['backtest']}
有效前沿结论: {prog['frontier']}
蒙特卡洛结论: {prog['monte_carlo']}
因子分析结论: {prog['factors']}

你之前的独立分析:
回测: {ai_json.get('backtest', '')}
有效前沿: {ai_json.get('frontier', '')}
蒙特卡洛: {ai_json.get('monte_carlo', '')}
因子: {ai_json.get('factors', '')}

请评议程序生成的结论：哪些靠谱，哪些不够准确或有遗漏，整体评价。用中文，2-3 句话。直接说结论不要客套。"""

    review_text = _deepseek([
        {"role": "system", "content": "你是量化投资分析师。请直接给出评议，不要客套。"},
        {"role": "user", "content": review_prompt},
    ], temperature=0.3, max_tokens=512, lang=lang)

    return {
        "ai": ai_json,
        "ai_review": review_text.strip(),
        "programmatic": prog,
    }


def _parse_ai_json(text):
    """Parse AI's JSON response, handling markdown code fences."""
    text = text.strip()
    # Remove markdown code fences if present
    if text.startswith("```"):
        lines = text.split("\n")
        # Remove first line (```json or ```) and last line (```)
        if lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        text = "\n".join(lines).strip()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # Fallback: return raw text wrapped
        return {
            "backtest": text,
            "frontier": "",
            "monte_carlo": "",
            "factors": "",
        }


def _snapshot_data():
    """Return a dict with all commonly-needed snapshot-derived data."""
    snap = current_snapshot()
    ps = portfolio_summary(snap)
    hd = holdings_detail(snap)
    sc = sector_concentration(snap)
    pnl = pnl_contribution(snap)
    etf = etf_lookthrough(snap, basis="market")
    bt = backtest()
    fa = factor_analysis()
    dd = drawdown_curve()
    bench = cumulative_vs_benchmark("SPY")
    hist = lab_history_summary()

    return {
        "snap": snap,
        "summary": ps,
        "holdings": hd,
        "sectors": sc,
        "pnl": pnl,
        "etf": etf,
        "backtest": bt,
        "factors": fa,
        "drawdown": dd,
        "benchmark": bench,
        "history": hist,
    }


# ── MVP Phase 1 Functions ──────────────────────────────────────────


def portfolio_briefing(lang: str | None = None):
    """AI Portfolio Briefing — 组合每日总结."""
    d = _snapshot_data()
    ps = d["summary"]
    hd = d["holdings"]
    sc = d["sectors"]
    bt = d["backtest"]
    dd = d["drawdown"]
    bench = d["benchmark"]

    # Top holdings
    top_holdings = hd.get("rows", [])[:10]
    top_lines = []
    for h in top_holdings:
        top_lines.append(
            f"  {h.get('ticker')} ({h.get('display_name', h.get('name', ''))}): "
            f"权重={_fmt_pct(h.get('weight', 0))}, 今日涨跌={_fmt_pct_direct(h.get('today_change_percent'))}, "
            f"浮盈={_fmt_pct_direct(h.get('unrealized_percent'))}"
        )

    # Sector concentration
    sc_rows = sc.get("rows", [])[:8]
    sector_lines = []
    for s in sc_rows:
        sector_lines.append(f"  {s.get('sector')}: {_fmt_pct(s.get('weight', 0))}")

    # Benchmark comparison
    bench_rows = bench.get("rows", [])
    bench_final = bench_rows[-1] if bench_rows else {}
    bench_excess = bench_final.get("excess", 0)

    # Drawdown
    max_dd = dd.get("max_drawdown", 0)

    # Portfolio-level stats
    pf = bt.get("portfolio", {}).get("stats", {})
    bm_list = bt.get("benchmarks", [])
    spy_bt = next((b for b in bm_list if b.get("symbol") == "SPY"), {})
    spy_stats = spy_bt.get("stats", {})

    prompt = f"""你是一位资深投资组合分析师。以下是用户当前持仓的实时数据。请用中文给出简短有力的组合总结（4-5 句话），直接说结论不要客套。

## 组合概况
总成本: ${ps.get('total_cost_usd_standard', 0):,.0f}
总市值: ${ps.get('market_value_usd', 0):,.0f}
未实现盈亏: ${ps.get('unrealized_usd', 0):,.0f}
持仓数: {ps.get('trading212_positions', 0)}
现金: {json.dumps(ps.get('cash', {}), ensure_ascii=False)}

## 前10大持仓
{chr(10).join(top_lines)}

## 行业分布
{chr(10).join(sector_lines)}

## 业绩对比
组合年化收益: {_fmt_pct(pf.get('annual_return'))}
组合年化波动: {_fmt_pct(pf.get('annual_volatility'))}
最大回撤: {_fmt_pct(max_dd)}
SPY年化收益: {_fmt_pct(spy_stats.get('annual_return'))}
相对SPY超额: {_fmt_pct(bench_excess)}

请分析：
1. 当前组合风格（进攻/防守/均衡）
2. 近期表现：跑赢还是跑输基准
3. 主要收益来源和亏损来源
4. 当前最大风险
5. 是否存在持仓过度集中或ETF与个股重复暴露

用中文回答，4-5句话，直接给结论。"""

    text = _deepseek([
        {"role": "system", "content": "你是资深投资组合分析师。请直接给出分析，4-5句话，中文。"},
        {"role": "user", "content": prompt},
    ], temperature=0.4, max_tokens=600, lang=lang)

    return {"briefing": text.strip()}


def risk_diagnosis(lang: str | None = None):
    """AI Risk Diagnosis — 组合风险诊断."""
    d = _snapshot_data()
    hd = d["holdings"]
    sc = d["sectors"]
    fa = d["factors"]
    etf = d["etf"]
    dd = d["drawdown"]

    # Top 5 concentration
    top5 = hd.get("rows", [])[:5]
    top5_weight = sum(h.get("weight", 0) for h in top5)
    top5_lines = [f"  {h.get('ticker')}: {_fmt_pct(h.get('weight', 0))}" for h in top5]

    # Factor exposure
    factor_lines = []
    for f in fa.get("rows", [])[:6]:
        factor_lines.append(f"  {f.get('label')} ({f.get('factor')}): beta={_fmt_num(f.get('beta'))}, 相关={_fmt_num(f.get('correlation'))}")
    top_factor = fa.get("rows", [{}])[0] if fa.get("rows") else {}

    # ETF overlap
    etf_tickers = etf.get("etf_tickers", [])
    etf_total = etf.get("etf_total_usd", 0)
    etf_rows = etf.get("rows", [])[:8]
    etf_lines = []
    for r in etf_rows:
        etf_lines.append(
            f"  {r.get('ticker')} ({r.get('name', '')}): 直接={r.get('direct_usd', 0):,.0f}, "
            f"ETF穿透={r.get('from_etf_usd', 0):,.0f}"
        )

    # Sector top
    top_sector = sc.get("rows", [{}])[0] if sc.get("rows") else {}

    # Beta
    portfolio_beta = top_factor.get("beta", 1.0) if top_factor else 1.0

    # Drawdown
    max_dd = dd.get("max_drawdown", 0)

    prompt = f"""你是一位风险管理专家。请根据以下数据诊断用户组合的风险状况，用中文给出结论。

## 集中度
前5大持仓占比: {_fmt_pct(top5_weight)}
{chr(10).join(top5_lines)}

## 行业集中
最大行业: {top_sector.get('sector', '—')} ({_fmt_pct(top_sector.get('weight', 0))})
{chr(10).join(f"  {s.get('sector')}: {_fmt_pct(s.get('weight', 0))}" for s in sc.get('rows', [])[:5])}

## 因子暴露
组合Beta(相对{top_factor.get('label', 'SPY')}): {_fmt_num(portfolio_beta)}
{chr(10).join(factor_lines)}

## ETF穿透 (S&P 500)
ETF持仓市值: ${etf_total:,.0f}
{chr(10).join(etf_lines)}

## 回撤
最大历史回撤: {_fmt_pct(max_dd)}

请输出：
1. 风险等级（低/中/偏高/高）
2. 主要风险标签（从以下选：科技股集中、半导体集中、AI主题集中、高Beta、单一个股依赖、ETF与个股重叠、现金比例不足、防守资产不足、波动率偏高、回撤风险偏高）
3. 最重要的3-4条风险发现

请严格按照以下JSON格式回复：
{{
  "risk_level": "偏高",
  "risk_tags": ["标签1", "标签2"],
  "findings": ["发现1", "发现2", "发现3"]
}}"""

    text = _deepseek([
        {"role": "system", "content": "你是风险管理专家。请严格按JSON格式回复。"},
        {"role": "user", "content": prompt},
    ], temperature=0.3, max_tokens=800, lang=lang)

    result = _parse_ai_json(text)
    return result if isinstance(result, dict) and "risk_level" in result else {
        "risk_level": "—",
        "risk_tags": [],
        "findings": [text.strip()],
    }


def performance_explanation(question: str = "", lang: str | None = None):
    """AI Performance Explanation — 收益归因解释."""
    d = _snapshot_data()
    ps = d["summary"]
    pnl = d["pnl"]
    bench = d["benchmark"]
    hd = d["holdings"]

    # Top gainers and losers
    all_rows = sorted(pnl.get("rows", []), key=lambda r: r.get("unrealized_usd", 0), reverse=True)
    gainers = [r for r in all_rows if r.get("unrealized_usd", 0) > 0][:5]
    losers = [r for r in all_rows if r.get("unrealized_usd", 0) < 0][-5:]

    gainer_lines = [f"  {r.get('ticker')}: +${r.get('unrealized_usd', 0):,.0f} ({_fmt_pct_direct(r.get('unrealized_percent'))})" for r in gainers]
    loser_lines = [f"  {r.get('ticker')}: ${r.get('unrealized_usd', 0):,.0f} ({_fmt_pct_direct(r.get('unrealized_percent'))})" for r in losers]

    # Today performers
    today_sorted = sorted(hd.get("rows", []), key=lambda r: r.get("today_change_percent") or -999, reverse=True)
    today_up = [r for r in today_sorted if (r.get("today_change_percent") or 0) > 0][:5]
    today_down = [r for r in today_sorted if (r.get("today_change_percent") or 0) < 0][-5:]

    today_up_lines = [f"  {r.get('ticker')}: {_fmt_pct_direct(r.get('today_change_percent'))}" for r in today_up]
    today_down_lines = [f"  {r.get('ticker')}: {_fmt_pct_direct(r.get('today_change_percent'))}" for r in today_down]

    # Benchmark
    bench_rows = bench.get("rows", [])
    bench_final = bench_rows[-1] if bench_rows else {}
    bench_excess = bench_final.get("excess", 0)

    # Sector contributions
    pnl_rows = pnl.get("rows", [])[:10]
    pnl_lines = [f"  {r.get('ticker')}: 贡献权重={_fmt_pct(r.get('contribution_weight', 0))}, 浮动盈亏=${r.get('unrealized_usd', 0):,.0f}" for r in pnl_rows]

    q = question or "请解释组合近期表现"

    prompt = f"""你是一位业绩归因分析师。用户问："{q}"

## 组合数据
总市值: ${ps.get('market_value_usd', 0):,.0f}
未实现盈亏: ${ps.get('unrealized_usd', 0):,.0f}
相对SPY超额收益: {_fmt_pct(bench_excess)}

## 最大盈利持仓（累计）
{chr(10).join(gainer_lines) if gainer_lines else "  无"}

## 最大亏损持仓（累计）
{chr(10).join(loser_lines) if loser_lines else "  无"}

## 今日涨幅最大
{chr(10).join(today_up_lines) if today_up_lines else "  无"}

## 今日跌幅最大
{chr(10).join(today_down_lines) if today_down_lines else "  无"}

## 盈亏贡献前10
{chr(10).join(pnl_lines)}

请用中文回答用户的问题，2-4句话，直接给结论不要客套。"""

    text = _deepseek([
        {"role": "system", "content": "你是业绩归因分析师。请直接回答用户问题，简短有力。"},
        {"role": "user", "content": prompt},
    ], temperature=0.3, max_tokens=500, lang=lang)

    return {"explanation": text.strip(), "question": q}


def overlap_analysis(lang: str | None = None):
    """AI Holding Overlap Analysis — 持仓重叠分析."""
    d = _snapshot_data()
    etf = d["etf"]
    hd = d["holdings"]
    sc = d["sectors"]

    # ETF lookthrough
    etf_rows = etf.get("rows", [])
    overlap_lines = []
    for r in etf_rows[:15]:
        direct = r.get("direct_usd", 0)
        from_etf = r.get("from_etf_usd", 0)
        if direct > 0 and from_etf > 0:
            overlap_lines.append(
                f"  ⚠ {r.get('ticker')}: 直接持有${direct:,.0f} + ETF穿透${from_etf:,.0f} = 合计${direct + from_etf:,.0f}"
            )

    # All holdings with sectors
    holding_lines = []
    for h in hd.get("rows", [])[:20]:
        holding_lines.append(
            f"  {h.get('ticker')} ({h.get('display_name', '')}): 权重={_fmt_pct(h.get('weight', 0))}, 行业={h.get('sector', '—')}"
        )

    # Sector concentration
    sector_lines = [f"  {s.get('sector')}: {_fmt_pct(s.get('weight', 0))}" for s in sc.get("rows", [])]

    prompt = f"""你是一位投资组合构建专家。请分析用户持仓是否存在"假分散"问题——表面上持有很多资产，但真实风险高度重复。

## ETF穿透分析 (S&P 500)
ETF穿透总市值: ${etf.get('etf_total_usd', 0):,.0f}
ETF标的: {', '.join(etf.get('etf_tickers', []))}

存在直接+ETF双重暴露的持仓:
{chr(10).join(overlap_lines) if overlap_lines else "  无明显双重暴露"}

## 持仓明细
{chr(10).join(holding_lines)}

## 行业分布
{chr(10).join(sector_lines)}

请分析：
1. 是否存在ETF与个股的重叠（例如持有QQQ的同时又持有大量NVDA/MSFT）
2. 是否存在行业/主题过度集中
3. 真实分散度评估：表面上持有X只，但实际独立风险来源只有几只

用中文回答，3-5句话，直接给结论。"""

    text = _deepseek([
        {"role": "system", "content": "你是投资组合构建专家。请直接分析持仓重叠问题。"},
        {"role": "user", "content": prompt},
    ], temperature=0.3, max_tokens=600, lang=lang)

    return {"overlap_analysis": text.strip()}


def what_if(scenario: str, lang: str | None = None):
    """AI What-if Scenario — 情景分析. Programmatic calculation + AI explanation."""
    d = _snapshot_data()
    hd = d["holdings"]
    sc = d["sectors"]
    fa = d["factors"]

    # Programmatic: compute basic impact data for AI to use
    holding_rows = hd.get("rows", [])
    total_market_value = d["summary"].get("market_value_usd", 1)

    # Build lookup: ticker -> weight
    ticker_weight = {}
    ticker_name = {}
    for h in holding_rows:
        ticker_weight[h.get("ticker", "")] = h.get("weight", 0)
        ticker_name[h.get("ticker", "")] = h.get("display_name", h.get("name", ""))

    # Top factor beta
    top_factor = fa.get("rows", [{}])[0] if fa.get("rows") else {}
    portfolio_beta = top_factor.get("beta", 1.0)

    # Sector weights
    sector_weight = {s.get("sector"): s.get("weight", 0) for s in sc.get("rows", [])}

    # Build scenario data
    scenario_data = f"""## 当前组合快照
总市值: ${total_market_value:,.0f}
组合Beta (相对{top_factor.get('label', 'SPY')}): {_fmt_num(portfolio_beta)}

## 持仓权重
{chr(10).join(f"  {t}: {_fmt_pct(w)}" for t, w in sorted(ticker_weight.items(), key=lambda x: x[1], reverse=True)[:15])}

## 行业权重
{chr(10).join(f"  {s}: {_fmt_pct(w)}" for s, w in sector_weight.items())}
"""

    prompt = f"""你是一位量化情景分析师。用户提出了以下假设情景，请基于当前组合数据进行分析。

{scenario_data}

用户情景: "{scenario}"

请分析：
1. 这个情景对组合的直接影响（基于权重和暴露估算）
2. 可能的二阶效应（相关性、行业联动等）
3. 组合中最脆弱的部分

用中文回答，3-5句话，给出具体的数字估算，直接说结论不要客套。
（注意：你是分析师，不推荐买卖，只分析影响。）"""

    text = _deepseek([
        {"role": "system", "content": "你是量化情景分析师。请基于数据给出具体的情景影响分析，不推荐买卖。"},
        {"role": "user", "content": prompt},
    ], temperature=0.3, max_tokens=600, lang=lang)

    return {"what_if_analysis": text.strip(), "scenario": scenario}


def _attention_thesis_prompt(rows: list[dict], sources: dict[str, list[dict]], lang: str) -> str:
    evidence = []
    for row in rows:
        evidence.append({
            "ticker": row["ticker"],
            "name": row["name"],
            "attention": row["attention"],
            "signals": row["signals"],
            "metrics_calculated_by_catfolio": {
                "weight": row["weight"],
                "today_change_percent": row["today_change_percent"],
                "portfolio_contribution_percent": row["portfolio_contribution_percent"],
                "return_60d_percent": row["return_60d_percent"],
                "volume_multiple": row["volume_multiple"],
                "distance_from_52w_high_percent": row["distance_from_52w_high_percent"],
                "distance_from_52w_low_percent": row["distance_from_52w_low_percent"],
                "ma_200_position_percent": row["ma_200_position_percent"],
            },
            "fundamentals": row["fundamentals"],
            "recent_source_bundle": sources.get(row["ticker"], []),
        })
    language = "English" if _normalize_lang(lang) == "en" else "Chinese"
    return f"""You are the thesis stage of Catfolio's Portfolio Attention Engine.

Catfolio has already calculated every market metric below. Never recalculate, alter, or invent a number. Only explain the supplied evidence. A headline is not proof of a catalyst unless it clearly describes a company-specific confirmed event. Do not invent article contents. If the evidence bundle is empty or only shows market/sector commentary, set company_specific_catalyst=false and catalyst_confirmed=false.

For each holding, evaluate what changed, why it matters, whether the investment thesis is strengthening, maintaining, or weakening, the strongest counter-evidence, risks, and what to watch. Risk flags may only use: legal_regulatory, governance, dilution, liquidity, leadership. Do not recommend buying or selling, give a target price, or suggest position sizing. Write human-readable fields in {language}.

Evidence:
{json.dumps(evidence, ensure_ascii=False)}

Return only this JSON structure:
{{
  "theses": [
    {{
      "ticker": "NVDA",
      "stance": "strengthening|maintaining|weakening",
      "what_changed": "...",
      "why_it_matters": "...",
      "supporting_evidence": ["..."],
      "counter_evidence": ["..."],
      "risks": ["..."],
      "watch_next": ["..."],
      "risk_flags": ["legal_regulatory|governance|dilution|liquidity|leadership"],
      "company_specific_catalyst": false,
      "catalyst_confirmed": false,
      "catalyst_is_recent": false,
      "evidence_source_ids": ["exact-source-id-from-bundle"],
      "severe_unresolved_risk": false
    }}
  ]
}}"""


def portfolio_attention(lang: str | None = None):
    """Run deterministic screening, then research/explain only selected rows."""
    normalized_lang = _normalize_lang(lang)
    snapshot = current_snapshot()
    history = get_history()
    result = scan_portfolio(snapshot, history)
    selected = result["attention_rows"]
    if not selected:
        return {**result, "research_status": "not_needed", "warnings": []}

    sources: dict[str, list[dict]] = {}
    if demo_mode():
        sources = {row["ticker"]: [] for row in selected}
    else:
        research_rows = selected[:8]
        with ThreadPoolExecutor(max_workers=min(4, len(research_rows))) as pool:
            futures = {
                row["ticker"]: pool.submit(fetch_recent_company_events, row["ticker"], row["name"])
                for row in research_rows
            }
            sources = {ticker: future.result() for ticker, future in futures.items()}

    model_by_ticker = {}
    warnings = []
    if not demo_mode():
        try:
            prompt = _attention_thesis_prompt(selected[:8], sources, normalized_lang)
            text = _deepseek([
                {"role": "system", "content": "You are a cautious portfolio research analyst. Return valid JSON only."},
                {"role": "user", "content": prompt},
            ], temperature=0.2, max_tokens=4000, lang=normalized_lang)
            parsed = _parse_ai_json(text)
            model_by_ticker = {
                str(item.get("ticker") or "").upper(): item
                for item in parsed.get("theses", [])
                if isinstance(item, dict) and item.get("ticker")
            }
        except Exception as exc:
            warnings.append(f"AI thesis unavailable: {type(exc).__name__}")

    output_rows = []
    for row in selected:
        source_rows = sources.get(row["ticker"], [])
        source_index = {source["id"]: source for source in source_rows}
        thesis = model_by_ticker.get(row["ticker"]) or fallback_thesis(row, normalized_lang)
        thesis["confidence"] = enforce_confidence(thesis, source_index)
        output_rows.append({**row, "thesis": thesis, "sources": source_rows})

    result["attention_rows"] = output_rows
    result["research_status"] = "demo" if demo_mode() else ("complete" if model_by_ticker else "signals_only")
    result["warnings"] = warnings
    return result


def ask(question: str, lang: str | None = None, context: dict | None = None):
    """Generic AI Q&A — answer any portfolio question by feeding all relevant data to DeepSeek."""
    if not question or not question.strip():
        return {"answer": "请先输入一个问题。", "question": question}

    d = _snapshot_data()
    ps = d["summary"]
    hd = d["holdings"]
    sc = d["sectors"]
    pnl = d["pnl"]
    etf = d["etf"]
    bt = d["backtest"]
    fa = d["factors"]
    dd = d["drawdown"]
    bench = d["benchmark"]
    hist = d["history"]

    # Build comprehensive data snapshot for AI context
    def _h():
        rows = hd.get("rows", [])[:15]
        return "\n".join(
            f"  {r.get('ticker')} ({r.get('display_name', r.get('name', ''))}): "
            f"权重={_fmt_pct(r.get('weight', 0))}, 今日={_fmt_pct_direct(r.get('today_change_percent'))}, "
            f"浮盈={_fmt_pct_direct(r.get('unrealized_percent'))}, 行业={r.get('sector', '—')}"
            for r in rows
        )

    def _sectors():
        return "\n".join(f"  {s.get('sector')}: {_fmt_pct(s.get('weight', 0))}" for s in sc.get("rows", []))

    def _factors():
        return "\n".join(
            f"  {f.get('label')} ({f.get('factor')}): beta={_fmt_num(f.get('beta'))}, 相关={_fmt_num(f.get('correlation'))}"
            for f in fa.get("rows", [])[:6]
        )

    def _benchmarks():
        lines = []
        for b in bt.get("benchmarks", [])[:5]:
            s = b.get("stats", {})
            lines.append(
                f"  {b.get('symbol')} ({b.get('label')}): 年化收益={_fmt_pct(s.get('annual_return'))}, "
                f"波动={_fmt_pct(s.get('annual_volatility'))}, 最大回撤={_fmt_pct(s.get('max_drawdown'))}"
            )
        return "\n".join(lines)

    def _etf_overlap():
        rows = etf.get("rows", [])
        lines = []
        for r in rows[:10]:
            d_usd = r.get("direct_usd", 0)
            e_usd = r.get("from_etf_usd", 0)
            if d_usd > 0 or e_usd > 0:
                lines.append(f"  {r.get('ticker')}: 直接${d_usd:,.0f} + ETF穿透${e_usd:,.0f}")
        return "\n".join(lines) if lines else "  无明显重叠"

    pf_stats = bt.get("portfolio", {}).get("stats", {})
    hist_stats = hist.get("stats", {})
    max_dd = dd.get("max_drawdown", 0)
    top5_w = sum(h.get("weight", 0) for h in hd.get("rows", [])[:5])

    attention_context = ""
    if isinstance(context, dict) and context.get("type") == "portfolio_attention":
        compact = context.get("data") or {}
        attention_context = f"""

## 本轮对话之前的 Portfolio Attention 结果
{json.dumps(compact, ensure_ascii=False)[:24000]}

如果用户的追问涉及上述结果，必须沿用 Catfolio 已计算的信号、thesis 和 confidence，不要重算数字。"""

    data = f"""## 用户提问
"{question.strip()}"

## 组合概况
总市值: ${ps.get('market_value_usd', 0):,.0f}
总成本: ${ps.get('total_cost_usd_standard', 0):,.0f}
未实现盈亏: ${ps.get('unrealized_usd', 0):,.0f}
持仓数: {ps.get('trading212_positions', 0)}
前5大持仓占比: {_fmt_pct(top5_w)}

## 持仓明细
{_h()}

## 行业分布
{_sectors()}

## 因子暴露
{_factors()}

## 基准对比
{_benchmarks()}

## 组合统计
年化收益: {_fmt_pct(pf_stats.get('annual_return') or hist_stats.get('annual_return'))}
年化波动: {_fmt_pct(pf_stats.get('annual_volatility') or hist_stats.get('annual_volatility'))}
Sharpe: {_fmt_num(pf_stats.get('sharpe') or hist_stats.get('sharpe'))}
最大回撤: {_fmt_pct(max_dd)}

## ETF穿透
{_etf_overlap()}{attention_context}"""

    prompt = f"""{data}

请用中文回答用户的问题。要求：
- 直接给结论，不要客套话
- 基于数据给出具体分析，能估算的给出数字
- 不推荐买卖，只分析现状和影响
- 3-5句话，简明有力
- 如果问题涉及调仓影响，分析后果但不推荐具体操作"""

    text = _deepseek([
        {"role": "system", "content": "你是投资组合分析师。基于数据回答用户问题，直接给结论，不推荐买卖。中文，简短有力。"},
        {"role": "user", "content": prompt},
    ], temperature=0.3, max_tokens=700, lang=lang)

    return {"answer": text.strip(), "question": question.strip()}


def returns_explanation(lang: str | None = None):
    """AI Benchmark Comparison — 用简单的话解释收益对比数据."""
    twr = cumulative_vs_benchmark("SPY")
    multi = cumulative_multi_benchmark()
    monthly = monthly_return_heatmap()

    # TWR summary
    twr_rows = twr.get("rows", [])
    twr_start = twr_rows[0] if twr_rows else {}
    twr_end = twr_rows[-1] if twr_rows else {}
    twr_start_date = twr.get("date_range", {}).get("start", "—")
    twr_end_date = twr.get("date_range", {}).get("end", "—")

    # Multi-benchmark summary
    bm_list = multi.get("benchmarks", [])
    pf_final = multi.get("portfolio_final_return", 0)
    bm_lines = []
    for b in bm_list:
        excess = (b.get("final_return", 0) or 0) - (pf_final or 0)
        bm_lines.append(
            f"  {b.get('symbol')} ({b.get('label')}): 累计收益={_fmt_pct(b.get('final_return'))}, "
            f"组合超额={'+' if excess >= 0 else ''}{_fmt_pct(excess)}"
        )

    # Monthly returns for context
    monthly_rows = monthly.get("rows", [])[-12:] if monthly.get("rows") else []
    monthly_lines = []
    for m in monthly_rows:
        monthly_lines.append(f"  {m.get('month')}: {_fmt_pct(m.get('return'))}")

    prompt = f"""你是一位投资顾问，擅长把复杂数据用简单的话解释给普通投资者。

## 收益对比数据
数据区间: {twr_start_date} 至 {twr_end_date}
基准: SPY (标普500)

组合累计收益: {_fmt_pct(pf_final)}
SPY累计收益: {_fmt_pct(twr_end.get('benchmark'))}

## 所有基准对比
{chr(10).join(bm_lines)}

## 最近12个月月度收益
{chr(10).join(monthly_lines) if monthly_lines else "  月度数据暂缺"}

## 数据说明
- "TWR" = Time-Weighted Return，剔除了入金出金影响，纯衡量策略表现
- 组合收益是基于当前持仓权重的历史回看，不是真实账户收益

请用中文简单解释：
1. 组合相比基准表现如何？
2. 跑赢还是跑输？主要在哪些阶段？
3. 组合的收益特征是什么（偏进攻/偏防守/波动大/稳健）？
4. 有什么值得注意的问题？

用简单的话，像跟朋友聊天一样，3-5句话。不要堆数据，直接给结论。"""

    text = _deepseek([
        {"role": "system", "content": "你是投资顾问，用简单直白的中文解释数据，不堆砌数字，直接给结论。"},
        {"role": "user", "content": prompt},
    ], temperature=0.4, max_tokens=500, lang=lang)

    return {"explanation": text.strip(), "period": f"{twr_start_date} ~ {twr_end_date}"}
