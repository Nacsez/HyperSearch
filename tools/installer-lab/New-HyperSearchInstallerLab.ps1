[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "configs\lab.example.json"),
    [string]$VMName = "",
    [string]$BaseVhdPath = "",
    [string]$SwitchName = "Default Switch",
    [string]$CheckpointName = "clean-windows",
    [switch]$StartVM,
    [switch]$CreateCheckpoint
)

$ErrorActionPreference = "Stop"

function Expand-LabPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Hyper-V lab setup must be run from an elevated PowerShell session."
    }
}

function Read-LabConfig {
    param([string]$Path)
    if (!(Test-Path $Path)) {
        throw "Lab config was not found: $Path"
    }
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

Assert-Admin
Import-Module Hyper-V -ErrorAction Stop

$config = Read-LabConfig -Path $ConfigPath
$labRoot = Expand-LabPath $config.labRoot
if ([string]::IsNullOrWhiteSpace($labRoot)) {
    $labRoot = Join-Path $env:LOCALAPPDATA "HyperSearch\installer-lab"
}
New-Item -ItemType Directory -Force -Path $labRoot | Out-Null

if ([string]::IsNullOrWhiteSpace($VMName)) {
    $firstScenario = @($config.scenarios | Select-Object -First 1)
    if ($firstScenario.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$firstScenario[0].vmName)) {
        throw "Pass -VMName or set scenarios[0].vmName in the lab config."
    }
    $VMName = [string]$firstScenario[0].vmName
}

$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    if ([string]::IsNullOrWhiteSpace($BaseVhdPath)) {
        throw "VM '$VMName' does not exist. Pass -BaseVhdPath to create it from an existing Windows VHDX, or create/import the VM first."
    }
    $BaseVhdPath = Expand-LabPath $BaseVhdPath
    if (!(Test-Path $BaseVhdPath)) {
        throw "Base VHDX was not found: $BaseVhdPath"
    }
    $vmRoot = Join-Path $labRoot "vms\$VMName"
    New-Item -ItemType Directory -Force -Path $vmRoot | Out-Null
    if ($PSCmdlet.ShouldProcess($VMName, "Create Hyper-V VM from $BaseVhdPath")) {
        $vm = New-VM -Name $VMName -Generation 2 -MemoryStartupBytes ([int64]$config.vmDefaults.memoryStartupBytes) -VHDPath $BaseVhdPath -SwitchName $SwitchName -Path $vmRoot
    }
} else {
    Write-Host "Using existing VM: $VMName"
}

$processorCount = if ($config.vmDefaults.processorCount) { [int]$config.vmDefaults.processorCount } else { 4 }
$memoryStartupBytes = if ($config.vmDefaults.memoryStartupBytes) { [int64]$config.vmDefaults.memoryStartupBytes } else { 17179869184 }
$checkpointType = if ($config.vmDefaults.checkpointType) { [string]$config.vmDefaults.checkpointType } else { "Standard" }

if ($PSCmdlet.ShouldProcess($VMName, "Configure Hyper-V test settings")) {
    Set-VMProcessor -VMName $VMName -Count $processorCount
    Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes $memoryStartupBytes
    Set-VM -Name $VMName -CheckpointType $checkpointType
    if ($config.vmDefaults.enableNestedVirtualization -ne $false) {
        Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true
    }
    if ($config.vmDefaults.enableGuestServiceInterface -ne $false) {
        Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue
    }
}

if ($StartVM -and (Get-VM -Name $VMName).State -ne "Running") {
    if ($PSCmdlet.ShouldProcess($VMName, "Start VM")) {
        Start-VM -Name $VMName | Out-Null
    }
}

if ($CreateCheckpoint) {
    $existing = Get-VMSnapshot -VMName $VMName -Name $CheckpointName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Checkpoint already exists: $CheckpointName"
    } elseif ($PSCmdlet.ShouldProcess($VMName, "Create checkpoint $CheckpointName")) {
        Checkpoint-VM -Name $VMName -SnapshotName $CheckpointName | Out-Null
    }
}

Get-VM -Name $VMName | Select-Object Name, State, Generation, ProcessorCount, MemoryStartup
