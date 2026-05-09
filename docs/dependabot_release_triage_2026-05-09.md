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
| `dependabot/docker/apps/ui/node-26-alpine` | Defer | Node 26 build-stage jump. Node 20 is stable for the current release build path. |
| `dependabot/docker/apps/api/python-3.14-slim` | Defer | Python 3.14 runtime jump could affect binary wheels and local provider stack behavior. Python 3.11 remains the safer 1.0 base. |
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
- Rebuilt full media zip SHA256:
  `10f4a42e55a94d88bae0f2091a2eb39cf0cb2d12b1e7c8a6b45edbb511d675c1`.
- Rebuilt online media zip SHA256:
  `d44929b62f9bd4c9d83d6ef92723aa16845438c6c8b908392ae04d5a15505f2e`.

## Remaining GitHub Cleanup

After GitHub app access is refreshed, close or mark superseded PRs for the
deferred branches above, then rerun the repository vulnerability view. The likely
release blocker alerts should be cleared by the Vite/esbuild and Tauri updates;
any remaining Dependabot items should be reviewed as planned post-1.0 dependency
modernization unless GitHub flags them as direct runtime vulnerabilities.
