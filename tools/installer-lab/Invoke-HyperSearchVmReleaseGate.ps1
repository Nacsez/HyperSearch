[CmdletBinding()]
param(
    [string]$ConfigPath = "",
    [string[]]$ScenarioName = @(),
    [string]$OutputRoot = "%LOCALAPPDATA%\HyperSearch\installer-lab\release-gates",
    [switch]$SkipUnitTests,
    [switch]$SkipMatrix,
    [switch]$SkipMediaCopy,
    [switch]$KeepVmRunning,
    [switch]$NoSelfElevate
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Expand-GatePath {
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

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
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

function Get-RepoRoot {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
}

function Write-GateLog {
    param([Parameter(Mandatory = $true)][string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message
    Add-Content -Path $script:GateLog -Value $line
    Write-Host $line
}

function Invoke-GateProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory
    )
    $stdoutPath = Join-Path $script:GateRoot "$Name.stdout.log"
    $stderrPath = Join-Path $script:GateRoot "$Name.stderr.log"
    $argumentLine = ConvertTo-ArgumentLine $Arguments
    Write-GateLog "Starting step '$Name': $FilePath $argumentLine"
    $started = Get-Date
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $argumentLine `
        -WorkingDirectory $WorkingDirectory `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    $completed = Get-Date
    $status = if ($process.ExitCode -eq 0) { "passed" } else { "failed" }
    Write-GateLog "Completed step '$Name' with exit code $($process.ExitCode)."
    return [ordered]@{
        name = $Name
        status = $status
        exitCode = $process.ExitCode
        startedAt = $started.ToString("o")
        completedAt = $completed.ToString("o")
        durationSeconds = [math]::Round(($completed - $started).TotalSeconds, 2)
        stdoutPath = $stdoutPath
        stderrPath = $stderrPath
    }
}

function Read-GateConfig {
    param([string]$Path)
    if (!(Test-Path $Path)) { return $null }
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function Get-LabRunsRoot {
    param($Config)
    if ($null -eq $Config) { return "" }
    $labRoot = ""
    if ($Config.PSObject.Properties["labRoot"]) {
        $labRoot = Expand-GatePath ([string]$Config.labRoot)
    }
    if ([string]::IsNullOrWhiteSpace($labRoot)) {
        $labRoot = Join-Path $env:LOCALAPPDATA "HyperSearch\installer-lab"
    }
    return Join-Path $labRoot "runs"
}

function Find-NewestMatrixSummary {
    param([string]$RunsRoot, [datetime]$StartedAfter)
    if ([string]::IsNullOrWhiteSpace($RunsRoot) -or !(Test-Path $RunsRoot)) { return "" }
    $summary = Get-ChildItem -Path $RunsRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $StartedAfter.AddMinutes(-1) } |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object {
            $candidate = Join-Path $_.FullName "matrix-summary.json"
            if (Test-Path $candidate) { return $candidate }
        } |
        Select-Object -First 1
    if ($summary) { return [string]$summary }
    return ""
}

$requiresAdministrator = -not $SkipMatrix
if ($requiresAdministrator -and -not (Test-Administrator)) {
    if ($NoSelfElevate) {
        throw "HyperSearch VM release gate must run elevated because it restores Hyper-V checkpoints and controls VMs."
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
        "-NoSelfElevate"
    )
    if ($ScenarioName.Count -gt 0) {
        $args += "-ScenarioName"
        $args += $ScenarioName
    }
    if ($SkipUnitTests) { $args += "-SkipUnitTests" }
    if ($SkipMatrix) { $args += "-SkipMatrix" }
    if ($SkipMediaCopy) { $args += "-SkipMediaCopy" }
    if ($KeepVmRunning) { $args += "-KeepVmRunning" }
    $argumentLine = ConvertTo-ArgumentLine $args
    Write-Host "Requesting elevation for HyperSearch VM release gate."
    $process = Start-Process -FilePath $powershell -ArgumentList $argumentLine -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    exit $process.ExitCode
}

$repoRoot = Get-RepoRoot
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot "configs\release-gate.windows10-11.example.json"
}
$outputBase = Expand-GatePath $OutputRoot
if ([string]::IsNullOrWhiteSpace($outputBase)) {
    $outputBase = Join-Path $env:LOCALAPPDATA "HyperSearch\installer-lab\release-gates"
}
$gateId = Get-Date -Format "yyyyMMdd-HHmmss"
$script:GateRoot = Join-Path $outputBase $gateId
New-Item -ItemType Directory -Force -Path $script:GateRoot | Out-Null
$script:GateLog = Join-Path $script:GateRoot "release-gate.log"

$resolvedConfigPath = if ([IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath } else { Join-Path $repoRoot $ConfigPath }
$config = Read-GateConfig -Path $resolvedConfigPath
$summary = [ordered]@{
    gateId = $gateId
    repoRoot = $repoRoot
    configPath = $resolvedConfigPath
    outputRoot = $script:GateRoot
    startedAt = (Get-Date).ToString("o")
    completedAt = ""
    status = "failed"
    steps = @()
    matrixSummaryPath = ""
    matrixSummary = $null
}

try {
    Write-GateLog "HyperSearch VM release gate started. GateId=$gateId"
    if (!(Test-Path $resolvedConfigPath) -and -not $SkipMatrix) {
        throw "Release gate config was not found: $resolvedConfigPath"
    }
    if (Test-Path $resolvedConfigPath) {
        Copy-Item -LiteralPath $resolvedConfigPath -Destination (Join-Path $script:GateRoot "config.snapshot.json") -Force
    }

    if (-not $SkipUnitTests) {
        $python = (Get-Command python -ErrorAction Stop).Source
        $step = Invoke-GateProcess -Name "unit-installer-wizard" -FilePath $python -WorkingDirectory $repoRoot -Arguments @(
            "-m",
            "pytest",
            "tests/unit/test_installer_wizard.py",
            "-q"
        )
        $summary.steps += $step
        if ($step.exitCode -ne 0) {
            throw "Unit installer tests failed. See $($step.stdoutPath) and $($step.stderrPath)."
        }
    } else {
        Write-GateLog "Skipping unit tests by request." "WARN"
    }

    if (-not $SkipMatrix) {
        $matrixStarted = Get-Date
        $powershell = Get-WindowsPowerShellPath
        $matrixArgs = @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            (Join-Path $PSScriptRoot "Invoke-HyperSearchInstallerMatrix.ps1"),
            "-ConfigPath",
            $resolvedConfigPath
        )
        if ($ScenarioName.Count -gt 0) {
            $matrixArgs += "-ScenarioName"
            $matrixArgs += $ScenarioName
        }
        if ($SkipMediaCopy) { $matrixArgs += "-SkipMediaCopy" }
        if ($KeepVmRunning) { $matrixArgs += "-KeepVmRunning" }
        $step = Invoke-GateProcess -Name "hyperv-installer-matrix" -FilePath $powershell -WorkingDirectory $repoRoot -Arguments $matrixArgs
        $summary.steps += $step
        $matrixSummaryPath = Find-NewestMatrixSummary -RunsRoot (Get-LabRunsRoot -Config $config) -StartedAfter $matrixStarted
        $summary.matrixSummaryPath = $matrixSummaryPath
        if ($matrixSummaryPath) {
            Copy-Item -LiteralPath $matrixSummaryPath -Destination (Join-Path $script:GateRoot "matrix-summary.snapshot.json") -Force
            $summary.matrixSummary = Get-Content -Raw -Path $matrixSummaryPath | ConvertFrom-Json
        }
        if ($step.exitCode -ne 0) {
            throw "Hyper-V installer matrix failed. See $($step.stdoutPath), $($step.stderrPath), and $matrixSummaryPath."
        }
    } else {
        Write-GateLog "Skipping Hyper-V matrix by request." "WARN"
    }

    $summary.status = "passed"
    Write-GateLog "HyperSearch VM release gate passed."
} catch {
    $summary.status = "failed"
    $summary.error = $_.Exception.Message
    Write-GateLog $_.Exception.Message "ERROR"
} finally {
    $summary.completedAt = (Get-Date).ToString("o")
    Write-Utf8NoBom -Path (Join-Path $script:GateRoot "release-gate-summary.json") -Value ($summary | ConvertTo-Json -Depth 10)
    Write-GateLog "Release gate summary: $(Join-Path $script:GateRoot "release-gate-summary.json")"
}

if ($summary.status -ne "passed") { exit 1 }
exit 0
