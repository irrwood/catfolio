# iOS SnapTrade

## 使用

设置 → 新建账户 → **SnapTrade**：

1. 在 [SnapTrade Dashboard](https://dashboard.snaptrade.com) 开启双重验证，创建 **Personal API Key**。
2. 填入 Client ID、Consumer Key，可先保存凭证。
3. 选择「连接或重新授权券商」，在 SnapTrade 页面完成授权，关闭网页回到 App。已经连接的券商可跳过此步。
4. 读取账户列表，选择一个账户，预览持仓，确认创建。多个账户分别添加。
5. 后续在账户详情 → SnapTrade 同步中读取并确认更新。这里的重新授权针对当前账户所属的连接。

账户凭证以一个 JSON 条目保存在 iPhone Keychain，使用 `WhenUnlockedThisDeviceOnly`。新账户未确认前可以保存草稿凭证；账户创建后凭证按 SnapTrade account UUID 保存。移除本机凭证不撤销 SnapTrade 端授权；授权在 Dashboard 管理。

本实现用于设备所有者自己的个人 API Key，不包含 Commercial consumer key、用户注册、商业应用 OAuth 配置或服务端。所有请求直达 SnapTrade，连接权限明确为 `read`，没有下单调用。

## 数据范围

- 读取 `/accounts`、指定账户详情、连接状态和 `/accounts/{id}/positions/all`。
- 导入有完整数量、成本、价格及币种的多头股票、ADR、ETF、封闭式基金和共同基金。当前证券映射覆盖已识别的美股交易所、伦敦、多伦多、TSX Venture、香港；未识别市场拒绝本次导入。共同基金等仍须具有可识别的上市市场和原始代码。
- 不导入现金余额、交易流水、期权、债券、期货、CFD 或空头。若非零持仓含不支持项或缺失数据，整个账户不更新，避免无提示丢失仓位。
- 不把当前持仓伪造成 BUY 交易，不推定开户日为建仓日。没有历史成交支撑的 FX 影响明确不可算。现有财务计算保持原样。
- 保存 SnapTrade 的 `data_freshness.as_of` 作为报价观察时间。Daily 计划可能返回缓存数据，界面展示数据时间；不发起可能收费的强制刷新。
- 每次确认只替换一个 `SnapTrade|account UUID` 账户的持仓，其他账户与已有交易历史保留；15 分钟后预览失效。新建路径拒绝已存在的 SnapTrade UUID；管理路径拒绝其他 UUID。
- 首次同步未完成、`holdings_unavailable`、连接失效、网络失败、非法/缺失响应均不能清仓。已验证的空账户仍须用户确认后才能清空其旧持仓。
- SnapTrade 删除连接后重连可能产生新的 UUID；跨券商直连渠道和新旧 UUID 不自动识别为同一账户，添加前需自行避免重复计入。

## 实现与验证

- `SnapTradeClient.swift`：Personal 签名、固定 HTTPS API、临时网络会话、禁止 HTTP 重定向、错误脱敏、响应校验与标准化。
- `SnapTradeView.swift`：现有 Settings 组件、Safari 授权、账户选择、不可变预览与确认。
- `AppModel.importSnapTrade`：现有 `LocalPortfolioStore.replace` 的单账户替换路径。
- `SnapTradeTests`：独立 HMAC 向量、分数股、数值/字符串字段、空仓和缺数保护、市场代码、账户身份、过期、网络错误、授权 URL、账户及历史保留。

真实账户授权和读取仍需用户自己的 Personal API Key；本次开发使用合成数据与模拟网络。

## 官方接口依据

- [Getting Started](https://docs.snaptrade.com/docs/getting-started)
- [Request Signatures](https://docs.snaptrade.com/docs/request-signatures)
- [List Accounts](https://docs.snaptrade.com/reference/Account%20Information/AccountInformation_listUserAccounts)
- [List All Account Positions](https://docs.snaptrade.com/reference/Account%20Information/AccountInformation_getAllAccountPositions)

### 本次验证结果

- iOS Simulator 编译成功；`SnapTradeTests`、`BrokerResultPreservationTests`、`PortfolioAccountAggregationTests`、`LocalizationTests` 共 39 项通过。补充币种与重新授权处理后，10 项 SnapTrade 测试再次通过。
- 双语资源检查通过，账户昵称回归脚本通过；旧券商空仓同步的 Python 执行测试通过。
- 英文、中文配置页使用独立模拟器检查，未使用真实账户或凭证。
- `test_ios_account_settings.py` 有 17 项已有静态断言失败（仍断言旧 Form、未本地化字符串及旧方法名称）。在临时副本中移除本次 SnapTrade 改动后失败集合完全一致；本次没有修改这些既有测试或相关旧界面。
