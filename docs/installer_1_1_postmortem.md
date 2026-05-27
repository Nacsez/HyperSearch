# HyperSearch 1.1 Installer Postmortem

This postmortem covers the Windows installation failures reported after the HyperSearch launch, with emphasis on Rachel's assisted install and Dan's logged install attempt. The conclusion is that the 1.0 installer did too much work inside one mutable PowerShell script, did not enforce step boundaries, and treated partial prerequisite setup as success.

## Impact

- Users could complete the application installer but still be left without a working HyperSearch runtime.
- Docker failures were hard for non-technical users to interpret because the installer continued into image loading and model setup after Docker was not usable.
- The support path required manual log discovery, manual WSL/Docker troubleshooting, and repeated installer runs.
- The broken state was especially confusing for users who already had Docker Desktop installed, because "Docker installed" was not the same as "Docker engine and Compose are ready."

## Evidence

Rachel-style install:

- Docker Desktop installation completed, but `docker` was not available on `PATH` in the same installer session.
- WSL update/status commands returned failures or usage output instead of a clean updated state.
- Docker readiness produced repeated API `500`, named-pipe, and daemon-not-ready errors.
- The installer still attempted `docker load` and subsequent runtime setup after Docker was unavailable or not ready.

Dan-style install:

- Docker Desktop was already present, but the installed Docker CLI/engine path was old or broken enough that `docker info --format {{.ServerVersion}}` panicked repeatedly.
- The installer moved from readiness warnings into bundled image loading, then image setup failed.
- `lms get qwen2.5-7b-instruct` failed because that model key was not a valid/current LM Studio catalog key.

Code-level findings:

- `Write-SetupLog` used `Write-Output`, so log text entered the PowerShell success stream. Any function that returned values could be contaminated by log lines.
- Docker checks were not all-or-nothing. Some code treated "installer ran" or "Docker executable exists" as enough to continue.
- `imageSetup.verified` could be set `true` after bundled image load attempts even when a `docker load` command failed.
- The installer relied on `docker` being resolvable through the current process `PATH`, which is unreliable immediately after Docker Desktop installation.
- Online image pulls could trigger registry/auth/Docker Hub friction during first install.
- Model selection was hard-coded instead of validated as a release artifact.

## Root Causes

1. The installer had no strict separation between UI decisions, prerequisite detection, execution, and verification.
2. Steps did not return structured statuses, so blocked work could fall through into later steps.
3. PowerShell logging contaminated return streams, making state checks unreliable.
4. Docker readiness was under-specified. The installer needed to verify the engine, context, Compose, named pipe, and fatal stderr before loading images.
5. Full media was not treated as the default path, so installs could depend on registry access and Docker Hub behavior.
6. Diagnostics were produced, but not packaged into a single support bundle with enough command-level stdout/stderr.

## Corrective Actions In 1.1

- Replace the old prerequisite script with `HyperSearchInstallationWizard.ps1` plus `HyperSearchInstallerCore.ps1`.
- Keep all execution logic in the core; UI pages only collect choices and render progress.
- Use structured step statuses: `not_started`, `running`, `passed`, `warning`, `blocked`, and `failed`.
- Keep setup logging on file/host streams only. Core functions return explicit objects and do not write success-stream log text.
- Resolve `docker.exe` from known Docker Desktop install locations before falling back to `PATH`.
- Treat Docker readiness as a gate before image load or stack startup.
- Default release media to Full, with bundled Docker image archives and checksum verification.
- Mark image setup verified only when every load/pull succeeds and every expected image/tag/digest inspects successfully.
- Use explicit license consent before passing Docker Desktop or winget agreement flags.
- Write `%LOCALAPPDATA%\HyperSearch\install-profile.json` and import it from the desktop app.
- Export redacted diagnostics that include installer logs, command logs, env files, setup summaries, Docker/Compose state, and model download logs.

## Residual Risks

- Docker Desktop may still show unavoidable first-run terms, product prompts, or sign-in prompts. The 1.1 mitigation is to avoid Docker Hub pulls for Standard install, not to promise suppression of Docker UI.
- WSL feature enablement or kernel updates can require a Windows reboot. The 1.1 installer registers a resume path, but Windows policy or locked-down machines may still block automation.
- LM Studio CLI behavior can change. The 1.1 installer treats model download as optional and pending rather than failing the HyperSearch search stack.
- Corporate proxies, EDR tooling, and disabled virtualization can still block Docker/WSL. These are now classified as blocked states with diagnostics instead of silent fallthrough.
