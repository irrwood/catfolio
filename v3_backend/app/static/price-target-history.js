(async()=>{
'use strict';
const $=id=>document.getElementById(id), money=n=>n==null?'—':'$'+n.toFixed(2);
let chart,records,range='all';
try{
const response=await fetch('/api/price-target-history?'+new URLSearchParams({symbol:new URLSearchParams(location.search).get('symbol')||'AAPL'}));if(!response.ok)throw Error('历史数据暂不可用，请检查 T7 数据盘。');
const entry=await response.json();records=entry.records;if(!records.length||!records.some(r=>r.sourceChartSharePrice!=null||r.targetConsensus!=null))throw Error('来源暂无目标价和股价，请查看下方推荐建议。');
const last=records.at(-1);
$('pt-status').textContent=`${records[0].chartDateLabel} — ${last.chartDateLabel} · ${records.length} 个来源数据点${entry.warnings?.length?' · 部分异常目标价已留空':''}`;
$('pt-metrics').innerHTML=[['图表股价',money(last.sourceChartSharePrice)],['共识目标价',money(last.targetConsensus)],['目标价范围',money(last.targetLow)+'–'+money(last.targetHigh)]].map(([label,value])=>`<div><span>${label}</span><strong>${value}</strong><small>来源最新标签 ${last.chartDateLabel}</small></div>`).join('');
$('pt-source').innerHTML=`来源：<a href="${entry.sourceURL}" target="_blank" rel="noopener">MarketBeat · ${entry.symbol} ↗</a>　采集于 ${entry.retrievedAt.slice(0,10)}　·　<a href="/api/price-target-history?symbol=${encodeURIComponent(entry.symbol)}" target="_blank">查看数据 JSON ↗</a>`;
$('pt-rows').innerHTML=records.map(r=>`<tr><td>${r.chartDateLabel}</td><td>${money(r.sourceChartSharePrice)}</td><td>${money(r.targetConsensus)}</td><td>${money(r.targetLow)}</td><td>${money(r.targetHigh)}</td></tr>`).join('');
chart=echarts.init($('pt-chart'),null,{renderer:'svg'});
function draw(){
const end=new Date(last.chartDateLabel+'T00:00:00Z'),start=new Date(end);if(range!=='all')start.setUTCMonth(start.getUTCMonth()-Number(range));
const rows=range==='all'?records:records.filter(r=>r.chartDateLabel>=start.toISOString().slice(0,10));
const points=key=>rows.map(r=>[r.chartDateLabel,r[key]]);
chart.setOption({animation:false,textStyle:{fontFamily:'Nunito Local, Nunito, sans-serif'},grid:{left:60,right:20,top:25,bottom:45},tooltip:{trigger:'axis',confine:true,backgroundColor:'#fff',borderColor:'#EAEBED',padding:16,extraCssText:'box-shadow:none;border-radius:12px;',axisPointer:{type:'line',lineStyle:{color:'#EAEBED'}},formatter:params=>{const r=rows[params[0].dataIndex];return `<strong>${r.chartDateLabel}</strong><br/>股价（来源图表）　${money(r.sourceChartSharePrice)}<br/>共识目标价　${money(r.targetConsensus)}<br/>最低目标价　${money(r.targetLow)}<br/>最高目标价　${money(r.targetHigh)}`;}},xAxis:{type:'time',boundaryGap:false,axisLine:{show:false},axisTick:{show:false},splitLine:{show:false},axisLabel:{color:'#888',hideOverlap:true,formatter:'{yyyy}/{MM}'}},yAxis:{type:'value',min:value=>Math.floor(value.min/50)*50,axisLabel:{color:'#888',formatter:'${value}'},splitLine:{lineStyle:{color:'#EAEBED'}},axisLine:{show:false},axisTick:{show:false}},series:[{name:'区间底部',type:'line',stack:'target-range',data:points('targetLow'),symbol:'none',lineStyle:{opacity:0},areaStyle:{opacity:0},silent:true},{name:'目标价范围',type:'line',stack:'target-range',data:rows.map(r=>[r.chartDateLabel,r.targetHigh==null||r.targetLow==null?null:r.targetHigh-r.targetLow]),symbol:'none',lineStyle:{opacity:0},areaStyle:{color:'rgba(112,140,255,0.12)',opacity:1},silent:true},{name:'共识目标价',type:'line',data:points('targetConsensus'),showSymbol:false,lineStyle:{color:'#a8b7f0',width:3},itemStyle:{color:'#a8b7f0'},z:3},{name:'股价',type:'line',data:points('sourceChartSharePrice'),showSymbol:false,symbolSize:9,lineStyle:{color:'#708cff',width:4},itemStyle:{color:'#708cff'},z:4}]},true);
}
for(const b of document.querySelectorAll('[data-range]'))b.addEventListener('click',()=>{range=b.dataset.range;for(const btn of document.querySelectorAll('[data-range]'))btn.setAttribute('aria-pressed',String(btn===b));draw();});
draw();new ResizeObserver(()=>chart.resize()).observe($('pt-chart'));
}catch(e){$('pt-status').textContent=e.message;$('pt-chart').textContent='未加载图表数据';}
})();
