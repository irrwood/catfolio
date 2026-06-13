  async function getChatId() {
    const tokenInput = document.getElementById('input_TELEGRAM_BOT_TOKEN');
    const chatInput  = document.getElementById('input_TELEGRAM_CHAT_ID');
    // Use typed token if available, otherwise server reads from keychain
    const token = tokenInput.value.trim() || null;
    const res = await fetch('/api/telegram/get-chat-id' + (token ? '?token=' + encodeURIComponent(token) : ''));
    const data = await res.json();
    if (data.ok) {
      chatInput.value = data.chat_id;
      chatInput.placeholder = data.chat_id;
      const label = data.title ? ` (${data.title})` : '';
      document.getElementById('tg_test_result').innerHTML =
        `<span style="color:var(--positive)"><i class="fa-solid fa-check"></i> Chat ID: ${data.chat_id}${label}</span>`;
    } else {
      document.getElementById('tg_test_result').innerHTML =
        `<span style="color:var(--negative)"><i class="fa-solid fa-xmark"></i> ${data.error}</span>`;
    }
  }

  async function tgTest(btn) {
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i>';
    const res = await fetch('/api/telegram/test', {method: 'POST'});
    const data = await res.json();
    const el = document.getElementById('tg_test_result');
    if (data.ok) {
      el.innerHTML = '<span style="color:var(--positive)"><i class="fa-solid fa-check"></i> 消息已发送！</span>';
      document.getElementById('tg_status_badge').innerHTML =
        '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive)"><div class="status-dot"></div> 已配置</span>';
    } else {
      el.innerHTML = `<span style="color:var(--negative)"><i class="fa-solid fa-xmark"></i> 失败：${data.error || '未知错误'}</span>`;
    }
    setTimeout(() => { btn.innerHTML = orig; btn.disabled = false; }, 2000);
  }

  async function saveKey(envName, btn) {
    const input = document.getElementById('input_' + envName);
    const value = input.value.trim();
    if (!value) return;
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i>';
    try {
      const res = await fetch('/api/settings/save-key', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({name: envName, value})
      });
      const data = await res.json();
      if (data.ok) {
        input.value = '';
        input.placeholder = '已设置，留空则不修改';
        const badge = document.getElementById('badge_' + envName);
        badge.innerHTML = '<span class="market-status-badge" style="color:var(--positive);background:var(--positive-soft);border-color:var(--positive);white-space:nowrap"><div class="status-dot"></div> 已设置</span>';
        btn.innerHTML = '<i class="fa-solid fa-check"></i> 已保存';
        setTimeout(() => { btn.innerHTML = orig; btn.disabled = false; }, 2000);
      } else {
        btn.innerHTML = '<i class="fa-solid fa-xmark"></i> 失败';
        setTimeout(() => { btn.innerHTML = orig; btn.disabled = false; }, 2000);
      }
    } catch(e) {
      btn.innerHTML = orig; btn.disabled = false;
    }
  }

  async function setProvider(value, btn) {
    const status = document.getElementById('aiProviderStatus');
    try {
      const res = await fetch('/api/settings/save-key', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({name: 'AI_PROVIDER', value})
      });
      const data = await res.json();
      if (data.ok) {
        document.querySelectorAll('.ai-provider-btn').forEach(b => {
          b.style.background = 'var(--soft)'; b.style.color = 'var(--ink)'; b.style.borderColor = 'transparent';
        });
        btn.style.background = 'var(--accent)'; btn.style.color = '#fff'; btn.style.borderColor = 'var(--accent)';
        status.innerHTML = '当前：<strong style="color:var(--ink)">' + btn.textContent.trim() + '</strong> <span style="color:var(--positive)">已切换</span>';
      } else {
        status.innerHTML = '<span style="color:var(--negative)">切换失败：' + (data.error || '未知错误') + '</span>';
      }
    } catch(e) {
      status.innerHTML = '<span style="color:var(--negative)">切换失败</span>';
    }
  }

  async function triggerRefresh(type) {
    const statusEl = document.getElementById("settingsStatus");
    statusEl.className = "status";
    if (type === 'market') {
      statusEl.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 正在强制拉取最新行情...';
      try {
        const response = await fetch("/api/refresh/market?force=true", { method: "POST" });
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "status positive";
        statusEl.innerHTML = '<i class="fa-solid fa-check"></i> 行情刷新完成！';
        setTimeout(() => location.reload(), 1000);
      } catch (err) {
        statusEl.className = "status negative";
        statusEl.innerHTML = '<i class="fa-solid fa-xmark"></i> 刷新失败。';
      }
    } else if (type === 'history') {
      statusEl.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 正在重新获取所有标的历史价格...';
      try {
        const response = await fetch("/api/lab/refresh-history?force=true", { method: "POST" });
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "status positive";
        statusEl.innerHTML = '<i class="fa-solid fa-check"></i> 历史价格刷新完成！';
        setTimeout(() => location.reload(), 1000);
      } catch (err) {
        statusEl.className = "status negative";
        statusEl.innerHTML = '<i class="fa-solid fa-xmark"></i> 刷新失败。';
      }
    } else if (type === 'fundamentals') {
      statusEl.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 正在重新拉取 FMP 估值数据...';
      try {
        const response = await fetch("/api/refresh/fundamentals?force=true", { method: "POST" });
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "status positive";
        statusEl.innerHTML = '<i class="fa-solid fa-check"></i> 估值数据刷新完成！';
        setTimeout(() => location.reload(), 1500);
      } catch (err) {
        statusEl.className = "status negative";
        statusEl.innerHTML = '<i class="fa-solid fa-xmark"></i> 刷新失败。';
      }
    } else if (type === 'after-hours') {
      statusEl.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> 正在拉取 Massive 盘后数据...';
      try {
        const response = await fetch("/api/refresh/after-hours?force=true", { method: "POST" });
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "status positive";
        statusEl.innerHTML = '<i class="fa-solid fa-check"></i> 盘后数据刷新完成！';
        setTimeout(() => location.reload(), 1000);
      } catch (err) {
        statusEl.className = "status negative";
        statusEl.innerHTML = '<i class="fa-solid fa-xmark"></i> 刷新失败。';
      }
    }
  }
