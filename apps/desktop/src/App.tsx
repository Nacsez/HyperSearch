import { useEffect, useMemo, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import logoUrl from "./assets/hypersearch-logo.png";

interface PrerequisiteStatus {
  docker_installed: boolean;
  docker_detail: string;
  lmstudio_detected: boolean;
  lmstudio_detail: string;
}

interface BackendStatus {
  ok: boolean;
  detail: string;
  app_url: string;
  lan_enabled: boolean;
}

interface ExportSettings {
  export_dir: string;
}

interface SessionTab {
  id: string;
  title: string;
  url: string;
  state: "loading" | "ready";
}

interface ActionEntry {
  id: string;
  createdAt: string;
  text: string;
}

type AppView = "deploy" | "sessions";
type OutputView = "friendly" | "logs";
type BackendAction = "up" | "down" | "restart" | "logs" | "browser" | "lan" | "refresh" | "diagnostics";
const SESSION_COUNTER_KEY = "hypersearch_desktop_session_counter";
const DESKTOP_ZOOM_KEY = "hypersearch_desktop_ui_zoom";

function asMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function displayUrl(value: string) {
  return value.split("?")[0];
}

function sessionUrl(baseUrl: string, session: Pick<SessionTab, "id" | "title">) {
  const url = new URL(baseUrl);
  url.searchParams.set("hypersearch_session_id", session.id);
  url.searchParams.set("hypersearch_session_title", session.title);
  return url.toString();
}

function parseDesktopMessage(input: unknown): { type?: string; payload?: { filename?: string; xml?: string; id?: string; title?: string } } | null {
  if (typeof input === "string") {
    try {
      const parsed = JSON.parse(input) as unknown;
      return parseDesktopMessage(parsed);
    } catch {
      return null;
    }
  }
  if (!input || typeof input !== "object") {
    return null;
  }
  return input as { type?: string; payload?: { filename?: string; xml?: string; id?: string; title?: string } };
}

function nextDesktopSessionNumber() {
  const current = Number(window.localStorage.getItem(SESSION_COUNTER_KEY) ?? "0");
  const next = Number.isFinite(current) ? current + 1 : 1;
  window.localStorage.setItem(SESSION_COUNTER_KEY, String(next));
  return next;
}

export function App() {
  const [view, setView] = useState<AppView>("deploy");
  const [theme, setTheme] = useState<"light" | "dark">(
    () => (window.localStorage.getItem("hypersearch_desktop_theme") as "light" | "dark" | null) ?? "light"
  );
  const [desktopZoom, setDesktopZoom] = useState(() => {
    const stored = Number(window.localStorage.getItem(DESKTOP_ZOOM_KEY) ?? "1");
    return Number.isFinite(stored) ? Math.min(2, Math.max(0.5, stored)) : 1;
  });
  const [prerequisites, setPrerequisites] = useState<PrerequisiteStatus | null>(null);
  const [status, setStatus] = useState<BackendStatus | null>(null);
  const [exportDir, setExportDir] = useState("");
  const [exportDirDraft, setExportDirDraft] = useState("");
  const [logs, setLogs] = useState("");
  const [outputView, setOutputView] = useState<OutputView>("friendly");
  const [actionHistory, setActionHistory] = useState<ActionEntry[]>([]);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [busyAction, setBusyAction] = useState<BackendAction | null>(null);
  const [message, setMessage] = useState("");
  const [sessions, setSessions] = useState<SessionTab[]>([]);
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null);

  const refresh = async (showBusy = false) => {
    if (showBusy) {
      setBusyAction("refresh");
    }
    try {
      const [nextPrerequisites, nextStatus] = await Promise.all([
        invoke<PrerequisiteStatus>("check_prerequisites"),
        invoke<BackendStatus>("backend_status")
      ]);
      setPrerequisites(nextPrerequisites);
      setStatus(nextStatus);
      return nextStatus;
    } finally {
      if (showBusy) {
        setBusyAction(null);
      }
    }
  };

  const recordAction = (text: string) => {
    setMessage(text);
    setActionHistory((current) => [
      {
        id: crypto.randomUUID(),
        createdAt: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" }),
        text
      },
      ...current
    ].slice(0, 80));
  };

  const runAction = async (action: "up" | "down" | "restart") => {
    setBusyAction(action);
    recordAction(action === "up" ? "Starting the local Docker stack..." : action === "restart" ? "Restarting the stack..." : "Stopping HyperSearch services...");
    try {
      const output = await invoke<string>("backend_action", { action });
      recordAction(output || `${action} completed.`);
      const nextStatus = await refresh();
      if (action === "down") {
        setSessions([]);
        setActiveSessionId(null);
        setView("deploy");
      } else if (action === "up" && nextStatus?.ok) {
        setView("sessions");
      }
    } catch (error) {
      recordAction(asMessage(error));
    } finally {
      setBusyAction(null);
    }
  };

  const loadLogs = async () => {
    setBusyAction("logs");
    try {
      setLogs(await invoke<string>("backend_logs"));
      recordAction("Backend logs loaded.");
    } catch (error) {
      setLogs(asMessage(error));
      recordAction(asMessage(error));
    } finally {
      setBusyAction(null);
    }
  };

  const showOutputView = (nextView: OutputView) => {
    setOutputView(nextView);
    if (nextView === "logs" && !logs) {
      void loadLogs();
    }
  };

  const openSession = () => {
    if (!status?.ok || !status.app_url) {
      recordAction("Start the stack before opening a session.");
      setView("deploy");
      return;
    }
    const nextSession: SessionTab = {
      id: crypto.randomUUID(),
      title: `Session ${nextDesktopSessionNumber()}`,
      url: "",
      state: "loading"
    };
    nextSession.url = sessionUrl(status.app_url, nextSession);
    setSessions((current) => [...current, nextSession].slice(-6));
    setActiveSessionId(nextSession.id);
    recordAction(`Opening ${nextSession.title}...`);
    setView("sessions");
  };

  const openSavedSession = (id: string, title: string) => {
    if (!status?.ok || !status.app_url) {
      recordAction("Start the stack before opening a saved session.");
      setView("deploy");
      return;
    }
    const trimmedTitle = title.trim() || "Saved Session";
    const existing = sessions.find((session) => session.id === id);
    if (existing) {
      setSessions((current) => current.map((session) => (
        session.id === id ? { ...session, title: trimmedTitle } : session
      )));
      setActiveSessionId(id);
      setView("sessions");
      recordAction(`Loaded ${trimmedTitle}.`);
      return;
    }
    const nextSession: SessionTab = {
      id,
      title: trimmedTitle,
      url: "",
      state: "loading"
    };
    nextSession.url = sessionUrl(status.app_url, nextSession);
    setSessions((current) => [...current, nextSession].slice(-6));
    setActiveSessionId(nextSession.id);
    setView("sessions");
    recordAction(`Opening saved session ${trimmedTitle}...`);
  };

  const openHelpSession = async () => {
    if (!status?.ok || !status.app_url) {
      try {
        await invoke("open_local_help");
        recordAction("Opened local Help from the desktop application.");
      } catch (error) {
        recordAction(asMessage(error));
      }
      return;
    }
    const helpUrl = new URL(status.app_url);
    helpUrl.pathname = "/help/index.html";
    helpUrl.search = "";
    const helpSession: SessionTab = {
      id: "hypersearch-help",
      title: "Help",
      url: helpUrl.toString(),
      state: "loading"
    };
    setSessions((current) => {
      if (current.some((session) => session.id === helpSession.id)) {
        return current;
      }
      return [...current, helpSession].slice(-6);
    });
    setActiveSessionId(helpSession.id);
    recordAction("Opening Help...");
    setView("sessions");
  };

  const closeSession = (id: string) => {
    setSessions((current) => {
      const next = current.filter((session) => session.id !== id);
      if (activeSessionId === id) {
        setActiveSessionId(next[next.length - 1]?.id ?? null);
      }
      return next;
    });
  };

  const markSessionReady = (id: string) => {
    setSessions((current) => current.map((session) => (
      session.id === id ? { ...session, state: "ready" } : session
    )));
    recordAction("Session ready.");
  };

  const openBrowser = async () => {
    setBusyAction("browser");
    try {
      await invoke("open_console");
      recordAction("Opened HyperSearch in the default browser.");
    } catch (error) {
      recordAction(asMessage(error));
    } finally {
      setBusyAction(null);
    }
  };

  const toggleLan = async (enabled: boolean) => {
    setBusyAction("lan");
    try {
      const token = await invoke<string>("set_lan_mode", { enabled });
      recordAction(enabled ? `LAN mode enabled. Pairing token: ${token}` : "LAN mode disabled.");
      await refresh();
    } catch (error) {
      recordAction(asMessage(error));
    } finally {
      setBusyAction(null);
    }
  };

  const saveExportDir = async () => {
    setBusyAction("refresh");
    try {
      const settings = await invoke<ExportSettings>("set_export_dir", { path: exportDirDraft });
      setExportDir(settings.export_dir);
      setExportDirDraft(settings.export_dir);
      recordAction(`Export folder saved: ${settings.export_dir}`);
    } catch (error) {
      recordAction(asMessage(error));
    } finally {
      setBusyAction(null);
    }
  };

  const exportDiagnostics = async () => {
    setBusyAction("diagnostics");
    recordAction("Collecting diagnostic logs and runtime status...");
    try {
      const path = await invoke<string>("export_diagnostics");
      recordAction(`Diagnostics exported: ${path}`);
    } catch (error) {
      recordAction(asMessage(error));
    } finally {
      setBusyAction(null);
    }
  };

  useEffect(() => {
    refresh().catch((error) => recordAction(asMessage(error)));
    invoke<ExportSettings>("get_export_settings")
      .then((settings) => {
        setExportDir(settings.export_dir);
        setExportDirDraft(settings.export_dir);
      })
      .catch((error) => recordAction(asMessage(error)));
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    window.localStorage.setItem("hypersearch_desktop_theme", theme);
  }, [theme]);

  useEffect(() => {
    const clamped = Math.min(2, Math.max(0.5, Number.isFinite(desktopZoom) ? desktopZoom : 1));
    document.documentElement.style.setProperty("--desktop-ui-scale", String(clamped));
    window.localStorage.setItem(DESKTOP_ZOOM_KEY, String(clamped));
  }, [desktopZoom]);

  useEffect(() => {
    const onMessage = async (event: MessageEvent) => {
      const data = parseDesktopMessage(event.data);
      if (!data) {
        return;
      }
      if (data.type === "hypersearch.openHelp") {
        void openHelpSession();
        const source = event.source as WindowProxy | null;
        source?.postMessage({ type: "hypersearch.openHelp.result", ok: true }, event.origin === "null" ? "*" : event.origin || "*");
        return;
      }
      if (data.type === "hypersearch.sessionTitle" && data.payload?.id && data.payload.title) {
        setSessions((current) => current.map((session) => (
          session.id === data.payload?.id ? { ...session, title: data.payload.title?.trim() || session.title } : session
        )));
        return;
      }
      if (data.type === "hypersearch.openSavedSession" && data.payload?.id && data.payload.title) {
        openSavedSession(data.payload.id, data.payload.title);
        return;
      }
      if (data.type !== "hypersearch.exportSession" || !data.payload?.filename || !data.payload?.xml) {
        return;
      }
      const source = event.source as WindowProxy | null;
      const reply = (body: Record<string, unknown>) => {
        source?.postMessage({ type: "hypersearch.exportSession.result", ...body }, event.origin === "null" ? "*" : event.origin || "*");
      };
      recordAction("Exporting session XML...");
      try {
        const path = await invoke<string>("export_session_xml", { payload: data.payload });
        recordAction(`Exported session XML: ${path}`);
        reply({ ok: true, path, filename: data.payload.filename });
      } catch (error) {
        const errorMessage = asMessage(error);
        recordAction(errorMessage);
        reply({ ok: false, error: errorMessage, filename: data.payload.filename });
      }
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, [sessions, status?.app_url, status?.ok]);

  const busy = busyAction != null;
  const backendState = status?.ok ? "Running" : busy ? "Working" : "Stopped";
  const backendTone = status?.ok ? "status-pill--ok" : busy ? "status-pill--busy" : "status-pill--stopped";
  const activeSession = sessions.find((session) => session.id === activeSessionId) ?? sessions[sessions.length - 1] ?? null;
  const safeAppUrl = status?.app_url ? displayUrl(status.app_url) : "";
  const statusText = useMemo(() => {
    if (busyAction === "up") {
      return "Starting Docker services and waiting for startup confirmation";
    }
    if (busyAction === "restart") {
      return "Restarting local services";
    }
    if (busyAction === "down") {
      return "Stopping HyperSearch services";
    }
    if (busyAction === "logs") {
      return "Loading backend logs";
    }
    if (activeSession?.state === "loading") {
      return `${activeSession.title} is loading`;
    }
    return status?.ok ? `Ready at ${safeAppUrl}` : "Stack stopped";
  }, [activeSession, busyAction, safeAppUrl, status?.ok]);

  return (
    <main className={`desktop-shell desktop-shell--${view}`}>
      <header className="app-topbar">
        <button type="button" className="brand-button" onClick={() => setView("deploy")} aria-label="HyperSearch status">
          <img className="brand-logo" src={logoUrl} alt="" />
          <span>HyperSearch</span>
        </button>
        <nav className="view-toggle" aria-label="Launcher views">
          <button type="button" className={view === "deploy" ? "view-toggle__button view-toggle__button--active" : "view-toggle__button"} onClick={() => setView("deploy")}>
            <span className="view-icon view-icon--deploy" />
            Deploy
          </button>
          <button type="button" className={view === "sessions" ? "view-toggle__button view-toggle__button--active" : "view-toggle__button"} onClick={() => setView("sessions")}>
            <span className="view-icon view-icon--sessions" />
            Sessions
            {sessions.length ? <span className="view-count">{sessions.length}</span> : null}
          </button>
        </nav>
        <div className="topbar-actions">
          <span className={`status-pill ${backendTone}`}>{backendState}</span>
          <button type="button" className="icon-button" onClick={() => void openHelpSession()}>Help</button>
          <button type="button" className="icon-button" onClick={() => setSettingsOpen(true)}>Settings</button>
          <button type="button" className="button button--primary launch-button" onClick={() => status?.ok ? openSession() : runAction("up")} disabled={busyAction === "up" || busyAction === "restart"}>
            {status?.ok ? "New Session" : busyAction === "up" ? "Starting..." : "Start"}
          </button>
        </div>
      </header>

      {view === "deploy" ? (
        <DeployView
          prerequisites={prerequisites}
          status={status}
          safeAppUrl={safeAppUrl}
          logs={logs}
          busyAction={busyAction}
          onStart={() => runAction("up")}
          onRestart={() => runAction("restart")}
          onStop={() => runAction("down")}
          onOpenSession={openSession}
          onOpenBrowser={openBrowser}
          onLoadLogs={() => {
            setOutputView("logs");
            void loadLogs();
          }}
          outputView={outputView}
          onOutputViewChange={showOutputView}
          onToggleLan={() => toggleLan(!status?.lan_enabled)}
          onRefresh={() => {
            setActionHistory([]);
            setMessage("");
            refresh(true).catch((error) => recordAction(asMessage(error)));
          }}
          actionHistory={actionHistory}
        />
      ) : (
        <SessionsView
          sessions={sessions}
          activeSession={activeSession}
          canOpen={Boolean(status?.ok)}
          safeAppUrl={safeAppUrl}
          onOpenSession={openSession}
          onSetActive={setActiveSessionId}
          onCloseSession={closeSession}
          onFrameReady={markSessionReady}
        />
      )}

      <footer className="desktop-statusbar">
        <span className={busy || activeSession?.state === "loading" ? "status-dot-inline status-dot-inline--busy" : "status-dot-inline"} />
        <strong>{statusText}</strong>
        {message ? <span>{message.split("\n")[0]}</span> : null}
      </footer>

      <AppSettingsDrawer
        open={settingsOpen}
        theme={theme}
        desktopZoom={desktopZoom}
        exportDir={exportDir}
        exportDirDraft={exportDirDraft}
        prerequisites={prerequisites}
        safeAppUrl={safeAppUrl}
        onClose={() => setSettingsOpen(false)}
        onThemeChange={setTheme}
        onDesktopZoomChange={setDesktopZoom}
        onExportDirChange={setExportDirDraft}
        onSaveExportDir={saveExportDir}
        onExportDiagnostics={exportDiagnostics}
      />
    </main>
  );
}

function DeployView({
  prerequisites,
  status,
  safeAppUrl,
  logs,
  busyAction,
  onStart,
  onRestart,
  onStop,
  onOpenSession,
  onOpenBrowser,
  onLoadLogs,
  outputView,
  onOutputViewChange,
  onToggleLan,
  onRefresh,
  actionHistory
}: {
  prerequisites: PrerequisiteStatus | null;
  status: BackendStatus | null;
  safeAppUrl: string;
  logs: string;
  busyAction: BackendAction | null;
  onStart: () => void;
  onRestart: () => void;
  onStop: () => void;
  onOpenSession: () => void;
  onOpenBrowser: () => void;
  onLoadLogs: () => void;
  outputView: OutputView;
  onOutputViewChange: (view: OutputView) => void;
  onToggleLan: () => void;
  onRefresh: () => void;
  actionHistory: ActionEntry[];
}) {
  return (
    <section className="deploy-page">
      <div className="deploy-hero">
        <div className="deploy-hero__title">
          <h1>Deploy HyperSearch</h1>
        </div>
        <p className="deploy-hint">Press Start to load the HyperSearch stack. Enable LAN only for use on your network.</p>
        <div className="deploy-actions">
          <button type="button" className="button button--primary launch-button" onClick={status?.ok ? onOpenSession : onStart} disabled={busyAction === "up"}>
            {status?.ok ? "Open Session" : busyAction === "up" ? "Starting..." : "Start Stack"}
          </button>
          <button type="button" className="button" onClick={onOpenBrowser} disabled={!status?.ok || busyAction === "browser"}>Browser</button>
        </div>
      </div>

      <section className="control-band">
        <button type="button" className="button button--primary launch-button deploy-action-button" onClick={onStart} disabled={busyAction === "up"}>Start</button>
        <button type="button" className="button deploy-action-button" onClick={onRestart} disabled={busyAction === "restart"}>Restart</button>
        <button type="button" className="button deploy-action-button" onClick={onStop} disabled={busyAction === "down"}>Stop</button>
        <button type="button" className="button deploy-action-button" onClick={onLoadLogs} disabled={busyAction === "logs"}>Logs</button>
        <button type="button" className="button deploy-action-button" onClick={onToggleLan} disabled={busyAction === "lan"}>
          {status?.lan_enabled ? "Disable LAN" : "Enable LAN"}
        </button>
        <button type="button" className="button deploy-action-button" onClick={onRefresh} disabled={busyAction === "refresh"}>Refresh</button>
      </section>

      <section className="deploy-dashboard">
        <article className="output-panel">
          <div className="output-panel__header">
            <div className="panel-heading">
              <span>{outputView === "friendly" ? "Recent actions" : "Backend logs"}</span>
              <strong>{outputView === "friendly" ? (actionHistory.length ? `${actionHistory.length} actions` : "Ready") : (logs ? "Loaded" : "Not loaded")}</strong>
            </div>
            <div className="panel-toggle" aria-label="Output mode">
              <button type="button" className={outputView === "friendly" ? "panel-toggle__button panel-toggle__button--active" : "panel-toggle__button"} onClick={() => onOutputViewChange("friendly")}>
                Output
              </button>
              <button type="button" className={outputView === "logs" ? "panel-toggle__button panel-toggle__button--active" : "panel-toggle__button"} onClick={() => onOutputViewChange("logs")}>
                Logs
              </button>
            </div>
          </div>
          {outputView === "friendly" ? (
            <div className="action-feed" role="log" aria-live="polite">
              {actionHistory.length ? actionHistory.map((entry, index) => (
                <article key={entry.id} className={index === 0 ? "action-feed__item action-feed__item--latest" : "action-feed__item"}>
                  <span>{entry.createdAt}</span>
                  <p>{entry.text}</p>
                </article>
              )) : (
                <p className="action-feed__empty">Start, stop, LAN, export, and session events will appear here.</p>
              )}
            </div>
          ) : (
            <pre>{logs || "Loading logs will show Docker service output here."}</pre>
          )}
        </article>

        <aside className="status-rail" aria-label="System status">
          <StatusCard
            label="Docker Desktop"
            value={prerequisites?.docker_installed ? "Installed" : "Needs setup"}
            tone={prerequisites?.docker_installed ? "ok" : "warn"}
            detail={prerequisites?.docker_detail ?? "Checking Docker Desktop and engine access."}
          />
          <StatusCard
            label="LM Studio"
            value={prerequisites?.lmstudio_detected ? "Detected" : "Optional"}
            tone={prerequisites?.lmstudio_detected ? "ok" : "muted"}
            detail={prerequisites?.lmstudio_detail ?? "Required only for research synthesis."}
          />
          <StatusCard
            label="Backend Stack"
            value={status?.ok ? "Running" : "Stopped"}
            tone={status?.ok ? "ok" : "warn"}
            detail={status?.ok ? `Console: ${safeAppUrl}` : "Press Start to launch API, UI, Caddy, Valkey, and SearXNG."}
          />
          <StatusCard
            label="LAN Access"
            value={status?.lan_enabled ? "Paired mode" : "Local only"}
            tone={status?.lan_enabled ? "warn" : "ok"}
            detail={status?.lan_enabled ? "App sessions pair automatically. Other computers still need the browser pairing token." : "Only this computer can access HyperSearch."}
          />
        </aside>
      </section>
    </section>
  );
}

function AppSettingsDrawer({
  open,
  theme,
  desktopZoom,
  exportDir,
  exportDirDraft,
  prerequisites,
  safeAppUrl,
  onClose,
  onThemeChange,
  onDesktopZoomChange,
  onExportDirChange,
  onSaveExportDir,
  onExportDiagnostics
}: {
  open: boolean;
  theme: "light" | "dark";
  desktopZoom: number;
  exportDir: string;
  exportDirDraft: string;
  prerequisites: PrerequisiteStatus | null;
  safeAppUrl: string;
  onClose: () => void;
  onThemeChange: (theme: "light" | "dark") => void;
  onDesktopZoomChange: (zoom: number) => void;
  onExportDirChange: (value: string) => void;
  onSaveExportDir: () => void;
  onExportDiagnostics: () => void;
}) {
  return (
    <div className={open ? "settings-layer settings-layer--open" : "settings-layer"} aria-hidden={!open}>
      <button type="button" className="settings-backdrop" onClick={onClose} aria-label="Close settings" tabIndex={open ? 0 : -1} />
      <aside className="settings-drawer" aria-label="Application settings">
        <header className="settings-drawer__header">
          <div>
            <span>Application</span>
            <strong>Settings</strong>
          </div>
          <button type="button" className="icon-button" onClick={onClose}>Close</button>
        </header>

        <section className="settings-section">
          <div className="settings-section__heading">
            <span>Appearance</span>
            <strong>Theme</strong>
          </div>
          <div className="settings-segmented" role="group" aria-label="Application theme">
            <button type="button" className={theme === "light" ? "settings-segmented__button settings-segmented__button--active" : "settings-segmented__button"} onClick={() => onThemeChange("light")}>
              Light
            </button>
            <button type="button" className={theme === "dark" ? "settings-segmented__button settings-segmented__button--active" : "settings-segmented__button"} onClick={() => onThemeChange("dark")}>
              Dark
            </button>
          </div>
          <label className="settings-field settings-field--range">
            <span>Launcher UI size</span>
            <div className="settings-range-row">
              <small>50%</small>
              <input
                type="range"
                min={50}
                max={200}
                step={5}
                value={Math.round(desktopZoom * 100)}
                onChange={(event) => onDesktopZoomChange(Number(event.target.value) / 100)}
              />
              <small>200%</small>
            </div>
            <strong>{Math.round(desktopZoom * 100)}%</strong>
          </label>
        </section>

        <section className="settings-section">
          <div className="settings-section__heading">
            <span>Session export</span>
            <strong>XML folder</strong>
          </div>
          <label className="settings-field">
            <span>Export location</span>
            <input value={exportDirDraft} onChange={(event) => onExportDirChange(event.target.value)} placeholder="C:\\Users\\Seeker\\Documents\\HyperSearch Exports" />
          </label>
          <button type="button" className="button button--primary settings-save" onClick={onSaveExportDir}>Save Folder</button>
          <p className="settings-note">Current folder: {exportDir || "Not configured"}</p>
        </section>

        <section className="settings-section">
          <div className="settings-section__heading">
            <span>Local tools</span>
            <strong>Detected paths</strong>
          </div>
          <dl className="settings-list">
            <div>
              <dt>Docker</dt>
              <dd>{prerequisites?.docker_detail ?? "Checking Docker Desktop and engine access."}</dd>
            </div>
            <div>
              <dt>LM Studio</dt>
              <dd>{prerequisites?.lmstudio_detail ?? "Required only for research synthesis."}</dd>
            </div>
            <div>
              <dt>Console</dt>
              <dd>{safeAppUrl || "Stack stopped"}</dd>
            </div>
          </dl>
        </section>

        <section className="settings-section">
          <div className="settings-section__heading">
            <span>Support</span>
            <strong>Diagnostics</strong>
          </div>
          <p className="settings-note">Export installer logs, launcher logs, Docker status, Compose status, and redacted settings for beta issue reports.</p>
          <button type="button" className="button settings-save" onClick={onExportDiagnostics}>Export Diagnostics</button>
        </section>
      </aside>
    </div>
  );
}

function SessionsView({
  sessions,
  activeSession,
  canOpen,
  safeAppUrl,
  onOpenSession,
  onSetActive,
  onCloseSession,
  onFrameReady
}: {
  sessions: SessionTab[];
  activeSession: SessionTab | null;
  canOpen: boolean;
  safeAppUrl: string;
  onOpenSession: () => void;
  onSetActive: (id: string) => void;
  onCloseSession: (id: string) => void;
  onFrameReady: (id: string) => void;
}) {
  return (
    <section className="sessions-page">
      <div className="sessions-toolbar">
        <div>
          <span>Workspace</span>
          <strong>{activeSession ? activeSession.title : "No session open"}</strong>
        </div>
        <button type="button" className="button button--primary launch-button" onClick={onOpenSession} disabled={!canOpen}>New Session</button>
      </div>

      {sessions.length > 0 ? (
        <div className="session-tabs" role="tablist" aria-label="HyperSearch sessions">
          {sessions.map((session) => (
            <div key={session.id} className={activeSession?.id === session.id ? "session-tab session-tab--active" : "session-tab"}>
              <button type="button" onClick={() => onSetActive(session.id)}>
                <span className={session.state === "loading" ? "session-state session-state--loading" : "session-state"} />
                {session.title}
              </button>
              <button type="button" className="session-tab__close" onClick={() => onCloseSession(session.id)} aria-label={`Close ${session.title}`}>x</button>
            </div>
          ))}
        </div>
      ) : null}

      <div className="session-frame-shell">
        {sessions.length > 0 ? (
          sessions.map((session) => (
            <iframe
              key={session.id}
              className={activeSession?.id === session.id ? "session-frame session-frame--active" : "session-frame"}
              title={session.title}
              src={session.url}
              onLoad={() => onFrameReady(session.id)}
            />
          ))
        ) : (
          <div className="session-empty">
            <strong>{canOpen ? "Open a session to begin." : "Start the stack first."}</strong>
            <p>{canOpen ? `Sessions open at ${safeAppUrl} and stay alive while you switch tabs.` : "The deploy tab starts Docker and confirms service readiness."}</p>
          </div>
        )}
      </div>
    </section>
  );
}

function StatusCard({
  label,
  value,
  detail,
  tone
}: {
  label: string;
  value: string;
  detail: string;
  tone: "ok" | "warn" | "muted";
}) {
  return (
    <article className="status-card">
      <div>
        <span>{label}</span>
        <strong>{value}</strong>
      </div>
      <p className={`detail detail--${tone}`}>{detail}</p>
    </article>
  );
}
