  function currentLang() {
    return (document.documentElement.lang || "zh").startsWith("en") ? "en" : "zh";
  }

  const UI = currentLang() === "en" ? {
    briefingHint: "Use the top-right refresh button to generate a portfolio summary.",
    briefingLoading: "AI is analyzing your portfolio...",
    loadFailed: "Failed to load",
    retry: "Retry",
    enterQuestion: "Enter a question",
    analyzing: "AI is analyzing...",
    thinking: "Thinking...",
    createReminder: "Create reminder",
    analysisFailed: "AI analysis failed",
    failed: "Failed",
    reminderLoading: "Generating reminder draft...",
    noCondition: "This answer does not contain a measurable reminder condition.",
    reminderDraft: "AI reminder draft",
    concentrationReminderTitle: "AI concentration risk alert",
    concentrationReminderMessage: "Portfolio concentration risk has increased. Review single-stock, sector, and index-substitution options.",
    cancel: "Cancel",
    draftFailed: "Failed to generate reminder draft:",
    keepCondition: "Keep at least one trigger condition.",
    reminderCreated: "Reminder created:",
    createFailed: "Failed to create:",
    moreQuestions: "Generate more",
    moreQuestionsAgain: "Another batch",
    generatedQuestions: "New questions",
  } : {
    briefingHint: "点击右上角刷新按钮生成组合总结。",
    briefingLoading: "AI 正在分析你的组合...",
    loadFailed: "加载失败",
    retry: "重试",
    enterQuestion: "请输入一个问题",
    analyzing: "AI 正在分析...",
    thinking: "思考中...",
    createReminder: "创建提醒",
    analysisFailed: "AI 分析失败",
    failed: "失败",
    reminderLoading: "正在生成提醒草稿...",
    noCondition: "这条回答里没有可监控的数字条件。",
    reminderDraft: "AI 提醒草稿",
    concentrationReminderTitle: "AI 集中风险提醒",
    concentrationReminderMessage: "当前组合集中风险上升，请重新评估单票、行业和指数替代方案。",
    cancel: "取消",
    draftFailed: "提醒草稿生成失败：",
    keepCondition: "至少保留一个触发条件。",
    reminderCreated: "已创建提醒：",
    createFailed: "创建失败：",
    moreQuestions: "生成更多",
    moreQuestionsAgain: "再来一批",
    generatedQuestions: "新生成的问题",
  };

  // ── Question Bank ──
  const Q_ZH = {
    quick: [
      "为什么今天涨跌？",
      "我现在主要在赌什么？",
      "我的组合是不是太集中？",
      "如果 QQQ 跌 10%，我会怎样？",
      "哪个持仓贡献最大？",
      "怎么降低最大回撤？",
      "我的 ETF 和个股有没有重复？",
      "这次回撤是谁造成的？"
    ],
    bet: [
      "我的组合是真分散还是假分散？",
      "我是不是买了太多科技股？",
      "我是不是过度暴露在 AI 主题？",
      "我是不是太依赖 NVDA？",
      "我同时买了很多重复资产吗？"
    ],
    risk: [
      "我现在最大的风险是什么？",
      "如果市场下跌，我哪里最脆弱？",
      "我的组合 Beta 高吗？",
      "我的波动率是不是太高？",
      "我的现金比例够不够？",
      "我的组合适合长期拿吗？"
    ],
    whatIf: [
      "如果 QQQ 跌 10%，我会亏多少？",
      "如果 NVDA 跌 20%，组合会怎样？",
      "如果我卖掉 Unity，会降低多少风险？",
      "如果我买 10% VOO，组合会更稳吗？",
      "如果我加 20% 现金，最大回撤会下降多少？",
      "如果我减半 NVDA，收益和风险会怎么变？"
    ],
    overlap: [
      "QQQ 和我的个股重叠吗？",
      "SMH 和 NVDA 重叠严重吗？",
      "我的真实 NVDA 暴露是多少？",
      "哪些持仓其实是同一个方向？",
      "我的 Apple 暴露是不是比表面更高？"
    ],
    performance: [
      "过去 30 天收益主要来自哪里？",
      "今年收益主要靠哪几只股票？",
      "我的收益是靠个股选择还是靠市场上涨？",
      "哪个板块贡献最大？",
      "如果去掉 NVDA，组合还赚钱吗？",
      "如果去掉前 3 大赢家，组合表现怎样？"
    ],
    drawdown: [
      "这次回撤是怎么造成的？",
      "为什么我跌得比大盘多？",
      "这次亏损主要来自哪几只？",
      "这次是市场问题还是持仓结构问题？",
      "如果我减仓 NVDA 到 10%，风险会下降多少？",
      "如果我卖掉 TSLA 换成 VOO，会怎样？"
    ],
    more: [
      "当前组合最依赖哪三个未来假设？",
      "什么数据会证伪我第一大持仓的逻辑？",
      "如果利率在高位维持一年，哪些持仓最脆弱？",
      "如果 AI 资本开支放缓，组合会如何传导？",
      "如果半导体估值回归历史中位，我会损失多少？",
      "未来 12 个月最可能改变组合风格的变量是什么？",
      "哪个持仓的下行风险与上行弹性最不对称？",
      "如果美元走强 10%，我的跨币种暴露会怎样？",
      "如果组合相关性在危机中升到 0.8，分散还有效吗？",
      "哪些持仓看似不同，但在下跌时可能同时失效？",
      "如果前三大赢家未来一年只横盘，组合还有多少动力？",
      "如果最大持仓下跌 15%，对总市值的直接冲击是多少？",
      "我的预期收益中，有多少其实来自估值继续扩张？",
      "如果市场从成长切换到价值，组合会跑输多少？",
      "什么宏观情景对我的组合最有利，什么情景最不利？",
      "哪个风险平时看不见，但可能在回撤时突然放大？",
      "如果明年收益只有历史回测的一半，风险收益还合理吗？",
      "用乐观、基准、悲观三种情景估算组合一年后的区间。"
    ]
  };
  const Q_EN = {
    quick: [
      "Why did my portfolio move today?",
      "What am I mainly betting on?",
      "Is my portfolio too concentrated?",
      "What happens if QQQ drops 10%?",
      "Which holding contributed the most?",
      "How can I reduce max drawdown?",
      "Do my ETFs overlap with individual stocks?",
      "What caused this drawdown?"
    ],
    bet: [
      "Is my portfolio truly diversified?",
      "Do I own too much technology?",
      "Am I overexposed to the AI theme?",
      "Am I too dependent on NVDA?",
      "Do I own duplicate exposures?"
    ],
    risk: [
      "What is my biggest risk right now?",
      "Where am I most vulnerable if the market falls?",
      "Is my portfolio beta high?",
      "Is my volatility too high?",
      "Is my cash allocation sufficient?",
      "Is this portfolio suitable for long-term holding?"
    ],
    whatIf: [
      "How much would I lose if QQQ drops 10%?",
      "What happens if NVDA drops 20%?",
      "How much risk falls if I sell Unity?",
      "Would adding 10% VOO make the portfolio more stable?",
      "How would 20% cash change max drawdown?",
      "What changes if I halve my NVDA position?"
    ],
    overlap: [
      "Does QQQ overlap with my individual stocks?",
      "How severe is the overlap between SMH and NVDA?",
      "What is my true NVDA exposure?",
      "Which holdings are effectively the same bet?",
      "Is my Apple exposure higher than it appears?"
    ],
    performance: [
      "What drove returns over the past 30 days?",
      "Which stocks drove returns this year?",
      "Did returns come from stock selection or the market?",
      "Which sector contributed the most?",
      "Would the portfolio still be profitable without NVDA?",
      "How would performance look without the top three winners?"
    ],
    drawdown: [
      "What caused this drawdown?",
      "Why did I fall more than the market?",
      "Which holdings caused most of this loss?",
      "Was this a market problem or a portfolio-structure problem?",
      "How much risk falls if NVDA is reduced to 10%?",
      "What changes if I replace TSLA with VOO?"
    ],
    more: [
      "Which three future assumptions does this portfolio depend on most?",
      "What evidence would invalidate the thesis behind my largest holding?",
      "Which holdings are most vulnerable if rates stay high for another year?",
      "How would slower AI capital spending propagate through my portfolio?",
      "What happens if semiconductor valuations revert to their historical median?",
      "Which variable is most likely to change the portfolio's style over the next 12 months?",
      "Which holding has the most asymmetric downside versus upside?",
      "How would a 10% stronger dollar affect my cross-currency exposure?",
      "Is diversification still effective if correlations rise to 0.8 in a crisis?",
      "Which different-looking holdings could fail together in a selloff?",
      "What happens if my top three winners trade sideways for a year?",
      "How much does portfolio value fall if the largest holding drops 15%?",
      "How much of expected return depends on valuations expanding further?",
      "What happens if the market rotates from growth to value?",
      "Which macro scenario helps this portfolio most, and which hurts it most?",
      "Which hidden risk could suddenly amplify during a drawdown?",
      "Is the risk-return profile still sound if future returns are half the backtest?",
      "Estimate a one-year range under optimistic, base, and bearish scenarios."
    ]
  };
  const Q = currentLang() === "en" ? Q_EN : Q_ZH;

  function renderChips(containerId, questions) {
    const el = document.querySelector(containerId);
    if (!el) return;
    el.innerHTML = questions
      .map(q => `<button class="qb-chip" type="button" onclick="quickAsk(this)">${escapeHtml(q)}</button>`)
      .join("");
  }

  Object.entries({
    "#quickQuestions": Q.quick,
    "#betQuestions": Q.bet,
    "#riskQuestions": Q.risk,
    "#whatIfQuestions": Q.whatIf,
    "#overlapQuestions": Q.overlap,
    "#performanceQuestions": Q.performance,
    "#drawdownQuestions": Q.drawdown
  }).forEach(([sel, qs]) => renderChips(sel, qs));

  const promptLibrary = document.querySelector(".ai-prompt-library");
  function syncPromptLibraryHeader() {
    promptLibrary?.classList.toggle("is-scrolled", promptLibrary.scrollTop > 1);
  }
  promptLibrary?.addEventListener("scroll", syncPromptLibraryHeader, { passive: true });
  syncPromptLibraryHeader();

  const MORE_QUESTION_BATCH = 6;
  let moreQuestionCursor = 0;

  function generateMoreQuestions() {
    const group = document.querySelector("#generatedQuestionsGroup");
    const title = document.querySelector("#generatedQuestionsTitle");
    const button = document.querySelector("#moreQuestionsBtn");
    const batch = Array.from({ length: MORE_QUESTION_BATCH }, (_, index) =>
      Q.more[(moreQuestionCursor + index) % Q.more.length]
    );
    moreQuestionCursor = (moreQuestionCursor + MORE_QUESTION_BATCH) % Q.more.length;
    renderChips("#generatedQuestions", batch);
    group.hidden = false;
    group.open = true;
    title.textContent = UI.generatedQuestions;
    button.querySelector(".prompt-more-label").textContent = UI.moreQuestionsAgain;
    group.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  // ── Core API ──
  async function aiPost(url, body) {
    const payload = { ...(body || {}) };
    if (url.startsWith("/api/ai/")) payload.lang = currentLang();
    const resp = await fetch(url, { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(payload) });
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    return resp.json();
  }

  // ── Briefing (cached, manual refresh) ──
  const BRIEFING_KEY = "ai_briefing_v1_" + currentLang();
  function showCachedBriefing() {
    const cached = localStorage.getItem(BRIEFING_KEY);
    const status = document.querySelector("#briefingStatus");
    const content = document.querySelector("#briefingContent");
    const text = document.querySelector("#briefingText");
    if (!status || !content || !text) return false;
    if (cached) {
      try {
        const data = JSON.parse(cached);
        text.textContent = data.briefing;
        status.style.display = "none";
        content.style.display = "block";
        return true;
      } catch(e) {}
    }
    status.innerHTML = `<span style="color:var(--muted)">${UI.briefingHint}</span>`;
    content.style.display = "none";
    return false;
  }

  async function loadBriefing() {
    const status = document.querySelector("#briefingStatus");
    const content = document.querySelector("#briefingContent");
    const text = document.querySelector("#briefingText");
    if (!status || !content || !text) return;
    status.style.display = "block";
    status.innerHTML = `<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> ${UI.briefingLoading}`;
    content.style.display = "none";
    try {
      const data = await aiPost("/api/ai/briefing");
      text.textContent = data.briefing;
      localStorage.setItem(BRIEFING_KEY, JSON.stringify(data));
      status.style.display = "none";
      content.style.display = "block";
    } catch(e) {
      status.innerHTML = `<span style="color:var(--negative)">${UI.loadFailed}: ${escapeHtml(e.message)} <button class="btn" onclick="loadBriefing()" style="font-size:11px;padding:2px 8px;">${UI.retry}</button></span>`;
    }
  }

  // ── Quick Ask (from chip) ──
  function quickAsk(chip) {
    const question = chip.textContent.trim();
    document.querySelector("#aiAskInput").value = question;
    doAsk();
  }

  // ── Ask question ──
  async function doAsk() {
    const input = document.querySelector("#aiAskInput");
    const btn = document.querySelector("#askBtn");
    const status = document.querySelector("#askStatus");
    const conv = document.querySelector("#convArea");
    const question = input.value.trim();
    if (!question) { status.innerHTML = `<span style="color:var(--negative)">${UI.enterQuestion}</span>`; return; }

    input.value = "";
    btn.disabled = true;
    status.innerHTML = `<svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> ${UI.analyzing}`;

    // Add question to conversation
    const itemId = "conv-" + Date.now();
    document.querySelector(".ai-chat-scroll")?.classList.add("has-conversation");
    conv.insertAdjacentHTML("beforeend",
      `<div class="conv-item" id="${itemId}"><div class="conv-q">${escapeHtml(question)}</div><div class="conv-a loading"><svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> ${UI.thinking}</div></div>`);
    document.querySelector(".ai-chat-scroll")?.scrollTo({ top: 1e9, behavior: "smooth" });

    try {
      const data = await aiPost("/api/ai/ask", {question});
      const answerEl = document.querySelector(`#${itemId} .conv-a`);
      answerEl.textContent = data.answer;
      answerEl.classList.remove("loading");
      answerEl.insertAdjacentHTML("afterend", `
        <div class="ai-reminder-actions">
          <button class="btn" onclick="previewReminderFromAnswer('${itemId}')">
            <svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-bell"></use></svg> ${UI.createReminder}
          </button>
        </div>
        <div class="ai-reminder-draft" id="${itemId}-reminder"></div>
      `);
      status.innerHTML = "";
      document.querySelector(".ai-chat-scroll")?.scrollTo({ top: 1e9, behavior: "smooth" });
    } catch(e) {
      const answerEl = document.querySelector(`#${itemId} .conv-a`);
      answerEl.textContent = `${UI.analysisFailed}: ${e.message}`;
      answerEl.classList.remove("loading");
      answerEl.style.color = "var(--negative)";
      status.innerHTML = `<span style="color:var(--negative)">${UI.failed}: ${escapeHtml(e.message)}</span>`;
    } finally {
      btn.disabled = false;
    }
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" }[c]));
  }

  function reminderPercent(value) {
    return `${(Math.abs(Number(value || 0)) * 100).toLocaleString("en-GB", { maximumFractionDigits: 1 })}%`;
  }

  function localizeReminderCondition(condition) {
    if (currentLang() !== "en") return condition.label || condition.metric;
    const value = Number(condition.value || 0);
    switch (condition.metric) {
      case "single_holding_weight":
        return `Any holding exceeds ${reminderPercent(value)}`;
      case "top_n_weight":
        return `Top ${Number(condition.n || 5)} holdings exceed ${reminderPercent(value)}`;
      case "sector_exposure":
        return `${condition.sector || "Sector"} exposure exceeds ${reminderPercent(value)}`;
      case "portfolio_qqq_correlation":
        return `QQQ correlation exceeds ${value.toFixed(2)}`;
      case "portfolio_beta":
        return `Portfolio beta exceeds ${value.toFixed(2)}`;
      case "max_drawdown":
        return `Maximum drawdown exceeds ${reminderPercent(value)}`;
      case "sharpe":
        return `Sharpe falls below ${value.toFixed(2)}`;
      default:
        return condition.label || condition.metric;
    }
  }

  function localizeReminderDraft(draft) {
    if (currentLang() !== "en") return draft;
    return {
      ...draft,
      title: UI.concentrationReminderTitle,
      message: UI.concentrationReminderMessage,
      conditions: (draft.conditions || []).map(condition => ({
        ...condition,
        label: localizeReminderCondition(condition),
      })),
    };
  }

  async function previewReminderFromAnswer(itemId) {
    const answer = document.querySelector(`#${itemId} .conv-a`)?.textContent || "";
    const box = document.querySelector(`#${itemId}-reminder`);
    box.innerHTML = `<div class="ai-reminder-box"><svg class="hi hi-inline hi-spin" aria-hidden="true" focusable="false"><use href="#hi-spinner"></use></svg> ${UI.reminderLoading}</div>`;
    try {
      const data = await aiPost("/api/alerts/preview-ai-reminders", { text: answer });
      const sourceDraft = (data.drafts || [])[0];
      if (!sourceDraft) {
        box.innerHTML = `<div class="ai-reminder-box muted">${UI.noCondition}</div>`;
        return;
      }
      const draft = localizeReminderDraft(sourceDraft);
      box.dataset.draft = JSON.stringify(draft);
      box.innerHTML = `
        <div class="ai-reminder-box">
          <div class="ai-reminder-head">
            <b>${escapeHtml(draft.title)}</b>
            <span>${UI.reminderDraft}</span>
          </div>
          <div class="ai-reminder-rule-list">
            ${draft.conditions.map((c, index) => `
              <label class="ai-reminder-rule">
                <input type="checkbox" checked data-condition-index="${index}">
                <span>${escapeHtml(c.label || c.metric)}</span>
              </label>
            `).join("")}
          </div>
          <div class="ai-reminder-footer">
            <button class="btn primary" onclick="saveReminderDraft('${itemId}')"><svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check"></use></svg> ${UI.createReminder}</button>
            <button class="btn" onclick="document.querySelector('#${itemId}-reminder').innerHTML=''">${UI.cancel}</button>
          </div>
        </div>`;
    } catch (error) {
      box.innerHTML = `<div class="ai-reminder-box negative">${UI.draftFailed} ${escapeHtml(error.message)}</div>`;
    }
  }

  async function saveReminderDraft(itemId) {
    const box = document.querySelector(`#${itemId}-reminder`);
    const draft = JSON.parse(box.dataset.draft || "{}");
    const checked = [...box.querySelectorAll("input[data-condition-index]:checked")].map(input => Number(input.dataset.conditionIndex));
    draft.conditions = (draft.conditions || []).filter((_, index) => checked.includes(index));
    if (!draft.conditions.length) {
      box.querySelector(".ai-reminder-footer").insertAdjacentHTML("beforebegin", `<div class="negative">${UI.keepCondition}</div>`);
      return;
    }
    try {
      const data = await aiPost("/api/alerts", draft);
      const created = localizeReminderDraft(data.rule || draft);
      box.innerHTML = `<div class="ai-reminder-box positive"><svg class="hi hi-inline" aria-hidden="true" focusable="false"><use href="#hi-check-circle"></use></svg> ${UI.reminderCreated} ${escapeHtml(created.title)}</div>`;
    } catch (error) {
      box.innerHTML = `<div class="ai-reminder-box negative">${UI.createFailed} ${escapeHtml(error.message)}</div>`;
    }
  }

  // Init
  showCachedBriefing();
