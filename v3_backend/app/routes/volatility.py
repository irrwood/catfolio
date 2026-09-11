"""Mobile-first sector sentiment page; all financial derivation belongs to Core."""
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from app.components import render_layout
from app.i18n import get_lang
from app.volatility import snapshot
from app.data_store import current_snapshot, demo_mode
from app.analytics import holdings_by_ticker, market_by_ticker

router = APIRouter(tags=['volatility'])
BODY = '''<main class="volatility-page">
<header class="v4-hero"><div class="v4-hero-text"><p>半导体</p><h1>Fear &amp; Greed</h1></div></header>
<div class="volatility-grid">
<section class="v4-card sentiment-card" aria-labelledby="sentiment-title">
<div class="volatility-heading"><h2 id="sentiment-title">行业情绪</h2><span class="market-status-badge">VXSMH / SMH</span></div>
<p id="volatility-status" role="status">正在读取日线数据…</p>
<div class="sentiment-dial" role="meter" aria-label="Fear & Greed，0 恐惧，100 贪婪" aria-valuemin="0" aria-valuemax="100" id="sentiment-meter"><svg viewBox="0 0 240 140" aria-hidden="true"><path class="dial-track" d="M20 120 A100 100 0 0 1 220 120"/><path id="dial-fill" d="M20 120 A100 100 0 0 1 220 120" pathLength="100"/></svg><div><strong id="sentiment-score">—</strong><span id="sentiment-label">等待数据</span></div></div>
<div class="dial-labels"><span>0 · 极度恐惧</span><span>极度贪婪 · 100</span></div>
<div class="regime-line"><span>市场状态</span><strong id="sentiment-regime">—</strong></div>
<div class="volatility-metrics" id="volatility-metrics"></div>
</section>
<section class="v4-card volatility-chart-card"><div class="volatility-heading"><div><h2>波动率趋势</h2></div></div>
<div class="segmented-control" role="group" aria-label="趋势时间范围"><button class="btn" type="button" data-vol-range="21" aria-pressed="false">1M</button><button class="btn" type="button" data-vol-range="63" aria-pressed="true">3M</button><button class="btn" type="button" data-vol-range="252" aria-pressed="false">1Y</button></div>
<div id="volatility-chart" role="img" aria-label="VXSMH 日线及20日均线，下方为 SMH 成交量"></div><p id="volatility-chart-note" role="status" hidden></p>
</section></div>
<section class="v4-card volatility-insight"><h2>Today Insight</h2><p id="volatility-insight">正在读取组合暴露…</p><small>直接持仓占比 · 不含现金及 ETF 穿透</small></section>

</main><script src="/static/vendor/echarts.min.js"></script><script src="/static/volatility.js"></script>'''


@router.get('/sentiment')
def page(request: Request):
    return HTMLResponse(render_layout(request, '行业波动情绪', BODY, '/sentiment', get_lang(request), head_extra='<link rel="stylesheet" href="/static/volatility.css" />'))


@router.get('/api/volatility/semiconductors')
def api_snapshot():
    portfolio = current_snapshot()
    market = market_by_ticker(portfolio)
    holdings = []
    for ticker, holding in holdings_by_ticker(portfolio).items():
        value = market.get(ticker, {}).get('market_value_usd')
        if value is None:
            value = holding.get('api_market_value_usd')
        holdings.append({'ticker': ticker, 'market_value_usd': value})
    result = snapshot(holdings)
    result['portfolio_mode'] = 'demo' if demo_mode() else 'live'
    return result
