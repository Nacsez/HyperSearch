# HyperSearch AGPL-3.0 License Posture Review - 2026-05-09

This is an engineering license-readiness review, not legal advice. It evaluates whether HyperSearch can reasonably move to GNU AGPL v3 for public release and what compliance work should be completed first.

Implementation update: `LICENSE.md`, `COPYING`, `THIRD_PARTY_NOTICES.md`, `SOURCE_OFFER.md`, package metadata, and release-media notice refresh automation were added after this review using the owner's selected `AGPL-3.0-only` posture.

## Executive Finding

Using AGPL-3.0 for HyperSearch is a coherent choice and appears compatible with the project architecture.

There is no obvious dependency-license blocker in the code paths reviewed. The larger release risk is operational compliance: the installer and full media distribute binaries, Docker images, and third-party services, so the release needs clear license notices, source availability, and exact third-party attribution.

Recommended project license:

```text
AGPL-3.0-only for HyperSearch-owned source code.
Third-party dependencies and bundled services remain under their own licenses.
```

`AGPL-3.0-only` is a narrower grant than `AGPL-3.0-or-later`. It avoids automatic adoption of later GNU AGPL versions if one is published, at the cost of less future license flexibility.

## Why AGPL Fits HyperSearch

- HyperSearch includes a network-interactive local API and web UI.
- HyperSearch ships with SearXNG, which is already AGPL-3.0.
- HyperSearch's value is in orchestration, local-control workflow, installer hardening, UI, and source/research handling. AGPL helps ensure public forks and hosted derivatives keep their changes available.
- AGPL is still real open source. It does not solve AI training concerns directly, but it is a better fit than MIT/Apache if commercial cloning is a concern.

Important limitation:

- Do not add a "no AI training" restriction on top of AGPL. AGPL section 10 prohibits adding further restrictions on the rights it grants. A separate trademark policy or public data-use preference is fine, but it should not modify the software license grant.

## Current Project State

Current tracked license file:

```text
LICENSE.md: AGPL-3.0-only project license declaration
COPYING: full GNU AGPL v3 license text
THIRD_PARTY_NOTICES.md: generated dependency and service-image notices
SOURCE_OFFER.md: source availability and corresponding source expectations
```

Current release media note:

```text
docs/github_release_distribution_1_0_2026-05-09.md
```

Current go-live note:

```text
docs/go_live_plan_2026-05-08.md
```

Current release media:

```text
Installation Media\PublicRelease_YYYYMMDD
```

The Tauri bundle includes `LICENSE.md`, `README.md`, `SECURITY.md`, `CHANGELOG.md`, `docs`, `infra`, `apps/api`, `apps/ui`, and installer scripts as resources. That is good for source availability. Release validation should run `scripts/Update-LicenseNotices.ps1 -Check` so bundled notices do not drift from dependency and image changes.

## Dependency And Runtime Inventory

### HyperSearch-Owned Components

| Component | Current role | Recommended license posture |
| --- | --- | --- |
| `apps/api` FastAPI backend | HyperSearch-owned Python service | AGPL-3.0-only |
| `apps/ui` React web UI | HyperSearch-owned browser UI | AGPL-3.0-only |
| `apps/desktop` Tauri launcher | HyperSearch-owned desktop launcher | AGPL-3.0-only |
| `installer/windows` scripts | HyperSearch-owned installer helper | AGPL-3.0-only |
| `infra/docker` compose/config files | HyperSearch-owned deployment config | AGPL-3.0-only, except third-party config samples if copied from upstream |
| `docs` and help content | HyperSearch-owned docs | AGPL-3.0-only or CC-BY-4.0; AGPL is simpler for a first release |

### Python Runtime Dependencies

Reviewed from `apps/api/pyproject.toml` and installed package metadata.

| Dependency family | Observed license posture | AGPL concern |
| --- | --- | --- |
| FastAPI, Pydantic, AnyIO, h11, Redis client | MIT or similar permissive | Compatible |
| Uvicorn, HTTPX, Starlette, HTTP Core, lxml, jusText | BSD-family | Compatible |
| Trafilatura, Playwright, OpenTelemetry | Apache-2.0 | Compatible with GPLv3/AGPLv3-style projects; preserve notices |
| Certifi | MPL-2.0 | Generally compatible when not marked incompatible with secondary licenses; preserve MPL notice and source availability for modified files if any |

No direct Python dependency reviewed requires relicensing HyperSearch away from AGPL.

### Frontend Node Dependencies

Reviewed from `apps/ui/package-lock.json` and `apps/desktop/package-lock.json`.

