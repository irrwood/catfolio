# Catfolio — Local-first Portfolio, Quant, and Strategy Dashboard

Catfolio is a self-hosted portfolio dashboard and quantitative research workspace for investors who want a private command center for holdings, returns, risk, strategy experiments, and AI-assisted analysis.

It runs locally as a web app, can be packaged as a macOS desktop app, and ships with a full demo mode so contributors can explore the product without a broker account or API keys.

The project combines portfolio accounting with quant-style research tools: factor exposure, benchmark comparison, Monte Carlo simulation, efficient-frontier optimization, historical return modeling, and saved Python strategy backtests.

Project repository: [github.com/irrwood/catfolio](https://github.com/irrwood/catfolio)

## Highlights

- **Local-first by default**: portfolio files, imported CSVs, caches, saved strategy runs, and API keys stay on your machine.
- **Demo-safe for open source**: `CATFOLIO_DEMO=1` uses bundled sample data and does not read local private account files.
- **Broker sync or CSV import**: connect Trading 212 for live holdings, or upload broker transaction CSVs to calculate weighted-average cost and current positions.
- **Portfolio overview**: total value, P&L, breadth, concentration, sector exposure, and the largest positions at a glance.
- **Detailed holdings**: full position detail with cost basis, quote currency, market value, P&L, account, and raw-versus-ETF-look-through views.
- **Returns workspace**: portfolio returns against benchmarks such as SPY, QQQ, and IWM, with monthly heatmaps.
- **Analysis charts**: monthly return heatmaps, drawdown curves, holding correlations, valuation matrices, and return distributions.
- **Strategy Lab**: write Python allocation strategies, rebalance over historical prices, compare CAGR/volatility/Sharpe/max drawdown, save runs, and optionally ask an AI provider to critique the result.
- **AI analysis**: portfolio briefing, risk diagnosis, performance explanation, overlap analysis, what-if scenarios, returns explanation, and free-form portfolio Q&A.
- **Local-first bank and email analytics**: connect Plaid through the existing FastAPI app, keep normalized transactions in local SQLite, encrypt access tokens with AES-256-GCM and a Keychain-backed key, and scan authorised mailboxes directly over read-only IMAP for refund opportunities.
- **Provider choices**: DeepSeek, Grok/xAI, OpenAI, Gemini, Moonshot Kimi, Zhipu GLM, Qwen, and OpenRouter are supported through one provider registry.
- **Desktop build**: PyInstaller + pywebview packaging for `Catfolio.app` on macOS.

## Screenshots

These screenshots use Catfolio's built-in demo data mode. No real portfolio data, broker account, or API key is shown.

| Portfolio | Analysis Charts |
| --- | --- |
| ![Catfolio portfolio using bundled demo data](docs/screenshots/portfolio-v5.jpg) | ![Catfolio analysis charts using bundled demo data](docs/screenshots/analytics-v5.jpg) |

| Returns & Benchmarks | Holdings Heatmap |
| --- | --- |
| ![Catfolio returns benchmark comparison using bundled demo data](docs/screenshots/returns-v5.jpg) | ![Catfolio holdings heatmap using bundled demo data](docs/screenshots/heatmap-v5.jpg) |

| Strategy Lab | AI Analyst |
| --- | --- |
| ![Catfolio strategy backtest using bundled demo data](docs/screenshots/strategy-v5.jpg) | ![Catfolio AI Analyst in demo mode](docs/screenshots/ai-v5.jpg) |

![Catfolio bank analytics prototype using bundled demo data](docs/screenshots/bank-v5.jpg)

## Quick Start

### Docker

```bash
git clone https://github.com/irrwood/catfolio.git
cd catfolio
docker compose up
```

Open [http://localhost:8787](http://localhost:8787). Docker runs in demo mode by default.

### Python

```bash
git clone https://github.com/irrwood/catfolio.git
cd catfolio/v3_backend

python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

CATFOLIO_DEMO=1 uvicorn app.main:app --host 127.0.0.1 --port 8787
```

Open [http://localhost:8787](http://localhost:8787).

The first visit to Returns or a backtest may take longer while Yahoo Finance history is fetched and cached. Portfolio and Holdings use the current snapshot and stay lightweight.

## Live Data Setup

Copy the example environment file and fill in only the integrations you want to use:

```bash
cp .env.example .env
```

Common variables:

```env
# Trading 212 portfolio sync
TRADING212_API_KEY=
TRADING212_API_SECRET=

# Fundamentals and valuation metrics
FMP_API_KEY=
FINNHUB_API_KEY=

# AI provider keys, depending on selected provider
DEEPSEEK_API_KEY=
XAI_API_KEY=
OPENAI_API_KEY=
GEMINI_API_KEY=
MOONSHOT_API_KEY=
ZHIPU_API_KEY=
QWEN_API_KEY=
OPENROUTER_API_KEY=

# Optional data sources
MASSIVE_API_KEY=
FRED_API_KEY=

# Optional Plaid Open Banking connection (Sandbox by default)
PLAID_CLIENT_ID=
PLAID_SECRET=
PLAID_ENV=sandbox
PLAID_COUNTRY_CODES=GB

# Optional Telegram alerts
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

# Data directory override
CATFOLIO_DATA_DIR=/path/to/local/data
```

## Where To Get API Keys

Catfolio works in demo mode without any keys. For live data or AI analysis, use the official provider links below and configure only the services you need.

| Environment variable | Used for | Where to get it |
| --- | --- | --- |
| `TRADING212_API_KEY` | Broker holdings, average cost, cash, and transaction sync | [Trading 212 API key guide](https://helpcentre.trading212.com/hc/en-us/articles/14584770928157-Trading-212-API-key) |
| `TRADING212_API_SECRET` | Optional Trading 212 secret for account setups that expose key/secret credentials | [Trading 212 API key guide](https://helpcentre.trading212.com/hc/en-us/articles/14584770928157-Trading-212-API-key) |
| `FMP_API_KEY` | Fundamentals and valuation metrics | [Financial Modeling Prep quickstart](https://site.financialmodelingprep.com/developer/docs/quickstart) |
| `FINNHUB_API_KEY` | Fundamentals fallback when FMP is unavailable | [Finnhub registration](https://finnhub.io/register) |
| `MASSIVE_API_KEY` | Optional after-hours movers and options snapshots | [Massive REST API quickstart](https://massive.com/docs/rest/quickstart) |
| `FRED_API_KEY` | Optional macro data such as rates and inflation | [FRED API key docs](https://fred.stlouisfed.org/docs/api/api_key.html) |
| `PLAID_CLIENT_ID` / `PLAID_SECRET` | Optional local bank connection and transaction sync | [Plaid Dashboard](https://dashboard.plaid.com/) |
| `DEEPSEEK_API_KEY` | AI Analyst and Strategy Lab evaluation | [DeepSeek API keys](https://platform.deepseek.com/api_keys) |
| `XAI_API_KEY` | Grok / xAI provider for AI analysis | [xAI console](https://console.x.ai/) |
| `OPENAI_API_KEY` | OpenAI provider for AI analysis | [OpenAI API keys](https://platform.openai.com/api-keys) |
| `GEMINI_API_KEY` | Google Gemini provider for AI analysis | [Google AI Studio API keys](https://aistudio.google.com/app/apikey) |
| `MOONSHOT_API_KEY` | Moonshot Kimi provider for AI analysis | [Kimi API keys](https://platform.kimi.ai/console/api-keys) |
| `ZHIPU_API_KEY` | Zhipu GLM provider for AI analysis | [Zhipu BigModel API keys](https://open.bigmodel.cn/usercenter/apikeys) |
| `QWEN_API_KEY` | Alibaba Cloud Qwen / DashScope provider for AI analysis | [Alibaba Cloud Model Studio API key guide](https://www.alibabacloud.com/help/en/model-studio/get-api-key) |
| `OPENROUTER_API_KEY` | OpenRouter provider for multi-model AI analysis | [OpenRouter API authentication](https://openrouter.ai/docs/api/reference/authentication) |
| `TELEGRAM_BOT_TOKEN` | Optional Telegram alert bot | [Telegram BotFather tutorial](https://core.telegram.org/bots/tutorial) |
| `TELEGRAM_CHAT_ID` | Optional Telegram alert destination | [Telegram Bot API docs](https://core.telegram.org/bots/api) |

Keep provider keys out of git. Use `.env`, macOS Keychain, or another local secret store, and prefer separate keys with spending limits where providers support them.

Run without `CATFOLIO_DEMO=1` when you are ready to use real data:

```bash
cd v3_backend
source .venv/bin/activate
uvicorn app.main:app --host 127.0.0.1 --port 8787 --reload
```

On macOS, API keys can also be stored in Keychain under `com.catfolio.portfolio`:

```bash
security add-generic-password -a TRADING212_API_KEY -s com.catfolio.portfolio -w "your_key"
security add-generic-password -a FMP_API_KEY -s com.catfolio.portfolio -w "your_key"
security add-generic-password -a DEEPSEEK_API_KEY -s com.catfolio.portfolio -w "your_key"
```

## Main Screens

- **Portfolio**: a lightweight status view for total value, P&L, breadth, concentration, sector allocation, and major position proportions.
- **Holdings**: the full position ledger, including average cost, current price, total cost, market value, unrealized P&L, account, and an ETF look-through toggle.
- **Returns**: time-weighted return views and benchmark comparisons.
- **Analysis Charts**: monthly return heatmaps, drawdowns, holding correlations, valuation, distributions, and attribution views.
- **Backtest**: predefined multi-asset experiments and optimizer-style workflows.
- **Strategy Lab**: custom Python strategy research with historical rebalancing, saved run history, performance metrics, and optional AI evaluation.
- **Heatmap**: short-term performance grid across the current universe.
- **AI Analyst**: a chat-oriented portfolio assistant with a preset question library for briefing, risk, overlap, what-if, performance, and free-form Q&A.
- **Bank**: local SQLite account and transaction storage, Plaid Link and incremental sync, subscription detection, refund matching, and opt-in direct IMAP analysis. Mail credentials stay in the OS Keychain; raw message bodies are not persisted.
- **Import**: broker CSV upload for users who do not use Trading 212.
- **Settings**: API keys, data refresh controls, demo mode, AI provider selection, Telegram alert configuration, and cache controls.

## Strategy Example

Strategy Lab is designed for turning investment hypotheses into repeatable strategy backtests. A strategy is a Python allocation function that receives historical market context and returns target portfolio weights at each rebalance date:

```python
def strategy(ctx):
    weights = {}

    eligible = [
        ticker
        for ticker in ctx.universe
        if ctx.price(ticker) > ctx.sma(ticker, 200)
    ]

    if not eligible:
        return weights

    for ticker in eligible:
        weights[ticker] = 1.0 / len(eligible)

    return weights
```

Results include equity curve, CAGR, volatility, Sharpe ratio, max drawdown, turnover-style diagnostics, saved run history, and optional AI critique. This makes Catfolio useful both as a personal portfolio tracker and as a lightweight quant strategy sandbox.

## Roadmap

- **More broker API integrations**: the next major direction is adding support for more brokerage APIs so Catfolio can sync live holdings beyond the current Trading 212 workflow.
- **UI and UX polish milestone**: if the project reaches 1,000 GitHub stars, a dedicated UI/UX optimization pass will focus on navigation, layout density, responsive behavior, visual consistency, and smoother day-to-day portfolio workflows.

## Data And Privacy

- No analytics or telemetry are built into the app.
- Private runtime outputs are ignored by git, including `.env`, `outputs/`, `build/`, `dist/`, and generated release archives.
- `CATFOLIO_DATA_DIR` lets you keep private data outside the repository.
- Demo mode uses static sample holdings and market content.
- Demo-mode bank and email examples are generated from bundled fictional records. In real mode, Plaid access tokens are encrypted locally and bank transactions remain in the configured `CATFOLIO_DATA_DIR`.
- External network calls happen only when you configure and use providers such as Trading 212, Yahoo Finance, FMP, Finnhub, Massive, FRED, Plaid, IMAP, Telegram, or an AI provider.

This is not financial advice. Catfolio is a personal analysis tool; verify all numbers before making investment decisions.

## Development

Install dependencies:

```bash
cd v3_backend
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

Run tests:

```bash
cd ..
v3_backend/.venv/bin/python -m pytest v3_backend/tests
python3 -m compileall -q v3_backend scripts
```

Run the open-source readiness check:

```bash
v3_backend/.venv/bin/python scripts/check_open_source_ready.py
```

Create a sanitized source archive:

```bash
v3_backend/.venv/bin/python scripts/export_open_source_archive.py
```

## macOS Desktop Build

Build `dist/Catfolio.app` from the repository root:

```bash
v3_backend/.venv/bin/pyinstaller catfolio.spec --clean
```

The desktop app embeds the FastAPI backend and opens a local pywebview window.

## Project Layout

```text
catfolio/
├── v3_backend/
│   ├── app/
│   │   ├── main.py              # FastAPI entry point
│   │   ├── data_store.py        # snapshots, secrets, refresh orchestration
│   │   ├── analytics.py         # portfolio analytics
│   │   ├── banking.py           # demo subscription/refund recognition
│   │   ├── lab.py               # returns, backtests, simulations
│   │   ├── ai.py                # AI provider registry and prompts
│   │   ├── demo_data.py         # bundled demo data
│   │   ├── routes/              # page and API route modules
│   │   └── static/              # CSS, JS, icons, vendor charts
│   ├── desktop.py               # pywebview desktop launcher
│   └── requirements.txt
├── scripts/                     # data refresh, validation, release helpers
├── assets/                      # app icon assets
├── docs/                        # release and architecture notes
├── Dockerfile
├── docker-compose.yml
├── catfolio.spec
└── .env.example
```

## License

MIT
