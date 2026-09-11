# 板块轮动 v2

原生入口：收益表现 → 行情与 AI → 板块轮动；研究页也有入口。Web：`/rotation?ui=v5`（应用会自动规范化为 `/rotation`）。

采用 Figma `261:1860` 的紧凑四象限、周轨迹、时间回放结构。页面沿用已有共享组件；用中性背景和网格保持数字可读，不复制设计稿的装饰渐变或示例股票。默认显示 11 个 ETF、仅标注离中心最远的 4 个；点径 13pt、点击区域 44pt、选中显示轨迹、点击空白取消、原生长按显示精确值。列表可选择重叠点，图表不注册拖动手势，保留纵向滚动。

## 计算与数据

基准 SPY；XLK/XLF/XLE/XLV/XLY/XLP/XLI/XLB/XLU/XLRE/XLC。数据源为 Yahoo 日线 `indicators.adjclose`；禁止退回原始 close。每个标的保存最近 400 个有效交易日。先取 12 个标的共同交易日期，缺价日不生成快照、不向前填充。

`R = ln(ETF) - ln(SPY)`，`S = SMA5(R)`；`x_raw = S(t-21)-S(t-63)`，`y_raw = S(t)-S(t-21)`。各轴用 median/MAD（系数 1.4826）标准化，小于 `1e-8` 时归零；最终 `2.5*tanh(z/2)`。展示百分比使用 `expm1(raw)`，API 小数 `0.048` 表示 UI `+4.8%`。图心是当日 11 个板块中位数，不是 SPY 或零收益。

坐标与文字标签分离。中心双轴绝对值均小于 0.25 时立即中性；其他新象限连续 2 个真实交易日成立才切换。缺失交易日打断连续计数。初始化首个标签使用当前候选，之后按前述规则更新。

`sector_rotation.sqlite` 位于 `CATFOLIO_DATA_DIR`，默认仓库 `outputs/`。主键 `(calcVersion,date)`，快照从不更新；事务锁串行化写入。不在已发布时间段中补插遗漏日，以免改写后续标签历史。每周取过去 8 个**完整 ISO 周**的最后有效快照，再加当前点；当前周不重复入轨迹。所有坐标都读取同版本已保存快照。

初始化回填使用**回填时可取得**的复权价、仅使用观察日及以前价格；无法声称恢复了当年数据源实际发布的版本。返回 `backfilled` 和原始 `generatedAt`，UI 标识回填。首批 60 日开头可能不足 8 周轨迹，这会随着积累自然补齐。

## 独立批处理

```sh
v3_backend/.venv/bin/pip install -r v3_backend/requirements.txt
v3_backend/.venv/bin/python scripts/sector_rotation.py --backfill 60
v3_backend/.venv/bin/python scripts/sector_rotation.py --daily
v3_backend/.venv/bin/python scripts/sector_rotation.py --validate
v3_backend/.venv/bin/python scripts/sector_rotation.py --export /path/to/snapshot.json
v3_backend/.venv/bin/python scripts/sector_rotation.py --export-history CatfolioIOS/CatfolioIOS/Resources/sector_rotation_history.json
```

`--db` 可指定独立数据库。批处理不会被 API、账户同步或行情轮询触发。失败返回非零码，保留最后快照并记录运行状态。XNYS 日历负责节假日、提前收盘和夏令时；收盘后留 2.5 小时数据准备时间。

仓库提供 `deploy/sector-rotation/` 下 systemd service/timer 模板，固定 **23:45 UTC**（冬季英国 23:45，夏季英国次日 00:45），全年晚于数据准备时间与 22:30 GMT。部署时调整 `/opt/catfolio`、运行用户和数据目录，安装并启用 timer；**本次未部署服务或启用生产调度**。不要直接用 22:45 UTC：冬季纽约 16:00 为 UTC 21:00，尚未满足 2.5 小时窗口。假期、尚未就绪及已经完成的交易日由 `--daily` 跳过。失败后可手工重跑；缺价不会制造当日假快照。

