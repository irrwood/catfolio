"""DCA page and read-only simulation APIs."""
from datetime import date
import json

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import HTMLResponse

from app.components import render_layout
from app.data_store import demo_mode
from app.dca import DCAConfig, clean_prices, observations, simulate
from app.dca_i18n import EN, translate_content
from app.i18n import get_lang
from app.lab import get_history_cached
from app.strategy_engine import get_prices

router = APIRouter(tags=["dca"])


def prices_for(symbol, years=6):
    if demo_mode():
        rows = get_history_cached().get("prices", {}).get(symbol, [])
        if not rows:
            raise HTTPException(404, "演示行情暂不包含该标的，请选择 SPY、QQQ、AAPL、MSFT 或 NVDA")
        return rows, ["当前使用合成演示行情，仅用于体验计算器。"], "合成演示行情"
    prices, warnings = get_prices([symbol], years=years)
    rows = prices.get(symbol, [])
    if not rows:
        raise HTTPException(422, "暂无该标的的历史行情，请检查代码或稍后重试")
    return rows, warnings, "Yahoo Finance · 策略行情缓存"


@router.get("/api/dca/market")
def market(symbol: str = Query(default="SPY", pattern=r"^[A-Za-z]{1,6}(?:[.-][ABab])?$")):
    symbol = symbol.upper().replace(".", "-")
    raw, warnings, source = prices_for(symbol)
    try:
        rows = clean_prices(raw)
    except ValueError as exc:
        raise HTTPException(422, str(exc)) from exc
    if len(rows) < 2:
        raise HTTPException(422, "历史行情不足")
    last = rows[-1]
    last_day = date.fromisoformat(last["date"])
    returns = {}
    for years in (1, 3, 5):
        cutoff = last_day.toordinal() - round(years * 365.25)
        prior = next((r for r in reversed(rows) if date.fromisoformat(r["date"]).toordinal() <= cutoff), None)
        returns[str(years)] = ((last["close"] / prior["close"]) ** (365.25 / (last_day - date.fromisoformat(prior["date"])).days) - 1) if prior else None
    return {"symbol": symbol, "price": last["close"], "as_of": last["date"], "first_date": rows[0]["date"],
            "count": len(rows), "returns": returns, "indicators": observations(rows),
            "source": source, "demo": demo_mode(), "warnings": warnings}


@router.post("/api/dca/backtest")
def backtest(config: DCAConfig):
    years = min(12, max(6, (date.today() - config.start).days / 365.25 + 1))
    rows, warnings, source = prices_for(config.symbol, years)
    try:
        result = simulate(config, rows)
    except (ValueError, KeyError, TypeError) as exc:
        raise HTTPException(422, str(exc)) from exc
    result["warnings"] = warnings + result["warnings"]
    result["source"] = source
    result["demo"] = demo_mode()
    return result


def _range(name, title, minimum, maximum, step, value, unit="", hint=""):
    return f'''<label class="dca-field" for="{name}"><span>{title}<output for="{name}" data-output="{name}" data-unit="{unit}">{value}{unit}</output></span>
      <input id="{name}" name="{name}" type="range" min="{minimum}" max="{maximum}" step="{step}" value="{value}">
      <small>{hint}</small></label>'''


