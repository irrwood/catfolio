# iOS 沪深行情：Longbridge 与 AKShare 来源

入口：**设置 → 服务商 → A 股行情**。iPhone 直接联网，不需要 Python、OpenD 或 Catfolio 后端。

- **自动**（默认）：有完整长桥凭据时先使用长桥，失败后访问公开源；未配置长桥时直接使用公开源。
- **Longbridge**：只使用长桥，凭据或权限错误会显示失败，不静默换源。
- **AKShare 来源**：Swift 直连腾讯行情，东方财富提供备用行情与搜索目录。两者都是 AKShare 使用的公开来源。手机不运行 Python，也不依赖托管的“AKShare API”服务。

长桥需要用户自己的 App Key、App Secret、Access Token，保存在设备本地 Keychain 的单条记录中，目前不加入 iCloud 密钥同步。设置页提供独立的保存、验证、删除操作；验证请求 `600519.SH` 报价，不导入账户、不下单。OpenAPI 权限独立于长桥 App 行情权限。官方定价页说明，中国大陆以外 IP 的 A 股行情延迟 15 分钟。

## 接入范围

首版支持上海、深圳的股票及场内 ETF；北交所、指数、债券不在本适配器范围内。支持中文或代码搜索、当前报价、今日涨跌、历史日线、分时、成交量分析及现有持仓报价更新。财报、公告、券商账户同步仍由各自模块负责。

搜索目录使用公开源，并保留现有离线目录。查询普通美股代码不会增加国内搜索请求。`600519.SH` / `600519.SS` / `SH.600519` 统一到同一个上海上市标的，`000001.SZ` 不会与上证指数 `000001.SH` 混合。裸六位代码只有在已知人民币报价上下文中才推断沪深上市地点。搜索结果保留 CNY、交易所和 ETF 类型。

持仓刷新使用原始报价与供应商观察时间，网络失败不会把缓存日线伪装为新报价。走势使用前复权日线，估值请求与成交量价格使用未复权数据。东方财富成交量的“手”乘以 100 转为股；腾讯科创板已经以股计，主板、创业板和 ETF 以手计；长桥保持股数。供应商与复权方式分别缓存；前复权历史整段替换，不把不同复权基准的尾部拼接到旧数据上。

公开行情优先访问腾讯 JSON 接口；历史使用 AKShare 当前采用的 `proxy.finance.qq.com/ifzqgtimg/appstock/app/newfqkline/get`，报价和分时使用 `web.ifzq.gtimg.cn/appstock/app/minute/query`。连接失败时整次操作回退东方财富，不把两家的历史拼接在一起。HTTP 401、403、429、腾讯 HTML 访问拦截页和用户取消不会触发换源；502、503、504 最多重试一次。东方财富报价网关失败时，仍可尝试其最新一分钟数据，保留原始观察时间。

腾讯日线每次最多 640 条，按日期向前翻页。现金分红的前复权算法可能使很早的历史价格成为非正数，本应用的价格/收益模型不接受这些点；只显示正数的可用区间，不截成零、不以未复权值替换。分时仅保留沪深正常交易时段，排除午休和 15:00 后的固定价格交易点。腾讯报价快照保留供应商的更新时间，分时图保留每根柱的上海时间。

个股页显示分时行情来源、观察时间和缓存标记。未持有的 A 股搜索详情也会发布涨跌幅到页面模型，不创建持仓、不改变账户总值。A 股交易日期采用 Asia/Shanghai，开市徽标处理工作日与午休；与当前其他市场的徽标一样，尚未集成交易所节假日日历，不用于判断订单可交易性。

切换数据源后，详情页按当前来源重新加载，页面内存缓存也按来源隔离。保存或删除长桥凭据会更新配置版本；长桥磁盘缓存另按凭据摘要隔离，避免切换账户后复用前一个账户的历史。正在返回的旧配置请求不能覆盖当前页面或涨跌幅。

一张 A 股图表的日线与分时固定来自同一个数据源，来源信息随数据一起返回。自动模式在日线失败时整张图回退；只有分时失败时保留同源日线。若网络失败后使用已有历史，页面保留缓存标记。详情页的涨跌幅使用当前图表的数据；切换到可能延迟的长桥数据时，不会因为时间早于公开源而继续显示旧来源涨跌幅。

## 协议与验证

长桥采用官方签名算法获取一次性 socket token，以 WebSocket + Protobuf 请求行情。只实现报价、分时和历史 K 线命令，串行限速，设置请求期限并在取消或超时时关闭连接。支持 gzip 响应。历史日线按 1,000 条向前翻页。

