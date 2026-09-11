"""Display source chart observations without interpreting them as PIT forecasts."""
import json
from html import escape
from pathlib import Path
from fastapi import APIRouter, HTTPException, Request
from app.components import render_layout
from fastapi.responses import HTMLResponse
router = APIRouter()
CATALOG = Path(__file__).resolve().parents[3] / 'CatfolioIOS/CatfolioIOS/Resources/analyst_history_catalog.json'

def entry_for(symbol: str):
    try:
        entries = json.loads(CATALOG.read_text())['entries']
    except (OSError, ValueError):
        raise HTTPException(503, '历史快照暂不可用。')
    entry = entries.get(symbol.strip().upper())
    if not entry:
        raise HTTPException(404, '尚未采集该证券的历史数据。')
    return entry

@router.get('/api/price-target-history')
def history(symbol: str = 'AAPL'):
    e = entry_for(symbol)
    records = [dict(chartDateLabel=p['date'], sourceChartSharePrice=p['price'], targetLow=p['low'], targetConsensus=p['mean'], targetHigh=p['high']) for p in e['points']]
    return dict(records=records, sourceURL=e['sourceURL'], retrievedAt=e['retrievedOn'], status=e['status'], warnings=e['warnings'], symbol=e['symbol'])

@router.get('/api/ratings-history')
def ratings_history(symbol: str = 'AAPL'):
    e = entry_for(symbol)
    rows = [dict(chartDateLabel=p['date'], sourceChartSharePrice=p['price'], Sell=p['sell'], Hold=p['hold'], Buy=p['buy'], StrongBuy=p['strongBuy'], TotalRatings=p['sell']+p['hold']+p['buy']+p['strongBuy']) for p in e['points'] if p['sell'] is not None]
    return dict(records=rows, sourceURL=e['sourceURL'], retrievedOn=e['retrievedOn'], status=e['status'], evaluationEligible=False)

BODY = '''<main class="pt-page"><header class="v4-hero"><div><a href="/lab" class="pt-back">← 返回持仓</a><p class="pt-eyebrow">APPLE INC. / NASDAQ: AAPL</p><h1>苹果公司每月股价目标</h1><p class="pt-muted">股价与市场预期，放在同一条时间线上。</p></div><span class="pt-badge">真实数据 · 本地 Demo</span></header>
<section class="v4-card pt-card"><div class="pt-top"><div><h2>股价与共识目标价</h2><p id="pt-status" role="status">正在读取历史数据…</p></div><div class="segmented-control" aria-label="图表时间范围"><button class="btn" data-range="12" aria-pressed="false">1 年</button><button class="btn" data-range="24" aria-pressed="false">2 年</button><button class="btn" data-range="all" aria-pressed="true">全部</button></div></div>
<div class="pt-metrics" id="pt-metrics"></div><div id="pt-chart" role="img" aria-label="苹果历史股价、共识目标价和最低至最高目标价范围"></div>
<div class="pt-legend"><span><i class="pt-price"></i>股价（来源图表）</span><span><i class="pt-consensus"></i>共识目标价</span><span><i class="pt-band"></i>最低—最高目标价</span></div>
<p class="pt-hint">悬停或点按图表查看当期数值 · 单位 USD</p></section>
<section class="v4-card pt-card" id="monthly-ratings"><div class="pt-top"><div><h2>苹果公司分析师每月推荐建议</h2><p id="ratings-status" role="status">正在读取推荐建议…</p></div><div class="segmented-control" aria-label="推荐建议时间范围"><button class="btn" data-rating-range="12" aria-pressed="false">1 年</button><button class="btn" data-rating-range="24" aria-pressed="false">2 年</button><button class="btn" data-rating-range="all" aria-pressed="true">全部</button></div></div><div class="pt-metrics" id="ratings-metrics"></div><div id="ratings-chart" role="img" aria-label="苹果每月卖出、持有、买入、强烈买入评级数量堆叠柱状图，叠加右轴美元股价"></div><p class="pt-hint">左轴：评级数量 · 右轴：股价（USD） · 悬停或点按查看各类评级与股价</p><p class="pt-muted ratings-note">每根柱子代表该月份对应的过去一年评级分布，并非当月新增建议。股价沿用上图同一来源的月度数据，按日期标签精确匹配，不补齐缺失值。</p><details><summary>查看推荐建议原始数值</summary><div class="pt-table"><table><thead><tr><th>日期标签</th><th>卖出</th><th>持有</th><th>买入</th><th>强烈买入</th><th>合计</th><th>股价</th></tr></thead><tbody id="ratings-rows"></tbody></table></div></details></section>
<section class="v4-card pt-notes"><div><h3>关于这组数据</h3><p>保留 MarketBeat 原始图表日期和数值，月度股价并非当日收盘价。最新日期标签单独保留。月份统计窗口与拆股调整口径尚未确认，本图用于历史展示，不计算预测准确率。</p></div><p id="pt-source"></p><details><summary>查看每期原始数值</summary><div class="pt-table"><table><thead><tr><th>来源日期标签</th><th>图表股价</th><th>共识目标价</th><th>最低目标价</th><th>最高目标价</th></tr></thead><tbody id="pt-rows"></tbody></table></div></details></section></main><script src="/static/vendor/echarts.min.js"></script><script src="/static/price-target-history.js"></script><script src="/static/ratings-history.js"></script>'''

@router.get('/price-target-history', response_class=HTMLResponse)
def page(request: Request, symbol: str = 'AAPL', currency: str = 'USD'):
    symbol = symbol.strip().upper()
    try:
        e = entry_for(symbol)
    except HTTPException:
        e = None
    if not e or not e['points'] or (currency and currency.upper() != e['currency']):
        reason = '该证券尚未采集。' if not e else {'UNSUPPORTED_LISTING': '该上市市场暂不支持，未使用其他市场的同名股票数据。', 'FETCH_FAILED': '来源抓取失败，尚未取得可用历史数据。', 'NO_COVERAGE': '来源暂无分析师历史覆盖。'}.get(e['status'], '暂无可用数据，或报价币种不匹配。')
        content = f'<main class="pt-page"><header class="v4-hero"><h1>{escape(symbol)} · 历史分析</h1></header><section class="v4-card pt-notes"><h2>暂无该证券的历史数据</h2><p>{reason}</p><a href="/lab">返回持仓</a></section></main>'
        return render_layout(request, f'{escape(symbol)} · 历史分析', content, '/price-target-history', 'zh', head_extra='<link rel="stylesheet" href="/static/price-target-history.css">')
    body = BODY.replace('苹果公司', escape(symbol)).replace('苹果', escape(symbol)).replace('APPLE INC. / NASDAQ: AAPL', escape(e['name'] + ' / ' + e['exchange'] + ': ' + symbol))
    return render_layout(request, f'{escape(symbol)} · 历史分析', body, '/price-target-history', 'zh', head_extra='<link rel="stylesheet" href="/static/price-target-history.css">')
