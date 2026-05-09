# HyperSearch 1.0 Release Checklist

## Required Checks

- `pytest`
- `cd apps/ui && npm run build`
- `cd apps/desktop && npm run build`
- `cd apps/desktop/src-tauri && cargo check`
- `cd infra/docker && docker compose --project-name hypersearch config --quiet`
- `cd infra/docker && docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml config --quiet`
- `.\scripts\Build-InstallationMedia.ps1 -RunName PublicRelease_20260509 -Channel Both -Version 1.0.0 -RegistryMode GHCR -BuildImages -SigningMode Verify`
- Release Docker stack startup on `127.0.0.1:8090` with API, UI/Caddy, SearXNG, and Valkey running.
- Search smoke with no LM Studio.
- Research fallback smoke with no LM Studio; expect `trace.mode="search-only-fallback"`.
- Research synthesis smoke with LM Studio running and preferred model loaded.
- Full media install on a clean Windows VM.
- Diagnostics export sentinel check: token/key/password/auth test values must be absent from the bundle.

## Security Gates

- Public security reporting path is committed in `SECURITY.md`.
- GitHub private vulnerability reporting is enabled before the repository is made public or before public testers are invited.
- Tracked files pass a secret scan for `.env`, token, password, pairing token, certificate, PFX, private key, Docker credential, and diagnostics-bundle material.
- Repo-root `.env` has no cloud provider API keys.
- LAN mode defaults to disabled.
- Pairing token is generated before LAN mode is enabled.
- Metrics, admin, providers, search, research, and history endpoints are protected for LAN clients.
- SearXNG secret is changed before any LAN/shared deployment.
- LAN paired URLs put `hypersearch_token` in the URL fragment, not the query string.
- Direct private-LAN requests cannot bypass local-only mode by spoofing `X-HyperSearch-Proxy`.
- Public release artifacts are trusted-signed, or the release notes explicitly state that the 1.0 release uses the no-cost unsigned path with SHA256 verification instructions.
- Trusted-signed artifacts verify with Authenticode and SignTool on a clean Windows machine, or no-cost unsigned artifacts include matching GitHub SHA256 checksums and `signing-summary.json`.

## Packaging Gates

- Windows desktop installer builds.
- Online installer builds and reports registry/network failures clearly.
- Full media builds with a Docker image archive, image digest manifest, checksums, and setup can run `docker load`.
- Online and full media are zipped for GitHub release assets; installer binaries and image archives are not committed to git.
- Caddy, Valkey, and SearXNG images are pinned to exact tags or digests; no release path uses `latest`.
- Docker Desktop missing/not-ready state is handled in installer and launcher.
- Installer records WSL status and runs `wsl --update` before Docker image setup; elevated retry and manual-remediation messaging are covered.
- Docker Desktop and bundled LM Studio installers pass Authenticode and media SHA256 checks before execution.
- If signing is enabled, media manifests include signer, certificate thumbprint, timestamp status, and verification result.
- No signing private keys, PFX files, certificate passwords, or Azure signing secrets are committed to the repository.
- Search-only state, LM Studio missing-state, and `lms.exe` unavailable state are handled in installer and launcher.
- Start, restart, stop, logs, and open-console actions work from the launcher.
- Backend actions are serialized and normal startup does not use `--build`.
- Diagnostics export creates a bundle with redacted env files, Docker/Compose command output, command logs, and desktop logs.
- Data and log locations are documented.

## Documentation Gates

- README, API docs, deployment docs, operations docs, and in-app help match the shipped UI/API.
- `docs/release_candidate_deployment.md` reflects the current 1.0 build workflow.
- `docs/github_release_distribution_1_0_2026-05-09.md` records asset names, SHA256 hashes, and GitHub release instructions.
- In-app help includes online/full installer, local provider, XML export, diagnostics, CLI/API, and troubleshooting workflows.
- Changelog has the release date and validation notes.
- Security policy is present.
- License choice is confirmed by the project owner before public distribution.
- `docs/security_signing_release_plan_2026-05-09.md` has been reviewed for current signing and security registration decisions.