## API 与 iOS

`GET /api/sector-rotation`；`GET /api/sector-rotation?asOf=YYYY-MM-DD` 读取当日或之前最近有效快照。日期列表只用于回放导航，轨迹不含所选日期之后的坐标。API 返回 `calcVersion=2`、纽约时区、原始生成时间、`stale`、`validUntil`、日期列表及 `sectors`。首次无数据返回 `status=unavailable`；有旧数据时继续返回旧快照并标记延迟。

原生只消费快照，不重新计算。随包提供此次真实 60 日回填用于离线回看；进入页面时读取文件缓存。右上角「快照数据源」可填写已部署的 HTTPS API；不预设未经确认的生产域名。新数据写入设备受保护缓存。离线超过下一交易日收盘加 2.5 小时的 `validUntil` 会显示更新延迟。生产 API 地址和调度部署仍需环境配置。

## 验证

后端测试：`PYTHONPATH=v3_backend python -m pytest v3_backend/tests/test_sector_rotation.py`。原生针对性测试：`CatfolioIOSTests/SectorRotationTests`。

诊断脚本输出每日截面相关性、最后一天相关性、平均绝对相关性及四象限占比；至少 60 日、最新绝对相关性和平均绝对相关性均 <0.3、每象限占比 >=10% 才通过。中性计入占比分母。不是要求每天相关性都低于 0.3，也不承诺非重叠窗口必然独立。未通过返回退出码 2，不自动调参数。

本次截至 2026-09-09 的 60 日回填：最新相关性 -0.12462，平均绝对相关性 0.25176；领先 29.24%、减弱 23.03%、落后 21.97%、改善 22.58%。此诊断不代表预测能力或样本外有效性。

