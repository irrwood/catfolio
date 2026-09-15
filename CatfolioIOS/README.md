# Catfolio iOS

独立运行的原生 SwiftUI 投资组合客户端。组合数据保存在 iPhone 本地，不需要 Mac、OpenD、Gateway 或 Catfolio 服务端常开。

开发入口：[引擎与能力清单](../ENGINE_CATALOG.md)。列明已有计算实现、调用方、测试位置和限制；新增或抽取引擎前先查此表，避免重复建设。

## 页面

- 持仓：成本与市值对比、持仓明细
- 成交量：点按持仓后打开原生 Sheet，拖动价格图查看 VAH、POC、VAL、成本与现价
- ETF 穿透：按成本或市值展开 ETF 底层股票，并合并直接与间接暴露
- 收益：组合与 SPY、QQQ、VTI、GLD 对比
- 全局悬浮 AI：从持仓、收益或设置任一主界面打开组合简报与问答
- 设置：券商直连、本机行情与 AI Key
- CSV 导入：从“文件”选择交易记录，在 iPhone 内解析并保存

## 券商 API

- 支持 iPhone 直连 Trading 212 正式或模拟环境，可合并两个账户；API Key 与 Secret 仅保存在设备 Keychain。
- 支持 iPhone 通过 OAuth 2.1 + PKCE 直连新版 Moomoo REST OpenAPI，无需 OpenD 或 API Key；自动读取全部授权账户。
- Moomoo OAuth 使用官方支持的 `http://localhost:60355/callback` 本机回调；授权时只需授予 `trade:read` 权限。同步会按账户和市场分页读取持仓与历史成交。
- 支持 iPhone 直连 IBKR Flex Web Service；Token 与 Query ID 仅保存在设备 Keychain，不需要 Gateway。

- 支持 iPhone 通过 SnapTrade Personal API Key 直连：券商授权、单账户持仓预览与确认同步，凭证只存本机 Keychain。首版不导入现金或交易流水。[配置与覆盖范围](../docs/ios-snaptrade.md)。

### 汇率影响管线

1. 先保留券商原始值：Trading 212 返回的 FX P/L 会作为券商口径展示。
2. Moomoo 和 IBKR 把历史成交标准化为本地交易账本，按“账户 + 代码”匹配，并用 FIFO 重建当前剩余批次。
3. 每个账户独立计算。IBKR 以账户 Base Currency 为口径，成交若有 `FX Rate to Base` 则优先使用；Moomoo 通用账户没有单一固定本位币，因此以同步时 Catfolio 选中的显示币种为口径。其余情况使用交易日的历史日汇率。
4. 单个剩余批次的汇率影响为：`数量 × 当前价 × (当前资产币/账户币汇率 - 建仓时汇率)`。批次求和后转为 USD 存储，界面再按当前显示币种换算。
5. 成交历史不完整但有建仓日时，结果标记为“估算”；缺账户币种、建仓日或历史汇率时，明确标记为“不可算”，不会用 0 冒充。

IBKR 的 Activity Flex Query 应输出 XML，时间范围覆盖完整成交历史，并至少加入：

- `Account Information`: Account ID、Base Currency
- `Open Positions` / Summary: Symbol、Description、Currency、Asset Category、Quantity、Mark Price、Market Value、Cost Basis Price、Cost Basis Money
- `Trades` / Executions: Account ID、Trade ID、Symbol、Description、Currency、Asset Category、Buy/Sell、Quantity、Trade Price、Trade Date、FX Rate to Base
- `Cash Transactions`: Account ID、Currency、FX Rate to Base、Symbol、Description、Date/Time、Amount、Type、Transaction ID、Code（用于同步已入账利息、股息和入出金；不要同时导入 Interest Accruals，以免月末入账时重复计算）

## 本机数据与第三方服务

