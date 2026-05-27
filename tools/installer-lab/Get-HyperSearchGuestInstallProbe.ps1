[CmdletBinding()]
param(
    [string]$VMName = "HyperSearchLab-WinDev",
    [string]$CredentialPath = "C:\tmp\hypersearch-lab-credential.xml",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Guest install probe must be run from an elevated PowerShell session."
    }
}

Assert-Admin
Import-Module Hyper-V -ErrorAction Stop

if (!(Test-Path $CredentialPath)) {
    throw "Guest credential file was not found: $CredentialPath"
}
$credential = Import-Clixml -LiteralPath $CredentialPath
if ($credential -isnot [Management.Automation.PSCredential]) {
    throw "Guest credential file did not contain a PSCredential: $CredentialPath"
}

if ((Get-VM -Name $VMName).State -ne "Running") {
    Start-VM -Name $VMName | Out-Null
    Start-Sleep -Seconds 20
}

$result = Invoke-Command -VMName $VMName -Credential $credential -ScriptBlock {
    $paths = @(
        "C:\Program Files\HyperSearch",
        (Join-Path $env:LOCALAPPDATA "HyperSearch"),
        "C:\HyperSearchInstallerLab"
    )
    [ordered]@{
        computerName = $env:COMPUTERNAME
        user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        paths = @($paths | ForEach-Object {
            [ordered]@{
                path = $_
                exists = Test-Path $_
                files = if (Test-Path $_) {
                    @(Get-ChildItem -Path $_ -Recurse -File -ErrorAction SilentlyContinue |
                        Select-Object -First 80 FullName, Length, LastWriteTime)
                } else {
                    @()
                }
            }
        })
        uninstallKeys = @(Get-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*HyperSearch*" } |
            Select-Object DisplayName, DisplayVersion, InstallLocation, UninstallString)
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
