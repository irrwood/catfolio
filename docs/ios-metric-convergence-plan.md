# Catfolio iOS 口径收敛清单

> **用途**：把「同一个口径存在多份实现」这件事，从一句结论变成一张可执行的工单。
> **基线**：工作树 `HEAD = 3162c10`（build 10）+ 未提交修改。工作树有 23 个文件处于 ` M` 状态，**本清单所有行号对应工作树内容，不是 HEAD**。
> **基线校验**（想确认我读的是哪一版，比对前 12 位即可）：
>
> | 文件 | SHA-256 前缀 |
> |---|---|
> | `LocalServices.swift` | `de88fae72d4d` |
> | `LocalPortfolioStore.swift` | `f2896b6d8b55` |
> | `PortfolioView.swift` | `3fd75f03906a` |
> | `TodayDetailView.swift` | `32426cdedf7f` |
> | `LocalReturnsAnalytics.swift` | `5cdec6f81a0a` |
> | `GBPFXRates.swift` | `eeab843c15b8` |
> | `StandardLineChart.swift` | `f2db1f0c6693` |
>
> **核实标记**：✅ = 本次亲自逐行核实过调用方；⚠️ = 部分核实，动手前需再确认。

---

## 0. 判定图例

| 类型 | 含义 | 处置方向 |
|---|---|---|
| **A 修正未收敛** | 旧实现被判为不够好、新实现上线了，**旧路径没退休** | 删旧的，或把调用方全迁过去 |
| **B 纯重复** | 同一意图、同一公式，多处维护，守卫已分叉 | 抽单一 owner |
| **C 语义撞名** | 两个都对的指标共用一个名字 | 改名 + UI 说明口径 |
| **D 真 bug** | 活路径上会算出错数字 | 立刻修 |

**执行顺序：D → A → B → C。**
理由：D 是用户已经在被误导；A 是「以为修好了」的陷阱，成本最低；B 是防复发；C 是产品决策，需要你拍板，可以先挂着。

---

## 批次 1 — 真 bug（D 类）

### D1 估值矩阵：分子分母币种范围不一致 ✅

| 项 | 内容 |
|---|---|
| **现象** | 气泡大小（权重）被系统性缩小 |
| **证据** | `LocalReturnsAnalytics.swift:378-384` 分母 `totalMarketValue` 对**全部持仓**求和（不限币种）；`:390` 分组时**只取 `currency == "USD"`**；`:411` `weight: value.marketValue / totalMarketValue` |
| **旁证** | 同一函数 `:417` 的警告文案自己写着「估值矩阵目前只计算以 USD 为成本币种的持仓」——**分母没有遵守这个口径** |
| **影响** | 例如组合 50% USD + 50% GBP：每个 USD 气泡的权重都只有真实值的一半 |
| **处置** | 二选一，需你拍板：<br>(a) 分母改为 USD 子集之和 → 气泡表达「占 USD 持仓比」<br>(b) 分组扩到全币种（需确认 FMP 能取到对应标的的基本面） |
| **前置测试** | 构造 USD + GBP 混合组合，断言 `Σ weight ≤ 1` 且与选定口径一致 |
| **风险** | 低。只影响气泡大小，不影响任何收益数字 |
| **工作量** | 0.5 天 |

### D2 `completeWithCodex` 丢失 `structured` ✅

| 项 | 内容 |
|---|---|
| **现象** | `.codex` 或 `automatic` 命中 Codex 时，要求 JSON 的请求返回自然语言散文 |
| **证据** | `LocalServices.swift:4308` 签名 `completeWithCodex(question:context:)` **无 `structured` 参数**；调用点 `:4138`、`:4151` 均未传；对比 `:4302`（DeepSeek）与 `:4580`（OpenRouter）**都有**该参数并据此切换 `structuredSystemPrompt` |
| **受害调用方** | `SecurityDebateStore`、`PolicyRunCoordinator.swift:242`、`PolicyComposerStore.swift:475`——都按 JSON 解析返回值 |
| **影响** | `automatic` 模式下 Codex 排在 OpenRouter/DeepSeek 之前，**这条路径会被真实命中**，表现为解析失败（可能呈现为「分析失败」或空结果，用户看不出根因） |
| **处置** | 二选一：<br>(b) **先止血**：让 Codex 不参与 structured 请求，provider 选择时跳过它<br>(a) 后续：让 Codex 支持 structured（Codex Responses 端点支持 `response_format` / JSON schema，需实测） |
| **前置测试** | 断言 structured 请求在 Codex 路径要么返回可解析 JSON，要么抛出明确错误——**不能返回散文** |
| **风险** | 中。(b) 会改动 `automatic` 的回退顺序，需回归 `AIStreamingTests` 与 provider 相关测试 |
| **工作量** | (b) 0.5 天 / (a) 2–3 天 |

