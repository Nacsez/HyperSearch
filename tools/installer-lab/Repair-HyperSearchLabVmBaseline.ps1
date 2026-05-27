[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "configs\release-gate.windows10-11.local.json"),
    [string[]]$VMName = @(),
    [string]$CheckpointName = "",
    [string]$CredentialPath = "",
    [string]$OutputRoot = "%LOCALAPPDATA%\HyperSearch\installer-lab\baseline-repairs",
    [int]$ProcessorCount = 8,
    [int64]$MemoryStartupBytes = 17179869184,
    [int]$GuestReadyTimeoutSeconds = 1800,
    [switch]$SkipGuestFeatureEnable,
    [switch]$ReplaceCheckpoint,
    [switch]$NoSelfElevate
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Expand-LabPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function ConvertTo-ArgumentLine {
    param([string[]]$Arguments)
    return ($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WindowsPowerShellPath {
    $candidate = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $candidate) { return $candidate }
    return "powershell.exe"
}

function Write-RepairLog {
    param([Parameter(Mandatory = $true)][string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message
    Add-Content -Path $script:RepairLogPath -Value $line
    Write-Host $line
}

function Read-LabConfig {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or !(Test-Path $Path)) { return $null }
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Get-ConfigVmNames {
    param($Config)
    $names = @()
    if ($null -eq $Config) { return $names }
    if ($Config.PSObject.Properties["releaseGate"]) {
        foreach ($entry in $Config.releaseGate.PSObject.Properties) {
            if ($entry.Value.PSObject.Properties["vmName"]) {
                $name = [string]$entry.Value.vmName
                if (-not [string]::IsNullOrWhiteSpace($name)) { $names += $name }
            }
        }
    }
    if ($Config.PSObject.Properties["scenarios"]) {
        foreach ($scenario in @($Config.scenarios)) {
            if ($scenario.PSObject.Properties["vmName"]) {
                $name = [string]$scenario.vmName
                if (-not [string]::IsNullOrWhiteSpace($name)) { $names += $name }
            }
        }
    }
    return @($names | Select-Object -Unique)
}

function Get-CheckpointNameForVm {
    param($Config, [string]$Name, [string]$Fallback)
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) { return $Fallback }
    if ($null -ne $Config -and $Config.PSObject.Properties["scenarios"]) {
        foreach ($scenario in @($Config.scenarios)) {
            if ([string]$scenario.vmName -eq $Name -and $scenario.PSObject.Properties["checkpoint"]) {
                $candidate = [string]$scenario.checkpoint
                if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
            }
        }
    }
    if ($null -ne $Config -and $Config.PSObject.Properties["releaseGate"]) {
        foreach ($entry in $Config.releaseGate.PSObject.Properties) {
            if ([string]$entry.Value.vmName -eq $Name -and $entry.Value.PSObject.Properties["checkpoint"]) {
                $candidate = [string]$entry.Value.checkpoint
                if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
            }
        }
    }
    return "clean-windows-docker-supported-ready"
}

function Get-ConfigMediaRoot {
    param($Config)
    if ($null -ne $Config -and $Config.PSObject.Properties["mediaRoot"]) {
        $candidate = Expand-LabPath ([string]$Config.mediaRoot)
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            if ([IO.Path]::IsPathRooted($candidate)) { return $candidate }
            return Join-Path $repoRoot $candidate
        }
    }
    return ""
}

function Wait-HyperSearchGuestSession {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [int]$TimeoutSeconds = 1800
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = ""
    $lastLog = Get-Date
    while ((Get-Date) -lt $deadline) {
        $session = $null
        try {
            $session = New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop
            Invoke-Command -Session $session -ScriptBlock { $PSVersionTable.PSVersion.ToString() } -ErrorAction Stop | Out-Null
            return $session
        } catch {
            $lastError = $_.Exception.Message
            if ($session) {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }
            if (((Get-Date) - $lastLog).TotalSeconds -ge 60) {
                Write-RepairLog "Still waiting for PowerShell Direct in '$Name': $lastError" "DEBUG"
                $lastLog = Get-Date
            }
            Start-Sleep -Seconds 5
        }
    }
    throw "Timed out waiting for PowerShell Direct in '$Name'. Last error: $lastError"
}

function Wait-HyperSearchGuestSessionWithRecovery {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [int]$TimeoutSeconds = 1800,
        [int]$RecoveryTimeoutSeconds = 900
    )
    try {
        return Wait-HyperSearchGuestSession -Name $Name -Credential $Credential -TimeoutSeconds $TimeoutSeconds
    } catch {
        Write-RepairLog "PowerShell Direct did not return within $TimeoutSeconds seconds for '$Name'. Performing one hard power-cycle recovery before failing baseline repair. Error: $($_.Exception.Message)" "WARN"
        Stop-HyperSearchVmHard -Name $Name
        Start-VM -Name $Name | Out-Null
        return Wait-HyperSearchGuestSession -Name $Name -Credential $Credential -TimeoutSeconds $RecoveryTimeoutSeconds
    }
}

