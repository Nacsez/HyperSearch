# HyperSearch 1.0 Release Checklist

## Required Checks

- `pytest`
- `cd apps/ui && npm run build`
- `cd apps/desktop && npm run build`
- `cd apps/desktop/src-tauri && cargo check`
- `cd infra/docker && docker compose --project-name hypersearch config --quiet`
- `cd infra/docker && docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml config --quiet`
- `.\scripts\Build-ContainerImages.ps1 -Version 1.0.0 -RegistryMode Both -SaveArchive`
- Release Docker stack startup on `127.0.0.1:8090` with API, UI/Caddy, SearXNG, and Valkey running.
- Search smoke with no LM Studio.
- Research fallback smoke with no LM Studio; expect `trace.mode="search-only-fallback"`.
- Research synthesis smoke with LM Studio running and preferred model loaded.
- Full media install on a clean Windows VM.
- Diagnostics export sentinel check: token/key/password/auth test values must be absent from the bundle.

## Security Gates

- Repo-root `.env` has no cloud provider API keys.
- LAN mode defaults to disabled.
- Pairing token is generated before LAN mode is enabled.
- Metrics, admin, providers, search, research, and history endpoints are protected for LAN clients.
- SearXNG secret is changed before any LAN/shared deployment.
- LAN paired URLs put `hypersearch_token` in the URL fragment, not the query string.
- Direct private-LAN requests cannot bypass local-only mode by spoofing `X-HyperSearch-Proxy`.

## Packaging Gates

- Windows desktop installer builds.
- Online installer builds and reports registry/network failures clearly.
- Full media builds with a Docker image archive, image digest manifest, checksums, and setup can run `docker load`.
- Online and full media are zipped for GitHub release assets; installer binaries and image archives are not committed to git.
- Caddy, Valkey, and SearXNG images are pinned to exact tags or digests; no release path uses `latest`.
- Docker Desktop missing/not-ready state is handled in installer and launcher.
- Docker Desktop and bundled LM Studio installers pass Authenticode and media SHA256 checks before execution.
- Search-only state, LM Studio missing-state, and `lms.exe` unavailable state are handled in installer and launcher.
- Start, restart, stop, logs, and open-console actions work from the launcher.
- Backend actions are serialized and normal startup does not use `--build`.
- Diagnostics export creates a bundle with redacted env files, Docker/Compose command output, command logs, and desktop logs.
- Data and log locations are documented.

## Documentation Gates

- README, API docs, deployment docs, operations docs, and in-app help match the shipped UI/API.
- `docs/release_candidate_deployment.md` reflects the current private beta build workflow.
- `docs/beta_github_distribution_2026-05-08.md` records asset names, SHA256 hashes, and private GitHub release instructions.
- In-app help includes online/full installer, local provider, XML export, diagnostics, CLI/API, and troubleshooting workflows.
- Changelog has the release date and validation notes.
- Security policy is present.
- License choice is confirmed by the project owner before public distribution.
