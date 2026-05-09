# HyperSearch Public Go-Live Plan - 2026-05-08

This plan covers the remaining work between the current 1.0 release-prep state and a public HyperSearch release. It assumes the repository will be released from the current `main` branch after the final release-prep commit is pushed.

The final release-prep branch is `main`; publish from the release commit pushed
after the final media/hash documentation update.

Final release media:

```text
Installation Media\PublicRelease_20260509
```

The earlier `WslUpdatePolish_20260508` media is superseded by the final 1.0
release-prep changes. The staged public release media is:

```text
HyperSearch_1.0.0_Full_PublicRelease_20260509.zip
SHA256 931a7ac1d3ec8a3bc9763302610b8e13640d969eb6de2f4cd841ac3b72d203b1

HyperSearch_1.0.0_Online_PublicRelease_20260509.zip
SHA256 84724e60f9665bd0f74131c1eb839042b8f2ba7c34c8928170896a1173aa2c6b
```

## Release Goal

An end user should be able to reach a usable HyperSearch session from the GitHub page without needing Docker-specific troubleshooting knowledge. Search-only mode is a valid success state. Local-model research synthesis is a supported optional capability when LM Studio or another local OpenAI-compatible provider is ready.

## Go/No-Go Definition

Public release is a **go** when:

- Full media installs on a clean Windows test computer and reaches search-ready without manual command-line repair.
- Setup runs or clearly records WSL update handling.
- Search works with no LM Studio installed.
- Research fallback works with no LM Studio and returns source-review output rather than a server error.
- Research synthesis works when LM Studio is installed and the configured model is loaded.
- Diagnostics export is redacted and contains enough logs to diagnose installer/runtime failures.
- GitHub release assets, checksums, README, help, security policy, changelog, and license state are all public-ready.

Public release is a **no-go** when:

- Clean install cannot reach search-ready from the installer and launcher.
- Docker/WSL failures require undocumented manual commands.
- LAN/local-only access controls regress.
- Diagnostics expose tokens, keys, passwords, auth values, or pairing tokens.
- Release media hashes do not match the published checksums.
- The project license, full license text, third-party notices, or source-offer files are missing or stale at the moment the repository is made public.

## Phase 1 - Final Scratch Install Test

Use the full media zip first. This is the most important release path because it avoids registry/network dependency during first launch.

Test procedure:

1. Start from a clean Windows 10/11 machine or VM without relying on existing HyperSearch state.
2. Download or copy `HyperSearch_1.0.0_Full_PublicRelease_20260509.zip`.
3. Verify the zip hash matches the SHA256 published on the GitHub release.
4. Extract the zip to a writable folder.
5. Run `HyperSearch_1.0.0_x64-setup.exe`.
6. If Docker Desktop is missing, accept Docker installation and Windows elevation.
7. Confirm setup records WSL status and `wsl --update` in `%LOCALAPPDATA%\HyperSearch\logs\setup-summary-*.json`.
8. If LM Studio is not installed, either skip it to validate search-only mode or install it to validate synthesis.
9. Launch HyperSearch from the installed shortcut.
10. Start the stack and confirm the app opens at `http://127.0.0.1:8090`.
11. Run a normal search.
12. Run research with no model available and confirm source-review fallback.
13. If validating LM Studio, load the configured model and run research synthesis.
14. Save a session and confirm it appears in the Session Library.
15. Export diagnostics and inspect that sentinel token/key/password/auth values are absent.
16. Reboot, launch HyperSearch again, and confirm it remembers app window state and can start the stack.

Pass criteria:

- The tester never needs to manually run Docker, Compose, or WSL commands.
- Any restart requirement is explained by the installer, launcher, or setup summary.
- Search-only is presented as valid, not as a failed install.

## Phase 2 - Public Asset Readiness

Before publishing a public release, decide which distribution paths are official:

- **Recommended public asset**: Full media zip.
- **Secondary public asset**: Online media zip.
- **Optional advanced asset**: standalone `HyperSearch_1.0.0_x64-setup.exe` for connected users.
- **Developer path**: source checkout plus `scripts\Deploy-HyperSearch.cmd`.

Required asset checks:

- Upload the full and online media zips from `Installation Media\PublicRelease_20260509`.
- Publish SHA256 checksums in the release description.
- Download the uploaded assets from GitHub and verify hashes after upload.
- Run at least one install from the downloaded GitHub asset, not only the local build folder.

Online media gate:

- If online media remains a public asset, unauthenticated image pulls must work from a machine with no registry login.
- Run the GitHub Actions workflow **Publish Container Images** for `version=1.0.0`, keep Docker Hub publishing off unless you intentionally configure Docker Hub secrets, make the GHCR packages public, and test `docker compose pull` from a clean machine.
- If the GHCR packages are not public yet, position online media as an advanced connected-install path and recommend full media for normal users.

## Phase 3 - Repository Public-Readiness

These items should be complete before changing repository visibility:

