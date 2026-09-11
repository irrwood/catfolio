(async () => {
  const $ = id => document.getElementById(id);
  const fmt = (v, suffix = '') => v == null ? '—' : Number(v).toFixed(2) + suffix;
  function insight(d) {
    if (d.status === 'unavailable') return '行情暂不可用。';
    if (d.stale) return `日线停留在 ${d.as_of}，暂不生成当前高波动提示。`;
    if (d.exposure_pct == null) return '暂无完整持仓市值，暂时无法计算半导体暴露。';
    if (d.exposure_pct === 0) return '当前持仓未识别到半导体直接暴露。';
    const high = ['Fear', 'Panic'].includes(d.regime);
    return `${d.portfolio_mode === 'demo' ? '演示组合' : '你的组合'}有 ${d.exposure_pct.toFixed(1)}% 暴露于${high ? '当前高波动半导体板块' : '半导体板块'}。当前状态：${d.regime}。`;
  }
  try {
    const response = await fetch('/api/volatility/semiconductors');
    if (!response.ok) throw new Error('fetch failed');
    const d = await response.json();
    if ($('today-volatility-insight')) $('today-volatility-insight').textContent = insight(d);
    if (!$('volatility-chart')) return;
    $('volatility-insight').textContent = insight(d);
    if (d.status === 'unavailable') {
      $('volatility-status').textContent = '暂无行情数据';
      $('volatility-chart-note').hidden = false;
      $('volatility-chart-note').textContent = '暂无历史数据';
      return;
    }
    $('volatility-status').textContent = `${d.as_of}${d.stale ? ' · 已过期' : ''}`;
    $('sentiment-score').textContent = d.score ?? '—';
    $('sentiment-label').textContent = d.score == null ? '至少需要20条日线' : d.score < 20 ? '极度恐惧' : d.score < 40 ? '恐惧' : d.score <= 60 ? '中性' : d.score <= 80 ? '贪婪' : '极度贪婪';
    $('sentiment-meter').title = `基于 ${d.sample_count}/252 个交易日`;
    if (d.score != null) {
      $('sentiment-meter').setAttribute('aria-valuenow', d.score);
      $('sentiment-meter').setAttribute('aria-valuetext', `${d.score}，${$('sentiment-label').textContent}`);
    }
    else $('sentiment-meter').setAttribute('aria-valuetext', '不足20条日线，暂无评分');
    $('dial-fill').style.visibility = d.score == null ? 'hidden' : 'visible';
    $('dial-fill').style.strokeDasharray = `${d.score ?? 0} 100`;
    $('sentiment-regime').textContent = d.regime;
    $('sentiment-regime').className = ['Fear', 'Panic'].includes(d.regime) ? 'negative' : d.regime === 'Risk-on' ? 'positive' : '';
    const metrics = [['VXSMH', fmt(d.close)], ['20日均值', fmt(d.ma20)], ['20日 Z-Score', fmt(d.z20)], [d.sample_count < 252 ? '可用历史分位数' : '1年分位数', fmt(d.sample_count < 252 ? d.available_percentile : d.percentile, '%')], ['VXSMH 1日变化', `${fmt(d.change)} / ${fmt(d.change_pct, '%')}`], ['SMH 1日涨跌', fmt(d.price_change_pct, '%')]];
    for (const [label, value] of metrics) {
      const cell = document.createElement('div');
      const name = document.createElement('span'); name.textContent = label;
      const number = document.createElement('strong'); number.textContent = value;
      cell.append(name, number); $('volatility-metrics').append(cell);
    }
    $('volatility-chart-note').hidden = d.aligned;
    $('volatility-chart-note').textContent = d.aligned ? '' : '日期未对齐，市场状态暂不可用';
    const chart = echarts.init($('volatility-chart'));
    function draw(count) {
      const rows = d.history.slice(-count);
      chart.setOption({animation: !matchMedia('(prefers-reduced-motion: reduce)').matches, backgroundColor: 'transparent', color: ['#708cff', '#a7a7a7', '#c9d4ff'], legend: {data: ['VXSMH', 'MA20', 'SMH 成交量'], textStyle:{color:'#888'}}, tooltip:{trigger:'axis'}, grid:[{left:45,right:15,top:40,height:'52%'},{left:45,right:15,top:'74%',height:'16%'}], xAxis:[{type:'category',data:rows.map(r=>r.date),axisLabel:{show:false},axisLine:{lineStyle:{color:'#EAEBED'}}},{type:'category',gridIndex:1,data:rows.map(r=>r.date),axisLabel:{color:'#888',formatter:v=>v.slice(5)},axisLine:{lineStyle:{color:'#EAEBED'}}}], yAxis:[{type:'value',scale:true,splitLine:{lineStyle:{color:'#EAEBED'}}},{type:'value',gridIndex:1,splitNumber:2,axisLabel:{formatter:v=>(v/1e6).toFixed(0)+'M'},splitLine:{show:false}}],series:[{name:'VXSMH',type:'line',symbol:'none',data:rows.map(r=>r.close)},{name:'MA20',type:'line',symbol:'none',data:rows.map(r=>r.ma20)},{name:'SMH 成交量',type:'bar',xAxisIndex:1,yAxisIndex:1,data:rows.map(r=>r.volume)}]});
    }
    draw(63);
    document.querySelectorAll('[data-vol-range]').forEach(button => button.addEventListener('click', () => {
      document.querySelectorAll('[data-vol-range]').forEach(b => b.setAttribute('aria-pressed', String(b === button)));
      draw(Number(button.dataset.volRange));
    }));
    new ResizeObserver(() => chart.resize()).observe($('volatility-chart'));
  } catch (error) {
    for (const id of ['volatility-status', 'volatility-chart-note', 'volatility-insight', 'today-volatility-insight']) if ($(id)) $(id).textContent = '数据暂不可用，请稍后刷新。';
  }
})();
