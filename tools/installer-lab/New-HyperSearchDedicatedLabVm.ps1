[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$VMName = "HyperSearchLab-WinDev",
    [string]$LabRoot = "E:\HyperSearchInstallerLab",
    [string]$DownloadUrl = "https://aka.ms/windev_VM_hyperv",
    [string]$ArchivePath = "",
    [string]$SwitchName = "Default Switch",
    [string]$CheckpointName = "clean-windows",
    [int]$ProcessorCount = 8,
    [Int64]$MemoryStartupBytes = 17179869184,
    [switch]$Download,
    [switch]$Extract,
    [switch]$Import,
    [switch]$StartVM,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Dedicated Hyper-V lab VM setup must be run from an elevated PowerShell session."
    }
}

function Write-Step {
    param([string]$Message)
    Write-Host "[HyperSearchLab] $Message"
}

function Get-FreeBytes {
    param([string]$Path)
    $root = [System.IO.Path]::GetPathRoot((Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue).Path)
    if (-not $root) {
        $root = [System.IO.Path]::GetPathRoot($Path)
    }
    $drive = [System.IO.DriveInfo]::new($root)
    return $drive.AvailableFreeSpace
}

function Invoke-Download {
    param([string]$Uri, [string]$Destination)
    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if (Test-Path $Destination) {
        Write-Step "Download already exists: $Destination"
        return
    }

    Write-Step "Resolving download URL: $Uri"
    $head = Invoke-WebRequest -Uri $Uri -Method Head -MaximumRedirection 5 -UseBasicParsing
    $resolved = $head.BaseResponse.ResponseUri.AbsoluteUri
    $bytes = [int64]($head.Headers["Content-Length"])
    if ($bytes -gt 0) {
        $free = Get-FreeBytes -Path $parent
        if ($free -lt ($bytes * 3)) {
            throw "Not enough free space under $parent. Need roughly $([math]::Round(($bytes * 3) / 1GB, 2)) GB for download plus expansion; free $([math]::Round($free / 1GB, 2)) GB."
        }
    }

    Write-Step "Downloading $resolved to $Destination"
    try {
        Start-BitsTransfer -Source $resolved -Destination $Destination -DisplayName "HyperSearch Windows lab VM" -Description "Microsoft Windows development VM for HyperSearch installer tests" -ErrorAction Stop
    } catch {
        Write-Step "BITS download failed, falling back to Invoke-WebRequest: $($_.Exception.Message)"
        Invoke-WebRequest -Uri $resolved -OutFile $Destination -UseBasicParsing
    }
}

function Expand-LabArchive {
    param([string]$SourceArchive, [string]$Destination)
    if (!(Test-Path $SourceArchive)) {
        throw "Archive was not found: $SourceArchive"
    }
    $marker = Join-Path $Destination ".extracted"
    if ((Test-Path $marker) -and -not $Force) {
        Write-Step "Archive already extracted: $Destination"
        return
    }
    if ((Test-Path $Destination) -and $Force) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Write-Step "Extracting $SourceArchive to $Destination"
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if ($tar) {
        & $tar.Source -xf $SourceArchive -C $Destination
        if ($LASTEXITCODE -ne 0) {
            throw "tar.exe extraction failed with exit code $LASTEXITCODE"
        }
    } else {
        Expand-Archive -Path $SourceArchive -DestinationPath $Destination -Force
    }
    Set-Content -Path $marker -Value (Get-Date).ToString("o") -Encoding ASCII
}

function Find-HyperVConfig {
    param([string]$Root)
    $vmcx = Get-ChildItem -Path $Root -Recurse -File -Filter "*.vmcx" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($vmcx) { return $vmcx.FullName }
    $xml = Get-ChildItem -Path $Root -Recurse -File -Filter "*.xml" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "\\Virtual Machines\\" } |
        Select-Object -First 1
    if ($xml) { return $xml.FullName }
    return ""
}

function Find-LabVhd {
    param([string]$Root)
    $vhd = Get-ChildItem -Path $Root -Recurse -File -Include "*.vhdx", "*.vhd" -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending |
        Select-Object -First 1
    if ($vhd) { return $vhd.FullName }
    return ""
}

