[CmdletBinding()]
param(
    [string]$VMName = "HyperSearchLab-WinDev",
    [string]$CredentialPath = "C:\tmp\hypersearch-lab-credential.xml",
    [string]$ReadyCheckpointName = "clean-windows-ready",
    [int]$TimeoutSeconds = 900,
    [switch]$ReplaceReadyCheckpoint,
    [switch]$KeepRunning
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Offline guest bootstrap must be run from an elevated PowerShell session."
    }
}

function Get-LocalUserName {
    param([string]$Name)
    if ($Name -match "\\") {
        return ($Name -split "\\")[-1]
    }
    if ($Name -match "@") {
        return ($Name -split "@")[0]
    }
    return $Name
}

function Wait-GuestSession {
    param(
        [string]$Name,
        [Management.Automation.PSCredential]$Credential,
        [int]$Timeout
    )
    $deadline = (Get-Date).AddSeconds($Timeout)
    do {
        try {
            $session = New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop
            $probe = Invoke-Command -Session $session -ScriptBlock {
                [pscustomobject]@{
                    computerName = $env:COMPUTERNAME
                    user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                    psVersion = $PSVersionTable.PSVersion.ToString()
                }
            }
            Remove-PSSession $session -ErrorAction SilentlyContinue
            return $probe
        } catch {
            Start-Sleep -Seconds 10
        }
    } while ((Get-Date) -lt $deadline)
    throw "PowerShell Direct did not become available for $Name with user '$($Credential.UserName)' within $Timeout seconds."
}

