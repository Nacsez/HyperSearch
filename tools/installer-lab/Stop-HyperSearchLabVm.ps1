[CmdletBinding()]
param(
    [string]$VMName = "HyperSearchLab-Win11-24H2",
    [string]$OutputRoot = "%LOCALAPPDATA%\HyperSearch\installer-lab\vm-stops",
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
        throw "Stop-HyperSearchLabVm.ps1 must run elevated because it controls Hyper-V VMs."
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
        "-OutputRoot",
        $OutputRoot,
        "-NoSelfElevate"
    )
    Write-Host "Requesting elevation to stop HyperSearch lab VM '$VMName'."
    $process = Start-Process -FilePath $powershell -ArgumentList (ConvertTo-ArgumentLine $args) -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    exit $process.ExitCode
}

Import-Module Hyper-V -ErrorAction Stop
$stopId = Get-Date -Format "yyyyMMdd-HHmmss"
$stopRoot = Join-Path (Expand-LabPath $OutputRoot) $stopId
New-Item -ItemType Directory -Force -Path $stopRoot | Out-Null

$before = Get-VM -Name $VMName -ErrorAction Stop
if ($before.State -ne "Off") {
    Stop-VM -Name $VMName -TurnOff -Force -ErrorAction Stop
}
$after = Get-VM -Name $VMName -ErrorAction Stop
$summary = [ordered]@{
    capturedAt = (Get-Date).ToString("o")
    vmName = $VMName
    beforeState = [string]$before.State
    afterState = [string]$after.State
}
$path = Join-Path $stopRoot "vm-stop-summary.json"
Write-Utf8NoBom -Path $path -Value ($summary | ConvertTo-Json -Depth 4)
$summary | ConvertTo-Json -Depth 4
