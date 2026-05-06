import type { SearchResponse } from "../../lib/api";
import { MarkdownAnswer } from "../research/ResearchPane";

interface SearchResultsProps {
  payload?: SearchResponse | null;
}

export function SearchResults({ payload }: SearchResultsProps) {
  if (!payload) {
    return <p className="muted">Search results will land here after the first run.</p>;
  }

  const results = Array.isArray(payload.results) ? payload.results : [];
  const cache = payload.cache && typeof payload.cache === "object" ? payload.cache : {};
  const cacheSummary = Object.entries(cache).map(([key, value]) => `${key}:${String(value)}`).join(" - ");
  const requestId = payload.request_id || "unknown-request";
  const resultCount = Number.isFinite(payload.result_count) ? payload.result_count : results.length;

  return (
    <div className="result-stack">
      <div className="result-summary">
        <div className="result-summary__primary">
          <strong>{resultCount}</strong> results
          <span className="summary-chip">Req {requestId.slice(0, 8)}</span>
          {payload.summary ? <span className="summary-chip">Summary ready</span> : null}
        </div>
        <div className="summary-chip">Cache {cacheSummary || "not reported"}</div>
      </div>
      {payload.summary ? (
        <article className="summary-panel">
          <h3>Summary</h3>
          <MarkdownAnswer value={payload.summary} />
        </article>
      ) : null}
      {results.map((result, index) => (
        <article key={result.url || `result-${index}`} id={`source-${index + 1}`} className="result-card">
          <div className="result-card__meta">
            <span className="result-badge">Source {index + 1}</span>
            <span className="result-badge">{result.engine ?? "engine-unknown"}</span>
            {result.published_date ? <span className="result-badge">{result.published_date}</span> : null}
            <span className="result-badge">{result.fetched ? "Fetched" : "Unfetched"}</span>
            <span className="result-badge">{result.extracted ? "Extracted" : "Raw"}</span>
          </div>
          <h3>{result.title || "Untitled result"}</h3>
          {result.url ? (
            <a href={result.url} target="_blank" rel="noreferrer">
              {result.url}
            </a>
          ) : null}
          {result.snippet ? <p>{result.snippet}</p> : null}
          {result.content ? <div className="result-card__content">{result.content.slice(0, 600)}{result.content.length > 600 ? "..." : ""}</div> : null}
        </article>
      ))}
    </div>
  );
}
