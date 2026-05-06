# HyperSearch Test Results and Roadmap Sanity Check - 2026-04-28

## Scope

This note summarizes post-installer testing on:

- A Windows 11 tablet with 8 GB RAM and an Intel 6700-class processor.
- The development workstation/runtime installation.

The focus is installer behavior, local search/research readiness, browser-session persistence, and comparison against the 1.0 local-control design targets.

## Evidence Reviewed

- Tablet installer log: `F:\installer-20260427-203659.log`
- Tablet LM Studio model action log: `F:\model-download-20260427-204439.log`
- Installed runtime database: `%LOCALAPPDATA%\HyperSearch\runtime\data\hypersearch.db`
- Development database: `data\hypersearch.db`
- LM Studio dev-machine log: `%APPDATA%\LM Studio\logs\main.log`
- Design docs:
  - `docs/local_control_1_0.md`
  - `docs/architecture.md`
  - `docs/desktop-launcher.md`
  - `docs/release_checklist.md`
  - `docs/windows_installer_test_plan.md`

## What Passed

The installer completed the core setup path on the tablet:

- Runtime payload copied to `C:\Users\Administrator\AppData\Local\HyperSearch\runtime`.
- Docker Desktop download started and the installer was launched.
- LM Studio installation was started through `winget`.
- The no-GPU fallback model profile was configured as `qwen2.5-7b-instruct`.
- The LM Studio server was started on port `1234`.

The search pipeline appears stable enough for continued QA:

- The installed runtime database recorded multiple successful search requests on 2026-04-28.
- The development database contains 157 recorded history rows from ongoing search/research testing.
- Search remained usable on the low-memory tablet, which validates the core local-search value proposition independent of model performance.

The packaged runtime location strategy is working:

- Installed runtime files exist under `%LOCALAPPDATA%\HyperSearch\runtime`.
- User data is separated from the application install location, which is the right direction for reinstall/update safety.

## Main Findings

### 1. Provider Health Is Too Shallow

LM Studio can report healthy even when the model is functionally unusable for research. The current provider health path primarily verifies that `/v1/models` responds and that the preferred model is listed. That is reachability, not readiness.

On the tablet, the chosen no-GPU model profile technically started but was not practically useful. This is expected for an 8 GB system, but HyperSearch currently presents that state too optimistically.

Roadmap impact:

- Split model state into:
  - provider reachable
  - model listed
  - model loaded
  - generation smoke passed
  - performance acceptable
- Readiness should be degraded if a short completion cannot finish within a bounded time.
- Low-memory machines should default to "search-only ready" unless a small local model profile is explicitly confirmed.

### 2. Installer Model Logging Lost Critical Evidence

The tablet model action log only contains LM Studio service startup output. The actual `lms get` output was overwritten by the later `lms server start` redirect.

Roadmap impact:

- Change model-download logging from overwrite redirection to append redirection.
- Log each command, exit code, model id, and remediation message.
- Treat "server started" and "model downloaded" as separate states.

### 3. Automatic Model Selection Is Too Coarse

The installer currently uses GPU presence as the main branch:

- GPU detected: `openai/gpt-oss-20b`
- No usable GPU detected: `qwen2.5-7b-instruct`

This is not enough for real-world hardware. RAM, VRAM, CPU generation, quantization, context size, and thermal limits matter. An 8 GB no-GPU tablet should not be nudged toward a 7B-class research workflow by default.

Roadmap impact:

- Add a hardware profile step:
  - RAM
  - VRAM
  - CPU class
  - available disk
  - Windows power profile if available
- Recommend modes:
  - Search only
  - Lightweight rename/summarize
  - Full research
- Keep model download optional, but show capability warnings before download.

### 4. Research Prompt Budgeting Is Not Yet 1.0-Stable

The LM Studio dev-machine log contains a concrete context failure:

`n_keep: 21764 >= n_ctx: 8192`

This means a research prompt exceeded the loaded model context. The current synthesis loop chunks source material, but the final evidence brief can still become too large for the active model.

Roadmap impact:

