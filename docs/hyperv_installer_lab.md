# HyperSearch Hyper-V Installer Lab

The Hyper-V installer lab is the local fire-and-forget test harness for HyperSearch Windows release validation. It exists so installer changes can be tested repeatedly across clean and dirty machine states without borrowing real user computers.

## Goals

- Reset Windows VMs to known checkpoints.
- Run the real NSIS installer and postinstall prerequisite flow.
- Exercise the same installer core used by the visible Installation Wizard.
- Collect installer logs, command logs, setup summaries, desktop logs, and diagnostics.
- Fail the matrix when Docker readiness, image verification, Compose startup, profile import, or known regression checks fail.
- Keep all VM credentials and release artifacts out of git.

## Repo Components

- `tools/installer-lab/New-HyperSearchInstallerLab.ps1`
  - Configures an existing Hyper-V VM for installer testing.
  - Can create a VM from an existing VHDX when one is provided.
  - Enables nested virtualization, fixed memory, checkpoint mode, and guest file copy.

- `tools/installer-lab/New-HyperSearchDedicatedLabVm.ps1`
  - Downloads or consumes a Microsoft Windows Hyper-V evaluation image.
  - Extracts/imports it into a dedicated `HyperSearchLab-*` VM.
  - Configures nested virtualization, fixed memory, guest file copy, and a clean checkpoint.

- `tools/installer-lab/New-HyperSearchIsoLabVm.ps1`
  - Creates a clean Generation 2 Hyper-V VM directly from an official Windows ISO.
  - Applies the selected install image to a VHDX, injects unattended local-admin setup, enables nested virtualization, optionally enables vTPM, validates the Docker-supported Windows build floor, and writes the release-gate checkpoint.

- `tools/installer-lab/Initialize-HyperSearchReleaseGateLab.ps1`
  - Top-level setup command for the Windows 10 plus Windows 11 release-gate lab.
  - Given official ISO paths and a Full media path, creates both supported VMs, writes the ignored local release-gate config, and can immediately run the release gate.

- `tools/installer-lab/Invoke-HyperSearchVmReleaseGate.ps1`
  - One-command release gate for installer work.
  - Self-elevates when needed, runs installer unit/parser tests, runs the Hyper-V matrix, and writes a release-gate summary with links to stdout/stderr logs and matrix artifacts.

- `tools/installer-lab/Initialize-HyperSearchDedicatedGuest.ps1`
  - Starts the dedicated Microsoft dev VM baseline.
  - Uses the initial `User` account when available to create the password-backed lab administrator.
  - Verifies PowerShell Direct and writes a ready checkpoint.

- `tools/installer-lab/Invoke-HyperSearchGuestOfflineBootstrap.ps1`
  - Dedicated-VM fallback when the Microsoft no-password user cannot be used through PowerShell Direct.
  - Mounts the VM VHD offline and injects a one-shot LocalSystem bootstrap service.
  - Creates the lab administrator at boot, verifies PowerShell Direct, and writes a ready checkpoint.

- `tools/installer-lab/Invoke-HyperSearchInstallerMatrix.ps1`
  - Runs configured scenarios.
  - Restores checkpoints, starts VMs, waits for PowerShell Direct, copies media, runs the silent installer, collects data, and runs assertions.

- `tools/installer-lab/Update-HyperSearchLabWindowsImage.ps1`
  - Probes the dedicated VM Windows build.
  - Can restore a baseline checkpoint, run Windows Update passes inside the guest, reboot between passes, and create a new ready checkpoint only when the guest reaches the configured Docker-supported build floor.

- `tools/installer-lab/Repair-HyperSearchLabVmBaseline.ps1`
  - Restores the release-gate checkpoints, enables nested virtualization on the VM, optionally enables WSL/VirtualMachinePlatform/HypervisorPlatform inside the guest, restarts, verifies WSL/processor state, stops the VM, and optionally replaces the ready checkpoint.

- `tools/installer-lab/Assert-HyperSearchInstallResult.ps1`
  - Parses installer state and scenario assertions.
  - Verifies result status, Docker readiness, image verification, stack readiness, model IDs, and Compose `.env` BOM safety.

- `tools/installer-lab/configs/lab.example.json`
  - Example matrix with fresh, existing-Docker, BOM regression, and search-only scenarios.

