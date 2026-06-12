# Portfolio Analysis 产品文档与页面审计

更新时间：2026-06-05  
当前入口：`http://127.0.0.1:8787/`

## 1. 产品定位

这是一个面向个人投资者的本地持仓分析工具。核心目标不是做一个“行情网站”，而是把 Trading 212 持仓、成本、实时行情、ETF 穿透、收益、风险、估值和组合优化放到同一个决策工作台里。

用户真正想回答的问题：

- 我现在整体赚了还是亏了，今天发生了什么？
- 哪些持仓贡献最大收益，哪些拖累最大？
- 仓位是否过度集中在某些股票、板块、ETF 或风格？
- 如果今天重建组合，应该加仓、减仓什么？
- 当前持仓贵不贵，风险大不大，回撤有多深？
- 数据到底来自哪里，哪些是账户真实数据，哪些只是模型估算？

当前产品已经覆盖了很多分析能力，但页面职责有重叠，数据口径分散，老 v2 报表和新 v3 Lab 并存，导致用户会在多个页面看到相似但不完全一致的答案。

## 2. 页面总览

### `/` 投资分析控制台

定位：后端控制台和导航入口。

现有模块：

- 持仓热力图 iframe 预览
- 主要动作：打开报表、打开 Lab、打开热力图、API 文档
- 刷新行情、刷新 Trading 212
- 核心 API 链接

优点：

- 入口清楚，适合作为后端控制台。
- 能快速跳到报表、Lab、热力图。
- 把刷新动作放在首页符合“控制台”心智。

问题：

- 首页嵌入热力图，与 `/heatmap` 重复。
- “刷新行情”和“刷新”命名不清，第二个刷新实际是 Trading 212。
- API 列表对普通投资者价值较低，占据首页空间。
- 没有全局数据状态，如持仓刷新时间、行情刷新时间、估值刷新时间、API key 状态。

建议职责：

- 首页只保留“系统状态 + 刷新入口 + 主要页面导航”。
- 热力图只保留小型预览或直接入口，不要承担完整分析功能。
- API 链接折叠到开发者区。

### `/report` Trading 212 API 持仓分析 v2

定位：旧版静态报表，偏“审计、成本、对账、导出”。

现有模块：

- 持仓成本规模
- Trading 212 API 更新对账
- S&P 500 基金穿透分析
- 持仓分析
- 收入统计
- 主要持仓
- 量化雷达
- 图表视图
- 每只股票成本价
- 口径与提示
- 多个 CSV 导出

优点：

- 成本价、账户对账、收入统计和导出能力较完整。
- 适合做“存档报表”和税务、复盘材料。
- 口径提示比 Lab 更完整。

问题：

- 与 `/lab` 的持仓明细、PnL、S&P 500 重复。
- “量化雷达”和 Lab 的 Factor Analysis、Portfolio Rebuild 有功能重叠。
- “图表视图”已经被新的 Lab 和 Heatmap 替代，继续保留会造成用户困惑。
- 视觉和交互风格与 v3 页面不统一。
- 页面标题仍是 v2，和当前 v3 后端控制台并存，产品版本感混乱。

建议职责：

- 把 `/report` 收敛为“审计报表页”。
- 保留成本价、交易流水、收入统计、账户对账、导出。
- 移除或降级旧图表视图、旧量化雷达、旧持仓分析。
- 从 Lab 链接到 Report 时，文案改为“审计报表”而不是“报表”。

### `/lab` Portfolio Lab

定位：当前核心产品页面，组合分析和决策工作台。

现有模块：

- 顶部总览卡：总市值、总浮盈、今日盈亏、持仓股数、夏普比率、最大回撤
- 最大回撤时间选择：全部、1 年、6 月、3 月、1 月
- 每日盈亏
- 月度收益热图
- 估值矩阵 P/E vs 成长
- 估值水位 Premium/Discount
- 4 个问题：Backtesting、Optimization、Monte Carlo、Factor
- Portfolio Command Center
- 持仓分类集中度
- 个股盈亏贡献
- 持仓明细
- 模型累计收益 vs 基准
- 收益率分布
- 回撤水下曲线
- 持仓相关性矩阵
- 模型归因 Waterfall
- 52 周位置
- Backtesting
- Portfolio Rebuild
- Optimization Suggestions
- Monte Carlo
- Decision Brief
- Factor Analysis
- Optimized Portfolios
- 资产归并
- Monte Carlo Range
- 状态

