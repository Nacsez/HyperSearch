import { useEffect, useMemo, useState } from "react";

import type {
  HistoryRecord,
  LlmSettings,
  ProviderDraftRequest,
  ProviderInfo,
  ProviderProfileUpdate,
  ReadinessResponse
} from "../../lib/api";

interface AdminPanelProps {
  providers: ProviderInfo[];
  providerModels: Record<string, string[]>;
  providerModelsLoading: Record<string, boolean>;
  pairingToken: string;
  lastMessage: string;
  readiness?: ReadinessResponse;
  llmSettings?: LlmSettings;
  history: HistoryRecord[];
  onPairingTokenChange: (value: string) => void;
  onLlmSettingsChange: (settings: { enabled: boolean; reason?: string | null }) => void;
  onTestProvider: (draft: ProviderDraftRequest) => void;
  onVerifyProvider: (draft: ProviderDraftRequest) => void;
  onDiscoverModels: (draft: ProviderDraftRequest) => Promise<string[]>;
  onSetDefaultProvider: (name: string) => void;
  onUpdateProvider: (name: string, profile: ProviderProfileUpdate) => void;
  onInvalidateCache: (namespace: string) => void;
  onRefreshHistory: () => void;
  onApplyRetention: (days: number) => void;
}

function defaultEndpoint(provider: ProviderInfo) {
  if (provider.name === "lmstudio") {
    return provider.base_url ?? "http://host.docker.internal:1234";
  }
  return provider.base_url ?? "";
}

function modelChoices(provider: ProviderInfo, discoveredModels: string[], currentModel: string) {
  const values = new Set(discoveredModels);
  if (provider.model) {
    values.add(provider.model);
  }
  if (currentModel) {
    values.add(currentModel);
  }
  return Array.from(values).sort((left, right) => left.localeCompare(right));
}