- 持仓账本写入 App 的 Application Support，使用 iOS 文件保护；每天同步时保留一份市值/成本快照。
- CSV 不上传，导入会替换手机上的当前持仓。
- ETF 穿透使用 App 内置的 Vanguard S&P 500 与 Invesco EQQQ 官方持仓快照；支持 VUAG、VUSA、SPY、VOO、IVV、EQQQ 和 XS2D（含同基金常见欧洲上市代码）。XS2D 的净持仓金额只分配一次，2x 日杠杆不会再次乘到市值或成本上。
- 成交量与历史日线支持直连 Massive 和 Financial Modeling Prep，并保留 Yahoo 自动回退；API Key 只保存在设备 Keychain。
- 个股 OI 持仓墙直接读取 Yahoo 期权链，无需 Massive Key、Python 或桌面服务；沿用 yfinance 的到期日清单与逐到期日读取方式。7/30/90 天范围内逐个校验，缺失 OI、缺失到期日或请求失败不会发布新的部分持仓墙，也不会用成交量替代 OI。仅处理可核对的 REGULAR 合约；数据源覆盖不代表交易所全合约覆盖。
- OI 使用独立 Yahoo 本地缓存（不混用旧 Massive 缓存），手动刷新，失败保留旧数据并显示获取时间。OI 结算日期未提供时明确标为未知；429 停止请求并冷却，不绕过限流。当前网络已观察到 Yahoo 429，不能保证自动获取成功。回归检查：`python3 v3_backend/tests/test_ios_options_oi.py`（包括模拟网络的多到期日、缺数、缓存与限流测试）。
- AI 可选直连 DeepSeek；只发送组合摘要与当前问题，API Key 保存在 Keychain。问答历史使用 iOS 文件保护保存在本机，并排除 iCloud 备份。

## 运行

个股研究区新增「管理层兑现情况」：在 iPhone 下载并分析最近 4、6 或 8 季度的已有电话会文字稿和财报，对照原话与后续结果。仅支持已确认的美国上市公司证券，需 FMP 文字稿/财报权限，以及支持 Apple Intelligence 的 iOS 26 设备。资料和结果仅存本机，未就绪时不切换云端模型。页面提供来源、待验证状态及本机资料删除入口。[实现边界与验证说明](../docs/ios-management-delivery.md)。

1. 用 Xcode 26 打开 `CatfolioIOS.xcodeproj`。
2. 选择模拟器或已签名的 iPhone 后直接运行。
3. 在 App 的“设置”中直连券商或导入 CSV；不需要先启动后端。

应用最低支持 iOS 18。iOS 26 上使用原生 Liquid Glass；旧系统使用系统材质回退。

## 本地资源

ETF 穿透所需的静态持仓快照位于 `CatfolioIOS/Resources/ETF/`，由 iOS 工程直接打包读取。构建和运行不依赖仓库中的 Web/FastAPI 目录。

## 佩洛西模式

设置中的开关与人物多选切换独立模拟账户。App 从 Core 发布包的历史快照与 Pelosi PTR 构建 `LocalTransactionRecord`、`LocalPositionRecord` 和每日账户快照，使用现有持仓、Today、History、Performance、ETF 和个股详情界面。模式不再屏蔽行情、历史曲线或收益分析，也不写入真实/假数据账本。选择人物后，账户范围包含新选中的人物。

模拟账本口径（保留在数据层，不在页面反复展示）：

- 13F：在申报日后的首个可用交易日，以收盘价把账户调到报告股数；报告日至模拟执行日之间的拆股先调整股数。第一期视为初始建仓，后续产生 BUY/SELL；较晚提交的旧报告不覆盖新报告。季度缺口/不完整报告不直接推导退出，未匹配证券按 CUSIP 保留相应旧仓，不阻止其他证券正常退出。
- Pelosi：PTR 使用交易日期后的首个可用交易日收盘价；金额按用户指定的披露上限。年度报告在申报日把已知股票调整至上限金额对应的股数，之后继续处理 PTR。超过已知持仓的卖出只关闭已有数量，剩余记入诊断，不虚构期初持仓或做空。
- Yahoo split-only close 用于模拟成交：不使用含分红复权的 `adjclose`。先按拆股档案恢复当日价格，再维护实际日期的股数和成本。逐日估值最多沿用七天内报价；交易、建仓、拆股和持仓均进入同一账本。历史成本线表示模拟净投入，买入为流入、卖出为流出。
- 只有可匹配且有历史报价的股票/ETF进入模拟账本。未识别证券、缺报价及无法确定合约的期权记录留在独立诊断文件，不能冒充股票交易。当前模拟不含未取得的分红、费用和现金资产，不是人物真实账户收益。

