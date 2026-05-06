# HyperSearch Architecture

HyperSearch is split into a backend API, a browser UI, a Windows-first desktop launcher, and deployment assets that keep search orchestration independent from any future MCP adapter.

## Backend

- `hypersearch_api.main` wires FastAPI, middleware, request IDs, JSON logging, and metrics.
- `lifespan.py` performs startup/shutdown, SQLite WAL setup, cache initialization, provider registration, and service assembly.
- `services/search_service.py` owns the search pipeline:
  search normalization -> SearXNG query -> dedupe/rank -> optional fetch -> optional extraction -> optional synthesis.
- `services/research_service.py` composes search plus synthesis into a citation-bearing research answer.
- `services/cache_service.py` isolates hot cache behavior and can use in-memory fallback or Valkey.
- `providers/llm/*` exposes a local OpenAI-compatible adapter layer with LM Studio as the default.
- LAN access is disabled by default. When enabled by the desktop launcher, non-local clients must send a pairing token.

## Storage

- SQLite stores durable provider config, presets, and request history.
- Valkey is used for hot cache and request coalescing when configured.
- Search payloads, fetched pages, extracted content, and synthesized outputs are cached under separate namespaces.

## Frontend

- React + TanStack Query drive the first-party console.
- The UI is intentionally thin: it speaks to the same REST surface expected to be used by external agents or tools.
- Raw JSON remains visible so debugging agent integrations does not require browser devtools.

## Desktop Launcher

- `apps/desktop` is a Tauri + React launcher for Windows-first 1.0 packaging.
- It checks Docker Desktop and LM Studio, starts/stops the Compose stack, opens the browser console, displays logs, and manages LAN pairing settings.
- Docker remains the managed backend runtime for 1.0; non-Docker service bundling is deferred.
