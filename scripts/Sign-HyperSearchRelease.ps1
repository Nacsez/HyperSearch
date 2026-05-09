[CmdletBinding()]
param(
    [ValidateSet("Verify", "SelfSigned", "CertStore")]
    [string]$Mode = "Verify",
    [string]$Version = "1.0.0",
    [string]$PublisherName = "Robert Choudury",
    [string]$AppName = "HyperSearch",
    [string[]]$ArtifactPath = @(),
    [string]$CertificateThumbprint = "",
    [string]$TimestampUrl = "http://timestamp.digicert.com",
    [switch]$SkipTimestamp,
    [switch]$CreateSelfSignedCertificate,
    [switch]$TrustSelfSignedCertificateForCurrentUser,
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Resolve-SignTool {
    $command = Get-Command "signtool.exe" -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $kitRoot = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin"
    if (Test-Path $kitRoot) {
        $candidate = Get-ChildItem -Path $kitRoot -Recurse -Filter "signtool.exe" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\x64\\signtool\.exe$" } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($candidate) {
            return $candidate.FullName
        }
    }

    return ""
}

function Get-DefaultArtifacts {
    param([Parameter(Mandatory = $true)][string]$ReleaseVersion)

    $releaseRoot = Join-Path $repoRoot "apps\desktop\src-tauri\target\release"
    $paths = [System.Collections.Generic.List[string]]::new()

    foreach ($relative in @(
        "hypersearch-desktop.exe",
        "bundle\nsis\HyperSearch_${ReleaseVersion}_x64-setup.exe",
        "bundle\msi\HyperSearch_${ReleaseVersion}_x64_en-US.msi"
    )) {
        $path = Join-Path $releaseRoot $relative
        if (Test-Path $path) {
            $paths.Add((Resolve-Path $path).Path) | Out-Null
        }
    }

    foreach ($glob in @(
        "bundle\nsis\HyperSearch_*_x64-setup.exe",
        "bundle\msi\HyperSearch_*_x64_en-US.msi"
    )) {
        $parent = Split-Path -Parent (Join-Path $releaseRoot $glob)
        $filter = Split-Path -Leaf $glob
        if (Test-Path $parent) {
            Get-ChildItem -Path $parent -Filter $filter -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1 |
                ForEach-Object { $paths.Add($_.FullName) | Out-Null }
        }
    }

    return @($paths | Select-Object -Unique)
}

function Find-CertificateByThumbprint {
    param([Parameter(Mandatory = $true)][string]$Thumbprint)

    $clean = ($Thumbprint -replace "\s", "").ToUpperInvariant()
    foreach ($store in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")) {
        $cert = Get-ChildItem -Path $store -ErrorAction SilentlyContinue |
            Where-Object { ($_.Thumbprint -replace "\s", "").ToUpperInvariant() -eq $clean } |
            Select-Object -First 1
        if ($cert) {
            return [pscustomobject]@{
                Certificate = $cert
                StorePath = $store
                UseMachineStore = $store -like "Cert:\LocalMachine*"
            }
        }
    }
    return $null
}

function Find-SelfSignedCertificate {
    param([Parameter(Mandatory = $true)][string]$Subject)

    $now = Get-Date
    $cert = Get-ChildItem -Path "Cert:\CurrentUser\My" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Subject -eq $Subject -and
            $_.HasPrivateKey -and
            $_.NotAfter -gt $now
        } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
    if ($cert) {
        return [pscustomobject]@{
            Certificate = $cert
            StorePath = "Cert:\CurrentUser\My"
            UseMachineStore = $false
        }
    }
    return $null
}

function New-LocalSelfSignedCertificate {
    param([Parameter(Mandatory = $true)][string]$Subject)

    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $Subject `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -HashAlgorithm SHA256 `
        -KeyUsage DigitalSignature `
        -NotAfter (Get-Date).AddYears(2)

    return [pscustomobject]@{
        Certificate = $cert
        StorePath = "Cert:\CurrentUser\My"
        UseMachineStore = $false
    }
}

function Add-CertificateTrustForCurrentUser {
    param([Parameter(Mandatory = $true)]$Certificate)

    $tempPath = Join-Path $env:TEMP ("hypersearch-signing-{0}.cer" -f ([guid]::NewGuid().ToString("N")))
    try {
        Export-Certificate -Cert $Certificate -FilePath $tempPath | Out-Null
        Import-Certificate -FilePath $tempPath -CertStoreLocation "Cert:\CurrentUser\Root" | Out-Null
        Import-Certificate -FilePath $tempPath -CertStoreLocation "Cert:\CurrentUser\TrustedPublisher" | Out-Null
    } finally {
        if (Test-Path $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force
        }
    }
}

function Invoke-SignArtifact {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$CertificateInfo,
        [Parameter(Mandatory = $true)][string]$ToolPath
    )

    if ($ToolPath) {
        $args = @("sign")
        if ($CertificateInfo.UseMachineStore) {
            $args += "/sm"
        }
        $args += @("/sha1", $CertificateInfo.Certificate.Thumbprint, "/fd", "SHA256", "/d", $AppName)
        if (-not $SkipTimestamp) {
            $args += @("/tr", $TimestampUrl, "/td", "SHA256")
        }
        $args += $Path
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & $ToolPath @args 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($exitCode -ne 0) {
            throw "signtool sign failed for $Path with exit code $exitCode.`n$($output -join [Environment]::NewLine)"
        }
        return ($output -join [Environment]::NewLine)
    }

    $signatureArgs = @{
        FilePath = $Path
        Certificate = $CertificateInfo.Certificate
        HashAlgorithm = "SHA256"
    }
    if (-not $SkipTimestamp) {
        $signatureArgs["TimestampServer"] = $TimestampUrl
    }
    $signature = Set-AuthenticodeSignature @signatureArgs
    if ($signature.Status -eq "NotSigned") {
        throw "Set-AuthenticodeSignature did not sign $Path."
    }
    return "Signed with Set-AuthenticodeSignature. Status=$($signature.Status)"
}

