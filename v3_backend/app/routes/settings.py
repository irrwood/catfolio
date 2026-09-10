"""Page route: settings."""
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, JSONResponse
from app.data_store import (
    secret_value,
    save_secret,
    live_cache_age_seconds,
    fundamentals_cache_age_seconds,
    after_hours_cache_age_seconds,
    load_json,
    demo_mode,
    set_demo_mode,
)
from app.lab import history_cache_age_seconds
from app.settings import ROOT, V2_DIR
from app.components import render_layout
from app.i18n import get_lang
from app.ai import PROVIDERS as AI_PROVIDERS, DEFAULT_PROVIDER as AI_DEFAULT
from datetime import datetime, timezone
import json

router = APIRouter(tags=["pages"])


@router.get("/settings")
def settings_page(request: Request):
    demo_on = demo_mode()
    if demo_on:
        fmp_set = finnhub_set = fred_set = massive_set = t212_set = t212_second_set = False
        plaid_client_set = plaid_secret_set = False
        ai_provider = AI_DEFAULT
    else:
        fmp_set = secret_value("FMP_API_KEY") is not None
        finnhub_set = secret_value("FINNHUB_API_KEY") is not None
        fred_set = secret_value("FRED_API_KEY") is not None
        massive_set = secret_value("MASSIVE_API_KEY") is not None
        t212_set = secret_value("TRADING212_API_KEY") is not None
        t212_second_set = secret_value("TRADING212_API_KEY_2") is not None
        plaid_client_set = secret_value("PLAID_CLIENT_ID") is not None
        plaid_secret_set = secret_value("PLAID_SECRET") is not None
        ai_provider = (secret_value("AI_PROVIDER") or AI_DEFAULT).strip().lower()
    if ai_provider not in AI_PROVIDERS:
        ai_provider = AI_DEFAULT

    market_cache = live_cache_age_seconds()
    history_cache = history_cache_age_seconds()
    fundamentals_cache = fundamentals_cache_age_seconds()
    after_hours_cache = after_hours_cache_age_seconds()

    # FMP coverage stats
    fund_data = load_json(V2_DIR / "fundamentals_data.json", {"rows": []})
    fund_tickers = len(fund_data.get("rows", []))
    pf_data = load_json(V2_DIR / "portfolio_analysis.json", {"holdings": []})
    usd_count = sum(1 for h in pf_data.get("holdings", []) if h.get("cost_currency") == "USD")
    
    def fmt_age(sec):
        if sec is None: return "无缓存"
        if sec < 60: return f"{sec} 秒前"
        if sec < 3600: return f"{sec // 60} 分钟前"
        return f"{sec // 3600} 小时前"

    def key_row(env_name, label, description, is_set, border=True):
        badge = (
            '<span class="settings-status settings-status-success"><span class="settings-status-dot"></span>已设置</span>'
            if is_set else
            '<span class="settings-status settings-status-muted"><span class="settings-status-dot"></span>未配置</span>'
        )
        ph = "已设置，留空则不修改" if is_set else "粘贴 API Key…"
        row_class = "settings-key-row" if border else "settings-key-row settings-key-row-last"
        return f"""<div class="{row_class}">
          <div class="settings-key-meta">
            <div class="settings-row-copy">
              <strong>{label}</strong>
              <span>{description}</span>
            </div>
            <div id="badge_{env_name}">{badge}</div>
          </div>
          <div class="settings-key-controls">
            <input class="settings-input" type="password" id="input_{env_name}"
              placeholder="{ph}" autocomplete="off" />
            <button class="settings-button settings-button-primary"
              onclick="saveKey('{env_name}', this)">
              <svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-save"></use></svg> 保存
            </button>
          </div>
        </div>"""

    def provider_btn(value, label, key_set, active):
        is_active = active == value
        active_class = " is-active" if is_active else ""
        warn = "" if key_set else '<span class="settings-provider-warning" title="该提供方的 API Key 未配置"></span>'
        return (
            f'<button class="ai-provider-btn{active_class}" data-provider="{value}" '
            f'onclick="setProvider(\'{value}\', this)">{warn}<span>{label}</span></button>'
        )

    # Generate AI provider key rows + switcher buttons from the registry so new
    # providers added in ai.py appear here automatically.
    ai_set = {name: False for name in AI_PROVIDERS}
    if not demo_on:
        ai_set = {name: secret_value(p["key"]) is not None for name, p in AI_PROVIDERS.items()}
    ai_provider_items = list(AI_PROVIDERS.items())
    ai_key_rows = "".join(
        key_row(
            p["key"],
            f"{p['label']} API Key",
            p.get("hint", "AI 分析提供方"),
            ai_set[name],
            border=index < len(ai_provider_items) - 1,
        )
        for index, (name, p) in enumerate(ai_provider_items)
    )
    ai_switch_btns = "".join(
        provider_btn(name, p["label"], ai_set[name], ai_provider)
        for name, p in AI_PROVIDERS.items()
    )
    ai_current_label = AI_PROVIDERS[ai_provider]["label"]
    credential_panel = (
        """<div class="settings-notice">
        当前是演示数据模式。为了方便开源演示和截图，此页面不会读取或显示本机 Keychain / 环境变量里的凭证状态。
        关闭演示模式后才会显示 API Key 配置。
      </div>"""
        if demo_on else
        f"""<div class="settings-credential-groups">
      <section class="settings-credential-group" aria-labelledby="settingsCredentialBroker">
        <header class="settings-credential-group-head">
          <strong id="settingsCredentialBroker">Trading 212 账户</strong>
          <span>分别保存两个账户的 Key，同步时自动合并。</span>
        </header>
        <div class="settings-key-list">
          {key_row("TRADING212_API_KEY", "Trading 212 API Key 1", "主账户：同步持仓、平均成本和账户现金", t212_set)}
          {key_row("TRADING212_API_KEY_2", "Trading 212 API Key 2", "第二账户（可选）：同步时自动合并两个账户", t212_second_set, border=False)}
        </div>
      </section>
      <section class="settings-credential-group" aria-labelledby="settingsCredentialMarket">
        <header class="settings-credential-group-head">
          <strong id="settingsCredentialMarket">市场数据</strong>
          <span>行情、估值、盘后异动和宏观数据源。</span>
        </header>
        <div class="settings-key-list">
          {key_row("FMP_API_KEY", "FMP API Key (Financial Modeling Prep)", "美股 P/E、P/S、EPS 成长率估值", fmp_set)}
          {key_row("FINNHUB_API_KEY", "Finnhub API Key", "备用估值接口，FMP 缺失时自动切换", finnhub_set)}
          {key_row("MASSIVE_API_KEY", "Massive API Key", "盘后异动、期权链快照（可选）", massive_set)}
          {key_row("FRED_API_KEY", "FRED API Key (St. Louis Fed)", "宏观利率、通胀数据（可选）", fred_set, border=False)}
        </div>
      </section>
      <section class="settings-credential-group" aria-labelledby="settingsCredentialBank">
        <header class="settings-credential-group-head">
          <strong id="settingsCredentialBank">Open Banking</strong>
          <span>Plaid Link 与交易同步；Access Token 另行加密保存在本机 SQLite。</span>
        </header>
        <div class="settings-key-list">
          {key_row("PLAID_CLIENT_ID", "Plaid Client ID", "Plaid Dashboard 的应用标识", plaid_client_set)}
          {key_row("PLAID_SECRET", "Plaid Secret", "默认连接 Sandbox；正式环境通过 PLAID_ENV 切换", plaid_secret_set, border=False)}
        </div>
      </section>
      <section class="settings-credential-group" aria-labelledby="settingsCredentialAi">
        <header class="settings-credential-group-head">
          <strong id="settingsCredentialAi">AI 模型</strong>
          <span>组合分析、风险诊断和收益归因的模型服务。</span>
        </header>
        <div class="settings-key-list">{ai_key_rows}</div>
      </section>
    </div>"""
    )
    ai_panel = (
        """<div class="settings-notice">演示数据模式下 AI 提供方配置已隐藏。</div>"""
        if demo_on else
        f"""<div class="settings-provider-panel">
      <div class="settings-provider-grid">
        {ai_switch_btns}
      </div>
      <div id="aiProviderStatus" class="settings-inline-status">
        当前：<strong>{ai_current_label}</strong>
      </div>
    </div>"""
    )
    telegram_configured = False
    telegram_key_rows = (
        """<div class="settings-notice">
        演示数据模式下 Telegram 凭证配置已隐藏。
    </div>"""
        if demo_on else
        f"""<div class="settings-key-list">

    <div class="settings-notice settings-notice-steps">
      <b>配置步骤：</b>
      1. 在 Telegram 找 <code>@BotFather</code>，发 <code>/newbot</code> 创建机器人，复制 Token。
      2. 向你的新机器人发任意消息，然后点「获取 Chat ID」。
      3. 点「发测试消息」验证。
    </div>

    {key_row("TELEGRAM_BOT_TOKEN", "Bot Token", "从 @BotFather 获取，格式：123456:ABCdef…", secret_value("TELEGRAM_BOT_TOKEN") is not None)}

    <div class="settings-key-row settings-key-row-last">
      <div class="settings-key-meta">
        <div class="settings-row-copy">
          <strong>Chat ID</strong>
          <span>你的用户 ID 或频道 ID（负数为群组）</span>
        </div>
        <div id="badge_TELEGRAM_CHAT_ID">
          { '<span class="settings-status settings-status-success"><span class="settings-status-dot"></span>已设置</span>' if secret_value("TELEGRAM_CHAT_ID") else '<span class="settings-status settings-status-muted"><span class="settings-status-dot"></span>未配置</span>' }
        </div>
      </div>
      <div class="settings-key-controls settings-key-controls-wide">
        <input class="settings-input" type="text" id="input_TELEGRAM_CHAT_ID"
          placeholder="{ '已设置，留空则不修改' if secret_value('TELEGRAM_CHAT_ID') else '点右边按钮自动获取…' }"
          autocomplete="off" />
        <button class="settings-button" onclick="getChatId()">
          <svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-search"></use></svg> 获取 Chat ID
        </button>
        <button class="settings-button settings-button-primary"
          onclick="saveKey('TELEGRAM_CHAT_ID', this)">
          <svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-save"></use></svg> 保存
        </button>
      </div>
    </div>

    <div class="settings-test-row">
      <button class="settings-button" onclick="tgTest(this)">
        <svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-paper-plane"></use></svg> 发测试消息
      </button>
      <div id="tg_test_result" class="settings-inline-status"></div>
    </div>
  </div>"""
    )
    if not demo_on:
        telegram_configured = bool(secret_value("TELEGRAM_BOT_TOKEN") and secret_value("TELEGRAM_CHAT_ID"))
    root_display = "隐藏（演示数据模式）" if demo_on else str(ROOT)

    content = f"""<main class="settings-page">
  <header class="settings-page-header">
    <h1>设置</h1>
    <p>管理数据源、AI 提供方、缓存和本地服务。</p>
  </header>

  <div class="settings-layout">
    <nav class="settings-nav" aria-label="设置分类">
      <a class="settings-nav-link is-active" href="#settings-general">常规</a>
      <a class="settings-nav-link" href="#settings-data">数据与缓存</a>
      <a class="settings-nav-link" href="#settings-ai">AI</a>
      <a class="settings-nav-link" href="#settings-credentials">凭证</a>
      <a class="settings-nav-link" href="#settings-system">系统</a>
      <a class="settings-nav-link" href="#settings-developer">开发者</a>
    </nav>

    <div class="settings-content">
      <section class="settings-section" id="settings-general">
        <div class="settings-section-header">
          <h2>常规</h2>
          <p>控制当前工作区使用真实数据还是演示组合。</p>
        </div>
        <div class="settings-group">
          <div class="settings-row">
            <div class="settings-row-copy">
              <strong>演示数据模式</strong>
              <span id="demoModeState">当前：{"已开启 — 显示样例数据" if demo_on else "已关闭 — 显示真实数据"}</span>
            </div>
            <button class="settings-button {"settings-button-primary" if demo_on else ""}" id="demoModeBtn" data-on="{"1" if demo_on else "0"}" onclick="toggleDemoMode()">
              {"关闭假数据" if demo_on else "开启假数据"}
            </button>
          </div>
        </div>
      </section>

      <section class="settings-section" id="settings-data">
        <div class="settings-section-header">
          <h2>数据与缓存</h2>
          <p>查看缓存状态，并在需要时单独刷新数据源。</p>
        </div>
        <div class="settings-group">
          <div class="settings-row">
            <div class="settings-row-copy"><strong>Trading 212 持仓</strong><span>重新拉取持仓与平均成本，并验证 API 凭证。</span></div>
            <button class="settings-button" onclick="triggerRefresh('trading212')">立即同步</button>
          </div>
          <div class="settings-row">
            <div class="settings-row-copy"><strong>历史日线价格</strong><span>当前缓存： {fmt_age(history_cache)} · 每 12 小时过期</span></div>
            <button class="settings-button" onclick="triggerRefresh('history')">刷新历史</button>
          </div>
          <div class="settings-row">
            <div class="settings-row-copy"><strong>FMP 估值数据</strong><span>当前缓存： {fmt_age(fundamentals_cache)} · 覆盖 {fund_tickers}/{usd_count} 只美股</span></div>
            <button class="settings-button" onclick="triggerRefresh('fundamentals')">刷新估值</button>
          </div>
          <div class="settings-row">
            <div class="settings-row-copy"><strong>Massive 盘后异动</strong><span>当前缓存： {fmt_age(after_hours_cache)} · 每 15 分钟过期</span></div>
            <button class="settings-button" onclick="triggerRefresh('after-hours')">刷新盘后</button>
          </div>
        </div>
        <div id="settingsStatus" class="settings-action-status" aria-live="polite"></div>
      </section>

      <section class="settings-section" id="settings-ai">
        <div class="settings-section-header">
          <h2>AI 提供方</h2>
          <p>选择用于组合总结、风险诊断和收益归因的模型。</p>
        </div>
        <div class="settings-group settings-group-padded">{ai_panel}</div>
      </section>

      <section class="settings-section" id="settings-credentials">
        <div class="settings-section-header">
          <h2>凭证</h2>
          <p>密钥保存到系统 Keychain，不会写入项目文件。</p>
        </div>
        <details class="settings-disclosure" open>
          <summary>
            <span><strong>外部 API 凭证</strong><small>行情、估值、宏观数据和 AI 服务</small></span>
            <span class="settings-chevron" aria-hidden="true"></span>
          </summary>
          <div class="settings-disclosure-body">{credential_panel}</div>
        </details>
        <details class="settings-disclosure">
          <summary>
            <span><strong>Telegram 提醒</strong><small>集中度、估值和回撤阈值通知</small></span>
            <span class="settings-summary-status" id="tg_status_badge">
              { '<span class="settings-status settings-status-success"><span class="settings-status-dot"></span>已配置</span>' if telegram_configured else '<span class="settings-status settings-status-muted"><span class="settings-status-dot"></span>未配置</span>' }
              <span class="settings-chevron" aria-hidden="true"></span>
            </span>
          </summary>
          <div class="settings-disclosure-body">{telegram_key_rows}</div>
        </details>
        <div id="keyStatus" class="settings-action-status" aria-live="polite"></div>
      </section>

      <section class="settings-section" id="settings-system">
        <div class="settings-section-header">
          <h2>系统</h2>
          <p>当前工作区路径、缓存目录和汇率基准。</p>
        </div>
        <div class="settings-group">
          <div class="settings-row settings-system-row"><div class="settings-row-copy"><strong>项目根路径</strong><span>数据保存与脚本执行的工作区</span></div><code>{root_display}</code></div>
          <div class="settings-row settings-system-row"><div class="settings-row-copy"><strong>V2 缓存路径</strong><span>主数据模型文件存放目录</span></div><code>outputs/portfolio_analysis_v2/</code></div>
          <div class="settings-row settings-system-row"><div class="settings-row-copy"><strong>GBP/USD 汇率</strong><span>英股与英镑资产的展示基准</span></div><code>1.3460</code></div>
          <div class="settings-row settings-system-row"><div class="settings-row-copy"><strong>EUR/USD 汇率</strong><span>欧洲股票资产的换算基准</span></div><code>1.1630</code></div>
        </div>
      </section>

      <section class="settings-section" id="settings-developer">
        <div class="settings-section-header">
          <h2>开发者</h2>
          <p>供本地脚本和报表工具读取的 JSON 接口。</p>
        </div>
        <details class="settings-disclosure">
          <summary>
            <span><strong>本地 REST API</strong><small>4 个只读数据接口</small></span>
            <span class="settings-chevron" aria-hidden="true"></span>
          </summary>
          <div class="settings-disclosure-body settings-api-list">
            <a class="settings-api-row" href="/api/portfolio/summary"><span><strong>组合汇总数据</strong><small>成本、市值、未实现盈亏和账户现金</small></span><code>/api/portfolio/summary</code></a>
            <a class="settings-api-row" href="/api/holdings"><span><strong>当前持仓明细</strong><small>股数、均价、成本、现价和市值比重</small></span><code>/api/holdings</code></a>
            <a class="settings-api-row" href="/api/etf-lookthrough"><span><strong>ETF 穿透</strong><small>底层股票暴露，支持成本和市值口径</small></span><code>/api/etf-lookthrough</code></a>
            <a class="settings-api-row" href="/api/chart/exposure"><span><strong>相关性矩阵</strong><small>集中度与归因相关的格式化数据</small></span><code>/api/chart/exposure</code></a>
          </div>
        </details>
      </section>
    </div>
  </div>
</main>
<script src="/static/settings.js"></script>
"""
    return HTMLResponse(render_layout(
        request,
        "系统设置",
        content,
        "/settings",
        get_lang(request),
        head_extra='<link rel="stylesheet" href="/static/settings.css" />',
    ))


