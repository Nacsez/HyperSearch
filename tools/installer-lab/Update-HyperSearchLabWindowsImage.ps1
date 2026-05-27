[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$VMName = "HyperSearchLab-WinDev",
    [string]$CredentialPath = "C:\tmp\hypersearch-lab-credential.xml",
    [string]$RestoreCheckpointName = "",
    [string]$ReadyCheckpointName = "clean-windows-docker-supported-ready",
    [int]$MinimumWindowsBuild = 22631,
    [int]$MaxUpdatePasses = 3,
    [int]$GuestReadyTimeoutSeconds = 900,
    [string]$OutputPath = "C:\tmp\hypersearch-lab-windows-update.json",
    [switch]$InstallUpdates,
    [switch]$CreateCheckpoint,
    [switch]$ReplaceCheckpoint
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowNull()]$Value = "")
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, [string]$Value, [System.Text.UTF8Encoding]::new($false))
}

function Add-Event {
    param([System.Collections.ArrayList]$Events, [string]$Message, [string]$Level = "INFO")
    [void]$Events.Add([ordered]@{
        at = (Get-Date).ToString("o")
        level = $Level
        message = $Message
    })
    Write-Host "[$Level] $Message"
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must run from an elevated PowerShell session."
    }
}

function Wait-GuestReady {
    param(
        [string]$Name,
        [Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSeconds,
        [System.Collections.ArrayList]$Events
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock {
                [pscustomobject]@{
                    computerName = $env:COMPUTERNAME
                    user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                    localAppData = $env:LOCALAPPDATA
                }
            } -ErrorAction Stop
        } catch {
            Add-Event -Events $Events -Level "DEBUG" -Message "Waiting for PowerShell Direct on ${Name}: $($_.Exception.Message)"
            Start-Sleep -Seconds 10
        }
    } while ((Get-Date) -lt $deadline)
    throw "PowerShell Direct did not become ready for '$Name' within $TimeoutSeconds seconds."
}

function Get-GuestWindowsState {
    param([string]$Name, [Management.Automation.PSCredential]$Credential)
    return Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock {
        $os = Get-CimInstance Win32_OperatingSystem
        $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
        [pscustomobject]@{
            computerName = $env:COMPUTERNAME
            user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            caption = $os.Caption
            version = $os.Version
            buildNumber = [int]$os.BuildNumber
            displayVersion = [string]$cv.DisplayVersion
            ubr = $cv.UBR
            editionId = [string]$cv.EditionID
            installationType = [string]$cv.InstallationType
            freeGb = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
        }
    }
}

function Test-GuestRebootPending {
    param([string]$Name, [Management.Automation.PSCredential]$Credential)
    return Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock {
        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
            "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
        )
        foreach ($path in $paths) {
            if (Test-Path $path) { return $true }
        }
        return $false
    }
}

function Invoke-GuestWindowsUpdatePass {
    param([string]$Name, [Management.Automation.PSCredential]$Credential, [int]$Pass)
    return Invoke-Command -VMName $Name -Credential $Credential -ArgumentList $Pass -ScriptBlock {
        param([int]$Pass)
        $ErrorActionPreference = "Stop"
        $ProgressPreference = "SilentlyContinue"
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $logDir = "C:\HyperSearchInstallerLab\windows-update"
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
        $logPath = Join-Path $logDir ("windows-update-pass-{0}.log" -f $Pass)
        function Log($Message) {
            Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format "o"), $Message)
        }
        Log "Starting Windows Update pass $Pass."
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Log "Installing NuGet package provider."
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }
        $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
        if ($repo -and $repo.InstallationPolicy -ne "Trusted") {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Log "Installing PSWindowsUpdate module."
            Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -AllowClobber
        }
        Import-Module PSWindowsUpdate
        Log "Querying available Microsoft updates."
        $available = @(Get-WindowsUpdate -MicrosoftUpdate -ErrorAction Stop)
        $availablePath = Join-Path $logDir ("available-updates-pass-{0}.json" -f $Pass)
        $available | Select-Object KB, Title, Size, IsDownloaded, IsInstalled |
            ConvertTo-Json -Depth 5 | Out-File -FilePath $availablePath -Encoding utf8
        if ($available.Count -eq 0) {
            Log "No available updates returned."
            return [pscustomobject]@{
                pass = $Pass
                updateCount = 0
                installed = @()
                rebootRequired = $false
                logPath = $logPath
                availablePath = $availablePath
            }
        }
        Log "Installing $($available.Count) updates."
        $installOutput = Join-Path $logDir ("install-updates-pass-{0}.txt" -f $Pass)
        $installed = @(Install-WindowsUpdate -MicrosoftUpdate -AcceptAll -IgnoreReboot -ErrorAction Stop *>&1)
        $installed | Out-String | Out-File -FilePath $installOutput -Encoding utf8
        $rebootRequired = $false
        foreach ($path in @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
            "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations"
        )) {
            if (Test-Path $path) { $rebootRequired = $true }
        }
        Log "Install completed. RebootRequired=$rebootRequired"
        return [pscustomobject]@{
            pass = $Pass
            updateCount = $available.Count
            available = @($available | Select-Object -First 30 KB, Title, Size)
            installedSummaryPath = $installOutput
            rebootRequired = $rebootRequired
            logPath = $logPath
            availablePath = $availablePath
        }
    }
}

Assert-Admin
Import-Module Hyper-V -ErrorAction Stop

