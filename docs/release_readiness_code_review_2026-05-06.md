# HyperSearch 1.0 Release Readiness Code Review - 2026-05-06

## Scope

This review focused on whether the current HyperSearch codebase, desktop launcher, web interface, CLI helpers, Docker runtime, and installer media are ready to hand to a technically capable Windows user who should not need developer help to get from zero to a comfortable running state.

The review intentionally avoids feature suggestions except where the change is core to the reliability, security, installability, or supportability of the current 1.0 product.

## Overall Assessment

HyperSearch is close to a credible private release candidate, especially when using the Full installer media. The project already has useful release documentation, installer logging, desktop command logs, diagnostics export, prebuilt image support, bundled image archive support, Docker readiness parsing, and backend action serialization.

I would not yet treat the current build as public/general-use ready for arbitrary systems. The main blockers are not the search/research implementation itself. They are release-hardening issues around diagnostics secret leakage, false-positive stack readiness, image reproducibility, PowerShell execution policy friction, and the amount of live packaged-runtime testing currently enforced.

For a gamer friend handoff, the Full media is the safer path. The Online media remains dependent on registry/network behavior and should be considered a connected beta/developer path until image publishing and third-party image pinning are tightened.

## Severity Rubric

- **Critical**: likely data exposure, install failure, or app failure for a normal user with no good workaround.
- **High**: likely to break confidence, cause unsafe support artifacts, or produce false readiness on common systems.
- **Medium**: important robustness, security, or supportability issue with a workaround.
- **Low**: cleanup that reduces confusion or future regression risk.

## Verification Performed

- `pytest`: 13 passed, 1 skipped. The skipped test was the live smoke test gated by `HYPERSEARCH_E2E_BASE_URL`.
- `apps/ui`: `npm.cmd run build` passed.
- `apps/desktop`: `npm.cmd run build` passed.
- `apps/desktop/src-tauri`: `cargo check` passed.
- Compose release config: `docker compose --project-name hypersearch config --quiet` exited 0.
- Compose dev config: `docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml config --quiet` exited 0.
- PowerShell script parse check passed for installer, build, deploy, invoke, and launcher scripts.
- Production npm audits for `apps/ui` and `apps/desktop` with `--omit=dev` reported 0 vulnerabilities.
- Full npm audits reported 2 moderate dev/build-chain advisories through Vite/esbuild in both frontend projects.
- Current Full media was inspected at `Installation Media/RC1_PrivateFix_20260506/Full`; it includes setup EXE, MSI, direct EXE, manifest, checksums, and a 293,605,888 byte image archive. The payload archive hash matches the generated checksum file.

## Verification Not Completed

- I could not run the live Docker stack smoke test because Docker Desktop did not become ready within the deploy helper timeout on this machine. The helper gave a clear error after trying to start Docker Desktop.
- I did not execute the installer on a clean Windows VM during this review.
- I did not run Python or Rust vulnerability audits because `pip-audit` and `cargo-audit` are not installed in this environment.

## Findings

### 1. High - Diagnostics and LAN Pairing Flow Can Leak Tokens

**Evidence**

- `paired_app_url()` places the LAN token in the URL query string when LAN mode is enabled: `apps/desktop/src-tauri/src/main.rs:753-769`.
- The browser UI already knows how to read tokens from the URL fragment as well as the query string: `apps/ui/src/lib/api.ts:225-229`.
- Diagnostics redacts `.env` files only: `apps/desktop/src-tauri/src/main.rs:811-827`.
- Diagnostics writes raw Docker and Compose command output, including `docker compose config`, into the bundle: `apps/desktop/src-tauri/src/main.rs:884-897`.
- Desktop command logs store full stdout/stderr before diagnostics copies the logs tree: `apps/desktop/src-tauri/src/main.rs:410-430` and `apps/desktop/src-tauri/src/main.rs:898-899`.
- On this machine, `docker compose config` includes secret-bearing environment names such as pairing token and API-key variables. I did not copy their values into this document.

**Impact**

The pairing token can appear in Caddy access logs because query strings are sent to the server. Diagnostics bundles can also include unredacted token/key values through `compose-config.txt` and copied command logs. This undermines the intended safe support flow where a user can export diagnostics and send them to someone else.

**Recommended remediation**

