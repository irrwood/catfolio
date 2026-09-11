# iOS 与桌面分析师历史回顾

已从苹果专用 demo 改成按 ticker 读取同一份 `analyst_history_catalog.json`。
桌面入口：Portfolio 个股名称/代码。iOS 入口：持仓详情 → 分析师历史回顾，独立于最新评级请求，离线可打开。

2026-09-09 覆盖本次桌面持仓的 78 个证券：73 个有目标价与股价，74 个有评级（NTDOY 仅评级），VUSA / ASMLA / RR / XS2D 暂不支持上市市场。没有用美国同名 ticker 替换非美元证券。任天堂 OTC 上市位置经原站 forecast 页核对。

抓取工具：`core/tools/collect_portfolio_analyst_history.py`。输入持仓 JSON 的 rows 与公司参考目录，根据已知交易所请求公开图表，串行限速，失败保留状态，不绕过登录或访问限制。原 HTML、两个 CSV 与 SHA256 保存在 T7 `core/storage/price-target-history/portfolio-20260909/`。整理目录复制为 iOS 资源，桌面也只读该文件。新增持仓仍需要采集并更新目录；尚无自动刷新服务。

无效目标价区间按月份置空，不修正数值；股价与有效评级仍保留。缺价格的评级保留，价格为 null，不填零；按日期标签精确关联。原生曲线在目标价/价格缺失处按独立序列断开，桌面使用 null 断线。每月评级是对应过去一年分布，不是当月新增；来源月度股价不是当天收盘价。时间与复权口径未确认，不用于预测准确率。

原生 Swift Charts 支持目标价上下区间、共识与股价折线、评级堆叠柱及双轴股价；1 年／2 年／全部、长按选择与文本明细。双轴内部按独立上限归一化，标签还原数量和 USD。

验证：9 项相关测试通过；78 个 symbol 的 API 与各自源记录长度、价格身份核对；真机包目录与工作区目录一致；真机 Debug 编译通过，已安装并启动于连接的 iPhone。浏览器实测 META 双图、NTDOY 仅评级状态。覆盖统计见 analyst-history-coverage.json。
