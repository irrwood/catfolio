# 策略编曲家共享契约 v1

2026-09-10。状态：共享格式与测试向量，**不是执行器交付或数据覆盖证明**。UIKit 客户端实现唯一 parser / executor；Core 本次仅提供契约，不新增路由、调度、金融计算或服务端 parser。

## 文件与所有权

- `core/reference/strategy.schema.json`：JSON Schema Draft 2020-12，根验证 StrategyDocument；`$defs.runArtifact` 是独立运行工件契约。
- `core/reference/strategy-fixtures/`：合成文档、文本、正反例、解释向量及契约校验工具。示例账户/证券并非真实数据，不是默认市场名单。
- UIKit 任务拥有编辑器、存储、Swift parser、能力注册表、执行器及集成测试。Core 维护格式；字段变化需协调消费者并版本化。
- 执行宿主尚待选择。此格式不授权上传个人持仓，也不意味着已有公网服务、后台队列或完成推送。

## 文档与修订

唯一执行输入是经过验证的 StrategyDocument，而非屏幕节点、Markdown 文本或 AI 的自然语言解释。根字段：`kind=STRATEGY_DOCUMENT`、`schemaVersion=1`、`strategyId`、`revision`、`name`、`mode`、`accountScope`、`dataPolicy`、`statePolicy`、`nodes`、`outputs`。

`strategyId` / `nodeId` 为稳定的 1–64 位 ASCII 标识（字母开头，后续字母数字下划线连字符），不得由显示标题或数组序号推导。编辑节点保留 ID；复制策略生成新 strategyId，节点内部引用保持有效，可保留原节点ID因为其作用域是策略。已确认的语义修改递增 revision；草稿键入和纯格式变化不递增执行修订。旧修订不可原地覆盖。未知 schemaVersion 或字段拒绝激活，同时保存原稿。

`accountScope.accountIds` 是客户端不透明账户 ID，只在本地解析；固定列出的账户不包含日后新增账户。首版 scope 仅 SELECTED_ACCOUNTS。空账户列表可保存为草稿，但运行前必须选定账户，禁止悄悄扩展成“全部账户”。复制/跨设备导入时不能把无法解析的账户映射为别人的账户。

`mode` 仅 ANALYZE / SIMULATE。无 LIVE、提交订单、执行券商交易接口。SIZE 的 proposal 是研究目标配置，不是订单。任何 STATE 节点要求 SIMULATE。

`dataPolicy.asOf` 是带时区的截止时间，不是“latest”占位；创建时由用户/客户端明确设定。运行冻结实际输入。必须拒绝未来观测，历史模拟还要验证当时可获知性；仅有今天的历史更正或今日成分快照时不能宣称无前视偏差。`priceBasis` 为 UNADJUSTED / SPLIT_ADJUSTED / TOTAL_RETURN；请求口径缺失不能自行换口径。`maxAgeDays` 单位 DAYS、非负整数且必须已确认；0表示仅截止日，跨市场按各自日历检查最后已完成交易日与实际自然日差。`etfProxyPolicy` 只允许 REJECT / ALLOW_LABELLED，代理不能升级 VERIFIED 基金持仓。

## 类型、参数与预检

数量：`{state:RESOLVED,value:"10",unit:PERCENT}`；未知参数：`{state:UNRESOLVED,reason:"待确认"}`。Decimal 字符串禁止指数、NaN/Infinity，避免跨语言浮点误差。单位为 COUNT / SHARES / RATIO / PERCENT / CURRENCY / PRICE / MULTIPLE / DAYS / SESSIONS / SCORE；PERCENT 的 10 是 10%，RATIO 的 0.1 是同一比例，但必须显式转换，不静默比较。CURRENCY / PRICE 必须带结算 currency；GBX 是报价单位，输入适配时除100成为GBP并记录该变换，不作独立结算币种。

Schema 合法仅说明结构正确。预检须逐层验证：

