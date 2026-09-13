# Catfolio 引擎与能力清单

最后核对：2026-09-08。面向产品、iOS、Core 和后续共享引擎开发者。

**开始新增计算能力前，先查本清单，避免重复实现。** 本文件是能力导航，不是上线验收报告。
本次核对范围为 iOS 实现、主要调用点及 Core 已完成的数据工作；尚未逐项审计 Web/Desktop。
有测试文件表示存在测试，不代表每次编辑本文都重新运行了整套测试。

## 如何理解状态

- **已接入 iOS**：已有实现及实际调用方，不一定已经抽成独立包。
- **Core 已有**：数据或导出流程存在；不代表 App 在运行时访问 Core，也不代表全市场覆盖。
- **试采 / 研究**：部分真实数据和可复算流程，覆盖或语义仍有缺口。
- **待抽取 / 待建设**：目标架构，不能当作已交付功能。

当前大部分计算仍在 iOS 的 Swift 文件中。Core 负责参考数据、历史资料及导出，
两者尚未共享一个统一计算 SDK。

## iOS 已有计算与数据能力

下表中的文件相对 `CatfolioIOS/CatfolioIOS/`；测试相对 `CatfolioIOS/CatfolioIOSTests/`。

| 能力 | 实现入口 | 调用/消费位置 | 测试与边界 |
|---|---|---|---|
| 管理层兑现核对 | `ManagementDelivery.swift`、`ManagementDeliveryClient.swift`、`ManagementDeliveryAnalyzer.swift` | 个股研究区 `ManagementDeliveryCard`；iPhone 直接下载 FMP 文字稿与标准化财报，设备端 AI 提取/匹配，数字由规则判定 | `ManagementDeliveryTests.swift`；最近 4/6/8 季度、至少四个连续财季，最多核对 40 项承诺。资料不上传；需 iOS 26 Apple Intelligence 与 FMP 权限，证据不足为待验证。[边界与验收](docs/ios-management-delivery.md)，2026-09-13 新增；真机端到端尚未验收 |
| 组合估值、成本和持仓汇总 | [LocalPortfolioStore.swift](CatfolioIOS/CatfolioIOS/LocalPortfolioStore.swift) → `LocalPortfolioEngine` | 本地组合 presentation、概览和持仓 | `LocalPortfolioEngineTests.swift`；当前估值 FX 有缓存及固定值兜底，不用于历史成交对账 |
| 券商读取及导入 | [Trading212Client.swift](CatfolioIOS/CatfolioIOS/Trading212Client.swift)、[IBKRFlexClient.swift](CatfolioIOS/CatfolioIOS/IBKRFlexClient.swift)、[MoomooOAuthClient.swift](CatfolioIOS/CatfolioIOS/MoomooOAuthClient.swift)、[CSVImportView.swift](CatfolioIOS/CatfolioIOS/CSVImportView.swift) | 各券商连接页、CSV 导入、本地组合存储 | `Trading212FillDecodingTests.swift`、`BrokerResultPreservationTests.swift`；仍是多处适配代码，未统一成跨端账本引擎 |
| 账本对账 | [LedgerReconciliation.swift](CatfolioIOS/CatfolioIOS/LedgerReconciliation.swift) | `SettingsView` 中生成和显示 report | `LedgerReconciliationTests.swift`；对账报告不等于自动修复原账本 |
| 已实现盈亏、FIFO | [RealisedProfitCalculator.swift](CatfolioIOS/CatfolioIOS/RealisedProfitCalculator.swift) | `HistoryView` 收益汇总 | `RealisedProfitCalculatorTests.swift`、`BrokerResultPreservationTests.swift`；保留可用券商结果，缺失时尝试本地重建，成本不足须显式保留 |
| 拆股调整 | [StockSplitCatalog.swift](CatfolioIOS/CatfolioIOS/StockSplitCatalog.swift) | 已实现盈亏、历史匹配、FX 影响计算 | `StockSplitTests.swift`；美股资源为主，不是完整公司行动引擎 |
| 英国股票匹配与成本池 | [UKShareMatching.swift](CatfolioIOS/CatfolioIOS/UKShareMatching.swift)、[UKSection104Pool.swift](CatfolioIOS/CatfolioIOS/UKSection104Pool.swift) | 历史处置匹配/成本池链路 | `UKShareMatchingTests.swift`、`UKSection104PoolTests.swift`；同日、30 天和 Section 104 已有代码，不是完整报税系统 |
| GBP 历史换算 | [GBPFXRates.swift](CatfolioIOS/CatfolioIOS/GBPFXRates.swift) | 本地历史换算及 FX 影响链路 | 返回匹配类别，查询允许有限前值回退；不能把回退当作当日真实观测 |
| 汇率影响 | [FXImpactCalculator.swift](CatfolioIOS/CatfolioIOS/FXImpactCalculator.swift)、[LocalServices.swift](CatfolioIOS/CatfolioIOS/LocalServices.swift) 中 `LocalFXImpactCalculator` | `LocalPortfolioEngine` 等展示链路 | `FXImpactTests.swift`；存在不同层级实现，抽取时先比较口径和调用方 |
| 资金加权收益 | [Models.swift](CatfolioIOS/CatfolioIOS/Models.swift) → `MoneyWeightedReturnCalculator` | `LocalServices`、`LocalPortfolioEngine` | `MoneyWeightedReturnCalculatorTests.swift`；不能把 MWR 与 TWR 混称 |
| ETF 穿透与直接/间接暴露合并 | [LocalServices.swift](CatfolioIOS/CatfolioIOS/LocalServices.swift) → `LocalETFLookThrough` | `APIClient` 调用，`ETFLookThroughView` / 组合相关界面展示 | `ETFLookThroughExpansionTests.swift`；支持成本/市值口径，精确基金快照优先，部分 ticker 仍使用指数代理；不是全市场或历史时点完整穿透 |
| 公司参考查询、行业归类 | [CompanyReferenceCatalog.swift](CatfolioIOS/CatfolioIOS/CompanyReferenceCatalog.swift)、[SectorAttribution.swift](CatfolioIOS/CatfolioIOS/SectorAttribution.swift) | 持仓分类及相关分析 | `SectorAttributionTests.swift`、`CompanyCIKSeedTests.swift`；不是完整历史证券生命周期解析器；当前行业数据由已有维护流程负责，勿重复改写 |
| 公开投资者资料与组合适配 | [PublicInvestorCatalog.swift](CatfolioIOS/CatfolioIOS/PublicInvestorCatalog.swift) | 公开投资者选择及 `PublicInvestorAccountAdapter` | `PublicInvestorCatalogTests.swift`、`PublicInvestorSelectionTests.swift`；公开披露不是实时真实账户 |
| 收益分析数据组织 | [LocalReturnsAnalytics.swift](CatfolioIOS/CatfolioIOS/LocalReturnsAnalytics.swift) | 收益分析页面 | 含历史收益与估值数据组织；不能据此宣称完整独立风险引擎已建成 |

