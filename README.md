# Helm

Personal investment portfolio command center. Connects to Trading 212, pulls live quotes and fundamentals, and surfaces quantitative analytics — exposure, risk, valuation, backtesting, and AI-powered Q&A — in a single local dashboard.

## Features

- **Dashboard** — portfolio snapshot, data freshness, refresh controls
- **Portfolio Lab** — efficient frontier, Monte Carlo, factor analysis, drawdown curves
- **Holdings Heatmap** — full-screen visual position monitor
- **Returns Benchmarking** — cumulative returns vs SPY/QQQ/VTI
- **Audit Report** — cost-basis reconciliation, CSV/Excel export
- **AI Analysis** — DeepSeek-powered portfolio briefing, risk diagnosis, what-if scenarios
- **Settings** — API key status, cache lifecycle, exchange rates

## Quick Start

```bash
cd v3_backend
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp ../.env.example ../.env   # edit with your API keys
uvicorn app.main:app --host 127.0.0.1 --port 8787
```

Open http://127.0.0.1:8787

## Environment Variables

Copy `.env.example` to `.env` and fill in:

| Variable | Required | Purpose |
|---|---|---|
| `TRADING212_API_KEY` | Yes | Sync positions and cost basis |
| `FMP_API_KEY` | Yes | Valuation data (PE, PS, PB, growth) |
| `FINNHUB_API_KEY` | No | Fallback valuation provider |
| `DEEPSEEK_API_KEY` | No | AI-powered portfolio analysis |
| `MASSIVE_API_KEY` | No | After-hours unusual activity |
| `FRED_API_KEY` | No | Macro data (rates, inflation) |
| `HELM_DATA_DIR` | No | Directory with Trading 212 CSV exports |

On macOS, keys can alternatively be stored in Keychain (service: `portfolio-analysis-v4`, account: variable name).

## CSV Transaction Data

Place Trading 212 account statement CSVs in a directory and set `HELM_DATA_DIR`. Files should follow the standard Trading 212 export format with columns: `Date`, `Action`, `Ticker`, `Quantity`, `Price / share`, `Total`, `Currency (Total)`.

## Tech Stack

Python 3, FastAPI, uvicorn, ECharts, Lightweight Charts, DeepSeek API

## License

MIT