- `tools/installer-lab/guest/Seed-ComposeEnvBom.ps1`
  - Guest preparation script for Dan's Compose `.env` BOM regression.

## Required Host Setup

- Windows 10/11 Pro, Enterprise, or Education with Hyper-V.
- Elevated PowerShell for lab setup and matrix runs.
- A Windows guest VM with a local administrator account.
- PowerShell Direct working from host to guest.
- Nested virtualization enabled for guests that install/run Docker Desktop.
- Enough disk space for release media, VHDX checkpoints, and copied diagnostics.

The current recommended guest account pattern is a local administrator such as `HyperSearchAdmin`. Avoid using the same name as the VM/computer name because Windows account resolution can silently skip local Administrators membership in unattended setup. Prefer a DPAPI-protected credential file so the password never appears in chat, shell history, or logs:

```powershell
.\tools\installer-lab\New-HyperSearchLabCredential.ps1 `
  -OutputPath C:\tmp\hypersearch-lab-credential.xml
```

Set `guestCredentialPath` in the local lab config to that file. The matrix still supports the older environment-variable path for short-lived local sessions:

```powershell
$env:HYPERSEARCH_LAB_GUEST_PASSWORD = '<guest-admin-password>'
```

Do not commit a config file containing real passwords.

## VM Baselines

Create these checkpoints over time:

- `clean-windows`: fresh Windows with guest account configured, no Docker, no LM Studio.
- `clean-windows-docker-supported-ready`: fresh Windows on a Docker-supported build, no Docker, no LM Studio.
- `docker-current`: Docker Desktop installed and working.
- `docker-stopped`: Docker installed but daemon stopped or not started.
- `lmstudio-current`: LM Studio installed and first-run initialized.
- `dirty-runtime`: existing `%LOCALAPPDATA%\HyperSearch` runtime with user data to verify reinstall preservation.
- `legacy-windows-unsupported`: older Windows baseline used only to verify graceful OS blocking and search-only/manual-upgrade behavior.

The harness does not require all checkpoints on day one. Start with `docker-current` and `existing-compose-env-bom`, then add clean-machine coverage after the base VM is ready.

The Microsoft WinDev2407 Hyper-V image currently resolves to Windows 11 Enterprise Evaluation 22H2 build `22621.3880`, which is below Docker Desktop's current Windows 11 support floor. Do not use it as the full Docker Desktop release gate. Keep it only for unsupported/legacy behavior testing unless a newer image is imported.

For the v1.1 release gate, create two supported clean baselines from official ISO media:

- `HyperSearchLab-Win10-22H2`: Windows 10 22H2 build `19045+`, Pro/Enterprise/Education.
- `HyperSearchLab-Win11-24H2`: Windows 11 23H2+ build `22631+`, Pro/Enterprise/Education.

The ISO files are intentionally not downloaded or committed by the repo. Put official Microsoft ISO media somewhere local, for example `E:\ISOs`, then run the top-level initializer:

```powershell
.\tools\installer-lab\Initialize-HyperSearchReleaseGateLab.ps1 `
  -Win10IsoPath E:\ISOs\Win10_22H2_English_x64.iso `
  -Win11IsoPath E:\ISOs\Win11_24H2_English_x64.iso `
  -MediaRoot ".\Installation Media\PublicRelease_1_1\Full" `
  -InstallerExe HyperSearch_1.1.0_x64-setup.exe `
  -Force
```

Set `HYPERSEARCH_LAB_GUEST_PASSWORD` first or provide an existing `C:\tmp\hypersearch-lab-credential.xml`. The initializer will pass that credential through to the ISO VM creator and write `tools/installer-lab/configs/release-gate.windows10-11.local.json`.

Use Enterprise or Education image names instead if that is the official ISO edition available locally:

```powershell
.\tools\installer-lab\Initialize-HyperSearchReleaseGateLab.ps1 `
  -Win10IsoPath E:\ISOs\Win10_22H2_English_x64.iso `
  -Win11IsoPath E:\ISOs\Win11_24H2_English_x64.iso `
  -Win10ImageName "*Windows 10 Enterprise*" `
  -Win11ImageName "*Windows 11 Enterprise*" `
  -MediaRoot ".\Installation Media\PublicRelease_1_1\Full" `
  -InstallerExe HyperSearch_1.1.0_x64-setup.exe `
  -Force
