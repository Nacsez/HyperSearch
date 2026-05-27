[CmdletBinding()]
param(
    [string]$VMName = "HyperSearchLab-Win11-24H2",
    [string]$CredentialPath = "C:\tmp\hypersearch-lab-credential.xml",
    [string]$GuestScenarioRoot = "C:\HyperSearchInstallerLab\win11-fresh-standard-full",
    [string]$OutputRoot = "%LOCALAPPDATA%\HyperSearch\installer-lab\live-snapshots",
    [switch]$NoSelfElevate
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Expand-LabPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowNull()]$Value = "")
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, [string]$Value, [System.Text.UTF8Encoding]::new($false))
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

function Get-WindowsPowerShellPath {
    $candidate = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $candidate) { return $candidate }
    return "powershell.exe"
}

if (-not (Test-Administrator)) {
    if ($NoSelfElevate) {
        throw "Get-HyperSearchLabLiveSnapshot.ps1 must run elevated because it uses Hyper-V PowerShell Direct."
    }
    $powershell = Get-WindowsPowerShellPath
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $PSCommandPath,
        "-VMName",
        $VMName,
        "-CredentialPath",
        $CredentialPath,
        "-GuestScenarioRoot",
        $GuestScenarioRoot,
        "-OutputRoot",
        $OutputRoot,
        "-NoSelfElevate"
    )
    Write-Host "Requesting elevation for HyperSearch lab live snapshot."
    $process = Start-Process -FilePath $powershell -ArgumentList (ConvertTo-ArgumentLine $args) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    exit $process.ExitCode
}

Import-Module Hyper-V -ErrorAction Stop

$CredentialPath = Expand-LabPath $CredentialPath
if (!(Test-Path -LiteralPath $CredentialPath)) {
    throw "Credential file was not found: $CredentialPath"
}
$credential = Import-Clixml -LiteralPath $CredentialPath
$snapshotId = Get-Date -Format "yyyyMMdd-HHmmss"
$snapshotRoot = Join-Path (Expand-LabPath $OutputRoot) $snapshotId
New-Item -ItemType Directory -Force -Path $snapshotRoot | Out-Null

$vm = Get-VM -Name $VMName -ErrorAction Stop
$processor = Get-VMProcessor -VMName $VMName -ErrorAction Stop
$hostSnapshot = [ordered]@{
    capturedAt = (Get-Date).ToString("o")
    vmName = $VMName
    state = [string]$vm.State
    uptime = [string]$vm.Uptime
    cpuUsage = $vm.CPUUsage
    memoryAssigned = $vm.MemoryAssigned
    status = [string]$vm.Status
    processorCount = [int]$processor.Count
    exposeVirtualizationExtensions = [bool]$processor.ExposeVirtualizationExtensions
}
Write-Utf8NoBom -Path (Join-Path $snapshotRoot "host-vm.json") -Value ($hostSnapshot | ConvertTo-Json -Depth 6)

$guestSnapshot = Invoke-Command -VMName $VMName -Credential $credential -ScriptBlock {
    param($ScenarioRoot)
    $ErrorActionPreference = "Continue"
    $localHyperSearch = Join-Path $env:LOCALAPPDATA "HyperSearch"
    $statePath = Join-Path $ScenarioRoot "installer-state.json"
    $progressPath = Join-Path $ScenarioRoot "installer-progress-watchdog.json"
    $processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -match "HyperSearch|installer-lab|HyperSearchPrereqSetup|HyperSearchInstallationWizard|Docker|DockerDesktop|wsl|winget|LM Studio|powershell|msiexec|setup" -or
            $_.Name -match "powershell|wsl|Docker|winget|msiexec|setup"
        } |
        Select-Object ProcessId, ParentProcessId, Name, CreationDate, CommandLine)
    $scenarioFiles = @()
    if (Test-Path -LiteralPath $ScenarioRoot) {
        $scenarioFiles = @(Get-ChildItem -LiteralPath $ScenarioRoot -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 120 FullName, Length, LastWriteTime)
    }
    $hyperSearchFiles = @()
    if (Test-Path -LiteralPath $localHyperSearch) {
        $hyperSearchFiles = @(Get-ChildItem -LiteralPath $localHyperSearch -Recurse -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 120 FullName, Length, LastWriteTime)
    }
    [pscustomobject][ordered]@{
        capturedAt = (Get-Date).ToString("o")
        computerName = $env:COMPUTERNAME
        user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        scenarioRoot = $ScenarioRoot
        scenarioRootExists = Test-Path -LiteralPath $ScenarioRoot
        installerStateExists = Test-Path -LiteralPath $statePath
        progressWatchdogExists = Test-Path -LiteralPath $progressPath
        localHyperSearch = $localHyperSearch
        localHyperSearchExists = Test-Path -LiteralPath $localHyperSearch
        processes = $processes
        scenarioFiles = $scenarioFiles
        hyperSearchFiles = $hyperSearchFiles
        installerStateTail = if (Test-Path -LiteralPath $statePath) { @(Get-Content -LiteralPath $statePath -Tail 160) } else { @() }
        progressWatchdogTail = if (Test-Path -LiteralPath $progressPath) { @(Get-Content -LiteralPath $progressPath -Tail 160) } else { @() }
    }
} -ArgumentList $GuestScenarioRoot

Write-Utf8NoBom -Path (Join-Path $snapshotRoot "guest-snapshot.json") -Value ($guestSnapshot | ConvertTo-Json -Depth 10)

$commandLogs = @($guestSnapshot.hyperSearchFiles | Where-Object { [string]$_.FullName -match "\\logs\\commands\\" } | Select-Object -First 20)
foreach ($entry in $commandLogs) {
    $safeName = ([IO.Path]::GetFileName([string]$entry.FullName)) -replace '[^\w\.\-]+', '_'
    try {
        $content = Invoke-Command -VMName $VMName -Credential $credential -ScriptBlock {
            param($Path)
            if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Tail 120 }
        } -ArgumentList ([string]$entry.FullName)
        Write-Utf8NoBom -Path (Join-Path $snapshotRoot "guest-command-log-$safeName.txt") -Value ($content -join "`r`n")
    } catch {}
}

[pscustomobject][ordered]@{
    snapshotRoot = $snapshotRoot
    vmState = $hostSnapshot.state
    installerStateExists = $guestSnapshot.installerStateExists
    progressWatchdogExists = $guestSnapshot.progressWatchdogExists
    processCount = @($guestSnapshot.processes).Count
    latestScenarioFile = @($guestSnapshot.scenarioFiles | Select-Object -First 1)
    latestHyperSearchFile = @($guestSnapshot.hyperSearchFiles | Select-Object -First 1)
} | ConvertTo-Json -Depth 6
