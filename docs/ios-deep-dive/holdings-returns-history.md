# Catfolio iOS「持仓 / 收益 / 历史 / 个股详情」主链路代码考古报告

分析目录：`CatfolioIOS/CatfolioIOS`（111 个 Swift 文件，纯 SwiftUI）。
只读分析，未修改任何现有文件。所有引用为 `文件:行号`，公式为逐字摘录。全文区分**确实实现**与**文档/注释声称**。

---

## 0. 四 tab 与页面结构总览

```text
RootTabView.swift:81  TabView(selection:)
├─ Tab .portfolio  → PortfolioView.swift:263                    标题「持仓」
│   └─ ScrollView :307
│       ├─ PortfolioRefreshTimestamp :504
│       ├─ CostMarketCard :1287                    ← 总资产 hero + 净值/成本曲线 + 时间范围
│       │   ├─ FastCostMarketPlot :1687
│       │   └─ ChartTimeRangePicker (DesignSystem.swift:1801)
│       └─ PortfolioContentSheet :160
│           ├─ TodayContributionCard :535          ← 今日盈亏/归因条
│           ├─ PortfolioDetailsCard :1915          ← 持仓列表 / 热力图 / ETF 穿透 三态
│           │   ├─ HoldingRow :2886 → HoldingMetrics :3036
│           │   ├─ HoldingsHeatmapView  (HoldingsHeatmapView.swift:9)
│           │   └─ ETFExposureRow :2766
│           └─ sheet → HoldingDetailView (= VolumeProfileView.swift:27)
│       └─ navigationDestination → TodayDetailView.swift:19
├─ Tab .returns    → ReturnsView.swift:3                          标题「Performance」
│   └─ SettingsPage :21
│       ├─ PortfolioDetailsCard(showsHeatmap:true) :25 → PerformanceHeatmapHero
│       ├─ TodayAttentionPreview
│       └─ SettingsNavigationRow × ReturnsChartDestination :134
│           ├─ .contributors → HoldingContributionChart.swift:11
│           ├─ .losses       → LossAnalysisChart.swift:8
│           ├─ .comparison   → ReturnsComparisonPanel :262 → ReturnsChart :694
│           ├─ .drawdown/.valuation → ReturnsAnalyticsView.swift:3
│           └─ .underwater   → UnderwaterAnalysisChart.swift:9
├─ Tab .research   → ResearchView.swift
└─ Tab .settings   → SettingsView.swift
```

**关键结论：热力图、ETF 穿透、回撤/水下/损失/贡献度五条支线全部挂在「收益」tab 的滚动页里，不是独立页面**（`ReturnsView.swift:134-203`）。首页的 `PortfolioDetailsCard` 默认不显示热力图（`PortfolioView.swift:1930-1936`，`showsHeatmap` 默认 false）。

---

## 1. 数据流、刷新触发点、缓存先展示后刷新

### 1.1 单一状态源：`AppModel`（`APIClient.swift:6`）

视图层**不直接持有 store**，全部通过 `@Environment(AppModel.self)` 读 `model.holdings / model.overview / model.portfolioChart / model.holdingDailyChanges / model.comparison / model.returnsAnalytics`。真实取数走 `LocalPortfolioStore.shared` → 磁盘账本 `LocalPortfolioDocument`，计算走 `LocalPortfolioEngine`（`LocalPortfolioStore.swift:1848`）与 `LocalMarketDataClient`（`LocalServices.swift`）。

### 1.2 首页刷新链（`AppModel.refreshPortfolio`，`APIClient.swift:101-194`）

顺序刻意设计成「先磁盘、后网络」，注释在 `:116-117` 明说：

```text
1) loadActiveDocument()                        // 读本地账本（APIClient.swift:114）
2) restoreHomePresentation(from:)              // 用 PortfolioPresentationCache 立刻上屏（:118）
   └─ 命中 → restoreSourcePresentation :1451   // 直接赋值 overview/chart/holdings/dailyChanges
3) 未命中 → apply(loaded, preservesChart: canPreserveHomeChart)  // :123
4) isPortfolioLoading = false                  // :128 解锁控件
5) 并行：refreshHistoricalChart ∥ refreshHoldingDailyChanges ∥ LocalCurrentFXRefresh ∥ latestQuotes
                                               // :162-174
6) apply(loaded, invalidatesDailyChanges:false) // :182 行情回来后原地更新
7) saveHomePresentation(generation:)            // :185 回写缓存
```

时间线三条链互不阻塞：`refreshHistoricalChart`（净值曲线，`:1636`）先在 `cachedOnly:true` 下取本地缓存直接上屏（`:1640-1648`），再 `enrichPortfolioChart`（`:1653`）拉全量。

### 1.3 刷新触发点

| 触发点 | 位置 |
|---|---|
| 首屏 `.task`（`overview == nil` 时） | `PortfolioView.swift:426-429` |
| 下拉刷新（自研桥接，非系统 refreshable） | `PortfolioView.swift:399-409` → `PortfolioHomeScrollBridge`（`PortfolioHomeScrollInteraction.swift:426`），`refresh: { await model.refreshPortfolio() }` |
| 错误态「重试」按钮 | `PortfolioView.swift:387` |
| 收益页下拉 | `ReturnsView.swift:214-220` → `refreshReturnsPage()`（`APIClient.swift:310`） |
| 冷启动分析数据 | `ReturnsView.swift:227-240`（`comparison == nil` 才拉） |

`PortfolioHomeScrollBridge` 是 `UIViewRepresentable`，通过向上遍历 `superview` 找到 `UIScrollView` 挂 `PortfolioHomeScrollController`（`:454-469`），用一个 `isUserInteractionEnabled = false` 的边界视图订阅偏移——**没有用系统 `.refreshable`**，注释（`PortfolioView.swift:422-424`）解释为需要「原生橡皮筋 + 仅在完全静止的下限被新手势武装」。

### 1.4 Skeleton 与 ripple 加载动画

- Skeleton：`PortfolioLoadingView`（`PortfolioView.swift:3175`）、`HomeSkeletonBlock`（`:3090`）、`TodayContributionLoadingBars`（`:3103`）、`PortfolioChartLoadingPlaceholder`（`:3248`）。`isHomeReadyForRipple`（`:290-295`）要求 overview/chart/holdings/三个 loading flag 全部就绪。
- Ripple：`PortfolioLoadRipple`（`PortfolioLoadRipple.swift:19`）。流程 = 等 500ms 让入场动画收敛 → `UIGraphicsImageRenderer` 整屏截图（`:206-216`）→ `TimelineView(.animation(1/60))` 对**静态图片**做 `ShaderLibrary.portfolioLoadRipple` 水波纹着色（`:50-62`）。注释 `:18` 明确「One completion cue per app launch」，`PortfolioLoadRippleHistory.hasPlayed`（`:13-14`）保证只播一次。单击任意位置立即 `stop()`（`:227-232`，识别器 `return false` 不抢手势）。

### 1.5 缓存先展示后刷新的边界条件

`restoreHomePresentation`（`APIClient.swift:1506-1525`）的守卫很严：

```swift
// APIClient.swift:1508-1509
guard overview == nil || presentedSource != portfolioSource,
      detailMarketObservations[portfolioSource]?.isEmpty != false else { return false }
```

即：**当前已显示且来源相同、或个股详情页刚推入过更新的报价时，不做缓存恢复**（否则会把更新的报价回退）。恢复后 `holdingDailyChangesSignature = ""`（`:1523`）强制后台重拉当日涨跌，并注释「restoration is not a fresh quote」。

---

## 2. 首页指标清单与公式

数据源 `LocalPortfolioEngine.presentation(for:)`（`LocalPortfolioStore.swift:1900-2015`）。

### 2.1 总市值、成本、未实现盈亏

```swift
// LocalPortfolioStore.swift:1890-1898  totals(for:)
cost        += usd(position.shares * position.averageCost, currency: position.currency)
marketValue += usd(position.shares * position.quotePrice,  currency: position.quoteCurrency)

// :1906
let unrealized = totals.marketValue - totals.cost
```

（公开披露组合走 `PublicInvestorAccountAdapter`，成本记 `.nan`，`:1894`。）

单持仓（`:1928-1993`）：

```swift
let costUSD   = usd(shares * averageCost, currency: costCurrency)
let marketUSD = usd(shares * quotePrice,  currency: quoteCurrency)
let pnl       = marketUSD - costUSD
unrealizedPercent = costUSD > 0 ? pnl / costUSD * 100 : 0     // :1988
weight            = totals.marketValue > 0 ? marketUSD / totals.marketValue : 0   // :1986
```

### 2.2 今日涨跌与今日归因

