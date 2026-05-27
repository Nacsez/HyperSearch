[CmdletBinding()]
param(
    [string]$ConfigName = "dev-win11-standard-full.local.json",
    [string]$OutputRoot = "%LOCALAPPDATA%\HyperSearch\installer-lab\host-stops",
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
        throw "Stop-HyperSearchLabHostRun.ps1 must run elevated to inspect and stop host lab processes."
    }
    $powershell = Get-WindowsPowerShellPath
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $PSCommandPath,
        "-ConfigName",
        $ConfigName,
        "-OutputRoot",
        $OutputRoot,
        "-NoSelfElevate"
    )
    Write-Host "Requesting elevation to stop stale HyperSearch host release-gate processes."
    $process = Start-Process -FilePath $powershell -ArgumentList (ConvertTo-ArgumentLine $args) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    exit $process.ExitCode
}

$stopId = Get-Date -Format "yyyyMMdd-HHmmss"
$stopRoot = Join-Path (Expand-LabPath $OutputRoot) $stopId
New-Item -ItemType Directory -Force -Path $stopRoot | Out-Null

$currentPid = $PID
$patterns = @(
    "Invoke-HyperSearchVmReleaseGate.ps1",
    "Invoke-HyperSearchInstallerMatrix.ps1"
)
$candidates = @(Get-CimInstance Win32_Process -ErrorAction Stop |
    Where-Object {
        $_.ProcessId -ne $currentPid -and
        $_.CommandLine -and
        ($_.CommandLine -match ($patterns -join "|")) -and
        ([string]::IsNullOrWhiteSpace($ConfigName) -or $_.CommandLine -match [regex]::Escape($ConfigName))
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

$summary = [ordered]@{
    capturedAt = (Get-Date).ToString("o")
    configName = $ConfigName
    candidates = $candidates
    stopped = $stopped
}
$path = Join-Path $stopRoot "host-stop-summary.json"
Write-Utf8NoBom -Path $path -Value ($summary | ConvertTo-Json -Depth 8)
[pscustomobject][ordered]@{
    stopRoot = $stopRoot
    candidateCount = @($candidates).Count
    stoppedCount = @($stopped | Where-Object { $_.stopped -eq $true }).Count
} | ConvertTo-Json -Depth 4
