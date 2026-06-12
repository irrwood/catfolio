"""Page route: ai."""
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from app.components import wrap_v4_layout
from app.i18n import get_lang

router = APIRouter(tags=["pages"])


@router.get("/ai")
def ai_page(request: Request):
    content = """<div class="v4-hero">
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
</div>

<style>
  .ai-layout { display: grid; grid-template-columns: 1fr 320px; gap: 16px; }
  @media (max-width: 900px) { .ai-layout { grid-template-columns: 1fr; } }

  .ai-main { display: flex; flex-direction: column; gap: 16px; }

  .ai-sidebar { display: flex; flex-direction: column; gap: 12px; }

  .qb-section { background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 12px; }
  .qb-title { font-weight: 700; font-size: 12px; color: var(--muted); margin-bottom: 8px; text-transform: uppercase; letter-spacing: 0.3px; }
  .qb-grid { display: flex; flex-wrap: wrap; gap: 5px; }

  .qb-chip { display: inline-block; padding: 4px 10px; background: var(--bg); border: 1px solid var(--line); border-radius: 99px; font-size: 11px; color: var(--text); cursor: pointer; white-space: nowrap; transition: all 0.15s; }
  .qb-chip:hover { border-color: var(--accent); color: var(--accent); background: oklch(0.5 0.04 265 / 0.08); }

  .ai-briefing-card { background: var(--surface); border: 1px solid var(--accent); border-radius: 12px; padding: 20px; }
  .ai-briefing-card p { font-size: 15px; line-height: 1.7; color: var(--text); margin: 0; }

  .ai-ask-bar { display: flex; gap: 8px; padding: 0 0 12px 0; }
  .ai-input { background: var(--bg); border: 1px solid var(--line); border-radius: 8px; padding: 10px 14px; font-size: 14px; color: var(--text); outline: none; }
  .ai-input:focus { border-color: var(--accent); }

  #convArea { display: flex; flex-direction: column; gap: 12px; }
  .conv-item { display: flex; flex-direction: column; gap: 4px; }
  .conv-q { font-size: 12px; color: var(--accent); font-weight: 600; }
  .conv-a { font-size: 13px; line-height: 1.65; color: var(--text); background: var(--surface); border: 1px solid var(--line); border-radius: 10px; padding: 12px 14px; }
  .conv-a.loading { color: var(--muted); font-style: italic; }
</style>

<script>
  // ── Question Bank ──
  const Q = {
    quick: [
      "为什么今天涨跌？",
      "我现在主要在赌什么？",
      "我的组合是不是太集中？",
      "如果 QQQ 跌 10%，我会怎样？",
      "哪个持仓贡献最大？",
      "怎么降低最大回撤？",
      "我的 ETF 和个股有没有重复？",
      "这次回撤是谁造成的？"
    ],
    bet: [
      "我的组合是真分散还是假分散？",
      "我是不是买了太多科技股？",
      "我是不是过度暴露在 AI 主题？",
      "我是不是太依赖 NVDA？",
      "我同时买了很多重复资产吗？"
    ],
    risk: [
      "我现在最大的风险是什么？",
      "如果市场下跌，我哪里最脆弱？",
      "我的组合 Beta 高吗？",
      "我的波动率是不是太高？",
      "我的现金比例够不够？",
      "我的组合适合长期拿吗？"
    ],
    whatIf: [
      "如果 QQQ 跌 10%，我会亏多少？",
      "如果 NVDA 跌 20%，组合会怎样？",
      "如果我卖掉 Unity，会降低多少风险？",
      "如果我买 10% VOO，组合会更稳吗？",
      "如果我加 20% 现金，最大回撤会下降多少？",
      "如果我减半 NVDA，收益和风险会怎么变？"
    ],
    overlap: [
      "QQQ 和我的个股重叠吗？",
      "SMH 和 NVDA 重叠严重吗？",
      "我的真实 NVDA 暴露是多少？",
      "哪些持仓其实是同一个方向？",
      "我的 Apple 暴露是不是比表面更高？"
    ],
    performance: [
      "过去 30 天收益主要来自哪里？",
      "今年收益主要靠哪几只股票？",
      "我的收益是靠个股选择还是靠市场上涨？",
      "哪个板块贡献最大？",
      "如果去掉 NVDA，组合还赚钱吗？",
      "如果去掉前 3 大赢家，组合表现怎样？"
    ],
    drawdown: [
      "这次回撤是怎么造成的？",
      "为什么我跌得比大盘多？",
      "这次亏损主要来自哪几只？",
      "这次是市场问题还是持仓结构问题？",
      "如果我减仓 NVDA 到 10%，风险会下降多少？",
      "如果我卖掉 TSLA 换成 VOO，会怎样？"
    ]
  };

  function renderChips(containerId, questions) {
    const el = document.querySelector(containerId);
    if (!el) return;
    el.innerHTML = questions.map(q => `<span class="qb-chip" onclick="quickAsk(this)">${q}</span>`).join("");
  }

  Object.entries({
    "#quickQuestions": Q.quick,
    "#betQuestions": Q.bet,
    "#riskQuestions": Q.risk,
    "#whatIfQuestions": Q.whatIf,
    "#overlapQuestions": Q.overlap,
    "#performanceQuestions": Q.performance,
    "#drawdownQuestions": Q.drawdown
  }).forEach(([sel, qs]) => renderChips(sel, qs));

  // ── Core API ──
  async function aiPost(url, body) {
    const resp = await fetch(url, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body || {}) });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    return resp.json();
  }

  // ── Briefing (cached, manual refresh) ──
  const BRIEFING_KEY = "ai_briefing_v1";
  function showCachedBriefing() {
    const cached = localStorage.getItem(BRIEFING_KEY);
    const status = document.querySelector("#briefingStatus");
    const content = document.querySelector("#briefingContent");
    const text = document.querySelector("#briefingText");
    if (cached) {
      try {
        const data = JSON.parse(cached);
        text.textContent = data.briefing;
        status.style.display = "none";
        content.style.display = "block";
        return true;
      } catch(e) {}
    }
    status.innerHTML = `<span style="color:var(--muted)">点击右上角 <i class="fa-solid fa-arrows-rotate"></i> 刷新 生成组合总结</span>`;
    content.style.display = "none";
    return false;
  }

  async function loadBriefing() {
    const status = document.querySelector("#briefingStatus");
    const content = document.querySelector("#briefingContent");
    const text = document.querySelector("#briefingText");
    status.style.display = "block";
    status.innerHTML = `<i class="fa-solid fa-spinner fa-spin"></i> AI 正在分析你的组合...`;
    content.style.display = "none";
    try {
      const data = await aiPost("/api/ai/briefing");
      text.textContent = data.briefing;
      localStorage.setItem(BRIEFING_KEY, JSON.stringify(data));
      status.style.display = "none";
      content.style.display = "block";
    } catch(e) {
      status.innerHTML = `<span style="color:var(--negative)">加载失败: ${e.message} <button class="btn" onclick="loadBriefing()" style="font-size:11px;padding:2px 8px;">重试</button></span>`;
    }
  }

  // ── Quick Ask (from chip) ──
  function quickAsk(chip) {
    const question = chip.textContent.trim();
    document.querySelector("#aiAskInput").value = question;
    doAsk();
  }

  // ── Ask question ──
  async function doAsk() {
    const input = document.querySelector("#aiAskInput");
    const btn = document.querySelector("#askBtn");
    const status = document.querySelector("#askStatus");
    const conv = document.querySelector("#convArea");
    const question = input.value.trim();
    if (!question) { status.innerHTML = `<span style="color:var(--negative)">请输入一个问题</span>`; return; }

    input.value = "";
    btn.disabled = true;
    status.innerHTML = `<i class="fa-solid fa-spinner fa-spin"></i> AI 正在分析...`;

    // Add question to conversation
    const itemId = "conv-" + Date.now();
    conv.insertAdjacentHTML("beforeend",
      `<div class="conv-item" id="${itemId}"><div class="conv-q">${question}</div><div class="conv-a loading"><i class="fa-solid fa-spinner fa-spin"></i> 思考中...</div></div>`);

    try {
      const data = await aiPost("/api/ai/ask", {question});
      const answerEl = document.querySelector(`#${itemId} .conv-a`);
      answerEl.textContent = data.answer;
      answerEl.classList.remove("loading");
      status.innerHTML = "";
    } catch(e) {
      const answerEl = document.querySelector(`#${itemId} .conv-a`);
      answerEl.textContent = `AI 分析失败: ${e.message}`;
      answerEl.classList.remove("loading");
      answerEl.style.color = "var(--negative)";
      status.innerHTML = `<span style="color:var(--negative)">失败: ${e.message}</span>`;
    } finally {
      btn.disabled = false;
    }
  }

  // Init
  showCachedBriefing();
</script>"""
    return HTMLResponse(wrap_v4_layout("AI 分析", content, "/ai", get_lang(request)))

