"""Chat-oriented AI analyst page."""

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse

from app.components import render_layout
from app.i18n import get_lang

router = APIRouter(tags=["pages"])

_HEAD = '<link rel="stylesheet" href="/static/ai.css" />'
_SCRIPTS = '<script src="/static/ai.js"></script>'
_BODY = r"""
<div class="ai-page-head">
  <h1>AI Analyst</h1>
</div>

<div class="ai-chat-layout">
  <aside class="ai-prompt-library">
    <div class="prompt-library-head">
      <b>从一个问题开始</b>
      <button id="moreQuestionsBtn" class="prompt-more-btn" type="button" onclick="generateMoreQuestions()">
        <span class="prompt-more-label">生成问题</span>
      </button>
    </div>
    <details open><summary>快捷提问</summary><div class="qb-grid" id="quickQuestions"></div></details>
    <details id="generatedQuestionsGroup" class="generated-questions" hidden open><summary id="generatedQuestionsTitle">新生成的问题</summary><div class="qb-grid" id="generatedQuestions"></div></details>
    <details><summary>我在赌什么？</summary><div class="qb-grid" id="betQuestions"></div></details>
    <details><summary>风险诊断</summary><div class="qb-grid" id="riskQuestions"></div></details>
    <details><summary>情景分析</summary><div class="qb-grid" id="whatIfQuestions"></div></details>
    <details><summary>持仓重叠</summary><div class="qb-grid" id="overlapQuestions"></div></details>
    <details><summary>收益归因</summary><div class="qb-grid" id="performanceQuestions"></div></details>
    <details><summary>回撤与调仓</summary><div class="qb-grid" id="drawdownQuestions"></div></details>
  </aside>

  <main class="ai-chatbox">
    <h2 class="ai-chat-title">Ask Cat</h2>
    <div class="ai-chat-scroll">
      <section class="ai-welcome">
        <img class="ai-welcome-art" src="/static/icons/ai-welcome-book.svg" alt="" width="130" height="87" />
        <div class="ai-welcome-copy">
          <b>你想先了解组合的哪一部分？</b>
          <p>可以问仓位集中度、ETF 重叠、收益来源、回撤或假设情景。</p>
        </div>
      </section>

      <div id="convArea" aria-live="polite"></div>
    </div>

    <div class="ai-composer">
      <div id="askStatus"></div>
      <div class="ai-ask-bar">
        <input id="aiAskInput" class="ai-input" placeholder="输入关于你的组合的问题…" onkeydown="if(event.key==='Enter')doAsk()" />
        <button id="askBtn" class="ai-send" type="button" onclick="doAsk()" aria-label="发送">
          <img src="/static/icons/ai-send-arrow.svg" alt="" width="27" height="27" />
        </button>
      </div>
      <small>AI 可能会出错，重要数字请回到 Portfolio 核对。</small>
    </div>
  </main>
</div>
"""


@router.get("/ai")
def ai_page(request: Request):
    return HTMLResponse(
        render_layout(request, "AI 分析", _BODY + _SCRIPTS, "/ai", get_lang(request), head_extra=_HEAD)
    )
