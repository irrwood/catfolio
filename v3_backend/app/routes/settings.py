"""Page route: settings."""
from fastapi import APIRouter
from fastapi.responses import HTMLResponse
from app.data_store import (
    secret_value,
    live_cache_age_seconds,
    fundamentals_cache_age_seconds,
    after_hours_cache_age_seconds,
    load_json,
)
from app.lab import history_cache_age_seconds
from app.settings import ROOT, V2_DIR
from app.components import wrap_v4_layout
from datetime import datetime, timezone
import json

router = APIRouter(tags=["pages"])


@router.get("/settings")
def settings_page():
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
        <h2 class="v4-card-title"><i class="fa-solid fa-key text-accent" style="color:var(--accent)"></i> 外部 API 凭证状态</h2>
        <div class="v4-card-subtitle">系统从环境变量或 macOS Keychain 中安全读取秘钥，不保存在本地文件中。</div>
      </div>
    </div>
    <div style="display:flex;flex-direction:column;gap:14px;">
      <div style="display:flex;justify-content:space-between;align-items:center;padding-bottom:10px;border-bottom:1px solid var(--line);">
        <div>
          <strong style="display:block;">FMP API Key (Financial Modeling Prep)</strong>
          <span style="font-size:12px;color:var(--muted)">用于获取美股 P/E, P/S 等估值及 EPS 同比成长率数据。</span>
        </div>
        <div>
          { '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive);"><div class="status-dot"></div> 已设置</span>' if fmp_set else '<span class="market-status-badge" style="color:var(--negative);background:var(--negative-soft);border-color:var(--negative);"><div class="status-dot danger"></div> 未配置</span>' }
        </div>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;padding-bottom:10px;border-bottom:1px solid var(--line);">
        <div>
          <strong style="display:block;">Finnhub API Key</strong>
          <span style="font-size:12px;color:var(--muted)">备用美股基本面接口。在 FMP Key 缺失或失效时使用。</span>
        </div>
        <div>
          { '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive);"><div class="status-dot"></div> 已设置</span>' if finnhub_set else '<span class="market-status-badge" style="color:var(--negative);background:var(--negative-soft);border-color:var(--negative);"><div class="status-dot danger"></div> 未配置</span>' }
        </div>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <div>
          <strong style="display:block;">FRED API Key (St. Louis Fed)</strong>
          <span style="font-size:12px;color:var(--muted)">用于获取宏观国债利率、联邦基金基准利率及通胀率。</span>
        </div>
        <div>
          { '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive);"><div class="status-dot"></div> 已设置</span>' if fred_set else '<span class="market-status-badge" style="color:var(--negative);background:var(--negative-soft);border-color:var(--negative);"><div class="status-dot danger"></div> 未配置</span>' }
        </div>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <div>
          <strong style="display:block;">Massive API Key (盘后数据)</strong>
          <span style="font-size:12px;color:var(--muted)">用于获取盘后异动、期权链快照和市值参考数据。</span>
        </div>
        <div>
          { '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive);"><div class="status-dot"></div> 已设置</span>' if massive_set else '<span class="market-status-badge" style="color:var(--negative);background:var(--negative-soft);border-color:var(--negative);"><div class="status-dot danger"></div> 未配置</span>' }
        </div>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;padding-bottom:10px;border-bottom:1px solid var(--line);">
        <div>
          <strong style="display:block;">Trading 212 API Key (交易账户)</strong>
          <span style="font-size:12px;color:var(--muted)">用于同步持仓数据、平均买入成本和账户现金快照。</span>
        </div>
        <div>
          { '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive);"><div class="status-dot"></div> 已设置</span>' if t212_set else '<span class="market-status-badge" style="color:var(--negative);background:var(--negative-soft);border-color:var(--negative);"><div class="status-dot danger"></div> 未配置</span>' }
        </div>
      </div>
      <div style="display:flex;justify-content:space-between;align-items:center;">
        <div>
          <strong style="display:block;">DeepSeek API Key (AI 分析)</strong>
          <span style="font-size:12px;color:var(--muted)">用于 AI 组合总结、风险诊断、收益归因和情景分析。</span>
        </div>
        <div>
          { '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive);"><div class="status-dot"></div> 已设置</span>' if deepseek_set else '<span class="market-status-badge" style="color:var(--negative);background:var(--negative-soft);border-color:var(--negative);"><div class="status-dot danger"></div> 未配置</span>' }
        </div>
      </div>
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
    return HTMLResponse(wrap_v4_layout("系统设置", content, "/settings"))