`PortfolioOverview.todayPnl` 在本地路径**恒为 0**（`:1919`），`todayChangePercent` 也**恒为 nil**（`:1984`）——今日数据完全由 `AppModel.holdingDailyChanges` 承担：

```swift
// LocalServices.swift:1644-1651  latestDailyChange
return (latest / previous - 1) * 100      // 最近两个交易日收盘价
```

批量入口 `dailyChanges(for:)`（`LocalServices.swift:1500-1524`）一次取 14 天收盘，`benchmarkDailyChange` 单独取 SPY（`APIClient.swift:654`）。

**今日归因（价格/汇率/交易）分三层：**

1. **价格贡献（首页「TODAY」）**，`PortfolioView.swift:601-618`：

```swift
let factor = 1 + change / 100
guard factor > 0 else { return nil }
amount = holding.marketValue - holding.marketValue / factor
```

   —— 等价于 `MV - MV₋₁`，隐含假设「今日无交易」。总百分比 `:625-631`：

```swift
previousValue = currentValue - totalAmount
totalPercent  = totalAmount / previousValue * 100
```

   对比基准（`:768-775`）：`difference = totalPercent - benchmarkChange`，显示为 `±SPY x.xx%`。

2. **汇率贡献**：`Holding.fxPnl`（`Models.swift:142-145`）。三级来源（`LocalPortfolioStore.swift:1932-1969`）：券商原币 FX 分项 → 券商总 P&L 减去价格 P&L 的**残差**（`broker_total_pnl_residual`）→ 用 ECB 日频汇率在**成交日**重建（`FXImpactCalculator.impact`，`ecb_daily_on_trade_dates`）。`fxPnlPercent = fxPnl / costUSD * 100`（`:1990`）。

3. **交易/行业归因**：`TodayDetailView` 与 `SectorAttribution.split`（`TodayDetailView.swift:118-177`）。

**口径不一致（技术债）**：同一公式在两处维护——`PortfolioView.swift:601-618` 用 `guard factor > 0`（跌幅 ≤ -100% 丢弃），`TodayDetailView.swift:26-39` 用 `let previous = MV/(1+change/100); guard amount.isFinite`（跌幅 < -100% 会显示经济含义错误的正值）。

### 2.3 货币换算口径

```swift
// LocalPortfolioStore.swift:1868-1881
static func usd(_ amount: Double, currency: String) throws -> Double { amount * rate }
static func usdRate(for currency: String) -> Double? {
    if code == "USD" { return 1 }
    if code == "GBX" { return usdRate(for: "GBP").map { $0 / 100 } }
    return LocalCurrentFXCache.shared.record(code)?.rate ?? usdRates[code]   // ← 静态兜底表
}
```

`usdRates` 是**硬编码离线汇率表**（`:1854-1866`：GBP 1.346 / EUR 1.163 / HKD 0.1275 …），`LocalCurrentFXRefresh`（`:1824-1846`）每 30 分钟刷新一次（`timeIntervalSince(lastAttempt) > 1800`），拉 `{CUR}USD=X` 近 10 天收盘。**实时与离线汇率混用无任何提示**（`fxStatus`（`:1883-1888`）只说明「缺失币种使用离线估值」）。

### 2.4 排序、搜索、账户切换

- 排序字段 4 个：`marketValue / unrealized / unrealizedPercent / name`（`PortfolioView.swift:2436-2461`），持久化在 `@AppStorage("portfolio.holdings.sortField")`（`:1959-1960`）。比较器处理 NaN：有限值优先，两者相等按 ticker 二级排序（`:2220-2252`）。
- 「今日 / 持有期」切换改变列表展示口径（`:2865-2884`）：今日用 `MV - MV/(1+r)`，持有期用 `unrealized / unrealizedPercent`。
- 账户切换：`model.selectedAccountKeys`，`CostMarketCard` 用 `.id(model.selectedAccountKeys.sorted())` 强制重建 hero（`:338`），`resolvedAccountKeys` 落在 `APIClient.swift:1561-1566`。

---

## 3. 收益页

### 3.1 三种模式的实现位置

`ReturnsChartMode`（`ReturnsView.swift:385-399`）：`twr / mwr / cashFlowMatched`，默认 `.twr`（`:265-270`）。三种模式共用一份 `ReturnsPreparedData`（`ReturnsView.swift:1303-1408`），**全部本地计算**。

### 3.2 TWR：`DailyTimeWeightedReturn.calculate`（`DailyTimeWeightedReturn.swift:67-173`）

**不是 Modified Dietz；是「日初入金 / 日末出金」的每日几何链式**：

```swift
// :158-162
let capital = previous + inflow
if capital > 0 {
    let growth = (value + outflow) / capital
    nav *= growth
    started = true
}
```

含义：`r_t = (V_t + outflow_t − V_{t−1} − inflow_t) / (V_{t−1} + inflow_t)`，`nav₀ = 1`，只有 `capital > 0` 之后才记录点（`:167`），否则抛「缺少期初资金，无法确定收益分母」（`:164`）。

关键规则：
- 现金流只认 `external`（`DEPOSIT`/`WITHDRAWAL`，`LocalServices.swift:2463`），股息/费用/交易是内部（文件头注释 `:3-4`）。
- 内部转账配对：同 `transferID` 多腿、跨账户、各币种净额必须为 0，否则抛错（`:104-116`）。
- 日估值 = 所有账户现金（负现金直接抛错，`:144`）+ Σ 股数 × 当日收盘（`:149-157`）。
- 缺价、缺汇率、重复流水、流水日无估值一律抛错（`:69-74`、`:87-88`、`:152-154`）。
- 拆股在日循环**开头**调整持仓数量（`:92-99`）。
- 收盘价含 **4 天（假设重建 21 天）carry-forward** 容忍休市（`LocalServices.swift:2588-2592`）。

### 3.3 MWR：`MoneyWeightedReturnCalculator`（`Models.swift:364-489`）

**区间收益率（date-aware period return），非年化 XIRR**（文件注释 `:365`）。

```swift
// :386-388  符号约定：入金为正 cashFlow → 事件取负
if cashFlow.isFinite, abs(cashFlow) > 0.000_001 { events.append((date, -cashFlow)) }
// :413
let flows = events + [(terminalDate, terminalValue)]
// :418-427  NPV 在 log-growth 空间，按时间比例折现
let fraction = max(0, flow.date.timeIntervalSince(startDate) / duration)
let discount = exp(-fraction * logGrowth)
value += flow.amount * discount
derivative -= fraction * flow.amount * discount
```

求解：**牛顿法 + 扫描 + 二分兜底**。初值 `logGrowth = log(1.1)`，≤32 次，收敛阈值 `abs(NPV) ≤ scale * 1e-10`，步长限幅 `logGrowth ∈ [-20, 20]`（`:431-446`）；失败则 `stride(-20...20, by: 0.25)` 找变号区间，取最接近 0 的括号（`:450-469`），二分 ≤80 次（`:472-485`）。返回 `rate = exp(logGrowth) - 1`，非有限则 nil。

区间取法（`Models.swift:530-551`）：`startIndex > 0` 时把**期初估值本身**作为第一笔现金流（`flows[0] = opening`），注释 `:541` 说明「期初估值已含当日流水」。

### 3.4 基准对比

```swift
// Models.swift:578
static let defaults = ["SPY", "QQQ", "VTI", "VOO", "DIA", "IWM", "VEU", "GLD"]
static let maximumCount = 12      // :580
static let preferenceKey = "returns.comparisonBenchmarks"   // :584
```

用户可增删、可搜索添加任意标的（`ReturnsBenchmarkPicker`，`ReturnsView.swift:1760-1895`）。**基准序列有两条独立口径**：

1. **现金流镜像（默认）**：把账户的真实外部现金流按同日收盘价买入基准单位（`AccountMWRLedger.mirror`，`Models.swift:556-570`）：

```swift
units += cashFlows[index] / price
guard units >= -1e-10 else { valid = false; return nil }   // 基准付不起出金 → 标为不可用
return max(0, units) * price
```

   收益率 `(value + withdrawn)/deposited - 1`（`Models.swift:521`）。

2. **TWR 口径（指数化）**：`$0 / base`（`LocalServices.swift:2708`）。组合用原始收盘价 + 显式股息流水；基准用 **adjclose 总收益价**（`LocalServices.swift:3049-3051`）——**两者口径不对称**，是潜在偏差来源。

### 3.5 时间范围切换

`ChartTimeRange`（`DesignSystem.swift:1801-1824`）共 10 档：`1D / 1W / 1M / 2M / YTD / 6M / 1Y / 2Y / 5Y / MAX`，选择器 5 个槽位、点击已选槽位切到同槽下一档（`:1816-1823`）。**没有 3M**（启动参数 `--show-returns-3m` 实际映射到 `.twoMonths`，`ReturnsView.swift:276-277`）。区间映射 `includes(_:through:previousTradingDate:)`（`DesignSystem.swift:1826-1856`），`1D` 用 `previousTradingDate`。

