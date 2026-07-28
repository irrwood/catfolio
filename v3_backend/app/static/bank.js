(function () {
  const lang = document.documentElement.lang.startsWith("en") ? "en" : "zh";
  const copy = {
    zh: {
      accounts: (count) => `${count} 个账户 · Demo 数据`,
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
      mailSelected: (name) => `已选择 ${name}。正式版本将跳转到只读 OAuth 授权。`,
      kind: {
        train_delay: "火车延误",
        flight_delay: "航班延误",
        cancelled_journey: "行程取消",
      },
    },
    en: {
      accounts: (count) => `${count} accounts · Demo data`,
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
      mailSelected: (name) => `${name} selected. Production will continue to read-only OAuth.`,
      kind: {
        train_delay: "Train delay",
        flight_delay: "Flight delay",
        cancelled_journey: "Cancelled journey",
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
        <span class="bank-month-label">${copy.months[row.month] || row.month}</span>
      </div>
    `).join("");
  }

  function renderAccounts(accounts) {
    const target = document.getElementById("bankAccountList");
    if (!target) return;
    target.innerHTML = accounts.map((account) => `
      <div class="bank-account-row">
        <div class="bank-account-copy">
          <span class="bank-account-mark">${account.name.slice(0, 1)}</span>
          <span>
            <strong>${account.name}</strong>
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
          <strong>${item.merchant}</strong>
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
            <strong>${item.merchant}</strong>
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
          <strong>${item.merchant}</strong>
          <small>${copy.kind[item.kind] || item.kind} · ${formatDate(item.event_date)}</small>
        </div>
        <div class="bank-email-evidence">
          <strong>${item.subject}</strong>
          <small>${copy.evidence}：${item.evidence} · ${copy.deadline(item.deadline)}</small>
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
    setText("bankAccountCount", copy.accounts(data.accounts.length));
    setText("bankNetCashFlow", money(data.summary.monthly_income - data.summary.monthly_spend));
    setText("bankSubscriptionCost", money(data.summary.monthly_subscriptions));
    setText("bankRefundsRecovered", money(data.summary.refunds_recovered));
    document.getElementById("bankNetCashFlow")?.classList.add("positive");
    document.getElementById("bankRefundsRecovered")?.classList.add("positive");
    renderCashFlow(data.cash_flow);
    renderAccounts(data.accounts);
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

  document.querySelectorAll("[data-open-dialog]").forEach((button) => {
    button.addEventListener("click", () => document.getElementById(button.dataset.openDialog)?.showModal());
  });

  document.querySelectorAll("[data-provider]").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll("[data-provider]").forEach((option) => option.classList.remove("is-selected"));
      button.classList.add("is-selected");
      setText("bankProviderNotice", copy.selected(button.dataset.provider));
    });
  });

  document.querySelectorAll("[data-mail-provider]").forEach((button) => {
    button.addEventListener("click", () => {
      document.querySelectorAll("[data-mail-provider]").forEach((option) => option.classList.remove("is-selected"));
      button.classList.add("is-selected");
      setText("emailProviderNotice", copy.mailSelected(button.dataset.mailProvider));
    });
  });

  loadOverview().catch(() => {
    setText("bankAccountCount", copy.scanError);
  });
})();
