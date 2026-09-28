# Catfolio iOS 全构造盘查报告

> 核对对象：`CatfolioIOS/`（版本 1.0，Build 10，2026-09-15 工作区）
> 核对范围：App 框架、页面结构、全部功能、业务逻辑、券商同步链路、AI 流式实现
> 核对方式：6 路并行深挖（框架 / 券商 / AI / 持仓收益 / 研究 / 设置与 Policy）+ 复核，全部结论取自当前工作树源码
> 引用规范：关键结论标注 `文件:行号`；公式逐字摘录；区分「已实现且 UI 可达」「有代码未接线/死代码」「文档声称但代码中未找到」
> 配套附录：`docs/ios-deep-dive/holdings-returns-history.md`（838 行，持仓/收益/历史的逐行细节）

> **⚠️ 三处最重要的纠正**（本报告与既有文档/口头描述不一致处）
> 1. 「个股正反方辩论 / 多智能体辩论」**不存在**——实现是同模型两趟串行 + 逐字引文校验，prompt 明文禁止 bull/bear。
> 2. 「研究 tab 装全部研究功能」**不成立**——研究域 19 个模块里只有 4 个挂在研究 tab。
> 3. 「后台运行」是 **iOS 26 独占**（部署目标却是 iOS 18），且策略引擎的交易日历**只覆盖 2026 年**，2027 年起无法运行。

---

## 0. 一页速览

| 维度 | 结论 |
|---|---|
| 形态 | 纯原生 SwiftUI App，**单 target、零第三方依赖**，无后端常开、无 OpenD/Gateway |
| 规模 | App 源码 **111 个 Swift 文件 / 69,908 行**；测试 **52 个文件 / 11,844 行** |
| 系统 | 最低 iOS 18，Swift 5；iOS 26 使用 Liquid Glass，旧系统走材质回退 |
| 版本 | `MARKETING_VERSION = 1.0`、`CURRENT_PROJECT_VERSION = 10` |
| 导航 | 自绘悬浮 TabBar，4 个 tab（持仓 / 收益 / 研究 / 设置）+ 全局 AI 悬浮球 |
| 数据 | 全部本机：Application Support 文件 + Keychain；iCloud KVS 只同步白名单偏好 |
| 页面 | 4 个主页面 + 个股详情（约 4,400 行的巨型 Sheet）+ 设置（约 2,200 行） |
| 券商 | Trading 212、Moomoo（OAuth）、IBKR Flex、SnapTrade 四家直连 + CSV 导入 |
| AI | 五档 provider：自动 / Apple 本地 / Codex / DeepSeek / OpenRouter，支持流式 + 思维链 |
| 后端关系 | 与仓库中的 FastAPI/Web 完全解耦，构建运行不依赖 Web 目录 |
| 最大风险 | 巨型文件（`LocalServices.swift` 4,992 行）、单 target 无模块化、**同一口径多处实现且已漂移**、**3 套已完成引擎从未接线**、**数据时效性对用户不可见** |
| 死代码 | 23 个未引用类型 + 一批死方法/死字段；全项目 `TODO/FIXME/HACK` **0 命中**（债务不靠注释标记） |

---

## 1. 工程与构建

### 1.1 Target 与配置

| 项 | 值 | 来源 |
|---|---|---|
| 工程 | `CatfolioIOS/CatfolioIOS.xcodeproj` | — |
| Target | `CatfolioIOS`（App）、`CatfolioIOSTests`（单测） | `project.pbxproj:665,682` |
| Bundle ID | `com.catfolio.ios`（测试 `com.catfolio.ios.tests`） | `project.pbxproj:1051,983` |
| Team | `2G5PCQU652` | `project.pbxproj:1042` |
| 部署目标 | iOS 18.0 | `project.pbxproj:1045` |
| Swift | 5.0 | `project.pbxproj:1056` |
| 设备族 | iPhone + iPad；iPhone 仅竖屏，iPad 四向 | `Info.plist` |
| 显示名 | Catfolio | `Info.plist` |
| 图标 | `AppIcon.icon`（Icon Composer）+ `Assets.xcassets/AppIcon.appiconset` | — |
| 签名方式 | Automatic | `project.pbxproj:1039` |

### 1.2 依赖：确认零第三方

对全部源码的 `import` 做统计，只出现系统框架：

```
58 Foundation      53 SwiftUI        18 UIKit        11 CryptoKit
10 Observation      6 Charts          3 UniformTypeIdentifiers
 2 WebKit           2 Security        2 SafariServices
 2 FoundationModels 1 UserNotifications / OSLog / Network
 1 ImageIO / CoreText / CoreImage / CoreGraphics / CoreFoundation
 1 BackgroundTasks
```

`project.pbxproj` 中 `XCRemoteSwiftPackageReference` / `XCSwiftPackageProductDependency` 计数为 **0**，无 CocoaPods/Carthage 文件。**结论：完全自包含，无任何外部包管理依赖。**

### 1.3 能力声明

- `CatfolioIOS.entitlements`：**只有一项** `com.apple.developer.ubiquity-kvstore-identifier`（`$(TeamIdentifierPrefix)$(CFBundleIdentifier)`），**没有 CloudKit 容器键**。这从工程配置层面确认：设置页的 iCloud 同步就是 `NSUbiquitousKeyValueStore`，不是 CloudKit / iCloud Documents。
- **没有注册任何 URL scheme**：`Info.plist` 无 `CFBundleURLTypes`，全仓无 `onOpenURL` 或 `catfolio://`。Moomoo 与 Codex 都走 **device-code + 轮询**式流程，不需要 redirect URI；后续若要接真正的 redirect-URI OAuth，需先补 URL scheme。
- `Info.plist`：
  - `BGTaskSchedulerPermittedIdentifiers = com.catfolio.ios.policy.*`
  - `UIBackgroundModes = [processing]`
  - `ITSAppUsesNonExemptEncryption = false`
  - `UIApplicationSupportsMultipleScenes = false`
  - `GENERATE_INFOPLIST_FILE = NO`（使用手写 plist）

### 1.4 目录组织

```
CatfolioIOS/
├─ CatfolioIOS.xcodeproj/         工程（含 xcodecloud manifest）
├─ CatfolioIOS/                   App 源码 111 个 .swift（扁平，无子目录分组）
│  ├─ Assets.xcassets/            图标与 Tab 图标（SVG 单色模板）
│  ├─ AppIcon.icon/               Icon Composer 图标源
│  ├─ Resources/                  大体积 JSON 资源 + 1077 个股票 logo
│  ├─ en.lproj / zh-Hans.lproj/   各 2,402 条本地化 key
│  ├─ Info.plist / *.entitlements / PrivacyInfo.xcprivacy
│  └─ PortfolioLoadRipple.metal   Metal 着色器
├─ CatfolioIOSTests/              52 个 XCTest 文件
├─ scripts/                       资源生成脚本
├─ design-qa-assets/              设计走查素材
└─ build/                         DerivedData（构建产物，非源码）
```

**结构特征：App 源码完全扁平**，111 个文件平铺在同一目录，仅靠命名前缀区分领域（`Policy*` 11 个、`Sector*`/`StockCharts*`、`Management*` 等）。

---

## 2. App 框架

### 2.1 启动链路与依赖注入

```
CatfolioIOSApp (@main, 61 行)
└─ @State AppModel()                     ← 唯一全局状态容器
   └─ RootTabView()
      ├─ .environment(model)             ← 向下注入
      ├─ .environment(\.locale, …)       ← 语言
      ├─ .tint(CatfolioTheme.accent)
      ├─ .fontDesign(.rounded)
      ├─ .preferredColorScheme(…)
      ├─ .task { ReferenceCatalogs.warm() }
      ├─ .task { CloudPreferences.start() }
      └─ .task { PublicInvestorPreferences.migrateDemoSelectionIfNeeded() }
```

`CatfolioIOSApp.swift:4-60` 的职责非常薄：启动场景、注入环境、注册三个后台预热任务。它在 `DEBUG` 下还支持一个隔离测试宿主（`CATFOLIO_RESEARCH_TEST_HOST=1` 时渲染空视图，`CatfolioIOSApp.swift:26-32`），避免公开新闻类测试在真机上触发组合刷新与云偏好。

**依赖注入方式**：没有 DI 容器。`AppModel` 通过 `@State` 创建、`@Environment` 注入；其他服务（`LocalPortfolioStore.shared`、`PublicInvestorSimulationStore.shared`、`PortfolioPresentationCache.shared`、`CodexOAuthClient` 等）全部走单例或静态方法。`AppModel.init` 接受可注入参数（`defaults`、`publicInvestorStore`、`personalDocumentLoader`、`presentationCache`），这是为测试预留的唯一注入点（`APIClient.swift:77-99`）。

### 2.2 导航结构

导航**不是**系统 `TabView` 的默认样式，而是自绘底栏：

- `RootTabView.swift:80-132` 用 `TabView` 承载 4 个页面，但 `.toolbarVisibility(.hidden, for: .tabBar)` 隐藏系统 TabBar。
- 底栏由 `navigationBar(in:)`（`RootTabView.swift:161-204`）自绘：一个胶囊里放 4 个按钮，右侧独立放 AI 悬浮球。
- 每个 tab 各自包一个 `NavigationStack`（`tabPage(_:content:)`，`RootTabView.swift:136-159`），保证一个 tab 的标题/推入页面不会串到另一个 tab。
- AI 助手是该 tab 内 `navigationDestination` 的推入目标，并使用 `.navigationTransition(.zoom(sourceID: "ai-bubble", in: zoom))` 从悬浮球做 zoom 转场（`RootTabView.swift:147-156`）。
- iOS 26 用 `glassEffect(.regular.interactive(), in: Capsule())`，旧系统 `.ultraThinMaterial` 回退（`RootTabView.swift:340-348`）。
- 滚动时底栏自动收起：`tracksRootTabBarScroll` 修饰符累积滚动位移，超过 12pt 阈值切换 compact 态（`RootTabView.swift:273-338`），并尊重 `accessibilityReduceMotion`。

**启动参数即 deep-link**（`RootTabView.swift:35-52`）：`--show-returns-page`、`--show-heatmap`、`--show-policy-composer`、`--show-research-tab`、`--show-settings`、`--show-local-services`、`--show-local-service-*`、`--show-ai`、`--demo-ai-open`、`--probe-news`、`--run-foundation-checks`。这是自动化截图与回归测试的主要入口。

此外还有 **40+ 个参数分散在各视图的 `init`/`body`**，而非集中在一处：`ReturnsView`（`--show-returns-1d/1w/1m/…`、`--show-cash-flow`、`--show-mwr`）、`PortfolioView`（`--show-volume`、`--show-etf`、`--demo-security-transition`、`--show-chart-*`、`--group-heatmap-by-sector`）、`SettingsView`（`--show-sector-rotation`、`--show-screener`、`--preview-options-oi` 等）。

> **⚠️ 风险**：这些后门参数多数**不在 `#if DEBUG` 内**（如 `ReturnsView.swift:9,13,116,266-282`、`PortfolioView.swift:284,430-448,550,1308,1941-1965`、`SettingsView.swift:115-121`），Release 构建同样会解析并可能触发演示数据分支；`PolicyRunCoordinator.swift:207-208` 的 QA 故障注入在 Release 也可达。

### 2.3 状态与偏好体系

**全局状态**集中在 `AppModel`（`APIClient.swift:4-99`），`@Observable @MainActor`。它持有：组合概览、持仓、资金曲线、基准对比、收益分析、账户列表与选择、模拟模式开关、加载/错误态、以及大量 `@ObservationIgnored` 的请求代次计数器与缓存。

关键设计：**每个刷新路径都有 generation 计数器**（`portfolioRequestGeneration`、`returnsRequestGeneration`、`returnsAnalyticsRequestGeneration`、`returnsPageRequestGeneration`、`dailyChangesRequestGeneration`、`portfolioSourceGeneration`），过期响应直接丢弃，避免旧请求覆盖新状态（`APIClient.swift:52-65,103-115`）。

**偏好持久化**分两类：

| 存储 | 内容 | 代码 |
|---|---|---|
| `UserDefaults` | 显示币种、公司名显示、语言、外观、触感、AI provider、OpenRouter 模型、账户选择、模拟模式等 | `@AppStorage` + `AppModel.modeDefaults` |
| Keychain | API Key、券商凭证、OAuth token、Codex 凭证 | `KeychainStore.swift` |
| iCloud KVS | 仅白名单偏好（外观、币种、公司名、触感、排序、部分研究/选股规则） | `CloudPreferences.swift` |

**明确不同步**：个人账本、券商凭据、账户选择、模拟模式、语言偏好。iCloud 开关**每台设备独立、默认关闭**（`CloudPreferences`、`SettingsView`，见 `docs/ios-icloud-preferences.md`）。

### 2.4 设计系统

`DesignSystem.swift`（2,742 行）是视觉单一事实来源，包含：

- `CatfolioTheme` / `CatfolioPalette` / `CatfolioStyle`：颜色、语义色、分类色。
- `DisplayCurrency`（九种币种）、`AppAppearance`、`CompanyNameDisplay`、`ChartDateRange`、`ChartInteractionStyle`。
- 图表交互基元：`ChartInteractionOverlay`、`ChartSeriesInteractionMask`、`ChartTimeRangePicker`。
- 卡片与按钮：`ContentCard`、`GlassPrimaryButton`、`GlassChoiceBar`、`StatusNotice`、`ToolbarIconButton`。
- **AssetLogo 体系**：`AssetLogoRepository` / `AssetLogoImageCache` / `AssetLogoLayout` / `AssetBrandColor`，对应 `Resources/AssetLogos/` 的 1,077 个 PNG 与 `brandfetch-symbols.json`。
- 数字格式化：`CurrencyFormatterCache`、`DisplayFormat`、`ContributionStripePattern`。

`Typography.swift`（419 行）：`TypeScale`、`Typography`、`CurrencySemanticFont`、`NumericAlternates`、`ScaledFont`，处理等宽数字与货币符号替代字形。

**核实到的具体 token**：

- `CatfolioStyle`：`pageHorizontalInset = 20`、`cardRadius = 20`、`controlRadius = 12`。
- `CatfolioTheme`：`accent = blue500`、`positive = green500`、`danger = rose500`、`warning = orange500`；**增益/亏损必须成对定义**——`gain(for:)` / `loss(for:)`（注释明确「曾有 9 种绿 5 种红」），无 scheme 场景才用 `gainDefault` / `lossDefault`。
- `CatfolioPalette`：全色谱 + 4 组渐变 + 业务色（`contributionGreen`、`dividendSeries`、`tradeBuy/tradeSellLight/Dark`、`statementInflow/Outflow`、`securityPriceLine`）。
- `DisplayFormat`：`money` 含 GBX→GBP（÷100）与「>100 万去小数」；`compact` / `compactMoney` 的后缀**随语言**——中文用 万/亿/万亿，英文用 K/M/B/T。DESIGN.md 规定「数字只能经 `DisplayFormat` 缩写」。
- `TypeScale`：12 档（display 32 → nano 10），每档带 Dynamic Type 档位、`numberWeight`（数字比正文重一档）、`lineSpacing`、`capsTracking`（约 6%）。
- 字体只允许在 token 文件构建（DESIGN.md），全局 `.fontDesign(.rounded)`；早期自带字体（Montserrat）已移除，pbxproj 残留空 `Fonts` group。
- **玻璃回退没有单一抽象**：`#available(iOS 26.0, *)` 全项目 **39 处、18 个文件**，`RootTabView` 有一份 private `navigationGlass`，`DesignSystem` 另有一套，`GlassChoiceBar` 与 `GlassPrimaryButton` 各自实现，回退外观一致性全靠人工对齐。

`DESIGN.md` 规定色彩可写位置、语义色/分类色/品牌色、字号阶梯与数字排版规则。

### 2.5 本地化

- `Localization.swift`（163 行）：`AppLanguage`（跟随系统 / 简体中文 / English）、`L10n`、`ContentLanguage`。
- 资源：`en.lproj/Localizable.strings` 与 `zh-Hans.lproj/Localizable.strings`，**各 2,402 条 key**，双语 key 一致。
- 动态文案用 `L10n.text("已同步 \(count) 个持仓")`；代码/枚举 rawValue/图表系列 ID 不翻译。
- 校验脚本：`scripts/check_ios_localizations.py`（仓库根 `scripts/`），测试 `LocalizationTests.swift`（337 行）。
- 内容语言（新闻、预测市场、AI 输出）跟随界面语言，历史缓存不自动重译。

### 2.6 后台与性能设施

| 设施 | 作用 | 代码 |
|---|---|---|
| `PolicyBackgroundService` | `BGTaskScheduler` 注册 `com.catfolio.ios.policy.*`，策略定时运行 | `PolicyBackgroundService.swift`（70 行） |
| `PortfolioPresentationCache` | 首页结果落盘，冷启动先恢复再刷新 | `PortfolioPresentationCache.swift`（125 行） |
| `ReferenceCatalogs.warm()` | 启动预热大体积参考目录 | `ReferenceCatalogs.swift`（26 行） |
| generation 计数器 | 取消/丢弃过期异步结果 | `APIClient.swift` |
| 历史下载并发上限 | 账本历史最多同时下载 4 只证券 | 审计 FIXES #16 |
| `PortfolioLoadRipple` + `.metal` | 首页加载波纹动画（Metal 着色器） | `PortfolioLoadRipple.swift` |
| `SmoothReveal` | AI 流式打字机节流（约 30fps） | `AIStreaming.swift:81-90` |

---

## 3. 数据层与持久化

### 3.1 分层

