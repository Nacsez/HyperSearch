# API Overview

## Search

- `POST /v1/search`
  - Parameters include query, engines, categories, language, time range, paging, dedupe, fetch/extract flags, summarize, timeout, streaming, and cache policy.
  - When `streaming=true`, the endpoint responds as Server-Sent Events.
  - The UI field **Results to Collect** maps to `page=1`, `results_per_page<=50`, and `max_pages<=5`. The current backend bound is 250 collected results.

## Research

- `POST /v1/research`
  - Runs search, fetches/extracts top results, then synthesizes an answer with citations and a trace payload.
  - Supports provider override and SSE streaming mode.
  - Requires a reachable local provider and verifies the saved preferred model before synthesis.
  - The UI field **Research Sources** maps to `top_n`, currently bounded from 1 to 250.

## Providers

- `GET /v1/providers`
- `POST /v1/providers/test`
- `POST /v1/providers/default`
- `PATCH /v1/providers/{name}`
- `POST /v1/providers/{name}/verify-model`

Provider profiles store local endpoint, provider type, preferred model, display name, enabled state, and default state. They do not store cloud API keys.

## Operations

- `GET /v1/health`
- `GET /v1/live`
- `GET /v1/ready`
- `GET /v1/metrics`
- `POST /v1/admin/cache/invalidate`
- `POST /v1/admin/maintenance/vacuum`
- `GET /v1/search/presets`
- `POST /v1/search/presets`

## History

- `GET /v1/history`
- `GET /v1/history/export`
- `DELETE /v1/history/{history_id}`
- `POST /v1/history/retention`

## Access

Localhost requests are allowed. LAN requests are disabled unless the desktop launcher enables LAN mode and writes a pairing token. Paired LAN clients send `X-HyperSearch-Token` or `Authorization: Bearer <token>`.

## Headless PowerShell Helper

Use `scripts/Invoke-HyperSearch.cmd` when you want command-line access without hand-writing JSON:

```powershell
.\scripts\Invoke-HyperSearch.cmd -Action search -Query "history of cincinnati ohio" -Results 10 -Summarize
.\scripts\Invoke-HyperSearch.cmd -Action research -Query "origin of ronald mcdonald" -Results 25 -ResearchSources 5 -TimeoutMs 60000
.\scripts\Invoke-HyperSearch.cmd -Action provider-models -ProviderName lmstudio
.\scripts\Invoke-HyperSearch.cmd -Action history-export
```

Supported actions are `ready`, `health`, `search`, `research`, `providers`, `provider-models`, `set-provider`, `default-provider`, `history`, `history-export`, and `retention`.

## Session XML Export

Session XML is built by the browser UI and can include metadata, question, search results, fetched full text, summaries, research answer, research sources, activity log, and provider trace. Embedded desktop sessions send export payloads to the desktop shell; browser-only sessions download the XML directly.
