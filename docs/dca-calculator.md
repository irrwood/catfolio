# 定投计算器

入口：`/dca`（共享 v5 侧栏与策略回测页均有链接）。Figma 参考节点 `EtNSXmasS8lz9JzrWUoMd9 / 382:3898`，功能参考 `https://dingtouapp.org/`。图表使用项目内已有 ECharts，页面使用 FastAPI HTML、vanilla JavaScript 和共享设计变量。

## 数据与配置

- `GET /api/dca/market?symbol=SPY`：最近收盘价、1/3/5 年年化行情收益、SMA200、Price/SMA200、RV20、ER20、252 日内高点回撤。短历史返回 null，不使用样例填充。
- `POST /api/dca/backtest`：经 `DCAConfig` 验证的配置，返回现金流、每期执行原因、资产曲线、固定定投对照、XIRR 与剔除入金影响的最大回撤。
- 真实模式复用 `strategy_engine.get_prices` 和行情缓存；演示模式仅用现有合成数据，不访问网络、私人持仓或券商接口。演示模式缺少的代码明确报错。
- 配置保存在浏览器 `catfolio.dca.config.v1`；弹窗中取消 / Escape 不提交草稿。结果保留其实际运行参数，修改参数后显示待重算状态。交易记录可导出 CSV。

## 计算约定

这是一份只含选定资产和现金的独立模拟组合。初始资金作为现金池；每周或每月新增基础金额，从起始日期锚定，休市顺延，月底按原始日号取当月最后一天。价格使用现有数据源的复权收盘口径（数据源无复权值时会回落到原始价），份额为模型等效份额，不代表券商真实股数。不计利息、税费、滑点与交易费。

信号使用上一可用交易日，按计划日收盘价模拟成交。SMA200 需要 200 条历史；RV20 使用 20 个对数收益的样本标准差乘 √252；ER20 使用 20 日净变化绝对值除以每日绝对变化总和（价格不变时为 0）。不足时条件状态未知，保留新增入金并暂停条件买入。

价格 / SMA200 低于下限目标为 2×；高于上限，或任一启用的 RV / ER 判断不通过，优先使用最低倍数。回撤达到启用门槛后，10% / 20% / 30% 对应 1.5× / 2× / 3×；多个加仓信号取最大，不相乘，再受最高倍数约束。冷却期从实际买入大于当期基础入金时起算，只限制额外加仓。

现金储备和最高单资产仓位均以该模拟组合的总资产为分母；它们只约束新增买入，不因市场上涨而自动卖出。实际投入可小于最低倍数。因为只有一只资产，10–20% 的仓位限制通常比 20–40% 现金储备更严格；不要把它当作用户真实多资产组合的仓位检查。

固定定投对照使用相同入金和资金上限、始终以 1× 为目标；它不使用条件指标或冷却。收益率为期末利润 / 累计入金；XIRR 使用实际入金日期，少于 30 天返回 null；最大回撤使用剔除外部入金的单位净值。行情早于 / 晚于请求区间不足时显示实际范围及提示；不虚构未来价格。

## 验证

```sh
v3_backend/.venv/bin/python -m pytest v3_backend/tests/test_dca.py v3_backend/tests/test_app_contracts.py v3_backend/tests/test_strategy_demo.py v3_backend/tests/test_strategy_security.py v3_backend/tests/test_portfolio_lab_design.py -q
node --check v3_backend/app/static/dca.js
```

浏览器验证 `/dca?ui=v5`（现有中间件会重定向为 `/dca`），包括条件取消 / 应用 / 重载恢复、周月切换、图表切换与导出、错误恢复，以及 390px 窄屏与桌面。预览截图位于 `output/playwright/dca-*.png`。
