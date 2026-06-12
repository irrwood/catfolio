# V3XP 清理与整合计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 收紧 v3xp 产品：消除页面间重复、统一数据口径、重构 Lab 为问题导向布局、增加数据健康指示器、实现真实 TWR 回报率。

**Architecture:** 保持现有 FastAPI 纯 Python 后端 + 服务端渲染 HTML 的技术栈不变。核心改动分四个方向：(1) 拆分 main.py 巨型文件为路由模块；(2) 重排 Lab 为问题分组布局；(3) 新增数据健康条组件；(4) 实现基于交易流水的真实 TWR 回报率计算。

**Tech Stack:** Python 3, FastAPI 0.115, uvicorn, ECharts, Lightweight Charts, DeepSeek AI — 与现有完全一致，不引入新依赖。

---

## 前置：项目当前状态快照

产品审计文档列出了 10 个最高优先级问题和三阶段路线图。经过检查，以下项目已完成：

- 首页热力图 iframe → 已移除（首页已是纯数据控制台 + 导航入口）
- 设置页 `/settings` → 已存在（API key 状态、缓存生命周期、汇率）

以下项目仍需处理：

| # | 问题 | 状态 |
|---|------|------|
| 2 | `/report` 仍用旧 v2 HTML，风格与 v3xp 割裂 | 待修 |
| 3 | `/api/command-center` fundamentals status 可能过期 | 待验证 |
| 4 | Lab 顶部缺少数据健康条 | 待做 |
| 5 | Heatmap 缺少标题、图例、估值覆盖率 | 待做 |
| 6 | Lab 模块排列未按问题分组 | 待做 |
| 9 | 缺少真实账户 TWR/IRR 回报率 | 待做 |
| 10 | ETF 穿透未统一 exposure API | 待做 |

---

## 任务总览

```
Phase 1 (struct):   拆分 main.py 路由           — Task 1-4
Phase 2 (data):     统一 exposure API + 数据健康条  — Task 5-7
Phase 3 (ux):       Lab 问题分组重构              — Task 8-10
Phase 4 (returns):  真实 TWR 回报率              — Task 11-14
Phase 5 (polish):   Heatmap UX + Report 清理     — Task 15-17
```

---

### Task 1: 创建路由模块骨架

**Files:**
- Create: `v3_backend/app/routes/__init__.py`
- Create: `v3_backend/app/routes/home.py`
- Create: `v3_backend/app/routes/lab.py`
- Create: `v3_backend/app/routes/heatmap.py`
- Create: `v3_backend/app/routes/returns.py`
- Create: `v3_backend/app/routes/backtest.py`
- Create: `v3_backend/app/routes/report.py`
- Create: `v3_backend/app/routes/ai.py`
- Create: `v3_backend/app/routes/settings.py`
- Create: `v3_backend/app/routes/api.py`
- Create: `v3_backend/app/components.py`
- Modify: `v3_backend/app/main.py`

- [ ] **Step 1: 创建 components.py — 提取共享 UI 组件**

新建 `v3_backend/app/components.py`，包含 `wrap_v3xp_layout()` 和 `data_health_bar()` 函数。从 main.py 中逐字复制 `wrap_v3xp_layout()` 完整实现，再添加 `data_health_bar()`（详见下方代码块）。

- [ ] **Step 2: 创建 routes/__init__.py**

空文件，含 docstring。

- [ ] **Step 3: 创建各路由模块骨架**

每个模块创建 `router = APIRouter(tags=["pages"])` 并包含 route decorator 空壳。

- [ ] **Step 4: 修改 main.py 注册路由**

将 main.py 精简为 app 初始化 + CORS + static mount + `include_router` 调用。

- [ ] **Step 5: Commit**

---

### Task 2: 迁移 home 路由

**Files:**
- Create: `v3_backend/app/routes/home.py`
- Modify: `v3_backend/app/main.py`

从 main.py 复制 `index()` 和 `test_lw()` 到 routes/home.py，修改 import 路径为 `from app.components import ...`。逐个验证页面正常渲染。

---

### Task 3: 迁移 lab, heatmap, returns, backtest, ai, settings 路由

**Files:**
- Create: 各 route 文件
- Modify: `v3_backend/app/main.py`

对每个页面路由：复制函数体 → 修改 import → 注册 router → 验证 → 从 main.py 删除原函数。

---

### Task 4: 迁移 API 路由

**Files:**
- Create: `v3_backend/app/routes/api.py`
- Modify: `v3_backend/app/main.py`

复制所有 `/api/` 端点到 routes/api.py。验证全部 API 返回 200。

---

### Task 5: 修复 command-center fundamentals 状态

**Files:**
- Modify: `v3_backend/app/routes/api.py`

在 `command_center()` 函数中，将 `fundamentals.status` 从硬编码的 `"needs_fundamentals_api"` 改为根据缓存数据动态判断：

```python
fund_rows = snapshot["fundamentals"].get("rows", [])
fund_status = "available" if fund_rows else "unavailable"
```

同时在返回值中增加 `data_health` 字段，包含各数据源刷新时间和覆盖数量。

---

### Task 6: 统一 Exposure API

**Files:**
- Modify: `v3_backend/app/analytics.py`
- Modify: `v3_backend/app/routes/api.py`

新增 `unified_exposure()` 函数，整合三层暴露：
1. 合并重复 ETF（VUAG/VUSA → 单一 S&P 500 Fund）
2. ETF look-through 穿透到底层股票
3. 直接股票 + 穿透股票合并

让 `etf_lookthrough()` 和 `chart_exposure()` 内部引用统一逻辑。新增 `GET /api/exposure` 端点。

---

### Task 7: 给 Lab 和 Heatmap 添加数据健康条

