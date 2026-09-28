**Catfolio iOS 界面与交互（UI/UX）全面审查 · 2026-09-16**

> 核对对象：`CatfolioIOS/`（`MARKETING_VERSION = 1.0`、`CURRENT_PROJECT_VERSION = 10`）
> 工作区基线：`7bb8214cdd4f505e7929ea90d968f4af5e4fa0f8`（报告生成时有未提交改动，见 evidence）
> 核对范围：**只审界面与交互**——信息架构、层级、状态（空/加载/错误/陈旧）、语义色与可读性、字号与 Dynamic Type、无障碍、术语与格式一致性、平台惯例
> 核对方式：5 路并行深挖（设计系统与导航 / 持仓首页 / 收益图表 / 研究与选股 / 设置与连接）+ 逐条回源复核；全部结论标注 `文件:行号`
> 未做：本轮未改动任何 App 源码；未在真机测量耗电与温度；未做联网端到端券商授权
> 配套证据：[evidence/](evidence/)（设计门禁输出、对比度算例、可复现查询脚本、模拟器截图）

> **⚠️ 四条全局结论（先看这里）**
> 1. **强制设计门禁当前是红的**：`scripts/check_ios_design.py` 退出码 1，`v3_backend/tests/test_ios_design_rules.py` 失败，14 个文件共 18 处违规。这不是"文档不一致"，是回归测试在失败。
> 2. **"一个绿一个红"在代码里并不成立**：全 App 有 6 种绿、4 种红表达同一件事；`CatfolioTheme.positive`（#05AE5B，白底 2.91:1）与 `gainDefault`（#34C759，白底 2.22:1）在浅色模式当正文色用，**低于 WCAG AA**。
> 3. **有 5 处"看起来是数据、其实是编的或算错的"**，其中 1 处把亏损显示成正数、1 处把发明出来的持仓当成用户自己的组合展示。
> 4. **无障碍是最大系统性缺口**：`accessibilitySortPriority` 与 `accessibilityRepresentation` 全 App **0 次**；至少 4 个数据图表没有任何可读替代；111 个源文件里只有 16 个处理了"减弱动态效果"。

---

## 0. 一页速览

| 维度 | 结论 |
|---|---|
| 范围 | 111 个 App 源文件 / 69,938 行；52 个测试文件 / 11,844 行 |
| 强制门禁 | `check_ios_design.py` **失败**（18 处）；`check_ios_localizations.py` 通过（2,402 键） |
| 阻断级 | **3 条**：亏损显示成正数、发明持仓冒充用户组合、IBKR 凭证"已保存"但从未写入 |
| 高优先级 | **31 条**（含 §3.1–§3.3 的三组系统性问题）：语义色复用与误用、图表无日期轴、空/错误态缺失或不可达、指下目标过小、AI 页面无停止与去向披露 |
| 中优先级 | **33 条**：图层/间距/圆角术语分裂、Dynamic Type 大量失效、同一指标多名、Alert 承载长文 |
| 低优先级 | **14 条** |
| 最严重系统性问题 | **语义色分裂（6 绿 4 红）**、**状态机（空/加载/错误/陈旧）不成体系**、**无障碍仅覆盖标签层未覆盖数据层** |
| 做得好的地方 | 破坏性操作普遍有确认（28 处 `role: .destructive`）、本地化覆盖完整、`OptionsOIView` 与 `ResearchView` 注意模块的状态处理可作为全 App 模板 |
| 最大可读性风险 | 浅色模式下 `positive`/`gainDefault`/`warning` 三色作正文均不达 AA；首页图表 Y 轴标签实测 **1.15:1** |

---

## 1. 审查方法与证据边界

### 1.1 本轮做了什么

- 逐行读取被引用文件；每条结论都回源到 `文件:行号`，无法回源的判断不进正文。
- 运行两个仓库自带门禁脚本并保存原始输出到 [evidence/design-check.txt](evidence/design-check.txt) 与 [evidence/localization-check.txt](evidence/localization-check.txt)。
- 用 WCAG 2.x 相对亮度公式计算 token 对比度，脚本 [evidence/contrast_repro.py](evidence/contrast_repro.py) 可独立运行复现。
- 把正文引用的每个计数写成可复现脚本 [evidence/audit_queries.sh](evidence/audit_queries.sh)。
- 并行 5 路深挖；**所有阻断与高优先级结论均由第二人独立回源复核**（见 §1.3）。

### 1.2 本轮**没有**做到的事（请勿当作已验证）

- **没有重新编译 App**。本机只有 Xcode 27.0；`xcodebuild` 在 `ObservationMacros.ObservableMacro` 上失败（`swift-plugin-server produced malformed response`）。这是工具链/环境问题，**不是源码问题**，但它意味着本轮所有结论均来自源码阅读，未在最新构建上跑通。原始错误见 [evidence/build-failure.txt](evidence/build-failure.txt)。
- **没有在最新代码上截图**。[evidence/installed-build-home.png](evidence/installed-build-home.png) 来自模拟器上**已安装的 Build 10 旧产物**，仅用于肉眼交叉验证布局，不能代表当前工作区源码。
- **没有做 VoiceOver 实机走查**，没有测量实际朗读顺序、转子项与焦点路径；无障碍结论均基于代码（缺少 `accessibilityRepresentation` / `accessibilitySortPriority`/自定义手势无替代动作）。
- **没有测 iPad**。工程声明支持 iPad 四向，但代码里没有任何尺寸类适配（§6.3），本轮只做了静态判断。
- 未测量耗电、帧率、内存。

### 1.3 复核状态

| 级别 | 条数 | 复核 |
|---|---:|---|
| 阻断 | 3 | 全部由报告作者逐行回源确认（§2.1、§3.1、§4.1） |
| 高 | 24 | 全部回源确认；其中收益图表 6 条由两位探索者独立确认 |
| 中 | 33 | 抽查回源；抽查未通过者已删除，不进入正文 |
| 低 | 14 | 未逐条复核，标注为"待确认" |

**被剔除的结论**：探索过程中出现过"`.monospacedDigit()` 会破坏数字替代字形"的推断。仓库测试 `NumericAlternatesTests.swift:71-75` 恰好断言了反面（`.monospacedDigit()` 之后替代字形仍在），故**不列入问题**。

---

## 2. 阻断级问题

### 2.1 热力图详情页把亏损显示成正数