| Dependency family | Observed license posture | AGPL concern |
| --- | --- | --- |
| React, React DOM, TanStack Query, Vite, TypeScript ecosystem | Mostly MIT, ISC, Apache-2.0, BSD-3-Clause | Compatible |
| Tauri JS packages | MIT / Apache-2.0 family | Compatible |
| `caniuse-lite` | CC-BY-4.0 | Usually build-time/browser-data only; include attribution if distributed in source or notices |

The package-lock files show no obvious AGPL-incompatible frontend runtime dependency.

### Rust/Tauri Dependencies

Reviewed from `apps/desktop/src-tauri/Cargo.toml`, `Cargo.lock`, and locally cached crate metadata where available.

Direct dependencies:

| Dependency | License posture | AGPL concern |
| --- | --- | --- |
| Tauri / Tauri shell plugin / Tauri build | MIT and/or Apache-2.0 family | Compatible |
| Serde / Serde JSON | MIT or Apache-2.0 family | Compatible |
| Rand | MIT or Apache-2.0 family | Compatible |

Local cached transitive crate metadata showed MIT, Apache-2.0, BSD, Unicode, MPL-2.0, Unlicense, Zlib, and CC0-style licenses, with no obvious GPL-incompatible license found in cached crates. A full Rust license scan could not be completed from local cache because Cargo attempted to fetch missing crates while network access was restricted.

Required before public release:

```text
cargo install cargo-deny cargo-about
cargo deny check licenses
cargo about generate about.hbs > THIRD_PARTY_RUST_LICENSES.html
```

Use equivalent tooling if preferred.

### Docker Images And Base Images

HyperSearch distributes or references:

| Image/component | License posture | AGPL concern |
| --- | --- | --- |
| `searxng/searxng:2026.4.13-ee66b070a` | SearXNG is AGPL-3.0 | Compatible; also creates AGPL source/notice obligations |
| `valkey/valkey:8.1.6-alpine` | Valkey source is BSD-3-Clause; image includes OS packages | Compatible; preserve notices |
| `caddy:2.11.2-alpine` | Caddy is Apache-2.0; image includes OS packages | Compatible; preserve notices |
| HyperSearch API image | HyperSearch-owned code plus Python slim base and pip dependencies | AGPL source + third-party notices required |
| HyperSearch UI image | HyperSearch-owned build output plus Nginx/Alpine base | AGPL source + third-party notices required |
| `python:3.11-slim`, `node:20-alpine`, `nginx:1.27-alpine` | Base images include their own licenses and OS packages | Not an AGPL blocker, but binary redistribution needs notices/source references |

The full media image archive is the biggest notice/source compliance surface. It packages third-party binaries, not just HyperSearch source.

## AGPL Obligations That Matter Here

### Source Availability

For HyperSearch binaries, installers, and Docker images, public release should provide corresponding source for the exact released version. The easiest compliant posture is:

- Public GitHub repository contains the exact source.
- Release is tagged, for example `v1.0.0`.
- GitHub release assets clearly link to the source tag.
- Installer media includes or links to source and build scripts.
- Docker image manifests record exact image names/digests.

### Network Source Offer

Because HyperSearch has an interactive web UI and network API, include a visible source/license entry in the UI. A good minimal implementation:

- Add **About / License** in Help or Settings.
- Show copyright, AGPL-3.0-only, no warranty notice, and source URL.
- Include third-party notices link.
- Add an API endpoint such as `/v1/about` or static `/licenses` only if useful; the visible UI link is the important user-facing piece.

### Notices

The release should include:

- `LICENSE.md` with AGPL text.
- `NOTICE.md` or `THIRD_PARTY_NOTICES.md`.
- A generated dependency license inventory for Python, Node, Rust, and Docker/runtime services.
- SearXNG, Valkey, Caddy, Nginx, Python, Node, Alpine/Debian base image notices or source pointers.
- Exact Docker image digests and upstream source URLs.

### Installer / Full Media

The full media zip should include a top-level notice file or release asset companion:

```text
LICENSE.md
THIRD_PARTY_NOTICES.md
SOURCE_OFFER.md
checksums.sha256
manifest.json
```

The release description should say where source code for the exact release can be obtained.

## Compatibility Findings

### No obvious blocker: SearXNG

SearXNG being AGPL-3.0 is aligned with licensing HyperSearch as AGPL. HyperSearch currently uses SearXNG as a separate Docker service over HTTP and ships only a small configuration file. Even if treated as an aggregate/separate service, AGPL for HyperSearch makes the combined distribution story simpler and more coherent.

