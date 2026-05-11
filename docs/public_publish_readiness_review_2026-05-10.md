# HyperSearch Public Publish Readiness Review - 2026-05-10

This review records the remaining work between the current private repository
state and a public HyperSearch 1.0 repository/release. It focuses on items that
should be resolved before the repository is made public, or immediately after
visibility changes where GitHub only enables a feature for public repositories.

## Current Verified Good State

- Local checkout is clean and synced with `origin/main`.
- Current release commit: `995947a Finalize release dependency triage`.
- Latest `main` GitHub Actions run passed:
  `https://github.com/Nacsez/HyperSearch/actions/runs/25628471249`.
- Open GitHub pull requests: 0.
- Open GitHub issues: 0.
- Open Dependabot alerts: 0.
- Remaining `glib` Dependabot alert was dismissed as accepted 1.0 risk for the
  Windows-first release because it is in the transitive Tauri/Wry Linux GTK
  dependency chain.
- Local tracked-file secret scan found no high-confidence committed secret
  values. Expected matches were workflow secret placeholders and scanner test
  patterns.
- Release security script passed locally with process-scoped execution-policy
  bypass:
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ReleaseSecurity.ps1 -SkipNetworkAudits`.
- The latest staged local media hashes are:
  - Full media ZIP:
    `b68858bbed2f870167998f9f20d3ceb4fac4ff3a2f3ce732ba2086dc0245a6c8`
  - Online media ZIP:
    `a3770be9c219950b35638f803814308b6c3ced4d57820a670e1f6d7a40d7aa47`
  - NSIS setup EXE:
    `488af4acc9a060a615d4bf0b3a66ea9265d874fd580dcfc2f59950e3859217f6`
  - Full media Docker image archive:
    `919aadcd5a78e4edd9cbedab0f2c6f2fcac4b899330fa007453a893bef2987d6`

## Fixes Applied After This Review

- Added a conventional root `LICENSE` file containing the full AGPL text so
  GitHub license detection can identify the project more reliably while
  preserving `LICENSE.md` as the project-specific license posture note.
- Updated GitHub repository metadata while the repository remains private:
  description, homepage, and public-facing topics.
- Ran the GitHub Actions **Publish Container Images** workflow for `version=1.0.0`
  with GHCR enabled and Docker Hub disabled:
  `https://github.com/Nacsez/HyperSearch/actions/runs/25646369101`.
- Confirmed the workflow pushed both GHCR images successfully, but clean
  unauthenticated manifest checks still returned `unauthorized` until package
  visibility is changed to public.

## Must Fix Before Public Release Announcement

### 1. Upload Release Assets

Severity: High

Evidence: `gh release view 1.0 --repo Nacsez/HyperSearch` reported
`assets: []`.

Required action:

- Upload `HyperSearch_1.0.0_Full_PublicRelease_20260509.zip`.
- Upload `HyperSearch_1.0.0_Online_PublicRelease_20260509.zip` only if the
  GHCR images are published and public, or remove the Online asset from the
  release plan.
- Upload `release-assets.sha256`.
- Consider also uploading standalone `HyperSearch_1.0.0_x64-setup.exe`,
  `HyperSearch_1.0.0_x64_en-US.msi`, and `signing-summary.json` as optional
  advanced assets.

Publish gate:

- Do not publish the GitHub release until the assets visible on the draft match
  the checksums in the release body.

### 2. Fix Draft Release Hashes

Severity: High

Evidence: the GitHub draft release body currently lists old hashes:

- Full media ZIP:
  `0fa8a0ef2a83f04802150f0f9dbb935aca94c55cc2f94abaaae4083ab7229590`
- Online media ZIP:
  `77ec1b22904306c1360322c0688655ae2ee61c01cdb8982f5b3e1c21daaedcfb`

Those do not match the current local `release-assets.sha256` values:

- Full media ZIP:
  `b68858bbed2f870167998f9f20d3ceb4fac4ff3a2f3ce732ba2086dc0245a6c8`
- Online media ZIP:
  `a3770be9c219950b35638f803814308b6c3ced4d57820a670e1f6d7a40d7aa47`

Required action:

- Replace the draft release body with
  `docs/releases/hypersearch-1.0-github-release.md`, or manually update the
  GitHub draft to the current hashes.
- After upload, download each release asset back from GitHub and recompute
  SHA256 to confirm GitHub-hosted bytes match the published checksums.

### 3. Publish Or Remove The Online GHCR Install Path

Severity: High

Evidence:

- Before the image workflow ran,
  `gh api users/Nacsez/packages/container/hypersearch-api` returned
  `Package not found`.
- Unauthenticated manifest checks returned `denied` for:
  - `ghcr.io/nacsez/hypersearch-api:1.0.0`
  - `ghcr.io/nacsez/hypersearch-ui:1.0.0`
- After the image workflow ran successfully, clean unauthenticated manifest
  checks returned `unauthorized`, which indicates the packages exist but are
  not public.

Required action:

- Make the GHCR packages public.
- Verify unauthenticated clean-client pulls:
  - `docker pull ghcr.io/nacsez/hypersearch-api:1.0.0`
  - `docker pull ghcr.io/nacsez/hypersearch-ui:1.0.0`

Alternative:

- If GHCR publishing is deferred, do not publish the Online media asset and
  remove Online media and GHCR image promises from the release body until those
  images are public.

