# HyperSearch 1.1 Windows Installation Wizard Design

HyperSearch 1.1 ships a Windows-first Installation Wizard. The goal is a one-run Standard install that handles prerequisites in the right order, explains what will be installed, records explicit consent, and stops cleanly when a machine is not ready instead of continuing into misleading failures.

## User Experience

The public installer path is named **HyperSearch Installation Wizard**. The wizard uses a small wizard-hat visual treatment and a conventional page flow:

1. Welcome
2. License consent
3. Standard or Custom install
4. Setup profile
5. Progress with expandable logs
6. Finish with result and diagnostics path

Standard install is the default. It installs or repairs Docker Desktop, uses bundled Docker images from Full media, attempts LM Studio setup when missing, starts the HyperSearch stack, writes first-run profile settings, and verifies service health. HyperSearch search-stack readiness is independent from LM Studio readiness.

The wizard also offers an opt-in Windows sign-in startup setting. When selected, setup registers the installed desktop app in `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` with `--hypersearch-autostart`; the desktop app then prepares the runtime and starts the managed Docker stack in the background after sign-in.

Custom install exposes:

- Docker install/repair/skip
- Docker per-user or all-users mode
- LM Studio install/skip
- Docker image source: bundled, online, or skip
- Stack startup yes/no
- Start HyperSearch when signing into Windows yes/no
- Usage preset
- Model choice
- Model download yes/no

## Architecture

The installer is split into three layers:

- `installer/windows/HyperSearchPrereqSetup.ps1`: compatibility launcher used by NSIS and old entrypoints.
- `installer/windows/HyperSearchInstallationWizard.ps1`: Windows Forms wizard UI.
- `installer/windows/HyperSearchInstallerCore.ps1`: pure installer core with detection, execution, verification, profile writing, and diagnostics.

The core is the only layer that changes machine state. UI pages pass an options object into `Invoke-HyperSearchInstallation`.

Core functions must not write log text to the PowerShell success stream. Logging goes to file and host output through `Write-SetupLog`. Each installer phase returns state through the setup state object and updates a structured step status.

## Step Statuses

Every major installer phase reports one of these statuses:

- `not_started`: the step has not run.
- `running`: the step is active.
- `passed`: the step completed and verified.
- `warning`: setup can continue, but the user/support team should review the warning.
- `blocked`: the step could not complete because a prerequisite is missing or unavailable.
- `failed`: an unexpected setup error occurred.

The wizard can finish with `warning` when HyperSearch search is ready but optional model setup is pending. It should finish `blocked` when Docker/WSL/image verification prevents stack startup.

## License Handling

The wizard records explicit component-license consent before passing third-party installer agreement flags.

Docker Desktop install/repair uses supported installer flags including `--accept-license`, WSL2 backend selection, and per-user or all-users mode. LM Studio winget fallback uses `--silent`, `--disable-interactivity`, `--accept-package-agreements`, and `--accept-source-agreements`.

Docker Desktop may still show unavoidable first-run product prompts or sign-in UI. HyperSearch Standard install avoids Docker Hub pulls by using bundled images, so Docker sign-in is not required for HyperSearch startup.

## WSL And Docker Flow

The installer captures:

- Windows caption, version, build, architecture
- elevation state
- reboot-pending state
- WSL command availability and `wsl --status`
- Docker Desktop path/version
- Docker CLI path
- Docker context
- Docker engine readiness
- Compose availability
- named-pipe visibility
- disk and command logs where applicable

When WSL is missing or outdated, the core prefers the bundled Microsoft WSL MSI when Full media supplies one, then falls back to:

- `wsl --install --no-distribution --web-download`
- `wsl --update --web-download`

If Windows reports a pending reboot, the core registers a RunOnce resume command for the Installation Wizard and marks WSL/Docker/image setup blocked until reboot.

Docker readiness gates image setup. The core waits for:

- `docker version`
- `docker info`
- `docker compose version`
- `docker context show`
- no fatal stderr such as daemon, named-pipe, API `500`, or panic text

`docker load`, `docker compose pull`, and `docker compose up` do not run until readiness passes.

## Image And Runtime Flow

Full media carries Docker image archives in `payload\images` and optional digest manifests. The installer loads each archive, then inspects every expected image reference before setting `imageSetup.verified=true`.

Online image pulls are Custom-only for 1.1. If online pull is selected and registry access fails, the installer records the exact Docker/Compose stdout/stderr path and keeps the images step blocked.

Stack startup runs:

- `docker compose up -d`
- `docker compose ps`
- `GET /v1/live`
- `GET /v1/ready`
- `docker compose logs --tail 260` on readiness failure

## LM Studio And Model Flow

The wizard prefers a bundled LM Studio installer. It tries silent bundled install modes first and records every attempt, command log path, exit code, and hexadecimal exit code. If unavailable, it falls back to winget with silent and agreement flags.

After LM Studio install/detection, the wizard launches LM Studio once and polls for `lms.exe`. LM Studio documentation says `lms` ships with LM Studio but requires LM Studio to be run at least once before use. If the installer cannot detect LM Studio or `lms.exe` after setup, it records `lmStudio.pending=true`, writes a manual action, and configures HyperSearch as search-ready with `HYPERSEARCH_LLM_ENABLED=false` and profile mode `lmstudio-pending`. It does not fail the whole install when model automation is unavailable.

Initial model catalog:

- Low-resource: `google/gemma-3-1B-it-QAT`
- Standard: `qwen2.5-7b-1m`
- High-resource: `openai/gpt-oss-20b`

The installer should validate this catalog during release build when a network-enabled environment is available. If `lms get` cannot run non-interactively, the setup result is warning/pending rather than failed.

## Setup Profile

The installer writes:

`%LOCALAPPDATA%\HyperSearch\install-profile.json`

It includes:

- selected components
- login autostart request, registry command, and registration status
- Docker mode
- image source
- LM Studio path and CLI readiness
- LM Studio pending/manual action, installer attempts, and installer exit codes
- provider base URL
- selected model ID
- LLM enabled/search-only state
- usage preset
- setup result
- log paths

For backward compatibility, it also writes:

`%LOCALAPPDATA%\HyperSearch\install-profile.env`

The desktop launcher imports both files, with JSON carrying the richer 1.1 setup state and env preserving older profile behavior.

## Diagnostics

Installer diagnostics include:

- setup summary JSON
- installer log
- transcript log
- command stdout/stderr logs
- redacted root `.env`
- redacted compose `.env`
- redacted install profile JSON/env
- WSL status output
- Docker state
- Compose state/logs
- model download logs and helper script path

The desktop diagnostics export also copies redacted installer profiles so support can connect first-run settings to runtime behavior.

## Troubleshooting Classifications

- WSL blocked: WSL missing/outdated, virtualization disabled, or reboot required.
- Docker blocked: Docker Desktop missing, repair required, daemon not ready, fatal stderr, or Compose unavailable.
- Image blocked: archive missing, checksum/signature failure, `docker load` failure, missing inspected images, or online pull failure.
- Stack blocked: images verified but Compose startup or health checks failed.
- LM Studio warning: optional provider install skipped, installer failed, app detection failed, or `lms.exe` was not ready. Search-stack readiness must remain valid and the profile must not enable LLM features while LM Studio is pending.
- Model warning: selected model is pending because non-interactive LM Studio download was unavailable.
- Login autostart warning: the user selected Windows sign-in startup, but the installed desktop executable was missing or the per-user Run key could not be updated. This should not invalidate Docker/search-stack setup, but strict release gates require the Standard Full public installer path to register it successfully.
