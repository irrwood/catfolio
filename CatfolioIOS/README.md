# Catfolio iOS

原生 SwiftUI 客户端，复用 `v3_backend` 的现有 API，不修改任何金融计算。

## 页面

- 持仓：成本与市值对比、持仓明细
- 成交量：点按持仓后打开原生 Sheet，拖动价格图查看 VAH、POC、VAL、成本与现价
- ETF 穿透：按成本或市值展开 ETF 底层股票，并合并直接与间接暴露
- 收益：组合与 SPY、QQQ、VTI、GLD 对比
- AI：组合简报与问答
- 设置：服务地址、连接测试和服务端设置入口

## 券商 API

- 支持在 iOS 设置中读取和切换 Trading 212、Moomoo、Interactive Brokers 数据源。
- 支持分别测试 Moomoo OpenD 与 IBKR Client Portal Gateway 连接。
- 支持从当前券商主动同步；成功后自动刷新 iOS 持仓。
- 券商连接始终发生在 Catfolio 服务端，iPhone 不保存券商密钥，也不直接连接本机 Gateway。

## 运行

1. 启动后端：`cd v3_backend && .venv/bin/uvicorn app.main:app --reload`
2. 用 Xcode 26 打开 `CatfolioIOS.xcodeproj`。
3. iOS 模拟器默认使用 `http://127.0.0.1:8000`。真机请在设置中改为 Mac 的局域网地址。

应用最低支持 iOS 18。iOS 26 上使用原生 Liquid Glass；旧系统使用系统材质回退。
