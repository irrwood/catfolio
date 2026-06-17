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
from app.components import wrap_v4_layout
from app.i18n import get_lang
from app.ai import PROVIDERS as AI_PROVIDERS, DEFAULT_PROVIDER as AI_DEFAULT
from datetime import datetime, timezone
import json

router = APIRouter(tags=["pages"])


@router.get("/settings")
def settings_page(request: Request):
    demo_on = demo_mode()
    if demo_on:
        fmp_set = finnhub_set = fred_set = massive_set = t212_set = False
        ai_provider = AI_DEFAULT
    else:
        fmp_set = secret_value("FMP_API_KEY") is not None
        finnhub_set = secret_value("FINNHUB_API_KEY") is not None
        fred_set = secret_value("FRED_API_KEY") is not None
        massive_set = secret_value("MASSIVE_API_KEY") is not None
        t212_set = secret_value("TRADING212_API_KEY") is not None
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
            '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive);white-space:nowrap"><div class="status-dot"></div> 已设置</span>'
            if is_set else
            '<span class="market-status-badge" style="color:var(--negative);background:var(--negative-soft);border-color:var(--negative);white-space:nowrap"><div class="status-dot danger"></div> 未配置</span>'
        )
        ph = "已设置，留空则不修改" if is_set else "粘贴 API Key…"
        border_style = "padding-bottom:14px;border-bottom:1px solid var(--line);" if border else ""
        return f"""<div style="display:flex;flex-direction:column;gap:8px;{border_style}">
          <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:12px;">
            <div>
              <strong style="display:block;font-size:var(--text-sm)">{label}</strong>
              <span style="font-size:var(--text-xs);color:var(--muted)">{description}</span>
            </div>
            <div id="badge_{env_name}" style="flex-shrink:0">{badge}</div>
          </div>
          <div style="display:flex;gap:8px;align-items:center;">
            <input type="password" id="input_{env_name}"
              placeholder="{ph}"
              autocomplete="off"
              style="flex:1;background:var(--soft);border:1px solid var(--line);border-radius:var(--radius-md);
                     padding:8px 12px;color:var(--ink);font-family:var(--font-mono);font-size:var(--text-sm);outline:none;"
              onfocus="this.style.borderColor='var(--accent)'"
              onblur="this.style.borderColor='var(--line)'"
            />
            <button class="btn primary" style="white-space:nowrap;flex-shrink:0;"
              onclick="saveKey('{env_name}', this)">
              <i class="fa-solid fa-floppy-disk"></i> 保存
            </button>
          </div>
        </div>"""

    def provider_btn(value, label, key_set, active):
        is_active = active == value
        css = (
            "background:var(--accent);color:#fff;border-color:var(--accent);"
            if is_active else
            "background:var(--soft);color:var(--ink);border-color:var(--line);"
        )
        warn = "" if key_set else '<span title="该提供方的 API Key 未配置" style="color:var(--warn)">●</span> '
        return (
            f'<button class="ai-provider-btn" data-provider="{value}" onclick="setProvider(\'{value}\', this)" '
            f'style="border:1px solid var(--line);border-radius:999px;padding:7px 14px;font-size:var(--text-sm);'
            f'font-weight:600;cursor:pointer;font-family:inherit;white-space:nowrap;{css}">{warn}{label}</button>'
        )

    # Generate AI provider key rows + switcher buttons from the registry so new
    # providers added in ai.py appear here automatically.
    ai_set = {name: False for name in AI_PROVIDERS}
    if not demo_on:
        ai_set = {name: secret_value(p["key"]) is not None for name, p in AI_PROVIDERS.items()}
    ai_key_rows = "".join(
        key_row(p["key"], f"{p['label']} API Key", p.get("hint", "AI 分析提供方"), ai_set[name])
        for name, p in AI_PROVIDERS.items()
    )
    ai_switch_btns = "".join(
        provider_btn(name, p["label"], ai_set[name], ai_provider)
        for name, p in AI_PROVIDERS.items()
    )
    ai_current_label = AI_PROVIDERS[ai_provider]["label"]
    credential_panel = (
        """<div style="padding:0 var(--sp-xl) var(--sp-xl);">
      <div style="padding:var(--sp-md);background:var(--accent-soft);border:1px solid var(--line);border-radius:var(--radius-md);font-size:var(--text-sm);color:var(--ink);">
        当前是演示数据模式。为了方便开源演示和截图，此页面不会读取或显示本机 Keychain / 环境变量里的凭证状态。
        关闭演示模式后才会显示 API Key 配置。
      </div>
    </div>"""
        if demo_on else
        f"""<div style="display:flex;flex-direction:column;gap:16px;padding:0 var(--sp-xl) var(--sp-xl);">
      {key_row("TRADING212_API_KEY", "Trading 212 API Key", "同步持仓、平均成本、账户现金", t212_set)}
      {key_row("FMP_API_KEY", "FMP API Key (Financial Modeling Prep)", "美股 P/E、P/S、EPS 成长率估值", fmp_set)}
      {key_row("FINNHUB_API_KEY", "Finnhub API Key", "备用估值接口，FMP 缺失时自动切换", finnhub_set)}
      {ai_key_rows}
      {key_row("MASSIVE_API_KEY", "Massive API Key", "盘后异动、期权链快照（可选）", massive_set)}
      {key_row("FRED_API_KEY", "FRED API Key (St. Louis Fed)", "宏观利率、通胀数据（可选）", fred_set, border=False)}
    </div>"""
    )
    ai_panel = (
        """<div style="padding:0 var(--sp-xl) var(--sp-xl);">
      <div style="font-size:var(--text-sm);color:var(--muted);">演示数据模式下 AI 提供方配置已隐藏。</div>
    </div>"""
        if demo_on else
        f"""<div style="padding:0 var(--sp-xl) var(--sp-xl);">
      <div style="display:flex;flex-wrap:wrap;gap:6px;">
        {ai_switch_btns}
      </div>
      <div id="aiProviderStatus" style="margin-top:10px;font-size:var(--text-xs);color:var(--muted);">
        当前：<strong style="color:var(--ink)">{ai_current_label}</strong>
      </div>
    </div>"""
    )
    telegram_configured = False
    telegram_key_rows = (
        """<div style="padding:0 var(--sp-xl) var(--sp-xl);">
      <div style="padding:var(--sp-md);background:var(--accent-soft);border:1px solid var(--line);border-radius:var(--radius-md);font-size:var(--text-sm);">
        演示数据模式下 Telegram 凭证配置已隐藏。
      </div>
    </div>"""
        if demo_on else
        f"""<div style="padding:0 var(--sp-xl) var(--sp-xl);display:flex;flex-direction:column;gap:16px;">

    <div style="padding:var(--sp-md);background:var(--accent-soft);border-radius:var(--radius-md);font-size:var(--text-sm);">
      <b>配置步骤：</b>
      1. 在 Telegram 找 <code>@BotFather</code>，发 <code>/newbot</code> 创建机器人，复制 Token。
      2. 向你的新机器人发任意消息，然后点「获取 Chat ID」。
      3. 点「发测试消息」验证。
    </div>

    {key_row("TELEGRAM_BOT_TOKEN", "Bot Token", "从 @BotFather 获取，格式：123456:ABCdef…", secret_value("TELEGRAM_BOT_TOKEN") is not None)}

    <div style="display:flex;flex-direction:column;gap:8px;">
      <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:12px;">
        <div>
          <strong style="display:block;font-size:var(--text-sm)">Chat ID</strong>
          <span style="font-size:var(--text-xs);color:var(--muted)">你的用户 ID 或频道 ID（负数为群组）</span>
        </div>
        <div id="badge_TELEGRAM_CHAT_ID" style="flex-shrink:0">
          { '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive);white-space:nowrap"><div class="status-dot"></div> 已设置</span>' if secret_value("TELEGRAM_CHAT_ID") else '<span class="market-status-badge" style="color:var(--negative);background:var(--negative-soft);border-color:var(--negative);white-space:nowrap"><div class="status-dot danger"></div> 未配置</span>' }
        </div>
      </div>
      <div style="display:flex;gap:8px;align-items:center;">
        <input type="text" id="input_TELEGRAM_CHAT_ID"
          placeholder="{ '已设置，留空则不修改' if secret_value('TELEGRAM_CHAT_ID') else '点右边按钮自动获取…' }"
          autocomplete="off"
          style="flex:1;background:var(--soft);border:1px solid var(--line);border-radius:var(--radius-md);
                 padding:8px 12px;color:var(--ink);font-family:var(--font-mono);font-size:var(--text-sm);outline:none;"
          onfocus="this.style.borderColor='var(--accent)'"
          onblur="this.style.borderColor='var(--line)'"
        />
        <button class="btn" style="white-space:nowrap;flex-shrink:0;" onclick="getChatId()">
          <i class="fa-solid fa-magnifying-glass"></i> 获取 Chat ID
        </button>
        <button class="btn primary" style="white-space:nowrap;flex-shrink:0;"
          onclick="saveKey('TELEGRAM_CHAT_ID', this)">
          <i class="fa-solid fa-floppy-disk"></i> 保存
        </button>
      </div>
    </div>

    <div style="display:flex;gap:8px;padding-top:4px;">
      <button class="btn" onclick="tgTest(this)">
        <i class="fa-solid fa-paper-plane"></i> 发测试消息
      </button>
      <div id="tg_test_result" style="font-size:var(--text-sm);display:flex;align-items:center;color:var(--muted);"></div>
    </div>
  </div>"""
    )
    if not demo_on:
        telegram_configured = bool(secret_value("TELEGRAM_BOT_TOKEN") and secret_value("TELEGRAM_CHAT_ID"))
    root_display = "隐藏（演示数据模式）" if demo_on else str(ROOT)

    content = f"""<div class="v4-hero">
  <div class="v4-hero-text">
    <h1>系统配置与状态</h1>
    <p>管理本地量化分析服务的外部凭证状态、数据刷新策略及缓存生命周期。</p>
  </div>
</div>

<div class="grid-2" style="margin-top:20px;">
  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><i class="fa-solid fa-key" style="color:var(--accent)"></i> 外部 API 凭证</h2>
        <div class="v4-card-subtitle">Key 保存至系统密钥库，不写入任何文件。留空点保存 = 不修改。</div>
      </div>
    </div>
    {credential_panel}
    <div id="keyStatus" style="padding:0 var(--sp-xl) var(--sp-xl);font-size:var(--text-sm);display:none;"></div>
  </div>

  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><i class="fa-solid fa-robot" style="color:var(--accent)"></i> AI 提供方</h2>
        <div class="v4-card-subtitle">选择驱动 AI 组合分析的模型。切换前请先填好对应的 API Key（● 表示未配置）。</div>
      </div>
    </div>
    {ai_panel}
  </div>

  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><i class="fa-solid fa-flask" style="color:var(--accent)"></i> 演示数据模式</h2>
        <div class="v4-card-subtitle">开启后用内置样例组合替代真实数据，适合截图、演示或分享，不暴露你的真实持仓。</div>
      </div>
    </div>
    <div style="padding:0 var(--sp-xl) var(--sp-xl);display:flex;justify-content:space-between;align-items:center;gap:12px;">
      <div>
        <strong style="display:block;">假数据模式</strong>
        <span id="demoModeState" style="font-size:var(--text-xs);color:var(--muted)">当前：{"已开启 — 显示样例数据" if demo_on else "已关闭 — 显示真实数据"}</span>
      </div>
      <button class="btn {"primary" if demo_on else ""}" id="demoModeBtn" data-on="{"1" if demo_on else "0"}" onclick="toggleDemoMode()">
        {"关闭假数据" if demo_on else "开启假数据"}
      </button>
    </div>
  </div>

  <div class="v4-card">
    <div class="v4-card-header">
      <div>
        <h2 class="v4-card-title"><i class="fa-solid fa-database"></i> 数据缓存生命周期</h2>
        <div class="v4-card-subtitle">系统采用增量与缓存机制，避免频繁调用外部接口导致封禁。</div>
      </div>
    </div>
    <div style="display:flex;flex-direction:column;gap:14px;">
      <div style="display:flex;justify-content:space-between;align-items:center;padding-bottom:10px;border-bottom:1px solid var(--line);">
        <div>
          <strong style="display:block;">Trading 212 持仓同步</strong>
          <span style="font-size:12px;color:var(--muted)">重新拉取持仓与平均成本，并验证 API 凭证。</span>
        </div>
        <button class="btn" onclick="triggerRefresh('trading212')">立即同步</button>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;padding-bottom:10px;border-bottom:1px solid var(--line);">
        <div>
          <strong style="display:block;">历史日线价格缓存 (Lab 回测)</strong>
          <span style="font-size:12px;color:var(--muted)">当前缓存年龄：{fmt_age(history_cache)}。过期时间：12 小时。</span>
        </div>
        <button class="btn" onclick="triggerRefresh('history')">刷新历史</button>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;padding-bottom:10px;border-bottom:1px solid var(--line);">
        <div>
          <strong style="display:block;">FMP 估值数据缓存</strong>
          <span style="font-size:12px;color:var(--muted)">当前缓存年龄：{fmt_age(fundamentals_cache)} · 覆盖 {fund_tickers}/{usd_count} 只美股。过期时间：12 小时。</span>
        </div>
        <button class="btn" onclick="triggerRefresh('fundamentals')">刷新估值</button>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <div>
          <strong style="display:block;">Massive 盘后异动缓存</strong>
          <span style="font-size:12px;color:var(--muted)">当前缓存年龄：{fmt_age(after_hours_cache)}。过期时间：15 分钟。</span>
        </div>
        <button class="btn" onclick="triggerRefresh('after-hours')">刷新盘后</button>
      </div>
    </div>
    <div id="settingsStatus" class="status" style="margin-top:12px;"></div>
  </div>
</div>

<div class="v4-card" style="margin-top:24px;">
  <div class="v4-card-header">
    <div>
      <h2 class="v4-card-title"><i class="fa-solid fa-sliders"></i> 本地系统配置与汇率基准</h2>
      <div class="v4-card-subtitle">显示当前本地数据处理路径和系统采用的汇率常量。</div>
    </div>
  </div>
  <div class="table-wrap">
    <table>
      <thead>
        <tr>
          <th>配置属性</th>
          <th>当前参数值</th>
          <th>说明</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>项目根路径 (Root)</td>
          <td class="font-mono">{root_display}</td>
          <td>数据保存与脚本执行的工作区</td>
        </tr>
        <tr>
          <td>V2 缓存路径</td>
          <td class="font-mono">outputs/portfolio_analysis_v2/</td>
          <td>主数据模型文件存放目录</td>
        </tr>
        <tr>
          <td>GBP/USD 汇率</td>
          <td class="font-mono">1.3460</td>
          <td>用于展示 Trading 212 英股/英镑资产价值的基准汇率</td>
        </tr>
        <tr>
          <td>EUR/USD 汇率</td>
          <td class="font-mono">1.1630</td>
          <td>用于折算欧洲股票资产价值的基准汇率</td>
        </tr>
      </tbody>
    </table>
  </div>
</div>

<div class="v4-card" style="margin-top:24px;">
  <div class="v4-card-header" style="margin-bottom:12px;cursor:pointer;" onclick="document.getElementById('settingsDeveloperAccordion').classList.toggle('hide')">
    <div>
      <h2 class="v4-card-title"><i class="fa-solid fa-code"></i> 本地 REST API 数据接口 (折叠)</h2>
      <div class="v4-card-subtitle">提供 JSON 接口供外部脚本或报表工具进行数据对接</div>
    </div>
  </div>
  <div id="settingsDeveloperAccordion" class="hide" style="display:flex;flex-direction:column;gap:12px;">
    <div class="table-wrap">
      <table>
        <thead>
          <tr>
            <th>接口名称</th>
            <th>请求路径</th>
            <th>核心字段说明</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>组合汇总数据</td>
            <td><a href="/api/portfolio/summary" class="font-mono" style="color:var(--accent);">/api/portfolio/summary</a></td>
            <td>成本、市值、未实现盈亏、按账户统计现金及货币分布</td>
          </tr>
          <tr>
            <td>当前持仓明细</td>
            <td><a href="/api/holdings" class="font-mono" style="color:var(--accent);">/api/holdings</a></td>
            <td>持股数、均价、买入成本（原币种）、本地现价和市值比重</td>
          </tr>
          <tr>
            <td>ETF 穿透 (Look-through)</td>
            <td><a href="/api/etf-lookthrough" class="font-mono" style="color:var(--accent);">/api/etf-lookthrough</a></td>
            <td>将 S&P 500 等 ETF 穿透到底层股票暴露，支持 cost / market 口径</td>
          </tr>
          <tr>
            <td>相关性矩阵</td>
            <td><a href="/api/chart/exposure" class="font-mono" style="color:var(--accent);">/api/chart/exposure</a></td>
            <td>返回供前端渲染集中度与归因子相关的格式化数据</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</div>

<div class="v4-card" style="margin-top:24px;">
  <div class="v4-card-header">
    <div>
      <h2 class="v4-card-title"><i class="fa-brands fa-telegram" style="color:#2AABEE"></i> Telegram 提醒</h2>
      <div class="v4-card-subtitle">仓位集中度、高估值、最大回撤超阈值时自动推送到 Telegram。每条提醒最多每小时推一次。</div>
    </div>
    <div id="tg_status_badge">
      { '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive)"><div class="status-dot"></div> 已配置</span>' if telegram_configured else '<span class="market-status-badge" style="color:var(--muted);background:var(--soft);border-color:var(--line)"><div class="status-dot" style="background:var(--muted)"></div> 未配置</span>' }
    </div>
  </div>
  {telegram_key_rows}
</div>

<script src="/static/settings.js"></script>
"""
    return HTMLResponse(wrap_v4_layout("系统设置", content, "/settings", get_lang(request)))


_ALLOWED_KEYS = {
    "TRADING212_API_KEY", "FMP_API_KEY", "FINNHUB_API_KEY",
    "MASSIVE_API_KEY", "FRED_API_KEY",
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
