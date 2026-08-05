(function () {
  const isEnglish = (document.documentElement.lang || "zh").startsWith("en");
  const locale = isEnglish ? "en-GB" : "zh-CN";
  const copy = isEnglish ? {
    asset: "Asset",
    currentPrice: "Current Price",
    today: "Today",
    profit: "Unreal. P&L",
    fxProfit: "FX P&L",
    marketValueColumn: "Market Value",
    weeks: "52 Weeks",
    rangeCurrent: "Current price",
    rangeLocation: "of the 52-week range",
    directValue: "Direct Value",
    etfExposure: "ETF Exposure",
    totalExposure: "Total Exposure",
    source: "Source",
    etfWeight: "ETF Weight",
    etfMix: "ETF Mix",
    holdings: "holdings",
    exposures: "exposures",
    marketValue: "market value",
    etfValue: "ETF value",
    direct: "Direct",
    etf: "ETF",
    directEtf: "Direct + ETF",
    loading: "Loading holdings…",
    empty: "No holdings are available.",
    failed: "Holdings failed to load",
    amountSort: "amount",
    percentSort: "percentage",
    highToLow: "high to low",
    lowToHigh: "low to high",
    profileUnavailable: "Volume profile unavailable",
    profileTitle: "Volume Profile",
    profileVah: "VAH",
    profilePoc: "POC",
    profileCost: "Cost Price",
    profileVal: "VAL",
  } : {
    asset: "资产",
    currentPrice: "现价",
    today: "今日",
    profit: "未实现盈亏",
    fxProfit: "汇率盈亏",
    marketValueColumn: "市值",
    weeks: "52 周",
    rangeCurrent: "当前价格",
    rangeLocation: "位于 52 周区间",
    directValue: "直接持有",
    etfExposure: "ETF 间接暴露",
    totalExposure: "总暴露",
    source: "来源",
    etfWeight: "ETF 权重",
    etfMix: "ETF 比例",
    holdings: "个持仓",
    exposures: "个底层暴露",
    marketValue: "市值",
    etfValue: "ETF 市值",
    direct: "直接持有",
    etf: "ETF",
    directEtf: "直接 + ETF",
    loading: "正在读取持仓…",
    empty: "暂无可用持仓。",
    failed: "持仓加载失败",
    amountSort: "金额",
    percentSort: "比例",
    highToLow: "从高到低",
    lowToHigh: "从低到高",
    profileUnavailable: "暂无成交量分布数据",
    profileTitle: "成交量分布",
    profileVah: "VAH 上沿",
    profilePoc: "POC 峰值",
    profileCost: "持仓成本",
    profileVal: "VAL 下沿",
  };

  const elements = {
    meta: document.querySelector("#portfolioHoldingsMeta"),
    head: document.querySelector("#portfolioHoldingsHead"),
    rows: document.querySelector("#portfolioHoldingsRows"),
    modes: Array.from(document.querySelectorAll("[data-portfolio-holdings-mode]")),
  };
  if (!elements.meta || !elements.head || !elements.rows) return;

  const state = {
    mode: "direct",
    direct: [],
    lookthrough: [],
    total: 0,
    etfTotal: 0,
    sortKey: "position",
    sortDirection: "desc",
    profitSortMetric: "amount",
  };
  const volumeProfiles = new Map();
  const finePointer = window.matchMedia("(hover: hover) and (pointer: fine)");
  let volumeProfileTimer = 0;
  let volumeProfileRequest = null;
  let activeVolumeProfileRow = null;
  let volumeProfilePoint = { x: 0, y: 0 };

  const volumeProfilePopover = document.createElement("div");
  volumeProfilePopover.className = "portfolio-volume-profile-popover";
  volumeProfilePopover.id = "portfolioVolumeProfilePopover";
  volumeProfilePopover.setAttribute("role", "tooltip");
  volumeProfilePopover.hidden = true;
  volumeProfilePopover.innerHTML = `<strong class="portfolio-volume-profile-title">${copy.profileTitle}</strong>
    <span class="portfolio-volume-profile-body">
      <span class="portfolio-volume-profile-rail" aria-hidden="true"></span>
      <span class="portfolio-volume-profile-rows"></span>
    </span>`;
  document.body.appendChild(volumeProfilePopover);

  const escapeHtml = value => String(value ?? "").replace(/[&<>"']/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  }[character]));
  const numeric = value => Number.isFinite(Number(value)) ? Number(value) : 0;
  const formatNumber = (value, maximumFractionDigits = 2, minimumFractionDigits = 0) => numeric(value).toLocaleString(locale, {
    maximumFractionDigits,
    minimumFractionDigits,
  });
  const money = value => {
    const amount = numeric(value);
    return `${amount < 0 ? "-" : ""}$${Math.abs(amount).toLocaleString(locale, { maximumFractionDigits: 0 })}`;
  };
  const preciseMoney = value => `${numeric(value) < 0 ? "-" : ""}$${Math.abs(numeric(value)).toLocaleString(locale, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  const signedMoney = value => `${numeric(value) >= 0 ? "+" : "-"}$${Math.abs(numeric(value)).toLocaleString(locale, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  const signedPercent = value => `${numeric(value) >= 0 ? "+" : ""}${numeric(value).toFixed(1)}%`;
  const ratioPercent = value => `${(numeric(value) * 100).toFixed(1)}%`;

  function nativePrice(value, currency, minDigits = 2) {
    if (value === null || value === undefined || value === "") return "—";
    const code = String(currency || "USD").toUpperCase();
    const amount = code === "GBX" ? numeric(value) / 100 : numeric(value);
    const displayCurrency = code === "GBX" ? "GBP" : code;
    const symbols = { USD: "$", GBP: "£", EUR: "€", JPY: "¥", CNY: "¥" };
    const formatted = formatNumber(amount, 2, minDigits);
    return symbols[displayCurrency] ? `${symbols[displayCurrency]}${formatted}` : `${formatted} ${escapeHtml(displayCurrency)}`;
  }

  function rangePrice(value, currency) {
    if (value === null || value === undefined || value === "") return "—";
    const amount = formatNumber(value, 2, 2);
    if (currency === "USD") return `$${amount}`;
    if (currency === "GBP") return `£${amount}`;
    if (currency === "EUR") return `€${amount}`;
    if (currency === "GBX") return `£${formatNumber(numeric(value) / 100, 2, 2)}`;
    return amount;
  }

  function rangePosition(row) {
    const low = Number(row.low_52w);
    const high = Number(row.high_52w);
    const price = Number(row.quote_price);
    if (![low, high, price].every(Number.isFinite) || high <= low) return null;
    return Math.max(0, Math.min(1, (price - low) / (high - low)));
  }

  function rangeMarkup(row) {
    const position = rangePosition(row);
    if (position === null) return '<span class="muted">—</span>';
    const percentage = Math.round(position * 100);
    const current = rangePrice(row.quote_price, row.quote_currency);
    const hint = `${copy.rangeCurrent} ${current} · ${copy.rangeLocation} ${percentage}%`;
    return `<span class="portfolio-holding-range" role="img" aria-label="${escapeHtml(hint)}">
      <span class="portfolio-holding-range-values"><span>${rangePrice(row.high_52w, row.quote_currency)}</span><span>${rangePrice(row.low_52w, row.quote_currency)}</span></span>
      <span class="portfolio-holding-range-track" title="${escapeHtml(hint)}">
        <i style="height:${Math.max(2, position * 100).toFixed(2)}%"></i>
        <span class="portfolio-holding-range-marker" style="bottom:${(position * 100).toFixed(2)}%" aria-hidden="true"></span>
      </span>
    </span>`;
  }

  function tickerHue(ticker) {
    return Array.from(String(ticker || "?")).reduce((total, character) => total + character.charCodeAt(0) * 17, 0) % 360;
  }

  function holdingName(row) {
    const ticker = String(row.ticker || "");
    const companyName = String(row.company_name || row.name || "").trim();
    if (companyName && companyName.toUpperCase() !== ticker.toUpperCase()) return companyName;
    return ticker;
  }

  function assetCells(row, shares = row.shares) {
    const ticker = escapeHtml(row.ticker || "—");
    const name = escapeHtml(holdingName(row));
    const shareLabel = shares === null || shares === undefined || shares === "" ? "" : formatNumber(shares, 3, 3);
    const initial = escapeHtml(String(row.ticker || "?").slice(0, 1));
    const logoSymbol = String(row.logo_symbol || row.ticker || "").trim();
    const logoImage = logoSymbol
      ? `<img class="portfolio-holding-logo-image" src="/api/asset-logo/${encodeURIComponent(logoSymbol)}" alt="" loading="lazy" decoding="async" />`
      : "";
    return `<td class="portfolio-holding-logo"><span class="portfolio-holding-badge" style="--asset-hue:${tickerHue(row.ticker)}"><span class="portfolio-holding-initial">${initial}</span>${logoImage}</span></td>
      <td class="portfolio-holding-asset"><span class="portfolio-holding-identity"><strong title="${name}">${name}</strong><small>${shareLabel ? `<span>${shareLabel}</span>` : ""}<span>${ticker}</span></small></span></td>`;
  }

  function bindAssetLogos() {
    elements.rows.querySelectorAll(".portfolio-holding-logo-image").forEach(image => {
      const badge = image.closest(".portfolio-holding-badge");
      const showLogo = () => badge?.classList.add("has-logo");
      if (image.complete) {
        if (image.naturalWidth > 0) showLogo();
        else image.remove();
        return;
      }
      image.addEventListener("load", showLogo, { once: true });
      image.addEventListener("error", () => image.remove(), { once: true });
    });
  }

  function positionVolumeProfilePopover() {
    if (volumeProfilePopover.hidden) return;
    const gap = 12;
    const edge = 8;
    const rect = volumeProfilePopover.getBoundingClientRect();
    let left = volumeProfilePoint.x + gap;
    let top = volumeProfilePoint.y + gap;
    if (left + rect.width > window.innerWidth - edge) left = volumeProfilePoint.x - rect.width - gap;
    if (top + rect.height > window.innerHeight - edge) top = volumeProfilePoint.y - rect.height - gap;
    volumeProfilePopover.style.left = `${Math.max(edge, left)}px`;
    volumeProfilePopover.style.top = `${Math.max(edge, top)}px`;
  }

  function volumeProfileMarker(value, profile, tone) {
    const vah = Number(profile?.vah);
    const val = Number(profile?.val);
    const price = Number(value);
    if (![vah, val, price].every(Number.isFinite) || vah <= val) return "";
    const position = Math.max(4.5, Math.min(95.5, ((vah - price) / (vah - val)) * 100));
    return `<i class="portfolio-volume-profile-marker is-${tone}" style="--profile-marker-position:${position.toFixed(2)}%"></i>`;
  }

  function fillVolumeProfile(profile, currency, costPrice, costCurrency) {
    const available = profile?.available;
    volumeProfilePopover.title = available ? "" : copy.profileUnavailable;
    const profileCurrency = profile?.currency || currency || "USD";
    const numericCost = costPrice === null || costPrice === undefined || costPrice === "" ? null : Number(costPrice);
    const entries = [
      { key: "vah", label: copy.profileVah, value: available ? Number(profile.vah) : null, currency: profileCurrency, rank: 0 },
      { key: "poc", label: copy.profilePoc, value: available ? Number(profile.poc) : null, currency: profileCurrency, rank: 1 },
      { key: "cost", label: copy.profileCost, value: Number.isFinite(numericCost) ? numericCost : null, currency: costCurrency || profileCurrency, rank: 2 },
      { key: "val", label: copy.profileVal, value: available ? Number(profile.val) : null, currency: profileCurrency, rank: 3 },
    ];
    if (available) {
      entries.sort((left, right) => {
        if (left.value === null) return 1;
        if (right.value === null) return -1;
        return right.value - left.value || left.rank - right.rank;
      });
    }
    const rows = volumeProfilePopover.querySelector(".portfolio-volume-profile-rows");
    rows.innerHTML = entries.map(entry => {
      const formatted = entry.value === null ? "—" : nativePrice(entry.value, entry.currency, 2);
      return `<span class="portfolio-volume-profile-row${entry.key === "cost" ? " is-cost" : ""}"><b>${entry.label}</b><i>${formatted}</i></span>`;
    }).join("");
    const rail = volumeProfilePopover.querySelector(".portfolio-volume-profile-rail");
    rail.innerHTML = available
      ? `${volumeProfileMarker(numericCost, profile, "cost")}${volumeProfileMarker(profile.poc, profile, "poc")}`
      : "";
  }

  function hideVolumeProfile(row = null) {
    if (row && activeVolumeProfileRow !== row) return;
    window.clearTimeout(volumeProfileTimer);
    volumeProfileTimer = 0;
    volumeProfileRequest?.abort();
    volumeProfileRequest = null;
    activeVolumeProfileRow = null;
    volumeProfilePopover.hidden = true;
  }

  async function showVolumeProfile(row) {
    if (!finePointer.matches || activeVolumeProfileRow !== row) return;
    const ticker = row.dataset.volumeProfileTicker;
    const currency = row.dataset.volumeProfileCurrency;
    const costPrice = row.dataset.volumeProfileCostPrice;
    const costCurrency = row.dataset.volumeProfileCostCurrency;
    if (!ticker) return;
    fillVolumeProfile(volumeProfiles.get(ticker), currency, costPrice, costCurrency);
    volumeProfilePopover.hidden = false;
    positionVolumeProfilePopover();
    if (volumeProfiles.has(ticker)) return;

    volumeProfileRequest?.abort();
    const request = new AbortController();
    volumeProfileRequest = request;
    try {
      const response = await fetch(`/api/holdings/${encodeURIComponent(ticker)}/volume-profile`, {
        signal: request.signal,
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const profile = await response.json();
      volumeProfiles.set(ticker, profile);
      if (activeVolumeProfileRow === row) {
        fillVolumeProfile(profile, currency, costPrice, costCurrency);
        positionVolumeProfilePopover();
      }
    } catch (error) {
      if (error.name !== "AbortError" && activeVolumeProfileRow === row) {
        fillVolumeProfile({ available: false }, currency, costPrice, costCurrency);
      }
    } finally {
      if (volumeProfileRequest === request) volumeProfileRequest = null;
    }
  }

  function bindVolumeProfileRows() {
    hideVolumeProfile();
    if (!finePointer.matches) return;
    elements.rows.querySelectorAll("[data-volume-profile-ticker]").forEach(row => {
      row.addEventListener("pointerenter", event => {
        activeVolumeProfileRow = row;
        volumeProfilePoint = { x: event.clientX, y: event.clientY };
        window.clearTimeout(volumeProfileTimer);
        volumeProfileTimer = window.setTimeout(() => showVolumeProfile(row), 120);
      });
      row.addEventListener("pointermove", event => {
        if (activeVolumeProfileRow !== row) return;
        volumeProfilePoint = { x: event.clientX, y: event.clientY };
        positionVolumeProfilePopover();
      });
      row.addEventListener("pointerleave", () => hideVolumeProfile(row));
    });
  }

  function directRow(row) {
    const today = numeric(row.today_change_percent);
    const profit = numeric(row.unrealized_usd);
    const profitPercent = numeric(row.unrealized_percent);
    const fxProfit = numeric(row.broker_fx_ppl_usd);
    const fxProfitPercent = numeric(row.broker_fx_ppl_percent);
    const tone = value => numeric(value) >= 0 ? "positive" : "negative";
    const fxTone = Math.abs(fxProfit) < 0.005 ? "muted" : tone(fxProfit);
    const fxMoney = Math.abs(fxProfit) < 0.005 ? preciseMoney(0) : signedMoney(fxProfit);
    const fxPercentLabel = Math.abs(fxProfitPercent) < 0.005 ? "0.0%" : signedPercent(fxProfitPercent);
    return `<tr data-volume-profile-ticker="${escapeHtml(row.ticker || "")}" data-volume-profile-currency="${escapeHtml(row.quote_currency || row.cost_currency || "USD")}" data-volume-profile-cost-price="${escapeHtml(row.avg_cost_native ?? row.avg_cost_usd ?? "")}" data-volume-profile-cost-currency="${escapeHtml(row.cost_currency || row.quote_currency || "USD")}">
      ${assetCells(row)}
      <td><span class="portfolio-holding-stack"><b>${nativePrice(row.quote_price, row.quote_currency || row.cost_currency || "USD")}</b><span>${nativePrice(row.avg_cost_native ?? row.avg_cost_usd, row.cost_currency || "USD")}</span></span></td>
      <td class="${tone(today)}">${signedPercent(today)}</td>
      <td><span class="portfolio-holding-profit ${tone(profit)}"><b>${signedMoney(profit)}</b><span>${signedPercent(profitPercent)}</span></span></td>
      <td><span class="portfolio-holding-fx ${fxTone}"><b>${fxMoney}</b><span>${fxPercentLabel}</span></span></td>
      <td><span class="portfolio-holding-market"><b>${preciseMoney(row.market_value_usd)}</b><span>${ratioPercent(row.weight)}</span></span></td>
      <td>${rangeMarkup(row)}</td>
    </tr>`;
  }

  function matchingDirectHolding(row) {
    const ticker = String(row.ticker || "").toUpperCase();
    return state.direct.find(item => String(item.ticker || "").toUpperCase() === ticker);
  }

  function lookthroughRow(row) {
    const direct = matchingDirectHolding(row);
    const total = numeric(row.total_usd);
    const position = state.total ? total / state.total : 0;
    const today = direct ? numeric(direct.today_change_percent) : null;
    const profit = direct ? numeric(direct.unrealized_usd) : null;
    const profitPercent = direct ? numeric(direct.unrealized_percent) : null;
    const fxProfit = direct ? numeric(direct.broker_fx_ppl_usd) : null;
    const fxProfitPercent = direct ? numeric(direct.broker_fx_ppl_percent) : null;
    const tone = value => numeric(value) >= 0 ? "positive" : "negative";
    const fxTone = Math.abs(numeric(fxProfit)) < 0.005 ? "muted" : tone(fxProfit);
    const fxMoney = Math.abs(numeric(fxProfit)) < 0.005 ? preciseMoney(0) : signedMoney(fxProfit);
    const fxPercentLabel = Math.abs(numeric(fxProfitPercent)) < 0.005 ? "0.0%" : signedPercent(fxProfitPercent);
    const asset = direct ? { ...row, company_name: direct.company_name || row.company_name, logo_symbol: direct.logo_symbol || row.logo_symbol } : row;
    const profileTicker = direct?.ticker || "";
    const profileCurrency = direct?.quote_currency || direct?.cost_currency || "USD";
    return `<tr${profileTicker ? ` data-volume-profile-ticker="${escapeHtml(profileTicker)}" data-volume-profile-currency="${escapeHtml(profileCurrency)}" data-volume-profile-cost-price="${escapeHtml(direct?.avg_cost_native ?? direct?.avg_cost_usd ?? "")}" data-volume-profile-cost-currency="${escapeHtml(direct?.cost_currency || direct?.quote_currency || "USD")}"` : ""}>
      ${assetCells(asset, direct?.shares)}
      <td>${direct ? `<span class="portfolio-holding-stack"><b>${nativePrice(direct.quote_price, direct.quote_currency || direct.cost_currency || "USD")}</b><span>${nativePrice(direct.avg_cost_native ?? direct.avg_cost_usd, direct.cost_currency || "USD")}</span></span>` : '<span class="muted">—</span>'}</td>
      <td class="${direct ? tone(today) : "muted"}">${direct ? signedPercent(today) : "—"}</td>
      <td>${direct ? `<span class="portfolio-holding-profit ${tone(profit)}"><b>${signedMoney(profit)}</b><span>${signedPercent(profitPercent)}</span></span>` : '<span class="muted">—</span>'}</td>
      <td>${direct ? `<span class="portfolio-holding-fx ${fxTone}"><b>${fxMoney}</b><span>${fxPercentLabel}</span></span>` : '<span class="muted">—</span>'}</td>
      <td><span class="portfolio-holding-market"><b>${preciseMoney(total)}</b><span>${ratioPercent(position)}</span></span></td>
      <td>${direct ? rangeMarkup(direct) : '<span class="muted">—</span>'}</td>
    </tr>`;
  }

  const directHeaders = [
    ["§"], [copy.asset], [copy.currentPrice], [copy.today, "today"],
    [copy.profit, "profit"], [copy.fxProfit, "fx"], [copy.marketValueColumn, "position"], [copy.weeks, "range"],
  ];
  function renderHead() {
    elements.head.innerHTML = `<tr>${directHeaders.map(([label, key]) => {
      const active = key && state.sortKey === key;
      const ariaSort = active ? ` aria-sort="${state.sortDirection === "asc" ? "ascending" : "descending"}"` : "";
      if (!key) return `<th scope="col">${escapeHtml(label)}</th>`;
      const sortIcon = active ? '<img src="/static/icons/portfolio-sort.svg" alt="" />' : "";
      const profitSortHint = active && key === "profit"
        ? `${label}: ${state.profitSortMetric === "amount" ? copy.amountSort : copy.percentSort}, ${state.sortDirection === "desc" ? copy.highToLow : copy.lowToHigh}`
        : label;
      return `<th scope="col"${ariaSort}><button class="portfolio-holdings-sort${active && state.sortDirection === "asc" ? " ascending" : ""}" type="button" data-portfolio-sort="${key}" aria-label="${escapeHtml(profitSortHint)}" title="${escapeHtml(profitSortHint)}">${escapeHtml(label)}${sortIcon}</button></th>`;
    }).join("")}</tr>`;

    elements.head.querySelectorAll("[data-portfolio-sort]").forEach(button => {
      button.addEventListener("click", () => {
        const key = button.dataset.portfolioSort;
        if (key === "profit") {
          if (state.sortKey !== "profit") {
            state.sortKey = "profit";
            state.profitSortMetric = "amount";
            state.sortDirection = "desc";
          } else if (state.profitSortMetric === "amount" && state.sortDirection === "desc") {
            state.sortDirection = "asc";
          } else if (state.profitSortMetric === "amount") {
            state.profitSortMetric = "percent";
            state.sortDirection = "desc";
          } else if (state.sortDirection === "desc") {
            state.sortDirection = "asc";
          } else {
            state.profitSortMetric = "amount";
            state.sortDirection = "desc";
          }
        } else if (state.sortKey === key) state.sortDirection = state.sortDirection === "desc" ? "asc" : "desc";
        else {
          state.sortKey = key;
          state.sortDirection = "desc";
        }
        render();
      });
    });
  }

  function sortValue(row) {
    if (state.mode === "direct") {
      return {
        today: numeric(row.today_change_percent),
        profit: state.profitSortMetric === "amount" ? numeric(row.unrealized_usd) : numeric(row.unrealized_percent),
        fx: numeric(row.broker_fx_ppl_usd),
        range: rangePosition(row) ?? Number.NEGATIVE_INFINITY,
        position: numeric(row.weight),
      }[state.sortKey] ?? 0;
    }
    const direct = matchingDirectHolding(row);
    const total = numeric(row.total_usd);
    return {
      today: direct ? numeric(direct.today_change_percent) : Number.NEGATIVE_INFINITY,
      profit: direct ? (state.profitSortMetric === "amount" ? numeric(direct.unrealized_usd) : numeric(direct.unrealized_percent)) : Number.NEGATIVE_INFINITY,
      fx: direct ? numeric(direct.broker_fx_ppl_usd) : Number.NEGATIVE_INFINITY,
      range: direct ? (rangePosition(direct) ?? Number.NEGATIVE_INFINITY) : Number.NEGATIVE_INFINITY,
      position: state.total ? total / state.total : 0,
    }[state.sortKey] ?? 0;
  }

  function render() {
    renderHead();
    const source = state.mode === "direct" ? state.direct : state.lookthrough;
    const rows = [...source].sort((left, right) => {
      const delta = sortValue(left) - sortValue(right);
      return state.sortDirection === "asc" ? delta : -delta;
    });
    elements.rows.innerHTML = rows.length
      ? rows.map(state.mode === "direct" ? directRow : lookthroughRow).join("")
      : `<tr class="portfolio-holdings-message"><td>${copy.empty}</td></tr>`;
    bindAssetLogos();
    bindVolumeProfileRows();
    elements.meta.textContent = state.mode === "direct"
      ? `${state.direct.length} ${copy.holdings} · ${copy.marketValue} ${money(state.total)}`
      : `${state.lookthrough.length} ${copy.exposures} · ${copy.etfValue} ${money(state.etfTotal)}`;
  }

  elements.modes.forEach(button => {
    button.addEventListener("click", () => {
      state.mode = button.dataset.portfolioHoldingsMode;
      state.sortKey = "position";
      state.sortDirection = "desc";
      state.profitSortMetric = "amount";
      elements.modes.forEach(item => {
        const active = item === button;
        item.classList.toggle("active", active);
        item.setAttribute("aria-selected", active ? "true" : "false");
      });
      render();
    });
  });

  window.addEventListener("scroll", () => hideVolumeProfile(), { passive: true });
  window.addEventListener("blur", () => hideVolumeProfile());

  Promise.all([
    fetch("/api/holdings/detail").then(response => {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.json();
    }),
    fetch("/api/etf-lookthrough?basis=market").then(response => {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.json();
    }),
  ]).then(([direct, lookthrough]) => {
    state.direct = direct.rows || [];
    state.lookthrough = lookthrough.rows || [];
    state.total = numeric(direct.summary?.market_value_usd);
    state.etfTotal = numeric(lookthrough.etf_total_usd);
    render();
  }).catch(error => {
    elements.meta.textContent = `${copy.failed}: ${error.message}`;
    elements.rows.innerHTML = `<tr class="portfolio-holdings-message"><td>${copy.failed}</td></tr>`;
  });
})();
