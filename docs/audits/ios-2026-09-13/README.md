**Catfolio iOS 全面审查 · 2026-09-13**

**2026-09-14 修复更新：01–20 已完成代码修复，验证结果和限制见 [修复记录](FIXES.md)。下文保留修复前发现，不再代表这些问题仍存在于当前代码。第 21 项本次全套测试通过，未单独实施修复。**

截至 2026-09-14，保留 21 条审查记录：19 项代码/行为问题、1 项设计表达问题、1 项待交叉复现。前 20 项合计 8 项 P1、12 项 P2；第 21 项暂不计入已确认缺陷。优先处理同步丢失历史、持仓重建、收益计算和证券识别。本轮审查及复核补充未修改 App 实现。

P1 表示应在下一次发布前优先修复；P2 表示需要排期修复的功能、数据、交互或性能问题。下文分别标明独立复现、代码链路分析和模拟器回归结果，未把所有失败测试直接视为产品缺陷。

审查覆盖 101 个 App Swift 源文件所在的主要模块：账户与券商同步、CSV、本地存储、持仓与收益引擎、历史交易、行情与缓存、ETF/研究/期权图表、AI 会话、设置及云偏好。执行了 iOS 26.5 模拟器测试，并检查 iOS 18 的 iPhone SE 3 首页、收益页和设置页。未使用真实券商授权完成在线端到端验收，未在物理设备上测量耗电、温升或长时间内存增长。

工作区原有未提交改动，审查期间也有其他改动进入工作区。代码链接对应报告生成时的位置；测试使用本轮构建的快照，源码哈希和独立复现脚本已保存在 [证据说明](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/README.md)。

**2026-09-14 复核补充**

根据本次收到的逐项复核反馈：01–05、07–18、20 与复核方的当前代码核查一致，06 的真实涨跌被抹平问题也得到认可；19 据反馈遵循 Figma 原稿，但负号与可读性问题仍保留为设计表达问题，是否调整由产品决定。第 21 项在另一环境未复现，现降为待交叉复现。本轮只重新查看了 06、16、19、21 的相关函数，没有把反馈冒充为又一次全量独立验收。

本轮额外核对确认：普通真实账户刷新路径在最新报价前后各调用一次完整历史曲线计算。逐只串行读取历史已在原 16 条列出；二次计算补充到同一条，避免按不同描述重复计数。底层有行情缓存，因此两次计算不意味着必然下载两遍。

**01 · P1 · Moomoo 历史请求失败仍会覆盖本地完整交易历史**

Moomoo 按市场获取历史成交时，异常仅转成 warning，然后返回剩余的部分成交；导入层继续把这个数组交给 replace，存储层先删除该来源/账户的旧交易，再写入本次数组。持仓成功、历史超时的一次同步，就可能把完整历史替换为部分甚至空历史，进一步改变已实现收益和历史曲线。证据是完整调用链，未对真实账户执行破坏性同步。

位置：[MoomooOAuthClient.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/MoomooOAuthClient.swift:475) → [APIClient.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/APIClient.swift:977) → [LocalPortfolioStore.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalPortfolioStore.swift:1425)。修复时应传递每账户、每市场的完整性状态；只有完整快照才能替换历史，部分结果应合并并保留旧记录。

**02 · P1 · Moomoo 已清仓证券的历史成交被静默丢弃**

导入成交时，币种必须从“当前持仓”查到，查不到就直接 return nil。因此已经卖光的股票，其历史买卖都会被过滤。上游还只查询当前仍有持仓的市场，整个已退出市场的历史也不会获取。独立复现：输入 OPEN、CLOSED 两条成交，仅有 OPEN 当前持仓，输出只剩 OPEN 一条，CLOSED 被丢弃。这与 01 不同：全部网络请求成功时仍会发生。

位置：[APIClient.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/APIClient.swift:935)、[APIClient.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/APIClient.swift:949)、[MoomooOAuthClient.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/MoomooOAuthClient.swift:463)。应从成交/证券元数据解析币种，并按授权账户支持的市场读取历史。

**03 · P1 · 全部清仓后，IBKR/Moomoo 无法把本地持仓同步为空**

两个客户端都把空持仓数组当作错误抛出。账户正常卖光后，同步在写入前失败，旧持仓仍留在手机上。账户身份又主要由持仓/成交推导，单独同步已空账户也缺少可靠边界。位置：[IBKRFlexClient.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/IBKRFlexClient.swift:225)、[MoomooOAuthClient.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/MoomooOAuthClient.swift:479)、[LocalPortfolioStore.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalPortfolioStore.swift:1392)。

