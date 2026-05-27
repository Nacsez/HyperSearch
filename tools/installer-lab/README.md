# HyperSearch Installer Lab

This folder contains the local Hyper-V automation harness for repeatable Windows installer testing.

The lab is intentionally file and checkpoint driven:

- Keep release media outside git under `Installation Media/`.
- Keep VM credentials outside git through a DPAPI-protected credential file or short-lived environment variables.
- Reset VMs to named Hyper-V checkpoints before each scenario.
- Drop `hypersearch-install-automation.json` into a per-scenario copy of the media root.
- Run the NSIS installer silently so its postinstall hook launches the same installer core used by the public wizard.
- Collect `%LOCALAPPDATA%\HyperSearch` logs and a host-side scenario summary after each run.

## Minimum Setup

1. Create or import dedicated Windows release-gate VMs in Hyper-V.

   For Docker-supported v1.1 release testing, prefer official ISO media over the older Microsoft WinDev Hyper-V package:

   ```powershell
   .\tools\installer-lab\Initialize-HyperSearchReleaseGateLab.ps1 `
     -Win10IsoPath E:\ISOs\Win10_22H2_English_x64.iso `
     -Win11IsoPath E:\ISOs\Win11_24H2_English_x64.iso `
     -MediaRoot ".\Installation Media\PublicRelease_1_1\Full" `
     -InstallerExe HyperSearch_1.1.0_x64-setup.exe `
     -Force
   ```

   Use Pro, Enterprise, or Education images that meet Docker Desktop's supported build floor: Windows 10 22H2 build `19045+` or Windows 11 23H2 build `22631+`.
   Set `HYPERSEARCH_LAB_GUEST_PASSWORD` first, or provide `C:\tmp\hypersearch-lab-credential.xml`, so the initializer can create the unattended local administrator.

   The older Microsoft WinDev path remains useful for unsupported/legacy classification testing:

   ```powershell
   .\tools\installer-lab\New-HyperSearchDedicatedLabVm.ps1 `
     -VMName HyperSearchLab-WinDev `
     -LabRoot E:\HyperSearchInstallerLab `
     -Download `
     -Extract `
     -Import `
     -CheckpointName clean-windows
   ```

   Or configure an existing dedicated Windows VM:

   ```powershell
   .\tools\installer-lab\New-HyperSearchInstallerLab.ps1 -ConfigPath .\tools\installer-lab\configs\lab.example.json -VMName HyperSearchLab-Win11
   ```

2. Create a local administrator account in the guest.

   For the Microsoft dev VM baseline, try the automated initializer:

   ```powershell
   .\tools\installer-lab\Initialize-HyperSearchDedicatedGuest.ps1 `
     -VMName HyperSearchLab-WinDev `
     -CredentialPath C:\tmp\hypersearch-lab-credential.xml `
     -ReadyCheckpointName clean-windows-ready
   ```

   If the blank-password Microsoft `User` account cannot be used through PowerShell Direct, initialize the dedicated VM offline:

   ```powershell
   .\tools\installer-lab\Invoke-HyperSearchGuestOfflineBootstrap.ps1 `
     -VMName HyperSearchLab-WinDev `
     -CredentialPath C:\tmp\hypersearch-lab-credential.xml `
     -ReadyCheckpointName clean-windows-ready `
     -ReplaceReadyCheckpoint
   ```

3. Confirm PowerShell Direct works from an elevated host PowerShell:

   ```powershell
   Invoke-Command -VMName HyperSearchLab-Win11 -Credential (Get-Credential) -ScriptBlock { $PSVersionTable.PSVersion }
   ```

