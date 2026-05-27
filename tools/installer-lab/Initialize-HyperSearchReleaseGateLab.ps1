[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Win10IsoPath,
    [Parameter(Mandatory = $true)][string]$Win11IsoPath,
    [string]$MediaRoot = "Installation Media\PublicRelease_1_1\Full",
    [string]$InstallerExe = "HyperSearch_1.1.0_x64-setup.exe",
    [string]$LabRoot = "E:\HyperSearchInstallerLab",
    [string]$CredentialPath = "C:\tmp\hypersearch-lab-credential.xml",
    [string]$ConfigOutputPath = "",
    [string]$Win10VmName = "HyperSearchLab-Win10-22H2",
    [string]$Win11VmName = "HyperSearchLab-Win11-24H2",
    [string]$CheckpointName = "clean-windows-docker-supported-ready",
    [string]$LocalAdminUser = "HyperSearchAdmin",
    [string]$Win10ImageName = "*Windows 10 Pro*",
    [string]$Win11ImageName = "*Windows 11 Pro*",
    [switch]$SkipVmCreation,
    [switch]$RunGate,
    [switch]$Force,
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

function Resolve-RepoPath {
    param([string]$Path)
    $expanded = Expand-LabPath $Path
    if ([IO.Path]::IsPathRooted($expanded)) { return [IO.Path]::GetFullPath($expanded) }
    $repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
    return [IO.Path]::GetFullPath((Join-Path $repoRoot $expanded))
}

function Invoke-LabScript {
    param([string]$ScriptPath, [string[]]$Arguments)
    $argLine = ConvertTo-ArgumentLine (@("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $Arguments)
    $script:StepIndex += 1
    $safeName = "{0:D2}-{1}" -f $script:StepIndex, [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
    $stdoutPath = Join-Path $script:InitLogRoot "$safeName.stdout.log"
    $stderrPath = Join-Path $script:InitLogRoot "$safeName.stderr.log"
    Write-Host "[HyperSearchLab] $ScriptPath $($Arguments -join ' ')"
    $process = Start-Process `
        -FilePath (Get-WindowsPowerShellPath) `
        -ArgumentList $argLine `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -Wait `
        -PassThru `
        -WindowStyle Hidden
    if ($process.ExitCode -ne 0) {
        throw "$ScriptPath failed with exit code $($process.ExitCode). See $stdoutPath and $stderrPath."
    }
}

$requiresAdministrator = (-not $SkipVmCreation) -or $RunGate
if ($requiresAdministrator -and -not (Test-Administrator)) {
    if ($NoSelfElevate) {
        throw "Release-gate lab initialization must run elevated to create Hyper-V VMs or run the VM matrix."
    }
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $PSCommandPath,
        "-Win10IsoPath",
        $Win10IsoPath,
        "-Win11IsoPath",
        $Win11IsoPath,
        "-MediaRoot",
        $MediaRoot,
        "-InstallerExe",
        $InstallerExe,
        "-LabRoot",
        $LabRoot,
        "-CredentialPath",
        $CredentialPath,
        "-Win10VmName",
        $Win10VmName,
        "-Win11VmName",
        $Win11VmName,
        "-CheckpointName",
        $CheckpointName,
        "-LocalAdminUser",
        $LocalAdminUser,
        "-Win10ImageName",
        $Win10ImageName,
        "-Win11ImageName",
        $Win11ImageName,
        "-NoSelfElevate"
    )
    if ($ConfigOutputPath) {
        $args += "-ConfigOutputPath"
        $args += $ConfigOutputPath
    }
    if ($SkipVmCreation) { $args += "-SkipVmCreation" }
    if ($RunGate) { $args += "-RunGate" }
    if ($Force) { $args += "-Force" }
    $argumentLine = ConvertTo-ArgumentLine $args
    Write-Host "Requesting elevation for HyperSearch release-gate lab initialization."
    $process = Start-Process -FilePath (Get-WindowsPowerShellPath) -ArgumentList $argumentLine -Verb RunAs -WindowStyle Hidden -Wait -PassThru
    exit $process.ExitCode
}

if ([string]::IsNullOrWhiteSpace($ConfigOutputPath)) {
    $ConfigOutputPath = Join-Path $PSScriptRoot "configs\release-gate.windows10-11.local.json"
}

$win10Iso = Resolve-RepoPath $Win10IsoPath
$win11Iso = Resolve-RepoPath $Win11IsoPath
$mediaRootFull = Resolve-RepoPath $MediaRoot
$credentialFull = Expand-LabPath $CredentialPath
$configFull = Resolve-RepoPath $ConfigOutputPath
$script:InitLogRoot = Join-Path $env:LOCALAPPDATA ("HyperSearch\installer-lab\initializers\{0}" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$script:StepIndex = 0
New-Item -ItemType Directory -Force -Path $script:InitLogRoot | Out-Null

if (!(Test-Path $win10Iso)) { throw "Windows 10 ISO was not found: $win10Iso" }
if (!(Test-Path $win11Iso)) { throw "Windows 11 ISO was not found: $win11Iso" }
if (!(Test-Path $mediaRootFull)) { throw "Full release media root was not found: $mediaRootFull" }
if (!(Test-Path (Join-Path $mediaRootFull $InstallerExe))) { throw "Installer EXE was not found: $(Join-Path $mediaRootFull $InstallerExe)" }

if (-not $SkipVmCreation) {
    $commonArgs = @(
        "-LabRoot",
        $LabRoot,
        "-LocalAdminUser",
        $LocalAdminUser,
        "-PasswordCredentialPath",
        $credentialFull,
        "-CredentialOutputPath",
        $credentialFull,
        "-CheckpointName",
        $CheckpointName
    )
    if ($Force) { $commonArgs += "-Force" }

    Invoke-LabScript -ScriptPath (Join-Path $PSScriptRoot "New-HyperSearchIsoLabVm.ps1") -Arguments (@(
        "-VMName",
        $Win10VmName,
        "-IsoPath",
        $win10Iso,
        "-ImageName",
        $Win10ImageName
    ) + $commonArgs)

    Invoke-LabScript -ScriptPath (Join-Path $PSScriptRoot "New-HyperSearchIsoLabVm.ps1") -Arguments (@(
        "-VMName",
        $Win11VmName,
        "-IsoPath",
        $win11Iso,
        "-ImageName",
        $Win11ImageName,
        "-EnableTpm"
    ) + $commonArgs)
}

$examplePath = Join-Path $PSScriptRoot "configs\release-gate.windows10-11.example.json"
$config = Get-Content -Raw -Path $examplePath | ConvertFrom-Json
$config.mediaRoot = $mediaRootFull
$config.installerExe = $InstallerExe
$config.guestCredentialPath = $credentialFull
$config.guestUser = $LocalAdminUser
$config.releaseGate.windows10.vmName = $Win10VmName
$config.releaseGate.windows10.checkpoint = $CheckpointName
$config.releaseGate.windows11.vmName = $Win11VmName
$config.releaseGate.windows11.checkpoint = $CheckpointName
foreach ($scenario in $config.scenarios) {
    if ([string]$scenario.name -like "win10-*") {
        $scenario.vmName = $Win10VmName
        $scenario.checkpoint = $CheckpointName
    }
    if ([string]$scenario.name -like "win11-*") {
        $scenario.vmName = $Win11VmName
        $scenario.checkpoint = $CheckpointName
    }
}
Write-Utf8NoBom -Path $configFull -Value ($config | ConvertTo-Json -Depth 10)
Write-Host "[HyperSearchLab] Wrote local release-gate config: $configFull"
Write-Host "[HyperSearchLab] Initialization logs: $script:InitLogRoot"

if ($RunGate) {
    Invoke-LabScript -ScriptPath (Join-Path $PSScriptRoot "Invoke-HyperSearchVmReleaseGate.ps1") -Arguments @(
        "-ConfigPath",
        $configFull,
        "-NoSelfElevate"
    )
}
