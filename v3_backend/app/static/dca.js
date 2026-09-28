(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const t = value => Object.entries(window.CATFOLIO_PAGE_I18N || {}).reduce((text, [zh, en]) => text.split(zh).join(en), String(value));
  const money = value => value == null ? '—' : new Intl.NumberFormat('en-US', {style: 'currency', currency: 'USD', maximumFractionDigits: 2}).format(value);
  const percent = value => value == null ? '—' : `${value > 0 ? '+' : ''}${(value * 100).toFixed(2)}%`;
  const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;'}[c]));
  const defaults = {sma_enabled: true, price_low: .85, price_high: 1.15, rv_enabled: true, rv_operator: 'lte', rv_threshold: 40, er_enabled: true, er_operator: 'gte', er_threshold: .3, drawdown_enabled: true, drawdown_threshold: .2, cash_reserve: 30, max_position: 20, min_multiplier: .5, max_multiplier: 3, cooldown: 7};
  const storageKey = 'catfolio.dca.config.v1';
  let conditions = {...defaults}, market = null, marketSequence = 0, result = null, chart = null, chartMode = 'value', allTrades = false, runSequence = 0, dirty = false;
  const dialog = $('conditionsDialog');
  const formatOutput = (input, unit) => unit === '$' ? money(Number(input.value)).replace('.00', '') : `${Number(input.value).toFixed(Number(input.step) < 1 ? 2 : 0)}${unit}`;
  function syncOutputs() {
    document.querySelectorAll('[data-output]').forEach(output => { output.textContent = formatOutput($(output.dataset.output), output.dataset.unit || ''); });
  }
  function setFields(values) {
    Object.entries(values).forEach(([key, value]) => {
      const input = $(key);
      if (!input) return;
      if (input.type === 'checkbox') input.checked = Boolean(value);
      else input.value = value;
    });
    syncOutputs();
  }
  function readConditions() {
    return Object.fromEntries(Object.keys(defaults).map(key => {
      const input = $(key);
      return [key, input.type === 'checkbox' ? input.checked : key.endsWith('_operator') ? input.value : Number(input.value)];
    }));
  }
  function configuration() {
    return {...conditions, symbol: $('symbol').value.trim().toUpperCase(), start: $('start').value, end: $('end').value,
      base_amount: Number($('base_amount').value), initial_cash: Number($('initial_cash').value), frequency: $('frequency').value,
      rv_threshold: conditions.rv_threshold / 100, cash_reserve: conditions.cash_reserve / 100, max_position: conditions.max_position / 100};
  }
  function summary() {
    $('conditionCount').textContent = ['sma_enabled', 'rv_enabled', 'er_enabled', 'drawdown_enabled'].filter(key => conditions[key]).length;
    $('ruleSummary').innerHTML = [`${money(Number($('base_amount').value))} / ${$('frequency').value === 'weekly' ? '周' : '月'}`, `投入倍数 ${conditions.min_multiplier}–${conditions.max_multiplier}×`, `现金储备 ${conditions.cash_reserve}%`, `单资产上限 ${conditions.max_position}%`, `加仓冷却 ${conditions.cooldown} 天`].map(value => `<span>${esc(value)}</span>`).join('');
  }
  function persist() {
    try { localStorage.setItem(storageKey, JSON.stringify({conditions, fields: {symbol: $('symbol').value, initial_cash: $('initial_cash').value, base_amount: $('base_amount').value, frequency: $('frequency').value, start: $('start').value, end: $('end').value}})); } catch (_) { /* Storage is optional. */ }
  }
  function changed() {
    dirty = true;
    runSequence += 1; // Never present an in-flight response as the new configuration.
    $('runDca').disabled = false;
    $('runDca').textContent = '开始回测 ↗';
    $('runStatus').textContent = result ? '参数已修改，下方保留上次结果；点击「开始回测」更新。' : '参数已更新，点击「开始回测」查看结果。';
    $('runStatus').classList.remove('negative');
    summary(); syncOutputs(); persist();
  }
  async function request(url, options) {
    const response = await fetch(url, options);
    const data = await response.json();
    if (!response.ok) {
      const detail = Array.isArray(data.detail) ? data.detail.map(item => item.msg).join('；') : data.detail || data.error || '请求失败';
      throw new Error(detail);
    }
    return data;
  }
  function signed(id, value, formatter = percent) {
    $(id).textContent = formatter(value);
    $(id).classList.toggle('positive', value != null && value > 0);
    $(id).classList.toggle('negative', value != null && value < 0);
  }
  async function loadMarket() {
    const sequence = ++marketSequence;
    const symbol = $('symbol').value.trim().toUpperCase();
    $('symbol').value = symbol;
    market = null;
    $('marketStatus').textContent = `正在读取 ${symbol} 的历史行情…`;
    $('marketStatus').classList.remove('negative');
    [1,3,5].forEach(year => signed(`return${year}`, null));
    $('latestPrice').textContent = '—';
    document.querySelectorAll('[data-symbol]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.symbol === symbol)));
    currentConditions();
    try {
      const data = await request(`/api/dca/market?symbol=${encodeURIComponent(symbol)}`);
      if (sequence !== marketSequence) return;
      market = data;
      [1,3,5].forEach(year => signed(`return${year}`, data.returns[String(year)]));
      $('latestPrice').textContent = money(data.price);
      $('marketStatus').textContent = `${data.demo ? '演示数据 · ' : ''}${data.source} · ${data.count.toLocaleString()} 个交易日 · 截至 ${data.as_of}（复权口径）`;
      // Set a useful covered interval only on first use. Keep user choices on symbol changes.
      if (!$('start').value) {
        const candidate = new Date(`${data.as_of}T12:00:00Z`);
        candidate.setUTCFullYear(candidate.getUTCFullYear() - 3);
        $('start').value = [candidate.toISOString().slice(0,10), data.first_date].sort().at(-1);
      }
      if (!$('end').value) $('end').value = data.as_of;
      currentConditions(); persist();
      return true;
    } catch (error) {
      if (sequence !== marketSequence) return;
      $('marketStatus').textContent = error.message;
      $('marketStatus').classList.add('negative');
      return false;
    }
  }
  function currentConditions() {
    $('conditionSymbol').textContent = $('symbol').value.toUpperCase();
    const c = readConditions(), obs = market?.indicators || {};
    document.querySelectorAll('.dca-condition-row').forEach(row => {
      const enabled = row.querySelector('[role="switch"]').checked;
      row.querySelectorAll('input[type="range"], select').forEach(input => { input.disabled = !enabled; });
    });
    const show = (id, enabled, value, formatted, status) => {
      $(id).innerHTML = `${esc(value == null ? '—' : formatted)}<small>${esc(!enabled ? '未启用' : value == null ? '历史不足 / 未加载' : status)}</small>`;
    };
    show('currentSma', c.sma_enabled, obs.price_ratio, `${obs.price_ratio?.toFixed(2)}×`, obs.price_ratio <= c.price_low ? '低于区间 · 加仓信号' : obs.price_ratio >= c.price_high ? '高于区间 · 减量信号' : '区间内 · 基础投入');
    show('currentRv', c.rv_enabled, obs.rv20, `${(obs.rv20 * 100).toFixed(1)}%`, (c.rv_operator === 'lte' ? obs.rv20 <= c.rv_threshold / 100 : obs.rv20 >= c.rv_threshold / 100) ? '满足' : '未满足 · 减量信号');
    show('currentEr', c.er_enabled, obs.er20, obs.er20?.toFixed(2), (c.er_operator === 'lte' ? obs.er20 <= c.er_threshold : obs.er20 >= c.er_threshold) ? '满足' : '未满足 · 减量信号');
    show('currentDrawdown', c.drawdown_enabled, obs.drawdown, percent(obs.drawdown), obs.drawdown <= -c.drawdown_threshold ? '达到加仓门槛' : '未达到门槛');
    $('conditionAsOf').textContent = market ? `当前指标截至 ${market.as_of}${market.demo ? ' · 合成演示行情' : ''}。历史回测按前一交易日的指标重新判断。` : '当前指标尚未加载。历史回测按前一交易日的指标重新判断。';
  }
  function renderResult() {
    const m = result.metrics;
    signed('totalReturn', m.return); signed('totalProfit', m.profit, money); signed('annualReturn', m.xirr); signed('maxDrawdown', m.max_drawdown);
    Object.entries({contributed: m.contributed, totalValue: m.value, holdings: m.holdings, cash: m.cash}).forEach(([id,value]) => $(id).textContent = money(value));
    $('buyCount').textContent = m.buy_count.toLocaleString();
    $('shares').textContent = m.shares.toLocaleString('en-US', {maximumFractionDigits: 4});
    $('resultPeriod').textContent = `${result.config.symbol} · ${result.start} — ${result.end}${result.demo ? ' · 演示' : ''}`;
    $('tradeCount').textContent = `· ${result.trades.length} 期`;
    $('exportDca').disabled = false;
    renderTrades(); renderChart();
  }
  function renderTrades() {
    const rows = [...result.trades].reverse();
    $('tradeRows').innerHTML = rows.slice(0, allTrades ? rows.length : 8).map(row => `<tr><td>${esc(row.date)}</td><td>${money(row.price)}</td><td>${money(row.deposit)}</td><td>${money(row.amount)}</td><td>${row.multiplier.toFixed(2)}×</td><td>${money(row.cash)}</td><td>${esc(row.reason)}</td></tr>`).join('');
    $('moreTrades').hidden = rows.length <= 8;
    $('moreTrades').textContent = allTrades ? '收起明细' : `展开全部 ${rows.length} 期`;
  }
  function renderChart() {
    if (!result) return;
    if (!window.echarts) {
      $('dcaChart').textContent = '图表组件加载失败，请刷新页面。明细表仍可查看全部数据。';
      return;
    }
    if (!chart) { $('dcaChart').replaceChildren(); chart = echarts.init($('dcaChart')); }
    const css = getComputedStyle(document.documentElement), color = name => css.getPropertyValue(name).trim();
    const drawdown = chartMode === 'drawdown';
    const series = drawdown ? [['drawdown','策略回撤','#708cff']] : [['contributed','累计入金','#a7a7a7'], ['value','策略总资产','#708cff'], ['holdings','持仓市值','#2f8a3e'], ['baseline','固定定投','#a9b8fa'], ['cash','现金余额','#c5c5c5']];
    chart.setOption({animation: !matchMedia('(prefers-reduced-motion: reduce)').matches, backgroundColor: 'transparent',
      textStyle: {fontFamily: 'Nunito Local, Nunito, sans-serif'},
      legend: {top: 0, left: 0, icon: 'roundRect', itemWidth: 12, itemHeight: 3, textStyle: {color: color('--muted')}, selected: {[t('现金余额')]: false}},
      grid: {left: 10, right: 12, top: innerWidth < 450 ? 90 : 65, bottom: 55, containLabel: true},
      tooltip: {trigger: 'axis', renderMode: 'richText', backgroundColor: color('--panel'), borderColor: color('--line-strong'), textStyle: {color: color('--ink')}, valueFormatter: value => drawdown ? percent(value) : money(value)},
      xAxis: {type: 'category', data: result.curve.map(row => row.date), boundaryGap: false, axisLine: {lineStyle: {color: color('--line-strong')}}, axisTick: {show: false}, axisLabel: {color: color('--muted'), formatter: value => value.slice(0,7)}, axisPointer: {lineStyle: {color: color('--line-strong')}}},
      yAxis: {type: 'value', axisLabel: {color: color('--muted'), formatter: value => drawdown ? `${(value*100).toFixed(0)}%` : `$${Math.abs(value) >= 1000 ? `${(value/1000).toFixed(0)}k` : value}`}, splitLine: {lineStyle: {color: color('--line-strong')}}},
      dataZoom: [{type: 'inside', zoomOnMouseWheel: 'ctrl'}, {type: 'slider', bottom: 4, height: 18, borderColor: color('--line'), fillerColor: 'rgba(112,140,255,.10)', textStyle: {color: color('--muted')}}],
      series: series.map(([key,name,lineColor]) => ({name: t(name), type: 'line', showSymbol: false, smooth: false, data: result.curve.map(row => row[key]), lineStyle: {width: key === 'value' ? 2.5 : 1.5, color: lineColor, type: key === 'baseline' ? 'dashed' : 'solid'}, itemStyle: {color: lineColor}}))}, true);
    $('dcaChart').setAttribute('aria-label', `${result.config.symbol} ${drawdown ? '剔除入金后的回撤' : '定投资金'}图，${result.start} 至 ${result.end}；数据可在下方表格查看并导出。`);
  }
  async function run() {
    if (!$('dcaForm').reportValidity()) return;
    const config = configuration(), sequence = ++runSequence;
    $('runDca').disabled = true;
    $('runDca').textContent = '正在回测…';
    $('runStatus').classList.remove('negative');
    $('runStatus').textContent = '正在读取历史行情并逐期计算…';
    try {
      const data = await request('/api/dca/backtest', {method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(config)});
      if (sequence !== runSequence) return;
      result = data; dirty = false; allTrades = false;
      renderResult(); persist();
      $('runStatus').textContent = data.warnings.length ? data.warnings.join(' ') : `回测完成 · ${data.source} · ${data.trades.length} 期入金，${data.metrics.buy_count} 次买入。`;
    } catch (error) {
      if (sequence !== runSequence) return;
      $('runStatus').textContent = `${error.message}${result ? '；下方保留上次成功结果。' : ''}`;
      $('runStatus').classList.add('negative');
    } finally {
      if (sequence === runSequence) { $('runDca').disabled = false; $('runDca').textContent = '开始回测 ↗'; }
    }
  }
  $('dcaForm').addEventListener('submit', event => { event.preventDefault(); run(); });
  $('dcaForm').addEventListener('input', changed);
  $('symbol').addEventListener('change', loadMarket);
  document.querySelectorAll('[data-symbol]').forEach(button => button.addEventListener('click', () => { $('symbol').value = button.dataset.symbol; changed(); loadMarket(); }));
  $('openConditions').addEventListener('click', () => { setFields(conditions); currentConditions(); dialog.showModal(); });
  const close = () => { dialog.close(); setFields(conditions); $('openConditions').focus(); };
  $('closeConditions').addEventListener('click', close);
  $('cancelConditions').addEventListener('click', close);
  dialog.addEventListener('cancel', () => setFields(conditions));
  $('conditionsForm').addEventListener('input', () => { syncOutputs(); currentConditions(); });
  $('resetConditions').addEventListener('click', () => { setFields(defaults); currentConditions(); });
  $('conditionsForm').addEventListener('submit', event => { event.preventDefault(); conditions = readConditions(); changed(); close(); });
  $('moreTrades').addEventListener('click', () => { allTrades = !allTrades; renderTrades(); });
  document.querySelectorAll('[data-chart]').forEach(button => button.addEventListener('click', () => {
    chartMode = button.dataset.chart;
    document.querySelectorAll('[data-chart]').forEach(item => { item.classList.toggle('active', item === button); item.setAttribute('aria-pressed', String(item === button)); });
    renderChart();
  }));
  $('exportDca').addEventListener('click', () => {
    if (!result) return;
    const rows = [['标的', '日期', '信号日期', '复权价格', '入金', '实际买入', '等效份额', '实际倍数', '目标倍数', '现金余额', '原因'], ...result.trades.map(row => [result.config.symbol, row.date, row.signal_date, row.price, row.deposit, row.amount, row.shares, row.multiplier, row.target_multiplier, row.cash, row.reason])];
    const csv = '\uFEFF' + rows.map(row => row.map(value => `"${String(value ?? '').replaceAll('"', '""')}"`).join(',')).join('\r\n');
    const url = URL.createObjectURL(new Blob([csv], {type:'text/csv;charset=utf-8;'}));
    const a = document.createElement('a'); a.href = url; a.download = `Catfolio-DCA-${result.config.symbol}-${result.end}.csv`; a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  });
  new ResizeObserver(() => chart?.resize()).observe($('dcaChart'));
  new MutationObserver(() => renderChart()).observe(document.documentElement, {attributes: true, attributeFilter: ['class']});
  try {
    const saved = JSON.parse(localStorage.getItem(storageKey) || 'null');
    if (saved && saved.conditions && saved.fields) {
      conditions = {...defaults, ...Object.fromEntries(Object.entries(saved.conditions).filter(([key]) => key in defaults))};
      setFields(saved.fields);
    }
  } catch (_) { /* Recover from unavailable storage or an invalid draft. */ }
  setFields(conditions); syncOutputs(); summary();
  $('end').max = new Date().toISOString().slice(0,10);
  loadMarket().then(ready => { if (ready && !dirty) run(); });
})();
