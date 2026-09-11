# iOS 盈利历史

股票详情页的盈利历史组件对应 Figma `234:36693`，以 SwiftUI 实现。每股收益和收入分别展示预估空心点、实际实心点和差值连线，支持手动刷新。绿色代表超预期，红色代表低于预期，灰色代表持平或没有可比较的预估。

## 独立联网

- iOS 直接使用已有 Keychain 中的 FMP 配置访问 `https://financialmodelingprep.com/stable/earnings?symbol=...`，复用 `StockScreenDataClient` 和全局 FMP 限流器。密钥不写入代码、缓存或诊断输出。
- FMP 无密钥、无覆盖或请求失败时，直接尝试 `https://api.nasdaq.com/api/company/{symbol}/earnings-surprise`。该接口当前提供最近四期 EPS 实际值与预估，无收入对比；无收入数据时显示简短空状态。
- 不访问本机 Core HTTP 服务，不读取 T7，不将本地原始包打包进 App，不依赖 Mac 常驻。
- 快照写入设备 Application Support/EarningsHistory，24 小时内复用；过期重读。刷新失败保留原快照，不将完整 FMP 缓存静默替换成较短的 Nasdaq 历史。

## 口径

两种来源不拼接同一条历史，避免供应商 EPS 定义差异。横轴使用 Q2’25 格式，每列数据点对应一个刻度；记录较多时点列与刻度一起横向滚动：优先从 Nasdaq fiscalQtrEnd 得到报告期所在自然季度；没有报告期时使用公布日期所在自然季度。图下不再展示点选详情、来源、更新时间、接口权限说明或操作提示。源接口不提供报告币种时不假定为持仓报价币种、不换汇。未来预估、缺失数据保留可选值；零、负数与缺失区分。最多展示最近 16 个有当前指标的记录。

## 验证

`EarningsHistoryTests` 覆盖数字解析（含零、负数、布尔、NaN/Infinity）、证券匹配、重复版本、非法日期、只有预估的记录、Nasdaq 响应和设备磁盘缓存。图表渲染测试使用明确标注的 TEST FIXTURE；不把测试值作为行情。

可选在线验证设置 `TEST_RUNNER_CATFOLIO_LIVE_EARNINGS=1` 后运行该测试类，在模拟器进程中通过 URLSession 请求 Nasdaq。FMP 的收入在线覆盖需要设备密钥具备 earnings 接口权限；本地数据包有字段并不证明该权限。