- Add token/character budget enforcement before every model call.
- Store provider/model context capability in the provider profile.
- Adapt research depth to context size.
- Fail gracefully with "too much source material for current model context" and remediation.
- Add a "compact research mode" for low-context or low-memory models.

### 5. Browser Session Persistence Is Too Aggressive

The browser bug is likely frontend state, not backend search execution. The installed runtime database shows the backend accepted and stored new search queries. In the UI code, plain browser launches call `getInitialSessionId()`, which reuses `hypersearch_last_session_id` even for a normal `/` browser launch.

This can reopen an old session when the user expects a clean page.

There is also a preset-specific defect: `loadPreset()` still assigns `query: String(request.query ?? "")`. Since presets are now settings-only, loading a preset can clear or interfere with the current query.

Roadmap impact:

- Browser `/` should start a new blank session by default.
- Resume should happen only through explicit session id, session library action, or "Resume last session".
- Loading presets must never mutate the query.
- Add a visible "New blank session / clear local UI state" recovery action.

## Design-Doc Comparison

The local-control direction remains sound:

- Local-only provider strategy is still correct.
- Docker-managed backend is working as a deployment abstraction.
- Search is delivering value even where local research is too heavy.
- Desktop-managed setup is the right novice-friendly path.

The docs now lag the implementation in one important place:

- `docs/local_control_1_0.md` still says automatic model downloads are not supported in 1.0.
- The current installer offers optional model download.

This needs a product decision:

1. Keep optional model download in 1.0 and update the docs to call it a guided optional setup action.
2. Move model download back out of 1.0 and make installer configuration-only.

Given the tablet result, the safer 1.0 framing is:

> HyperSearch 1.0 installs and runs local search everywhere Docker Desktop works. Research synthesis is available when local hardware and the selected model pass readiness checks.

## Recommended Roadmap Update

### P0 Before Wider Installer Testing

- Fix browser session startup so `/` does not silently reload the last session.
- Fix `loadPreset()` so settings presets never touch query text.
- Fix model-download logging to append and preserve `lms get` output.
- Add functional provider readiness using a short timed completion.
- Add hardware-aware model guidance and a search-only path for low-memory machines.
- Add model/context budget checks before research synthesis.

## P0 Implementation Update - 2026-04-28

The P0 items above have been implemented for the next test build:

- Browser `/` now creates a new blank session by default. Existing sessions are restored only through an explicit `hypersearch_session_id` URL or the explicit `hypersearch_resume_last=1` path.
- Search presets are now settings-only in the UI load path. Loading a preset leaves the active query untouched.
- LM Studio provider readiness now checks provider reachability, preferred-model availability, and a short bounded generation smoke test. Readiness is cached briefly to avoid repeated startup stalls.
- Research synthesis now applies conservative character budgets to batch summaries, question refinement, final source lists, and the final evidence prompt before sending anything to the local model.
- The Windows prerequisite helper now appends model-download logs, records command boundaries and exit codes, and preserves `lms get` output before starting the LM Studio server.
- The Windows prerequisite helper now detects low-memory CPU-only machines and configures them as `search-only` instead of automatically assigning a 7B model profile.

Verification run:

- `python -m compileall apps\api\hypersearch_api` passed.
- `npm.cmd run build` in `apps\ui` passed.
- `python -m pytest` passed with 11 tests passing and 1 live smoke test skipped.

## Provider Readiness Follow-Up - 2026-05-02

Additional desktop testing exposed a false negative in the LM Studio readiness check. The saved provider profile pointed at `openai/gpt-oss-20b`, LM Studio accepted direct chat-completion requests for that model, but the HyperSearch provider health check marked it unavailable because the smoke test requested only 8 output tokens. Reasoning models can spend that budget on hidden reasoning and return an empty visible `message.content` even though the generation endpoint is functioning.

Fix applied:

- The smoke test now asks for a larger 64-token response window.
- Readiness now treats a successful completion transaction with choices or usage metadata as generation-ready, even if the visible smoke-test content is empty.
- Direct local verification against `http://127.0.0.1:1234/v1/chat/completions` passed for `openai/gpt-oss-20b`.
- `python -m pytest` passed again with 11 tests passing and 1 live smoke test skipped.

