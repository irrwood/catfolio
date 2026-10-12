# Catfolio iOS 审计 · 2026-10-12

优先处理数据完整性和报价一致性，然后改善离线恢复、对比度和规则检查。当前实现已经有账户隔离、取消任务保护、本机 Keychain、缓存恢复和较完整的回归测试；这次发现的问题主要在这些机制之间的边界条件。

本次只增加审计材料，没有修改业务实现。审计对象为当前工作区，包含尚未提交的盘前盘后及热力图修改，不等同于已发布版本。

## 范围与证据

- 阅读持仓刷新、收益入口、行情服务/缓存、个股图表、交易时段、CSV 导入/存储、汇率、搜索、账户删除、AI 请求/取消、密钥存储和设计系统相关实现。
- 在 iOS 27 模拟器重新截取 7 个入口/状态，使用虚构组合；没有读取或操作真实券商账户，没有发送 AI 问题。
- All 计划构建成功：1,500 个用例中 1,497 通过、3 跳过、0 失败。双语检查通过；设计检查有 42 个文件的 52 组违规。另外 5 个独立审计复现用例按预期失败，确认了已有测试未覆盖的边界。详细结果见 [verification.txt](/Users/qian/Documents/股票分析/docs/audits/ios-app-2026-10-12/verification.txt)。
- 截图主要为中文、默认字号。页面通过开发启动入口直接打开；不能据此声称所有页面间的点击路径均已人工走通。搜索、导航、大字体、图表和滚动由已有测试补充覆盖。
- 未验证真实券商 OAuth/同步、收费数据权限、真实 AI 输出质量、真机耗电/发热、VoiceOver 全流程，以及 iOS 18 等旧系统。没有进行正式安全渗透测试。

## 修改优先级

### 1. P1 · 部分错误的 CSV 会覆盖原账户

**证据：已运行复现。** 原账户有 AAPL 和 MSFT。重新导入时，将 AAPL 的数量改为无效文本，保留有效 MSFT 行。解析器返回 MSFT 和一条警告；随后账户替换删除了原有 AAPL。警告直到保存后才显示，也没有为这次覆盖生成备份。

- 位置：[AppModel+Accounts.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/AppModel+Accounts.swift:243)、[LocalCSVImporter.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalCSVImporter.swift:235)、[CSVImportView.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/CSVImportView.swift:228)。
- 建议：拆成解析预览和提交；预览新增/删除持仓、交易数量和跳过行。更新已有账户时，存在交易解析错误应阻止覆盖，或在明确展示影响后允许继续；提交前保留可恢复备份。
- 验收：坏行、截断文件、重复导入均不会静默删除原账本；取消预览不写盘。

### 2. P1 · 汇率过期和离线估值没有传递到资产数字

**证据：代码路径确认，未更改用户缓存。** `usdRate` 直接使用缓存，不检查记录日期；缺失时使用写死的 GBP 1.346、EUR 1.163 等汇率。这些值直接参与成本、市值与跨币种汇总。当前提示在偏好设置页，首页资产数字无法区分有效行情与离线估算。显示币种为 USD 时，提示只取 GBP 日期，也无法代表所有持仓币种的汇率状态。

- 位置：[LocalPortfolioEngine.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalPortfolioEngine.swift:65)、[AppSettingsView.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/AppSettingsView.swift:116)。
- 建议：汇率返回值携带来源、日期和质量状态；汇总使用的每个币种都参与新鲜度判定。保留离线查看能力，同时在受影响的资产数字旁标记估算/截至日期。
- 验收：首次离线、单一币种缺失、长期离线及多币种部分更新均能识别估算；恢复网络后状态与金额一起更新。

### 3. P2 · Yahoo 返回旧数据时不会尝试 Massive

**证据：已运行复现。** Yahoo 返回上周五正常盘收盘前的有效 bar，Massive 可返回周一盘前的新 bar；加载器直接返回 Yahoo 的 100，没有调用 Massive 的 105。当前回退处理了异常、空数据和非法价格，但没有处理“请求成功、数据过期/缺少当前交易阶段”的情况。缓存的 `includesExtendedHours` 也由请求参数决定，不代表实际有对应覆盖。