切换只做**本地过滤 + 重基准**，不触发网络：`rebuildDisplayData`（`ReturnsView.swift:1032-1039`）。TWR 每个区间**重新链式归零**（`:1507-1519`）：

```swift
let firstNAV = 1 + first / 100
value: (1 + point.value / 100) / firstNAV - 1
```

MWR 每个区间**独立解一次 XIRR**（`ReturnsView.swift:1443-1460` → `ledger.returns(startIndex: max(0, first - 1))`）。

### 3.6 收益分析子页（`ReturnsAnalyticsView` + `LocalReturnsAnalytics`）

两部件**并行取数 + 分步发布**（`LocalReturnsAnalytics.swift:187-231`，`withTimeout` 35 秒，`:245-266`）：

- **回撤卡**：口径是「当前权重 Top35 的**模型组合**五年 NAV」，不是真实账户回撤（`LocalReturnsAnalytics.swift:270-376`）。权重按 symbol 分组合并（`:309-313`），组内按市值加权日收益（`:334-338`），
```swift
nav *= 1 + dailyReturn; peak = max(peak, nav); value = peak > 0 ? nav / peak - 1 : 0   // :363-365
```
  只用所有组的**共同交易日**（`:346`），缺行情持仓会写进 warning（`:370-374`）。
- **估值矩阵**：FMP API（需 Keychain Key，`:436-439`），P/E 优先 forward 再 trailing（`:470-477`），成长优先 EPS 同比再营收同比（`:480-492`），`growth = abs(raw) <= 2 ? raw * 100 : raw`（`:493`）；缓存 TTL 12 小时（`:26`）。**口径 bug：分母 `totalMarketValue` 是全币种市值（`:379-384`），分子却只收 USD 成本币种持仓（`:388`）**——非 USD 持仓会系统性压低所有气泡权重。

---

## 4. 历史页

### 4.1 结构：全量流水 + 分类横向翻页

`HistoryView.body`（`HistoryView.swift:226-241`）→ `HistoryPagingView`（`HistoryPagingView.swift:6`）承载 5 个 `HistoryCategory`：`All / Orders / Dividends / Interest / Fees`（`HistoryView.swift:10-16`）。

**必须纠正一处命名误解：`HistoryPagingView` 不是记录级分页器**，它是一个 `UIScrollView`（`isPagingEnabled = true`，`HistoryPagingView.swift:85`）做的**分类横向翻页**。**没有 page size、游标、增量加载、无限滚动**。性能策略是「一次性全量取回 + SwiftUI `List` 自身懒加载 + 相邻页 80ms 依次预热」（`:112`、`:197-202`）。唯一的分页状态机是「占位 `Color.clear` → `livePages` 唤醒」（`:216-222`）。

数据源：`model.activityLedger()`（`APIClient.swift:759-781`），载荷 `PortfolioActivityLedger{accounts, transactions, securityNames}`（`HistoryView.swift:4-8`）——**交易流水，不是每日快照**。排序：日期倒序、同日 id 倒序（`HistoryView.swift:1360-1363`）。

### 4.2 已实现盈亏：FIFO（确实实现）

`HistoryView.swift:1325-1330` 确实调用 `RealisedProfitCalculator`：

```swift
result.realisedTotal = RealisedProfitCalculator.summarize(transactions: transactions)
for basis in TaxYearBasis.allCases {
    result.realisedByTaxYear[basis] = RealisedProfitCalculator
        .summarize(transactions: transactions, basis: basis)
        .filter { $0.summary.saleCount > 0 }
}
```

算法（`RealisedProfitCalculator.swift:163-241`）是 **FIFO 逐批消耗**，不是平均成本：

```swift
while remaining > 0.000_000_1, !lots.isEmpty {
    let matched = min(remaining, lots[0].quantity)
    matchedCostUSD += lots[0].costPerShareUSD * matched
    remaining -= matched
    lots[0].quantity -= matched
    if lots[0].quantity <= 0.000_000_1 { lots.removeFirst() }
}
...
let profit = price * rate * saleQuantity - matchedCostUSD     // :232
```

两条关键口径：
- **券商 Result 与本地估算严格分列**（文件头 `:3-9`、`:137-147`）：券商的按原币存 `brokerTotals`，本地估算进 `estimatedUSD`，`combinedUSD = brokerUSD + estimatedUSD`（`:34`）并注明「按今日汇率折算，属近似」。
- 只有**全部份额都匹配到导入买入**才估算，否则记 `unavailable`（`:227-231`），避免「部分成本」高估利润。

另一真实调用方是个股详情页：`HoldingDetailRealisedProfitRequest.summary()`（`:266-285`）由 `VolumeProfileView.swift:303-307` 调用。

### 4.3 现金活动分类与**被过滤的出入口**

`PortfolioActivityKind.init(action:)`（`HistoryView.swift:53-77`）按字符串归一化匹配：`DIVIDEND`/`INTEREST`/`BUY, BUY_BACK`/`SELL, SELL_SHORT`/`DEPOSIT, CASH_DEPOSIT, FUNDING, TRANSFER_IN`/`WITHDRAW*, TRANSFER_OUT`/`TRANSFER|CURRENCY_EXCHANGE`。

**关键发现：deposit / withdrawal / transfer 被整体剔除，永远不会出现在历史页**：

```swift
return activity.kind.isCashTransfer ? nil : activity      // HistoryView.swift:1319
```

`isCashTransfer = deposit || withdrawal || transfer`（`:105-107`）。枚举里为它们准备的标题与图标（`:83-100`）是**不可达分支**。同时 `FEE`/`TAX` 没有独立 kind，落进 `.other`（显示「Account activity」），只在 All 页出现；而 `HistoryCategory.fees.includes` 恒为 `false`（`:37`），所以 Fees 页**不接受任何流水行**，而是另一套「基金年费运行率」估算（`:1396-1403`，`annual = marketValue * rate`，页脚阴确声明「不是已扣除的金额…不要再从收益里减一次」，`:436`）。

### 4.4 费用

`LocalTransactionRecord`（`LocalPortfolioStore.swift:407-427`）**没有 commission/fee 字段**。CSV 导入只在判断 Total 是否已含费时读 fee/tax/commission 列，且刻意不猜（`LocalPortfolioStore.swift:2377-2392` 注释原文：「do not guess whether a fee column was already included in Total」）。结论：**手续费既不计入成本、也不计入已实现盈亏**（`:232` 的利润式无费用项），两种情况都无法还原真实手续费。

### 4.5 拆股

`StockSplitCatalog`（`StockSplitCatalog.swift`）读 `Resources/stock_splits.json`（18330 个 ticker）：`factor = to / from`（`:21-25`），`adjustment(ticker:from:)` 只累乘**买入日之后**的拆股（`:48-62`）。调整方式为**数量 × factor、价格 ÷ factor**（保持 `quantity × price` 不变）：

```swift
// RealisedProfitCalculator.swift:181-185（UKShareMatching.swift:96-98、UKSection104Pool.swift:120-123 重复同一段）
let split = catalog?.adjustment(ticker: transaction.ticker, from: transaction.date) ?? 1
let quantity = abs(transaction.quantity) * split
let price = split > 0 ? transaction.price / split : transaction.price
```

**历史页只在英国配对注释里用拆股（`HistoryView.swift:1332-1336`），列表行显示的股数与成交价不做调整**（`activityRow` 直接用 `transaction.quantity/price`，`:727-740`）。

### 4.6 英国税规则（分状态回答，这是本报告最需要精确的一节）

| 能力 | 状态 | 证据 |
|---|---|---|
| same-day + 30 天 + 池余量**匹配** | ✅ 实现并接线（仅作行内注释） | `UKShareMatching.swift:118-140`；`HistoryView.swift:760-786` |
| 30 天窗口 = 30 个 UTC 日历日 | ✅ | `UKShareMatching.swift:24`、`:68-73` |
| 英国税年 4/6–4/5 归属 | ✅ | `RealisedProfitCalculator.swift:85-88` |
| Section 104 池成本（英镑、均价分摊） | ⚠️ **实现但零调用方**（仅 XCTest 引用） | `UKSection104Pool.swift:94-224`；全项目 grep 唯一命中是定义行 `:20` + `CatfolioIOSTests/UKSection104PoolTests.swift` |
| CGT 税率 / 年度免税额 / 亏损结转 | ❌ **未实现** | 仅否定式注释 `UKSection104Pool.swift:18` |
| 印花税 stamp duty | ❌ **未实现**（0 命中） | — |
| 独立税务计算页面 | ❌ 入口被禁用 | `ReturnsView.swift:63-65`「税务计算」`.disabled(true)` |

