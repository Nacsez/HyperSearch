# HyperSearch Windows Installation Wizard Test Plan

This document tracks the Windows installer path for HyperSearch 1.1. The default public installer is the **Full** media package and runs the **HyperSearch Installation Wizard**. The release-gate matrix covers Docker-supported Windows 10 22H2 and Windows 11 23H2+ baselines.

## Installer Responsibilities

- Present Standard and Custom install paths.
- Record explicit license consent before passing Docker Desktop, WSL, LM Studio, or winget agreement flags.
- Copy the bundled HyperSearch runtime stack into `%LOCALAPPDATA%\HyperSearch\runtime`.
- Preserve existing user data, `.env`, Docker state, cache, exports, and logs on reinstall.
- Detect Windows version/build, elevation, reboot-pending state, WSL, Docker Desktop, Docker CLI, Compose, disk/network state where available, LM Studio, and hardware profile.
- Install or repair WSL from bundled Full media when present, fall back to `--web-download` when required, then register a resume-after-reboot step if Windows must restart.
- Install or repair Docker Desktop in Standard mode, resolve `docker.exe` from known install paths, and wait for clean Docker readiness before image setup.
- Load bundled Docker image archives in Standard Full installs, then inspect expected image references before setting `imageSetup.verified=true`.
- Keep online image pulls Custom-only for 1.1.
- Install LM Studio from bundled media or winget where automation is supported, launch it once, and poll for `lms.exe`.
- When LM Studio cannot be installed or initialized non-interactively, record `lmStudio.pending=true`, keep the Docker search stack ready, and disable LLM features in the imported profile until the user finishes LM Studio setup.
- Configure the first-run setup profile in `%LOCALAPPDATA%\HyperSearch\install-profile.json`.
- When selected, register per-user Windows sign-in startup with the desktop `--hypersearch-autostart` argument and record the registration state in the setup profile.
- Start the Docker stack during the wizard and verify `compose ps`, `/v1/live`, and `/v1/ready`.
- Export installer diagnostics with setup summaries, command logs, redacted profiles/env files, Docker/Compose state, and model logs.

## Standard Fresh Windows Test Pass

1. Start from a supported Windows 10 or Windows 11 VM with no WSL, no Docker Desktop, and no LM Studio.
2. Run the NSIS setup EXE from the generated Full `Installation Media` folder.
3. Confirm the post-install page opens **HyperSearch Installation Wizard**.
4. Accept the license consent page.
5. Choose Standard install.
6. Choose a setup profile and model preference.
7. Confirm bundled WSL MSI install/repair runs when present, or WSL install/update falls back to `--web-download`.
8. If a reboot is required, reboot and confirm the wizard resumes without asking the tester to rerun setup manually.
9. Confirm Docker Desktop installs or repairs with WSL2 mode and license acceptance.
10. Confirm Docker readiness passes before any `docker load` command appears in command logs.
11. Confirm bundled image archives load and every expected image inspects successfully.
12. Confirm LM Studio installs or is detected, or is recorded as pending with installer attempt logs and a manual action.
13. Confirm model download is either started or marked pending without failing the search stack.
14. Confirm `docker compose up -d` runs and `/v1/live` plus `/v1/ready` pass.
15. If sign-in startup was selected, confirm the HKCU Run value points to the installed desktop executable with `--hypersearch-autostart`.
16. Launch HyperSearch and confirm the desktop app imports `install-profile.json`.
17. Open desktop Settings and run **Export Diagnostics**.

## Required Scenario Matrix

- Fresh Windows 10 22H2 build 19045+: no WSL, no Docker, no LM Studio. Standard install completes after any required reboot resume.
- Fresh Windows 11 23H2+ build 22631+: no WSL, no Docker, no LM Studio. Standard install completes after any required reboot resume.
- Existing Docker current: installer detects and uses it without reinstalling.
- Existing old/broken Docker like Dan: wizard classifies repair/upgrade required and verifies after repair.
- Docker installed but PATH stale like Rachel: wizard resolves direct Docker path and blocks image load until readiness passes.
- Docker daemon not ready: wizard waits and records fatal stderr without running image setup early.
- Full installer offline after launch: bundled images load and HyperSearch starts without Docker Hub.
- Custom skip Docker: wizard records Docker skipped and blocks image/stack setup clearly.
- Custom skip LM Studio: HyperSearch installs search-only and marks LLM setup optional.
- Custom online images: registry or proxy failure records command logs and blocks images without setting verified.
- LM Studio installer failure: wizard records `lmStudio.pending=true`, records installer exit details, writes `profile.mode=lmstudio-pending`, disables LLM features, and still finishes with search stack ready.
- Model download failure: wizard records model pending and still finishes with search stack ready.
- Reinstall over existing runtime: user data, exports, cache, and `.env` are preserved.

## Automated Hyper-V Lab Gate

The local release gate is driven by `tools/installer-lab/Invoke-HyperSearchVmReleaseGate.ps1`, which runs unit/parser tests and then calls `tools/installer-lab/Invoke-HyperSearchInstallerMatrix.ps1`.

