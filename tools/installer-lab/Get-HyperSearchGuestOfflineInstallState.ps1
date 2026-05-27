[CmdletBinding()]
param(
    [string]$VMName = "HyperSearchLab-WinDev",
    [string]$OutputPath = "",
    [switch]$StopVm
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Offline guest install state inspection must be run from an elevated PowerShell session."
    }
}

function Find-WindowsRoot {
    param([int]$DiskNumber)
    foreach ($partition in (Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.Type -eq "Basic" -or $_.GptType -eq "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}" })) {
        if (-not $partition.DriveLetter) {
            try {
                $partition | Add-PartitionAccessPath -AssignDriveLetter | Out-Null
                $partition = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $partition.PartitionNumber
            } catch {
                continue
            }
        }
        if ($partition.DriveLetter) {
            $root = "{0}:\" -f $partition.DriveLetter
            if (Test-Path (Join-Path $root "Windows\System32\Config\SYSTEM")) {
                return $root
            }
        }
    }
    return ""
}

function Get-RelativeListing {
    param([string]$Root, [int]$Limit = 120)
    if (!(Test-Path $Root)) { return @() }
    $base = (Resolve-Path $Root).Path
    return @(Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First $Limit |
        ForEach-Object {
            [ordered]@{
                relativePath = $_.FullName.Substring($base.Length).TrimStart("\")
                length = $_.Length
                lastWriteTime = $_.LastWriteTime.ToString("o")
            }
        })
}

Assert-Admin
Import-Module Hyper-V -ErrorAction Stop

if ($StopVm -and (Get-VM -Name $VMName).State -ne "Off") {
    Stop-VM -Name $VMName -TurnOff -Force
}

$vhd = (Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1).Path
$result = [ordered]@{
    vmName = $VMName
    state = [string](Get-VM -Name $VMName).State
    vhd = $vhd
    windowsRoot = ""
    paths = @()
    registry = @()
}

$mounted = $null
$softwareHiveLoaded = $false
try {
    $mounted = Mount-VHD -Path $vhd -PassThru
    $disk = $mounted | Get-Disk
    $windowsRoot = Find-WindowsRoot -DiskNumber $disk.Number
    $result.windowsRoot = $windowsRoot
    if ($windowsRoot) {
        $targetPaths = @(
            "Program Files\HyperSearch",
            "HyperSearchInstallerLab",
            "Users\seeker\AppData\Local\HyperSearch",
            "Users\User\AppData\Local\HyperSearch",
            "ProgramData\HyperSearch"
        )
        $result.paths = @($targetPaths | ForEach-Object {
            $path = Join-Path $windowsRoot $_
            [ordered]@{
                guestPath = "C:\$_"
                hostPath = $path
                exists = Test-Path $path
                files = Get-RelativeListing -Root $path
            }
        })

        $softwareHive = Join-Path $windowsRoot "Windows\System32\Config\SOFTWARE"
        & reg.exe load HKLM\HyperSearchInspectSoftware $softwareHive | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $softwareHiveLoaded = $true
            $uninstallRoots = @(
                "HKLM:\HyperSearchInspectSoftware\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKLM:\HyperSearchInspectSoftware\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
            )
            foreach ($root in $uninstallRoots) {
                if (Test-Path $root) {
                    $result.registry += @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
                        $props = Get-ItemProperty -Path $_.PSPath
                        if ($props.DisplayName -like "*HyperSearch*") {
                            [ordered]@{
                                key = $_.Name
                                displayName = $props.DisplayName
                                displayVersion = $props.DisplayVersion
                                installLocation = $props.InstallLocation
                                uninstallString = $props.UninstallString
                            }
                        }
                    } | Where-Object { $_ })
                }
            }
        }
    }
} finally {
    if ($softwareHiveLoaded) {
        [gc]::Collect()
        Start-Sleep -Milliseconds 500
        & reg.exe unload HKLM\HyperSearchInspectSoftware | Out-Null
    }
    if ($mounted) {
        Dismount-VHD -Path $vhd
    }
}

$json = $result | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
} else {
    $json
}
