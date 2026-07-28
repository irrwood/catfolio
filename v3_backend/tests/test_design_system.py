from pathlib import Path


ROOT = Path(__file__).parents[1]


def test_v5_layout_loads_shared_design_system_after_page_styles():
    components = (ROOT / "app" / "components.py").read_text(encoding="utf-8")

    page_style = components.index("{head_extra}", components.index("def wrap_v5_layout"))
    design_system = components.index('/static/design-system.css', page_style)
    assert design_system > page_style


def test_design_system_matches_lab_foundations():
    css = (ROOT / "app" / "static" / "design-system.css").read_text(encoding="utf-8")

    for declaration in (
        '--bg: #f7f8fa;',
        '--panel: #fff;',
        '--line: #f1f1f1;',
        '--line-strong: #eaebed;',
        '--positive: #2f8a3e;',
        '--negative: #e40014;',
        '--radius-xl: 20px;',
    ):
        assert declaration in css

    assert 'body:not(.page-lab) .v5-content' in css
    assert 'body.page-analytics .v5-content,\nbody.page-ai .v5-content { max-width: 1520px; }' in css
    assert '@media (prefers-reduced-motion: reduce)' in css


def test_design_system_documentation_and_agent_rules_exist():
    assert (ROOT.parent / "DESIGN_SYSTEM.md").is_file()
    assert (ROOT.parent / "AGENTS.md").is_file()


def test_heatmap_matches_figma_page_structure_without_legacy_card():
    route = (ROOT / "app" / "routes" / "heatmap.py").read_text(encoding="utf-8")

    assert 'class="heatmap-page-head"' in route
    assert 'class="market-status-badge"' in route
    assert 'id="rawHoldingsBtn"' in route
    assert 'id="etfUnwrapBtn"' in route
    assert 'class="heatmap-scan-button"' in route
    assert 'id="heatmap" role="img"' in route
    assert 'class="v4-card heatmap-workspace-card"' not in route
    assert 'id="heatmapSummary"' not in route
    assert 'id="refreshMarket"' not in route
    assert route.count('class="arrow" src="/static/icons/portfolio-sort.svg"') == 5
    assert "⌄" not in route


def test_heatmap_uses_figma_palette_spacing_and_market_value_area():
    css = (ROOT / "app" / "static" / "heatmap.css").read_text(encoding="utf-8")
    script = (ROOT / "app" / "static" / "heatmap.js").read_text(encoding="utf-8")

    assert "height: calc(100dvh - 48px);" in css
    assert "border-radius: 16px;" in css
    for color in ("#89d663", "#a6e585", "#d0f6b7", "#ff889e", "#ff97a8", "#ffd3d9"):
        assert color in script
    assert 'sizeMode_value === "marketcap") value = Math.max(Number(row.market_value_usd || 0), 1)' in script
    assert 'gapWidth: 4' in script
    assert 'borderRadius: 8' in script
    assert 'return isDarkMode() ? "rgba(255, 255, 255, 0.56)" : "rgba(0, 0, 0, 0.5)"' in script
    assert 'color: metricLabelColor()' in script
    assert 'setStatus(`<span class="status-dot"></span> ${tr("已更新")}`)' in script
    assert 'const FIGMA_HEAT_PALETTE' in script
    assert 'const DARK_HEAT_PALETTE' in script
    assert 'mixColor' not in script
    assert '#heatmap::after' not in css
    assert 'border: 1px solid var(--line);' in css


def test_heatmap_can_switch_company_logos_on_without_losing_tickers():
    route = (ROOT / "app" / "routes" / "heatmap.py").read_text(encoding="utf-8")
    script = (ROOT / "app" / "static" / "heatmap.js").read_text(encoding="utf-8")
    analytics = (ROOT / "app" / "analytics.py").read_text(encoding="utf-8")

    assert 'data-name="ticker"' in route
    assert 'data-name="logo"' in route
    assert "Logo + 代码" in route
    assert 'function assetLogoUrl(row)' in script
    assert '`/api/asset-logo/${encodeURIComponent(symbol)}`' in script
    assert 'return `{logo| }\\n{ticker|${item.ticker || ""}}\\n{metric|${metricLabel(item)}}`' in script
    assert '"logo_symbol": row.get("logo_symbol") or yahoo_symbol' in analytics


