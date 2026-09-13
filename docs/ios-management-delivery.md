# iOS 管理层兑现情况

入口：个股详情 → 研究区 →「管理层兑现情况」。第一版仅向本地证券参考库中确认的美国上市公司证券展示；基金和未确认挂牌市场的证券不显示入口。

## 使用与隐私

- 选择最近 4、6 或 8 季度，点击「下载并在本机分析」。FMP Key 沿用设置 → 服务商中的本机 Keychain 配置，需要电话会文字稿和财报接口权限。
- 只下载已有文字稿，不下载录音、不做转写。先查询可用季度，去重、排序、排除未来日期；至少四个连续财季。请求八季而来源只有六季时显示实际覆盖。
- iPhone 直接以 GET 访问 FMP。数据、分析提示和结果不会进入 Catfolio 后端、DeepSeek、远程 AI 或组合云同步。数据服务仍接收下载所需的证券代码、期间和 API Key。
- 仅调用 `SystemLanguageModel.default` 的设备端模型。需要 iOS 26 及支持并已启用 Apple Intelligence 的设备。模型未就绪或拒绝生成时显示原因/失败状态，不回退到云模型。
- `Application Support/Catfolio/ManagementDelivery/` 按证券、季度范围、内容语言分开保存。目录和文件设置完整文件保护，排除设备云备份；文件名为哈希，不包含凭据。
- 首次下载完成即保存资料；分析取消后可重用。更新已有报告时，完整下载与分析成功后才替换旧报告。离开页面或 App 进入后台时取消当前分析。页面提供删除当前范围及语言的资料入口。

## 资料与判定边界

数据接口：FMP stable `earning-call-transcript-dates`、`earning-call-transcript`、`income-statement` 和 `cash-flow-statement`。季度财报取所选长度，年度财报辅助核对全年目标，并限制到文字稿覆盖的发布日期范围。财报保存原始 JSON，分析消费标准化收入、利润、EPS 和现金流字段。当前不分析 10-K/10-Q 的完整叙述章节，也不计算增长率、利润率、分部指标或调整后指标。

文字稿全文按 4,200 字符、400 字符重叠分块，每次创建新模型会话。每段提取最多三项明确承诺；提取结果必须能在该段找到对应原话。来源 ID 由程序赋值，承诺 ID 按来源与原话生成稳定哈希。同一次运行最多核对最近 40 项提取结果，并披露截取及无法核对原话的数量。该结果不是全部承诺的穷尽审计。

数字判定由规则执行，AI 不提供实际财务数字或数字兑现状态：

- 只接受可核对的公司整体 GAAP 口径、明确财年/财季/币种和支持的财务字段；不明口径、非 GAAP、分部或缺失资料留为「待验证」。FMP 为标准化财报来源，原始申报口径仍需沿来源复核。
- 数字从原话中的确切数字 token 解析，并验证 million/billion 数量级。季度、年度不混用，缺失数值不补零。
- `atLeast` ≥ 下限；`atMost` ≤ 上限；明确双边限制的 `between` 要求落在区间内。收入/利润指引区间按下沿考核，超过上沿仍视为达到目标。没有自行设定「差一点也算兑现」的容差。
- 后续财报必须在承诺之后公开，期间结束日在承诺之后；不使用未来资料，也不能用更长期间结果满足更早的明确截止日。重复申报数值冲突时留待验证。
- 单项全部达标为「已兑现」，全部不达标为「未兑现」，同一承诺有独立目标通过及失败才为「部分兑现」。任何目标证据不足，整项为「待验证」，同时保留已核对的子目标证据。

定性承诺由设备端 AI 匹配最多六段相关后续原文。需要原定期限及带明确年份的事件日期，原话必须在候选段中存在；没有找到证据不能判失败，后续证据冲突也留待验证。此初版有意保持保守，很多没有明确事件日期的定性承诺会待验证。

页面显示 AI 总结、四种状态的数量及每项承诺的原话、原定期限、结果、方法和可展开来源。财报优先链接到提供的原始申报 URL；文字稿保留不含 Key 的 FMP 来源接口链接。该链接仍需要 FMP 权限，App 内同时可直接查看已下载全文，不将 Key 拼进外链。

## 实现与验证

- `ManagementDelivery.swift`：资料/承诺/结果模型、资格筛选、数字规则。
- `ManagementDeliveryClient.swift`：FMP 下载、共享限流、财报解析、本地文件保护。
- `ManagementDeliveryAnalyzer.swift`：设备端模型、分块、引用校验、证据检索、总结。
- `ManagementDeliveryView.swift`：任务生命周期、缓存、个股折叠卡片和来源查看。
- `ManagementDeliveryTests.swift`：阈值、上下限、复合目标、口径/期间/币种不匹配、缺数、冲突、未来资料、伪造原话、下载契约、凭据隔离、文件存取、取消和窄屏渲染。

运行：

```sh
xcodebuild -project CatfolioIOS/CatfolioIOS.xcodeproj -scheme CatfolioIOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:CatfolioIOSTests/ManagementDeliveryTests \
  -only-testing:CatfolioIOSTests/HoldingDetailInteractionTests test
```

模拟器测试使用明确标注的固定资料和模型替身，不能证明实际 FMP 账号权限或真机模型提取质量。完整文件保护的设备属性断言只在真机运行，模拟器校验云备份排除和文件存取。真实资料与 Apple Intelligence 端到端验收仍需在配置了相应 FMP 权限的支持设备上进行。

2026-09-13 验证：Xcode 26.5 / iPhone 17 Pro 模拟器构建通过；本功能 21 项测试与现有个股页交互 3 项测试全部通过。已查看 320/393 点宽度及展开证据的渲染图。本功能 68 处本地化调用均有中英资源及匹配占位符。全项目本地化扫描仍报告工作区其他策略/分析师页面的缺项，本次未改动这些页面。

模型会话边界参考 [Apple 设备端模型上下文说明](https://developer.apple.com/documentation/Technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)。FMP 接口参考 [官方 API 文档](https://site.financialmodelingprep.com/developer/docs/stable)。
