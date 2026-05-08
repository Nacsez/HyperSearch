# Research Reliability And UI Polish Notes - 2026-05-08

## Root Cause

The failed research exports showed search collection succeeded and returned the requested source count, but the API returned `search-only-fallback` with `LLM synthesis exceeded the overall research request budget`. The local provider could still complete afterward, which explains why LM Studio logs showed an answer that HyperSearch did not use.

The backend was applying the user-facing `timeout_ms` as an outer `asyncio.wait_for` around the entire synthesis step. Once that outer deadline fired, HyperSearch returned a fallback and discarded any provider response that arrived later.

## Remediation Implemented

- Research now treats `timeout_ms` as the search collection budget and provider-call guidance, not as a hard outer deadline for the full multi-step synthesis transaction.
- Synthesis calls use longer provider-level timeouts and can scale up to 600 seconds when requested.
- Batch summarization and final synthesis now retry with smaller prompt budgets when a provider reports context-window or token-limit errors.
- Failed or fallback synthesis payloads are no longer written to the synthesis cache, and the research cache key was versioned to avoid reusing old fallback results.
- The research metrics panel now shows explicit source counts:
  - Search Sources Requested
  - Search Sources Retrieved
  - Research Sources Requested
  - Research Sources Retrieved
- Object-valued trace fields are summarized instead of displayed as `[object Object]`.
- Help now includes zoom controls and Ctrl+mouse-wheel zoom, and its language has been revised toward public user-guide wording.
- The desktop launcher now persists window size, position, maximized state, and zoom values, and enforces a larger minimum window size.
- Narrow-width result cards, citation cards, badges, and launcher controls now wrap or clamp text more consistently.

## Validation

- `pytest tests\unit\test_research_service.py tests\unit\test_synthesize_service.py`
- `pytest`
- `npm.cmd run build` in `apps/ui`
- `cargo check` in `apps/desktop/src-tauri`
- `npm.cmd run build` in `apps/desktop`
- `scripts\Build-InstallationMedia.ps1 -RunName ResearchReliabilityPolish_20260508 -Channel Both -BuildImages`
- Docker Compose runtime recreation against the existing AppData runtime
- `GET http://127.0.0.1:8090/v1/ready`
- `POST http://127.0.0.1:8090/v1/research` with a two-source LM Studio smoke

Generated media:

- `Installation Media\ResearchReliabilityPolish_20260508\Online`
- `Installation Media\ResearchReliabilityPolish_20260508\Full`
- Setup EXE SHA256: `B8DA56C3FBBDA03ACC765D2E7B4246C24A9455359DE5439E8D407BF2619E0635`
- Full image archive SHA256: `46EEF7016CD961DC89AB7E3443B480A57DD290F6573E1A4C2FFAF404ECAC518E`