function Configure-LabVm {
    param([string]$Name)
    Write-Step "Configuring VM settings for $Name"
    Set-VMProcessor -VMName $Name -Count $ProcessorCount
    Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false -StartupBytes $MemoryStartupBytes
    Set-VM -Name $Name -CheckpointType Standard
    Set-VMProcessor -VMName $Name -ExposeVirtualizationExtensions $true
    Enable-VMIntegrationService -VMName $Name -Name "Guest Service Interface" -ErrorAction SilentlyContinue
    $adapter = Get-VMNetworkAdapter -VMName $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($adapter -and $SwitchName) {
        Connect-VMNetworkAdapter -VMName $Name -SwitchName $SwitchName
    }
}

Assert-Admin
Import-Module Hyper-V -ErrorAction Stop

$downloadRoot = Join-Path $LabRoot "downloads"
$extractRoot = Join-Path $LabRoot "expanded"
$vmRoot = Join-Path $LabRoot "vms"
$vhdRoot = Join-Path $LabRoot "vhds"
New-Item -ItemType Directory -Force -Path $downloadRoot, $extractRoot, $vmRoot, $vhdRoot | Out-Null

if (-not $ArchivePath) {
    $ArchivePath = Join-Path $downloadRoot "WinDev.HyperV.zip"
}

if ($Download) {
    Invoke-Download -Uri $DownloadUrl -Destination $ArchivePath
}
if ($Extract) {
    Expand-LabArchive -SourceArchive $ArchivePath -Destination $extractRoot
}

$existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existing -and $Import) {
    if (-not $Force) {
        throw "VM '$VMName' already exists. Use -Force to replace it."
    }
    if ($PSCmdlet.ShouldProcess($VMName, "Remove existing dedicated lab VM")) {
        if ($existing.State -ne "Off") {
            Stop-VM -Name $VMName -TurnOff -Force
        }
        Remove-VM -Name $VMName -Force
    }
}

if ($Import) {
    $configPath = Find-HyperVConfig -Root $extractRoot
    $vhdPath = Find-LabVhd -Root $extractRoot
    if (-not $configPath -and -not $vhdPath) {
        throw "No Hyper-V VM config or VHD/VHDX was found under $extractRoot."
    }

    if ($configPath) {
        Write-Step "Importing VM from $configPath"
        $imported = Import-VM -Path $configPath -Copy -GenerateNewId -VirtualMachinePath $vmRoot -VhdDestinationPath $vhdRoot
        if ($imported.Name -ne $VMName) {
            Rename-VM -VM $imported -NewName $VMName
        }
    } else {
        Write-Step "Creating VM from VHD $vhdPath"
        $targetVhd = Join-Path $vhdRoot "$VMName.vhdx"
        Copy-Item -LiteralPath $vhdPath -Destination $targetVhd -Force
        New-VM -Name $VMName -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -VHDPath $targetVhd -Path $vmRoot -SwitchName $SwitchName | Out-Null
    }

    Configure-LabVm -Name $VMName
    $snapshot = Get-VMSnapshot -VMName $VMName -Name $CheckpointName -ErrorAction SilentlyContinue
    if (-not $snapshot) {
        Write-Step "Creating checkpoint $CheckpointName"
        Checkpoint-VM -Name $VMName -SnapshotName $CheckpointName | Out-Null
    }
}

if ($StartVM) {
    if ((Get-VM -Name $VMName).State -ne "Running") {
        Write-Step "Starting VM $VMName"
        Start-VM -Name $VMName | Out-Null
    }
}

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
[pscustomobject]@{
    vmName = $VMName
    vmExists = [bool]$vm
    state = if ($vm) { [string]$vm.State } else { "" }
    labRoot = $LabRoot
    archivePath = $ArchivePath
    extractRoot = $extractRoot
    checkpoint = $CheckpointName
    processorCount = $ProcessorCount
    memoryStartupBytes = $MemoryStartupBytes
} | ConvertTo-Json -Depth 4