```
视图层        PortfolioView / ReturnsView / ResearchView / SettingsView /
              VolumeProfileView(个股详情) / AIView
   │  @Environment(AppModel)
状态层        AppModel（APIClient.swift）—— 请求代次、缓存、账户/模式编排
   │
服务层        LocalServices.swift（4,992 行，本机数据总线）
              ├─ LocalMarketDataClient        行情（FMP / Massive / Yahoo 回退）
              ├─ LocalHistoricalPriceCache    历史日线缓存
              ├─ LocalIntradayPriceCache      盘中缓存
              ├─ LocalVolumeBarCache          成交量分布缓存
              ├─ LocalETFLookThrough          ETF 穿透
              ├─ LocalFXImpactCalculator      汇率影响
              ├─ LocalAIClient                AI 编排
              ├─ PortfolioEventResearchClient 事件研究
              ├─ LocalPortfolioAttentionEngine 组合关注引擎
              └─ CodexOAuthClient / Apple 本地模型
账本层        LocalPortfolioStore.swift（2,705 行）→ LocalPortfolioEngine
              LocalPortfolioDocument / LocalTransactionRecord / LocalPositionRecord
记忆层        KeychainStore · PortfolioPresentationCache · LocalChatStore
              CloudPreferences · 各功能独立缓存
```

### 3.2 AppModel 的方法面（按用途分类）

| 类别 | 方法 |
|---|---|
| 组合刷新 | `refreshPortfolio(refreshMarketData:)`、`refreshReturns()`、`refreshReturnsPage()`、`refreshReturnsAnalytics()`、`refreshHoldingDailyChanges()` |
| 详情数据 | `cachedHoldingDetail(for:)`、`volumeProfile(for:…)`、`securityPriceHistory(for:)`、`marketPriceHistory(…)`、`holdingDetailAccountContext(for:)` |
| AI | `loadBriefing()`、`askAI(_:)`、`streamAI(_:)`、`rejudgeAttention(…)`、`followUpAttention(…)`、`portfolioAttention()` |
| 账户 | `selectBroker(_:)`、`selectAllAccounts()`、`toggleAccount(_:)`、`renameAccount(_:to:)`、`deleteAccount(_:)`、`registerPendingAccount(…)`、`accountNames(…)` |
| 导入 | `importCSV(…)`、`importTrading212(…)`、`importMoomoo(…)`、`importSnapTrade(…)`、`importIBKR(…)` |
| 交易流水 | `transactions(for:)`、`activityLedger()`、`addHistoricalTransaction(…)`、`deduplicateTransactions(for:)` |
| 模式 | `setPortfolioMode(enabled:selection:)`、`portfolioSource` |
| 其他 | `loadETFLookThrough(basis:)`、`resetLocalPortfolio()`、`holdingValueHistory(cachedOnly:)`、`fixedShareHistory(cachedOnly:)` |

### 3.3 本机存储路径清单（源码核实）

从 `appendingPathComponent` 汇总，落盘位置包括：

**Application Support / Catfolio 相关**
- 账本与快照：`LocalPortfolioStore` 管理的账户账本、每日市值/成本快照
- 首页呈现缓存：`Application Support/Catfolio/HomePresentation/`（README + `PortfolioPresentationCache`）
- 证券异动：`Catfolio/security-price-moves-v1.json`
- 参考缓存：`catfolio-market-history-units-v2.json`、`catfolio-intraday-history-units-v2.json`、`catfolio-volume-bars-units-v2.json`、`catfolio-fundamentals.json`、`catfolio-company-financials.json`、`catfolio-sec-tickers.json`、`catfolio-polymarket-markets.json`
- 券商同步检查点：`trading212-history-sync.json`、`trading212-dividend-sync.json`、`trading212-interest-sync.json`
- 功能快照：`InsiderTrades/snapshots-v3.json`、`EarningsHistory/snapshots-v1.json`、`analyst-consensus-v1.json`、`industry-sentiment.json`、`options-oi-yahoo-v1-<key>.json`
- logo 磁盘缓存：`image-stock/<symbol>.png`
- 公开投资者模拟：`Application Support/InvestorSimulation/`
- 重置备份：`portfolio-<reason>-<UUID>.json`
- 账户数据问题：`issues-<accounts>.json`

**缓存目录（可被系统清理）**
- `foundation-regression.txt`（Debug 回归报告）

**Keychain**
- `catfolio.fmp.api-key`、`catfolio.massive.api-key`、`catfolio.deepseek.api-key`、`catfolio.openrouter.api-key`、`catfolio.finnhub.api-key`
- 券商凭证与 OAuth token（Trading 212 / Moomoo / IBKR / SnapTrade）
- Codex 凭证 `catfolio.codex.oauth-credentials`、pending login

**UserDefaults（非机密）**
- `catfolio.openrouter.model`、`catfolio.ai.provider`、币种/语言/外观、账户选择、模拟模式开关等

**偏好读取规模**：全项目 `@AppStorage` **77 处、分布在 23 个文件**，且**没有任何 `@SceneStorage`**。关键 key 定义点：`catfolio.language`（`Localization.swift:9`）、`catfolio.displayCurrency`（`DesignSystem.swift:1056`）、`catfolio.appearance`（`:1092`）、`catfolio.companyNameDisplay`（`:1117`）、`catfolio.haptics`（`:1341`）、`catfolio.ai.provider`（`LocalServices.swift:83`）、`catfolio.activeBroker` / `selectedAccounts` / `fakeDataMode`（`APIClient.swift:70-75`）、`returns.comparisonBenchmarks`（`Models.swift:584`）、`research.evidence.*` 与 `research.signals.*`（`Models.swift:783-785,836-844`）、`news.*`（`NewsSources.swift:56-58`）。

**文件保护与备份排除不统一**：

| 项 | 现状 |
|---|---|
| 文件保护等级 | 三档混用：`.completeFileProtection`（账本、聊天、首页缓存、ManagementDelivery、Policies）、`.completeFileProtectionUnlessOpen`（OI、分析师、盈利、内幕、轮动）、`.completeFileProtectionUntilFirstUserAuthentication`（PolicyRuns） |
| `isExcludedFromBackup` | **全项目仅 3 处**：首页呈现缓存（`PortfolioPresentationCache.swift:103`）、管理层兑现（`ManagementDeliveryClient.swift:38`）、AI 聊天历史（`LocalChatStore.swift:245`） |
| ⚠️ 账本 | `Catfolio/portfolio.json` **未排除 iCloud 备份**（`LocalPortfolioStore.swift:1379-1381,1697`），会进备份 |
| ⚠️ 研究落盘 | `security-developments-v2.json` / `security-price-moves-v1.json` **既无文件保护也无备份排除**（`SecurityDebateStore.swift:252`、`:420`） |
| 命名空间 | `Catfolio/` 前缀与顶层 `sector-rotation-v2/`、`EarningsHistory/`、`InsiderTrades/`、`OptionsOI/`、`AnalystConsensus/`、`InvestorSimulation/`、`research-analysis-v1/` 并存 |
| 单点风险 | `portfolio.json` 是唯一账本文件，JSON prettyPrinted、无多版本；损坏只靠 `portfolio-corrupt-<UUID>.json` 事后兜底 |

**隐私清单**：`PrivacyInfo.xcprivacy` 声明 `NSPrivacyTracking = false`、无追踪域名，收集 `NSPrivacyCollectedDataTypeFinancialInfo` 与 `OtherUserContent`（均不关联用户、仅 App 功能），`NSPrivacyAccessedAPICategoryUserDefaults` reason `CA92.1`。

### 3.4 凭证与隐私边界

- 所有 API Key 与券商凭证**只在设备 Keychain**（`WhenUnlockedThisDeviceOnly`，无 `kSecAttrSynchronizable`，不进 iCloud Keychain），不上传、不入 iCloud 偏好同步白名单。
- 文件保护**并非全部到位**：AI 聊天历史、首页缓存、管理层兑现、策略草稿有 `.completeFileProtection`；但 **`portfolio.json` 未排除 iCloud 备份**，**developments / price-moves 两个研究文件既无文件保护也无备份排除**（详见 3.3）。
- AI 只发送组合摘要与当前问题；Apple 本地模型路径完全不联网。
- 组合摘要与公开研究的上下文相互隔离（`LocalServices.researchAnswer` 注释明确「不发账户余额、凭证、持仓」，`LocalServices.swift:4124-4126`）。

---

## 4. 页面结构全景

### 4.1 四个主 tab

```
RootTabView
├─ 持仓 PortfolioView.swift (3,279 行)
│  ├─ 顶部英雄区：总市值 / 成本 / 盈亏 / 今日涨跌 + 资金曲线
│  ├─ PortfolioHeroChart / CostMarketCard / FastCostMarketPlot
│  ├─ TodayContributionCard → TodayDetailView（今日盈亏归因、行业下钻）
│  ├─ 持仓列表：HoldingRow / 排序 HoldingSortField / 今日-持有期切换
│  ├─ PortfolioDetailsCard：列表 / 热力图 / ETF 穿透 三态切换（**默认不显示热力图**）
│  ├─ 首页缓存恢复 + 下拉刷新（自研桥接）+ skeleton + ripple 动画
│  └─ 长按 HoldingRow → 个股详情 Sheet
├─ 收益 ReturnsView.swift (1,963 行)
│  ├─ PerformanceHeatmapHero（首页热力图的等距 hero 形态）
│  ├─ 组合 vs 基准对比，三口径（现金流镜像 / TWR / MWR），默认基准 8 个
│  ├─ StandardLineChart + 双指区间测量 + 单日读取 + 10 档时间范围
│  ├─ 五条支线（**均挂在本页滚动流内，不是独立页面**）
│  │   ├─ 贡献度 → HoldingContributionChart
│  │   ├─ 损失 → LossAnalysisChart
│  │   ├─ 对比 → ReturnsComparisonPanel → ReturnsChart
│  │   ├─ 回撤 / 估值矩阵 → ReturnsAnalyticsView
│  │   └─ 水下 → UnderwaterAnalysisChart
│  ├─ TodayAttentionPreview →「更多」→ TodayAttentionView（复用研究 tab 页面）
│  └─ Section「行情与 AI」(ReturnsView.swift:44-66)
│      ├─ 板块轮动 → SectorRotationView (:50)
│      ├─ 市场轮动 · RRG → StockChartsRotationView (:53)
│      ├─ 行业情绪 → IndustrySentimentView (:57)
│      ├─ 选股器 → StockScreenerView (:60)
│      ├─ 策略编曲家 → PolicyComposer (:63)
│      └─ 税务计算 → disabled 占位 (:65-67)
├─ 研究 ResearchView.swift (982 行)   ← 注意：研究 tab 只直挂 4 个页面
│  ├─ 离线证券搜索框 → 个股详情（约 2 万只离线目录）
│  ├─ Section「关键指标」4 张卡：^GSPC / ^IXIC / ^VIX / ^TNX
│  ├─ 板块轮动 → SectorRotationView (:500)
│  ├─ 市场轮动 · RRG → StockChartsRotationView (:501)
│  ├─ 周期对比 → CycleComparisonView (:502)
│  └─ 今天值得关注 → TodayAttentionView（AI 分析 + 信号规则）
│
│  ⚠️ 研究域其余 ~13 个模块并不在 ResearchView 里：
│     · 个股详情页 HoldingResearchSection 挂 7 个（见 4.2）
│     · 收益 tab「行情与 AI」组挂 5 个（见上）
│     · 设置 tab 挂新闻 / 佩洛西模式
│     · 合计研究域 19 个功能模块
└─ 设置 SettingsView.swift (2,205 行)   ← 见 4.3
```

### 4.2 个股详情（App 内最重的页面）

`VolumeProfileView.swift`（4,433 行，**全 App 最大文件**）实际承载 `HoldingDetailView`，是持仓/研究/搜索共用的详情 Sheet：

| 区块 | 内容 |
|---|---|
| 头部 | 价格、涨跌、52 周区间（`FiftyTwoWeekRange`）、账户选择器、关闭手势 |
| 价格图 | `SecurityPriceChart` / `SecurityPricePlot`，多时间范围、成本参考线、买卖点标记 |
| 成交量分布 | `VolumeProfileInterpretation`、`VolumePriceChart`，POC / VAH / VAL 与成本/现价对照 |
| 持仓数据 | `HoldingDataRow`（成本、市值、盈亏、汇率影响、占比） |
| 财务 | `CompanyFinancialsView`（利润表/资产负债表/现金流） |
| 盈利 | `EarningsHistoryView` |
| 分析师 | `AnalystConsensusView` → `AnalystHistoryView` |
| 内部人交易 | `HoldingInsiderTradesCard` |
| 期权 OI | `OptionsOIView` |
| 管理层兑现 | `ManagementDeliveryCard` |
| 证据核对（SecurityDebate） | `SecurityDebateCard` |
| 预测市场 | `HoldingPredictionMarketsCard` → `PolymarketEventCard` |
| 已实现盈亏 | `RealisedProfitCalculator` 结果 |

### 4.3 设置页分区

`SettingsView.swift`（2,205 行）**不是** `List`/`Form`，根容器是自定义 `SettingsPage`（`ScrollView + VStack`，`SettingsTemplate.swift:317-345`），`NavigationStack` 来自外层 `RootTabView.tabPage`。共 **14 个分区、约 80 条行级条目**：

| # | 分区 | 内容 |
|---|---|---|
| 1 | （页面标题「设置」） | `SettingsPage` |
| 2 | 账户模式 | `PublicInvestorSettingsSection`（佩洛西模式开关 + 人物多选） |
| 3 | 账户范围 / 账户活动 | 账户多选、`SettingsHistoryOverview`（仅当有账户时显示） |
| 4 | 新建账户 | Trading 212 / Moomoo / IBKR / SnapTrade / CSV 导入 + **1 个 disabled 占位**（拍照 AI 添加持仓） |
| 5 | 行情与 AI | `LocalServicesSettingsView`：5 个密钥（Massive / FMP / DeepSeek / OpenRouter / Finnhub）+ 默认模型 5 档 + Codex 登录 |
| 6 | 偏好设置 | 触控反馈、语言、外观、公司名称、数据货币 |
| 7 | （FX 脚注） | `LocalPortfolioEngine.fxStatus` |
| 8 | iCloud | `CloudPreferencesSettingsSection`（开关默认关闭 + 状态 + 重试） |
| 9 | 本机数据 | 来源、持仓数、**对账结果（内联，无独立子页）**、行情更新时间、数据问题 |
| 10 | （对账详情脚注） | `reconciliationDetail(_:)` |
| 11 | 本机组合数据 | 「备份并重置」 |
| 12 | （恢复提示脚注） | `portfolioRecoveryNotice` |
| 13 | 实验 | 等距热力图实验页 |
| 14 | 关于 | 版本等 |

相关子视图：`CloudPreferencesSettingsSection`、`AccountDetailView`、`AccountNotice`、`AccountDataIssuesView`、`AccountTransactionsView`（**未引用**）、`ManualTransactionView`、`SettingsHistoryOverview`、`LocalServicesSettingsView`、`LocalServiceDetailView`、`CodexOAuthSettingsView`、`NewsSettingsView`、`CSVImportView`。设置模板组件库在 `SettingsTemplate.swift`（1,250 行）——它是**设计组件库 + token 命名空间**，不是数据驱动模板，也没有 result builder。

**账户详情页**（`AccountDetailView`）：账户信息（重命名、类型/币种/Broker 只读）、数据来源（同步 / CSV / 手动补充）、数据记录（History、数据匹配与去重）、账户设置（删除账户）。每个券商对应一个连接视图（`Trading212View` / `MoomooOAuthView` / `IBKRFlexView` / `SnapTradeView`）。

**对账**（`LedgerReconciliation.report`）：只统计 BUY/SELL，按拆股归一，逐 ticker 比较账本净股数与实际持仓，**相对误差 ≥ 0.1% 才算 mismatch**；展示区分「账本股数多于持仓（缺卖出记录）」与「持仓多于账本（缺买入记录）」。**报告不等于自动修复**。

> **⚠️ 设置页里没有 Policy 入口**：`grep "policy|策略" SettingsView.swift` 为 0 命中。策略编曲家入口在**收益 tab**。
> **⚠️ 设置页里没有「导出」**：全仓 Swift 源码 `grep "导出"` 0 命中，无 `ShareLink`/`fileExporter`；CSV 只有单向导入。

### 4.4 入口矩阵（功能挂在哪个页面）

以下为源码交叉引用核实结果，是理解「功能从哪里进」的关键。

**主页面级入口**

| 功能视图 | App 内实例化位置 |
|---|---|
| `TodayDetailView` | `PortfolioView` |
| `ETFLookThroughView` | **无实例化点**（实际走热力图 exposure 模式） |
| `PolymarketMarketsView` / `PolymarketMarketsSection` | **无实例化点**（实际用 `PolymarketEventCard` 在个股详情） |
| `InsiderTradesView` | **无实例化点**（实际用 `HoldingInsiderTradesCard` 在个股详情） |
| `CompanyFinancialsView` / `EarningsHistoryView` / `AnalystConsensusView` / `OptionsOIView` / `ManagementDeliveryCard` / `SecurityDebateCard` | 全部在 `VolumeProfileView`（个股详情） |
| `IndustrySentimentView` / `StockScreenerView` | `ReturnsView`「行情与 AI」组 |
| `SectorRotationView` / `StockChartsRotationView` | `ResearchView`、`ReturnsView`、`SettingsView`（三处，主要作 DEBUG 预览） |
| `CycleComparisonView` | `ResearchView` |
| `PublicInvestorSelectionView` | `PublicInvestorView` |
| `NewsSettingsView` | `SettingsView` |
| `PolicyComposerView` | `ReturnsView`「行情与 AI」组（标签为「策略编曲家」） |

**研究域 19 个模块的入口分布**（修正「研究 tab 装全部研究功能」的误解）