应区分“请求失败”和“成功返回零持仓”，传入明确的已同步账户列表，让成功的空快照关闭这些账户的旧持仓，同时保留历史交易。

**04 · P1 · CRLF 换行的正常 CSV 无法导入**

解析器按 Swift Character 遍历，Windows 常见的 CRLF 是一个扩展字素簇，不等于单独的 CR 或 LF，因此未被识别为换行。只有分隔符检测函数归一化了换行，实际记录解析仍使用原字符串。独立复现：表头加一条有效买入的 CRLF 文件只解析成 1 条记录，导入报“没有有效交易”；LF 版本可用。Trading 212 报表也复用了这个解析器，若下载内容使用 CRLF，同样受影响。

位置：[LocalPortfolioStore.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalPortfolioStore.swift:2513)，尤其 [LocalPortfolioStore.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalPortfolioStore.swift:2533)。应统一处理 CRLF/CR/LF，并覆盖引号内换行、转义引号的回归样例。

**05 · P1 · CSV 持仓重建没有处理拆股，能把有效持仓算成零**

CSV 用原始买卖股数累加，卖出后负数直接截成零，没有应用拆股事件。复现：NVDA 在 2024-06-07 买 10 股，单价 1,000；10:1 拆股后，6 月 11 日卖 50 股。正确剩余 50 股、单位成本 100；实际导入剩余持仓为空，warnings 也为空。其他收益引擎已经使用拆股目录，因而同一份账本会出现不同口径。

位置：[LocalPortfolioStore.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalPortfolioStore.swift:2354)、[LocalPortfolioStore.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalPortfolioStore.swift:2369)。应在持仓重建中使用统一的公司行动处理，保留原始成交，并对无法解释的超额卖出明确报错或提示。

**06 · P1 · 收益引擎会把真实的大幅涨跌改写成入出金**

不完整账本会启用 1.5 倍阈值。只要当日组合增长超过 50%，或下跌超过约 33.3%，引擎就把差额当成未记录的转账，当日净值不变化。判断没有核对价格是否真实变化。复现：投入 100 买一股，次日价格从 100 涨到 160，无任何资金流；实际 NAV 仍是 1，并虚构 60 入金，正确 NAV 应为 1.6。这也会扭曲后续累计收益及回撤。

位置：[DailyTimeWeightedReturn.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/DailyTimeWeightedReturn.swift:158)，调用处 [LocalServices.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalServices.swift:2494)。应根据明确资金事件/可验证的数据缺口补流水，不能仅凭涨跌幅改写收益；无法确认的区间应显示质量状态。

复核建议先扣除价格可以解释的变动，这有助于保护真实涨跌；但剩余差额仍不能自动认定为资金流，还应核对汇率变化、公司行动、费用与已知交易/现金流水。无法解释的余额应保留为数据缺口，而不是生成看似精确的入出金。

**07 · P1 · ECB 汇率损益回退路径把 GBP 金额当作证券报价币种**

GBPFXRates 的报价方向是“一英镑兑换多少外币”。成本乘以两次倒数汇率之差，结果是 GBP；调用方却按 position.currency 转成 USD。复现：美元成本 10,000，买入时 GBP/USD=1.5，当前=1.2；算法得到 GBP 1,666.67，界面管线把它当成 USD 1,666.67，而同一假设下应为 USD 2,000。问题发生在没有可用券商 FX 值、进入 ECB fallback 的持仓。

位置：[FXImpactCalculator.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/FXImpactCalculator.swift:83) → [LocalPortfolioStore.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalPortfolioStore.swift:1896)。应让结果类型携带实际币种，并统一到 USD 存储；测试必须独立检查单位，不能只重复实现中的公式。

**08 · P1 · 美股 ENR 被无条件映射为德国另一只证券**