- 位置：[LocalMarketDataClient+Intraday.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalMarketDataClient+Intraday.swift:138)。
- 建议：按交易日、时段和实际最新时间校验响应覆盖；疑似过期再询问 Massive，按观测时间选取结果。低流动性证券没有成交不能直接当故障，需要明确宽限规则。
- 验收：HTTP 200 但只有旧正常盘数据也能进入回退；休市和无成交时不会反复请求；缓存记录实际覆盖。

### 4. P2 · 主价格和图表末点会使用不同的交易时段

**证据：已运行复现。** 周五正常盘 100、盘后 110，周一正常盘已经开始但未取得新数据时，主价格回到 100，长周期图表末点仍为 110。主价格带当前时间和时段过滤，图表末点采用另一套筛选，且不检查年龄。

- 位置：[SecurityPriceModels.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/SecurityPriceModels.swift:26)、[SecurityPriceModels.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/SecurityPriceModels.swift:52)。
- 建议：统一生成详情展示报价：价格、时间、时段、涨跌基准、新鲜度；现有主价格、图标和图表末点共同读取。组合估值仍保留其独立的正常盘口径。
- 验收：09:30、16:00、20:00、跨日、周末、网络失败时，未拖动图表的主价格和最新末点始终一致。

### 5. P2 · 休市判断缺交易日历和午间休市

**证据：已运行复现，并核对交易所规则。** `0700.HK` 在香港时间 12:30 被判为开市；AAPL 在 2026-12-25 10:00 以及 2026-11-27 14:00（纽约时间）也被判为正常盘。当前只判断星期与固定开收盘时间。

