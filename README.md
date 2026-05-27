# HyperSearch

HyperSearch is a local-control search and research service for people who want their own searchable history, local caching, and local-model synthesis without depending on a cloud model provider. The 1.1 target is Windows-first, desktop-launched, localhost by default, and LAN-capable only through an explicit pairing-token flow.

## What is included

- FastAPI backend under `apps/api`
- React + TanStack Query UI under `apps/ui`
- Tauri desktop launcher scaffold under `apps/desktop`
- SearXNG, Valkey, Caddy, and Compose assets under `infra/docker`
- SQLite WAL storage, migrations, provider registry, cache service, and request history
- Local LM Studio provider adapter, plus local vLLM and llama.cpp-compatible wrappers
- Smoke/benchmark scripts and a Linux install helper
- Unit, integration, and live-smoke test scaffolding

## Install HyperSearch 1.1

The recommended public install path is the **Full Installation Media** ZIP from
GitHub Releases:

1. Download the 1.1 Full Installation Media ZIP.
2. Verify the published SHA256 checksum before running the installer.
3. Extract the ZIP to a writable folder.
4. Run `HyperSearch_1.1.0_x64-setup.exe`.
5. Follow the **HyperSearch Installation Wizard** prompts for license consent, Standard or Custom install, Docker/WSL readiness, LM Studio setup, model choice, stack startup, optional Windows sign-in startup, and diagnostics.

Full media includes the HyperSearch installer and bundled Docker image archive.
Standard install uses the bundled images so Docker Hub sign-in is not required
for HyperSearch startup. Docker Desktop and LM Studio are third-party tools and
may still require internet access when they need to be installed or updated.
Search-only mode is a supported success state; LM Studio and model download are
optional.

The Online media ZIP is smaller and uses the public GHCR images:

- `ghcr.io/nacsez/hypersearch-api:1.0.0`
- `ghcr.io/nacsez/hypersearch-ui:1.0.0`

Use Online media when the target computer has reliable internet and registry
access. Use Full media for normal end users, clean machines, and offline-prone
systems.

## 1.0 Local-Control Position

- No external/cloud model API keys are supported for 1.0.
- Search-only is a supported installation mode. Research synthesis uses a local OpenAI-compatible provider such as LM Studio, local vLLM, or local llama.cpp when one is enabled and ready.
- The app-level LLM toggle is stored locally. `HYPERSEARCH_LLM_ENABLED=false` or `HYPERSEARCH_RESEARCH_CAPABILITY=search-only` starts HyperSearch in search-only mode.
- Browser/API access binds to localhost by default.
- LAN access is opt-in and protected by a pairing token managed by the desktop launcher.
- Docker remains the backend runtime for 1.1, but the desktop launcher is the preferred user entrypoint.

## Quick Start

### API

```bash
python -m venv .venv
. .venv/bin/activate
pip install -e ./apps/api[all]
cp .env.example .env
uvicorn hypersearch_api.main:app --app-dir apps/api --host 127.0.0.1 --port 8000
```

### UI

```bash
cd apps/ui
npm install
npm run dev
```

The UI defaults to `http://127.0.0.1:5173` and targets the API at `http://127.0.0.1:8000` in dev mode.

### Desktop Launcher

```bash
cd apps/desktop
npm install
npm run build
cd src-tauri
cargo check
```

The desktop launcher starts/stops the Docker Compose stack, checks Docker and LM Studio availability, opens the console, shows logs, and manages LAN pairing settings.

## Docker

```bash
cd infra/docker
docker compose --project-name hypersearch up -d
```

The release compose path uses prebuilt images and exposes the reverse-proxied UI/API stack on `http://127.0.0.1:8090`.
For local image development, add the dev override:

