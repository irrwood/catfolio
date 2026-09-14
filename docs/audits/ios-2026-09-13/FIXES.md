**已确认问题修复记录 · 2026-09-14**

已修复原审查记录 01–20，包含第 19 项负轴标签及可读性调整。第 21 项没有作为确认缺陷修改；它在本次中文环境的全套测试中通过。下表对应当前代码；原 README 和 evidence 中的复现保留为修复前证据。

| 编号 | 修复后的行为 | 主要实现 |
|---|---|---|
| 01 | Moomoo / IBKR 成交按账户及成交 ID 合并；空数组、失败或较短时间窗口不删除旧成交，相同 ID 可更新券商修订值。 | LocalPortfolioStore.replace、APIClient.importMoomoo/importIBKR |
| 02 | 从 Moomoo 账户市场权限和持仓市场的并集请求历史；已清仓美股可确定 USD，其他市场从订单详情补币种。无法核实币种时提示并保留原有历史。 | MoomooAccount.historyMarkets、resolvingFillCurrencies |
| 03 | 明确返回空持仓时更新相应账户为空，保留成交和账户身份；IBKR 缺少 OpenPositions 栏目、只有 LOT 而没有 Summary、或报表无效时拒绝覆盖。只返回成交的其他账户不会被清仓。 | IBKRFlexClient.parseStatement、IBKRFlexView / MoomooOAuthView 同步入口、LocalPortfolioStore.replace |
| 04 | CSV 支持 LF、CR、CRLF，并保留引号字段内的换行。 | LocalCSVImporter.parseRecords |
| 05 | 用已有拆股目录重建当前股数和单位成本，原始成交不变；无法解释的超额卖出报错。同一文件含多个明确账户时要求分开导入，避免互相抵销。 | LocalCSVImporter.parse |
| 06 | 移除涨跌幅阈值产生的虚构入出金；真实价格与汇率涨跌计入 TWR。仅在不完整账本模式下，把已有的无现金证券数量变动按当日价格估作转入/转出，并列入数据说明。 | DailyTimeWeightedReturn、LocalServices |
| 07 | FX 回退结果明确带 GBP 单位，展示管线按 GBP 转换到内部 USD。 | FXImpactCalculator.Result、LocalPortfolioEngine.presentation |
| 08 | ENR / RWE 仅在 EUR 情况下使用德国映射，USD ENR 保留美股代码。 | LocalMarketDataClient.yahooSymbol |
| 09 | 行情携带观察时间；拒绝早于已有报价、超过 7 天或未来的异常报价。旧版文档参考已有整体时间戳；仅有日线时采用真实日期。IBKR 采用报表日期，整体更新时间不再冒充当前时刻。 | ObservedMarketQuote、latestRawPrice、updateMarketQuotes |
| 10 | FX 回退先按账户与币种分别消耗买入批次，再汇总。 | FXImpactCalculator.openLots |
| 11 | 汇率回溯按真实日历天数判断；当前日期不再被截到资源最后一日，过期返回缺失，回溯值标为估算。 | GBPFXRates.quote、FXImpactCalculator.impact |
| 12 | FIFO 优先使用有效 executedAt，支持带时区及小数秒；没有时间或时间完全相同的记录保留买入优先的日期级估算顺序。 | orderedForLotMatching、RealisedProfitCalculator |
| 13 | 先为所有卖出预留同日买入，再处理 30 天匹配，最后进入 Section 104。 | UKShareMatching |
| 14 | 启动/初次同步时，云端缺键不会删除本地设置；仅明确的服务器变更通知允许传播删除。后续已补上设置页开关/状态、按键增量推送及 iCloud 签名权限，默认本机关闭。 | CloudPreferences、CloudPreferenceSync、SettingsView；[补全说明](../../ios-icloud-preferences.md) |
| 15 | 每个 AI 请求绑定会话 ID 与请求代次；新建、切换、删除、清空会话会取消旧请求，迟到回答和错误均被拒绝。 | AIView |
| 16 | 最新报价、Today 与历史曲线并行启动；每次刷新只重建一次完整历史，报价写回保留已完成曲线；账本历史最多同时下载 4 只证券。 | AppModel.refreshPortfolio、LocalServices |
| 17 | 文件读取和预览在后台进行，预览最多解析 27 条记录；完整解析留到确认导入，避免重复解析整份 CSV。 | CSVImportView、SelectedCSVFile |
| 18 | 排队请求每次唤醒都重新检查退避截止时间；后来收到的 429 同样延后已排队请求，恢复后保持请求间隔。 | FMPRequestLimiter |
| 19 | 周期图负轴保留负号，去掉叠加透明度，采用可随明暗主题调整的次要文字颜色。 | CycleComparisonView |
| 20 | 行权价保留最多四位小数、去掉尾零，10.1 与 10.2 不再显示成同一个整数；说明文案同步更新。 | OIPriceLabel |