function Invoke-HyperSearchGuestCommand {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )
    return Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ErrorAction Stop
}

function Stop-HyperSearchVmHard {
    param([Parameter(Mandatory = $true)][string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction Stop
    if ($vm.State -ne "Off") {
        Stop-VM -Name $Name -TurnOff -Force -ErrorAction Stop
    }
}

function Restart-HyperSearchGuestOs {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$Reason = "HyperSearch lab baseline repair"
    )
    try {
        Invoke-Command -Session $Session -ScriptBlock {
            param($Comment)
            & shutdown.exe /r /t 0 /f /c $Comment 2>&1 | Out-String
        } -ArgumentList $Reason -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-RepairLog "Guest restart command returned during shutdown: $($_.Exception.Message)" "DEBUG"
    }
    Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
}

function Install-HyperSearchGuestWslMsi {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory = $true)][string]$WslMsiPath
    )
    if ([string]::IsNullOrWhiteSpace($WslMsiPath) -or !(Test-Path -LiteralPath $WslMsiPath)) {
        return [pscustomobject][ordered]@{
            status = "skipped"
            message = "WSL MSI was not found on the host."
            hostPath = $WslMsiPath
        }
    }
    $guestDir = "C:\HyperSearchInstallerLab\baseline-repair\prereqs"
    $guestMsi = Join-Path $guestDir "WSL.msi"
    Invoke-Command -Session $Session -ScriptBlock {
        param($Path)
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    } -ArgumentList $guestDir
    Copy-Item -ToSession $Session -LiteralPath $WslMsiPath -Destination $guestMsi -Force
    return Invoke-Command -Session $Session -ScriptBlock {
        param($MsiPath, $HostPath)
        $arguments = "/i `"$MsiPath`" /qn /norestart"
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        [pscustomobject][ordered]@{
            status = if ($process.ExitCode -in @(0, 3010)) { "passed" } else { "failed" }
            exitCode = $process.ExitCode
            hostPath = $HostPath
            guestPath = $MsiPath
        }
    } -ArgumentList $guestMsi, $WslMsiPath
}

function Get-HyperSearchVmHostSnapshot {
    param([Parameter(Mandatory = $true)][string]$Name)
    $vm = Get-VM -Name $Name -ErrorAction Stop
    $processor = Get-VMProcessor -VMName $Name -ErrorAction Stop
    $memory = Get-VMMemory -VMName $Name -ErrorAction Stop
    [pscustomobject][ordered]@{
        name = $vm.Name
        state = [string]$vm.State
        processorCount = [int]$processor.Count
        exposeVirtualizationExtensions = [bool]$processor.ExposeVirtualizationExtensions
        memoryStartup = [int64]$memory.Startup
        dynamicMemoryEnabled = [bool]$memory.DynamicMemoryEnabled
        checkpointType = [string]$vm.CheckpointType
    }
}

function Invoke-HyperSearchGuestReadiness {
    param([Parameter(Mandatory = $true)][System.Management.Automation.Runspaces.PSSession]$Session)
    return Invoke-HyperSearchGuestCommand -Session $Session -ScriptBlock {
        $ErrorActionPreference = "Stop"
        function Invoke-NativeText {
            param([string]$FilePath, [string[]]$Arguments = @())
            $oldPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $text = (& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ } | Out-String).Trim()
                $exitCode = $LASTEXITCODE
            } catch {
                $text = $_.Exception.Message
                $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }
            } finally {
                $ErrorActionPreference = $oldPreference
            }
            $text = $text -replace "`0", ""
            return [ordered]@{ exitCode = $exitCode; output = $text }
        }
        $featureNames = @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform", "HypervisorPlatform")
        $features = @($featureNames | ForEach-Object {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $_ -ErrorAction Stop
            [ordered]@{ name = $_; state = [string]$feature.State }
        })
        $processor = Get-CimInstance Win32_Processor | Select-Object -First 1 Name, VirtualizationFirmwareEnabled, SecondLevelAddressTranslationExtensions, VMMonitorModeExtensions
        $os = Get-CimInstance Win32_OperatingSystem | Select-Object -First 1 Caption, Version, BuildNumber
        $systemInfo = @(systeminfo.exe 2>&1 | Select-String -Pattern "Hyper-V|Virtualization|hypervisor" | ForEach-Object { $_.Line })
        $bcdeditCurrent = Invoke-NativeText -FilePath "bcdedit.exe" -Arguments @("/enum", "{current}")
        $wslStatus = Invoke-NativeText -FilePath "wsl.exe" -Arguments @("--status")
        $wslVersion = Invoke-NativeText -FilePath "wsl.exe" -Arguments @("--version")
        $combined = @($wslStatus.output, $wslVersion.output, ($systemInfo -join "`n")) -join "`n"
        $virtualizationBlocked = $combined -match "(?i)(WSL2 is unable to start since virtualization is not enabled|virtualization is not enabled|aka\.ms/enablevirtualization|Virtual Machine Platform.*firmware settings)"
        $wslNotInstalled = $combined -match "(?i)(Windows Subsystem for Linux is not installed|wsl\.exe --install|wsl --install)"
        $featuresEnabled = @($features | Where-Object { [string]$_.state -ne "Enabled" }).Count -eq 0
        [pscustomobject][ordered]@{
            computerName = $env:COMPUTERNAME
            os = $os
            features = $features
            featuresEnabled = $featuresEnabled
            processor = $processor
            bcdeditCurrent = $bcdeditCurrent
            wslStatus = $wslStatus
            wslVersion = $wslVersion
            systemInfo = $systemInfo
            virtualizationBlocked = $virtualizationBlocked
            wslNotInstalled = $wslNotInstalled
            dockerSupportedReady = ($featuresEnabled -and -not $virtualizationBlocked -and -not $wslNotInstalled)
        }
    }
}