优点：

- 是当前最接近“投资决策驾驶舱”的页面。
- Perplexity 风格已经比较统一。
- 把真实持仓数据和模型分析分区，方向正确。
- 有效前沿、蒙特卡洛、因子分析、相关性、回撤等能力已经成形。
- 新增估值水位后，估值判断比单个气泡图更直观。

问题：

- 页面过长，很多模块回答相似问题。
- 顶部有“每日盈亏、月度收益热图”，Command Center 里又有“模型累计收益、收益率分布、Waterfall”，都属于收益分析，但分散。
- “今天先回答这 4 个问题”和后面的 Backtesting、Portfolio Rebuild、Monte Carlo、Factor Analysis 是摘要与详情关系，但视觉上像两个独立产品。
- Command Center 中的“持仓明细”和 Report 的“每只股票成本价”重复。
- 估值矩阵、估值水位、热力图估值模式都在讲“贵不贵”，但还没有统一解释。
- 数据质量说明存在，但不够显眼。模型类图表容易被误认为真实账户收益。
- `/api/command-center` 里 `fundamentals.status` 仍写 `needs_fundamentals_api`，但现在 FMP 已接入，这个状态已过期。

建议职责：

- `/lab` 保留为唯一“分析与决策”页面。
- 以用户问题组织，而不是以图表类型组织：
  - 现在怎么样：总览、今日盈亏、持仓明细、热力图入口
  - 风险在哪里：集中度、相关性、回撤、风险贡献
  - 收益从哪里来：PnL 贡献、Waterfall、月度热图、累计收益
  - 贵不贵：估值矩阵、估值水位、52 周位置
  - 怎么调仓：Portfolio Rebuild、Optimization Suggestions、Decision Brief
- 把摘要卡和详情模块建立明确跳转或锚点关系。

### `/heatmap` 持仓热力图

定位：盯盘和暴露观察的全屏视图。

现有模块：

- 按板块 / 按大小切换
- USD / GBP 切换
- 今日 / 盈亏 / 估值模式
- 中文 / 英文 / 隐藏名称
- 日间 / 夜间
- 刷新数据、刷新估值、刷新持仓
- hover 详情

优点：

- 这是最清楚的视觉化持仓入口。
- 模式切换覆盖了“今日涨跌、整体盈亏、估值”三个高频视角。
- 全屏单页体验比 Lab 内嵌更合适。

问题：

- 缺少 H1 或清晰页面标题，对可访问性和语义不好。
- 刷新动作和首页重复。
- 估值模式依赖 fundamentals，当前只有 3 个 FMP 美股数据，很多股票没有估值，会导致用户误解。
- 热力图和 Lab 的持仓集中度、估值水位、PnL 贡献部分重叠，但没有互相解释。
- 没有明确图例，用户需要自己理解颜色和面积。

建议职责：

- 保持为独立全屏“视觉盯盘页”。
- 增加小型图例和数据覆盖率提示。
- 刷新按钮保留，但增加更新时间和失败原因，不要只显示“刷新完成”。
- 加隐藏标题或视觉标题，提升语义。

## 3. 数据源与口径

### 当前数据源

- Trading 212 API：持仓、现金、成本、账户快照。
- CSV 历史文件：早期成本价和交易记录基础。
- Yahoo Finance chart：实时行情、历史日线价格、Lab 回测。
- FMP：fundamentals，当前用于 P/E、P/S、P/B、EPS growth、Revenue growth。
- Finnhub：保留为 fundamentals 备选。
- FRED、Massive、宏观和期权数据：项目里有缓存文件或脚本痕迹，但当前 v3 页面未形成稳定产品功能。

