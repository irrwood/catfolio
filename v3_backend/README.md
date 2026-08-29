# Portfolio Analysis v3 Backend

本地 FastAPI 后端，第一版先把 v2 的核心数据服务化。

## 启动

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --host 127.0.0.1 --port 8787 --reload
```

## 常用接口

- `GET /api/portfolio/summary`
- `GET /api/holdings`
- `GET /api/etf-lookthrough?basis=cost`
- `GET /api/etf-lookthrough?basis=market`
- `GET /api/chart/exposure`
- `GET /api/chart/pnl`
- `GET /api/market/live`
- `POST /api/refresh/market`
- `POST /api/refresh/trading212`
- `GET /api/brokers/{provider}/test`
- `POST /api/refresh/broker`
- `GET /lab`
- `GET /api/lab/history`
- `POST /api/lab/refresh-history`
- `GET /api/lab/efficient-frontier`
- `GET /api/lab/monte-carlo`
- `GET /api/lab/backtest`
- `GET /api/lab/factor-analysis`
- `GET /report`

Trading 212 凭证继续从 macOS Keychain 或环境变量读取，不写入 HTML 或 JSON 输出。

## 券商数据源

在 `/settings` 的“券商持仓源”中可选择 Trading 212、Moomoo 或 Interactive Brokers。同步只读取账户、持仓、平均成本、现价和未实现盈亏，不包含下单能力。

- Moomoo：先启动并登录 Futu OpenD。默认地址为 `127.0.0.1:11111`，可配置市场 `US,HK,CN,SG,JP` 和账户 ID。
- Interactive Brokers：先启动 Client Portal Gateway，并在浏览器完成每日登录。默认地址为 `https://localhost:5000/v1/api`；macOS 如果 5000 端口冲突，可在设置里改成本机其他端口。
- 为避免服务器端请求伪造，两种本地网关都只允许 `localhost`、`127.0.0.1` 或 `::1`。

## 刷新策略

- Trading 212：手动刷新，更新持仓、现金、平均成本和账户快照。
- 行情价格：可更频繁刷新，默认写入 `outputs/portfolio_analysis_v2/live_market_data.json` 缓存。
- 行情缓存默认 60 秒内复用，避免过度请求外部行情接口。

## Portfolio Lab

`/lab` 提供第一版 Portfolio Visualizer 类功能：

- 历史净值和基准回测
- Efficient Frontier
- Monte Carlo
- Factor Analysis
- Max Sharpe / Min Volatility 优化组合

当前版本用 Yahoo Finance 日线历史价格，并缓存到 `outputs/portfolio_analysis_v2/lab_history_data.json`。因子分析使用 ETF proxy（SPY、QQQ、IWM、VEU、GLD）做近似单因子回归。