| 模块 | 实际入口 | 数据源 | 关键限制 |
|---|---|---|---|
| 关键指标 4 卡 | ResearchView | Yahoo chart | 仅最近收盘，非实时 |
| 证券搜索 | ResearchView | 打包 `company_reference.json` | 约 2 万只离线快照 |
| 今天值得关注 | ResearchView | 本地信号 + 新闻 + SEC + AI | AI 失败降级为纯价格基线 |
| 周期对比 | ResearchView | Yahoo chart（自 2014-12） | 过去周期不完整则不画 |
| 板块轮动 | ResearchView（+ Returns） | **用户自填端点** `sectorRotation.endpoint` | App 不算 RRG，只校验展示 |
| 市场轮动 RRG | ResearchView（+ Returns） | **WKWebView 截获 stockcharts.com 自身 XHR** | 第三方页面改版即失效 |
| 行业情绪 | ReturnsView | 仅 JSON 快照，无网络端点 | 仅半导体专项 |
| 选股器 | ReturnsView | FMP 5 端点 | 限 US 三交易所，limit=1000 |
| 期权 OI 墙 | 个股详情 | Yahoo options + crumb | 只认 REGULAR/USD；429 冷却 |
| 预测市场 | 个股详情 | Polymarket gamma API | 未提供所选语言的盘口被过滤 |
| 发展/事实核查 | 个股详情 | 5 家新闻源 + 正文抓取 | 每票最多 2 篇、每篇 1,500 字 |
| 管理层兑现 | 个股详情 | FMP 文字稿 + 财报 | **硬依赖 iOS 26 + Apple Intelligence** |
| 分析师共识 | 个股详情 | FMP，降级 Nasdaq | 仅 USD |
| 分析师历史 | 个股详情 → sheet | 纯本地 `analyst_history_catalog.json` | 78 只覆盖 |
| 内幕交易 | 个股详情 | Nasdaq API | 单票上限 300 行 |
| 盈利历史 | 个股详情 | FMP，降级 Nasdaq | Nasdaq 仅 4 期 EPS、无收入 |
| 公司财报 | 个股详情 → sheet | **SEC → FMP → Nasdaq 三级** | 境外无 SEC 覆盖 |
| 分部收入 | 个股详情 | 打包 `revenue_segments.json` | 2,198 家公司，随包定格 |
| 新闻设置 | 设置 tab | — | Finnhub 需 Key |

模块显隐由 `HoldingResearchModule` 枚举（7 项）加 OI 墙与管理层兑现两个旁路卡片共同决定；分析师/内幕**硬性限制为 USD 计价**，基金类标的默认不显示、需有实际内容才出现（`CompanyReferenceCatalog.swift:190-213`）。

---

## 5. 全部功能清单

> 交叉核对 `docs/ios-feature-inventory.md`（2026-09-09）与当前代码。该文档已落后于代码：OpenRouter、SnapTrade、AI 思维链流式、iCloud 偏好同步、策略编曲家均为文档后新增，见第 11 章。

### 5.1 账户接入与管理
Trading 212 只读 API（正式/模拟）、Moomoo OAuth 2.1 + PKCE、IBKR Flex Web Service、SnapTrade、CSV 导入；账户多选、昵称、删除、交易记录、手工补录、同步状态与失败提示。

### 5.2 组合首页与持仓

**刷新链**（`AppModel.refreshPortfolio`）刻意「先磁盘、后网络」：读本地账本 → 用 `PortfolioPresentationCache` 立刻上屏 → 解锁控件 → **并行**拉历史曲线 / 今日涨跌 / 汇率 / 报价 → 行情回来后原地更新 → 回写缓存。历史曲线先在 `cachedOnly` 下取本地缓存上屏，再拉全量。

**核心公式**（源码逐字）：

```
cost         += shares × averageCost   (折 USD)
marketValue  += shares × quotePrice    (折 USD)
unrealized    = marketValue − cost
unrealizedPct = cost > 0 ? pnl / cost × 100 : 0
weight        = marketValue / totalMarketValue
```

**今日盈亏**：本地路径的 `overview.todayPnl` 恒为 0、`todayChangePercent` 恒为 nil——今日数据完全由 `holdingDailyChanges` 承担，口径是**最近两个交易日收盘价** `(latest/previous − 1) × 100`。单持仓今日金额：

```
factor = 1 + change/100
amount = marketValue − marketValue / factor     // 等价 MV − MV₋₁
```

隐含假设「今日无交易」。对比基准显示 `±SPY x.xx%`。

**汇率归因三级来源**：券商原币 FX 分项 → 券商总 P&L 减价格 P&L 的**残差** → 用 ECB 日频汇率在**成交日**重建。

**下拉刷新不是系统 `.refreshable`**：`PortfolioHomeScrollBridge`（`UIViewRepresentable`）向上遍历 superview 找 `UIScrollView`，挂自研 `PortfolioHomeScrollController`，用 `CADisplayLink` 跑欠阻尼弹簧 snap（response 0.42 / damping 0.82 / 最长 1.2s）。

**加载动画**：`PortfolioLoadRipple` 等 500ms 收敛 → 整屏截图 → 对**静态图片**跑 Metal 水波纹着色器，每次启动只播一次，任意触摸立即停止。

**列表**：排序字段 4 个（市值 / 盈亏 / 收益率 / 名称，持久化）、「今日 / 持有期」口径切换、账户多选；比较器对 NaN 做「有限值优先」处理。

### 5.3 今日盈亏归因

`TodayDetailView` + `SectorAttribution`：按行业汇总贡献、下钻成分、上涨/拖累分列。

**行业归因算法**（`SectorAttribution.split`，**不是 Brinson**——全项目 `brinson|allocation effect|selection effect` 0 命中）：

```
基金   → 用 etf_sector_composition.json 的指数成分权重
个股   → 满权重记入其 GICS 行业
未覆盖 → 显式 unclassified（权重和 ≤ 1，余数记 unclassifiedFraction）
```

**覆盖度实测**：`company_reference.json` **21,794 条中仅 8,120 条有 sector（37.3%）**；`etf_sector_composition.json` 的 6 个指数权重和并不为 1（SP500 = 1.0000，ACWI = 0.9219、NDX100 = 0.9433、RUSSELL2000 = 0.9759），差额会被当成「未分类」。

**口径限制**：按持仓市值 × 最近报价涨跌推算，未计入今日买卖影响。代码注释也自认这是代理口径：「the fund's move was not uniform across its holdings, but a defensible one when per-constituent returns are not available.」

**⚠️ 同一公式两处实现且已漂移**：`PortfolioView.swift:601-618` 用 `guard factor > 0`（跌幅 ≤ −100% 丢弃），`TodayDetailView.swift:26-39` 用 `previous = MV/(1+change/100)` + 有限性判断（跌幅 < −100% 会显示经济含义错误的正值）。

### 5.4 ETF 穿透与重叠暴露

**活实现是首页的 `etfTable`**，不是 `ETFLookThroughView.swift`（214 行，**零调用方**）。真算法在 `LocalServices.swift:4694-4877` 的 `LocalETFLookThrough.make`。

```
直接持仓 = 不在受支持 ETF 名单里的持仓
间接     = 基金暴露 × 成分权重 / 100
同一 ticker 跨多个 ETF 累加
总暴露   = 直接 + 间接（直接额只取一次，不做去重或归一化）
```

同一标的既直接持有又通过多个 ETF 间接持有的情况**已正确处理**（按 ticker 累加 + 移除直接项），UI 用「重叠持仓」标签提示。XS2D 的 2 倍日杠杆只分配一次。

**成本/市值两口径**：成本口径 = 基金成本 × 基金内权重，注释自认「allocates fund P/L; it is not a constituent's historical price return」。**活 UI 固定使用市值口径，成本口径只在死掉的 `ETFLookThroughView` 中暴露**。

**快照来源与时效**——`etf_holdings.json` 实测 **77 只基金**（`as_of` 2026-09-03/04），`ETF/sp500_holdings.json` 为 2026-06-30（17 个高频 ticker）、`eqqq_holdings.json` 为 2026-08-27。快照日期字段存在并被拼成 `holdingsAsOf`，**但活着的 UI 不展示它，也没有 TTL / 过期判断**（项目里轮动数据有 `isExpired`，穿透没有）。

**⚠️ 两个 ETF 宇宙不一致（结构性风险）**：

| 面 | 规模 | 后果 |
|---|---|---|
| 穿透支持面 | `etf_holdings.json` 77 只 + 硬编码 17 个 ticker，去重 **93** | — |
| 行业权重面 | `etf_sector_composition.json` **76** alias | — |
| 差集 | **76 个 ticker 能穿透但拿不到行业权重**（IBB/SOXX/ITA/IGF/ITOT/EWJ/MCHI…）；**59 个有行业权重但不能穿透**（QQQ/CSPX/VWCE/VT/VWRL…） | 穿透行与行业归因口径不对齐 |

**⚠️ 费率未接入穿透**：`FundFeeCatalog`（7,199 records / 13,124 aliases）只有 `expenseRatio` 一个字段，**96.8% 的记录缺 `expenseRatioAsOf`**，且 `LocalETFLookThrough.make` **完全不引用它**——穿透净值与行业归因都是**费前**数字。费率仅用于 History 的 run-rate 估算与个股详情的一行展示（注释明确「run rate at today's price, not a fee already paid」）。

**未穿透残差显式处理**：`CASH`/`ETF 其他`、`unallocatedWeight`、合成「基金现金、衍生品及未识别部分」行、`coveredWeightPercent`——不会静默丢弃。

**其他口径不一致**：`etfWeightPercent`（基数 = ETF 总市值）与 UI `portfolioWeight`（基数 = 穿透后全部行合计）用了两个不同基数；`otherWeightPercent` 算出后无人使用。

### 5.5 收益与组合分析

**三种模式**（`ReturnsChartMode`）：`cashFlowMatched`（「现金流镜像」）、`twr`（默认）、`mwr`。全部本地计算，**无任何 returns 相关 HTTP 端点**。数据不足时各自给出独立文案。

**TWR**：不是 Modified Dietz，是「入金日初 / 出金日末」的每日几何链式（公式见 8.3）。现金流只认 `external`；股息/费用/交易是内部；内部转账按 `transferID` 跨账户配对且各币种净额必须为零；缺价/缺汇率/重复流水/流水日无估值一律抛错。

**MWR**：**区间收益率，非年化 XIRR**。在 log-growth 空间求 NPV，符号约定入金为正、事件取负；求解为**牛顿法 + 扫描 + 二分兜底**（初值 `log(1.1)`，≤32 次迭代，步长限幅 ±20，失败则按 0.25 步长扫描找变号区间，再二分 ≤80 次）。

**基准**：默认 8 个（SPY/QQQ/VTI/VOO/DIA/IWM/VEU/GLD），上限 12，用户可搜索任意标的增删。**两条独立口径**：
1. **现金流镜像**：把真实外部现金流按同日收盘价买入基准单位，`units += flow / price`；基准付不起出金则整体标为不可用；
2. **TWR 指数化**：`value / base`。

**⚠️ 收益口径不对称**：组合用**原始收盘价 + 显式股息流水**，基准用 **adjclose 总收益**——未导入股息的持仓会天然跑输基准。汇总固定取 SPY，SPY 被移除则汇总为 nil。

**时间范围**：10 档（1D/1W/1M/2M/YTD/6M/1Y/2Y/5Y/MAX），**没有 3M**（`--show-returns-3m` 实际映射到 2M）。切换只做本地过滤 + 重基准；TWR 每区间重新链式归零，MWR 每区间独立解一次。

**回撤与水下**：两条**互不相同**的实现——收益页的「回撤」是**当前权重 Top35 的模型组合 5 年 NAV**，不是真实账户回撤；「水下」用 `fixedShareHistory`（固定今日股数回推）。

**估值矩阵**：FMP 数据，P/E 优先 forward 再 trailing，成长优先 EPS 同比再营收同比，缓存 12 小时。**⚠️ 口径 bug：分母用全币种市值，分子只收 USD 成本币种持仓。**

### 5.6 个股行情与持仓详情
历史价格、买卖点、成本线、跨账户持仓、汇率影响、52 周区间、Volume Profile（POC/VAH/VAL）、状态区分（券商报告 / 重建 / 估算 / 缺失）。个股详情是全 App 最重的页面（4,433 行），承载 7 个研究模块（见 4.2）。

**成交量分布（VAH/POC/VAL）**：**数据源是日线 OHLCV，不是分钟线**。窗口 = 最近 **160 个交易日**，固定 **36 桶**，桶宽 `(max−min)/36`；成交量按**典型价 `(H+L+C)/3` 全额记入单一桶**（不做 high-low 均摊）；POC = 最大桶中点；价值区目标 **70% 硬编码**，VAH/VAL 用**逐桶贪心扩张**（每次比较上下相邻桶取较大者，并列时取上侧）。三者均取**桶中点**，而前端「实际 profile 区间」用**桶边界**——导致 VAH 标签压在 silhouette 内部而非边缘。

**与经典 Steidlmayer 口径的两处差异**：经典做法是一次判定上/下「一对」桶后整体纳入，这里是逐桶择大者；若两侧同时耗尽仍未达 70%，循环退出而**实际覆盖可能 < 70% 且无任何警告**。字段 `valueAreaPercent`（schema 里有）解码后**从未被读取**，70% 在展示文案里另写一遍。

**拖动交互**：只把 `location.y` 线性反解成价格写入 `selectedPrice`——**profile 不重算、不平移、无命中测试（不判断落在哪个桶）、无防抖**（只有等值短路）。

### 5.7 期权 OI 持仓墙
Yahoo 期权链直读，7/30/90 天范围，Call/Put 峰值与集中区，本地缓存 + 手动刷新，429 冷却，缺数不覆盖完整缓存，只处理可核验 REGULAR 合约。

### 5.8 公司财务、盈利与市场预期
三类财务报表（SEC Company Facts 优先，回退 FMP）、年度/季度、重述取最新、原币种保留；盈利历史实际 vs 预期；分析师一致预期、评级分布、目标价；相关 Polymarket 事件。

### 5.9 市场研究与今天值得关注

**研究 tab 直挂（4 页 + 1 入口）**：关键指标 4 卡（Yahoo，仅最近收盘）、离线证券搜索（打包 `company_reference.json`，约 2 万只）、板块轮动、市场轮动 RRG、周期对比、今天值得关注。

**「今天值得关注」逻辑**（`LocalPortfolioAttentionEngine.scan`，`LocalServices.swift:3495`）：逐持仓算 5 类信号——N 日涨跌幅、量比（最新量 ÷ 前 N 日均量）、距 52 周高低点百分比、MA 上下穿（比较前一日收盘与前一日均线）、今日异动；再加组合贡献度 `weight × todayChangePercent`（占比达阈值且绝对值 ≥ 0.20 才计）。满足任一信号即入列，信号数 ≥ 阈值记高关注。默认阈值：60D ±10%、MA200、52 周 3%、2× 30 日均量、今日 ±5%、贡献 40%、2 个信号。历史不足 40 根只发 warning 不补数。

**AI 阶段硬约束**：只在引用未过期且 `company_specific_catalyst && catalyst_confirmed && catalyst_is_recent` 全真时才认公司事件；`risk_flags` 白名单 5 项；置信度 high 需反方证据非空且无重大未决风险。**只有前 6 只取正文摘录**，每只最多 2 篇、每篇 1,500 字。

**⚠️ 归属修正**：`docs/ios-feature-inventory.md:102` 把「持仓涨幅榜、持仓跌幅榜」列在研究与今天值得关注并署来源 `ResearchView.swift`，但榜单实际在 `TodayDetailView.swift:204-209`（**持仓 tab** 的今日详情），ResearchView 中不存在涨跌榜，研究 tab 也无法到达该页。

**⚠️ 研究 tab 的真实构成**：研究域共 19 个功能模块，其中只有 4 个页面挂在 ResearchView；另外 8 个在个股详情页、5 个在收益 tab「行情与 AI」组、2 个在设置 tab。详见 4.1 / 4.2 / 4.4。

### 5.10 选股器
七类条件（市值、年度营收、TTM 市盈率、营收同比、净利率、自由现金流、距 52 周低点）、规则保存、自然语言生成条件、分批核验（每批 20 家）、AI 解释匹配理由。

### 5.11 行业情绪
半导体专项：情绪分数、VXSMH、SMH 成交量、组合半导体直接持仓占比；依赖 JSON 快照导入。不含现金与 ETF 穿透。

### 5.12 AI 助手与个股证据核对
五档 provider、流式 + 思维链、本机聊天历史、Markdown、语言跟随、任务可后台继续、真实账户与模拟账户上下文隔离。（详见第 7 章）

**⚠️ 命名澄清**：文档与部分描述中的「个股正反方辩论 / 多智能体辩论」**在代码中并不存在**。`SecurityDebate.swift:5` 明确写「The historical type name is kept internal」，`:519` 的 prompt 甚至**明文禁止**编造辩论：「Do not invent a debate, bull/bear sides, consensus, opposing views…」。实际实现是**同一模型的两次串行调用（抽取 + 审计）+ 逐字引文校验**，角色数为 0。

### 5.13 History、现金活动与费用

**⚠️ 命名纠正**：`HistoryPagingView` **不是记录级分页器**，而是 `UIScrollView(isPagingEnabled)` 做的**分类横向翻页**（All / Orders / Dividends / Interest / Fees）。**没有 page size、游标、增量加载或无限滚动**——性能策略是「一次性全量取回 + `List` 自身懒加载 + 相邻页 80ms 预热」。

**数据源是交易流水，不是每日快照**（`PortfolioActivityLedger`）。排序为日期倒序、同日 id 倒序。

