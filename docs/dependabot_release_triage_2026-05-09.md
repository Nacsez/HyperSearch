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
| API test/build tooling | `dependabot/pip/apps/api/pytest-gte-8.3-and-lt-10.0`, `dependabot/pip/apps/api/pytest-asyncio-gte-0.24-and-lt-2.0` | Raised `pytest` to `>=9.0.3,<10.0`, allowed `pytest-asyncio` 1.x, raised build-time `setuptools` to `>=78.1.1`, and removed dev/test extras from the production API image install. | A temporary `pip-audit` environment showed `pytest 8.4.2` vulnerable under the old `<9` cap. `setuptools>=78.1.1` avoids current setuptools advisories in build isolation. Dev tools should not ship in the runtime image. |
| API runtime Python extras | `dependabot/pip/apps/api/redis-gte-5.2-and-lt-8.0`, `dependabot/pip/apps/api/trafilatura-gte-1.12-and-lt-3.0` | Raised Redis client to `>=7.4,<8.0` and Trafilatura to `>=2.0,<3.0`. | These are runtime extras and the remaining likely GitHub alerts after npm, Dockerfile, Tauri, pytest, and setuptools remediation. HyperSearch uses narrow stable surfaces for both libraries. |
| Desktop token generation | `dependabot/cargo/apps/desktop/src-tauri/rand-0.10.1` | Updated direct `rand` usage to `0.10.1` and adjusted LAN token generation to the current `rand::distr` / `rand::rng()` API. | The upstream Dependabot branch was stale and would have downgraded Tauri; applying the rand update on current `main` removed the direct rand advisory without taking stale lockfile churn. |

## Deferred Or Rejected For 1.0

| Branch | Decision | Reason |
| --- | --- | --- |
| `dependabot/npm_and_yarn/apps/ui/multi-76a9a2998f` | Defer | React 19 major update. Not needed for the active security alerts and higher UI regression risk before 1.0. |
| `dependabot/npm_and_yarn/apps/ui/multi-bb2efd036b` | Defer | React DOM 19 major update. Same release-risk rationale. |
| `dependabot/npm_and_yarn/apps/desktop/multi-76a9a2998f` | Defer | React 19 major update in the desktop shell. Not a 1.0 release blocker. |
| `dependabot/npm_and_yarn/apps/ui/typescript-6.0.3` | Defer | TypeScript 6 major tooling update. Not needed after Vite audit remediation. |
| `dependabot/npm_and_yarn/apps/desktop/typescript-6.0.3` | Defer | Same TypeScript 6 major tooling risk. |
| `dependabot/npm_and_yarn/apps/ui/types/node-25.6.2` | Defer | Type-only major update. Not needed for release security. |

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
- `cargo check` in `apps/desktop/src-tauri`: passed with Tauri 2.11.1
  and `rand 0.10.1`.
- `pytest`: 19 passed, 1 skipped.
- Temporary clean API audit environment: installed `hypersearch-api[all]` with
  `redis 7.4.0`, `trafilatura 2.0.0`, `pytest 9.0.3`, and
  `pytest-asyncio 1.3.0`; `pip-audit` reported no known vulnerabilities.
- Release media rebuild: passed for `PublicRelease_20260509` after dependency
  remediation.
- Production API image check: `pytest` is not installed in
  `hypersearch-api:1.0.0`; `redis` resolves to `7.4.0`, `trafilatura`
  resolves to `2.0.0`, and `setuptools` resolves to `82.0.1`.
- Rebuilt-image stack smoke: `hypersearch-api:1.0.0`,
  `hypersearch-ui:1.0.0`, Caddy, SearXNG, and Valkey started successfully;
  `/v1/ready` returned `status="ready"` with search ready and LLM unavailable
  as a safe optional-provider state.
- `cargo-audit` 0.22.1 was installed under `C:\tmp\cargo-tools` and run
  against `apps/desktop/src-tauri/Cargo.lock`; it exited successfully. After
  the rand update it reports 17 allowed warnings, down from 19. It
  reported allowed warnings for transitive Tauri/Linux GTK3 ecosystem crates and
  related unmaintained/unsound advisories. Those are upstream Tauri dependency
  chain issues, not direct HyperSearch code or the Windows release target, and
  should be tracked after 1.0 while staying current with Tauri.
- Final rebuilt full media zip SHA256:
  `b68858bbed2f870167998f9f20d3ceb4fac4ff3a2f3ce732ba2086dc0245a6c8`.
- Final rebuilt online media zip SHA256:
  `a3770be9c219950b35638f803814308b6c3ced4d57820a670e1f6d7a40d7aa47`.
- Final rebuilt NSIS setup SHA256:
  `488af4acc9a060a615d4bf0b3a66ea9265d874fd580dcfc2f59950e3859217f6`.
- Final rebuilt full-media image archive SHA256:
  `919aadcd5a78e4edd9cbedab0f2c6f2fcac4b899330fa007453a893bef2987d6`.

## Remaining GitHub Cleanup

After all inferable Dependabot branch remediations were committed and pushed,
GitHub still reported one moderate alert on the default branch:
`https://github.com/Nacsez/HyperSearch/security/dependabot/3`. The GitHub
connector is still expired and `gh` is not installed, so the exact alert record
could not be opened from this environment.

Required follow-up with refreshed GitHub security access:

1. Open `https://github.com/Nacsez/HyperSearch/security/dependabot/3`.
2. Confirm the remaining alert by package and advisory ID.
3. If they match the transitive Tauri/Linux GTK or GLib advisories still shown
   by `cargo-audit`, mark them as accepted risk/not applicable for the Windows
   1.0 release and track upstream Tauri updates after release.
4. If the alert names a direct HyperSearch runtime dependency, treat it as a
   release blocker and patch before publishing.
5. Close or mark superseded Dependabot PRs for branches already remediated on
   `main`; leave deferred modernization branches open only if they are useful
   post-1.0.

## Follow-Up Completed 2026-05-10

- Installed and authenticated GitHub CLI locally after the Codex GitHub
  connector remained expired.
- Confirmed alert 3 is `glib` advisory `GHSA-wrw7-89jp-8q8g` in
  `apps/desktop/src-tauri/Cargo.lock`.
- Dismissed alert 3 as accepted/tolerable risk for 1.0 with this release
  rationale: it is in the transitive Tauri/Wry Linux GTK dependency chain,
  while the packaged 1.0 desktop release is Windows-focused and the Windows
  cargo check tree does not pull `glib`.
- Closed Dependabot PRs 6, 10, 11, 13, 15, and 17 as deferred post-1.0
  modernization work because they were React 19, TypeScript 6, or
  `@types/node` 25 updates with non-clean CI and no active release-blocking
  security alert.
- Verified no open GitHub issues, pull requests, or Dependabot alerts remained
  after cleanup.
