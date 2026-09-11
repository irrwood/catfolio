# 行业波动情绪 MVP

入口 `/sentiment?ui=v5`（当前应用规范化至 `/sentiment`），首页 `/lab` 的 Today Insight 链接到同一页面。手机纵向排列，桌面左指标右趋势。未提供截图文件，本版沿用现有 Lab 设计系统与用户描述的信息结构。

## 分层

- `core/volatility/__init__.py`：纯 Python `VolatilityRegimeEngine`，属于 Core，与 Rust/PostgreSQL 无依赖；不在页面重复计算。输入通用波动率日线与对应标的 OHLCV，可复用到其他行业。
- `core/volatility/collect.py`：Cboe VXSMH CSV、Yahoo Finance SMH OHLCV。纽约18:00之前排除当日，之后允许当日已完成日线；不计算期权 IV。
- `./core/dev collect-volatility`：采集入口，外置盘标记检查、TLS 校验、超时和响应大小限制、数据校验后原子发布。失败保留上一版，原始来源写入 T7 `core/storage/raw-data/volatility/`，发布到 `core/storage/volatility/current.json`。
- `v3_backend/app/volatility.py`：只读桥接，重新按当前日期判断 freshness；Core 必须与后端一起分发（Core 当前被仓库本地 exclude 排除）。
- `/api/volatility/semiconductors`：读取快照，按当前账户生成组合暴露；不在页面访问时触发采集。
- Codex 本任务已创建每日07:00（Europe/London）采集自动化；运行依赖本机 Codex 与 T7 可用，失败时通知。

## 口径 v1.1

20条交易日收盘价均值、总体标准差；Z=(close−mean)/std，平坦窗口Z=0。252条日线包含当日，分位=(小于当前的数量+0.5×等于当前的数量)/252。

Fear = 0.5×percentile + 0.3×100×normalCDF(Z20) + 0.2×clamp(50+5×日变化百分比,0,100)。Score=round(clamp(100−Fear,0,100))。0极度恐惧、100极度贪婪。该评分是启发式设计，未做预测有效性回测。

少于20条不输出MA或Z；20–251条使用可用历史分位数计算暂定评分，score_status=provisional；满252条自动变为complete。不足20条评分为空，状态为insufficient。一年分位数仅满252条输出，暂定阶段页面标为可用历史分位数。2026-09-08首次发布的已完成样本共246条。

两条数据必须包含相同的最近两个波动指数交易日，且最新日一致，才判断Regime。SMH跌、VX涨为Fear；其中可用历史分位≥90且（Z≥2或VX日涨≥10%）为Panic。SMH涨/平、VX涨为Hedging；SMH涨、VX跌为Risk-on；其余Neutral；缺失/不对齐为Unknown。超过4个自然日视为过期，过期数据保留可见但不生成当前高波动提示。该简化规则尚未接入交易所节假日日历。

组合比例采用已识别半导体股及SMH/SOXX的美元绝对市值/全部持仓美元绝对市值，不含现金或ETF穿透。识别清单为MVP显式清单，不等同完整行业分类。任一持仓缺失市值时不输出比例；演示账户显式标记。市值口径沿用现有账户快照，尚未验证组合报价的新鲜度。

## 验证

```sh
python3 -B -m unittest discover -s core/tests -p test_volatility.py
CATFOLIO_PUBLIC_DEMO=1 v3_backend/.venv/bin/python -m pytest v3_backend/tests/test_volatility_page.py -q
./core/dev collect-volatility
```

来源：Cboe https://cdn.cboe.com/api/global/us_indices/daily_prices/VXSMH_History.csv
SMH 使用现有项目同类 Yahoo chart 接口。供应商可用性及历史范围可能变化；不承诺实时行情或补足官方尚未提供的历史。
