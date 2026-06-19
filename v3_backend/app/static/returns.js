const BENCH_CN = { "SPY": "标普500", "QQQ": "纳斯达克100", "VTI": "美国全市场", "VOO": "先锋标普500", "DIA": "道琼斯30", "IWM": "罗素2000", "VEU": "全球除美", "GLD": "黄金" };

  let returnsMode = 'twr';
  let chart = null;
  let chartSeries = [];
  const currentLang = () => (document.documentElement.lang || "zh").startsWith("en") ? "en" : "zh";
  const isEn = () => currentLang() === "en";
  const tr = (zh, en) => isEn() ? en : zh;

  const CF_COLORS = ['#f97316','#8b5cf6','#06b6d4','#eab308','#ec4899','#a855f7','#22c55e','#ef4444'];
  const TWR_COLORS = ['#888','#f97316','#8b5cf6','#ec4899','#06b6d4','#eab308','#ef4444','#a855f7'];

  function isDark() { return !document.documentElement.classList.contains('light-theme'); }

  function chartColors() {
    const d = isDark();
    return {
      bg: d ? '#0b0d0f' : '#ffffff',
      text: d ? '#707580' : '#5d6068',
      grid: d ? 'rgba(255,255,255,0.05)' : 'rgba(0,0,0,0.06)',
      crosshair: d ? 'rgba(255,255,255,0.08)' : 'rgba(0,0,0,0.08)',
    };
  }

  function selectedRange() {
    const v = document.getElementById('returnsRange')?.value || '252';
    return v === 'all' ? null : Number(v);
  }

  function filterRows(rows) {
    const days = selectedRange();
    if (!days) return rows;
    return rows.slice(-days);
  }

  function numValue(row, keys, fallback = null) {
    for (const key of keys) {
      const raw = row?.[key];
      if (raw === undefined || raw === null || raw === '') continue;
      const value = Number(raw);
      if (Number.isFinite(value)) return value;
    }
    return fallback;
  }

  function getActiveData() {
    if (returnsMode === 'cf') {
      const raw = cfData.rows || [];
      if (!raw.length) return { rows: [], unit: '$' };
      const mapped = raw.map(r => ({
        date: r.date,
        portfolio: numValue(r, ['adjusted_portfolio_value', 'portfolio_value', 'portfolio'], 0),
      }));
      return { rows: filterRows(mapped), unit: '$' };
    } else if (returnsMode === 'cv') {
      const raw = cfData.rows || [];
      if (!raw.length) return { rows: [], unit: '$' };
      const mapped = raw.map(r => ({
        date: r.date,
        portfolio: numValue(r, ['portfolio_value', 'adjusted_portfolio_value', 'portfolio'], 0),
        buy_total: numValue(r, ['net_cash_flow', 'invested_cost_usd', 'buy_total', 'buy_total_usd'], 0),
      }));
      return { rows: filterRows(mapped), unit: '$' };
    }
    return { rows: filterRows(twrData.rows || []), unit: '%' };
  }

  function fmtDollar(v) {
    const abs = Math.abs(v || 0);
    if (abs >= 1e6) return '$' + (abs/1e6).toFixed(1) + 'M';
    if (abs >= 1000) return '$' + (abs/1000).toFixed(0) + 'k';
    return '$' + abs.toFixed(0);
  }

  function fmtPct(v) { return (v || 0).toFixed(1) + '%'; }

  function buildChart() {
    const container = document.getElementById('returnsChart');
    const c = chartColors();
    container.innerHTML = '';

    chart = LightweightCharts.createChart(container, {
      width: container.clientWidth,
      height: 420,
      layout: {
        background: { color: c.bg },
        textColor: c.text,
      },
      grid: {
        vertLines: { color: c.grid },
        horzLines: { color: c.grid },
      },
      crosshair: {
        mode: LightweightCharts.CrosshairMode.Normal,
        vertLine: { color: c.crosshair, labelBackgroundColor: c.crosshair },
        horzLine: { color: c.crosshair, labelBackgroundColor: c.crosshair },
      },
      rightPriceScale: {
        borderColor: c.grid,
      },
      timeScale: {
        borderColor: c.grid,
        timeVisible: true,
        secondsVisible: false,
      },
    });

    chartSeries = [];
    return chart;
  }

  function addLine(label, data, color, opts = {}) {
    const series = chart.addLineSeries({
      color: color,
      lineWidth: opts.lineWidth || 1,
      lineStyle: opts.dashed ? 2 : 0,
      priceFormat: opts.priceFormat || ((returnsMode === 'cf' || returnsMode === 'cv') ? { type: 'custom', formatter: fmtDollar } : { type: 'custom', formatter: fmtPct }),
      title: label,
      visible: opts.visible !== undefined ? opts.visible : true,
    });
    const chartData = data
      .map(d => ({ time: d.date, value: Number(d.value) }))
      .filter(d => d.time && Number.isFinite(d.value));
    series.setData(chartData);
    chartSeries.push(series);
    return series;
  }

  function renderChart() {
    if (chart) {
      chart.remove();
      chart = null;
    }

    const data = getActiveData();
    const rows = data.rows;
    const container = document.getElementById('returnsChart');
    if (!rows.length) {
      container.innerHTML = `
        <div style="display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; color: var(--muted); padding: 40px; text-align: center;">
          <svg class="hi hi-inline" style="font-size: 32px; margin-bottom: 12px; color: var(--accent);" aria-hidden="true" focusable="false"><use href="#hi-alert-circle"></use></svg>
          <div style="font-size: 15px; font-weight: 600; margin-bottom: 6px; color: var(--ink);">${tr("需要交易流水数据", "Transaction history required")}</div>
          <div style="font-size: 12px; max-width: 320px; line-height: 1.6;">
            ${returnsMode === 'cf' || returnsMode === 'cv'
              ? tr('此模式依赖交易流水。请在环境配置中设置 CATFOLIO_DATA_DIR 目录以导入 Trading 212 交易历史 CSV 文件。', 'This mode requires transaction history. Set CATFOLIO_DATA_DIR to import Trading 212 transaction CSV files.')
              : tr('暂无可用收益数据。', 'No return data is available.')}
          </div>
        </div>
      `;
      return;
    }

    const isDollar = data.unit === '$';
    buildChart();

      if (returnsMode === 'cv') {
      // Cost vs Market Value mode: Plot Current Market Value and Cumulative Investment Cost
      addLine(tr('当前总市值 (USD)', 'Current Market Value (USD)'), rows.map(r => ({ date: r.date, value: r.portfolio })), '#27a648', { lineWidth: 3 });
      addLine(tr('净投入成本 (USD)', 'Net Invested Cost (USD)'), rows.map(r => ({ date: r.date, value: r.buy_total })), '#e54d5e', { lineWidth: 2 });
    } else {
      // Portfolio line (always first, thick blue)
      addLine('Portfolio', rows.map(r => ({ date: r.date, value: isDollar ? r.portfolio : ((r.portfolio||1)-1)*100 })), '#8fca5b', { lineWidth: 3 });

      if (returnsMode === 'cf') {
        // Cash flow mirror: all benchmark lines in dollars
        let ci = 0;
        Object.entries(cfBenchmarks).forEach(([symbol, bm]) => {
          const bmRows = bm.rows || [];
          const bmByDate = {};
          bmRows.forEach(r => {
            bmByDate[r.date] = numValue(r, ['adjusted_benchmark_value', 'benchmark_value', 'benchmark']);
          });
          const lineData = rows.map(r => ({ date: r.date, value: bmByDate[r.date] || null }));
          const isSpy = symbol === 'SPY';
          addLine(isEn() ? symbol : (BENCH_CN[symbol] || symbol), lineData, isSpy ? '#f97316' : CF_COLORS[ci % CF_COLORS.length], {
            lineWidth: isSpy ? 2 : 1,
            dashed: isSpy,
          });
          if (!isSpy) ci++;
        });
      } else {
        // TWR mode: multi-benchmark lines in percent
        if (multiData.benchmarks) {
          multiData.benchmarks.forEach((b, i) => {
            const lineData = rows.map(r => {
              const mr = multiData.rows?.find(m => m.date === r.date);
              return { date: r.date, value: mr ? ((mr[b.symbol] || 1) - 1) * 100 : null };
            });
            addLine(b.symbol, lineData, TWR_COLORS[i % TWR_COLORS.length], { lineWidth: 1 });
          });
        }
      }
    }  }

  function setModeButtonState(activeId) {
    ['twrMode', 'cfMirrorMode', 'costValueMode'].forEach(id => {
      const button = document.getElementById(id);
      const active = id === activeId;
      button.classList.toggle('active', active);
      button.setAttribute('aria-selected', active ? 'true' : 'false');
      button.setAttribute('aria-pressed', active ? 'true' : 'false');
    });
  }

  document.getElementById('twrMode').addEventListener('click', () => {
    returnsMode = 'twr';
    setModeButtonState('twrMode');
    document.getElementById('chartModeLabel').textContent = 'TWR';
    document.getElementById('chartSubtitle').textContent = tr('剔除现金流影响，衡量策略本身表现。', 'Removes cash-flow effects to measure strategy performance.');
    renderChart();
  });
  document.getElementById('cfMirrorMode').addEventListener('click', () => {
    returnsMode = 'cf';
    setModeButtonState('cfMirrorMode');
    document.getElementById('chartModeLabel').textContent = tr('现金流镜像', 'Cash-Flow Mirror');
    document.getElementById('chartSubtitle').textContent = tr(
      '按你的真实买卖日期和金额重放：Portfolio=持仓市值+累计卖出现金；各基准=同日买入/卖出等额基准。纵轴为 USD 总价值，不是收益率。',
      'Replays your actual trade dates and amounts: Portfolio = holding value plus cumulative sale proceeds; each benchmark buys/sells the same amount on the same date. The y-axis is total USD value, not return percentage.'
    );
    renderChart();
  });
  document.getElementById('costValueMode').addEventListener('click', () => {
    returnsMode = 'cv';
    setModeButtonState('costValueMode');
    document.getElementById('chartModeLabel').textContent = tr('投入成本 vs 总市值', 'Cost vs Market Value');
    document.getElementById('chartSubtitle').textContent = tr(
      '净投入成本(买入-卖出)与当前持仓总市值的对比线图。纵轴为美元(USD)。',
      'Line chart comparing net invested cost (buys minus sells) with current holding market value. The y-axis is USD.'
    );
    renderChart();
  });

  document.getElementById('returnsRange').addEventListener('change', () => renderChart());

  window.addEventListener('resize', () => {
    if (chart) chart.resize(document.getElementById('returnsChart').clientWidth, 420);
  });

  // Kick off
  renderChart();

  // ── AI 解读 ──
  async function loadReturnsAI() {
    const btn = document.querySelector("#aiReturnsBtn");
    const status = document.querySelector("#aiReturnsStatus");
    const result = document.querySelector("#aiReturnsResult");
    btn.disabled = true;
    btn.innerHTML = `<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> ${tr('AI 分析中...', 'AI analyzing...')}`;
    status.innerHTML = "";
    result.style.display = "none";
    try {
      const lang = currentLang();
      const resp = await fetch("/api/ai/returns-explanation", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ lang }),
      });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();
      document.querySelector("#aiReturnsText").textContent = data.explanation;
      document.querySelector("#aiReturnsPeriod").textContent = data.period || "";
      btn.innerHTML = `<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-ai"></use></svg> ${tr('AI 解读', 'AI Analysis')}`;
      status.innerHTML = "";
      result.style.display = "block";
    } catch(e) {
      status.innerHTML = `<span style="color:var(--negative)">${tr('AI 分析失败: ', 'AI analysis failed: ')}${e.message}</span>`;
      btn.innerHTML = `<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-ai"></use></svg> ${tr('AI 解读', 'AI Analysis')}`;
    } finally {
      btn.disabled = false;
    }
  }