- Change desktop-generated paired URLs from `?hypersearch_token=...` to `#hypersearch_token=...`; the UI already supports fragment hydration and fragments are not sent to Caddy/API logs.
- Redact command output written into diagnostics, especially `compose config`, `compose logs`, and copied command logs.
- Either omit raw `docker compose config` from support bundles or generate a sanitized variant that masks any key containing `TOKEN`, `SECRET`, `PASSWORD`, `KEY`, `AUTH`, or `CREDENTIAL`.
- Add a regression test that creates fake `.env` and compose config output with sentinel secrets, exports diagnostics, and asserts the sentinel values do not appear anywhere in the bundle.

### 2. High - Desktop Stack Status Can Report Running When Critical Services Are Not Ready

**Evidence**

- Desktop status marks the backend `ok` if the text output of `docker compose ps` contains `running`, `Up`, or `healthy`: `apps/desktop/src-tauri/src/main.rs:1030-1042`.
- Compose has no service healthchecks and uses basic `depends_on`, which only orders startup: `infra/docker/docker-compose.yml:20-23` and `infra/docker/docker-compose.yml:48-50`.
- API, UI, Caddy, Valkey, and SearXNG have `restart: unless-stopped`, but no health criteria are surfaced to the launcher: `infra/docker/docker-compose.yml:23`, `infra/docker/docker-compose.yml:27`, `infra/docker/docker-compose.yml:32`, `infra/docker/docker-compose.yml:40`, `infra/docker/docker-compose.yml:51`.

**Impact**

If any one service is running, the desktop launcher may show the stack as running even when the UI, API, Caddy, or SearXNG is broken. That is exactly the kind of failure mode that sends a non-developer user into a dead end: they press Start, see "Running", then the browser/session fails.

**Recommended remediation**

- Parse structured compose output, for example `docker compose ps --format json`, and require all required services to be running.
- Add Compose healthchecks for at least API `/v1/live`, Caddy/UI HTTP, SearXNG, and Valkey.
- After `up -d`, have the desktop launcher poll `http://127.0.0.1:<port>/v1/live` and a search-core health endpoint before switching to the Sessions view.
- Report separate states: Docker ready, containers running, HTTP reachable, search ready, research provider ready.

### 3. High - Third-Party Runtime Images Are Not Fully Pinned or Reproducible

**Evidence**

- Release compose uses `valkey/valkey:8-alpine`, `searxng/searxng:latest`, and `caddy:2-alpine`: `infra/docker/docker-compose.yml:30`, `infra/docker/docker-compose.yml:35`, `infra/docker/docker-compose.yml:43`.
- `infra/docker/.env.example` also defaults SearXNG to `searxng/searxng:latest`: `infra/docker/.env.example:7`.
- The image archive builder saves those same third-party tags: `scripts/Build-ContainerImages.ps1:61-64`.

**Impact**

The Full media captures whatever `latest` and floating Alpine tags resolved to at build time, while Online media can pull a different image later. That creates hard-to-reproduce support failures and makes it harder to prove a packaged release is the same release you tested.

**Recommended remediation**

- Pin third-party images to immutable digests or at minimum exact version tags.
- Record the resolved image digests in the media manifest and setup summary.
- Make `Build-ContainerImages.ps1` verify that the archive contains the exact image references used by release compose.
- Avoid `latest` in any release path.

### 4. Medium - Documented PowerShell Deploy Command Is Blocked by Execution Policy

**Evidence**

- README tells users to run `.\scripts\Deploy-HyperSearch.ps1` directly: `README.md:75-78`.
- Running that exact command in this environment failed because the script is not digitally signed and the current execution policy blocks it.
- The `.cmd` wrappers that do use `-ExecutionPolicy Bypass` exist for launch and API invocation, but not for `Deploy-HyperSearch.ps1`: `Launch-HyperSearch.cmd`, `scripts/Invoke-HyperSearch.cmd`.

**Impact**

The CLI path is likely to fail on normal Windows systems with default or stricter execution policy. A technically capable friend may still not know why a documented command is blocked.

**Recommended remediation**

- Add `scripts/Deploy-HyperSearch.cmd` that calls PowerShell with `-NoProfile -ExecutionPolicy Bypass -File`.
- Update README and deployment docs to use the `.cmd` wrapper for novice/operator CLI paths.
- Consider signing release PowerShell scripts for public distribution.
- Keep direct `.ps1` examples under an "advanced PowerShell" note.

