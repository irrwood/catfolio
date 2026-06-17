"""Shared UI components used across route modules."""

import re as _re
import time as _time
from datetime import datetime, timezone
from pathlib import Path
from app.data_store import current_snapshot, demo_mode
from app.i18n import t_block

_STATIC_DIR = Path(__file__).resolve().parent / "static"


def _version_assets(html: str) -> str:
    """Append ?v=<mtime> to every local /static asset URL so browsers refetch
    whenever a file changes (cache-busting). Without this, extracted CSS/JS stay
    cached and edits never reach users."""
    def repl(match):
        path = match.group(1)
        rel = path[len("/static/"):]
        try:
            mtime = int((_STATIC_DIR / rel).stat().st_mtime)
            return f"{path}?v={mtime}"
        except OSError:
            return path
    return _re.sub(r'(/static/[^"?\s>]+\.(?:css|js|png|jpg|jpeg|webp|svg))', repl, html)


def wrap_v4_layout(title: str, content: str, active_page: str, lang: str = "zh", head_extra: str = "") -> str:
    demo_on = demo_mode()
    try:
        snapshot = current_snapshot()
        trading_unix = snapshot["trading212"].get("as_of_unix")
        market_unix = snapshot["market"].get("as_of_unix")
        fundamentals_unix = snapshot["fundamentals"].get("as_of_unix")
    except Exception:
        trading_unix = market_unix = fundamentals_unix = None

    def fmt_time(val):
        if not val:
            return "未刷新"
        return datetime.fromtimestamp(int(val), tz=timezone.utc).astimezone().strftime("%H:%M")

    nav_links = [
        ("/", "数据控制台", "fa-chart-pie"),
        ("/lab", "Portfolio Lab", "fa-flask"),
        ("/backtest", "回测与优化", "fa-calculator"),
        ("/strategy", "策略回测", "fa-vials"),
        ("/returns", "收益对比", "fa-chart-line"),
        ("/heatmap", "持仓热力图", "fa-border-all"),
        ("/report", "审计报表", "fa-file-invoice-dollar"),
        ("/ai", "AI 分析", "fa-robot"),
        ("/import", "导入数据", "fa-file-import"),
        ("/settings", "系统设置", "fa-sliders")
    ]
    
    links_html = ""
    for href, label, icon in nav_links:
        is_active = "active" if href == active_page else ""
        links_html += f'<a class="nav-link {is_active}" href="{href}"><span class="nav-link-icon"><i class="fa-solid {icon}"></i></span>{label}</a>'

    zh_lang_class = "active" if lang == "zh" else ""
    en_lang_class = "active" if lang == "en" else ""

    html = f"""<!doctype html>
<html lang="{'en' if lang == 'en' else 'zh-CN'}">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{title} · Catfolio</title>
  <script>
    // Theme follows the OS unless the user has explicitly chosen one.
    // Applied before render to prevent a flash.
    (function () {{
      var saved = localStorage.getItem("theme");
      var sysLight = window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches;
      if (saved ? saved === "light" : sysLight) {{
        document.documentElement.classList.add("light-theme");
      }}
    }})();
  </script>
  <link rel="stylesheet" href="/static/v4.css" />
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css" integrity="sha512-iecdLmaskl7CVkqkXNQ/ZH/XLlvWZOJyj7Yy7tcenmpD1ypASozpmT/E0iPtmFIB46ZmdtAc9eNBvH0H/ZpiBw==" crossorigin="anonymous" referrerpolicy="no-referrer" />
  {head_extra}
</head>
<body>
  <div class="v4-shell">
    <aside class="v4-sidebar">
      <a class="sidebar-brand" href="/">
        <div class="brand-icon" aria-hidden="true">
          <img class="brand-icon-img brand-icon-dark" src="/static/icons/catfolio-icon-dark.png" alt="" width="36" height="36" />
          <img class="brand-icon-img brand-icon-light" src="/static/icons/catfolio-icon-light.png" alt="" width="36" height="36" />
        </div>
        <div class="brand-text">
          <span class="brand-name">Catfolio</span>
          <span class="brand-version">投资组合</span>
          {'<span class="brand-demo-badge"><i class="fa-solid fa-flask-vial"></i> 假数据</span>' if demo_on else ''}
        </div>
      </a>
      
      <nav class="sidebar-nav">
        {links_html}
      </nav>
      
      <div class="sidebar-footer">
        <button class="theme-toggle-btn" id="themeToggleBtn">
          <i class="fa-solid fa-moon"></i> <span>深色模式</span>
        </button>

        <div class="language-switcher" aria-label="Language">
          <a class="language-option {zh_lang_class}" href="/set-lang/zh">中文</a>
          <a class="language-option {en_lang_class}" href="/set-lang/en">EN</a>
        </div>

        <div class="sidebar-status-card">
          <div style="font-weight:700;margin-bottom:6px;display:flex;align-items:center;gap:6px;">
            <div class="status-dot"></div> 数据同步状态
          </div>
          <div class="sidebar-status-item"><span>Trading 212:</span> <strong>{fmt_time(trading_unix)}</strong></div>
          <div class="sidebar-status-item"><span>Yahoo 行情:</span> <strong>{fmt_time(market_unix)}</strong></div>
          <div class="sidebar-status-item"><span>FMP 估值:</span> <strong>{fmt_time(fundamentals_unix)}</strong></div>
        </div>
      </div>
    </aside>
    
    <div class="v4-main">
      <header class="v4-topbar">
        <div class="topbar-left">
          <button class="menu-toggle" id="menuToggleBtn" aria-label="Toggle Navigation"><i class="fa-solid fa-bars"></i></button>
          <div class="topbar-page-title">{title}</div>
        </div>
        <div class="topbar-right">
          <span class="market-status-badge">
            <div class="status-dot"></div> 账户已连接
          </span>
        </div>
      </header>
      
      <div class="v4-content">
        {content}
      </div>
    </div>
  </div>
  
  <script src="/static/client_i18n.js"></script>
  <script>
    const html = document.documentElement;
    const themeToggleBtn = document.getElementById("themeToggleBtn");

    // Three-state theme: 跟随系统 → 浅色 → 深色 → 跟随系统.
    // "system" = no stored override, follows prefers-color-scheme.
    const THEME_MODES = ["system", "light", "dark"];
    const THEME_META = {{
      system: ["fa-circle-half-stroke", "跟随系统"],
      light: ["fa-sun", "浅色模式"],
      dark: ["fa-moon", "深色模式"],
    }};
    function sysLight() {{
      return window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches;
    }}
    function currentMode() {{
      const s = localStorage.getItem("theme");
      return (s === "light" || s === "dark") ? s : "system";
    }}
    function applyMode(mode) {{
      if (mode === "system") localStorage.removeItem("theme");
      else localStorage.setItem("theme", mode);
      const light = mode === "light" || (mode === "system" && sysLight());
      html.classList.toggle("light-theme", light);
      const meta = THEME_META[mode];
      themeToggleBtn.innerHTML = '<i class="fa-solid ' + meta[0] + '"></i> <span>' + meta[1] + '</span>';
    }}
    applyMode(currentMode());

    themeToggleBtn.addEventListener("click", () => {{
      const next = THEME_MODES[(THEME_MODES.indexOf(currentMode()) + 1) % THEME_MODES.length];
      applyMode(next);
    }});

    // Live-follow OS theme changes while in 跟随系统 mode.
    if (window.matchMedia) {{
      window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", (e) => {{
        if (currentMode() === "system") html.classList.toggle("light-theme", e.matches);
      }});
    }}
    
    const menuToggleBtn = document.getElementById("menuToggleBtn");
    const sidebar = document.querySelector(".v4-sidebar");
    
    menuToggleBtn?.addEventListener("click", (e) => {{
      e.stopPropagation();
      sidebar.classList.toggle("open");
    }});
    
    document.addEventListener("click", (e) => {{
      if (sidebar.classList.contains("open") && !sidebar.contains(e.target) && e.target !== menuToggleBtn) {{
        sidebar.classList.remove("open");
      }}
    }});
  </script>
</body>
</html>"""
    return t_block(_version_assets(html), lang)





