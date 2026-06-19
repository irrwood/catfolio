"""Page route: lab — HTML body only; CSS/JS live in static/lab.css and static/lab.js."""
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from app.components import wrap_v4_layout
from app.i18n import get_lang

router = APIRouter(tags=["pages"])

_HEAD = '<link rel="stylesheet" href="/static/lab.css" />'
_SCRIPTS = (
    '<script src="/static/vendor/echarts.min.js"></script>'
    '<script src="/static/lab.js"></script>'
    '<script src="/static/home.js"></script>'
)

_BODY = r"""    
<header id="overview" class="lab-hero">
        <div>
            <h1>Portfolio Lab</h1>
            <p>组合分析、量化回测与优化</p>
        </div>
        <div class="lab-hero-actions">
            <div class="lab-hero-actions-label">数据控制</div>
            <div class="toolbar">
                <button id="refreshButton" class="btn primary" type="button">同步持仓</button>
                <button id="marketRefreshButton" class="btn" type="button">刷新行情</button>
                <button id="fundamentalsRefreshButton" class="btn" type="button">刷新估值</button>
                <button id="refreshHistory" class="btn" type="button">刷新历史价格</button>
                <a class="btn" href="/import">手动导入</a>
            </div>
        </div>
    </header>
    <div class="dashboard-stack">
    <section class="command-card lab-control-card">
        <div id="refreshStatus" class="status"></div>
    </section>

    <div class="data-health-row">
        <div class="data-health-chip"><b><span class="status-dot"></span>Trading 212</b><span id="healthTrading212">读取中...</span></div>
        <div class="data-health-chip"><b><span class="status-dot"></span>Yahoo 行情</b><span id="healthMarket">读取中...</span></div>
        <div class="data-health-chip"><b><span id="healthFundamentalsDot" class="status-dot warn"></span>FMP 估值</b><span id="healthFundamentals">读取中...</span></div>
        <div class="data-health-chip"><b><span class="status-dot"></span>历史价格</b><span id="healthHistory">读取中...</span></div>
    </div>
    <div class="snapshot-grid">
        <div class="snapshot-card">
            <div>
                <div class="snapshot-label">总市值</div>
                <div id="snapshotMarketValue" class="snapshot-value">—</div>
                <div id="snapshotMarketSub" class="snapshot-sub">等待持仓...</div>
            </div>
            <svg id="snapshotMarketSpark" class="snapshot-spark muted" viewBox="0 0 120 34" preserveAspectRatio="none"></svg>
        </div>
        <div class="snapshot-card">
            <div>
                <div class="snapshot-label">总浮盈</div>
                <div id="snapshotTotalPnl" class="snapshot-value positive">—</div>
                <div id="annualReturn" class="snapshot-sub positive">—</div>
            </div>
            <svg id="snapshotPnlSpark" class="snapshot-spark" viewBox="0 0 120 34" preserveAspectRatio="none"></svg>
        </div>
        <div class="snapshot-card">
            <div>
                <div class="snapshot-label">今日盈亏</div>
                <div id="snapshotTodayPnl" class="snapshot-value positive">—</div>
                <div id="annualVol" class="snapshot-sub positive">—</div>
            </div>
            <svg id="snapshotTodaySpark" class="snapshot-spark" viewBox="0 0 120 34" preserveAspectRatio="none"></svg>
        </div>
        <div class="snapshot-card">
            <div>
                <div class="snapshot-label">持仓股数</div>
                <div id="snapshotHoldingsCount" class="snapshot-value">—</div>
                <div id="snapshotBreadth" class="snapshot-sub">等待涨跌分布...</div>
            </div>
        </div>
        <div class="snapshot-card">
            <div>
                <div class="snapshot-label">夏普比率</div>
                <div id="sharpe" class="snapshot-value">—</div>
                <div id="snapshotSharpeSub" class="snapshot-sub positive">等待基准...</div>
            </div>
        </div>
        <div class="snapshot-card">
            <div>
                <div class="snapshot-card-head">
                    <div class="snapshot-label">最大回撤</div>
                    <select id="drawdownRangeSelect" class="snapshot-control" aria-label="最大回撤统计时间">
                        <option value="all">全部</option>
                        <option value="252">1 年</option>
                        <option value="126">6 月</option>
                        <option value="63">3 月</option>
                        <option value="21">1 月</option>
                    </select>
                </div>
                <div id="maxDrawdown" class="snapshot-value negative">—</div>
                <div id="snapshotDrawdownSub" class="snapshot-sub">样本期</div>
            </div>
        </div>
    </div>
    <section class="daily-pnl-panel">
        <div class="daily-pnl-head">
            <div>
                <div class="daily-pnl-title">收益分布日历</div>
                <div class="daily-pnl-sub">每日盈亏 · 月 / 年 视图</div>
            </div>
            <div class="pnl-cal-nav">
                <div class="pnl-cal-viewtabs" role="tablist" aria-label="收益日历视图">
                    <button class="pnl-cal-viewtab active" id="calViewMonth" type="button" role="tab" aria-selected="true" aria-pressed="true">月</button>
                    <button class="pnl-cal-viewtab" id="calViewYear" type="button" role="tab" aria-selected="false" aria-pressed="false">年</button>
                </div>
                <button class="pnl-cal-nav-btn" id="calPrev" type="button" title="上一页" aria-label="上一页">&#8249;</button>
                <span id="calMonthLabel" class="pnl-cal-month-label">—</span>
                <button class="pnl-cal-nav-btn" id="calNext" type="button" title="下一页" aria-label="下一页">&#8250;</button>
            </div>
        </div>
        <div id="pnlCalendar" class="pnl-cal-grid"></div>
        <div class="pnl-cal-summary">
            <div>
                <div id="calTotalLabel" class="pnl-cal-stat-label">当月盈亏</div>
                <div id="calMonthTotal" class="pnl-cal-stat-value">—</div>
            </div>
            <div>
                <div class="pnl-cal-stat-label">盈利天数</div>
                <div id="calPosDays" class="pnl-cal-stat-value positive">—</div>
            </div>
            <div>
                <div class="pnl-cal-stat-label">亏损天数</div>
                <div id="calNegDays" class="pnl-cal-stat-value negative">—</div>
            </div>
            <div>
                <div class="pnl-cal-stat-label">最大单日</div>
                <div id="calBestDay" class="pnl-cal-stat-value positive">—</div>
            </div>
            <div>
                <div class="pnl-cal-stat-label">最差单日</div>
                <div id="calWorstDay" class="pnl-cal-stat-value negative">—</div>
            </div>
        </div>
    </section>
    <section class="daily-pnl-panel">
        <div class="daily-pnl-head">
            <div>
                <div class="daily-pnl-title">月度收益热图</div>
                <div class="daily-pnl-sub">年 × 月盈亏%</div>
            </div>
            <div class="daily-pnl-note">按当前仓位模型估算，适合看月份节奏和波动，不代表完整账户现金流收益。</div>
        </div>
        <div id="monthlyReturnDarkChart" class="monthly-return-chart"></div>
    </section>
    <section class="daily-pnl-panel">
        <div class="daily-pnl-head">
            <div>
                <div class="daily-pnl-title">估值矩阵 (P/E vs 成长)</div>
                <div class="daily-pnl-sub">气泡大小 = 仓位权重</div>
            </div>
            <div class="daily-pnl-note">优先使用 EPS 成长率；缺失时使用营收同比成长率。需要 fundamentals 数据源刷新。</div>
        </div>
        <div id="valuationMatrixChart" class="valuation-matrix-chart"></div>
        <div class="valuation-waterline">
            <div class="valuation-waterline-summary">
                <div class="kicker">估值水位<br>(PREMIUM/DISCOUNT)</div>
                <b id="valuationWaterlineOverall">—</b>
                <span id="valuationWaterlineNote">刷新 FMP fundamentals 后，显示持仓相对同板块/组合中位估值的 premium 或 discount。</span>
            </div>
            <div id="valuationWaterlineList" class="valuation-waterline-list"></div>
        </div>
    </section>

    <section class="command-card">
        <div class="chart-head" style="display:flex;justify-content:space-between;align-items:center;">
            <div>
                <h2>盘后异动 <span style="font-size:11px;color:var(--muted);font-weight:400;">Massive · After-Hours Movers</span></h2>
                <div style="font-size:11px;color:var(--muted);">盘后价 vs 收盘价涨跌超过 ±1% 的持仓</div>
            </div>
            <button id="afterHoursBtn" class="btn primary" type="button" onclick="loadAfterHours()">刷新盘后数据</button>
        </div>
        <div id="afterHoursStatus" style="padding:8px 0;font-size:12px;color:var(--muted);">点击刷新获取最新盘后数据</div>
        <div id="afterHoursResult" style="display:none;">
            <div class="table-wrap">
                <table>
                    <thead><tr><th>代码</th><th>收盘价</th><th>盘后价</th><th>盘后涨跌</th><th>成交量</th></tr></thead>
                    <tbody id="afterHoursBody"></tbody>
                </table>
            </div>
            <div id="afterHoursQuiet" style="display:none;padding:16px;text-align:center;color:var(--muted);font-size:14px;">
                盘后无异常波动，所有持仓盘后变化均小于 1%
            </div>
            <div id="afterHoursMeta" style="font-size:11px;color:var(--muted);margin-top:8px;"></div>
        </div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>持仓分类集中度</h2><span><span class="source-badge">真实持仓 + 本地分类</span></span></div>
        <div id="sectorChart" class="mini-chart"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>个股盈亏贡献</h2><span><span class="source-badge">真实账户 · 美元浮盈（成本 vs 现价）</span></span></div>
        <div id="pnlChart" class="mini-chart"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>持仓明细</h2><span>成本、现价、今日涨跌、浮盈和仓位</span></div>
        <div class="table-wrap">
            <table>
                <thead><tr><th>代码</th><th>名称</th><th>成本</th><th>现价</th><th>今日</th><th>浮盈%</th><th>52周</th><th>仓位</th></tr></thead>
                <tbody id="holdingRows"></tbody>
            </table>
        </div>
    </section>

    <div class="section-kicker">模型分析，按当前仓位回看历史，不是现金流口径真实收益</div>

    <section class="command-card">
        <div class="chart-head"><h2>收益率分布</h2><span>模型日收益</span></div>
        <div id="distributionChart" class="mini-chart"></div>
        <div id="distributionNote" style="font-size:11px;color:var(--muted);text-align:center;margin-top:4px;"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>回撤水下曲线</h2><span>模型组合跌离高点</span></div>
        <div id="drawdownChart" class="mini-chart"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>持仓相关性矩阵</h2><span>颜色越深，越容易同涨同跌</span></div>
        <div id="correlationChart" class="heatmap-chart"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>模型归因 Waterfall</h2><span>模型口径 · 当月权重收益%（非真实盈亏）</span></div>
        <div id="waterfallChart" class="mini-chart"></div>
    </section>

    <section class="command-card">
        <div class="chart-head"><h2>累计收益对比</h2><span id="cumulativeRange">TWR / 现金流镜像</span></div>
        <div id="cumulativeChart" style="width:100%;height:280px;"></div>
    </section>

    <aside class="stack">
        <section class="panel">
            <h2>资产归并</h2>
            <table>
                <thead><tr><th>底层暴露</th><th>成员</th><th>权重</th></tr></thead>
                <tbody id="groupRows"></tbody>
            </table>
        </section>
        <section class="panel" style="display: none;">
            <h2>Monte Carlo Range</h2>
            <div id="percentileGrid" class="percentile-grid"></div>
        </section>
        <section class="panel" style="display: none;">
            <h2>状态</h2>
            <p id="status">正在加载 Portfolio Lab...</p>
        </section>
    </aside>
    </div>"""


@router.get("/lab")
def lab_page(request: Request):
    content = _BODY + _SCRIPTS
    return HTMLResponse(
        wrap_v4_layout("Portfolio Lab", content, "/lab", get_lang(request), head_extra=_HEAD)
    )
