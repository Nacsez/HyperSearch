[CmdletBinding()]
param(
    [string]$VMName = "HyperSearchLab-Win11-24H2",
    [string]$CredentialPath = "C:\tmp\hypersearch-lab-credential.xml",
    [string]$GuestScenarioRoot = "C:\HyperSearchInstallerLab\win11-fresh-standard-full",
    [string]$OutputRoot = "%LOCALAPPDATA%\HyperSearch\installer-lab\stops",
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
        throw "Stop-HyperSearchLabGuestInstaller.ps1 must run elevated because it uses Hyper-V PowerShell Direct."
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
    Write-Host "Requesting elevation to stop stale HyperSearch lab guest installer processes."
    $process = Start-Process -FilePath $powershell -ArgumentList (ConvertTo-ArgumentLine $args) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    exit $process.ExitCode
}

Import-Module Hyper-V -ErrorAction Stop

$CredentialPath = Expand-LabPath $CredentialPath
if (!(Test-Path -LiteralPath $CredentialPath)) {
    throw "Credential file was not found: $CredentialPath"
}
$credential = Import-Clixml -LiteralPath $CredentialPath
$stopId = Get-Date -Format "yyyyMMdd-HHmmss"
$stopRoot = Join-Path (Expand-LabPath $OutputRoot) $stopId
New-Item -ItemType Directory -Force -Path $stopRoot | Out-Null

$result = Invoke-Command -VMName $VMName -Credential $credential -ScriptBlock {
    param($ScenarioRoot)
    $ErrorActionPreference = "Continue"
    $candidates = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -match [regex]::Escape($ScenarioRoot) -and
            ($_.CommandLine -match "HyperSearchPrereqSetup\.ps1|HyperSearchInstallationWizard\.ps1|run-installer-core\.ps1")
        } |
        Select-Object ProcessId, ParentProcessId, Name, CreationDate, CommandLine)
    $stopped = @()
    foreach ($process in @($candidates | Sort-Object ProcessId -Descending)) {
        try {
            Stop-Process -Id ([int]$process.ProcessId) -Force -ErrorAction Stop
            $stopped += [ordered]@{
                processId = [int]$process.ProcessId
                name = [string]$process.Name
                commandLine = [string]$process.CommandLine
                stopped = $true
                error = ""
            }
        } catch {
            $stopped += [ordered]@{
                processId = [int]$process.ProcessId
                name = [string]$process.Name
                commandLine = [string]$process.CommandLine
                stopped = $false
                error = $_.Exception.Message
            }
        }
    }
    [pscustomobject][ordered]@{
        capturedAt = (Get-Date).ToString("o")
        computerName = $env:COMPUTERNAME
        scenarioRoot = $ScenarioRoot
        candidates = $candidates
        stopped = $stopped
    }
} -ArgumentList $GuestScenarioRoot

$path = Join-Path $stopRoot "stop-summary.json"
Write-Utf8NoBom -Path $path -Value ($result | ConvertTo-Json -Depth 8)
[pscustomobject][ordered]@{
    stopRoot = $stopRoot
    candidateCount = @($result.candidates).Count
    stoppedCount = @($result.stopped | Where-Object { $_.stopped -eq $true }).Count
} | ConvertTo-Json -Depth 4