**已实现盈亏**：`RealisedProfitCalculator` 的 **FIFO 逐批消耗**（非平均成本法），并有 `TaxYearBasis.allCases` 分税年。两条关键口径：**券商 Result 与本地估算严格分列**（`combinedUSD = brokerUSD + estimatedUSD`，并注明是今日汇率折算的近似）；**只有全部份额都匹配到导入买入**才估算，否则标 `unavailable`。

**⚠️ 出入金被整体过滤**：`HistoryView.swift:1319` 的 `activity.kind.isCashTransfer ? nil : activity` 让 **deposit / withdrawal / transfer 永远不会出现在历史页**；枚举里为它们准备的标题与图标（`:83-100`）是**不可达分支**。

**⚠️ 手续费无字段、不参与计算**：`LocalTransactionRecord` 没有 commission/fee 字段；CSV 导入刻意不猜「fee 列是否已含在 Total 里」，**手续费既不计入成本、也不计入已实现盈亏**。`FEE`/`TAX` 没有独立 kind，落进 `.other`，只在 All 页出现。

**Fees 页不是流水**：`HistoryCategory.fees.includes` 恒为 `false`，该页不接受任何流水行，而是「基金年费运行率」估算（`marketValue × rate`），页脚明确声明「不是已扣除的金额…不要再从收益里减一次」。

**拆股**：`StockSplitCatalog` 读 18,330 个 ticker 的拆股档案，只累乘**买入日之后**的事件，口径为 `数量 × factor`、`价格 ÷ factor`。**⚠️ 历史页只在英国配对计算里用拆股，列表行显示的股数与成交价不做调整。**

**英国税规则（分状态）**：

| 能力 | 状态 |
|---|---|
| same-day + 30 天 + 池余量**匹配** | ✅ 实现并接线（`HistoryView`） |
| 30 天窗口 = 30 个 UTC 日历日 | ✅ |
| 英国税年 4/6–4/5 归属 | ✅ |
| Section 104 池成本 | ⚠️ **实现但零调用方**（仅 XCTest） |
| CGT 税率 / 年度免税额 / 亏损结转 / 印花税 | ❌ 完全未实现（仅否定式注释） |
| 独立税务计算页 | ❌ 入口 `.disabled(true)` |

代码自己声明了边界且与事实一致：「It does not compute tax: no rates, no annual exemption, no brought-forward losses.」

**CSV 导出**：**存在**，在 **History 页**（`HistoryView.swift:285` 的 `.fileExporter` + `HistoryCSVDocument: FileDocument`，`:1060-1090` 生成 CSV）。但**设置页没有导出**（全仓 `grep "导出"` 在设置页 0 命中）——两份子报告曾在此点互相矛盾，已按源码核实。

**基金费用**：`FundFeeCatalog` 7,199 records / 13,124 aliases，**96.8% 缺 `expenseRatioAsOf`**；旧参考包漏掉 QQQ/VTI/VT/ARKK/SCHD。

### 5.14 佩洛西模式与演示账户
公开投资者多选、独立模拟账户、复用全部页面、诊断文件隔离、离线披露包（截至 2026-09-07）、与真实账本完全隔离。

### 5.15 偏好、存储与可靠性
语言（中/英/系统）、外观（浅/深/系统）、触觉反馈、公司名显示、九种币种、密钥管理、Codex 登录、本机账本保护、交易对账、重置与恢复、iCloud 白名单同步（默认关闭）。

### 5.16 策略编曲家（Policy）与轮动

**入口位置修正**：策略编曲家在**收益 tab**，不在设置 tab，也不在研究 tab——入口是 `ReturnsView.swift:62` 的 `SettingsButtonRow` → `fullScreenCover` → `PolicyComposerEntry()`（`ReturnsView.swift:100`）。

- **策略编曲家**：编排 / 文本 / 运行三视图、12 种节点、指标筛选排序、风险检查、只读模拟、运行历史与因果追踪。**绝不下单**——契约层 `strategy.schema.json` 用 `"actionPolicy": {"const": "NO_ORDERS"}` 锁死，运行时写死 `PolicyRunCoordinator.swift:82`。只覆盖美元美股日线，**非历史时点回测**（只能跑「今天之前最近一个完整交易日」），本地化未完成。
- **市场轮动 · RRG**：六个市场指数、SPX 基准、30 周轨迹与回放。实现方式是 **WKWebView 加载 stockcharts.com 公开页并截获其自身 XHR**（仅接受 `origin=stockcharts.com && pathname=/d-rrg/rrg && cmd=getrrgdata2 && b=$SPX && p=w`）——第三方页面改版即失效，README 完全未提这条脆弱链路。
- **板块轮动**：11 个行业 ETF、四象限相对强弱/动量、历史轨迹与回放。**端点由用户在 UI 自填**（`@AppStorage("sectorRotation.endpoint")`），App 只做严格校验（`calcVersion==2`、`benchmark=="SPY"`、11 个固定 ETF、`|x|,|y|≤2.5`），**不含任何 RRG 计算**。
- **周期对比**：年度周期对比 + 本年分红预测。README 与功能清单均未列此页。

### 5.17 明确未开放 / 未实现

**入口占位（disabled）**：拍照 AI 添加持仓、税务计算。券商账户可通过现有 SnapTrade 个人 API 入口连接。

**完全没有执行入口**：App 内下单、自动交易/跟单。

**覆盖不保证**：全市场实时行情、全市场 ETF 穿透、所有行业自动情绪、完整历史目标价回测。

**明确不做**：个人账本全量 iCloud 同步、官网正式下载。

**深挖新确认的实现缺口**：

| 缺口 | 说明 |
|---|---|
| History 记录级分页 / 无限滚动 | 不存在（`HistoryPagingView` 是分类翻页器） |
| 出入金（deposit/withdrawal/transfer）展示 | 被 `HistoryView.swift:1319` 整体过滤 |
| 手续费计入成本 / 盈亏 | 无字段、不参与计算 |
| Section 104 成本池 | 已实现、有测试，但**零 UI 调用方** |
| CGT 税率 / 年度免税额 / 亏损结转 / 印花税 | 未实现（仅否定式注释） |
| ETF 成本口径 | 已实现，但只在死代码 `ETFLookThroughView` 中暴露 |
| 双设备账本合并（`PortfolioDocumentMerge`） | 已实现，仅测试引用 |
| 记录级胜率 / 盈亏比 / HHI / Brinson 分解 | 未实现 |
| ETF 快照时效展示与过期判断 | 未实现（轮动数据有 `isExpired`，穿透没有） |
| 费率进入穿透与收益计算 | 未接入（穿透为费前数字） |
| 平均成本法 | 仅 FIFO |

---

## 6. 券商同步链路

### 6.0 全局数据流

```
[设置页各券商 View]                        [Keychain / UserDefaults]
 Trading212View.preview()                    trading212.account-N.api-key/-secret
 MoomooOAuthView.preview()                   moomoo.oauth.client-id
 IBKRFlexView.fetchOpenPositions()           moomoo.oauth.account.{id}.tokens
 SnapTradeView.loadAccounts()                ibkr.flex.{acct}.token/.query-id
                                             snaptrade.{uuid}.credentials
        │ ① 网络拉取（各客户端自带 URLSession）
        ▼
 Trading212Client.fetchSnapshot      → Trading212Snapshot
 MoomooOpenAPIClient.fetchSnapshot   → MoomooSnapshot
 IBKRFlexClient.fetchOpenPositions   → IBKRFlexSnapshot
 SnapTradeClient.snapshot            → SnapTradeSnapshot
        │ ② 用户确认后调用 AppModel（APIClient.swift）
        ▼
 AppModel.importTrading212 / importMoomoo / importIBKR / importSnapTrade / importCSV
        │ ③ 归一化：Self.merge(positions)
        │ ④ 若 fxPnl 为空 → LocalFXImpactCalculator().enrich(...)（FIFO + Yahoo 日线）
        ▼
 LocalPortfolioStore.shared.replace(positions:source:transactions:...)
        │ ⑤ 落盘 Application Support/Catfolio/portfolio.json
        ▼
 LocalPortfolioEngine.presentation(for:) → Holding[] + PortfolioChartResponse
```

**关键结论：iOS 侧不存在统一券商抽象。** 四家各自定义 Snapshot / Error / Credentials 与 fetch 方法，只在 `PortfolioAccount`（`LocalPortfolioStore.swift:588`）与 `LocalPositionRecord`（`:170`）处汇合；唯一「统一入口」是 `AppModel.replace(...)`（`APIClient.swift:1262`）。没有 `protocol BrokerClient`，新增券商要重写 fetch → Snapshot → `importX` → `replace` 四段。

`LocalServices.swift` **不含任何券商同步代码**，它是行情 + 账本重建 + FX + 估值层。

### 6.1 Trading 212（`Trading212Client.swift` 1,644 行）

- **鉴权**：HTTP Basic，`base64(apiKey:apiSecret)`（`:837`、`:1472`、`:1581`、`:1606`）。Key 校验禁止冒号、长度 ≤512（`:29-40`）。
- **凭证**：Keychain `trading212.account-{slot}.api-key` / `.api-secret`；环境存 UserDefaults `trading212.environment`。
- **端点**（base：live/demo `*.trading212.com/api/v0`）：`equity/positions`（404 回退 `equity/portfolio`）、`equity/account/info`（失败再试 `equity/account/cash`）、`equity/history/orders?limit=50`、`equity/history/dividends?limit=50`、`POST equity/history/exports`（异步结算报表）、`GET equity/history/exports`。
- **分页/限流**：游标 `nextPagePath`，**每页落盘**、中断可续传；官方限流 6 次/分，故单轮上限 `for _ in 0..<6`，触顶写 `resumeAfter = now+61s`。报表接口 61s / 5 分钟冷却，完成后 24h 内不复查。**未对 HTTP 429 做专门处理。**
- **字段映射**：`averagePricePaid`→`averageCost`、`currentPrice`→`quotePrice`、`createdAt`→`openedDate`、`walletImpact.currency`→`accountCurrency`；`ppl`→`brokerPnl`；`fxPpl`（或 `walletImpact.fxImpact`）→`brokerFxPnl`，标 `fxPnlStatus="broker_reported"`。
- **币种口径**：先查 `InstrumentCurrencyRules.knownPriceCurrency` 白名单（VUAG/VUSA=GBP、EQQQ/XSPS=GBX 等），再取 API `currency`（`GBp`→`GBX`），最后才用 `l_EQ`→GBX 兜底。
- **多账户**：每账户一个 slot（`account-1`、`account-2`…），`accountKey = "Trading 212|account-N"`。
- **⚠️ base currency 风险**：`fetchAccountCurrency` 两个端点都失败时**静默回退 `"GBP"`**（`:570-574`），此时账户币是猜测值，`fxPpl` 可能被按 GBP 解读。
- **部分失败**：持仓失败中止整轮；股息/利息失败被隔离只写状态串；持仓总写入，交易仅在 `hasCompleteTransactionHistory` 为真时随 `replace` 写入，否则走增量并集。冷启动会用 `cachedTransactions` 把 checkpoint 合并进本机账本。

### 6.2 Moomoo（`MoomooOAuthClient.swift` 1,062 行）

- **鉴权**：OAuth 2.1 + PKCE(S256)，动态注册 public client（`token_endpoint_auth_method: none`）。`POST /oauth2/register` → `GET /oauth2/authorize/confirm` → `POST /oauth2/token`（`grant_type=authorization_code|refresh_token`）。
- **回调**：`http://localhost:60355/callback`，自建 `NWListener` 绑 `127.0.0.1:60355`，300 秒超时、state 校验、16KB 请求体上限；PKCE verifier 用 `SecRandomCopyBytes`。
- **凭证**：Keychain `moomoo.oauth.client-id`、`moomoo.oauth.account.{accountID}.tokens`、`…disconnected`；`isUsable` 要求剩余有效期 >90 秒。
- **端点**（`https://webapi.moomoo.com`）：`/api/v1.0/accounts/authorized_trd_accs`、`/accounts/{id}/positions`、`/accounts/{id}/fills_history`（`page_size=50`）、`POST /accounts/{id}/orders/detail`（按交易所分组、每批 49 个 order_id 补币种）。**不调用任何现金余额接口。**
- **分页/限流**：`page_flag` 游标，上限 400 页 × 50 = 20,000 笔/账户/市场，按 `deal_id` 去重。**没有限流退避或 429 处理。**
- **多市场**：市场集合 = `enable_market` 映射 ∪ 持仓代码推出的市场，因此**已清仓市场仍会拉历史**。
- **⚠️ base currency 风险**：通用账户无固定本位币，代码直接把**调用方传入的 Catfolio 显示币种**当作账户币（`MoomooOAuthClient.swift:495`）。这意味着同一持仓在不同显示币种下会算出不同 FX 数字。
- **部分失败**：单账户持仓失败抛出；单市场成交失败仅警告，其余保留；成交以并集写入，缺失不等于删除。

### 6.3 IBKR Flex Web Service（`IBKRFlexClient.swift` 519 行）

- **鉴权**：Flex Token + Query ID，均校验为纯数字（长度 6–128 / 3–32）。Keychain `ibkr.flex.{accountID}.token` / `.query-id`。
- **端点**：`GET ndcdyn.interactivebrokers.com/AccountManagement/FlexWebService/SendRequest?t=&q=&v=3` → 取 `ReferenceCode` + `Url` → `GET {url}?t=&q={referenceCode}&v=3`。`Url` 强制 https 且主机必须为 `interactivebrokers.com` 或其子域。
- **轮询**：报表异步生成，`errorCode == "1019"` 表示仍在生成。退避 16 档 `[1.5,2,3,4,5,6,8,10,10,12,15,15,20,20,20,20]`（累计约 192 秒），超时抛 `generationTimedOut`。
- **数据**：`XMLParser` 解析 `AccountInformation` / `OpenPosition` / `Trade` / `CashTransaction`。`costBasisPrice`（或 `openPrice`，或 `costBasisMoney/quantity`）→`averageCost`；`fxRateToBase`→`brokerFXRate`；`reportDate` 解析为 `quoteObservedAt`（报价时间以报表口径为准）。现金活动归类为 INTEREST / DIVIDEND / DEPOSIT / WITHDRAW，**明确不使用 Interest Accruals 以免月末重复计息**。
- **base currency**：取 `AccountInformation@basecurrency`，缺失回退 `"USD"` 并给出「汇率影响暂不可计算」警告。
- **部分失败**：无 `OpenPositions` 段 → `noPositions`；`levelOfDetail=LOT` 的账户从 Summary 去重；非 `STK` 持仓与缺成本持仓**逐仓跳过并警告**，账户其余持仓照常写入；交易并集写入。

### 6.4 SnapTrade（`SnapTradeClient.swift` 264 行）

- **鉴权**：Personal API Key + HMAC-SHA256 请求签名（canonical JSON `{content, path, query}` 放 `Signature` 头），`timestamp` 走 query。`URLSession` **显式禁用重定向**，避免把签名转发给其它主机。
- **端点**：`GET /accounts`、`GET /accounts/{id}`、`GET /authorizations/{brokerage_authorization}`、`GET /accounts/{id}/positions/all`、`POST /snapTrade/login`（`connectionType: "read"`，返回必须是 `app.snaptrade.com` 的 https URL）。**无分页。**
- **凭证**：Keychain `snaptrade.{accountUUID|pending}.credentials`，`WhenUnlockedThisDeviceOnly`。
- **数据**：只导入持仓。`kind` 白名单 `stock/adr/etf/cef/mutualfund`；交易所映射支持 `XNAS/XNYS/ARCX/BATS/XASE/IEXG` → 原代码 `.`→`-`，`XTSE`→`.TO`、`XTSX`→`.V`、`XLON`→`.L`、`XHKG`→`%04d.HK`，**其它市场直接判不支持**。
- **明确不伪造历史**：`fxPnlStatus` 硬编码 `"unavailable"`，`openedDate` 为 nil——不把当前持仓伪装成 BUY，也不推定开户日为建仓日。
- **部分失败最严格**：**任一非零持仓含不支持类型或缺字段，整账户不写入**；写前用 `LocalPortfolioEngine.usd(1, currency:)` 预校验币种可估值；预览 900 秒过期；确认时再次校验凭证未变；空账户需显式确认才清空。

### 6.5 CSV 导入（`LocalCSVImporter`，`LocalPortfolioStore.swift:2212-2705`）

- **解析**：全程本机、`Task.detached`。支持 UTF-16LE/BE（BOM 判定）、UTF-8、Windows-1252、Latin-1；分隔符 `, ; \t` 自动探测，支持 `sep=` 指令行；表头在前 25 行内按匹配列数最多者判定；列名别名覆盖中英双语。≤50 MB、必须 `.csv`。
- **多账户**：若文件含 account 列且出现多个不同账户，**整份拒绝**并提示拆分。
- **是否替换式**：始终以 `replacingAccountsOnly: true` 调用，**只替换目标账户**的持仓与交易，其它账户保留。README「导入会替换手机上的当前持仓」应读作「替换该账户持仓」。
- **重建**：按成交日期排序做加权平均成本重建，逐笔套用拆股系数（`quantity × factor`、`price ÷ factor`）；卖出量超过可重建持仓时**直接报错拒绝整份导入**。现金腿只有在存在 `net cash amount` 或「`total` 且 fee/tax/commission 全为 0」时才生成。

### 6.6 逐券商对照表