def data_health_bar(snapshot) -> str:
    """Render a compact data-health indicator bar."""
    trading_unix = snapshot["trading212"].get("as_of_unix")
    market_unix = snapshot["market"].get("as_of_unix")
    fundamentals_unix = snapshot["fundamentals"].get("as_of_unix")
    fund_rows = len(snapshot["fundamentals"].get("rows", []))
    market_rows = len(snapshot["market"].get("rows", []))
    trading_positions = len(snapshot["trading212"].get("positions", []))

    def age_class(unix_val, max_age_sec):
        if not unix_val:
            return "stale"
        age = max(0, int(_time.time()) - int(unix_val))
        if age < max_age_sec:
            return "fresh"
        return "stale"

    t212_class = age_class(trading_unix, 3600)
    market_class = age_class(market_unix, 120)
    fund_class = age_class(fundamentals_unix, 12 * 3600)

    def fmt_age(val):
        if not val:
            return "未刷新"
        age = max(0, int(_time.time()) - int(val))
        if age < 60:
            return f"{age}秒"
        if age < 3600:
            return f"{age//60}分钟"
        return f"{age//3600}小时"

    return f"""<div class="data-health-bar">
  <span class="dh-item {t212_class}"><span class="dh-dot"></span> 持仓 ({trading_positions}个, {fmt_age(trading_unix)})</span>
  <span class="dh-item {market_class}"><span class="dh-dot"></span> 行情 ({market_rows}只, {fmt_age(market_unix)})</span>
  <span class="dh-item {fund_class}"><span class="dh-dot"></span> 估值 ({fund_rows}只, {fmt_age(fundamentals_unix)})</span>
</div>"""