### 4. Finalize Tag Naming And Target Commit

Severity: Medium

Evidence:

- Local `git tag --list` returned no tags.
- The GitHub draft release uses tag `1.0` and target `main`.
- The product/package version is `1.0.0`.

Required action:

- Choose the final tag convention, preferably `v1.0.0` or `1.0.0`.
- Create the tag on commit `995947a` or on a later final media rebuild commit.
- Update the GitHub draft release to use that tag.
- Avoid a moving `main` target for the published release.

### 5. Decide Whether To Rebuild Media From The Exact Final Commit

Severity: Medium

Evidence:

- Current media was generated on 2026-05-09 before commit `995947a`.
- The post-media commit changed CI and release-triage documentation, not
  runtime code, but the release guide states final media should be built from
  the exact release commit after validation passes.

Required action:

- Conservative path: rebuild Full and Online media from the final tagged commit,
  recompute hashes, update release docs/body, and upload those assets.
- Pragmatic path: keep the current media because runtime code did not change,
  but explicitly record that the media predates a CI/docs-only commit.

Recommendation:

- Rebuild only if you want maximum release hygiene. The current media is likely
  acceptable functionally, but exact-commit rebuilds make future support and
  provenance cleaner.

### 6. Resolve GitHub License Detection

Severity: Fixed Locally, Verify After Push

Evidence:

- GitHub repository API reports license as `Other` / `NOASSERTION`.
- The repository has `LICENSE.md` and `COPYING`, and `LICENSE.md` declares
  `AGPL-3.0-only`, but GitHub is not detecting it as AGPL.

Action taken:

- Added root `LICENSE` with the exact AGPL text from `COPYING`.

Follow-up:

- After this change is pushed, re-check GitHub repository license detection.
  It may take GitHub a short time to refresh.

### 7. Confirm GitHub Security Features After Visibility Change

Severity: Medium

Evidence:

- Private vulnerability reporting API check returned `404`.
- Secret scanning API reported: `Secret scanning is disabled on this repository.`
- Branch protection API returned `403` because the private repository/free plan
  cannot use that feature until the repository is public or upgraded.

Required action:

- After making the repository public, before broad announcement:
  - Enable private vulnerability reporting if it is not already visible.
  - Enable or confirm secret scanning for the public repository.
  - Confirm Dependabot alerts remain enabled.
  - Add branch protection or a ruleset for `main` with required CI checks before
    accepting external contributions.

Publish sequencing note:

- Some of these controls may only become available after the repository becomes
  public. If so, make the repo public first, enable/verify them immediately,
  then publish or announce the 1.0 release.

### 8. Update Public Repository Metadata

Severity: Fixed

Evidence:

- GitHub description is still:
  "Locally cached search application with web app and CLI. Results can
  optionally be analyzed with Local LLM for summaries and research."
- Repository homepage is blank.
- Repository topics are empty.

Required action:

- Updated description to:
  "Windows-first local search and research workstation with Docker-backed
  search, saved sessions, and optional local LLM synthesis."
- Set homepage to `https://github.com/Nacsez/HyperSearch`.
- Added topics: `local-first`, `search`, `research`, `docker`, `tauri`,
  `fastapi`, `react`, `lm-studio`, `agpl`.

### 9. Review Historical Internal Docs For Public Tone

Severity: Low

Evidence:

- `docs/release_readiness_code_review_2026-05-06.md` contains historical
  readiness language such as "private beta" and "I would not yet hand it to a
  general user" from an earlier pre-remediation state.

Required action:

- Either keep these docs as transparent process history, or move historical
  review/postmortem material under a clearly labeled archive path.
- If kept public, add a short archive note to old readiness-review docs saying
  they describe an earlier state and have been superseded by the 1.0 release
  remediation and final readiness checks.

## Already Acceptable For Public Flip

- README explains Full and Online install paths, search-only mode, unsigned
  hash-verifiable release posture, Docker Desktop requirement, and local LLM
  optionality.
- `SECURITY.md` exists and tells reporters not to disclose vulnerabilities in
  public issues.
- Issue templates warn users not to post secrets, pairing tokens, `.env`
  contents, Docker credentials, or full diagnostics bundles publicly.
- `CHANGELOG.md` has a 1.0.0 entry.
- `COPYING`, `LICENSE.md`, `THIRD_PARTY_NOTICES.md`, and `SOURCE_OFFER.md` are
  present.
- `docs/assets/hypersearch-1.0-release-banner.svg` exists, so the release body
  banner should render after the repository is public.
- Generated media is ignored by git and was not committed.

## Recommended Final Sequence

1. Decide whether to rebuild media from the final commit.
2. Publish GHCR `1.0.0` API/UI images or remove Online media from the release.
3. Verify unauthenticated GHCR pulls if Online media remains.
4. Fix the GitHub draft release body hashes.
5. Upload release assets and checksum/signing metadata.
6. Create/update the final release tag on the exact commit.
7. Optionally fix GitHub license detection and public repository metadata.
8. Make the repository public.
9. Immediately verify private vulnerability reporting, secret scanning, and
   `main` branch protection/rulesets after public visibility enables them.
10. Download assets from GitHub, recompute SHA256, and run one final install
    smoke if time permits.
11. Publish the GitHub release.