$events = [System.Collections.ArrayList]::new()
$passes = [System.Collections.ArrayList]::new()
$result = [ordered]@{
    ok = $false
    generatedAt = (Get-Date).ToString("o")
    vmName = $VMName
    restoreCheckpointName = $RestoreCheckpointName
    readyCheckpointName = $ReadyCheckpointName
    minimumWindowsBuild = $MinimumWindowsBuild
    installUpdates = [bool]$InstallUpdates
    createCheckpoint = [bool]$CreateCheckpoint
    before = $null
    after = $null
    supported = $false
    checkpointCreated = $false
    passes = $passes
    events = $events
    error = ""
}

try {
    if (!(Test-Path $CredentialPath)) {
        throw "Credential file was not found: $CredentialPath"
    }
    $credential = Import-Clixml -LiteralPath $CredentialPath
    if ($credential -isnot [Management.Automation.PSCredential]) {
        throw "Credential file did not contain a PSCredential: $CredentialPath"
    }
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($RestoreCheckpointName) {
        if ($PSCmdlet.ShouldProcess($VMName, "Restore checkpoint $RestoreCheckpointName")) {
            Add-Event -Events $events -Message "Restoring checkpoint '$RestoreCheckpointName'."
            Restore-VMSnapshot -VMName $VMName -Name $RestoreCheckpointName -Confirm:$false
        }
    }
    if ((Get-VM -Name $VMName).State -ne "Running") {
        Add-Event -Events $events -Message "Starting VM '$VMName'."
        Start-VM -Name $VMName | Out-Null
    }
    Wait-GuestReady -Name $VMName -Credential $credential -TimeoutSeconds $GuestReadyTimeoutSeconds -Events $events | Out-Null
    $before = Get-GuestWindowsState -Name $VMName -Credential $credential
    $result.before = $before
    Add-Event -Events $events -Message "Current guest build: $($before.caption) $($before.displayVersion) build $($before.buildNumber).$($before.ubr)."

    if ($InstallUpdates) {
        for ($pass = 1; $pass -le $MaxUpdatePasses; $pass++) {
            $current = Get-GuestWindowsState -Name $VMName -Credential $credential
            if ($current.buildNumber -ge $MinimumWindowsBuild) {
                Add-Event -Events $events -Message "Guest already meets target build before update pass $pass."
                break
            }
            Add-Event -Events $events -Message "Running Windows Update pass $pass of $MaxUpdatePasses."
            $passResult = Invoke-GuestWindowsUpdatePass -Name $VMName -Credential $credential -Pass $pass
            [void]$passes.Add($passResult)
            $needsReboot = [bool]$passResult.rebootRequired -or (Test-GuestRebootPending -Name $VMName -Credential $credential)
            if ($needsReboot) {
                Add-Event -Events $events -Message "Restarting VM after update pass $pass."
                try {
                    Restart-VM -Name $VMName -Force
                } catch {
                    Add-Event -Events $events -Level "WARN" -Message "Restart-VM returned '$($_.Exception.Message)'. Waiting because Windows Update may already be shutting the guest down."
                }
                Start-Sleep -Seconds 20
                if ((Get-VM -Name $VMName).State -eq "Off") {
                    Add-Event -Events $events -Message "Starting VM after update shutdown."
                    Start-VM -Name $VMName | Out-Null
                    Start-Sleep -Seconds 20
                }
                Wait-GuestReady -Name $VMName -Credential $credential -TimeoutSeconds $GuestReadyTimeoutSeconds -Events $events | Out-Null
            }
            if ($passResult.updateCount -eq 0) {
                Add-Event -Events $events -Level "WARN" -Message "No updates were available on pass $pass."
                break
            }
        }
    }

    $after = Get-GuestWindowsState -Name $VMName -Credential $credential
    $result.after = $after
    $result.supported = ($after.buildNumber -ge $MinimumWindowsBuild)
    Add-Event -Events $events -Message "Final guest build: $($after.caption) $($after.displayVersion) build $($after.buildNumber).$($after.ubr). Supported=$($result.supported)."

    if ($CreateCheckpoint -and $result.supported) {
        $existing = Get-VMSnapshot -VMName $VMName -Name $ReadyCheckpointName -ErrorAction SilentlyContinue
        if ($existing -and -not $ReplaceCheckpoint) {
            throw "Checkpoint '$ReadyCheckpointName' already exists. Pass -ReplaceCheckpoint to replace it."
        }
        if ($existing -and $ReplaceCheckpoint) {
            Add-Event -Events $events -Message "Removing existing checkpoint '$ReadyCheckpointName'."
            Remove-VMSnapshot -VMName $VMName -Name $ReadyCheckpointName -Confirm:$false
        }
        if ($PSCmdlet.ShouldProcess($VMName, "Create checkpoint $ReadyCheckpointName")) {
            Add-Event -Events $events -Message "Creating checkpoint '$ReadyCheckpointName'."
            Checkpoint-VM -Name $VMName -SnapshotName $ReadyCheckpointName | Out-Null
            $result.checkpointCreated = $true
        }
    } elseif ($CreateCheckpoint) {
        Add-Event -Events $events -Level "WARN" -Message "Checkpoint was not created because the guest does not meet build $MinimumWindowsBuild."
    }

    $result.ok = $true
} catch {
    $result.error = $_.Exception.Message
    Add-Event -Events $events -Level "ERROR" -Message $result.error
} finally {
    $result.completedAt = (Get-Date).ToString("o")
    Write-Utf8NoBom -Path $OutputPath -Value ($result | ConvertTo-Json -Depth 12)
}

if (-not $result.ok -or ($CreateCheckpoint -and -not $result.checkpointCreated)) {
    exit 1
}
exit 0
