"""Strategy Lab: free-Python strategy backtesting with saved run history."""
from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import HTMLResponse

from app.components import wrap_v4_layout
from app.i18n import get_lang
from app.strategy_engine import run_backtest
from app import strategy_store

router = APIRouter(tags=["strategy"])


DEFAULT_CODE = '''# 在每个调仓日返回目标权重 dict（合计 <= 1，余下为现金）。
# 可用：ctx.universe、ctx.date、ctx.price(t)、ctx.history(t, n)、
#       ctx.sma(t, n)、ctx.momentum(t, n)
def strategy(ctx):
    # 示例：等权持有过去 60 日动量为正的标的
    picks = [t for t in ctx.universe if (ctx.momentum(t, 60) or 0) > 0]
    if not picks:
        return {}            # 全部空仓（现金）
    w = 1.0 / len(picks)
    return {t: w for t in picks}
'''

TEMPLATES = {
    "momentum": DEFAULT_CODE,
    "equal": '''# 等权买入持有所有标的
def strategy(ctx):
    n = len(ctx.universe)
    return {t: 1.0 / n for t in ctx.universe}
''',
    "sma": '''# 价格在 200 日均线之上才持有，等权（趋势择时）
def strategy(ctx):
    picks = [t for t in ctx.universe
             if ctx.price(t) and ctx.sma(t, 200) and ctx.price(t) > ctx.sma(t, 200)]
    if not picks:
        return {}
    w = 1.0 / len(picks)
    return {t: w for t in picks}
''',
    "topn": '''# 选过去 120 日动量最强的前 2 只，等权
def strategy(ctx):
    scored = sorted(((ctx.momentum(t, 120) or -9, t) for t in ctx.universe), reverse=True)
    picks = [t for s, t in scored[:2] if s > 0]
    if not picks:
        return {}
    w = 1.0 / len(picks)
    return {t: w for t in picks}
''',
}


# ── API ────────────────────────────────────────────────────────────────────────

@router.post("/api/strategy/run")
def api_run(payload: dict):
    code = (payload.get("code") or "").strip()
    if not code:
        raise HTTPException(status_code=400, detail="策略代码不能为空。")
    config = {
        "universe": payload.get("universe") or [],
        "benchmark": payload.get("benchmark") or "SPY",
        "capital": payload.get("capital") or 10000,
        "fee_bps": payload.get("fee_bps") or 0,
        "rebalance": payload.get("rebalance") or "monthly",
        "start": payload.get("start") or "",
        "end": payload.get("end") or "",
    }
    try:
        result = run_backtest(code, config)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"{type(exc).__name__}: {exc}")
    run_id = strategy_store.save_run(payload.get("name") or "未命名回测", code, result)
    return {"run_id": run_id, "result": result}


@router.get("/api/strategy/runs")
def api_runs():
    return {"runs": strategy_store.list_runs()}


@router.get("/api/strategy/runs/{run_id}")
def api_run_detail(run_id: int):
    run = strategy_store.get_run(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="找不到该回测记录。")
    return run


@router.delete("/api/strategy/runs/{run_id}")
def api_run_delete(run_id: int):
    if not strategy_store.delete_run(run_id):
        raise HTTPException(status_code=404, detail="找不到该回测记录。")
    return {"ok": True}