export function AdminPanel({
  providers,
  providerModels,
  providerModelsLoading,
  pairingToken,
  lastMessage,
  readiness,
  llmSettings,
  history,
  onPairingTokenChange,
  onLlmSettingsChange,
  onTestProvider,
  onVerifyProvider,
  onDiscoverModels,
  onSetDefaultProvider,
  onUpdateProvider,
  onInvalidateCache,
  onRefreshHistory,
  onApplyRetention
}: AdminPanelProps) {
  const readinessStatus = readiness?.status ?? "unknown";
  const readinessTone = readinessStatus === "ready" ? "ok" : readinessStatus === "degraded" ? "warning" : "muted";
  const llmCapability = readiness?.capabilities?.llm;
  const effectiveLlmEnabled = llmSettings?.enabled ?? llmCapability?.enabled ?? false;
  const confirmInvalidate = (namespace: string) => {
    if (window.confirm(`Invalidate the ${namespace} cache? Cached ${namespace} work will be recomputed on the next request.`)) {
      onInvalidateCache(namespace);
    }
  };
  const confirmRetention = () => {
    if (window.confirm("Apply 90 day history retention? Local history records older than 90 days will be deleted.")) {
      onApplyRetention(90);
    }
  };

  return (
    <div className="admin-stack">
      <div className={`ops-readiness ops-readiness--${readinessTone}`}>
        <span className="ops-readiness__dot" />
        <div>
          <strong>{readinessStatus === "ready" ? "Ready" : readinessStatus === "degraded" ? "Degraded" : "Readiness unknown"}</strong>
          <small>{readiness ? "Core checks loaded. Open provider settings for model details." : "Readiness has not been loaded yet."}</small>
        </div>
      </div>

      <section className="admin-action-grid" aria-label="Operations actions">
        <article className="admin-action-card">
          <div>
            <strong>LLM features</strong>
            <p>
              {effectiveLlmEnabled
                ? llmCapability?.ready
                  ? "Local synthesis is enabled and ready."
                  : "Local synthesis is enabled but the selected provider is not ready."
                : "Search-only mode is enabled. Search and source review remain available."}
            </p>
          </div>
          <label className="switch-row">
            <input
              type="checkbox"
              checked={effectiveLlmEnabled}
              onChange={(event) => onLlmSettingsChange({
                enabled: event.target.checked,
                reason: event.target.checked ? null : "Disabled from Operations"
              })}
            />
            <span>{effectiveLlmEnabled ? "LLM on" : "LLM off"}</span>
          </label>
        </article>
        <article className="admin-action-card">
          <div>
            <strong>Refresh local history</strong>
            <p>Reload the recent history list from the backend database.</p>
          </div>
          <button type="button" className="button button--ghost" onClick={onRefreshHistory}>Refresh history</button>
        </article>
        <article className="admin-action-card">
          <div>
            <strong>Invalidate search cache</strong>
            <p>Remove cached search responses so future searches ask SearXNG again.</p>
          </div>
          <button type="button" className="button button--ghost" onClick={() => confirmInvalidate("search")}>Invalidate search</button>
        </article>
        <article className="admin-action-card">
          <div>
            <strong>Invalidate extraction cache</strong>
            <p>Force fetched pages and extracted text to be collected again.</p>
          </div>
          <button type="button" className="button button--ghost" onClick={() => confirmInvalidate("extract")}>Invalidate extract</button>
        </article>
        <article className="admin-action-card">
          <div>
            <strong>Invalidate research cache</strong>
            <p>Clear cached synthesis results so research is generated again.</p>
          </div>
          <button type="button" className="button button--ghost" onClick={() => confirmInvalidate("research")}>Invalidate research</button>
        </article>
        <article className="admin-action-card">
          <div>
            <strong>Apply 90 day retention</strong>
            <p>Delete local history records older than 90 days.</p>
          </div>
          <button type="button" className="button button--ghost" onClick={confirmRetention}>Keep 90 days</button>
        </article>
      </section>

      {lastMessage ? <p className="admin-message">{lastMessage}</p> : null}

      <details className="admin-section" open>
        <summary>Local LLM providers</summary>
        <div className="provider-list">
          {providers.map((provider) => (
            <ProviderEditor
              key={provider.name}
              provider={provider}
              discoveredModels={providerModels[provider.name] ?? []}
              modelsLoading={Boolean(providerModelsLoading[provider.name])}
              onDiscoverModels={onDiscoverModels}
              onTestProvider={onTestProvider}
              onVerifyProvider={onVerifyProvider}
              onSetDefaultProvider={onSetDefaultProvider}
              onUpdateProvider={onUpdateProvider}
            />
          ))}
        </div>
      </details>

      <details className="admin-section">
        <summary>LAN browser pairing</summary>
        <div className="field">
          <label htmlFor="pairingToken">LAN Pairing Token</label>
          <input id="pairingToken" value={pairingToken} onChange={(event) => onPairingTokenChange(event.target.value)} placeholder="Only needed from a paired LAN browser" />
        </div>
      </details>

      <details className="admin-section">
        <summary>Local history preview</summary>
        <div className="history-panel">
          <div className="preset-list__header">
            <span>Local history</span>
            <span>{history.length}</span>
          </div>
          {history.length === 0 ? <p className="muted">No history records loaded.</p> : null}
          {history.slice(0, 8).map((item) => (
            <article key={item.history_id} className="history-row">
              <strong>{item.kind}</strong>
              <span>{item.query}</span>
              <small>{new Date(item.created_at).toLocaleString()}</small>
            </article>
          ))}
        </div>
      </details>
    </div>
  );
}

