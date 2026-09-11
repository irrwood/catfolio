"""Local research demo, served by demo/analyst_app.py."""
from fastapi import APIRouter, Request, HTTPException, Query
from fastapi.responses import HTMLResponse
from app.components import render_layout
from app import analyst_history as data
router = APIRouter()
BODY = '''<main class="ah-page">
<header class="v4-hero"><div><p class="ah-eyebrow">RESEARCH / 历史回顾</p><h1>那些评级，后来怎么样了？</h1><p>回看机构的判断，让每一个结果都有据可查。</p></div><span class="ah-tag">本地 Demo · 真实档案</span></header>
<section class="ah-stats" id="coverage" aria-label="数据覆盖"></section>
<section class="v4-card ah-context"><strong>机构评级方向回顾</strong><p>原始数据没有个人分析师姓名。命中率衡量评级后的涨跌方向，不代表跑赢大盘，也不是目标价达成率。</p><span id="asof"></span></section>
<section class="v4-card"><div class="ah-section-head"><h2>探索历史记录</h2><a href="#method">查看评估口径 ↗</a></div>
<div class="ah-controls"><label>查找机构<input class="form-control" id="firm-search" placeholder="例如 Morgan Stanley" type="search"></label><label>观察期限<select class="form-control" id="horizon"><option value="21">1 个月 · 21 交易日</option><option value="63" selected>3 个月 · 63 交易日</option><option value="126">6 个月 · 126 交易日</option><option value="252">12 个月 · 252 交易日</option></select></label><label>评级方向<select class="form-control" id="direction"><option value="BULLISH">看多</option><option value="BEARISH">看空</option></select></label><label>样本范围<select class="form-control" id="eligible"><option value="yes">达到展示门槛</option><option value="all">全部机构（含小样本）</option></select></label></div>
<p class="ah-muted">展示门槛：≥30 次已评分、≥10 只证券、≥3 个评级年份。机构按样本数排列。</p>
<div class="ah-workspace"><aside class="ah-firms" id="firms" aria-label="机构列表"></aside><div class="ah-detail"><div id="firm-summary"></div><div class="ah-section-head"><h3>逐次评级回顾</h3><label>筛选股票 <input class="form-control" id="ticker" placeholder="如 NVDA" type="search"></label></div><p id="events-status" role="status"></p><div class="ah-table-wrap"><table><thead><tr><th>评级日 / 股票</th><th>评级变更</th><th>观察起点 → 终点</th><th>股价变化</th><th>方向结果</th><th>依据</th></tr></thead><tbody id="events"></tbody></table></div><div class="ah-pagination"><button class="btn" id="prev">上一页</button><span id="page-info"></span><button class="btn" id="next">下一页</button></div></div></div></section>
<section class="v4-card" id="method"><h2>如何读这份回顾</h2><div class="ah-method-grid"><div><h3>01 / 先记录判断</h3><p>只评估评级改变的升级／降级事件。方向由新评级决定，降为 Buy 仍然看多；维持、中性、未知及同日冲突不计分。</p></div><div><h3>02 / 再观察价格</h3><p>评级后首个交易日收盘作为起点，再观察 21 / 63 / 126 / 252 个交易日。每个窗口使用同一档案版本的价格，不填补缺失端点。</p></div><div><h3>03 / 保留不确定性</h3><p>未到期及缺价不进分母；持平计入分母但不算命中。看空方向收益为价格收益的相反数，不是可执行的做空回报。</p></div></div><p class="ah-muted">所有结果为估算。未包含股息、费用或基准超额回报；评级存在回溯修订、幸存者偏差及重叠窗口。历史证券身份与复权未全面独立验证。评级档案的价格观察日历使用 AAPL 交易记录代理。</p><p>数据来源：<a href="https://site.financialmodelingprep.com/developer/docs/stable/grades" target="_blank" rel="noopener">FMP 机构评级 ↗</a> · <a href="https://site.financialmodelingprep.com/developer/docs/stable/historical-price-eod-full" target="_blank" rel="noopener">FMP 历史价格 ↗</a> · <a href="/api/analyst-history/summary" target="_blank">查看原始统计 JSON ↗</a></p></section>
</main><script src="/static/analyst-history.js"></script>'''

@router.get('/analyst-history', response_class=HTMLResponse)
def page(request: Request):
    return render_layout(request, '机构评级历史回顾', BODY, '/analyst-history', 'zh', head_extra='<link rel="stylesheet" href="/static/analyst-history.css">')

@router.get('/api/analyst-history/summary')
def summary():
    try:
        return data.snapshot()
    except (OSError, ValueError):
        raise HTTPException(503, '历史数据不可用，请连接 T7 数据盘。')

@router.get('/api/analyst-history/events')
def events(institution: str, horizon: int = 63, direction: str = 'BULLISH', ticker: str = '', offset: int = Query(0, ge=0)):
    if horizon not in (21,63,126,252) or direction not in ('BULLISH','BEARISH'):
        raise HTTPException(422, '无效观察期限或方向')
    try:
        rows = data.institution_events(str(data.release_path()), institution, horizon, direction)
    except (OSError, ValueError):
        raise HTTPException(503, '历史数据不可用，请连接 T7 数据盘。')
    if ticker.strip():
        rows = [r for r in rows if ticker.strip().upper() in r['symbol']]
    return {'total':len(rows), 'offset':offset, 'items':rows[offset:offset+20]}