**Files:**
- Modify: `v3_backend/app/routes/lab.py`
- Modify: `v3_backend/app/routes/heatmap.py`
- Modify: `v3_backend/app/static/v3xp.css`

在 Lab 和 Heatmap 页面顶部插入 `data_health_bar()`，显示 Trading 212、Yahoo 行情、FMP 估值三项的刷新时间和数据量，用绿色/黄色圆点区分新鲜/过期状态。

---

### Task 8: Lab 问题分组 — 重构 HTML 结构

**Files:**
- Modify: `v3_backend/app/routes/lab.py`

将 Lab 内容重排为 6 个问题分组，每组用 `<details open>` 折叠面板：

1. Portfolio Snapshot（总览卡）
2. 现在怎么样？（每日盈亏、月度热图、盈亏贡献、持仓明细 Top 10）
3. 风险在哪里？（集中度、相关性、回撤、收益分布、52 周位置）
4. 贵不贵？（估值矩阵、估值水位）
5. 怎么调？（Portfolio Rebuild、优化建议、Decision Brief）
6. 模型实验室（Backtesting、有效前沿、蒙特卡洛、因子分析）

移除顶部 "今天先回答这 4 个问题" 区域——对应的详情已在各自分组内。

---

### Task 9: 精简 Lab 持仓明细表

**Files:**
- Modify: `v3_backend/app/routes/lab.py`

Lab 的持仓明细降级为 Top 10 摘要表（ticker、名称、权重、今日涨跌、浮盈%）。底部添加 "完整持仓 → 审计报表" 链接指向 `/report`。

---

### Task 10: 给 Heatmap 添加标题和图例

**Files:**
- Modify: `v3_backend/app/routes/heatmap.py`

在热力图上方添加页面内标题 "持仓热力图"、说明文字、以及估值覆盖率动态提示。当用户切换到 "估值 P/E" 颜色模式时，显示 `估值覆盖: X/Y 只`。

---

### Task 11: 实现真实 TWR 回报率计算

**Files:**
- Create: `v3_backend/app/returns_twr.py`
- Modify: `v3_backend/app/routes/api.py`

新增 TWR 计算模块，使用 lab.py 的 6 个 CSV 交易文件重建现金流序列。MVP 版本按月度汇总现金流和交易笔数，返回简化 TWR 指标。暴露 `GET /api/returns/twr` 端点。

---

### Task 12: 完善 TWR — 每日持仓估值快照

**Files:**
- Modify: `v3_backend/app/returns_twr.py`

添加 `_daily_nav_series()` 骨架函数，用累积持仓 × Yahoo 日线价格重建每日估值序列。MVP 阶段返回结构说明，完整实现留待后续（需要 N 天 × N 只股票的 Yahoo API 调用）。

---

### Task 13: 在 Lab 和 Returns 页面区分真实收益与模型收益

**Files:**
- Modify: `v3_backend/app/routes/lab.py`
- Modify: `v3_backend/app/routes/returns.py`
- Modify: `v3_backend/app/static/v3xp.css`

所有模型类图表标题旁添加 `当前权重模型` 标签（蓝色），Returns 页面顶部添加说明框。CSS 新增 `.data-badge` 系列样式。

---

### Task 14: 清理 /report 页面

**Files:**
- Modify: `v3_backend/app/routes/report.py`

隐藏 v2 旧图表视图和量化雷达区域（用 regex 替换为 HTML 注释）。页面标题改为 "审计报表"。确认侧边栏导航标签同步更新。

---

### Task 15: 添加提醒与监控系统

**Files:**
- Create: `v3_backend/app/alerts.py`
- Modify: `v3_backend/app/routes/home.py`
- Modify: `v3_backend/app/static/v3xp.css`

本地规则检查器 `check_alerts()`，检测：单票仓位 > 25%、高 PE 持仓、回撤 > 20%。首页新增提醒卡片展示结果。

---

### Task 16: CSS 清理 — 审计 v3xp.css

**Files:**
- Modify: `v3_backend/app/static/v3xp.css`

分析 37000 行 CSS 的来源（Tailwind 生成 vs 手工累积）。如果是 Tailwind，找配置只保留用到的 utility classes。将本次新增样式追加到文件末尾。

---

### Task 17: 全量验证与回归

**Files:**
- None

验证全部 8 个页面路由返回 200，所有核心 API 端点正常，Python import 无错误。确认 `/api/returns/twr` 新端点可访问。

---

## 自检清单

覆盖审计文档的 10 个待修点：

1. ✅ Home 页热力图 iframe — 之前已移除
2. ✅ `/report` 改为审计报表 — Task 14
3. ✅ command-center fundamentals status — Task 5
4. ✅ Lab + Heatmap 数据健康条 — Task 7
5. ✅ Heatmap 标题、图例、覆盖率 — Task 10
6. ✅ Lab 问题分组重排 — Task 8
7. ✅ Lab 持仓精简 → Report 完整 — Task 9
8. ✅ Settings 页 — 已存在
9. ✅ 真实账户 TWR — Task 11-12
10. ✅ 统一 exposure API — Task 6

额外覆盖：

- 模型/真实数据口径标签 — Task 13
- 提醒系统 — Task 15
- main.py 拆分 — Task 1-4
- CSS 清理 — Task 16

---

## 执行建议

Phase 1 (Task 1-4) 必须顺序执行（路由拆分有依赖）。Phase 2 (Task 5-7) 可在 Phase 1 完成后并行。Phase 3 (Task 8-10) 的 UI 工作可提前。Phase 4 (Task 11-14) 在全部前置完成后执行。Phase 5 (Task 15-17) 最后做。

预计总工作量：3-4 小时（取决于 main.py 拆分时的验证轮次）。