**用户提出回归风险后的再次复查 · 2026-09-14**

确认上轮修复引入了一个此前测试未覆盖的边界：CSV 只有日期时，导入器会将 `executedAt` 保存为当天 00:00；新的 FIFO 排序在时间相同时按 ID 排列，可能让 `a-sell` 排在 `z-buy` 前，导致原本可重建的成本变成不足。已经修正为时间相同时沿用买入优先，再按 ID 排序，同时保留旧账本 BUY_BACK 等动作别名的兼容。有明确时间先后的成交仍按时间排序。

新增 `testDateOnlyAndEqualTimeCSVKeepTheBuyBeforeItsSale`，从 CSV 导入一路验证到已实现收益。生产排序函数的修复前后输出分别为 `["SELL", "BUY"]` 和 `["BUY", "SELL"]`，复现脚本见 [复查证据](fixes-evidence/regression-review/)。这说明前一轮全套测试通过并不能证明没有新增问题。本轮复查不是对所有路径的穷尽验证，真实券商在线同步、多设备 iCloud 与长时间运行仍未验收。

本轮复查验证：全套 645 项，644 通过、1 跳过、0 失败；最后补全旧动作别名兼容后，73 项相关回归全部通过；12 项生产函数运行回归通过；最终 Release 真机目标编译通过。见 [全套摘要](fixes-evidence/regression-review/full-zh-summary.log)、[最后回归摘要](fixes-evidence/regression-review/final-focused-summary.log) 与 [Release 编译摘要](fixes-evidence/regression-review/release-device-summary.log)。

**iCloud 设置入口及权限补全 · 2026-09-14**

用户要求补全后，已增加「设置 → iCloud → 同步偏好设置」，每台设备分别开启，默认关闭。页面说明允许列表、启用时的合并方式、停止同步的效果，并显示自动同步、错误、大小限制及最近接收入站更新的状态。开关不会同步到别的设备；关闭不删除本地或云端设置。最近接收时间不是所有设备已收到最新修改的证明。

将同步控制器收敛到主线程并注入存储接口，测试不再写入真实 iCloud。只推送本地实际变化的键，避免无关设置变动覆盖迟到的云端值。通知处理保留初次同步、账户变化和明确删除的边界。Debug / Release 均绑定 Key-value storage entitlement，Xcode 已启用相应 capability。

