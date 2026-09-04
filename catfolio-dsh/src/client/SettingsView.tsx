/**
 * Settings view (设置) — plugin configuration: Trading 212 credentials and
 * the data-source mode. Reads/writes `$DSH_HOME/catfolio.json` through the
 * plugin API; secrets are masked in the browser.
 */
import { useEffect, useState } from "react";
import { t } from "./copy.js";

type Row = Record<string, unknown>;

interface SettingsState {
  trading212: {
    apiKey?: string;
    apiSecret?: string;
    apiKey2?: string;
    apiSecret2?: string;
    accounts?: string;
  };
  dataSource: "auto" | "live" | "demo";
}

export function SettingsView() {
  const [settings, setSettings] = useState<SettingsState | null>(null);
  const [source, setSource] = useState<Row | null>(null);
  const [path, setPath] = useState("");
  const [draft, setDraft] = useState<SettingsState | null>(null);
  const [message, setMessage] = useState("");
  const [saving, setSaving] = useState(false);
  const [syncing, setSyncing] = useState(false);

  const load = async () => {
    try {
      const response = await fetch("/catfolio/api/settings", { headers: { Accept: "application/json" } });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = (await response.json()) as Row;
      setSettings((data.settings ?? {}) as SettingsState);
      setDraft((data.settings ?? {}) as SettingsState);
      setSource(data as Row);
      setPath(String(data.settings_path ?? ""));
    } catch (error) {
      setMessage(`设置加载失败：${error instanceof Error ? error.message : String(error)}`);
    }
  };

  useEffect(() => {
    load();
  }, []);

  const setField = (group: "trading212", field: string, value: string) => {
    setDraft((prev) => {
      if (!prev) return prev;
      return { ...prev, trading212: { ...prev.trading212, [field]: value } };
    });
  };

  const setMode = (mode: "auto" | "live" | "demo") => {
    setDraft((prev) => (prev ? { ...prev, dataSource: mode } : prev));
  };

  const save = async () => {
    if (!draft) return;
    setSaving(true);
    setMessage("保存中…");
    try {
      const response = await fetch("/catfolio/api/settings", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(draft),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = (await response.json()) as Row;
      setSettings((data.settings ?? {}) as SettingsState);
      setDraft((data.settings ?? {}) as SettingsState);
      setSource(data as Row);
      setMessage(`已保存 · 当前数据源：${String((data.source as string) ?? "")} · ${Number(data.holdings ?? 0)} 个持仓`);
    } catch (error) {
      setMessage(`保存失败：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setSaving(false);
    }
  };

  const sync = async () => {
    setSyncing(true);
    setMessage("正在同步 Trading 212…");
    try {
      const response = await fetch("/catfolio/api/refresh/trading212", { method: "POST" });
      const result = (await response.json()) as Row;
      if (!response.ok || !result.ok) {
        setMessage(String(result.error || result.message || `HTTP ${response.status}`));
        return;
      }
      const reloaded = (result.reloaded ?? {}) as Row;
      setMessage(`同步完成 · ${String(reloaded.source ?? "")} · ${Number(reloaded.holdings ?? 0)} 个持仓`);
      load();
    } catch (error) {
      setMessage(`同步失败：${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setSyncing(false);
    }
  };

  const hasKey = Boolean(settings?.trading212?.apiKey);
  const hasKey2 = Boolean(settings?.trading212?.apiKey2);

  return (
    <main className="catfolio-view">
      <div className="catfolio-settings">
        <header className="catfolio-page-head">
          <h1>设置</h1>
          <span className="catfolio-status" aria-live="polite">
            {source ? `数据源：${source.source === "live" ? "真实数据" : source.source === "live-unavailable" ? "真实数据（不可用）" : "演示数据"} · ${Number(source.holdings ?? 0)} 持仓` : t("loading")}
          </span>
        </header>

        {message && (
          <div className="catfolio-analytics-status is-visible" aria-live="polite">{message}</div>
        )}

        <section className="catfolio-settings-card">
          <h2>Trading 212</h2>
          <p className="catfolio-settings-note">
            {hasKey ? "已配置 API Key。" : "未配置 API Key。"}
            {path ? ` 配置文件：${path}` : ""}
          </p>

          <div className="catfolio-settings-field">
            <label htmlFor="cf-t212-key">API Key（主账户）</label>
            <input
              id="cf-t212-key"
              type="password"
              autoComplete="off"
              placeholder={hasKey ? "••••••••（已配置，留空保持不变）" : "输入 Trading 212 API Key"}
              value={draft?.trading212?.apiKey ?? ""}
              onChange={(event) => setField("trading212", "apiKey", event.target.value)}
            />
          </div>
          <div className="catfolio-settings-field">
            <label htmlFor="cf-t212-secret">API Secret（主账户，可选）</label>
            <input
              id="cf-t212-secret"
              type="password"
              autoComplete="off"
              placeholder={settings?.trading212?.apiSecret ? "••••••••（已配置，留空保持不变）" : "输入 Secret（Basic 认证）"}
              value={draft?.trading212?.apiSecret ?? ""}
              onChange={(event) => setField("trading212", "apiSecret", event.target.value)}
            />
          </div>
          <div className="catfolio-settings-field">
            <label htmlFor="cf-t212-key2">API Key 2（第二账户，可选）</label>
            <input
              id="cf-t212-key2"
              type="password"
              autoComplete="off"
              placeholder={hasKey2 ? "••••••••（已配置，留空保持不变）" : "输入第二账户 API Key"}
              value={draft?.trading212?.apiKey2 ?? ""}
              onChange={(event) => setField("trading212", "apiKey2", event.target.value)}
            />
          </div>
          <div className="catfolio-settings-field">
            <label htmlFor="cf-t212-secret2">API Secret 2（第二账户，可选）</label>
            <input
              id="cf-t212-secret2"
              type="password"
              autoComplete="off"
              placeholder={settings?.trading212?.apiSecret2 ? "••••••••（已配置，留空保持不变）" : "输入第二账户 Secret"}
              value={draft?.trading212?.apiSecret2 ?? ""}
              onChange={(event) => setField("trading212", "apiSecret2", event.target.value)}
            />
          </div>
        </section>

        <section className="catfolio-settings-card">
          <h2>数据源</h2>
          <div className="catfolio-settings-modes" role="group" aria-label="数据源模式">
            {([
              ["auto", "自动", "检测到本地真实快照时使用，否则回退演示数据"],
              ["live", "真实数据", "强制使用 outputs/portfolio_analysis_v2 快照"],
              ["demo", "演示数据", "始终使用内置演示数据"],
            ] as const).map(([mode, label, note]) => (
              <button
                key={mode}
                type="button"
                className={draft?.dataSource === mode ? "active" : ""}
                aria-pressed={draft?.dataSource === mode}
                onClick={() => setMode(mode)}
              >
                <strong>{label}</strong>
                <span>{note}</span>
              </button>
            ))}
          </div>
        </section>

        <div className="catfolio-settings-actions">
          <button className="catfolio-ai-button" type="button" disabled={saving} onClick={save}>
            <span>{saving ? "保存中…" : "保存设置"}</span>
          </button>
          <button className="catfolio-ai-button" type="button" disabled={syncing} onClick={sync}>
            <span>{syncing ? "同步中…" : "立即同步 Trading 212"}</span>
          </button>
        </div>
      </div>
    </main>
  );
}
