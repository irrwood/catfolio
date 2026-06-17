"""Page route: report."""
import re
from html import escape
from fastapi import APIRouter, Request, HTTPException
from fastapi.responses import HTMLResponse
from app.analytics import portfolio_summary
from app.components import wrap_v4_layout
from app.data_store import current_snapshot, demo_mode
from app.i18n import get_lang
from app.settings import V2_HTML

router = APIRouter(tags=["pages"])


def _fmt_number(value, digits=2):
    try:
        return f"{float(value):,.{digits}f}"
    except (TypeError, ValueError):
        return "—"


def _money(value, currency="USD", digits=2):
    symbol = {"USD": "$", "GBP": "£", "EUR": "€", "GBX": ""}.get(currency, "")
    suffix = "p" if currency == "GBX" else (f" {currency}" if not symbol else "")
    return f"{symbol}{_fmt_number(value, digits)}{suffix}"


def _demo_report_content():
    """Render a self-contained audit report from the static demo snapshot.

    Demo mode must never read generated HTML from CATFOLIO_DATA_DIR because that
    file can contain a user's real account data from a previous live refresh.
    """
    snapshot = current_snapshot()
    summary = portfolio_summary(snapshot)
    holdings = snapshot["portfolio"].get("holdings", [])
    market_by_ticker = {
        (row.get("ticker") or "").upper(): row
        for row in snapshot["market"].get("rows", [])
    }
    t212_by_ticker = {
        (row.get("normalized_ticker") or row.get("ticker") or "").upper(): row
        for row in snapshot["trading212"].get("positions", [])
    }

    cost_rows = []
    reconcile_rows = []
    for row in sorted(holdings, key=lambda item: item.get("ticker", "")):
        ticker = (row.get("ticker") or "").upper()
        market = market_by_ticker.get(ticker, {})
        t212 = t212_by_ticker.get(ticker, {})
        shares = row.get("shares")
        api_shares = t212.get("quantity", shares)
        diff = (float(api_shares or 0) - float(shares or 0)) if shares is not None else 0
        status = "匹配" if abs(diff) < 0.0001 else "数量差异"
        currency = row.get("cost_currency") or "USD"
        cost_rows.append(
            f"<tr>"
            f"<td>{escape(ticker)}</td>"
            f"<td>{escape(row.get('name') or ticker)}</td>"
            f"<td>{_fmt_number(shares, 4)}</td>"
            f"<td>{escape(currency)}</td>"
            f"<td>{_money(row.get('avg_cost_native'), currency, 4)}</td>"
            f"<td>{_money(row.get('cost_usd_standard'), 'USD')}</td>"
            f"<td>{_money(market.get('market_value_usd'), 'USD')}</td>"
            f"</tr>"
        )
        reconcile_rows.append(
            f"<tr>"
            f"<td>{escape(ticker)}</td>"
            f"<td><span class=\"pill source-finnhub\">{status}</span></td>"
            f"<td>{_fmt_number(shares, 6)}</td>"
            f"<td>{_fmt_number(api_shares, 6)}</td>"
            f"<td>{_fmt_number(diff, 6)}</td>"
            f"<td>{_money(t212.get('current_price') or row.get('last_trade_price'), t212.get('currency') or currency, 4)}</td>"
            f"<td>{_money(t212.get('market_value_gbp_estimated'), 'GBP')}</td>"
            f"</tr>"
        )

    return f"""
<style>
  .demo-report-grid {{
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 14px;
    margin-bottom: 16px;
  }}
  .demo-report-card {{
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: var(--radius-lg);
    padding: 16px;
  }}
  .demo-report-card span {{
    display: block;
    color: var(--muted);
    font-size: 12px;
    margin-bottom: 8px;
  }}
  .demo-report-card b {{
    color: var(--ink);
    font-size: 24px;
    letter-spacing: 0;
  }}
  .audit-note {{
    margin: 0 0 16px; padding: 12px 16px;
    border: 1px solid var(--line); border-radius: var(--radius-lg);
    color: var(--muted); background: var(--panel-raised);
    font-size: 13px; line-height: 1.5;
  }}
  .demo-report-section {{
    background: var(--panel);
    border: 1px solid var(--line);
    border-radius: var(--radius-xl);
    margin: 0 0 16px;
    overflow: hidden;
  }}
  .demo-report-section h2 {{
    margin: 0;
    padding: 16px 18px;
    border-bottom: 1px solid var(--line);
    font-size: 16px;
  }}
  .demo-report-section table {{
    width: 100%;
    border-collapse: collapse;
  }}
  .demo-report-section th,
  .demo-report-section td {{
    padding: 10px 12px;
    border-bottom: 1px solid var(--line);
    text-align: left;
    font-size: 13px;
  }}
  .demo-report-section th {{
    color: var(--muted);
    background: var(--panel-raised);
    font-weight: 650;
  }}
  @media (max-width: 900px) {{
    .demo-report-grid {{ grid-template-columns: 1fr; }}
    .demo-report-section {{ overflow-x: auto; }}
  }}
</style>
<div class="audit-note">
  Demo mode is using Catfolio's built-in sample portfolio. No generated report file from your local data directory is read on this page.
</div>
<div class="demo-report-grid">
  <div class="demo-report-card"><span>Market Value</span><b>{_money(summary.get("market_value_usd"), "USD")}</b></div>
  <div class="demo-report-card"><span>Cost Basis</span><b>{_money(summary.get("total_cost_usd_standard"), "USD")}</b></div>
  <div class="demo-report-card"><span>Open Positions</span><b>{_fmt_number(summary.get("open_positions"), 0)}</b></div>
</div>
<section class="demo-report-section">
  <h2>Trading 212 API Reconciliation</h2>
  <table>
    <thead><tr><th>Ticker</th><th>Status</th><th>CSV Shares</th><th>API Shares</th><th>Difference</th><th>API Price</th><th>Estimated GBP Value</th></tr></thead>
    <tbody>{''.join(reconcile_rows)}</tbody>
  </table>
</section>
<section class="demo-report-section">
  <h2>Cost Basis by Stock</h2>
  <table>
    <thead><tr><th>Ticker</th><th>Name</th><th>Shares</th><th>Currency</th><th>Avg Cost</th><th>USD Cost</th><th>Market Value</th></tr></thead>
    <tbody>{''.join(cost_rows)}</tbody>
  </table>
</section>
"""


