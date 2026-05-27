from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
CORE = REPO_ROOT / "installer" / "windows" / "HyperSearchInstallerCore.ps1"
WIZARD = REPO_ROOT / "installer" / "windows" / "HyperSearchInstallationWizard.ps1"
PREREQ = REPO_ROOT / "installer" / "windows" / "HyperSearchPrereqSetup.ps1"
MEDIA = REPO_ROOT / "scripts" / "Build-InstallationMedia.ps1"
DESKTOP = REPO_ROOT / "apps" / "desktop" / "src-tauri" / "src" / "main.rs"
LAB_ROOT = REPO_ROOT / "tools" / "installer-lab"
LAB_MATRIX = LAB_ROOT / "Invoke-HyperSearchInstallerMatrix.ps1"
LAB_SETUP = LAB_ROOT / "New-HyperSearchInstallerLab.ps1"
LAB_ASSERT = LAB_ROOT / "Assert-HyperSearchInstallResult.ps1"
LAB_ISO = LAB_ROOT / "New-HyperSearchIsoLabVm.ps1"
LAB_GATE = LAB_ROOT / "Invoke-HyperSearchVmReleaseGate.ps1"
LAB_INIT_GATE = LAB_ROOT / "Initialize-HyperSearchReleaseGateLab.ps1"
LAB_REPAIR_BASELINE = LAB_ROOT / "Repair-HyperSearchLabVmBaseline.ps1"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def test_installer_logging_does_not_contaminate_success_stream() -> None:
    core = read(CORE)
    prereq = read(PREREQ)

    write_setup_log = core[core.index("function Write-SetupLog") : core.index("function Add-SetupWarning")]
    setup_command = core[core.index("function Invoke-SetupCommand") : core.index("function Get-MediaManifest")]
    process_arg_quote = prereq[prereq.index("function ConvertTo-ProcessArgument") : prereq.index("Write-WrapperLog \"Wrapper start")]
    assert "Write-Output" not in write_setup_log
    assert "Write-Host" in write_setup_log
    assert "Write-Output" not in prereq
    assert "ConvertTo-ProcessArgument" in prereq
    assert "ConvertTo-ProcessArgument" in core
    assert "argumentLine=$argumentLine" in setup_command
    assert "function ConvertTo-CommandText" in core
    assert 'replace "`0", ""' in core
    assert "ConvertTo-CommandText (Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue)" in setup_command
    assert "-ArgumentList $argumentLine" in prereq
    assert "ArgumentList = $argumentLine" in setup_command
    assert "ArgumentList = $Arguments" not in setup_command
    assert "-ArgumentList $argsList" not in prereq
    assert "-replace '(\\\\*)\"'" in process_arg_quote


