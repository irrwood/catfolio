"""Presentation and read-only API; requests never trigger the price batch."""
from datetime import date
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse
from app.components import render_layout
from app.i18n import get_lang
from app import sector_rotation

router = APIRouter(tags=['sector-rotation'])
BODY = '''<main class="rotation-page">
<header class="v4-hero"><div class="v4-hero-text"><p>美国市场 · 11 个 SPDR 板块 ETF / SPY</p><h1>板块轮动</h1></div></header>
<section class="v4-card rotation-card">
<div class="rotation-heading"><div><h2>中期相对强弱 × 近月相对动量</h2><p id="rotation-status" role="status">读取每日快照…</p></div>
<div class="segmented-control" role="group" aria-label="观察周期"><button class="btn" disabled title="暂未开放">短期</button><button class="btn" aria-pressed="true">中期</button><button class="btn" disabled title="暂未开放">长期</button></div></div>
<div class="rotation-layout"><div><p class="rotation-axis">近 1 月相对动量 ↑</p><div id="rotation-plot" class="rotation-plot" aria-label="板块轮动四象限图"></div><p class="rotation-axis rotation-axis-x">中期相对强弱 →</p>
<p class="rotation-note">图心是当日 11 个板块的中位数，不是 SPY 或零收益。位置是相对其他板块的，不是绝对涨跌。</p>
<div class="rotation-playback"><button id="rotation-play" class="btn" aria-label="播放历史快照" disabled>播放</button><input id="rotation-date" type="range" min="0" max="0" value="0" aria-label="回看日期" disabled><output id="rotation-date-label"></output><button id="rotation-latest" class="btn" disabled>最新</button></div></div>
<aside id="rotation-detail" aria-live="polite"><h3>选择一个板块</h3><p>点击图中圆点或下方列表，查看过去 8 周轨迹与规则解释。</p></aside></div>
<div id="rotation-sectors" class="rotation-sectors" aria-label="全部板块"></div>
</section>
<details class="v4-card rotation-rules"><summary>如何阅读这张图</summary><p>领先：中期与近月位置都高于板块中位数。减弱：中期高于、近月低于。落后：两者都低于。改善：中期低于、近月高于。这些状态不表示绝对涨跌，也不是买卖信号。</p><p>先计算 ETF 与 SPY 复权价的对数差，再作 5 日均值。横轴取第 63 至第 21 个交易日前的变化，纵轴取最近 21 个交易日的变化；两者不重叠。分别以当日中位数和 MAD 标准化，再用 tanh 软压缩。</p><p>显示的百分比由原始对数差还原，表示相对 SPY 的变化。图上位置以板块截面为中心。中心 ±0.25 范围为中性；新象限连续两交易日成立才切换文字标签，因此文字可能暂时不同于点所在象限。</p><p>历史来自当日快照，每周取最后有效交易日；选中后显示当前点和过去 8 个完整 ISO 周的周点。初始化历史使用回填时可得的复权序列，可能与当时实际发布值略有差异。此图不使用 JdK RRG 专有计算。</p></details>
<p class="rotation-note">展示板块相对 SPY 的趋势和动量，仅供市场观察，不构成投资建议。</p>
</main><script src="/static/sector-rotation.js" defer></script>'''

@router.get('/rotation')
def page(request: Request):
    return HTMLResponse(render_layout(request, '板块轮动', BODY, '/rotation', get_lang(request), head_extra='<link rel="stylesheet" href="/static/sector-rotation.css">'))

@router.get('/api/sector-rotation')
def snapshot(asOf: str | None = None):
    if asOf:
        try:
            if date.fromisoformat(asOf).isoformat() != asOf:
                raise ValueError
        except ValueError:
            raise HTTPException(422, 'asOf must be YYYY-MM-DD')
    return sector_rotation.read_snapshot(sector_rotation.DB_PATH, as_of=asOf)
