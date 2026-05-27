[CmdletBinding()]
param(
    [string]$OutputPath = "C:\tmp\hypersearch-lab-credential.xml",
    [string]$Message = "Enter the local administrator credential for the HyperSearch installer lab guest VM."
)

$ErrorActionPreference = "Stop"

$credential = Get-Credential -Message $Message
if ($null -eq $credential) {
    throw "No credential was provided."
}

$parent = Split-Path -Parent $OutputPath
if ($parent) {
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
}

$credential | Export-Clixml -Path $OutputPath
Write-Host "Wrote guest credential to $OutputPath"
Write-Host "This file is encrypted for the current Windows user via DPAPI and should not be committed."
