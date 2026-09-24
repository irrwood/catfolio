"""Call tracker page and API. Reads never fetch prices; only POST /api/calls/refresh does."""
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import HTMLResponse
from starlette.concurrency import run_in_threadpool

from app import call_tracker as ct
from app.components import render_layout
from app.data_store import demo_mode
from app.i18n import get_lang

router = APIRouter(tags=['call-tracker'])

BODY = '''<main class="calls-page" id="calls-root" data-demo="{demo}">
<header class="v4-hero calls-hero"><div class="v4-hero-text"><p>任何来源的个股观点 · 基准 SPY</p><h1>观点记分牌</h1></div>
<div class="calls-horizon" id="calls-horizon" role="group"></div></header>
<section class="calls-meta"><p id="calls-freshness" role="status">正在读取观点数据…</p><p id="calls-method-line"></p><p class="calls-disclaimer">仅供复盘，不构成投资建议。</p></section>
<section class="v4-card calls-card" id="calls-overview" aria-labelledby="calls-overview-title">
<div class="calls-card-head"><div><h2 class="v4-card-title" id="calls-overview-title">来源对比</h2><p class="v4-card-subtitle" id="calls-totals"></p></div></div>
<div class="calls-table-wrap"><table class="calls-table" id="calls-sources"></table></div>
<p class="calls-footnote" id="calls-sort-note"></p></section>
<section class="calls-detail" id="calls-detail" aria-labelledby="calls-detail-title" hidden>
<div class="calls-detail-head"><button type="button" class="btn" id="calls-back"></button><h2 id="calls-detail-title" translate="no"></h2><span class="calls-tag" id="calls-detail-status"></span></div>
<dl class="calls-stats" id="calls-detail-stats"></dl>
<div class="calls-charts">
<article class="v4-card calls-card"><div class="calls-card-head"><div><h3 class="v4-card-title">如果每次都跟</h3><p class="v4-card-subtitle">每条已到期观点在起点投入等额资金、持有到期（看空按做空计），按日汇总；虚线为同期同方向持有 SPY。</p></div></div>
<p class="calls-readout" id="calls-curve-readout" aria-live="polite"></p><div class="calls-chart" id="calls-curve"></div></article>
<article class="v4-card calls-card"><div class="calls-card-head"><div><h3 class="v4-card-title">逐月命中率</h3><p class="v4-card-subtitle">按观点日所在月份；柱顶数字为已到期条数，虚线为 50%。</p></div></div>
<div class="calls-chart" id="calls-months"></div></article>
</div>
<article class="v4-card calls-card"><div class="calls-card-head"><div><h3 class="v4-card-title">逐条观点</h3><p class="v4-card-subtitle" id="calls-events-status"></p></div></div>
<div class="calls-table-wrap"><table class="calls-table calls-events" id="calls-events"></table></div>
<div class="calls-pager"><button type="button" class="btn" id="calls-prev">上一页</button><span id="calls-page-info"></span><button type="button" class="btn" id="calls-next">下一页</button></div></article>
</section>
{panel}
<details class="v4-card calls-card calls-method" id="calls-method"><summary>观点记分牌的统计口径</summary><ul>
<li>一条观点 = 来源、日期、代码、方向（看多、看空、中性），可附理由和链接。同一来源、同一天、同一代码只算一次。</li>
<li>起点：观点日之后第一个交易日的收盘价（观点只有日期没有时刻，这样不会用到发布时还不知道的价格）。终点：起点之后第 5、21、63 个交易日的收盘价；当天没有收盘价时取之前最近的一个。</li>
<li>命中：看多时终点高于起点，看空时终点低于起点；持平算未命中。中性观点只显示股价变化，不计入命中率和超额。</li>
<li>超额按方向计算：看多为股票收益减去 SPY 同期收益，看空为 SPY 同期收益减去股票收益。非美股的 SPY 取同日或之前最近一个交易日的收盘。</li>
<li>还没到期的观点显示“待观察”，缺少价格的显示“缺价”，两者都不进分母。已到期不足 10 条的来源标“待观察”，排在已达门槛的来源之后。</li>
<li>来源按 63 日命中率排序（63 日结果相同或还没有时，再按当前观察期的命中率）。</li>
<li>“每次都跟”：每条已到期的看多或看空观点在起点投入等额资金、持有到终点（看空按做空计），按日汇总成净值；对照线是同期、同方向持有 SPY。</li>
<li>最大单笔贡献：最赚钱的一条观点占全部盈利观点收益之和的比例。比例越高，结果越依赖单笔。</li>
<li>价格为雅虎日线复权收盘价（含分红和拆股调整），显示的价格可能与当日报价略有不同。未计交易成本、税费和做空成本；只统计导入的观点，可能存在幸存者偏差。</li>
</ul></details>
</main><script src="/static/call-tracker.js" defer></script>'''