Next QA focus:

- Confirm search summaries and research synthesis no longer report “model not connected” when LM Studio is actively processing requests.
- Confirm long research requests still respect the prompt-budget guardrails added on 2026-04-28.

## Large Research Robustness Follow-Up - 2026-05-03

Recent tests showed the harness still behaved poorly when a research request collected a larger body of evidence. The simple research runs completed through LM Studio, but the larger indoor-spice-plants query with 25 documents returned `provider: fallback`, `model: null`, and an empty provider error. The answer was a pasted source-excerpt list instead of a synthesized answer.

Finding:

- The failure was not basic LM Studio connectivity. Smaller research requests completed with `provider: lmstudio` and normal research traces.
- The large request triggered the all-or-nothing fallback path inside research synthesis. A timeout or empty intermediate completion during one of the batch/consolidation/final calls caused HyperSearch to discard partial work and return raw excerpts.
- Empty error strings were caused by exception types such as timeouts whose `str(error)` can be blank.

Fix applied:

- Large research jobs now switch to a compact synthesis mode with fewer, smaller source batches and smaller final evidence/source-list budgets.
- Batch-level model failures no longer fail the entire research run. HyperSearch now records a structured batch error and substitutes compact source notes for that batch.
- Consolidation failure now falls back to the joined staged synopses instead of throwing away the work.
- Question-refinement failure now keeps the original user query and records the error.
- Final synthesis failure now returns the staged evidence brief with a clear error note instead of a raw quote collage.
- Search-summary fallback now produces a concise top-source summary and includes the real exception type.
- Provider errors now include exception class names, so timeout-style failures are diagnosable instead of appearing as blank strings.

Verification run:

- Added regression tests for batch timeout recovery and final synthesis timeout fallback.
- `python -m pytest` passed with 13 tests passing and 1 live smoke test skipped.

## Installer Diagnostics Follow-Up - 2026-05-04

The next fresh-machine installer test needs enough diagnostics to reconstruct prerequisite setup, runtime copy, Docker startup, LM Studio setup, model-download handoff, and first desktop launch without relying on manual notes.

Fix applied:

- The Windows prerequisite helper now writes a plain installer log, full PowerShell transcript, and JSON setup summary for every run.
- Setup diagnostics now record runtime payload source/destination, robocopy exit code, Docker detection/install/download/exit-code/version details, LM Studio detection/install/exit-code/path details, hardware profile, selected model/search-only profile, and async model-download script/log paths.
- The desktop launcher now writes persistent first-launch and service-control events to `%LOCALAPPDATA%\HyperSearch\logs\desktop.log`, including runtime preparation, provider-profile application, Docker readiness checks, compose commands, LAN toggles, browser/session launches, XML exports, and shutdown.
- The installation media build script now fails fast if the Tauri build fails or expected artifacts are missing, preventing stale installers from being copied after a failed build.
- The Windows installer test plan and installation media manifest now list all log collection paths.

Verification run:

- Installer prerequisite script parsed successfully with PowerShell scriptblock compilation.
- `cargo check` for the Tauri desktop app passed.
- `python -m pytest` passed with 13 tests passing and 1 live smoke test skipped.
- Fresh installation media was built in `Installation Media\TestRun_20260504_InstallerLoggingPass`.

### P1 Before Public 1.0

- Add installer setup result screen showing Docker, LM Studio, runtime path, model profile, and next action.
- Add app-level diagnostics export bundle for logs, env, readiness, Docker status, and provider smoke result.
- Add compact research mode for small models.
- Add a QA matrix covering low-memory CPU-only, midrange laptop, GPU desktop, and fresh Windows account installs.

### P2 After 1.0

- Consider prebuilt HyperSearch container images to avoid Docker build time on novice machines.
- Add deeper LM Studio integration if stable APIs support model download/load status.
- Add automatic local model recommendations from a maintained compatibility manifest.
