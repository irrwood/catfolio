# 机构评级历史回顾本地 Demo

连接 T7 后，从 v3_backend 运行 `.venv/bin/uvicorn demo.analyst_app:app --host 127.0.0.1 --port 8791`。
打开 http://127.0.0.1:8791/analyst-history?ui=v5 。入口复用现有应用与 v5 shell，仅额外注册 demo 路由。

只读 Core release 09c2d833d79d34dc。评级与行情截至 2026-09-04，评估截止 2026-09-08。没有重新抓取全市场更新，没有修改 Core 评分公式。

支持机构搜索、四个期限、方向、样本门槛、股票筛选、分页和原始依据展开。股票筛选仅改变明细。

2026-09-09 以固定种子 20260909 回查 12 条已评分记录，验证评级存在于原始 ZIP、member SHA256、起止收盘价、评级后入场和收益算术；全部通过。见 analyst-history-demo-audit.json。

Morgan Stanley / NVDA / 2023-03-17 的日期与 Equal Weight → Overweight 与 Investing.com 同日公开报道一致；展开记录提供链接。此证据不是原始研报，不代表所有评级已独立验证。

浏览器检查发现 Morgan Stanley / NVDA 在 2018-04-09 和 2018-04-10 有相同评级变更。适配层对同一机构股票、相同新旧评级与 action、相隔不超过 3 个自然日的事件加待核实标记，不擅自从 Core 统计剔除。可能影响方向命中率，不能据此认定机构表现高低。

验证：6 个 demo 测试、10 个 Core 测试通过；浏览器验证股票筛选、评级结果和审计展开。

2026-09-09 后续：个股历史图已扩展至当前 78 个持仓。页面 `/price-target-history?symbol=META&currency=USD`，读取桌面与 iOS 共用的 catalog；详见 ios-analyst-history.md 与 analyst-history-coverage.json。原机构命中率页面保持独立。
