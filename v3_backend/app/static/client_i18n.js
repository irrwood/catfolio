(function () {
  if (!document.documentElement.lang || !document.documentElement.lang.startsWith("en")) return;

  const exact = new Map(Object.entries({
    "未刷新": "-",
    "读取中": "Loading",
    "读取中...": "Loading...",
    "等待": "Waiting",
    "月": "Month",
    "年": "Year",
    "当月盈亏": "Monthly P/L",
    "全年盈亏": "Yearly P/L",
    "盈利天数": "Winning Days",
    "亏损天数": "Losing Days",
    "最大单日": "Best Day",
    "最差单日": "Worst Day",
    "AI 评价": "AI Evaluation",
    "AI 解读": "AI Analysis",
    "关闭假数据": "Turn Off Demo Data",
    "开启假数据": "Turn On Demo Data",
    "当前：已开启 — 显示样例数据": "Current: On - showing sample data",
    "当前：已关闭 — 显示真实数据": "Current: Off - showing real data",
    "已配置": "Configured",
    "未配置": "Not configured",
    "已设置": "Configured",
    "已保存": "Saved",
    "已切换": "Switched",
    "失败": "Failed",
    "未知错误": "Unknown error",
    "消息已发送！": "Message sent.",
    "正在同步 Trading 212 持仓...": "Syncing Trading 212 holdings...",
    "Trading 212 同步完成！": "Trading 212 sync complete.",
    "同步失败，请检查 API Key。": "Sync failed. Check the API key.",
    "正在同步 Trading 212 持仓…": "Syncing Trading 212 holdings…",
    "正在刷新实时行情…": "Refreshing live quotes…",
    "正在刷新历史价格…": "Refreshing price history…",
    "正在刷新估值数据…": "Refreshing valuation data…",
    "全部组合数据已刷新。": "All portfolio data refreshed.",
    "正在强制拉取最新行情...": "Fetching latest quotes...",
    "行情刷新完成！": "Quote refresh complete.",
    "正在重新获取所有标的历史价格...": "Refreshing all historical prices...",
    "历史价格刷新完成！": "Historical prices refreshed.",
    "正在重新拉取 FMP 估值数据...": "Refreshing FMP valuation data...",
    "估值数据刷新完成！": "Valuation data refreshed.",
    "正在拉取 Massive 盘后数据...": "Fetching Massive after-hours data...",
    "盘后数据刷新完成！": "After-hours data refreshed.",
    "刷新失败。": "Refresh failed.",
    "正在读取历史价格和分析结果...": "Reading historical prices and analytics...",
    "正在刷新历史价格...": "Refreshing historical prices...",
    "暂无可用 P/E 数据。先刷新估值数据源。": "No P/E data available. Refresh valuation data first.",
    "等待基准...": "Waiting for benchmark...",
    "等待持仓...": "Waiting for holdings...",
    "等待涨跌分布...": "Waiting for breadth...",
    "基准数据不足": "Insufficient benchmark data",
    "直接持仓": "Direct holding",
    "直接持仓 + ETF": "Direct holding + ETF",
    "ETF 穿透": "ETF look-through",
    "P/E 和成长率需要 fundamentals API": "P/E and growth require the fundamentals API",
    "估值数据还没更新": "Valuation data has not been updated",
    "刷新 fundamentals 后会显示 P/E、成长率和仓位气泡": "Refresh fundamentals to show P/E, growth, and position-weight bubbles",
    "现金流镜像 · 等待日期流水": "Cash-flow mirror · waiting for dated transactions",
    "需要入金 / 出金日期": "Deposit / withdrawal dates required",
    "现金流镜像需要逐日现金流流水，当前只能看到汇总金额。": "Cash-flow mirror requires daily cash-flow transactions; only summary amounts are currently available.",
    "剔除现金流影响，用于衡量策略本身表现。": "Removes cash-flow effects to measure strategy performance.",
    "复制你的真实入金出金节奏，用于比较真实账户表现。": "Replays your actual cash-flow timing to compare real-account performance.",
    "Return分布 days历": "Return Distribution Calendar",
    "Daily P/L · 月 / 年 视图": "Daily P/L · Month / Year View",
    "真实Account · 美元浮盈（Cost vs Current Price）": "Real Account · USD Unrealized P/L (Cost vs Current Price)",
    "Model Basis · 当月WeightReturn%（非真实盈亏）": "Model Basis · Current-Month Weighted Return % (not real P/L)"
  }));

  const fragments = [
    [" 个交易日", " trading days"],
    [" 个持仓", " holdings"],
    [" 持仓", " holdings"],
    [" 行情", " quotes"],
    [" 今日", " today"],
    [" 总收益率", " total return"],
    [" 上涨 ", " up "],
    [" 下跌 ", " down "],
    [" 天收跌", " down days"],
    [" 日均 ", " mean "],
    [" 天", " days"],
    [" 年 ", " "],
    ["一月", "January"],
    ["二月", "February"],
    ["三月", "March"],
    ["四月", "April"],
    ["五月", "May"],
    ["六月", "June"],
    ["七月", "July"],
    ["八月", "August"],
    ["九月", "September"],
    ["十月", "October"],
    ["十一月", "November"],
    ["十二月", "December"],
    ["低点", "Low"],
    ["现价", "Current"],
    ["高点", "High"],
    ["位置", "Position"],
    ["离高点", "From high"],
    ["基准", "Benchmark"],
    ["仓位", "Weight"],
    ["EPS 成长", "EPS growth"],
    ["营收成长", "Revenue growth"],
    ["成长率", "Growth"],
    ["P/E 倍数", "P/E multiple"],
    ["盈利Days", "Winning Days"],
    ["亏损Days", "Losing Days"],
    ["最大单 days", "Best Day"],
    ["最差单 days", "Worst Day"]
  ];

  function translateText(value) {
    if (!value || !/[\u4e00-\u9fff]/.test(value)) return value;
    const trimmed = value.trim();
    if (exact.has(trimmed)) return value.replace(trimmed, exact.get(trimmed));
    let out = value;
    exact.forEach((en, zh) => {
      if (zh && out.includes(zh)) out = out.split(zh).join(en);
    });
    fragments.forEach(([zh, en]) => {
      if (out.includes(zh)) out = out.split(zh).join(en);
    });
    return out;
  }

  function translateNode(root) {
    if (!root || root.nodeType === 8) return;
    if (root.nodeType === 3) {
      const next = translateText(root.nodeValue);
      if (next !== root.nodeValue) root.nodeValue = next;
      return;
    }
    if (root.nodeType !== 1) return;
    if (root.matches && root.matches("script,style,code,pre,textarea")) return;
    ["title", "placeholder", "aria-label"].forEach((attr) => {
      if (root.hasAttribute && root.hasAttribute(attr)) {
        const value = root.getAttribute(attr);
        const next = translateText(value);
        if (next !== value) root.setAttribute(attr, next);
      }
    });
    if (root.matches && root.matches("input")) return;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const parent = node.parentElement;
        if (parent && parent.matches("script,style,code,pre,textarea,input")) return NodeFilter.FILTER_REJECT;
        return /[\u4e00-\u9fff]/.test(node.nodeValue || "") ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP;
      }
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(translateNode);
  }

  translateNode(document.body);
  const observer = new MutationObserver((mutations) => {
    mutations.forEach((mutation) => {
      mutation.addedNodes.forEach(translateNode);
      if (mutation.type === "characterData") translateNode(mutation.target);
    });
  });
  observer.observe(document.body, { childList: true, subtree: true, characterData: true });
})();