---

## 批次 2 — 修正未收敛（A 类）

> 这一批的共同特征：**审计报告里已经打了勾，但修复只落在了一个调用方身上。**

### A1 FIFO 批次排序：修复从未覆盖 FX 路径 ✅

| 项 | 内容 |
|---|---|
| **两套实现** | **A** = `LocalPortfolioStore.swift:473-488` `orderedForLotMatching`<br>**B** = `LocalServices.swift:3423-3426` `remainingLots` 内联比较器 |
| **差异（逐字）** | A：`date` → 真实时间戳（缺失时买入 `-∞` / 卖出 `+∞`）→ 同时刻**买入优先** → `id`<br>B：**只有** `date` → `tradeID` |
| **修复史** | `docs/audits/ios-2026-09-13/FIXES.md` 的 **#12** 与随后的**"再次复查"**改的都是 **A**——先修时间戳解析，发现引入回归（CSV 只有日期时 `executedAt` 全是 `00:00`，同时间按 ID 排序会让 `a-sell` 排在 `z-buy` 前），再改成「同时刻买入优先」。**B 两次修复都没收到。** |
| **调用方** | B 仅服务 `LocalFXImpactCalculator.remainingLots`（FX 批次重建）；A 服务已实现盈亏等路径 |
| **处置** | 删除 B，改为调用 A |
| **前置测试** | 复用审计复查的用例（CSV 仅日期 + `a-sell`/`z-buy`），断言 **FX 路径与已实现盈亏路径的同日批次顺序一致** |
| **风险** | 低，但**会改变 FX 数字** → 建议先跑一份真实账本，记录改前改后差异并人工确认哪个对 |
| **工作量** | 0.5 天 |

### A2 FX 影响：两套口径并存，且旧口径带未修分支 ✅

| 项 | 内容 |
|---|---|
| **主口径** | `LocalFXImpactCalculator.enrich`——当前价口径、USD 存储、Yahoo 日线。调用点：`APIClient.swift:1035 / 1135 / 1234`（Trading 212 / Moomoo / IBKR 三处导入） |
| **旧口径** | `FXImpactCalculator.impact`——**剩余成本**口径、硬编码目标币种 `GBP`、内置 ECB 离线包。调用点：`LocalPortfolioStore.swift:1951`（**展示层兜底**：券商无 `fxPnl` 且无 `brokerPnl` 时） |
| **关键判断** | **两者算的不是同一个问题**，不是简单的"旧的不准"：<br>· 当前价口径 = FX 对**当前价值**的影响<br>· 剩余成本口径 = FX 对**成本基础**的影响<br>两个定义都能自圆其说。审计 #07 / #10 / #11 修的是**旧口径的实现细节**（单位、批次消耗顺序、汇率回溯日期），不是公式选择 |
| **附带未修分支** | `GBPFXRates.swift:91-93`：`let code = currency.uppercased()` 之后才判 `if code == "GBX" \|\| code == "GBp"`——`"GBp".uppercased() == "GBP"` 会先被上一行的 `code == "GBP"` 命中并返回 **rate 1**，即**便士当英镑**。该分支当前不可达 |
| **可达性** | 券商客户端（Trading 212 / SnapTrade）已把 `GBp` 归一化为 `GBX`，所以是**潜在**问题而非已确认的线上错误；但账本还可能来自 CSV、公开投资者等路径，不能假定永远不出现 |
| **用户可见后果** | **同一持仓，券商报了 `fxPnl` 走主口径，没报走旧口径 → 两个不同的 FX 数字** |
| **处置** | 三选一，需你拍板：<br>**(a) 推荐**：两套都留，但**强制区分命名与 UI 标注**（"按当前价值的汇率影响" / "按成本的汇率影响"），并修掉 `GBp` 分支<br>(b) 展示层统一走主口径，删除 `FXImpactCalculator`<br>(c) 保留兜底但只修 `GBp` 与单位，不做命名区分 |
| **前置测试** | ① 同一持仓在"有券商 fxPnl / 无券商 fxPnl"两条路径下，断言 UI 标注不同、数字来源可辨；② `quote(currency: "GBp")` 断言返回 **100** 而非 1 |
| **风险** | 中。涉及用户可见的 FX 数字 |
| **工作量** | 1–2 天 |

