# HyperSearch Polish Pass - 2026-05-07

## Goals

- Fix excessive spacing in the research "Sources Used" cards.
- Make large requested result/source counts explicit and more faithfully fulfilled.
- Rename the primary "Export XML" action to "Save Session" while preserving XML export/session-library behavior.
- Ensure saved default search presets prepopulate new sessions.
- Add browser-style Ctrl+mouse-wheel zoom.

## Implementation Notes

- Source cards now use a dedicated two-column grid (`citation index` + `content`) instead of inheriting the shared `justify-content: space-between` flex layout used by metadata rows.
- Search and research requests now accept `target_result_count`.
  - The UI stores the requested count directly as `target_results`.
  - Legacy `results_per_page` and `max_pages` remain populated for compatibility.
  - Backend collection uses the explicit target, fetches additional SearXNG pages when needed, deduplicates, ranks, and slices to the target.
  - Search debug output now reports `target_result_count`, `searx_results_per_page`, `page_budget`, `pages_attempted`, and `result_shortfall`.
  - Research trace now reports `requested_source_count`, `source_shortfall`, `search_target_result_count`, and `search_result_count`.
- New-session preset defaults now persist both the default preset ID and a normalized default form snapshot in localStorage.
  - This makes new sessions hydrate immediately from the saved default without waiting for preset list polling.
  - If an existing default preset is overwritten, the stored default snapshot is refreshed.
  - Clearing the default returns new sessions to the built-in base profile.
- Request status text now advances through collection, extraction, source review/synthesis, and consolidation phases while a long search or research request is pending.
- Ctrl+mouse-wheel now adjusts the same UI zoom state used by the existing zoom buttons and keyboard shortcuts.

## Validation

- `pytest tests\unit\test_search_service.py tests\unit\test_research_service.py tests\unit\test_query_normalizer.py` passed.
- Full `pytest` passed: 18 passed, 1 live smoke skipped.
- `npm.cmd run build` passed in `apps/ui`.
- `npm.cmd run build` passed in `apps/desktop`.
- `cargo check` passed in `apps/desktop/src-tauri`.
- `docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml up -d --build` succeeded from `infra/docker`.
- `GET http://127.0.0.1:8090/v1/live` returned `ok`.
- `GET http://127.0.0.1:8090/v1/ready` returned `ready`.
- Live search smoke through Caddy with `target_result_count=30` returned:
  - `result_count=30`
  - `target_result_count=30`
  - `result_shortfall=0`
- Live research smoke through Caddy with `target_result_count=30` and `top_n=5` returned:
  - `mode=llm-synthesis`
  - `citations=5`
  - `source_shortfall=0`
  - `search_result_count=30`