if (-not (Test-Administrator)) {
    if ($NoSelfElevate) {
        throw "Repair-HyperSearchLabVmBaseline.ps1 must run elevated because it restores checkpoints and changes Hyper-V processor settings."
    }
    $powershell = Get-WindowsPowerShellPath
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $PSCommandPath,
        "-ConfigPath",
        $ConfigPath,
        "-OutputRoot",
        $OutputRoot,
        "-ProcessorCount",
        [string]$ProcessorCount,
        "-MemoryStartupBytes",
        [string]$MemoryStartupBytes,
        "-GuestReadyTimeoutSeconds",
        [string]$GuestReadyTimeoutSeconds,
        "-NoSelfElevate"
    )
    if (-not [string]::IsNullOrWhiteSpace($CheckpointName)) {
        $args += "-CheckpointName"
        $args += $CheckpointName
    }
    if (-not [string]::IsNullOrWhiteSpace($CredentialPath)) {
        $args += "-CredentialPath"
        $args += $CredentialPath
    }
    foreach ($name in $VMName) {
        $args += "-VMName"
        $args += $name
    }
    if ($SkipGuestFeatureEnable) { $args += "-SkipGuestFeatureEnable" }
    if ($ReplaceCheckpoint) { $args += "-ReplaceCheckpoint" }
    Write-Host "Requesting elevation for HyperSearch lab baseline repair."
    $process = Start-Process -FilePath $powershell -ArgumentList (ConvertTo-ArgumentLine $args) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    exit $process.ExitCode
}

