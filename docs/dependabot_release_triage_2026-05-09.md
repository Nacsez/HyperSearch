# HyperSearch Dependabot Release Triage - 2026-05-09

This note records the Dependabot/security branch review performed before the
HyperSearch 1.0 public release.

## Access State

- GitHub remote access through `git` is working.
- The GitHub connector returned `token_expired`, so PR metadata, merge buttons,
  alert dismissal, and branch/PR closure were not available through the app.
- `gh` is not installed in this environment.
- The remediation below was applied directly to `main` by inspecting remote
  Dependabot branches and updating the affected dependency files locally.

## Accepted For 1.0

| Area | Branches superseded | Action | Reason |
| --- | --- | --- | --- |
| UI Vite security | `dependabot/npm_and_yarn/apps/ui/vite-8.0.11`, `dependabot/npm_and_yarn/apps/ui/vitejs/plugin-react-6.0.1` | Updated `apps/ui` to `vite@8.0.11` and `@vitejs/plugin-react@6.0.1`. | Fixes npm audit findings for Vite path traversal and esbuild dev-server exposure. |
| Desktop Vite security | `dependabot/npm_and_yarn/apps/desktop/vite-8.0.11`, `dependabot/npm_and_yarn/apps/desktop/vitejs/plugin-react-6.0.1` | Updated `apps/desktop` to `vite@8.0.11` and `@vitejs/plugin-react@6.0.1`. | Same Vite/esbuild audit findings existed in the desktop frontend workspace. |
| Desktop Tauri security | `dependabot/cargo/apps/desktop/src-tauri/tauri-2.11.1`, `dependabot/cargo/apps/desktop/src-tauri/tauri-build-2.6.1`, `dependabot/npm_and_yarn/apps/desktop/tauri-apps/cli-2.11.1` | Updated Rust lockfile to `tauri@2.11.1` / `tauri-build@2.6.1`; updated npm CLI to `@tauri-apps/cli@2.11.1` and API package to the latest published `@tauri-apps/api@2.11.0`. | Tauri is security-sensitive desktop shell code. The update passed frontend build and `cargo check`. |
| API runtime image | `dependabot/docker/apps/api/python-3.14-slim` | Updated API image base to `python:3.14-slim`. | Remaining GitHub alerts appeared to include Docker base images. Python 3.14 built successfully with current wheels. |
| UI build image | `dependabot/docker/apps/ui/node-26-alpine` | Updated UI build stage to `node:26-alpine`. | Remaining GitHub alerts appeared to include Docker base images. The Vite 8 UI image build passed with Node 26. |
| UI runtime image | `dependabot/docker/apps/ui/nginx-1.29-alpine` | Updated the UI Docker runtime stage from `nginx:1.27-alpine` to `nginx:1.29-alpine`. | Low-risk exact-tag source-build fallback image update. |

## Deferred Or Rejected For 1.0

| Branch | Decision | Reason |
| --- | --- | --- |
| `dependabot/npm_and_yarn/apps/ui/multi-76a9a2998f` | Defer | React 19 major update. Not needed for the active security alerts and higher UI regression risk before 1.0. |
| `dependabot/npm_and_yarn/apps/ui/multi-bb2efd036b` | Defer | React DOM 19 major update. Same release-risk rationale. |
| `dependabot/npm_and_yarn/apps/desktop/multi-76a9a2998f` | Defer | React 19 major update in the desktop shell. Not a 1.0 release blocker. |
| `dependabot/npm_and_yarn/apps/ui/typescript-6.0.3` | Defer | TypeScript 6 major tooling update. Not needed after Vite audit remediation. |
| `dependabot/npm_and_yarn/apps/desktop/typescript-6.0.3` | Defer | Same TypeScript 6 major tooling risk. |
| `dependabot/npm_and_yarn/apps/ui/types/node-25.6.2` | Defer | Type-only major update. Not needed for release security. |
| `dependabot/cargo/apps/desktop/src-tauri/rand-0.10.1` | Defer | Major API change for token generation code; not tied to the active release security alerts. |
| `dependabot/pip/apps/api/pytest-gte-8.3-and-lt-10.0` | Defer | Broadens dev dependency upper bound and makes future installs less predictable. Current tests pass. |
| `dependabot/pip/apps/api/pytest-asyncio-gte-0.24-and-lt-2.0` | Defer | Broadens dev dependency upper bound. Current tests pass. |
| `dependabot/pip/apps/api/redis-gte-5.2-and-lt-8.0` | Defer | Broadens runtime dependency upper bound across major Redis client versions; not required for a known current vulnerability. |
| `dependabot/pip/apps/api/trafilatura-gte-1.12-and-lt-3.0` | Defer | Broadens extraction dependency upper bound across a major version; source extraction behavior is release-critical. |

## No-Op Branches

- `origin/security/update-tauri-origin-confusion` had no diff against the
  current release commit after the release assets commit.
- `origin/ci/fix-tauri-frontend-build` had no diff against the current release
  commit after the release assets commit.

## Validation Run During Triage

- `npm audit --json` in `apps/ui`: 0 vulnerabilities after the Vite update.
- `npm audit --json` in `apps/desktop`: 0 vulnerabilities after the Vite/Tauri npm update.
- `npm run build` in `apps/ui`: passed with Vite 8.
- `npm run build` in `apps/desktop`: passed with Vite 8.
- `cargo check` in `apps/desktop/src-tauri`: passed with Tauri 2.11.1.
- `pytest`: 19 passed, 1 skipped.
- Release media rebuild: passed for `PublicRelease_20260509` after dependency
  remediation.
- Rebuilt-image stack smoke: `hypersearch-api:1.0.0`,
  `hypersearch-ui:1.0.0`, Caddy, SearXNG, and Valkey started successfully;
  `/v1/ready` returned `status="ready"` with search ready and LLM unavailable
  as a safe optional-provider state.
- `cargo-audit` 0.22.1 was installed under `C:\tmp\cargo-tools` and run
  against `apps/desktop/src-tauri/Cargo.lock`; it exited successfully. It
  reported allowed warnings for transitive Tauri/Linux GTK3 ecosystem crates and
  related unmaintained/unsound advisories. Those are upstream Tauri dependency
  chain issues, not direct HyperSearch code or the Windows release target, and
  should be tracked after 1.0 while staying current with Tauri.
- Final rebuilt full media zip SHA256:
  `ae4c2df17ccb3f4be00c3a6f72501c9fbe4b55147450a3dc6a7fdabb084856e9`.
- Final rebuilt online media zip SHA256:
  `f656d0b0628b957472d39ad87430856b275929ce8c0f7e66b29776f0a3755a00`.

## Remaining GitHub Cleanup

After GitHub app access is refreshed, close or mark superseded PRs for the
deferred branches above, then rerun the repository vulnerability view. The likely
release blocker alerts should be cleared by the Vite/esbuild and Tauri updates;
any remaining Dependabot items should be reviewed as planned post-1.0 dependency
modernization unless GitHub flags them as direct runtime vulnerabilities.
