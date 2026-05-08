import { startTransition, useEffect, useState } from "react";
import { useMutation, useQuery } from "@tanstack/react-query";

import { JsonView } from "../components/JsonView";
import { SectionCard } from "../components/SectionCard";
import { AdminPanel } from "../features/admin/AdminPanel";
import { ResearchPane } from "../features/research/ResearchPane";
import { SearchCommand, SearchSettings, SearchFormState } from "../features/search/SearchForm";
import { SearchResults } from "../features/search/SearchResults";
import {
  ProviderDraftRequest,
  ResearchResponse,
  SearchPreset,
  SearchResponse,
  applyHistoryRetention,
  deletePreset,
  discoverDraftProviderModels,
  generateSessionTitle,
  getLlmSettings,
  getReadiness,
  getStoredPairingToken,
  hydratePairingTokenFromUrl,
  invalidateCache,
  listHistory,
  listPresets,
  listProviders,
  runResearch,
  runSearch,
  savePreset,
  setDefaultProvider,
  setStoredPairingToken,
  testProvider,
  updateLlmSettings,
  updateProviderProfile,
  verifyProviderModel
} from "../lib/api";
import { queryClient } from "../lib/queryClient";

const INITIAL_FORM: SearchFormState = {
  query: "",
  engines: "",
  categories: "",
  language: "",
  time_range: "",
  page: 1,
  results_per_page: 10,
  max_pages: 1,
  target_results: 10,
  safe_search: 1,
  dedupe: true,
  fetch_pages: false,
  extract_text: false,
  summarize: false,
  auto_name_session: true,
  top_n: 5,
  timeout_ms: 30000,
  cache_policy: "use",
  provider: ""
};

type WorkspaceTab = "results" | "research";
type UtilityPanel = "ops" | "log" | "sessions" | null;

interface ActivityEntry {
  id: string;
  createdAt: string;
  kind: "search" | "research" | "ops" | "error";
  title: string;
  summary: string;
  payload: unknown;
}

interface SessionSnapshot {
  id: string;
  name: string;
  createdAt: string;
  updatedAt: string;
  form: SearchFormState;
  workspaceTab: WorkspaceTab;
  activityLog: ActivityEntry[];
  searchPayload?: SearchResponse | null;
  researchPayload?: ResearchResponse | null;
}

export interface XmlExportOptions {
  metadata: boolean;
  question: boolean;
  searchResults: boolean;
  fullText: boolean;
  summaries: boolean;
  researchAnswer: boolean;
  citations: boolean;
  activityLog: boolean;
  providerTrace: boolean;
}

const SESSION_INDEX_KEY = "hypersearch_session_index";
const MIN_UI_ZOOM = 0.5;
const MAX_UI_ZOOM = 2;
const MAX_FORM_RESULTS = 250;
const MAX_REQUEST_TIMEOUT_MS = 600000;
const SESSION_RESULT_CONTENT_LIMIT = 1200;
const SESSION_SNIPPET_LIMIT = 700;
const SESSION_ANSWER_LIMIT = 120000;
const SESSION_TRACE_TEXT_LIMIT = 1200;
const XML_EXPORT_OPTIONS_KEY = "hypersearch_xml_export_options";
const DEFAULT_PRESET_KEY = "hypersearch_default_preset_id";
const DEFAULT_PRESET_FORM_KEY = "hypersearch_default_preset_form";
const DEFAULT_XML_EXPORT_OPTIONS: XmlExportOptions = {
  metadata: true,
  question: true,
  searchResults: true,
  fullText: true,
  summaries: true,
  researchAnswer: true,
  citations: true,
  activityLog: true,
  providerTrace: true
};

function buildPresetSettings(form: SearchFormState) {
  return {
    engines: splitCsv(form.engines),
    categories: splitCsv(form.categories),
    language: form.language || null,
    time_range: form.time_range || null,
    page: form.page,
    results_per_page: form.results_per_page,
    max_pages: form.max_pages,
    target_result_count: form.target_results,
    safe_search: form.safe_search,
    dedupe: form.dedupe,
    fetch_pages: form.fetch_pages,
    extract_text: form.extract_text,
    summarize: form.summarize,
    auto_name_session: form.auto_name_session,
    top_n: form.top_n,
    provider: form.provider || null,
    timeout_ms: form.timeout_ms,
    cache_policy: form.cache_policy
  };
}

function clampFormInt(value: unknown, fallback: number, min: number, max: number) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return fallback;
  }
  return Math.min(max, Math.max(min, Math.round(numeric)));
}

function normalizeStoredForm(form?: Partial<SearchFormState> | null): SearchFormState {
  const raw = (form ?? {}) as Partial<SearchFormState> & { target_result_count?: number | null };
  const merged = { ...INITIAL_FORM, ...raw };
  const resultsPerPage = clampFormInt(merged.results_per_page, INITIAL_FORM.results_per_page, 1, 50);
  const maxPages = clampFormInt(merged.max_pages, INITIAL_FORM.max_pages, 1, 5);
  const fallbackTarget = resultsPerPage * maxPages;
  return {
    ...merged,
    page: clampFormInt(merged.page, INITIAL_FORM.page, 1, 20),
    results_per_page: resultsPerPage,
    max_pages: maxPages,
    target_results: clampFormInt(raw.target_results ?? raw.target_result_count, fallbackTarget, 1, MAX_FORM_RESULTS),
    safe_search: clampFormInt(merged.safe_search, INITIAL_FORM.safe_search, 0, 2),
    top_n: clampFormInt(merged.top_n, INITIAL_FORM.top_n, 1, MAX_FORM_RESULTS),
    timeout_ms: clampFormInt(merged.timeout_ms, INITIAL_FORM.timeout_ms, 1000, MAX_REQUEST_TIMEOUT_MS)
  };
}

function formFromPresetRequest(request: Record<string, unknown>, current: SearchFormState = INITIAL_FORM): SearchFormState {
  const resultsPerPage = clampFormInt(request.results_per_page, current.results_per_page, 1, 50);
  const maxPages = clampFormInt(request.max_pages, current.max_pages, 1, 5);
  const fallbackTarget = resultsPerPage * maxPages;
  return normalizeStoredForm({
    ...current,
    engines: Array.isArray(request.engines) ? request.engines.join(",") : "",
    categories: Array.isArray(request.categories) ? request.categories.join(",") : "",
    language: String(request.language ?? ""),
    time_range: String(request.time_range ?? ""),
    page: clampFormInt(request.page, 1, 1, 20),
    results_per_page: resultsPerPage,
    max_pages: maxPages,
    target_results: clampFormInt(
      request.target_result_count ?? request.target_results,
      fallbackTarget,
      1,
      MAX_FORM_RESULTS
    ),
    safe_search: clampFormInt(request.safe_search, current.safe_search, 0, 2),
    top_n: clampFormInt(request.top_n, current.top_n, 1, MAX_FORM_RESULTS),
    dedupe: Boolean(request.dedupe ?? true),
    fetch_pages: Boolean(request.fetch_pages ?? false),
    extract_text: Boolean(request.extract_text ?? false),
    summarize: Boolean(request.summarize ?? false),
    auto_name_session: Boolean(request.auto_name_session ?? true),
    provider: String(request.provider ?? ""),
    cache_policy: (request.cache_policy as SearchFormState["cache_policy"]) ?? "use",
    timeout_ms: clampFormInt(request.timeout_ms, current.timeout_ms, 1000, MAX_REQUEST_TIMEOUT_MS)
  });
}

