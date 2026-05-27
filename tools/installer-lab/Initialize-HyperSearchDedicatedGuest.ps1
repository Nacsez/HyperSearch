[CmdletBinding()]
param(
    [string]$VMName = "HyperSearchLab-WinDev",
    [string]$CredentialPath = "C:\tmp\hypersearch-lab-credential.xml",
    [string]$BootstrapUser = "User",
    [AllowEmptyString()]
    [string]$BootstrapPassword = "",
    [string]$ReadyCheckpointName = "clean-windows-ready",
    [int]$TimeoutSeconds = 1800,
    [switch]$ReplaceReadyCheckpoint,
    [switch]$KeepRunning
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Dedicated guest initialization must be run from an elevated PowerShell session."
    }
}

function New-PlainCredential {
    param([string]$UserName, [AllowEmptyString()][string]$Password)
    if ($Password.Length -eq 0) {
        $secure = [Security.SecureString]::new()
    } else {
        $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    }
    return [Management.Automation.PSCredential]::new($UserName, $secure)
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
            return [pscustomobject]@{ session = $session; probe = $probe }
        } catch {
            Start-Sleep -Seconds 10
        }
    } while ((Get-Date) -lt $deadline)
    throw "PowerShell Direct did not become available for $Name with user '$($Credential.UserName)' within $Timeout seconds."
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

$vm = Get-VM -Name $VMName -ErrorAction Stop
if ($vm.State -ne "Running") {
    Start-VM -Name $VMName | Out-Null
}

$bootstrapCredential = New-PlainCredential -UserName $BootstrapUser -Password $BootstrapPassword
$bootstrap = Wait-GuestSession -Name $VMName -Credential $bootstrapCredential -Timeout $TimeoutSeconds
try {
    Invoke-Command -Session $bootstrap.session -ArgumentList @($targetUser, $targetCredential.Password) -ScriptBlock {
        param($UserName, [securestring]$Password)
        $existing = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
        if ($existing) {
            Set-LocalUser -Name $UserName -Password $Password
            Enable-LocalUser -Name $UserName
        } else {
            New-LocalUser -Name $UserName -Password $Password -FullName "HyperSearch Installer Lab" -Description "HyperSearch lab admin" | Out-Null
        }
        $memberNames = @(Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        if ($memberNames -notcontains $UserName -and $memberNames -notcontains ".\$UserName" -and -not ($memberNames | Where-Object { $_ -match "\\$([regex]::Escape($UserName))$" })) {
            Add-LocalGroupMember -Group "Administrators" -Member $UserName
        }
        [pscustomobject]@{
            user = $UserName
            isAdmin = $true
        }
    } | Out-Null
} finally {
    Remove-PSSession $bootstrap.session -ErrorAction SilentlyContinue
}

$verify = Wait-GuestSession -Name $VMName -Credential $targetCredential -Timeout 300
try {
    $probe = $verify.probe
} finally {
    Remove-PSSession $verify.session -ErrorAction SilentlyContinue
}

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
