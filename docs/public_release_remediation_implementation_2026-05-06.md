# Public Release Remediation Implementation Notes

Date: 2026-05-06

## Scope

This implementation pass addressed the High and Medium release-readiness gaps from the public release remediation plan:

- search-only as a supported operating mode
- app-level LLM enable/disable state
- search readiness independent from LLM readiness
- research source-review fallback when LLM is disabled or unavailable
- draft provider model discovery/test/verify
- paired-token and proxy trust hardening
- desktop diagnostics redaction
- structured desktop Docker readiness
- Docker doctor output
- pinned release image references
- installer media digest/signature hardening
- updated operator docs and release gates

## Implemented Changes

### Backend

- Added SQLite `app_settings` migration and persisted `llm_enabled` / `llm_disabled_reason`.
- Seeded LLM state from `HYPERSEARCH_LLM_ENABLED=false` and compatibility value `HYPERSEARCH_RESEARCH_CAPABILITY=search-only`.
- Added local-only `GET /v1/admin/llm` and `PATCH /v1/admin/llm`.
- Changed `/v1/ready` so `status` reflects search-core readiness only, with separate `capabilities.search` and `capabilities.llm`.
- Updated `/v1/research` to return a valid `ResearchResponse` in `trace.mode="search-only-fallback"` when LLM is disabled, missing, unavailable, or over request budget.
- Treated research `timeout_ms` as an overall budget across search, provider readiness, and synthesis.
- Extended provider test/model discovery/verify paths to accept draft endpoint/model state without saving profiles.
- Tightened proxy trust so direct private-LAN clients cannot spoof `X-HyperSearch-Proxy`; Caddy now strips inbound proxy markers before setting its own.

### Web UI

- Added Operations LLM toggle backed by `/v1/admin/llm`.
- Updated status copy to show search-ready with LLM off/unavailable as a valid state.
- Provider Discover models, Test, and Verify model now use the draft form endpoint/model.
- Research button relabels to Source Review when LLM is off/unready.
- Model-dependent search summary and session auto-name controls disable when LLM is not ready.

### Desktop And Installer

- Changed paired LAN app URLs to use `#hypersearch_token=...` fragments instead of query strings.
- Redacted token/key/password/auth/credential values in desktop event logs, command logs, diagnostics commands, compose output, env files, and copied logs.
- Replaced substring-based desktop status with structured `docker compose ps --format json` parsing plus `/v1/live` and `/v1/ready` HTTP probes.
- Added Docker doctor checks for local/user Docker config permissions, Docker context, named-pipe access, Docker Desktop service state, and `docker-users` group membership.
- Added `scripts/Deploy-HyperSearch.cmd` wrapper for Windows operator paths.
- Added installer Authenticode and media SHA256 verification before running bundled/downloaded Docker Desktop and bundled LM Studio installers.
- Configured installer search-only mode when LM Studio is skipped/missing or hardware recommends search-only.

### Release Images And Media

- Removed `latest` and floating release tags from runtime compose defaults.
- Pinned:
  - `caddy:2.11.2-alpine`
  - `valkey/valkey:8.1.6-alpine`
  - `searxng/searxng:2026.4.13-ee66b070a`
- Added image archive manifest generation with image IDs, repo digests when available, and archive SHA256.
- Copied image digest manifests into Full media payloads and media manifests.

## Validation Completed

- `pytest`: 17 passed, 1 skipped.
- UI build: passed.
- Desktop frontend build: passed.
- Desktop native `cargo check`: passed.
- Desktop native `cargo test`: 1 passed.
- Production npm audit, UI: 0 vulnerabilities.
- Production npm audit, desktop: 0 vulnerabilities.
- Compose config validation: passed with pinned Caddy, Valkey, and SearXNG images.
- PowerShell syntax validation: passed for installer, deploy, image build, and media build scripts.

## Environment Blocker

Live Docker stack startup could not be completed in this environment because Docker engine access is blocked:

- user Docker config `C:\Users\Seeker\.docker\config.json` reports access denied
- Docker named pipe `\\.\pipe\docker_engine` is not accessible
- `com.docker.service` is stopped
- current user is not reported in `docker-users`

`scripts\Deploy-HyperSearch.cmd -Action doctor` now surfaces these findings with remediation text.

## Remaining Release Gates

These still require a Docker-ready machine or clean Windows VM:

- release Docker stack startup on `127.0.0.1:8090`
- search smoke with no LM Studio
- research fallback smoke with no LM Studio
- research synthesis smoke with LM Studio and loaded matching model
- full media install on clean Windows VM
- diagnostics export sentinel-secret verification