### A3 NAV/TWR 的第三套实现是死代码 ⚠️

| 项 | 内容 |
|---|---|
| **死的那套** | `LocalServices.swift:2804` `private static func currentWeightModelSeries`——全仓**仅命中定义行**，无调用方 |
| **别误删的** | `impliedLedgerDays` 是**活的**：`LocalPortfolioStore.swift:2152` 与 `LocalServices.swift:2337` 两个调用方。它是"不完整账本"下的成本推算兜底，不是死代码 |
| **现行主路径** | `accountTimeWeightedSeries`（`LocalServices.swift:2404`，全文件最大方法，247 行） |
| **处置** | 只删 `currentWeightModelSeries` |
| **风险** | 零 |
| **工作量** | 0.2 天 |

---

## 批次 3 — 纯重复（B 类）

### B1 今日盈亏：同一公式两处，守卫已分叉 ✅

| 项 | 内容 |
|---|---|
| **A** | `PortfolioView.swift:601-618`（`makeContributions`）：`let factor = 1 + change/100; guard factor > 0 else { return nil }` |
| **B** | `TodayDetailView.swift:26-39`：`let previous = MV / (1 + change/100); let amount = MV - previous; guard amount.isFinite` |
| **同一性** | 两处代数上是同一个公式（等价于 `MV − MV₋₁`）。差的是**边界守卫**，不是精度 |
| **漂移方向** | `change < −100%` 时：A 丢弃；B 算出 `previous = MV / 负数 = −2MV` → `amount = 3MV`，**显示一个经济含义错误的大正值**。即**后写的那处更差** |
| **处置** | 保留 A 的守卫，抽成单一函数（建议随计算引擎迁入 `CatfolioCore`） |
| **前置测试** | 参数化 `change ∈ {+5, −5, −50, −99, −100, −101, −150}`，断言两处输出**完全一致**，且 `< −100%` 时两边都返回 `nil` |
| **风险** | 低 |
| **工作量** | 0.5 天 |

### B2 Y 轴刻度：9 个调用点各写一遍 ✅

| 项 | 内容 |
|---|---|
| **调用点（9 个）** | `CycleComparison.swift:387`（`[0]`）<br>`HoldingContributionChart.swift:175`（`[top, top/2, 0]`）<br>`IndustrySentimentView.swift:220`（`(0...3).map`）<br>`LossAnalysisChart.swift:162`（`[0, bottom/2, bottom]`）<br>`PortfolioView.swift:1734`（`(0..<5).map`）<br>`ReturnsAnalyticsView.swift:242` → 本地 helper<br>`ReturnsView.swift:1120`（`(0..<6).map`）<br>`UnderwaterAnalysisChart.swift:404`（`[0, bottom*50, bottom*100]`）<br>`VolumeProfileView.swift:1491`（`(0..<4).map`） |
| **根因** | `StandardLineChart` 的 `yTicks: [Double]` 由调用方传入（`StandardLineChart.swift:438/498`），渲染器**不做 nice numbers** |
| **⚠️ 关键提醒** | **各图的 `bottom` / `top` 单位不同，不能盲目套同一个公式**：<br>· 水下图 `bottom` 是**小数**（drawdown，如 −0.25），series 已 `×100`<br>· 损失图 / 贡献图的 `bottom` / `top` 是**金额**（美元）<br>· 行业情绪图是分数<br>这正是本清单初版把一个**自洽的实现误判为 bug** 的成因（见第 5 节） |
| **处置** | 在 `StandardLineChart` 加 `niceTicks(domain:count:)`，调用方**先把自己归一化到显示单位**再调用；一个图一个图替换，不批量改 |
| **前置测试** | 对每个图做特征测试：断言替换前后 `yTicks` **完全相等**；不等就先别换（说明该图有特殊口径） |
| **风险** | 低—中（视觉） |
| **工作量** | 2–3 天 |