- Confirm the committed AGPL license posture, full license text, third-party notices, and source-offer files are current.
- Update `SECURITY.md` with a public reporting path instead of the temporary maintainer-channel language.
- Review `docs/security_signing_release_plan_2026-05-09.md` and confirm the release notes describe the no-cost unsigned 1.0 path with SHA256 verification.
- Confirm `README.md` leads with end-user install guidance before developer setup details.
- Confirm `CHANGELOG.md` has the final release date and validation summary.
- Confirm `docs/github_release_distribution_1_0_2026-05-09.md` points at the final asset names and SHA256 hashes.
- Confirm no private-only notes remain in first-viewport public documentation.
- Run a secrets scan over tracked files and confirm no `.env`, token, password, pairing token, or local machine path leak is being published as a credential.
- Confirm `.gitignore` keeps installer binaries, image archives, logs, runtime state, local `.env`, and diagnostics out of source history.

Recommended GitHub setup:

- Repository description: short local-control search/research description.
- Topics: `search`, `local-first`, `docker`, `windows`, `searxng`, `lm-studio`.
- Releases enabled.
- Issues enabled with bug report and diagnostics checklist templates.
- Discussions optional; useful if users need a lower-friction place to ask setup questions.

## Phase 4 - Final Release Build And Tag

If no code changes are needed after the scratch install test, the current commit can be used. If the scratch test finds a fix, rebuild from the fixed commit and regenerate media.

Final local commands:

```powershell
pytest
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ReleaseSecurity.ps1
cd apps/ui; npm.cmd run build; cd ..\..
cd apps/desktop; npm.cmd run build; cd ..\..
cd apps/desktop/src-tauri; cargo check; cd ..\..\..
cd infra/docker; docker compose --project-name hypersearch config --quiet; cd ..\..
cd infra/docker; docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml config --quiet; cd ..\..
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-InstallationMedia.ps1 -RunName PublicRelease_20260509 -Channel Both -Version 1.0.0 -RegistryMode GHCR -BuildImages -SigningMode Verify
```

After the final build:

- Zip the final `Online` and `Full` media folders.
- Compute SHA256 hashes.
- Update the GitHub distribution note with final names and hashes.
- Commit any final documentation/hash changes.
- Tag the exact release commit, for example `v1.0.0`.
- Push `main` and the tag.

## Phase 5 - GitHub Release

Create the GitHub release manually.

Release body should include:

- One-sentence product purpose.
- Recommended install path: Full media zip.
- Online media explanation.
- Search-only support statement.
- Optional LM Studio/local model statement.
- Windows/Docker Desktop prerequisite statement.
- WSL update behavior statement.
- SHA256 checksums.
- Known limitations and support path.

Upload assets:

- Full media zip.
- Online media zip.
- Optional standalone NSIS setup EXE.
- Optional `checksums.sha256` file.

After upload:

1. Download each uploaded asset from GitHub.
2. Verify SHA256 hashes.
3. Install from the downloaded full media asset on at least one machine or VM.
4. Confirm GitHub release links and README instructions point to the same assets.

## Phase 6 - Public Visibility Switch

Only make the repository public after:

- License, full license text, third-party notices, and source-offer files are committed and current.
- Public security reporting path is committed.
- Security/signing plan decisions are reflected in release notes and media manifests.
- Release assets are uploaded and hash-verified.
- README, release notes, and in-app help agree on install behavior.
- Final clean install passes.

Visibility switch checklist:

1. Confirm no private/internal docs are linked from README first-run paths.
2. Confirm generated media is available through GitHub Releases.
3. Change repository visibility to public.
4. Open the public repo in a private browser session and verify the install path without maintainer credentials.
5. Download release media anonymously and verify it is accessible.

## Phase 7 - Post-Release Smoke

Run these after the repository is public:

- Anonymous download of full media zip.
- Hash verification of downloaded zip.
- Fresh install from downloaded media.
- Search-only smoke.
- Diagnostics export smoke.
- Optional LM Studio synthesis smoke.
- Uninstall/reinstall smoke to confirm local data preservation.
- GitHub issue intake smoke with a sample private diagnostic checklist, not real secrets.

## Expected Support Triage

Treat these as release blockers:

- Installer crash.
- Docker Desktop installation accepted but HyperSearch cannot reach search-ready with no clear remediation.
- WSL update loops with no clear message.
- Full media cannot load Docker images.
- Search endpoint fails when LLM is absent.
- Diagnostics redaction failure.

Treat these as 1.0 follow-up issues if documented:

- LM Studio model download is slow or user chooses not to install it.
- Online media fails because a user's network blocks registry access, while full media works.
- Windows SmartScreen warns because the installer is unsigned, if the release notes explicitly disclose the no-cost unsigned distribution path and provide SHA256 verification instructions.
- Specific websites fail extraction while search results still return.

## Final Human Decisions

These require owner judgment before public release:

- Final legal/signoff review of the selected AGPL-3.0-only posture.
- Whether to add trusted code signing in a future release.
- Whether online media is promoted equally with full media or documented as advanced.
- Final release asset names and SHA256 hashes.