| 维度 | Trading 212 | Moomoo | IBKR Flex | SnapTrade | CSV |
|---|---|---|---|---|---|
| 鉴权 | HTTP Basic | OAuth2.1+PKCE(S256) | Flex Token+Query ID | HMAC-SHA256 签名 | 无 |
| 主要端点 | `equity/positions`、`equity/history/*` | `accounts/*/positions`、`fills_history` | `FlexWebService` + 报表 URL | `/accounts`、`positions/all` | 本机解析 |
| 分页 | `nextPagePath` 游标 | `page_flag` ≤400×50 | 单次报表轮询 | 无 | 无 |
| 限流 | 6 次/分，61s 冷却 | 未见处理 | 16 档退避 ≈192s | 429 提示重试 | — |
| 成交 | ✅ + 异步报表回填 | ✅ | ✅ | ❌ | ✅ |
| 现金/利息/股息 | ✅ | ❌ | ✅ | ❌ | 条件性 |
| 汇率 | 券商 fxPpl 原值 | Yahoo 日线重建 | `FX Rate to Base` 优先 | 不计算 | 无 |
| 账户本位币 | info→cash，**兜底 GBP** | **= 显示币种** | baseCurrency，缺则 USD | balance.currency | 无 |
| 部分失败 | 逐段隔离 + 历史并集 | 逐市场隔离 + 并集 | 逐仓跳过 + 并集 | **整账户拒绝** | **整份拒绝** |

### 6.7 统一账本如何构建

1. **成交量标准化**：各客户端把方向统一成 `BUY/SELL/DIVIDEND/INTEREST/DEPOSIT/WITHDRAW`；数量一律取绝对值，方向只由 action 表达；全部落成 `LocalTransactionRecord`（`LocalPortfolioStore.swift:407-503`）。
2. **按「账户+代码」匹配**：`accountKey = "\(source)|\(accountID ?? "default")"`；FIFO 分桶键进一步是 `"\(accountKey)|\(currency.uppercased())"`（`FXImpactCalculator.swift:104`）。记录 `id` 由账户键 + tradeID（或日期/动作/代码/数量/价格）构成。
3. **FIFO 重建剩余批次**：排序规则见 `LocalTransactionRecord.orderedForLotMatching`（`:473-488`）——日期升序 → 有 `executedAt` 的按真实时间戳升序（无时间戳的买入取 `-.infinity`、卖出取 `.infinity`）→ 同时间买入优先 → `id` 升序。
   - **⚠️ 两条 FIFO 实现排序不一致**：`LocalFXImpactCalculator.remainingLots`（`LocalServices.swift:3423-3426`）只按 `(date, tradeID)` 排序，比 `orderedForLotMatching` 粗糙，同日顺序规则不同。
4. **新数据不覆盖旧数据**：不完整历史一律走并集合并（`mergesTransactionHistory: true`），缺失 ≠ 删除。

### 6.8 FX 影响管线：README 5 步逐条核对

| README 步骤 | 代码位置 | 核对 |
|---|---|---|
| ① 保留券商原始 fxPpl | `LocalPositionRecord.fxPnl/fxPnlSource`；T212 写 `broker_reported` | ✅ |
| ② Moomoo/IBKR 标准化为账本，账户+代码匹配，FIFO 重建 | `remainingLots`（`LocalServices.swift:3418`）、`enrich`（`:3276`） | ✅ |
| ③ 每账户独立；IBKR 优先 `FX Rate to Base`；Moomoo 用显示币种；其余用交易日历史汇率 | IBKR `:3372-3377`；Moomoo `MoomooOAuthClient.swift:495`；其余 Yahoo 日线 `:3379-3393` | ✅ 完全吻合 |
| ④ `数量 × 当前价 × (当前资产币/账户币汇率 − 建仓时汇率)`，求和后转 USD | `:3396-3397`、`:3399`、`:3411` | ✅ 公式逐字吻合 |
| ⑤ 不完整→「估算」；缺账户币种/建仓日/历史汇率→「不可算」，绝不用 0 冒充 | `status="estimated"`（`:3327`）；`unavailable` 共 7 个来源串 | ✅ |

**存在第二套 FX 实现**：`FXImpactCalculator.impact`（`FXImpactCalculator.swift:48-86`）用**剩余成本**而非当前价，目标币种硬编码 `"GBP"`，数据源为内置 ECB 包（离线）。它只被 `LocalPortfolioStore.swift:1951-1964` 用作展示层兜底。两套公式会给出不同数字。

### 6.9 拆股、英国税规则、隐含资金

- **拆股**：`StockSplitCatalog.adjustment(ticker:from:)` 把 `d > date` 的事件 `t/f` 连乘；统一口径 `quantity × factor`、`price ÷ factor`，在 CSV 重建、FX FIFO、Section 104、UK 匹配、账本勾稽、TWR 重建**六处一致使用**。
- **UK 同日 / 30 天匹配**（`UKShareMatching.swift`）：窗口用 UTC 公历加 30 个自然日；算法是**两轮全局扫描**——先所有卖出的同日匹配，再所有卖出的 30 天匹配，买入一旦被消耗不可复用，余量归 Section 104。代码注释明确它「只描述匹配、不是税务计算」，**App 自身的已实现盈亏仍是 FIFO**。
- **Section 104 成本池**（`UKSection104Pool.swift`）：处置成本 = 匹配收购的实际单位英镑成本 + 池的加权平均成本 × 取用比例；卖超账本记录或汇率缺失返回 nil；给了 `expectedQuantity` 时再做 0.1% 勾稽。
- **隐含资金 `ImpliedFunding`**（`extension DailyTimeWeightedReturn`）：为「只有成交腿、没有现金腿」的账户重建 TWR 所需的外部资金流，三条假设——成交现金 = 数量×价格；某日现金为负即视为当日外部入金；交易解释不了的股份按窗口内首个收盘价转入。四个函数 `openingTransfers` / `closingTransfers` / `fundingShortfalls` / `close`。**不写回账本**，只在当次 TWR 重建时注入内存并写进 `assumptions`。

### 6.10 账户删除、重置与清理

- `deleteAccount` → `LocalPortfolioStore.removeAccount`：删该账户的 positions / transactions / knownAccounts，并从**每个历史快照的 `accountTotals` 中摘除**、按剩余账户重算该日总额，`accountTotals` 为空的快照整条丢弃；随后清首页缓存。
- `resetLocalPortfolio`：先把账本 `moveItem` 备份为 `portfolio-reset-{UUID}.json`，再清空内存态与 `portfolio.json`、首页缓存、账户选择。UI 明说「**券商授权和 AI 对话已保留**」——即 **Keychain 凭证不随重置删除**，必须由用户在对应设置页单独移除。
- 保护：`save` 用 `[.atomic, .completeFileProtection]`；Keychain 用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`；损坏的 `portfolio.json` 改名归档并提示重新导入。

### 6.11 估值与 FX 兜底链

`LocalPortfolioEngine.usdRate(for:)` 三级兜底：
1. `LocalCurrentFXCache`（UserDefaults `catfolio.currentFX.v1`），由 `LocalCurrentFXRefresh` 每 30 分钟节流刷新，数据源 Yahoo `{CUR}USD=X` 日线，FMP 备用；
2. **硬编码离线汇率表**（GBP 1.346 / EUR 1.163 / HKD 0.1275 / CAD 0.726 / AUD 0.655 / SGD 0.777 / JPY 0.0068 / CNY·CNH 0.139）；GBX 恒为 GBP/100；
3. 未知币种抛 `unsupportedCurrency`，**不会当作 0**。

`fxStatus` 文案直接暴露降级状态：「汇率缓存 · 日期；缺失币种使用离线估值」/「汇率未更新 · 使用离线估值，不适用于历史成交对账」。

**已知限制**：硬编码汇率是静态常量，与真实市场脱钩时只有文案提示无数值告警；`LocalCurrentFXRefresh` 只在 `refreshPortfolio` 的联网分支且持仓非空时触发；`GBPFXRates.swift:93` 的 `"GBp"` 分支**不可达**（`:91` 已 uppercase，`"GBp".uppercased() == "GBP"` 会命中 rate 1），便士口径在该函数里被当作英镑；展示层历史汇率走内置 ECB 包（离线），而 `enrich` 走 Yahoo 日线（联网），同一 FX 数字可能来自两个汇率源。

---

## 7. AI 流式实现

### 7.1 Provider 矩阵（源码核实）

`AIProviderPreference`（`LocalServices.swift:76-117`）五档：

| 枚举 | 标题 | 端点 / 模型 | 鉴权 | 联网 |
|---|---|---|---|---|
| `automatic` | 自动 | 按优先级依次尝试 | — | 视情况 |
| `apple` | Apple 本地 | `FoundationModels`（iOS 26 `#available`） | 系统 | 否 |
| `codex` | Codex | `https://chatgpt.com/backend-api/codex/responses` | OAuth 设备码登录（`catfolio.codex.oauth-credentials`） | 是 |
| `deepSeek` | DeepSeek | `https://api.deepseek.com/chat/completions`，模型 `deepseek-chat` | `catfolio.deepseek.api-key` | 是 |
| `openRouter` | OpenRouter | `https://openrouter.ai/api/v1/chat/completions`，默认模型 `openrouter/auto` | `catfolio.openrouter.api-key` | 是 |

`automatic` 的回退顺序为 **Apple → Codex → OpenRouter → DeepSeek**，每级失败记录原因，全部失败抛出聚合错误（`LocalServices.swift:4139-4171`）。

### 7.2 差异化能力

- **原生联网搜索只有 Codex 能做**：`researchAnswerWithNativeSearch` 强制要求 Codex 已连接，否则抛 `missingCodexConnection`（`LocalServices.swift:4186-4192`）。代码注释解释原因：Apple 本地模型无网络、DeepSeek API 无托管工具、Codex 端点可能支持 `web_search`。
- `researchAnswerAllowingSearch` 在 Codex 可用时优先进 Codex，自动模式下失败再退回普通阶梯（`LocalServices.swift:4194-4209`）。
- 公开研究（`researchAnswer`）**不加载也不发送**账户余额、凭证、持仓，与组合问答严格分离（`LocalServices.swift:4124-4126`）。

### 7.3 请求构造

`ChatCompletionsService`（`LocalServices.swift:4467-4514`）统一 DeepSeek 与 OpenRouter：

```swift
payload = [
  "model": model,
  "temperature": 0.2,
  "messages": [
    ["role": "system", "content": system],
    ["role": "user",   "content": user]
  ]
]
// 流式追加
payload["stream"] = true
payload.merge(streamingBody)   // OpenRouter: ["reasoning": ["effort": "medium"]]
```

- 超时：流式 90s / 非流式 45s。
- 请求头：`Accept: text/event-stream`（流式）、`Authorization: Bearer <key>`；OpenRouter 额外 `X-Title: Catfolio`。
- 系统提示词（`LocalServices.swift:4464-4465`）：
  - 组合助手：只依据手机提供的组合摘要回答，不虚构实时新闻或行情，明确声明不是投资建议。
  - 结构化输出：严格按 JSON schema 输出单个 JSON 对象，证据不足时遵循空结果规则，选股条件不支持的放入 `unsupported`。

### 7.4 流式解析（`AIStreaming.swift`，118 行）

`AIStreamEvent` 只有两种事件：`.reasoning(String)`（思维链增量）与 `.text(String)`（正文增量），均为**增量 delta**。

**Codex Responses 流**（`AIStreamParsing.codexEvents`，`AIStreaming.swift:20-40`）：
- `response.output_text.delta` → `.text`
- `response.reasoning_summary_text.delta` → `.reasoning`；用 `summary_index` 判断是否开启新段落，索引变化时先插入 `"\n\n"`
- `response.failed` / `error` → 抛 `LocalServiceError.remote(message)`

**Chat Completions 流**（DeepSeek / OpenRouter，`AIStreaming.swift:45-53`）：
- 从 `choices[0].delta` 同时取 `reasoning_content`（DeepSeek）与 `reasoning`（OpenRouter），以及 `content`
- OpenRouter 的**流中错误**特殊处理：HTTP 已是 200，错误藏在 `data:` 事件里，由 `chatCompletionError` 提取（`AIStreaming.swift:55-61`）
- `[DONE]` 判定：`isDone`（`AIStreaming.swift:64-66`）
- 统一的 `payload(_:)` 只认 `data:` 前缀、跳过 `[DONE]`、JSON 解析失败静默返回 nil（`AIStreaming.swift:68-73`）

### 7.5 流式渲染的三个关键机制

1. **打字机节流 `SmoothReveal`**（`AIStreaming.swift:81-90`）：固定 33ms 一帧（约 30fps），每帧揭示 `min(backlog, max(2, backlog/8))` 个字符——落后越多追得越快，既不抖也不明显滞后。
2. **半成品 Markdown 修复 `StreamingMarkdown.displayable`**（`AIStreaming.swift:96-107`）：未闭合的 ``` 代码围栏补 `\n```；落单的 `*` 删除；`**`、`` ` `` 奇数时补齐。保证流式过程中不会出现裸露的星号或吞掉整页的代码块。
3. **`StreamStartFlag`**（`AIStreaming.swift:112-118`）：`NSLock` 保护的跨线程标志，用于「已开始输出就不允许切换 provider」——只有还没吐出任何内容的失败 provider 才能降级到下一个。

### 7.6 竞态与取消

`AppModel.streamAI(_:)`（`APIClient.swift:685`）返回 `AsyncThrowingStream<AIStreamEvent, Error>`。审计修复 #15 明确：**每个 AI 请求绑定会话 ID 与请求代次**；新建、切换、删除、清空会话都会取消旧请求，迟到回答与错误被拒绝（`AIView.swift`）。回归测试覆盖「AI 供应商忽略取消仍迟到返回」的场景。

取消链路：`continuation.onTermination = { task.cancel() }`（`LocalServices.swift:4351`、`:4372`）+ 逐行 `try Task.checkCancellation()`（`:331`、`:4559`）+ UI 侧 `answerGeneration` UUID 代际校验（`AIView.swift:589-603`）。**已收到的部分回答会先落盘再报错**（`AIView.swift:671-682`）。

### 7.7 已确认的实现缺陷（高优先）

1. **`completeWithCodex` 吞掉 `structured` 参数**（`LocalServices.swift:4308-4315`，调用点 `:4137-4138`）。`.codex` 模式下 `researchAnswer(..., structured: true)` 返回自然语言，而 `SecurityDebateStore`、`PolicyRunCoordinator:242`、`PolicyComposerStore:475` 都按 JSON 解析；`automatic` 模式下 Codex 排在 OpenRouter/DeepSeek 之前，这条路径会被真实命中。
2. **`briefing` 的 prompt 写死中文**（`LocalServices.swift:3805`）：`"请生成一段简洁的中文组合简报…"`。英文界面下仍要求中文，语言仅靠 system prompt 兜底——用户可见的本地化缺陷。
3. **主 attention prompt 漏加语言指令**（`:3877-3890`），而同文件 `:3987`（followUpAttention）、`:4024`（rejudgeAttention）都追加了 `L10n.responseLanguageInstruction`——不一致。
4. **对预置问题并非真流式**：`requestCompletion` 请求体仍写 `"stream": true`（`:471`）却用 `Self.session.data(for:)`（`:488`）整包接收，再解析 SSE；`streamPublicResearch` 拿到全文后一次性 `yield(.text)`（`:4332-4339`），与「as the model writes it」的注释不符。只有 `streamAnswer` 是真流式。
5. **`try? await complete(...)` 静默降级**（`:3891-3895`）：AI 调用失败时静默返回只有价格档的 report，用户看不到「模型失败」，只会看到一份没有 thesis 的分析。另有两处空 catch（`:3993-3995`、`:4205-4208`）。
6. **对比缓存文件名不含语言但内容语言化**：`ComparisonSnapshotCache` 文件名 = `SHA256(scope)`，而 `scope = [mode] + sorted(accountKeys)`（`APIClient.swift:339-342`）**不含语言**，但 fingerprint 的 Inputs 含 `language`。跨语言切换会覆盖同一文件并重建，与 README「组合研究缓存分语言保存」的措辞存在偏差。
7. **聊天页没有多轮上下文**：`streamAnswer` / `complete` 不把历史消息发给模型，只发「当前问题 + 组合概要」（`:4357-4374`、`:4107-4113`）。唯一的多轮是 `followUpAttention` 手工拼 `history.suffix(4)`（`:3973`），仅用于持仓关注卡追问。
8. **研究落盘缺保护**：`security-developments-v2.json` 与 `security-price-moves-v1.json` 既无 `.completeFileProtection` 也无 `isExcludedFromBackup`（`SecurityDebateStore.swift:252`、`:420`），与 `ai-chat-history.json`（两者都有）不一致；两文件日期策略也不一致（`.iso8601` vs `.deferredToDate`）。
9. **SSE 多行 `data:` 未合并**：每行独立解析，SSE 规范允许的跨行 event 会被丢弃；未知事件类型静默忽略。
10. **AI 路径完全没有 429 处理**：无 Retry-After、无退避，流式不重试；用户看到厂商原文或 `"AI 请求失败（429）"`。429 专门文案只存在于 FMP/行情侧（`FMPRateLimiter.swift:61` 等），不可误认为 AI 重试。
11. **自动回退错误信息会误导**：DeepSeek 是无条件兜底，即使没有 Key 也会被尝试并失败，于是错误串里永远带一条 DeepSeek 失败；而没有 Key 的 OpenRouter 被静默跳过、不出现在错误串里。
12. **硬编码私有端点与常量**：`chatgpt.com/backend-api/codex/responses`（非公开文档 API）、模型名 `"gpt-5.4"`、Codex clientID。只有 400 时「去掉 reasoning summary 重试」这一层防御；模型下线或后端变更即整体失效。
13. **Apple 流式差分的隐含假设**：`streamWithApple` 只在 `content.hasPrefix(written)` 时推进，若快照非单调则**静默丢输出**；最终仅以「非空」作为成功条件（`LocalServices.swift:4451`、`:4459`）。
14. **`LocalChatStore.clear()` 是死代码**（`:249-252`），已无调用方。

### 7.8 与文档声称的差异