### 5. Medium - Direct API Exposure Can Bypass Local-Only Protection With a Spoofed Proxy Header

**Evidence**

- `_is_trusted_private_proxy()` trusts any direct private IP client that sends `X-HyperSearch-Proxy: caddy`: `apps/api/hypersearch_api/auth.py:48-56`.
- When LAN mode is disabled, `require_access()` allows a trusted local proxy request without a token: `apps/api/hypersearch_api/auth.py:86-91`.

**Impact**

In the default Docker release path, the API service is not published directly, so this is mostly contained. If a user runs the API directly on `0.0.0.0`, uses the systemd path, or otherwise exposes port 8000 to the LAN, a LAN client can spoof the proxy marker and bypass the local-only guard.

**Recommended remediation**

- Trust the proxy marker only from known local proxy addresses or a configured trusted proxy CIDR, not all private addresses.
- Have Caddy strip inbound `X-HyperSearch-Proxy` from clients before setting its own marker.
- Add tests for direct private-network requests with spoofed `X-HyperSearch-Proxy` when LAN mode is disabled.

### 6. Medium - Search-Only Systems Are Reported as Not Ready

**Evidence**

- Installer intentionally supports search-only configuration on low-resource machines: `installer/windows/HyperSearchPrereqSetup.ps1:447-470` and `installer/windows/HyperSearchPrereqSetup.ps1:918-921`.
- `/v1/ready` returns 503 unless both SearXNG is healthy and the default provider is healthy: `apps/api/hypersearch_api/routers/health.py:15-27`.

**Impact**

A low-resource or LM-Studio-not-installed user can have a valid "search works, research disabled" installation, but readiness will say degraded/not ready. That creates confusing operator feedback and makes smoke checks too strict for a supported 1.0 mode.

**Recommended remediation**

- Split readiness into `search_ready` and `research_ready`.
- Let `/v1/ready` return 200 when core search dependencies are healthy, with research marked disabled/degraded separately.
- Keep `/v1/health` detailed for provider state.
- Update UI, CLI, and docs to describe "Search ready / Research needs model" instead of a single ready/degraded state.

### 7. Medium - Installer Downloads and Runs Elevated Third-Party Installers Without Signature Verification

**Evidence**

- Docker Desktop is downloaded directly and then launched elevated: `installer/windows/HyperSearchPrereqSetup.ps1:501-524`.
- Bundled prereq installers are accepted by path when present: `installer/windows/HyperSearchPrereqSetup.ps1:502-509` and `installer/windows/HyperSearchPrereqSetup.ps1:760-768`.

**Impact**

The installer is asking Windows for elevation and executing third-party binaries. HTTPS reduces risk, but release-grade installers should verify Authenticode signer and preferably expected hashes for bundled prerequisites.

**Recommended remediation**

- Verify Authenticode signatures before running Docker Desktop or LM Studio installers.
- For bundled prereqs, store expected SHA256 hashes in the media manifest and verify before execution.
- Record signer, hash, and verification result in `setup-summary-*.json`.
- Fail closed or show a clear warning if verification fails.

### 8. Medium - Live Packaged Runtime and Installer Testing Are Not Enforced by CI

**Evidence**

- CI runs unit/integration tests, frontend builds, cargo check, compose config, and Docker image builds: `.github/workflows/ci.yml:10-77`.
- The live smoke test is skipped unless `HYPERSEARCH_E2E_BASE_URL` is set: `tests/e2e/test_live_smoke.py:9-16`.
- The release checklist calls for Docker smoke and local research smoke tests, but they are not enforced in CI: `docs/release_checklist.md:12-13`.

**Impact**

The checks are useful, but they do not prove that the packaged desktop app, installer media, Docker stack, Caddy route, and API work together after installation. This is the highest process gap for avoiding "works on my machine" release failures.

**Recommended remediation**

- Add a CI or scheduled workflow that starts the release Compose stack and runs a local smoke test against `http://127.0.0.1:8090`.
- Add a Windows packaging validation workflow that builds the Tauri bundle and runs script-level installer/media checks.
- Keep a clean Windows VM acceptance pass as a release gate for Full media.
- Have the smoke test exercise search without LM Studio and a provider-readiness check with LM Studio absent.

