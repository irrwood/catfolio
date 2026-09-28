# Robinhood MCP 接入调查

核实日期：2026-09-28。已实现 iOS 实验性本地连接；未完成真实账号端到端联调，不代表已上线或已验证全部数据格式。

## 官方服务与授权

- MCP：`https://agent.robinhood.com/mcp/trading`，Streamable HTTP。
- 实测未授权 `initialize` 返回 HTTP 401，并通过 `WWW-Authenticate` 指向受保护资源元数据。
- 资源元数据：`https://agent.robinhood.com/.well-known/oauth-protected-resource/mcp/trading`。
- 授权元数据：`https://agent.robinhood.com/.well-known/oauth-authorization-server`。
- 元数据公布 authorization code、refresh token、PKCE S256、public client（token endpoint auth method `none`），以及动态客户端注册端点。
- 公布的 scope 仅有 `internal`；不能将其描述为 Robinhood 端强制的只读权限。Catfolio 必须通过自身工具白名单限制为数据读取。
- 官方当前要求在桌面设备完成认证和 Agentic 账户开户；不能承诺 iPhone 内一键完成授权。

来源：[Agentic Trading overview](https://robinhood.com/us/en/support/articles/agentic-trading-overview/)。授权元数据已通过无凭证 HTTP GET 核实；另已验证动态注册端点接受 `http://localhost:60356/callback`；未登录或读取用户账户。

## 能力与读取边界

| 需求 | 官方工具 | 接入约束 |
| --- | --- | --- |
| 实时股票报价 | `get_equity_quotes` | 每次最多 20 个代码；保留上游报价时间和币种 |
| Level 2 | `get_equity_price_book` | 每次最多 4 个代码；失败或无权限不能以普通报价冒充盘口 |
| 期权 | `get_option_chains`, `get_option_instruments`, `get_option_quotes`, `get_option_positions` | 合约身份独立于股票代码；不能套用股票数量和成本模型 |
| 账户与组合 | `get_accounts`, `get_portfolio`, `get_equity_positions` | 按用户与券商账户隔离；组合快照不是完整交易账本 |
| 后续减少历史数据请求 | `get_equity_historicals` | 接入前核实时间范围、复权、币种、时区和分页契约 |

来源：[Trading with your agent](https://robinhood.com/us/en/support/articles/trading-with-your-agent/)。此表仅列官方说明中的能力；正式实现须在授权后通过 `tools/list` 取得 input schema，并保存脱敏响应 fixture 验证解码。未验证的工具参数和响应字段不能作为已知契约。

不暴露下单、撤单、订单模拟、watchlist 写入等工具；不提供可调用任意工具的透传入口。

## 与当前 Catfolio 的关系

`CatfolioIOS/README.md` 定义 iOS 独立运行，不要求 Catfolio 服务端常开。新增后端托管授权会改变这一产品约束，需明确选择。

`LocalMarketDataClient.latestQuotes` 当前从价格 bars 获取持仓报价，保留真实观察时间；FMP 主要用于历史行情备用。`CompanyFinancials` 的 FMP 使用包括 SEC 缺失报表补充。只接入实时股票报价，不会消除这些财务和历史请求。

实现时建议：

1. 只在用户已连接时，优先从 Robinhood 批量取得受支持证券的报价。
2. 按代码单独回退：仅对缺失、过期、不支持或无权限的标的调用现有行情链路。
3. 保留行情时间、来源、市场时段和币种；不能用请求完成时间把旧价标记成实时价。
4. 连接、令牌和缓存按用户隔离；单个用户授权的行情不得写入共享行情缓存或服务其他用户。
5. 限流时遵循 `Retry-After`，合并并发刷新；断开连接清理令牌和关联缓存，并丢弃断开前尚未完成的请求结果。
6. 财务数据继续走现有路径；Robinhood 历史数据和财务数据须分别验证字段覆盖、复权和时间口径后再替换。

## 当前交付与待验证范围

- 用户已选 iOS；入口：设置 → 新建账户 → Robinhood。
- 授权方式：设备创建 PKCE 请求 → 分享登录链接到桌面 → 用户授权后复制 localhost 回调 URL → 粘贴回 iOS。App 校验回调地址、state 和 30 分钟有效期，在本机换取令牌。桌面 localhost 不连接 iPhone，采用手动交接；该完整流程尚待真实账号验证。
- 客户端支持 MCP JSON/SSE 解析、工具发现、读取白名单、刷新令牌及限流回退。凭证在 Keychain，数据查询视图仅在内存中保留。
- 股票报价按最多 20 个代码批量读取，只有明确 USD、正数价格且时间不超过 120 秒的记录参与优先行情路径。未知格式或缺失字段保守回退；目前解析字段是待验证的适配约定，不能视为已经确认的官方响应契约。
- 账户、组合、股票/期权持仓、Level 2、期权链和期权报价提供只读查询入口。查询展示原始字段以供联调；股票/ETF 现在可预览后创建独立账户，并从账户详情同步。参数仍须以实际 tools/list 验证。
- 此版本没有替换 FMP 财务或历史接口，也没有经过测量的 FMP 调用节省数据。
- 完成真实授权后，验证工具 schema、股票报价、Level 2、期权、组合及账户覆盖范围；使用脱敏 fixtures 增加回退、隔离、令牌刷新和断开连接测试。

## 本地验证

`RobinhoodMCPTests` 在 iPhone 17 Pro / iOS 26.5 模拟器上通过 7 项测试：PKCE、表单编码、回调来源/state/过期校验、JSON-RPC/SSE 请求匹配、工具错误/写操作拒绝、schema 变化、报价币种与时效过滤。测试使用合成数据，不代表 Robinhood 真实响应已验证。

项目本地化检查被既有 `ReturnsView.swift`、`SecurityPriceChart.swift` 的两条缺失翻译阻挡；新增 Robinhood 词条包含中英文。电脑控制工具未能连接 Simulator，未完成页面视觉验收。


## iOS 账户同步

每个 Robinhood 账户使用 `Robinhood|账户号码` 作为独立身份，昵称、账户筛选和详情页同步复用现有账户组件。创建时过滤已有账户，管理时限定当前账户；同步只替换指定账户的股票持仓，不生成历史成交，也不覆盖其他账户。

当前导入范围仅 USD 股票/ETF，明确排除现金和期权。缺失成本、未知币种、错误账户、重复证券及带有未完成分页标志的响应会整体失败，保留已有数据。明确空数组可在确认后清空所选账户的股票持仓，账户本身和交易历史保留。预览 15 分钟后失效，授权变更也使旧预览失效。

导入可以使用七天内的最后报价，保留上游真实观察时间，便于休市时同步；实时行情优先路径仍要求 120 秒以内。账户/持仓解析字段仍待真实授权返回验证，未知格式不会猜测写入。