4. Enable nested virtualization and guest file copy if the VM was not created by `New-HyperSearchDedicatedLabVm.ps1`:

   ```powershell
   .\tools\installer-lab\New-HyperSearchInstallerLab.ps1 -ConfigPath .\tools\installer-lab\configs\lab.example.json -VMName HyperSearchLab-Win11
   ```

   If a matrix run reports Docker/WSL virtualization errors, repair the release-gate baselines and recapture their ready checkpoints:

   ```powershell
   .\tools\installer-lab\Repair-HyperSearchLabVmBaseline.ps1 `
     -ConfigPath .\tools\installer-lab\configs\release-gate.windows10-11.local.json `
     -ReplaceCheckpoint
   ```

   For the focused Windows 11 lane, repair just the Win11 VM:

   ```powershell
   .\tools\installer-lab\Repair-HyperSearchLabVmBaseline.ps1 `
     -ConfigPath .\tools\installer-lab\configs\dev-win11-standard-full.local.json `
     -VMName HyperSearchLab-Win11-24H2 `
     -CheckpointName clean-windows-docker-supported-ready `
     -CredentialPath C:\tmp\hypersearch-lab-credential.xml `
     -ReplaceCheckpoint
   ```

   The matrix also runs a host preflight after checkpoint restore. Docker scenarios re-enable `ExposeVirtualizationExtensions` before VM boot and write `vm-host-preflight.json`, so stale checkpoint VM settings fail early or self-correct before media copy and installer execution.

5. Build Full release media.
6. Copy `configs\release-gate.windows10-11.example.json` to a local ignored file, set real paths and VM names, then run the one-command gate:

   ```powershell
   Copy-Item `
     .\tools\installer-lab\configs\release-gate.windows10-11.example.json `
     .\tools\installer-lab\configs\release-gate.windows10-11.local.json

   .\tools\installer-lab\Invoke-HyperSearchVmReleaseGate.ps1 `
     -ConfigPath .\tools\installer-lab\configs\release-gate.windows10-11.local.json
   ```

   For faster iteration while debugging the Standard path, start with the Windows 11 baseline config:

   ```powershell
   Copy-Item `
     .\tools\installer-lab\configs\dev-win11-standard-full.example.json `
     .\tools\installer-lab\configs\dev-win11-standard-full.local.json

   .\tools\installer-lab\Invoke-HyperSearchVmReleaseGate.ps1 `
     -ConfigPath .\tools\installer-lab\configs\dev-win11-standard-full.local.json
   ```

   The dev config uses a progress watchdog: it polls installer progress every `30` seconds and fails after `8` consecutive no-progress polls. It also sets `dockerReadyTimeoutSeconds=240` so Docker readiness failures do not dominate the edit-test loop. The full matrix example uses looser defaults so long Docker operations can continue as long as logs, process CPU, or setup state are still moving.

   For the final 1.1 release gate, Standard Full scenarios are strict green: expected result `passed`, no installer warnings, Docker/images/stack ready, and LM Studio plus `lms.exe` ready. The `win11-nsis-standard-full` scenario runs the public NSIS installer path and verifies the opt-in Windows sign-in autostart Run key.

## Expected Local Files

The example configs expect these fields to be edited locally:

- `mediaRoot`: extracted Full media folder containing `HyperSearch_1.1.0_x64-setup.exe`.
- `guestCredentialPath`: preferred DPAPI-protected credential file created by `New-HyperSearchLabCredential.ps1`.
- `guestUser`: local administrator in the VM when not using `guestCredentialPath`.
- `guestPasswordEnv`: fallback environment variable that contains the guest password.
- `scenarios[].vmName`: VM to run.
- `scenarios[].checkpoint`: checkpoint to restore before the scenario.

Do not commit `lab.local.json` if it contains machine-specific paths or usernames.

## Scenario Results

Each matrix run writes to:

`%LOCALAPPDATA%\HyperSearch\installer-lab\runs\<run-id>`

Per scenario, the harness writes:

- `host-scenario.log`
- `vm-host-preflight.json`
- `automation-config.json`
- `installer-state.json`
- `installer-progress-watchdog.json` if the no-progress watchdog stopped a stalled installer
- copied `HyperSearch` guest logs
- `assertion-result.json`

The matrix summary is written to `matrix-summary.json`.

The release gate additionally writes:

`%LOCALAPPDATA%\HyperSearch\installer-lab\release-gates\<gate-id>`

with `release-gate.log`, `release-gate-summary.json`, unit-test stdout/stderr, matrix stdout/stderr, and a matrix summary snapshot.