- [长桥行情协议](https://open.longbridge.com/docs/quote/overview)
- [长桥权限及地区延迟](https://open.longbridge.com/zh-CN/pricing)
- [官方 Protobuf 定义](https://github.com/longbridge/openapi-protobufs/blob/main/quote/api.proto)
- [官方签名实现](https://github.com/longbridge/openapi/blob/master/rust/crates/httpclient/src/signature.rs)
- [AKShare 日线和分时实现](https://github.com/akfamily/akshare/blob/main/akshare/stock_feature/stock_hist_em.py)
- [AKShare 腾讯历史行情实现](https://github.com/akfamily/akshare/blob/main/akshare/stock_feature/stock_hist_tx.py)

`ChinaMarketDataTests`、`LongbridgeMarketDataTests` 覆盖身份、时间、单位、签名、消息解码、回退、取消与缓存隔离。`ChinaMarketViewTests` 覆盖凭据保存/验证状态、交易时段和设置页渲染。`ChinaMarketLiveTests` 为可选的公开源联网验收：

```sh
TEST_RUNNER_CATFOLIO_RESEARCH_TEST_HOST=1 TEST_RUNNER_CATFOLIO_TEST_CN_LIVE=1 xcodebuild test \
  -project CatfolioIOS/CatfolioIOS.xcodeproj -scheme CatfolioIOS \
  -testPlan Logic -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:CatfolioIOSTests/ChinaMarketLiveTests
```

`CATFOLIO_RESEARCH_TEST_HOST` 使用隔离的 App 测试入口，避免验收行情时触发账户刷新或云同步。真机测试可将 destination 换为 `platform=iOS,id=<设备 ID>`；图表截图要求设备解锁且测试 App 在前台。

没有真实长桥凭据时，协议测试不能代替账户权限与生产网关联调；在设置页填入凭据后使用“测试连接”完成账户验证。

`ChinaMarketSwitchingTests` 使用隔离缓存和固定响应验证 Longbridge → AKShare → Longbridge、账户缓存隔离、整图回退及旧请求发布保护。`ChinaMarketViewTests` 另验证详情页内存缓存的来源与凭据版本隔离。

真实长桥验收只从测试设备的 Keychain 读取用户已保存的凭据，不通过命令行传入凭据，也不把凭据写入日志：

```sh
TEST_RUNNER_CATFOLIO_RESEARCH_TEST_HOST=1 TEST_RUNNER_CATFOLIO_TEST_LONGBRIDGE_LIVE=1 xcodebuild test \
  -project CatfolioIOS/CatfolioIOS.xcodeproj -scheme CatfolioIOS \
  -testPlan Logic -destination 'platform=iOS,id=<设备 ID>' \
  -parallel-testing-enabled NO -only-testing:CatfolioIOSTests/LongbridgeLiveTests
```

联网切换与图表验收使用 `TEST_RUNNER_CATFOLIO_TEST_CN_SWITCHING=1`，选择 `Views` 计划和 `-only-testing:CatfolioIOSViewTests/ChinaMarketLiveViewTests/testLiveLongbridgeAKShareAndSwitchBack`。它依次切换 Longbridge → AKShare → Longbridge，每轮检查三只沪深标的的真实历史、分时、来源、涨跌幅及图表截图；缺少设备凭据会明确失败，不用固定响应冒充实连成功。

`TencentMarketDataTests` 验证上游断连回退、取消与限流不换源、640 条分页、上海时间和各板块成交量单位。`ChinaMarketLiveViewTests` 使用真实联网数据经过 `LocalMarketDataClient.securityPriceHistory`，渲染实际个股价格组件并检查图表像素、保存截图；可用同一环境变量在 `Views` 计划中运行。

### 本次验证记录（2026-10-20）

- 修复了东方财富行情端点直接断连，以及腾讯旧历史端点返回 HTML 拦截页导致的失败；默认改用腾讯报价/分时与 AKShare 当前的腾讯历史端点。
- 已连接的 **iPhone 17 Pro（iOS 27.2）** 构建、安装与测试通过。`Logic` 计划的相关 **32 项**测试通过：`ChinaMarketDataTests` 11 项、`TencentMarketDataTests` 8 项、`ChinaMarketLiveTests` 1 项、`LongbridgeMarketDataTests` 5 项、`DetailMarketSyncTests` 7 项。
- `Views` 计划的相关 **4 项**测试通过：设置/交易时段 3 项，实际联网图表验收 1 项。已人工核对三张真机行情截图，以及中文浅色、英文深色大字号设置页截图。
- 真机联网验收覆盖 **600519.SH（贵州茅台）、000001.SZ（平安银行）、510300.SH（沪深 300 ETF）**：搜索、报价、未复权日线、分时；图表验收另外经过实际 App 历史加载与发布路径，检查超过 640 条的完整历史、来源/缓存状态、涨跌幅与实际曲线像素。
- 同一 Swift 客户端在 macOS 额外验证完整前复权历史：三个标的分别返回 2,492、5,139、3,497 个有效日线点，每个标的 242 个正常交易时段分时点。早期非正前复权价格按上述规则排除。
- 测试结果：`/tmp/china-iphone-logic-final.xcresult`、`/tmp/china-iphone-views-verified.xcresult`；真机截图位于 `/tmp/china-iphone-verified-images/`。
- 长桥真实账户权限验证仍需用户凭据，本轮完成了协议回归。全库设计检查仍报告既有颜色字面量问题；本次 A 股接入与切换修改没有新增颜色字面量。

### 双源切换回归（同日后续）

- 修复详情页复用旧来源缓存、并行请求来源归属混淆，以及切换后旧请求仍更新涨跌幅的问题；长桥缓存增加凭据隔离。
- iPhone 17 Pro 上相关 `Logic` **29 项**测试通过：`ChinaMarketDataTests` 11 项、`ChinaMarketSwitchingTests` 5 项、`ChinaMarketLiveTests` 1 项、`LongbridgeMarketDataTests` 5 项、`DetailMarketSyncTests` 7 项。结果位于 `/tmp/china-switching-logic.xcresult`。
- 生产长桥探测 `/tmp/longbridge-iphone-probe.xcresult` 在读取设备凭据时明确失败：设备尚未保存完整凭据，未进入长桥网络请求。双源生产联网验收尚未完成。
- `Views` 首次启动被自动锁屏阻断，重新启动后 **5 项通过**：页面缓存、凭据状态、交易时段、双语设置渲染 4 项，以及三只标的真实 AKShare 行情图表验收 1 项。结果 `/tmp/china-switching-views-retry.xcresult`，截图 `/tmp/china-switching-images/`；已人工核对三张行情图及两张设置页截图。设置页确认三项长桥凭据仍为空。
- 本轮合计 **34 项真机测试通过**，其中固定响应的长桥切换测试不代表长桥生产联网通过。长桥联网及 Longbridge → AKShare → Longbridge 的真实图表切换验收仍待设备保存凭据后执行。
