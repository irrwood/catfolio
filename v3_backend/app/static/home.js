  const refreshButton = document.getElementById("refreshButton");
  const marketRefreshButton = document.getElementById("marketRefreshButton");
  const fundamentalsRefreshButton = document.getElementById("fundamentalsRefreshButton");
  const refreshStatus = document.getElementById("refreshStatus");
  
  // Smart refresh: first click uses cache, second click forces
  function fmtAge(sec) { return sec == null ? "" : sec < 60 ? `${sec}秒前` : sec < 3600 ? `${Math.floor(sec/60)}分钟前` : `${Math.floor(sec/3600)}小时前`; }

  let _forceRefresh = false;
  async function smartRefresh(button, label, url) {
    button.disabled = true;
    const doFetch = async () => {
      const sep = url.includes('?') ? '&' : '?';
      const u = _forceRefresh ? `${url}${sep}force=true` : url;
      return await fetch(u, { method: "POST" });
    };
    refreshStatus.innerHTML = `<i class="fa-solid fa-spinner fa-spin"></i> ${label}...`;
    try {
      let resp = await doFetch();
      let data = await resp.json();
      if (data.refresh?.cached || data.market?.cached || data.fundamentals?.cached) {
        const age = data.refresh?.age_seconds || data.market?.age_seconds || data.fundamentals?.age_seconds;
        refreshStatus.className = "status";
        refreshStatus.innerHTML = `<i class="fa-solid fa-clock"></i> ${label}已缓存(${fmtAge(age)})。<a href="#" onclick="event.preventDefault();_forceRefresh=true;smartRefresh(${button.id},'${label}','${url}');return false" style="color:var(--accent);cursor:pointer;margin-left:8px;">强制刷新</a>`;
        button.disabled = false;
        return;
      }
      _forceRefresh = false;
      refreshStatus.className = "status positive";
      refreshStatus.innerHTML = `<i class="fa-solid fa-circle-check"></i> ${label}完成！`;
      setTimeout(() => location.reload(), 1200);
    } catch (error) {
      _forceRefresh = false;
      refreshStatus.className = "status negative";
      refreshStatus.innerHTML = `<i class="fa-solid fa-circle-xmark"></i> ${label}失败：${error.message}`;
      button.disabled = false;
    }
  }

  marketRefreshButton?.addEventListener("click", () => smartRefresh(marketRefreshButton, "行情刷新", "/api/refresh/market"));
  refreshButton?.addEventListener("click", () => smartRefresh(refreshButton, "T212同步", "/api/refresh/trading212"));
  fundamentalsRefreshButton?.addEventListener("click", () => smartRefresh(fundamentalsRefreshButton, "估值刷新", "/api/refresh/fundamentals"));

  // ── After-Hours Unusual Activity ──
  async function loadAfterHours() {
    const btn = document.querySelector("#afterHoursBtn");
    const status = document.querySelector("#afterHoursStatus");
    const result = document.querySelector("#afterHoursResult");
    const body = document.querySelector("#afterHoursBody");
    const quiet = document.querySelector("#afterHoursQuiet");
    const meta = document.querySelector("#afterHoursMeta");
    btn.disabled = true;
    btn.innerHTML = `<i class="fa-solid fa-spinner fa-spin"></i> 正在拉取 Massive 盘后数据...`;
    status.innerHTML = "";
    result.style.display = "none";
    try {
      const resp = await fetch("/api/refresh/after-hours", { method: "POST" });
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const json = await resp.json();
      const data = json.data || json;
      const rows = data.rows || [];
      const warnings = data.warnings || [];

      if (rows.length === 0) {
        quiet.style.display = "block";
        body.innerHTML = "";
      } else {
        quiet.style.display = "none";
        body.innerHTML = rows.map(r => {
          const cls = r.change_pct >= 0 ? "positive" : "negative";
          const sign = r.change_pct >= 0 ? "+" : "";
          return `<tr>
            <td><b>${r.ticker}</b></td>
            <td>${r.close?.toFixed(2) || "—"}</td>
            <td>${r.after_hours?.toFixed(2) || "—"}</td>
            <td class="${cls}">${sign}${r.change_pct?.toFixed(2)}%</td>
            <td>${r.volume?.toLocaleString() || "—"}</td>
          </tr>`;
        }).join("");
      }

      meta.textContent = `共检查 ${data.total_checked || rows.length} 只美股 · ${data.date || ""} · ${warnings.length ? warnings[0] : "Massive API"}`;
      btn.innerHTML = `<i class="fa-solid fa-arrows-rotate"></i> 刷新盘后数据`;
      status.innerHTML = "";
      result.style.display = "block";
    } catch(e) {
      status.innerHTML = `<span style="color:var(--negative)">拉取失败：${e.message} <button class="btn" onclick="loadAfterHours()" style="font-size:11px;padding:2px 8px;">重试</button></span>`;
      btn.innerHTML = `<i class="fa-solid fa-arrows-rotate"></i> 刷新盘后数据`;
    } finally {
      btn.disabled = false;
    }
  }
