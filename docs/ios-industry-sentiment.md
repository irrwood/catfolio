# iOS 行业情绪

入口：收益表现 → 行情与 AI → 行业情绪。

原生 SwiftUI 页面：分段仪表盘、Core 评分、市场状态、六项指标、VXSMH/MA20趋势与SMH成交量。趋势复用 `StandardLineChart`，包含统一坐标、网格、端点、长按查看和区间切换；MA20用虚线。组合卡片只在当前账户有已识别半导体持仓且行业快照未过期时显示，使用本机当前持仓美元绝对市值口径；演示模式显式标记。

评分、MA、Z、分位数、Regime全部来自Core导出，不在Swift重算。半导体识别清单也由Core发布。iOS仅做展示范围裁剪、图表坐标范围和当前持仓暴露比例。

```sh
./core/dev collect-volatility
./core/dev export-volatility-ios
```

导出精简市场快照到 `CatfolioIOS/CatfolioIOS/Resources/industry_sentiment.json`，不含账户数据。构建随App携带快照。真机无需依赖Mac的localhost，离线可查看；右上角导入按钮接受同结构JSON，校验后保存到App本地。不会导入比现有快照旧的日期，格式错误保持原快照。

当前没有公网实时更新服务，也不把构建时快照称为实时行情。日期始终可见，超过4个自然日标记过期；日常自动采集仍更新T7源数据，手机更新需重新导出并导入，或以后接通托管快照服务。

验证：Core 10项测试、原生JSON解码/设置与统一图表接线测试、iOS Simulator Debug编译。未修改现有账户、收益计算及图表公共组件。