证券映射表无条件把 ENR 改成 ENR.DE，忽略传入的 USD 币种。独立执行得到 yahooSymbol(ENR, USD) → ENR.DE，随后行情、历史和相关研究会使用错误证券。Energizer 的官方投资者页面确认其 NYSE 代码为 ENR、报价币种为 USD。[Energizer 官方证券信息](https://investors.energizerholdings.com/stock-quote)

位置：[LocalServices.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalServices.swift:3038)。应使用交易所/上市地与币种组成明确证券身份，EUR 德股映射不能覆盖同名美股。行情写回时也应核对返回证券和币种。

**09 · P2 · 过期缓存行情可以覆盖更新的券商报价，并被标成刚刷新**

实时行情失败时，intradayBars 无条件返回旧缓存；latestRawPrice 取最后一个 close，丢掉观察时间；updateMarketQuotes 再覆盖持仓并把 marketDataUpdatedAt 设为当前时间。例如刚同步到券商的新报价后，外部行情失败且磁盘有数日前缓存，旧价仍能写回持仓和当日快照。保留旧缓存本身合理，问题在于它被当成一次新报价成功。

位置：[LocalServices.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalServices.swift:1745)、[LocalServices.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalServices.swift:1253)、[LocalPortfolioStore.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalPortfolioStore.swift:1489)。报价结构应保留 observedAt/source/stale，比较时间后决定能否替换，并将“尝试刷新时间”与“数据时间”分开。

**10 · P2 · ECB FX 回退 FIFO 跨账户消耗买入批次**

openLots 只按 ticker 过滤和排序，没有按 accountKey 分组。复现：A 先买 100 股，每股 100；B 后买 100 股，每股 200，再由 B 卖光。正确剩余 A 的 10,000 成本，当前算法却消耗 A 的批次、留下 B 的 20,000 成本；样例 FX 损益从应有 GBP 1,666.67 变成 0。

位置：[FXImpactCalculator.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/FXImpactCalculator.swift:99)。应先在账户内匹配批次，再汇总选中账户；此问题针对 ECB 回退实现，另一条 LocalFXImpactCalculator 路径已有账户隔离，不能据此认为回退也安全。

**11 · P2 · 汇率“最多回溯 7 天”实际按数组行数判断，可采用数年前汇率**

GBPFXRates 用跨过的记录数作为 daysBack，没有计算日历差。仅含 2024-01-03 最后报价的样例，在查询 2026-09-13、within=7 时仍返回该旧报价，并声称只回溯 1 天。FXImpactCalculator 又把当前日期截到资源最新日期，可能将陈旧的“当前汇率”视为精确值。

位置：[GBPFXRates.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/GBPFXRates.swift:104)、[FXImpactCalculator.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/FXImpactCalculator.swift:68)。应计算真实日历天数，同时校验当前报价的年龄；资源过期应返回缺失或估算状态。

**12 · P2 · FIFO 已实现收益忽略成交时间，用 tradeID 排列同日交易**

LocalTransactionRecord 已保存 executedAt，但收益引擎只按日期、买入优先、tradeID 排序。同日 09:00 买 10 股@100、10:00 卖 10 股@200、11:00 再买 10 股@50；当第二笔买入的 ID 排在前面时，算法拿未来买入批次匹配先前卖出。复现收益为 1,500，正确应为 1,000，剩余成本也随之错误。影响没有券商已实现结果、使用本地估算的交易。

位置：[RealisedProfitCalculator.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/RealisedProfitCalculator.swift:167)。应优先按有效 executedAt 排序；只有缺少时间的记录才采用明确的日期级规则，并标明估算边界。

**13 · P2 · 英国股票匹配没有全局优先保留同日买入**

实现逐笔卖出先做同日、再做未来 30 日匹配，但较早卖出会提前消耗后来卖出当天的买入。有效持仓池样例：1 月 2 日卖 10 股，1 月 10 日买 10 股并卖 10 股。当前把 1 月 10 日买入匹配给 1 月 2 日卖出，再把 1 月 10 日卖出放入 Section 104；同日买卖应先匹配。HMRC 明确规定同日匹配优先于随后 30 天匹配。[HMRC CG51560](https://www.gov.uk/hmrc-internal-manuals/capital-gains-manual/cg51560)

位置：[UKShareMatching.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/UKShareMatching.swift:114)、[UKShareMatching.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/UKShareMatching.swift:135)；显示入口 [HistoryView.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/HistoryView.swift:1131)。应先完成所有日期的同日聚合匹配，再处理 30 天和持仓池。此项确认的是历史匹配标注错误，不代表完成了税务申报全规则审计。

**14 · P2 · 启动时空 iCloud 偏好会删除已有本地设置**

start 每次都先全量 pull 再 push；pull 遇到云端缺键就删除 UserDefaults。它没有区分云同步尚未完成、云端从未保存过该键、用户明确删除三种状态。隔离 UserDefaults 与空云存储复现：本地已有 EUR 显示币种和筛选规则，启动同步后两者都变成 nil。

位置：[CloudPreferences.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/CloudPreferences.swift:92)、[CloudPreferences.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/CloudPreferences.swift:136)，启动调用 [CatfolioIOSApp.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/CatfolioIOSApp.swift:37)。应实施初始合并/迁移，等同步结果明确后应用远端值，仅在有明确删除语义时删除本地键。模拟器未签名造成的 KVS entitlement 日志不作为生产配置缺陷。

**15 · P2 · AI 请求途中切换会话，回复会写入错误的会话**

发送 Task 跨 await 后直接向视图当前 messages 追加，保存时也使用当前 activeConversationID。请求期间侧边栏仍允许新建、打开和删除会话。A 会话发出慢请求后切到 B，A 的答案回来会追加并保存到 B；删除当前会话后迟到的答案也会污染之后打开的会话。清空按钮部分路径虽然禁用，侧边栏路径仍存在。

位置：[AIView.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/AIView.swift:446)、[AIView.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/AIView.swift:551)、[AIView.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/AIView.swift:527)。应在请求开始时固定 conversationID、请求代次和上下文，按会话更新存储；删除时取消或丢弃该会话的迟到响应。

**16 · P2 · 首页最新报价和 Today 更新被完整历史加载阻塞**

refreshPortfolio 先 await enrichPortfolioChart，之后才启动 daily changes 和 latest quotes。账本历史又逐只证券串行 await，包含历史上已清仓的股票。因此冷缓存、多标的或一个慢数据源就能拖延整个首页新报价更新；本地首屏虽已展示，但其内容持续陈旧。此项由调用顺序确认，未将模拟网络测试的耗时当作真实券商延迟。

2026-09-14 补充：在有持仓且刷新正常完成的普通真实账户路径，报价更新前后分别调用 enrichPortfolioChart，都会进入 portfolioChart 的账本重建路径。第二次可能复用 12 小时内的历史行情缓存，但仍会重复计算、组装曲线。修复时应复用已计算的历史，明确哪些变更只需更新末点，哪些必须重建历史。

位置：[APIClient.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/APIClient.swift:139)、[LocalServices.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/LocalServices.swift:2364)。应让报价、Today 和完整历史独立启动，保留 generation/cancellation 防止旧请求覆盖，并对历史下载采用有上限的并发与缓存。

**17 · P2 · CSV 文件预览在主线程完整解析，合法大文件会卡住交互**

文件选择回调同步读 Data，再同步创建 SelectedCSVFile，后者解码并遍历全部记录，仅为了显示预览；正式导入还会再次解析。允许大小为 50 MiB。以原解析器编译优化版测试 40.95 MB、65 万行文件，解析墙钟约 13.66 秒，CPU user 约 3.08 秒、sys 约 0.39 秒，进程峰值 footprint 约 200.6 MB。机器当时有其他测试负载，这不是 iPhone 性能测量，但足以证实不能把全量工作放在 UI 回调。

位置：[CSVImportView.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/CSVImportView.swift:200)、[CSVImportView.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/CSVImportView.swift:284)。应把文件读取、解码和解析移出主线程；预览只读取必要表头/有限样本，并复用解析结果或流式导入。

**18 · P2 · FMP 已排队请求不遵守后来收到的退避时间**

waitForTurn 预留一个时间点后直接 sleep；backOff 只改 nextAllowedAt，已经睡眠排队的任务不再检查。独立并发复现：第二个请求已排队时收到 5 秒退避，第二个请求仍在约 0.26 秒发出，可能导致多张研究卡片连续触发 429。

位置：[FMPRateLimiter.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/FMPRateLimiter.swift:23)、[FMPRateLimiter.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/FMPRateLimiter.swift:38)。应分别管理正常请求间隔和全局 blockedUntil，唤醒后重新检查退避，确保已排队请求也被推迟。

**19 · P2 · 周期对比图的负轴刻度丢失负号**

Y 轴从 -4 到 4 排列，却把 index 取绝对值后生成文字。低于零的 -10、-20 会显示成 10、20，使亏损侧与上涨侧数值相同。位置：[CycleComparison.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/CycleComparison.swift:396)。应保留符号，并明确涨跌幅单位；同时该组文字内外各设一次 0.4 opacity，最终约 16%，可读性也偏低。该文件属于审查时工作区中的新增功能。2026-09-14 收到的复核反馈说明这是按 Figma 原稿实现，本轮未另行获取 Figma 对照；因此本项评价的是数值表达，不认定为实现偏离设计。建议保留布局并补负号，提高必要刻度的可读性。

**20 · P2 · 期权 OI 的行权价全部取整，不同合约显示同一个价格**

OIPriceLabel 对所有价格先 rounded，再以零位小数显示；该函数用于选中行权价的描述。10.1、10.2 均显示 $10，10.5 显示 $11，用户无法从选中标签确认真实行权价。现有测试甚至固定了部分取整行为，因此测试通过不能证明产品表达正确。

位置：[OptionsOIView.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/OptionsOIView.swift:80)、[OptionsOIView.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/OptionsOIView.swift:995)。轴刻度可以按密度简化，但交互提示必须保留合约真实价格精度，按实际 tick/小数位格式化。

**21 · 待交叉复现（原 P2）· 嵌套弹层的刷新控件隔离**

2026-09-13 本轮 iOS 26.5 模拟器记录中，打开并刷新下一级弹层后，详情的继承刷新控件重新出现；该测试在全量与单独重跑中均于当时第 232 行失败：预期 refreshControl 为 nil，实际存在 UIKitRefreshControl。原始日志保留，说明当时观察到的行为，但不能据此断言所有环境都失败。

2026-09-14 收到的复核反馈显示该测试在另一环境的多次全套运行均通过。因此降为待交叉复现，需要对齐源码版本、iOS runtime、语言、模拟器状态和测试顺序后比较；尚未确定差异来自环境、时序还是代码版本。本轮未重跑该测试，也未确认新的用户可见误刷新或崩溃。

位置：[VolumeProfileView.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOS/VolumeProfileView.swift:314)；回归证据 [HoldingDetailInteractionTests.swift](/Users/qian/Documents/股票分析/CatfolioIOS/CatfolioIOSTests/HoldingDetailInteractionTests.swift:232)。进一步定位时需覆盖弹层呈现/关闭后的生命周期，同时核对父页和子页各自刷新能力；明确触发条件后再决定实现修复。

**原审查测试与设计检查结果（2026-09-13，保留原始记录）**

| 检查 | 结果 | 解释 |
| --- | --- | --- |
| iOS 模拟器构建 | 成功 | Xcode 26.5；不等于签名发布构建验收 |
| 完整 XCTest | 622 项：615 通过、6 失败、1 跳过 | 另外显式排除了 3 项在线测试 |
| 失败 UI 定向重跑 | 1 通过、1 失败 | 图表 motion 重跑通过；详情刷新隔离再次失败 |
| Python iOS 检查 | 118 通过、60 失败；14 subtests 通过 | 多处源码字符串断言已落后于当前实现，另有提取式 Swift 测试缺依赖和设计检查失败 |
| 本地化检查 | 通过 | 2,187 双语键、2,179 本地化调用点 |
| 设计规则检查 | 失败 | 存在绕过 Typography 的字体、直接颜色值；也有数值缩放规则误报 |
| iOS 18 / SE 3 | 启动及三个主页面可渲染 | 使用演示数据；未完成每条入口的触控与 VoiceOver 验收 |

6 个 XCTest 失败中，4 个是固定中文预期与英语运行环境不一致（3 个 PolicyShortcut、1 个 LocalPortfolioEngine）；1 个是本轮环境两次出现、另一环境未复现的刷新边界问题；1 个是图表测试进程被 kill，单独重跑通过，暂不列作 App 崩溃缺陷。复核反馈中的这 4 项均通过，符合其环境敏感的判断，不能计作 4 个业务缺陷。应使语言相关测试显式固定语言，或断言稳定语义。

Python 失败中，例如旧 Montserrat 字体、旧页面结构、旧字符串片段已与当前代码不同；这些断言需要和现行设计契约对齐。不能把 60 次检查失败全部算作 60 个 bug，也不能在检查长期红灯时认为回归保护有效。设计检查中，把周期图的时间轴换算识别成金额缩放，是一个需要修正的误报。

除 19、20、21 外，界面还有值得改进的可读性：iOS 18 首页图表的浅色轴文字在浅蓝背景上很难辨认；收益页空状态使用旋转、模糊并被边缘截断的装饰文字，用户不容易读到明确的状态与下一步。这两点有截图证据，属于设计建议，未额外计入上述审查记录，也未声称已测得具体对比度或全量无障碍合规性。

截图：[首页](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/ios18-home.png)、[收益页](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/ios18-returns.png)、[设置页](/Users/qian/Documents/股票分析/docs/audits/ios-2026-09-13/evidence/ios18-settings.png)。

建议修复顺序：先让同步不会覆盖不完整历史、空账户能正确落地，再统一证券/币种/拆股/成交顺序并校正收益计算；随后处理缓存时间语义、并发与主线程工作，最后修复图表标签、弹层和测试契约。每项修复应加入能区分“旧错误结果”和“正确结果”的小型回归样例。
