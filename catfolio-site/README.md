# Catfolio 官网

以 Atlas 官网为视觉参考的独立静态官网。保留 Catfolio 品牌、原生 App 截图和本地字体，无外部运行依赖。

本地预览：`python3 -m http.server 4318 --bind 127.0.0.1 --directory catfolio-site`（从仓库根目录运行）。当前未部署，下载按钮显示发布状态，尚未配置 App Store / TestFlight 地址。

## 2026-09-13 更新

- 全部在用 App 截图更新为本次工作区构建的原生版本，存放于 `assets/refresh/`。旧 `assets/features/` 图片保留归档，页面已不再引用。
- 共 38 个功能与交互条目：交互 3、账户与持仓 10、收益与分析 9、研究与 AI 11、模拟与设置 5。每项都配有独立截图。
- 新增「手指里的细节」专区，可切换双指区间、单指单日、立体热力图和展开热力图四个原生截图状态。
- 「最近更新」突出市场 / 板块轮动、策略编曲家、收益来源、收入构成、内部人士交易和分析师历史回顾。
- 历史中的交易、分红、利息与基金费用，以及货币选择，都有各自截图。
- 税务计算、拍照导入在本次构建仍 disabled；税损模拟尚未实现，保留待开放说明。

## 内容维护

`features.json` 是功能图库内容来源，每项记录图文、截图路径与拍摄日期。修改后运行：

```sh
python3 catfolio-site/render_features.py
```

脚本验证唯一 ID 和图片路径，然后替换 `index.html` 中标记的静态图库，同步功能总数。网站无需 JavaScript 也能显示完整图文；JavaScript 提供分类筛选、弹窗与交互截图切换。

## 截图来源和边界

在独立 iPhone 17 Pro / iOS 26.5 模拟器中构建并安装当前 CatfolioIOS 工作区。截图统一 1206 × 2622、状态栏 9:41，浅色模式；AI 助手按其当前原生外观展示。

组合、账户、买卖、分红、利息与费用使用 App 内置的完全虚构测试组合，没有使用个人券商账户或凭据。研究页包含 App 可用的公开数据与本地快照；拍摄日期不代表行情日期。不同曲线、报价与持仓快照可能有不同的更新时间。

- 双指 / 单指截图通过原生预览参数进入选中状态，展示真实组件，不是手工合成；网页按钮仅切换截图。
- 市场 RRG 来自 StockCharts 快照；板块轮动使用独立的相对强弱 / 动量算法，截图保留更新延迟提示。
- ORCL 财务来自 App 的 SEC / Nasdaq 路径；收入构成使用 FMP 年度快照，报告期可能不一致。
- OI 为 ORCL 期权链界面，替换旧布局测试图；财务也已替换旧测试样本图。
- 分析师历史采用本地月度快照。内部人士交易过滤依赖公开披露及规则识别。
- 行情解读纸张（daily-brief）未能取得正文，真实记录为重试状态，并在卡片中明确说明。
- 收益来源图以当前股数回推市值，不包含已卖出持仓，不作为完整交易归因。
- 分红 / 利息是已导入流水汇总；基金费用是当前市值乘年费率估算，不是实际扣款。

主要核对源：`ReturnsView.swift`、`StandardLineChart.swift`、`HoldingContributionChart.swift`、`PerformanceHeatmapHero.swift`、`VolumeProfileView.swift`、`SettingsView.swift`，以及策略、内部人士交易和财务相关实现。此次仅修改官网，未修改原生 App 和金融计算。

## 验证

本次原生构建成功。官网验证覆盖静态图文及图片路径、分类计数、四种交互截图状态、截图放大 / 前后切换 / 方向键 / Escape、筛选后的锚点定位、桌面及手机布局；JavaScript 语法检查通过。

新增「汇率自动更新」独立条目及跨市场专区介绍：依据 APIClient 的组合加载路径与 LocalCurrentFXRefresh，非演示且有持仓时自动请求最近可用收盘汇率，30 分钟节流；缓存日期并提供离线估值。配图复用本次设置页截图，明确为演示模式未更新状态。

安全专区：强调本地账本和组合计算、用户自行配置、只读连接、Keychain 凭证存储、无交易或转账入口。没有宣称所有功能离线或所有已有凭据必然无写权限；建议专用只读凭据，并说明外部行情、可选远程 AI 和偏好同步范围。iOS 独立运行无需自建常驻服务器。核对 CatfolioIOS/README.md、Trading212View.swift 及原生连接 / 计算路径。