### B3 玻璃回退：39 处、15 个文件 ✅

| 项 | 内容 |
|---|---|
| **计数** | `#available(iOS 26.0` 共 **39 处**，分布：`VolumeProfileView` 7、`LocalServices` 5、`DesignSystem` 5、`StandardLineChart` 4、`PortfolioView` 3、`AIView` 3、`PolicyBackgroundService` / `OptionsOIView` / `HistoryView` 各 2，其余 6 个文件各 1 |
| **处置** | 抽 `View.glassSurface(_:)` 单一封装；`RootTabView` 已有一份 private `navigationGlass` 可作为原型 |
| **风险** | 低（纯视觉），但注意 `PolicyBackgroundService` 与 `LocalServices` 里的 2 处不是视觉、是 API 可用性判断，**不要一起抽** |
| **工作量** | 1–2 天 |

---

## 批次 4 — 语义撞名（C 类）

### C1 「回撤」：两个不同的指标共用一个名字 ✅

| 项 | 内容 |
|---|---|
| **定义 A** | `LocalReturnsAnalytics.swift:270` `drawdown(document:)`——**当前权重 Top35 的模型组合**、5 年 NAV |
| **定义 B** | `UnderwaterAnalysis.swift:15` / `UnderwaterAnalysisChart`——**实际持仓**（`fixedShareHistory` 固定今日股数回推） |
| **判定** | **两个都是合理指标，没有哪个更准。** 问题在于用户看到的都叫「回撤」，而 `ReturnsView.swift:145` 的入口文案是「回撤水下曲线」 |
| **处置** | 改名 + UI 说明：把模型组合那条明确标为「参考组合回撤（Top35 权重模型）」，实际持仓那条保持「我的回撤」 |
| **风险** | 低（文案 + 命名） |
| **工作量** | 1 天 |

### C2 ETF 权重：两个基数的同名字段 ✅（已降级）

| 项 | 内容 |
|---|---|
| **基数 A** | `LocalServices.swift:4821` `etfWeightPercent = fromETFUSD / etfTotal`，其中 `etfTotal`（`:4751`）= **仅 ETF 敞口之和** |
| **基数 B** | `PortfolioView.swift:2772-2774` `portfolioWeight = row.totalUSD / portfolioTotal`，其中 `etfPortfolioTotal`（`:2364-2366`）= **穿透后全部行合计**（直接 + 间接） |
| **严重度修正** | 初版把这条写成「同一行显示两个百分比」。**复核后降级**：`etfWeightPercent` 当前**只在死代码 `ETFLookThroughView.swift:163-164` 渲染**，活 UI 只渲染 `portfolioWeight`。所以现在是**字段语义陷阱**，不是用户可见错误 |
| **处置** | 改名区分（如 `shareOfETFExposure` / `shareOfPortfolio`），或直接删掉活路径不用的那个 |
| **风险** | 低 |
| **工作量** | 0.3 天 |

### C3 基准总收益不对称 ✅（口径选择，非代码 bug）

| 项 | 内容 |
|---|---|
| **基准侧** | `LocalServices.swift:2707` 调 `historicalCloses(symbols:...)` **不传** `dividendAdjusted` → 命中默认值 `true`（`:2879`）→ `:3051` 取 `adjclose`，即**总收益** |
| **组合侧** | 持仓市值 + **显式股息现金流** |
| **后果** | 未导入股息的组合会**系统性跑输**基准 |
| **判定** | 这是**口径选择**，不是实现 bug——但后果对用户真实。`dividendAdjusted: false` 在 `:1377` 是给"取最近报价"用的，不是收益序列 |
| **处置** | 二选一：<br>(b) **先做**：UI 明说「基准为总收益口径，组合为现金流口径」<br>(a) 后续：组合侧补上未录入股息的估算并显式标注为估算 |
| **风险** | (b) 低 / (a) 中 |
| **工作量** | 1 天 / 3–5 天 |