### 数据口径分类

可靠账户数据：

- 当前持仓数量
- 成本价
- 持仓市值
- 浮盈亏
- 现金
- 账户对账

市场数据：

- 当前价格
- 今日涨跌
- 52 周高低位置
- 历史价格

模型估算：

- 当前权重回测
- 月度收益热图
- 累计收益 vs 基准
- 收益率分布
- 回撤水下曲线
- 相关性矩阵
- Waterfall
- Efficient Frontier
- Monte Carlo
- Factor Analysis

当前需要特别标注的风险：

- Lab 的历史收益不是现金流口径真实账户收益，而是当前仓位模型回测。
- FMP fundamentals 当前只覆盖部分美股，ETF、英股、部分欧洲股票可能没有估值数据。
- S&P 500 ETF 穿透仍是近似权重，不应当当成实时基金持仓。
- 汇率使用固定或缓存口径，不是完整实时 FX。

## 4. 重复功能清单

### 重复 1：持仓明细

出现位置：

- `/report` 每只股票成本价
- `/lab` Portfolio Command Center 持仓明细
- `/api/holdings`

问题：

- Report 更像审计，Lab 更像决策，但两边都展示成本、现价、涨跌、浮盈。
- 用户可能不知道哪个是最新版。

建议：

- `/lab` 保留轻量决策表，只显示 Top holdings 和核心列。
- `/report` 保留完整明细和导出，作为唯一完整审计表。

### 重复 2：热力图

出现位置：

- `/` 首页 iframe
- `/heatmap` 全屏页
- `/lab` 顶部链接

问题：

- 首页嵌入会让用户以为首页也能完整操作热力图。

建议：

- 首页保留缩略入口或状态卡，不嵌完整热力图。
- `/heatmap` 是唯一全功能热力图。

### 重复 3：收益分析

出现位置：

- `/lab` 每日盈亏
- `/lab` 月度收益热图
- `/lab` 模型累计收益 vs 基准
- `/lab` 模型归因 Waterfall
- `/report` 收入统计
- `/report` 主要持仓

问题：

- 真实收入、浮盈亏、模型收益混在一起。

建议：

- 收益分成三类：
  - 账户真实：股息、利息、已实现盈亏，放 Report。
  - 当前持仓浮盈：放 Lab 总览和 Command Center。
  - 模型回测收益：放 Lab 的模型分析区。

### 重复 4：风险分析

出现位置：

- `/lab` 夏普比率、最大回撤
- `/lab` 回撤水下曲线
- `/lab` 收益率分布
- `/lab` 持仓相关性矩阵
- `/lab` Portfolio Rebuild 风险评分
- `/report` 量化雷达

问题：

- 同样是风险，分散在多个区域，且 Report 的量化雷达和 Lab 的风险模块可能给出不同感受。

建议：

- `/lab` 保留风险分析主能力。
- `/report` 的量化雷达改为“历史版本”或移除。

### 重复 5：ETF / S&P 500 穿透

出现位置：

- `/report` S&P 500 基金穿透分析
- `/lab` 资产归并
- `/api/etf-lookthrough`
- `/api/lab/history` 的 S&P 500 Fund grouping

问题：

- “ETF 穿透”和“资产归并”不是同一件事，但目前容易被用户理解成同一件事。
- VUAG/VUSA 合并已经处理在 Lab history，但 Report 里可能仍然显示旧逻辑。

建议：

- 建立统一的 Exposure Engine：
  - 第一层：合并重复 ETF，比如 VUAG/VUSA。
  - 第二层：ETF look-through 到底层股票。
  - 第三层：直接股票 + 穿透股票合并。
- 所有页面使用同一个 exposure API。

### 重复 6：估值判断

出现位置：

- `/lab` 估值矩阵
- `/lab` 估值水位
- `/heatmap` 估值模式
- `/api/fundamentals`

问题：

- 估值矩阵回答“P/E 和成长是否匹配”。
- 估值水位回答“相对同类贵不贵”。
- 热力图估值模式回答“哪些仓位面积大且估值高”。
- 三者有价值，但需要统一说明。

