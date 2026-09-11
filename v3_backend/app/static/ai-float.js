(function () {
  const root = document.getElementById("globalAiFloat");
  if (!root) return;

  const panel = document.getElementById("globalAiPanel");
  const launcher = document.getElementById("globalAiLauncher");
  const closeButton = document.getElementById("globalAiClose");
  const form = document.getElementById("globalAiComposer");
  const input = document.getElementById("globalAiInput");
  const sendButton = document.getElementById("globalAiSend");
  const suggestionsButton = document.getElementById("globalAiSuggestions");
  const starters = document.getElementById("globalAiStarters");
  const conversation = document.getElementById("globalAiConversation");
  const scroll = document.getElementById("globalAiScroll");
  const status = document.getElementById("globalAiStatus");
  const isEnglish = (document.documentElement.lang || "zh").startsWith("en");
  const OPEN_KEY = "catfolio_global_ai_open_v1";
  const MESSAGES_KEY = "catfolio_global_ai_messages_v1";
  const copy = isEnglish ? {
    enter: "Enter a question",
    thinking: "Thinking…",
    failed: "AI analysis failed",
    starters: ["What am I mainly betting on?", "Is my portfolio too concentrated?", "What happens if QQQ drops 10%?"],
  } : {
    enter: "请输入一个问题",
    thinking: "思考中…",
    failed: "AI 分析失败",
    starters: ["我现在主要在赌什么？", "我的组合是不是太集中？", "如果 QQQ 跌 10%，我会怎样？"],
  };
  let messages = [];

  try {
    const saved = JSON.parse(sessionStorage.getItem(MESSAGES_KEY) || "[]");
    if (Array.isArray(saved)) messages = saved.slice(-20);
  } catch (_) {
    messages = [];
  }

  function persistMessages() {
    sessionStorage.setItem(MESSAGES_KEY, JSON.stringify(messages.slice(-20)));
  }

  function renderMessage(message) {
    const bubble = document.createElement("div");
    bubble.className = `global-ai-message ${message.role}${message.error ? " error" : ""}`;
    bubble.textContent = message.text;
    conversation.appendChild(bubble);
    panel.classList.add("has-conversation");
    return bubble;
  }

  messages.forEach(renderMessage);

  function scrollToLatest(behavior) {
    scroll.scrollTo({ top: scroll.scrollHeight, behavior: behavior || "smooth" });
  }

  function setOpen(open, focusInput) {
    panel.hidden = !open;
    launcher.hidden = open;
    launcher.setAttribute("aria-expanded", String(open));
    localStorage.setItem(OPEN_KEY, open ? "true" : "false");
    if (open && focusInput) requestAnimationFrame(() => input.focus());
  }

  const savedOpen = localStorage.getItem(OPEN_KEY);
  setOpen(savedOpen === null ? root.dataset.defaultOpen === "true" : savedOpen === "true", false);

  closeButton.addEventListener("click", () => setOpen(false, false));
  launcher.addEventListener("click", () => setOpen(true, true));

  copy.starters.forEach((question) => {
    const button = document.createElement("button");
    button.className = "global-ai-starter";
    button.type = "button";
    button.textContent = question;
    button.addEventListener("click", () => {
      starters.hidden = true;
      suggestionsButton.setAttribute("aria-expanded", "false");
      ask(question);
    });
    starters.appendChild(button);
  });

  suggestionsButton.addEventListener("click", () => {
    const expanded = starters.hidden;
    starters.hidden = !expanded;
    suggestionsButton.setAttribute("aria-expanded", String(expanded));
  });

  function resizeInput() {
    input.style.height = "auto";
    input.style.height = `${Math.min(input.scrollHeight, 96)}px`;
  }

  input.addEventListener("input", resizeInput);
  input.addEventListener("keydown", (event) => {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      form.requestSubmit();
    }
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !panel.hidden) setOpen(false, false);
  });

  async function ask(explicitQuestion) {
    const question = (explicitQuestion || input.value).trim();
    if (!question || sendButton.disabled) {
      if (!question) status.textContent = copy.enter;
      return;
    }

    input.value = "";
    resizeInput();
    status.textContent = copy.thinking;
    sendButton.disabled = true;

    const userMessage = { role: "user", text: question };
    messages.push(userMessage);
    renderMessage(userMessage);
    const pending = renderMessage({ role: "assistant", text: copy.thinking });
    scrollToLatest();

    try {
      const response = await fetch("/api/ai/ask", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ question, lang: isEnglish ? "en" : "zh" }),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      const answer = String(data.answer || "");
      pending.textContent = answer;
      messages.push({ role: "assistant", text: answer });
      persistMessages();
      status.textContent = "";
    } catch (error) {
      const message = `${copy.failed}: ${error.message}`;
      pending.textContent = message;
      pending.classList.add("error");
      messages.push({ role: "assistant", text: message, error: true });
      persistMessages();
      status.textContent = message;
    } finally {
      sendButton.disabled = false;
      scrollToLatest();
    }
  }

  form.addEventListener("submit", (event) => {
    event.preventDefault();
    ask();
  });

  if (messages.length) requestAnimationFrame(() => scrollToLatest("auto"));
})();