参考：[Figma 节点](https://www.figma.com/design/EtNSXmasS8lz9JzrWUoMd9/Catfolio?node-id=261-1860)、[StockCharts 四象限交互](https://stockcharts.com/freecharts/rrg/)、[交易日历文档](https://github.com/gerrymanoim/exchange_calendars)。不使用 JdK RRG 计算，不生成交易建议或下单入口。

本次执行结果：后端 14 项、原生 5 项针对性测试通过，Xcode Simulator 编译通过；网页 390px 和 1280px 检查通过，原生模拟器已验证选择及回放。仓库全量本地化检查仍报告其他既有页面 6 条缺失（策略编曲家及 AnalystHistoryView）；本功能新增文案均已登记。


## iOS Figma 还原修订

Web 按后续指示保留；本次修订只涉及 iOS。原生页直接使用 Figma 背景节点 `261:2033` 导出的颜色与点阵资产 `RotationQuadrantBackground`，图宽高比 370:246、圆角 24、17pt 左对齐标题；播放区采用 50pt 灰底黑色按钮、39 根 4×52pt 刻度和黑色当前日期标记。方法、数据源放入菜单，板块列表改为选择菜单，详细信息只在选中时展开。

复杂部分改用 UIKit：`SectorRotationChartView` 负责背景、贝塞尔轨迹、点位、标签避让、最近点命中和长按；`SectorRotationTimelineControl` 是原生可访问 UIControl，负责拖动日期和 VoiceOver 增减日期。图表不注册拖动，长按移动容差为 8pt，并允许页面滚动手势同时识别；时间轴只有横向拖动才开始。

背景是静态设计资产，点、轨迹、标签和播放内容全部来自已有版本化快照；默认仍按 v2 仅画 11 个当前点和最外侧 4 个标签，选中后绘制该板块轨迹。白底留白与 Figma 一致，常驻相对位置说明和免责声明以小字保留。原数据计算和快照未更改。

2026-09-10 iOS 轨迹展示更新：按用户要求，默认展示最外侧 4 个已标注板块的真实周曲线；选中其他板块时叠加其轨迹并淡化背景轨迹。仍读取已有最多 8 周快照，不生成示例走势。

2026-09-10 iOS 矢量触感更新：背景点阵和板块节点改为 Core Graphics 矢量路径，点阵及节点高光使用 `CGBlendMode.overlay`。底色按 Figma 节点的圆形、渐变与模糊参数生成并缓存，不再从含点阵的 PNG 绘制。触摸处约 48pt 范围内的小点局部隆起，板块节点放大并向上抬起，松手以阻尼动画回落；定位环与历史曲线保持真实坐标。被动触摸观察器不阻止点击、长按或滚动，垂直移动超过 8pt 即交还页面；离开页面清除动画，减少动态效果开启时只改变高光。已通过 9 项原生测试，含触摸释放、导航清理与手势互不阻断检查，并保存静止/按下截图对照。

2026-09-10 Figma 色彩与字体校正：重新读取 `261:1860`、标题 `261:11791`、象限文字 `261:11625/11627/11631/11632` 和背景 `261:2033` 的实际属性与 SVG。标题为 17pt SF Pro Medium；象限为 11pt SF Pro Rounded Semibold、大写、0.55pt 字距、8pt cap-height，分别使用设计稿原始紫/绿/红/黄文字颜色。主轨迹采用稿内紫色 `#9E16B1`、绿色 `#1E7D00`、黄色 `#FFDC18`、红色 `#FF4141`，仍按板块固定映射。修正底色合成：`261:2034` 的 `#DFF4FF` 是 alpha 遮罩，底板应为 `261:2024` 的白色；Core Image 改为 sRGB 工作空间，点阵按原稿以不透明黑色进行 overlay，并补齐点阵上方的两片局部柔化色层。保持实时矢量点、触摸隆起与无箭头曲线。

2026-09-10 板块表现迁移（Figma `264:11960`）：将 Research 原有 11 个 SPDR 板块代理的表现网格移到轮动图与播放条下方。使用 `264:13509` 卡片的两列布局、12pt 间距、24pt 圆角、13pt/18pt 内边距、16pt ETF 代码及 17pt 名称/涨跌幅；复用现有矢量 SettingsChevron。移除重复页面内标题以对齐新稿。卡片和图点共用固定板块色，黄色卡使用黑字，其余白字，底色透明度 80%。原 Research 保留关键指标、持仓涨跌榜和轮动入口，停止重复请求板块历史。

数据仍由 `LocalMarketDataClient.historicalCloses` 的最近 14 天历史与本机缓存提供，沿用 `ResearchMarketSnapshot.changePercent` 的最近两个可用收盘价变化口径。先读缓存再刷新；空响应、单价响应及更旧响应不覆盖已有完整值。卡片展示最近收盘表现，不随轮动回放日期改写；独立标注真实数据日期/日期范围。点击卡片进入其收盘走势与相对趋势详情，显示各自日期。大字号切为单列并增高卡片。

2026-09-10 行业轨迹过冲修复：原 Catmull–Rom 连线可能在两个同侧周点之间额外穿轴（XLB，8 月 21 日至 28 日），或超过压缩坐标边界（XLU，8 月 7 日至 14 日）。现在对 x、y 分别使用保形三次 Hermite 插值：相邻同向变化取调和均值切线，局部极值和持平区间切线归零。共享端点切线保持一阶连续，贝塞尔控制点落在对应两个观察值的坐标范围内，因此整条曲线不会出现额外越界或穿轴。历史周点、当前点、百分比、快照、象限判定和触摸效果不变；仍无箭头。新增历史轨迹全覆盖检查，验证控制点边界、曲线单调性、端点一致和接缝连续，同时覆盖重复点及上述两例回归。

过冲修复验证：行业页 14 项及独立 StockCharts 页 5 项原生测试全部通过。历史覆盖检查遍历打包的 60 日全部板块轨迹，检查每段控制点凸包与曲线样本；XLB、XLU 的实际 UIKit 选中轨迹另经模拟器检查。iPhone 签名构建通过。
