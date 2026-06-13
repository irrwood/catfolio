"""Page route: returns."""
import json
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from app.components import wrap_v4_layout
from app.i18n import get_lang
from app.lab import BENCHMARKS, cash_flow_mirror_vs_benchmark, cumulative_multi_benchmark, cumulative_vs_benchmark, monthly_return_heatmap, drawdown_curve, return_distribution, monthly_contribution_waterfall

router = APIRouter(tags=["pages"])


@router.get("/returns")
def returns_page(request: Request):
    twr_returns = cumulative_vs_benchmark()
    multi_benchmark = cumulative_multi_benchmark()
    cash_flow_benchmarks = {symbol: cash_flow_mirror_vs_benchmark(symbol) for symbol in BENCHMARKS}
    cf_mirror = cash_flow_benchmarks.get("SPY") or cash_flow_mirror_vs_benchmark()

    twr_start = twr_returns.get("date_range", {}).get("start", "—")
    twr_end = twr_returns.get("date_range", {}).get("end", "—")

    # latest values
    twr_rows = twr_returns.get("rows", [])
    latest = twr_rows[-1] if twr_rows else {}
    last_portfolio = latest.get("portfolio", 1.0)
    last_benchmark = latest.get("benchmark", 1.0)
    last_excess = latest.get("excess", 0)

    mb_rows = multi_benchmark.get("rows", [])
    mb_latest = mb_rows[-1] if mb_rows else {}

    bench_summary_rows = ""
    for symbol, label in BENCHMARKS.items():
        val = mb_latest.get(symbol, None)
        if val is None:
            continue
        pct = (val - 1.0) * 100
        excess_pct = ((last_portfolio - 1.0) - (val - 1.0)) * 100
        return_cls = "positive" if pct >= 0 else "negative"
        excess_cls = "positive" if excess_pct > 0 else "negative"
        bench_summary_rows += f"""<tr>
            <td class="font-mono">{symbol}</td>
            <td>{label}</td>
            <td class="{return_cls}">{pct:+.1f}%</td>
            <td class="{excess_cls}">{excess_pct:+.1f}%</td>
        </tr>"""

    multi_json = json.dumps(multi_benchmark, ensure_ascii=False)
    twr_json = json.dumps(twr_returns, ensure_ascii=False)
    cf_json = json.dumps(cf_mirror, ensure_ascii=False)
    cf_benchmarks_json = json.dumps({s: r for s, r in cash_flow_benchmarks.items() if r.get("available")}, ensure_ascii=False)

    content = f"""<div class="returns-page">
<div class="v4-hero">
  <div class="v4-hero-text">
    <h1>收益对比 · Benchmark Comparison</h1>
    <p>组合净值 vs 各大指数基准。TWR (时间加权收益) 剔除现金流影响，衡量策略本身表现。</p>
  </div>
  <div class="btn" style="pointer-events:none"><i class="fa-solid fa-calendar-day"></i> 数据区间：{twr_start} → {twr_end}</div>
  <button id="aiReturnsBtn" class="btn primary" onclick="loadReturnsAI()"><i class="fa-solid fa-robot"></i> AI 解读</button>
</div>

<div id="aiReturnsResult" style="display:none;">
  <div class="v4-card" style="border-color:var(--accent);">
    <div class="v4-card-header">
      <div><h2 class="v4-card-title"><i class="fa-solid fa-robot"></i> AI 收益解读</h2><div class="v4-card-subtitle" id="aiReturnsPeriod"></div></div>
      <span onclick="document.querySelector('#aiReturnsResult').style.display='none'" style="cursor:pointer;color:var(--muted);font-size:18px;">&times;</span>
    </div>
    <div style="padding:12px 16px;"><p id="aiReturnsText" style="font-size:14px;line-height:1.7;margin:0;"></p></div>
  </div>
</div>

<div id="aiReturnsStatus" style="font-size:12px;"></div>

<div class="metrics-grid returns-summary-grid">
  <div class="metric-card">
    <span class="metric-label">组合净值 (TWR)</span>
    <div class="metric-value {("positive" if last_portfolio >= 1.0 else "negative")}">{((last_portfolio - 1.0) * 100):+.1f}%</div>
    <span class="metric-subtext">基准: {twr_returns.get("benchmark", "SPY")}</span>
  </div>
  <div class="metric-card">
    <span class="metric-label">基准净值</span>
    <div class="metric-value {("positive" if last_benchmark >= 1.0 else "negative")}">{((last_benchmark - 1.0) * 100):+.1f}%</div>
    <span class="metric-subtext">{twr_returns.get("benchmark", "SPY")}</span>
  </div>
  <div class="metric-card">
    <span class="metric-label">超额收益 (α)</span>
    <div class="metric-value {("positive" if last_excess >= 0 else "negative")}">{(last_excess * 100):+.1f}%</div>
    <span class="metric-subtext">Portfolio - Benchmark</span>
  </div>
  <div class="metric-card">
    <span class="metric-label">数据说明</span>
    <div class="metric-value" style="font-size:13px;font-family:var(--font-sans);">模型口径</div>
    <span class="metric-subtext">按当前持仓权重回看历史，非现金流口径</span>
  </div>
</div>

<div class="v4-card returns-mode-card">
  <div style="display:flex;align-items:center;gap:12px;">
    <span style="font-size:13px;font-weight:650;color:var(--ink);">收益口径</span>
    <div style="display:inline-flex;background:var(--bg);border-radius:8px;padding:3px;gap:3px;">
      <button id="twrMode" class="active" type="button" style="border:0;border-radius:6px;padding:6px 14px;font-size:12px;font-weight:600;cursor:pointer;background:transparent;color:var(--muted);transition:all 0.15s;">TWR</button>
      <button id="cfMirrorMode" type="button" style="border:0;border-radius:6px;padding:6px 14px;font-size:12px;font-weight:600;cursor:pointer;background:transparent;color:var(--muted);transition:all 0.15s;">现金流镜像</button>
      <button id="costValueMode" type="button" style="border:0;border-radius:6px;padding:6px 14px;font-size:12px;font-weight:600;cursor:pointer;background:transparent;color:var(--muted);transition:all 0.15s;">成本与市值对比</button>
    </div>
  </div>
</div>


<div class="v4-card">
  <div class="v4-card-header">
    <div>
      <h2 class="v4-card-title"><i class="fa-solid fa-chart-line text-accent" style="color:var(--accent)"></i> 累计净值对比 — <span id="chartModeLabel">TWR</span></h2>
      <div class="v4-card-subtitle" id="chartSubtitle">剔除现金流影响，衡量策略本身表现。</div>
    </div>
    <select id="returnsRange" class="snapshot-control" style="height:32px;min-width:100px;max-width:120px;" aria-label="时间范围">
      <option value="all">全部</option>
      <option value="504">2 年</option>
      <option value="252" selected>1 年</option>
      <option value="126">6 月</option>
      <option value="63">3 月</option>
      <option value="21">1 月</option>
    </select>
  </div>
  <div id="returnsChart" style="width:100%;height:420px;"></div>
</div>

<div class="grid-2">
  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><i class="fa-solid fa-table"></i> 各基准表现汇总</h2>
        <div class="v4-card-subtitle">截至最新一致日期的累计收益与超额收益</div>
      </div>
    </div>
    <div class="table-wrap" style="overflow:visible;">
      <table style="min-width:0;">
        <thead>
          <tr><th>代码</th><th>名称</th><th>累计收益</th><th>超额 vs 组合</th></tr>
        </thead>
        <tbody>{bench_summary_rows}</tbody>
      </table>
    </div>
  </div>
  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><i class="fa-solid fa-circle-info"></i> 口径说明</h2>
        <div class="v4-card-subtitle">理解不同收益计算方式</div>
      </div>
    </div>
    <div style="display:flex;flex-direction:column;gap:14px;">
      <div style="padding-bottom:12px;border-bottom:1px solid var(--line);">
        <strong style="display:block;margin-bottom:4px;">TWR (Time-Weighted Return)</strong>
        <span style="font-size:12px;color:var(--muted);">剔除入金/出金影响，纯衡量策略选股表现。适合评价基金经理能力。</span>
      </div>
      <div style="padding-bottom:12px;border-bottom:1px solid var(--line);">
        <strong style="display:block;margin-bottom:4px;">Cash Flow Mirror</strong>
        <span style="font-size:12px;color:var(--muted);">模拟实际账户资金进出时间，更接近真实账户收益体验。</span>
      </div>
      <div>
        <strong style="display:block;margin-bottom:4px;">模型口径 vs 真实收益</strong>
        <span style="font-size:12px;color:var(--muted);">本页数据按当前持仓权重回看历史。不对应历史真实持仓变动和现金流。仅为分析参考。</span>
      </div>
    </div>
  </div>
</div>
</div>

<script src="/static/vendor/lightweight-charts.standalone.production.js"></script>
<script>

  const multiData = {multi_json};
  const twrData = {twr_json};
  const cfData = {cf_json};
  const cfBenchmarks = {cf_benchmarks_json};
</script>
<script src="/static/returns.js"></script>"""
    return HTMLResponse(wrap_v4_layout("收益对比", content, "/returns", get_lang(request), head_extra='<link rel="stylesheet" href="/static/returns.css" />'))
