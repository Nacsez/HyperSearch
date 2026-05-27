param(
    [string]$InstallDir = "",
    [string]$MediaDir = "",
    [switch]$DownloadModelOnly,
    [string]$ModelId = "",
    [string]$ModelLabel = "",
    [switch]$Automated,
    [string]$ConfigPath = "",
    [string]$ResultPath = ""
)

$ErrorActionPreference = "Stop"

function Write-WrapperLog {
    param([string]$Message)
    try {
        $logRoot = Join-Path $env:LOCALAPPDATA "HyperSearch\logs"
        New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
        if (-not $script:WrapperLogPath) {
            $script:WrapperLogPath = Join-Path $logRoot ("prereq-wrapper-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        }
        $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
        Add-Content -Path $script:WrapperLogPath -Value $line
    } catch {
        Write-Host "[HyperSearchPrereqSetup] $Message"
    }
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

if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $nativePowerShell = Join-Path $env:WINDIR "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $nativePowerShell) {
        $nativeArgs = @(
            "-NoProfile",
            "-Sta",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            $PSCommandPath
        )
        if (-not [string]::IsNullOrWhiteSpace($InstallDir)) { $nativeArgs += @("-InstallDir", $InstallDir) }
        if (-not [string]::IsNullOrWhiteSpace($MediaDir)) { $nativeArgs += @("-MediaDir", $MediaDir) }
        if ($DownloadModelOnly) { $nativeArgs += "-DownloadModelOnly" }
        if (-not [string]::IsNullOrWhiteSpace($ModelId)) { $nativeArgs += @("-ModelId", $ModelId) }
        if (-not [string]::IsNullOrWhiteSpace($ModelLabel)) { $nativeArgs += @("-ModelLabel", $ModelLabel) }
        if ($Automated) { $nativeArgs += "-Automated" }
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $nativeArgs += @("-ConfigPath", $ConfigPath) }
        if (-not [string]::IsNullOrWhiteSpace($ResultPath)) { $nativeArgs += @("-ResultPath", $ResultPath) }
        $nativeArgumentLine = ($nativeArgs | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) }) -join " "
        Write-WrapperLog "Re-launching wrapper in 64-bit PowerShell: $nativePowerShell $nativeArgumentLine"
        $nativeProcess = Start-Process -FilePath $nativePowerShell -ArgumentList $nativeArgumentLine -Wait -PassThru
        Write-WrapperLog "64-bit wrapper exited with code $($nativeProcess.ExitCode)"
        exit $nativeProcess.ExitCode
    }
}

Write-WrapperLog "Wrapper start. InstallDir='$InstallDir' MediaDir='$MediaDir' Automated=$Automated ConfigPath='$ConfigPath' ResultPath='$ResultPath'"

$wizard = Join-Path $PSScriptRoot "HyperSearchInstallationWizard.ps1"
$argsList = @(
    "-NoProfile",
    "-Sta",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $wizard,
    "-InstallDir",
    $InstallDir,
    "-MediaDir",
    $MediaDir
)

if ($DownloadModelOnly) {
    $argsList += "-DownloadModelOnly"
}
if (-not [string]::IsNullOrWhiteSpace($ModelId)) {
    $argsList += @("-ModelId", $ModelId)
}
if (-not [string]::IsNullOrWhiteSpace($ModelLabel)) {
    $argsList += @("-ModelLabel", $ModelLabel)
}

$automationConfig = $ConfigPath
if ([string]::IsNullOrWhiteSpace($automationConfig) -and -not [string]::IsNullOrWhiteSpace($env:HYPERSEARCH_INSTALL_AUTOMATED_CONFIG)) {
    $automationConfig = $env:HYPERSEARCH_INSTALL_AUTOMATED_CONFIG
}
if ([string]::IsNullOrWhiteSpace($automationConfig) -and -not [string]::IsNullOrWhiteSpace($MediaDir)) {
    $mediaConfig = Join-Path $MediaDir "hypersearch-install-automation.json"
    if (Test-Path $mediaConfig) {
        $automationConfig = $mediaConfig
    }
}
Write-WrapperLog "Automation config resolved to '$automationConfig'"
$resolvedResultPath = $ResultPath
if ([string]::IsNullOrWhiteSpace($resolvedResultPath) -and -not [string]::IsNullOrWhiteSpace($automationConfig) -and (Test-Path $automationConfig)) {
    try {
        $automation = Get-Content -Raw -Path $automationConfig | ConvertFrom-Json
        if ($automation.PSObject.Properties["resultPath"] -and -not [string]::IsNullOrWhiteSpace([string]$automation.resultPath)) {
            $resolvedResultPath = [string]$automation.resultPath
            Write-WrapperLog "Result path resolved from automation config to '$resolvedResultPath'"
        }
    } catch {
        Write-WrapperLog "Could not read resultPath from automation config: $($_.Exception.Message)"
    }
}
if ($Automated -or -not [string]::IsNullOrWhiteSpace($automationConfig)) {
    $argsList += "-Automated"
    if (-not [string]::IsNullOrWhiteSpace($automationConfig)) {
        $argsList += @("-ConfigPath", $automationConfig)
    }
    if (-not [string]::IsNullOrWhiteSpace($resolvedResultPath)) {
        $argsList += @("-ResultPath", $resolvedResultPath)
    }
}

$argumentLine = ($argsList | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) }) -join " "
Write-WrapperLog "Launching wizard: powershell.exe $argumentLine"
$process = Start-Process -FilePath "powershell.exe" -ArgumentList $argumentLine -Wait -PassThru
Write-WrapperLog "Wizard exited with code $($process.ExitCode)"
if (-not [string]::IsNullOrWhiteSpace($resolvedResultPath) -and !(Test-Path $resolvedResultPath)) {
    try {
        $summary = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "HyperSearch\logs") -Filter "setup-summary-*.json" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($summary) {
            $parent = Split-Path -Parent $resolvedResultPath
            if ($parent) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
            Copy-Item -LiteralPath $summary.FullName -Destination $resolvedResultPath -Force
            Write-WrapperLog "Copied setup summary to missing result path '$resolvedResultPath'"
        } else {
            Write-WrapperLog "No setup summary was available to copy to result path '$resolvedResultPath'"
        }
    } catch {
        Write-WrapperLog "Could not backfill result path '$resolvedResultPath': $($_.Exception.Message)"
    }
}
exit $process.ExitCode