建议：

- 将它们归入“贵不贵”问题组。
- 明确三种视角：
  - 估值矩阵：相对成长。
  - 估值水位：相对同组中位数。
  - 热力图估值：仓位权重叠加估值风险。

## 5. 缺失能力清单

### P0：数据状态与可信度中心

缺失内容：

- Trading 212 最近刷新时间
- Yahoo 行情最近刷新时间
- FMP fundamentals 最近刷新时间
- 历史价格缓存时间
- API key 是否可用
- 每个数据源覆盖了多少持仓
- 哪些图表正在用真实账户数据，哪些是模型估算

建议：

- 首页增加 Data Health 面板。
- Lab 顶部增加小型数据状态条。
- Heatmap 增加估值覆盖率和更新时间。

### P0：真实账户收益率

缺失内容：

- 现金流调整收益率，如 Time Weighted Return 或 Money Weighted Return。
- 充值、提现、买入、卖出、股息、利息对收益的拆解。

当前风险：

- Lab 的回测收益容易被误读成真实账户收益。

建议：

- 建立 transaction ledger。
- Report 做真实账户收益。
- Lab 明确只做当前组合模型收益。

### P0：统一页面信息架构

缺失内容：

- 当前没有统一导航层级。
- `/report` 和 `/lab` 之间关系不明确。
- 首页像后端控制台，Lab 像产品主界面，Report 像旧产品。

建议：

- 主导航改成：
  - Overview
  - Lab
  - Heatmap
  - Report
  - Settings / Data
- 当前页高亮。
- Report 命名为 Audit Report。

### P1：设置页

缺失内容：

- Trading 212 API key 状态
- FMP key 状态
- Finnhub key 状态
- Massive key 状态
- FRED key 状态
- 数据刷新策略
- 缓存清理
- 汇率设置

建议：

- 新增 `/settings` 或 `/data-sources`。
- 只显示 key 是否存在和最后验证结果，不显示明文 key。

### P1：统一导出中心

缺失内容：

- 不同页面导出按钮分散。
- Lab 的图表和建议没有导出。
- Heatmap 没有图片导出。

建议：

- Report 作为导出中心。
- 支持 CSV、Excel、PNG、完整 HTML snapshot。

### P1：可解释的调仓建议

缺失内容：

- Optimization Suggestions 已有，但还不够像投资建议工作流。
- 没有约束条件输入，如不卖某些股票、税务限制、最低交易金额、目标现金比例。
- 没有把“应该买什么”和当前现金金额连接起来。

建议：

- 增加 “Rebalance Plan”：
  - 当前现金
  - 风险偏好
  - 不动持仓
  - 建议买入/减仓金额
  - 预期风险变化
  - 原因解释

### P1：ETF 穿透可信数据源

缺失内容：

- ETF 最新持仓数据源。
- VUAG/VUSA/XUSE/CNX1 等基金的真实成分和更新时间。

建议：

- 对常见 ETF 建立 fund holdings cache。
- 如果没有实时基金成分，显示“估算穿透”。

### P2：移动端任务流

缺失内容：

- Lab 太长，移动端虽然不溢出，但任务流沉重。
- Heatmap 移动端可看，但控制按钮多。

建议：

- 移动端 Lab 只显示 Overview、Heatmap、Alerts、Top Questions。
- 深度图表折叠。

### P2：提醒与监控

缺失内容：

- 估值水位超过阈值提醒。
- 单股仓位过高提醒。
- 回撤超过阈值提醒。
- 52 周位置接近高点/低点提醒。

建议：

- 先做本地规则，不需要自动交易。

## 6. 建议的新产品结构

### 首页 `/`

职责：系统总览和数据健康。

保留：

- 总市值、总浮盈、今日盈亏
- 数据源状态
- 刷新入口
- 页面导航

移除或折叠：

- 完整热力图 iframe
- 开发者 API 列表

### Lab `/lab`

