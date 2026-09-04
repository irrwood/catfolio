# Catfolio iOS

独立运行的原生 SwiftUI 投资组合客户端。组合数据保存在 iPhone 本地，不需要 Mac、OpenD、Gateway 或 Catfolio 服务端常开。

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
- AI 可选直连 DeepSeek；只发送组合摘要与当前问题，API Key 保存在 Keychain。问答历史使用 iOS 文件保护保存在本机，并排除 iCloud 备份。

## 运行

1. 用 Xcode 26 打开 `CatfolioIOS.xcodeproj`。
2. 选择模拟器或已签名的 iPhone 后直接运行。
3. 在 App 的“设置”中直连券商或导入 CSV；不需要先启动后端。

应用最低支持 iOS 18。iOS 26 上使用原生 Liquid Glass；旧系统使用系统材质回退。

## 本地资源

ETF 穿透所需的静态持仓快照位于 `CatfolioIOS/Resources/ETF/`，由 iOS 工程直接打包读取。构建和运行不依赖仓库中的 Web/FastAPI 目录。
