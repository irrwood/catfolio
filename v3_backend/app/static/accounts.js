(() => {
  const english = document.documentElement.lang.startsWith('en');
  const translations = JSON.parse(document.getElementById('accountTranslations')?.textContent || '{}');
  const tr = text => english ? (translations[text] || text) : text;
  const list = document.getElementById('accountList');
  if (!list) return;
  const dialog = document.getElementById('accountDialog');
  const form = document.getElementById('accountForm');
  const status = document.getElementById('accountDialogStatus');
  const pageStatus = document.getElementById('accountStatus');
  const previewSection = document.getElementById('accountPreview');
  const fields = document.getElementById('accountConnectionFields');
  const labels = {trading212: 'Trading 212', moomoo: 'Moomoo', ibkr: 'Interactive Brokers', csv: 'CSV 导入'};
  let state = {accounts: [], legacy: []};
  let active = null;
  let token = null;
  let busy = false;
  const specs = {
    csv: [],
    trading212: [['api_key', 'API Key', 'password', '粘贴 API Key'], ['api_secret', 'API Secret', 'password', '粘贴对应的 API Secret']],
    moomoo: [['host', 'OpenD Host', 'text', '127.0.0.1'], ['port', 'OpenD Port', 'number', '11111'], ['markets', '市场', 'text', 'US,HK'], ['account_id', '账户 ID', 'text', '填写需同步的账户 ID']],
    ibkr: [['base_url', 'Gateway URL', 'url', 'https://localhost:5000/v1/api'], ['account_id', '账户 ID', 'text', '例如 U1234567']]
  };
  const hints = {
    csv: '上传此账户的完整交易 CSV（Date、Action、Ticker、Quantity、Price、Currency）。预览后确认替换本账户的 CSV 记录，其他账户不受影响。导入后可刷新行情。',
    trading212: '使用只读 API Key 和对应 Secret。凭证保存在服务器所在设备的系统凭证库。当前同步持仓与现金，完整交易流水仍需 CSV 补充。',
    moomoo: '先在运行 Catfolio 的设备上启动并登录 OpenD。每个连接对应一个账户；多账户请分别添加。',
    ibkr: '先在运行 Catfolio 的设备上启动并登录 Client Portal Gateway。每个连接对应一个账户。'
  };
  function element(tag, text, className) {
    const el = document.createElement(tag);
    if (text !== undefined) el.textContent = tr(text);
    if (className) el.className = className;
    return el;
  }
  async function request(path, body, method = 'POST') {
    const response = await fetch('/api/accounts' + path, {method,
      headers: body === undefined ? {} : {'Content-Type': 'application/json'},
      body: body === undefined ? undefined : JSON.stringify(body)});
    const data = await response.json();
    if (!response.ok) throw new Error(typeof data.detail === 'string' ? data.detail : data.error || '操作失败，请重试。');
    return data;
  }
  function invalidate() {
    token = null;
    previewSection.hidden = true;
    form.hidden = false;
  }
  function configureFields() {
    fields.replaceChildren();
    specs[form.elements.provider.value].forEach(([name, title, type, placeholder]) => {
      const label = element('label', title);
      const input = element('input', undefined, 'settings-input');
      input.name = name; input.type = type; input.autocomplete = 'off';
      input.placeholder = tr(active ? '已保存，留空保持原值' : placeholder);
      if (type === 'password') input.maxLength = 4096;
      label.append(input); fields.append(label);
    });
    if (form.elements.provider.value === 'csv') {
      const label = element('label', '交易 CSV 文件');
      const input = element('input', undefined, 'settings-input');
      input.name = 'csv_file'; input.type = 'file'; input.accept = '.csv,text/csv';
      label.append(input); fields.append(label);
    }
    document.getElementById('accountConnectionHint').textContent = tr(hints[form.elements.provider.value]);
    invalidate();
  }
  function render() {
    list.replaceChildren();
    [...state.accounts, ...state.legacy.map(a => ({...a, legacy: true}))].forEach(account => {
      const row = element('div', undefined, 'account-row');
      const checkbox = element('input', undefined, 'account-scope');
      checkbox.type = 'checkbox'; checkbox.checked = account.selected;
      checkbox.setAttribute('aria-label', '计入 ' + account.name);
      checkbox.dataset[account.legacy ? 'legacy' : 'accountId'] = account.legacy ? account.name : account.id;
      row.append(checkbox);
      if (account.legacy) {
        const copy = element('div', undefined, 'settings-row-copy');
        copy.append(element('strong', account.name), element('span', '已有持仓 · 可关联独立同步连接'));
        const connect = element('button', '连接账户', 'settings-button');
        connect.type = 'button'; connect.dataset.connectLegacy = account.name;
        row.append(copy, connect);
      } else {
        const open = element('button', undefined, 'account-open');
        open.type = 'button'; open.dataset.accountId = account.id;
        const when = account.updated_at ? new Date(account.updated_at * 1000).toLocaleString() : tr('等待首次同步');
        open.append(element('strong', account.name), element('span', `${labels[account.provider]} · ${account.positions} ${english ? 'holdings' : '项持仓'} · ${when}`));
        row.append(open, element('span', '›'));
      }
      list.append(row);
    });
    if (!list.childElementCount) list.append(element('p', '还没有账户。添加券商连接，预览后即可同步持仓。', 'settings-notice'));
  }
  async function reload() {
    state = await request('', undefined, 'GET'); render();
  }
  function open(account = null, legacy = '') {
    active = account; form.reset(); invalidate(); status.textContent = tr('');
    form.elements.name.value = account?.name || legacy;
    form.elements.provider.value = account?.provider || 'trading212';
    form.elements.provider.disabled = !!account;
    const select = form.elements.replaces_account;
    select.replaceChildren(new Option(tr('新账户'), ''));
    const source = account?.replaces_account || legacy;
    const names = new Set(state.legacy.map(a => a.name));
    if (source) names.add(source);
    names.forEach(name => select.add(new Option(name, name)));
    select.value = source || ''; select.disabled = !!account?.updated_at;
    document.getElementById('accountDialogTitle').textContent = account ? account.name : tr('添加账户');
    document.getElementById('accountDialogSubtitle').textContent = account?.updated_at
      ? `${labels[account.provider]} · ${account.currency || '—'} · ${account.positions} ${english ? 'holdings' : '项持仓'}${account.market_value_usd == null ? '' : ' · ' + new Intl.NumberFormat(undefined, {style: 'currency', currency: 'USD'}).format(account.market_value_usd)} · ${english ? 'Synced' : '上次同步'} ${new Date(account.updated_at * 1000).toLocaleString()}`
      : tr('配置连接 → 预览持仓 → 确认同步');
    document.getElementById('deleteAccount').hidden = !account;
    configureFields(); dialog.showModal();
  }
  function setBusy(value) {
    busy = value; dialog.setAttribute('aria-busy', String(value));
    dialog.querySelectorAll('button').forEach(b => { b.disabled = value; });
    form.querySelectorAll('input, select').forEach(input => {
      input.disabled = value || (input.name === 'provider' && !!active) || (input.name === 'replaces_account' && !!active?.updated_at);
    });
  }
  async function operation(fn) {
    if (busy) return;
    setBusy(true);
    try { await fn(); } catch (error) { status.textContent = error.message; }
    finally { setBusy(false); if (token) document.getElementById('confirmAccountSync').focus(); }
  }
  async function save() {
    const config = {};
    specs[form.elements.provider.value].forEach(([name]) => { config[name] = form.elements[name].value; });
    const source = form.elements.replaces_account.value || null;
    const result = await request('/connection', {id: active?.id || null, name: form.elements.name.value,
      provider: form.elements.provider.value, config, replaces_account: source});
    active = {...result, replaces_account: source};
    // Never retain typed credentials after successful persistence.
    specs[active.provider].forEach(([name]) => { form.elements[name].value = ''; form.elements[name].placeholder = '已保存，留空保持原值'; });
    document.getElementById('deleteAccount').hidden = false;
    await reload();
  }
  form.addEventListener('input', invalidate);
  form.elements.provider.addEventListener('change', configureFields);
  form.addEventListener('submit', event => {
    event.preventDefault(); if (!form.reportValidity()) return;
    operation(async () => { invalidate(); await save(); status.textContent = tr('连接已保存。预览并确认后才会更新持仓。'); });
  });
  document.getElementById('previewAccount').addEventListener('click', () => {
    if (!form.reportValidity()) return;
    operation(async () => {
      invalidate(); status.textContent = tr('正在连接并读取持仓，当前组合尚未改变…');
      await save();
      const csvFile = form.elements.csv_file?.files[0];
      if (active.provider === 'csv' && (!csvFile || csvFile.size > 5 * 1024 * 1024)) throw new Error('请选择不超过 5 MB 的 CSV 文件。');
      const body = csvFile ? {csv_text: await csvFile.text()} : {};
      const data = await request('/' + active.id + '/preview', body); token = data.token;
      const rows = document.getElementById('accountPreviewRows'); rows.replaceChildren();
      data.positions.forEach(position => {
        const row = element('tr');
        [position.normalized_ticker || position.ticker, position.quantity, position.average_price_paid ?? '—', position.currency || '—'].forEach(value => row.append(element('td', String(value))));
        rows.append(row);
      });
      document.getElementById('accountPreviewSummary').textContent = `${data.source_account} · ${data.currency || ''} · ${data.positions.length} 项持仓 · 新增 ${data.added} 项 / 移除 ${data.removed} 项${data.empty ? '。此账户当前没有持仓，确认将清空其旧持仓。' : ''}`;
      document.getElementById('accountSyncNotice').textContent = active.provider === 'csv' ? (english ? 'Confirmation replaces this account’s CSV holdings and transaction records. Other accounts are preserved. The preview expires in 15 minutes.' : '确认后将按本次文件更新此账户的持仓与交易记录，其他账户不受影响。预览在 15 分钟后失效。') : tr('确认后只更新此账户。持仓数量为零时会清空此账户的当前持仓；已导入的历史记录保留。预览在 15 分钟后失效。');
      previewSection.hidden = false; form.hidden = true; status.textContent = tr('预览完成，请检查后确认。');
      document.getElementById('confirmAccountSync').focus();
    });
  });
  document.getElementById('confirmAccountSync').addEventListener('click', () => {
    if (!token) return;
    operation(async () => {
      status.textContent = tr('正在保存此账户的持仓…');
      await request('/' + active.id + '/sync', {token});
      await reload(); invalidate(); dialog.close(); pageStatus.textContent = tr('账户已同步，组合已更新。');
    });
  });
  document.getElementById('cancelAccountPreview').addEventListener('click', invalidate);
  document.getElementById('deleteAccount').addEventListener('click', () => {
    if (!active || !window.confirm(`删除账户“${active.name}”？将移除此账户的连接和已同步持仓，其他账户不受影响。`)) return;
    operation(async () => {
      await request('/' + active.id, undefined, 'DELETE'); await reload(); dialog.close(); pageStatus.textContent = tr('账户已删除。');
    });
  });
  document.getElementById('closeAccount').addEventListener('click', () => { if (!busy) dialog.close(); });
  dialog.addEventListener('cancel', event => { if (busy) event.preventDefault(); });
  dialog.addEventListener('close', () => { form.reset(); fields.replaceChildren(); invalidate(); });
  document.getElementById('addAccount').addEventListener('click', () => open());
  document.getElementById('addCSVAccount').addEventListener('click', () => { open(); form.elements.provider.value = 'csv'; configureFields(); });
  list.addEventListener('click', event => {
    const target = event.target.closest('button');
    if (target?.dataset.accountId) open(state.accounts.find(a => a.id === target.dataset.accountId));
    if (target?.dataset.connectLegacy) open(null, target.dataset.connectLegacy);
  });
  list.addEventListener('change', async event => {
    const checkbox = event.target;
    if (!checkbox.matches('.account-scope')) return;
    checkbox.disabled = true;
    try {
      if (checkbox.dataset.legacy) await request('/legacy-scope', {name: checkbox.dataset.legacy, selected: checkbox.checked});
      else await request('/' + checkbox.dataset.accountId, {selected: checkbox.checked});
      await reload(); pageStatus.textContent = tr('组合账户范围已更新。');
    } catch (error) { checkbox.checked = !checkbox.checked; pageStatus.textContent = error.message; }
    finally { checkbox.disabled = false; }
  });
  reload().catch(error => { pageStatus.textContent = error.message; });
})();
