export type CachePolicy = "use" | "bypass" | "refresh" | "only-if-cached";

export interface SearchRequest {
  query: string;
  engines?: string[] | null;
  categories?: string[] | null;
  language?: string | null;
  time_range?: string | null;
  page: number;
  results_per_page: number;
  max_pages: number;
  target_result_count?: number | null;
  safe_search: number;
  dedupe: boolean;
  fetch_pages: boolean;
  extract_text: boolean;
  summarize: boolean;
  streaming: boolean;
  timeout_ms?: number | null;
  cache_policy: CachePolicy;
}

export interface SearchResult {
  title: string;
  url: string;
  engine?: string | null;
  score?: number | null;
  snippet?: string | null;
  content?: string | null;
  published_date?: string | null;
  fetched: boolean;
  extracted: boolean;
  metadata: Record<string, unknown>;
}

export interface SearchResponse {
  request_id: string;
  query: string;
  page: number;
  result_count: number;
  results: SearchResult[];
  summary?: string | null;
  cache: Record<string, unknown>;
  debug: Record<string, unknown>;
}

export interface ResearchRequest {
  query: string;
  engines?: string[] | null;
  categories?: string[] | null;
  language?: string | null;
  time_range?: string | null;
  page: number;
  results_per_page: number;
  max_pages: number;
  target_result_count?: number | null;
  safe_search: number;
  top_n: number;
  timeout_ms?: number | null;
  cache_policy: CachePolicy;
  provider?: string | null;
  streaming: boolean;
  include_debug_trace: boolean;
}

export interface ResearchCitation {
  index: number;
  title: string;
  url: string;
  excerpt?: string | null;
}

export interface ResearchResponse {
  request_id: string;
  query: string;
  answer: string;
  citations: ResearchCitation[];
  trace: Record<string, unknown>;
  raw_search?: SearchResponse | null;
}

export interface SessionTitleRequest {
  query: string;
  context?: string | null;
  provider?: string | null;
}

export interface SessionTitleResponse {
  title: string;
  provider?: string | null;
  model?: string | null;
}

export interface ProviderInfo {
  name: string;
  display_name?: string | null;
  provider_type: string;
  base_url?: string | null;
  model?: string | null;
  enabled: boolean;
  is_default: boolean;
  healthy?: boolean | null;
  detail?: string | null;
  generation_ok?: boolean | null;
  model_available?: boolean | null;
  latency_ms?: number | null;
  models?: string[] | null;
}

export interface ProviderProfileUpdate {
  display_name: string;
  provider_type: "openai-compatible";
  base_url?: string | null;
  model?: string | null;
  enabled: boolean;
  is_default: boolean;
}

export interface ProviderModelsResponse {
  provider: string;
  base_url?: string | null;
  models: string[];
}

export interface ProviderDraftRequest {
  name: string;
  provider_type: "openai-compatible";
  base_url?: string | null;
  model?: string | null;
  enabled: boolean;
}

export interface ProviderTestResponse {
  ok: boolean;
  detail: string;
  provider?: string | null;
  base_url?: string | null;
  model?: string | null;
  model_available?: boolean | null;
  generation_ok?: boolean | null;
  latency_ms?: number | null;
  models?: string[] | null;
}

export interface LlmCapability {
  enabled: boolean;
  ready: boolean;
  mode: string;
  detail?: string | null;
  provider?: string | null;
  base_url?: string | null;
  model?: string | null;
  models?: string[] | null;
  model_available?: boolean | null;
  generation_ok?: boolean | null;
  latency_ms?: number | null;
}

export interface SearchCapability {
  enabled: boolean;
  ready: boolean;
  mode: string;
  detail?: string | null;
}

export interface LlmSettings {
  enabled: boolean;
  reason?: string | null;
  source?: string | null;
}

export interface ReadinessResponse {
  status: "ready" | "degraded";
  service: string;
  environment: string;
  checks: Record<string, unknown>;
  capabilities?: {
    search?: SearchCapability;
    llm?: LlmCapability;
  };
}

export interface SearchPreset {
  preset_id: string;
  name: string;
  request: SearchRequest;
  created_at: string;
}

export type SearchPresetSettings = Omit<SearchRequest, "query" | "streaming"> & {
  top_n?: number;
  provider?: string | null;
  auto_name_session?: boolean;
};