匹配规则逐字：

```swift
for index in sales.indices { consume(index, sameDay: true) }    // UKShareMatching.swift:132
for index in sales.indices { consume(index, sameDay: false) }   // :133
let eligible = sameDay ? date == sales[sale].date
    : date > sales[sale].date && date <= windowEnd              // :122-123
```

代码自己声明了边界，且与事实一致（`UKShareMatching.swift:17-20`、`UKSection104Pool.swift:17-19`：「It does not compute tax: no rates, no annual exemption, no brought-forward losses.」）。

---

## 5. 回撤 / 水下、损失、贡献度

### 5.1 两条互不相同的「回撤」

1. **`ReturnsChartDestination.drawdown`** = `LocalReturnsAnalytics.drawdown`（`:270-376`），**当前权重 Top35 模型组合**的 5 年 NAV（见 3.6）。
2. **`ReturnsChartDestination.underwater`** = `UnderwaterAnalysisChart`，用 `model.fixedShareHistory`（固定今日股数回推，`LocalServices.swift:1268-1309`），**不是** `holdingValueHistory`（后者让新仓按买入日进入，会把买入读成上涨）。

### 5.2 水下分析（`UnderwaterAnalysis.swift`）

```swift
// :20-29  窗口内 running high-water mark
if value >= peak { peak = value; peakText = dates[index].text }
points.append(Point(dateText:..., value: value, peak: peak, peakDateText: peakText))

// :15
var drawdown: Double { peak > 0 ? value / peak - 1 : 0 }
```

- 最大回撤 = `min(0, trough.drawdown)`，trough 取最深、相等取更早（`:32-36`）。
- 恢复点 = 最深点之后首次 `value >= trough.peak`（`:40-43`）。
- 回补所需涨幅 = `1/(1+dd) - 1`（`:73-75`，-20% → +25%，有测试锚定）。
- `daysUnderwater`（`:47-51`）、`longestUnderwaterDays`（`:55-69`）。
- 归因分解（`:149-156`）：`part_i(t) = (V_i(t) − V_i(peak)) / V_total(peak)`，单位是**高点的百分比份额**，不是金额。

**⚠️ 疑似笔误（口径不一致）**：`UnderwaterAnalysisChart.swift:403-404` 的 `domain: (bottom * 100)...0` 配 `yTicks: [0, bottom * 50, bottom * 100]`，而序列值已 `×100` 为百分点、`bottom` 仍是小数——刻度比坐标范围大两个数量级。对比 `LossAnalysisChart.swift:162`、`HoldingContributionChart.swift:175` 都自洽，可确认为本文件笔误。

### 5.3 损失分析（`LossAnalysisChart.swift`）

- 按持仓聚合、按**期内最深亏损**排序（`:347-360`）：`deepestLoss[ticker] = max(deepestLoss, max(0, -row.gain(ticker)))`。
- 每日每层高度只取亏损侧（`:378-385`）：`max(0, -row.gain(ticker))`，盈利记 0。
- **没有胜率、盈亏比、平均亏损、HHI**（全项目 grep 零命中）；`losingCount`/`netGain` 仅展示。最接近的集中度控制是复用贡献图的「≤6 只 / 6%」阈值（`:358-360` 调用 `HoldingContributionStack.namedCount`）。

### 5.4 贡献度（`HoldingContributionChart.swift`）

**不是权重 × 收益率，而是绝对金额（value − cost）**：

```swift
// LocalServices.swift:1008-1015
result[ticker] = value - (last.costs[ticker] ?? costs[ticker] ?? value)
```

堆叠口径（`HoldingContributionChart.swift:447-459`）：

```swift
let namedGains = named.reversed().map { max(0, row.gain($0)) }
let remainder = row.total - row.cost - namedGains.reduce(0, +)
let othersGain = others.reduce(0) { $0 + row.gain($1) }
Row(..., principal: row.cost, othersGain: othersGain,
    bands: [row.cost + min(0, remainder), max(0, remainder)] + namedGains)
```

**明确的非 Brinson**：无配置效应/选择效应/交互项分解。截断规则：按盈利降序，**首只无条件入选**，之后要求 `gain/total >= 0.06`，上限 6（`:386-410`）。

**⚠️ 口径依赖风险**：`principal: row.cost` 取自 `HoldingValueHistory.Row.cost`，而该字段实际是**累计净存入**（`LocalServices.swift:1242-1246`），注释却称之为「买入成本」——对个人组合成立，多账户/有卖出时会偏离真实成本基础。

---

## 6. ETF 穿透

### 6.1 视图：活的是 `PortfolioView.etfTable`，`ETFLookThroughView.swift` 是死代码

- **`ETFLookThroughView.swift`（214 行）零调用方**（全项目 grep 唯一命中是自身声明行 `:3`）。
- 活的实现：`PortfolioView.swift:1944-1945` 的 `tableMode == "ETF 穿透"` → `etfTable :2266-2327` → `loadETF() :2379-2404` → `APIClient.loadETFLookThrough :714` → **真算法在 `LocalServices.swift:4694-4877` 的 `LocalETFLookThrough.make(document:basis:)`**。
- 视图固定 `.market`；**成本口径 `.cost` 只有死掉的 `ETFLookThroughView` 才暴露**（`ETFLookThroughView.swift:8,31-39`）。

### 6.2 直接 + 间接合并算法

```swift
// LocalServices.swift:4752 直接持仓 = 不在受支持 ETF 名单里的持仓
let directPositions = document.positions.filter { !supported.contains($0.ticker.uppercased()) }
// :4778 间接 = 基金暴露 × 成分权重
let amount = exposure.amount * weight / 100
// :4792 同一 ticker 跨多个 ETF 累加
current.fromETFUSD += amount
// :4820 合并
totalUSD: directUSD + exposure.fromETFUSD
```

**同一标的既直接持有又通过多个 ETF 间接持有的情况已被正确处理**：`aggregated` 以 ticker 为键累加（`:4787-4800`），合并时 `direct.removeValue(forKey: ticker)`（`:4810`）取出直接部分相加，**不做去重、不做归一化、无双重计算折扣**（这是正确的：经济暴露就是两部分之和）。

### 6.3 成本与市值两种口径

```swift
// :4719-4726
case .market: try usd(position.shares * position.quotePrice, currency: position.quoteCurrency)
case .cost:   try usd(position.shares * position.averageCost,  currency: position.currency)
// :4727-4732 直接持仓恒为市值
```

间接成本 = 基金成本 × 基金内权重（`:4797`），注释 `:4793-4795` 自认「allocates fund P/L; it is not a constituent's historical price return」。

**两个不同的权重基数**（口径不一致）：
- `etfWeightPercent = fromETFUSD / etfTotal * 100`（`:4821`，基数 = ETF 总市值 `:4751`）
- UI 的 `portfolioWeight = totalUSD / etfPortfolioTotal`（`PortfolioView.swift:2364-2366`、`:2774`，基数 = 穿透后全部行合计）

未穿透残差显式处理：`CASH`/`ETF 其他` 直接进 other（`:4780-4786`）、`unallocatedWeight = max(0, 100 - allocatedWeight)`（`:4802-4806`）、合成 `ETF 其他` 行「基金现金、衍生品及未识别部分」（`:4829-4836`）、`coveredWeightPercent = max(0, 100 - otherWeight)`（`:4869`）。

### 6.4 静态快照来源

`Bundle.main.url(forResource:withExtension:)` + `Data(contentsOf:)`（`LocalServices.swift:4712-4716`），`static let` 惰性全局缓存（`:4658-4692` 的 `additionalDatasets`），`schemaVersion` 必须为 1。数据结构 `Dataset :4625-4637` / `Constituent :4639-4649`。

`Resources/etf_holdings.json` 实测：**77 只基金，`as_of` 为 2026-09-03/04**；`Resources/ETF/sp500_holdings.json` 为 2026-06-30、`eqqq_holdings.json` 为 2026-08-27。**快照日期字段存在并被拼成 `holdingsAsOf`（`:4853-4855`）——但活着的 `PortfolioView` 不展示它，只有死掉的 `ETFLookThroughView.swift:53-55` 显示**，用户对时效性不可见，且 `etf_holdings` **没有 TTL / 过期判断**（轮动数据有 `isExpired`，穿透没有）。

### 6.5 `SectorAttribution`：不是 Brinson

全项目 grep `brinson|allocation effect|selection effect|配置效应|选择效应` **0 命中**。它只是把金额按行业权重分摊：