强化已有今日收益模块：新增 today-returns 专区，说明首页盈亏金额 / 涨跌幅、上涨与下跌贡献切换、行业归因与市场基准，用于辅助判断。复用本次 today.png；保留当前持仓与最近报价估算、未计入今日交易的口径说明，功能总数仍为 35。

新增 Portfolio X-Ray / 组合透视：以现有今日行业贡献能力为依据，展示行业盈亏、行业内持仓、贡献与拖累。配图复用行业分析 today.png，明确今日口径，未宣称任意历史周期归因。

新增财报电话会 / 管理层兑现追踪专区及独立图库条目，核对 ManagementDeliveryView.swift 和 docs/ios-management-delivery.md。4 / 6 / 8 季度、承诺原话、期限、后续结果与来源、四种核对状态；准确说明用户发起和按需刷新、本机分析及 iOS 26 / Apple Intelligence / FMP 前提。management-delivery.png 来自本次成功构建的独立演示模拟器，展示展开的入口，不是分析结果；未调用用户凭据或生成真实报告。

强化已有收益来源功能为「收益来源 · 胜利复盘」，新增 returns-review 专区，复用 contributors.png，展示盈利贡献、时间变化及图例聚焦。依据 HoldingContributionChart.swift 保留当前股数回推、不含已卖出持仓及亏损抵扣本金层的说明，不宣称自动判断投资决策对错。条目数保持 37。

新增个股账户对比专区及图库条目：全部合并、单账户独立查看、多选汇总，成本与买卖标记联动。核对 VolumeProfileView.swift 的账户选择和有效持仓路径；在独立演示模拟器重新拍摄 account-combined.png 与 account-single.png，实际验证取消美股账户后股数由 32.8656 变为 16.9995、成本线随全球账户更新。

依据用户提供的产品信息新增「丰富的系统小组件」文字专区和导航，主文案为「把投资，放在主屏幕上」。当前工作区未找到 WidgetKit 扩展或小组件截图，因此未编造具体类型、刷新频率、锁屏支持或界面；等待新版代码 / 真实截图来源，不计入 38 项截图图库。

按用户提供的产品信息，将分红条目扩充为「股息计算与预测」，同步历史专区。当前工作区可核对历史汇总，未找到预测实现，因此不描述预测算法、期限或具体指标；沿用 dividends.png 并明确为历史记录截图，预测界面尚待补充。

按用户要求，在待开放功能区新增「连接 2000+ 家券商与金融机构」，明确标注 Coming soon · 即将推出；不计入当前可用截图图库，具体机构和地区以正式上线为准。

依据用户提供的产品信息，补充自行配置券商 / 账户连接数量不限、全部账户统一监控分析，新增 all-accounts 专区并更新账户管理卡片。明确数量不限适用于已支持接入方式，与 Coming soon 的 2000+ 机构覆盖计划分开；图库仍为 38 项。

按用户提供的费用政策新增「连接你自己的 AI」专区并更新 AI 卡片：Catfolio 不额外收取 AI 接入费，第三方订阅 / 用量费另按服务计费。以自主选择与授权、明确本地和远程数据范围表达安全，不承诺远程服务零风险或完全免费。

## English website

`en.html` is the complete English edition, sharing the Chinese page's layout, styles, images, and interactions. The header switches languages and retains the current section. Metadata, accessibility labels, 38 feature cards, dialogs, filters, and interaction captions are translated. Screenshots retain the Chinese app interface, disclosed in the English gallery introduction.

Maintain page copy in `translations.en.json` and feature copy in `features.en.json`. Run `python3 catfolio-site/render_features.py` to regenerate both languages; `render_english.py` rejects missing translations, mismatched feature IDs, and unexpected untranslated Chinese. New Chinese content needs a corresponding English translation.

Verified English/Chinese switching with section retention, category counts, screenshot dialog, interaction captions, download dialog, and desktop/390px mobile layouts without horizontal overflow. Local asset/link checks and JavaScript syntax check pass. No external deployment performed.

新增中英文「投资管理 · 金融学习」专区，定位为结合持仓、图表、复盘和 AI 问答的使用中学习，连接收益来源、个股研究、组合透视和自有 AI 四个现有章节；未宣称独立课程或学习进度系统。
