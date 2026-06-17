  const $ = id => document.getElementById(id);
  const TEMPLATES = __TEMPLATES__;
  $("f_code").value = TEMPLATES.momentum;
  let equityChart = null, ddChart = null, activeRunId = null, themeReady = false;

  function applyTemplate() {
    const t = TEMPLATES[$("f_template").value];
    if (t) $("f_code").value = t;
  }
  async function importHoldings() {
    const status = $("runStatus");
    status.style.color = "var(--muted)"; status.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 读取持仓…';
    try {
      const data = await (await fetch("/api/strategy/holdings-universe?top=10")).json();
      if (data.symbols && data.symbols.length) {
        $("f_universe").value = data.symbols.join(", ");
        status.style.color = "var(--positive)"; status.innerHTML = '<i class="fa-solid fa-check"></i> 已导入 ' + data.symbols.length + ' 只标的';
      } else { status.innerHTML = "没有可导入的持仓"; }
    } catch (e) { status.style.color = "var(--negative)"; status.innerHTML = "导入失败"; }
  }

  function ensureTheme() {
    if (themeReady || !window.echarts) return;
    const axisDef = { axisLine:{lineStyle:{color:"rgba(128,128,128,0.28)"}}, splitLine:{lineStyle:{color:"rgba(128,128,128,0.14)"}} };
    window.echarts.registerTheme("catfolio", { categoryAxis: axisDef, valueAxis: axisDef });
    themeReady = true;
  }
  const fmtPct = v => (v === null || v === undefined) ? "—" : (v*100).toFixed(1) + "%";
  const fmtNum = v => (v === null || v === undefined) ? "—" : Number(v).toFixed(2);
  const fmtDate = ts => new Date(ts*1000).toLocaleDateString("zh-CN", {month:"short", day:"numeric", hour:"2-digit", minute:"2-digit"});

  async function loadRuns() {
    const res = await fetch("/api/strategy/runs");
    const data = await res.json();
    const el = $("runList");
    if (!data.runs.length) { el.innerHTML = '<div style="font-size:12px;color:var(--muted);">还没有回测记录</div>'; return; }
    el.innerHTML = data.runs.map(r => {
      const cagr = r.metrics && r.metrics.cagr != null ? fmtPct(r.metrics.cagr) : "—";
      return '<div class="run-item ' + (r.id===activeRunId?'active':'') + '" onclick="loadRun(' + r.id + ')">' +
        '<div class="rn"><span>' + escapeHtml(r.name) + '</span><span class="run-del" onclick="event.stopPropagation();delRun(' + r.id + ')"><i class="fa-solid fa-trash"></i></span></div>' +
        '<div class="rm">CAGR ' + cagr + ' · ' + fmtDate(r.created_at) + '</div></div>';
    }).join("");
  }
  function escapeHtml(s){ return String(s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

  function gatherConfig() {
    return {
      name: $("f_name").value,
      code: $("f_code").value,
      universe: $("f_universe").value.split(",").map(s=>s.trim()).filter(Boolean),
      benchmark: $("f_benchmark").value.trim(),
      capital: Number($("f_capital").value),
      fee_bps: Number($("f_fee").value),
      rebalance: $("f_rebalance").value,
      start: $("f_start").value.trim(),
      end: $("f_end").value.trim(),
    };
  }

  async function runBacktest() {
    const btn = $("runBtn"), status = $("runStatus");
    btn.disabled = true; status.style.color = "var(--muted)";
    status.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 正在拉取历史并回测…';
    try {
      const res = await fetch("/api/strategy/run", { method:"POST", headers:{"Content-Type":"application/json"}, body: JSON.stringify(gatherConfig()) });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || "回测失败");
      status.style.color = "var(--positive)"; status.innerHTML = '<i class="fa-solid fa-check"></i> 完成';
      activeRunId = data.run_id;
      renderResult(data.result, gatherConfig().name || "回测结果");
      await loadRuns();
    } catch (err) {
      status.style.color = "var(--negative)"; status.innerHTML = '<i class="fa-solid fa-xmark"></i> ' + escapeHtml(err.message);
    } finally { btn.disabled = false; }
  }

  function metricBox(label, value, cls) {
    return '<div class="metric-box"><div class="ml">' + label + '</div><div class="mv" style="color:' + (cls||'var(--ink)') + '">' + value + '</div></div>';
  }

  async function evaluateRun() {
    if (!activeRunId) { return; }
    const btn = $("aiEvalBtn"), box = $("aiEvalBox");
    btn.disabled = true; box.style.color = "var(--muted)";
    box.textContent = "AI 正在分析回测结果…";
    try {
      const res = await fetch("/api/strategy/runs/" + activeRunId + "/evaluate", { method: "POST" });
      const data = await res.json();
      if (!res.ok) throw new Error(data.detail || "评价失败");
      box.style.color = "var(--ink-secondary)"; box.textContent = data.ai_eval;
      loadRuns();
    } catch (e) { box.style.color = "var(--negative)"; box.textContent = e.message; }
    finally { btn.disabled = false; }
  }

  function renderResult(result, name, aiEval) {
    $("resultCard").style.display = "block";
    $("resultTitle").textContent = name;
    const c = result.config || {};
    $("resultRange").textContent = c.start + " → " + c.end + " · " + c.trading_days + " 个交易日 · 调仓 " + c.rebalance;
    const m = result.metrics || {}, bm = result.benchmark_metrics || {};
    const sign = v => v == null ? "var(--ink)" : (v >= 0 ? "var(--positive)" : "var(--negative)");
    $("metricCards").innerHTML =
      metricBox("总收益", fmtPct(m.total_return), sign(m.total_return)) +
      metricBox("年化 (CAGR)", fmtPct(m.cagr), sign(m.cagr)) +
      metricBox("年化波动", fmtPct(m.vol)) +
      metricBox("夏普", fmtNum(m.sharpe)) +
      metricBox("最大回撤", fmtPct(m.max_drawdown), "var(--negative)") +
      metricBox("基准(" + result.benchmark + ") 总收益", fmtPct(bm.total_return), sign(bm.total_return));

    ensureTheme();
    if (equityChart) equityChart.dispose();
    equityChart = window.echarts.init($("equityChart"), "catfolio");
    const dates = result.equity.map(e => e.date);
    equityChart.setOption({
      backgroundColor: "transparent",
      tooltip: { trigger: "axis" },
      legend: { bottom: 0, textStyle: { color: "#9ca3af" } },
      grid: { left: 56, right: 18, top: 16, bottom: 40 },
      xAxis: { type: "category", data: dates, axisLabel: { color: "#9ca3af" } },
      yAxis: { type: "value", scale: true, axisLabel: { color: "#9ca3af" } },
      series: [
        { name: "策略", type: "line", showSymbol: false, data: result.equity.map(e=>e.nav), lineStyle:{width:2.2,color:"#5e6ad2"}, itemStyle:{color:"#5e6ad2"} },
        { name: "基准 " + result.benchmark, type: "line", showSymbol: false, data: result.benchmark_equity.map(e=>e.nav), lineStyle:{width:1.5,color:"#888",opacity:0.85}, itemStyle:{color:"#888"} },
      ],
    });
    // drawdown (underwater) chart
    if (ddChart) ddChart.dispose();
    ddChart = window.echarts.init($("drawdownChart"), "catfolio");
    ddChart.setOption({
      backgroundColor: "transparent",
      tooltip: { trigger: "axis", valueFormatter: v => (v*100).toFixed(1) + "%" },
      grid: { left: 56, right: 18, top: 10, bottom: 24 },
      xAxis: { type: "category", data: (result.drawdown||[]).map(e=>e.date), axisLabel: { color: "#9ca3af" } },
      yAxis: { type: "value", axisLabel: { color: "#9ca3af", formatter: v => (v*100).toFixed(0) + "%" } },
      series: [{ type: "line", showSymbol: false, data: (result.drawdown||[]).map(e=>e.dd), areaStyle: { opacity: 0.18 }, lineStyle: { width: 1.2 }, itemStyle: { color: "#e54d5e" } }],
    });

    // allocation / rebalance detail table
    const trades = result.trades || [];
    $("tradeCount").textContent = "(" + trades.length + " 次)";
    if (!trades.length) {
      $("tradeTableWrap").innerHTML = '<div style="font-size:12px;color:var(--muted);">该策略全程空仓</div>';
    } else {
      const rows = trades.slice().reverse().map(tr => {
        const alloc = Object.entries(tr.weights).sort((a,b)=>b[1]-a[1])
          .map(([t,w]) => '<span style="display:inline-block;background:var(--accent-soft);color:var(--accent);border-radius:4px;padding:1px 7px;margin:1px 3px 1px 0;font-size:11px;">' + escapeHtml(t) + ' ' + (w*100).toFixed(0) + '%</span>').join("");
        return '<tr><td style="padding:6px 10px;color:var(--muted);font-family:var(--font-mono);white-space:nowrap;">' + tr.date + '</td><td style="padding:6px 10px;">' + alloc + '</td></tr>';
      }).join("");
      $("tradeTableWrap").innerHTML = '<table style="width:100%;border-collapse:collapse;font-size:12px;"><thead><tr><th style="text-align:left;padding:6px 10px;color:var(--muted);font-weight:600;border-bottom:1px solid var(--line);">调仓日</th><th style="text-align:left;padding:6px 10px;color:var(--muted);font-weight:600;border-bottom:1px solid var(--line);">目标持仓</th></tr></thead><tbody>' + rows + '</tbody></table>';
    }

    $("resultWarnings").innerHTML = (result.warnings && result.warnings.length) ? ("注意：" + result.warnings.map(escapeHtml).join("；")) : "";
    $("aiEvalBox").style.color = "var(--ink-secondary)";
    $("aiEvalBox").textContent = aiEval || "";
  }

  async function loadRun(id) {
    const res = await fetch("/api/strategy/runs/" + id);
    if (!res.ok) return;
    const run = await res.json();
    activeRunId = id;
    $("f_name").value = run.name;
    $("f_code").value = run.code;
    const c = run.config || {};
    $("f_universe").value = (c.universe||[]).join(", ");
    $("f_benchmark").value = c.benchmark || "SPY";
    $("f_capital").value = c.capital || 10000;
    $("f_fee").value = c.fee_bps || 0;
    $("f_rebalance").value = c.rebalance || "monthly";
    renderResult(run.result, run.name, run.ai_eval);
    loadRuns();
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  async function delRun(id) {
    await fetch("/api/strategy/runs/" + id, { method:"DELETE" });
    if (activeRunId === id) activeRunId = null;
    loadRuns();
  }

  function newRun() {
    activeRunId = null;
    $("resultCard").style.display = "none";
    $("runStatus").innerHTML = "";
    loadRuns();
  }

  loadRuns();