```swift
// SectorAttribution.swift:108-118
if let fund = fundComposition(for: symbol) { return fund }         // 基金 → 指数成分权重
if let entry = catalog.entry(brokerSymbol: symbol),
   let sector = PortfolioSector(sourceName: entry.sector) {
    return SectorSplit(weights: [sector: 1], isLookThrough: false)  // 个股 → 满权重
}
return .unclassified                                                // 未覆盖 → 显式未分类
```

`weights` 之和 ≤ 1，余数为 `unclassifiedFraction`（`:87-96`）；无基准、无效用分解。基金行业权重来自 `Resources/etf_sector_composition.json`（6 个指数 / 76 个 alias，`SectorAttribution.swift:175-196`）；公司行业来自 `company_reference.json`（**21794 条中仅 8120 条有 sector，37.3%**）。

**两个 ETF 宇宙不一致（最严重的结构性风险）**：`etf_sector_composition.json` 只有 76 个 alias，而穿透支持的 ticker 远多于它——**绝大多数能穿透的成分股拿不到行业权重**，反向也有 59 个「有行业权重但不能穿透」（QQQ/CSPX/VWCE/VT…）。

### 6.6 `FundFeeCatalog` 未进入任何收益/成本计算

`Resources/fund_fees.json`：7199 records / 13124 aliases，只有 `expenseRatio` 一个字段（无管理费/交易费/佣金），且 **96.8% 的 `expenseRatioAsOf` 为 null**。调用点仅三处：`HistoryView.swift:1396-1403`（名义 run-rate = `marketValue × rate`）、`VolumeProfileView.swift:1909-1914`（详情页 Expense Ratio 行）、`ReferenceCatalogs.swift:21`（预解码）。**`LocalETFLookThrough.make` 完全不引用它 → 穿透净值和行业归因都不扣费**，且旧包漏掉 QQQ/VTI/VT/ARKK/SCHD（`FundFeeCatalog.swift:5-11`）。

### 6.7 已知代理局限（代码注释原文）

- `SectorAttribution.swift:84-86`：「an approximation, because the fund's move was not uniform across its holdings」
- `SectorAttribution.swift:3-9`：FMP 与 GICS 两套行业词汇冲突，必须归一到一套
- `SectorAttribution.swift:100-107`：覆盖不全必须显式未分类，「a breakdown that quietly drops part of the portfolio is worse than none」
- `SectorAttribution.swift:191-192`：无指数映射就返回 nothing，不用邻近指数的权重
- `LocalServices.swift:4687`：「Exact fund snapshots take precedence over the historical index proxy」
- `LocalServices.swift:4678-4680`：XS2D 杠杆只分配一次，避免重复计入
- `SectorPerformance.swift:98, 243`：行业 ETF 作为美国板块代理，非盘中实时
- **没有任何注释承认 ETF 持仓快照会过期**。

---

## 7. 热力图 / treemap / 轮动

### 7.1 `HoldingsTreemapLayout`：真·squarified treemap

实现与声明一致（`HoldingsTreemapLayout.swift:4`、`:29-34`）。面积权重 = `marketValue`（调用方传入）；只接受**有限且 > 0** 的权重（`:38`），负权重丢弃。

防溢出缩放（先除以最大权重再求和，`:47-68`）：

```swift
let scaledTotal = weightedItems.reduce(into: 0.0) { $0 += entry.element.weight / largestWeight }
let fraction = (entry.element.weight / largestWeight) / scaledTotal
let area = totalArea * fraction
```

经典 worst-aspect-ratio 贪心（`:78-99`）：

```swift
if currentRow.isEmpty
    || candidateMetrics.worstAspectRatio(along: shortSide)
        <= currentMetrics.worstAspectRatio(along: shortSide) { 接受 } else { 封行 }
```

```swift
// :134-148
return max(sideSquared * largestArea / totalSquared,
           totalSquared / (sideSquared * smallestArea))
```

条带切分（`:194-263`）：宽 ≥ 高竖切，否则横切；条带厚度 `rowArea / 长边`，**最后一个 tile 吃掉剩余长度**以消除浮点缝隙（`:222-224`）。**布局内零 padding**，gutter 由调用方 inset（`HoldingsHeatmapTile.swift:161-164`、`HoldingsHeatmapView.swift:371-372`）。

⚠️ 注释过度承诺：`HoldingsTreemapLayout.swift:31-33` 称可选末项「anchored at the bottom-right corner」，排序确实把它排到最前（`:40-42`），但贪心可能把它并入第一行，**不保证落在右下角**。

### 7.2 `HoldingsHeatmapView` / `HoldingsHeatmapTile`

- 分组维度是**行业**，不是资产类别（`HoldingsHeatmapView.swift:168-176`、`:242-287`）。
- 颜色映射**没有插值色带，只有固定色 + 变透明度**（`HoldingsHeatmapTile.swift:352-364`）：

```swift
guard let change = model.changePercent, abs(change) >= 0.005 else { return .secondary }
let intensity = min(abs(change) / 3, 1)
let opacity = 0.12 + intensity * 0.22
return (change > 0 ? green500 : rose500).opacity(opacity)
```

  即阈值 |Δ| < 0.005%、满强度点 3%、透明度区间 [0.12, 0.34]。
- 涨跌幅口径：`.today` 用 `dailyChanges[ticker] ?? holding.todayChangePercent`；`.holdingPeriod` 用 `unrealizedPercent`（`:295-321`）。
- 裁剪：持仓模式最多 20 块（前 4 名无条件保留），ETF 穿透最多 28 块；行业模式另有一轮基于**实际布局尺寸**的二次合并（`HoldingsHeatmapView.swift:509-556`）。
- 文字**不做任何测量**，全靠尺寸阈值硬编码（ticker ≥ 40×22 等，`HoldingsHeatmapTile.swift:166-183`）。`showsTicker` 与 `canShowIdentifier` 阈值不一致（`:151-153` vs `:166`）导致窄高条出现「有 logo 无 ticker」分支。

### 7.3 `PerformanceHeatmapHero`

**不是时间 × 持仓的二维矩阵**（`PerformanceHeatmapHero.swift:24-36`、`:165-231`）——它是把热力图渲染成纹理、贴在等距平面上的动画容器。渲染键 `heatmapRenderKey`（`PortfolioView.swift:2039-2058`）变化才重新烘焙（延迟 100ms，`:104-119`）；`isSnapshot == true` 时 `isInteractive = false`，不构造菜单与个股预览。

### 7.4 `IsometricHeatmapLab`：实验代码但**不是死代码**

文件头自认「An experiment」（`IsometricHeatmapLab.swift:3`），但该文件同时定义了生产组件依赖的公共类型 `IsometricBands`（`:229`）、`IsometricLayer`（`:345`）、`IsometricEdgeEffects`（`:357`）、`View.liveBlur`（`:392`），被 `PerformanceHeatmapHero.swift:61/249/327/368/382/394/406-407/468` 使用。**不能按名字把它当实验代码整体删除**。反向地，它自己有 release 可达入口（`SettingsView.swift:335-345`、`:369`）与**内置假数据 `sample`**（`:145-151`）——全项目唯一用假数据渲染真实 UI 的地方。

### 7.5 轮动图（RRG / 板块轮动）——Swift 端只有渲染

**(A) StockCharts RRG**：`jdkratio`/`jdkmom` 是**来源服务器返回的原值**，App 不算任何东西：

```swift
// StockChartsRotation.swift:12-19
var quadrant: String {
    jdkratio >= 100 ? (jdkmom >= 100 ? "leading" : "weakening")
                    : (jdkmom >= 100 ? "improving" : "lagging")
}
```

象限阈值就是 100 中线；尾迹取最后 30 周（`:67-70`）；坐标是纯线性缩放（`StockChartsRotationUIKit.swift:66-73`）。注释自认「Uses source coordinates on linear axes around 100. No MAD, tanh, or resampling」（`:14`）。取数用隐藏 `WKWebView` 注入 JS 钩住 `XMLHttpRequest`/`fetch`（`:170-199`），落盘并与打包资源 `Resources/stockcharts_rrg_reference.json` 取最新（`:109-114`）。

**(B) SectorRotation v2**：`x/y/relativeTrend/relativeMomentum/quadrant/trail` **全部由 JSON 提供**（`SectorRotation.swift:10-23`），Swift 侧只有参数硬校验（`:94-106`：`calcVersion == 2`、`benchmark == "SPY"`、`trendWindow == [63,21]`、`momentumWindow == [21,0]`、`smoothing == 5`）。**公式只以说明文字存在于 UI 文案里**（`SectorRotationView.swift:127-129`）：

