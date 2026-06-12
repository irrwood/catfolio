import json
import os
from html import escape
from pathlib import Path


def fmt(value, digits=2):
    try:
        return f"{float(value):,.{digits}f}"
    except (TypeError, ValueError):
        return escape(str(value))


def money(value, currency, digits=2):
    number = fmt(value, digits)
    if currency == "GBX":
        return f"{number}p"
    if currency == "GBP":
        return f"£{number}"
    if currency == "USD":
        return f"${number}"
    if currency == "EUR":
        return f"€{number}"
    return f"{number} {escape(str(currency))}"


def load_optional_json(path, fallback):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return fallback


def pct(value, digits=1):
    if value is None:
        return "—"
    return f"{fmt(value, digits)}%"


def dash(value):
    if value is None or value == "":
        return "—"
    return escape(str(value))


def signed_class(value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return "num-muted"
    if number > 0:
        return "num-positive"
    if number < 0:
        return "num-negative"
    return "num-muted"


def signed_pct_html(value, digits=1):
    return f'<span class="{signed_class(value)}">{pct(value, digits)}</span>'


def signed_money_html(value, currency="USD", digits=2):
    if value is None:
        return "—"
    return f'<span class="{signed_class(value)}">{money(value, currency, digits)}</span>'


def pill_html(value, class_name=""):
    if value is None or value == "":
        return "—"
    extra = f" {class_name}" if class_name else ""
    return f'<span class="pill{extra}">{escape(str(value))}</span>'


def ratio_html(value):
    if value is None:
        return "—"
    try:
        number = float(value)
    except (TypeError, ValueError):
        return f'<span class="num-muted">{escape(str(value))}</span>'
    if number >= 1:
        class_name = "num-negative"
    elif number <= 0.7:
        class_name = "num-positive"
    else:
        class_name = "num-muted"
    return f'<span class="{class_name}">{fmt(number, 2)}</span>'


def main(data_dir=None, out_path=None):
    data_dir = Path(data_dir or os.environ.get("PORTFOLIO_ANALYSIS_DIR", "outputs/portfolio_analysis"))
    out_path = Path(out_path or os.environ.get("PORTFOLIO_HTML_OUT", str(data_dir / "portfolio_cost_basis.html")))
    data_path = data_dir / "portfolio_analysis.json"
    data = json.loads(data_path.read_text(encoding="utf-8"))
    summary = data["summary"]
    is_v2_api = summary.get("version") == "v2_trading212_api"
    report_title = "Trading 212 API 持仓分析 v2" if is_v2_api else "股票持仓成本分析"
    report_subtitle = (
        "v2 基于 Trading 212 API 当前快照；成本价来自 API averagePrice，当前市值来自 API currentPrice。"
        if is_v2_api
        else f'基于 6 个账户 A/B CSV 文件，统计日期：{escape(summary["as_of"])}。成本价采用移动平均法；卖出按当时平均成本扣减。'
    )
    holdings = data["holdings"]
    warnings = summary.get("warnings", [])
    trading212_data = load_optional_json(data_dir / "trading212_data.json", {"summary": {}, "account_cash": {}, "warnings": ["trading212_data.json missing"]})
    trading212_summary = trading212_data.get("summary", {})
    trading212_cash = trading212_data.get("account_cash", {})
    trading212_positions = trading212_data.get("positions", [])
    csv_by_ticker = {row["ticker"].upper(): row for row in holdings}
    api_by_ticker = {}
    for row in trading212_positions:
        ticker = (row.get("normalized_ticker") or row.get("ticker") or "").upper()
        if not ticker:
            continue
        api_by_ticker[ticker] = row
    trading212_reconcile_rows = []
    for ticker in sorted(set(csv_by_ticker) | set(api_by_ticker)):
        csv_row = csv_by_ticker.get(ticker)
        api_row = api_by_ticker.get(ticker)
        csv_shares = float(csv_row.get("shares") or 0) if csv_row else 0
        api_shares = float(api_row.get("quantity") or 0) if api_row else 0
        if csv_row and api_row:
            diff = api_shares - csv_shares
            status = "匹配" if abs(diff) < 0.0001 else "数量差异"
        elif api_row:
            diff = api_shares
            status = "API 新增"
        else:
            diff = -csv_shares
            status = "CSV 独有"
        trading212_reconcile_rows.append({
            "ticker": ticker,
            "status": status,
            "csv_shares": csv_shares,
            "api_shares": api_shares,
            "diff": diff,
            "api_price": api_row.get("current_price") if api_row else None,
            "api_currency": api_row.get("currency") if api_row else None,
            "api_market_value_gbp": api_row.get("market_value_gbp_estimated") if api_row else None,
            "csv_cost_usd": csv_row.get("cost_usd_standard") if csv_row else None,
        })
    trading212_reconcile_rows = sorted(
        trading212_reconcile_rows,
        key=lambda row: (row["status"] != "数量差异", row["status"] != "API 新增", abs(row["diff"])),
        reverse=False,
    )
    trading212_status_counts = {}
    for row in trading212_reconcile_rows:
        trading212_status_counts[row["status"]] = trading212_status_counts.get(row["status"], 0) + 1
    def t212_status_html(status):
        class_name = {
            "匹配": "source-finnhub",
            "数量差异": "source-option",
            "API 新增": "source-yahoo",
            "CSV 独有": "source-massive",
        }.get(status, "")
        return pill_html(status, class_name)

    trading212_reconcile_html = "".join(
        f'<tr><td>{escape(row["ticker"])}</td><td>{t212_status_html(row["status"])}</td><td>{fmt(row["csv_shares"], 6)}</td><td>{fmt(row["api_shares"], 6)}</td><td><span class="{signed_class(row["diff"])}">{fmt(row["diff"], 6)}</span></td><td>{money(row["api_price"], row["api_currency"], 4) if row["api_price"] is not None else "—"}</td><td>{money(row["api_market_value_gbp"], "GBP") if row["api_market_value_gbp"] is not None else "—"}</td><td>{money(row["csv_cost_usd"], "USD") if row["csv_cost_usd"] is not None else "—"}</td></tr>'
        for row in trading212_reconcile_rows[:80]
    )

    html = f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{escape(report_title)}</title>
  <style>
    :root {{
      --bg: oklch(0.975 0.006 92);
      --panel: oklch(0.995 0.004 92);
      --panel-soft: oklch(0.965 0.007 92);
      --ink: oklch(0.205 0.012 180);
      --muted: oklch(0.52 0.016 190);
      --line: oklch(0.895 0.009 88);
      --line-strong: oklch(0.82 0.013 88);
      --accent: oklch(0.46 0.075 180);
      --accent-2: oklch(0.42 0.062 235);
      --warn: oklch(0.48 0.083 62);
      --positive: oklch(0.47 0.105 150);
      --positive-bg: oklch(0.955 0.03 150);
      --negative: oklch(0.48 0.145 28);
      --negative-bg: oklch(0.955 0.035 28);
      --caution: oklch(0.5 0.09 68);
      --caution-bg: oklch(0.965 0.035 78);
      --info: oklch(0.43 0.075 235);
      --info-bg: oklch(0.955 0.025 235);
      --shadow: 0 1px 2px rgba(24, 26, 27, 0.04), 0 14px 34px rgba(24, 26, 27, 0.045);
      --radius: 8px;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background: var(--bg);
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, "PingFang SC", "Microsoft YaHei", sans-serif;
      line-height: 1.45;
      font-size: 14px;
    }}
    header {{
      background: linear-gradient(180deg, oklch(0.995 0.004 92), var(--bg));
      color: var(--ink);
      padding: 24px 28px 20px;
      border-bottom: 1px solid var(--line);
    }}
    .wrap {{ max-width: 1180px; margin: 0 auto; }}
    .query-line {{
      display: flex;
      align-items: center;
      gap: 8px;
      color: var(--muted);
      font-size: 13px;
      margin-bottom: 14px;
    }}
    .query-dot {{
      width: 8px;
      height: 8px;
      background: var(--accent);
      border-radius: 50%;
      box-shadow: 0 0 0 4px oklch(0.92 0.026 180);
    }}
    .answer-panel {{
      max-width: 860px;
    }}
    .hero-row {{
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 18px;
      align-items: start;
    }}
    .header-actions {{
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      justify-content: flex-end;
    }}
    .top-link {{
      display: inline-flex;
      align-items: center;
      height: 32px;
      padding: 0 11px;
      border: 1px solid var(--line);
      border-radius: 999px;
      background: var(--panel);
      color: var(--ink);
      text-decoration: none;
      font-size: 13px;
      font-weight: 650;
    }}
    .top-link.primary {{
      background: var(--ink);
      border-color: var(--ink);
      color: var(--panel);
    }}
    h1 {{ margin: 0 0 10px; font-size: 28px; line-height: 1.18; letter-spacing: 0; font-weight: 650; }}
    .sub {{ margin: 0; color: var(--muted); font-size: 14px; max-width: 75ch; }}
    .source-row {{ display: flex; gap: 8px; flex-wrap: wrap; margin-top: 16px; }}
    .source-pill {{
      display: inline-flex;
      align-items: center;
      height: 28px;
      padding: 0 10px;
      border: 1px solid var(--line);
      background: var(--panel);
      border-radius: 999px;
      color: var(--muted);
      font-size: 12px;
      font-weight: 650;
    }}
    .grid {{
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 10px;
      margin-top: 24px;
    }}
    .metric {{
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: var(--radius);
      padding: 14px;
      min-height: 92px;
    }}
    .metric .label {{ color: var(--muted); font-size: 12px; font-weight: 650; }}
    .metric .value {{ margin-top: 10px; font-size: 22px; font-weight: 680; letter-spacing: 0; }}
    .report-nav {{
      position: sticky;
      top: 0;
      z-index: 5;
      background: color-mix(in oklch, var(--bg) 86%, var(--panel));
      border-bottom: 1px solid var(--line);
      backdrop-filter: blur(10px);
    }}
    .nav-wrap {{
      max-width: 1180px;
      margin: 0 auto;
      padding: 9px 28px;
      display: flex;
      gap: 8px;
      overflow-x: auto;
      scrollbar-width: none;
    }}
    .nav-wrap::-webkit-scrollbar {{ display: none; }}
    .nav-wrap a {{
      flex: 0 0 auto;
      display: inline-flex;
      align-items: center;
      height: 30px;
      padding: 0 10px;
      border: 1px solid var(--line);
      border-radius: 999px;
      color: var(--muted);
      background: var(--panel);
      text-decoration: none;
      font-size: 12px;
      font-weight: 650;
    }}
    .nav-wrap a:hover {{
      color: var(--ink);
      border-color: var(--line-strong);
    }}
    main {{ padding: 22px 28px 42px; }}
    section {{
      background: var(--panel);
      border: 1px solid var(--line);
      box-shadow: var(--shadow);
      border-radius: var(--radius);
      margin: 0 auto 14px;
      max-width: 1180px;
      overflow: hidden;
      scroll-margin-top: 58px;
    }}
    .section-head {{
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 16px;
      padding: 16px 18px 13px;
      border-bottom: 1px solid var(--line);
      background: linear-gradient(180deg, var(--panel), oklch(0.985 0.005 92));
    }}
    h2 {{ margin: 0; font-size: 16px; line-height: 1.25; font-weight: 680; }}
    .note {{ color: var(--muted); font-size: 13px; margin-top: 4px; }}
    .controls {{ display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }}
    input, select, button {{
      height: 36px;
      border: 1px solid var(--line);
      background: var(--panel);
      padding: 0 10px;
      font-size: 13px;
      color: var(--ink);
      border-radius: 7px;
    }}
    input {{
      min-width: 210px;
    }}
    button {{
      background: var(--accent);
      border-color: var(--accent);
      color: oklch(0.995 0.004 92);
      font-weight: 680;
      cursor: pointer;
    }}
    button:hover {{ filter: brightness(0.96); }}
    button:focus-visible, input:focus-visible, select:focus-visible {{
      outline: 2px solid oklch(0.78 0.055 180);
      outline-offset: 2px;
    }}
    .ghost-button {{
      background: var(--panel);
      border-color: var(--line);
      color: var(--ink);
    }}
    .ghost-button:hover {{ background: var(--panel-soft); }}
    .currency-grid {{
      display: grid;
      grid-template-columns: repeat(4, minmax(0, 1fr));
      gap: 0;
      border-top: 1px solid var(--line);
    }}
    .currency-box {{ padding: 16px 18px; border-right: 1px solid var(--line); background: color-mix(in oklch, var(--panel) 92%, var(--bg)); }}
    .currency-box:last-child {{ border-right: 0; }}
    .currency-box span {{ color: var(--muted); font-size: 12px; font-weight: 650; }}
    .currency-box b {{ display: block; font-size: 21px; line-height: 1.2; margin-top: 7px; font-weight: 700; }}
    .summary-table td:first-child, .summary-table th:first-child,
    .summary-table td:nth-child(2), .summary-table th:nth-child(2),
    .summary-table td:nth-child(3), .summary-table th:nth-child(3) {{ text-align: left; }}
    .table-wrap {{ overflow-x: auto; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 13px; }}
    th, td {{
      padding: 9px 12px;
      border-bottom: 1px solid var(--line);
      white-space: nowrap;
      text-align: right;
    }}
    th {{
      position: sticky;
      top: 0;
      background: var(--panel-soft);
      color: var(--muted);
      font-size: 12px;
      cursor: pointer;
      user-select: none;
      z-index: 1;
    }}
    td:first-child, th:first-child,
    td:nth-child(2), th:nth-child(2),
    td:nth-child(3), th:nth-child(3) {{ text-align: left; }}
    tr:hover td {{ background: oklch(0.975 0.006 92); }}
    .num-positive {{ color: var(--positive); font-weight: 800; }}
    .num-negative {{ color: var(--negative); font-weight: 800; }}
    .num-muted {{ color: var(--muted); }}
    .num-info {{ color: var(--info); font-weight: 800; }}
    .source-yahoo {{ background: oklch(0.955 0.021 180); color: var(--accent); border-color: oklch(0.86 0.026 180); }}
    .source-finnhub {{ background: var(--info-bg); color: var(--info); border-color: oklch(0.86 0.024 235); }}
    .source-massive {{ background: oklch(0.955 0.026 295); color: oklch(0.45 0.082 295); border-color: oklch(0.86 0.034 295); }}
    .source-option {{ background: var(--caution-bg); color: var(--caution); border-color: oklch(0.86 0.04 76); }}
    .pill {{
      display: inline-flex;
      align-items: center;
      height: 24px;
      padding: 0 8px;
      background: oklch(0.955 0.021 180);
      color: var(--accent);
      border: 1px solid oklch(0.86 0.026 180);
      font-weight: 600;
      font-size: 12px;
      border-radius: 999px;
    }}
    .top-list {{
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 12px;
      padding: 18px;
    }}
    .top-item {{
      border: 1px solid var(--line);
      border-radius: var(--radius);
      padding: 13px;
      background: var(--panel);
    }}
    .top-row {{ display: flex; justify-content: space-between; gap: 12px; align-items: baseline; }}
    .ticker {{ font-weight: 800; font-size: 16px; }}
    .name {{ color: var(--muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }}
    .warn {{ color: var(--warn); padding: 14px 18px; border-top: 1px solid var(--line); font-size: 13px; background: var(--caution-bg); }}
    .insights {{
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 14px;
      padding: 18px;
    }}
    .insight {{
      border: 1px solid var(--line);
      border-radius: var(--radius);
      background: var(--panel);
      padding: 14px;
      min-height: 120px;
    }}
    .insight.positive {{ background: var(--positive-bg); border-color: oklch(0.86 0.035 150); }}
    .insight.info {{ background: var(--info-bg); border-color: oklch(0.86 0.024 235); }}
    .insight.caution {{ background: var(--caution-bg); border-color: oklch(0.86 0.04 76); }}
    .insight.negative {{ background: var(--negative-bg); border-color: oklch(0.86 0.043 28); }}
    .insight b {{ display: block; font-size: 22px; margin: 7px 0; }}
    .insight ul {{ margin: 10px 0 0; padding-left: 18px; color: var(--muted); font-size: 13px; }}
    .bars {{ padding: 18px; display: grid; gap: 8px; }}
    .bar-row {{
      display: grid;
      grid-template-columns: 92px 1fr 92px;
      gap: 10px;
      align-items: center;
      font-size: 13px;
    }}
    .bar-track {{ height: 20px; background: var(--panel-soft); border: 1px solid var(--line); border-radius: 999px; overflow: hidden; }}
    .bar-fill {{ height: 100%; background: var(--accent-2); border-radius: inherit; }}
    .bar-value {{ text-align: right; font-weight: 700; }}
    .chart-shell {{ padding: 18px; }}
    .chart-toolbar {{ display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 12px; }}
    .chart-mode {{
      height: 34px;
      border: 1px solid var(--line);
      background: var(--panel);
      color: var(--muted);
      font-weight: 680;
      border-radius: 999px;
    }}
    .chart-mode.active {{ background: var(--ink); border-color: var(--ink); color: var(--panel); }}
    .chart-mode[data-chart-mode="pnl"].active {{ background: var(--positive); border-color: var(--positive); }}
    .chart-mode[data-chart-mode="options"].active {{ background: var(--caution); border-color: var(--caution); }}
    .chart-title-row {{ display: flex; justify-content: space-between; align-items: baseline; gap: 12px; margin-bottom: 10px; }}
    .chart-title-row b {{ font-size: 15px; }}
    .chart-legend {{ color: var(--muted); font-size: 13px; }}
    .echart-layout {{ display: grid; grid-template-columns: minmax(0, 1fr) 280px; gap: 14px; align-items: stretch; }}
    #portfolioChart {{ min-height: 500px; border: 1px solid var(--line); background: var(--panel); border-radius: var(--radius); }}
    .chart-side {{ border: 1px solid var(--line); border-radius: var(--radius); background: var(--panel-soft); padding: 14px; }}
    .chart-side b {{ display: block; font-size: 15px; margin-bottom: 8px; }}
    .chart-side ul {{ margin: 10px 0 0; padding-left: 18px; color: var(--muted); font-size: 13px; }}
    .chart-side .big {{ font-size: 24px; font-weight: 800; color: var(--ink); margin: 8px 0; }}
    .fallback-note {{ color: var(--negative); font-size: 13px; margin-top: 10px; }}
    .hidden {{ display: none; }}
    .collapse-body.collapsed {{ display: none; }}
    .summary-table tbody tr:last-child td,
    #holdingsTable tbody tr:last-child td {{ border-bottom: 0; }}
    .section-head .controls button,
    .section-head .controls input,
    .section-head .controls select {{ box-shadow: none; }}
    @media (max-width: 860px) {{
      header, main {{ padding-left: 16px; padding-right: 16px; }}
      .hero-row {{ grid-template-columns: 1fr; }}
      .header-actions {{ justify-content: flex-start; }}
      .nav-wrap {{ padding-left: 16px; padding-right: 16px; }}
      .grid, .currency-grid, .top-list, .insights {{ grid-template-columns: 1fr; }}
      .currency-box {{ border-right: 0; border-bottom: 1px solid var(--line); }}
      .section-head {{ align-items: flex-start; flex-direction: column; }}
      .controls {{ width: 100%; }}
      input, select, button {{ max-width: 100%; }}
      #portfolioChart {{ min-height: 380px; }}
      .echart-layout {{ grid-template-columns: 1fr; }}
      h1 {{ font-size: 24px; }}
    }}
  </style>
</head>
<body>
  <header>
    <div class="wrap">
      <div class="query-line"><span class="query-dot"></span><span>持仓分析 · Trading 212 API · 本地生成</span></div>
      <div class="hero-row">
        <div class="answer-panel">
          <h1>{escape(report_title)}</h1>
          <p class="sub">{report_subtitle}</p>
          <div class="source-row" aria-label="数据来源">
            <span class="source-pill">Trading 212</span>
            <span class="source-pill">CSV 账本</span>
            <span class="source-pill">Yahoo / Finnhub</span>
            <span class="source-pill">FRED</span>
          </div>
        </div>
        <div class="header-actions" aria-label="报表操作">
          <a class="top-link primary" href="/">后端控制台</a>
          <a class="top-link" href="/docs">API 文档</a>
          <a class="top-link" href="/api/chart/exposure">图表 API</a>
        </div>
      </div>
      <div class="grid">
        <div class="metric"><div class="label">交易流水</div><div class="value">{summary["transactions"]:,}</div></div>
        <div class="metric"><div class="label">当前股票数</div><div class="value">{summary["open_positions"]}</div></div>
        <div class="metric"><div class="label">USD 标准成本</div><div class="value">${fmt(summary["total_cost_usd_standard"])}</div></div>
        <div class="metric"><div class="label">已清仓条目</div><div class="value">{summary["closed_positions"]}</div></div>
      </div>
    </div>
  </header>
  <nav class="report-nav" aria-label="报表目录">
    <div class="nav-wrap">
      <a href="#overview">概览</a>
      <a href="#api-reconcile">API 对账</a>
      <a href="#holdings">成本价</a>
      <a href="#notes">口径提示</a>
    </div>
  </nav>
  <main>
    <section id="overview">
      <div class="section-head">
        <div>
          <h2>持仓成本规模</h2>
          <div class="note">统一口径改为 USD 标准；原币仍保留。报告日汇率：GBP/USD 1.3460，EUR/USD 1.1630；GBX 按便士折 GBP 后再折 USD。</div>
        </div>
      </div>
      <div class="currency-grid">
        <div class="currency-box"><span>USD 标准总成本</span><b>${fmt(summary["total_cost_usd_standard"])}</b><div class="note">{summary["open_positions_by_account"]} 条账户持仓</div></div>
        {''.join(f'<div class="currency-box"><span>{escape(cur)} 原币成本</span><b>{money(item["cost_native"], cur)}</b><div class="note">{item["positions"]} 条账户持仓</div></div>' for cur, item in summary["cost_scale_by_currency"].items())}
      </div>
    </section>

    <section id="api-reconcile">
      <div class="section-head">
        <div>
          <h2>Trading 212 API 更新对账</h2>
          <div class="note">{'v2 主数据来自 Trading 212 API；CSV 仅用于历史账本对账，帮助发现数量差异或新持仓。' if is_v2_api else 'Trading 212 API 只用于刷新当前持仓数量、现价和现金；CSV 仍作为历史成本账本。对账用于发现数量差异或新持仓。'}</div>
        </div>
        <div class="controls">
          <button id="toggleT212Reconcile" class="ghost-button" type="button" aria-expanded="false">展开明细</button>
          <button id="exportT212Csv" type="button">导出 API 对账 CSV</button>
        </div>
      </div>
      <div class="currency-grid">
        <div class="currency-box"><span>API 当前持仓</span><b>{trading212_summary.get("positions", 0)}</b><div class="note">Trading 212 live portfolio</div></div>
        <div class="currency-box"><span>API 现金/总值</span><b>{money(trading212_cash.get("total"), trading212_cash.get("currencyCode") or "GBP") if trading212_cash.get("total") is not None else "—"}</b><div class="note">账户 id 已脱敏</div></div>
        <div class="currency-box"><span>数量差异</span><b>{trading212_status_counts.get("数量差异", 0)}</b><div class="note">API 股数 - CSV 股数</div></div>
        <div class="currency-box"><span>API 新增</span><b>{trading212_status_counts.get("API 新增", 0)}</b><div class="note">CSV 中未出现的当前持仓</div></div>
      </div>
      <div id="t212ReconcileBody" class="collapse-body collapsed">
        <div class="table-wrap">
          <table class="summary-table">
            <thead>
              <tr>
                <th>Ticker</th>
                <th>状态</th>
                <th>CSV 股数</th>
                <th>API 股数</th>
                <th>差异</th>
                <th>API 现价</th>
                <th>API 估算市值 GBP</th>
                <th>CSV USD 成本</th>
              </tr>
            </thead>
            <tbody>
              {trading212_reconcile_html}
            </tbody>
          </table>
        </div>
        <div class="warn">
          {'v2 成本价来自 Trading 212 API averagePrice；CSV 成本只用于对账参考。凭证从 macOS Keychain 读取，不需要写入文件。' if is_v2_api else '如果需要刷新 Trading 212 API 数据，运行本地脚本即可；凭证从 macOS Keychain 读取，不需要写入文件。API 当前不覆盖 CSV 成本价。'}
        </div>
      </div>
    </section>

    <section id="holdings">
      <div class="section-head">
        <div>
          <h2>每只股票成本价</h2>
          <div class="note">原币列会带单位：GBX 是便士 p，GBP 是 £，USD 是 $，EUR 是 €；USD 标准列用于横向比较。</div>
        </div>
        <div class="controls">
          <input id="search" placeholder="搜索股票或公司" />
          <select id="currencyFilter">
            <option value="">全部币种</option>
            <option value="USD">USD</option>
            <option value="GBP">GBP</option>
            <option value="GBX">GBX</option>
            <option value="EUR">EUR</option>
          </select>
          <button id="exportCsv" type="button">导出 CSV</button>
        </div>
      </div>
      <div class="table-wrap">
        <table id="holdingsTable">
          <thead>
            <tr>
              <th data-key="ticker">Ticker</th>
              <th data-key="name">名称</th>
              <th data-key="shares">股数</th>
              <th data-key="cost_currency">币种</th>
              <th data-key="cost_usd_standard">USD 标准成本</th>
              <th data-key="avg_cost_usd_standard">USD 标准/股</th>
              <th data-key="cost_native">总成本（原币）</th>
              <th data-key="avg_cost_native">成本价/股（原币）</th>
              <th data-key="accounts">账户</th>
              <th data-key="last_trade_price">最后成交价参考</th>
              <th data-key="last_trade_time">最后成交时间</th>
            </tr>
          </thead>
          <tbody></tbody>
        </table>
      </div>
    </section>

    <section id="notes">
      <div class="section-head">
        <div>
          <h2>口径与提示</h2>
          <div class="note">CSV 负责成本口径；Yahoo/FRED/期权链负责外部快照。行情快照只用于估算，不覆盖原始流水。</div>
        </div>
      </div>
      <div class="warn">
        {escape("；".join(warnings[:8])) if warnings else "没有发现需要提示的流水异常。"}
      </div>
    </section>
  </main>

  <script>
    const holdings = {json.dumps(holdings, ensure_ascii=False)};
    const trading212Rows = {json.dumps(trading212_reconcile_rows, ensure_ascii=False)};
    const tbody = document.querySelector("#holdingsTable tbody");
    const search = document.querySelector("#search");
    const currencyFilter = document.querySelector("#currencyFilter");
    const exportCsv = document.querySelector("#exportCsv");
    const exportT212Csv = document.querySelector("#exportT212Csv");
    const toggleT212Reconcile = document.querySelector("#toggleT212Reconcile");
    const t212ReconcileBody = document.querySelector("#t212ReconcileBody");
    let sortKey = "cost_usd_standard";
    let sortDir = -1;

    const numberKeys = new Set(["shares", "cost_native", "avg_cost_native", "cost_usd_standard", "avg_cost_usd_standard", "last_trade_price"]);
    const tableKeys = ["ticker","name","shares","cost_currency","cost_usd_standard","avg_cost_usd_standard","cost_native","avg_cost_native","accounts","last_trade_price","last_trade_time"];
    const tableHeaders = ["Ticker","名称","股数","币种","USD 标准成本","USD 标准/股","总成本（原币）","成本价/股（原币）","账户","最后成交价参考","最后成交时间"];
    const trading212Keys = ["ticker","status","csv_shares","api_shares","diff","api_price","api_currency","api_market_value_gbp","csv_cost_usd"];
    const trading212Headers = ["Ticker","状态","CSV 股数","API 股数","差异","API 现价","API 币种","API 估算市值 GBP","CSV USD 成本"];

    function formatNativeMoney(value, currency, digits = 2) {{
      const n = Number(value || 0);
      const amount = n.toLocaleString("en-GB", {{ maximumFractionDigits: digits, minimumFractionDigits: 2 }});
      if (currency === "GBX") return `${{amount}}p`;
      if (currency === "GBP") return `£${{amount}}`;
      if (currency === "USD") return `$${{amount}}`;
      if (currency === "EUR") return `€${{amount}}`;
      return `${{amount}} ${{currency || ""}}`.trim();
    }}

    function currencyClass(currency) {{
      if (currency === "USD") return "source-finnhub";
      if (currency === "GBP" || currency === "GBX") return "source-yahoo";
      if (currency === "EUR") return "source-massive";
      return "";
    }}

    function formatCell(key, value, row) {{
      if (key === "cost_currency") return `<span class="pill ${{currencyClass(value)}}">${{value}}</span>`;
      if (key === "cost_native") return formatNativeMoney(value, row.cost_currency, 2);
      if (key === "avg_cost_native") return formatNativeMoney(value, row.cost_currency, 4);
      if (key === "cost_usd_standard") return Number(value || 0) ? `<span class="num-info">$${{Number(value).toLocaleString("en-GB", {{ maximumFractionDigits: 2, minimumFractionDigits: 2 }})}}</span>` : "—";
      if (key === "avg_cost_usd_standard") return Number(value || 0) ? `$${{Number(value).toLocaleString("en-GB", {{ maximumFractionDigits: 4, minimumFractionDigits: 2 }})}}` : "—";
      if (numberKeys.has(key)) {{
        const n = Number(value || 0);
        const digits = key === "shares" ? 6 : 2;
        return n.toLocaleString("en-GB", {{ maximumFractionDigits: digits, minimumFractionDigits: key === "shares" ? 0 : 2 }});
      }}
      return String(value ?? "");
    }}

    function getVisibleRows() {{
      const q = search.value.trim().toLowerCase();
      const cur = currencyFilter.value;
      return holdings
        .filter(row => !cur || row.cost_currency === cur)
        .filter(row => [row.ticker, row.name, row.accounts].join(" ").toLowerCase().includes(q))
        .sort((a, b) => {{
          const av = a[sortKey];
          const bv = b[sortKey];
          if (numberKeys.has(sortKey)) return (Number(av || 0) - Number(bv || 0)) * sortDir;
          return String(av || "").localeCompare(String(bv || "")) * sortDir;
        }});
    }}

    function render() {{
      const rows = getVisibleRows();

      tbody.innerHTML = rows.map(row => `
        <tr>
          ${{tableKeys
            .map(key => `<td>${{formatCell(key, row[key], row)}}</td>`).join("")}}
        </tr>
      `).join("");
    }}

    function csvValue(value) {{
      const text = String(value ?? "");
      return `"${{text.replaceAll('"', '""')}}"`;
    }}

    function downloadCsv() {{
      const rows = getVisibleRows();
      const csvRows = [
        tableHeaders.map(csvValue).join(","),
        ...rows.map(row => tableKeys.map(key => csvValue(row[key])).join(","))
      ];
      const blob = new Blob(["\\ufeff" + csvRows.join("\\n")], {{ type: "text/csv;charset=utf-8" }});
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      const filterPart = currencyFilter.value ? `_${{currencyFilter.value}}` : "";
      link.href = url;
      link.download = `portfolio_cost_basis${{filterPart}}.csv`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
    }}


    function downloadT212Csv() {{
      const csvRows = [
        trading212Headers.map(csvValue).join(","),
        ...trading212Rows.map(row => trading212Keys.map(key => csvValue(row[key])).join(","))
      ];
      const blob = new Blob(["\\ufeff" + csvRows.join("\\n")], {{ type: "text/csv;charset=utf-8" }});
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = "trading212_api_reconcile.csv";
      document.body.appendChild(link);
      link.click();
      link.remove();
      URL.revokeObjectURL(url);
    }}

    document.querySelectorAll("th[data-key]").forEach(th => {{
      th.addEventListener("click", () => {{
        const key = th.dataset.key;
        if (sortKey === key) sortDir *= -1;
        else {{
          sortKey = key;
          sortDir = numberKeys.has(key) ? -1 : 1;
        }}
        render();
      }});
    }});
    search.addEventListener("input", render);
    currencyFilter.addEventListener("change", render);
    exportCsv.addEventListener("click", downloadCsv);
    exportT212Csv.addEventListener("click", downloadT212Csv);
    toggleT212Reconcile.addEventListener("click", () => {{
      const isCollapsed = t212ReconcileBody.classList.toggle("collapsed");
      toggleT212Reconcile.textContent = isCollapsed ? "展开明细" : "收起明细";
      toggleT212Reconcile.setAttribute("aria-expanded", String(!isCollapsed));
    }});
    render();
  </script>
</body>
</html>
"""
    out_path.write_text(html, encoding="utf-8")
    print(out_path.resolve())


if __name__ == "__main__":
    main()
