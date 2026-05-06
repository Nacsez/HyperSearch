# HyperSearch 1.0 Release Checklist

## Required Checks

- `pytest`
- `cd apps/ui && npm run build`
- `cd apps/desktop && npm run build`
- `cd apps/desktop/src-tauri && cargo check`
- `cd infra/docker && docker compose --project-name hypersearch config --quiet`
- `cd infra/docker && docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml config --quiet`
- `.\scripts\Build-ContainerImages.ps1 -Version 1.0.0 -RegistryMode Both -SaveArchive`
- Docker smoke test with SearXNG and Valkey running.
- Local research smoke test with LM Studio running and preferred model loaded.

## Security Gates

- Repo-root `.env` has no cloud provider API keys.
- LAN mode defaults to disabled.
- Pairing token is generated before LAN mode is enabled.
- Metrics, admin, providers, search, research, and history endpoints are protected for LAN clients.
- SearXNG secret is changed before any LAN/shared deployment.

## Packaging Gates

- Windows desktop installer builds.
- Online installer builds and reports registry/network failures clearly.
- Full media builds with a Docker image archive and setup can run `docker load`.
- Docker Desktop missing/not-ready state is handled in installer and launcher.
- LM Studio missing-state and `lms.exe` unavailable state are handled in installer and launcher.
- Start, restart, stop, logs, and open-console actions work from the launcher.
- Backend actions are serialized and normal startup does not use `--build`.
- Diagnostics export creates a bundle with redacted env files and Docker/Compose command output.
- Data and log locations are documented.

## Documentation Gates

- README, API docs, deployment docs, operations docs, and in-app help match the shipped UI/API.
- `docs/release_candidate_deployment.md` reflects the current private beta build workflow.
- In-app help includes online/full installer, local provider, XML export, diagnostics, CLI/API, and troubleshooting workflows.
- Changelog has the release date and validation notes.
- Security policy is present.
- License choice is confirmed by the project owner before public distribution.