### 9. Medium - Research and Fetch Limits Can Still Produce Very Long Requests

**Evidence**

- Research allows `top_n` up to 250 and `timeout_ms` up to 120000: `apps/api/hypersearch_api/schemas/research.py:20-21`.
- The UI also exposes 250 as the maximum collected result count: `apps/ui/src/features/search/SearchForm.tsx:62`.
- Fetching is concurrency-limited by a semaphore: `apps/api/hypersearch_api/services/fetch_service.py:29`.
- Hydration still schedules work for every selected result and waits for all of it: `apps/api/hypersearch_api/services/search_service.py:247-249` and `apps/api/hypersearch_api/services/search_service.py:329-330`.

**Impact**

A user can request a large research run that takes many minutes or longer on slow/blocked pages. The app has timeouts per fetch/provider call, but no clear overall request budget or cancellation path. For a novice operator, this can look like a hang.

**Recommended remediation**

- Keep the backend hard max, but lower the UI default and warning threshold for research sources.
- Add an overall request deadline for research execution.
- Return partial progress/results when the deadline is hit.
- Log and surface "timed out after N sources" as an expected degraded result, not an opaque failure.

### 10. Low - Release Runtime Can Keep Development Environment Defaults

**Evidence**

- `.env.example` starts with `HYPERSEARCH_ENV=development`: `.env.example:1`.
- The desktop runtime setup copies `.env.example` if no runtime `.env` exists: `apps/desktop/src-tauri/src/main.rs:388`.
- Installer env setup also copies `.env.example` before setting image and compose values: `installer/windows/HyperSearchPrereqSetup.ps1:371-418`.

**Impact**

The running container can report `environment=development` in health responses even in an installed release. Today this is mostly cosmetic, but it is a poor release invariant and could become behaviorally risky if future code gates behavior on environment.

**Recommended remediation**

- Set `HYPERSEARCH_ENV=production` explicitly during installer and desktop runtime env creation.
- Consider a dedicated `.env.release.example` for bundled runtime media.
- Add a setup-summary field and a test asserting release media writes production defaults.

### 11. Low - Dev Dependency Audit Has Moderate Vite/esbuild Advisories

**Evidence**

- Full `npm audit --json` reports moderate advisories for Vite/esbuild in both `apps/ui` and `apps/desktop`.
- Production-only audits with `npm audit --omit=dev --json` report 0 vulnerabilities for both projects.

**Impact**

This does not appear to affect the packaged static UI or desktop runtime, but it does affect developer machines and local dev servers.

**Recommended remediation**

- Plan a Vite upgrade in a controlled branch.
- After upgrade, rerun UI build, desktop build, Tauri build/check, and a local dev-server smoke test.

## Positive Readiness Notes

- The desktop launcher now uses an explicit Compose project name and runtime-local Docker config, reducing collision and unreadable user Docker config problems.
- Docker readiness parsing rejects known fatal stderr and requires a version-like stdout.
- Backend actions are serialized in Rust, which addresses the previous overlapping start/stop failure mode.
- Full media includes a Docker image archive and checksums.
- Installer logs, setup summaries, desktop logs, and command logs are comprehensive enough to diagnose most support issues.
- The API input schemas enforce useful bounds for query length, page size, page count, safe search, and cache policy.
- Provider profiles are restricted to local/private endpoints.
- The UI avoids raw HTML rendering for model/search output and uses React escaping for rendered content.

## Suggested Remediation Order

1. Fix diagnostics/token leakage before sharing support bundles outside your own machines.
2. Make desktop readiness service-specific and HTTP-aware.
3. Pin third-party runtime images and record digests in media.
4. Add the deploy `.cmd` wrapper and update docs.
5. Split search readiness from research-provider readiness.
6. Harden proxy trust and add spoofed-header tests.
7. Add Authenticode/hash verification for prereq installers.
8. Add live packaged-runtime smoke testing to CI or the release gate.

## Current Handoff Recommendation

Use the Full media for private beta handoffs only after applying or consciously accepting the high-severity items above. The current build is diagnosable and likely workable on a prepared system, but I would not yet hand it to a general user as a "no-call-needed" installer because it can still report false readiness, leak tokens in diagnostics, and drift through floating container tags.