## Core 已有数据与导出模块

Core 源码和部分文档属于当前工作区的可选私有目录。其他 checkout 若未包含这些文件，
应向维护者确认 Core 版本；链接缺失不代表要在 iOS 重写相同流程。

| 模块 | 当前交付 | 主要入口 / 说明 | 主要缺口 |
|---|---|---|---|
| Security / Company Reference | 证券与挂牌资料、公司信息、别名、国际分类、CIK 等参考数据 | [Core README](core/README.md)、`core/tools/export_company_reference.py`、`export_international_company_reference.py` | 映射与历史发行人生命周期并非全覆盖 |
| ETF Reference / 费用 | 产品与挂牌模型、基金 metadata、费率采集和导出 | `core/tools/export_etf_reference.py`、`collect_fund_fees.py`、`export_fund_fees.py` | 字段来源/覆盖各不相同；资料存在不等于 iOS 已调用 |
| ETF 成分快照 | 有日期的基金 holdings 包，供客户端穿透 | `core/tools/export_etf_holdings.py` | 不是全市场，也不是每只基金都有完整历史快照 |
| 股票拆股 | 全量档案抽取，保持 iOS 已用 JSON 契约 | [拆股流程](docs/core-stock-splits.md)、`core/tools/export_stock_splits.py` | 国际市场及其他公司行动待补 |
| GBP 日汇率 | ECB 来源、明确方向和缺失策略的离线包 | [GBP 汇率](docs/core-gbp-fx.md)、`core/tools/export_gbp_fx.py` | 币种/日期缺口保留；消费端回退需区别于原始观测 |
| 历史价格 | 原始日线档案、审核/导出流程及部分正式价格 | [来源审核](docs/core-history-source-review.md)、`core/tools/export_delivery_pack.py` | 原始档案存在不等于所有价格已标准化入正式库；复权口径须匹配 |
| Investor Mode | 13F / House 披露导入、历史快照及季度变化；ownership importer 基础 | [Investor Mode](docs/core-investor-mode.md)、`core/tools/investor_mode/` | 历史身份、部分申报及派生表现仍不完整 |
| 历史机构评级方向评估 | 可复算的机构级研究包 | [评级评估](docs/core-analyst-track-record.md)、`core/tools/export_analyst_track_record.py` | **用户已明确不需要评级功能；保留既有研究，不作为目标价功能继续扩建** |
| 历史目标价 | 3 条公开报道试采记录 | Core storage 的 `price-target-history/` | 批量历史未取得；范围暂定 2023 年至今，统一观察 **12 个自然月**；不得把模拟图当真实数据 |
| OI 持仓墙 | Yahoo 浏览器试采 AAPL 3 个到期日、418 合约；按执行价导出 OI | [Yahoo OI](docs/core-yahoo-oi.md)、`core/tools/export_oi_walls.py` | 未覆盖全链/全市场、无每日自动采集；OI 结算日期未知；yfinance 尚未实测接入 |