def test_heatmap_sector_headers_use_a_single_horizontal_line():
    script = (ROOT / "app" / "static" / "heatmap.js").read_text(encoding="utf-8")
    styles = (ROOT / "app" / "static" / "heatmap.css").read_text(encoding="utf-8")

    assert 'name: `${localizedSector(group.sector)}   ${holdingsLabel} · ${groupValue}   ${groupMetric}`' in script
    assert 'height: 28, align: "left", verticalAlign: "middle"' in script
    assert 'backgroundColor: cssVar("--panel")' in script
    assert 'borderColor: "transparent"' in script
    assert 'shadowColor: "transparent"' in script
    assert "#heatmap::after" not in styles


def test_heatmap_uses_chinese_source_copy_and_translates_it_to_english():
    from app.i18n import t_block
    from app.routes.heatmap import _BODY

    assert "持仓热力图" in _BODY
    assert "按大小" in _BODY
    assert "原始持仓" in _BODY
    assert "更新中..." in _BODY

    english = t_block(_BODY, "en")
    assert "Heatmap" in english
    assert "By Size" in english
    assert "Ticker" in english
    assert "Raw holdings" in english
    assert "Updating..." in english
    assert "按大小" not in english

    script = (ROOT / "app" / "static" / "heatmap.js").read_text(encoding="utf-8")
    assert 'const layoutLabels = { size: "按大小", sector: "按板块" }' in script
    assert 'setStatus(`<span class="status-dot"></span> ${tr("已更新")}`)' in script


def test_sidebar_language_accessibility_labels_do_not_mix_languages():
    components = (ROOT / "app" / "components.py").read_text(encoding="utf-8")

    assert 'language_group_label = "语言" if lang == "zh" else "Language"' in components
    assert 'language_target = "en" if lang == "zh" else "zh"' in components
    assert 'language_toggle_text = "CN" if lang == "zh" else "EN"' in components
    assert 'language_toggle_label = "切换到英文" if language_target == "en" else "Switch to Chinese"' in components
    assert 'aria-label="语言 / Language"' not in components


def test_sidebar_language_switcher_uses_extrabold_weight():
    sidebar = (ROOT / "app" / "static" / "v5.css").read_text(encoding="utf-8")

    language_rules = [rule for rule in sidebar.split("}") if rule.strip().startswith(".v5-lang a {")]
    assert len(language_rules) == 2
    assert all("font-weight: 800;" in rule for rule in language_rules)


def test_shared_design_system_and_heatmap_follow_dark_theme_tokens():
    design = (ROOT / "app" / "static" / "design-system.css").read_text(encoding="utf-8")
    sidebar = (ROOT / "app" / "static" / "v5.css").read_text(encoding="utf-8")
    heatmap_css = (ROOT / "app" / "static" / "heatmap.css").read_text(encoding="utf-8")
    heatmap_js = (ROOT / "app" / "static" / "heatmap.js").read_text(encoding="utf-8")
    portfolio_css = (ROOT / "app" / "static" / "portfolio.css").read_text(encoding="utf-8")
    portfolio_js = (ROOT / "app" / "static" / "portfolio.js").read_text(encoding="utf-8")
    components = (ROOT / "app" / "components.py").read_text(encoding="utf-8")

    assert "background: var(--bg);" in design
    assert "background: var(--panel);" in design
    assert "color: var(--ink);" in design
    assert ".v5-sidebar" in sidebar and "background: var(--bg);" in sidebar
    assert ':root.light-theme .v5-nav-link.active .v5-nav-icon' in sidebar
    assert "background: var(--panel);" in heatmap_css
    assert 'const DARK_HEAT_PALETTE' in heatmap_js
    assert 'window.addEventListener("catfolio:themechange"' in heatmap_js
    assert "body.page-lab" in portfolio_css and "background: var(--bg);" in portfolio_css
    assert "background: var(--panel);" in portfolio_css
    assert 'function syncChartColors()' in portfolio_js
    assert 'window.addEventListener("catfolio:themechange"' in portfolio_js
    assert 'window.dispatchEvent(new CustomEvent("catfolio:themechange"' in components