Required action:

- Preserve SearXNG license notice.
- Record SearXNG image tag/digest and upstream source URL.
- If modifying SearXNG source later, publish those modifications under AGPL.

### No obvious blocker: Apache-2.0 dependencies

Apache-2.0 dependencies are generally one-way compatible into GPLv3-family projects. Preserve notices and do not attempt to relicense upstream Apache code itself.

Required action:

- Include Apache-2.0 license texts/notices in third-party notices.

### Watch item: MPL-2.0 dependency files

Certifi is MPL-2.0. MPL-2.0 is file-level copyleft and can be combined with GPL-family works when not marked incompatible with secondary licenses.

Required action:

- Do not modify MPL-covered files unless prepared to publish those modified files under MPL.
- Preserve MPL notices in third-party notices.

### Watch item: Docker image redistribution

Distributing Docker image archives is convenient for users but increases compliance scope. Full media conveys binary forms of third-party software, including OS package layers.

Required action:

- Generate an image SBOM or license inventory per release.
- Include exact image digests.
- Include upstream source URLs and license texts.
- Consider adding `SOURCE_OFFER.md` for third-party image components if public distribution broadens.

### Watch item: generated/minified frontend

The UI build emits minified JavaScript. If released under AGPL, corresponding source must be available. The repo and bundled `apps/ui/src` satisfy this if they match the exact release.

Required action:

- Tag the exact commit used to build release assets.
- Keep build scripts and package lock files in source.

## Recommended Remediation Before Public Release

High priority:

1. Done: replace `LICENSE.md` with AGPL-3.0-only project license language and add `COPYING` with the full AGPL text.
2. Add SPDX headers or a repository-level SPDX policy:
   - `SPDX-License-Identifier: AGPL-3.0-only`
   - Use exceptions/third-party notices where needed.
3. Add `THIRD_PARTY_NOTICES.md`.
4. Add `SOURCE_OFFER.md` explaining how to obtain exact corresponding source for:
   - HyperSearch installer/app/images
   - SearXNG image
   - Valkey image
   - Caddy image
   - Python/Node/Nginx/base images
5. Add visible in-app **About / License** link with AGPL, no warranty, source URL, and third-party notices.
6. Run full automated license scans:
   - Python: `pip-licenses`, `pipdeptree`, or `cyclonedx-py`
   - Node: `license-checker-rseidelsohn` or `licensee`
   - Rust: `cargo-deny` and `cargo-about`
   - Docker: `syft` or Docker Scout SBOM
7. Update GitHub release notes to link source tag and license/notice files.

Medium priority:

1. Add issue template language asking users not to upload secrets in diagnostics.
2. Add a trademark/name-use policy if "HyperSearch" branding should be protected separately from AGPL code rights.
3. Decide whether docs stay AGPL or use CC-BY-4.0.
4. Partially done: release automation now refreshes `THIRD_PARTY_NOTICES.md` and `SOURCE_OFFER.md`, and image builds emit digest manifests. A fuller SBOM remains a later hardening item.
5. Verify whether standalone Docker Desktop or LM Studio installers are bundled. If bundled, confirm redistribution rights or remove them.

Low priority:

1. Add `REUSE.toml` or adopt REUSE compliance layout.
2. Add license scanning to CI.
3. Publish SBOMs as GitHub release assets.

## Recommended Public Release Language

Short form:

```text
HyperSearch is licensed under GNU AGPLv3 only. Third-party dependencies and bundled services remain under their respective licenses. Source for this exact release is available from the GitHub release tag. See THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md for third-party notices and source information.
```

Installer/release note addition:

```text
The Full media package includes Docker image archives for offline-friendly setup. These images contain HyperSearch and third-party open-source components including SearXNG, Valkey, Caddy, Nginx, Python, Node, Alpine/Debian base layers, and related package dependencies. See THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md for license notices and source locations.
```

## Sources Consulted

- GNU AGPL v3 text: https://www.gnu.org/licenses/agpl-3.0.en.html
- SearXNG repository/license: https://github.com/searxng/searxng
- Valkey COPYING: https://raw.githubusercontent.com/valkey-io/valkey/unstable/COPYING
- Caddy repository/license: https://github.com/caddyserver/caddy
- Apache License 2.0 GPL compatibility: https://www.apache.org/licenses/GPL-compatibility
- Mozilla MPL 2.0 FAQ: https://www.mozilla.org/en-US/MPL/2.0/FAQ/
- Tauri repository/license notes: https://github.com/tauri-apps/tauri