function ProviderEditor({
  provider,
  discoveredModels,
  modelsLoading,
  onDiscoverModels,
  onTestProvider,
  onVerifyProvider,
  onSetDefaultProvider,
  onUpdateProvider
}: {
  provider: ProviderInfo;
  discoveredModels: string[];
  modelsLoading: boolean;
  onDiscoverModels: (draft: ProviderDraftRequest) => Promise<string[]>;
  onTestProvider: (draft: ProviderDraftRequest) => void;
  onVerifyProvider: (draft: ProviderDraftRequest) => void;
  onSetDefaultProvider: (name: string) => void;
  onUpdateProvider: (name: string, profile: ProviderProfileUpdate) => void;
}) {
  const [displayName, setDisplayName] = useState(provider.display_name ?? provider.name);
  const [baseUrl, setBaseUrl] = useState(defaultEndpoint(provider));
  const [model, setModel] = useState(provider.model ?? "");
  const [enabled, setEnabled] = useState(provider.enabled);
  const [makeDefault, setMakeDefault] = useState(provider.is_default);
  const choices = useMemo(() => modelChoices(provider, discoveredModels, model), [provider, discoveredModels, model]);

  useEffect(() => {
    setDisplayName(provider.display_name ?? provider.name);
    setBaseUrl(defaultEndpoint(provider));
    setModel(provider.model ?? "");
    setEnabled(provider.enabled);
    setMakeDefault(provider.is_default);
  }, [provider]);

  const saveProfile = () => {
    onUpdateProvider(provider.name, {
      display_name: displayName.trim() || provider.name,
      provider_type: "openai-compatible",
      base_url: baseUrl.trim() || null,
      model: model.trim() || null,
      enabled,
      is_default: makeDefault
    });
  };

  const draftPayload = (): ProviderDraftRequest => ({
    name: provider.name,
    provider_type: "openai-compatible",
    base_url: baseUrl.trim() || null,
    model: model.trim() || null,
    enabled
  });

  const discoverModels = async () => {
    const models = await onDiscoverModels(draftPayload());
    if (!model && models[0]) {
      setModel(models[0]);
    }
  };

  return (
    <article className="provider-card">
      <div className="provider-card__body">
        <div className="provider-card__headline">
          <strong>{provider.display_name ?? provider.name}</strong>
          {provider.is_default ? <span className="default-badge">Default</span> : null}
          <span className={`status-dot ${provider.healthy ? "status-dot--ok" : "status-dot--warn"}`}>
            {provider.healthy == null ? "unknown" : provider.healthy ? "healthy" : "down"}
          </span>
        </div>

        <div className="provider-form-grid">
          <div className="field">
            <label htmlFor={`${provider.name}-display`}>Display name</label>
            <input id={`${provider.name}-display`} value={displayName} onChange={(event) => setDisplayName(event.target.value)} />
          </div>
          <div className="field">
            <label htmlFor={`${provider.name}-endpoint`}>Endpoint</label>
            <input id={`${provider.name}-endpoint`} value={baseUrl} onChange={(event) => setBaseUrl(event.target.value)} placeholder="http://host.docker.internal:1234" />
          </div>
          <div className="field">
            <label htmlFor={`${provider.name}-model`}>Preferred model</label>
            {choices.length > 0 ? (
              <select id={`${provider.name}-model`} value={model} onChange={(event) => setModel(event.target.value)}>
                <option value="">Select a loaded model</option>
                {choices.map((choice) => (
                  <option key={choice} value={choice}>{choice}</option>
                ))}
              </select>
            ) : (
              <input id={`${provider.name}-model`} value={model} onChange={(event) => setModel(event.target.value)} placeholder="Discover models or type an exact model id" />
            )}
          </div>
        </div>

        <div className="provider-flags">
          <label>
            <input type="checkbox" checked={enabled} onChange={(event) => setEnabled(event.target.checked)} />
            Enabled
          </label>
          <label>
            <input type="checkbox" checked={makeDefault} onChange={(event) => setMakeDefault(event.target.checked)} />
            Default for research
          </label>
        </div>

        <small>{provider.base_url ?? "no base URL configured"}</small>
        {provider.detail ? <p className="provider-card__detail">{provider.detail}</p> : null}
      </div>
      <div className="provider-card__actions">
        <button type="button" className="button button--ghost" onClick={saveProfile}>
          Save profile
        </button>
        <button type="button" className="button button--ghost" onClick={discoverModels} disabled={modelsLoading}>
          {modelsLoading ? "Discovering..." : "Discover models"}
        </button>
        <button type="button" className="button button--ghost" onClick={() => onTestProvider(draftPayload())}>
          Test
        </button>
        <button type="button" className="button button--ghost" onClick={() => onVerifyProvider(draftPayload())}>
          Verify model
        </button>
        {!provider.is_default ? (
          <button type="button" className="button button--ghost" onClick={() => onSetDefaultProvider(provider.name)}>
            Set default
          </button>
        ) : null}
      </div>
    </article>
  );
}
