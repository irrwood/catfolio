    const heatmap = document.querySelector("#heatmap");
    const statusEl = document.querySelector("#status");
    const isEnglish = () => (document.documentElement.lang || "").startsWith("en");
    const EN = {
      "无估值": "No valuation",
      "刚才": "just now",
      "分钟前": " min ago",
      "小时前": " hr ago",
      "高估": "Premium",
      "低估": "Discount",
      "估值 P/E": "Valuation P/E",
      "浮动盈亏 %": "Unrealized P/L %",
      "浮动盈亏, %": "Unrealized P/L, %",
      "相对成交量": "Relative Volume",
      "相对成交量(量/均量)": "Relative Volume (volume/average)",
      "涨跌1天, %": "Change 1D, %",
      "今日涨跌 %": "Today Change %",
      "板块": "Sector",
      "仓位": "Weight",
      "今日": "Today",
      "估值更新": "Valuation Updated",
      "市值": "Market Value",
      "浮盈亏": "Unrealized P/L",
      "成本": "Cost",
      "现价": "Current Price",
      "来源": "Source",
      "全部来自 ETF": "All from ETF",
      "含 ETF": "Includes ETF",
      "历史表现": "Historical Performance",
      "持仓数": "Holdings",
      "总市值": "Total Market Value",
      "今日盈亏": "Today's P/L",
      "涨跌比": "Advance/Decline",
      "日涨跌%": "Daily Change %",
      "ETF穿透": "ETF Look-Through",
      "已开启": "On",
      "关闭": "Off",
      "ETF穿透板块": "ETF Look-Through",
      "图表库加载失败": "Chart library failed to load",
      "按板块": "By Sector",
      "按大小": "By Size",
      "成交量1天": "Volume 1D",
      "成交额1天": "Turnover 1D",
      "相同大小": "Equal Size",
      "涨跌1周, %": "Change 1W, %",
      "涨跌1月, %": "Change 1M, %",
      "涨跌3月, %": "Change 3M, %",
      "涨跌6月, %": "Change 6M, %",
      "今年以来 YTD, %": "YTD Change, %",
      "涨跌1年, %": "Change 1Y, %",
      "代码": "Ticker",
      "Logo + 代码": "Logo + Ticker",
      "中文": "Chinese",
      "英文": "English",
      "隐藏": "Hidden",
      "已就绪": "Ready",
      "已更新": "Updated",
      "ETF已穿透": "ETF look-through enabled",
      "没有持仓热力图数据": "No holdings heatmap data",
      "没有可用数据": "No available data",
      "刷新行情": "Refresh Quotes",
      "刷新估值": "Refresh Valuation",
      "同步持仓": "Sync Holdings",
      "中...": "...",
      "失败：": " failed: ",
      "加载失败：": "Load failed: ",
    };
    const tr = (value) => isEnglish() ? (EN[value] || value) : value;
    let statusTimeout = null;
    function setStatus(html, autoHide = false) {
      if (statusTimeout) { clearTimeout(statusTimeout); statusTimeout = null; }
      statusEl.style.display = "inline-flex";
      statusEl.style.opacity = "1";
      statusEl.style.transition = "none";
      statusEl.innerHTML = html;
      if (autoHide) {
        statusTimeout = setTimeout(() => {
          statusEl.style.transition = "opacity 0.5s ease";
          statusEl.style.opacity = "0";
          statusTimeout = setTimeout(() => {
            statusEl.style.display = "none";
          }, 500);
        }, 1500);
      }
    }
    const hoverCard = document.querySelector("#hoverCard");
    const layoutTrigger = document.querySelector("#layoutTrigger");
    const layoutMenu = document.querySelector("#layoutMenu");
    const layoutLabel = document.querySelector("#layoutLabel");
    const currencyTrigger = document.querySelector("#currencyTrigger");
    const currencyMenu = document.querySelector("#currencyMenu");
    const currencyLabel = document.querySelector("#currencyLabel");
    const colorTrigger = document.querySelector("#colorTrigger");
    const colorMenu = document.querySelector("#colorMenu");
    const colorLabel = document.querySelector("#colorLabel");
    const sizeTrigger = document.querySelector("#sizeTrigger");
    const sizeMenu = document.querySelector("#sizeMenu");
    const sizeLabel = document.querySelector("#sizeLabel");
    const nameTrigger = document.querySelector("#nameTrigger");
    const nameMenu = document.querySelector("#nameMenu");
    const nameLabel = document.querySelector("#nameLabel");
    const rawHoldingsBtn = document.querySelector("#rawHoldingsBtn");
    const etfUnwrapBtn = document.querySelector("#etfUnwrapBtn");
    const fullscreenBtn = document.querySelector("#fullscreenBtn");
    const refreshMarketButton = document.querySelector("#refreshMarket");
    const refreshValuationButton = document.querySelector("#refreshValuation");
    const refreshHoldingsButton = document.querySelector("#refreshHoldings");
    const legendBar = document.querySelector("#legendBar");
    const legendLabels = document.querySelector("#legendLabels");
    const legendNote = document.querySelector("#legendNote");
    let heatmapChart = null;
    let currentRows = [];
    let layoutMode = "size";
    let currencyMode = "USD";
    let colorMode = "day";
    let sizeMode_value = "marketcap";
    let nameMode = "ticker";
    let etfUnwrap = false;
    let rawRows = [];
    let lookthroughData = null;
    let isFullscreen = false;
    if (localStorage.getItem("theme") === "light") {
      document.documentElement.classList.add("light-theme");
    }
    const layoutLabels = { size: "按大小", sector: "按板块" };
    const sizeLabels = { marketcap: "市值", equal: "相同大小", vol1d: "成交量1天", turnover1d: "成交额1天" };
    const colorLabels = {
      day: "涨跌1天, %",
      week: "涨跌1周, %",
      month: "涨跌1月, %",
      quarter: "涨跌3月, %",
      halfyear: "涨跌6月, %",
      ytd: "今年以来 YTD, %",
      year: "涨跌1年, %",
      valuation: "估值 P/E",
      pnl: "浮动盈亏, %",
      relvolume: "相对成交量",
    };
    const nameLabels = { ticker: "代码", logo: "Logo + 代码" };
    const SECTOR_ZH = {
      "Technology": "科技",
      "Communication Services": "通信服务",
      "Financials": "金融",
      "Consumer Cyclical": "可选消费",
      "Consumer Defensive": "必选消费",
      "Healthcare": "医疗健康",
      "Industrials": "工业",
      "Energy": "能源",
      "Utilities": "公用事业",
      "Real Estate": "房地产",
      "Basic Materials": "基础材料",
      "ETF / S&P 500": "ETF / 标普 500",
      "ETF / Multi-Asset": "ETF / 多资产",
      "Other / Unclassified": "其他 / 未分类",
      "Other": "其他",
    };
    const localizedSector = value => isEnglish() ? value : (SECTOR_ZH[value] || value);
    function cssVar(name) {
      return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
    }
    function htmlEscape(str) {
      if (!str) return "";
      return str.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#039;");
    }
    function fmtPct(val) { return `${(Number(val || 0) * 100).toFixed(2)}%`; }
    function fmtDay(val) { const num = Number(val || 0); return `${num >= 0 ? "+" : ""}${num.toFixed(2)}%`; }
    function fmtMoney(val) {
      const rate = currencyMode === "GBP" ? 1.0 / 1.3460 : 1.0;
      const prefix = currencyMode === "GBP" ? "£" : "$";
      return `${prefix}${Number((val || 0) * rate).toLocaleString("en-GB", { maximumFractionDigits: 0 })}`;
    }
    const fmtRatio = val => val === null || val === undefined ? "—" : val.toFixed(1);
    const fmtNum = val => val === null || val === undefined ? "—" : Number(val).toFixed(2);
    function fmtAge(unix) {
      if (!unix) return tr("无估值");
      const seconds = Math.floor(Date.now() / 1000 - Number(unix));
      if (seconds < 60) return tr("刚才");
      if (seconds < 3600) return isEnglish() ? `${Math.floor(seconds / 60)}${tr("分钟前")}` : `${Math.floor(seconds / 60)}分钟前`;
      return isEnglish() ? `${Math.floor(seconds / 3600)}${tr("小时前")}` : `${Math.floor(seconds / 3600)}小时前`;
    }
    function colorMetric(row) {
      if (colorMode === "valuation") { const pe = valuationPe(row); if (pe === null) return 0; return pe > 22 ? -1.5 : 1.5; }
      if (colorMode === "pnl") { return row.unrealized_percent === null ? 0 : Number(row.unrealized_percent); }
      if (colorMode === "relvolume") { const vol = Number(row.volume || 0); const avg = Number(row.avg_volume_3m || 1); return avg > 0 ? (vol / avg - 1) : 0; }
      if (colorMode === "week") { return row.return_1w === null || row.return_1w === undefined ? 0 : Number(row.return_1w); }
      if (colorMode === "month") { return row.return_1m === null || row.return_1m === undefined ? 0 : Number(row.return_1m); }
      if (colorMode === "quarter") { return row.return_3m === null || row.return_3m === undefined ? 0 : Number(row.return_3m); }
      if (colorMode === "halfyear") { return row.return_6m === null || row.return_6m === undefined ? 0 : Number(row.return_6m); }
      if (colorMode === "ytd") { return row.return_ytd === null || row.return_ytd === undefined ? 0 : Number(row.return_ytd); }
      if (colorMode === "year") { return row.return_1y === null || row.return_1y === undefined ? 0 : Number(row.return_1y); }
      return row.today_change_percent === null ? 0 : Number(row.today_change_percent);
    }
    function colorMetricLimit() {
      if (colorMode === "valuation") return 2;
      if (colorMode === "pnl") return 20;
      if (colorMode === "relvolume") return 1.5;
      if (colorMode === "week") return 5;
      if (colorMode === "month") return 10;
      if (colorMode === "quarter") return 15;
      if (colorMode === "halfyear") return 20;
      if (colorMode === "ytd") return 25;
      if (colorMode === "year") return 30;
      return 2;
    }
    const FIGMA_HEAT_PALETTE = {
      positive: ["#ffffff", "#edffe0", "#d0f6b7", "#a6e585", "#89d663"],
      negative: ["#ffffff", "#ffeff1", "#ffd3d9", "#ff97a8", "#ff889e"],
    };
    const DARK_HEAT_PALETTE = {
      positive: ["#111713", "#17331d", "#205329", "#2b7436", "#389547"],
      negative: ["#191315", "#35191f", "#57232d", "#78303e", "#963d4d"],
    };
    function paletteColor(amount, colors) {
      const value = Math.max(0, Math.min(1, amount));
      const index = value <= 0.025 ? 0 : value < 0.18 ? 1 : value < 0.42 ? 2 : value < 0.72 ? 3 : 4;
      return colors[index];
    }
    function heatColor(val, limit) {
      const t = Math.max(-1, Math.min(1, Number(val || 0) / Math.max(limit, 0.001)));
      const palette = isDarkMode() ? DARK_HEAT_PALETTE : FIGMA_HEAT_PALETTE;
      if (colorMode === "valuation") return t >= 0 ? palette.positive[4] : palette.negative[4];
      return t >= 0
        ? paletteColor(t, palette.positive)
        : paletteColor(Math.abs(t), palette.negative);
    }
    function valuationPe(row) { const pe = Number(row.trailing_pe || 0); if (pe > 0 && pe < 300) return pe; return null; }
    function metricLabel(row) {
      if (colorMode === "valuation") { const pe = valuationPe(row); return pe === null ? "P/E —" : `P/E ${pe.toFixed(1)}`; }
      if (colorMode === "pnl") { const val = row.unrealized_percent; return val === null ? "—" : `${val >= 0 ? "+" : ""}${Number(val).toFixed(1)}%`; }
      if (colorMode === "relvolume") { const vol = Number(row.volume||0); const avg = Number(row.avg_volume_3m||1); const rv = avg>0 ? vol/avg : 0; return `Vol ${rv.toFixed(1)}x`; }
      let val = null;
      if (colorMode === "week") val = row.return_1w;
      else if (colorMode === "month") val = row.return_1m;
      else if (colorMode === "quarter") val = row.return_3m;
      else if (colorMode === "halfyear") val = row.return_6m;
      else if (colorMode === "ytd") val = row.return_ytd;
      else if (colorMode === "year") val = row.return_1y;
      else val = row.today_change_percent;
      return val === null || val === undefined ? "—" : `${val >= 0 ? "+" : ""}${Number(val).toFixed(2)}%`;
    }
    function labelCompanyName(row) {
      if (nameMode === "hidden") return "";
      const display = row.display_name || row.name || "";
      if (nameMode === "en") return row.name || "";
      return display;
    }
    function groupRows(rows) {
      const map = {};
      rows.forEach(row => { const sector = row.sector || "Other"; if (!map[sector]) map[sector] = []; map[sector].push(row); });
      return Object.entries(map).map(([sector, list]) => {
        const totalValue = list.reduce((sum, r) => sum + Number(r.market_value_usd || 0), 0) || 1;
        const weightedChange = list.reduce((sum, r) => sum + Number(r.today_change_percent || 0) * Number(r.market_value_usd || 0), 0) / totalValue;
        const weightedPnl = list.reduce((sum, r) => sum + Number(r.unrealized_percent || 0) * Number(r.market_value_usd || 0), 0) / totalValue;
        
        let targetKey = "today_change_percent";
        if (colorMode === "week") targetKey = "return_1w";
        else if (colorMode === "month") targetKey = "return_1m";
        else if (colorMode === "quarter") targetKey = "return_3m";
        else if (colorMode === "halfyear") targetKey = "return_6m";
        else if (colorMode === "ytd") targetKey = "return_ytd";
        else if (colorMode === "year") targetKey = "return_1y";
        
        const weightedValue = list.reduce((sum, r) => sum + Number(r[targetKey] || 0) * Number(r.market_value_usd || 0), 0) / totalValue;
        let peWeightSum = 0, peValueSum = 0;
        list.forEach(r => { const pe = valuationPe(r); if (pe !== null) { peValueSum += pe * Number(r.market_value_usd || 0); peWeightSum += Number(r.market_value_usd || 0); } });
        const weightedPe = peWeightSum > 0 ? peValueSum / peWeightSum : null;
        const count = list.length;
        return { sector, holdings: list, weightedChange, weightedPnl, weightedValue, weightedPe, count };
      }).sort((a, b) => b.holdings.reduce((s, r) => s + Number(r.market_value_usd || 0), 0) - a.holdings.reduce((s, r) => s + Number(r.market_value_usd || 0), 0));
    }
    function labelSize(row) {
      if (sizeMode_value === "equal") {
        return { fontSize: 10, lineHeight: 12 };
      }
      const pct = Number(row.weight || 0) * 100;
      if (pct >= 20) return { fontSize: 18, lineHeight: 24 };
      if (pct >= 10) return { fontSize: 17, lineHeight: 22 };
      if (pct >= 5) return { fontSize: 16, lineHeight: 21 };
      if (pct >= 2) return { fontSize: 13, lineHeight: 17 };
      if (pct >= 1) return { fontSize: 10, lineHeight: 13 };
      if (pct >= 0.5) return { fontSize: 8, lineHeight: 10 };
      return { fontSize: 6, lineHeight: 8 };
    }
    function isDarkMode() {
      return !document.documentElement.classList.contains("light-theme");
    }
    function labelColor() {
      return cssVar("--ink") || (isDarkMode() ? "#ededef" : "#000000");
    }
    function metricLabelColor() {
      return isDarkMode() ? "rgba(255, 255, 255, 0.56)" : "rgba(0, 0, 0, 0.5)";
    }
    function assetLogoUrl(row) {
      const symbol = String(row.logo_symbol || row.ticker || "").trim();
      return symbol ? `/api/asset-logo/${encodeURIComponent(symbol)}` : "";
    }
    function leafNode(row) {
      const metric = colorMetric(row);
      const size = labelSize(row);
      const lc = labelColor();
      let value;
      if (sizeMode_value === "equal") value = 1;
      else if (sizeMode_value === "vol1d") value = Math.max(Number(row.volume || 0), 1);
      else if (sizeMode_value === "turnover1d") value = Math.max(Number(row.volume || 0) * Number(row.quote_price || row.avg_cost_usd || 1), 1);
      else if (sizeMode_value === "marketcap") value = Math.max(Number(row.market_value_usd || 0), 1);
      else value = Math.max(Number(row.market_value_usd || 0), 1);
      const pct = Number(row.weight || 0) * 100;
      const inset = pct >= 2 ? 16 : pct >= 1 ? 10 : pct >= 0.5 ? 6 : 4;
      const logoSize = pct >= 5 ? 30 : pct >= 2 ? 26 : 22;
      const logoUrl = nameMode === "logo" ? assetLogoUrl(row) : "";
      return {
        name: row.ticker,
        value,
        raw: row,
        itemStyle: {
          color: heatColor(metric, colorMetricLimit()),
          borderColor: "transparent",
          borderWidth: 0,
          gapWidth: 4,
          borderRadius: 8,
          shadowBlur: 0,
          shadowColor: "transparent",
        },
        label: {
          show: true, color: lc, position: "insideTopLeft", align: "left", verticalAlign: "top",
          padding: [inset, inset, 0, inset], overflow: "truncate",
          formatter: params => {
            const item = params.data.raw || {};
            const itemPct = Number(item.weight || 0) * 100;
            if (itemPct < 0.12) return "";
            if (itemPct < 0.35) return `{ticker|${item.ticker || ""}}`;
            if (nameMode === "logo" && itemPct >= 0.5 && logoUrl) {
              return `{logo| }\n{ticker|${item.ticker || ""}}\n{metric|${metricLabel(item)}}`;
            }
            return `{ticker|${item.ticker || ""}}\n{metric|${metricLabel(item)}}`;
          },
          rich: {
            logo: {
              width: logoSize,
              height: logoSize,
              borderRadius: Math.ceil(logoSize / 2),
              backgroundColor: logoUrl ? { image: logoUrl } : "transparent",
            },
            ticker: { color: lc, fontWeight: 700, fontSize: size.fontSize, lineHeight: size.lineHeight },
            metric: {
              color: metricLabelColor(),
              fontWeight: 600,
              fontSize: Math.max(6, size.fontSize - 2),
              lineHeight: Math.max(8, size.lineHeight - 2),
            },
          },
        },
        emphasis: { itemStyle: { shadowBlur: 0, shadowColor: "transparent" }, label: { color: lc } },
      };
    }
    function buildSizeData(rows) {
      return rows.sort((a, b) => Number(b.market_value_usd || 0) - Number(a.market_value_usd || 0)).map(row => leafNode(row));
    }
    function buildSectorData(rows) {
      return groupRows(rows).map(group => {
        const children = group.holdings.map(leafNode);
        const childrenSum = children.reduce((sum, child) => sum + child.value, 0);
        const holdingsLabel = isEnglish() ? `${group.count} holdings` : `${group.count}只`;
        const groupValue = fmtMoney(group.holdings.reduce((s, r) => s + Number(r.market_value_usd || 0), 0));
        const groupMetric = colorMode === "valuation"
          ? (group.weightedPe ? `P/E ${group.weightedPe.toFixed(1)}` : "P/E —")
          : colorMode === "pnl"
            ? fmtDay(group.weightedPnl)
            : (colorMode === "day" ? fmtDay(group.weightedChange) : fmtDay(group.weightedValue));
        return {
          name: `${localizedSector(group.sector)}   ${holdingsLabel} · ${groupValue}   ${groupMetric}`,
          value: childrenSum,
          itemStyle: {
            color: cssVar("--panel"),
            borderColor: cssVar("--panel"),
            borderWidth: 0,
            gapWidth: 4,
            borderRadius: 8,
            shadowBlur: 0,
            shadowColor: "transparent",
          },
          upperLabel: {
            show: true, height: 28, align: "left", verticalAlign: "middle", padding: [0, 10, 0, 10],
            color: cssVar("--ink"), backgroundColor: cssVar("--panel"), fontSize: 12, fontWeight: 800,
            overflow: "truncate",
          },
          children,
        };
      });
    }
    function buildLegend() {
      const limit = colorMetricLimit();
      let stops, labels;
      if (colorMode === "valuation") {
        stops = ["#ef4444", "#22c55e"];
        labels = [tr("高估"), tr("低估")];
      } else {
        const steps = 7;
        stops = [];
        labels = [];
        for (let i = 0; i < steps; i++) {
          const t = (i / (steps - 1)) * 2 - 1;
          const a = Math.abs(t);
          if (t >= 0) {
            stops.push(`rgb(${Math.round(22 + a * 200)},${Math.round(163 + a * 85)},${Math.round(86 + a * 60)})`);
          } else {
            stops.push(`rgb(${Math.round(200 + a * 55)},${Math.round(68 + a * 30)},${Math.round(68 + a * 30)})`);
          }
        }
        labels = [`${(-limit).toFixed(0)}%`, "", "0%", "", `${limit.toFixed(0)}%`];
      }
      legendBar.innerHTML = stops.map(s => `<div class="legend-stop" style="background:${s}"></div>`).join("");
      legendLabels.innerHTML = labels.map(l => `<span>${l}</span>`).join("");
      const label = colorMode === "valuation" ? tr("估值 P/E") : colorMode === "pnl" ? tr("浮动盈亏 %") : colorMode === "relvolume" ? tr("相对成交量(量/均量)") : tr("今日涨跌 %");
      legendNote.textContent = label;
    }
    function tooltipHtml(row) {
      const day = Number(row.today_change_percent || 0);
      const metric = colorMetric(row);
      const pnl = Number(row.unrealized_usd || 0);
      const pnlPct = row.unrealized_percent === null ? "—" : `${Number(row.unrealized_percent).toFixed(1)}%`;
      const pe = valuationPe(row);
      const forwardPe = Number(row.forward_pe || 0) > 0 ? Number(row.forward_pe) : null;
      const sales = Number(row.price_to_sales || 0) > 0 ? Number(row.price_to_sales) : null;
      const valuationAge = fmtAge(row.valuation_as_of_unix);
      const text = cssVar("--ink"); const muted = cssVar("--muted");
      const up = "var(--positive)"; const down = "var(--negative)";
      const fmtReturn = val => {
        if (val === null || val === undefined) return "—";
        const num = Number(val);
        return `<span style="color:${num >= 0 ? up : down}; font-weight: 700;">${num >= 0 ? "+" : ""}${num.toFixed(2)}%</span>`;
      };
      const period = (zh, en) => isEnglish() ? en : zh;
      return `<div style="width:260px;border:1px solid var(--line);border-radius:10px;background:var(--panel);box-shadow:0 8px 32px rgba(0,0,0,0.5);padding:10px 11px;color:${text};">
        <div style="display:flex;align-items:baseline;justify-content:space-between;gap:10px;border-bottom:1px solid var(--line);padding-bottom:7px;margin-bottom:7px;">
          <div style="min-width:0;">
            <div style="font-weight:850;font-size:14px;line-height:1.1;">${htmlEscape(row.ticker)}</div>
            <div style="color:${muted};font-size:10px;line-height:1.25;margin-top:3px;">${htmlEscape(row.display_name || row.name || row.ticker)}</div>
          </div>
          <div style="font-weight:850;font-size:13px;color:${metric >= 0 ? up : down};">${metricLabel(row)}</div>
        </div>
        <div style="display:grid;gap:5px;font-size:11px;line-height:1.25;">
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">${tr("板块")}</span><b style="font-weight:650;text-align:right;">${htmlEscape(localizedSector(row.sector || "Other"))}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">${tr("仓位")}</span><b style="font-weight:750;">${fmtPct(row.weight)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">${tr("今日")}</span><b style="font-weight:750;color:${day >= 0 ? up : down};">${fmtDay(day)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">P/E</span><b style="font-weight:750;color:${pe === null ? muted : pe <= 22 ? up : down};">${fmtRatio(pe)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">Forward P/E</span><b style="font-weight:750;">${fmtRatio(forwardPe)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">P/S</span><b style="font-weight:750;">${fmtRatio(sales)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;border-top:1px solid var(--line);padding-top:5px;margin-top:2px;"><span style="color:${muted};">${tr("估值更新")}</span><b style="font-weight:650;color:${muted};">${valuationAge}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">${tr("市值")}</span><b style="font-weight:750;">${fmtMoney(row.market_value_usd)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">${tr("浮盈亏")}</span><b style="font-weight:750;color:${pnl >= 0 ? up : down};">${fmtMoney(pnl)} / ${pnlPct}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">${tr("成本")}</span><b style="font-weight:750;">${fmtMoney(row.cost_usd)}</b></div>
          <div style="display:flex;justify-content:space-between;gap:14px;"><span style="color:${muted};">${tr("现价")}</span><b style="font-weight:750;">${fmtNum(row.quote_price)} ${htmlEscape(row.quote_currency || "")}</b></div>
          ${row._etf_only ? `<div style="display:flex;justify-content:space-between;gap:14px;border-top:1px solid var(--line);padding-top:5px;margin-top:2px;"><span style="color:var(--accent);">${tr("来源")}</span><b style="font-weight:650;color:var(--accent);">${tr("全部来自 ETF")}</b></div>` : row._etf_portion ? `<div style="display:flex;justify-content:space-between;gap:14px;border-top:1px solid var(--line);padding-top:5px;margin-top:2px;"><span style="color:var(--accent);">${tr("含 ETF")}</span><b style="font-weight:650;color:var(--accent);">+${fmtMoney(row._etf_portion)}</b></div>` : ""}
          
          <div style="display:flex;justify-content:space-between;gap:14px;border-top:1px solid var(--line);padding-top:5px;margin-top:2px;"><span style="color:${muted}; font-weight:700;">${tr("历史表现")}</span></div>
          <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px 10px;font-size:10px;margin-top:2px;">
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">${period("1周", "1W")}</span><b>${fmtReturn(row.return_1w)}</b></div>
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">${period("1月", "1M")}</span><b>${fmtReturn(row.return_1m)}</b></div>
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">${period("3月", "3M")}</span><b>${fmtReturn(row.return_3m)}</b></div>
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">${period("6月", "6M")}</span><b>${fmtReturn(row.return_6m)}</b></div>
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">YTD</span><b>${fmtReturn(row.return_ytd)}</b></div>
            <div style="display:flex;justify-content:space-between;"><span style="color:${muted};">${period("1年", "1Y")}</span><b>${fmtReturn(row.return_1y)}</b></div>
          </div>
        </div>
      </div>`;
    }

    function renderSummary(rows) {
      const el = document.getElementById("heatmapSummary");
      if (!el) return;
      const total = rows.reduce((s, r) => s + Number(r.market_value_usd || 0), 0);
      const dayPnl = rows.reduce((s, r) => { const ch = Number(r.today_change_percent||0)/100; const v = Number(r.market_value_usd||0); return s + (v - v/(1+ch)); }, 0);
      const up = rows.filter(r => Number(r.today_change_percent||0) > 0).length;
      const down = rows.filter(r => Number(r.today_change_percent||0) < 0).length;
      const upColor = dayPnl >= 0 ? "var(--positive)" : "var(--negative)";
      el.innerHTML = `<div class="detail" style="padding:10px 14px;"><span>${tr("持仓数")}</span><b>${rows.length}</b></div>
        <div class="detail" style="padding:10px 14px;"><span>${tr("总市值")}</span><b>${fmtMoney(total)}</b></div>
        <div class="detail" style="padding:10px 14px;"><span>${tr("今日盈亏")}</span><b style="color:${upColor}">${fmtMoney(dayPnl)}</b></div>
        <div class="detail" style="padding:10px 14px;"><span>${tr("涨跌比")}</span><b>↑${up} / ↓${down}</b></div>
        <div class="detail" style="padding:10px 14px;"><span>${tr("日涨跌%")}</span><b style="color:${upColor}">${total ? (dayPnl/(total-dayPnl)*100).toFixed(2) : "—"}%</b></div>
        <div class="detail" style="padding:10px 14px;"><span>${tr("ETF穿透")}</span><b>${etfUnwrap ? tr("已开启") : tr("关闭")}</b></div>`;
    }

    function renderDailyTrend(rows) {
      try {
      const el = document.getElementById("dailyTrendChart");
      if (!el || !window.LightweightCharts) return;
      if (el._lwChart) { el._lwChart.remove(); el._lwChart = null; }
      const d = document.documentElement.classList.contains("light-theme");
      const chart = LightweightCharts.createChart(el, {
        width: el.clientWidth, height: 220,
        layout: { background: { color: d ? '#ffffff' : '#0b0d0f' }, textColor: d ? '#5d6068' : '#707580' },
        grid: { vertLines: { color: d ? 'rgba(0,0,0,0.06)' : 'rgba(255,255,255,0.05)' }, horzLines: { color: d ? 'rgba(0,0,0,0.06)' : 'rgba(255,255,255,0.05)' } },
        rightPriceScale: { borderColor: d ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.05)' },
        timeScale: { borderColor: d ? 'rgba(0,0,0,0.08)' : 'rgba(255,255,255,0.05)', timeVisible: false },
        crosshair: { mode: 0 },
      });
      el._lwChart = chart;
      const sorted = [...rows].filter(r => Number.isFinite(Number(r.today_change_percent)))
        .sort((a, b) => Number(b.today_change_percent || 0) - Number(a.today_change_percent || 0));
      if (!sorted.length) return;
      const fmtPctVal = v => (v != null ? (v >= 0 ? '+' : '') + v.toFixed(2) + '%' : '');
      // Use epoch seconds as time so LW Charts renders correctly
      const baseTime = Math.floor(Date.now() / 86400) * 86400;
      const series = chart.addHistogramSeries({
        priceFormat: { type: 'custom', formatter: fmtPctVal },
      });
      series.setData(sorted.map((r, i) => ({
        time: baseTime + i * 60,
        value: Number(r.today_change_percent || 0),
        color: (Number(r.today_change_percent) || 0) >= 0 ? '#27a648' : '#e54d5e',
      })));      } catch(e) { /* daily trend chart optional */ }
    }
    function getActiveRows() {
      if (!etfUnwrap || !lookthroughData) return rawRows;
      const etfTickers = new Set(lookthroughData.etf_tickers);
      const ltRows = lookthroughData.rows || [];
      const merged = {};
      rawRows.forEach(r => {
        if (!etfTickers.has(r.ticker)) merged[r.ticker] = Object.assign({}, r);
      });
      ltRows.forEach(lt => {
        if (merged[lt.ticker]) {
          merged[lt.ticker].market_value_usd = (Number(merged[lt.ticker].market_value_usd) || 0) + (lt.from_etf_usd || 0);
          merged[lt.ticker]._etf_portion = lt.from_etf_usd;
        } else {
          merged[lt.ticker] = {
            ticker: lt.ticker,
            name: lt.name,
            display_name: lt.name,
            sector: tr("ETF穿透板块"),
            market_value_usd: lt.total_usd || 0,
            today_change_percent: null,
            unrealized_percent: null,
            unrealized_usd: null,
            cost_usd: null,
            shares: null,
            weight: 0,
            quote_price: null,
            quote_currency: "USD",
            _etf_only: true,
          };
        }
      });
      const result = Object.values(merged);
      const totalValue = result.reduce((s, r) => s + (Number(r.market_value_usd) || 0), 0);
      result.forEach(r => { r.weight = totalValue > 0 ? (Number(r.market_value_usd) || 0) / totalValue : 0; });
      return result;
    }
    function render() {
      const rows = getActiveRows();
      if (!window.echarts) {
        setStatus(`<div class="status-dot danger"></div> ${tr("图表库加载失败")}`);
        heatmap.innerHTML = `<div style="padding:24px;color:#a9364b;font-weight:800;">${tr("图表库加载失败")}</div>`;
        return;
      }
      currentRows = rows;
      layoutLabel.textContent = tr(layoutLabels[layoutMode] || "按大小");
      layoutMenu.querySelectorAll(".menu-item").forEach(el => {
        el.classList.toggle("active", el.dataset.layout === layoutMode);
      });
      currencyLabel.textContent = currencyMode;
      currencyMenu.querySelectorAll(".menu-item").forEach(el => {
        el.classList.toggle("active", el.dataset.currency === currencyMode);
      });
      colorLabel.textContent = tr(colorLabels[colorMode] || "涨跌1天, %");
      colorMenu.querySelectorAll(".menu-item").forEach(el => {
        el.classList.toggle("active", el.dataset.color === colorMode);
      });
      sizeMenu.querySelectorAll(".menu-item").forEach(el => {
        el.classList.toggle("active", el.dataset.size === sizeMode_value);
      });
      sizeLabel.textContent = tr(sizeLabels[sizeMode_value] || "市值");
      nameLabel.textContent = tr(nameLabels[nameMode] || "代码");
      nameMenu.querySelectorAll(".menu-item").forEach(el => {
        el.classList.toggle("active", el.dataset.name === nameMode);
      });
      rawHoldingsBtn?.classList.toggle("active", !etfUnwrap);
      rawHoldingsBtn?.setAttribute("aria-pressed", String(!etfUnwrap));
      etfUnwrapBtn.classList.toggle("active", etfUnwrap);
      etfUnwrapBtn.setAttribute("aria-pressed", String(etfUnwrap));
      if (!heatmapChart) {
        heatmapChart = echarts.init(heatmap, null, { renderer: "canvas" });
        window.addEventListener("resize", () => { heatmapChart?.resize(); });
      }
      const data = layoutMode === "sector" ? buildSectorData(rows) : buildSizeData(rows);
      heatmapChart.setOption({
        animationDuration: 280, animationDurationUpdate: 260,
        animationEasing: "cubicOut", animationEasingUpdate: "cubicOut",
        tooltip: {
          trigger: "item", confine: true, borderWidth: 0, padding: 0, backgroundColor: "transparent",
          formatter: params => { const row = params.data.raw; if (!row) return ""; return tooltipHtml(row); },
        },
        series: [{
          type: "treemap", roam: false, nodeClick: false, breadcrumb: { show: false },
          visibleMin: 0, left: 0, top: 0, right: 0, bottom: 0, squareRatio: 1.15, sort: "desc",
          levels: [
            { itemStyle: { borderWidth: 0, gapWidth: 4, borderColor: cssVar("--bg"), borderRadius: 8 } },
            { upperLabel: { show: layoutMode === "sector" }, itemStyle: { borderWidth: 0, gapWidth: 4, borderColor: cssVar("--bg"), borderRadius: 8 } },
            { itemStyle: { borderWidth: 0, gapWidth: 4, borderColor: cssVar("--bg"), borderRadius: 8 } },
          ],
          data,
        }],
      }, true);
      setStatus(`<span class="status-dot"></span> ${tr("已更新")}`);
      buildLegend();
      renderSummary(rows);
    }
    function toggleFullscreen() {
      isFullscreen = !isFullscreen;
      heatmap.parentElement.classList.toggle("fullscreen-mode", isFullscreen);
      fullscreenBtn.innerHTML = isFullscreen ? '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-compress"></use></svg>' : '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-expand"></use></svg>';
      setTimeout(() => heatmapChart?.resize(), 100);
    }
    window.addEventListener("catfolio:themechange", () => {
      if (heatmapChart && currentRows.length) render();
    });
    fullscreenBtn.addEventListener("click", toggleFullscreen);
    document.addEventListener("keydown", e => { if (e.key === "Escape" && isFullscreen) toggleFullscreen(); });
    function closeAllMenus() {
      colorMenu.classList.remove("open");
      sizeMenu.classList.remove("open");
      nameMenu.classList.remove("open");
      layoutMenu.classList.remove("open");
      currencyMenu.classList.remove("open");
    }
    colorTrigger.addEventListener("click", (e) => { e.stopPropagation(); const open = colorMenu.classList.contains("open"); closeAllMenus(); if (!open) colorMenu.classList.add("open"); });
    document.addEventListener("click", () => { closeAllMenus(); });
    colorMenu.querySelectorAll(".menu-item:not(.disabled)").forEach(item => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        colorMode = item.dataset.color;
        closeAllMenus();
        render();
      });
    });
    sizeTrigger.addEventListener("click", (e) => { e.stopPropagation(); const open = sizeMenu.classList.contains("open"); closeAllMenus(); if (!open) sizeMenu.classList.add("open"); });
    sizeMenu.querySelectorAll(".menu-item:not(.disabled)").forEach(item => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        sizeMode_value = item.dataset.size;
        closeAllMenus();
        render();
      });
    });
    nameTrigger.addEventListener("click", (e) => { e.stopPropagation(); const open = nameMenu.classList.contains("open"); closeAllMenus(); if (!open) nameMenu.classList.add("open"); });
    nameMenu.querySelectorAll(".menu-item:not(.disabled)").forEach(item => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        nameMode = item.dataset.name;
        closeAllMenus();
        render();
      });
    });
    layoutTrigger.addEventListener("click", (e) => { e.stopPropagation(); const open = layoutMenu.classList.contains("open"); closeAllMenus(); if (!open) layoutMenu.classList.add("open"); });
    layoutMenu.querySelectorAll(".menu-item:not(.disabled)").forEach(item => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        layoutMode = item.dataset.layout;
        closeAllMenus();
        render();
      });
    });
    currencyTrigger.addEventListener("click", (e) => { e.stopPropagation(); const open = currencyMenu.classList.contains("open"); closeAllMenus(); if (!open) currencyMenu.classList.add("open"); });
    currencyMenu.querySelectorAll(".menu-item:not(.disabled)").forEach(item => {
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        currencyMode = item.dataset.currency;
        closeAllMenus();
        render();
      });
    });
    rawHoldingsBtn?.addEventListener("click", () => {
      if (!etfUnwrap) return;
      etfUnwrap = false;
      render();
    });
    etfUnwrapBtn.addEventListener("click", () => {
      if (!lookthroughData) return;
      if (etfUnwrap) return;
      etfUnwrap = true;
      render();
    });
    async function boot() {
      const [heatmapResponse, s, lt] = await Promise.all([fetch("/api/holdings/heatmap"), fetch("/api/portfolio/summary"), fetch("/api/etf-lookthrough?basis=market")]);
      if (!heatmapResponse.ok) throw new Error(`HTTP ${heatmapResponse.status}`);
      if (!s.ok) throw new Error(`HTTP ${s.status}`);
      const data = await heatmapResponse.json();
      const summary = await s.json();
      fxToUsd = { USD: 1, GBP: Number(summary.report_fx_to_usd?.GBP || 1.346) };
      rawRows = data.rows || [];
      if (!rawRows.length) throw new Error("没有持仓热力图数据");
      if (lt.ok) lookthroughData = await lt.json();
      render();
    }
    async function refreshAndReload(button, label, url) {
      button.disabled = true;
      setStatus(`<div class="status-dot"></div> ${tr(label)}${tr("中...")}`);
      try {
        const r = await fetch(url, { method: "POST" });
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        const p = await r.json();
        if (p.refresh?.ok === false) throw new Error(p.refresh?.warning || tr("没有可用数据"));
        await boot();
      } catch (e) {
        setStatus(`<div class="status-dot danger"></div> ${tr(label)}${tr("失败：")}${e.message}`);
        if (currentRows.length) {
          setTimeout(() => {
            setStatus(`<div class="status-dot"></div> ${tr("已就绪")}`, true);
          }, 2200);
        }
      }
      finally { button.disabled = false; }
    }
    refreshMarketButton?.addEventListener("click", () => refreshAndReload(refreshMarketButton, "刷新行情", "/api/refresh/market?force=true"));
    refreshValuationButton?.addEventListener("click", () => refreshAndReload(refreshValuationButton, "刷新估值", "/api/refresh/fundamentals?force=true"));
    refreshHoldingsButton?.addEventListener("click", () => refreshAndReload(refreshHoldingsButton, "同步持仓", "/api/refresh/trading212"));
    boot().catch(error => {
      const message = tr(error.message);
      setStatus(`<div class="status-dot danger"></div> ${tr("加载失败：")}${message}`);
      heatmap.innerHTML = `<div style="color:#a9364b;font-weight:700;">${htmlEscape(message)}</div>`;
    });
  
