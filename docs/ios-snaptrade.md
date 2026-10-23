# iOS SnapTrade

## 使用

设置 → 新建账户 → **SnapTrade**：

1. 在 [SnapTrade Dashboard](https://dashboard.snaptrade.com) 开启双重验证，创建 **Personal API Key**。
2. 填入 Client ID、Consumer Key，可先保存凭证。
3. 点击「读取账户列表」，直接通过 Personal API Key 读取已关联账户，不打开登录或授权网页。
4. 选择一个账户，预览持仓和交易记录数量，确认创建。多个账户分别添加。若该 Key 下尚无账户，先在 SnapTrade Dashboard 关联券商，再回来读取。
5. 后续在账户详情 → SnapTrade 同步中读取并确认更新；失效连接在 Dashboard 重新授权。

账户凭证以一个 JSON 条目保存在 iPhone Keychain，使用 `WhenUnlockedThisDeviceOnly`。新账户未确认前可以保存草稿凭证；账户创建后凭证按 SnapTrade account UUID 保存。移除本机凭证不撤销 SnapTrade 端授权；授权在 Dashboard 管理。

本实现用于设备所有者自己的个人 API Key，不包含 Commercial consumer key、用户注册、商业应用 OAuth 配置或服务端。所有请求直达 SnapTrade；账户流程只读取数据，没有下单调用。

## 已有账户同步时认证失败

已添加账户表示本机保存过账户及持仓，不代表当前凭证或每个数据接口仍然可用。同步依次读取账户详情、连接状态、持仓和交易历史；其中任何一步收到 HTTP 401/403，都不会提交本次更新。

错误提示现在区分失败步骤及 HTTP 状态，并在响应包含合法的四位数字错误码时展示该码。401 提示检查已保存的个人 API 凭证和设备时间；403 提示检查凭证有效性和该项数据的访问权限。这些提示不能单独证明具体根因，仍须结合失败步骤及服务端错误码判断。不会展示原始响应文字、签名 URL、密钥或账户号码。

`401 / 1076` 在官方 API 定义中表示无法验证请求签名，此时提示明确显示「请求签名校验失败」。交易历史优先请求 canonical 根路径；仅该请求返回此错误时，使用与账户/持仓读取相同的 `/api/v1` 兼容路径重新签名并重试一次。成功后本次剩余分页固定使用同一路径；其他认证错误、权限错误、限流或网络失败不触发兼容重试，两种路径均失败时不提供可提交的预览。

请求查询字符串采用与官方 TypeScript SDK `URLSearchParams` 相同的编码，例如 `BUY,SELL` 编码为 `BUY%2CSELL`，字面量 `+` 编码为 `%2B`，空格为 `+`。用于 HMAC 的路径和查询字符串始终与实际请求完全一致；对根路径和兼容路径分别使用独立 Node.js/Python HMAC 向量验证。

1076 兼容修复已通过 Simulator 构建与 33 项 SnapTrade 回归：20 项交易历史/认证测试和 13 项原有 SnapTrade 测试。覆盖单次兼容重试、后续分页沿用成功路径、两条路径均拒绝时终止，以及其他认证/权限/限流错误不重试；真实账户是否恢复仍需更新版本后确认。

诊断改动已通过 Simulator 构建与 28 项 SnapTrade 逻辑回归，覆盖四个同步步骤各自返回 401/403 的情况、账户列表错误定位和响应脱敏；真实账户拒绝原因仍须依据实际返回的步骤与错误码确认。

## 数据范围

- 读取 `/accounts`、指定账户详情、连接状态、`/accounts/{id}/positions/all` 和 `/accounts/{id}/activities`。新增交易历史请求优先使用官方 canonical 根路径，遇到明确的 `401 / 1076` 时允许一次现有 `/api/v1` 路径兼容重试；原有账户/持仓请求保持兼容路径。分页及过滤参数均参与签名。
- 导入有完整数量、成本、价格及币种的多头股票、ADR、ETF、封闭式基金和共同基金。当前证券映射覆盖已识别的美股交易所、伦敦、多伦多、TSX Venture、香港；未识别市场拒绝本次导入。共同基金等仍须具有可识别的上市市场和原始代码。
- 不导入现金余额、现金流水、期权、债券、期货、CFD 或空头持仓。若非零持仓含不支持项或缺失数据，整个账户不更新，避免无提示丢失仓位。
- 交易历史按 `type=BUY,SELL` 请求，每页最多 1000 条，依据返回的 offset/limit/total 读取全部可用页。数量支持分数股和数值字符串；SELL 的负数量标准化为正数量，方向单独保存。使用实际 `price`、交易币种和 `trade_date`，不使用结算日、不从金额反推成交价。与持仓共享交易所代码映射，保留已清仓证券的历史。
- 每笔成交以 `SnapTrade|account UUID|activity ID` 合并入现有 `LocalTransactionRecord` 账本。相同 ID 重复同步不会新增，其他账户、手工记录和本次响应未包含的旧成交保留；现有图表买卖点、交易读数及交易明细直接消费此账本。
- 期权、非股票/基金证券、未知市场或无法映射的买卖记录跳过并在预览提示；股息、费用、出入金等不作为买卖点。受支持股票成交若缺少数量、成交价、币种或有效交易日期，整次读取失败；分页失败、重复 ID、变化的总数或首次交易同步未完成也不能生成可确认的预览。
- 保留有实际时间的成交时间；仅日期或午夜占位时间不生成分时买卖点。不推算佣金后的现金流水、券商已实现盈亏或账户汇率。SnapTrade 的 `fx_rate` 是成交换汇信息，不冒充账本的账户本位币汇率。
- 不把当前持仓伪造成 BUY 交易，不推定开户日为建仓日。没有历史成交支撑的 FX 影响明确不可算。现有财务计算保持原样。
- 保存 SnapTrade 的 `data_freshness.as_of` 作为报价观察时间。Daily 计划可能返回缓存数据，界面展示数据时间；不发起可能收费的强制刷新。
- 每次确认只替换一个 `SnapTrade|account UUID` 账户的持仓并合并该账户的历史交易，其他账户与已有交易历史保留；15 分钟后预览失效。新建路径拒绝已存在的 SnapTrade UUID；管理路径拒绝其他 UUID。
- 历史范围由券商决定，可能不覆盖开户以来的全部成交；交易数据通常每日刷新，本实现不调用收费的强制刷新接口。SnapTrade 提醒 activity ID 在罕见的删除并重建数据后可能变化，跨此类重建不保证自动去重。
- 首次同步未完成、`holdings_unavailable`、连接失效、网络失败、非法/缺失响应均不能清仓。已验证的空账户仍须用户确认后才能清空其旧持仓。
- SnapTrade 删除连接后重连可能产生新的 UUID；跨券商直连渠道和新旧 UUID 不自动识别为同一账户，添加前需自行避免重复计入。

## 实现与验证

- `SnapTradeClient.swift`：Personal 签名、固定 HTTPS API、临时网络会话、禁止 HTTP 重定向、错误脱敏、响应校验与标准化。
- `SnapTradeActivities.swift`：交易活动解码、证券映射与交易账本标准化。
- `SnapTradeView.swift`：现有 Settings 组件、凭证直读账户、账户选择、不可变预览与确认。
- `AppModel.importSnapTrade`：现有 `LocalPortfolioStore.replace` 的单账户替换及交易历史合并路径。
- `SnapTradeTests`：独立 HMAC 向量、分数股、数值/字符串字段、空仓和缺数保护、市场代码、账户身份、过期、网络错误、授权 URL、账户及历史保留。
- `SnapTradeActivityTests`、`SnapTradeActivityPresentationTests`：分页签名、多页及异常响应、交易字段、日期/分时时间、市场映射、非股票过滤、重复同步及持久化、图表买卖点和账户过滤。

真实账户授权和读取仍需用户自己的 Personal API Key；本次开发使用合成数据与模拟网络。

### 交易历史接入验证（2026-10-21）

- Simulator 构建成功；选定 Logic 回归 35 项通过，包含 12 项新增交易历史测试。
- 选定 Views 回归 9 项中 8 项首轮通过，包含新增的账本到图表买卖点测试和 3 项图表缓存回归；通用输入框焦点测试首轮失败，单独复跑通过。
- 全仓设计检查仍有其他文件的既有颜色字面量违规；本地化检查仍受 `ScreenshotImportView.swift` 的「股票代码」缺少翻译键阻塞。本次新增 SnapTrade 文案均提供中英文。

## 官方接口依据

- [Getting Started](https://docs.snaptrade.com/docs/getting-started)
- [Request Signatures](https://docs.snaptrade.com/docs/request-signatures)
- [官方 SDK 查询参数编码](https://github.com/passiv/snaptrade-sdks/blob/master/sdks/typescript/common.ts)
- [官方 API 的 401 / 1076 定义](https://github.com/passiv/snaptrade-sdks/blob/master/api.yaml)
- [List Accounts](https://docs.snaptrade.com/reference/Account%20Information/AccountInformation_listUserAccounts)
- [List All Account Positions](https://docs.snaptrade.com/reference/Account%20Information/AccountInformation_getAllAccountPositions)
- [List account activities](https://docs.snaptrade.com/reference/Account%20Information/AccountInformation_getAccountActivities)

### 早期接入验证结果

- iOS Simulator 编译成功；`SnapTradeTests`、`BrokerResultPreservationTests`、`PortfolioAccountAggregationTests`、`LocalizationTests` 共 39 项通过。补充币种与重新授权处理后，10 项 SnapTrade 测试再次通过。
- 双语资源检查通过，账户昵称回归脚本通过；旧券商空仓同步的 Python 执行测试通过。
- 英文、中文配置页使用独立模拟器检查，未使用真实账户或凭证。
- `test_ios_account_settings.py` 有 17 项已有静态断言失败（仍断言旧 Form、未本地化字符串及旧方法名称）。在临时副本中移除本次 SnapTrade 改动后失败集合完全一致；本次没有修改这些既有测试或相关旧界面。