@router.get("/dca", response_class=HTMLResponse)
def dca_page(request: Request):
    content = '''<div class="dca-page">
  <header class="v4-hero"><div class="v4-hero-text"><h1>美股定投计算器</h1><p>让每一次投入，都有自己的节奏。</p></div>
    <a class="btn" href="/strategy">策略回测 ↗</a></header>
  <form id="dcaForm">
    <section class="panel dca-market" aria-label="标的选择">
      <div class="dca-section-head"><h2>选择标的</h2><span class="dca-kicker">DOLLAR-COST AVERAGING</span></div>
      <div class="dca-symbol-row"><label class="dca-symbol-input"><span class="sr-only">美股代码</span><input id="symbol" name="symbol" value="SPY" maxlength="8" placeholder="输入美股代码" aria-label="美股代码" pattern="[A-Za-z]{1,6}([.\\-][A-Za-z])?" required></label>
        <div class="dca-symbols" aria-label="常用标的">'''
    content += "".join(f'<button class="btn" type="button" data-symbol="{symbol}" aria-pressed="{str(symbol == "SPY").lower()}">{symbol}</button>' for symbol in ["SPY", "QQQ", "VTI", "AAPL", "MSFT", "NVDA", "TSLA", "TSM"])
    content += '''</div></div>
      <div class="dca-market-metrics"><div><span>1 年年化收益率</span><strong id="return1">—</strong></div><div><span>3 年年化收益率</span><strong id="return3">—</strong></div><div><span>5 年年化收益率</span><strong id="return5">—</strong></div><div><span>最近收盘价 · USD</span><strong id="latestPrice">—</strong></div></div>
      <p class="dca-note" id="marketStatus" role="status">正在读取历史行情…</p>
    </section>
    <section class="panel dca-parameters">
      <div class="dca-section-head"><div><h2>定投参数</h2><p>从基础金额开始，用规则调整每次投入。</p></div><button class="btn" type="button" id="openConditions">条件配置 <span id="conditionCount">4</span></button></div>
      <div class="dca-form-grid">
        <label class="dca-field" for="initial_cash"><span>初始资金 · USD</span><select id="initial_cash" name="initial_cash"><option value="0">$0</option><option value="5000">$5,000</option><option value="10000" selected>$10,000</option><option value="25000">$25,000</option><option value="50000">$50,000</option><option value="100000">$100,000</option></select><small>作为模拟现金池，按定投计划逐期买入</small></label>'''
    content += _range("base_amount", "Base Amount · 基础投入", 50, 2000, 50, 500, "$", "每期新增入金；加仓可动用现金池")
    content += '''<label class="dca-field" for="frequency"><span>Frequency · 定投频率</span><select id="frequency" name="frequency"><option value="weekly">每周</option><option value="monthly">每月</option></select><small>从起始日计，休市顺延至下个交易日</small></label>
        <label class="dca-field" for="start"><span>起始日期</span><input id="start" name="start" type="date" required><small>可用区间以实际行情为准</small></label>
        <label class="dca-field" for="end"><span>结束日期</span><input id="end" name="end" type="date" required><small>使用已完成的日线数据</small></label>
        <div class="dca-run"><button id="runDca" class="btn primary" type="submit">开始回测 <span aria-hidden="true">↗</span></button><small>对比条件定投与固定定投</small></div>
      </div>
      <div class="dca-rule-summary" id="ruleSummary"></div>
    </section>
  </form>
  <p id="runStatus" class="dca-note" role="status" aria-live="polite">选择标的和参数，查看定投结果。</p>
  <section id="dcaResults" class="panel" aria-label="回测结果">
    <div class="dca-section-head"><h2>回测结果</h2><span id="resultPeriod" class="dca-note">等待首次回测</span></div>
    <div class="dca-primary-metrics"><div><span>定投收益率</span><strong id="totalReturn">—</strong><small>总收益 ÷ 累计入金，包含留存现金</small></div><div><span>期末总收益</span><strong id="totalProfit">—</strong><small>期末总资产 − 累计入金</small></div></div>
    <dl class="dca-result-grid"><div><dt>累计入金</dt><dd id="contributed">—</dd></div><div><dt>期末总资产</dt><dd id="totalValue">—</dd></div><div><dt>年化收益率 · XIRR</dt><dd id="annualReturn">—</dd></div><div><dt>买入次数</dt><dd id="buyCount">—</dd></div><div><dt>持有份额（复权等效）</dt><dd id="shares">—</dd></div><div><dt>持仓市值</dt><dd id="holdings">—</dd></div><div><dt>剩余现金</dt><dd id="cash">—</dd></div><div><dt>最大回撤 · 剔除入金</dt><dd id="maxDrawdown">—</dd></div></dl>
  </section>
  <section class="panel dca-chart-panel"><div class="dca-section-head"><div><h2>资金走势</h2><p>每一笔投入，汇成一条长期曲线。</p></div><div class="risk-tabs dca-chart-tabs" role="group" aria-label="图表内容"><button type="button" class="btn risk-tab active" data-chart="value" aria-pressed="true">资金</button><button type="button" class="btn risk-tab" data-chart="drawdown" aria-pressed="false">回撤</button></div></div>
    <div id="dcaChart" class="dca-chart" role="img" aria-label="定投资金走势图"><p class="dca-empty">完成回测后，查看累计入金、持仓市值与总资产。</p></div>
    <p class="dca-note">悬停查看明细 · 点击图例显示或隐藏 · 拖动底部滑块缩放。固定定投使用相同入金、现金储备和仓位限制，仅不应用信号倍数。</p>
  </section>
  <section class="panel"><div class="dca-section-head"><div><h2>定投明细 <span id="tradeCount" class="dca-note"></span></h2><p>实际买入、资金余额，以及每次调整的原因。</p></div><button id="exportDca" class="btn" type="button" disabled>导出 CSV</button></div>
    <div class="dca-table-scroll"><table class="dca-table"><thead><tr><th>日期</th><th>复权价格</th><th>入金</th><th>实际买入</th><th>实际倍数</th><th>现金余额</th><th>触发原因</th></tr></thead><tbody id="tradeRows"><tr><td colspan="7" class="dca-empty">暂无交易记录</td></tr></tbody></table></div><button id="moreTrades" class="btn dca-more" type="button" hidden>展开全部</button>
  </section>
  <details class="dca-method"><summary>计算口径与规则说明</summary><p>初始资金作为现金池，每期新增基础金额。SMA200 为 200 个交易日收盘均值；RV20 为 20 个对数收益的样本标准差 × √252；ER20 为 20 日净价格变化绝对值 ÷ 每日变化绝对值之和。信号读取前一交易日，按定投日收盘价格模拟买入。</p><p>价格低于区间下限时目标为 2×，高于上限或 RV / ER 条件未满足时优先降至最低倍数。回撤以此前最多 252 个交易日的高点计算；达到所选门槛后，-10% / -20% / -30% 分别对应 1.5× / 2× / 3×，受最高倍数限制。冷却期仅限制实际超过基础金额的加仓。</p><p>现金储备与单一资产仓位均以「模拟持仓市值 + 现金」为分母，只约束新增买入，不主动卖出；资金或仓位不足时实际金额可以低于最低倍数。历史不足时暂停信号买入并保留入金。固定定投不使用信号，仍遵守相同资金上限。</p><p>使用现有策略行情源的复权收盘价（上游缺少复权价时返回原始收盘价），份额为模型等效份额。未计交易费、滑点、税费及现金利息；XIRR 按实际现金流日期计算，少于 30 天不年化。回测为模拟，不连接券商交易。</p></details>
</div>
<dialog id="conditionsDialog" class="dca-dialog" aria-labelledby="conditionsTitle">
  <form id="conditionsForm">
    <div class="dca-dialog-head"><div><h2 id="conditionsTitle">条件配置</h2><p><span id="conditionSymbol">SPY</span> <span>· 调整节奏，保留纪律</span></p></div><button class="btn" type="button" id="closeConditions" aria-label="关闭条件配置">×</button></div>
    <div class="dca-dialog-body">
      <div class="dca-condition-labels"><span>指标 / 周期</span><span>判断与阈值</span><span>最近状态</span></div>
      <div class="dca-condition-row"><label class="dca-condition-name"><input id="sma_enabled" type="checkbox" role="switch" checked><span><b>SMA200</b><small>200 日均线 · Price / SMA200</small></span></label><div class="dca-condition-controls">'''
    content += _range("price_low", "低于时加仓", .7, 1., .01, .85, "×")
    content += _range("price_high", "高于时减量", 1., 1.3, .01, 1.15, "×")
    content += '''</div><div class="dca-current" id="currentSma">—</div></div>
      <div class="dca-condition-row"><label class="dca-condition-name"><input id="rv_enabled" type="checkbox" role="switch" checked><span><b>RV20</b><small>20 日实现波动率 · 年化</small></span></label><div class="dca-condition-controls"><select id="rv_operator" aria-label="RV20 判断"><option value="lte">≤ 不高于</option><option value="gte">≥ 不低于</option></select>'''
    content += _range("rv_threshold", "波动率阈值", 5, 100, 5, 40, "%")
    content += '''</div><div class="dca-current" id="currentRv">—</div></div>
      <div class="dca-condition-row"><label class="dca-condition-name"><input id="er_enabled" type="checkbox" role="switch" checked><span><b>ER20</b><small>20 日效率比 · 0–1</small></span></label><div class="dca-condition-controls"><select id="er_operator" aria-label="ER20 判断"><option value="gte">≥ 不低于</option><option value="lte">≤ 不高于</option></select>'''
    content += _range("er_threshold", "效率比阈值", 0, 1, .05, .3)
    content += '''</div><div class="dca-current" id="currentEr">—</div></div>
      <div class="dca-condition-row"><label class="dca-condition-name"><input id="drawdown_enabled" type="checkbox" role="switch" checked><span><b>Drawdown</b><small>距近 252 个交易日高点</small></span></label><label class="dca-field"><span>开始加仓的回撤门槛</span><select id="drawdown_threshold"><option value="0.1">−10%</option><option value="0.2" selected>−20%</option><option value="0.3">−30%</option></select></label><div class="dca-current" id="currentDrawdown">—</div></div>
      <div class="dca-section-head dca-risk-heading"><div><h3>资金与风险边界</h3><p>资金限制优先于目标投入倍数。</p></div></div><div class="dca-risk-grid">'''
    content += _range("cash_reserve", "Cash Reserve · 现金储备", 20, 40, 5, 30, "%", "买入后至少保留的现金占比")
    content += _range("max_position", "Max Position · 仓位上限", 10, 20, 5, 20, "%", "占模拟总资产的最高买入仓位")
    content += '''<label class="dca-field"><span>Min Multiplier · 最低倍数</span><select id="min_multiplier"><option value="0.25">0.25×</option><option value="0.5" selected>0.5×</option></select><small>高估或条件未满足时的目标倍数</small></label><label class="dca-field"><span>Max Multiplier · 最高倍数</span><select id="max_multiplier"><option value="2">2×</option><option value="3" selected>3×</option></select><small>单次加仓的倍数上限</small></label>'''
    content += _range("cooldown", "Cooldown · 加仓冷却", 3, 7, 1, 7, " 天", "距上一次实际加仓的自然日数")
    content += '''</div><p class="dca-note" id="conditionAsOf">当前指标根据最近可用收盘价计算；历史回测按每个交易日重新判断。</p></div>
    <div class="dca-dialog-footer"><button class="btn" id="resetConditions" type="button">恢复默认</button><div><button class="btn" id="cancelConditions" type="button">取消</button><button class="btn primary" type="submit">应用配置</button></div></div>
  </form>
</dialog>
<script src="/static/vendor/echarts.min.js"></script><script src="/static/dca.js" defer></script>'''
    lang = get_lang(request)
    if lang == "en":
        content = translate_content(content)
        # ASCII JSON survives the shell's legacy phrase replacement unchanged.
        copy = dict(sorted(EN.items(), key=lambda item: len(item[0]), reverse=True))
        content += '<script>window.CATFOLIO_PAGE_I18N = ' + json.dumps(copy) + ';</script>'
    return HTMLResponse(render_layout(request, "美股定投计算器" if lang == "zh" else "US Stock DCA Calculator", content, "/dca", lang,
                                      head_extra='<link rel="stylesheet" href="/static/dca.css" />'))