Use `tools/installer-lab/configs/dev-win11-standard-full.local.json` as the tight development loop until the Windows 11 Standard Full path is clean. That lane polls progress every `30` seconds, fails after `8` consecutive no-progress polls, and uses `dockerReadyTimeoutSeconds=240` to shorten Docker readiness failures during development. `installer-progress-watchdog.json` captures the process tree, watched files, and last observed progress. After that lane passes reliably, return to `release-gate.windows10-11.local.json` for the full matrix.

If the lane reports WSL2 virtualization unavailable, repair and recapture the Win11 baseline before rerunning:

```powershell
.\tools\installer-lab\Repair-HyperSearchLabVmBaseline.ps1 `
  -ConfigPath .\tools\installer-lab\configs\dev-win11-standard-full.local.json `
  -VMName HyperSearchLab-Win11-24H2 `
  -CheckpointName clean-windows-docker-supported-ready `
  -CredentialPath C:\tmp\hypersearch-lab-credential.xml `
  -ReplaceCheckpoint
```

Docker scenarios also write `vm-host-preflight.json` after checkpoint restore. That preflight confirms or reapplies host-side nested virtualization before the guest boots.

Minimum automated scenarios before publishing 1.1:

- `win10-fresh-standard-full`
- `win10-compose-env-bom`
- `win10-search-only-skip-lmstudio`
- `win11-fresh-standard-full`
- `win11-nsis-standard-full`
- `win11-compose-env-bom`
- `win11-search-only-skip-lmstudio`

The Standard Full scenarios are strict green release gates: installer result must be `passed`, no installer warnings are allowed, Docker/Compose/images/stack must be ready, and LM Studio plus `lms.exe` must be detected. The `win11-nsis-standard-full` lane additionally verifies opt-in login autostart registration for the real public installer path.

Additional stale-environment scenarios before broad distribution:

- `docker-stopped`
- `dirty-runtime`
- `docker-current`
- `docker-broken-old`
- `legacy-windows-unsupported`

Each scenario must collect `installer-state.json`, copied `%LOCALAPPDATA%\HyperSearch` logs, and `assertion-result.json`. The matrix fails when Docker readiness, image verification, stack readiness, invalid model IDs, Compose `.env` BOM checks, or LM Studio-pending profile safety checks fail.

## Regression Assertions

- `Write-SetupLog` must not use `Write-Output`.
- Installer core functions must return explicit objects or mutate setup state; log text must not contaminate success streams.
- `imageSetup.verified` must be all-or-nothing after load/pull plus image inspection.
- Docker readiness must check engine version, `docker info`, Compose, context, named pipe, and fatal stderr/panic text.
- `docker load` and `docker compose up` must not run before Docker readiness passes.
- WSL decision logic must cover missing WSL, update required, reboot pending, and resume registration.
- Docker installer args must include license acceptance and WSL2 backend selection.
- LM Studio bundled attempts must be logged with exit code and hex exit code; winget fallback must include silent, no-interactivity, package agreement, and source agreement flags.
- If LM Studio is pending, the profile must be `lmstudio-pending` with LLM disabled so the app starts in a valid search-ready state.
- Recovered LM Studio installer attempts must stay in `lmStudio.installAttempts` and command logs without producing global installer warnings when a later attempt succeeds.
- Strict Standard Full lanes must fail if any installer warning remains.
- Opt-in login autostart must record the HKCU Run command and the desktop app must recognize `--hypersearch-autostart`.
- Model catalog must contain `google/gemma-3-1B-it-QAT`, `qwen2.5-7b-1m`, and `openai/gpt-oss-20b`.
- The invalid old model key `qwen2.5-7b-instruct` must not appear in installer code or desktop defaults.
- Desktop startup must import `install-profile.json` and diagnostics must export redacted profile files.
- Installer automation mode must accept a JSON config and run the same installer core as the visible wizard.
- Hyper-V lab scripts must parse and must keep credentials out of committed config files.
- Compose `.env` files must be written without UTF-8 BOM and existing BOMs must be stripped before desktop rewrites.

## Logs And Diagnostics

Installer setup logs:

`%LOCALAPPDATA%\HyperSearch\logs\installer-*.log`

Full PowerShell setup transcripts:

`%LOCALAPPDATA%\HyperSearch\logs\installer-transcript-*.log`

Machine-readable setup summaries:

`%LOCALAPPDATA%\HyperSearch\logs\setup-summary-*.json`

Command stdout/stderr logs:

`%LOCALAPPDATA%\HyperSearch\logs\commands`

Setup profile:

`%LOCALAPPDATA%\HyperSearch\install-profile.json`

Diagnostics exports:

`%LOCALAPPDATA%\HyperSearch\diagnostics`

Asynchronous model download logs:

`%LOCALAPPDATA%\HyperSearch\logs\model-download-*.log`

For issue reports, collect the newest installer diagnostics bundle and the desktop **Export Diagnostics** output. These should be enough to diagnose WSL, Docker, image loading, Compose, and model setup without asking the user to manually find individual command errors.