```

The underlying ISO VM creator will refuse to create the release-gate checkpoint unless the guest reaches Docker's supported build floor, unless `-AllowUnsupportedBuild` is explicitly provided for a legacy classification VM.

To try refreshing a dedicated guest through Windows Update and create a supported checkpoint only if the build target is reached:

```powershell
.\tools\installer-lab\Update-HyperSearchLabWindowsImage.ps1 `
  -VMName HyperSearchLab-WinDev `
  -CredentialPath C:\tmp\hypersearch-lab-credential.xml `
  -RestoreCheckpointName clean-windows-ready `
  -InstallUpdates `
  -CreateCheckpoint `
  -ReadyCheckpointName clean-windows-docker-supported-ready
```

If the update pass does not reach Windows build `22631+`, import a newer Windows 11 24H2/25H2 or Windows 10 22H2 build `19045` image instead of forcing Docker Desktop onto an unsupported build.

If Docker Desktop or WSL reports that virtualization is unavailable even though the host supports Hyper-V, repair and recapture the VM baselines before rerunning the gate:

```powershell
.\tools\installer-lab\Repair-HyperSearchLabVmBaseline.ps1 `
  -ConfigPath .\tools\installer-lab\configs\release-gate.windows10-11.local.json `
  -ReplaceCheckpoint
```

For the focused Windows 11 baseline loop, repair only that VM:

```powershell
.\tools\installer-lab\Repair-HyperSearchLabVmBaseline.ps1 `
  -ConfigPath .\tools\installer-lab\configs\dev-win11-standard-full.local.json `
  -VMName HyperSearchLab-Win11-24H2 `
  -CheckpointName clean-windows-docker-supported-ready `
  -CredentialPath C:\tmp\hypersearch-lab-credential.xml `
  -ReplaceCheckpoint
```

Do not use `-SkipGuestFeatureEnable` for this repair unless the guest optional features were already verified after boot. The repair should enable nested virtualization on the Hyper-V VM, ensure WSL/VirtualMachinePlatform/HypervisorPlatform inside the guest, restart gracefully inside the guest, install the bundled `payload\prereqs\WSL.msi` from the configured Full media if the WSL package is missing, verify WSL state, stop the VM, and replace the ready checkpoint only when `dockerSupportedReady=true`.

The matrix also re-applies `ExposeVirtualizationExtensions=true` immediately after restoring a Docker scenario checkpoint and writes `<scenario>\vm-host-preflight.json`. After PowerShell Direct connects, it writes `<scenario>\guest-wsl-preflight.json` before copying the full installer media. This protects the run from older checkpoints that restore nested virtualization as disabled, and from recaptured guests where WSL features are enabled but WSL2 still reports virtualization unavailable.

Scenarios can set `allowRebootResume=true`. When the first automated installer pass returns a blocked WSL/reboot state, the harness restarts the VM and reruns the installed `HyperSearchPrereqSetup.ps1` wrapper with the same automation config.

## Live Run Triage

If a VM run appears hung, capture a non-destructive live snapshot before stopping anything:

```powershell
.\tools\installer-lab\Get-HyperSearchLabLiveSnapshot.ps1 `
  -VMName HyperSearchLab-Win11-24H2 `
  -CredentialPath C:\tmp\hypersearch-lab-credential.xml `
  -GuestScenarioRoot C:\HyperSearchInstallerLab\win11-fresh-standard-full
```

The snapshot writes host VM state, guest process state, recent installer files, installer state tail, and recent command logs under `%LOCALAPPDATA%\HyperSearch\installer-lab\live-snapshots`.

If the guest installer wrote a final state but a stale PowerShell process is still holding the matrix open, stop only the matching guest installer processes:

```powershell
.\tools\installer-lab\Stop-HyperSearchLabGuestInstaller.ps1 `
  -VMName HyperSearchLab-Win11-24H2 `
  -CredentialPath C:\tmp\hypersearch-lab-credential.xml `
  -GuestScenarioRoot C:\HyperSearchInstallerLab\win11-fresh-standard-full
```

If the host matrix process remains wedged after guest cleanup, stop only release-gate/matrix processes for the active config:

```powershell
.\tools\installer-lab\Stop-HyperSearchLabHostRun.ps1 `
  -ConfigName dev-win11-standard-full.local.json
```

Finally, leave VMs off after interrupted runs:

```powershell
.\tools\installer-lab\Stop-HyperSearchLabVm.ps1 `
  -VMName HyperSearchLab-Win11-24H2
```

