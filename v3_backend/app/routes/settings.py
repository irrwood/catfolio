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
)
from app.lab import history_cache_age_seconds
from app.settings import ROOT, V2_DIR
from app.components import wrap_v4_layout
from app.i18n import get_lang
from datetime import datetime, timezone
import json

router = APIRouter(tags=["pages"])


@router.get("/settings")
def settings_page(request: Request):
    fmp_set = secret_value("FMP_API_KEY") is not None
    finnhub_set = secret_value("FINNHUB_API_KEY") is not None
    fred_set = secret_value("FRED_API_KEY") is not None
    massive_set = secret_value("MASSIVE_API_KEY") is not None
    t212_set = secret_value("TRADING212_API_KEY") is not None
    deepseek_set = secret_value("DEEPSEEK_API_KEY") is not None

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
    <div style="display:flex;flex-direction:column;gap:16px;padding:0 var(--sp-xl) var(--sp-xl);">
      {key_row("TRADING212_API_KEY", "Trading 212 API Key", "同步持仓、平均成本、账户现金", t212_set)}
      {key_row("FMP_API_KEY", "FMP API Key (Financial Modeling Prep)", "美股 P/E、P/S、EPS 成长率估值", fmp_set)}
      {key_row("FINNHUB_API_KEY", "Finnhub API Key", "备用估值接口，FMP 缺失时自动切换", finnhub_set)}
      {key_row("DEEPSEEK_API_KEY", "DeepSeek API Key", "AI 组合分析、风险诊断、策略评价", deepseek_set)}
      {key_row("MASSIVE_API_KEY", "Massive API Key", "盘后异动、期权链快照（可选）", massive_set)}
      {key_row("FRED_API_KEY", "FRED API Key (St. Louis Fed)", "宏观利率、通胀数据（可选）", fred_set, border=False)}
    </div>
    <div id="keyStatus" style="padding:0 var(--sp-xl) var(--sp-xl);font-size:var(--text-sm);display:none;"></div>
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
          <strong style="display:block;">Yahoo 实时现价缓存</strong>
          <span style="font-size:12px;color:var(--muted)">当前缓存年龄：{fmt_age(market_cache)}。过期时间：60 秒。</span>
        </div>
        <button class="btn" onclick="triggerRefresh('market')">强制刷新</button>
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
          <td class="font-mono">{ROOT}</td>
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

<script>
  async function saveKey(envName, btn) {{
    const input = document.getElementById('input_' + envName);
    const value = input.value.trim();
    if (!value) return;
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i>';
    try {{
      const res = await fetch('/api/settings/save-key', {{
        method: 'POST',
        headers: {{'Content-Type': 'application/json'}},
        body: JSON.stringify({{name: envName, value}})
      }});
      const data = await res.json();
      if (data.ok) {{
        input.value = '';
        input.placeholder = '已设置，留空则不修改';
        const badge = document.getElementById('badge_' + envName);
        badge.innerHTML = '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive);white-space:nowrap"><div class="status-dot"></div> 已设置</span>';
        btn.innerHTML = '<i class="fa-solid fa-check"></i> 已保存';
        setTimeout(() => {{ btn.innerHTML = orig; btn.disabled = false; }}, 2000);
      }} else {{
        btn.innerHTML = '<i class="fa-solid fa-xmark"></i> 失败';
        setTimeout(() => {{ btn.innerHTML = orig; btn.disabled = false; }}, 2000);
      }}
    }} catch(e) {{
      btn.innerHTML = orig; btn.disabled = false;
    }}
  }}

  async function triggerRefresh(type) {{
    const statusEl = document.getElementById("settingsStatus");
    statusEl.className = "status";
    if (type === 'market') {{
      statusEl.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 正在强制拉取最新行情...';
      try {{
        const response = await fetch("/api/refresh/market?force=true", {{ method: "POST" }});
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "status positive";
        statusEl.innerHTML = '<i class="fa-solid fa-check"></i> 行情刷新完成！';
        setTimeout(() => location.reload(), 1000);
      }} catch (err) {{
        statusEl.className = "status negative";
        statusEl.innerHTML = '<i class="fa-solid fa-xmark"></i> 刷新失败。';
      }}
    }} else if (type === 'history') {{
      statusEl.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 正在重新获取所有标的历史价格...';
      try {{
        const response = await fetch("/api/lab/refresh-history?force=true", {{ method: "POST" }});
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "status positive";
        statusEl.innerHTML = '<i class="fa-solid fa-check"></i> 历史价格刷新完成！';
        setTimeout(() => location.reload(), 1000);
      }} catch (err) {{
        statusEl.className = "status negative";
        statusEl.innerHTML = '<i class="fa-solid fa-xmark"></i> 刷新失败。';
      }}
    }} else if (type === 'fundamentals') {{
      statusEl.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 正在重新拉取 FMP 估值数据...';
      try {{
        const response = await fetch("/api/refresh/fundamentals?force=true", {{ method: "POST" }});
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "status positive";
        statusEl.innerHTML = '<i class="fa-solid fa-check"></i> 估值数据刷新完成！';
        setTimeout(() => location.reload(), 1500);
      }} catch (err) {{
        statusEl.className = "status negative";
        statusEl.innerHTML = '<i class="fa-solid fa-xmark"></i> 刷新失败。';
      }}
    }} else if (type === 'after-hours') {{
      statusEl.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 正在拉取 Massive 盘后数据...';
      try {{
        const response = await fetch("/api/refresh/after-hours?force=true", {{ method: "POST" }});
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "status positive";
        statusEl.innerHTML = '<i class="fa-solid fa-check"></i> 盘后数据刷新完成！';
        setTimeout(() => location.reload(), 1000);
      }} catch (err) {{
        statusEl.className = "status negative";
        statusEl.innerHTML = '<i class="fa-solid fa-xmark"></i> 刷新失败。';
      }}
    }}
  }}
</script>
"""
    return HTMLResponse(wrap_v4_layout("系统设置", content, "/settings", get_lang(request)))


_ALLOWED_KEYS = {
    "TRADING212_API_KEY", "FMP_API_KEY", "FINNHUB_API_KEY",
    "DEEPSEEK_API_KEY", "MASSIVE_API_KEY", "FRED_API_KEY",
}

@router.post("/api/settings/save-key")
async def save_key_api(request: Request):
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