- 位置：[MarketHours.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/MarketHours.swift:29)、[ExtendedMarketSession.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/ExtendedMarketSession.swift:13)。
- 官方依据：[HKEX 交易时段](https://www.hkex.com.hk/Global/Exchange/FAQ/Securities-Market/Trading/Securities-Market-Operations?sc_lang=en)、[NYSE 假期与提前收市](https://www.nyse.com/trade/hours-calendars?os=i)。港股普通股票连续交易分上午和下午；NYSE 2026-11-27 提前至 13:00 收市。
- 建议：优先使用行情源确认的 session window，其余由交易所日历补足节假日、提前收市和午休；日历不可用时显示未知状态。
- 验收：节假日、半日市、午休、夏令时切换均有确定性测试；Massive 回退也沿用一致的会话定义。

### 6. P2 · 日线不足会挡住已有的分时数据

**证据：代码路径确认。** `securityPriceHistory` 必须先成功取得日线，并要求至少两个有效日线点，之后才构建分时点。新上市股票只有一天日线，或日线接口失败但分时成功时，现有单点/盘前盘后图表能力无法到达。

- 位置：[LocalMarketDataClient+Intraday.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalMarketDataClient+Intraday.swift:29)、[LocalMarketDataClient+Intraday.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalMarketDataClient+Intraday.swift:48)。
- 建议：日线、分时独立降级；有有效分时就允许 1D 展示。没有前收盘时，涨跌百分比保持不可用，不能编造基准。
- 验收：0/1 个日线点 + 多个分时点、日线失败 + 分时成功，都能显示真实价格走势。

### 7. P2 · 离线失败说明和重试入口不够明确

**证据：本次截图 05 + 代码。** 模拟离线时显示“Massive 与 Yahoo 暂未返回分钟级数据”，没有说明网络不可用；报价无截至时间。刷新实际藏在点击价格的按钮中，视觉上看不出入口。分时错误被 `try?` 转成空数组，因此下游难以区分没成交、无权限、网络失败和无缓存。

- 位置：[LocalMarketDataClient+Intraday.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalMarketDataClient+Intraday.swift:34)、[HoldingDetailHeader.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/HoldingDetailHeader.swift:48)、[HoldingDetailPage.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/HoldingDetailPage.swift:302)。
- 建议：保留失败原因和缓存时间；空状态提供可见的重试动作，现有价格区增加轻量的更新时间/延迟说明；回到前台时按有效期刷新。
- 验收：离线、有缓存、无缓存、限流、无权限分别有正确文案；重试不重置时间范围或账户选择。

### 8. P2 · 首页图表刻度对比度太低

**证据：本次截图 01 + 代码。** 蓝色背景上的白色刻度几乎看不见；代码明确在浅色模式用白色 16% 不透明度，深色只有 8%。浅色主曲线也固定为白色，背景越浅越难辨认。

- 位置：[CostMarketCard.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/CostMarketCard.swift:508)、[CostMarketPlot.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/CostMarketPlot.swift:106)。
- 建议：按背景亮度选轴文字颜色，至少提供“增强对比度”适配；保持现有图表布局，验证所有可选背景。
- 验收：浅色渐变、纯白、深色和增强对比度下都可读。截图发现可见风险，不等同于完成正式无障碍合规评估。

### 9. P3 · 设计检查需要恢复为可靠的门禁

**证据：本次检查未通过。** 多处字体绕过共享 token、颜色字面量超出预算、数值格式绕过统一规则；双语检查通过。不是每个字面量都应当删除，例如 Shader 和图表调色板可能需要明确例外。

- 建议：先区分合理例外与页面硬编码，将一般文本/数字/状态色收敛到共享规则，更新合理预算后在 CI 阻止新增违规。
- 验收：现有设计检查通过且不会放过新的不一致；避免靠批量放宽预算掩盖问题。

## 页面检查记录

以下都是本次运行保存并查看的截图，使用虚构组合。

| 步骤 | 页面/状态 | 结论 |
|---|---|---|
| 01 | 持仓首页 · 浅色 | 金额与层级清楚；轴刻度对比度需要修改（问题 8） |
| 02 | 收益入口 · 深色 | 卡片和热力图区域可正常绘制；收益计算主要由测试核查 |
| 03 | 研究入口 · 浅色 | 搜索入口明确，指标卡片可读；真实行情新鲜度仍需统一状态 |
| 04 | 账户入口 · 浅色 | 账户范围与历史入口清楚；真实连接/删除流程未实际执行 |
| 05 | 个股详情 · 深色、模拟离线 | 正常显示无日内数据；恢复动作和数据时间不够明确（问题 7） |
| 06 | CSV 导入入口 | 文件大小与必需列说明齐全；解析错误应在写入前出现（问题 1） |
| 07 | AI 助手 · 演示状态 | 输入与卡片可见，明确标明演示分析；真实模型质量未验证 |

### 01 · 持仓首页

![本次审计：持仓首页](/Users/qian/Documents/股票分析/docs/audits/ios-app-2026-10-12/screenshots/01-portfolio.png)

### 02 · 收益入口

![本次审计：收益入口深色](/Users/qian/Documents/股票分析/docs/audits/ios-app-2026-10-12/screenshots/02-returns-dark.png)

### 03 · 研究入口

![本次审计：研究入口](/Users/qian/Documents/股票分析/docs/audits/ios-app-2026-10-12/screenshots/03-research.png)

### 04 · 账户入口

![本次审计：账户入口](/Users/qian/Documents/股票分析/docs/audits/ios-app-2026-10-12/screenshots/04-settings.png)

### 05 · 个股详情离线状态

![本次审计：个股详情离线状态](/Users/qian/Documents/股票分析/docs/audits/ios-app-2026-10-12/screenshots/05-detail-offline.png)

### 06 · CSV 导入

![本次审计：CSV 导入](/Users/qian/Documents/股票分析/docs/audits/ios-app-2026-10-12/screenshots/06-csv-import.png)

### 07 · AI 助手

![本次审计：AI 助手演示状态](/Users/qian/Documents/股票分析/docs/audits/ios-app-2026-10-12/screenshots/07-ai.png)

## 建议执行顺序

1. CSV 两阶段导入与可恢复备份。
2. 汇率质量状态、行情实际时间校验、Yahoo → Massive 过期回退。
3. 统一详情报价与图表末点，补交易日历和稀疏数据展示。
4. 离线恢复入口、报价截至时间、图表对比度。
5. 清理设计检查，补齐以上边界条件测试。

复现代码保存在 [AppAuditReproductionTests.swift](/Users/qian/Documents/股票分析/docs/audits/ios-app-2026-10-12/AppAuditReproductionTests.swift)，不属于 App 或测试 target。它们描述建议达到的行为，在本次审计版本中失败，用于确认问题；未将故意失败的测试留在常规测试计划里。
