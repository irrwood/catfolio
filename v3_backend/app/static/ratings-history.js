(async()=>{
const $=id=>document.getElementById(id), money=v=>v==null?'无匹配价格':'$'+v.toFixed(2);
try{
const response=await fetch('/api/ratings-history?'+new URLSearchParams({symbol:new URLSearchParams(location.search).get('symbol')||'AAPL'}));if(!response.ok)throw Error('推荐建议数据暂不可用，请检查数据盘。');
const data=await response.json(),records=data.records,last=records.at(-1);if(!last)throw Error('来源暂无有效的月度评级分布。');
$('ratings-status').textContent=`${records[0].chartDateLabel} — ${last.chartDateLabel} · ${records.length} 个月 · MarketBeat`;
$('ratings-metrics').innerHTML=`<div><span>最近月份评级数量</span><strong>${last.TotalRatings}</strong><small>${last.chartDateLabel}</small></div><div><span>买入 / 强烈买入</span><strong>${last.Buy} / ${last.StrongBuy}</strong><small>原始分类数量</small></div><div><span>同月图表股价</span><strong>${money(last.sourceChartSharePrice)}</strong><small>月度数值，非日收盘价</small></div>`;
$('ratings-rows').innerHTML=records.map(r=>`<tr><td>${r.chartDateLabel}</td><td>${r.Sell}</td><td>${r.Hold}</td><td>${r.Buy}</td><td>${r.StrongBuy}</td><td>${r.TotalRatings}</td><td>${money(r.sourceChartSharePrice)}</td></tr>`).join('');
const chart=echarts.init($('ratings-chart'),null,{renderer:'svg'});
let range='all';
function draw(){const rows=range==='all'?records:records.slice(-Number(range));
const categories=[['Sell','卖出','#e40014'],['Hold','持有','#eadba3'],['Buy','买入','#87c19a'],['StrongBuy','强烈买入','#2f8a3e']];
chart.setOption({animation:false,textStyle:{fontFamily:'Nunito Local, Nunito, sans-serif'},grid:{left:55,right:65,top:45,bottom:85},legend:{bottom:5,data:[...categories.map(c=>c[1]),'股价'],textStyle:{color:'#888'},itemWidth:18,itemHeight:9},tooltip:{trigger:'axis',confine:true,backgroundColor:'#fff',borderColor:'#EAEBED',padding:16,extraCssText:'box-shadow:none;border-radius:12px;',axisPointer:{type:'shadow',shadowStyle:{color:'rgba(0,0,0,.025)'}},formatter:params=>{const r=rows[params[0].dataIndex];return `<strong>${r.chartDateLabel.slice(0,7)}</strong><br/>强烈买入　${r.StrongBuy}<br/>买入　${r.Buy}<br/>持有　${r.Hold}<br/>卖出　${r.Sell}<br/>合计　${r.TotalRatings}<br/>股价　${money(r.sourceChartSharePrice)}`;}},xAxis:{type:'category',data:rows.map(r=>r.chartDateLabel),axisLabel:{color:'#888',hideOverlap:true,formatter:v=>v.slice(0,7)},axisTick:{show:false},axisLine:{lineStyle:{color:'#EAEBED'}}},yAxis:[{type:'value',name:'评级数量',min:0,minInterval:1,nameTextStyle:{color:'#888'},axisLabel:{color:'#888'},splitLine:{lineStyle:{color:'#EAEBED'}}},{type:'value',name:'股价 USD',min:0,nameTextStyle:{color:'#888'},axisLabel:{color:'#888',formatter:'${value}'},splitLine:{show:false}}],series:[...categories.map(([key,name,color])=>({type:'bar',name,stack:'ratings',data:rows.map(r=>r[key]),barMaxWidth:32,barCategoryGap:'18%',itemStyle:{color},emphasis:{focus:'series'}})),{name:'股价',type:'line',yAxisIndex:1,data:rows.map(r=>r.sourceChartSharePrice),connectNulls:false,showSymbol:false,symbolSize:8,lineStyle:{width:3,color:'#708cff'},itemStyle:{color:'#708cff'},z:5}]},true);
}
draw();new ResizeObserver(()=>chart.resize()).observe($('ratings-chart'));
for(const b of document.querySelectorAll('[data-rating-range]'))b.addEventListener('click',()=>{range=b.dataset.ratingRange;for(const x of document.querySelectorAll('[data-rating-range]'))x.setAttribute('aria-pressed',String(x===b));draw();});
}catch(e){$('ratings-status').textContent=e.message;}
})();
