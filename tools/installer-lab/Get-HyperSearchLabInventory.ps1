[CmdletBinding()]
param(
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$result = [ordered]@{
    ok = $true
    generatedAt = (Get-Date).ToString("o")
    isAdmin = Test-IsAdmin
    vms = @()
}

try {
    Import-Module Hyper-V -ErrorAction Stop
    foreach ($vm in Get-VM) {
        $result.vms += [ordered]@{
            name = $vm.Name
            state = [string]$vm.State
            generation = $vm.Generation
            processorCount = $vm.ProcessorCount
            memoryStartup = $vm.MemoryStartup
            checkpointType = [string]$vm.CheckpointType
            notes = $vm.Notes
            disks = @(Get-VMHardDiskDrive -VMName $vm.Name | Select-Object Path, ControllerType, ControllerNumber, ControllerLocation)
            snapshots = @(Get-VMSnapshot -VMName $vm.Name -ErrorAction SilentlyContinue | Select-Object Name, CreationTime, SnapshotType)
            integrationServices = @(Get-VMIntegrationService -VMName $vm.Name | Select-Object Name, Enabled, PrimaryStatusDescription)
        }
    }
} catch {
    $result.ok = $false
    $result.error = $_.Exception.Message
}

$json = $result | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $parent = Split-Path -Parent $OutputPath
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($OutputPath, $json, [System.Text.UTF8Encoding]::new($false))
} else {
    $json
}