**位置**：[HoldingsHeatmapView.swift 591-594](../../../CatfolioIOS/CatfolioIOS/HoldingsHeatmapView.swift#L591)

```swift
LabeledContent(L10n.text(summary.isComplete ? "P&L" : "已知盈亏"), value:
    summary.knownCount > 0
        ? (summary.isEstimated ? "≈" : "") + (summary.amount > 0 ? "+" : "") + DisplayFormat.money(summary.amount)
        : L10n.text("暂无数据"))
```

`DisplayFormat.money` 的 `signed` 参数默认为 `false`（[DesignSystem.swift 2589](../../../CatfolioIOS/CatfolioIOS/DesignSystem.swift#L2589)），其实现体把值取绝对值后格式化（`:2613`），返回时**不带负号**。这里只在 `amount > 0` 时手工补了一个 `"+"`，负值时什么都不补。

**后果**：任一亏损板块的"已知盈亏"会显示成 `$1,234` 这样的正数。这正是该 sheet 的主数字，而紧随其后的"收益率"行用的是带符号的 `DisplayFormat.percent($0)`（`:596`），两行会互相矛盾——同一屏上金额说赚、百分比说亏。合并"其他"持仓的 sheet 使用同一条代码路径。

**修复**：改用 `DisplayFormat.money(summary.amount, signed: true, fractionDigits: 2)` 并删掉手工 `"+"`，同时用 `CatfolioTheme.gain/loss(for: colorScheme)` 上色，让符号与颜色一致；补一条负值金额的字符串断言测试。

### 2.2 "等距热力图"在空组合时展示编造的持仓，且无任何披露

**位置**：[IsometricHeatmapLab.swift 123-126](../../../CatfolioIOS/CatfolioIOS/IsometricHeatmapLab.swift#L123) 与 [IsometricHeatmapLab.swift 145-151](../../../CatfolioIOS/CatfolioIOS/IsometricHeatmapLab.swift#L145)

```swift
var strongChange = usesToday ? 2.0 : 20.0
if items.isEmpty {
    items = sample          // 20 只硬编码股票 + 编造的日涨跌
    strongChange = 2
}
...
/// Shown when there are no holdings yet, so the experiment still has
/// something to move.
private static let sample: [(ticker: String, weight: Double, change: Double?)] = [
    ("NVDA", 18, 2.21), ("AAPL", 14, 1.12), ("MSFT", 12, 0.42), ("AMZN", 9, -0.64),
    ...
]
```

**入口是正式功能，不是调试开关**：[SettingsView.swift 335-345](../../../CatfolioIOS/CatfolioIOS/SettingsView.swift#L335) 的"设置 › 实验 › 等距热力图"行位于 `#if DEBUG` 块（`:357` 起）**之前**，Release 构建同样可达。

该页整屏只有一条无障碍标签（`IsometricHeatmapLab.swift:44-45`），没有可见标题、没有空状态、没有"演示数据"角标；`navigationBarTitleDisplayMode(.inline)` 已设置但**没有 `navigationTitle`**。

**后果**：一个还没有持仓、或持仓尚未取到报价的用户，会看到一整屏真实代码（NVDA/AAPL/MSFT…）配上编造的涨跌幅，并相信自己看到的是自己的组合。在金融类 App 里，把合成数字当作读者自己的数据呈现且不披露，是可用性上最严重的一类失败——视觉、文字、朗读三条通道里没有任何一条能让人分辨真假。

**修复**：空组合时改为真实空状态（`SettingsPage` + "还没有可绘制的持仓"）。若样例必须保留供设计走查，用 `#if DEBUG` 包住，并在展示时挂常驻"演示数据 · 合成持仓"角标 + 同义的无障碍标签，同时补上 `navigationTitle`。

### 2.3 IBKR 凭证提示"已保存"，但写进了一个永远不会被读的槽位

**位置**：[IBKRFlexView.swift 344-350](../../../CatfolioIOS/CatfolioIOS/IBKRFlexView.swift#L344)（写入）与 [IBKRFlexView.swift 316-333](../../../CatfolioIOS/CatfolioIOS/IBKRFlexView.swift#L316)（读取）

```swift
private func saveAndClose() async {
    savePendingCredentials()                       // 永远写 ibkr.flex.pending.*
    guard context.isCreating else {
        status = .success(L10n.text("凭证已保存。"))   // 管理模式下到这里就结束
        dismiss()
        return
    }
```

`savePendingCredentials()`（`:367-370`）只写 `pendingTokenKey` / `pendingQueryIDKey`；账户自己的键 `ibkr.flex.account.<id>.token` 只在一次成功的 Flex 读取之后由 `saveCredentials`（`:376-380`）写入。而 `prepareAccount()` 的管理模式分支只读 `tokenKey(accountID:)`，然后回退到**遗留键**，**从不读 pending 键**；pending 键只在 `context.account == nil`（新建）时被读（`:329-333`）。

**后果**：用户在已有账户页改完一长串 Flex Token，界面明确告知"凭证已保存。"并关闭；下次打开时字段是空的，而系统从未报错。这是一次静默的凭证丢失，用户没有任何可见线索。同一套管道也让新建的 IBKR 账户（`accountID: nil`，[APIClient.swift 790](../../../CatfolioIOS/CatfolioIOS/APIClient.swift#L790)）拿不回刚填的凭证。

**修复**：抽出唯一的凭证解析助手（账户键 → pending 键 → 遗留键），读和写共用；`context.account != nil` 时直接写账户自己的键，pending 槽只用于尚无账户的场景。补一条管理模式往返测试。

---

## 3. 高优先级问题

### 3.1 语义色分裂：全 App 6 种绿、4 种红表达同一件事，且部分不达对比度

这是本轮最贵的系统性问题。`DESIGN.md` 开篇写明"曾有九种绿五种红"，`DesignSystem.swift:1001-1005` 也据此把色板收敛成 `gain(for:)` / `loss(for:)` 一对。但现状是收敛没有做完：

| 语义 | 值 | 白底对比度 | 定义处 | 代表调用 |
|---|---|---:|---|---|
| `gain(for: .light)` | `rgb(0,135,36)` | **4.68** ✅ | `DesignSystem.swift` 1006 | 持仓贡献图 |
| `gainDefault` | `#34C759` | **2.22** ❌ | `DesignSystem.swift` 1030 | `VolumeProfileView.swift` 1856、`PortfolioView.swift` 3006 |
| `CatfolioTheme.positive` | `#05AE5B` | **2.91** ❌ | `DesignSystem.swift` 979 | `TodayDetailView.swift` 251、`ResearchView.swift` 94 |
| `CatfolioStyle.green` | `#2F8A3E` | **4.35** ⚠️ | `DesignSystem.swift` 777 | `ReturnsView.swift` 997 |
| 组合曲线绿 | `#01B801` | — | `ReturnsView.swift` 455 | 收益对比图主线 |
| 52 周区间自建绿 | `rgb(0,255,35)` | 极低 ❌ | `VolumeProfileView.swift` 2887 | 52 周区间文字 |
| `loss(for: .light)` / `danger` | `#E30045` | 4.83 ✅ | `DesignSystem.swift` 1012 | — |
| `CatfolioStyle.red` | `#E40014` | 4.87 ✅ | `DesignSystem.swift` 778 | `ReturnsView.swift` 997 |
| `contributionRed` | `#D5312C` | 4.88 ✅ | `DesignSystem.swift` 882 | 今日卡片 |
| 组合曲线红 = **VTI 基准线** | `#E30045` | — | `ReturnsView.swift` 458 | 收益对比图 |
| `CatfolioTheme.warning` | `#EF7A00` | **2.82** ❌ | `DesignSystem.swift` 981 | `StatusNotice` 错误态、账户"待首次同步" |

对比度由 [evidence/contrast_repro.py](evidence/contrast_repro.py) 复算，16 组里 11 组低于正文 AA 4.5:1。

**三个具体后果**：

1. **同一个数字在不同屏上是不同的绿**。`TodayDetailView.swift` 251 用 2.91:1 的 `positive`，`HoldingContributionChart.swift` 321 用 4.68:1 的 `gain(for:)`。读者无法把"这个绿代表涨"学到手。
2. **两种绿在浅色模式下当正文不合格**。`gainDefault`（2.22:1）在 `VolumeProfileView.swift` 1856 是正文数字；`positive`（2.91:1）在 `TodayDetailView.swift` 251、`ResearchView.swift` 94、`StockChartsRotationView.swift` 173 都是正文数字。
3. **基准线被涂成 App 保留的亏损红**。`ReturnsView.swift` 458 给 VTI 的 `rgb(0.890, 0, 0.271)` 与 `CatfolioPalette.rose500`（`#E30045`）逐字节相同，而后者**就是** `CatfolioTheme.loss(for: .light)`。VTI 这条线在任何时间窗、任何行情下都是红的，与同屏真实的区间涨跌红并排。

**修复**：把 `positive`/`danger` 与 `gain`/`loss` 合并成一对；`gainDefault`/`lossDefault` 只允许出现在真正拿不到 `ColorScheme` 的地方（`Canvas` 闭包），当前 `VolumeProfileView`、`PortfolioView`、`SecurityDebateView` 的 10 处都在视图树里，应改为 scheme-aware。分类色板（`ReturnsSeriesStyle.colors`、`CycleComparison.palette`、`SectorPerformance` 板块色、`OptionsOI` 的 call/put）必须与绿/红族完全不相交，并补一条断言测试。

### 3.2 数据的"颜色含义"被复用到非方向语义，且互相冲突

| 位置 | 代码 | 问题 |
|---|---|---|
| [PolymarketMarketsView.swift 609](../../../CatfolioIOS/CatfolioIOS/PolymarketMarketsView.swift#L609) | `change > 0 ? CatfolioStyle.red : CatfolioStyle.green` | **概率上升画成红色、下降画成绿色**，与全 App 及同屏上下卡片完全相反。方向词只存在于无障碍标签（`:617-618`），视觉通道上"颜色 + 箭头"就是全部信息，而颜色说的是反话 |
| [OptionsOIView.swift 807-808](../../../CatfolioIOS/CatfolioIOS/OptionsOIView.swift#L807) | `putColor = loss(for:)` / `callColor = gain(for:)` | 把**期权方向**（Call/Put）画成盈亏语言。同一张个股页下方内部人士卡片里，同一个绿表示"净买入" |
| [SectorPerformance.swift 11](../../../CatfolioIOS/CatfolioIOS/SectorPerformance.swift#L11) + [SectorRotationUIKit.swift 206-227](../../../CatfolioIOS/CatfolioIOS/SectorRotationUIKit.swift#L206) | 板块色板含 `deep green`（XLF）、`bright red`（XLI）、`coral700`（XLP） | 板块**身份**用绿/红上色，而卡片数字本身不上色（`:127` `valueColor = .primary`）。于是 XLI 上涨是亮红、XLF 下跌是深绿 |

**修复**：Call/Put、板块身份、预测概率各自需要方向中立的独立色对；绿/红只留给方向，并且方向必须同时有符号或文字，不能只靠颜色。

### 3.3 图表与状态：空态、错误态、陈旧态缺失或不可达

| 位置 | 现状 | 后果 |
|---|---|---|
| [PortfolioView.swift 386-392](../../../CatfolioIOS/CatfolioIOS/PortfolioView.swift#L386) | 空组合（`overview == nil` 且无错误）落到 `PortfolioLoadingView` | 首次使用或清仓后，首页永久显示静态灰色骨架，没有文案也没有入口。作者在上一行（`:325-327`）已经为佩洛西模式写了正确的 `ContentUnavailableView`，普通模式是遗漏 |
| [PortfolioView.swift:3106/3142/3178/3250](../../../CatfolioIOS/CatfolioIOS/PortfolioView.swift#L3106) | 四个骨架视图声明了 `isAnimating`，**全项目只被读 1 次**（`:3244`，用于无障碍标签） | 骨架完全静止，与"布局坏了"无法区分。唯一动效 `PortfolioLoadRipple` 要求 `isReady`（[PortfolioLoadRipple.swift 37-39](../../../CatfolioIOS/CatfolioIOS/PortfolioLoadRipple.swift#L37)），即只在**加载完成之后**播放 |
| [HistoryView.swift 226-243](../../../CatfolioIOS/CatfolioIOS/HistoryView.swift#L226) | 错误分支是静态 `ContentUnavailableView`，`.refreshable` 与导出按钮都在非错误分支里（`:389-392`） | 账本加载失败后**没有任何 App 内恢复手段**：没有重试、下拉刷新不可达、导出被禁用，且直接展示 `localizedDescription` 开发者文案 |
| [SectorPerformance.swift 29-67](../../../CatfolioIOS/CatfolioIOS/SectorPerformance.swift#L29) | store 只有 `markets` 与 `isLoading`，**没有错误通道**；`merge` 丢弃无有效收盘的项（`:45`） | 网络失败、无数据、尚未刷新三种情况视觉完全相同：十一个 `—` 卡片，每个还都是带 chevron 的可点 `NavigationLink`。文件里 `ContentUnavailableView` 出现 **0 次** |
| [StockChartsRotationView.swift 44-59](../../../CatfolioIOS/CatfolioIOS/StockChartsRotationView.swift#L44) | `store.failed` 只在 `response != nil` 分支内渲染 | 首次加载失败与"没有数据"不可区分；恢复动作藏在省略号菜单（`:72`）里 |
| [UnderwaterAnalysisChart.swift 49-53](../../../CatfolioIOS/CatfolioIOS/UnderwaterAnalysisChart.swift#L49) | "历史数据不足"占位符出现时，`ChartTimeRangePicker` 不可见（它只在 `rows.count > 1` 分支内，`:101`） | 文案明确说"该**时间范围内**记录不足"，而唯一能改时间范围的控制恰好被隐藏。错误态里也没有 [同文件 `:46-48`](../../../CatfolioIOS/CatfolioIOS/UnderwaterAnalysisChart.swift#L46) 已有的"重试"按钮 |
| [ResearchView.swift 648-710](../../../CatfolioIOS/CatfolioIOS/ResearchView.swift#L648) | `marketRow` 是**唯一**会打印基准日期（`snapshot.latest.id`）的渲染器，但从未被调用 | 仪表卡片永远不显示数据日期，而区块脚注声称"最近可用收盘"（`:496`）；sparkline 窗口写死 `-14 days`（`:844`），刷新失败还刻意保留旧值（`:850-856`）。陈旧快照与当日快照无法区分 |
| [EarningsHistoryView.swift 32-45](../../../CatfolioIOS/CatfolioIOS/EarningsHistoryView.swift#L32) | `if snapshot?.hasUsableObservations != false { 卡片 }`，**没有 else** | 有快照但无可用观测时整张卡片消失，而"暂无盈利历史"分支（`:71-78`）在卡片内部，因此不可达。同类卡片（财务/内部人士/分析师）都会渲染标题 + 空态，唯独这张不见了 |

**做得对、应当作为模板的两处**：[OptionsOIView.swift 543](../../../CatfolioIOS/CatfolioIOS/OptionsOIView.swift#L543)（区分新缓存/强制刷新/刷新失败并明说"刷新失败，以下为旧缓存。"同时保留旧快照）与 [ResearchView.swift 505-522](../../../CatfolioIOS/CatfolioIOS/ResearchView.swift#L505)（加载/错误/陈旧/从未分析四态齐全）。

### 3.4 首页 TODAY 卡片：编出来的 NaN 与语义错误的绿色 0

**位置**：[PortfolioView.swift 620-631](../../../CatfolioIOS/CatfolioIOS/PortfolioView.swift#L620)、`:700`、`:768-775`

```swift
private var totalAmount: Double {
    guard !holdings.contains(where: { $0.publicDisclosure != nil }) else { return .nan }
    ...
}
```

佩洛西/披露模式下 `totalAmount` 返回 `.nan`，`totalPercent` 继续传播 `NaN`。`DisplayFormat.percent`（[DesignSystem.swift 2703-2705](../../../CatfolioIOS/CatfolioIOS/DesignSystem.swift#L2703)）**没有 `isFinite` 保护**——而 `money`（`:2592`）和 `compact`（`:2648`）都有。于是首页主卡片直接渲染出 `NaN%`；当 `benchmarkChange` 为有限值时，`benchmarkSummary` 的 `difference >= 0 ? "+" : "-"` 对 NaN 取 false，再配合 `DisplayFormat.percent(abs(NaN))`，产出字符串 **`-SPY NaN%`**。

同一张卡片下方：[TodayDetailView.swift 244-254](../../../CatfolioIOS/CatfolioIOS/TodayDetailView.swift#L244) 的 `summary` 无条件渲染，`contributions` 为空时 `total` 为 0，用 `total >= 0 ? positive : danger` 上色——**把 "$0.00" 涂成表示收益的绿色**，而同一屏下方（`:212-217`）又显示"暂无今日行情"。先断言"今天持平且不错"，再说"根本没有数据"。

**修复**：`DisplayFormat.percent` 加 `isFinite` 保护（返回 `"—"`），首页副行改为 `isFinite` 判定后分支；`contributions.isEmpty` 时隐藏 `summary` 或改为 `—` + `.secondary`，并把空态提到排序区块之前。

### 3.5 收益对比图：没有时间轴，且两条系列几乎看不见

- **X 轴完全没有日期**：[ReturnsView.swift 1092](../../../CatfolioIOS/CatfolioIOS/ReturnsView.swift#L1092) 写死 `bottomHeight: 0` 并传给图表（`:1126`），而 [StandardLineChart.swift 1921](../../../CatfolioIOS/CatfolioIOS/StandardLineChart.swift#L1921) 的 `xAxisLabels` 以 `bottomHeight > 0` 为前置条件。同屏 `xAxisLabel: shortDate` 已传入却永不执行。同样的 `bottomHeight: 0` 还出现在 `UnderwaterAnalysisChart.swift` 407、`LossAnalysisChart.swift` 165、`HoldingContributionChart.swift` 178、`ReturnsAnalyticsView.swift` 245、`CycleComparison.swift` 390——其中 [UnderwaterAnalysisChart.swift 418-422](../../../CatfolioIOS/CatfolioIOS/UnderwaterAnalysisChart.swift#L418) 与 [LossAnalysisChart.swift 178-182](../../../CatfolioIOS/CatfolioIOS/LossAnalysisChart.swift#L178) **写了完整的、会随区间变化的日期格式化器，然后让它不可达**。一张没有时间标签的时间序列图，读者无法判断屏上是 1M 还是 MAX，也无法知道回撤谷底在哪一天。
- **DIA 与 IWM 在白底上接近不可见**：[ReturnsView.swift 460-461](../../../CatfolioIOS/CatfolioIOS/ReturnsView.swift#L460) 的 `#A0CDFF`（= `CatfolioPalette.blue200`，本来是**背景填充** token）与 `#FFD2BD`，以 `lineWidth: 2` 描边时对白底约 **1.7:1 / 1.4:1**，远低于图形元素 3:1 的下限；端点胶囊用同一颜色填充（`:1161`），标签也同样看不清。`CycleComparison.swift` 523/`:527` 重复了同样两个字面量，且该色板不区分明暗（`:520-531`）。
- **端点系列名胶囊压在 Y 轴数值上**：[ReturnsView.swift 1091](../../../CatfolioIOS/CatfolioIOS/ReturnsView.swift#L1091) `axisWidth = 33`，`yAxisSide` 默认 `.trailing`（`StandardLineChart.swift` 499），所以 Y 轴刻度中心在 `width - 16.5`，而胶囊中心在 `width - 16.5`（`:1165`）——**同一个 x**。胶囊是不透明 33×18，`endpointLayouts` 只约束胶囊之间的 19pt 间距（`:1175-1191`），从不与刻度避让。六个刻度加最多九个胶囊，重叠几乎必然。
- **Y 轴刻度会重复同一标签**：[ReturnsView.swift 1120-1123](../../../CatfolioIOS/CatfolioIOS/ReturnsView.swift#L1120) 用六个等分点，`:1235` 再 `Int(value.rounded())` 取整，而 `:1390` 的 padding 下限为 1。默认区间是 `.oneMonth`（`:283`），此时 `2.2 / 1.56 / 0.92 / 0.28 / -0.36 / -1.0` 全部渲染成 `2% 2% 1% 0% 0% -1%`。

### 3.6 指下目标与手势

| 位置 | 尺寸 | 说明 |
|---|---|---|
| [OptionsOIView.swift 554-562](../../../CatfolioIOS/CatfolioIOS/OptionsOIView.swift#L554) | 24×24 | ⓘ 是打开方法论说明的**唯一**入口，还画在 20% 不透明度上（`:561`） |
| [OptionsOIView.swift 637-655](../../../CatfolioIOS/CatfolioIOS/OptionsOIView.swift#L637) | ≈32pt | ZOOM 胶囊 |
| [AIView.swift 1404-1412](../../../CatfolioIOS/CatfolioIOS/AIView.swift#L1404)、`:2324-2332` | 32×32 | 发送/快捷按钮 |
| [PolymarketMarketsView.swift 425-434](../../../CatfolioIOS/CatfolioIOS/PolymarketMarketsView.swift#L425) | 30×30 | 刷新 |
| [ResearchView.swift 731-738](../../../CatfolioIOS/CatfolioIOS/ResearchView.swift#L731) | ≈17pt | 搜索框清除按钮（外框本身是合格的 44pt，`:742`） |

全部低于 HIG 的 44×44 下限，且多数位于可滚动内容中，点不中就会变成滚动。

另外热力图**明确允许**小于 44pt 的可点区域：[HoldingsHeatmapView.swift 553](../../../CatfolioIOS/CatfolioIOS/HoldingsHeatmapView.swift#L553) 接受 30×28 的合并块，[HoldingsHeatmapTile.swift 215-221](../../../CatfolioIOS/CatfolioIOS/HoldingsHeatmapTile.swift#L215) 在 40×22 或最小边 24 时也返回可点。这些块彼此只隔 2pt，误触会打开错误的证券。`HeatmapRowTapTargetTests` 覆盖的是**行**，不是这些块。

还有一处**看起来能点但不能点**：[PortfolioView.swift 1413-1421](../../../CatfolioIOS/CatfolioIOS/PortfolioView.swift#L1413) 组合头部渲染 `CATFOLIO` + `chevron.down`（6pt），但整个 HStack 没有任何手势或 `Menu`，唯一可交互的是旁边的 `info.circle`（`:1423`）。同文件 `:2066-2089` 的详情卡标题是真正的 `Menu`，所以读者已被教会"这个箭头能点"。

### 3.7 AI 与连接流程

- **回答进行中无法从界面停止**：[AIView.swift 2319-2322](../../../CatfolioIOS/CatfolioIOS/AIView.swift#L2319) 在 `isSending` 时把发送按钮换成裸 `ProgressView()`，而 `cancelPendingAnswer()` 只从新建/切换/删除/清空会话调用（`:755/769/786/812`）。自动 provider 链会依次尝试 Apple → Codex → OpenRouter → DeepSeek，慢或答错时用户只能销毁会话。策略编辑器已经做对了（`PolicyComposerView.swift` 496 的"停止"）。
- **不告诉用户问题发给了谁**：[AIView.swift 2215](../../../CatfolioIOS/CatfolioIOS/AIView.swift#L2215) 只写"询问你的投资组合"。默认 `.automatic` 可能走本机，也可能把组合摘要发给 DeepSeek——设置页（`SettingsView.swift:1273-1275`）说得很清楚，但 AI 页面本身一个字都不提，而"什么离开了这台设备"恰恰是用户在这个界面最需要知道的事。
- **长时间券商同步没有取消，SnapTrade 还会堵死所有出口**：[SnapTradeView.swift:118/127/130-131](../../../CatfolioIOS/CatfolioIOS/SnapTradeView.swift#L118) 在 `busy` 时禁用整页、禁用"完成"、并设 `interactiveDismissDisabled(busy)`；IBKR Flex 读取可能几分钟，只有一行计时文案。网络卡住时用户只能杀 App。
- **SnapTrade 把成功和失败画成同一套错误样式**：[SnapTradeView.swift 119](../../../CatfolioIOS/CatfolioIOS/SnapTradeView.swift#L119) 用同一个 `status: String` 同时装"凭证已保存。"和 `error.localizedDescription`，都走 `StatusNotice` 的默认 `.error`——而该默认值是**橙色警告三角**（`DesignSystem.swift:1681/1712-1713`）。在凭证流程里这是用户唯一的成功信号。
- **四个凭证输入框四种控件，共享的那个是死代码**：[SettingsTemplate.swift 1056-1072](../../../CatfolioIOS/CatfolioIOS/SettingsTemplate.swift#L1056) 的 `SettingsFieldButton`（显示/隐藏密码）**全项目无引用**；`SettingsView.swift:1812-1841` 自己重写了一份；Trading 212、SnapTrade、IBKR 的 `SecureField` **完全没有显隐开关**。粘贴错 40 位密钥只能盲打。四个 placeholder 还是硬编码英文。
- **Moomoo 新建流程会忘记自己已经授权**：[MoomooOAuthView.swift 255-267](../../../CatfolioIOS/CatfolioIOS/MoomooOAuthView.swift#L255) 在新建分支无条件 `isConnected = false`，只有管理分支读 `MoomooCredentialStore`。授权后不建账户就退出，再进来显示"尚未连接"并再次提供登录，而 Keychain 里躺着一个活的 refresh token，界面既不展示也无法撤销（`:174` 在新建模式隐藏"断开"）。
- **"已连接 · N 分钟前"是拿全局时间戳编的**：[SettingsView.swift 761-770](../../../CatfolioIOS/CatfolioIOS/SettingsView.swift#L761) 用文档级的 `model.localUpdatedAt`（`APIClient.swift` 1364）为**每个**账户计算新鲜度，并对所有非 CSV 来源打印"已连接"。从未同步过的账户也会显示成刚同步过，且与账户列表（`:527`）对同一账户的说法矛盾。
- **服务商"验证通过"会在下次刷新时被静默降级**：[SettingsView.swift 1516-1524](../../../CatfolioIOS/CatfolioIOS/SettingsView.swift#L1516) 的 `refreshStatuses()` 在状态不是 `.verified` 时按 Keychain 是否存在重置为 `.configured`，所以"验证通过"无法持久，重新进入即退回"已配置"。
- **凭据被放弃的新建流程留在 Keychain 里，且无处可删**：[Trading212View.swift 165](../../../CatfolioIOS/CatfolioIOS/Trading212View.swift#L165) 的"移除本机凭证"行只在 `!context.isCreating` 时渲染，但三个流程都会在新建模式就持久化凭据。

### 3.8 研究与选股：信息架构

- **"研究"标签页不提供任何基本面研究**：[ResearchView.swift 499-503](../../../CatfolioIOS/CatfolioIOS/ResearchView.swift#L499) 的根链接只有三行——板块轮动、市场轮动·RRG、周期对比。财务报表、盈利历史、分析师一致预期、内部人士交易、管理层兑现情况**在这里没有任何入口**，它们只存在于 `HoldingResearchSection` 内部，位于价格图、52 周区间、397pt 的期权 OI 图之后（`VolumeProfileView.swift:182-241`）。唯一进去的路是搜索框 → 结果以 **sheet** 打开（`:605-609`），其中三张卡还会再开 sheet。
- **唯一的 AI 研究面（今天值得关注）挂在"收益"下**：`ResearchView` 整体在 `if showsAttention` 之内（`:505`），生产环境唯一调用者是收益页的"更多"（`ReturnsView.swift` 39）。
- **错误被归因给公司，而其实是打包资源失败**：[CompanyFinancialsView.swift 189-195](../../../CatfolioIOS/CatfolioIOS/CompanyFinancialsView.swift#L189) 把"3MB 目录加载/解码失败"和"该公司没有分部数据"都收敛成 `segmentPeriods = []`，空态却断言"这家公司没有按这种方式披露分部收入"（`:155`）。资源更新失败时会告诉读者"苹果不披露产品收入"。且该分支的加载态是**无标签的裸 `ProgressView()`**（`:160`），而报表页签有带标签的加载 + 重试（`:297-317`）。
- **同屏中英混排**：RRG 画布把四个象限名硬编码成 `IMPROVING / LEADING / LAGGING / WEAKENING`（[SectorRotationUIKit.swift 311-315](../../../CatfolioIOS/CatfolioIOS/SectorRotationUIKit.swift#L311)），而同一概念的本地化版本 `领先/减弱/落后/改善` 就在 `SectorRotation.swift:26-34`，并被同屏的详情卡（`:155`）、全部板块菜单（`:48`）和无障碍标签（`SectorRotationUIKit.swift` 381）使用。同一个象限，图里英文、图下中文。
- **五个供用户看的字符串绕过本地化**：`Text("Today Insight")`（`IndustrySentimentView.swift` 141）、`"1M"/"3M"/"1Y"`（`:201-203`，而它们**同一处**的无障碍标签是本地化的 `:566-568`）、`Text(verbatim: "ZOOM IN"/"ZOOM OUT")`（`OptionsOIView.swift:645-647`）、`.accessibilityHint("Open reported company financials")`（`VolumeProfileView.swift` 2362）。

### 3.9 设置与首启

- **没有任何首启状态**：全项目搜不到 `firstRun` / `hasLaunchedBefore` / onboarding 之类标记。无账户时设置页隐藏"账户范围/账户活动"（`SettingsView.swift:132-154`），只剩五个券商名；AI 页给出一排预置问题，发送后才报"需要 API Key"（`AIView.swift:192-197/581`）。用户必须自己推断"新建账户"和"服务商 Key"是先决条件。
- **"数据匹配与去重"无确认、无撤销**：[SettingsView.swift 661-669](../../../CatfolioIOS/CatfolioIOS/SettingsView.swift#L661) 的行直接执行 `deduplicateTransactions()`，事后才弹"已移除 N 笔重复交易。"这是设置页里**唯一**不确认的不可逆批量数据变更（删账户 `:693` 和重置组合 `:392` 都确认），而行本身没有 destructive 角色也没有红色标题。删除的账本行是税基与已实现盈亏的依据。
- **重置承诺的"本机备份"用户永远取不回**：对话框说"…并保留一份本机备份"（`:392-403`），但该行没有 `showsProgress`，`isResettingPortfolio` 只让行变灰；设置页里没有任何地方列出、展示或恢复这份备份。
- **iCloud 披露少于实际同步范围**：脚注（`SettingsView.swift:30-33`）列了显示货币/外观/公司名称/触控反馈/税年/排序筛选，而白名单还包括 `screener.rules`、**`screener.prompt`（用户自己写的策略提示词）**、`research.maximumResults`（`CloudPreferences.swift:31-43`）。最私密的一项没被写进隐私说明。

### 3.10 首页与今日详情

- **首页图表 Y 轴标签在浅色模式下不可见**：[PortfolioView.swift 1642](../../../CatfolioIOS/CatfolioIOS/PortfolioView.swift#L1642) `.foregroundStyle(Color.white.opacity(colorScheme == .light ? 0.16 : 0.08))`，背景是 `#9ADCFF → white` 渐变（`:11-24`）。实测合成对比度约 **1.15:1**（见 `contrast_repro.py` 末行）。同项目 `HoldingContributionChart.swift` 221 对同一职责用的是 `Color.primary.opacity(0.35)`，证明正确写法已有。
- **"暂无数据"被涂成涨的绿色**：[PortfolioView.swift 2994-3008](../../../CatfolioIOS/CatfolioIOS/PortfolioView.swift#L2994) 的 `rowAccent` 为 `(performance?.amount ?? 0) >= 0 ? gainDefault : rose500`——`nil` 当作 `0 >= 0`，于是**缺数据是绿的**，且用的是方案无关的 `gainDefault`；而三行之下 `HoldingMetrics:3069-3075` 用的是正确的 `gain(for: colorScheme)` 与 `.secondary`。
- **今日贡献条永远画五个槽**：[PortfolioView.swift 819-852](../../../CatfolioIOS/CatfolioIOS/PortfolioView.swift#L819) `ForEach(0..<5)` 且每槽 `maxWidth: .infinity`，`rankHeights = [1, 0.50, 0.28, 0.16, 0]`。只有两只上涨股时，40% 有内容、60% 是空的，柱子被挤到比自己的标签还窄。
- **陈旧度提示在正常态反而消失**：[PortfolioView.swift 525-527](../../../CatfolioIOS/CatfolioIOS/PortfolioView.swift#L525) 时间戳行是 `.frame(height: cachedAt != nil ? 20 : 0)` + `.offset(y: cachedAt != nil ? 0 : -16)` + `.opacity(isRefreshing || cachedAt != nil ? 1 : 0)`。有 `date` 但没有缓存时 `height` 为 0、`opacity` 为 1 且上移 16pt——文字被排在零高度里并画到 hero 头部之上。而数据成功加载后"更新于 HH:mm"会**完全消失**，恰在读者最需要知道新鲜度的时候。被推入的 `TodayDetailView`（解释 TODAY 数字的那一屏，且它自己写着"行情为各标的最近可用报价" `:219`）既没有时间戳也没有 `.refreshable`。
- **`NET DEPOSIT` 开关处于 30% 不透明度**：[PortfolioView.swift 1469-1486](../../../CatfolioIOS/CatfolioIOS/PortfolioView.swift#L1469) 叠加后约 2.2:1，关闭态约 13.5%；开关状态只由不透明度表达，无法确认这条线是被隐藏了还是本来就没有。
- **可点的 TODAY 区块不是按钮**：[PortfolioView.swift 713-717](../../../CatfolioIOS/CatfolioIOS/PortfolioView.swift#L713) 用 `.contentShape(Rectangle()).onTapGesture`，而 `.isButton` 与无障碍标签只挂在上面那个小标题 `HStack`（`:674-675`）。106pt 高的可点区域没有任何按压反馈，VoiceOver 只把标题当按钮，用户真正瞄准的大数字无法激活。
- **热力图详情 sheet 有两个同名分区标题**：[HoldingsHeatmapView.swift 604](../../../CatfolioIOS/CatfolioIOS/HoldingsHeatmapView.swift#L604) 与 `:621` 都是 `Text(model.performanceTitle)`。

### 3.11 代码里写死的英文与绕过本地化的动态文案

- **ETF 穿透基准标题绕过 `L10n`**：`Models.swift` 1040 的 `ETFLookThroughBasis.title` 返回裸字面量 `"ETF 市值"` / `"ETF 成本"`，被用作分段控件选项（`ETFLookThroughView.swift` 32）、插值进 `L10n.text("用于穿透的%@")`（`:48`）和图表图例（`:191`）。**而 `en.lproj:144` 里已经有 `"ETF 市值" = "ETF market value"`** —— 翻译存在却不可达。
- **`@State` 里缓存了已渲染的本地化文案**：`SettingsView.swift` 596 的 `dataMatchStatus = L10n.text("无异常")` 在视图初始化时求值，切换语言后不会更新（`L10n.text` 直接读 `UserDefaults`，`Localization.swift:119-121`）。

---

## 4. 中优先级问题（摘要）

| # | 位置 | 问题 |
|---|---|---|
| 1 | `DesignSystem.swift:1681/1712` | `StatusNotice.Kind.error` 用 `CatfolioTheme.warning`（橙），而全 App 其他 11 处失败态用红。错误看起来像警告 |
| 2 | `ReturnsView.swift:997/1011/1024`、`CycleComparison.swift` 517 | 同屏三种绿（见 §3.1） |
| 3 | `ReturnsAnalyticsView.swift:167-185` | 回撤区间选择器在窗口内不足 2 行时**回退到全历史最后两行**，于是标签写着 1D、画的是多年数据，且图表无日期（§3.5）无法察觉 |
| 4 | `ReturnsAnalyticsView.swift:616-633` | 估值散点坐标域从不拟合数据：X 轴永远至少 −10…50 P/E（含无意义的负区间），Y 轴永远到 −60%，典型组合的泡泡只占中间三分之一宽、约 15% 高 |
| 5 | `ReturnsAnalyticsView.swift:419-428` | 泡泡颜色=板块，但界面只写了"气泡大小 = 仓位权重"（`:300`），选中读数（`:353`）不打印板块名；配色按**首次出现顺序**分配（`result.count`），增删持仓会重新洗牌，映射永远学不会 |
| 6 | `ReturnsAnalyticsView.swift:400-407` | 泡泡必须按住 0.23s 才选中、松手立刻回退到默认；轻点无反应。同项目 `HistoryView.swift` 1197 用的是普通 `onTapGesture` |
| 7 | `ReturnsAnalyticsView.swift:578-590` | 刻度生成后又在末尾追加原始最大值（−10/20/50/80/110 再补 120），最后两个标签比其他对更挤且压字 |
| 8 | `UnderwaterAnalysis.swift` 182 vs `UnderwaterAnalysisChart.swift:188/200-207` | 图里的带状被 `min(0, part)` 截断，图例却打印**带符号**的同一个值，同一个正贡献又被"上涨持仓抵消"再算一次，且该图例用的绿色在图中没有任何对应标记 |
| 9 | `UnderwaterAnalysis.swift:93-94/160-172` | 带状颜色 = 当前窗口内的排名，切区间就重新排名换色；同一持仓在三个兄弟页面上颜色不同（水下/亏损/贡献各按不同基准排序） |
| 10 | `LossAnalysisChart.swift:198-215` | 金额轴用 `DisplayFormat.compact`（无货币符号），同卡头部用 `money`（有符号且换汇），轴显示 `-13`、头显示 `-$12,345` |
| 11 | `LossAnalysisChart.swift:94-102` | 全部图例关闭后 `floor` 夹到 `-1.08`，两个轴标注都取整成 `-1`，得到一块空白矩形配两个相同标签。`CycleComparison.swift:442-443` 已用 `ContentUnavailableView` 处理同一情形 |
| 12 | `CompanyFinancialsView.swift:419-529/682/745-767` | 三张财务流向图用蓝/橙表达流入流出，**整页没有任何图例**；分段图还按 `index.isMultiple(of: 2)` 交替透明度（`:682`），诱导读者误判为类别划分 |
| 13 | `ManagementDeliveryView.swift:209-248` | 已兑现/部分兑现/未兑现/待验证只有纯文字，无角标无着色；卡片存在的意义就是回答"管理层做到了吗"，而四个汇总格全是同样的灰 |
| 14 | `InsiderTradesView.swift` 231 | `Text(trade.insider.capitalized)` 会把 McDonald 变成 Mcdonald、van der Berg 变成 Van Der Berg |
| 15 | `InsiderTradesView.swift:152-153/208/237` | 汇总表两列写死 112pt，无障碍字号下表头换行/截断，两个需要对比的列不再对齐；`details` 行 `.lineLimit(1)` 反而藏起了区分高管/董事的职衔 |
| 16 | `SectorRotationView.swift:90-91` | `.navigationTitle("")`，从两个标签页推入的同一个页面没有标题；该页三行免责声明是 10pt / 40% 不透明度（`:69-81`），而同样的句子在"如何阅读这张图" sheet 里是可读字号（`:127-129`） |
| 17 | `OptionsOIView.swift:502-506` | 全部方法论塞进一个约 420 汉字的 `.alert`；alert 正文不滚动，无障碍字号下最关键的"获取时间不是 OI 数据日期"会被裁掉且无法触及 |
| 18 | `StockChartsRotationView.swift:44-59`、`SectorRotationView.swift:197-206` | 首次加载失败与"无数据"不可区分；板块页把抓取失败报成"数据更新延迟" |
| 19 | `SectorRotationUIKit.swift:109-110`、`StockChartsRotationUIKit.swift` 24 | 两个 UIKit 画布在 `init` 里**一次性**取 9–11pt 字体（并按 `designWidth` 硬编码宽度），trait 变化只 `setNeedsDisplay()`。SwiftUI 外壳随字号放大、画布内文字冻结 |
| 20 | `StockChartsRotationView.swift:28-189`、`SectorRotationView.swift:59-79` | 两个轮动页所有标签用绝对点数（9–20pt），无 `@ScaledMetric`，正是低视力用户打开的那个界面最不响应字号 |
| 21 | `AnalystHistoryView.swift:143-147`、`EarningsHistoryView.swift:119/175`、`AnalystHistoryView.swift:178/209` | 混用 `.font(.system(size:))` / `.font(.title3.bold())` / `.monospacedDigit()`，绕过 `appNumber` 的字重与替代字形 |
| 22 | `CompanyFinancialsView.swift:58/61/126/132`、`InsiderTradesView.swift:61/68-71`、`VolumeProfileView.swift` 2549 | 从同一张研究卡打开的四个 sheet 有**三种关闭按钮**（图标 Label / 文字"关闭" / 裸 xmark）、**两种页面底色**（`systemBackground` vs `systemGroupedBackground`）、**两种页面内边距**（20 vs 16）。卡片本身是刻意统一的（`VolumeProfileView.swift:2610-2657`） |
| 23 | `AnalystConsensusView.swift:194/407`、`AnalystHistoryView.swift` 147 | 同一个分析师均值目标有三个名字：均价 / 平均目标 / 共识。而"共识"与该卡已经叫"评级分布"的评级共识撞名 |
| 24 | `ReturnsView.swift` 283、`ReturnsAnalyticsView.swift` 87、`UnderwaterAnalysisChart.swift` 21、`LossAnalysisChart.swift` 22、`HoldingContributionChart.swift` 19 | 同一个"收益"区块下的五个兄弟页默认区间分别是 1M / MAX / 1Y / 1Y / YTD |
| 25 | `CycleComparison.swift:259-264` | "对比年数"分段控件的 `1Y…5Y` 与共享词表的 `ChartTimeRange.fiveYears = "5Y"`（滚动五年窗口）同名不同义，间隔一次点击；且两个选择器都 `.labelsHidden()` |
| 26 | `DesignSystem.swift:1961-1972` | 区间选择器渲染 5 个格子但存在 10 个区间；**重复轻点已选中的格子会静默切换区间**（1M → 2M），而分段控件里点已选项普遍被理解为无操作。1D/2M/6M/5Y 只能靠发现"再点一次"才能到达，唯一说明是不可见的 `accessibilityHint`（`:1974-1982`） |
| 27 | `PolicyComposerView.swift:289-315` | 运行按钮在 `store.blocker != nil` 时用 `tertiarySystemFill` + 灰 `play.fill`——看起来是禁用，实际可点，点了只弹一个 4 秒后自动消失的提示 |
| 28 | `PolicyComposerStore.swift:483-487` vs `:459-464` | 同一个操作的两个出口行为相反：生成失败会把原文还回输入框，点"停止"则直接丢弃用户精心写的策略句子且无撤销 |
| 29 | `AIView.swift:2213-2233` vs `:2301-2337` | 同一个输入框两个变体：placeholder 一个是"询问你的投资组合"一个是"Ask AI"；标准变体的发送按钮在 `.disabled` 时仍是白字蓝底（看起来可用），浮动变体则会正确变淡 |
| 30 | `AIView.swift:93-97` vs `:811-835` | 清空对话的对话框写着"清空本机 AI 对话"、正文说"此操作只会删除保存在这台 iPhone 上的聊天记录"（读起来像清空全部），实际只删当前会话；而侧栏整划删除**没有任何确认** |
| 31 | `CSVImportView.swift:76-87` vs `:236` | 零数据行时主按钮仍可点，按钮旁边就显示"CSV 没有可导入的数据行。"；确认对话框走完，`importSelectedFile()` 首行 `guard ... else { return }` 静默返回——没有 spinner、没有报错、没有任何状态变化 |
| 32 | `CSVImportView.swift` 111 | 导入结果列表 `prefix(8)` 硬截断，头部却写着"已导入 N 个持仓"，没有"另有 N 项"或"查看全部" |
| 33 | `PerformanceHeatmapHero.swift:338-341` | 折叠态 hero 在纹理烘焙完成前 `overlay` 的 `if` 没有 `else`，而烘焙需要 `Task.sleep(100ms)` + `ImageRenderer`（`:104-119`）；首次进入性能页顶部约 250pt 是空白，烘焙失败则永久空白且无提示 |

---

## 5. 低优先级问题

| # | 位置 | 问题 |
|---|---|---|
| 1 | `TodayDetailView.swift:234-238` | `navigationDestination(isPresented:)` + `if let` 由两份状态驱动，`selectedSector` 为 nil 时会推出一个只有返回按钮的空页；应改用 `navigationDestination(item:)` |
| 2 | `SettingsView.swift:174-191` | 两个永久 `.disabled(true)` 的"即将开放"行与五个可用券商同卡同 chevron；其一以硬编码 `false` 判断版本，iOS 27 上文案会错 |
| 3 | `SettingsView.swift:596/797/803` | `@State` 缓存已渲染文案，切换语言后不更新 |
| 4 | `LineLimit(1)` 全项目 117 处 | 大量单行截断（`PortfolioView` 16、`VolumeProfileView` 15、`ReturnsView` 8…），配合 `minimumScaleFactor` 低至 0.5，在无障碍字号下把用户选的字号缩回去 |
| 5 | `RootTabView.swift:12/217` | 紧凑态标签按钮高度 40pt（常规 48pt），略低于 44pt 下限 |
| 6 | `RootTabView.swift:161-204` | 自绘悬浮 TabBar 未暴露为 tab bar 语义（无 `UIAccessibilityTraits` 的 tab 角色、无 `accessibilitySortPriority`） |
| 7 | `DesignSystem.swift:20-37` | `CatfolioDisplayAmountText` 在字号 token 体系之外自建字体（`size: 32` / `symbolSize: 20.64`），并在 HStack 上再叠 `.monospacedDigit()`；首页/收益页最大的那个数字与其余数字来源不同 |
| 8 | `SettingsView.swift` 1356 | `.verified`（"验证通过"）不是持久状态，`refreshStatuses()` 下次即降级为"已配置" |
| 9 | `AIView.swift` 1585、`DesignSystem.swift` 700 | 两处 `sensoryFeedback` 未受"触控反馈"偏好约束（全项目 23 处中 21 处已约束） |
| 10 | `CatfolioIOSApp.swift` 44 | 界面语言只注入 `\.locale`，不设 `AppleLanguages`；VoiceOver 会按设备语言而非 App 语言朗读 |
| 11 | `SettingsView.swift:30-33` | iCloud 脚注手写清单，应改为由 `CloudPreferences.synchronised` 生成，否则永远会漂移（§3.9） |
| 12 | `SettingsView.swift:128-355` | 设置根页无搜索无索引，十一个区块平铺；而设计稿 `settings-ios.html` 顶部是有"搜索设置"的 |
| 13 | 全项目 | 46 个 `View` 文件、**0 个 `#Preview`**；视觉走查只能靠 `--show-*` 启动参数与截图，缺预览使设计回归难以及时发现 |
| 14 | `PortfolioView.swift:872-880` | 今日卡片方向按钮 44×41（父容器 47pt），图标用 `.font(.system(size: 14))`，颜色写死 `rgb(17,17,17)` |

---

## 6. 无障碍专项

### 6.1 数据层没有可读替代

- `accessibilityRepresentation` 全 App **0 次**，`accessibilitySortPriority` **0 次**（111 个源文件）。
- 数据图表里至少 **4 处没有任何无障碍标签**，VoiceOver 只能读到零散子元素：`AnalystHistoryView.swift` 161、`AnalystHistoryView.swift` 185（目标价图与评级柱图）、`SectorPerformance.swift` 232（行业 ETF 走势）。`ReturnsAnalyticsView.swift` 的回撤曲线、`LossAnalysisChart` 与 `HoldingContributionChart` 有 `accessibilityLabel`，但同样没有 `accessibilityRepresentation`，即标签只是概览，**无法读到具体数值**。
- 与之对比，`OptionsOIView.swift:888-892` 做了正确的示范：`.accessibilityElement(children: .ignore)` + `label` + `value` + `accessibilityAdjustableAction`。这是全 App 唯一一个把图表数据真正暴露给 VoiceOver 的地方，应作为模板。
- `UIAccessibility.post` 全 App **1 次**（`SettingsView.swift` 2025）。复制成功、同步完成、筛选变化等操作不会播报，VoiceOver 用户必须重新聚焦才能知道发生了什么。
- `accessibilityValue` 25 处、`accessibilityHint` 34 处、`accessibilityElement` 61 处、`accessibilityHidden` 57 处——**标签层覆盖尚可，数据层基本空白**。

### 6.2 Dynamic Type

- 只有 **16 / 111** 个文件提到 `accessibilityReduceMotion`；**8 个文件有动画但完全不处理**（`UnderwaterAnalysisChart` 5 处、`LossAnalysisChart` 3 处、`HoldingContributionChart` 3 处、`IBKRFlexView` 2 处等）。
- 只有 **8 / 111 个文件** 引用 `dynamicTypeSize`，而全项目 **117 处** `.lineLimit(1)`、**49 处** `minimumScaleFactor`（最低 0.5，分布在 21 个文件）。
- 关键固定尺寸容器在无障碍字号下会挤压文字：`PortfolioView.swift:668/689/711/723/743`（17/39/20/106/326pt）、`VolumeProfileView.swift:961/991/1159`。`HoldingRow`（`PortfolioView.swift:2900-2916`）已经按 `isAccessibilitySize` 分支，说明正确模式已存在，这些是漏网的。
- 两个 UIKit 画布的字号在 `init` 里取一次（§4 #19），是 Dynamic Type 完全失效的最硬一处。

### 6.3 设备适配

- `horizontalSizeClass` / `userInterfaceIdiom` 全项目 **0 次**，而工程声明支持 iPad 四向。iPad 上卡片会横跨整个 1024pt 宽，自绘悬浮胶囊 TabBar 的 `padding(.horizontal, 20)` 在宽屏上会显得孤立。本轮未实机验证，但代码层面确实没有适配层。

---

## 7. 设计门禁为何是红的

`scripts/check_ios_design.py` 退出码 1，`v3_backend/tests/test_ios_design_rules.py` 的 `test_design_checker_passes` 失败。14 个文件、18 处违规：

**6 个文件共 27 处字体绕过字号 token**（检查器要求用 `Typography.number(size:)` / `Typography.text(size:)`）：

| 文件 | 处数 |
|---|---:|
| `StockChartsRotationView.swift` | 12 |
| `SecurityDebateView.swift` | 5 |
| `ResearchView.swift` | 4 |
| `SectorRotationView.swift` | 3 |
| `IsometricHeatmapLab.swift` | 2 |
| `SectorPerformance.swift` | 1 |

**8 处颜色字面量与 1 处量级阶梯越界**（括号内是脚本记录的预算）：

| 文件 | 越界 | 预算 |
|---|---|---:|
| `SectorRotationUIKit.swift` | 16 处颜色 | 0 |
| `CycleComparison.swift` | 12 处颜色 + 1 处 `/1_000_000` 阶梯 | 0 |
| `SettingsTemplate.swift` | 5 处颜色 | 0 |
| `AIView.swift` | 3 处颜色 | 2 |
| `HoldingContributionChart.swift` | 3 处颜色 | 0 |
| `ReturnsView.swift` | 17 处颜色 | 9 |
| `LossAnalysisChart.swift` / `OptionsOIView.swift` / `ResearchView.swift` / `StockChartsRotationUIKit.swift` / `UnderwaterAnalysisChart.swift` | 各 1 处颜色 | 0 |

**检查器还有三类它看不见的漏洞**，这也是 §3.1 能发生的原因：

1. **只认 `Color(red:)` / `Color(white:)` / `Color(hue:)`**。`Color.red`、`Color.green`、`Color.orange` 等内建色共 **71 处**完全不报（`AIView.swift` 1663、`PortfolioView.swift` 2815、`AnalystConsensusView.swift` 371…）。
2. **只认 `design: .rounded`**。`.font(.system(size:))` 这类**不带 design 参数**的写法不报，而全 App 有 **71 处**（`PolicyComposerView` 10、`StockChartsRotationView` 13、`VolumeProfileView` 8…）。这些字号既不过 token、也不上 `@ScaledMetric`。
3. **只认 `/ 1_000`**。没有百分比与日期格式化的一致性检查，所以 `String(format: "%.1f%%")` 等 54 处与 `.formatted(` 缺显式 locale 的 **89 处**都不在门禁范围内。

**另外三项**（同一类系统性缺口，建议一并纳入门禁而非逐个修）：

| 维度 | 现状 |
|---|---|
| 圆角 | 17 个不同取值；`CatfolioStyle` 只定义 `cardRadius: 20` / `controlRadius: 12`，但 `SettingsTemplate` 用 `cardRadius: 24`，实际还混用 22/16/18/14/26/17/13 等 |
| 内边距 | 35 个不同取值（含 1/3/5/7/9/11/13/15/17 等奇数） |
| 间距 | 23 个不同 `spacing:` 取值（4/5/6/7/9/13/14/17/22/26…） |

**修复建议**：先让门禁恢复绿色（把 27 处字体与 18 处颜色收敛，或把确实为设计需要的项写进预算并**只在预算下降时更新**），再把上面三类盲区补进 `check_ios_design.py`，否则同一个坑会再踩一次。`SettingsTemplate` 与 `CatfolioStyle` 两套几何 token（16 vs 20 页面内边距、24 vs 20 圆角）需要先合并成一套再谈统一。

---

## 8. 建议的修复顺序

**第一批（阻断，建议下个构建前）**

1. `HoldingsHeatmapView.swift:591-594` 亏损符号（§2.1）
2. `IsometricHeatmapLab` 合成数据要么 `#if DEBUG`，要么加常驻披露 + 标题（§2.2）
3. IBKR 凭证读写路径统一（§2.3）
4. `DisplayFormat.percent` 加 `isFinite` 保护（§3.4，一行修复消除一整类 `NaN%`）
5. `scripts/check_ios_design.py` 恢复绿色，让回归测试重新可信（§7）

**第二批（高，本迭代）**

6. 语义色收敛：合并 `positive`/`danger` 与 `gain`/`loss`；`gainDefault` 限制到无 `ColorScheme` 的上下文；分类色板与绿/红族解耦；VTI 换色；Call/Put 与板块身份另立色对（§3.1、§3.2）
7. `StatusNotice.error` 改用红，或把成功的 `StatusNotice` 显式传 `.success`（§4 #1、§3.7）
8. 状态机补齐：首页空组合、历史错误重试、板块失败通道、收入分部资源失败、持仓详情陈旧时间戳（§3.3）
9. 图表：给六个 `bottomHeight: 0` 的页面恢复时间轴并删掉不可达的日期格式化器；换掉 DIA/IWM 淡色；端点胶囊与 Y 轴刻度避让；Y 轴刻度取整去重（§3.5）
10. 指下目标不足 44pt 的六处 + 热力图可点阈值（§3.6）
11. AI 停止按钮与 provider 去向披露；SnapTrade 保留一个可用出口；凭证显隐统一到 `SettingsFieldButton`（§3.7）
12. 研究标签页补个股研究与"今天值得关注"入口（§3.8）

**第三批（中，排期）**

13. 无障碍数据层：给所有数据图表加 `accessibilityRepresentation` 或"读数值"动作，按 `OptionsOIView.swift:888-892` 的模式；关键操作加 `UIAccessibility.post` 播报
14. Dynamic Type：把两个 UIKit 画布的字体改为按 trait 重建；清掉 27 处绝对字号；把固定高度容器改成 `minHeight` + `@ScaledMetric`
15. 几何 token 合并（`SettingsTemplate` ↔ `CatfolioStyle`）并统一 sheet chrome
16. 术语与格式：分析师目标价统一命名；ETF 基准标题走 `L10n`；补上五处硬编码英文；日期与货币统一传语言 locale
17. iPad 布局适配，或从工程里移除 iPad 支持声明

**第四批（低）**

18. 设置搜索与索引；iCloud 脚注改为自动生成；重置进度与备份恢复入口；"数据匹配与去重"加确认；首启清单

---

## 9. 逐条证据索引

| 文件 | 本轮引用的行 |
|---|---|
| `PortfolioView.swift` | 11-24, 320-334, 386-392, 504-533, 620-631, 655-723, 762-780, 819-852, 1413-1428, 1469-1486, 1629-1646, 2066-2089, 2900-2916, 2994-3008, 3069-3075, 3090-3250 |
| `TodayDetailView.swift` | 194-254, 210-217, 234-238, 311-341, 219 |
| `HoldingsHeatmapView.swift` / `HoldingsHeatmapTile.swift` | 553, 591-598, 603-622, 151-153, 215-221, 354-373 |
| `PerformanceHeatmapHero.swift` | 104-119, 330-360 |
| `CSVImportView.swift` | 76-87, 97-111, 169-182, 236 |
| `ETFLookThroughView.swift` / `Models.swift` | 32, 48, 191 / 1040 |
| `ReturnsView.swift` | 39, 283, 450-476, 788, 910, 994-1030, 1086-1130, 1138, 1156-1191, 1226-1251, 1253, 1390, 1627, 1787-1832 |
| `StandardLineChart.swift` | 29, 467-564, 595-604, 679, 1876-1879, 1906-1931, 2226-2253, 2357, 2363 |
| `ReturnsAnalyticsView.swift` | 78, 87, 111-141, 167-185, 245, 288-354, 400-443, 578-633 |
| `HistoryView.swift` | 226-248, 389-392, 431-463, 501-602, 737, 790-818, 940-948, 1197, 1386 |
| `UnderwaterAnalysis.swift` / `UnderwaterAnalysisChart.swift` | 93-94, 160-212 / 21, 46-53, 101, 165-172, 219, 269, 394, 407, 418-422, 522-537, 551, 571 |
| `LossAnalysisChart.swift` | 22, 57-72, 94-112, 127, 132-215, 258, 295-300, 363-372 |
| `HoldingContributionChart.swift` | 19, 57, 108, 126, 178-221, 326-336, 431-435 |
| `CycleComparison.swift` | 102-109, 190, 259-264, 288-301, 390, 413-443, 484-558 |
| `SectorPerformance.swift` / `SectorRotationUIKit.swift` | 11-232 / 91-137, 206-227, 310-333, 381 |
| `SectorRotationView.swift` / `SectorRotation.swift` | 44-99, 127-141, 155, 173, 189 / 26-34 |
| `StockChartsRotationView.swift` / `StockChartsRotationUIKit.swift` | 19-72, 105-189 / 15-24, 38, 169, 182 |
| `OptionsOIView.swift` | 80, 502-568, 594, 630-655, 685-750, 774, 805-808, 822-892, 914-952, 1033-1082 |
| `PolymarketMarketsView.swift` | 405-537, 555-616 |
| `ResearchView.swift` | 75-166, 184, 271-315, 413-522, 553-604, 605-774, 844-958 |
| `AnalystConsensusView.swift` | 194, 212-232, 270-279, 351, 366-412 |
| `AnalystHistoryView.swift` | 14-34, 70, 90-147, 161-225 |
| `EarningsHistoryView.swift` | 32-45, 71-78, 85, 100-121, 175-191 |
| `CompanyFinancialsView.swift` | 58-75, 100, 129-161, 189-195, 244, 297-317, 419-529, 675-767 |
| `InsiderTradesView.swift` | 22-71, 143-237, 218, 303 |
| `IndustrySentimentView.swift` | 72-83, 141-145, 187-233, 279-285 |
| `ManagementDeliveryView.swift` | 142-175, 209-288 |
| `VolumeProfileView.swift` | 182-241, 605-747, 816, 961-1159, 1498, 1760-1856, 1888-1941, 2039-2040, 2239-2414, 2549-2657, 2884-2919, 3018, 3141, 3805, 4031, 4336-4344 |
| `IsometricHeatmapLab.swift` | 44-45, 118-151, 184, 455-459 |
| `RootTabView.swift` | 6-15, 80-159, 161-204, 231-349 |
| `DesignSystem.swift` | 13-37, 96-114, 363-378, 653-709, 776-784, 788-1043, 1271-1746, 1791-2035, 2035-2098, 2535-2711 |
| `SettingsView.swift` | 30-33, 128-355, 392-411, 527-533, 596, 609-697, 761-807, 907-1034, 1141-1187, 1273-1345, 1371-1439, 1489-1530, 1556-1604, 1790-1856, 2025, 2087, 2151-2179 |
| `SettingsTemplate.swift` | 21-107, 120-200, 288-330, 369, 873, 1056-1072 |
| `CloudPreferences.swift` | 31-43 |
| `Localization.swift` | 3-34, 119-121 |
| `APIClient.swift` | 613-653, 790, 1364 |
| `Typography.swift` | 20-139, 140-175, 180-230, 255-306, 308-355, 361-419 |
| `CatfolioIOSApp.swift` | 36, 44 |
| `PolicyComposerView.swift` | 88-151, 213-346, 425-594, 623-779, 853, 944-1008, 1093-1183, 1244-1337 |
| `PolicyComposerStore.swift` | 459-487 |
| `AIView.swift` | 78-144, 192-197, 240-362, 500-581, 698-835, 1204-1280, 1345-1416, 1540-1585, 1663, 1814, 1878, 2213-2337, 2401-2465, 2686-2696 |
| `Trading212View.swift` / `SnapTradeView.swift` | 36-165, 226-313 / 33-169 |
| `MoomooOAuthView.swift` / `IBKRFlexView.swift` | 27-276 / 45-92, 152-257, 316-402 |
| `NumericAlternatesTests.swift` | 60-92（用于剔除误报） |
| `v3_backend/tests/test_ios_design_rules.py` | 全文件 |
| `scripts/check_ios_design.py` | 全文件 |

---

## 10. 结论

这份审查看到的是一个**功能做得比界面认真得多**的 App。计算引擎、账本、错误文案（"已达到 FMP 的频率上限（429）。这不是密钥或权限问题…"这类写法在全项目里比比皆是）、破坏性操作确认、本地化覆盖，都明显高于同类产品的平均水平；`OptionsOIView` 的状态处理和 `ResearchView` 的四态处理，可以直接当作其余 100 个文件的模板。

问题集中在三处：

1. **设计系统"写了但没关住"。** `DESIGN.md` 把规则写得非常清楚，门禁也造出来了——但门禁现在是红的，而且它有三类结构性盲区（内建色、无 design 参数的字体、百分比与 locale）。结果是 `gain`/`loss` 这一对核心语义色在全 App 有 6 绿 4 红，其中两种绿在浅色模式下作正文不合格，VTI 基准线被涂成保留的亏损红。
2. **状态机没有统一。"** 空 / 加载 / 错误 / 陈旧"四种状态在这 111 个文件里各写各的：`OptionsOIView` 做到满分，首页空组合永久转圈，历史错误态没有重试，板块失败没有错误通道，收益页切换区间会画出窗口外的旧数据。这是读者最容易误判的一类问题——把"没有数据"读成"数据是零"。
3. **无障碍只做到了标签层。** `accessibilityLabel` 遍布代码，但 `accessibilityRepresentation` 和 `accessibilitySortPriority` 是 0，图表数据对 VoiceOver 基本不可达；Dynamic Type 在 8 个有动画的文件和两个 UIKit 画布上完全不起作用。

**最需要尽快处理的一条**不是最显眼的那条：`DisplayFormat.percent` 缺 `isFinite` 保护（[DesignSystem.swift 2703](../../../CatfolioIOS/CatfolioIOS/DesignSystem.swift#L2703)）。`money` 和 `compact` 都有这个保护，只有它没有——一行改动可以消掉一整类 `NaN%` 与 `-SPY NaN%`，而它现在正出现在首页主卡片上。