1. 图结构：nodeId 唯一、引用存在、无环、输出port有效；类型/端口/输入基数正确，未知字段不忽略。无节点或无输出是可保存草稿，诊断 EMPTY_GRAPH / NO_OUTPUTS，不可执行。
2. 参数：不存在 UNRESOLVED；阈值维度一致，COUNT/日数/窗口为合适整数，窗口长度正数；支持的 operator/metric/methodologyVersion 才可执行。
3. 能力：执行器声明的 `type + operation/metric + methodologyVersion` 支持集合，不支持返回 UNSUPPORTED；不得因为 JSON 值齐全就显示“策略可运行”。
4. 数据：账户、证券/挂牌身份唯一，实际日期、历史长度、价格口径、币种与来源满足要求。否则 UNKNOWN / INCOMPLETE 并返回原因，不用0/false/样例补齐。

诊断至少包含 code、message、nodeId（根问题可空）、JSON Pointer、文本 span（若可定位）。区分 INVALID（语法/类型不合法）、UNRESOLVED（参数待确认）、UNSUPPORTED（当前无能力）、DATA_INCOMPLETE（本次数据缺口）、READY。检查顺序不能掩盖其他诊断。

运行值的 UNKNOWN 与草稿参数的 UNRESOLVED 是两类状态。运行 observation 的 value 在 UNKNOWN 时必须 null，reason 必填；VERIFIED/ESTIMATED 必须有数据来源或可追溯的输入工件，不能把模型回答本身标为经事实核验。

## 节点端口与行为

`inputs` 是命名输入 → `{nodeId,port}`；`outputs` 是需交付结果的 edge 数组。schema 保持统一 envelope，以下端口与语义由唯一 Swift 验证器检查。未知 port 拒绝，不忽略。Universe 中每项以 `(securityId,listingId)` 标识；不能以全球裸 ticker 联接。

| type | 输入 | 输出 | v1语义 |
|---|---|---|---|
| source | 无 | universe | SELECTED_HOLDINGS 时 securities 必须空；EXPLICIT_SECURITIES 必须非空且身份唯一。范围须展示，不称全市场 |
| indicator | universe | value | 对每证券产出带单位/日期/来源的值；不支持或缺数据显式标记 |
| filter | universe, value | universe, predicate | LT/LTE/EQ/GTE/GT/NE；predicate 为同一宇宙逐证券三值结果；universe只保留TRUE并另报UNKNOWN数量 |
| any / all | p1…pN（至少2个连续编号） | predicate | 同一宇宙的predicate运算；不隐式broadcast、union或按数组位置拼接 |
| if | universe, condition | then, else, unknown | TRUE/FALSE/UNKNOWN分别分区；unknown不走else，未知分区可展示诊断但不能用于生成配置proposal |
| ai | universe | thesis | THESIS 结构化证据工件；首版不直接输出买卖或boolean predicate |
| sort | universe, value | universe | ASC/DESC，null EXCLUDE/LAST；同值以securityId再listingId的ASCII序确定次序；limit为正整数COUNT |
| size | universe | proposal | TARGET_WEIGHT / FIXED_AMOUNT / FIXED_SHARES；对每个输入证券的目标值，非增量订单 |
| risk | proposal | predicate | 对整个提案+冻结组合做已注册风险指标比较，输出单个三值predicate |
| guard | proposal, condition | proposal | 仅接受风险/明确注册的标量predicate；TRUE放行；FALSE/UNKNOWN均阻断 |
| state | READ无输入；PROPOSE_SET必须condition | READ:value；PROPOSE_SET:delta | condition是标量predicate，TRUE才返回delta，其余不改状态；永不直接提交状态 |

各输出附 UNKNOWN、排除和缺失的独立诊断。一个无输出的未连接节点仍需结构验证；只执行 outputs 可达的依赖，未触及节点记 SKIPPED 并说明 UNREACHABLE。需要运行的 AI/STATE 节点必须被 outputs 或依赖引用，不能因为画在画布上就产生副作用。全图参数预检应提示未连接草稿缺口，运行计划必须明确实际选用的可达子图；首版可直接禁止任何未解决参数以简化界面。

risk/guard 的标量predicate与 filter 的逐证券predicate是不同类型。禁止隐式把“某只通过”解释为“整个组合通过”。IF只做同宇宙分区，复杂分支合并需以后新增显式算子，v1不支持循环或隐式merge。