Import-Module Hyper-V -ErrorAction Stop

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$resolvedConfigPath = if ([IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath } else { Join-Path $repoRoot $ConfigPath }
$config = Read-LabConfig -Path $resolvedConfigPath
$mediaRoot = Get-ConfigMediaRoot -Config $config
$wslMsiPath = if ([string]::IsNullOrWhiteSpace($mediaRoot)) { "" } else { Join-Path $mediaRoot "payload\prereqs\WSL.msi" }
if ($VMName.Count -eq 0) {
    $VMName = Get-ConfigVmNames -Config $config
}
if ($VMName.Count -eq 0) {
    throw "No VM names were provided and none could be read from $resolvedConfigPath."
}
if ([string]::IsNullOrWhiteSpace($CredentialPath) -and $null -ne $config -and $config.PSObject.Properties["guestCredentialPath"]) {
    $CredentialPath = [string]$config.guestCredentialPath
}
$CredentialPath = Expand-LabPath $CredentialPath
if ([string]::IsNullOrWhiteSpace($CredentialPath) -or !(Test-Path $CredentialPath)) {
    throw "Guest credential file was not found. Pass -CredentialPath or set guestCredentialPath in the release-gate config."
}
$credential = Import-Clixml -Path $CredentialPath

$outputBase = Expand-LabPath $OutputRoot
if ([string]::IsNullOrWhiteSpace($outputBase)) {
    $outputBase = Join-Path $env:LOCALAPPDATA "HyperSearch\installer-lab\baseline-repairs"
}
$repairId = Get-Date -Format "yyyyMMdd-HHmmss"
$script:RepairRoot = Join-Path $outputBase $repairId
New-Item -ItemType Directory -Force -Path $script:RepairRoot | Out-Null
$script:RepairLogPath = Join-Path $script:RepairRoot "baseline-repair.log"

$summary = [ordered]@{
    repairId = $repairId
    configPath = $resolvedConfigPath
    credentialPath = $CredentialPath
    mediaRoot = $mediaRoot
    wslMsiPath = $wslMsiPath
    outputRoot = $script:RepairRoot
    startedAt = (Get-Date).ToString("o")
    completedAt = ""
    status = "failed"
    skipGuestFeatureEnable = [bool]$SkipGuestFeatureEnable
    replaceCheckpoint = [bool]$ReplaceCheckpoint
    vms = @()
}

try {
    Write-RepairLog "HyperSearch lab baseline repair started. RepairId=$repairId"
    foreach ($name in $VMName) {
        $checkpoint = Get-CheckpointNameForVm -Config $config -Name $name -Fallback $CheckpointName
        $record = [ordered]@{
            vmName = $name
            checkpoint = $checkpoint
            status = "failed"
            startedAt = (Get-Date).ToString("o")
            completedAt = ""
            before = $null
            enableFeatureResult = $null
            wslMsiInstallResult = $null
            after = $null
            hostAfterStop = $null
            rebootRecovery = @()
            error = ""
        }
        try {
            Write-RepairLog "Preparing VM '$name' from checkpoint '$checkpoint'."
            $snapshot = Get-VMSnapshot -VMName $name -Name $checkpoint -ErrorAction Stop
            Stop-HyperSearchVmHard -Name $name
            Restore-VMSnapshot -VMSnapshot $snapshot -Confirm:$false | Out-Null
            Stop-HyperSearchVmHard -Name $name

            Set-VMProcessor -VMName $name -Count $ProcessorCount -ExposeVirtualizationExtensions $true
            Set-VMMemory -VMName $name -DynamicMemoryEnabled $false -StartupBytes $MemoryStartupBytes
            Enable-VMIntegrationService -VMName $name -Name "Guest Service Interface" -ErrorAction SilentlyContinue
            $record.before = Get-HyperSearchVmHostSnapshot -Name $name

            if (-not $SkipGuestFeatureEnable) {
                Start-VM -Name $name | Out-Null
                $session = Wait-HyperSearchGuestSession -Name $name -Credential $credential -TimeoutSeconds $GuestReadyTimeoutSeconds
                try {
                    $record.enableFeatureResult = Invoke-HyperSearchGuestCommand -Session $session -ScriptBlock {
                        $ErrorActionPreference = "Stop"
                        $features = @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform", "HypervisorPlatform")
                        $featureRecords = @()
                        foreach ($feature in $features) {
                            $beforeFeature = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction Stop
                            $dismOutput = ""
                            $dismExitCode = 0
                            if ([string]$beforeFeature.State -ne "Enabled") {
                                $dismOutput = (& dism.exe /online /enable-feature /featurename:$feature /all /norestart 2>&1 | Out-String).Trim()
                                $dismExitCode = $LASTEXITCODE
                            }
                            $afterFeature = Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction Stop
                            $featureRecords += [ordered]@{
                                name = $feature
                                before = [string]$beforeFeature.State
                                after = [string]$afterFeature.State
                                dismExitCode = $dismExitCode
                                dismOutput = $dismOutput
                            }
                        }
                        $bcdOutput = (& bcdedit.exe /set hypervisorlaunchtype Auto 2>&1 | Out-String).Trim()
                        [pscustomobject][ordered]@{
                            computerName = $env:COMPUTERNAME
                            features = $featureRecords
                            bcdeditSetOutput = $bcdOutput
                        }
                    }
                } catch {
                    if ($session) {
                        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
                        $session = $null
                    }
                    throw
                }

                Write-RepairLog "Restarting '$name' after feature enablement."
                $record.rebootRecovery += [ordered]@{
                    reason = "after-feature-enablement"
                    method = "guest-shutdown"
                    startedAt = (Get-Date).ToString("o")
                }
                Restart-HyperSearchGuestOs -Session $session -Reason "HyperSearch lab baseline repair: applying WSL and virtualization features"
                $session = $null
                Start-Sleep -Seconds 15
                $session = Wait-HyperSearchGuestSessionWithRecovery -Name $name -Credential $credential -TimeoutSeconds $GuestReadyTimeoutSeconds
                try {
                    $record.after = Invoke-HyperSearchGuestReadiness -Session $session
                    if ([bool]$record.after.wslNotInstalled) {
                        if ([string]::IsNullOrWhiteSpace($wslMsiPath) -or !(Test-Path -LiteralPath $wslMsiPath)) {
                            throw "Guest WSL package is not installed and bundled WSL MSI was not found at '$wslMsiPath'. Rebuild/copy Full media with payload\prereqs\WSL.msi before repairing the baseline."
                        }
                        Write-RepairLog "Guest optional features are enabled but WSL package is missing. Installing bundled WSL MSI: $wslMsiPath"
                        $record.wslMsiInstallResult = Install-HyperSearchGuestWslMsi -Session $session -WslMsiPath $wslMsiPath
                        if ([string]$record.wslMsiInstallResult.status -ne "passed") {
                            throw "Bundled WSL MSI installation failed with exit code $($record.wslMsiInstallResult.exitCode)."
                        }
                        Restart-HyperSearchGuestOs -Session $session -Reason "HyperSearch lab baseline repair: applying bundled WSL MSI"
                        $session = $null
                        $record.rebootRecovery += [ordered]@{
                            reason = "after-wsl-msi"
                            method = "guest-shutdown"
                            startedAt = (Get-Date).ToString("o")
                        }
                        Start-Sleep -Seconds 15
                        $session = Wait-HyperSearchGuestSessionWithRecovery -Name $name -Credential $credential -TimeoutSeconds $GuestReadyTimeoutSeconds
                        $record.after = Invoke-HyperSearchGuestReadiness -Session $session
                    }
                    if (-not [bool]$record.after.dockerSupportedReady) {
                        Write-RepairLog "Guest WSL readiness check did not pass after first reboot. Performing one additional graceful reboot before failing." "WARN"
                        Restart-HyperSearchGuestOs -Session $session -Reason "HyperSearch lab baseline repair: second WSL readiness reboot"
                        $session = $null
                        $record.rebootRecovery += [ordered]@{
                            reason = "second-readiness-check"
                            method = "guest-shutdown"
                            startedAt = (Get-Date).ToString("o")
                        }
                        Start-Sleep -Seconds 15
                        $session = Wait-HyperSearchGuestSessionWithRecovery -Name $name -Credential $credential -TimeoutSeconds $GuestReadyTimeoutSeconds
                        $record.after = Invoke-HyperSearchGuestReadiness -Session $session
                    }
                    if (-not [bool]$record.after.dockerSupportedReady) {
                        $wslText = @($record.after.wslStatus.output, $record.after.wslVersion.output) -join "`n"
                        throw "Guest WSL/Docker readiness did not pass after repair. featuresEnabled=$($record.after.featuresEnabled) virtualizationBlocked=$($record.after.virtualizationBlocked) wsl='$wslText'"
                    }
                } finally {
                    if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
                }
            } else {
                $record.after = Get-HyperSearchVmHostSnapshot -Name $name
            }

            Stop-HyperSearchVmHard -Name $name
            $hostAfterStop = Get-HyperSearchVmHostSnapshot -Name $name
            $record["hostAfterStop"] = $hostAfterStop
            if (-not [bool]$hostAfterStop.exposeVirtualizationExtensions) {
                throw "Nested virtualization was not enabled on '$name' after repair."
            }
            if ($ReplaceCheckpoint) {
                Write-RepairLog "Replacing checkpoint '$checkpoint' on '$name'."
                Get-VMSnapshot -VMName $name -Name $checkpoint -ErrorAction SilentlyContinue | Remove-VMSnapshot -Confirm:$false
            }
            if (!(Get-VMSnapshot -VMName $name -Name $checkpoint -ErrorAction SilentlyContinue)) {
                Checkpoint-VM -Name $name -SnapshotName $checkpoint | Out-Null
            }
            $record.status = "passed"
            Write-RepairLog "Prepared '$name' and captured checkpoint '$checkpoint'."
        } catch {
            $record.error = $_.Exception.Message
            Write-RepairLog "Failed to prepare '$name': $($record.error)" "ERROR"
            try { Stop-HyperSearchVmHard -Name $name } catch { Write-RepairLog "Could not stop '$name' after failure: $($_.Exception.Message)" "WARN" }
        } finally {
            $record.completedAt = (Get-Date).ToString("o")
            $summary.vms += $record
        }
    }
    if (@($summary.vms | Where-Object { $_.status -ne "passed" }).Count -eq 0) {
        $summary.status = "passed"
    }
} finally {
    $summary.completedAt = (Get-Date).ToString("o")
    $summaryPath = Join-Path $script:RepairRoot "baseline-repair-summary.json"
    [System.IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 16), [System.Text.UTF8Encoding]::new($false))
    Write-RepairLog "Baseline repair summary written: $summaryPath"
    if ($summary.status -ne "passed") {
        exit 1
    }
}
