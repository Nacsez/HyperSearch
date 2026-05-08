# Operations

## Logging

- Logs are emitted as JSON.
- Request IDs and trace IDs are included on every request.
- Common secret-bearing headers are redacted before structured logging.
- Desktop and installer command logs are written separately from the event timeline so Docker/Compose stdout and stderr are preserved for diagnosis.
- Desktop diagnostics export redacts token, key, password, auth, and credential values across env files, Compose output, command logs, copied desktop logs, Docker status, and recent service logs.

## Metrics

- `GET /v1/metrics` exports a Prometheus-compatible text payload.
- The current baseline records request counts and durations.
- Metrics are protected by local/LAN pairing-token access rules.

## Health

- `GET /v1/live` reports process liveness.
- `GET /v1/ready` reports search-core readiness for SearXNG and cache, plus separate `capabilities.search` and `capabilities.llm` details.
- `GET /v1/health` remains a detailed compatibility endpoint and may report degraded status when dependencies are unavailable.

## Cache

- Namespaces:
  - `search`
  - `page`
  - `extract`
  - `synthesis`
  - `research`
- Admin cache invalidation works by namespace.

## History

- Durable history is stored in SQLite.
- Raw prompts are not stored unless debug prompt persistence is explicitly enabled.
- History can be listed, exported, deleted by record ID, or pruned by retention window through `/v1/history`.

## Local Providers

- 1.0 supports local OpenAI-compatible providers only: LM Studio, local vLLM, and local llama.cpp.
- Provider profiles contain endpoint, preferred model, display name, enabled state, and default state.
- Search-only is valid. `GET/PATCH /v1/admin/llm` controls app-level LLM usage locally; provider discovery/testing can still contact local endpoints while LLM usage is globally off.
- Research verifies that the default or requested local model is available before synthesis. If LLM is disabled or unavailable, `/v1/research` returns source-review fallback with `trace.mode="search-only-fallback"`.

## Installer Operations

- Release startup uses prebuilt images and does not build on the user machine.
- Caddy, Valkey, and SearXNG release images are pinned to exact tags. Full media loads image archives with `docker load` and includes image digest manifests.
- Online media runs `docker compose pull` and reports registry, DNS, proxy, or private-image failures before setup claims success.
- Installer setup records WSL status before/after and runs `wsl --update` before Docker image setup. If Windows requires elevation, setup requests an elevated WSL update and records the result.
- Docker readiness requires a clean server-version response, not just any Docker command output.
- Docker doctor output includes local/user Docker config permission checks, Docker context, named-pipe access, Docker Desktop service state, and `docker-users` group membership remediation.
