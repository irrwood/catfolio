  async function toggleDemoMode() {
    const btn = document.getElementById('demoModeBtn');
    const state = document.getElementById('demoModeState');
    const turnOn = btn.dataset.on !== '1';
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg>';
    try {
      const res = await fetch('/api/settings/demo-mode', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ on: turnOn })
      });
      const data = await res.json();
      const on = !!data.demo;
      btn.dataset.on = on ? '1' : '0';
      btn.classList.toggle('settings-button-primary', on);
      btn.innerHTML = on ? '关闭假数据' : '开启假数据';
      state.textContent = on ? '当前：已开启 — 显示样例数据' : '当前：已关闭 — 显示真实数据';
      // reload so every page picks up the switched data source
      setTimeout(() => location.reload(), 600);
    } catch (e) {
      btn.innerHTML = orig;
    } finally {
      btn.disabled = false;
    }
  }

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
        `<span style="color:var(--positive)"><svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> Chat ID: ${data.chat_id}${label}</span>`;
    } else {
      document.getElementById('tg_test_result').innerHTML =
        `<span style="color:var(--negative)"><svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-x"></use></svg> ${data.error}</span>`;
    }
  }

  async function tgTest(btn) {
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg>';
    const res = await fetch('/api/telegram/test', {method: 'POST'});
    const data = await res.json();
    const el = document.getElementById('tg_test_result');
    if (data.ok) {
      el.innerHTML = '<span style="color:var(--positive)"><svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> 消息已发送！</span>';
      document.getElementById('tg_status_badge').innerHTML =
        '<span class="settings-status settings-status-success"><span class="settings-status-dot"></span>已配置</span><span class="settings-chevron" aria-hidden="true"></span>';
    } else {
      el.innerHTML = `<span style="color:var(--negative)"><svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-x"></use></svg> 失败：${data.error || '未知错误'}</span>`;
    }
    setTimeout(() => { btn.innerHTML = orig; btn.disabled = false; }, 2000);
  }

  async function saveKey(envName, btn) {
    const input = document.getElementById('input_' + envName);
    const value = input.value.trim();
    if (!value) return;
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg>';
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
        badge.innerHTML = '<span class="settings-status settings-status-success"><span class="settings-status-dot"></span>已设置</span>';
        btn.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> 已保存';
        setTimeout(() => { btn.innerHTML = orig; btn.disabled = false; }, 2000);
      } else {
        btn.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-x"></use></svg> 失败';
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
        document.querySelectorAll('.ai-provider-btn').forEach(b => b.classList.remove('is-active'));
        btn.classList.add('is-active');
        status.innerHTML = '当前：<strong style="color:var(--ink)">' + btn.textContent.trim() + '</strong> <span style="color:var(--positive)">已切换</span>';
      } else {
        status.innerHTML = '<span style="color:var(--negative)">切换失败：' + (data.error || '未知错误') + '</span>';
      }
    } catch(e) {
      status.innerHTML = '<span style="color:var(--negative)">切换失败</span>';
    }
  }

  async function setBrokerProvider(value, btn) {
    const status = document.getElementById('brokerProviderStatus');
    const labels = {trading212: 'Trading 212', moomoo: 'Moomoo', ibkr: 'Interactive Brokers'};
    try {
      const res = await fetch('/api/settings/save-key', {
        method: 'POST',
        headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({name: 'BROKER_PROVIDER', value})
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || `HTTP ${res.status}`);
      document.querySelectorAll('.broker-provider-btn').forEach(item => item.classList.remove('is-active'));
      btn.classList.add('is-active');
      status.innerHTML = `当前：<strong>${labels[value] || value}</strong> <span style="color:var(--positive)">已切换</span>`;
      setTimeout(() => location.reload(), 600);
    } catch (err) {
      status.innerHTML = `<span style="color:var(--negative)">切换失败：${err.message}</span>`;
    }
  }

  async function testBroker(provider, btn) {
    const result = document.getElementById('broker_test_' + provider);
    const original = btn.innerHTML;
    btn.disabled = true;
    btn.innerHTML = '<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> 正在连接';
    try {
      const response = await fetch(`/api/brokers/${provider}/test`);
      let payload = {};
      try { payload = await response.json(); } catch (_) {}
      if (!response.ok) {
        const detail = payload.detail || payload;
        throw new Error(detail.message || detail.error || `HTTP ${response.status}`);
      }
      result.innerHTML = `<span style="color:var(--positive)"><svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> ${payload.message || '连接成功'}</span>`;
    } catch (err) {
      result.innerHTML = `<span style="color:var(--negative)"><svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-x"></use></svg> ${err.message}</span>`;
    } finally {
      btn.innerHTML = original;
      btn.disabled = false;
    }
  }

  async function triggerRefresh(type) {
    const statusEl = document.getElementById("settingsStatus");
    statusEl.className = "settings-action-status";

    async function refreshRequest(url) {
      const response = await fetch(url, { method: "POST" });
      let payload = {};
      try { payload = await response.json(); } catch (_) {}
      if (!response.ok) {
        const detail = payload.detail || payload;
        const result = detail && typeof detail === 'object' ? detail : {};
        const summary = result.summary || result.refresh?.summary || {};
        const warnings = summary.warnings || result.warnings || [];
        const fallback = result.stderr || result.warning || result.message || `HTTP ${response.status}`;
        if (summary.error_code === 'authorization_failed' || result.error_code === 'authorization_failed') {
          const english = document.documentElement.lang?.startsWith('en');
          throw new Error(english
            ? 'Trading 212 authorization failed. Enter both the API Key and its matching API Secret.'
            : 'Trading 212 授权失败，请同时填写 API Key 和对应的 API Secret。');
        }
        throw new Error(warnings[0] || fallback);
      }
      return payload;
    }

    if (type === 'all') {
      const steps = [
        ["正在同步当前券商持仓…", "/api/refresh/broker"],
        ["正在增量刷新实时行情…", "/api/refresh/market"],
        ["正在增量刷新历史价格…", "/api/lab/refresh-history"],
        ["正在增量刷新估值数据…", "/api/refresh/fundamentals"],
        ["正在刷新 ETF 完整成分权重…", "/api/refresh/etf-holdings"],
      ];
      try {
        const notes = [];
        for (let index = 0; index < steps.length; index += 1) {
          statusEl.innerHTML = `<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> ${steps[index][0]}（${index + 1}/${steps.length}）`;
          const payload = await refreshRequest(steps[index][1]);
          const changes = payload.refresh?.summary?.changes;
          const stats = payload.market?.refresh_stats || payload.fundamentals?.refresh_stats || payload.refresh_stats;
          if (changes) notes.push(`持仓变更 ${changes.added + changes.updated + changes.removed}`);
          if (stats?.requested !== undefined) notes.push(`请求 ${stats.requested}`);
          if (stats?.incremental !== undefined) notes.push(`历史增量 ${stats.incremental}`);
          if (stats?.updated !== undefined) notes.push(`估值更新 ${stats.updated}`);
        }
        statusEl.className = "settings-action-status positive";
        const detail = notes.length ? `（${notes.join(" · ")}）` : "";
        statusEl.innerHTML = `<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> 全部组合数据已增量刷新。${detail}`;
        setTimeout(() => location.reload(), 1000);
      } catch (err) {
        statusEl.className = "settings-action-status negative";
        statusEl.textContent = `刷新已停止：${err.message}`;
      }
    } else if (type === 'broker') {
      statusEl.innerHTML = '<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> 正在同步当前券商持仓...';
      try {
        const payload = await refreshRequest("/api/refresh/broker");
        statusEl.className = "settings-action-status positive";
        const provider = payload.provider || 'broker';
        statusEl.innerHTML = `<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> ${provider} 同步完成！`;
        setTimeout(() => location.reload(), 1000);
      } catch (err) {
        statusEl.className = "settings-action-status negative";
        statusEl.textContent = `同步失败：${err.message}`;
      }
    } else if (type === 'trading212') {
      statusEl.innerHTML = '<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> 正在同步 Trading 212 持仓...';
      try {
        await refreshRequest("/api/refresh/trading212");
        statusEl.className = "settings-action-status positive";
        statusEl.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> Trading 212 同步完成！';
        setTimeout(() => location.reload(), 1000);
      } catch (err) {
        statusEl.className = "settings-action-status negative";
        statusEl.textContent = `同步失败：${err.message}`;
      }
    } else if (type === 'market') {
      statusEl.innerHTML = '<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> 正在强制拉取最新行情...';
      try {
        const response = await fetch("/api/refresh/market?force=true", { method: "POST" });
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "settings-action-status positive";
        statusEl.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> 行情刷新完成！';
        setTimeout(() => location.reload(), 1000);
      } catch (err) {
        statusEl.className = "settings-action-status negative";
        statusEl.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-x"></use></svg> 刷新失败。';
      }
    } else if (type === 'history') {
      statusEl.innerHTML = '<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> 正在重新获取所有标的历史价格...';
      try {
        const response = await fetch("/api/lab/refresh-history?force=true", { method: "POST" });
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "settings-action-status positive";
        statusEl.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> 历史价格刷新完成！';
        setTimeout(() => location.reload(), 1000);
      } catch (err) {
        statusEl.className = "settings-action-status negative";
        statusEl.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-x"></use></svg> 刷新失败。';
      }
    } else if (type === 'fundamentals') {
      statusEl.innerHTML = '<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> 正在重新拉取 FMP 估值数据...';
      try {
        const response = await fetch("/api/refresh/fundamentals?force=true", { method: "POST" });
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "settings-action-status positive";
        statusEl.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> 估值数据刷新完成！';
        setTimeout(() => location.reload(), 1500);
      } catch (err) {
        statusEl.className = "settings-action-status negative";
        statusEl.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-x"></use></svg> 刷新失败。';
      }
    } else if (type === 'after-hours') {
      statusEl.innerHTML = '<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> 正在拉取 Massive 盘后数据...';
      try {
        const response = await fetch("/api/refresh/after-hours?force=true", { method: "POST" });
        if (!response.ok) throw new Error("HTTP error");
        statusEl.className = "settings-action-status positive";
        statusEl.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> 盘后数据刷新完成！';
        setTimeout(() => location.reload(), 1000);
      } catch (err) {
        statusEl.className = "settings-action-status negative";
        statusEl.innerHTML = '<svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-x"></use></svg> 刷新失败。';
      }
    }
  }

  document.addEventListener('DOMContentLoaded', () => {
    const links = Array.from(document.querySelectorAll('.settings-nav-link'));
    const sections = links
      .map(link => document.querySelector(link.getAttribute('href')))
      .filter(Boolean);

    links.forEach(link => {
      link.addEventListener('click', () => {
        links.forEach(item => item.classList.toggle('is-active', item === link));
      });
    });

    if (!('IntersectionObserver' in window)) return;
    const observer = new IntersectionObserver(entries => {
      const visible = entries
        .filter(entry => entry.isIntersecting)
        .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
      if (!visible) return;
      links.forEach(link => {
        link.classList.toggle('is-active', link.getAttribute('href') === '#' + visible.target.id);
      });
    }, { rootMargin: '-18% 0px -64% 0px', threshold: [0, 0.15, 0.4] });
    sections.forEach(section => observer.observe(section));
  });