export interface HistoryRecord {
  history_id: string;
  kind: string;
  query: string;
  request: Record<string, unknown>;
  response: Record<string, unknown>;
  debug?: Record<string, unknown> | null;
  created_at: string;
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function asString(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function asNumber(value: unknown, fallback = 0): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function normalizeSearchResult(value: unknown, index: number): SearchResult {
  const item = asRecord(value);
  return {
    title: asString(item.title, "Untitled result"),
    url: asString(item.url, `about:blank#result-${index + 1}`),
    engine: typeof item.engine === "string" ? item.engine : null,
    score: typeof item.score === "number" ? item.score : null,
    snippet: typeof item.snippet === "string" ? item.snippet : null,
    content: typeof item.content === "string" ? item.content : null,
    published_date: typeof item.published_date === "string" ? item.published_date : null,
    fetched: Boolean(item.fetched),
    extracted: Boolean(item.extracted),
    metadata: asRecord(item.metadata)
  };
}

function normalizeSearchResponse(value: unknown): SearchResponse {
  const payload = asRecord(value);
  const results = Array.isArray(payload.results) ? payload.results.map(normalizeSearchResult) : [];
  return {
    request_id: asString(payload.request_id, "unknown-request"),
    query: asString(payload.query),
    page: asNumber(payload.page, 1),
    result_count: asNumber(payload.result_count, results.length),
    results,
    summary: typeof payload.summary === "string" ? payload.summary : null,
    cache: asRecord(payload.cache),
    debug: asRecord(payload.debug)
  };
}

function normalizeResearchCitation(value: unknown, index: number): ResearchCitation {
  const item = asRecord(value);
  return {
    index: asNumber(item.index, index + 1),
    title: asString(item.title, "Untitled source"),
    url: asString(item.url, `about:blank#source-${index + 1}`),
    excerpt: typeof item.excerpt === "string" ? item.excerpt : null
  };
}

function normalizeResearchResponse(value: unknown): ResearchResponse {
  const payload = asRecord(value);
  const citations = Array.isArray(payload.citations) ? payload.citations.map(normalizeResearchCitation) : [];
  return {
    request_id: asString(payload.request_id, "unknown-request"),
    query: asString(payload.query),
    answer: asString(payload.answer, ""),
    citations,
    trace: asRecord(payload.trace),
    // raw_search can contain many full extracted documents. The UI renders sources from
    // searchPayload, so do not carry this duplicate payload through session state.
    raw_search: null
  };
}

const API_BASE =
  import.meta.env.VITE_API_BASE_URL ??
  (window.location.port === "5173" ? "http://127.0.0.1:8000" : window.location.origin);

function getPairingToken(): string | null {
  return window.localStorage.getItem("hypersearch_pairing_token");
}

function tokenFromUrl(): string {
  const candidates = [
    new URLSearchParams(window.location.search),
    new URLSearchParams(window.location.hash.startsWith("#") ? window.location.hash.slice(1) : window.location.hash)
  ];
  for (const params of candidates) {
    const token = params.get("hypersearch_token") ?? params.get("pairing_token") ?? params.get("token");
    if (token?.trim()) {
      return token.trim();
    }
  }
  return "";
}

async function apiFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const headers = new Headers(init?.headers);
  headers.set("Content-Type", "application/json");
  const pairingToken = getPairingToken();
  if (pairingToken) {
    headers.set("X-HyperSearch-Token", pairingToken);
  }
  const response = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || `HTTP ${response.status}`);
  }
  return response.json() as Promise<T>;
}

async function apiFetchJson<T>(path: string, init?: RequestInit): Promise<{ ok: boolean; status: number; body: T }> {
  const headers = new Headers(init?.headers);
  headers.set("Content-Type", "application/json");
  const pairingToken = getPairingToken();
  if (pairingToken) {
    headers.set("X-HyperSearch-Token", pairingToken);
  }
  const response = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers
  });
  return {
    ok: response.ok,
    status: response.status,
    body: await response.json() as T
  };
}

export function listProviders() {
  return apiFetch<ProviderInfo[]>("/v1/providers");
}

export function getReadiness() {
  return apiFetchJson<ReadinessResponse>("/v1/ready").then((result) => result.body);
}

export function getLlmSettings() {
  return apiFetch<LlmSettings>("/v1/admin/llm");
}

