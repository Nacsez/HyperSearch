import { Component, ReactNode } from "react";

import type { ResearchResponse } from "../../lib/api";

interface ResearchPaneProps {
  payload?: ResearchResponse | null;
  searchSummary?: string | null;
}

function normalizeMarkdown(value: unknown) {
  return String(value ?? "")
    .replace(/\s+---\s+/g, "\n\n---\n\n")
    .replace(/\s+(#{2,4}\s+)/g, "\n\n$1")
    .replace(/\s+\*\s+(?=\*\*)/g, "\n- ")
    .replace(/\s+(\d+\.\s+\*\*)/g, "\n$1")
    .replace(/^\*\*Brief (conclusion|response):?\*\*\s*/i, "")
    .replace(/^Brief (conclusion|response):?\s*/i, "")
    .trim();
}

function subscriptDigits(value: string) {
  const map: Record<string, string> = {
    "0": "0",
    "1": "1",
    "2": "2",
    "3": "3",
    "4": "4",
    "5": "5",
    "6": "6",
    "7": "7",
    "8": "8",
    "9": "9"
  };
  return value.replace(/_\{?([0-9]+)\}?/g, (_, digits: string) => digits.split("").map((digit) => map[digit] ?? digit).join(""));
}

function texToPlainText(value: string) {
  return value
    .replace(/\$\$/g, "")
    .replace(/\$/g, "")
    .replace(/\\\[/g, "")
    .replace(/\\\]/g, "")
    .replace(/\\\(/g, "")
    .replace(/\\\)/g, "")
    .replace(/\\xrightarrow\{\\text\{([^}]+)\}\}/g, " ->[$1] ")
    .replace(/\\xrightarrow\{([^}]+)\}/g, " ->[$1] ")
    .replace(/\\rightarrow/g, " -> ")
    .replace(/\\Rightarrow/g, " => ")
    .replace(/\\to/g, " -> ")
    .replace(/\\leftrightarrow/g, " <-> ")
    .replace(/\\times/g, " x ")
    .replace(/\\cdot/g, " * ")
    .replace(/\\frac\{([^}]+)\}\{([^}]+)\}/g, "($1)/($2)")
    .replace(/\\text\{([^}]*)\}/g, "$1")
    .replace(/\\mathrm\{([^}]*)\}/g, "$1")
    .replace(/\\mathbf\{([^}]*)\}/g, "$1")
    .replace(/\\ce\{([^}]*)\}/g, "$1")
    .replace(/\\,/g, " ")
    .replace(/~/g, " ")
    .replace(/[{}]/g, "")
    .replace(/\\/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

function MathText({ value }: { value: string }) {
  return <div className="math-text">{subscriptDigits(texToPlainText(value))}</div>;
}

class MarkdownErrorBoundary extends Component<{ value: unknown; children: ReactNode }, { error: string | null }> {
  state = { error: null };

  static getDerivedStateFromError(error: unknown) {
    return { error: error instanceof Error ? error.message : String(error) };
  }

  render() {
    if (this.state.error) {
      return (
        <pre className="markdown-fallback">
          {String(this.props.value ?? "The research answer could not be rendered.")}
        </pre>
      );
    }
    return this.props.children;
  }
}

function renderInlineMarkdown(value: string) {
  const parts = value.split(/(\\\[.*?\\\]|\\\(.*?\\\)|\$\$.*?\$\$|\$[^$]+\$|`[^`]+`|\[[0-9]+\]|\*\*[^*]+\*\*)/g).filter(Boolean);
  return parts.map((part, index) => {
    if (/^(\\\[.*\\\]|\\\(.*\\\)|\$\$.*\$\$|\$[^$]+\$)$/.test(part)) {
      return <span key={`${part}-${index}`} className="math-inline">{subscriptDigits(texToPlainText(part))}</span>;
    }
    const citation = part.match(/^\[([0-9]+)\]$/);
    if (citation) {
      return (
        <a key={`${part}-${index}`} className="citation-link" href={`#source-${citation[1]}`}>
          {part}
        </a>
      );
    }
    if (part.startsWith("**") && part.endsWith("**")) {
      return <strong key={`${part}-${index}`}>{part.slice(2, -2)}</strong>;
    }
    if (part.startsWith("`") && part.endsWith("`")) {
      return <code key={`${part}-${index}`}>{part.slice(1, -1)}</code>;
    }
    return part;
  });
}

function splitTableRow(value: string) {
  return value
    .replace(/^\|/, "")
    .replace(/\|$/, "")
    .split("|")
    .map((cell) => cell.trim());
}

function isTableRow(value: string) {
  return value.includes("|") && splitTableRow(value).filter(Boolean).length >= 2;
}