| 文档位置 | 声称 | 实际 |
|---|---|---|
| `CatfolioIOS/README.md:50` | 「AI 可选直连 DeepSeek」 | **低估**：实际 5 档 provider |
| `CatfolioIOS/README.md:50` | 问答历史排除 iCloud 备份 | ✅ 对 `ai-chat-history.json` 成立；❌ 对 developments / price-moves 两文件不成立 |
| `CatfolioIOS/README.md:99` | 新闻使用对应 Yahoo 语言/地区参数 | ❌ Yahoo 硬编码 `lang=en-US&region=US`（`SecurityDebate.swift:155-156`）；GDELT 硬编码 `sourcelang:english`；正文抓取硬编码 `language:"en"` |
| `docs/ios-feature-inventory.md:137` | 自动模式顺序为 Apple → Codex → DeepSeek | ❌ 漏 OpenRouter，实为四路 |
| 功能清单 / 任务描述 | 「个股正反方辩论」多智能体 | ❌ **未实现**，且 prompt 明文禁止 |

---

## 8. 金融计算引擎清单

### 8.1 引擎总表

| 引擎 | 文件 | 调用方 | 测试 | 口径要点 |
|---|---|---|---|---|
| 组合估值与持仓汇总 | `LocalPortfolioStore.swift` → `LocalPortfolioEngine` | 首页、持仓、ETF | `LocalPortfolioEngineTests` | 估值 FX 有缓存与固定值兜底，不用于历史成交对账 |
| 资金加权收益 MWR | `Models.swift` → `MoneyWeightedReturnCalculator` | `LocalServices`、`LocalPortfolioEngine` | `MoneyWeightedReturnCalculatorTests` | 不能与 TWR 混称 |
| 时间加权收益 TWR | `DailyTimeWeightedReturn.swift` | 收益页 | 审计 #06 | 真实价格与汇率涨跌计入 TWR；仅在不完整账本模式下用隐含资金估计转入/转出 |
| 隐含资金流 | `ImpliedFunding.swift` | TWR 重建 | `ImpliedFundingTests` | 不写回账本，只在内存注入并写入 assumptions |
| 已实现盈亏 / FIFO | `RealisedProfitCalculator.swift` | `HistoryView` 收益汇总 | `RealisedProfitCalculatorTests` | 优先保留可用券商结果，缺失时本地重建；成本不足须显式保留 |
| 拆股调整 | `StockSplitCatalog.swift` | CSV 重建、FIFO、历史匹配、FX | `StockSplitTests` | 美股资源为主，非完整公司行动引擎 |
| 英国匹配 / 成本池 | `UKShareMatching.swift` / `UKSection104Pool.swift` | `HistoryView`（前者） | `UKShareMatchingTests` / `UKSection104PoolTests` | 已实现同日/30 天/Section 104，**非完整报税系统** |
| GBP 历史换算 | `GBPFXRates.swift` | 本地历史换算与 FX 链路 | `FXImpactTests` | 允许有限前值回退，回退值标为估算 |
| 汇率影响 | `FXImpactCalculator.swift` + `LocalFXImpactCalculator` | 展示链路 | `FXImpactTests` | **两套实现并存**：剩余成本法（GBP 口径）与当前价法（USD 口径） |
| ETF 穿透 | `LocalETFookThrough`（`LocalServices.swift`） | `APIClient`、热力图 exposure 模式 | `ETFLookThroughExpansionTests` | 精确基金快照优先，部分 ticker 用指数代理 |
| 行业归类 | `CompanyReferenceCatalog.swift`、`SectorAttribution.swift` | 持仓分类、今日归因 | `SectorAttributionTests` | 不是完整历史证券生命周期解析器 |
| 损益归因 | `HoldingContributionChart.swift`、`LossAnalysisChart.swift`、`SectorAttribution.swift` | 首页、今日详情 | `HoldingContributionTests` | 按持仓市值与最近报价推算 |
| 回撤分析 | `UnderwaterAnalysis.swift` / `UnderwaterAnalysisChart.swift` | 收益分析 | `UnderwaterAnalysisTests` | 水下曲线与最大回撤 |
| 周期对比 | `CycleComparison.swift` | 研究区 | `CycleComparisonTests` | 年度周期 + 本年分红预测；负轴保留负号（审计 #19） |
| 基金会费 | `FundFeeCatalog.swift` | History 费用卡 | `FundFeeTests` | 按当前市值 × 已取得年费率**估算**，不是实际扣款 |
| 账本对账 | `LedgerReconciliation.swift` | 设置页 | `LedgerReconciliationTests` | 报告不等于自动修复 |
| 公开投资者模拟 | `PublicInvestorCatalog.swift` | 佩洛西模式 | `PublicInvestorCatalogTests` 等 | 13F / PTR 模拟账本，含拆股与诊断文件 |
| 管理层兑现 | `ManagementDelivery*.swift` | 个股研究区 | `ManagementDeliveryTests` | 规则判定数字，设备端 AI 提取 |
| 策略执行 | `PolicyExecution.swift` 等 | Policy 编曲家 | `PolicyShortcutTests` | 只读模拟，不下单 |

### 8.2 拆股与公司行动的六处一致使用

`quantity × factor` / `price ÷ factor` 在以下六处口径一致：
`LocalPortfolioStore` CSV 重建（`:2443`）、`FXImpactCalculator` FIFO（`:108`）、`UKSection104Pool`（`:122`）、`UKShareMatching`（`:98`）、`LedgerReconciliation`（`:68`）、`LocalServices` TWR 重建（`:2571`）。

### 8.3 涉及的关键公式

**FX 影响（主口径，USD 存储）**
```
impact_account = Σ_lot [ qty_lot × price_now × (rate_now_asset→account − rate_open_asset→account) ]
impact_usd     = impact_account × rate_account→USD
```

**FX 影响（兜底口径，GBP 目标，基于剩余成本）**
```
fx = Σ_lot [ cost_lot × (1 / rate_now − 1 / rate_open) ]
```

**MWR / TWR 差异**：MWR 用现金流加权（`AccountMWRLedger`），TWR 用每日估值链式乘积；不完整账本时 TWR 依赖 `ImpliedFunding` 的假设性外部资金流。

**TWR 逐日公式**（`DailyTimeWeightedReturn.calculate`，源码逐行核实）：

```
capital = previous_value + inflow
growth  = (value + outflow) / capital        // capital > 0 时
nav    *= growth                              // nav 初值 1
```

其中 `value` = 当日现金（按当日汇率折 USD） + Σ(持仓数量 × 当日报价折 USD)。硬约束：

- 期初余额为零，**截断的账本必须显式提供期初资金/持仓事件，绝不用今天的持仓反推**；
- **价格/汇率变动永不产生合成现金流**；只有 `external` 事件改变资本；
- 内部转账按 `transferID` 配对，必须跨账户且各币种净额为零，否则报错；
- 现金为负（< -0.01）、持仓数量为负、缺报价或缺汇率 → 直接抛错（**不用 0 或估算冒充**）；
- 只有当 `inferUnfundedShareTransfers = true` 时，才把「无现金腿的证券数量变动」按当日价格估作转入/转出，并记入 `inferredShareTransfers` 与展示层 assumptions。

**收益页三口径**（`ReturnsChartMode`，源码核实）：`cashFlowMatched`（「现金流镜像」）、`twr`（TWR）、`mwr`（MWR）。三者各自在数据不足时给出独立文案，例如「现金流镜像：缺少完整资金账本和账户估值，暂不可用」「MWR 至少需要两个日期的组合价值与一笔有效现金流」——**缺数据不等于零收益**。

**今日归因**：按持仓市值 × 最近报价涨跌推算，**未计当日买卖影响**（已知边界）。

### 8.4 Policy 策略引擎

#### 数据模型

共享契约是**一份 JSON Schema**（`Resources/strategy.schema.json`，1,307 行，draft 2020-12，`$id: urn:catfolio:strategy:1`）。Swift 侧不生成第二套模型，用 `indirect enum PolicyJSON`（`PolicyContract.swift:5-41`）做类型化 JSON，**数量一律用十进制字符串**保存以避免 Double 精度问题。

- 顶层：`kind` / `schemaVersion` / `strategyId` / `revision` / `name` / `mode`（`ANALYZE` 或 `SIMULATE`）/ `accountScope` / `dataPolicy` / `statePolicy` / `nodes` / `outputs`；全程 `additionalProperties: false`。
- `quantity` 是**二态**：`{state:"UNRESOLVED", reason}` 或 `{state:"RESOLVED", value:"<十进制字符串>", unit, currency?}`；`CURRENCY`/`PRICE` 必须带 currency 且不得为 `GBX`。
- 跨字段约束：**只要 nodes 含 `state` 类型，mode 必须为 SIMULATE**。
- 运行记录 `runArtifact`：`runId` / `runRevision` / `strategyHash`(sha256) / `status`（QUEUED/RUNNING/SUCCEEDED/INCOMPLETE/FAILED/CANCELLED）/ `steps[]` / `proposedStateDelta[]` / **`actionPolicy` const `NO_ORDERS`**。
- `$defs/observation`（VERIFIED/ESTIMATED/UNKNOWN 观测模型）在 schema 中定义完整，但**当前执行链未使用**。

#### 用户如何编写

三条并行路径，操作同一份文档：
1. **一句话 → AI 生成步骤**：提示词为 `PolicyShortcut.generationGuide` + 完整示例；**失败可自纠一次**（把验证错误回给模型重试）。AI **不能改身份、账户与数据策略**——`kind`/`schemaVersion`/`strategyId`/`revision`/`dataPolicy`/`statePolicy`/`accountScope` 一律被本地值强制覆盖，并拒绝重复 JSON key。候选落盘为 `PENDING_CONFIRMATION`。
2. **卡片手工编排**：动作库按 5 类列出 12 种动作（`risk`/`guard`/`state` 标为「高级」）；新节点自动接到「前面最近的兼容节点」，未定数值一律写成 `UNRESOLVED`。
3. **策略库**：用户自己的策略，支持新建/复制/删除/切换；历史页可查看运行记录与旧版本并恢复（恢复生成新 revision）。

**没有内置成品策略模板库**——`PolicyTemplates.swift` 里是节点工厂 + 中文摘要 + 空白文档，新手引导只有空态里的 3 句示例。

**关键规范化**（`PolicyShortcut.normalized`）：自动把叶子节点写成 `outputs`；**只要含 `size`/`risk`/`guard`/`state` 就把 mode 改成 SIMULATE**；账户范围始终同步设置页选中账户；`maxAgeDays` 默认 7 天。

**持久化**：`PolicyWorkspaceStore`（actor）——每策略一个原子文件 `Catfolio/Policies/<uuid>.json` + `revision-<n>.json` + `candidates/`；**草稿与已验证文档分开存**，`save` 有 generation 乐观并发检查，冲突时报「策略已在另一处更新……草稿尚未覆盖」，**非法自由文本永不覆盖上次合法文档**；上限 256 KB，`.completeFileProtection`；UI 侧 450ms 防抖保存，每次实质改动 +1 revision。

#### 12 种节点与条件

| 节点 | 作用 | 关键约束 |
|---|---|---|
| `source` | 选择证券 | SELECTED_HOLDINGS / EXPLICIT_SECURITIES |
| `indicator` | 计算指标 | **只注册 5 个**：`price` / `return` / `sma` / `rsi` / `volatility`；`methodologyVersion` const "1"；窗口上限 250 交易日 |
| `filter` | 筛选条件 | LT/LTE/EQ/GTE/GT/NE；阈值单位须与指标一致 |
| `any` / `all` | 满足任一 / 全部 | **三值逻辑**——缺数据保留 UNKNOWN，既不算通过也不算不通过 |
| `if` | 条件分支 | `unknownPolicy` const BLOCK |
| `sort` | 排序 | ASC/DESC；`nullPolicy` EXCLUDE/LAST；`tieBreak` const SECURITY_ID_THEN_LISTING_ID |
| `size` | 目标配置 | TARGET_WEIGHT / FIXED_AMOUNT / FIXED_SHARES；denominator NAV/AVAILABLE_CASH/NOT_APPLICABLE |
| `risk` | 风险检查 | **只注册** `max_position_weight` |
| `guard` | 执行保护 | unknown 与 failure **均 const BLOCK** |
| `ai` | AI 研究 | **只注册** `promptTemplateId = price-evidence-thesis`；`evidencePolicy` const REQUIRE_CITATIONS |
| `state` | 模拟状态 | READ / PROPOSE_SET；**只允许 SIMULATE**；同一 key 只能有一个 PROPOSE_SET |

**指标实现**：`price` 取最后收盘；`sma` 均值；`return = 100*(last/first-1)`；**`rsi` 是 Cutler RSI（非 Wilder）**，无涨跌时返回 50；`volatility` = 对数收益样本标准差 × √252 × 100。

**端口/单位校验先于执行**：`PolicyCapabilities.diagnostics` 是能力白名单，拦截空图、无 outputs、无账户、任何 `UNRESOLVED` 数量、`priceBasis != SPLIT_ADJUSTED`、端口类型不兼容、未注册的 metric / risk / AI 模板等；**未知节点类型直接 `UNSUPPORTED`，绝不静默跳过**。

#### 执行时如何取行情

`PolicyMarketAdapter`（94 行，actor，只读——文件头明确「never calls a broker, submits an order, alters FX tables or writes the portfolio」）：
1. 按 `accountScope.accountIds` 冻结持仓；合成组合直接拒绝；账户必须存在且非空，**不允许自动扩展为全部账户**。
2. `asOf` 必须可解析、不晚于现在，且**只支持今天**；用 `PolicyUSSessionCalendar.completedSessions` 算已完成交易日。
3. **只支持 `market == "US"` 且 `currency == "USD"` 的美股**；起始日硬编码 `"2026-01-01"`。
4. 逐持仓调 `historicalCloses(..., dividendAdjusted: false)`——**split-only 复权**，与 UI 的复权序列共用 actor 但走不同缓存 key。
5. **单只失败不中断整个 run**：生成 `issue` 非空的 snapshot，该证券**进不了任何 indicator**，因此任何步骤都不可能判为「通过」；全部无价格才抛错。
6. 每取到一只立即 `onCapture` 落盘——**断点续跑靠这个**。
7. SIMULATE 的 `simulationBudget` 要求**完整 NAV（含现金）与同币种持仓估值**，任一无法估值即返回 nil，size 节点以 `reasons["budget"]` 拒绝出目标，而不是把持仓市值冒充账户预算。

> **⚠️ 交易日历硬编码只覆盖 2026 年**（`PolicyExecution.swift:12`），**2027 年起策略将完全无法运行**——这是一项有明确到期日的功能。

#### 运行追踪、后台与失败

- **三层追踪**：运行记录本体（artifact + 当时的策略原文 + 冻结持仓 + 行情快照 + 每节点每端口输出 + **inputHashes**）；存储为 `Catfolio/PolicyRuns/run_<id>/<08d>.json`（**每个 runRevision 一个不可变文件**）；`PolicyRunTrace` 把记录反向读成因果——每步状态、按交付输出分组的行、以及 **`excluded`**（每个「开始了但没进最终结果」的证券，附**被哪一步、因为什么**放掉）、`dataDate`、`isStale`。
- **续跑**：只重启 RUNNING/UNKNOWN/FAILED/CANCELLED 的步骤并 `attempt +1`；SUCCEEDED/CANCELLED 的运行不会自动重启。
- **后台运行**：用 **`BGContinuedProcessingTask`**（iOS 26+），**不是** `BGAppRefreshTask`/`BGProcessingTask`。**必须在 App 前台发起**；iOS < 26 直接前台执行。identifier 每次运行现生成（`com.catfolio.ios.policy.<UUID>`，靠 Info.plist 通配匹配），`registered` 集合只增不减。系统到期 → `interrupt()` → 状态 **INCOMPLETE**，**不自动续跑**。**没有注册任何周期任务，策略不会自动定时运行。**
  > **⚠️**部署目标是 iOS 18.0，因此**「后台运行」实际是 iOS 26 独占能力**；iOS 18–25 上离开 App 即暂停。
- **失败分档**：草稿非法 → 上次合法文档不被覆盖；能力预检失败 → **拒绝启动**；单节点数据不足 → 步骤 UNKNOWN、run 为 **INCOMPLETE（不是 FAILED）**；AI 证据不全 → **不发请求**；AI 返回非法 JSON → 给模型一次带错误的重试；取消/到期 → 已完成步骤与输入全部保留。
- **结果展示**：就地嵌在编辑器步骤列表下方（状态徽标、stale 提示、按输出分组的卡片、每行逐步轨迹、以及「没入选的 N 只，和原因」）；运行结束自动滚到结果；历史页可回看任意一次 run 的 trace。

#### 下单能力

**没有。** 三重证据：契约常量 `NO_ORDERS`（schema + 运行时写死）；`PolicyMarketAdapter` 文件头声明只读、全仓 `Policy*.swift` 搜下单 API 只命中该常量；UI 文案 5 处反复声明「不会下单」。`state` 节点只产出 `proposedStateDelta`（`commitPolicy` const `RETURN_DELTA_ONLY`），**只返回提案、不提交**；AI 节点 `approvalPolicy` 也是 `CANDIDATE_REQUIRES_CONFIRMATION`。

**产出上限**：筛选/排序后的证券清单 + 目标仓位提案 + 风控判定 + 一段带引用的 AI 摘要 + 本地通知。

### 8.5 图表基建：`StandardLineChart`（2,396 行）

单一渲染器，**1 个 init（约 40 个具名参数，35 个有默认值）+ 4 个外围骨架组件**，**没有链式 `.modifier` 配置**。消费者 9 处（Returns、Portfolio、VolumeProfile、ReturnsAnalytics、IndustrySentiment、Underwater、LossAnalysis、HoldingContribution、CycleComparison）。

**渲染方式**：纯 SwiftUI `Canvas` + `GraphicsContext`，`Path()` 手工构建折线/面积/条纹。**本文件无 `UIViewRepresentable`、无 `CGContext`**。