### C4 `comparison` 有两套实现 ✅

| 项 | 内容 |
|---|---|
| **两套** | `LocalPortfolioStore.swift:2151` `static func comparison(for:) throws`（同步、抛错）<br>`LocalServices.swift:2262` `func comparison(document:) async throws`（异步、实例方法） |
| **注意** | `PolicyRunTrace.swift:309` 的 `comparison(_:)` 是**字符串比较工具**，与此无关，别混进来 |
| **处置** | 先追调用方确认哪套是活路径，删另一套 |
| **前置工作** | 追调用方（约 0.2 天），再决定 |
| **风险** | 低 |
| **工作量** | 0.5 天 |

---

## 5. 本次核实的撤回与降级

**这份清单的初版有三条被高估，我逐条复核后修正如下。写在这里是为了让你知道哪些结论可信、哪些要打折。**

| 条目 | 初版说法 | 复核结论 |
|---|---|---|
| 水下图 yTicks | 「刻度比坐标范围大两个数量级，确认为笔误」 | ❌ **完全撤回**。`bottom` 是小数、series 已 `×100`，所以 `domain: (bottom*100)...0` 与 `[0, bottom*50, bottom*100]` **单位一致、完全自洽**。误判成因：拿它和 `LossAnalysisChart` 的 `bottom/2` 比表达式，但后者 `bottom` 是**美元**，两者单位约定不同 |
| `GBp` 分支 | 「便士当英镑（真 bug）」 | ⚠️ **降级为潜在问题**。分支确实不可达，但券商客户端已把 `GBp` 归一化为 `GBX`，当前是否可达未确认 |
| ETF 两个权重基数 | 「同一行显示两个不同百分比」 | ⚠️ **降级**。`etfWeightPercent` 只在死代码里渲染，活 UI 只显示一个 |

**三条修正的共同教训**：深挖报告倾向于把「**定义不同**」判定为「**实现错误**」，并且不检查**可达性**。

所以这份清单的每一条都标了 ✅ 和「活的调用方」——**动手前请先确认调用方那一栏，那才是决定严重度的东西**。

---

## 6. 执行建议

| 批次 | 内容 | 累计工作量 | 是否需你拍板 |
|---|---|---|---|
| 1 | D1 估值矩阵分母、D2 Codex structured | 1–3.5 天 | D1 需选口径；D2 需选方案 |
| 2 | A1 FIFO、A2 FX、A3 死代码 | +2–3 天 | A2 需选方案 |
| 3 | B1 今日盈亏、B2 y 轴、B3 玻璃 | +4–6 天 | 否 |
| 4 | C1 回撤、C2 ETF 权重、C3 基准、C4 comparison | +3–7 天 | C1/C3 需选方案 |

**需要你现在拍板的 5 个决策**：
1. D1：估值矩阵气泡表达「占 USD 持仓比」还是「占全部持仓比」？
2. D2：Codex 先跳过 structured（止血），还是直接实现 structured？
3. A2：FX 两套口径是「保留并区分命名」还是「统一到主口径」？
4. C1：「回撤」两个指标改成什么名字？
5. C3：基准口径是先加说明，还是直接补组合侧的总收益？

**前置条件**：开工前请先 `git commit` 或 `stash`。工作树现在有 23 个文件未提交，一旦我改文件，你的未提交修改和我的改动会混在一起，回滚粒度会丢失。

**每条完成的验收标准**：
- 该条对应的**一致性测试**必须先红过、再绿；
- 涉及数字的（A1 / A2 / B1 / D1 / C3），必须附**改前改后对照**；
- 全清单完成后，报告 §11.8 的「同一口径多处实现」表应归零。

**建议顺手加的 CI 检查**（防止清单做完又长回来）：
- 同名函数在多文件定义 → 告警；
- `#available(iOS 26.0` 出现文件数 > 1 → 告警（抽完封装后应恒为 1）；
- 单文件行数超过预算 → 告警（沿用 `scripts/check_ios_design.py` 的「预算只减不增」思路）。
