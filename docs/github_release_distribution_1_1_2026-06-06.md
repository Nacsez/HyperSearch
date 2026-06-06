# HyperSearch 1.1 GitHub Release Distribution Guide - 2026-06-06

This note records the final local release assets, hashes, branch triage, and clean-machine smoke procedure for the HyperSearch 1.1 unsigned public release path.

## Final Asset

Upload this file as the primary GitHub release asset:

`Installation Media\PublicRelease_20260606_1_1\HyperSearch_1.1.0_Full_20260606.zip`

SHA256:

`48893ec80265f087c4058f0baa6776620941a52d0dba8530a7dc1a6c8cc7c443`

Size: `2,204,085,832` bytes.

The ZIP contains 18 entries, including:

- `HyperSearch_1.1.0_x64-setup.exe`
- `HyperSearch_1.1.0_x64_en-US.msi`
- `hypersearch-desktop.exe`
- `payload\images\hypersearch-images-1.1.0.tar`
- `payload\images\hypersearch-images-1.1.0.tar.manifest.json`
- `payload\prereqs\Docker Desktop Installer.exe`
- `payload\prereqs\LM Studio.exe`
- `payload\prereqs\WSL.msi`
- `checksums.sha256`
- `signing-summary.json`
- license, source-offer, and third-party notice files

## Important Hashes

| Artifact | SHA256 |
| --- | --- |
| Full media ZIP | `48893ec80265f087c4058f0baa6776620941a52d0dba8530a7dc1a6c8cc7c443` |
| NSIS setup EXE | `e20e1b15a844b71db94b3f54ba2f12ff5a660ca6490bc4a15cf74dd7a0c22a93` |
| MSI | `486130444093c7716321638e4fc39b01336c7c46768173e5ee050350e488dc48` |
| Desktop EXE | `598506d78c74b017f4cadd9a46fe6992dcecf9cbe1e948b035b58b10401dfff8` |
| Docker image archive | `70fdfbcd2b89f33280ba9710a56b102ca4a1962a358487a008a825632f70c1b5` |
| Docker Desktop installer | `13a71ca029faa34947ffbf881bef63caee8094e5392e75ba57e420c78aacdf6b` |
| LM Studio installer | `85e4e85b9a855ae628355619f36e607610047c8376a2c55b9d5ad078467b52f7` |
| WSL MSI | `64d8c096738ab72e74e11c4d4afb1ae425627f71cc651734db1f887c82c07dfe` |

## Build And Verification

Final media build:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-InstallationMedia.ps1 `
  -RunName PublicRelease_20260606_1_1 `
  -Channel Full `
  -Version 1.1.0 `
  -RegistryMode GHCR `
  -BuildImages `
  -SigningMode Verify `
  -DockerDesktopInstallerPath "Installation Media\RC_20260526_1_1_win10fix\Full\payload\prereqs\Docker Desktop Installer.exe" `
  -WslInstallerPath "Installation Media\RC_20260526_1_1_win10fix\Full\payload\prereqs\WSL.msi" `
  -LmStudioInstallerPath "Installation Media\RC_20260526_1_1_win10fix\Full\payload\prereqs\LM Studio.exe"
```

Local checks completed on 2026-06-06:

- `python -m pytest`: `33 passed, 1 skipped`
- `npm.cmd run build` in `apps/ui`: passed
- `npm.cmd run build` in `apps/desktop`: passed
- `cargo check` in `apps/desktop/src-tauri`: passed
- `docker compose --project-name hypersearch config --quiet`: passed
- `docker compose --project-name hypersearch -f docker-compose.yml -f docker-compose.dev.yml config --quiet`: passed
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-ReleaseSecurity.ps1`: passed, license notices current, npm audits reported `0` vulnerabilities
- Full media build: passed, unsigned verification metadata written as expected
- ZIP integrity probe: 18 entries, setup/MSI/image archive/prerequisites present

Earlier full VM release gate remains the clean installer matrix evidence:

- Gate ID: `20260526-215927`
- Matrix ID: `20260526-215933`
- Result: `passed`
- Matrix: `9/9` scenarios passed, `0` failed

## Branch Triage

`origin/main` is the release branch and is clean at `82c56a2 Prepare HyperSearch 1.1 release` before the final documentation/hash update.

Merged into `origin/main`:

- `origin/ci/fix-tauri-frontend-build`
- `origin/security/update-tauri-origin-confusion`

Unmerged branches are Dependabot dependency-only branches. They were intentionally left out of the 1.1 release cut because merging them would change the already-tested dependency graph and require a new full VM release gate:

- Cargo/Tauri lockfile updates
- Docker `nginx` base-image update
- npm frontend/tooling updates, including React, Vite, plugin-react, Tauri CLI, React Query, and Node type updates
- Python `redis` optional dependency range update

These should be handled as post-1.1 maintenance PRs or a 1.1.1 release after normal dependency triage and matrix validation.

## Clean Tablet And Laptop Smoke

For each wiped Windows device:

1. Download `HyperSearch_1.1.0_Full_20260606.zip` from GitHub Releases.
2. Run `Get-FileHash .\HyperSearch_1.1.0_Full_20260606.zip -Algorithm SHA256` and compare it to the release-page hash.
3. Extract the ZIP to a local writable folder.
4. Confirm `checksums.sha256`, `signing-summary.json`, and `payload\images\hypersearch-images-1.1.0.tar` are present.
5. Run `HyperSearch_1.1.0_x64-setup.exe`.
6. Accept the expected unsigned-app/SmartScreen warning only after hash verification.
7. Choose Standard setup.
8. Confirm WSL and Docker Desktop setup either complete or request a reboot/resume.
9. Confirm bundled Docker images load from `payload\images` without requiring Docker Hub sign-in.
10. Confirm the stack reaches `/v1/live=200` and `/v1/ready=200` in the installer result.
11. Confirm LM Studio is installed/detected, or search-only/manual LM Studio state is clearly recorded.
12. Launch HyperSearch and confirm the UI opens at `http://127.0.0.1:8090`.
13. Run one normal search.
14. Export diagnostics from the desktop app before collecting notes.
15. Save the newest `%LOCALAPPDATA%\HyperSearch\logs\setup-summary-*.json` and diagnostics bundle if anything fails.

Release is ready to publish when both clean-device smoke passes are complete, or when any failures are captured with diagnostics and explicitly accepted.
