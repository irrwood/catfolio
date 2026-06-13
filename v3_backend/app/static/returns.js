const BENCH_CN = { "SPY": "标普500", "QQQ": "纳斯达克100", "VTI": "美国全市场", "VOO": "先锋标普500", "DIA": "道琼斯30", "IWM": "罗素2000", "VEU": "全球除美", "GLD": "黄金" };

  let currentMode = 'twr';
  let chart = null;
  let chartSeries = [];

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
    if (currentMode === 'cf') {
      const raw = cfData.rows || [];
      if (!raw.length) return { rows: [], unit: '$' };
      const mapped = raw.map(r => ({
        date: r.date,
        portfolio: numValue(r, ['adjusted_portfolio_value', 'portfolio_value', 'portfolio'], 0),
      }));
      return { rows: filterRows(mapped), unit: '$' };
    } else if (currentMode === 'cv') {
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
      priceFormat: opts.priceFormat || ((currentMode === 'cf' || currentMode === 'cv') ? { type: 'custom', formatter: fmtDollar } : { type: 'custom', formatter: fmtPct }),
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
          <i class="fa-solid fa-circle-exclamation" style="font-size: 32px; margin-bottom: 12px; color: var(--accent);"></i>
          <div style="font-size: 15px; font-weight: 600; margin-bottom: 6px; color: var(--ink);">需要交易流水数据</div>
          <div style="font-size: 12px; max-width: 320px; line-height: 1.6;">
            ${currentMode === 'cf' || currentMode === 'cv' ? '此模式依赖交易流水。请在环境配置中设置 HELM_DATA_DIR 目录以导入 Trading 212 交易历史 CSV 文件。' : '暂无可用收益数据。'}
          </div>
        </div>
      `;
      return;
    }

    const isDollar = data.unit === '$';
    buildChart();

      if (currentMode === 'cv') {
      // Cost vs Market Value mode: Plot Current Market Value and Cumulative Investment Cost
      addLine('当前总市值 (USD)', rows.map(r => ({ date: r.date, value: r.portfolio })), '#27a648', { lineWidth: 3 });
      addLine('净投入成本 (USD)', rows.map(r => ({ date: r.date, value: r.buy_total })), '#e54d5e', { lineWidth: 2 });
    } else {
      // Portfolio line (always first, thick blue)
      addLine('Portfolio', rows.map(r => ({ date: r.date, value: isDollar ? r.portfolio : ((r.portfolio||1)-1)*100 })), '#4C72FF', { lineWidth: 3 });

      if (currentMode === 'cf') {
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
          addLine(BENCH_CN[symbol] || symbol, lineData, isSpy ? '#f97316' : CF_COLORS[ci % CF_COLORS.length], {
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

  document.getElementById('twrMode').addEventListener('click', () => {
    currentMode = 'twr';
    document.getElementById('twrMode').classList.add('active');
    document.getElementById('cfMirrorMode').classList.remove('active');
    document.getElementById('costValueMode').classList.remove('active');
    document.getElementById('chartModeLabel').textContent = 'TWR';
    document.getElementById('chartSubtitle').textContent = '剔除现金流影响，衡量策略本身表现。';
    renderChart();
  });
  document.getElementById('cfMirrorMode').addEventListener('click', () => {
    currentMode = 'cf';
    document.getElementById('cfMirrorMode').classList.add('active');
    document.getElementById('twrMode').classList.remove('active');
    document.getElementById('costValueMode').classList.remove('active');
    document.getElementById('chartModeLabel').textContent = '现金流镜像';
    document.getElementById('chartSubtitle').textContent = '按你的真实买卖日期和金额重放：Portfolio=持仓市值+累计卖出现金；各基准=同日买入/卖出等额基准。纵轴为 USD 总价值，不是收益率。';
    renderChart();
  });
  document.getElementById('costValueMode').addEventListener('click', () => {
    currentMode = 'cv';
    document.getElementById('costValueMode').classList.add('active');
    document.getElementById('twrMode').classList.remove('active');
    document.getElementById('cfMirrorMode').classList.remove('active');
    document.getElementById('chartModeLabel').textContent = '投入成本 vs 总市值';
    document.getElementById('chartSubtitle').textContent = '净投入成本(买入-卖出)与当前持仓总市值的对比线图。纵轴为美元(USD)。';
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
    btn.innerHTML = `<i class="fa-solid fa-spinner fa-spin"></i> AI 分析中...`;
    status.innerHTML = "";
    result.style.display = "none";
    try {
      const resp = await fetch("/api/ai/returns-explanation", { method: "POST" });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();
      document.querySelector("#aiReturnsText").textContent = data.explanation;
      document.querySelector("#aiReturnsPeriod").textContent = data.period || "";
      btn.innerHTML = `<i class="fa-solid fa-robot"></i> AI 解读`;
      status.innerHTML = "";
      result.style.display = "block";
    } catch(e) {
      status.innerHTML = `<span style="color:var(--negative)">AI 分析失败: ${e.message}</span>`;
      btn.innerHTML = `<i class="fa-solid fa-robot"></i> AI 解读`;
    } finally {
      btn.disabled = false;
    }
  }
