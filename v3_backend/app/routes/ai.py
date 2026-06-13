"""Page route: ai — HTML body only; CSS/JS in static/ai.css and static/ai.js."""
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from app.components import wrap_v4_layout
from app.i18n import get_lang

router = APIRouter(tags=["pages"])

_HEAD = '<link rel="stylesheet" href="/static/ai.css" />'
_SCRIPTS = '<script src="/static/ai.js"></script>'

_BODY = r"""<div class="v4-hero">
  <div class="v4-hero-text">
    <h1><i class="fa-solid fa-robot"></i> AI 分析面板</h1>
    <p>AI 不预测涨跌，不推荐买卖。核心价值：解释组合发生了什么、找出真实风险、判断收益是否可靠、发现假分散、把复杂数据翻译成人话。</p>
  </div>
</div>

<div class="ai-layout">
  <!-- Left: Q&A area -->
  <div class="ai-main">

    <!-- Briefing (auto-load) -->
    <section class="panel">
      <div class="chart-head"><h2><i class="fa-solid fa-lightbulb"></i> 组合每日总结</h2><span id="briefingRefresh" style="cursor:pointer;font-size:11px;color:var(--accent);" onclick="loadBriefing()"><i class="fa-solid fa-arrows-rotate"></i> 刷新</span></div>
      <div id="briefingStatus" style="padding:4px 0 8px 0;"><i class="fa-solid fa-spinner fa-spin"></i> AI 正在分析你的组合...</div>
      <div id="briefingContent" style="display:none;">
        <div class="ai-briefing-card"><p id="briefingText"></p></div>
      </div>
    </section>

    <!-- Q&A conversation -->
    <section class="panel">
      <div class="chart-head"><h2><i class="fa-solid fa-comments"></i> 问答</h2><span>问任何关于你组合的问题</span></div>

      <!-- Input area -->
      <div class="ai-ask-bar">
        <input id="aiAskInput" class="ai-input" placeholder="输入问题，例如：我的组合是不是太集中？" style="flex:1;" onkeydown="if(event.key==='Enter')doAsk()" />
        <button id="askBtn" class="btn primary" onclick="doAsk()"><i class="fa-solid fa-paper-plane"></i> 提问</button>
      </div>
      <div id="askStatus" style="margin:8px 0;font-size:12px;"></div>

      <!-- Conversation history -->
      <div id="convArea"></div>
    </section>

  </div>

  <!-- Right: Question Bank -->
  <aside class="ai-sidebar">
    <div class="qb-section">
      <div class="qb-title"><i class="fa-solid fa-bolt"></i> 快捷提问</div>
      <div class="qb-grid" id="quickQuestions"></div>
    </div>

    <div class="qb-section">
      <div class="qb-title"><i class="fa-solid fa-bullseye"></i> 我在赌什么？</div>
      <div class="qb-grid" id="betQuestions"></div>
    </div>

    <div class="qb-section">
      <div class="qb-title"><i class="fa-solid fa-shield-halved"></i> 风险诊断</div>
      <div class="qb-grid" id="riskQuestions"></div>
    </div>

    <div class="qb-section">
      <div class="qb-title"><i class="fa-solid fa-flask-vial"></i> 情景分析</div>
      <div class="qb-grid" id="whatIfQuestions"></div>
    </div>

    <div class="qb-section">
      <div class="qb-title"><i class="fa-solid fa-clone"></i> 持仓重叠</div>
      <div class="qb-grid" id="overlapQuestions"></div>
    </div>

    <div class="qb-section">
      <div class="qb-title"><i class="fa-solid fa-magnifying-glass-dollar"></i> 收益归因</div>
      <div class="qb-grid" id="performanceQuestions"></div>
    </div>

    <div class="qb-section">
      <div class="qb-title"><i class="fa-solid fa-chart-line"></i> 回撤 & 调仓</div>
      <div class="qb-grid" id="drawdownQuestions"></div>
    </div>
  </aside>
</div>"""


@router.get("/ai")
def ai_page(request: Request):
    return HTMLResponse(
        wrap_v4_layout("AI 分析", _BODY + _SCRIPTS, "/ai", get_lang(request), head_extra=_HEAD)
    )
