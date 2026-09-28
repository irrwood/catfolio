# iOS 估值、成长与质量矩阵

2026-09-20。入口：收益 → 估值 · 成长 · 质量。最低 iOS 18。

- 原有 P/E 财报计算及 FMP 备用逻辑保留；在明细单独列出 P/E 的来源和期间。P/E 不一定与年度指标同期间。
- EPS Growth：同一份 SEC 年报披露的本年、上年稀释 EPS 相除减一。使用同份报告中的比较数以处理已重述的拆股口径。上年 EPS ≤ 0 不计算同比；本年负 EPS 保留负增长。不使用营收或净利润增长冒充 EPS 增长。
- ROIC：年度营业利润 × (1 − 所得税费用 / 税前利润)，除以期初、期末投入资本的平均。投入资本 = 账面权益 + 已披露有息借款 − 现金及现金等价物。是自算的会计口径近似值，不声称与 FMP 相同。
- 只接 US-GAAP 的 USD 标准标签；所有分子、分母取同一申报 accession，期间精确匹配；期初资产负债表需在财年开始前 1–8 天。不混入季度/YTD值，不将受限现金合计当现金及等价物。
- 债务优先已披露总借款，其次 DebtCurrent + LongTermDebtNoncurrent；再其次长期债务的流动/非流动部分（或长期债务合计）加短期借款。短借合计未披露时，可用披露的商业票据加同报告披露的其他短借。没有短借或商业票据数据时不猜零；这些标准标签不保证覆盖公司自定义债务标签。
- 不调整经营租赁、商誉或研发。税前利润 ≤ 0、有效税率不在 0–100%、期初/期末资本 ≤ 0、所需字段缺失时明确缺失原因。金融行业不使用此 ROIC 口径。ROIC 不是跨行业的统一排名。

图表：三维坐标为 P/E、年度 EPS Growth、年度 ROIC，球体体积随仓位权重缩放（极小仓位有最小可见尺寸）。卡片点选股票，全屏拖动旋转、双指缩放、重置。二维视图显示 P/E × 年度 EPS Growth，点面积表示仓位，颜色为本组合 ROIC 相对大小；缺失 ROIC 使用空心点。三维只绘制三项齐全的持仓，其余留在明细，给出覆盖数和原因。无自动旋转动画；VoiceOver 可通过股票选择菜单读取、选中数据。

视觉修订：图表和选中指标使用一体式深色面板；三维球体按股票区分颜色，股票名称使用屏幕空间标注和引导线，优先避让球体与其他名称（最多显示七只，优先选中和大仓位股票）。屏幕空间标注使用与相机相同的视场角、位置、旋转和缩放投影。删除横向股票胶囊，改用指标区域的原生菜单。计算口径未改动。

财报快照沿用已有日缓存；旧 SEC 缓存缺少指标版本时重新读取，失败保留旧报表。查看估值页经过客户端时效检查，不再永远读取 cached()。行情和用户账本不会被新指标改写。

验证入口：

```sh
xcodebuild -project CatfolioIOS/CatfolioIOS.xcodeproj -scheme CatfolioIOS \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test -only-testing:CatfolioIOSTests/ValuationQualityTests \
  -only-testing:CatfolioIOSTests/JEVTodayAttentionTests CODE_SIGNING_ALLOWED=NO
```

计算用例覆盖税率、资本、债务缺失与显式零、负值、EPS 拆股比较数、申报/币种/期间隔离、旧缓存兼容、图表负值和极端值；包含 AAPL 2025 年报 accession `0000320193-25-000079` 的真实摘录与手算核对。JEV 测试保护现有 P/E 结果。

开发界面预览：Debug 启动参数 `--preview-valuation-map`，可加 `--valuation-2d`、`--valuation-expanded`、`--valuation-dark`、`--valuation-select=MISSING`。预览明确标注示例数据，不进入组合数据链路，Release 不可用。

本次验证结果：iOS Simulator Debug 构建成功，14 个 ValuationQualityTests 与 18 个 JEVTodayAttentionTests 全部通过（32/32）。中英文 strings 文件校验、git diff 空白检查通过。已在 iPhone 17 Pro / iOS 26.5 模拟器检查浅色 3D、深色全屏 3D、深色 2D 和缺失指标状态；截图为明确标识的示例数据。真机手势手感和持仓全量数据覆盖尚未验收。
