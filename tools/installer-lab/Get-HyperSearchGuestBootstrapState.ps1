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
        throw "Bootstrap state inspection must be run from an elevated PowerShell session."
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
    service = $null
    files = @()
}

$mounted = $null
$systemHiveLoaded = $false
try {
    $mounted = Mount-VHD -Path $vhd -PassThru
    $disk = $mounted | Get-Disk
    $windowsRoot = Find-WindowsRoot -DiskNumber $disk.Number
    $result.windowsRoot = $windowsRoot
    if ($windowsRoot) {
        $systemHive = Join-Path $windowsRoot "Windows\System32\Config\SYSTEM"
        & reg.exe load HKLM\HyperSearchInspectSystem $systemHive | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $systemHiveLoaded = $true
            $select = Get-ItemProperty -Path "HKLM:\HyperSearchInspectSystem\Select"
            $controlSet = "ControlSet{0:D3}" -f ([int]$select.Current)
            $servicePath = "HKLM:\HyperSearchInspectSystem\$controlSet\Services\HyperSearchLabBootstrap"
            if (Test-Path $servicePath) {
                $service = Get-ItemProperty -Path $servicePath
                $result.service = [ordered]@{
                    controlSet = $controlSet
                    type = $service.Type
                    start = $service.Start
                    errorControl = $service.ErrorControl
                    objectName = $service.ObjectName
                    imagePath = $service.ImagePath
                }
            }
        }
        $dir = Join-Path $windowsRoot "ProgramData\HyperSearchLab"
        if (Test-Path $dir) {
            $result.files = @(Get-ChildItem -Path $dir -Force | ForEach-Object {
                $content = ""
                if ($_.Name -like "*Bootstrap*.ps1") {
                    $content = "<redacted bootstrap script>"
                } elseif (-not $_.PSIsContainer -and $_.Length -lt 20000) {
                    $content = [IO.File]::ReadAllText($_.FullName)
                }
                [ordered]@{
                    name = $_.Name
                    length = if ($_.PSIsContainer) { $null } else { $_.Length }
                    lastWriteTime = $_.LastWriteTime.ToString("o")
                    content = $content
                }
            })
        }
    }
} finally {
    if ($systemHiveLoaded) {
        [gc]::Collect()
        Start-Sleep -Milliseconds 500
        & reg.exe unload HKLM\HyperSearchInspectSystem | Out-Null
    }
    if ($mounted) {
        Dismount-VHD -Path $vhd
    }
}

$json = $result | ConvertTo-Json -Depth 6
if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
} else {
    $json
}