function Find-WindowsRoot {
    param([int]$DiskNumber)
    $partitions = @(Get-Partition -DiskNumber $DiskNumber | Where-Object { $_.Type -eq "Basic" -or $_.GptType -eq "{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}" })
    foreach ($partition in $partitions) {
        if (-not $partition.DriveLetter) {
            try {
                $partition | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction Stop | Out-Null
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
    throw "Mounted VHD did not expose a Windows partition."
}

function New-BootstrapScript {
    param(
        [string]$UserName,
        [string]$Password
    )
    $encodedPassword = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Password))
    return @"
`$ErrorActionPreference = "Stop"
`$logRoot = "C:\ProgramData\HyperSearchLab"
New-Item -ItemType Directory -Force -Path `$logRoot | Out-Null
Start-Transcript -Path (Join-Path `$logRoot "offline-bootstrap.log") -Append
`$completed = `$false
try {
    `$userName = "$UserName"
    `$password = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String("$encodedPassword"))
    `$secure = ConvertTo-SecureString `$password -AsPlainText -Force
    `$existing = Get-LocalUser -Name `$userName -ErrorAction SilentlyContinue
    if (`$existing) {
        Set-LocalUser -Name `$userName -Password `$secure
        Enable-LocalUser -Name `$userName
    } else {
        New-LocalUser -Name `$userName -Password `$secure -FullName "HyperSearch Installer Lab" -Description "HyperSearch lab admin" | Out-Null
    }
    `$memberNames = @(Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | ForEach-Object { `$_.Name })
    if (`$memberNames -notcontains `$userName -and `$memberNames -notcontains ".\`$userName" -and -not (`$memberNames | Where-Object { `$_ -match "\\`$([regex]::Escape(`$userName))`$" })) {
        Add-LocalGroupMember -Group "Administrators" -Member `$userName
    }
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\HyperSearchLabBootstrap" -Name Start -Value 4 -ErrorAction SilentlyContinue
    sc.exe delete HyperSearchLabBootstrap | Out-Null
    "ready $(Get-Date -Format o)" | Set-Content -Path (Join-Path `$logRoot "offline-bootstrap.ready") -Encoding ASCII
    `$completed = `$true
} finally {
    Stop-Transcript
    if (`$completed -and `$PSCommandPath) {
        Remove-Item -LiteralPath `$PSCommandPath -Force -ErrorAction SilentlyContinue
    }
}
"@
}

function New-BootstrapServiceExe {
    param([string]$OutputPath)
    if (Test-Path $OutputPath) { return }
    $sourcePath = [IO.Path]::ChangeExtension($OutputPath, ".cs")
    $source = @"
using System;
using System.Diagnostics;
using System.IO;
using System.ServiceProcess;
using System.Threading;

public sealed class HyperSearchLabBootstrapService : ServiceBase
{
    public HyperSearchLabBootstrapService()
    {
        ServiceName = "HyperSearchLabBootstrap";
        CanStop = true;
    }

    public static void Main()
    {
        ServiceBase.Run(new HyperSearchLabBootstrapService());
    }

    protected override void OnStart(string[] args)
    {
        ThreadPool.QueueUserWorkItem(_ => RunBootstrap());
    }

    private void RunBootstrap()
    {
        string logRoot = @"C:\ProgramData\HyperSearchLab";
        Directory.CreateDirectory(logRoot);
        try
        {
            var psi = new ProcessStartInfo(
                @"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"C:\\ProgramData\\HyperSearchLab\\OfflineBootstrap-LabAccount.ps1\"")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            using (var process = Process.Start(psi))
            {
                if (process != null)
                {
                    string stdout = process.StandardOutput.ReadToEnd();
                    string stderr = process.StandardError.ReadToEnd();
                    process.WaitForExit(300000);
                    File.AppendAllText(Path.Combine(logRoot, "bootstrap-service.log"), stdout + Environment.NewLine + stderr);
                }
            }
        }
        catch (Exception ex)
        {
            File.AppendAllText(Path.Combine(logRoot, "bootstrap-service.log"), ex.ToString());
        }
        finally
        {
            try { Stop(); } catch {}
        }
    }
}
"@
    [IO.File]::WriteAllText($sourcePath, $source, [Text.UTF8Encoding]::new($false))
    $cscCandidates = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )
    $csc = $cscCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $csc) {
        throw "Could not find .NET Framework csc.exe to build bootstrap service wrapper."
    }
    & $csc /nologo /target:exe /out:$OutputPath /reference:System.ServiceProcess.dll $sourcePath
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $OutputPath)) {
        throw "Failed to compile bootstrap service wrapper."
    }
}

Assert-Admin
Import-Module Hyper-V -ErrorAction Stop

if (!(Test-Path $CredentialPath)) {
    throw "Guest credential file was not found: $CredentialPath"
}
$targetCredential = Import-Clixml -LiteralPath $CredentialPath
if ($targetCredential -isnot [Management.Automation.PSCredential]) {
    throw "Guest credential file did not contain a PSCredential: $CredentialPath"
}
$targetUser = Get-LocalUserName -Name $targetCredential.UserName
$targetPassword = $targetCredential.GetNetworkCredential().Password
if ([string]::IsNullOrWhiteSpace($targetUser) -or [string]::IsNullOrEmpty($targetPassword)) {
    throw "Guest credential must contain a non-empty username and password."
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -ne "Off") {
    Stop-VM -Name $VMName -TurnOff -Force
}
$vhd = Get-VMHardDiskDrive -VMName $VMName | Select-Object -First 1
if (-not $vhd -or !(Test-Path $vhd.Path)) {
    throw "Could not find VM VHD path for $VMName."
}

$mounted = $null
$systemHiveLoaded = $false
try {
    $hostServiceExe = Join-Path $env:TEMP "HyperSearchLabBootstrapService.exe"
    New-BootstrapServiceExe -OutputPath $hostServiceExe

    $mounted = Mount-VHD -Path $vhd.Path -PassThru
    $disk = $mounted | Get-Disk
    $windowsRoot = Find-WindowsRoot -DiskNumber $disk.Number
    $guestScriptDir = Join-Path $windowsRoot "ProgramData\HyperSearchLab"
    New-Item -ItemType Directory -Force -Path $guestScriptDir | Out-Null
    $guestScriptPath = Join-Path $guestScriptDir "OfflineBootstrap-LabAccount.ps1"
    [IO.File]::WriteAllText($guestScriptPath, (New-BootstrapScript -UserName $targetUser -Password $targetPassword), [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath $hostServiceExe -Destination (Join-Path $guestScriptDir "HyperSearchLabBootstrapService.exe") -Force

    $systemHive = Join-Path $windowsRoot "Windows\System32\Config\SYSTEM"
    & reg.exe load HKLM\HyperSearchOfflineSystem $systemHive | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to load offline SYSTEM hive from $systemHive."
    }
    $systemHiveLoaded = $true
    $select = Get-ItemProperty -Path "HKLM:\HyperSearchOfflineSystem\Select"
    $controlSet = "ControlSet{0:D3}" -f ([int]$select.Current)
    $servicePath = "HKLM:\HyperSearchOfflineSystem\$controlSet\Services\HyperSearchLabBootstrap"
    New-Item -Path $servicePath -Force | Out-Null
    New-ItemProperty -Path $servicePath -Name Type -PropertyType DWord -Value 16 -Force | Out-Null
    New-ItemProperty -Path $servicePath -Name Start -PropertyType DWord -Value 2 -Force | Out-Null
    New-ItemProperty -Path $servicePath -Name ErrorControl -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $servicePath -Name DisplayName -PropertyType String -Value "HyperSearch Lab Bootstrap" -Force | Out-Null
    New-ItemProperty -Path $servicePath -Name ObjectName -PropertyType String -Value "LocalSystem" -Force | Out-Null
    $imagePath = 'C:\ProgramData\HyperSearchLab\HyperSearchLabBootstrapService.exe'
    New-ItemProperty -Path $servicePath -Name ImagePath -PropertyType ExpandString -Value $imagePath -Force | Out-Null
} finally {
    if ($systemHiveLoaded) {
        [gc]::Collect()
        Start-Sleep -Milliseconds 500
        & reg.exe unload HKLM\HyperSearchOfflineSystem | Out-Null
    }
    if ($mounted) {
        Dismount-VHD -Path $vhd.Path
    }
}

Start-VM -Name $VMName | Out-Null
$probe = Wait-GuestSession -Name $VMName -Credential $targetCredential -Timeout $TimeoutSeconds

if (-not $KeepRunning) {
    Stop-VM -Name $VMName -TurnOff -Force
}

$existingCheckpoint = Get-VMSnapshot -VMName $VMName -Name $ReadyCheckpointName -ErrorAction SilentlyContinue
if ($existingCheckpoint -and $ReplaceReadyCheckpoint) {
    Remove-VMSnapshot -VMName $VMName -Name $ReadyCheckpointName -Confirm:$false
    $existingCheckpoint = $null
}
if (-not $existingCheckpoint) {
    Checkpoint-VM -Name $VMName -SnapshotName $ReadyCheckpointName | Out-Null
}

[pscustomobject]@{
    vmName = $VMName
    readyCheckpoint = $ReadyCheckpointName
    verifiedUser = $probe.User
    guestComputerName = $probe.ComputerName
    psVersion = $probe.PSVersion
} | ConvertTo-Json -Depth 4
