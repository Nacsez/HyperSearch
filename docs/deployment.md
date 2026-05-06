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
- `infra/docker/docker-compose.dev.yml` is the development override for local API/UI image builds.
- The published HTTP port is bound to `127.0.0.1:8090` in the current local compose env.
- `infra/docker/.env` controls compose-time values such as the published port and host-side LM Studio URL.
- The repo-root `.env` is mounted into the API service and controls application settings.
- The fixed Compose project name is `hypersearch`.
- LAN exposure should be enabled through the desktop launcher so bind host and pairing token settings are updated together.
- Do not expose the stack directly to the public internet for 1.0.

Release mode:

```powershell
cd infra\docker
docker compose --project-name hypersearch up -d
```

Development build mode:

```powershell
cd infra\docker
docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

## Desktop Launcher

- `apps/desktop` is the preferred 1.0 user entrypoint on Windows.
- It manages Docker Compose lifecycle commands, shows status/logs, opens the console, and toggles paired LAN mode.
- The launcher detects Docker Desktop and common LM Studio install paths.
- Installer setup can guide Docker Desktop and LM Studio installation, load bundled image archives, pull online images, and configure an initial local-model profile.
- Desktop diagnostics can be exported from Settings for beta issue reports.

## Installer Channels

- **Online**: small installer, guided prerequisite downloads, `docker compose pull`.
- **Full**: installer plus `payload\images` archives, optional prerequisite installers, and `docker load` during setup.

See `docs/release_candidate_deployment.md` for the current private release-candidate workflow.

## systemd

- `infra/systemd/hypersearch.service` starts only the API process.
- Pair it with a separate Caddy unit or container for reverse proxying.
- Install the UI build under your preferred static host and point Caddy at it.
- systemd deployment is considered advanced/self-hosted and is not the primary 1.0 novice path.