def _evaluate_run(run):
    """Ask DeepSeek to critically evaluate a saved backtest run; returns text."""
    from collections import defaultdict
    from app.ai import _deepseek

    m = run.get("metrics") or {}
    res = run.get("result") or {}
    bm = res.get("benchmark_metrics") or {}
    cfg = res.get("config") or {}
    trades = res.get("trades") or []

    count = defaultdict(int)
    wsum = defaultdict(float)
    for t in trades:
        for tk, w in (t.get("weights") or {}).items():
            count[tk] += 1
            wsum[tk] += w
    alloc = "\n".join(
        f"- {tk}: 出现 {count[tk]}/{len(trades)} 次, 平均权重 {wsum[tk] / count[tk] * 100:.0f}%"
        for tk in sorted(count, key=lambda k: wsum[k], reverse=True)
    ) or "（全程空仓）"

    def pct(v):
        return "—" if v is None else f"{v * 100:.1f}%"

    summary = f"""策略代码：
{run.get('code', '')}

回测配置：标的 {cfg.get('universe')}，基准 {cfg.get('benchmark')}，区间 {cfg.get('start')}~{cfg.get('end')}（{cfg.get('trading_days')} 交易日），调仓 {cfg.get('rebalance')}，费率 {cfg.get('fee_bps')}bps，初始资金 {cfg.get('capital')}

策略业绩：总收益 {pct(m.get('total_return'))}，年化 {pct(m.get('cagr'))}，年化波动 {pct(m.get('vol'))}，夏普 {m.get('sharpe')}，最大回撤 {pct(m.get('max_drawdown'))}
基准业绩：总收益 {pct(bm.get('total_return'))}，年化 {pct(bm.get('cagr'))}
调仓次数：{len(trades)}
标的配置统计：
{alloc}"""

    messages = [
        {"role": "system", "content": (
            "你是严谨的量化策略审阅者。基于回测结果客观评价这个策略，重点：1)超额收益是否可能来自过拟合、"
            "个别标的(如单一暴涨股)或样本期运气；2)风险特征(回撤/波动/集中度)；3)相对基准是否有真实价值；"
            "4)潜在缺陷与盲点(前视偏差、幸存者偏差、样本期特殊性、未含滑点等)。不预测未来、不构成投资建议。"
            "用中文，分点输出，每点一句话，先给一句总体结论。"
        )},
        {"role": "user", "content": summary},
    ]
    return _deepseek(messages, temperature=0.4, max_tokens=900)


@router.post("/api/strategy/runs/{run_id}/evaluate")
def api_run_evaluate(run_id: int):
    run = strategy_store.get_run(run_id)
    if not run:
        raise HTTPException(status_code=404, detail="找不到该回测记录。")
    try:
        text = _evaluate_run(run)
    except RuntimeError as exc:        # e.g. DEEPSEEK_API_KEY missing
        raise HTTPException(status_code=400, detail=str(exc))
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"{type(exc).__name__}: {exc}")
    strategy_store.save_ai_eval(run_id, text)
    return {"ai_eval": text}


@router.get("/api/strategy/holdings-universe")
def api_holdings_universe(top: int = 10):
    """Top current holdings (by USD cost) as Yahoo symbols, for one-click universe import."""
    from app.data_store import current_snapshot
    holdings = current_snapshot()["portfolio"].get("holdings", [])
    ranked = sorted(holdings, key=lambda h: float(h.get("cost_usd_standard") or 0), reverse=True)
    symbols = []
    for h in ranked:
        sym = h.get("yahoo_symbol") or h.get("ticker")
        if sym and sym not in symbols:
            symbols.append(sym)
        if len(symbols) >= top:
            break
    return {"symbols": symbols}


# ── Page ─────────────────────────────────────────────────────────────────────

