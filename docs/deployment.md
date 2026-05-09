# Deployment Notes

## Local Development

1. Copy `.env.example` to `.env`.
2. Create a Python virtual environment and install `apps/api`.
3. Install UI dependencies in `apps/ui`.
4. Run the API with `uvicorn hypersearch_api.main:app --reload`.
5. Run the UI with `npm run dev`.

## Docker Compose

- `infra/docker/docker-compose.yml` defines API, UI, Caddy, Valkey, and SearXNG.
- Release startup uses pinned/prebuilt image references and does not build images on the user machine.
- Release images are pinned to exact tags for Caddy, Valkey, and SearXNG. Full media also records resolved image digests in the image archive manifest when images are built.
- `infra/docker/docker-compose.dev.yml` is the development override for local API/UI image builds.
- The published HTTP port is bound to `127.0.0.1:8090` in the current local compose env.
- `infra/docker/.env` controls compose-time values such as the published port and host-side LM Studio URL.
- The repo-root `.env` is mounted into the API service and controls application settings.
- The fixed Compose project name is `hypersearch`.
- LAN exposure should be enabled through the desktop launcher so bind host and pairing token settings are updated together.
- Do not expose the stack directly to the public internet for 1.0.

Release mode:

```powershell
.\scripts\Deploy-HyperSearch.cmd
```

Development build mode:

```powershell
cd infra\docker
docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

## Desktop Launcher

- `apps/desktop` is the preferred 1.0 user entrypoint on Windows.
- It manages Docker Compose lifecycle commands, shows status/logs, opens the console, and toggles paired LAN mode.
- The launcher detects Docker Desktop and common LM Studio install paths, then requires all Compose services plus `/v1/live` and search readiness before sessions open.
- Installer setup can guide Docker Desktop and LM Studio installation, check and update WSL for Docker Desktop's WSL backend, load bundled image archives, pull online images, configure a local-model profile, or deliberately configure search-only mode.
- Desktop diagnostics can be exported from Settings for issue reports. Token, key, password, auth, and credential values are redacted from env files, compose output, command logs, and desktop logs.

## Installer Channels

- **Online**: small installer, guided prerequisite downloads, `docker compose pull`.
- **Full**: installer plus `payload\images` archives, image digest manifests, optional prerequisite installers, and `docker load` during setup.

Search-only is a valid public-release deployment. Set `HYPERSEARCH_LLM_ENABLED=false` or `HYPERSEARCH_RESEARCH_CAPABILITY=search-only` to start with search and source review while leaving local model discovery/testing available in Operations.

See `docs/release_candidate_deployment.md` for the current private release-candidate workflow.

## systemd

- `infra/systemd/hypersearch.service` starts only the API process.
- Pair it with a separate Caddy unit or container for reverse proxying.
- Install the UI build under your preferred static host and point Caddy at it.
- systemd deployment is considered advanced/self-hosted and is not the primary 1.0 novice path.