function loadDefaultPresetForm() {
  try {
    const parsed = JSON.parse(window.localStorage.getItem(DEFAULT_PRESET_FORM_KEY) ?? "null");
    if (!parsed?.form) {
      return null;
    }
    return normalizeStoredForm(parsed.form);
  } catch {
    return null;
  }
}

function saveDefaultPresetForm(preset: SearchPreset) {
  try {
    window.localStorage.setItem(
      DEFAULT_PRESET_FORM_KEY,
      JSON.stringify({
        preset_id: preset.preset_id,
        name: preset.name,
        savedAt: new Date().toISOString(),
        form: formFromPresetRequest(preset.request as unknown as Record<string, unknown>)
      })
    );
  } catch (error) {
    console.warn("HyperSearch could not persist the default preset form.", error);
  }
}

function getSessionParam(name: string) {
  return new URLSearchParams(window.location.search).get(name);
}

function getInitialSessionId() {
  const existing = getSessionParam("hypersearch_session_id");
  if (existing?.trim()) {
    return existing.trim();
  }
  const resumeLast = getSessionParam("hypersearch_resume_last");
  if (resumeLast && ["1", "true", "yes"].includes(resumeLast.trim().toLowerCase())) {
    const stored = window.localStorage.getItem("hypersearch_last_session_id");
    if (stored?.trim()) {
      return stored.trim();
    }
  }
  return crypto.randomUUID();
}

function getInitialSessionName(sessionId: string) {
  const fromUrl = getSessionParam("hypersearch_session_title");
  const stored = loadSessionSnapshot(sessionId);
  return stored?.name ?? fromUrl?.trim() ?? "Untitled Session";
}

