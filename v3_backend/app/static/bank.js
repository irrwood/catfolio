(function () {
  const lang = document.documentElement.lang.startsWith("en") ? "en" : "zh";
  const copy = {
    zh: {
      accounts: (count, source) => `${count} 个账户 · ${source === "plaid" ? "本机数据" : "Demo 数据"}`,
      current: "活期账户",
      savings: "储蓄账户",
      months: { "2月": "2月", "3月": "3月", "4月": "4月", "5月": "5月", "6月": "6月", "7月": "7月" },
      chartValue: (income, spend) => `收入 ${money(income)} · 支出 ${money(spend)}`,
      scan: "扫描中…",
      subscriptionCount: (count) => `${count} 项`,
      refundCount: (count) => `${count} 组`,
      perMonth: "/ 月",
      perYear: (value) => `每年 ${money(value)}`,
      seen: (count) => `已识别 ${count} 次扣款`,
      purchased: (date) => `${formatDate(date)} 消费`,
      refunded: (date) => `${formatDate(date)} 退款`,
      matched: (days) => `${days} 天后到账`,
      refundStatus: "已完整退款",
      evidence: "邮件证据",
      deadline: (value) => `期限：${value}`,
      confidence: (value) => `${Math.round(value * 100)}% 置信度`,
      opportunityCount: (count) => `找到 ${count} 个可能机会`,
      emailError: "邮件扫描失败，请稍后重试。",
      scanError: "识别失败，请稍后重试。",
      selected: (name) => `已选择 ${name}。Demo 不会发起真实授权。`,
      connected: "Plaid · 本机已连接",
      demoBadge: "Demo · 本地分析",
      syncing: "同步中…",
      sync: "同步交易",
      connectError: "无法连接 Plaid，请检查设置里的 Client ID、Secret 和环境配置。",
      plaidLoading: "正在打开 Plaid 安全连接…",
      plaidSuccess: "银行连接成功，交易已加密保存到本机。",
      mailSelected: (name) => `已选择 ${name}。连接会直接从本机访问 IMAP。`,
      mailDisconnected: "邮箱未连接",
      mailConnected: (count) => `${count} 个邮箱 · IMAP 只读`,
      mailConnecting: "正在测试…",
      mailConnect: "测试并连接",
      mailSuccess: "邮箱已连接，凭证保存在系统 Keychain。",
      mailScan: "扫描邮件",
      mailScanDemo: "扫描 Demo 邮件",
      appPassword: "应用专用密码",
      oauthToken: "OAuth2 Access Token",
      kind: {
        train_delay: "火车延误",
        flight_delay: "航班延误",
        cancelled_journey: "行程取消",
        refund_available: "退款通知",
      },
    },
    en: {
      accounts: (count, source) => `${count} accounts · ${source === "plaid" ? "Local data" : "Demo data"}`,
      current: "Current account",
      savings: "Savings account",
      months: { "2月": "Feb", "3月": "Mar", "4月": "Apr", "5月": "May", "6月": "Jun", "7月": "Jul" },
      chartValue: (income, spend) => `Income ${money(income)} · spend ${money(spend)}`,
      scan: "Scanning…",
      subscriptionCount: (count) => `${count} items`,
      refundCount: (count) => `${count} pairs`,
      perMonth: "/ month",
      perYear: (value) => `${money(value)} per year`,
      seen: (count) => `${count} payments detected`,
      purchased: (date) => `Purchased ${formatDate(date)}`,
      refunded: (date) => `Refunded ${formatDate(date)}`,
      matched: (days) => `Received after ${days} days`,
      refundStatus: "Fully refunded",
      evidence: "Email evidence",
      deadline: (value) => `Deadline: ${value}`,
      confidence: (value) => `${Math.round(value * 100)}% confidence`,
      opportunityCount: (count) => `${count} possible opportunities`,
      emailError: "Email scan failed. Try again.",
      scanError: "Scan failed. Try again.",
      selected: (name) => `${name} selected. The demo will not start a real authorisation.`,
      connected: "Plaid · Connected locally",
      demoBadge: "Demo · Local analysis",
      syncing: "Syncing…",
      sync: "Sync transactions",
      connectError: "Plaid could not connect. Check the Client ID, Secret, and environment in Settings.",
      plaidLoading: "Opening Plaid secure connection…",
      plaidSuccess: "Bank connected. Transactions were encrypted and saved locally.",
      mailSelected: (name) => `${name} selected. Catfolio will connect directly over IMAP.`,
      mailDisconnected: "Email not connected",
      mailConnected: (count) => `${count} email account${count === 1 ? "" : "s"} · Read-only IMAP`,
      mailConnecting: "Testing…",
      mailConnect: "Test and connect",
      mailSuccess: "Email connected. The credential is stored in the system Keychain.",
      mailScan: "Scan email",
      mailScanDemo: "Scan demo email",
      appPassword: "App password",
      oauthToken: "OAuth2 Access Token",
      kind: {
        train_delay: "Train delay",
        flight_delay: "Flight delay",
        cancelled_journey: "Cancelled journey",
        refund_available: "Refund notice",
      },
    },
  }[lang];

  function money(value) {
    return new Intl.NumberFormat(lang === "en" ? "en-GB" : "zh-CN", {
      style: "currency",
      currency: "GBP",
      maximumFractionDigits: 2,
    }).format(Number(value || 0));
  }

  function formatDate(value) {
    const parsed = new Date(`${value}T00:00:00Z`);
    return parsed.toLocaleDateString(lang === "en" ? "en-GB" : "zh-CN", {
      day: "numeric",
      month: "short",
      timeZone: "UTC",
    });
  }

  function formatMonth(value) {
    if (/^\d{4}-\d{2}$/.test(value)) {
      const parsed = new Date(`${value}-01T00:00:00Z`);
      return parsed.toLocaleDateString(lang === "en" ? "en-GB" : "zh-CN", {
        month: "short",
        timeZone: "UTC",
      });
    }
    return copy.months[value] || value;
  }

  function escapeHtml(value) {
    return String(value ?? "")
      .replaceAll("&", "&amp;")
      .replaceAll("<", "&lt;")
      .replaceAll(">", "&gt;")
      .replaceAll('"', "&quot;")
      .replaceAll("'", "&#039;");
  }

  function setText(id, value) {
    const node = document.getElementById(id);
    if (node) node.textContent = value;
  }

  function renderCashFlow(rows) {
    const chart = document.getElementById("bankCashFlowChart");
    if (!chart) return;
    const peak = Math.max(...rows.flatMap((row) => [row.income, row.spend]), 1);
    chart.innerHTML = rows.map((row, index) => `
      <div class="bank-month" style="--delay:${index * 45}ms">
        <span class="bank-month-value">${copy.chartValue(row.income, row.spend)}</span>
        <i class="bank-bar income" style="height:${Math.max(4, row.income / peak * 100)}%;animation-delay:${index * 45}ms"></i>
        <i class="bank-bar spend" style="height:${Math.max(4, row.spend / peak * 100)}%;animation-delay:${index * 45 + 35}ms"></i>
        <span class="bank-month-label">${escapeHtml(formatMonth(row.month))}</span>
      </div>
    `).join("");
  }

  function renderAccounts(accounts) {
    const target = document.getElementById("bankAccountList");
    if (!target) return;
    target.innerHTML = accounts.map((account) => `
      <div class="bank-account-row">
        <div class="bank-account-copy">
          <span class="bank-account-mark">${escapeHtml(account.name.slice(0, 1))}</span>
          <span>
            <strong>${escapeHtml(account.name)}</strong>
            <small>${account.type === "savings" ? copy.savings : copy.current}</small>
          </span>
        </div>
        <span class="bank-account-balance">${money(account.balance)}</span>
      </div>
    `).join("");
  }

  function renderSubscriptions(items) {
    const target = document.getElementById("subscriptionList");
    setText("subscriptionCount", copy.subscriptionCount(items.length));
    target.innerHTML = items.map((item, index) => `
      <article class="bank-result-row" style="animation-delay:${index * 45}ms">
        <div>
          <strong>${escapeHtml(item.merchant)}</strong>
          <small>${copy.seen(item.payments_seen)} · ${copy.perYear(item.annual_cost)}</small>
        </div>
        <div class="bank-result-number">
          <strong>${money(item.amount)} ${copy.perMonth}</strong>
          <small>${Math.round(item.confidence * 100)}%</small>
        </div>
      </article>
    `).join("");
  }

  function renderRefunds(items) {
    const target = document.getElementById("refundList");
    setText("refundCount", copy.refundCount(items.length));
    target.innerHTML = items.map((item, index) => `
      <article class="bank-refund-row" style="animation-delay:${index * 45}ms">
        <div class="bank-refund-main">
          <div>
            <strong>${escapeHtml(item.merchant)}</strong>
            <small class="bank-refund-status">${copy.refundStatus} · ${copy.matched(item.days)}</small>
          </div>
          <span class="bank-refund-amount">${money(item.amount)}</span>
        </div>
        <div class="bank-refund-flow">
          <span>${copy.purchased(item.purchase_date)}</span>
          <i aria-hidden="true"></i>
          <span>${copy.refunded(item.refund_date)}</span>
        </div>
      </article>
    `).join("");
  }

  function renderEmail(items) {
    const target = document.getElementById("emailOpportunityList");
    document.querySelector(".bank-mail-status").textContent = copy.opportunityCount(items.length);
    target.innerHTML = items.map((item, index) => `
      <article class="bank-email-row" style="animation-delay:${index * 45}ms">
        <div class="bank-email-merchant">
          <strong>${escapeHtml(item.merchant)}</strong>
          <small>${copy.kind[item.kind] || item.kind} · ${formatDate(item.event_date)}</small>
        </div>
        <div class="bank-email-evidence">
          <strong>${escapeHtml(item.subject)}</strong>
          <small>${copy.evidence}：${escapeHtml(item.evidence)} · ${escapeHtml(copy.deadline(item.deadline))}</small>
        </div>
        <span class="bank-confidence">${copy.confidence(item.confidence)}</span>
        <span class="bank-email-amount">≈ ${money(item.estimated_amount)}</span>
      </article>
    `).join("");
  }

  async function loadOverview() {
    const response = await fetch("/api/bank/overview");
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const data = await response.json();
    setText("bankTotalBalance", money(data.summary.balance));
    setText("bankAccountCount", copy.accounts(data.accounts.length, data.provider));
    setText("bankNetCashFlow", money(data.summary.monthly_income - data.summary.monthly_spend));
    setText("bankSubscriptionCost", money(data.summary.monthly_subscriptions));
    setText("bankRefundsRecovered", money(data.summary.refunds_recovered));
    document.getElementById("bankNetCashFlow")?.classList.add("positive");
    document.getElementById("bankRefundsRecovered")?.classList.add("positive");
    renderCashFlow(data.cash_flow);
    renderAccounts(data.accounts);
    const badge = document.getElementById("bankConnectionBadge");
    const syncButton = document.getElementById("bankSyncBtn");
    if (badge) badge.lastChild.textContent = data.connected ? copy.connected : copy.demoBadge;
    if (syncButton) syncButton.hidden = !data.connected;
  }

  async function scan(button, path, render, errorText) {
    const original = button.textContent;
    button.disabled = true;
    button.textContent = copy.scan;
    try {
      const response = await fetch(path, { method: "POST" });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      render(data.items || []);
    } catch (error) {
      const targetId = path.includes("subscription")
        ? "subscriptionList"
        : path.includes("refund")
          ? "refundList"
          : "emailOpportunityList";
      document.getElementById(targetId).innerHTML = `<div class="bank-empty">${errorText}</div>`;
    } finally {
      button.disabled = false;
      button.textContent = original;
    }
  }

  document.getElementById("scanSubscriptionsBtn")?.addEventListener("click", (event) => {
    scan(event.currentTarget, "/api/bank/scan-subscriptions", renderSubscriptions, copy.scanError);
  });

  document.getElementById("scanRefundsBtn")?.addEventListener("click", (event) => {
    scan(event.currentTarget, "/api/bank/scan-refunds", renderRefunds, copy.scanError);
  });

  document.getElementById("scanEmailBtn")?.addEventListener("click", (event) => {
    scan(event.currentTarget, "/api/bank/scan-email", renderEmail, copy.emailError);
  });

  async function responseJson(response) {
    const data = await response.json().catch(() => ({}));
    if (!response.ok || data.ok === false) {
      const error = new Error(data.error || `HTTP ${response.status}`);
      error.code = data.error_code || "";
      throw error;
    }
    return data;
  }

  function ensurePlaidScript() {
    if (window.Plaid) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const existing = document.querySelector('script[data-catfolio-plaid]');
      if (existing) {
        existing.addEventListener("load", resolve, { once: true });
        existing.addEventListener("error", reject, { once: true });
        return;
      }
      const script = document.createElement("script");
      script.src = "https://cdn.plaid.com/link/v2/stable/link-initialize.js";
      script.dataset.catfolioPlaid = "1";
      script.onload = resolve;
      script.onerror = reject;
      document.head.appendChild(script);
    });
  }

  async function startPlaidLink(button) {
    const notice = document.getElementById("bankProviderNotice");
    button.disabled = true;
    if (notice) notice.textContent = copy.plaidLoading;
    try {
      const tokenData = await responseJson(await fetch("/api/bank/plaid/link-token", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
      }));
      await ensurePlaidScript();
      const handler = window.Plaid.create({
        token: tokenData.link_token,
        onSuccess: async (publicToken, metadata) => {
          try {
            await responseJson(await fetch("/api/bank/plaid/exchange", {
              method: "POST",
              headers: { "Content-Type": "application/json" },
              body: JSON.stringify({ public_token: publicToken, metadata }),
            }));
            if (notice) notice.textContent = copy.plaidSuccess;
            document.getElementById("bankConnectDialog")?.close();
            await loadOverview();
          } catch (error) {
            if (notice) notice.textContent = error.message || copy.connectError;
          } finally {
            button.disabled = false;
          }
        },
        onExit: (error) => {
          if (error && notice) notice.textContent = error.display_message || error.error_message || copy.connectError;
          button.disabled = false;
        },
      });
      handler.open();
    } catch (error) {
      if (notice) notice.textContent = error.code === "PLAID_NOT_CONFIGURED"
        ? copy.connectError
        : error.message || copy.connectError;
      button.disabled = false;
    }
  }

  document.querySelectorAll("[data-open-dialog]").forEach((button) => {
    button.addEventListener("click", () => document.getElementById(button.dataset.openDialog)?.showModal());
  });

  document.querySelectorAll("[data-provider]").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll("[data-provider]").forEach((option) => option.classList.remove("is-selected"));
      button.classList.add("is-selected");
      if (button.dataset.provider === "Plaid") {
        startPlaidLink(button);
      } else {
        setText("bankProviderNotice", copy.selected(button.dataset.provider));
      }
    });
  });

  document.getElementById("bankSyncBtn")?.addEventListener("click", async (event) => {
    const button = event.currentTarget;
    button.disabled = true;
    button.textContent = copy.syncing;
    try {
      await responseJson(await fetch("/api/bank/plaid/sync", { method: "POST" }));
      await loadOverview();
    } catch (error) {
      setText("bankAccountCount", error.message || copy.scanError);
    } finally {
      button.disabled = false;
      button.textContent = copy.sync;
    }
  });

  document.querySelectorAll("[data-mail-provider]").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll("[data-mail-provider]").forEach((option) => option.classList.remove("is-selected"));
      button.classList.add("is-selected");
      document.getElementById("emailConnectFields").hidden = false;
      document.getElementById("emailConnectFields").dataset.provider = button.dataset.mailProvider;
      document.getElementById("mailHostField").hidden = button.dataset.mailProvider !== "imap";
      const auth = document.getElementById("mailAuthType");
      if (button.dataset.mailProvider === "outlook") auth.value = "oauth2";
      auth.dispatchEvent(new Event("change"));
      setText("emailProviderNotice", copy.mailSelected(button.dataset.mailProvider));
    });
  });

  document.getElementById("mailAuthType")?.addEventListener("change", (event) => {
    setText("mailCredentialLabel", event.currentTarget.value === "oauth2"
      ? copy.oauthToken
      : copy.appPassword);
  });

  async function loadMailStatus() {
    const data = await responseJson(await fetch("/api/mail/status"));
    const status = document.querySelector(".bank-mail-status");
    if (status) status.textContent = data.connected
      ? copy.mailConnected(data.accounts.length)
      : copy.mailDisconnected;
    const scanButton = document.getElementById("scanEmailBtn");
    if (scanButton) scanButton.textContent = data.source === "demo"
      ? copy.mailScanDemo
      : copy.mailScan;
    return data;
  }

  document.getElementById("mailConnectBtn")?.addEventListener("click", async (event) => {
    const button = event.currentTarget;
    const fields = document.getElementById("emailConnectFields");
    const provider = fields.dataset.provider || "imap";
    button.disabled = true;
    button.textContent = copy.mailConnecting;
    try {
      const data = await responseJson(await fetch("/api/mail/connect", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          provider,
          email: document.getElementById("mailEmail").value.trim(),
          credential: document.getElementById("mailCredential").value,
          auth_type: document.getElementById("mailAuthType").value,
          host: document.getElementById("mailHost").value.trim(),
          port: 993,
        }),
      }));
      document.getElementById("mailCredential").value = "";
      setText("emailProviderNotice", copy.mailSuccess);
      await loadMailStatus();
      setTimeout(() => document.getElementById("emailConnectDialog")?.close(), 500);
      return data;
    } catch (error) {
      setText("emailProviderNotice", error.message || copy.emailError);
    } finally {
      button.disabled = false;
      button.textContent = copy.mailConnect;
    }
  });

  loadOverview().catch(() => {
    setText("bankAccountCount", copy.scanError);
  });
  loadMailStatus().catch(() => {
    const status = document.querySelector(".bank-mail-status");
    if (status) status.textContent = copy.mailDisconnected;
  });
})();