@router.get("/strategy")
def strategy_page(request: Request):
    content = """
<div class="v4-hero">
  <div class="v4-hero-text">
    <h1><i class="fa-solid fa-vials"></i> 策略回测</h1>
    <p>用 Python 写策略，对任意股票回测，每次运行自动保存为一条记录，可随时回看对比。</p>
  </div>
</div>

<div class="strat-layout" style="display:grid;grid-template-columns:260px minmax(0,1fr);gap:var(--sp-lg);margin-top:var(--sp-lg);">

  <!-- History sidebar -->
  <aside class="v4-card" style="padding:var(--sp-base);align-self:start;">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:var(--sp-md);">
      <strong style="font-size:13px;">历史回测</strong>
      <button class="btn" onclick="newRun()" style="height:28px;padding:0 10px;"><i class="fa-solid fa-plus"></i> 新建</button>
    </div>
    <div id="runList" style="display:flex;flex-direction:column;gap:6px;"></div>
  </aside>

  <!-- Main -->
  <div style="display:flex;flex-direction:column;gap:var(--sp-lg);min-width:0;">

    <div class="v4-card">
      <div class="v4-card-header"><div><h2 class="v4-card-title">策略与参数</h2></div>
        <button id="runBtn" class="btn primary" onclick="runBacktest()"><i class="fa-solid fa-play"></i> 运行回测</button>
      </div>

      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:var(--sp-md);margin-bottom:var(--sp-md);">
        <label class="strat-field">回测名称<input id="f_name" placeholder="我的策略" /></label>
        <label class="strat-field">标的（逗号分隔）<input id="f_universe" value="AAPL, MSFT, NVDA, SPY" /></label>
        <label class="strat-field">基准<input id="f_benchmark" value="SPY" /></label>
        <label class="strat-field">初始资金<input id="f_capital" type="number" value="10000" /></label>
        <label class="strat-field">调仓频率
          <select id="f_rebalance"><option value="monthly">每月</option><option value="weekly">每周</option><option value="daily">每日</option></select>
        </label>
        <label class="strat-field">费率(bps)<input id="f_fee" type="number" value="5" /></label>
        <label class="strat-field">开始日期<input id="f_start" placeholder="YYYY-MM-DD（可空）" /></label>
        <label class="strat-field">结束日期<input id="f_end" placeholder="YYYY-MM-DD（可空）" /></label>
      </div>

      <div style="display:flex;gap:12px;align-items:center;margin-bottom:8px;flex-wrap:wrap;">
        <label class="strat-field" style="flex-direction:row;align-items:center;gap:6px;">策略模板
          <select id="f_template" onchange="applyTemplate()">
            <option value="momentum">动量轮动（默认）</option>
            <option value="equal">等权买入持有</option>
            <option value="sma">200 日均线择时</option>
            <option value="topn">动量前 2 强</option>
          </select>
        </label>
        <button class="btn" onclick="importHoldings()" style="height:30px;"><i class="fa-solid fa-download"></i> 从持仓导入标的</button>
      </div>
      <textarea id="f_code" spellcheck="false"></textarea>
      <div id="runStatus" style="margin-top:8px;font-size:12px;min-height:16px;"></div>
    </div>

    <div id="resultCard" class="v4-card" style="display:none;">
      <div class="v4-card-header"><div><h2 class="v4-card-title" id="resultTitle">回测结果</h2>
        <div class="v4-card-subtitle" id="resultRange"></div></div></div>
      <div id="metricCards" style="display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:var(--sp-md);margin-bottom:var(--sp-base);"></div>
      <div id="equityChart" style="height:300px;"></div>
      <div style="font-size:11px;color:var(--muted);font-weight:650;margin:12px 0 2px;">回撤 (Drawdown)</div>
      <div id="drawdownChart" style="height:150px;"></div>
      <div id="resultWarnings" style="margin-top:10px;font-size:12px;color:var(--warn);"></div>
      <details style="margin-top:var(--sp-base);">
        <summary style="cursor:pointer;font-size:13px;font-weight:650;color:var(--ink);">调仓明细 <span id="tradeCount" style="color:var(--muted);font-weight:400;"></span></summary>
        <div id="tradeTableWrap" style="margin-top:10px;max-height:320px;overflow:auto;"></div>
      </details>

      <div style="margin-top:var(--sp-base);border-top:1px solid var(--line);padding-top:var(--sp-base);">
        <div style="display:flex;justify-content:space-between;align-items:center;">
          <strong style="font-size:13px;"><i class="fa-solid fa-robot" style="color:var(--accent);"></i> AI 评价</strong>
          <button id="aiEvalBtn" class="btn" onclick="evaluateRun()" style="height:30px;"><i class="fa-solid fa-wand-magic-sparkles"></i> 生成评价</button>
        </div>
        <div id="aiEvalBox" style="margin-top:10px;font-size:13px;line-height:1.75;color:var(--ink-secondary);white-space:pre-wrap;"></div>
      </div>
    </div>

  </div>
</div>

<style>
  .strat-field { display:flex; flex-direction:column; gap:4px; font-size:11px; color:var(--muted); font-weight:600; }
  .strat-field input, .strat-field select {
    height:34px; padding:0 10px; border:1px solid var(--line); border-radius:var(--radius-md);
    background:var(--soft); color:var(--ink); font-size:13px; font-family:var(--font-sans);
  }
  #f_code {
    width:100%; min-height:300px; box-sizing:border-box; resize:vertical;
    background:var(--bg); color:var(--ink); border:1px solid var(--line); border-radius:var(--radius-md);
    padding:14px; font-family:var(--font-mono); font-size:13px; line-height:1.6; tab-size:4;
  }
  .run-item { padding:8px 10px; border:1px solid var(--line); border-radius:var(--radius-md); cursor:pointer; background:var(--soft); }
  .run-item:hover { border-color:var(--line-strong); }
  .run-item.active { border-color:var(--accent); background:var(--accent-soft); }
  .run-item .rn { font-size:12px; font-weight:650; color:var(--ink); display:flex; justify-content:space-between; gap:6px; }
  .run-item .rm { font-size:11px; color:var(--muted); margin-top:3px; }
  .run-del { color:var(--muted); cursor:pointer; }
  .run-del:hover { color:var(--negative); }
  .metric-box { background:var(--soft); border:1px solid var(--line); border-radius:var(--radius-lg); padding:12px 14px; }
  .metric-box .ml { font-size:11px; color:var(--muted); font-weight:650; }
  .metric-box .mv { font-size:20px; font-weight:720; margin-top:4px; font-family:var(--font-mono); }
</style>

<script src="/static/vendor/echarts.min.js"></script>
<script>
  const $ = id => document.getElementById(id);
  const TEMPLATES = __TEMPLATES__;
  $("f_code").value = TEMPLATES.momentum;
  let equityChart = null, ddChart = null, activeRunId = null, themeReady = false;

  function applyTemplate() {
    const t = TEMPLATES[$("f_template").value];
    if (t) $("f_code").value = t;
  }
  async function importHoldings() {
    const status = $("runStatus");
    status.style.color = "var(--muted)"; status.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 读取持仓…';
    try {
      const data = await (await fetch("/api/strategy/holdings-universe?top=10")).json();
      if (data.symbols && data.symbols.length) {
        $("f_universe").value = data.symbols.join(", ");
        status.style.color = "var(--positive)"; status.innerHTML = '<i class="fa-solid fa-check"></i> 已导入 ' + data.symbols.length + ' 只标的';
      } else { status.innerHTML = "没有可导入的持仓"; }
    } catch (e) { status.style.color = "var(--negative)"; status.innerHTML = "导入失败"; }
  }

  function ensureTheme() {
    if (themeReady || !window.echarts) return;
    const axisDef = { axisLine:{lineStyle:{color:"rgba(128,128,128,0.28)"}}, splitLine:{lineStyle:{color:"rgba(128,128,128,0.14)"}} };
    window.echarts.registerTheme("helm", { categoryAxis: axisDef, valueAxis: axisDef });
    themeReady = true;
  }
  const fmtPct = v => (v === null || v === undefined) ? "—" : (v*100).toFixed(1) + "%";
  const fmtNum = v => (v === null || v === undefined) ? "—" : Number(v).toFixed(2);
  const fmtDate = ts => new Date(ts*1000).toLocaleDateString("zh-CN", {month:"short", day:"numeric", hour:"2-digit", minute:"2-digit"});

  async function loadRuns() {
    const res = await fetch("/api/strategy/runs");
    const data = await res.json();
    const el = $("runList");
    if (!data.runs.length) { el.innerHTML = '<div style="font-size:12px;color:var(--muted);">还没有回测记录</div>'; return; }
    el.innerHTML = data.runs.map(r => {
      const cagr = r.metrics && r.metrics.cagr != null ? fmtPct(r.metrics.cagr) : "—";
      return '<div class="run-item ' + (r.id===activeRunId?'active':'') + '" onclick="loadRun(' + r.id + ')">' +
        '<div class="rn"><span>' + escapeHtml(r.name) + '</span><span class="run-del" onclick="event.stopPropagation();delRun(' + r.id + ')"><i class="fa-solid fa-trash"></i></span></div>' +
        '<div class="rm">CAGR ' + cagr + ' · ' + fmtDate(r.created_at) + '</div></div>';
    }).join("");
  }
  function escapeHtml(s){ return String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

  function gatherConfig() {
    return {
      name: $("f_name").value,
      code: $("f_code").value,
      universe: $("f_universe").value.split(",").map(s=>s.trim()).filter(Boolean),
      benchmark: $("f_benchmark").value.trim(),
      capital: Number($("f_capital").value),
      fee_bps: Number($("f_fee").value),
      rebalance: $("f_rebalance").value,
      start: $("f_start").value.trim(),
      end: $("f_end").value.trim(),
    };
  }

  async function runBacktest() {
    const btn = $("runBtn"), status = $("runStatus");
    btn.disabled = true; status.style.color = "var(--muted)";
    status.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 正在拉取历史并回测…';
    try {
      const res = await fetch("/api/strategy/run", { method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify(gatherConfig()) });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || "回测失败");
      status.style.color = "var(--positive)"; status.innerHTML = '<i class="fa-solid fa-check"></i> 完成';
      activeRunId = data.run_id;
      renderResult(data.result, gatherConfig().name || "回测结果");
      await loadRuns();
    } catch (err) {
      status.style.color = "var(--negative)"; status.innerHTML = '<i class="fa-solid fa-xmark"></i> ' + escapeHtml(err.message);
    } finally { btn.disabled = false; }
  }

  function metricBox(label, value, cls) {
    return '<div class="metric-box"><div class="ml">' + label + '</div><div class="mv" style="color:' + (cls||'var(--ink)') + '">' + value + '</div></div>';
  }

  async function evaluateRun() {
    if (!activeRunId) { return; }
    const btn = $("aiEvalBtn"), box = $("aiEvalBox");
    btn.disabled = true; box.style.color = "var(--muted)";
    box.textContent = "AI 正在分析回测结果…";
    try {
      const res = await fetch("/api/strategy/runs/" + activeRunId + "/evaluate", { method: "POST" });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || "评价失败");
      box.style.color = "var(--ink-secondary)"; box.textContent = data.ai_eval;
      loadRuns();
    } catch (e) { box.style.color = "var(--negative)"; box.textContent = e.message; }
    finally { btn.disabled = false; }
  }

  function renderResult(result, name, aiEval) {
    $("resultCard").style.display = "block";
    $("resultTitle").textContent = name;
    const c = result.config || {};
    $("resultRange").textContent = c.start + " → " + c.end + " · " + c.trading_days + " 个交易日 · 调仓 " + c.rebalance;
    const m = result.metrics || {}, bm = result.benchmark_metrics || {};
    const sign = v => v == null ? "var(--ink)" : (v >= 0 ? "var(--positive)" : "var(--negative)");
    $("metricCards").innerHTML =
      metricBox("总收益", fmtPct(m.total_return), sign(m.total_return)) +
      metricBox("年化 (CAGR)", fmtPct(m.cagr), sign(m.cagr)) +
      metricBox("年化波动", fmtPct(m.vol)) +
      metricBox("夏普", fmtNum(m.sharpe)) +
      metricBox("最大回撤", fmtPct(m.max_drawdown), "var(--negative)") +
      metricBox("基准(" + result.benchmark + ") 总收益", fmtPct(bm.total_return), sign(bm.total_return));

    ensureTheme();
    if (equityChart) equityChart.dispose();
    equityChart = window.echarts.init($("equityChart"), "helm");
    const dates = result.equity.map(e => e.date);
    equityChart.setOption({
      backgroundColor: "transparent",
      tooltip: { trigger: "axis" },
      legend: { bottom: 0, textStyle: { color: "#9ca3af" } },
      grid: { left: 56, right: 18, top: 16, bottom: 40 },
      xAxis: { type: "category", data: dates, axisLabel: { color: "#9ca3af" } },
      yAxis: { type: "value", scale: true, axisLabel: { color: "#9ca3af" } },
      series: [
        { name: "策略", type: "line", showSymbol: false, data: result.equity.map(e=>e.nav), lineStyle:{width:2.2,color:"#5e6ad2"}, itemStyle:{color:"#5e6ad2"} },
        { name: "基准 " + result.benchmark, type: "line", showSymbol: false, data: result.benchmark_equity.map(e=>e.nav), lineStyle:{width:1.5,color:"#888",opacity:0.85}, itemStyle:{color:"#888"} },
      ],
    });
    // drawdown (underwater) chart
    if (ddChart) ddChart.dispose();
    ddChart = window.echarts.init($("drawdownChart"), "helm");
    ddChart.setOption({
      backgroundColor: "transparent",
      tooltip: { trigger: "axis", valueFormatter: v => (v*100).toFixed(1) + "%" },
      grid: { left: 56, right: 18, top: 10, bottom: 24 },
      xAxis: { type: "category", data: (result.drawdown||[]).map(e=>e.date), axisLabel: { color: "#9ca3af" } },
      yAxis: { type: "value", axisLabel: { color: "#9ca3af", formatter: v => (v*100).toFixed(0) + "%" } },
      series: [{ type: "line", showSymbol: false, data: (result.drawdown||[]).map(e=>e.dd), areaStyle: { opacity: 0.18 }, lineStyle: { width: 1.2 }, itemStyle: { color: "#e54d5e" } }],
    });

    // allocation / rebalance detail table
    const trades = result.trades || [];
    $("tradeCount").textContent = "(" + trades.length + " 次)";
    if (!trades.length) {
      $("tradeTableWrap").innerHTML = '<div style="font-size:12px;color:var(--muted);">该策略全程空仓</div>';
    } else {
      const rows = trades.slice().reverse().map(tr => {
        const alloc = Object.entries(tr.weights).sort((a,b)=>b[1]-a[1])
          .map(([t,w]) => '<span style="display:inline-block;background:var(--accent-soft);color:var(--accent);border-radius:4px;padding:1px 7px;margin:1px 3px 1px 0;font-size:11px;">' + escapeHtml(t) + ' ' + (w*100).toFixed(0) + '%</span>').join("");
        return '<tr><td style="padding:6px 10px;color:var(--muted);font-family:var(--font-mono);white-space:nowrap;">' + tr.date + '</td><td style="padding:6px 10px;">' + alloc + '</td></tr>';
      }).join("");
      $("tradeTableWrap").innerHTML = '<table style="width:100%;border-collapse:collapse;font-size:12px;"><thead><tr><th style="text-align:left;padding:6px 10px;color:var(--muted);font-weight:600;border-bottom:1px solid var(--line);">调仓日</th><th style="text-align:left;padding:6px 10px;color:var(--muted);font-weight:600;border-bottom:1px solid var(--line);">目标持仓</th></tr></thead><tbody>' + rows + '</tbody></table>';
    }

    $("resultWarnings").innerHTML = (result.warnings && result.warnings.length) ? ("注意：" + result.warnings.map(escapeHtml).join("；")) : "";
    $("aiEvalBox").style.color = "var(--ink-secondary)";
    $("aiEvalBox").textContent = aiEval || "";
  }

  async function loadRun(id) {
    const res = await fetch("/api/strategy/runs/" + id);
    if (!res.ok) return;
    const run = await res.json();
    activeRunId = id;
    $("f_name").value = run.name;
    $("f_code").value = run.code;
    const c = run.config || {};
    $("f_universe").value = (c.universe||[]).join(", ");
    $("f_benchmark").value = c.benchmark || "SPY";
    $("f_capital").value = c.capital || 10000;
    $("f_fee").value = c.fee_bps || 0;
    $("f_rebalance").value = c.rebalance || "monthly";
    renderResult(run.result, run.name, run.ai_eval);
    loadRuns();
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  async function delRun(id) {
    await fetch("/api/strategy/runs/" + id, { method:"DELETE" });
    if (activeRunId === id) activeRunId = null;
    loadRuns();
  }

  function newRun() {
    activeRunId = null;
    $("resultCard").style.display = "none";
    $("runStatus").innerHTML = "";
    loadRuns();
  }

  loadRuns();
</script>
""".replace("__TEMPLATES__", _js_templates())
    return HTMLResponse(wrap_v4_layout("策略回测", content, "/strategy", get_lang(request)))


def _js_templates():
    """Return the strategy templates as a JS object literal."""
    import json
    return json.dumps(TEMPLATES)