function loadSessionIndex(): Array<{ id: string; name: string; updatedAt: string; createdAt: string }> {
  try {
    const parsed = JSON.parse(window.localStorage.getItem(SESSION_INDEX_KEY) ?? "[]");
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function saveSessionIndex(items: Array<{ id: string; name: string; updatedAt: string; createdAt: string }>) {
  try {
    window.localStorage.setItem(SESSION_INDEX_KEY, JSON.stringify(items));
  } catch (error) {
    console.warn("HyperSearch could not persist the session index.", error);
  }
}

function sessionStorageKey(id: string) {
  return `hypersearch_session_${id}`;
}

function parseDesktopMessage(input: unknown): { type?: string; ok?: boolean; path?: string; error?: string; filename?: string } | null {
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
  return input as { type?: string; ok?: boolean; path?: string; error?: string; filename?: string };
}

function postDesktopMessage(payload: unknown) {
  if (window.parent && window.parent !== window) {
    window.parent.postMessage(JSON.stringify(payload), "*");
  }
}

function loadSessionSnapshot(id: string): SessionSnapshot | null {
  try {
    const raw = window.localStorage.getItem(sessionStorageKey(id));
    return raw ? JSON.parse(raw) as SessionSnapshot : null;
  } catch {
    return null;
  }
}

function loadXmlExportOptions(): XmlExportOptions {
  try {
    const parsed = JSON.parse(window.localStorage.getItem(XML_EXPORT_OPTIONS_KEY) ?? "{}") as Partial<XmlExportOptions>;
    return { ...DEFAULT_XML_EXPORT_OPTIONS, ...parsed };
  } catch {
    return DEFAULT_XML_EXPORT_OPTIONS;
  }
}

function indexSession(snapshot: SessionSnapshot) {
  const withoutCurrent = loadSessionIndex().filter((item) => item.id !== snapshot.id);
  saveSessionIndex([
    { id: snapshot.id, name: snapshot.name, createdAt: snapshot.createdAt, updatedAt: snapshot.updatedAt },
    ...withoutCurrent
  ].slice(0, 50));
  try {
    window.localStorage.setItem("hypersearch_last_session_id", snapshot.id);
  } catch (error) {
    console.warn("HyperSearch could not persist the last session id.", error);
  }
}

function truncateText(value: unknown, limit: number) {
  const text = String(value ?? "");
  return text.length > limit ? `${text.slice(0, limit)}\n\n[Truncated for saved session storage]` : text;
}

function compactUnknown(value: unknown, limit = SESSION_TRACE_TEXT_LIMIT): unknown {
  if (typeof value === "string") {
    return truncateText(value, limit);
  }
  if (typeof value === "number" || typeof value === "boolean" || value == null) {
    return value;
  }
  if (Array.isArray(value)) {
    return value.slice(0, 25).map((item) => compactUnknown(item, limit));
  }
  if (typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .slice(0, 40)
        .map(([key, item]) => [key, compactUnknown(item, limit)])
    );
  }
  return String(value);
}

function compactSearchPayload(payload: SearchResponse | null | undefined): SearchResponse | null {
  if (!payload) {
    return null;
  }
  const results = Array.isArray(payload.results) ? payload.results : [];
  return {
    ...payload,
    summary: payload.summary ? truncateText(payload.summary, SESSION_ANSWER_LIMIT) : payload.summary,
    results: results.slice(0, 250).map((result) => ({
      ...result,
      title: truncateText(result.title, 500),
      url: truncateText(result.url, 1000),
      snippet: result.snippet ? truncateText(result.snippet, SESSION_SNIPPET_LIMIT) : result.snippet,
      content: result.content ? truncateText(result.content, SESSION_RESULT_CONTENT_LIMIT) : result.content,
      metadata: compactUnknown(result.metadata, 500) as Record<string, unknown>
    })),
    cache: compactUnknown(payload.cache, 500) as Record<string, unknown>,
    debug: compactUnknown(payload.debug, 500) as Record<string, unknown>
  };
}

function compactResearchPayload(payload: ResearchResponse | null | undefined): ResearchResponse | null {
  if (!payload) {
    return null;
  }
  const citations = Array.isArray(payload.citations) ? payload.citations : [];
  return {
    ...payload,
    answer: truncateText(payload.answer, SESSION_ANSWER_LIMIT),
    citations: citations.slice(0, 250).map((citation) => ({
      ...citation,
      title: truncateText(citation.title, 500),
      url: truncateText(citation.url, 1000),
      excerpt: citation.excerpt ? truncateText(citation.excerpt, SESSION_SNIPPET_LIMIT) : citation.excerpt
    })),
    trace: compactUnknown(payload.trace, SESSION_TRACE_TEXT_LIMIT) as Record<string, unknown>,
    raw_search: null
  };
}

function compactActivityPayload(entry: ActivityEntry): ActivityEntry {
  if (entry.kind === "search" || entry.kind === "research") {
    const payload = entry.payload && typeof entry.payload === "object" ? entry.payload as Record<string, unknown> : {};
    return {
      ...entry,
      payload: {
        request_id: payload.request_id,
        query: payload.query,
        result_count: payload.result_count,
        citation_count: Array.isArray(payload.citations) ? payload.citations.length : undefined,
        trace: compactUnknown(payload.trace, 500)
      }
    };
  }
  return {
    ...entry,
    payload: compactUnknown(entry.payload, 800)
  };
}

function compactSessionSnapshot(snapshot: SessionSnapshot): SessionSnapshot {
  return {
    ...snapshot,
    activityLog: snapshot.activityLog.slice(0, 40).map(compactActivityPayload),
    searchPayload: compactSearchPayload(snapshot.searchPayload),
    researchPayload: compactResearchPayload(snapshot.researchPayload)
  };
}

function removeOldSavedSessions(currentSessionId: string) {
  const index = loadSessionIndex();
  const removable = index.filter((item) => item.id !== currentSessionId).slice(20);
  for (const item of removable) {
    window.localStorage.removeItem(sessionStorageKey(item.id));
  }
  if (removable.length > 0) {
    saveSessionIndex(index.filter((item) => !removable.some((removed) => removed.id === item.id)));
  }
}

function persistSessionSnapshot(snapshot: SessionSnapshot) {
  const compact = compactSessionSnapshot(snapshot);
  const key = sessionStorageKey(snapshot.id);
  const serialized = JSON.stringify(compact);
  try {
    window.localStorage.setItem(key, serialized);
    indexSession(compact);
    return true;
  } catch (error) {
    console.warn("HyperSearch session autosave exceeded local storage. Retrying after pruning old saved sessions.", error);
    try {
      removeOldSavedSessions(snapshot.id);
      window.localStorage.setItem(key, serialized);
      indexSession(compact);
      return true;
    } catch (retryError) {
      console.warn("HyperSearch session autosave skipped after quota retry.", retryError);
      const minimal = {
        ...compact,
        searchPayload: null,
        researchPayload: compact.researchPayload ? {
          ...compact.researchPayload,
          answer: truncateText(compact.researchPayload.answer, 20000),
          citations: compact.researchPayload.citations.slice(0, 50),
          trace: {},
          raw_search: null
        } : null,
        activityLog: compact.activityLog.map((entry) => ({ ...entry, payload: null }))
      };
      try {
        window.localStorage.setItem(key, JSON.stringify(minimal));
      } catch (minimalError) {
        console.warn("HyperSearch minimal session autosave skipped.", minimalError);
      }
      indexSession(minimal);
      return false;
    }
  }
}

function sanitizeFilenamePart(value: string) {
  return value.replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_").replace(/\s+/g, " ").trim().replace(/[. ]+$/g, "") || "hypersearch-session";
}

function xmlEscape(value: unknown) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

function datetimeCode(date = new Date()) {
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}_${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
}

function buildExportFilename(snapshot: SessionSnapshot) {
  const query = snapshot.researchPayload?.query || snapshot.searchPayload?.query || snapshot.form.query || snapshot.name;
  return `${sanitizeFilenamePart(query.slice(0, 48))}_${datetimeCode()}.xml`;
}

function buildSessionXml(snapshot: SessionSnapshot, options: XmlExportOptions) {
  const search = snapshot.searchPayload;
  const research = snapshot.researchPayload;
  const searchResults = search?.results ?? [];
  const citations = research?.citations ?? [];
  return `<?xml version="1.0" encoding="UTF-8"?>
<hypersearchSession version="1.0">
${options.metadata ? `  <metadata>
    <sessionId>${xmlEscape(snapshot.id)}</sessionId>
    <name>${xmlEscape(snapshot.name)}</name>
    <createdAt>${xmlEscape(snapshot.createdAt)}</createdAt>
    <updatedAt>${xmlEscape(snapshot.updatedAt)}</updatedAt>
    <exportedAt>${xmlEscape(new Date().toISOString())}</exportedAt>
${options.question ? `    <query>${xmlEscape(research?.query || search?.query || snapshot.form.query)}</query>` : ""}
${options.providerTrace ? `    <provider>${xmlEscape(research?.trace?.provider)}</provider>
    <model>${xmlEscape(research?.trace?.model)}</model>
    <documentCount>${xmlEscape(research?.trace?.document_count)}</documentCount>` : ""}
  </metadata>` : options.question ? `  <question>${xmlEscape(research?.query || search?.query || snapshot.form.query)}</question>` : ""}
${options.searchResults ? `  <search>
    <requestId>${xmlEscape(search?.request_id)}</requestId>
    <resultCount>${xmlEscape(search?.result_count ?? searchResults.length)}</resultCount>
${options.summaries ? `    <summary>${xmlEscape(search?.summary)}</summary>` : ""}
    <results>
${searchResults.map((result, index) => `      <result index="${index + 1}">
        <title>${xmlEscape(result.title)}</title>
        <url>${xmlEscape(result.url)}</url>
        <engine>${xmlEscape(result.engine)}</engine>
        <snippet>${xmlEscape(result.snippet)}</snippet>
${options.fullText ? `        <content>${xmlEscape(result.content)}</content>` : ""}
        <fetched>${xmlEscape(result.fetched)}</fetched>
        <extracted>${xmlEscape(result.extracted)}</extracted>
      </result>`).join("\n")}
    </results>
  </search>` : ""}
${options.researchAnswer || options.citations || options.providerTrace ? `  <research>
    <requestId>${xmlEscape(research?.request_id)}</requestId>
${options.researchAnswer ? `    <answer>${xmlEscape(research?.answer)}</answer>` : ""}
${options.providerTrace ? `    <trace>${xmlEscape(JSON.stringify(research?.trace ?? {}))}</trace>` : ""}
${options.citations ? `    <citations>
${citations.map((citation) => `      <citation index="${xmlEscape(citation.index)}">
        <title>${xmlEscape(citation.title)}</title>
        <url>${xmlEscape(citation.url)}</url>
        <excerpt>${xmlEscape(citation.excerpt)}</excerpt>
      </citation>`).join("\n")}
    </citations>` : ""}
  </research>` : ""}
${options.activityLog ? `  <activityLog>
${snapshot.activityLog.map((entry) => `    <event id="${xmlEscape(entry.id)}" kind="${xmlEscape(entry.kind)}" at="${xmlEscape(entry.createdAt)}">
      <title>${xmlEscape(entry.title)}</title>
      <summary>${xmlEscape(entry.summary)}</summary>
    </event>`).join("\n")}
  </activityLog>` : ""}
</hypersearchSession>
`;
}

function splitCsv(value: string): string[] | null {
  const items = value.split(",").map((item) => item.trim()).filter(Boolean);
  return items.length > 0 ? items : null;
}

function shortId(value: string | undefined) {
  return value ? value.slice(0, 8) : "n/a";
}

function summarizeSearch(payload: SearchResponse) {
  return `${payload.result_count} results for "${payload.query}"`;
}

function citationCount(payload: ResearchResponse | null | undefined) {
  return Array.isArray(payload?.citations) ? payload.citations.length : 0;
}

function resultCount(payload: SearchResponse | null | undefined) {
  return Number.isFinite(payload?.result_count) ? Number(payload?.result_count) : payload?.results?.length ?? 0;
}

function summarizeResearch(payload: ResearchResponse) {
  return `${citationCount(payload)} citations for "${payload.query}"`;
}

function requestedResultCount(form: SearchFormState) {
  return clampFormInt(form.target_results, form.results_per_page * form.max_pages, 1, MAX_FORM_RESULTS);
}

function withElapsed(message: string, elapsedSeconds: number) {
  return elapsedSeconds > 0 ? `${message} (${elapsedSeconds}s)` : message;
}

function describeSearchProgress(form: SearchFormState, elapsedSeconds: number) {
  const target = requestedResultCount(form);
  if (elapsedSeconds < 6) {
    return withElapsed(`Collecting result pages for up to ${target} results`, elapsedSeconds);
  }
  if ((form.fetch_pages || form.extract_text) && elapsedSeconds >= 12) {
    return withElapsed("Fetching and extracting selected result pages", elapsedSeconds);
  }
  if (elapsedSeconds < 20) {
    return withElapsed("Deduplicating and ranking collected results", elapsedSeconds);
  }
  return withElapsed("Still working through SearXNG, cache, and local fetches", elapsedSeconds);
}

function describeResearchProgress(form: SearchFormState, llmReady: boolean, elapsedSeconds: number) {
  const target = Math.max(requestedResultCount(form), form.top_n);
  if (elapsedSeconds < 6) {
    return withElapsed(`Collecting up to ${target} search results`, elapsedSeconds);
  }
  if (elapsedSeconds < 18) {
    return withElapsed(`Fetching and extracting up to ${form.top_n} source pages`, elapsedSeconds);
  }
  if (elapsedSeconds < 45) {
    return withElapsed(
      llmReady ? "Building source notes with the selected local model" : "Preparing source review from collected pages",
      elapsedSeconds
    );
  }
  return withElapsed("Consolidating evidence, citations, and final response", elapsedSeconds);
}

function isAutoGeneratedSessionName(value: string) {
  return !value.trim() || value === "Untitled Session" || /^Session\s+\d+$/i.test(value.trim());
}

export function App() {
  const [sessionId, setSessionId] = useState(() => getInitialSessionId());
  const [sessionName, setSessionName] = useState(() => getInitialSessionName(sessionId));
  const [sessionIndex, setSessionIndex] = useState(() => loadSessionIndex());
  const initialSnapshot = loadSessionSnapshot(sessionId);
  const defaultPresetForm = loadDefaultPresetForm();
  const [form, setForm] = useState<SearchFormState>(() => (
    initialSnapshot ? normalizeStoredForm(initialSnapshot.form) : normalizeStoredForm(defaultPresetForm)
  ));
  const [theme, setTheme] = useState<"light" | "dark">(
    () => (window.localStorage.getItem("hypersearch_theme") as "light" | "dark" | null) ?? "light"
  );
  const [uiZoom, setUiZoom] = useState(() => {
    const storedZoom = Number(window.localStorage.getItem("hypersearch_ui_zoom") ?? "1");
    return Number.isFinite(storedZoom) ? Math.min(MAX_UI_ZOOM, Math.max(MIN_UI_ZOOM, storedZoom)) : 1;
  });
  const [pairingToken, setPairingToken] = useState<string>(() => hydratePairingTokenFromUrl() || getStoredPairingToken());
  const [adminMessage, setAdminMessage] = useState("");
  const [workspaceTab, setWorkspaceTab] = useState<WorkspaceTab>(initialSnapshot?.workspaceTab ?? "results");
  const [utilityPanel, setUtilityPanel] = useState<UtilityPanel>(null);
  const [activityLog, setActivityLog] = useState<ActivityEntry[]>(initialSnapshot?.activityLog ?? []);
  const [searchPayload, setSearchPayload] = useState<SearchResponse | null>(initialSnapshot?.searchPayload ?? null);
  const [researchPayload, setResearchPayload] = useState<ResearchResponse | null>(initialSnapshot?.researchPayload ?? null);
  const [selectedLogId, setSelectedLogId] = useState<string | null>(null);
  const [providerModels, setProviderModels] = useState<Record<string, string[]>>({});
  const [providerModelsLoading, setProviderModelsLoading] = useState<Record<string, boolean>>({});
  const [xmlExportOptions, setXmlExportOptions] = useState<XmlExportOptions>(() => loadXmlExportOptions());
  const [searchSettingsExpanded, setSearchSettingsExpanded] = useState(() => window.localStorage.getItem("hypersearch_settings_expanded") !== "false");
  const [defaultPresetId, setDefaultPresetId] = useState(() => window.localStorage.getItem(DEFAULT_PRESET_KEY) ?? "");
  const [defaultPresetApplied, setDefaultPresetApplied] = useState(Boolean(initialSnapshot || defaultPresetForm));
  const [workStartedAt, setWorkStartedAt] = useState<number | null>(null);
  const [workClock, setWorkClock] = useState(0);
  const isEmbedded = window.parent && window.parent !== window;

  const providersQuery = useQuery({
    queryKey: ["providers"],
    queryFn: listProviders
  });

  const presetsQuery = useQuery({
    queryKey: ["presets"],
    queryFn: listPresets
  });

  const readinessQuery = useQuery({
    queryKey: ["readiness"],
    queryFn: getReadiness,
    retry: false
  });

  const llmSettingsQuery = useQuery({
    queryKey: ["llm-settings"],
    queryFn: getLlmSettings,
    retry: false
  });

  const historyQuery = useQuery({
    queryKey: ["history"],
    queryFn: () => listHistory({ limit: 25 })
  });

  const recordActivity = (entry: Omit<ActivityEntry, "id" | "createdAt">) => {
    const nextEntry: ActivityEntry = {
      ...entry,
      id: crypto.randomUUID(),
      createdAt: new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" })
    };
    setActivityLog((current) => [nextEntry, ...current].slice(0, 18));
    setSelectedLogId(nextEntry.id);
  };

  const titleMutation = useMutation({
    mutationFn: generateSessionTitle,
    onSuccess: (payload) => {
      setSessionName((current) => (
        payload.title && isAutoGeneratedSessionName(current) ? payload.title : current
      ));
      recordActivity({
        kind: "ops",
        title: "Session auto-named",
        summary: payload.title,
        payload
      });
    },
    onError: (error) => {
      recordActivity({
        kind: "error",
        title: "Session auto-name failed",
        summary: error instanceof Error ? error.message : "Unknown error",
        payload: { error: error instanceof Error ? error.message : "Unknown error" }
      });
    }
  });

  const maybeAutoNameSession = (query: string, context: string | null | undefined) => {
    if (!llmReady || !form.auto_name_session || !isAutoGeneratedSessionName(sessionName) || titleMutation.isPending) {
      return;
    }
    titleMutation.mutate({
      query,
      context: context ? context.slice(0, 4000) : null,
      provider: form.provider || null
    });
  };

  const searchMutation = useMutation({
    mutationFn: runSearch,
    onSuccess: (payload) => {
      startTransition(() => {
        setSearchPayload(payload);
        setWorkspaceTab("results");
        recordActivity({
          kind: "search",
          title: "Search completed",
          summary: summarizeSearch(payload),
          payload
        });
      });
      maybeAutoNameSession(payload.query, payload.summary ?? payload.results.slice(0, 5).map((item) => `${item.title}: ${item.snippet ?? ""}`).join("\n"));
    },
    onError: (error) => {
      recordActivity({
        kind: "error",
        title: "Search failed",
        summary: error instanceof Error ? error.message : "Unknown error",
        payload: { error: error instanceof Error ? error.message : "Unknown error" }
      });
    }
  });

  const researchMutation = useMutation({
    mutationFn: runResearch,
    onSuccess: (payload) => {
      const fallbackMode = payload.trace?.mode === "search-only-fallback";
      startTransition(() => {
        setResearchPayload(payload);
        setWorkspaceTab("research");
        recordActivity({
          kind: "research",
          title: fallbackMode ? "Source review completed" : "Research synthesis completed",
          summary: summarizeResearch(payload),
          payload
        });
      });
      maybeAutoNameSession(payload.query, payload.answer);
    },
    onError: (error) => {
      recordActivity({
        kind: "error",
        title: "Research failed",
        summary: error instanceof Error ? error.message : "Unknown error",
        payload: { error: error instanceof Error ? error.message : "Unknown error" }
      });
    }
  });

  const presetMutation = useMutation({
    mutationFn: ({ name }: { name: string }) =>
      savePreset(name, buildPresetSettings(form)),
    onSuccess: async (payload) => {
      if (payload.preset_id === defaultPresetId) {
        saveDefaultPresetForm(payload);
      }
      setAdminMessage("Preset saved.");
      recordActivity({
        kind: "ops",
        title: "Preset saved",
        summary: `"${payload.name}" settings saved`,
        payload
      });
      await queryClient.invalidateQueries({ queryKey: ["presets"] });
    }
  });

  const deletePresetMutation = useMutation({
    mutationFn: deletePreset,
    onSuccess: async (payload) => {
      if (payload.preset_id === defaultPresetId) {
        setDefaultPresetId("");
        window.localStorage.removeItem(DEFAULT_PRESET_KEY);
        window.localStorage.removeItem(DEFAULT_PRESET_FORM_KEY);
      }
      recordActivity({
        kind: "ops",
        title: "Preset deleted",
        summary: payload.preset_id,
        payload
      });
      await queryClient.invalidateQueries({ queryKey: ["presets"] });
    }
  });

  const providerTestMutation = useMutation({
    mutationFn: testProvider,
    onSuccess: (payload, draft) => {
      setAdminMessage(payload.detail);
      recordActivity({
        kind: "ops",
        title: `Provider test: ${draft.name}`,
        summary: payload.ok ? payload.detail : `Failed: ${payload.detail}`,
        payload
      });
    }
  });

  const defaultProviderMutation = useMutation({
    mutationFn: setDefaultProvider,
    onSuccess: async (payload) => {
      setAdminMessage(`Default provider set to ${payload.default_provider}.`);
      recordActivity({
        kind: "ops",
        title: "Default provider changed",
        summary: payload.default_provider,
        payload
      });
      await queryClient.invalidateQueries({ queryKey: ["providers"] });
      await queryClient.invalidateQueries({ queryKey: ["readiness"] });
    }
  });

  const providerUpdateMutation = useMutation({
    mutationFn: ({ name, profile }: { name: string; profile: Parameters<typeof updateProviderProfile>[1] }) =>
      updateProviderProfile(name, profile),
    onSuccess: async (payload) => {
      setAdminMessage(`Provider ${payload.name} updated.`);
      recordActivity({
        kind: "ops",
        title: "Provider profile updated",
        summary: payload.name,
        payload
      });
      await queryClient.invalidateQueries({ queryKey: ["providers"] });
      await queryClient.invalidateQueries({ queryKey: ["readiness"] });
    }
  });

  const providerVerifyMutation = useMutation({
    mutationFn: verifyProviderModel,
    onSuccess: (payload, draft) => {
      setAdminMessage(`Verified ${draft.name}.`);
      recordActivity({
        kind: "ops",
        title: `Provider model verified: ${draft.name}`,
        summary: String(payload.model ?? "model available"),
        payload
      });
    },
    onError: (error, draft) => {
      const message = error instanceof Error ? error.message : "Unknown error";
      setAdminMessage(message);
      recordActivity({
        kind: "error",
        title: `Provider model unavailable: ${draft.name}`,
        summary: message,
        payload: { error: message }
      });
    }
  });

  const discoverProviderModels = async (draft: ProviderDraftRequest) => {
    setProviderModelsLoading((current) => ({ ...current, [draft.name]: true }));
    try {
      const payload = await discoverDraftProviderModels(draft);
      setProviderModels((current) => ({ ...current, [draft.name]: payload.models }));
      recordActivity({
        kind: "ops",
        title: `Provider models discovered: ${draft.name}`,
        summary: `${payload.models.length} models from ${payload.base_url ?? "endpoint"}`,
        payload
      });
      return payload.models;
    } catch (error) {
      const message = error instanceof Error ? error.message : "Unknown error";
      setAdminMessage(message);
      recordActivity({
        kind: "error",
        title: `Provider model discovery failed: ${draft.name}`,
        summary: message,
        payload: { error: message }
      });
      return [];
    } finally {
      setProviderModelsLoading((current) => ({ ...current, [draft.name]: false }));
    }
  };

  const llmSettingsMutation = useMutation({
    mutationFn: updateLlmSettings,
    onSuccess: async (payload) => {
      setAdminMessage(payload.enabled ? "LLM features enabled." : "LLM features disabled. Search-only mode is active.");
      recordActivity({
        kind: "ops",
        title: payload.enabled ? "LLM enabled" : "LLM disabled",
        summary: payload.reason ?? payload.source ?? "application setting updated",
        payload
      });
      await queryClient.invalidateQueries({ queryKey: ["llm-settings"] });
      await queryClient.invalidateQueries({ queryKey: ["readiness"] });
      await queryClient.invalidateQueries({ queryKey: ["providers"] });
    },
    onError: (error) => {
      const message = error instanceof Error ? error.message : "Unknown error";
      setAdminMessage(message);
      recordActivity({
        kind: "error",
        title: "LLM setting update failed",
        summary: message,
        payload: { error: message }
      });
    }
  });

  const invalidateMutation = useMutation({
    mutationFn: invalidateCache,
    onSuccess: (payload, namespace) => {
      setAdminMessage(`Invalidated ${payload.deleted} keys.`);
      recordActivity({
        kind: "ops",
        title: `Cache invalidated: ${namespace}`,
        summary: `${payload.deleted} keys removed`,
        payload
      });
    }
  });

  const retentionMutation = useMutation({
    mutationFn: applyHistoryRetention,
    onSuccess: async (payload) => {
      setAdminMessage(`Deleted ${payload.deleted} old history records.`);
      recordActivity({
        kind: "ops",
        title: "History retention applied",
        summary: `${payload.deleted} records removed`,
        payload
      });
      await queryClient.invalidateQueries({ queryKey: ["history"] });
    }
  });

  const busy = searchMutation.isPending || researchMutation.isPending;

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try {
      window.localStorage.setItem("hypersearch_theme", theme);
    } catch (error) {
      console.warn("HyperSearch could not persist the theme preference.", error);
    }
  }, [theme]);

  useEffect(() => {
    try {
      window.localStorage.setItem(XML_EXPORT_OPTIONS_KEY, JSON.stringify(xmlExportOptions));
    } catch (error) {
      console.warn("HyperSearch could not persist XML export options.", error);
    }
  }, [xmlExportOptions]);

  useEffect(() => {
    const clamped = Math.min(MAX_UI_ZOOM, Math.max(MIN_UI_ZOOM, Number.isFinite(uiZoom) ? uiZoom : 1));
    document.documentElement.style.setProperty("--ui-zoom", String(clamped));
    try {
      window.localStorage.setItem("hypersearch_ui_zoom", String(clamped));
    } catch (error) {
      console.warn("HyperSearch could not persist UI zoom.", error);
    }
  }, [uiZoom]);

  useEffect(() => {
    try {
      window.localStorage.setItem("hypersearch_settings_expanded", String(searchSettingsExpanded));
    } catch (error) {
      console.warn("HyperSearch could not persist the search settings layout.", error);
    }
  }, [searchSettingsExpanded]);

  useEffect(() => {
    if (defaultPresetApplied || !defaultPresetId || !presetsQuery.data?.length) {
      return;
    }
    const preset = presetsQuery.data.find((item) => item.preset_id === defaultPresetId);
    if (!preset) {
      return;
    }
    setForm((current) => formFromPresetRequest(preset.request as unknown as Record<string, unknown>, current));
    setDefaultPresetApplied(true);
    recordActivity({
      kind: "ops",
      title: "Default preset loaded",
      summary: preset.name,
      payload: { preset_id: preset.preset_id, name: preset.name }
    });
  }, [defaultPresetApplied, defaultPresetId, presetsQuery.data]);

  useEffect(() => {
    postDesktopMessage({
      type: "hypersearch.sessionTitle",
      payload: { id: sessionId, title: sessionName }
    });
  }, [sessionId, sessionName]);

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (target?.closest("input, textarea, select, [contenteditable='true']")) {
        return;
      }
      if (event.key === "+" || event.key === "=") {
        event.preventDefault();
        adjustUiZoom(0.05);
        return;
      }
      if (event.key === "-" || event.key === "_") {
        event.preventDefault();
        adjustUiZoom(-0.05);
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  useEffect(() => {
    const onWheel = (event: WheelEvent) => {
      if (!event.ctrlKey) {
        return;
      }
      event.preventDefault();
      adjustUiZoom(event.deltaY < 0 ? 0.05 : -0.05);
    };
    window.addEventListener("wheel", onWheel, { passive: false });
    return () => window.removeEventListener("wheel", onWheel);
  }, []);

  useEffect(() => {
    if (!busy) {
      setWorkStartedAt(null);
      setWorkClock(0);
      return;
    }
    const startedAt = Date.now();
    setWorkStartedAt((current) => current ?? startedAt);
    setWorkClock(startedAt);
    const timer = window.setInterval(() => setWorkClock(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [busy]);

  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      const data = parseDesktopMessage(event.data);
      if (data?.type !== "hypersearch.exportSession.result") {
        return;
      }
      recordActivity({
        kind: data.ok ? "ops" : "error",
        title: data.ok ? "Session XML exported" : "Session XML export failed",
        summary: data.ok ? data.path ?? data.filename ?? "Export completed" : data.error ?? "Desktop export failed",
        payload: data
      });
    };
    window.addEventListener("message", onMessage);
    return () => window.removeEventListener("message", onMessage);
  }, []);

  useEffect(() => {
    const createdAt = loadSessionSnapshot(sessionId)?.createdAt ?? new Date().toISOString();
    const snapshot: SessionSnapshot = {
      id: sessionId,
      name: sessionName,
      createdAt,
      updatedAt: new Date().toISOString(),
      form,
      workspaceTab,
      activityLog,
      searchPayload,
      researchPayload
    };
    persistSessionSnapshot(snapshot);
    setSessionIndex(loadSessionIndex());
  }, [activityLog, form, researchPayload, searchPayload, sessionId, sessionName, workspaceTab]);

  const defaultProvider = providersQuery.data?.find((provider) => provider.is_default);
  const llmCapability = readinessQuery.data?.capabilities?.llm;
  const llmEnabled = llmSettingsQuery.data?.enabled ?? llmCapability?.enabled ?? false;
  const llmReady = Boolean(llmEnabled && llmCapability?.ready);
  const llmStatusLabel = !llmEnabled
    ? "Search ready / LLM off"
    : llmReady
      ? `${defaultProvider?.display_name ?? defaultProvider?.name ?? llmCapability?.provider ?? "LLM"} ready`
      : "Search ready / LLM unavailable";
  const selectedLog = activityLog.find((entry) => entry.id === selectedLogId) ?? activityLog[0] ?? null;
  const workspaceQuery = workspaceTab === "research"
    ? researchPayload?.query ?? searchPayload?.query
    : searchPayload?.query ?? researchPayload?.query;
  const latestRequestId = workspaceTab === "research"
    ? researchPayload?.request_id ?? searchPayload?.request_id
    : searchPayload?.request_id ?? researchPayload?.request_id;
  const activeWorkLabel = researchMutation.isPending
    ? llmReady ? "Research synthesis is running" : "Source review is running"
    : searchMutation.isPending
      ? "Search is running"
      : "Ready";
  const activeElapsedSeconds = workStartedAt ? Math.max(0, Math.floor(((workClock || workStartedAt) - workStartedAt) / 1000)) : 0;
  const activeWorkDetail = researchMutation.isPending
    ? describeResearchProgress(form, llmReady, activeElapsedSeconds)
    : searchMutation.isPending
      ? describeSearchProgress(form, activeElapsedSeconds)
      : latestRequestId
        ? `Latest request ${shortId(latestRequestId)}`
        : "No active request";

  const toggleUtilityPanel = (panel: UtilityPanel) => {
    setUtilityPanel((current) => (current === panel ? null : panel));
  };

  const runSearchRequest = () => {
    const startedAt = Date.now();
    setWorkStartedAt(startedAt);
    setWorkClock(startedAt);
    searchMutation.mutate({
      query: form.query,
      engines: splitCsv(form.engines),
      categories: splitCsv(form.categories),
      language: form.language || null,
      time_range: form.time_range || null,
      page: form.page,
      results_per_page: form.results_per_page,
      max_pages: form.max_pages,
      target_result_count: form.target_results,
      safe_search: form.safe_search,
      dedupe: form.dedupe,
      fetch_pages: form.fetch_pages,
      extract_text: form.extract_text,
      summarize: llmReady && form.summarize,
      streaming: false,
      timeout_ms: form.timeout_ms,
      cache_policy: form.cache_policy
    });
  };

  const runResearchRequest = () => {
    const startedAt = Date.now();
    setWorkStartedAt(startedAt);
    setWorkClock(startedAt);
    researchMutation.mutate({
      query: form.query,
      engines: splitCsv(form.engines),
      categories: splitCsv(form.categories),
      language: form.language || null,
      time_range: form.time_range || null,
      page: form.page,
      results_per_page: form.results_per_page,
      max_pages: form.max_pages,
      target_result_count: Math.max(form.target_results, form.top_n),
      safe_search: form.safe_search,
      top_n: form.top_n,
      timeout_ms: form.timeout_ms,
      cache_policy: form.cache_policy,
      provider: form.provider || null,
      streaming: false,
      include_debug_trace: true
    });
  };

  const handleSavePreset = () => {
    const name = window.prompt("Preset name");
    const trimmed = name?.trim();
    if (!trimmed) {
      return;
    }
    const existing = (presetsQuery.data ?? []).find((preset) => preset.name.toLowerCase() === trimmed.toLowerCase());
    if (existing && !window.confirm(`A preset named "${existing.name}" already exists. Save over it with the current search settings?`)) {
      return;
    }
    presetMutation.mutate({ name: trimmed });
  };

  const loadPreset = (preset: SearchPreset) => {
    const request = preset.request as unknown as Record<string, unknown>;
    setForm((current) => formFromPresetRequest(request, current));
  };

  const handleDeletePreset = (preset: SearchPreset) => {
    if (!window.confirm(`Delete preset "${preset.name}"?`)) {
      return;
    }
    deletePresetMutation.mutate(preset.preset_id);
  };

  const handleSetDefaultPreset = (preset: SearchPreset | null) => {
    if (!preset) {
      setDefaultPresetId("");
      window.localStorage.removeItem(DEFAULT_PRESET_KEY);
      window.localStorage.removeItem(DEFAULT_PRESET_FORM_KEY);
      recordActivity({
        kind: "ops",
        title: "Default preset cleared",
        summary: "New sessions will use built-in defaults.",
        payload: {}
      });
      return;
    }
    setDefaultPresetId(preset.preset_id);
    window.localStorage.setItem(DEFAULT_PRESET_KEY, preset.preset_id);
    saveDefaultPresetForm(preset);
    recordActivity({
      kind: "ops",
      title: "Default preset selected",
      summary: preset.name,
      payload: { preset_id: preset.preset_id, name: preset.name }
    });
  };

  const handlePairingTokenChange = (value: string) => {
    setPairingToken(value);
    setStoredPairingToken(value);
  };

  const adjustUiZoom = (delta: number) => {
    setUiZoom((current) => Math.min(MAX_UI_ZOOM, Math.max(MIN_UI_ZOOM, Number((current + delta).toFixed(2)))));
  };

  const snapshotNow = (): SessionSnapshot => ({
    id: sessionId,
    name: sessionName,
    createdAt: loadSessionSnapshot(sessionId)?.createdAt ?? new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    form,
    workspaceTab,
    activityLog,
    searchPayload,
    researchPayload
  });

  const loadSession = (id: string) => {
    const snapshot = loadSessionSnapshot(id);
    if (!snapshot) {
      return;
    }
    if (window.parent && window.parent !== window && id !== sessionId) {
      postDesktopMessage({
        type: "hypersearch.openSavedSession",
        payload: { id: snapshot.id, title: snapshot.name }
      });
      setUtilityPanel(null);
      return;
    }
    setSessionId(snapshot.id);
    setSessionName(snapshot.name);
    setForm(normalizeStoredForm(snapshot.form));
    setWorkspaceTab(snapshot.workspaceTab);
    setActivityLog(snapshot.activityLog);
    setSearchPayload(snapshot.searchPayload ?? null);
    setResearchPayload(snapshot.researchPayload ?? null);
    setSelectedLogId(snapshot.activityLog[0]?.id ?? null);
    setUtilityPanel(null);
  };

  const renameSession = (id: string) => {
    const snapshot = loadSessionSnapshot(id);
    if (!snapshot) {
      return;
    }
    const nextName = window.prompt("Session name", snapshot.name);
    if (!nextName?.trim()) {
      return;
    }
    const updated = { ...snapshot, name: nextName.trim(), updatedAt: new Date().toISOString() };
    persistSessionSnapshot(updated);
    setSessionIndex(loadSessionIndex());
    if (id === sessionId) {
      setSessionName(updated.name);
    }
  };

  const deleteSession = (id: string) => {
    if (!window.confirm("Delete this saved HyperSearch session?")) {
      return;
    }
    window.localStorage.removeItem(sessionStorageKey(id));
    saveSessionIndex(loadSessionIndex().filter((item) => item.id !== id));
    setSessionIndex(loadSessionIndex());
  };

  const exportSession = (snapshot = snapshotNow()) => {
    const xml = buildSessionXml(snapshot, xmlExportOptions);
    const filename = buildExportFilename(snapshot);
    if (window.parent && window.parent !== window) {
      window.parent.postMessage(JSON.stringify({ type: "hypersearch.exportSession", payload: { filename, xml } }), "*");
      recordActivity({
        kind: "ops",
        title: "Session XML export requested",
        summary: filename,
        payload: { filename }
      });
      return;
    }
    const blob = new Blob([xml], { type: "application/xml" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    link.click();
    URL.revokeObjectURL(url);
  };

  const openHelp = () => {
    if (window.parent && window.parent !== window) {
      let acknowledged = false;
      const onHelpAck = (event: MessageEvent) => {
        const data = parseDesktopMessage(event.data);
        if (data?.type === "hypersearch.openHelp.result" && data.ok) {
          acknowledged = true;
          window.removeEventListener("message", onHelpAck);
        }
      };
      window.addEventListener("message", onHelpAck);
      window.parent.postMessage(JSON.stringify({ type: "hypersearch.openHelp" }), "*");
      window.setTimeout(() => {
        window.removeEventListener("message", onHelpAck);
        if (!acknowledged) {
          window.location.assign("/help/index.html");
        }
      }, 350);
      return;
    }
    window.open("/help/index.html", "_blank", "noopener,noreferrer");
  };

  return (
    <div className="shell">
      <header className="hero">
        <div>
          <h1>HyperSearch</h1>
          <p className="hero__copy">
            Search, extract, and synthesize across web results with SearXNG, cached fetches, and local LLM providers.
          </p>
          <p className="session-title-line">Session: <strong>{sessionName}</strong></p>
        </div>
        <div className="hero__controls">
          <div className="signal-row">
            <span className={`signal-pill ${llmReady ? "signal-pill--ok" : "signal-pill--muted"}`}>
              {llmStatusLabel}
            </span>
            <span className="signal-pill signal-pill--muted">
              {presetsQuery.data?.length ?? 0} presets saved
            </span>
            {busy ? <span className="signal-pill signal-pill--running">Request in progress</span> : null}
          </div>
          <div className="hero__buttons">
            {!isEmbedded ? (
              <button type="button" className="button" onClick={openHelp}>
                Help
              </button>
            ) : null}
            <button type="button" className="button" onClick={() => toggleUtilityPanel("ops")}>
              Operations
            </button>
            <button type="button" className="button" onClick={() => toggleUtilityPanel("sessions")}>
              Session Library
            </button>
            <button type="button" className="button" onClick={() => exportSession()}>
              Save Session
            </button>
            <button type="button" className="button" onClick={() => toggleUtilityPanel("log")}>
              Verbose log
              {activityLog.length > 0 ? <span className="button__count">{activityLog.length}</span> : null}
            </button>
            <div className="zoom-control" aria-label="Page zoom">
              <button type="button" onClick={() => adjustUiZoom(-0.05)} disabled={uiZoom <= MIN_UI_ZOOM}>-</button>
              <span>{Math.round(uiZoom * 100)}%</span>
              <button type="button" onClick={() => adjustUiZoom(0.05)} disabled={uiZoom >= MAX_UI_ZOOM}>+</button>
            </div>
            <button
              type="button"
              className="theme-toggle"
              onClick={() => setTheme((current) => (current === "light" ? "dark" : "light"))}
            >
              {theme === "light" ? "Dark mode" : "Light mode"}
            </button>
          </div>
        </div>
      </header>

      <div className={`request-status ${busy ? "request-status--busy" : ""}`}>
        <span className="request-status__dot" />
        <strong>{activeWorkLabel}</strong>
        {busy ? <WaitingDots /> : null}
        <span>{activeWorkDetail}</span>
      </div>

      <main className={searchSettingsExpanded ? "workspace-layout" : "workspace-layout workspace-layout--settings-collapsed"}>
        <div className="workspace-main">
          <SectionCard title="Search" subtitle="Query workbench">
            <SearchCommand
              value={form}
              busy={busy}
              llmEnabled={llmEnabled}
              llmReady={llmReady}
              onChange={(patch) => setForm((current) => ({ ...current, ...patch }))}
              onSearch={runSearchRequest}
              onResearch={runResearchRequest}
            />
          </SectionCard>

          <SectionCard
            title="Answer"
            subtitle="Synthesis"
            actions={(
              <div className="workspace-summary__chips">
                {latestRequestId ? <span className="summary-chip">Req {shortId(latestRequestId)}</span> : null}
                {researchPayload ? <span className="summary-chip">{citationCount(researchPayload)} citations</span> : null}
                {searchPayload ? <span className="summary-chip">{resultCount(searchPayload)} results</span> : null}
              </div>
            )}
          >
            <ResearchPane payload={researchPayload} searchSummary={searchPayload?.summary ?? null} />
          </SectionCard>

          <SectionCard title="Results" subtitle="Collected sources">
            <div className="workspace-summary">
              <div>
                <p className="workspace-summary__label">Latest run</p>
                <strong>{workspaceQuery ?? "Nothing executed yet"}</strong>
              </div>
              <div className="workspace-summary__chips">
                {searchPayload ? <span className="summary-chip">{resultCount(searchPayload)} search hits</span> : null}
                {searchPayload?.summary ? <span className="summary-chip">Search summary ready</span> : null}
              </div>
            </div>
            <SearchResults payload={searchPayload} />
          </SectionCard>
        </div>

        <SearchSettings
          value={form}
          presets={presetsQuery.data ?? []}
          providers={providersQuery.data ?? []}
          exportOptions={xmlExportOptions}
          expanded={searchSettingsExpanded}
          llmEnabled={llmEnabled}
          llmReady={llmReady}
          defaultPresetId={defaultPresetId}
          onChange={(patch) => setForm((current) => ({ ...current, ...patch }))}
          onExpandedChange={setSearchSettingsExpanded}
          onSavePreset={handleSavePreset}
          onLoadPreset={loadPreset}
          onDeletePreset={handleDeletePreset}
          onSetDefaultPreset={handleSetDefaultPreset}
          onExportOptionsChange={(patch) => setXmlExportOptions((current) => ({ ...current, ...patch }))}
        />
      </main>

      {utilityPanel ? <button type="button" className="utility-overlay" aria-label="Close panel" onClick={() => setUtilityPanel(null)} /> : null}

      <aside className={`utility-drawer ${utilityPanel ? "utility-drawer--open" : ""}`} aria-hidden={!utilityPanel}>
        <div className="utility-drawer__header">
          <div>
            <p className="section-card__eyebrow">{utilityPanel === "ops" ? "Providers and cache" : utilityPanel === "sessions" ? "Saved sessions" : "Request diagnostics"}</p>
            <h2>{utilityPanel === "ops" ? "Operations" : utilityPanel === "sessions" ? "Session Library" : "Verbose Log"}</h2>
          </div>
          <button type="button" className="button button--ghost" onClick={() => setUtilityPanel(null)}>
            Close
          </button>
        </div>

        <div className="utility-drawer__body">
          {utilityPanel === "ops" ? (
            <AdminPanel
              providers={providersQuery.data ?? []}
              providerModels={providerModels}
              providerModelsLoading={providerModelsLoading}
              pairingToken={pairingToken}
              lastMessage={adminMessage}
              readiness={readinessQuery.data}
              llmSettings={llmSettingsQuery.data}
              history={historyQuery.data ?? []}
              onPairingTokenChange={handlePairingTokenChange}
              onLlmSettingsChange={(settings) => llmSettingsMutation.mutate(settings)}
              onTestProvider={(draft) => providerTestMutation.mutate(draft)}
              onVerifyProvider={(draft) => providerVerifyMutation.mutate(draft)}
              onDiscoverModels={discoverProviderModels}
              onSetDefaultProvider={(name) => defaultProviderMutation.mutate(name)}
              onUpdateProvider={(name, profile) => providerUpdateMutation.mutate({ name, profile })}
              onInvalidateCache={(namespace) => invalidateMutation.mutate(namespace)}
              onRefreshHistory={() => queryClient.invalidateQueries({ queryKey: ["history"] })}
              onApplyRetention={(days) => retentionMutation.mutate(days)}
            />
          ) : utilityPanel === "sessions" ? (
            <SessionLibrary
              currentSessionId={sessionId}
              sessionName={sessionName}
              sessionIndex={sessionIndex}
              onCurrentSessionNameChange={setSessionName}
              onLoad={loadSession}
              onRename={renameSession}
              onDelete={deleteSession}
              onExport={(id) => {
                const snapshot = id === sessionId ? snapshotNow() : loadSessionSnapshot(id);
                if (snapshot) {
                  exportSession(snapshot);
                }
              }}
            />
          ) : (
            <div className="diagnostics-panel">
              <div className="diagnostics-panel__summary">
                <span className="signal-pill signal-pill--muted">
                  {activityLog.length} recorded events
                </span>
                {searchMutation.error instanceof Error ? (
                  <span className="signal-pill signal-pill--warning">Search error present</span>
                ) : null}
                {researchMutation.error instanceof Error ? (
                  <span className="signal-pill signal-pill--warning">Research error present</span>
                ) : null}
              </div>

              <div className="log-list">
                {activityLog.length === 0 ? <p className="muted">Run a search, synthesis, or admin action to populate the verbose log.</p> : null}
                {activityLog.map((entry) => (
                  <button
                    key={entry.id}
                    type="button"
                    className={`log-item ${selectedLog?.id === entry.id ? "log-item--active" : ""}`}
                    onClick={() => setSelectedLogId(entry.id)}
                  >
                    <span className={`log-item__kind log-item__kind--${entry.kind}`}>{entry.kind}</span>
                    <strong>{entry.title}</strong>
                    <span>{entry.summary}</span>
                    <small>{entry.createdAt}</small>
                  </button>
                ))}
              </div>

              <div className="diagnostics-payload">
                <div className="diagnostics-payload__header">
                  <strong>{selectedLog?.title ?? "No payload selected"}</strong>
                  <span>{selectedLog?.summary ?? "Run something to inspect the payload here."}</span>
                </div>
                <JsonView
                  value={
                    selectedLog?.payload ?? {
                      latestSearchError: searchMutation.error instanceof Error ? searchMutation.error.message : null,
                      latestResearchError: researchMutation.error instanceof Error ? researchMutation.error.message : null
                    }
                  }
                />
              </div>
            </div>
          )}
        </div>
      </aside>
    </div>
  );
}

function WaitingDots() {
  return (
    <span className="waiting-dots" aria-hidden="true">
      <span>.</span>
      <span>.</span>
      <span>.</span>
    </span>
  );
}

function SessionLibrary({
  currentSessionId,
  sessionName,
  sessionIndex,
  onCurrentSessionNameChange,
  onLoad,
  onRename,
  onDelete,
  onExport
}: {
  currentSessionId: string;
  sessionName: string;
  sessionIndex: Array<{ id: string; name: string; updatedAt: string; createdAt: string }>;
  onCurrentSessionNameChange: (value: string) => void;
  onLoad: (id: string) => void;
  onRename: (id: string) => void;
  onDelete: (id: string) => void;
  onExport: (id: string) => void;
}) {
  return (
    <div className="session-library">
      <div className="field">
        <label htmlFor="current-session-name">Current session name</label>
        <input id="current-session-name" value={sessionName} onChange={(event) => onCurrentSessionNameChange(event.target.value)} />
      </div>
      <div className="session-library__actions">
        <button type="button" className="button button--ghost" onClick={() => onExport(currentSessionId)}>Save Current Session</button>
      </div>
      <div className="session-library__list">
        {sessionIndex.length === 0 ? <p className="muted">No saved sessions yet.</p> : null}
        {sessionIndex.map((item) => (
          <article key={item.id} className={`session-library__row ${item.id === currentSessionId ? "session-library__row--active" : ""}`}>
            <div>
              <strong>{item.name}</strong>
              <small>Updated {new Date(item.updatedAt).toLocaleString()}</small>
            </div>
            <div className="session-library__row-actions">
              <button type="button" className="button button--ghost" onClick={() => onLoad(item.id)}>Load</button>
              <button type="button" className="button button--ghost" onClick={() => onRename(item.id)}>Rename</button>
              <button type="button" className="button button--ghost" onClick={() => onExport(item.id)}>Save Session</button>
              <button type="button" className="button button--ghost" onClick={() => onDelete(item.id)}>Delete</button>
            </div>
          </article>
        ))}
      </div>
    </div>
  );
}