**性能策略——多数是「没有」**：
- ❌ 无 `drawingGroup()`、无 `Canvas(rendersAsynchronously:)` → **全部同步主线程绘制**；
- ❌ **无 LTTB / 无降采样**。抽稀只在部分调用方等距步进（成交量分布固定 150 点、周期对比固定 96 步）；Returns 与 Portfolio 把原始序列直接交给渲染器，Path 顶点数无上限；
- ✅ 预计算缓存（viewportPaths / morphPairs 每次更新构建一次、个股详情一次算完 10 个时间范围、成交量 bar 缓存 24h）；
- ✅ 手写指纹 diff：每条 series **每 8 个点抽 1 个** + 首尾——有意近似，第 3、11、19… 点的单点变化在 transitionKey 不变时可能不刷新。

**坐标系**：X 轴按时间比例线性映射；**Y 轴刻度由调用方传入（`yTicks: [Double]`），渲染器不做 nice numbers**——全项目 **8 处手写等分公式**，唯一 nice-number 实现却只喂自绘标签。**X 轴只有首尾两个日期标签。无对数坐标。**

**手势**：**没有 SwiftUI `DragGesture` / `MagnificationGesture`（捏合缩放全项目 0 命中）**。全部走 `ChartInteractionOverlay: UIViewRepresentable` + 自研 `ChartDetailGestureRecognizer`：
- **长按激活**（非拖动），`activationDuration 0.23`，手动置 `state = .began`；
- **冲突处理**：`allowableMovement = 10`，超限立即失败让位给外层 `ScrollView` 垂直滚动；系统边缘（x < 20）让位给返回手势；
- **双指测距**：第二指加入时切 `.changed` 不重启识别，≥2 个日期即走 `onMeasure`；
- **十字准线**：玻璃竖线 + 每 series 一个选择点 + 顶部日期气泡；命中测试为线性反解 + 二分最近日期。

**动画**：`StandardLineChartTransitionDriver: Animatable`，`animatableData = progress`，**每次插值重跑 Canvas 绘制闭包**（而非对 layer 补间）。进场 `timingCurve(0.22, 1, 0.36, 1, 0.45)`；揭示 `linear(0.9)` + 手写 `easeOutQuart`；打断用 `transitionGeneration` + `Task.yield()` 丢弃排队动画，并从「最后一帧实际画出的形状」起步。拖动**不发布 SwiftUI 更新**（进度对象是纯 class 而非 `Observable`）。`reduceMotion` 全路径降级。

### 8.6 热力图与 treemap

**`HoldingsTreemapLayout` 是真 squarified treemap**：面积权重 = 市值（只接受有限且 > 0 的权重），用 worst-aspect-ratio 的**迭代式贪心**决定封行；先除以最大权重再求和以防溢出；条带切分宽 ≥ 高则竖切，**最后一个 tile 吃掉剩余长度以消除浮点缝隙**；布局内零 padding，gutter 由调用方 inset。

**分组维度是行业，不是资产类别**。颜色映射**没有插值色带，只有固定色 + 变透明度**：阈值 |Δ| < 0.005% 视为中性，满强度点 3%，透明度区间 [0.12, 0.34]。裁剪：持仓模式最多 20 块（**前 4 名无条件保留**），ETF 穿透最多 28 块；行业模式另有基于**实际布局尺寸**的二次合并（`while true` 反复重排直到每块都能显示 ticker）。文字**不做任何测量**，全靠尺寸阈值硬编码。

**`PerformanceHeatmapHero` 不是时间 × 持仓的二维矩阵**，而是把热力图渲染成纹理贴在等距平面上的动画容器；渲染键变化才重新烘焙（延迟 100ms）。

**⚠️ 实验代码与生产类型同文件耦合**：`IsometricHeatmapLab.swift` 文件头自认「An experiment」，但同时定义了生产 hero 依赖的 `IsometricBands` / `IsometricLayer` / `IsometricEdgeEffects` / `View.liveBlur`——**按文件名当实验代码整体删除会直接编译失败**。它还有 release 可达入口，并且内置 `sample` 假数据，是全项目唯一用假数据渲染真实 UI 的地方。

### 8.7 轮动图（RRG / 板块轮动）

**Swift 端只有渲染，没有任何 RRG 计算**：

- **StockCharts RRG**：`jdkratio` / `jdkmom` 是**来源服务器返回的原值**，象限判定就是 `>= 100` 中线二分；尾迹取最后 30 周；坐标是纯线性缩放。注释自认「Uses source coordinates on linear axes around 100. No MAD, tanh, or resampling.」取数用隐藏 `WKWebView` 注入 JS 钩住 `XMLHttpRequest`/`fetch` 截获页面自身 XHR。
- **板块轮动 v2**：`x` / `y` / `relativeTrend` / `relativeMomentum` / `quadrant` / `trail` **全部由 JSON 提供**（服务端契约），Swift 侧只有参数硬校验（`calcVersion == 2`、`benchmark == "SPY"`、窗口与平滑参数固定）。x/y 的 tanh/MAD 公式**只以 UI 说明文字存在，Swift 未实现**。

UI 结构是「SwiftUI 外壳 + UIKit 内核」：状态在 SwiftUI 视图，绘图与手势在 `SectorRotationUIKit` / `StockChartsRotationUIKit`。**既有跨功能耦合**（RRG 图把板块轮动图当氛围背景层），也有**两种不同曲线插值**（三次 vs 单调保形）。

**数据时效**：`sector_rotation_history.json` 实测 60 个快照（2026-06-15 … 2026-09-09），最新 `validUntil` = 2026-09-10T22:30Z → **已过期**。

---

## 9. 测试与质量

### 9.1 规模

- **52 个测试文件 / 11,844 行**（`CatfolioIOSTests/`），共 **716 个 `func test`、75 个测试类**，全部在单一 test target 内（**无 UI test target**）。
- 审计记录的全套结果为 **658 项：657 通过、1 跳过、0 失败**（`docs/audits/ios-2026-09-13/FIXES.md:42`）。
- 明确排除真实网络测试：Earnings、公开投资者的 live 测试显式排除；`SecurityDebate` 实时测试按 opt-in 条件跳过。
- **5 个文件名与内部类名不一致**（如 `HoldingDetailInteractionTests` → `HoldingResearchVisibilityTests`、`SectorAttributionTests` → `PortfolioSectorTests`），检索成本高。

### 9.2 覆盖地图

| 域 | 测试文件 |
|---|---|
| 组合引擎/账本 | `LocalPortfolioEngineTests`、`PortfolioAccountAggregationTests`、`LedgerReconciliationTests`、`BrokerResultPreservationTests`、`PortfolioDocumentMergeTests` |
| 收益计算 | `MoneyWeightedReturnCalculatorTests`、`RealisedProfitCalculatorTests`、`UKSection104PoolTests`、`UKShareMatchingTests`、`StockSplitTests`、`ImpliedFundingTests`、`FXImpactTests`、`FundFeeTests` |
| 行情/穿透 | `ETFLookThroughExpansionTests`、`SectorAttributionTests`、`HeatmapRemainderReturnTests`、`HeatmapRowTapTargetTests`、`HoldingsHeatmapAggregationTests`、`HoldingContributionTests`、`UnderwaterAnalysisTests` |
| 研究功能 | `AnalystConsensusDataTests`、`NasdaqAnalystLogicTests`、`EarningsHistoryTests`、`InsiderTradesTests`、`ManagementDeliveryTests`、`RevenueSegmentsTests`、`CompanyCIKSeedTests`、`SectorRotationTests`、`StockChartsRotationTests`、`StockScreenerRulesTests`、`CycleComparisonTests` |
| 模拟账户 | `PublicInvestorCatalogTests`、`PublicInvestorSelectionTests` |
| 平台/交互 | `HistoryInteractionTests`、`HoldingDetailInteractionTests`、`HomeScrollInteractionTests`、`SettingsInteractionTests`、`PageLoadAndJitterTests`、`AIConversationLibraryTests`、`AIStreamingTests`、`LocalizationTests`、`TypographyTests`、`CompactNumberRuleTests`、`CurrencyFormattingTests`、`NumericAlternatesTests`、`CloudPreferencesTests`、`PortfolioPresentationCacheTests`、`SnapTradeTests`、`Trading212FillDecodingTests`、`PolicyShortcutTests`、`SecurityDebateResearchTests`、`AuditRegressionTests` |

### 9.3 测试策略特征

- 大量**交互级测试**（`HoldingDetailInteractionTests` 1,077 行、`HistoryInteractionTests` 574 行、`HomeScrollInteractionTests` 553 行），不只是纯函数单测。
- `AuditRegressionTests`（385 行）固化 2026-09-13 审计的 20 项修复。
- 存在 Python 侧调用 Swift 生产函数的运行时回归（见审计证据）。
- **已知局限**：真实券商在线同步、多设备 iCloud 传递、长时间运行仍未验收（`FIXES.md:32,47`）。

---

## 10. 资源与打包

### 10.1 内置 JSON 资源（体积）

| 文件 | 大小 | 消费方 |
|---|---|---|
| `company_reference.json` | 11.6 MB | `CompanyReferenceCatalog`（离线证券目录、行业归类） |
| `public_investors.json` | 3.0 MB | `PublicInvestorCatalog`（佩洛西模式） |
| `etf_holdings.json` | 3.7 MB | ETF 穿透 |
| `revenue_segments.json` | 3.0 MB | `RevenueSegmentCatalog` |
| `gbp_fx_daily.json` | 2.7 MB | `GBPFXRates` |
| `fund_fees.json` | 1.9 MB | `FundFeeCatalog` |
| `stock_splits.json` | 1.1 MB | `StockSplitCatalog` |
| `sector_rotation_history.json` | 564 KB | 板块轮动 |
| `analyst_history_catalog.json` | 770 KB | 分析师历史 |
| `stockcharts_rrg_reference.json` | 24 KB | RRG |
| `industry_sentiment.json` | 20 KB | 行业情绪快照 |
| `etf_sector_composition.json` | 3 KB | 行业构成 |
| `analyst_history_aapl.json` | 9 KB | 示例 |
| `strategy.schema.json` | 30 KB | Policy 契约校验 |

### 10.2 图片资源

- `Resources/AssetLogos/`：**1,077 个股票 logo PNG**，以 **blue folder reference 整目录打包**；运行时按 `Bundle.main.url(forResource: symbol.uppercased(), …, subdirectory: "AssetLogos")` 取用，失败回退 FMP 远程 `image-stock/<symbol>.png`，并有磁盘缓存与 Brandfetch 符号表（`brandfetch-symbols.json`）。
- `Assets.xcassets/`：32 个 imageset（其中 21 个为源码可见的 SVG/PNG imageset）+ `AccentColor.colorset`（sRGB 0.439/0.549/1.0 ≈ blue500）。Tab 图标 8 个（Portfolio/Performance/Research/Settings × Selected/Unselected）+ `TabAI`。
- **App 图标有两套配置**：真图标是 Icon Composer 工程 `AppIcon.icon`（`icon.json` 声明 glass + translucency + neutral shadow）；`Assets.xcassets/AppIcon.appiconset` **只有 `Contents.json`、没有任何 PNG**——未清理的空壳。
- `Resources/catfolio-daily-brief/`（blue folder）：`SKILL.md` + `references/cases.json` + `routing.json`，由 `SecurityDailyMoveSkill` 消费，同时驱动界面提问选择与 AI 提示词；README 未提。其中 `cases.json`（14 条合成用例）代码中未见读取。
- `PrivacyInfo.xcprivacy` 已编入 Resources。

### 10.3 打包脚本

- `CatfolioIOS/scripts/make_gbp_fx_resource.py`（生成 GBP 汇率资源）。
- 仓库根 `scripts/`：包含 `export_ios_public_investors.py`（更新公开投资者离线包，当前发布 `d2bffff934734d16`，截至 2026-09-07）、`check_ios_localizations.py`（本地化一致性）。
- `CatfolioIOS.xcodeproj/xcshareddata/xcodecloud/manifest.json`：已配置 Xcode Cloud。

---

## 11. 风险与技术债

### 11.1 结构性问题

1. **巨型文件**：`LocalServices.swift` 4,992 行、`VolumeProfileView.swift` 4,433 行、`PortfolioView.swift` 3,279 行、`AIView.swift` 2,770 行、`DesignSystem.swift` 2,742 行、`LocalPortfolioStore.swift` 2,705 行。前六个文件占全 App 约 **30%** 代码量。
2. **单 target 扁平组织**：111 个文件同目录，无 Feature 模块边界，无法增量编译隔离，合并冲突面大。
3. **无 DI 容器**：服务多为 `.shared` 单例 + 静态方法，测试替身只能靠 `AppModel.init` 的四个注入参数。
4. **计算引擎未抽包**：`ENGINE_CATALOG.md` 明确「大部分计算仍在 iOS 的 Swift 文件中」，跨端复用只能靠复制。

### 11.2 遗留与死代码（源码扫描结果）

扫描全部 111 个文件的类型声明与引用，得到 23 个未在 App 代码中实例化/引用的类型：

| 类型 | 文件 | 状态 |
|---|---|---|
| `ETFLookThroughView` | `ETFLookThroughView.swift` | 完全无引用（实际走热力图 exposure 模式） |
| `PolymarketMarketsSection` | `PolymarketMarketsView.swift` | 完全无引用（实际用 `PolymarketEventCard`） |
| `AccountTransactionsView` | `SettingsView.swift` | 完全无引用 |
| `PortfolioDocumentMerge` | `PortfolioDocumentMerge.swift` | 仅测试引用 |
| `UKSection104Pool` | `UKSection104Pool.swift` | 仅测试引用 |
| `SecurityPriceMoveSheet` | `SecurityDebateView.swift` | 仅测试引用 |
| `AskResponse` / `BriefingResponse` / `BrokerConnectionResult` / `BrokerConnectionState` / `BrokerOverview` / `BrokerRefreshEnvelope` / `ComparisonPoint` / `HoldingsResponse` / `SaveSettingResponse` | `Models.swift` | 完全无引用（旧 API 模型残留） |
| `ChartLegendItem` / `ToolbarIconButton` | `DesignSystem.swift` | 完全无引用 |
| `HoldingDetailModalHandle` / `HoldingMetric` / `SecurityPriceCostLegend` | `VolumeProfileView.swift` | 完全无引用 |
| `SettingsFieldButton` / `SettingsSegmentBar` | `SettingsTemplate.swift` | 完全无引用 |

（`CatfolioIOSApp` 为 `@main` 入口，属扫描误报，不计入。）

另有**方法/字段级**死代码（深挖发现，均已 grep 复核）：

| 项 | 位置 |
|---|---|
| `SettingsSegment`、`LocalMarketDataClient.testFMPConnection`、`LocalAIClient.researchAnswerAllowingSearch`、`currentWeightModelSeries`（约 71 行）、`LocalChatStore.clear()`、`SectorPerformanceDefinition.definition(for:)` | 全仓 0 引用 |
| `SettingsView` 的关闭按钮分支不可达（`showsCloseButton` 无调用点传 `true`） | `SettingsView.swift:371-379` |
| `PortfolioActivityKind.deposit/withdrawal/transfer` 的标题与图标 | 不可达（`:1319` 已过滤） |
| `HistoryCategory.fees.includes` 恒 false | `HistoryView.swift:37` |
| `forwardPE`（恒 nil，使其分支永不生效）、`VolumeProfile.available` / `.valueAreaPercent`、`ETFLookThroughResponse.otherWeightPercent`、`Dataset.benchmark`、`holdingsAsOf/holdingsSource` | 死字段 |
| `selectDrawableModeIfNeeded`（四分支全 `break`）、`returnsWarning`、`comparison.available`（从未被视图检查） | 死路径 |
| `$defs/observation` | schema 有定义，Swift 无引用 |
| `Resources/analyst_history_aapl.json` | 孤儿资源，未打进 App 包 |
| pbxproj 空 `Fonts` group、空壳 `AppIcon.appiconset` | 构建配置残留 |

### 11.3 文档漂移

`docs/ios-feature-inventory.md` 核对日期为 2026-09-09，**落后当前代码**。文档之后新增但未反映的功能：

| 功能 | 提交 |
|---|---|
| OpenRouter provider | `dbce47b`（09-15） |
| SnapTrade 直连 | `dbce47b`（09-15） |
| AI 流式 + 思维链 | `bd05e42`（09-15） |
| iCloud 偏好同步 | `e54280f`（09-14） |
| 个股页开合动画自绘、AI 页浅色 | `3a8d973`（09-15） |
| 首页 presentation cache 恢复 | `e78dec6`（09-15） |
| History 推入性能 | `291cd17`（09-14） |

`ENGINE_CATALOG.md` 最后核对 2026-09-08，同样未覆盖上述变更。

### 11.4 已知功能边界（不可当能力宣传）

- 今日归因未计当日买卖；ETF 穿透受内置快照限制；OI 依赖 Yahoo 且已观察到 429。
- 模拟账户不含分红、费用、现金资产；公开披露截至 2026-09-07。
- 选股器受数据商覆盖与额度限制；行业情绪仅半导体。
- 策略编曲家不下单、非回测、本地化未完成。
- 真实券商在线同步、双设备 iCloud、长时间运行**均未验收**。

### 11.5 Policy 引擎专项风险