def test_strategy_sidebar_uses_api_icon_asset():
    components = (ROOT / "app" / "components.py").read_text(encoding="utf-8")
    icon = (ROOT / "app" / "static" / "icons" / "sidebar" / "strategy.svg").read_text(encoding="utf-8")

    assert '("/strategy", "策略回测", "strategy.svg")' in components
    assert '<rect x="3" y="4" width="18" height="16" rx="3.5"' in icon
    assert 'M8.5 13.5L7 12L8.5 10.5' in icon
    assert 'M12.7764 9.10229L11.2235 14.8978' in icon


def test_bank_sidebar_uses_supplied_icon_with_distinct_interaction_states():
    components = (ROOT / "app" / "components.py").read_text(encoding="utf-8")
    sidebar = (ROOT / "app" / "static" / "v5.css").read_text(encoding="utf-8")
    icon = (ROOT / "app" / "static" / "icons" / "sidebar" / "bank.svg").read_text(encoding="utf-8")

    assert '("/bank", "银行", "bank.svg")' in components
    assert "v5-nav-icon-bank" in components
    assert 'mask-image: url("/static/icons/sidebar/bank.svg");' in sidebar
    assert ".v5-nav-link:hover .v5-nav-icon-mask" in sidebar
    assert ".v5-nav-link:active .v5-nav-icon-mask" in sidebar
    assert ".v5-nav-link.active .v5-nav-icon-mask" in sidebar
    assert ".v5-nav-link.active:hover .v5-nav-icon-mask" in sidebar
    assert 'fill="currentColor"' in icon


def test_collapsed_sidebar_secondary_links_fit_without_clipping():
    sidebar = (ROOT / "app" / "static" / "v5.css").read_text(encoding="utf-8")

    assert ".v5-shell.collapsed .v5-nav-group:nth-child(2) .v5-nav-link { width: 42px; }" in sidebar
    assert ".v5-shell.collapsed .v5-nav-group:nth-child(2) .v5-nav-link { width: 48px; }" not in sidebar


def test_sidebar_collapse_keeps_brand_nav_and_theme_icons_on_fixed_axes():
    sidebar = (ROOT / "app" / "static" / "v5.css").read_text(encoding="utf-8")

    assert ".v5-shell.collapsed .v5-brand {" in sidebar
    assert "margin-inline: 0;" in sidebar
    assert ".v5-nav-link .v5-nav-icon {" in sidebar and "left: 10px;" in sidebar
    assert ".v5-foot-btn .v5-theme-icon {" in sidebar and "left: 11px;" in sidebar
    assert ".v5-shell.collapsed .v5-lang a {\n  display: inline-flex;" in sidebar
    assert ".v5-shell.collapsed .v5-lang .v5-lang-toggle {" in sidebar
    assert "@media (prefers-reduced-motion: reduce)" in sidebar


def test_portfolio_holdings_rows_do_not_overflow_the_card_on_desktop():
    css = (ROOT / "app" / "static" / "portfolio.css").read_text(encoding="utf-8")

    row_rule = css[css.index(".portfolio-holdings-table tbody tr:not(.portfolio-holdings-message)") :]
    row_rule = row_rule[: row_rule.index("}")]
    assert "width: calc(100% - 40px);" in row_rule
    assert "margin-inline: 20px;" in row_rule
    assert "padding: 4px 16px 4px 8px;" in row_rule
    assert "box-sizing: border-box;" in row_rule
    assert "calc(100% + 40px)" not in css