IMPORT_PANEL = '''<section class="v4-card calls-card calls-import" id="calls-import" aria-labelledby="calls-import-title">
<div class="calls-card-head"><div><h2 class="v4-card-title" id="calls-import-title">导入观点文件</h2><p class="v4-card-subtitle">JSONL 文件，每行一条观点；导入后自动联网取价并计算。</p></div>
<button type="button" class="btn" id="calls-refresh">重新计算</button></div>
<form class="calls-import-form" id="calls-import-form">
<label>上传 JSONL 文件<input type="file" id="calls-file" accept=".jsonl,.ndjson,.json,.txt"></label>
<label>或填写本机路径<input type="text" id="calls-path" placeholder="~/Documents/calls.jsonl" autocomplete="off" spellcheck="false"></label>
<button type="submit" class="btn btn-primary" id="calls-import-btn">导入并计算</button></form>
<p class="calls-status" id="calls-import-status" role="status"></p>
<p class="calls-footnote">字段：date（YYYY-MM-DD）、source 或 channel、symbol 或 ticker、stance（看多／看空／中性，或 bullish／bearish／neutral），可选 name、reason、url 或 video_id。同一来源、同一天、同一代码只保留第一条；港股代码自动转成 0700.HK 格式。</p>
<p class="calls-footnote">观点只存在本机数据目录。计算时读取雅虎日线，与策略回测共用本机行情缓存（最长 12 小时更新一次）；“重新计算”会先重新读取上次导入的本机文件。</p>
</section>'''

DEMO_PANEL = '''<section class="v4-card calls-card calls-import" aria-labelledby="calls-demo-title">
<h2 class="v4-card-title" id="calls-demo-title">演示数据</h2>
<p class="calls-footnote">来源、观点和价格都是虚构的：由固定随机种子生成，不联网，不代表任何真实博主或机构。关闭演示模式后，可以在这里导入自己的观点文件。</p>
</section>'''

IMPORT_ERRORS = {
    'demo': '演示模式下不能导入或重新计算。',
    'no_file': '请选择文件或填写本机路径。',
    'bad_request': '请求格式不对。',
    'relative_path': '请填写完整路径（以 / 或 ~ 开头）。',
    'not_found': '找不到这个文件。',
    'not_a_file': '这个路径不是文件。',
    'bad_suffix': '只支持 .jsonl、.ndjson、.json 或 .txt 文件。',
    'too_large': '文件超过 20 MB。',
    'not_utf8': '文件不是 UTF-8 编码。',
}


def _error(status, code):
    raise HTTPException(status, detail={'code': code, 'message': IMPORT_ERRORS.get(code, code)})


def _horizon(horizon):
    if horizon not in ct.HORIZONS:
        raise HTTPException(422, 'horizon must be 5, 21 or 63')
    return horizon


def _dataset(request, with_prices=False):
    return ct.demo_dataset(get_lang(request)) if demo_mode() else ct.load_dataset(with_prices=with_prices)


@router.get('/calls')
def page(request: Request):
    demo = demo_mode()
    body = BODY.replace('{demo}', '1' if demo else '0').replace('{panel}', DEMO_PANEL if demo else IMPORT_PANEL)
    return HTMLResponse(render_layout(request, '观点记分牌', body, '/calls', get_lang(request),
                                      head_extra='<link rel="stylesheet" href="/static/call-tracker.css">'))


@router.get('/api/calls/summary')
def summary(request: Request, horizon: int = ct.DEFAULT_HORIZON):
    return ct.summary(_horizon(horizon), _dataset(request))


@router.get('/api/calls/source/{name:path}')
def source(request: Request, name: str, horizon: int = ct.DEFAULT_HORIZON):
    try:
        return ct.source_detail(name, _horizon(horizon), _dataset(request, with_prices=True))
    except KeyError:
        raise HTTPException(404, 'unknown source') from None


@router.get('/api/calls/events')
def events(request: Request, source: str = '', horizon: int = ct.DEFAULT_HORIZON, page: int = Query(1, ge=1)):
    return ct.events(source, _horizon(horizon), page, _dataset(request))


@router.post('/api/calls/import')
async def import_calls(request: Request):
    """Real mode only: multipart upload (field ``file``) or JSON ``{"path": "/abs/calls.jsonl"}``."""
    if demo_mode():
        _error(409, 'demo')
    length = request.headers.get('content-length', '')
    if length.isdigit() and int(length) > ct.MAX_IMPORT_BYTES + 65536:
        _error(413, 'too_large')
    try:
        if request.headers.get('content-type', '').startswith('multipart/form-data'):
            upload = (await request.form()).get('file')
            if upload is None or not hasattr(upload, 'read'):
                _error(400, 'no_file')
            data = await upload.read(ct.MAX_IMPORT_BYTES + 1)
            result = await run_in_threadpool(ct.import_jsonl, data)
        else:
            try:
                body = await request.json()
            except ValueError:
                _error(400, 'bad_request')
            raw = str(body.get('path') or '').strip() if isinstance(body, dict) else ''
            if not raw:
                _error(400, 'no_file')
            if not Path(raw).expanduser().is_absolute():
                _error(400, 'relative_path')
            result = await run_in_threadpool(ct.import_jsonl, raw)
    except ct.CallImportError as exc:
        _error(400, exc.code)
    return dict(ok=True, **result)


@router.post('/api/calls/refresh')
def refresh():
    """Real mode only: re-read the remembered local file, fetch prices and recompute."""
    if demo_mode():
        _error(409, 'demo')
    return dict(ok=True, **ct.refresh())