## Dedicated VM Creation

For local release testing, prefer a dedicated VM instead of reusing personal or work VMs. The bootstrap script defaults to Microsoft's Windows Development Environment Hyper-V package (`https://aka.ms/windev_VM_hyperv`), which is a large download and requires substantial disk space.

Example using a large local drive:

```powershell
.\tools\installer-lab\New-HyperSearchDedicatedLabVm.ps1 `
  -VMName HyperSearchLab-WinDev `
  -LabRoot E:\HyperSearchInstallerLab `
  -Download `
  -Extract `
  -Import `
  -CheckpointName clean-windows
```

The Microsoft development VM currently ships with a `User` account and no password. PowerShell Direct and unattended matrix runs require a password-backed local administrator account, so the first imported baseline may need a one-time console login to set the password or create the `HyperSearchAdmin` administrator account. After that, create the credential file with `New-HyperSearchLabCredential.ps1` and checkpoint the VM.

When the initial no-password `User` account is usable through PowerShell Direct, the guest can be initialized automatically:

```powershell
.\tools\installer-lab\Initialize-HyperSearchDedicatedGuest.ps1 `
  -VMName HyperSearchLab-WinDev `
  -CredentialPath C:\tmp\hypersearch-lab-credential.xml `
  -ReadyCheckpointName clean-windows-ready
```

If PowerShell Direct rejects the blank-password account, use the offline bootstrap fallback against the dedicated VM:

```powershell
.\tools\installer-lab\Invoke-HyperSearchGuestOfflineBootstrap.ps1 `
  -VMName HyperSearchLab-WinDev `
  -CredentialPath C:\tmp\hypersearch-lab-credential.xml `
  -ReadyCheckpointName clean-windows-ready `
  -ReplaceReadyCheckpoint
```

## Running The Matrix

1. Build Full release media.
2. Copy `tools/installer-lab/configs/lab.example.json` to a local file, for example `tools/installer-lab/configs/lab.local.json`.
3. Update `mediaRoot`, `installerExe`, `guestCredentialPath` or `guestUser`, and scenario VM/checkpoint names.
4. Run from elevated PowerShell:

```powershell
.\tools\installer-lab\Invoke-HyperSearchInstallerMatrix.ps1 `
  -ConfigPath .\tools\installer-lab\configs\lab.local.json
```

To run only one scenario:

```powershell
.\tools\installer-lab\Invoke-HyperSearchInstallerMatrix.ps1 `
  -ConfigPath .\tools\installer-lab\configs\lab.local.json `
  -ScenarioName existing-compose-env-bom
```

## Running The Release Gate

The preferred v1.1 path is the top-level release gate. It can self-elevate, run the unit/parser checks, then run the configured Windows 10 and Windows 11 Hyper-V scenarios:

```powershell
.\tools\installer-lab\Invoke-HyperSearchVmReleaseGate.ps1 `
  -ConfigPath .\tools\installer-lab\configs\release-gate.windows10-11.local.json
```

Use the committed example config as the template:

```powershell
Copy-Item `
  .\tools\installer-lab\configs\release-gate.windows10-11.example.json `
  .\tools\installer-lab\configs\release-gate.windows10-11.local.json
```

Edit the local file for the current release media path, installer filename, credential file, VM names, and checkpoint names. The local config is ignored by git.

Useful focused runs:

```powershell
.\tools\installer-lab\Invoke-HyperSearchVmReleaseGate.ps1 `
  -ConfigPath .\tools\installer-lab\configs\release-gate.windows10-11.local.json `
  -ScenarioName win11-fresh-standard-full

.\tools\installer-lab\Invoke-HyperSearchVmReleaseGate.ps1 `
  -ConfigPath .\tools\installer-lab\configs\release-gate.windows10-11.local.json `
  -ScenarioName win10-fresh-standard-full,win11-fresh-standard-full
```

### Fast Windows 11 Baseline Loop

While the installer is still being polished, use Windows 11 Standard Full as the baseline lane before returning to the full Windows 10 plus Windows 11 matrix. Copy `tools/installer-lab/configs/dev-win11-standard-full.example.json` to `dev-win11-standard-full.local.json`, set `mediaRoot` if needed, then run:

```powershell
.\tools\installer-lab\Invoke-HyperSearchVmReleaseGate.ps1 `
  -ConfigPath .\tools\installer-lab\configs\dev-win11-standard-full.local.json
```

