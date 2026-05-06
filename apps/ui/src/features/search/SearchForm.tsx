import { ChangeEvent, KeyboardEvent } from "react";

import type { ProviderInfo, SearchPreset } from "../../lib/api";

export interface SearchFormState {
  query: string;
  engines: string;
  categories: string;
  language: string;
  time_range: string;
  page: number;
  results_per_page: number;
  max_pages: number;
  safe_search: number;
  dedupe: boolean;
  fetch_pages: boolean;
  extract_text: boolean;
  summarize: boolean;
  auto_name_session: boolean;
  top_n: number;
  timeout_ms: number;
  cache_policy: "use" | "bypass" | "refresh" | "only-if-cached";
  provider: string;
}

interface SearchCommandProps {
  value: SearchFormState;
  busy: boolean;
  onChange: (patch: Partial<SearchFormState>) => void;
  onSearch: () => void;
  onResearch: () => void;
}

interface SearchSettingsProps {
  value: SearchFormState;
  presets: SearchPreset[];
  providers: ProviderInfo[];
  exportOptions: XmlExportOptions;
  expanded: boolean;
  onChange: (patch: Partial<SearchFormState>) => void;
  onExpandedChange: (expanded: boolean) => void;
  onSavePreset: () => void;
  onLoadPreset: (preset: SearchPreset) => void;
  onDeletePreset: (preset: SearchPreset) => void;
  onSetDefaultPreset: (preset: SearchPreset | null) => void;
  onExportOptionsChange: (patch: Partial<XmlExportOptions>) => void;
  defaultPresetId: string;
}

interface XmlExportOptions {
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

const MAX_RESULTS = 250;
const RESULTS_PER_PAGE_LIMIT = 50;
const ENGINE_OPTIONS = [
  "bing",
  "brave",
  "duckduckgo",
  "google",
  "mojeek",
  "presearch",
  "qwant",
  "startpage",
  "wikipedia"
];
const CATEGORY_OPTIONS = ["general", "news", "science", "it", "images", "videos", "files", "social media", "map"];
const LANGUAGE_OPTIONS = ["en-US", "en", "fr", "de", "es", "it", "pt", "ja", "ko", "zh"];

function clampNumber(value: number, min: number, max: number) {
  if (!Number.isFinite(value)) {
    return min;
  }
  return Math.min(max, Math.max(min, Math.round(value)));
}

function pagingForTotal(total: number) {
  const bounded = clampNumber(total, 1, MAX_RESULTS);
  return {
    page: 1,
    results_per_page: Math.min(RESULTS_PER_PAGE_LIMIT, bounded),
    max_pages: Math.ceil(bounded / RESULTS_PER_PAGE_LIMIT)
  };
}

function totalResults(value: SearchFormState) {
  return clampNumber(value.results_per_page * value.max_pages, 1, MAX_RESULTS);
}

export function SearchCommand({
  value,
  busy,
  onChange,
  onSearch,
  onResearch
}: SearchCommandProps) {
  const handleQueryChange = (event: ChangeEvent<HTMLInputElement>) => {
    onChange({ query: event.target.value });
  };

  const handleQueryKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    if (event.key !== "Enter") {
      return;
    }
    event.preventDefault();
    if (busy || !value.query.trim()) {
      return;
    }
    if (event.ctrlKey || event.metaKey) {
      onResearch();
      return;
    }
    onSearch();
  };

  return (
    <div className="search-command">
      <div className="field field--wide">
        <label htmlFor="query">Query</label>
        <input
          id="query"
          name="query"
          value={value.query}
          onChange={handleQueryChange}
          onKeyDown={handleQueryKeyDown}
          placeholder="Ask a question or search for a topic"
        />
      </div>
      <div className="button-row">
        <button type="button" className="button button--primary" onClick={onSearch} disabled={busy || !value.query.trim()}>
          {busy ? "Working..." : "Run Search"}
        </button>
        <button type="button" className="button" onClick={onResearch} disabled={busy || !value.query.trim()}>
          Research Synthesis
        </button>
      </div>
      <p className="muted">Enter searches. Ctrl+Enter runs research synthesis with the selected local model.</p>
    </div>
  );
}