1. **交易日历硬编码只覆盖 2026 年**（`PolicyExecution.swift:12`），2027 年起策略完全无法运行——有明确到期日的功能。
2. **起始日硬编码 `2026-01-01`**（`PolicyMarketAdapter.swift:42`），叠加 250 交易日窗口上限，长期会形成隐性截断。
3. **策略与 UI 共享 12 小时行情缓存，无 run 级隔离**：`PolicyMarketAdapter` 走 `historicalCloses`（TTL 12h），「用最近一个完整交易日收盘价」的承诺实际由缓存新鲜度兜底。
4. **`mode` 由节点类型自动推导**，用户无法显式选择 ANALYZE/SIMULATE；且 `simulationBudget` 只接受 USD。
5. **`PolicyRunCoordinator.observer` 只有一个槽位**，后注册者覆盖前者——一旦有第二个观察者会静默失效。
6. **`BGTaskSchedulerPermittedIdentifiers` 用通配 + 每次运行新 identifier**，`registered` 集合无清理，高频运行会累积标识符。
7. **run 记录的保护级别比草稿更宽松**：`frozenPositions` 把持仓 JSON（**有仓位与股数，无凭证**）明文写进 run 记录，用 `.completeFileProtectionUntilFirstUserAuthentication`，而草稿用 `.completeFileProtection`。
8. **`saveCandidate` 把完整原始 AI 回答原样落盘**（设计上保留证据），会随时间累积。

### 11.6 设置与工程层面的遗留

| 项 | 证据 |
|---|---|
| `AccountTransactionsView`（152 行整份视图）无引用 | 全仓仅命中定义行 |
| `SettingsView` 的关闭按钮分支不可达 | `showsCloseButton` 无任何调用点传 `true` |
| `SettingsSegmentBar` / `SettingsSegment` / `SettingsFieldButton` 零调用 | `SettingsTemplate.swift` 定义，全仓 0 引用 |
| `LocalMarketDataClient.testFMPConnection` 零引用 | 设置页实际走 `testFMPValuationConnection` |
| `LocalAIClient.researchAnswerAllowingSearch` 零引用 | `LocalServices.swift:4194` |
| `currentWeightModelSeries`（约 71 行）零引用 | `LocalServices.swift:2804` |
| `$defs/observation` schema 定义无 Swift 实现 | `strategy.schema.json` |
| 设置页 1 个 disabled 占位 | 「拍照 AI 添加持仓」 |
| 收益页「税务计算」disabled | `ReturnsView.swift:63-65` |
| 空壳资源 | pbxproj 中残留的空 `Fonts` group（磁盘无目录）；`AppIcon.appiconset` 只有 `Contents.json` 无 PNG（真图标在 `AppIcon.icon`） |
| 两个空实现 | `DesignSystem.swift:423-436` 的 `securityDetailZoomHost` / `securityDetailZoomTransition` |
| 双实现并存 | `SectorRotationUIKit` / `StockChartsRotationUIKit` 与对应 SwiftUI 版长期并存 |

### 11.7 跨仓库契约漂移

`v3_backend/tests/test_ios_holding_research_cards.py:31` 断言 `SecurityDebateSection(debate: debate, isHoldingCard: true)`，并要求该区间出现 `.holdingDetailGlassCard()` 与 `Button(action: onStart)`。当前 iOS 源码中 `isHoldingCard` **0 命中**，`SecurityDebateSection` 参数为 `debate:title:`，卡片改用 `HoldingDetailDisclosureCard`——**该 Python 测试按现状很可能失败**。说明 iOS 与 `v3_backend/tests` 之间已有未同步的接口假设。

另有 `docs/strategy-composer-*.md`（2026-09-10）写「生产功能尚未交付」并规划 UIKit 实现，而代码已于 09-13 落地为 SwiftUI——**该文档已过期**。

### 11.8 持仓 / 收益 / 历史主链路专项风险

**（一）同一口径被重复实现且已漂移**（会直接产生错误数字）

| 口径 | 两处（或多处）实现 | 漂移后果 |
|---|---|---|
| 今日盈亏 | `PortfolioView.swift:601-618` vs `TodayDetailView.swift:26-39` | 跌幅 < −100% 时一处丢弃、一处显示错误正值 |
| 回撤 | `LocalReturnsAnalytics.drawdown`（Top35 模型组合 5 年）vs `UnderwaterAnalysisChart`（fixedShareHistory） | 两个「回撤」含义不同，用户无法区分 |
| 成本定义 | `HoldingValueHistory.Row.cost` 实际是**累计净存入**，注释却称「买入成本」 | 多账户/有卖出时偏离真实成本基础 |
| 基准收益 | 组合用原始收盘 + 显式股息，基准用 adjclose 总收益 | 未导入股息的持仓天然跑输 |
| ETF 权重 | `etfWeightPercent`（基数 = ETF 总市值）vs UI `portfolioWeight`（基数 = 穿透后合计） | 同一行两个百分比 |
| NAV / TWR | 账本口径 / `currentWeightModelSeries`（权重模型，**死代码**）/ `impliedLedgerDays`（成本推算兜底） | 三套口径并存 |
| 对比 | `LocalMarketDataClient.comparison` vs `LocalPortfolioEngine.comparison` | 两处实现 |

**（二）两套已完成的引擎从未接线**
- `UKSection104Pool`（225 行）：实现完整、有测试，**在 App 目标零调用方**——英国税成本池算得出来但 UI 拿不到。
- `ETFLookThroughView`（214 行）：实现完整，**零调用方**——成本口径的 ETF 穿透只在它里面暴露。
- `PortfolioDocumentMerge`：实现完整，**仅测试引用**。

**（三）数据时效性对用户不可见**
- ETF 持仓快照有 `as_of`（2026-09-03/04、部分 2026-06-30）但**活 UI 不展示、无 TTL/过期判断**，而同一项目里轮动数据有 `isExpired`；
- `FundFeeCatalog` 96.8% 记录缺 `expenseRatioAsOf`；
- 离线硬编码汇率表与实时缓存混用，**无任何数值告警**（穿透市值可能同时混用实时报价与离线汇率）。

**（四）明确的实现缺口**
- 记录级分页 / 无限滚动：**不存在**；
- 出入金展示：**被过滤**；
- 手续费计入成本/盈亏：**无字段、不参与**；
- 平均成本法、CGT 税率、年度免税额、亏损结转、印花税、胜率、盈亏比、HHI、Brinson 分解：**均未实现**；
- 费率进入穿透/收益计算：**未接入**。

**（五）一处曾被误判、经复核撤回的问题**

`UnderwaterAnalysisChart.swift:403-404` 的 `domain: (bottom * 100)...0` 配 `yTicks: [0, bottom * 50, bottom * 100]`，表面上与 `LossAnalysisChart.swift:161-162` 的 `domain: bottom...0` / `yTicks: [0, bottom / 2, bottom]` 矛盾，曾被标为「刻度差两个数量级」。

**复核结论：不是 bug，两处都自洽。** 原因是两个文件对 `bottom` 的单位约定不同：

| 文件 | `bottom` 单位 | series 值 | domain | yTicks | 一致 |
|---|---|---|---|---|---|
| `UnderwaterAnalysisChart` | **小数**（drawdown，如 −0.25） | `drawdown * 100`（百分点） | `bottom * 100` = −25 | `[0, −12.5, −25]` | ✅ |
| `LossAnalysisChart` | **金额**（美元） | 原始金额 | `bottom` | `[0, bottom/2, bottom]` | ✅ |
| `HoldingContributionChart` | **金额**（美元） | 原始金额 | `top...0`（`top` 含 1.06 余量） | `[top, top/2, 0]` | ✅ |

教训：**表达式长得不一样 ≠ 单位不一致**，必须先追 `bottom` 的来源再判断。此条从缺陷清单撤回。

**（六）性能隐患**
- `StandardLineChart` 全部同步主线程绘制，过渡期每帧重跑绘制闭包并逐点构 `Path`；无 `drawingGroup`、无异步 Canvas、无 LTTB；
- `HoldingsHeatmapView` 固定 700pt 高 + 每次布局跑 4 次 treemap，`while true` 可能反复重排；
- `PerformanceHeatmapHero` 每次渲染键变化延迟 100ms **整屏重新烘焙纹理**，平面上同时绘制 15 份图像 + 5 层预模糊，30fps 驱动，内存驻留多张全宽位图；
- `VolumeDistributionPlot` 的分桶 filter/sort、连续切片、7 点卷积平滑、单调斜率都在 **Canvas 闭包内部逐帧重算**，未缓存；
- 52 周区间的 `markerIndex(at:)` 在 45 个刻度上线性扫描，**每次触摸移动都调用**；
- 条纹绘制用 `while` 逐条 `addLine`，数量随绘制区尺寸线性增长且无上限。

**（七）静默失败**
资源解码大量用 `try?`（拆股目录、费率目录、板块轮动、`FundCompositionCache.load` → **失败结果被永久缓存**）；资源缺失时拆股因子回落 1、费率页变空、历史静默丢弃，**无任何诊断信号**。

**（八）零技术债标记的反差**
全项目 `TODO|FIXME|HACK|XXX` **0 命中**。债务不以注释标记，只体现在结构里。需客观指出：**代码注释质量整体很高**，多处主动声明实现边界（两处「不是税务计算」、`SectorAttribution` 的代理局限、缓存 digest 的取舍），并非刻意隐瞒。

> 本条目的逐行细节、页面结构树与公式摘录另存于 `docs/ios-deep-dive/holdings-returns-history.md`（838 行）作为附录。

---

## 附录 A：源码文件规模表（111 个，按行数降序）

| 行数 | 文件 |
|---|---|
| 4992 | `LocalServices.swift` |
| 4433 | `VolumeProfileView.swift` |
| 3279 | `PortfolioView.swift` |
| 2770 | `AIView.swift` |
| 2742 | `DesignSystem.swift` |
| 2705 | `LocalPortfolioStore.swift` |
| 2396 | `StandardLineChart.swift` |
| 2205 | `SettingsView.swift` |
| 1963 | `ReturnsView.swift` |
| 1784 | `APIClient.swift` |
| 1644 | `Trading212Client.swift` |
| 1421 | `HistoryView.swift` |
| 1379 | `PolicyComposerView.swift` |
| 1250 | `SettingsTemplate.swift` |
| 1167 | `Models.swift` |
| 1153 | `SecurityDebateView.swift` |
| 1115 | `OptionsOIView.swift` |
| 1106 | `CompanyFinancials.swift` |
| 1062 | `MoomooOAuthClient.swift` |
| 982 | `ResearchView.swift` |
| 774 | `CompanyFinancialsView.swift` |
| 768 | `SecurityDebateStore.swift` |
| 735 | `LocalReturnsAnalytics.swift` |
| 723 | `PublicInvestorCatalog.swift` |
| 719 | `HoldingsHeatmapView.swift` |
| 670 | `PolymarketMarketsView.swift` |
| 659 | `PolicyShortcut.swift` |
| 636 | `SecurityDebate.swift` |
| 635 | `ReturnsAnalyticsView.swift` |
| 627 | `SectorRotationUIKit.swift` |
| 606 | `CycleComparison.swift` |
| 584 | `UnderwaterAnalysisChart.swift` |
| 541 | `StockScreenerView.swift` |
| 537 | `IBKRFlexView.swift` |
| 529 | `PolicyComposerStore.swift` |
| 526 | `PerformanceHeatmapHero.swift` |
| 519 | `IBKRFlexClient.swift` |
| 511 | `NewsSources.swift` |
| 471 | `IsometricHeatmapLab.swift` |
| 470 | `PortfolioHomeScrollInteraction.swift` |
| 469 | `TodayDetailView.swift` |
| 468 | `HoldingContributionChart.swift` |
| 449 | `HistoryPagingView.swift` |
| 430 | `Trading212View.swift` |
| 429 | `MoomooOAuthView.swift` |
| 426 | `LossAnalysisChart.swift` |
| 425 | `SecurityDetailTransition.swift` |
| 419 | `Typography.swift` |
| 416 | `AnalystConsensusView.swift` |
| 378 | `HoldingsHeatmapTile.swift` |
| 370 | `PolicyExecution.swift` |
| 363 | `InsiderTrades.swift` |
| 352 | `CSVImportView.swift` |
| 349 | `RootTabView.swift` |
| 312 | `PolicyRunTrace.swift` |
| 307 | `InsiderTradesView.swift` |
| 296 | `AIQuestionPresets.swift` |
| 295 | `PolicyContract.swift` |
| 293 | `ManagementDeliveryView.swift` |
| 292 | `CloudPreferences.swift` |
| 287 | `IndustrySentimentView.swift` |
| 286 | `RealisedProfitCalculator.swift` |
| 285 | `HoldingsTreemapLayout.swift` |
| 264 | `SnapTradeClient.swift` |
| 261 | `SectorPerformance.swift` |
| 255 | `PolicyRunCoordinator.swift` |
| 253 | `LocalChatStore.swift` |
| 243 | `PortfolioLoadRipple.swift` |
| 241 | `ManagementDelivery.swift` |
| 228 | `AnalystHistoryView.swift` |
| 225 | `UKSection104Pool.swift` |
| 225 | `ManagementDeliveryClient.swift` |
| 225 | `ManagementDeliveryAnalyzer.swift` |
| 223 | `StockChartsRotationUIKit.swift` |
| 222 | `CompanyReferenceCatalog.swift` |
| 220 | `UnderwaterAnalysis.swift` |
| 218 | `EarningsHistoryView.swift` |
| 217 | `SectorRotationView.swift` |
| 214 | `ETFLookThroughView.swift` |
| 200 | `StockChartsRotation.swift` |
| 200 | `EarningsHistory.swift` |
| 199 | `StockChartsRotationView.swift` |
| 197 | `SnapTradeView.swift` |
| 197 | `SectorAttribution.swift` |
| 183 | `NasdaqAnalystClient.swift` |
| 174 | `DailyTimeWeightedReturn.swift` |
| 172 | `PolicyWorkspaceStore.swift` |
| 169 | `UKShareMatching.swift` |
| 169 | `ImpliedFunding.swift` |
| 163 | `Localization.swift` |
| 157 | `FundFeeCatalog.swift` |
| 154 | `SectorRotation.swift` |
| 143 | `FXImpactCalculator.swift` |
| 139 | `PublicInvestorView.swift` |
| 136 | `GBPFXRates.swift` |
| 125 | `PortfolioPresentationCache.swift` |
| 118 | `AIStreaming.swift` |
| 103 | `PortfolioDocumentMerge.swift` |
| 102 | `RevenueSegments.swift` |
| 97 | `LedgerReconciliation.swift` |
| 94 | `PolicyMarketAdapter.swift` |
| 92 | `PolicyTemplates.swift` |
| 72 | `StockSplitCatalog.swift` |
| 70 | `PolicyBackgroundService.swift` |
| 68 | `KeychainStore.swift` |
| 66 | `FMPRateLimiter.swift` |
| 61 | `CatfolioIOSApp.swift` |
| 52 | `HoldingHistoryState.swift` |
| 47 | `ReturnsAnalyticsModels.swift` |
| 45 | `LegacyType.swift` |
| 26 | `ReferenceCatalogs.swift` |

## 附录 B：测试文件规模表（52 个）

| 行数 | 文件 |
|---|---|
| 1077 | `HoldingDetailInteractionTests.swift` |
| 635 | `SecurityDebateResearchTests.swift` |
| 574 | `HistoryInteractionTests.swift` |
| 553 | `HomeScrollInteractionTests.swift` |
| 517 | `RealisedProfitCalculatorTests.swift` |
| 495 | `PublicInvestorSelectionTests.swift` |
| 393 | `PageLoadAndJitterTests.swift` |
| 385 | `AuditRegressionTests.swift` |
| 342 | `HoldingsHeatmapAggregationTests.swift` |
| 337 | `LocalizationTests.swift` |
| 302 | `CloudPreferencesTests.swift` |
| 287 | `ManagementDeliveryTests.swift` |
| 283 | `LocalPortfolioEngineTests.swift` |
| 279 | `SectorAttributionTests.swift` |
| 250 | `MoneyWeightedReturnCalculatorTests.swift` |
| 240 | `UKSection104PoolTests.swift` |
| 240 | `PublicInvestorCatalogTests.swift` |
| 229 | `PortfolioPresentationCacheTests.swift` |
| 222 | `SectorRotationTests.swift` |
| 215 | `InsiderTradesTests.swift` |
| 214 | `PolicyShortcutTests.swift` |
| 204 | `AIConversationLibraryTests.swift` |
| 192 | `SettingsInteractionTests.swift` |
| 189 | `SnapTradeTests.swift` |
| 185 | `NumericAlternatesTests.swift` |
| 180 | `FXImpactTests.swift` |
| 178 | `HoldingContributionTests.swift` |
| 169 | `UnderwaterAnalysisTests.swift` |
| 166 | `CurrencyFormattingTests.swift` |
| 165 | `UKShareMatchingTests.swift` |
| 152 | `StockSplitTests.swift` |
| 150 | `PortfolioDocumentMergeTests.swift` |
| 147 | `CompactNumberRuleTests.swift` |
| 141 | `ImpliedFundingTests.swift` |
| 140 | `FundFeeTests.swift` |
| 119 | `TypographyTests.swift` |
| 116 | `ETFLookThroughExpansionTests.swift` |
| 115 | `EarningsHistoryTests.swift` |
| 113 | `LedgerReconciliationTests.swift` |
| 111 | `PortfolioAccountAggregationTests.swift` |
| 97 | `HeatmapRowTapTargetTests.swift` |
| 92 | `StockScreenerRulesTests.swift` |
| 84 | `NasdaqAnalystLogicTests.swift` |
| 83 | `HeatmapRemainderReturnTests.swift` |
| 81 | `StockChartsRotationTests.swift` |
| 79 | `CycleComparisonTests.swift` |
| 69 | `CompanyCIKSeedTests.swift` |
| 63 | `AIStreamingTests.swift` |
| 54 | `RevenueSegmentsTests.swift` |
| 50 | `BrokerResultPreservationTests.swift` |
| 47 | `Trading212FillDecodingTests.swift` |
| 44 | `AnalystConsensusDataTests.swift` |