SIZE：TARGET_WEIGHT 用 PERCENT 且 denominator=NAV；FIXED_AMOUNT 用 CURRENCY 且 denominator=NOT_APPLICABLE；FIXED_SHARES 用 SHARES 且 denominator=NOT_APPLICABLE。NAV/可用资金来自运行账户快照，禁止使用券商凭据或修改账户。目标权重0–100、金额/股数非负；多证券目标与现有未调整资产一起检查总预算，无法计算预算即 UNKNOWN。DOWN_TO_LOT 需要正SHARES lotSize及对应价格/FX；NONE仍须明确lotSize（1 SHARES，仅占位不参与舍入）。不自动假设可碎股、不允许隐含杠杆/负仓位；预算不足返回诊断，不自动归一化或强卖现有持仓。schema枚举保留 AVAILABLE_CASH 给未来明确口径，v1不支持时返回UNSUPPORTED。

## 指标注册表 v1（语义目标，不承诺适配完成）

| metric / methodologyVersion | window | outputUnit | 定义 |
|---|---|---|---|
| price / 1 | null | PRICE | 截止时间之前最后一个符合陈旧策略的完整日线close及结算币种，不是盘中价 |
| volume / 1 | null | SHARES | 同一完整日线成交股数；缺失不是0 |
| return / 1 | N SESSIONS | PERCENT | 100×(close[t]/close[t−N]−1)，需N+1条连续有效交易日close |
| sma / 1 | N SESSIONS | PRICE | 最近N条完整交易日close算术均值 |
| rsi / 1 | N SESSIONS | SCORE | 有限窗口Cutler RSI：最近N个差分正/负均值；需N+1条。涨跌均为0→50，仅跌为0→100；**不是Wilder平滑RSI** |
| volatility / 1 | N SESSIONS，N≥2 | PERCENT | 最近N个log(close[t]/close[t−1])的样本标准差(ddof=1)×sqrt(252)×100；需N+1条；252是方法假设，不是每市场实际日数 |

窗口 calendar=TRADING_SESSIONS、length单位SESSIONS，exchangeMIC必须与挂牌匹配；跨交易所Universe需要按挂牌各自日历（exchangeMIC=null），适配器不支持则阻断。CALENDAR_DAYS 可表达，首版上述指标不支持，返回UNSUPPORTED，禁止当交易日处理。数据中缺某交易日不能将缺口压缩为连续样本。price/sma 的 currency 从输入衍生；filter阈值必须同币种或经显式、有来源的转换。volume输入口径须相同，不因价格复权静默复权成交量。

risk初始建议注册 max_position_weight / 1：最大单证券目标敞口÷运行NAV×100，PERCENT，组合现有未修改资产也参与；缺估值/FX/身份时UNKNOWN。是否已实现由UIKit能力表报告，不能由本规范替代测试。其他metric允许表达，但没有明确版本定义前不得运行。AI_THESIS、复杂风险、跨会话STATE可先UNSUPPORTED。

## 三值逻辑和模拟状态

ANY: 任一TRUE→TRUE；全FALSE→FALSE；否则UNKNOWN。ALL: 任一FALSE→FALSE；全TRUE→TRUE；否则UNKNOWN。空逻辑节点非法。IF UNKNOWN不进入else；GUARD UNKNOWN阻断。风险数据缺失不自动视为安全。

STATE只允许SIMULATE，命名空间实际键为 `(strategyId, simulationSessionId, initialSnapshotId, key)`；不能省略simulationSessionId导致跨模拟串状态。statePolicy.initialSnapshotId为null表示明确空模拟状态，读不存在key→UNKNOWN，不能默认为“未触发”。PROPOSE_SET的value是提案literal；首次显式初始化应由用户确认的模拟起始状态提供，不擅自补默认。READ的params.value必须null。状态值首版限制scalar；用于数量计算需另有明确类型适配，不把string/number偷偷变成bool。

运行只返回 proposedStateDelta 和其来源node/前值版本工件；不写真实账户、真实档位或冷静期。多节点写同一key冲突阻断，不以执行顺序最后覆盖。即使用户选择续用模拟session，提交delta也需独立显式操作与期望前版本校验，首版可仅展示delta。

## 文本grammar及双向转换

规范文本 v1 是有 Markdown 外观的结构语言；自然语言不是执行语法。规范形式示例见 `return-screen.strategy.md`。EBNF（JSON使用RFC8259对象语法，禁止重复key）：