export function SearchSettings({
  value,
  presets,
  providers,
  exportOptions,
  expanded,
  onChange,
  onExpandedChange,
  onSavePreset,
  onLoadPreset,
  onDeletePreset,
  onSetDefaultPreset,
  onExportOptionsChange,
  defaultPresetId
}: SearchSettingsProps) {
  const handleText = (event: ChangeEvent<HTMLInputElement | HTMLSelectElement>) => {
    const { name, value: nextValue } = event.target;
    if (name === "safe_search" || name === "timeout_ms") {
      onChange({ [name]: Number(nextValue) } as Partial<SearchFormState>);
      return;
    }
    if (name === "total_results") {
      const paging = pagingForTotal(Number(nextValue));
      onChange({
        ...paging,
        top_n: Math.min(Math.max(value.top_n, 1), paging.results_per_page * paging.max_pages)
      });
      return;
    }
    if (name === "top_n") {
      const nextTopN = clampNumber(Number(nextValue), 1, MAX_RESULTS);
      onChange({
        top_n: nextTopN,
        ...(nextTopN > totalResults(value) ? pagingForTotal(nextTopN) : {})
      });
      return;
    }
    onChange({ [name]: nextValue } as Partial<SearchFormState>);
  };

  const handleToggle = (event: ChangeEvent<HTMLInputElement>) => {
    const { name, checked } = event.target;
    onChange({ [name]: checked } as Partial<SearchFormState>);
  };

  const handleExportToggle = (event: ChangeEvent<HTMLInputElement>) => {
    const { name, checked } = event.target;
    onExportOptionsChange({ [name]: checked } as Partial<XmlExportOptions>);
  };

  return (
    <aside className={expanded ? "search-settings-panel" : "search-settings-panel search-settings-panel--collapsed"}>
      <div className="settings-panel__header">
        <div>
          <p className="section-card__eyebrow">Options</p>
          <h2>Search Settings</h2>
        </div>
        <button type="button" className="button button--ghost settings-collapse-button" onClick={() => onExpandedChange(!expanded)}>
          {expanded ? "Collapse" : "Expand"}
        </button>
      </div>

      {!expanded ? (
        <div className="settings-compact-summary">
          <span>{totalResults(value)} results</span>
          <span>{value.top_n} research sources</span>
          <span>{value.safe_search === 0 ? "Safe search off" : value.safe_search === 1 ? "Moderate safe search" : "Strict safe search"}</span>
        </div>
      ) : null}

      {expanded ? <div className="settings-group">
        <div className="field">
          <label htmlFor="total_results">Results to Collect</label>
          <input id="total_results" name="total_results" type="number" min={1} max={MAX_RESULTS} value={totalResults(value)} onChange={handleText} />
          <small>HyperSearch fetches enough backend pages to collect this many results.</small>
        </div>
        <div className="field">
          <label htmlFor="top_n">Research Sources</label>
          <input id="top_n" name="top_n" type="number" min={1} max={MAX_RESULTS} value={value.top_n} onChange={handleText} />
          <small>Research uses up to this many collected results.</small>
        </div>
        <div className="field">
          <label htmlFor="safe_search">Safe Search</label>
          <select id="safe_search" name="safe_search" value={value.safe_search} onChange={handleText}>
            <option value={0}>Off</option>
            <option value={1}>Moderate</option>
            <option value={2}>Strict</option>
          </select>
        </div>
        <div className="field">
          <label htmlFor="cache_policy">Cache Policy</label>
          <select id="cache_policy" name="cache_policy" value={value.cache_policy} onChange={handleText}>
            <option value="use">Use cache</option>
            <option value="bypass">Bypass cache</option>
            <option value="refresh">Refresh cache</option>
            <option value="only-if-cached">Only if cached</option>
          </select>
        </div>
      </div> : null}

      {expanded ? <div className="toggle-row toggle-row--settings">
        <label><input type="checkbox" name="dedupe" checked={value.dedupe} onChange={handleToggle} /> Dedupe</label>
        <label><input type="checkbox" name="fetch_pages" checked={value.fetch_pages} onChange={handleToggle} /> Fetch pages</label>
        <label><input type="checkbox" name="extract_text" checked={value.extract_text} onChange={handleToggle} /> Extract text</label>
        <label><input type="checkbox" name="summarize" checked={value.summarize} onChange={handleToggle} /> Search summary</label>
        <label><input type="checkbox" name="auto_name_session" checked={value.auto_name_session} onChange={handleToggle} /> Auto-name session</label>
      </div> : null}

      {expanded ? <details className="advanced-panel">
        <summary>Advanced filters and provider controls</summary>
        <div className="advanced-panel__body">
          <div className="settings-group">
            <div className="field">
              <label htmlFor="engines">Engines</label>
              <input id="engines" name="engines" list="engine-options" value={value.engines} onChange={handleText} placeholder="google,duckduckgo" />
            </div>
            <div className="field">
              <label htmlFor="categories">Categories</label>
              <input id="categories" name="categories" list="category-options" value={value.categories} onChange={handleText} placeholder="general,news" />
            </div>
            <div className="field">
              <label htmlFor="language">Language</label>
              <input id="language" name="language" list="language-options" value={value.language} onChange={handleText} placeholder="en-US" />
            </div>
            <div className="field">
              <label htmlFor="time_range">Date Range</label>
              <select id="time_range" name="time_range" value={value.time_range} onChange={handleText}>
                <option value="">Any time</option>
                <option value="day">Past day</option>
                <option value="week">Past week</option>
                <option value="month">Past month</option>
                <option value="year">Past year</option>
              </select>
              <small>Limits result recency when the selected search engine supports it.</small>
            </div>
            <div className="field">
              <label htmlFor="provider">Provider Override</label>
              <input id="provider" name="provider" list="provider-options" value={value.provider} onChange={handleText} placeholder="lmstudio" />
            </div>
            <div className="field">
              <label htmlFor="timeout_ms">Timeout (ms)</label>
              <input id="timeout_ms" name="timeout_ms" type="number" min={1000} step={500} value={value.timeout_ms} onChange={handleText} />
            </div>
          </div>
          <datalist id="engine-options">
            {ENGINE_OPTIONS.map((option) => <option key={option} value={option} />)}
          </datalist>
          <datalist id="category-options">
            {CATEGORY_OPTIONS.map((option) => <option key={option} value={option} />)}
          </datalist>
          <datalist id="language-options">
            {LANGUAGE_OPTIONS.map((option) => <option key={option} value={option} />)}
          </datalist>
          <datalist id="provider-options">
            {providers.map((provider) => <option key={provider.name} value={provider.name}>{provider.display_name ?? provider.name}</option>)}
          </datalist>
        </div>
      </details> : null}

      {expanded ? <details className="advanced-panel">
        <summary>XML export contents</summary>
        <div className="advanced-panel__body">
          <p className="muted">Choose which saved session fields are written into exported XML files.</p>
          <div className="toggle-row toggle-row--settings">
            <label><input type="checkbox" name="metadata" checked={exportOptions.metadata} onChange={handleExportToggle} /> Session metadata</label>
            <label><input type="checkbox" name="question" checked={exportOptions.question} onChange={handleExportToggle} /> Question</label>
            <label><input type="checkbox" name="searchResults" checked={exportOptions.searchResults} onChange={handleExportToggle} /> Search results</label>
            <label><input type="checkbox" name="fullText" checked={exportOptions.fullText} onChange={handleExportToggle} /> Full text</label>
            <label><input type="checkbox" name="summaries" checked={exportOptions.summaries} onChange={handleExportToggle} /> Summaries</label>
            <label><input type="checkbox" name="researchAnswer" checked={exportOptions.researchAnswer} onChange={handleExportToggle} /> Research answer</label>
            <label><input type="checkbox" name="citations" checked={exportOptions.citations} onChange={handleExportToggle} /> Research sources</label>
            <label><input type="checkbox" name="activityLog" checked={exportOptions.activityLog} onChange={handleExportToggle} /> Activity log</label>
            <label><input type="checkbox" name="providerTrace" checked={exportOptions.providerTrace} onChange={handleExportToggle} /> Provider trace</label>
          </div>
        </div>
      </details> : null}

      {expanded ? <div className="preset-list">
        <div className="preset-list__header">
          <span>Saved presets</span>
          <span>{presets.length}</span>
        </div>
        <button type="button" className="button button--ghost" onClick={onSavePreset}>
          Save Preset
        </button>
        {presets.length === 0 ? <p className="muted">No presets saved yet.</p> : null}
        {presets.map((preset) => (
          <article key={preset.preset_id} className={preset.preset_id === defaultPresetId ? "preset-row preset-row--default" : "preset-row"}>
            <button className="preset-chip" type="button" onClick={() => onLoadPreset(preset)}>
              {preset.name}
            </button>
            <div className="preset-row__actions">
              <button type="button" className="mini-button" onClick={() => onSetDefaultPreset(preset)}>
                {preset.preset_id === defaultPresetId ? "Default" : "Set default"}
              </button>
              <button type="button" className="mini-button" onClick={() => onDeletePreset(preset)}>
                Delete
              </button>
            </div>
          </article>
        ))}
        {defaultPresetId ? (
          <button type="button" className="button button--ghost" onClick={() => onSetDefaultPreset(null)}>
            Clear Default Preset
          </button>
        ) : null}
      </div> : null}
    </aside>
  );
}