```bash
docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

### Windows Deploy Helper

```powershell
.\scripts\Deploy-HyperSearch.cmd
.\scripts\Deploy-HyperSearch.cmd -Action status
.\scripts\Deploy-HyperSearch.cmd -Action logs -Follow
.\scripts\Deploy-HyperSearch.cmd -Action doctor
.\scripts\Deploy-HyperSearch.cmd -Action down
```

The deploy helper wraps the Docker Compose stack in `infra/docker`, uses an isolated repo-local Docker config, and defaults to release-mode `up -d`. Use `-Build` only when you intentionally want the local development override. The `doctor` action reports Docker config ACLs, context, named-pipe access, Docker Desktop service state, and `docker-users` group membership.

### Release Media

```powershell
.\scripts\Build-InstallationMedia.ps1 -RunName PublicRelease_1_1 -Channel Full -Version 1.1.0 -RegistryMode GHCR -BuildImages -SigningMode Verify
```

The generated media supports:

- full installer media that loads bundled Docker image archives and carries image digest manifests
- custom online installer mode that can pull prebuilt images when explicitly selected
- the HyperSearch Installation Wizard with Standard and Custom install paths
- `install-profile.json` import into the desktop launcher for first-run provider/model/default settings
- installer and desktop command logs under `%LOCALAPPDATA%\HyperSearch\logs`
- diagnostics export under `%LOCALAPPDATA%\HyperSearch\diagnostics` with token/key/password/auth values redacted

For GitHub distribution, upload the generated media ZIP archives as release
assets rather than committing installer binaries to the repository. Use full
media as the public default so users do not depend on registry access during
first launch. The 1.1 installer architecture and test matrix are documented in
`docs/windows_installation_wizard_1_1_design.md` and
`docs/windows_installer_test_plan.md`.

The local Hyper-V release gate is documented in `docs/hyperv_installer_lab.md`.
For v1.1, the gate targets supported Windows 10 22H2 and Windows 11 23H2+
baselines and runs through `tools/installer-lab/Invoke-HyperSearchVmReleaseGate.ps1`.

## In-App Help

- The shipped operator guide is available from the UI `Help` button.
- The static help asset lives at `apps/ui/public/help/index.html`.
- When the stack is running, it is served at `http://127.0.0.1:8090/help/index.html`.

## Docker Config Split

- Repo-root `.env` is passed into the API container and controls application settings.
- `infra/docker/.env` is used by Docker Compose for published port and host-side interpolation values.
- If you want to change the local HTTP port, update `infra/docker/.env`.
- If you want to change the LM Studio model or provider settings used by the API, update the repo-root `.env`.

## LM Studio

- Start the LM Studio local server on port `1234`.
- Load a model and make sure the model identifier matches `HYPERSEARCH_LMSTUDIO_MODEL` in the repo-root `.env`.
- For Docker, the API reaches LM Studio through `http://host.docker.internal:1234`.
- If LM Studio is not installed or no model is loaded, search and source review still work. The UI reports "Search ready / LLM off" or "Search ready / LLM unavailable" instead of treating the installation as failed.

## Notable Design Choices

- Backend orchestration is independent from any future MCP facade.
- Search, fetched pages, extracts, and research synthesis use separate cache namespaces and TTLs.
- Default network bind is localhost. Non-local browser/API access is disabled unless LAN mode and a pairing token are enabled.
- Provider profiles store local endpoints and preferred model names, not cloud API secrets.
- `/v1/ready` reports search readiness independently from LLM readiness. Search can be ready while LLM is disabled or unavailable.
- Optional dependencies degrade gracefully:
  - no Valkey client -> in-memory cache
  - no Trafilatura -> basic HTML text stripping
  - no Playwright -> no JS fallback rendering
  - no OpenTelemetry -> no tracing export

## Validation

- Smoke test: `./scripts/smoke_test.sh`
- Benchmark: `python scripts/benchmark.py --base-url http://127.0.0.1:8000`
- Python tests: `pytest`
- UI build: `cd apps/ui && npm run build`
- Desktop frontend build: `cd apps/desktop && npm run build`
- Desktop native check: `cd apps/desktop/src-tauri && cargo check`
- License notice refresh/check: `.\scripts\Update-LicenseNotices.ps1` and `.\scripts\Update-LicenseNotices.ps1 -Check`

## License

HyperSearch-owned code is licensed as `AGPL-3.0-only`; see `LICENSE.md`
and the full GNU AGPL text in `COPYING`. Third-party dependency and
service-image posture is tracked in `THIRD_PARTY_NOTICES.md`, and public-release
source expectations are tracked in `SOURCE_OFFER.md`. Release media builds
refresh those notice files before packaging and include them at the media root.

## Status

This repository is staged for the HyperSearch 1.1 public release. Runtime use
requires Docker Desktop for the local service stack. Local LLM synthesis requires
an enabled local provider, but search, source review, diagnostics, and session
saving remain available without one.