function isTableSeparator(value: string) {
  return /^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?$/.test(value);
}

function looksLikeStandaloneHeading(value: string) {
  const text = value.replace(/\*\*/g, "").trim();
  return text.length > 2 && text.length <= 54 && !/[.!?]$/.test(text) && /^[A-Z0-9]/.test(text);
}

export function MarkdownAnswer({ value }: { value: unknown }) {
  const normalized = normalizeMarkdown(value || "No answer returned.");
  const blocks = normalized.split(/\n{2,}/).filter((block) => block.trim());

  return (
    <div className="markdown-body">
      {blocks.map((block, index) => {
        const trimmed = block.trim();
        if (trimmed === "---") {
          return <hr key={`hr-${index}`} />;
        }
        if (/^(\\\[|\\\(|\$\$|\$)|\\text\{|\\xrightarrow|\\rightarrow|\\ce\{/.test(trimmed)) {
          return <MathText key={`math-${index}`} value={trimmed} />;
        }
        const heading = trimmed.match(/^(#{2,4})\s+(.+)$/);
        if (heading) {
          const level = Math.min(4, Math.max(3, heading[1].length + 1));
          const Tag = `h${level}` as keyof JSX.IntrinsicElements;
          return <Tag key={`heading-${index}`}>{renderInlineMarkdown(heading[2])}</Tag>;
        }
        const lines = trimmed.split("\n").map((line) => line.trim()).filter(Boolean);
        const tableLines = lines.filter((line) => !isTableSeparator(line));
        if (tableLines.length >= 2 && tableLines.every(isTableRow)) {
          const [header, ...rows] = tableLines.map(splitTableRow);
          return (
            <div key={`table-wrap-${index}`} className="markdown-table-wrap">
              <table className="markdown-table">
                <thead>
                  <tr>{header.map((cell, cellIndex) => <th key={`h-${cellIndex}`}>{renderInlineMarkdown(cell)}</th>)}</tr>
                </thead>
                <tbody>
                  {rows.map((row, rowIndex) => (
                    <tr key={`r-${rowIndex}`}>
                      {row.map((cell, cellIndex) => <td key={`c-${rowIndex}-${cellIndex}`}>{renderInlineMarkdown(cell)}</td>)}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          );
        }
        if (lines.every((line) => /^[-*]\s+/.test(line))) {
          return (
            <ul key={`list-${index}`}>
              {lines.map((line, itemIndex) => (
                <li key={`${index}-${itemIndex}`}>{renderInlineMarkdown(line.replace(/^[-*]\s+/, ""))}</li>
              ))}
            </ul>
          );
        }
        if (lines.every((line) => /^\d+\.\s+/.test(line))) {
          return (
            <ol key={`ordered-${index}`}>
              {lines.map((line, itemIndex) => (
                <li key={`${index}-${itemIndex}`}>{renderInlineMarkdown(line.replace(/^\d+\.\s+/, ""))}</li>
              ))}
            </ol>
          );
        }
        if (lines.length > 1) {
          return (
            <div key={`lines-${index}`} className="markdown-lines">
              {lines.map((line, lineIndex) => (
                looksLikeStandaloneHeading(line)
                  ? <h3 key={`${index}-${lineIndex}`}>{renderInlineMarkdown(line)}</h3>
                  : <p key={`${index}-${lineIndex}`}>{renderInlineMarkdown(line)}</p>
              ))}
            </div>
          );
        }
        return <p key={`p-${index}`}>{renderInlineMarkdown(trimmed.replace(/\n/g, " "))}</p>;
      })}
    </div>
  );
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function asNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function firstNumber(...values: unknown[]): number | null {
  for (const value of values) {
    const parsed = asNumber(value);
    if (parsed !== null) {
      return parsed;
    }
  }
  return null;
}

function displayMetricValue(value: unknown) {
  if (typeof value === "string" && value.trim()) {
    return value;
  }
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(value);
  }
  if (typeof value === "boolean") {
    return value ? "Yes" : "No";
  }
  return "n/a";
}

function providerReadinessSummary(value: unknown): string | null {
  const readiness = asRecord(value);
  if (!Object.keys(readiness).length) {
    return null;
  }
  const model = readiness.model ?? readiness.preferred_model ?? readiness.selected_model;
  const provider = readiness.provider ?? readiness.name;
  const ready = readiness.ready ?? readiness.ok ?? readiness.generation_ok;
  const detail = readiness.detail ?? readiness.message ?? readiness.error;
  const state = typeof ready === "boolean" ? (ready ? "Ready" : "Not ready") : "Checked";
  return [state, provider, model, detail].filter((item) => typeof item === "string" && item.trim()).join(" · ");
}

function researchStepsSummary(value: unknown): string | null {
  const steps = asRecord(value);
  if (!Object.keys(steps).length) {
    return null;
  }
  const summaryMeta = asRecord(steps.summary_meta);
  const failedBatches = Array.isArray(summaryMeta.failed_batches) ? summaryMeta.failed_batches.length : 0;
  const fragments = [
    firstNumber(steps.source_count) !== null ? `${firstNumber(steps.source_count)} sources` : null,
    firstNumber(steps.synopsis_count) !== null ? `${firstNumber(steps.synopsis_count)} synopsis batch${firstNumber(steps.synopsis_count) === 1 ? "" : "es"}` : null,
    summaryMeta.compact_mode === true ? "compact mode" : null,
    failedBatches ? `${failedBatches} fallback batch${failedBatches === 1 ? "" : "es"}` : null
  ].filter(Boolean);
  return fragments.length ? fragments.join(" · ") : null;
}

export function ResearchPane({ payload, searchSummary }: ResearchPaneProps) {
  if (!payload) {
    if (searchSummary) {
      return (
        <article className="summary-panel">
          <h3>Search Summary</h3>
          <MarkdownErrorBoundary value={searchSummary}>
            <MarkdownAnswer value={searchSummary} />
          </MarkdownErrorBoundary>
        </article>
      );
    }
    return <p className="muted">Run research synthesis to generate an answer with citations.</p>;
  }

  const citations = Array.isArray(payload.citations) ? payload.citations : [];
  const trace = asRecord(payload.trace);
  const rawSearch = payload.raw_search ?? null;
  const requestId = payload.request_id || "n/a";
  const searchSourcesRequested = firstNumber(
    trace.search_target_result_count,
    rawSearch?.debug?.target_result_count,
    rawSearch?.result_count
  );
  const searchSourcesRetrieved = firstNumber(
    trace.search_result_count,
    rawSearch?.result_count,
    rawSearch?.results?.length
  );
  const researchSourcesRequested = firstNumber(
    trace.requested_source_count,
    trace.research_source_target_count,
    citations.length
  );
  const researchSourcesRetrieved = firstNumber(
    trace.research_sources_retrieved,
    trace.document_count,
    citations.length
  );
  const providerError = typeof trace.provider_error === "string" && trace.provider_error.trim() ? trace.provider_error : null;
  const providerStatus = providerReadinessSummary(trace.provider_readiness);
  const stepsSummary = researchStepsSummary(trace.research_steps);
  const metricItems = [
    { label: "Request", value: requestId.slice(0, 8) },
    { label: "Mode", value: trace.mode },
    { label: "Provider", value: trace.provider },
    { label: "Model", value: trace.model },
    { label: "Search Sources Requested", value: searchSourcesRequested },
    { label: "Search Sources Retrieved", value: searchSourcesRetrieved },
    { label: "Research Sources Requested", value: researchSourcesRequested },
    { label: "Research Sources Retrieved", value: researchSourcesRetrieved },
    { label: "Research Source Shortfall", value: trace.source_shortfall },
    { label: "Provider Status", value: providerStatus },
    { label: "Research Steps", value: stepsSummary },
    { label: "Provider Error", value: providerError }
  ].filter((item) => item.value !== null && item.value !== undefined && item.value !== "");

  return (
    <div className="research-pane">
      <article className="summary-panel">
        <MarkdownErrorBoundary value={payload.answer}>
          <MarkdownAnswer value={payload.answer} />
        </MarkdownErrorBoundary>
      </article>
      <div className="citation-stack citation-stack--compact">
        <h3>Sources Used</h3>
        {citations.length === 0 ? <p className="muted">No citations returned.</p> : null}
        {citations.map((citation) => (
          <article key={`${citation.index}-${citation.url}`} id={`citation-${citation.index}`} className="citation-card">
            <a className="citation-card__index" href={`#source-${citation.index}`}>[{citation.index}]</a>
            <div>
              <strong>{citation.title}</strong>
              <a href={citation.url} target="_blank" rel="noreferrer">
                {citation.url}
              </a>
              {citation.excerpt ? <p>{citation.excerpt}</p> : null}
            </div>
          </article>
        ))}
      </div>
      <div className="trace-grid">
        {metricItems.map((item) => (
          <div key={item.label} className="trace-item">
            <span>{item.label}</span>
            <strong>{displayMetricValue(item.value)}</strong>
          </div>
        ))}
      </div>
      <details className="trace-details">
        <summary>Debug trace</summary>
        <article className="trace-panel">
          <pre>{JSON.stringify(payload.trace ?? {}, null, 2)}</pre>
        </article>
      </details>
    </div>
  );
}
