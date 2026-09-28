# iOS 首页持仓列表规则

适用范围：Catfolio iOS 首页「Catfolio」持仓列表的标准 cell，包括普通账户、演示数据和佩洛西等公开投资人模式。三者使用同一套标题、数字、标签和视觉规则。这里不定义热力图、ETF 穿透明细或个股详情页。

设计参考：[首页列表](https://www.figma.com/design/EtNSXmasS8lz9JzrWUoMd9/Catfolio?node-id=109-18599)、[A/D 标签结构](https://www.figma.com/design/EtNSXmasS8lz9JzrWUoMd9/Catfolio?node-id=432-26702)、[标题与金额对齐](https://www.figma.com/design/EtNSXmasS8lz9JzrWUoMd9/Catfolio?node-id=432-12021)。本文件同时记录目前代码中的格式约定；设计要求和代码有差异时，在文末列明。

## 1. Cell 结构与尺寸

```text
┌──────────┬───────────────────────────────┬─────────────────┐
│ 44×44    │ 股票／基金简称                  │ 持仓金额         │
│ logo     │ 股票数量  代码  [A] [C] [D]   │ 盈亏金额  百分比块 │
└──────────┴───────────────────────────────┴─────────────────┘
```

- 标准 cell 最小高度 64pt；cell 之间 4pt；列表左右沿用页面的 20pt 边距。
- Logo 为 44 × 44pt，与文字区相隔 10pt。圆角 12pt，使用连续圆角，视觉上尽量接近 Figma 的最大 corner smoothing。
- Logo 依次使用打包的新版资源、旧版资源、在线 Logo；在线资源加载期间保留字母占位，成功后在列表原位显示。离线或确实没有资源时继续显示字母占位，不留空白。
- Logo 外描边为 0.5pt：日间黑色 5% 不透明度，夜间白色 5% 不透明度。
- 文字区上下两行间距 2pt。可见字形整体距 cell 上下边约 16pt；以视觉字形对齐，不直接拿字体的完整 line box 对齐。
- 第一行标题和右侧金额在视觉上上下对齐；第二行数量、代码、标签与盈亏信息对应。金额当前有 1pt 的向上光学调整。
- 标题占剩余宽度并可尾部截断；右侧金额、盈亏与百分比保持单行，不应被标题挤掉。
- 整个 cell 可点击。按下缩放反馈须遵守系统的“减少动态效果”设置。

## 2. 第一行：名称与持仓金额

### 名称

- 左侧只显示可识别的公司或基金简称，使用 SF Rounded 16pt、semibold；日间黑字为 `#1E1E20`，夜间使用系统主文字色。
- 普通账户、演示和公开投资人模式都经由 `Holding.shortName` 与 `CompanyNameCatalog` 得到展示名；公开披露数据先清掉披露附注，再走相同的简称规则。**不能按模式另做一套标题字体或简称表。**
- 已有通用简称优先，例如 `NVIDIA Corporation → NVIDIA`、`Apple Inc. → Apple`、`American Express Company → American Express`、`Interactive Brokers Group, Inc. → Interactive Brokers`。可选的「中文简称」设置同样作用于所有模式。
- 没有可靠别名时，去掉末尾的法律后缀，如 `Inc.`、`Incorporated`、`Corp.`、`Corporation`、`Holdings`、`Holding`、`Ltd.`、`Limited`、`PLC`、`Co.`；股票名称末尾的 `Common Stock`、`Common Shares`、`Ordinary Shares` 也可去掉。保留能辨认证券的主体名称，不机械删除名称中间的词。
- 基金的 `ETF`、`ETN`、`UCITS`、`Fund`、`Trust` 等产品信息要保留；不得把影响基金识别的词当作公司法律后缀删掉。
- `Acc`／`Dist`、`Class A/B/C…`、`Series A…` 等尾部类别不占第一行标题，转为第二行的小标签。
- 公开披露名称中的尾部 `(股票代码)`、重复的 `[股票代码]`，以及 `[ST]`、`[OP]` 等披露类型代码只从展示名中清除；原始披露名称与证券身份仍保留在数据里。不能把私人商业权益强行改成同代码的上市公司名称。

### 金额

- 右上角显示当前持仓市值，SF Rounded 15pt、semibold、等宽数字，右对齐；使用与标题相同的主文字色。
- 金额按当前展示货币格式化。常规金额保留两位小数；**绝对值超过 1,000,000** 后，当前格式省略小数。金额不使用股票数量的 `K/M/B` 缩写规则。
- 公开披露的金额可能是区间、下限、上限或「未披露」；按原有披露精度展示，不把区间伪装成精确市值。

## 3. 第二行：数量、代码、A/C/D 标签

- 从左到右固定为 **股票数量 → 股票代码 → 类别标签**。标签跟在代码后面，不回到第一行标题。
- 数量和代码使用 SF Rounded 14pt、medium；数量不强制等宽数字，二者和标签使用次要灰色（当前列表为 `#8E8E93`）。
- 股票数量固定保留两位小数，不加千位分隔符。绝对值达到 `1,000` 时改用 `K`，达到 `1,000,000` 时用 `M`，达到 `1,000,000,000` 时用 `B`；每档仍保留两位小数。四舍五入会显示 `1000.00K` 时应进位为 `1.00M`。无有效数值显示 `—`。

| 原始数量 | 列表展示 |
| ---: | ---: |
| `83.4078` | `83.41` |
| `1,000` | `1.00K` |
| `12,345.678` | `12.35K` |
| `999,999.99` | `1.00M` |
| `1,234,567` | `1.23M` |
| `1,500,000,000` | `1.50B` |

- 标签语义：`Acc`／`Accumulating → A`，`Dist`／`Distributing → D`；`Class A/B/C…`、`Cl A/B/C…`、`Series A…` 使用对应大写字母。若一个名称同时含分配类别和股份类别，按原文顺序展示多个标签，例如 `(Acc) Class C → [A] [C]`。
- 只解析**名称末尾**的类别描述；`Accenture` 这类公司名中的相同字母不得误判。
- 标签文字与右侧百分比同为 **12pt**，字重为 medium；按字母的可见字形做 vertical trim 并在浅灰底中垂直居中，不给单个字母额外的负字距。18pt 高的背景在字形上下留出空间，不能仅贴住字母轮廓。A、C、D 及其他类别使用同一个组件、同样的内边距和样式。日间底色为次要灰色 10% 不透明度，夜间为 24%，确保深色背景上能清楚看到标签底色；圆角为 3pt。

## 4. 第二行右侧：盈亏与百分比

- 盈亏金额在前，百分比块在后；两者相隔 4pt，并与左侧第二行视觉对齐。
- 盈亏金额使用 SF Rounded 14pt、medium、等宽数字；显示 `+` 或 `−` 方向及货币符号，常规值保留两位小数。百分比使用 12pt、semibold，保留一位小数；百分比块不重复显示前导 `+`，例如 `+$2,783.64  [18.1%]`。
- 百分比块水平内边距 5pt，最小高度 17pt，圆角 4pt。背景必须同时支持日夜模式。
- 盈利与亏损使用财务状态色。当前列表日间盈利文字 `#01B801`、背景 `#DCF7DC`；夜间盈利使用亮绿色，背景为同色约 18% 透明度。亏损文字使用红色，背景为红色约 18% 透明度；不能把日间浅绿块直接沿用到夜间。
- 盈亏周期由列表筛选设置决定（持有期或今日）。无可信数据时显示「暂无数据」，不把缺失值当作零收益。

## 5. 日夜模式与无障碍

- 日间所有承担“黑色主文字”角色的字统一用 `#1E1E20`；数量、代码、标签保留次要灰色，涨跌保留财务状态色。夜间主文字走系统动态主文字色。
- 夜间 Logo 外描边为白色 5% 不透明度；盈利百分比背景随夜间盈利绿动态变化。
- 系统辅助功能字号增大到无障碍级别时，cell 可改为上下堆叠结构，不强行维持 64pt 的双行横排。
- 视觉上使用 `K/M/B` 的股票数量，在朗读文本中仍应给出未缩写的两位小数；整行作为一个可访问对象读出名称、数量、代码、市值和盈亏。

## 6. 当前实现入口

| 规则 | 代码入口 |
| --- | --- |
| 标准 cell 布局、金额、盈亏、百分比 | [`PortfolioDetailsCard.swift`](../CatfolioIOS/CatfolioIOS/PortfolioDetailsCard.swift) 的 `HoldingRow` |
| 名称、公开披露清理、类别识别 | [`Models.swift`](../CatfolioIOS/CatfolioIOS/Models.swift) 的 `Holding`／`SecurityNameParts`；[`PublicInvestorCatalog.swift`](../CatfolioIOS/CatfolioIOS/PublicInvestorCatalog.swift) 的 `PublicDisclosureFormat` |
| 简称、数量与货币格式、颜色、Logo | [`DesignSystem.swift`](../CatfolioIOS/CatfolioIOS/DesignSystem.swift) 的 `CompanyNameCatalog`／`DisplayFormat`／`CatfolioTheme`／`AssetLogo` |
| 字号及字重 token | [`Typography.swift`](../CatfolioIOS/CatfolioIOS/Typography.swift) 的 `TypeScale` |