```text
rawTrend    = mean( log(price_sector / price_SPY) )  over t-63 … t-21
rawMomentum = mean( log(price_sector / price_SPY) )  over t-21 … t
x = tanh( (rawTrend    − median(rawTrend    across 11 sectors)) / MAD )   ← 文档描述，Swift 未实现
y = tanh( (rawMomentum − median(rawMomentum across 11 sectors)) / MAD )
中心 ±0.25 为中性；新象限连续两交易日成立才切换标签
```

**UIKit 与 SwiftUI 不是重复实现，而是「SwiftUI 外壳 + UIKit 内核」**：`SectorRotationView`/`StockChartsRotationView` 管状态，真正的绘图与手势在 `SectorRotationUIKit.swift:91` / `StockChartsRotationUIKit.swift:15`。但存在跨功能耦合：`StockChartsRRGChart` 把 `SectorRotationChartView` 当氛围背景层（`StockChartsRotationUIKit.swift:19`、`:32-35`）。两条轮动线还用了**两种不同曲线插值**（`:141-145` 三次 vs `RotationTrailCurve.segments` 单调保形）。

`Resources/sector_rotation_history.json` 实测为 **60 个快照的数组**（2026-06-15 … 2026-09-09），最新 `validUntil` 为 2026-09-10T22:30Z。

---

## 8. 图表基建：`StandardLineChart`

### 8.1 公开 API

单一渲染器，**1 个 init（约 40 个具名参数，35 个有默认值）+ 4 个外围骨架组件**（`StandardLineChart.swift:412`、init `:472-562`、骨架 `:2204/2304/2341`、`chartLoadingShimmer :49-53`）。模型：`StandardLineChartPoint :68`、`StandardLineChartSeries :80-127`（构造时强制按日期排序 `:113`）、`Marker :228`、`ReferenceLine :329`、`AxisSide :354`、`DataTransition :359`、视口插值 `ViewportPath :267-318`。

消费者 9 处：`ReturnsView.swift:1116`、`PortfolioView.swift:1727`、`VolumeProfileView.swift:1487`、`ReturnsAnalyticsView.swift:227`、`IndustrySentimentView.swift:214`、`UnderwaterAnalysisChart.swift:400`、`LossAnalysisChart.swift:158`、`HoldingContributionChart.swift:171`、`CycleComparison.swift:383`。

### 8.2 渲染方式：纯 SwiftUI `Canvas` + `GraphicsContext`

`Canvas` 于 `:573`（网格）、`:582`（主 series）、`:2231`、`:2350`；所有绘制函数接收 `inout GraphicsContext`（`:976, 997, 1018, 1069, 1129, 1187, 1351, 1430, 1475, 1512, 1707, 1739, 1834`）；`Path()` 手工构建折线（`:1194`、`:1479`）、面积（`:1711`）、条纹（`:1745`）。**本文件无 `UIViewRepresentable`、无 `CGContext`**；唯一 UIKit 桥接是手势层（见 8.4）。

**性能策略（多数为「没有」）**：
- ❌ 无 `drawingGroup()`、无 `Canvas(rendersAsynchronously:)`（全项目 0 命中）→ **全部同步主线程绘制**。
- ❌ **无 LTTB / 无降采样**（全项目 grep 0 命中）。抽稀只存在于调用方的等距步进：`VolumeProfileView.swift:1665-1667`（固定 150 点）、`CycleComparison`（固定 96 步）；`ReturnsView:1116`、`PortfolioView:1727` 把原始序列直接交给渲染器，Path 顶点数无上限。
- ✅ 预计算缓存：`viewportPaths`/`morphPairs`（`:770-793`，注释 `:265-266`「Build correspondence once per update, not once per animation frame」）、`SecurityPricePreparedData` 一次预计算全部 10 个时间范围（`VolumeProfileView.swift:1559-1580`）、`LocalVolumeBarCache` 24h。
- ✅ 手写指纹 diff：`StandardLineChartRevision`（`:367-370`）对每条 series **每 8 个点抽 1 个** + 首尾（`:724-732`）——有意近似，但第 3、11、19… 点的单点变化在 `transitionKey` 不变时可能不刷新。
- ✅ 节流：触觉最小间隔 35ms（`DesignSystem.swift:1340`）、详情页 header 交互发布 1/30s（`VolumeProfileView.swift:1421-1425`）、shimmer 30fps（`:29`）。

### 8.3 坐标系与坐标轴

```swift
// StandardLineChart.swift:742-751
let leadingInset = yAxisSide == .leading ? axisWidth : 0
let trailingAxisInset = yAxisSide == .trailing ? axisWidth : 0
CGRect(x: leadingInset, y: topInset,
       width: max(1, size.width - leadingInset - trailingAxisInset - plotTrailingInset),
       height: max(1, size.height - bottomHeight - topInset))

// :2000-2006 / :2012-2019  domain→screen
let span = max(last.timeIntervalSince(first), 1)
startX + (endX - startX) * CGFloat(date.timeIntervalSince(first) / span)
plot.maxY - plot.height * CGFloat((value - valueDomain.lowerBound) / span)
```

- **Y 轴刻度由调用方传入（`yTicks: [Double]`），渲染器不做 nice numbers**（`:416, :476`）。全项目有 **8 处手写等分公式**（`VolumeProfileView:1491`、`ReturnsView:1120`、`PortfolioView:1734`、`IndustrySentimentView:220`、`LossAnalysisChart:162`、`UnderwaterAnalysisChart:404`、`HoldingContributionChart:175`、`CycleComparison:387`）；唯一的 nice-number 实现在 `CycleComparison.swift:124-136`，却只喂自绘标签。
- **X 轴只有首尾两个日期标签**（`:1897-1910`）。
- **无对数坐标**（全项目无 log-scale 分支）。默认 inset：`axisWidth 52`、`topInset 8`、`bottomHeight 24`、`leadingLineOverflow 16`、`trailingEndpointInset 9`（`:478-484`）。

### 8.4 手势

**没有 SwiftUI `DragGesture` / `MagnificationGesture`（捏合缩放全项目 0 命中）**。全部走 `ChartInteractionOverlay: UIViewRepresentable`（`DesignSystem.swift:1360-1582`）+ 自研 `UIGestureRecognizer` 子类 `ChartDetailGestureRecognizer`（`:1455-1581`）：

- **长按激活**（非拖动）：`DispatchQueue.main.asyncAfter(deadline: .now() + minimumPressDuration)` 手动置 `state = .began`（`:1541-1552`），`activationDuration = 0.23`。
- **手势冲突处理**：`allowableMovement = 10`，`touchesMoved` 一旦 `distance > allowableMovement` 立即 `cancelActivation(); state = .failed`，让位给外层 `ScrollView` 的垂直滚动（`:1507-1523`，注释 `:1408-1411`）。系统边缘（`window` 坐标 x < 20）直接失败让位给返回手势（`:1492-1497`）。
- **双指测距**：第二指加入时 `state = .changed` 不重启识别（`:1501-1504`）；`updateSelection`（`:1912-1920`）在 `dates.count >= 2` 时走 `onMeasure(ChartDateRange)`，否则 `onSelect`。
- **十字准线**：`selectionOverlay:1756-1780` → 玻璃竖线 + 每条 series 一个 `GlassSelectionPoint`（值取 `nearestPoint`），顶部日期气泡。
- **命中测试**：线性比例反解 `date(at:plot:) :1947-1957` → 二分 `nearestDate :1959-1972`。

### 8.5 动画

核心是 `StandardLineChartTransitionDriver: View, Animatable`（`:372-392`），`animatableData = progress`，**每次插值重跑 Canvas 绘制闭包**（而非对 layer 补间）：

```swift
// :1147
?? StandardLineChartViewportPath(from: outgoing.points, to: incoming.points).samples(progress: progress)
```

- 进场 `.timingCurve(0.22, 1, 0.36, 1, duration: 0.45)`（`:201`、`:798`）；揭示 `.linear(duration: 0.9)` + 手写 `easeOutQuart`（`:809-812`，注释 `:821-822` 解释为何不用三次贝塞尔近似）；标记缩放 smoothstep `t²(3-2t)`（`:1406-1409`）。
- **打断处理**：`transitionGeneration` + `await Task.yield()` 丢弃排队动画（`:774`、`:794-797`），注释 `:768-769` 说明从「最后一帧实际画出的形状」起步，避免快速点 range 跳 400ms。
- 拖动**不发布 SwiftUI 更新**：`StandardLineChartPresentationProgress` 是纯 class 而非 `Observable`（`:320-324`）。
- `reduceMotion` 全路径降级（`:19, 176, 189, 196-208, 450, 579, 712-717, 764, 817`）。

### 8.6 `#available(iOS 26)` 处理

全项目 `#available(iOS 26.0` **39 处**，`#unavailable` **0 处**。模式统一为「玻璃 / 材质」双实现，**零统一封装**：