职责：投资决策工作台。

建议结构：

1. Portfolio Snapshot  
   总市值、今日盈亏、总浮盈、持仓数、最大回撤、数据更新时间。

2. What Changed  
   每日盈亏、个股盈亏贡献、Waterfall。

3. Where Is The Risk  
   板块集中度、相关性、回撤、收益分布。

4. Is It Expensive  
   估值矩阵、估值水位、52 周位置、热力图入口。

5. What Should I Do  
   Portfolio Rebuild、Optimization Suggestions、Decision Brief。

6. Model Lab  
   Efficient Frontier、Monte Carlo、Factor Analysis、Backtesting。

### Heatmap `/heatmap`

职责：全屏视觉盯盘。

保留：

- 按大小、按板块
- 今日、盈亏、估值
- USD、GBP
- 昼夜模式

补充：

- 标题和图例
- 数据覆盖率
- 当前颜色模式说明

### Report `/report`

职责：审计、对账、导出。

保留：

- 成本价
- 账户对账
- 收入统计
- 交易记录
- CSV/Excel 导出
- 口径说明

移除或降级：

- 旧图表视图
- 旧量化雷达
- 与 Lab 重复的持仓分析

### Settings `/settings`，建议新增

职责：数据源、刷新、安全。

模块：

- API key 状态
- 数据源覆盖率
- 缓存更新时间
- 汇率设置
- 刷新策略
- 本地文件路径

## 7. 数据产品改造建议

### 建立统一数据层

建议新增一个 normalized portfolio model：

- `positions`: 当前持仓
- `transactions`: 交易流水
- `cash_flows`: 入金、出金、股息、利息
- `quotes`: 行情
- `fundamentals`: 估值
- `history`: 历史价格
- `exposures`: ETF 穿透与合并暴露
- `metrics`: 派生指标

每个页面只读 normalized model，不自己拼口径。

### 给所有指标加 metadata

每个图表/指标应有：

- `source`
- `as_of`
- `coverage`
- `basis`
- `is_model_based`
- `warnings`

这样页面能自动显示可信度，不用每个模块手写说明。

## 8. 优先级路线图

### 第一阶段：减重复，稳口径

- 首页改为数据健康控制台。
- Report 改成 Audit Report。
- Lab 重排为问题导向。
- 修复 `/api/command-center` 中 fundamentals 过期状态。
- 给 FMP 覆盖率做显式提示。

### 第二阶段：补关键缺口

- 新增 Settings / Data Sources 页面。
- 建真实账户收益率计算。
- ETF 穿透统一 exposure API。
- 把股息、利息、已实现盈亏纳入 Lab 的收益解释。

### 第三阶段：增强决策

- Rebalance Plan 支持现金金额、风险偏好和约束。
- 增加提醒系统。
- 导出完整投资报告。
- 增加 benchmark 和时间范围选择。

## 9. 当前最需要修的 10 个点

1. 把首页热力图 iframe 改成入口卡，避免和 `/heatmap` 重复。
2. 把 `/report` 重命名为 Audit Report，并隐藏旧图表视图。
3. 修复 `/api/command-center` 的 fundamentals 状态，FMP 已接入，不应再写 `needs_fundamentals_api`。
4. Lab 顶部增加数据健康条，显示 Trading 212、Yahoo、FMP、历史价格更新时间。
5. Heatmap 增加标题、图例和估值覆盖率。
6. 将 Lab 的收益、风险、估值、优化按问题分组重排。
7. 把 Report 的持仓明细作为唯一完整导出表，Lab 只做决策摘要表。
8. 增加 Settings / Data Sources 页面。
9. 建真实账户收益率，与当前模型收益明确分开。
10. 建统一 exposure API，解决 ETF 穿透、VUAG/VUSA 合并、直接持仓重复计算问题。

## 10. 审计截图

- 首页：`outputs/product_audit_home.png`
- 报表：`outputs/product_audit_report.png`
- Lab：`outputs/product_audit_lab.png`
- 热力图：`outputs/product_audit_heatmap.png`
