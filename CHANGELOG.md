# Changelog

## 1.0.0 - Unreleased

- Repositioned HyperSearch as a local-control personal search and research app.
- Removed public cloud provider API-key support from the 1.0 configuration surface.
- Added LAN pairing-token access controls.
- Added liveness/readiness endpoints.
- Added local provider profile update and model verification endpoints.
- Added history list/export/delete/retention endpoints.
- Added Windows-first Tauri desktop launcher scaffold.
- Added request bounds, provider-default integrity checks, and structured upstream/provider errors.
- Added Docker and release hardening documentation.
- Added release-mode Docker Compose with prebuilt HyperSearch API/UI images and a dev override for local builds.
- Added channel-aware installer media generation for online and full/offline beta packages.
- Added installer support for bundled Docker image archives, prerequisite payloads, stricter Docker readiness, and setup result summaries.
- Added desktop command logs, serialized backend actions, fixed Compose project naming, and diagnostics export.
- Added private release-candidate deployment docs and updated in-app help for installer, diagnostics, local model, XML export, and beta workflows.
- Added app-level LLM enablement, search-only readiness, source-review research fallback, and reactive draft provider discovery/testing.
- Improved long research handling with chunked synthesis, request-budget traces, clearer source metrics, and graceful fallback behavior.
- Polished desktop/session UX for session saving, default search profiles, help zoom, Ctrl+wheel zoom, window-state restore, and narrow-window wrapping.
- Added beta GitHub distribution notes with upload-ready media asset names and SHA256 checksums.
- Added installer WSL status capture and `wsl --update` remediation before Docker image setup.