| 位置 | 分支 |
|---|---|
| `StandardLineChart.swift:2030 / 2060 / 2093 / 2127` | `GlassGuide` / `GlassReferenceLine` / `GlassSelectionPoint` / `DateBubble`：`.glassEffect(.clear.tint(...))` vs `.ultraThinMaterial + 描边` |
| `VolumeProfileView.swift:3146 / 4362 / 4378 / 4391` | 52 周气泡 / `glassRule` / `tintedGlassPill` / `@available(iOS 26.0, *) func glass(tint:)` |
| `DesignSystem.swift:97 / 109` | `softTopScrollEdge()` → `scrollEdgeEffectStyle(.soft)` / `topEdgeEffect.style = .soft` |
| `DesignSystem.swift:1740 / 1754 / 2068` | `tabBarMinimizeBehavior(.onScrollDown)` / `GlassChoiceBar` / `.buttonStyle(.glassProminent)` |

风险：这些分支在 iOS 27/28 会持续命中（`RootTabView.swift:198` 注释已提到「iOS 26/27」），且没有能力探测回退。

---

## 9. 成交量分布（VAH / POC / VAL）

**计算不在 `VolumeProfileView.swift`，在 `LocalServices.swift:2188-2260` 的 `makeVolumeProfile`。**

- **数据来源：日线 OHLCV，不是分钟线。** `volumeProfile(ticker:currency:...)`（`LocalServices.swift:1653-1736`）窗口 `-370 天`，Provider 回退链：Massive `/v2/aggs/.../range/1/day/...`（`:2073-2124`）→ Yahoo `interval=1d`（`:2126-2186`）→ FMP（`:1710-1724`），`LocalVolumeBarCache` 24h（`:1025-1056`）。模型 `VolumeProfile` / `VolumeProfileBin` 见 `Models.swift:192-236`。

窗口与分桶：

```swift
// LocalServices.swift:2195-2196
let annualSessions = Array(bars.sorted { $0.date > $1.date }.prefix(252))
let sessions = Array(annualSessions.prefix(160))          // profile 只用最近 160 个交易日

// :2206-2210
let minimum = sessions.map { $0.low  * scale }.min() ?? 0
let maximum = sessions.map { $0.high * scale }.max() ?? 0
let binCount = 36
let width = (maximum - minimum) / Double(binCount)
```

**成交量归属：按典型价全额记入单一桶，不做 high-low 均摊**：

```swift
// :2212-2216
for bar in sessions where bar.volume > 0 {
    let typical = (bar.high + bar.low + bar.close) / 3 * scale
    let index = min(binCount - 1, max(0, Int((typical - minimum) / width)))
    bins[index] += bar.volume
}
```

**POC = 最大桶的中点；Value area = 70% 硬编码；VAH/VAL 用逐桶贪心扩张**：

```swift
// :2217
guard let pocIndex = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[pocIndex] > 0
// :2220
let target = bins.reduce(0, +) * 0.70
// :2221-2234
var lowIndex = pocIndex, highIndex = pocIndex
var covered = bins[pocIndex]
while covered < target, lowIndex > 0 || highIndex < binCount - 1 {
    let lower = lowIndex > 0 ? bins[lowIndex - 1] : -1
    let upper = highIndex < binCount - 1 ? bins[highIndex + 1] : -1
    if upper >= lower { highIndex += 1; covered += bins[highIndex] }
    else              { lowIndex  -= 1; covered += bins[lowIndex]  }
}
// :2235 / :2240-2242
func midpoint(_ index: Int) -> Double { minimum + (Double(index) + 0.5) * width }
valueAreaHigh: midpoint(highIndex); pointOfControl: midpoint(pocIndex); valueAreaLow: midpoint(lowIndex)
```

**与标准口径的两处差异**：(1) Steidlmayer 经典做法是一次判定上/下「一对」桶后整体纳入，这里是**逐桶择大者**，并列时固定取上侧；(2) 若两侧同时耗尽仍未达 70%，循环退出，**实际覆盖可能 < 70% 且无警告**。另外 `valueAreaPercent` 字段（`Models.swift:200`）解码后**从未被读取**，70% 在展示文案里另写一遍（`VolumeProfileView.swift:3628`）。

**拖动交互**：`ChartPointInteractionOverlay`（`VolumeProfileView.swift:3951-3958`）只把 `location.y` 线性反解成价格写入 `selectedPrice`；**profile 不重算、不平移**，无命中测试（不判断落在哪个桶），无防抖（只有 `guard price != selectedPrice` 等值短路，`:3663-3671`）。标签让位靠 `ruleSegments:3987-4003` 把规则线在标签处切成多段；读数 pill 按 `touchX > size.width/2` 换边（`:3934`）。

**展示层与计算层口径混用**：VAH/VAL/POC 用**桶中点**（`:2235`），而前端「实际 profile 区间」用**桶边界**（`:3551-3552`），导致 VAH 标签压在 silhouette 内部而非边缘。

---

## 10. `PortfolioPresentationCache` 与首页冷启动

`PortfolioPresentationCache`（`PortfolioPresentationCache.swift:19`）是 `actor`，落盘到 `Application Support/Catfolio/HomePresentation/{personal|examples}/{digest}.plist`（`:45-62`），`isExcludedFromBackup = true`（`:102-104`），最多保留 12 个文件（`:112-119`），二进制 plist 以保留 NaN（注释 `:105-106`）。

**失效条件（version 2 的 `ledgerDigest`，`:67-76`）**：

```swift
var identity = document
identity.updatedAt = .distantPast            // 更新时间不参与
identity.marketDataUpdatedAt = nil           // 行情时间不参与
if document.isSynthetic != true && !document.isPublicDisclosure {
    identity.snapshots = []                  // 每日快照不参与
    identity.positions = document.positions.map { $0.withQuotePrice(0, observedAt: .distantPast) }
}                                            // 报价价格与观测时间不参与
return try digest(identity)
```

注释 `:64-66` 说得直白：「行情刷新也会改文档时间戳和每日快照，但它们不该让一份本来就相同的账本失去上次的显示。**交易、数量、成本、币种、账户身份会**。」

其他守卫：
- `hasUsableChart` 要求 `currentPoint.marketValue/cost` 有限（`:14-16`），否则不写也不读（`:86`、`:98`）。
- 缓存键含 `source / accountKeys / language`（`:23-37`），账户切换或语言切换各占一个文件。
- `version 1` 用全文档 digest，`version 2` 用 ledgerDigest；未知版本直接返回 nil（`:88-92`）。
- 恢复时的时序见 1.5（`APIClient.swift:1506-1525`）。

**收益页另有一套缓存**：`ComparisonSnapshotCache`（`LocalServices.swift:4885`），按 `mode|accountKeys` 分 scope（`APIClient.swift:339-342`），**指纹相同则直接用、不重建**（`:275-280`，注释解释「重建要抓每个持仓的历史，长账户可能几分钟」）。

---

## 11. 结构性风险与技术债

1. **实验代码与生产公共类型同文件耦合**。`IsometricHeatmapLab.swift` 既含 release 可达的实验页（`SettingsView.swift:342`），又定义了生产 hero 依赖的 4 个类型。按文件名清理会直接编译失败。
2. **页面/视图死代码**：`ETFLookThroughView.swift`（214 行）零调用方；`UKSection104Pool.swift`（225 行）零调用方（仅 XCTest）；`SectorPerformanceDefinition.definition(for:)` 零调用方；`currentWeightModelSeries`（`LocalServices.swift:2804`）、`ComparisonPoint`（`Models.swift:644`）、`returnsWarning`（`APIClient.swift:43`）、`selectDrawableModeIfNeeded`（`ReturnsView.swift:362-382` 全分支 `break`）、`forwardPE`（`LocalReturnsAnalytics.swift:596` 恒 nil）、`VolumeProfile.available/valueAreaPercent`、`ETFLookThroughResponse.otherWeightPercent`、`Dataset.benchmark`、`holdingsAsOf` 等字段均为死字段。
3. **不可达枚举分支**：`PortfolioActivityKind.deposit/withdrawal/transfer` 的标题与图标（`HistoryView.swift:84-99`）永远用不到，因为 `:1319` 已把它们过滤；`HistoryCategory.fees.includes` 恒 false（`:37`），语义与页面未对齐。
4. **命名误导**：`HistoryPagingView` 不含任何记录级分页；`PortfolioHomeScrollBridge` 不是系统 refreshable；`volumeProfile` 是日线而非分时分布。
5. **口径不一致（会直接产生错误数字）**：
   - `UnderwaterAnalysisChart.swift:403-404` 的 yTicks 与 domain 差两个数量级。
   - `HoldingContributionChart` 把「累计净存入」当「买入成本」（`LocalServices.swift:1242-1246`）。
   - `LocalReturnsAnalytics.swift:379-388` 估值矩阵分母用全币种、分子只用 USD 持仓。
   - 组合收益（原始收盘 + 显式股息）与基准收益（adjclose 总收益）口径不对称。
   - ETF 穿透的 `etfWeightPercent`（基数 = ETF 总市值）与 UI `portfolioWeight`（基数 = 穿透后合计）两个基数混用。
   - 今日盈亏公式在 `PortfolioView.swift:601-618` 与 `TodayDetailView.swift:26-39` 各写一遍，守卫条件已出现分歧。
