# HyperSearch

HyperSearch is a local-control search and research service for people who want their own searchable history, local caching, and local-model synthesis without depending on a cloud model provider. The 1.0 target is Windows-first, desktop-launched, localhost by default, and LAN-capable only through an explicit pairing-token flow.

## What is included

- FastAPI backend under `apps/api`
- React + TanStack Query UI under `apps/ui`
- Tauri desktop launcher scaffold under `apps/desktop`
- SearXNG, Valkey, Caddy, and Compose assets under `infra/docker`
- SQLite WAL storage, migrations, provider registry, cache service, and request history
- Local LM Studio provider adapter, plus local vLLM and llama.cpp-compatible wrappers
- Smoke/benchmark scripts and a Linux install helper
- Unit, integration, and live-smoke test scaffolding

## 1.0 Local-Control Position

- No external/cloud model API keys are supported for 1.0.
- Research synthesis requires a local OpenAI-compatible provider such as LM Studio, local vLLM, or local llama.cpp.
- Browser/API access binds to localhost by default.
- LAN access is opt-in and protected by a pairing token managed by the desktop launcher.
- Docker remains the backend runtime for 1.0, but the desktop launcher is the preferred user entrypoint.

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
.\scripts\Deploy-HyperSearch.ps1
.\scripts\Deploy-HyperSearch.ps1 -Action status
.\scripts\Deploy-HyperSearch.ps1 -Action logs -Follow
.\scripts\Deploy-HyperSearch.ps1 -Action down
```

The deploy helper wraps the Docker Compose stack in `infra/docker` and defaults to release-mode `up -d`. Use `-Build` only when you intentionally want the local development override.

### Release Candidate Media

```powershell
.\scripts\Build-ContainerImages.ps1 -Version 1.0.0 -RegistryMode Both -SaveArchive
.\scripts\Build-InstallationMedia.ps1 -RunName RC1 -Channel Both -Version 1.0.0 -ImageArchivePath .\artifacts\images\hypersearch-images-1.0.0.tar
```

The generated media supports:

- online installer media that pulls prebuilt images
- full installer media that loads bundled Docker image archives
- installer and desktop command logs under `%LOCALAPPDATA%\HyperSearch\logs`
- diagnostics export under `%LOCALAPPDATA%\HyperSearch\diagnostics`

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

## Notable Design Choices

- Backend orchestration is independent from any future MCP facade.
- Search, fetched pages, extracts, and research synthesis use separate cache namespaces and TTLs.
- Default network bind is localhost. Non-local browser/API access is disabled unless LAN mode and a pairing token are enabled.
- Provider profiles store local endpoints and preferred model names, not cloud API secrets.
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

## Status

This repository now contains the core 1.0 local-control implementation surfaces. Runtime verification still depends on Docker Desktop, SearXNG, Valkey, and a local model provider being available on the target machine.