@router.get("/report")
def report(request: Request):
    if demo_mode():
        return HTMLResponse(wrap_v4_layout("审计报表", _demo_report_content(), "/report", get_lang(request)))
    if not V2_HTML.exists():
        raise HTTPException(status_code=404, detail="v2 report has not been generated yet")
    raw = V2_HTML.read_text(encoding="utf-8")
    # Extract body content
    import re
    body_match = re.search(r'<body>(.*?)</body>', raw, re.DOTALL)
    if not body_match:
        raise HTTPException(status_code=500, detail="Invalid report format")
    body = body_match.group(1)
    # Extract inline CSS (keep v2-specific table/card styles)
    style_match = re.search(r'<style>(.*?)</style>', raw, re.DOTALL)
    v2_css = style_match.group(1) if style_match else ""
    # Remove the :root variables (v4 provides theme)
    v2_css = re.sub(r':root\s*\{[^}]*\}', '', v2_css)
    # Remove body/header/wrap styles (v4 handles these)
    v2_css = re.sub(r'body\s*\{[^}]*\}', '', v2_css)
    v2_css = re.sub(r'header\s*\{[^}]*\}', '', v2_css)
    v2_css = re.sub(r'\.wrap\s*\{[^}]*\}', '', v2_css)
    # Remove old nav links
    v2_css = re.sub(r'\.query-line\s*\{[^}]*\}', '', v2_css)
    # Remove the old <header> block entirely
    body = re.sub(r'<header>.*?</header>', '', body, flags=re.DOTALL)
    # Remove any top nav link rows
    body = re.sub(r'<div class="query-line">.*?</div>\s*</header>', '', body, flags=re.DOTALL)
    # Remove links to old pages ("后端控制台", "API 文档", etc.)
    body = re.sub(r'<a href="/"[^>]*>.*?</a>', '', body)
    body = re.sub(r'<a href="[^"]*">后端控制台</a>', '', body)
    body = re.sub(r'<a href="[^"]*">API 文档</a>', '', body)
    body = re.sub(r'<a href="[^"]*">Exposure API</a>', '', body)
    body = re.sub(r'<a href="[^"]*">图表 API</a>', '', body)
    # The audit report is intentionally limited to cost + reconciliation (overview /
    # api-reconcile / holdings / notes). The ETF look-through and holdings-analysis
    # ("radar": price / options / market value / P&L) sections — which duplicated
    # Portfolio Lab — are no longer generated by build_portfolio_html.py, so no
    # post-processing removal is needed here anymore.
    # Add btn class to buttons inside report
    body = body.replace('id="exportCsv" type="button"', 'id="exportCsv" class="btn" type="button"')
    body = body.replace('id="exportT212Csv" type="button"', 'id="exportT212Csv" class="btn" type="button"')
    body = body.replace('id="toggleT212Reconcile" class="ghost-button" type="button"', 'id="toggleT212Reconcile" class="btn" type="button"')
    # Keep the rest of the v2 styles for tables, cards, badges etc.
    content = f"""<style>
{v2_css}

    /* V2 compatibility — map to v4 variables */
    :root {{
      --positive-bg: var(--positive-soft);
      --negative-bg: var(--negative-soft);
      --caution: var(--warn); --caution-bg: var(--warn-soft);
      --info: var(--accent); --info-bg: var(--accent-soft);
    }}
    /* Dark theme overrides for V2 elements */
    .pill {{ background: var(--soft) !important; color: var(--muted) !important; border-color: var(--line) !important; }}
    .source-yahoo {{ background: var(--accent-soft) !important; color: var(--accent) !important; border-color: var(--accent) !important; }}
    .source-finnhub {{ background: var(--accent-soft) !important; color: var(--accent) !important; border-color: var(--accent) !important; }}
    .source-massive {{ background: var(--positive-soft) !important; color: var(--positive) !important; border-color: var(--positive) !important; }}
    .source-option {{ background: var(--warn-soft) !important; color: var(--warn) !important; border-color: var(--warn) !important; }}
    
    .section-head {{
      background: var(--panel-raised) !important;
      border-bottom: 1px solid var(--line) !important;
    }}
    .section-head h2 {{ color: var(--ink) !important; }}
    
    table {{ color: var(--ink) !important; }}
    th {{
      color: var(--muted) !important;
      background: var(--panel-raised) !important;
      border-bottom: 1px solid var(--line) !important;
    }}
    td {{
      border-color: var(--line) !important;
      color: var(--ink) !important;
    }}
    tr:hover td {{ background: var(--panel-hover) !important; }}
    .num-muted {{ color: var(--muted) !important; }}
    
    .insight {{ background: var(--panel) !important; border-color: var(--line) !important; }}
    .insight.positive {{ background: var(--positive-soft) !important; border-color: var(--positive) !important; }}
    .insight.info {{ background: var(--accent-soft) !important; border-color: var(--accent) !important; }}
    .insight.caution {{ background: var(--warn-soft) !important; border-color: var(--warn) !important; }}
    .insight.negative {{ background: var(--negative-soft) !important; border-color: var(--negative) !important; }}
    .insight b {{ color: var(--ink) !important; }}
    .insight ul {{ color: var(--muted) !important; }}
    .note {{ color: var(--muted) !important; }}
    .warn {{ color: var(--warn) !important; background: var(--warn-soft) !important; border-color: var(--warn) !important; }}
    
    input, select {{
      border: 1px solid var(--line) !important;
      background: var(--panel) !important;
      color: var(--ink) !important;
    }}
    input:focus, select:focus {{
      border-color: var(--accent) !important;
      outline: none !important;
    }}
    
    section {{
      background: var(--panel) !important;
      border: 1px solid var(--line) !important;
      box-shadow: var(--shadow-sm) !important;
      border-radius: var(--radius-xl) !important;
      /* Was capped at 1180px — let it fill the same 1520px column as every other
         page (.v4-content) so the report aligns in width with the rest of the app. */
      max-width: none !important;
      margin: 0 0 16px !important;
    }}

    /* Fix: .insights is a 3-col grid that defaults to align-items:stretch, so a
       single long card (e.g. the per-ticker valuation list) forced its short
       neighbours to stretch into tall empty bordered columns. Size to content. */
    .insights {{ align-items: start !important; }}
    /* Give the cramped per-ticker valuation lines room to breathe. */
    .insight li {{ line-height: 1.7 !important; padding: 1px 0 !important; }}
    
    .currency-box {{
      border-right: 1px solid var(--line) !important;
      background: var(--panel-raised) !important;
    }}
    .currency-box span {{ color: var(--muted) !important; }}
    .currency-box b {{ color: var(--ink) !important; }}
    
    .top-item {{
      border: 1px solid var(--line) !important;
      background: var(--panel) !important;
      border-radius: var(--radius-md) !important;
    }}
    .ticker {{ color: var(--ink) !important; }}
    .name {{ color: var(--muted) !important; }}
    
    .bar-track {{
      background: var(--panel-hover) !important;
      border: 1px solid var(--line) !important;
    }}
    .bar-fill {{
      background: var(--accent) !important;
    }}
    
    /* Floating Claude-style TOC — collapsed to dashes, expands on hover */
    .report-nav {{
      position: fixed !important;
      top: 50%; left: 64px;
      transform: translateY(-50%);
      z-index: 40;
      width: auto !important;
      max-height: calc(100vh - 120px);
      overflow: visible !important;
      background: transparent !important;
      border: 0 !important;
      border-radius: 14px;
      backdrop-filter: none !important;
      padding: 8px 6px;
      transition: background .15s ease, box-shadow .15s ease, border-color .15s ease;
    }}
    .report-nav:hover {{
      background: var(--panel) !important;
      border: 1px solid var(--line) !important;
      box-shadow: var(--shadow-md);
    }}
    .nav-wrap {{
      max-width: none !important;
      margin: 0 !important;
      padding: 0 !important;
      display: flex !important;
      flex-direction: column !important;
      gap: 4px !important;
      overflow: visible !important;
    }}
    .nav-wrap a {{
      flex: none !important;
      display: flex !important;
      align-items: center;
      gap: 0 !important;
      height: auto !important;
      padding: 7px 8px !important;
      border: 0 !important;
      border-radius: 8px !important;
      background: transparent !important;
      color: var(--muted) !important;
      font-size: 0 !important;            /* collapsed: label hidden */
      font-weight: 600 !important;
      white-space: nowrap;
      text-decoration: none !important;
      transition: color .12s ease, background .12s ease;
    }}
    .nav-wrap a::before {{
      content: "";
      flex: none;
      width: 18px;
      height: 2px;
      border-radius: 2px;
      background: currentColor;
      opacity: 0.4;
      transition: width .15s ease, opacity .15s ease, background .15s ease;
    }}
    .report-nav:hover .nav-wrap a {{ font-size: 13px !important; gap: 10px !important; }}
    .nav-wrap a:hover {{ background: var(--soft) !important; color: var(--ink) !important; }}
    .nav-wrap a:hover::before {{ opacity: 0.85; }}
    .nav-wrap a.active {{ color: var(--ink) !important; font-weight: 700 !important; }}
    .report-nav:hover .nav-wrap a.active {{ background: var(--soft) !important; }}
    .nav-wrap a.active::before {{ width: 26px; opacity: 1; background: var(--ink); }}
    main {{ padding-left: 52px !important; }}
    @media (max-width: 1024px) {{
      .report-nav {{
        position: static !important;
        transform: none !important;
        top: auto; left: auto; max-height: none;
        background: var(--panel) !important;
        border: 0 !important;
        border-bottom: 1px solid var(--line) !important;
        border-radius: 0; box-shadow: none !important;
        padding: 9px 16px;
      }}
      .nav-wrap {{ flex-direction: row !important; flex-wrap: wrap; gap: 8px !important; }}
      .nav-wrap a {{ font-size: 12px !important; gap: 8px !important; padding: 6px 10px !important; background: var(--soft) !important; border-radius: 999px !important; }}
      .nav-wrap a::before {{ display: none; }}
      main {{ padding-left: 28px !important; }}
    }}

    .audit-note {{
      margin: 0 0 16px; padding: 12px 16px;
      border: 1px solid var(--line); border-radius: var(--radius-lg);
      color: var(--muted); background: var(--panel-raised);
      font-size: 13px; line-height: 1.5;
    }}
</style>
<div class="audit-note">这是审计报表：保留完整成本、账户对账、收入统计和导出。组合决策、风险、估值和模型分析请使用 Portfolio Lab。</div>
{body}
<script src="/static/report_nav.js"></script>
"""
    return HTMLResponse(wrap_v4_layout("审计报表", content, "/report", get_lang(request)))


@router.post("/api/log-error")
def log_error_endpoint(data: dict):
    print("=== BROWSER JS ERROR ===")
    print(data.get("message"))
    print(data.get("stack"))
    print("========================")
    return {"status": "ok"}