This config restores `HyperSearchLab-Win11-24H2` to `clean-windows-docker-supported-ready`, runs the direct installer core in Standard mode, installs Docker and LM Studio, loads bundled images, starts the stack, and runs the normal host assertions.

The fast lane uses a progress watchdog in addition to the total installer timeout. The default dev settings poll every `30` seconds and fail after `8` consecutive polls with no observed process-tree, installer-state, Docker, or HyperSearch log-file changes. CPU churn is intentionally ignored because stale PowerShell processes can burn time without representing real installer progress. It also uses a shorter `dockerReadyTimeoutSeconds=240` automation value so Docker readiness bugs are surfaced quickly during development while the public wizard keeps the more patient default.

For direct installer-core scenarios, the host launches the guest runner asynchronously and polls `installer-process-result.json`. This avoids a known PowerShell Direct failure mode where the guest has already written a terminal installer result but the remoting job remains alive until the outer timeout. NSIS smoke scenarios also pass the installer state path into the guest runner so terminal-state detection and progress fingerprints can observe the same result file. When the guest runner sees a terminal installer state, it records `FinalStateDetected`, stops the stale wrapper process tree, writes the process result, and exits. When the watchdog fires, the scenario writes `installer-progress-watchdog.json`, stops the installer process tree, collects the guest snapshot, and returns the VM to a stopped state unless `-KeepVmRunning` is explicitly passed.

If this lane reports WSL2 virtualization unavailable, run the focused baseline repair command above before rerunning the gate.

Release-gate summaries are written under:

`%LOCALAPPDATA%\HyperSearch\installer-lab\release-gates\<gate-id>`

Each run includes:

- `release-gate.log`
- `release-gate-summary.json`
- stdout/stderr logs for unit tests and the Hyper-V matrix
- a config snapshot
- a matrix summary snapshot when the VM matrix starts

## How Automation Reaches The Installer

The lab creates a per-scenario `hypersearch-install-automation.json` file in the copied media root. The NSIS postinstall hook launches `HyperSearchPrereqSetup.ps1`, and the wrapper detects that file and runs:

```powershell
HyperSearchInstallationWizard.ps1 -Automated -ConfigPath <config>
```

That means automated scenarios bypass the visible Windows Forms UI but still exercise `HyperSearchInstallerCore.ps1`, Docker readiness gates, image verification, stack startup, profile writing, and diagnostics.

## Output

Runs are written under:

`%LOCALAPPDATA%\HyperSearch\installer-lab\runs\<run-id>`

Important files:

- `matrix.log`
- `matrix-summary.json`
- `<scenario>\host-scenario.log`
- `<scenario>\vm-host-preflight.json`
- `<scenario>\automation-config.json`
- `<scenario>\installer-process-result.json`
- `<scenario>\installer-progress-watchdog.json` when the no-progress watchdog fires
- `<scenario>\guest-data\...`
- `<scenario>\assertion-result.json`

## Release Gate

For v1.1, the release should not be finalized until these pass locally:

- `win10-fresh-standard-full`
- `win10-compose-env-bom`
- `win10-search-only-skip-lmstudio`
- `win11-fresh-standard-full`
- `win11-nsis-standard-full`
- `win11-compose-env-bom`
- `win11-search-only-skip-lmstudio`

The Standard Full scenarios are strict green release gates: they require `result=passed`, no installer warnings, Docker/image/stack readiness, and LM Studio plus `lms.exe` readiness. The public NSIS Standard Full lane also verifies opt-in Windows sign-in autostart registration with `--hypersearch-autostart`. Non-standard search-only lanes still accept warning results when optional LM Studio work is intentionally skipped.

Additional stale-environment coverage should be run before broader release:

- `docker-stopped`
- `dirty-runtime`
- `docker-current`
- `docker-broken-old`
- `legacy-windows-unsupported`

## Known Limits

- The first VM baseline still requires some manual setup or a prepared Windows VHDX.
- Docker Desktop inside a VM requires nested virtualization and may require a guest reboot.
- Windows RunOnce resume behavior may require an interactive guest logon. The harness uses a deterministic fallback: it restarts the VM and reruns the installed automated prerequisite wrapper after WSL/reboot blocks.
- GUI page testing should remain a small smoke test. Full regression should use automated config mode for determinism.