_ALLOWED_KEYS = {
    "TRADING212_API_KEY", "TRADING212_API_KEY_2", "FMP_API_KEY", "FINNHUB_API_KEY",
    "MASSIVE_API_KEY", "FRED_API_KEY",
    "PLAID_CLIENT_ID", "PLAID_SECRET",
    "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID",
    "AI_PROVIDER",
    # Every AI provider's API-key and model-override names, from the registry.
    *(p["key"] for p in AI_PROVIDERS.values()),
    *(p["model_key"] for p in AI_PROVIDERS.values()),
}

@router.post("/api/settings/save-key")
async def save_key_api(request: Request):
    if demo_mode():
        return JSONResponse({"ok": False, "error": "demo mode hides credential storage"}, status_code=403)
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"ok": False, "error": "invalid JSON"}, status_code=400)
    name = str(body.get("name", "")).strip()
    value = str(body.get("value", "")).strip()
    if name not in _ALLOWED_KEYS:
        return JSONResponse({"ok": False, "error": "unknown key"}, status_code=400)
    if not value:
        return JSONResponse({"ok": False, "error": "empty value"})
    ok = save_secret(name, value)
    return JSONResponse({"ok": ok})


@router.post("/api/settings/demo-mode")
async def demo_mode_api(request: Request):
    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"ok": False, "error": "invalid JSON"}, status_code=400)
    on = bool(body.get("on"))
    ok = set_demo_mode(on)
    return JSONResponse({"ok": ok, "demo": demo_mode()})


@router.post("/api/telegram/test")
async def telegram_test():
    from app.telegram_notify import test_connection
    result = test_connection()
    return JSONResponse({"ok": result.get("ok", False), "error": result.get("description") or result.get("error")})


@router.get("/api/telegram/get-chat-id")
async def telegram_get_chat_id(token: str = None):
    from app.telegram_notify import get_chat_id
    from app.data_store import secret_value
    t = token or secret_value("TELEGRAM_BOT_TOKEN")
    if not t:
        return JSONResponse({"ok": False, "error": "Bot Token 未配置，请先保存 Token 再获取 Chat ID。"})
    return JSONResponse(get_chat_id(t))
