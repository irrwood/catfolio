# Catfolio iOS

独立运行的原生 SwiftUI 投资组合客户端。组合数据保存在 iPhone 本地，不需要 Mac、OpenD、Gateway 或 Catfolio 服务端常开。

## 页面

- 持仓：成本与市值对比、持仓明细
- 成交量：点按持仓后打开原生 Sheet，拖动价格图查看 VAH、POC、VAL、成本与现价
- ETF 穿透：按成本或市值展开 ETF 底层股票，并合并直接与间接暴露
- 收益：组合与 SPY、QQQ、VTI、GLD 对比
- AI：组合简报与问答
- 设置：券商直连、本机行情与 AI Key
- CSV 导入：从“文件”选择交易记录，在 iPhone 内解析并保存

## 券商 API

- 支持 iPhone 直连 Trading 212 正式或模拟环境，可合并两个账户；API Key 与 Secret 仅保存在设备 Keychain。
- 支持 iPhone 通过 OAuth 2.1 + PKCE 直连新版 Moomoo REST OpenAPI，无需 OpenD 或 API Key；自动读取全部授权账户。
- Moomoo OAuth 使用官方支持的 `http://localhost:60355/callback` 本机回调；授权时只需授予账户持仓读取所需的 `trade:read` 权限。
- 支持 iPhone 直连 IBKR Flex Web Service；Token 与 Query ID 仅保存在设备 Keychain，不需要 Gateway。

## 本机数据与第三方服务

- 持仓账本写入 App 的 Application Support，使用 iOS 文件保护；每天同步时保留一份市值/成本快照。
- CSV 不上传，导入会替换手机上的当前持仓。
- ETF 穿透使用 App 内置的 Vanguard 官方 S&P 500 持仓快照。
- 成交量与基准对比可选直连 Financial Modeling Prep；API Key 保存在 Keychain。
- AI 可选直连 DeepSeek；只发送组合摘要与用户问题，API Key 保存在 Keychain。

## 运行

1. 用 Xcode 26 打开 `CatfolioIOS.xcodeproj`。
2. 选择模拟器或已签名的 iPhone 后直接运行。
3. 在 App 的“设置”中直连券商或导入 CSV；不需要先启动后端。

应用最低支持 iOS 18。iOS 26 上使用原生 Liquid Glass；旧系统使用系统材质回退。