## 后续引擎边界（计划，不是现状）

| 拟抽取模块 | 优先复用 | 交付边界 |
|---|---|---|
| 证券识别 | 现有参考库、别名和分类查询 | 标识 → Security / Listing / Company，歧义返回未解决 |
| 账本 | 券商适配、交易模型、FIFO、对账 | 保留原始事件及券商结果，规范化、去重、重建、对账 |
| 公司行动 | StockSplitCatalog 与 Core 拆股导出 | 先拆股，再扩展分拆/合并等，独立于券商适配 |
| 估值与 FX | LocalPortfolioEngine、GBPFXRates | 当前估值与历史换算分开；时间、币种、缺失策略明确 |
| 收益与归因 | 已实现盈亏、MWR、FX 影响 | 统一输入输出；FIFO、税务、TWR/MWR 各有明确口径 |
| 税务 | UKShareMatching、UKSection104Pool | 独立税区规则，不能用 FIFO 替代英国匹配 |
| ETF 穿透 | LocalETFLookThrough + Core holdings | 日期匹配、精确/代理来源、未知暴露与覆盖率 |
| 风险 | 现有收益分析及日线 | 在数据充分时计算；本次尚未确认独立完整实现 |
| 数据质量 | LedgerReconciliation + Core quality queue | 统一问题分类与可追溯解释，不静默修正原始数据 |

## 协作约定

1. 个人账本和凭据继续留在客户端本地。Core 存参考数据不等于迁移个人账本。
2. 抽取引擎先确定输入/输出契约，用现有测试和固定案例核对新旧结果，再替换调用方。
3. 不删除、覆盖或改变 Demo 数据、iOS 本地数据、真实账户同步逻辑。
4. 新增/替换模块时，同步更新本文的实现入口、实际消费者、覆盖限制和验证日期。
5. 数据覆盖不足必须返回缺失状态；已生成、已接入、已验证全覆盖是三个不同状态。
6. 公共资料及图表仅有研究样本时保留“试采”标记；不要用展示效果推断已完成数据链路。

本次文档整理没有修改任何计算或账户逻辑，也没有重新执行整套 iOS 测试。