```text
document = "# Strategy" LF blank* metadata blank* nodeSection* ;
metadata = "```json" LF metadataObject LF "```" LF ;
nodeSection = "## " nodeId LF blank* "```json" LF nodeObject LF "```" LF blank* ;
metadataObject = JSON对象（所有StrategyDocument字段，唯独不含nodes） ;
nodeObject = JSON对象（完整node，nodeId必须与heading一致） ;
blank = LF ;
```

JSON对象可多行，JSON字符串按JSON转义，不能按字符串内的换行文本截断对象。fence闭合必须独占一行；接受CRLF，规范输出LF。UTF-8，无BOM。首版不接受额外Markdown段落、注释、多个metadata fence、重复heading/JSON key；不能静默丢弃。title固定“Strategy”，显示名称取metadata.name。节点顺序按section顺序，视觉拖动改变顺序但保留ID；语义依赖来自edge，不能靠显示顺序执行。

`parse(render(AST))` 必须 JSON语义相等（对象key顺序忽略、数组顺序保留、decimal字符串原样保留）。`render(parse(text))` 允许缩进规范化，不要求字节一致。用户原文始终作为draftText独立保存；非法或不支持原文保留原字节和diagnostics，不能覆盖lastValidDocument，也不能悄悄运行旧版而宣称跑了当前草稿。转换失败停留文本视图，展示错误位置。运行旧版只能经明确“运行已保存第N版”操作。

编辑会话另外保存 baseRevision、draftText、lastValidDocument；它们不塞入执行AST。快捷插入直接生成节点或规范语法；未知参数生成UNRESOLVED。UI可通过表单美化参数，不能把未定义的“适当”“大涨”转为固定数字。

AI整理输出 candidateDocument + baseRevision + 语义diff，先校验再待用户确认；显示新增/删除节点、参数/单位/账户scope变更和未知项。用户确认时比较baseRevision，已变则冲突，禁止覆盖新稿。AI候选保留原输入/模型/提示版本/输出工件，禁止自动激活。

## 运行与可复现工件

`$defs.runArtifact` 与策略文档分开验证；runId标识一次运行，runRevision是其追加状态修订，strategyRevision固定，不能用运行进度更新策略revision。attempt在步骤重试时增加，历史attempt记录追加保留。snapshotId指向冻结Manifest：策略原始UTF-8工件及hash、数据与证券映射版本、引擎/指标版本、asOf、原始观测时间/来源hash、accountScope和私有持仓输入hash、初始模拟状态、AI工件。hash针对保存的确切字节，不要求不同语言JSON pretty printer产生相同hash；重放读同一工件。

所有个人账户快照继续本地私有存储；Core T7数据版本只存公共参考数据。本契约不授予上传或部署许可。结果绑定运行实际账户版本，不随当前持仓变化而悄悄更新。

确定性节点读冻结输入，禁止中途再次抓latest。AI单独留证据来源、内容hash、模型/提示/输出schema版本与原始答复；引用必须来自提供的证据集合，材料中的指令视为数据。未联网搜索不得标注“已搜索市场”；无引用不能编造来源。精确重放复用已保存AI工件；重新请求模型是新attempt/运行结果，不能承诺模型确定性。

进度按实际步骤/候选处理数与状态报告，不编造AI百分比。取消标记后不调度新步骤，已完成工件保留；允许已发出的外部AI请求结束，但结果不可越过取消状态重新激活运行。重试仅针对幂等步骤，使用冻结输入和独立attempt，不重复消费STATE。后台持久队列、事件流、完成通知均需宿主实现，本文件不表示已有。

## 校验与交接

运行 `python3 core/reference/strategy-fixtures/validate.py`：检查schema自洽、文档正反例、独立运行工件与固定文本fixture的映射。依赖jsonschema，缺库即报错，不自动安装。此工具只验证已知fixture布局，**不是生产parser或第二个执行器**。

`manifest.json` 区分schemaValid与预检解释；`validation-vectors.json` 给Swift行为预期，需由UIKit唯一执行器加入测试。该脚本通过不代表金融指标、三值逻辑或UIKit parser已经实现/验证。对外宣称READY前还需Swift执行测试，包括单位/历史缺口/未来观测/未知分支/AI失败/STATE隔离/重试取消，以及现有Demo与真实账户不受影响的回归。