export function updateLlmSettings(payload: { enabled: boolean; reason?: string | null }) {
  return apiFetch<LlmSettings>("/v1/admin/llm", {
    method: "PATCH",
    body: JSON.stringify(payload)
  });
}

export function testProvider(payload: ProviderDraftRequest) {
  return apiFetch<ProviderTestResponse>("/v1/providers/test", {
    method: "POST",
    body: JSON.stringify(payload)
  });
}

export function setDefaultProvider(name: string) {
  return apiFetch<{ status: string; default_provider: string }>("/v1/providers/default", {
    method: "POST",
    body: JSON.stringify({ name })
  });
}

export function updateProviderProfile(name: string, payload: ProviderProfileUpdate) {
  return apiFetch<ProviderInfo>(`/v1/providers/${name}`, {
    method: "PATCH",
    body: JSON.stringify(payload)
  });
}

export function listProviderModels(name: string) {
  return apiFetch<ProviderModelsResponse>(`/v1/providers/${name}/models`);
}

export function discoverDraftProviderModels(payload: ProviderDraftRequest) {
  return apiFetch<ProviderModelsResponse>("/v1/providers/models", {
    method: "POST",
    body: JSON.stringify(payload)
  });
}

export function verifyProviderModel(payload: ProviderDraftRequest) {
  return apiFetch<Record<string, unknown>>(`/v1/providers/${payload.name}/verify-model`, {
    method: "POST",
    body: JSON.stringify(payload)
  });
}

export function runSearch(payload: SearchRequest) {
  return apiFetch<unknown>("/v1/search", {
    method: "POST",
    body: JSON.stringify(payload)
  }).then(normalizeSearchResponse);
}

export function runResearch(payload: ResearchRequest) {
  return apiFetch<unknown>("/v1/research", {
    method: "POST",
    body: JSON.stringify(payload)
  }).then(normalizeResearchResponse);
}

export function generateSessionTitle(payload: SessionTitleRequest) {
  return apiFetch<SessionTitleResponse>("/v1/session-title", {
    method: "POST",
    body: JSON.stringify(payload)
  });
}

export function listPresets() {
  return apiFetch<SearchPreset[]>("/v1/search/presets");
}

export function savePreset(name: string, request: SearchPresetSettings) {
  return apiFetch<SearchPreset>("/v1/search/presets", {
    method: "POST",
    body: JSON.stringify({ name, request })
  });
}

export function deletePreset(presetId: string) {
  return apiFetch<{ deleted: boolean; preset_id: string }>(`/v1/search/presets/${presetId}`, {
    method: "DELETE"
  });
}

export function invalidateCache(namespace: string) {
  return apiFetch<{ status: string; deleted: number }>("/v1/admin/cache/invalidate", {
    method: "POST",
    body: JSON.stringify({ namespace })
  });
}

export function listHistory(params: { kind?: string; q?: string; limit?: number } = {}) {
  const query = new URLSearchParams();
  if (params.kind) {
    query.set("kind", params.kind);
  }
  if (params.q) {
    query.set("q", params.q);
  }
  if (params.limit) {
    query.set("limit", String(params.limit));
  }
  const suffix = query.toString() ? `?${query.toString()}` : "";
  return apiFetch<HistoryRecord[]>(`/v1/history${suffix}`);
}

export function exportHistory() {
  return apiFetch<{ exported_at: string; records: HistoryRecord[] }>("/v1/history/export");
}

export function applyHistoryRetention(days: number) {
  return apiFetch<{ deleted: number }>("/v1/history/retention", {
    method: "POST",
    body: JSON.stringify({ days })
  });
}

export function setStoredPairingToken(value: string) {
  if (value) {
    try {
      window.localStorage.setItem("hypersearch_pairing_token", value);
    } catch (error) {
      console.warn("HyperSearch could not persist the pairing token.", error);
    }
    return;
  }
  window.localStorage.removeItem("hypersearch_pairing_token");
}

export function getStoredPairingToken() {
  return getPairingToken() ?? "";
}

export function hydratePairingTokenFromUrl() {
  const token = tokenFromUrl();
  if (!token) {
    return getStoredPairingToken();
  }
  setStoredPairingToken(token);
  const cleanUrl = `${window.location.origin}${window.location.pathname}`;
  window.history.replaceState({}, document.title, cleanUrl);
  return token;
}