- 第一轮相关回归 39 项通过；最终全套 658 项，657 通过、1 跳过、0 失败。仍排除两项显式真实网络测试，另一个实时测试按其 opt-in 条件跳过。见 [相关回归摘要](fixes-evidence/icloud-settings/focused-summary.log)、[最终全套摘要](fixes-evidence/icloud-settings/full-zh-summary.log)。
- Release **带签名构建通过**，`codesign --verify --deep --strict` 通过。已核对签名内的 `2G5PCQU652.com.catfolio.ios` 与 provisioning profile 允许的 KVS 标识匹配。见 [构建摘要](fixes-evidence/icloud-settings/release-signed-summary.log)、[签名验证](fixes-evidence/icloud-settings/signing-verification.log)。
- 实际设置组件的四种隔离状态截图均已检查：[中文关闭](fixes-evidence/icloud-settings/icloud-off-zh.png)、[英文开启](fixes-evidence/icloud-settings/icloud-enabled-en.png)、[中文异常](fixes-evidence/icloud-settings/icloud-unavailable-zh.png)、[英文深色大字体](fixes-evidence/icloud-settings/icloud-large-text-en.png)。截图使用测试存储，不代表真实云端状态。
- 双语 2215 个 key 一致，plist 及 `git diff --check` 检查通过；[本轮源码哈希](fixes-evidence/icloud-settings/source-sha256.txt)。

完整本地结果位于 `/tmp/catfolio-icloud-20260914/`。版本仍为 1.0 (9)，未归档或上传。本轮完成设置入口、同步控制及签名配置；真实同一 Apple 账户的双设备传递与离线重连仍未验收。范围与实现见 [iCloud 偏好同步说明](../../ios-icloud-preferences.md)。

**首轮验证记录**

- 最终代码使用 Xcode 26.5、iOS 26.5、独立 iPhone 17 Pro 模拟器，中文区域全套 XCTest：644 项，643 通过、1 项按条件跳过、0 失败。完整记录在 [测试摘要](fixes-evidence/full-zh-summary.log)。显式排除 Earnings 与公开投资者的实时网络测试，SecurityDebate 的实时测试按其 opt-in 条件跳过。
- 账户边界、IBKR 报价日期与旧文档兼容保护的英文环境回归：130 项全部通过，见 [测试摘要](fixes-evidence/final-regressions-en-summary.log)。包括新增的 17 项 AuditRegressionTests。
- Python 执行 Swift 生产函数的延迟响应/首页加载回归，券商空账户同步入口，以及 OI 数值、网络缓存回归：12 项通过，见 [结果](fixes-evidence/pytest-runtime.log)。涵盖 AI 供应商忽略取消仍迟到返回、切换/删除/清空会话、旧请求不能清除新请求忙碌状态，以及报价先于阻塞历史发布、历史只计算一次。
- 最终代码的 iOS 真机目标 Release 编译通过（未签名、未归档上传），见 [构建摘要](fixes-evidence/release-device-summary.log)。编译仍报告已有的无须 await 和 Sendable 警告，未作为本次确认问题扩修。
- 中英文本检查通过：2200 个双语 key、2193 处本地化调用。`git diff --check` 通过。
- 额外运行旧 OI 源码字符串测试时，`test_oi_complete_chain_and_vp_template` 仍失败：它要求当前代码已不存在的 `shouldRefresh` 分支、旧标题及固定 400 高度。已验证这些断言在修复前的 git HEAD 上同样失败，见 [基线核对](fixes-evidence/legacy-oi-assertions.txt)。该检查与此次小数行权价修复无关，未修改产品行为以迁就旧断言；相关数值和网络运行测试均通过。

**边界**

Moomoo 新增市场/订单详情字段依据官方 [账户接口](https://open.moomoo.com/api/trading/account/get-accounts)、[命名字典](https://open.moomoo.com/api/trading/naming-dictionary) 和 [订单详情接口](https://open.moomoo.com/api/trading/order/get-order-details) 核对。本次未使用真实券商授权做在线同步，也未上传归档或改变发布版本。

拆股沿用现有目录，国际公司行动仍受数据覆盖限制。成交时间缺失时只能按日估算。部分历史的安全合并不会自动删除券商已取消但未明确通知的旧成交，仍需券商修订信息或人工对账。缺失历史/币种/汇率会保留提示，修复不意味着能够凭空恢复以前已经丢失的原始数据。

构建及完整 xcresult 位于 `/tmp/catfolio-ios-fixes-20260914/`，原审查证据保留，未改写真实账户数据。