def test_powershell_scripts_parse() -> None:
    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if not powershell:
        pytest.skip("PowerShell is not available")

    lab_scripts = sorted(LAB_ROOT.glob("*.ps1")) + sorted((LAB_ROOT / "guest").glob("*.ps1"))
    for script in [CORE, WIZARD, PREREQ, MEDIA, *lab_scripts]:
        command = (
            "$errors = $null; "
            f"[System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw '{script}'), [ref]$errors) | Out-Null; "
            "if ($errors -and $errors.Count -gt 0) { $errors | Format-List *; exit 1 }"
        )
        result = subprocess.run(
            [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
            text=True,
            capture_output=True,
            check=False,
        )
        assert result.returncode == 0, result.stdout + result.stderr


def test_image_verification_is_all_or_nothing() -> None:
    core = read(CORE)

    assert "$State.imageSetup.verified = ($State.imageSetup.errors.Count -eq 0 -and $present.Ok)" in core
    assert 'docker load failed for' in core
    assert "Test-RuntimeImagesPresent" in core
    assert '$script:setupState["imageSetup"]["verified"] = $true' not in core
    assert "$State.imageSetup.verified = $true" not in core


def test_docker_readiness_gates_image_setup() -> None:
    core = read(CORE)
    find_docker = core[core.index("function Find-DockerCli") : core.index("function Test-DockerFatalOutput")]

    assert "function Find-DockerCli" in core
    assert "function Test-DockerDesktopOsSupported" in core
    assert "Windows 11 23H2 build 22631 or newer" in core
    assert "Windows 10 22H2 build 19045 or newer" in core
    assert '"Enterprise|Professional|Education"' in core
    assert '"Enterprise|Professional|Education|Core|Home"' not in core
    assert "$candidates = @(Get-KnownDockerCliCandidates)" in find_docker
    assert "return [string]$matches[0]" in find_docker
    assert "Programs\\DockerDesktop\\resources\\bin\\docker.exe" in core
    assert "Programs\\DockerDesktop\\Docker Desktop.exe" in core
    assert '"info", "--format", "{{.ServerVersion}}"' in core
    assert '"info"' in core
    assert '"compose", "version"' in core
    assert '"context", "show"' in core
    assert "panic:" in core
    assert "request returned 500 internal server error" in core
    assert '"\\\\.\\pipe\\docker_engine"' in core

    docker_step = core.index("Install-OrRepairDocker -State $State")
    image_step = core.index("Initialize-DockerImages -State $State")
    assert docker_step < image_step
    image_setup = core[core.index("function Initialize-DockerImages") : core.index("function Find-LmStudio")]
    assert image_setup.index('$State.options.ImageSource -eq "skip"') < image_setup.index('Docker engine was not ready.')
    assert "WSL setup skipped because Docker installation was skipped." in core
    assert "Start-HyperSearchStack -State $State" in core


def test_wsl_resume_and_installer_flags_are_present() -> None:
    core = read(CORE)
    wsl_flow = core[core.index("function Invoke-ElevatedWsl") : core.index("function Get-KnownDockerCliCandidates")]

    assert '"--install", "--no-distribution", "--web-download"' in core
    assert '"--update", "--web-download"' in core
    assert "Invoke-WslSetupAttempt" in wsl_flow
    assert "Invoke-WslUpdateAttempt" in wsl_flow
    assert "Install-BundledWslMsi" in wsl_flow
    assert "wsl-msi-install" in wsl_flow
    assert "Bundled WSL was installed and needs a Windows restart" in wsl_flow
    assert "Test-WslVersionSupported" in wsl_flow
    assert "wslAlreadyPresent" in wsl_flow
    assert "WSL 2 kernel file is not found" in wsl_flow
    assert "wsl-install-fallback" in wsl_flow
    assert "does not support --no-distribution" in wsl_flow
    assert "$NamePrefix-update-fallback" in wsl_flow
    assert "wsl-version-after-setup" in wsl_flow
    assert "needs a Windows restart before Docker setup can continue" in wsl_flow
    assert "Stdout = \"\"; Stderr = \"\"" in wsl_flow
    assert "HyperSearchInstallationWizardResume" in core
    assert "--accept-license" in core
    assert "--backend=wsl-2" in core
    assert "--always-run-service" in core
    assert '"--user"' in core
    assert '"all-users"' in core


def test_wsl_virtualization_block_is_explicit_and_non_resumable() -> None:
    core = read(CORE)
    wsl_flow = core[core.index("function Test-WslVirtualizationBlocked") : core.index("function Get-KnownDockerCliCandidates")]
    install_flow = core[core.index("function Invoke-HyperSearchInstallation") : core.index("function Invoke-HyperSearchModelDownloadOnly")]

    assert "function Test-WslVirtualizationBlocked" in wsl_flow
    assert "function Test-WslServiceMissing" in wsl_flow
    assert "wsl-status-after-setup" in wsl_flow
    assert "virtualization is not enabled" in wsl_flow
    assert "WSL2 is unable to start" in wsl_flow
    assert "Wsl/ERROR_SERVICE_DOES_NOT_EXIST" in wsl_flow
    assert "specified service does not exist as an installed service" in wsl_flow
    assert "$State.wsl.serviceMissing = Test-WslServiceMissing -StatusText $wslStatusAfterSetupText" in wsl_flow
    assert "WSL service is not available yet" in wsl_flow
    assert "Hardware virtualization is not enabled" in wsl_flow
    assert "BIOS/UEFI" in wsl_flow
    assert "Intel VT-x/VT-d" in wsl_flow
    assert "AMD SVM/AMD-V" in wsl_flow
    assert "Set-InstallStepStatus -State $State -Name \"wsl\" -Status \"blocked\" -Message $message" in wsl_flow
    assert "$blockedBeforeDocker = -not $deferUntilResume" in install_flow
    assert "LM Studio setup skipped because prerequisite setup is blocked." in install_flow
    assert "Model setup skipped because prerequisite setup is blocked." in install_flow


def test_lm_studio_and_model_catalog_are_current() -> None:
    code = "\n".join(read(path) for path in [CORE, WIZARD, PREREQ, MEDIA, DESKTOP])
    core = read(CORE)
    lm_flow = core[core.index("function Install-LmStudio") : core.index("function Get-HardwareProfile")]

    assert "google/gemma-3-1B-it-QAT" in code
    assert "qwen2.5-7b-1m" in code
    assert "openai/gpt-oss-20b" in code
    assert "qwen2.5-7b-instruct" not in code
    assert "lmstudio-bundled-silent-current-user" in code
    assert "lmstudio-bundled-silent-all-users" in code
    assert "LM Studio setup is pending user action" in code
    assert "lmstudio-pending" in code
    assert "pendingReason" in code
    assert "--silent" in code
    assert "--disable-interactivity" in code
    assert "--accept-package-agreements" in code
    assert "--accept-source-agreements" in code
    assert "continuing with fallback attempts before classifying setup" in lm_flow
    assert "Add-SetupWarning -State $State -Message \"LM Studio installer attempt" not in lm_flow


def test_installer_exit_code_hex_conversion() -> None:
    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if not powershell:
        pytest.skip("PowerShell is not available")

    core = str(CORE).replace("'", "''")
    command = f". '{core}'; if ((ConvertTo-SetupExitCodeHex -ExitCode -1073741819) -ne '0xC0000005') {{ exit 1 }}"
    result = subprocess.run(
        [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_setup_profile_json_is_written_imported_and_exported() -> None:
    core = read(CORE)
    desktop = read(DESKTOP)

    assert 'install-profile.json' in core
    assert "function Get-SetupMapValue" in core
    assert "selectedComponents" in core
    assert "provider" in core
    assert "usagePreset" in core
    assert "EnableLoginAutostart" in core
    assert "Configure-LoginAutostart" in core
    assert "--hypersearch-autostart" in core

    assert "InstallProfileJson" in desktop
    assert 'join("install-profile.json")' in desktop
    assert "install-profile.redacted.json" in desktop
    assert "HYPERSEARCH_INSTALL_USAGE_PRESET" in desktop
    assert "--hypersearch-autostart" in desktop
    assert "login_autostart.backend.complete" in desktop
    assert "docker-installer-logs" in core


def test_install_profile_handles_deferred_lm_studio_state(tmp_path: Path) -> None:
    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if not powershell:
        pytest.skip("PowerShell is not available")

    root = str(tmp_path).replace("'", "''")
    core = str(CORE).replace("'", "''")
    command = f"""
    . '{core}'
    $options = New-HyperSearchInstallerOptions `
      -InstallDir '{root}\\install' `
      -MediaDir '{root}\\media' `
      -InstallMode custom `
      -AcceptedLicenses:$true `
      -InstallDocker:$true `
      -InstallLmStudio:$false `
      -ImageSource bundled `
      -StartStack:$true `
      -UsagePreset search-only `
      -SelectedModel search-only `
      -DownloadModel:$false
    $state = [ordered]@{{
      runId = 'unit-deferred-profile'
      version = '1.1.0'
      result = 'blocked'
      runtimeRoot = '{root}\\runtime'
      installProfilePath = '{root}\\HyperSearch\\install-profile.json'
      installProfileEnvPath = '{root}\\HyperSearch\\install-profile.env'
      logPath = '{root}\\installer.log'
      summaryPath = '{root}\\summary.json'
      commandLogDir = '{root}\\commands'
      warnings = @()
      options = $options
      docker = [ordered]@{{}}
      lmStudio = [ordered]@{{}}
      profile = [ordered]@{{}}
      steps = [ordered]@{{ profile = New-HyperSearchStep }}
    }}
    Configure-InstallProfile -State $state
    $profile = Get-Content -Raw -Path $state.installProfilePath | ConvertFrom-Json
    if ($profile.lmStudio.path -ne '') {{ throw 'Expected empty lmStudio.path for deferred state.' }}
    if ($profile.lmStudio.lmsPath -ne '') {{ throw 'Expected empty lmStudio.lmsPath for deferred state.' }}
    if ($profile.lmStudio.lmsReady -ne $false) {{ throw 'Expected lmsReady false for deferred state.' }}
    if ($profile.provider.llmEnabled -ne $false) {{ throw 'Expected search-only profile to disable LLM.' }}
    if ($profile.provider.configured -ne $false) {{ throw 'Expected search-only profile to leave provider unconfigured.' }}
    if (!(Test-Path (Join-Path $state.runtimeRoot '.env'))) {{ throw 'Expected runtime .env to be written.' }}
    """
    result = subprocess.run(
        [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_install_profile_disables_llm_when_lm_studio_is_pending(tmp_path: Path) -> None:
    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if not powershell:
        pytest.skip("PowerShell is not available")

    root = str(tmp_path).replace("'", "''")
    core = str(CORE).replace("'", "''")
    command = f"""
    . '{core}'
    $options = New-HyperSearchInstallerOptions `
      -InstallDir '{root}\\install' `
      -MediaDir '{root}\\media' `
      -InstallMode standard `
      -AcceptedLicenses:$true `
      -InstallDocker:$true `
      -InstallLmStudio:$true `
      -ImageSource bundled `
      -StartStack:$true `
      -UsagePreset general-research `
      -SelectedModel qwen2.5-7b-1m `
      -DownloadModel:$false
    $state = [ordered]@{{
      runId = 'unit-lmstudio-pending-profile'
      version = '1.1.0'
      result = 'warning'
      runtimeRoot = '{root}\\runtime'
      installProfilePath = '{root}\\HyperSearch\\install-profile.json'
      installProfileEnvPath = '{root}\\HyperSearch\\install-profile.env'
      logPath = '{root}\\installer.log'
      summaryPath = '{root}\\summary.json'
      commandLogDir = '{root}\\commands'
      warnings = @()
      options = $options
      docker = [ordered]@{{ readiness = [ordered]@{{ ready = $true; version = '29.4.3' }} }}
      lmStudio = [ordered]@{{
        path = ''
        lmsPath = ''
        lmsReady = $false
        pending = $true
        pendingReason = 'unit pending'
        manualAction = 'open LM Studio'
        installer = 'bundled'
        installerExitCode = -1073741819
        installerExitCodeHex = '0xC0000005'
        installAttempts = @([ordered]@{{ name = 'unit'; exitCode = -1073741819 }})
      }}
      profile = [ordered]@{{}}
      hardware = [ordered]@{{ totalMemoryGb = 16; maxVramGb = 0; gpus = @() }}
      steps = [ordered]@{{ profile = New-HyperSearchStep }}
    }}
    Configure-InstallProfile -State $state
    $profile = Get-Content -Raw -Path $state.installProfilePath | ConvertFrom-Json
    if ($profile.provider.configured -ne $true) {{ throw 'Expected provider to remain configured.' }}
    if ($profile.provider.llmEnabled -ne $false) {{ throw 'Expected pending LM Studio to disable LLM.' }}
    if ($profile.provider.pendingReason -ne 'unit pending') {{ throw 'Expected pending reason in provider profile.' }}
    if ($profile.lmStudio.pending -ne $true) {{ throw 'Expected lmStudio.pending true.' }}
    if ($profile.lmStudio.installerExitCodeHex -ne '0xC0000005') {{ throw 'Expected installer exit code hex in profile.' }}
    if ($profile.setup.result -ne 'warning') {{ throw 'Expected setup result warning.' }}
    if ($profile.usagePreset -ne 'general-research') {{ throw 'Expected usage preset to carry over.' }}
    if ($profile.provider.modelId -ne 'qwen2.5-7b-1m') {{ throw 'Expected selected model to carry over.' }}
    if ($profile.selectedComponents.lmStudio -ne $true) {{ throw 'Expected LM Studio selected component.' }}
    if ($profile.selectedComponents.loginAutostart -ne $false) {{ throw 'Expected login autostart to default false.' }}
    if ($profile.installMode -ne 'standard') {{ throw 'Expected standard install mode.' }}
    if ($profile.package -ne 'Full') {{ throw 'Expected Full package.' }}
    """
    result = subprocess.run(
        [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_env_writes_are_bom_safe_for_docker_compose() -> None:
    core = read(CORE)
    desktop = read(DESKTOP)
    set_env_value = core[core.index("function Set-EnvValue") : core.index("function Ensure-HyperSearchEnv")]

    assert "function Write-Utf8NoBom" in core
    assert "Write-Utf8NoBom -Path $Path -Value $nextLines" in set_env_value
    assert "Set-Content -Path $composeEnv -Encoding UTF8" not in core
    assert "trim_start_matches('\\u{feff}')" in desktop
    assert "env.rewrite.strip_bom" in desktop


def test_automated_installer_mode_and_hyperv_lab_exist() -> None:
    core = read(CORE)
    wizard = read(WIZARD)
    prereq = read(PREREQ)
    matrix = read(LAB_MATRIX)
    setup = read(LAB_SETUP)
    assert_script = read(LAB_ASSERT)
    iso_setup = read(LAB_ISO)
    release_gate = read(LAB_GATE)
    init_gate = read(LAB_INIT_GATE)
    repair_baseline = read(LAB_REPAIR_BASELINE)
    lab_config = read(LAB_ROOT / "configs" / "lab.example.json")
    release_config = read(LAB_ROOT / "configs" / "release-gate.windows10-11.example.json")
    dev_win11_config = read(LAB_ROOT / "configs" / "dev-win11-standard-full.example.json")

    assert "[switch]$Automated" in wizard
    assert "Invoke-AutomatedInstall" in wizard
    assert "DockerReadyTimeoutSeconds" in wizard
    assert "EnableLoginAutostart" in wizard
    assert "Start HyperSearch when I sign into Windows" in wizard
    assert "acceptedLicenses=true" in wizard
    assert "hypersearch-install-automation.json" in prereq
    assert "HYPERSEARCH_INSTALL_AUTOMATED_CONFIG" in prereq
    assert "Result path resolved from automation config" in prereq
    assert "Copied setup summary to missing result path" in prereq
    assert "Restore-VMSnapshot" in matrix
    assert "New-PSSession -VMName" in matrix
    assert "Copy-Item -ToSession" in matrix
    assert "Copy-VMFile" in matrix
    assert "Test-LabGuestMediaChecksums" in matrix
    assert "guest-media-checksums.json" in matrix
    assert "AppendAllText" in matrix
    assert "Invoke-LabGuestDirectInstaller" in matrix
    assert "GuestResultPath" in matrix
    assert "Get-LabInstallerFinalState -StatePath $stateLiteral" in matrix
    assert "FinalStateDetected" in matrix
    assert "Direct NSIS installer still running in guest" in matrix
    assert "Host-side direct installer poll timed out" in matrix
    assert "Installer core still running in guest" in matrix
    assert "Invoke-LabGuestCoreInstaller" in matrix
    assert "Invoke-LabVmHostPreflight" in matrix
    assert "vm-host-preflight.json" in matrix
    assert "Checkpoint restored with nested virtualization disabled" in matrix
    assert "Copy-LabInstallSourceToGuest" in matrix
    assert "Save-LabGuestSnapshot" in matrix
    assert "direct-psdirect" in matrix
    assert "installer-core" in matrix
    assert "installer-timeout-diagnostics.json" in matrix
    assert "installer-progress-watchdog.json" in matrix
    assert "Get-LabInstallerProgressSnapshot" in matrix
    assert "defaultProgressPollSeconds" in matrix
    assert "defaultNoProgressPollLimit" in matrix
    assert "resumeTimeoutSeconds" in matrix
    assert "Running reboot/resume installer core" in matrix
    assert "Copy-LabHyperSearchDataFromGuest" in matrix
    assert "guest-data-on-error" in matrix
    assert "Installer progress watchdog failed the scenario" in matrix
    assert "Docker Desktop is installed, but its backend is not accepting engine commands yet" in core
    assert "Get-LabProcessTreeIds" in matrix
    assert "Start-Process -FilePath $powershell" in matrix
    assert "Register-ScheduledTask" not in matrix
    assert "RunLevel Highest" not in matrix
    assert "SEE_MASK_NOZONECHECKS" in matrix
    assert "Unblock-File -LiteralPath $installerLiteral" in matrix
    assert 'Start-Process -FilePath $installerLiteral -ArgumentList @("/S", "/AllUsers")' in matrix
    assert "Installer requested reboot/resume" in matrix
    assert "HyperSearchPrereqSetup.ps1" in matrix
    assert "allowRebootResume" in lab_config
    assert "defaultProgressPollSeconds" in lab_config
    assert "defaultNoProgressPollLimit" in lab_config
    assert "Assert-HyperSearchInstallResult.ps1" in matrix
    assert "Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true" in setup
    assert "Expand-WindowsImage" in iso_setup
    assert "clean-windows-docker-supported-ready" in iso_setup
    assert "Enable-VMTPM" in iso_setup
    assert "NoSelfElevate" in release_gate
    assert "Start-Process -FilePath $powershell" in release_gate
    assert "tests/unit/test_installer_wizard.py" in release_gate
    assert "Invoke-HyperSearchInstallerMatrix.ps1" in release_gate
    assert "New-HyperSearchIsoLabVm.ps1" in init_gate
    assert "release-gate.windows10-11.local.json" in init_gate
    assert "Invoke-HyperSearchVmReleaseGate.ps1" in init_gate
    assert "Set-VMProcessor -VMName $name -Count $ProcessorCount -ExposeVirtualizationExtensions $true" in repair_baseline
    assert "Get-HyperSearchVmHostSnapshot" in repair_baseline
    assert "Nested virtualization was not enabled" in repair_baseline
    assert "Microsoft-Windows-Subsystem-Linux" in repair_baseline
    assert "VirtualMachinePlatform" in repair_baseline
    assert "HypervisorPlatform" in repair_baseline
    assert "bcdedit.exe /set hypervisorlaunchtype Auto" in repair_baseline
    assert "SkipGuestFeatureEnable" in repair_baseline
    assert "ReplaceCheckpoint" in repair_baseline
    assert "requireNoComposeEnvBom" in assert_script
    assert "requireLmStudioPendingDisablesLlm" in assert_script
    assert "requireNoInstallerWarnings" in assert_script
    assert "requireLmStudioReady" in assert_script
    assert "requireLoginAutostart" in assert_script
    assert "guestPasswordEnv" in lab_config
    assert "HyperSearchLab-Win10-22H2" in release_config
    assert "HyperSearchLab-Win11-24H2" in release_config
    assert "win10-nsis-bootstrap-smoke" in release_config
    assert "win11-nsis-bootstrap-smoke" in release_config
    assert "win11-nsis-standard-full" in release_config
    assert "win10-fresh-standard-full" in release_config
    assert "win11-fresh-standard-full" in release_config
    assert "defaultProgressPollSeconds" in release_config
    assert "defaultNoProgressPollLimit" in release_config
    assert '"requireLmStudioPendingDisablesLlm": true' in release_config
    assert '"requireNoInstallerWarnings": true' in release_config
    assert '"requireLmStudioReady": true' in release_config
    assert '"requireLoginAutostart": true' in release_config
    assert '"enableLoginAutostart": true' in release_config
    assert '"expectedResults": ["passed"]' in release_config
    assert "win11-fresh-standard-full" in dev_win11_config
    assert '"requireNestedVirtualization": true' in dev_win11_config
    assert '"installerTimeoutSeconds": 3600' in dev_win11_config
    assert '"resumeTimeoutSeconds": 2400' in dev_win11_config
    assert '"progressPollSeconds": 30' in dev_win11_config
    assert '"noProgressPollLimit": 8' in dev_win11_config
    assert '"dockerReadyTimeoutSeconds": 240' in dev_win11_config
    assert '"executionMode": "core"' in release_config
    assert '"skipStateAssertions": true' in release_config
    assert '"guestPassword":' not in lab_config
    assert '"guestPassword":' not in release_config


def test_full_installer_is_default_media_channel() -> None:
    media = read(MEDIA)

    assert '[string]$Channel = "Full"' in media
    assert '[string]$Version = "1.1.0"' in media
    assert '[string]$WslInstallerPath = ""' in media
    assert '"WSL.msi"' in media
    assert 'installationWizard = "HyperSearch Installation Wizard"' in media
    assert 'standardInstallChannel = "Full"' in media
    assert '"type": "offlineInstaller"' in read(REPO_ROOT / "apps" / "desktop" / "src-tauri" / "tauri.conf.json")
