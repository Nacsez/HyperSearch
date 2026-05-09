# Third-Party Notices

This file is maintained by `scripts/Update-LicenseNotices.ps1`. Run that script after dependency, image, or release-packaging changes, and run it with `-Check` in release validation to detect stale notices.

HyperSearch-owned source code is licensed under `AGPL-3.0-only`. Third-party components remain under their own licenses.

## Runtime Service Images

| Component | Current image reference | License posture | Source |
| --- | --- | --- | --- |
| Caddy | `caddy:2.11.2-alpine` | Apache-2.0 | https://github.com/caddyserver/caddy |
| HyperSearch API image | `ghcr.io/nacsez/hypersearch-api:1.0.0` | AGPL-3.0-only plus API dependencies below | This repository |
| HyperSearch UI image | `ghcr.io/nacsez/hypersearch-ui:1.0.0` | AGPL-3.0-only plus UI dependencies below | This repository |
| SearXNG | `searxng/searxng:2026.4.13-ee66b070a` | AGPL-3.0-or-later upstream project posture | https://github.com/searxng/searxng |
| Valkey | `valkey/valkey:8.1.6-alpine` | BSD-3-Clause | https://github.com/valkey-io/valkey |

Docker base images and operating-system packages inside the built images are provided under their own upstream licenses. Release media should retain Docker image digest manifests so an end user can match shipped images to the corresponding upstream image and source package set.

## Python Direct Dependencies

| Package | Scope | License posture | Source |
| --- | --- | --- | --- |
| `fastapi` | API runtime | MIT | https://github.com/fastapi/fastapi |
| `httpx` | API runtime | BSD-3-Clause | https://github.com/encode/httpx |
| `opentelemetry-api` | Optional observability | Apache-2.0 | https://github.com/open-telemetry/opentelemetry-python |
| `opentelemetry-instrumentation-fastapi` | Optional observability | Apache-2.0 | https://github.com/open-telemetry/opentelemetry-python-contrib |
| `opentelemetry-sdk` | Optional observability | Apache-2.0 | https://github.com/open-telemetry/opentelemetry-python |
| `playwright` | Optional JS fallback rendering | Apache-2.0 | https://github.com/microsoft/playwright-python |
| `pydantic` | API runtime | MIT | https://github.com/pydantic/pydantic |
| `pytest` | Development/test | MIT | https://github.com/pytest-dev/pytest |
| `pytest-asyncio` | Development/test | Apache-2.0 | https://github.com/pytest-dev/pytest-asyncio |
| `redis` | Optional cache client | MIT | https://github.com/redis/redis-py |
| `trafilatura` | Optional extraction | Apache-2.0 | https://github.com/adbar/trafilatura |
| `uvicorn` | API runtime | BSD-3-Clause | https://github.com/encode/uvicorn |

Python transitive dependencies are resolved by the installer/runtime build and remain under their own licenses. The release process should keep lockfile or image provenance artifacts with each binary/media release.

## npm Package License Summary

The npm package-lock files carry transitive package license metadata. This generated summary is intended to flag unusual drift before release; each package remains under its own license.

| Package lock | License expression | Package count |
| --- | --- | ---: |
| `apps/ui/package-lock.json` | `Apache-2.0` | 2 |
| `apps/ui/package-lock.json` | `BSD-3-Clause` | 1 |
| `apps/ui/package-lock.json` | `CC-BY-4.0` | 1 |
| `apps/ui/package-lock.json` | `ISC` | 5 |
| `apps/ui/package-lock.json` | `MIT` | 109 |
| `apps/desktop/package-lock.json` | `Apache-2.0` | 2 |
| `apps/desktop/package-lock.json` | `Apache-2.0 OR MIT` | 13 |
| `apps/desktop/package-lock.json` | `BSD-3-Clause` | 1 |
| `apps/desktop/package-lock.json` | `CC-BY-4.0` | 1 |
| `apps/desktop/package-lock.json` | `ISC` | 5 |
| `apps/desktop/package-lock.json` | `MIT` | 105 |

## Rust Direct Dependencies

| Crate | Scope | License posture | Source |
| --- | --- | --- | --- |
| `rand` | Desktop runtime | MIT OR Apache-2.0 | https://github.com/rust-random/rand |
| `serde` | Desktop runtime | MIT OR Apache-2.0 | https://github.com/serde-rs/serde |
| `serde_json` | Desktop runtime | MIT OR Apache-2.0 | https://github.com/serde-rs/json |
| `tauri` | Desktop runtime | MIT OR Apache-2.0 | https://github.com/tauri-apps/tauri |
| `tauri-build` | Desktop build | MIT OR Apache-2.0 | https://github.com/tauri-apps/tauri |
| `tauri-plugin-shell` | Desktop runtime | MIT OR Apache-2.0 | https://github.com/tauri-apps/plugins-workspace |

Rust transitive dependencies are resolved through `Cargo.lock` and remain under their own licenses. Review `cargo metadata` or a cargo license report before each public release if dependency versions change.

## Optional External Installers

Docker Desktop and LM Studio are optional external installers for full media workflows. They are not HyperSearch dependencies licensed by this repository. If they are bundled into release media, their redistribution terms, signatures, and SHA256 hashes must be verified and documented for that media build.