6. **重复实现**：玻璃/材质双分支 39 处零封装；Y 轴刻度 8 份手写等分；骨架/占位 5 套；热力图 tile 渲染与颜色映射两套（`HoldingsHeatmapTile.swift:352-364` vs `IsometricHeatmapLab.swift:159-173`）；矩形平面两套（每帧实时模糊 `liveBlur` vs 预烘焙纹理）；两条轮动线两种曲线插值。
7. **性能隐患**：
   - StandardLineChart 全部同步主线程绘制，过渡期每帧重跑 `drawMorphedBase` 并逐点构 `Path`；无 `drawingGroup`、无异步 Canvas、无 LTTB。
   - `HoldingsHeatmapView` 固定 700pt 高 + 每次布局跑 4 次 treemap，`while true` 可能反复重排（`:533-555`）。
   - `PerformanceHeatmapHero` 每次 renderKey 变化延迟 100ms **整屏重新烘焙纹理**，平面上同时绘制 15 份图像 + 5 层预模糊，`TimelineView` 30fps 驱动，内存驻留多张全宽位图。
   - `VolumeDistributionPlot` 的 bins filter/sort、`continuousSlices`、7 点卷积平滑、单调斜率都在 **Canvas 闭包内部逐帧重算**（`:3702-3742`、`:3806`、`:4244-4282`），未缓存到 `@State`。
   - `FiftyTwoWeekRange.markerIndex(at:)` 在 45 个刻度上做 `min(by:)` 线性扫描，每次触摸移动都调用（`:3172-3246`）。
8. **数据时效性不可见**：ETF 持仓快照有 `as_of` 但活 UI 不展示、无 TTL/过期判断（轮动数据有 `isExpired`）；`FundFeeCatalog` 96.8% 的记录缺 `expenseRatioAsOf`。
9. **静默失败**：资源解码大量用 `try?`（拆股目录 `HistoryView.swift:1332`、费率目录 `:1397`、板块轮动 `SectorRotation.swift:122-125`），资源缺失时拆股因子回落 1、费率页变空、历史静默丢弃，**无任何诊断信号**。
10. **汇率离线兜底无提示**：`LocalPortfolioStore.swift:1854-1866` 的硬编码汇率表与实时缓存混用，穿透市值可能同时混用实时报价与离线汇率。
11. **零技术债标记**：全项目 `TODO|FIXME|HACK|XXX` **0 命中**。债务完全不以注释标记，只体现在结构里——这一点需要客观指出：代码注释质量整体很高，且多处主动声明了实现边界（如两处「不是税务计算」、`SectorAttribution` 的代理局限、缓存 digest 的取舍），并非刻意隐瞒。

---

## 附录：确实实现 vs 文档/注释声称

| 能力 | 状态 | 依据 |
|---|---|---|
| 首页总市值/成本/未实现盈亏 | ✅ | `LocalPortfolioStore.swift:1890-1906` |
| 今日涨跌（最近两收盘） | ✅ | `LocalServices.swift:1644-1651` |
| 今日盈亏归因（价格） | ✅ 但隐含「今日无交易」 | `PortfolioView.swift:601-618` |
| 汇率归因 | ✅ 三级来源（券商→残差→ECB 重建） | `LocalPortfolioStore.swift:1932-1969` |
| 每日 TWR | ✅ 入金日初 / 出金日末，几何链式 | `DailyTimeWeightedReturn.swift:158-162` |
| MWR / XIRR | ✅ 牛顿 + 扫描 + 二分，**非年化** | `Models.swift:364-489` |
| SPY/QQQ/VTI/GLD 等基准对比 | ✅ 两条口径（现金流镜像 / TWR 指数化），可增删、上限 12 | `Models.swift:556-578`、`ReturnsView.swift:1760-1895` |
| 历史流水列表 / 账户+税年筛选 / CSV 导出 | ✅ | `HistoryView.swift:335-393` |
| **记录级分页 / 无限滚动** | ❌ **不存在**（`HistoryPagingView` 是分类翻页器） | `HistoryPagingView.swift:85-86` |
| 已实现盈亏 FIFO + 券商 Result 分列 | ✅ | `RealisedProfitCalculator.swift:163-241` |
| 平均成本法 | ❌ 仅 FIFO | 同上 |
| 出入金展示 | ❌ 被过滤 | `HistoryView.swift:1319` |
| 手续费计入成本/盈亏 | ❌ 无字段、不参与 | `LocalPortfolioStore.swift:407-427`、`RealisedProfitCalculator.swift:232` |
| 基金年费运行率估算 | ✅（估算，非已付） | `HistoryView.swift:1396-1403` |
| 拆股调整 | ✅ 数量×factor、价格÷factor（**不改列表显示**） | `StockSplitCatalog.swift:21-62` |
| UK same-day / 30 天匹配 | ✅ 实现并接线（仅注释展示） | `UKShareMatching.swift:118-140` |
| UK Section 104 池成本 | ⚠️ 实现但**零调用方** | `UKSection104Pool.swift:94-224` |
| UK 税年 4/6–4/5 | ✅ | `RealisedProfitCalculator.swift:85-88` |
| CGT 税率 / 免税额 / 亏损结转 / 印花税 | ❌ 未实现（仅否定式注释） | `UKSection104Pool.swift:18` |
| 独立税务计算页 | ❌ 入口禁用 | `ReturnsView.swift:63-65` |
| 回撤/水下分析 | ✅ 两条独立实现（不一致） | `UnderwaterAnalysis.swift:15-75`、`LocalReturnsAnalytics.swift:270-376` |
| 损失分析 | ✅ 仅绝对金额归因 | `LossAnalysisChart.swift:347-385` |
| 贡献度 | ✅ 绝对金额堆叠，**非 Brinson** | `HoldingContributionChart.swift:447-459` |
| ETF 直接+间接合并 | ✅ 按 ticker 相加，处理跨 ETF 重复 | `LocalServices.swift:4778-4820` |
| ETF 成本口径 | ✅ 基金成本 × 权重（**活 UI 未暴露**） | `LocalServices.swift:4723-4725`、`:4797` |
| ETF 快照时效性展示 | ❌ 活 UI 不显示、无过期判断 | `LocalServices.swift:4853-4872` vs 死代码 `ETFLookThroughView.swift:53-55` |
| 行业归因 | ✅ 权重分摊，**非 Brinson、无基准** | `SectorAttribution.swift:108-118` |
| 费率进入收益计算 | ❌ 完全未接入 | `LocalETFLookThrough.make` 不引用 `FundFeeCatalog` |
| Squarified treemap | ✅ | `HoldingsTreemapLayout.swift:78-148` |
| RRG 四象限 | ✅ 但值是**来源服务器**给的，非本地计算 | `StockChartsRotation.swift:12-19` |
| 板块轮动 x/y | ⚠️ **服务端计算**，Swift 只校验参数与文案 | `SectorRotation.swift:94-106` |
| StandardLineChart 折线基建 | ✅ Canvas 同步渲染 + UIKit 长按手势桥接；无缩放/无对数/无降采样 | `StandardLineChart.swift:573`、`DesignSystem.swift:1455` |
| VAH/POC/VAL | ✅ 160 根日线 / 固定 36 桶 / 典型价全额入桶 / 70% / 逐桶贪心 | `LocalServices.swift:2195-2242` |
| 首页冷启动缓存 | ✅ ledgerDigest 只认交易/数量/成本/币种/账户 | `PortfolioPresentationCache.swift:67-76` |

**一句话总结**：这条主链路的核心计算（TWR/MWR/FIFO/回撤/treemap/VAH-POC-VAL/缓存失效）都是**真正实现且有测试**的，注释诚实度也高于平均水准；最大的风险不是"没实现"，而是**同一口径被写了两三遍且已经漂移**（今日盈亏、回撤、成本定义、基准总收益）、**两套已完成的引擎从未接线**（`UKSection104Pool`、`ETFLookThroughView` 的成本口径）、以及**数据时效性对用户不可见**（ETF 快照、费率日期、离线汇率兜底）。