function Get-SignatureRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ToolPath
    )

    $signature = Get-AuthenticodeSignature -FilePath $Path
    $hash = Get-FileHash -Algorithm SHA256 -Path $Path
    $signtoolExitCode = $null
    $signtoolOutput = ""

    if ($ToolPath) {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $verifyOutput = & $ToolPath @("verify", "/pa", "/all", "/v", $Path) 2>&1
            $signtoolExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        $signtoolOutput = ($verifyOutput -join [Environment]::NewLine)
    }

    return [ordered]@{
        path = $Path
        sha256 = $hash.Hash
        authenticode_status = [string]$signature.Status
        authenticode_status_message = [string]$signature.StatusMessage
        signer_subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { "" }
        signer_thumbprint = if ($signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint } else { "" }
        timestamp_subject = if ($signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Subject } else { "" }
        signtool_verify_exit_code = $signtoolExitCode
        signtool_verify_output = $signtoolOutput
    }
}

$artifacts = @()
if ($ArtifactPath.Count -gt 0) {
    foreach ($path in $ArtifactPath) {
        if (-not (Test-Path $path)) {
            throw "Artifact was not found: $path"
        }
        $artifacts += (Resolve-Path $path).Path
    }
} else {
    $artifacts = Get-DefaultArtifacts -ReleaseVersion $Version
}

if ($artifacts.Count -eq 0) {
    throw "No release artifacts were found. Build the desktop release first or pass -ArtifactPath."
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $repoRoot "artifacts\signing\signing-summary.json"
}
$outputParent = Split-Path -Parent $OutputPath
if ($outputParent) {
    New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
}

$signTool = Resolve-SignTool
$certificateInfo = $null
$subject = "CN=$PublisherName"
$warnings = [System.Collections.Generic.List[string]]::new()

if ($Mode -eq "CertStore") {
    if (-not $CertificateThumbprint) {
        throw "-CertificateThumbprint is required when -Mode CertStore is used."
    }
    $certificateInfo = Find-CertificateByThumbprint -Thumbprint $CertificateThumbprint
    if (-not $certificateInfo) {
        throw "Certificate thumbprint was not found in CurrentUser\My or LocalMachine\My: $CertificateThumbprint"
    }
}

if ($Mode -eq "SelfSigned") {
    if ($CertificateThumbprint) {
        $certificateInfo = Find-CertificateByThumbprint -Thumbprint $CertificateThumbprint
        if (-not $certificateInfo) {
            throw "Self-signed certificate thumbprint was not found: $CertificateThumbprint"
        }
    } else {
        $certificateInfo = Find-SelfSignedCertificate -Subject $subject
        if (-not $certificateInfo -or $CreateSelfSignedCertificate) {
            $certificateInfo = New-LocalSelfSignedCertificate -Subject $subject
        }
    }

    $warnings.Add("Self-signed Authenticode signatures are for local testing and integrity verification only. They do not create public Windows trust and do not prevent SmartScreen warnings for normal users.") | Out-Null

    if ($TrustSelfSignedCertificateForCurrentUser) {
        Add-CertificateTrustForCurrentUser -Certificate $certificateInfo.Certificate
        $warnings.Add("The self-signed certificate was trusted for the current Windows user only. Do not ask public users to install this certificate.") | Out-Null
    }
}

if ($Mode -ne "Verify") {
    foreach ($artifact in $artifacts) {
        Write-Host "Signing $artifact" -ForegroundColor Cyan
        Invoke-SignArtifact -Path $artifact -CertificateInfo $certificateInfo -ToolPath $signTool | Out-Host
    }
}

$records = @()
foreach ($artifact in $artifacts) {
    $records += Get-SignatureRecord -Path $artifact -ToolPath $signTool
}

$summary = [ordered]@{
    product = $AppName
    publisher = $PublisherName
    mode = $Mode
    created_at = (Get-Date).ToUniversalTime().ToString("o")
    signtool = $signTool
    timestamp_url = if ($SkipTimestamp) { "" } else { $TimestampUrl }
    certificate_subject = if ($certificateInfo) { $certificateInfo.Certificate.Subject } else { "" }
    certificate_thumbprint = if ($certificateInfo) { $certificateInfo.Certificate.Thumbprint } else { "" }
    certificate_store = if ($certificateInfo) { $certificateInfo.StorePath } else { "" }
    warnings = @($warnings)
    artifacts = $records
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $OutputPath
Write-Host "Wrote signing summary: $OutputPath" -ForegroundColor Green

if ($Mode -eq "Verify") {
    $unsigned = @($records | Where-Object { $_.authenticode_status -eq "NotSigned" })
    if ($unsigned.Count -gt 0) {
        Write-Warning "One or more artifacts are unsigned. This is expected for the no-cost unsigned release path, but not for a trusted-signed public release."
    }
}
