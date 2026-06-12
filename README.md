# Helm — Personal Investment Command Center

**A self-hosted portfolio dashboard for active investors.** Connect your Trading 212 account, pull live quotes from Yahoo Finance, get AI-powered analysis of your positions, and backtest custom Python strategies — all running locally on your machine.

> **No data leaves your machine.** All processing is local. API keys live in your environment or macOS Keychain, never in files.

---

## Quick Start — no API keys needed

```bash
git clone https://github.com/yourname/helm.git
cd helm

# Option A: Docker (easiest)
docker compose up

# Option B: Python
cd v3_backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
HELM_DEMO=1 uvicorn app.main:app --port 8787
```

Open **http://localhost:8787** — you'll see a fully-populated demo dashboard with a sample 13-stock portfolio. No broker account or API keys required.

---

## Features

| Feature | Description |
|---|---|
| **Dashboard** | Portfolio overview: market value, P&L, unrealized gains, data freshness |
| **Portfolio Lab** | Holdings heatmap, sector breakdown, drawdown curves, factor charts |
| **Returns** | Time-weighted returns vs. SPY / QQQ / IWM with cash-flow mirroring |
| **Heatmap** | Colour-coded 30-day performance grid across all positions |
| **Backtest & Optimize** | Multi-asset backtesting with momentum, mean-reversion, SMA strategies |
| **Strategy Lab** | Write arbitrary Python strategies, run backtests, get AI critique |
| **AI Analysis** | DeepSeek-powered portfolio summaries, risk diagnosis, scenario analysis |
| **Audit Report** | Cost-basis reconciliation and transaction audit trail |
| **Settings** | API key status, cache management, data refresh controls |

---

## Full Setup (Live Data)

### 1. Copy the example env file

```bash
cp .env.example .env
```

```env
# Required for live portfolio data
TRADING212_API_KEY=your_trading212_api_key

# Required for US equity valuation metrics (P/E, P/S, EPS growth)
FMP_API_KEY=your_fmp_key           # https://financialmodelingprep.com
FINNHUB_API_KEY=your_finnhub_key   # https://finnhub.io (free tier works)

# Required for AI analysis and Strategy Lab evaluation
DEEPSEEK_API_KEY=your_deepseek_key # https://platform.deepseek.com

# Optional: after-hours movers
MASSIVE_API_KEY=your_massive_key
```

### 2. Run

```bash
cd v3_backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --port 8787 --reload
```

### 3. macOS Keychain (more secure alternative to `.env`)

```bash
security add-generic-password -a FMP_API_KEY -s com.helm.portfolio -w "your_key"
security add-generic-password -a TRADING212_API_KEY -s com.helm.portfolio -w "your_key"
```

---

## Docker

```bash
# Demo mode (default in docker-compose.yml)
docker compose up

# Live mode — pass keys as environment variables
TRADING212_API_KEY=xxx FMP_API_KEY=xxx docker compose up
```

Data is persisted in a named Docker volume at `/data` inside the container.

---

## Strategy Lab

Write Python strategies and backtest them against any set of tickers:

```python
def strategy(ctx):
    # ctx.price(ticker)   → latest price
    # ctx.sma(ticker, n)  → n-day simple moving average
    # ctx.momentum(ticker, n) → n-day momentum score

    weights = {}
    for ticker in ctx.universe:
        if ctx.price(ticker) > ctx.sma(ticker, 200):
            weights[ticker] = 1.0 / len(ctx.universe)
    return weights
```

Results include: equity curve, drawdown chart, CAGR, Sharpe ratio, max drawdown, and an optional AI evaluation from DeepSeek.

---

## Architecture

```
helm/
├── v3_backend/
│   ├── app/
│   │   ├── main.py            # FastAPI app entry point
│   │   ├── data_store.py      # Data loading + external API calls
│   │   ├── analytics.py       # Portfolio calculations
│   │   ├── lab.py             # Returns / backtest math
│   │   ├── demo_data.py       # Static demo snapshot (HELM_DEMO=1)
│   │   ├── i18n.py            # EN/ZH translation layer
│   │   ├── routes/            # Page handlers (server-side rendered HTML)
│   │   └── static/            # CSS + vendor JS (ECharts, LW Charts)
│   └── requirements.txt
├── scripts/
│   ├── build_trading212_v2.py      # Trading 212 data pipeline
│   └── enrich_trading212_data.py
├── Dockerfile
├── docker-compose.yml
└── .env.example
```

**Stack:** FastAPI · ECharts · Lightweight Charts · server-side rendered HTML · SQLite (strategy history) · Yahoo Finance / FMP / Finnhub / Trading 212 APIs

---

## Privacy

- All data stored locally in `outputs/` (or `HELM_DATA_DIR`)
- No telemetry, no analytics, no external calls except to the providers you configure
- `outputs/` and `.env` are gitignored

## Language

The UI auto-detects your browser language (EN/ZH). Switch manually via the sidebar toggle.

## License

MIT