每日快照直接提供给首页和 Performance；Today 使用现有股票行情接口。`Application Support/InvestorSimulation/` 独立保存账本和各人物组合的诊断，网络失败时可回退已保存账本；进程内五分钟缓存避免反复重建。AI 读取所选模拟账户上下文，不混入个人账户对话。

运行 `python3 scripts/export_ios_public_investors.py` 更新离线 Core 历史资源，默认读取 T7 的 `current.json`（可传 `--pointer`）。导出只消费当前发布的归并视图和 `derived.activityIds`，保留源文件 SHA256。当前资源发布为 `d2bffff934734d16`，截至 2026-09-07；后续行情由 App 获取。尚未配置 Core 披露自动更新或对外分发。

`PublicInvestorCatalogTests` 包含确定性账本用例和联网验收 `testLiveInvestorAccountTodayHistoryAndPerformance`。离线运行时可通过 Xcode 的 `-skip-testing:CatfolioIOSTests/PublicInvestorCatalogTests/testLiveInvestorAccountTodayHistoryAndPerformance` 跳过联网验收。

## 界面语言

设置 → 偏好设置 → 语言，支持「跟随系统」「简体中文」「English」。默认选择系统首个受支持的语言，其他语言回退到英语。偏好仅保存在此设备，切换即时生效，不重建导航、不更改显示币种或公司名称偏好。

界面资源在 `CatfolioIOS/en.lproj/Localizable.strings` 和 `CatfolioIOS/zh-Hans.lproj/Localizable.strings`；动态文案使用 `L10n.text("已同步 \(count) 个持仓")`，目录键使用 `%@` 占位符并保留顺序。新增语言时扩展 `AppLanguage` 并添加对应资源。

股票代码、账户名称、API 字段、枚举 rawValue 和图表系列 ID 保持原值，只翻译显示文案。AI 新问答请求遵循所选语言，已有聊天、缓存研究内容及外部服务原始返回文本不自动重译。系统授权页面使用 iOS 自身的语言设置。

验证：`LocalizationTests` 覆盖资源打包、双语占位符、动态插值、语言回退、偏好保存和稳定数据标识；`python3 scripts/check_ios_localizations.py` 检查文案键覆盖与资源一致性。

账户列表、账户详情、历史筛选和个股账户切换会翻译默认昵称及自动生成昵称（如「全球账户 / Global account」「橘子 / Orange」），保留券商前缀和数字后缀。账本中的账户名、去重判断、编辑框及导出保留原值；尚无对应词条的自定义昵称不会被部分替换。

### 内容语言

预测市场、新闻和新生成的 AI 研究结果跟随设置中的中文／英语选择。Polymarket 搜索先确定盘口及报价，再用 `/markets/keyset` 的 `locale=zh/en` 与盘口 ID 获取本地化标题；选项按原始索引匹配，概率及成交量保持不变。[接口文档](https://docs.polymarket.com/api-reference/markets/list-markets-keyset-pagination)。未提供所选语言的盘口会被过滤，空状态会说明语言限制。

新闻使用对应 Google News 地区版本及 Yahoo 语言／地区参数，并过滤不匹配的中文／非中文标题。SEC 原始申报文件仍以原文作为引用证据。AI 任务启动时固定输出语言，子任务与模型回退沿用该语言；盘口、个股研究和组合研究缓存分语言保存。旧版未标记语言的 AI 缓存保留在磁盘，但需重新生成后展示。
