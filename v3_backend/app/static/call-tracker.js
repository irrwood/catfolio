(() => {
  'use strict';
  const root = document.getElementById('calls-root');
  if (!root) return;
  const en = document.documentElement.lang === 'en';
  const demo = root.dataset.demo === '1';
  const HORIZONS = [5, 21, 63];
  const COPY = {
    zh: {
      horizonGroup: '观察期', horizon: n => `${n} 日`, loading: '正在读取…', loadFailed: '读取失败，请稍后重试。',
      methodLine: '口径：观点日后第一个交易日收盘为起点，看空取反，未到期和缺价不进分母。', methodLink: '完整口径',
      freshDemo: d => `演示数据 · 来源、观点和价格均为虚构 · 价格截至 ${d}`,
      freshReal: (t, d) => `数据更新于 ${t} · 价格截至 ${d} · 基准 SPY`,
      notComputed: '已导入，还没有计算：点“重新计算”联网取价。',
      noData: '还没有导入观点。', emptyReal: '还没有导入观点。在下方导入 JSONL 文件后，这里会按来源显示命中率。', emptyDemo: '没有演示数据。',
      totals: (t, h) => `共 ${t.calls} 条观点、${t.sources} 个来源：看多或看空 ${t.directional} 条，中性 ${t.neutral} 条；${h} 日已到期 ${t.scored} 条，待观察 ${t.pending} 条，缺价 ${t.missing} 条`,
      uncomputed: n => `，待计算 ${n} 条`,
      sortNote: '按 63 日命中率排序；已到期不足 10 条的来源排在后面并标“待观察”。样本含中性观点，到期和命中率只算看多、看空。',
      head: {source: '来源', calls: '样本', scored: '到期', hitRate: '命中率', avgExcess: '平均超额', top: '最大单笔贡献', status: '状态'},
      tip: {calls: '全部导入的观点，含中性', scored: '已到期、有价格的看多和看空观点', avgExcess: '按方向计算的相对 SPY 超额收益，取已到期观点的平均', top: '最赚钱的一条观点占全部盈利之和的比例'},
      watch: '待观察', watchTip: '已到期不足 10 条', ready: '已达门槛', readyTip: '已到期至少 10 条',
      open: name => `查看 ${name} 的详情`, back: '← 全部来源',
      stat: {calls: '样本', scored: '已到期', hitRate: '命中率', avgReturn: '平均方向收益', avgExcess: '平均超额', medianExcess: '中位超额', top: '最大单笔贡献', stances: '看多 / 看空 / 中性'},
      hits: (h, s) => `${h} / ${s} 命中`, waiting: (p, m) => `待观察 ${p} 条 · 缺价 ${m} 条`, perCall: '每条已到期观点',
      curveEmpty: '还没有已到期的看多或看空观点。',
      curveSummary: (n, a, b, f, s) => `${a} 至 ${b}，${n} 条已到期观点：每次都跟 ${f}，SPY 同方向 ${s}`,
      curveAt: (d, f, s) => `${d} · 每次都跟 ${f} · SPY 同方向 ${s}`,
      follow: '每次都跟', bench: 'SPY 同方向',
      monthsEmpty: '还没有看多或看空观点。',
      month: (m, r, n) => `${m}：命中率 ${r}，已到期 ${n} 条`, monthPending: (m, p) => `${m}：${p} 条待观察`,
      monthsLabel: '逐月命中率柱状图', curveLabel: '每次都跟的净值曲线与 SPY 同方向对照',
      ev: {date: '观点日', ticker: '代码', stance: '方向', reason: '理由', window: '起点 → 终点', change: '股价变化', excess: '超额', result: '结果'},
      stance: {bullish: '看多', bearish: '看空', neutral: '中性'},
      result: {hit: '命中', miss: '未命中', pending: '待观察', missing_price: '缺价', neutral: '不计分', uncomputed: '待计算'},
      link: '来源链接', eventsStatus: n => `共 ${n} 条，按观点日从新到旧`, page: (p, n) => `第 ${p} / ${n} 页`,
      importing: '正在导入…', computing: '正在联网取价并计算，可能需要几十秒…',
      imported: r => `读取 ${r.read} 条：新增 ${r.inserted} 条，重复 ${r.duplicates} 条，无效 ${r.invalid} 条。`,
      badLines: list => `无效行：${list}。`,
      computed: c => `已计算 ${c.calls} 条观点，价格截至 ${c.price_as_of || '—'}。`,
      missingSymbols: list => `没有取到价格的代码：${list}。`,
      reused: list => `这次取价失败、沿用上次保存价格的代码：${list}。`,
      failed: '操作失败：',
      errors: {demo: '演示模式下不能导入或重新计算。', no_file: '请选择文件或填写本机路径。', bad_request: '请求格式不对。', relative_path: '请填写完整路径（以 / 或 ~ 开头）。', not_found: '找不到这个文件。', not_a_file: '这个路径不是文件。', bad_suffix: '只支持 .jsonl、.ndjson、.json 或 .txt 文件。', too_large: '文件超过 20 MB。', not_utf8: '文件不是 UTF-8 编码。'},
      lines: {json: '不是有效的 JSON', object: '不是 JSON 对象', source: '缺少来源', date: '日期无效', symbol: '代码无效', stance: '方向无法识别'},
      line: (n, why) => `第 ${n} 行${why}`,
    },
    en: {
      horizonGroup: 'Horizon', horizon: n => `${n} days`, loading: 'Loading…', loadFailed: 'Could not load data. Please try again.',
      methodLine: 'Method: entry at the first close after the call date; bearish calls are inverted; pending and unpriced calls stay out of every denominator.', methodLink: 'Full method',
      freshDemo: d => `Demo data · sources, calls and prices are fictional · prices as of ${d}`,
      freshReal: (t, d) => `Updated ${t} · prices as of ${d} · benchmark SPY`,
      notComputed: 'Imported but not calculated yet: use Recalculate to fetch prices.',
      noData: 'No calls imported yet.', emptyReal: 'No calls imported yet. Import a JSONL file below to see hit rates by source.', emptyDemo: 'No demo data.',
      totals: (t, h) => `${t.calls} ${t.calls === 1 ? 'call' : 'calls'} from ${t.sources} ${t.sources === 1 ? 'source' : 'sources'}: ${t.directional} bullish or bearish, ${t.neutral} neutral. At ${h} days: ${t.scored} scored, ${t.pending} pending, ${t.missing} without prices`,
      uncomputed: n => `, ${n} not calculated`,
      sortNote: 'Sorted by 63-day hit rate. Sources with fewer than 10 scored calls come last and show “Too early”. Calls include neutral ones; scored calls and hit rates count bullish and bearish calls only.',
      head: {source: 'Source', calls: 'Calls', scored: 'Scored', hitRate: 'Hit rate', avgExcess: 'Avg. excess', top: 'Top call share', status: 'Status'},
      tip: {calls: 'All imported calls, including neutral ones', scored: 'Bullish and bearish calls whose window has ended and that have prices', avgExcess: 'Direction-adjusted return relative to SPY, averaged over scored calls', top: 'Share of all gains that came from the single best call'},
      watch: 'Too early', watchTip: 'Fewer than 10 scored calls', ready: 'Enough data', readyTip: 'At least 10 scored calls',
      open: name => `Open details for ${name}`, back: '← All sources',
      stat: {calls: 'Calls', scored: 'Scored', hitRate: 'Hit rate', avgReturn: 'Avg. directional return', avgExcess: 'Avg. excess', medianExcess: 'Median excess', top: 'Top call share', stances: 'Bullish / bearish / neutral'},
      hits: (h, s) => `${h} of ${s} hit`, waiting: (p, m) => `${p} pending · ${m} without prices`, perCall: 'Per scored call',
      curveEmpty: 'No scored bullish or bearish calls yet.',
      curveSummary: (n, a, b, f, s) => `${a} to ${b}, ${n} scored calls: follow every call ${f}, SPY same direction ${s}`,
      curveAt: (d, f, s) => `${d} · Follow every call ${f} · SPY same direction ${s}`,
      follow: 'Follow every call', bench: 'SPY, same direction',
      monthsEmpty: 'No bullish or bearish calls yet.',
      month: (m, r, n) => `${m}: hit rate ${r}, ${n} scored`, monthPending: (m, p) => `${m}: ${p} pending`,
      monthsLabel: 'Monthly hit rate bars', curveLabel: 'Follow-every-call equity curve against SPY in the same direction',
      ev: {date: 'Call date', ticker: 'Ticker', stance: 'Stance', reason: 'Reason', window: 'Entry → exit', change: 'Price change', excess: 'Excess', result: 'Result'},
      stance: {bullish: 'Bullish', bearish: 'Bearish', neutral: 'Neutral'},
      result: {hit: 'Hit', miss: 'Miss', pending: 'Pending', missing_price: 'No price', neutral: 'Not scored', uncomputed: 'Not calculated'},
      link: 'Source link', eventsStatus: n => `${n} calls, newest first`, page: (p, n) => `Page ${p} of ${n}`,
      importing: 'Importing…', computing: 'Fetching prices and calculating. This can take a minute…',
      imported: r => `Read ${r.read}: ${r.inserted} added, ${r.duplicates} duplicates, ${r.invalid} invalid.`,
      badLines: list => `Invalid lines: ${list}.`,
      computed: c => `Calculated ${c.calls} calls; prices as of ${c.price_as_of || '—'}.`,
      missingSymbols: list => `No prices for: ${list}.`,
      reused: list => `Price fetch failed; reused saved prices for: ${list}.`,
      failed: 'Failed: ',
      errors: {demo: 'Import and recalculation are off in demo mode.', no_file: 'Choose a file or enter a local path.', bad_request: 'The request was not understood.', relative_path: 'Enter a full path starting with / or ~.', not_found: 'File not found.', not_a_file: 'That path is not a file.', bad_suffix: 'Only .jsonl, .ndjson, .json or .txt files are supported.', too_large: 'The file is larger than 20 MB.', not_utf8: 'The file is not UTF-8 encoded.'},
      lines: {json: 'is not valid JSON', object: 'is not a JSON object', source: 'has no source', date: 'has an invalid date', symbol: 'has an invalid ticker', stance: 'has an unknown stance'},
      line: (n, why) => `line ${n} ${why}`,
    },
  };
  const L = en ? COPY.en : COPY.zh;
  const $ = id => document.getElementById(id);
  const SVG = 'http://www.w3.org/2000/svg';
  const state = {horizon: 21, source: null, page: 1, busy: false, loadToken: 0, detail: null};

  // ── helpers ────────────────────────────────────────────────────────────────
  function el(tag, attrs = {}, ...children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(attrs)) {
      if (value === null || value === undefined || value === false) continue;
      if (key === 'class') node.className = value;
      else if (key === 'text') node.textContent = value;
      else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
      else node.setAttribute(key, value === true ? '' : value);
    }
    for (const child of children.flat()) {
      if (child !== null && child !== undefined && child !== false) node.append(child instanceof Node ? child : String(child));
    }
    return node;
  }
  function svg(tag, attrs = {}, text) {
    const node = document.createElementNS(SVG, tag);
    for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
    if (text !== undefined) node.textContent = text;
    return node;
  }
  const pct = v => (v === null || v === undefined ? '—' : `${(v * 100).toFixed(1)}%`);
  const signed = v => {
    if (v === null || v === undefined) return '—';
    const text = Math.abs(v * 100).toFixed(1);
    return `${text === '0.0' ? '' : v > 0 ? '+' : '−'}${text}%`;
  };
  const tone = v => (v === null || v === undefined || Math.abs(v) < 0.0005 ? '' : v > 0 ? 'positive' : 'negative');
  const price = v => (v === null || v === undefined ? '—' : Number(v).toLocaleString(en ? 'en-US' : 'zh-CN', {minimumFractionDigits: 2, maximumFractionDigits: 2}));
  function when(iso) {
    if (!iso) return '—';
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    const two = n => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${two(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`;
  }
  async function api(url, options) {
    const response = await fetch(url, options);
    let body = null;
    try { body = await response.json(); } catch (_) { body = null; }
    if (!response.ok) {
      const detail = body && (body.detail || body.error);
      const code = detail && detail.code;
      const message = (code && L.errors[code]) || (detail && detail.message) || (typeof detail === 'string' ? detail : '') || `HTTP ${response.status}`;
      throw new Error(message);
    }
    return body;
  }

  // ── URL state ──────────────────────────────────────────────────────────────
  function readUrl() {
    const params = new URLSearchParams(location.search);
    const horizon = Number(params.get('horizon'));
    state.horizon = HORIZONS.includes(horizon) ? horizon : 21;
    state.source = params.get('source') || null;
    state.page = 1;
  }
  function writeUrl(push) {
    const params = new URLSearchParams();
    if (state.horizon !== 21) params.set('horizon', state.horizon);
    if (state.source) params.set('source', state.source);
    const query = params.toString();
    const url = `${location.pathname}${query ? `?${query}` : ''}`;
    if (push) history.pushState(null, '', url); else history.replaceState(null, '', url);
  }

  // ── static chrome ──────────────────────────────────────────────────────────
  function renderChrome() {
    const group = $('calls-horizon');
    group.setAttribute('aria-label', L.horizonGroup);
    group.replaceChildren(...HORIZONS.map(n => el('button', {
      type: 'button', 'data-horizon': n, 'aria-pressed': String(n === state.horizon), text: L.horizon(n),
      onclick: () => { if (state.horizon !== n) { state.horizon = n; state.page = 1; writeUrl(false); load(); } },
    })));
    $('calls-method-line').replaceChildren(L.methodLine, ' ', el('a', {href: '#calls-method', text: L.methodLink, onclick: () => { $('calls-method').open = true; }}));
    $('calls-sort-note').textContent = L.sortNote;
    $('calls-back').textContent = L.back;
  }
  function syncHorizon() {
    for (const button of $('calls-horizon').querySelectorAll('button')) {
      button.setAttribute('aria-pressed', String(Number(button.dataset.horizon) === state.horizon));
    }
  }
  function freshness(data) {
    if (data.demo) return L.freshDemo(data.price_as_of || '—');
    if (data.empty) return L.noData;
    if (!data.updated_at) return L.notComputed;
    return L.freshReal(when(data.updated_at), data.price_as_of || '—');
  }
  function statusTag(status) {
    const watch = status !== 'ready';
    return el('span', {class: `calls-tag${watch ? ' is-watch' : ''}`, title: watch ? L.watchTip : L.readyTip, text: watch ? L.watch : L.ready});
  }

  // ── overview ───────────────────────────────────────────────────────────────
  function renderOverview(data) {
    $('calls-freshness').textContent = freshness(data);
    const t = data.totals;
    $('calls-totals').textContent = data.empty ? '' : L.totals(t, data.horizon) + (t.uncomputed ? L.uncomputed(t.uncomputed) : '');
    const table = $('calls-sources');
    const th = (text, num, tip) => el('th', {scope: 'col', class: num ? 'num' : null, title: tip || null, text});
    const head = el('thead', {}, el('tr', {},
      th(L.head.source), th(L.head.calls, true, L.tip.calls), th(L.head.scored, true, L.tip.scored), th(L.head.hitRate, true),
      th(L.head.avgExcess, true, L.tip.avgExcess), th(L.head.top, true, L.tip.top), th(L.head.status)));
    const rows = data.sources.map(row => el('tr', {'data-source': row.source},
      el('th', {scope: 'row'}, el('button', {type: 'button', class: 'calls-source-link', translate: 'no', 'aria-label': L.open(row.source), text: row.source, onclick: () => openSource(row.source)})),
      el('td', {class: 'num', text: row.calls}),
      el('td', {class: 'num', text: row.scored}),
      el('td', {class: 'num', text: pct(row.hit_rate)}),
      el('td', {class: `num ${tone(row.avg_excess)}`, text: signed(row.avg_excess)}),
      el('td', {class: 'num', title: row.top_contribution ? `${row.top_contribution.ticker} · ${row.top_contribution.call_date} · ${signed(row.top_contribution.ret)}` : null, text: row.top_contribution ? pct(row.top_contribution.share) : '—'}),
      el('td', {}, statusTag(row.status))));
    const empty = el('tr', {}, el('td', {colspan: 7, class: 'calls-empty', text: data.demo ? L.emptyDemo : L.emptyReal}));
    table.replaceChildren(...(rows.length ? [head, el('tbody', {}, rows)] : [el('tbody', {}, empty)]));
    $('calls-sort-note').hidden = !rows.length;
  }

  // ── detail ─────────────────────────────────────────────────────────────────
  function renderStats(detail) {
    const m = detail.metrics;
    const top = m.top_contribution;
    const items = [
      [L.stat.calls, m.calls, L.stat.stances + ' ' + [detail.stances.bullish, detail.stances.bearish, detail.stances.neutral].join(' / ')],
      [L.stat.scored, m.scored, L.waiting(m.pending + m.uncomputed, m.missing)],
      [L.stat.hitRate, pct(m.hit_rate), L.hits(m.hits, m.scored)],
      [L.stat.avgReturn, signed(m.avg_return), L.perCall, tone(m.avg_return)],
      [L.stat.avgExcess, signed(m.avg_excess), `${L.stat.medianExcess} ${signed(m.median_excess)}`, tone(m.avg_excess)],
      [L.stat.top, top ? pct(top.share) : '—', top ? `${top.ticker} · ${top.call_date} · ${signed(top.ret)}` : ''],
    ];
    $('calls-detail-stats').replaceChildren(...items.map(([label, value, note, cls]) => el('div', {class: 'calls-stat'},
      el('dt', {text: label}), el('dd', {}, el('strong', {class: cls || null, text: value}), note ? el('small', {text: note}) : null))));
  }

  function renderCurve(curve) {
    const box = $('calls-curve');
    const readout = $('calls-curve-readout');
    if (!curve.dates.length) {
      box.replaceChildren(el('p', {class: 'calls-empty', text: L.curveEmpty}));
      readout.textContent = '';
      return;
    }
    const W = Math.max(320, Math.round(box.clientWidth || 640)), H = 240, left = 48, right = 14, top = 14, bottom = 28;
    const values = curve.follow.concat(curve.benchmark, [1]);
    const raw = Math.max(Math.max(...values) - Math.min(...values), 0.01);
    const step = [0.01, 0.02, 0.025, 0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 5].find(s => raw / s <= 5) || 10;
    const lo = Math.floor((Math.min(...values) - 1) / step) * step + 1;
    const hi = Math.max(lo + step, Math.ceil((Math.max(...values) - 1) / step) * step + 1);
    const ticks = [];
    for (let v = lo; v <= hi + step / 2; v += step) ticks.push(v);
    const n = curve.dates.length;
    const x = i => left + (n === 1 ? 0 : (i / (n - 1)) * (W - left - right));
    const y = v => top + (1 - (v - lo) / (hi - lo)) * (H - top - bottom);
    const chart = svg('svg', {viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': L.curveLabel});
    for (const v of ticks) {
      chart.append(svg('line', {x1: left, x2: W - right, y1: y(v), y2: y(v), class: 'calls-grid'}));
      chart.append(svg('text', {x: left - 6, y: y(v) + 4, 'text-anchor': 'end', class: 'calls-axis'}, `${v > 1.0001 ? '+' : v < 0.9999 ? '−' : ''}${Math.round(Math.abs(v - 1) * 100)}%`));
    }
    chart.append(svg('line', {x1: left, x2: W - right, y1: y(1), y2: y(1), class: 'calls-zero'}));
    for (const i of new Set([0, Math.floor((n - 1) / 2), n - 1])) {
      chart.append(svg('text', {x: x(i), y: H - 8, 'text-anchor': i === 0 ? 'start' : i === n - 1 ? 'end' : 'middle', class: 'calls-axis'}, curve.dates[i]));
    }
    const line = (series, cls) => svg('polyline', {points: series.map((v, i) => `${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(' '), class: cls});
    if (curve.benchmark.length) chart.append(line(curve.benchmark, 'calls-line-bench'));
    chart.append(line(curve.follow, 'calls-line-follow'));
    const guide = svg('line', {y1: top, y2: H - bottom, class: 'calls-guide', visibility: 'hidden'});
    const hitbox = svg('rect', {x: left, y: top, width: W - left - right, height: H - top - bottom, class: 'calls-hitbox'});
    chart.append(guide, hitbox);
    const last = n - 1;
    const bench = i => (curve.benchmark.length ? signed(curve.benchmark[i] - 1) : '—');
    const summary = L.curveSummary(curve.calls, curve.dates[0], curve.dates[last], signed(curve.follow[last] - 1), bench(last));
    readout.textContent = summary;
    hitbox.addEventListener('pointermove', event => {
      const rect = chart.getBoundingClientRect();
      const px = ((event.clientX - rect.left) / rect.width) * W;
      const i = Math.max(0, Math.min(last, Math.round(((px - left) / (W - left - right)) * last)));
      guide.setAttribute('x1', x(i)); guide.setAttribute('x2', x(i)); guide.setAttribute('visibility', 'visible');
      readout.textContent = L.curveAt(curve.dates[i], signed(curve.follow[i] - 1), bench(i));
    });
    hitbox.addEventListener('pointerleave', () => { guide.setAttribute('visibility', 'hidden'); readout.textContent = summary; });
    const legend = el('div', {class: 'calls-legend', 'aria-hidden': 'true'},
      el('span', {}, el('i', {class: 'calls-swatch-follow'}), L.follow),
      curve.benchmark.length ? el('span', {}, el('i', {class: 'calls-swatch-bench'}), L.bench) : null);
    box.replaceChildren(chart, legend);
  }

  function renderMonths(months) {
    const box = $('calls-months');
    if (!months.length) { box.replaceChildren(el('p', {class: 'calls-empty', text: L.monthsEmpty})); return; }
    const W = Math.max(260, Math.round(box.clientWidth || 360)), H = 240, left = 34, right = 8, top = 22, bottom = 28;
    const plotW = W - left - right, plotH = H - top - bottom;
    const slot = plotW / months.length;
    const y = rate => top + (1 - rate) * plotH;
    const chart = svg('svg', {viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': L.monthsLabel});
    for (const rate of [0, 0.5, 1]) {
      chart.append(svg('line', {x1: left, x2: W - right, y1: y(rate), y2: y(rate), class: rate === 0.5 ? 'calls-half' : 'calls-grid'}));
      chart.append(svg('text', {x: left - 6, y: y(rate) + 4, 'text-anchor': 'end', class: 'calls-axis'}, `${rate * 100}%`));
    }
    const every = Math.ceil(months.length / 8);
    months.forEach((m, i) => {
      const cx = left + slot * (i + 0.5);
      const width = Math.max(4, Math.min(28, slot * 0.6));
      const group = svg('g', {});
      if (m.scored) {
        const height = Math.max(1, plotH * m.hit_rate);
        const bar = svg('rect', {x: cx - width / 2, y: y(0) - height, width, height, rx: 3, class: 'calls-bar'});
        bar.append(svg('title', {}, L.month(m.month, pct(m.hit_rate), m.scored)));
        group.append(bar, svg('text', {x: cx, y: y(m.hit_rate) - 5, 'text-anchor': 'middle', class: 'calls-bar-count'}, m.scored));
      } else if (m.pending + m.missing) {
        const stub = svg('rect', {x: cx - width / 2, y: y(0) - 2, width, height: 2, class: 'calls-bar-empty'});
        stub.append(svg('title', {}, L.monthPending(m.month, m.pending + m.missing)));
        group.append(stub);
      }
      if (i % every === 0 || i === months.length - 1) {
        group.append(svg('text', {x: cx, y: H - 8, 'text-anchor': 'middle', class: 'calls-axis'}, i === 0 || m.month.endsWith('-01') ? m.month : m.month.slice(5)));
      }
      chart.append(group);
    });
    const described = months.filter(m => m.scored || m.pending + m.missing)
      .map(m => (m.scored ? L.month(m.month, pct(m.hit_rate), m.scored) : L.monthPending(m.month, m.pending + m.missing))).join(en ? '; ' : '；');
    chart.setAttribute('aria-label', `${L.monthsLabel}${en ? ': ' : '：'}${described}`);
    box.replaceChildren(chart);
  }

  function resultCell(outcome) {
    const status = outcome.status;
    const key = status === 'scored' ? (outcome.hit ? 'hit' : 'miss') : status;
    return el('td', {}, el('span', {class: `calls-result is-${key}`, text: L.result[key] || status}));
  }

  function renderEvents(data) {
    const th = (text, num) => el('th', {scope: 'col', class: num ? 'num' : null, text});
    const head = el('thead', {}, el('tr', {}, th(L.ev.date), th(L.ev.ticker), th(L.ev.stance), th(L.ev.reason), th(L.ev.window), th(L.ev.change, true), th(L.ev.excess, true), th(L.ev.result)));
    const rows = data.items.map(item => {
      const o = item.outcome;
      const reason = el('td', {class: 'calls-reason'},
        el('span', {translate: 'no', title: item.reason || null, text: item.reason || '—'}),
        item.url ? el('a', {href: item.url, target: '_blank', rel: 'noopener noreferrer', class: 'calls-link', text: `${L.link} ↗`}) : null);
      const pending = L.result.pending;
      const windowCell = o.entry_date
        ? el('td', {}, `${o.entry_date} → ${o.exit_date || pending}`, el('small', {text: `${price(o.entry_close)} → ${o.exit_date ? price(o.exit_close) : '—'}`}))
        : el('td', {text: '—'});
      return el('tr', {},
        el('td', {text: item.call_date}),
        el('td', {}, el('strong', {text: item.ticker}), item.name ? el('small', {translate: 'no', text: item.name}) : null),
        el('td', {}, el('span', {class: `calls-stance is-${item.stance}`, text: L.stance[item.stance] || item.stance})),
        reason, windowCell,
        el('td', {class: `num ${tone(o.ret)}`, text: signed(o.ret)}),
        el('td', {class: `num ${tone(o.excess)}`, text: signed(o.excess)}),
        resultCell(o));
    });
    $('calls-events').replaceChildren(head, el('tbody', {}, rows));
    $('calls-events-status').textContent = L.eventsStatus(data.total);
    $('calls-page-info').textContent = L.page(data.page, data.pages);
    $('calls-prev').disabled = data.page <= 1;
    $('calls-next').disabled = data.page >= data.pages;
  }

  // ── loading ────────────────────────────────────────────────────────────────
  async function loadEvents() {
    const token = state.loadToken;
    const params = new URLSearchParams({source: state.source, horizon: state.horizon, page: state.page});
    const data = await api(`/api/calls/events?${params}`);
    if (token === state.loadToken) renderEvents(data);
  }

  async function load() {
    const token = ++state.loadToken;
    syncHorizon();
    const detailView = Boolean(state.source);
    state.detail = null;
    $('calls-overview').hidden = detailView;
    $('calls-detail').hidden = !detailView;
    try {
      if (!detailView) {
        const data = await api(`/api/calls/summary?horizon=${state.horizon}`);
        if (token === state.loadToken) renderOverview(data);
        return;
      }
      const detail = await api(`/api/calls/source/${encodeURIComponent(state.source)}?horizon=${state.horizon}`);
      if (token !== state.loadToken) return;
      state.detail = detail;
      $('calls-freshness').textContent = freshness(detail);
      $('calls-detail-title').textContent = detail.source;
      $('calls-detail-status').replaceChildren(statusTag(detail.metrics.status));
      renderStats(detail);
      renderCurve(detail.curve);
      renderMonths(detail.monthly);
      await loadEvents();
    } catch (error) {
      if (token !== state.loadToken) return;
      if (detailView) { state.source = null; writeUrl(false); load(); return; }
      $('calls-freshness').textContent = `${L.loadFailed} ${error.message}`;
    }
  }

  function openSource(name) {
    state.source = name;
    state.page = 1;
    writeUrl(true);
    load();
    window.scrollTo(0, 0);
  }

  $('calls-back').addEventListener('click', () => { state.source = null; writeUrl(true); load(); });
  $('calls-prev').addEventListener('click', () => { if (state.page > 1) { state.page -= 1; loadEvents().catch(() => {}); } });
  $('calls-next').addEventListener('click', () => { state.page += 1; loadEvents().catch(() => {}); });
  window.addEventListener('popstate', () => { readUrl(); load(); });
  let resizeTimer = null;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      if (state.source && state.detail) { renderCurve(state.detail.curve); renderMonths(state.detail.monthly); }
    }, 150);
  });

  // ── import (real mode only) ────────────────────────────────────────────────
  function describeImport(result) {
    const parts = [L.imported(result)];
    if (result.errors && result.errors.length) {
      parts.push(L.badLines(result.errors.map(e => L.line(e.line, L.lines[e.code] || e.code)).join(en ? '; ' : '；')));
    }
    return parts.join(' ');
  }
  function describeCompute(computed) {
    const parts = [L.computed(computed)];
    if (computed.missing_symbols && computed.missing_symbols.length) parts.push(L.missingSymbols(computed.missing_symbols.join(', ')));
    if (computed.reused_symbols && computed.reused_symbols.length) parts.push(L.reused(computed.reused_symbols.join(', ')));
    return parts.join(' ');
  }
  async function run(task) {
    if (state.busy) return;
    state.busy = true;
    const status = $('calls-import-status');
    const buttons = [$('calls-import-btn'), $('calls-refresh')];
    buttons.forEach(b => { b.disabled = true; });
    try {
      await task(text => { status.textContent = text; });
    } catch (error) {
      status.textContent = L.failed + error.message;
    } finally {
      state.busy = false;
      buttons.forEach(b => { b.disabled = false; });
    }
  }
  async function recalculate(say, prefix) {
    say([prefix, L.computing].filter(Boolean).join(' '));
    const result = await api('/api/calls/refresh', {method: 'POST'});
    const imported = result.imported && !result.imported.error && result.imported.inserted ? describeImport(result.imported) : '';
    say([prefix, imported, describeCompute(result.computed)].filter(Boolean).join(' '));
    await load();
  }
  if (!demo && $('calls-import-form')) {
    $('calls-import-form').addEventListener('submit', event => {
      event.preventDefault();
      run(async say => {
        const file = $('calls-file').files[0];
        const path = $('calls-path').value.trim();
        if (!file && !path) throw new Error(L.errors.no_file);
        say(L.importing);
        let result;
        if (file) {
          const form = new FormData();
          form.append('file', file);
          result = await api('/api/calls/import', {method: 'POST', body: form});
        } else {
          result = await api('/api/calls/import', {method: 'POST', headers: {'Content-Type': 'application/json'}, body: JSON.stringify({path})});
        }
        $('calls-file').value = '';
        await recalculate(say, describeImport(result));
      });
    });
    $('calls-refresh').addEventListener('click', () => run(say => recalculate(say, '')));
  }

  readUrl();
  renderChrome();
  load();
})();
