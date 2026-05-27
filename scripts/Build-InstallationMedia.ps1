[CmdletBinding()]
param(
    [string]$RunName = ("TestRun_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")),
    [ValidateSet("Online", "Full", "Both")]
    [string]$Channel = "Full",
    [string]$Version = "1.1.0",
    [ValidateSet("GHCR", "DockerHub", "Both")]
    [string]$RegistryMode = "GHCR",
    [string]$GhcrNamespace = "ghcr.io/nacsez",
    [string]$DockerHubNamespace = "docker.io/nacsez",
    [string]$ImageArchivePath = "",
    [string]$DockerDesktopInstallerPath = "",
    [string]$WslInstallerPath = "",
    [string]$LmStudioInstallerPath = "",
    [switch]$BuildImages,
    [switch]$PushImages,
    [switch]$SkipTauriBuild,
    [switch]$SkipLicenseNoticeUpdate,
    [ValidateSet("None", "Verify", "SelfSigned", "CertStore")]
    [string]$SigningMode = "None",
    [string]$SigningCertificateThumbprint = "",
    [switch]$CreateSelfSignedSigningCertificate,
    [switch]$TrustSelfSignedSigningCertificateForCurrentUser,
    [switch]$SkipSigningTimestamp
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$desktopRoot = Join-Path $repoRoot "apps\desktop"
$mediaRoot = Join-Path $repoRoot "Installation Media"
$runRoot = Join-Path $mediaRoot $RunName
$onlineRoot = Join-Path $runRoot "Online"
$fullRoot = Join-Path $runRoot "Full"

New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

if (-not $SkipLicenseNoticeUpdate) {
    try {
        & (Join-Path $PSScriptRoot "Update-LicenseNotices.ps1")
    } catch {
        throw "License notice update failed: $($_.Exception.Message)"
    }
}

if ($BuildImages) {
    $imageDir = Join-Path $runRoot "image-build"
    New-Item -ItemType Directory -Force -Path $imageDir | Out-Null
    $ImageArchivePath = Join-Path $imageDir "hypersearch-images-$Version.tar"
    try {
        & (Join-Path $PSScriptRoot "Build-ContainerImages.ps1") `
            -Version $Version `
            -RegistryMode $RegistryMode `
            -GhcrNamespace $GhcrNamespace `
            -DockerHubNamespace $DockerHubNamespace `
            -SaveArchive `
            -ArchivePath $ImageArchivePath `
            -Push:$PushImages
    } catch {
        throw "Container image build failed: $($_.Exception.Message)"
    }
}

if (-not $SkipTauriBuild) {
    Push-Location $desktopRoot
    try {
        npm.cmd run tauri -- build
        if ($LASTEXITCODE -ne 0) {
            throw "Tauri build failed with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

$imageDigestManifestPath = ""
if ($ImageArchivePath -and (Test-Path "$ImageArchivePath.manifest.json")) {
    $imageDigestManifestPath = "$ImageArchivePath.manifest.json"
}
$signingSummaryPath = ""

$releaseRoot = Join-Path $desktopRoot "src-tauri\target\release"
$nsis = Join-Path $releaseRoot "bundle\nsis\HyperSearch_${Version}_x64-setup.exe"
$msi = Join-Path $releaseRoot "bundle\msi\HyperSearch_${Version}_x64_en-US.msi"
$exe = Join-Path $releaseRoot "hypersearch-desktop.exe"

if (!(Test-Path $nsis)) {
    $nsis = Get-ChildItem -Path (Join-Path $releaseRoot "bundle\nsis") -Filter "HyperSearch_*_x64-setup.exe" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (!(Test-Path $msi)) {
    $msi = Get-ChildItem -Path (Join-Path $releaseRoot "bundle\msi") -Filter "HyperSearch_*_x64_en-US.msi" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}

foreach ($artifact in @($nsis, $msi, $exe)) {
    if (!(Test-Path $artifact)) {
        throw "Expected build artifact was not created: $artifact"
    }
}

if ($SigningMode -ne "None") {
    $signingSummaryPath = Join-Path $runRoot "signing-summary.json"
    $signArgs = @{
        Mode = $SigningMode
        Version = $Version
        PublisherName = "Robert Choudury"
        AppName = "HyperSearch"
        OutputPath = $signingSummaryPath
    }
    if ($SigningCertificateThumbprint) {
        $signArgs.CertificateThumbprint = $SigningCertificateThumbprint
    }
    if ($CreateSelfSignedSigningCertificate) {
        $signArgs.CreateSelfSignedCertificate = $true
    }
    if ($TrustSelfSignedSigningCertificateForCurrentUser) {
        $signArgs.TrustSelfSignedCertificateForCurrentUser = $true
    }
    if ($SkipSigningTimestamp) {
        $signArgs.SkipTimestamp = $true
    }
    try {
        & (Join-Path $PSScriptRoot "Sign-HyperSearchRelease.ps1") @signArgs
    } catch {
        throw "Release signing step failed: $($_.Exception.Message)"
    }
}

function Copy-BaseArtifacts {
    param(
        [Parameter(Mandatory=$true)][string]$Destination,
        [Parameter(Mandatory=$true)][string]$MediaChannel
    )
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -LiteralPath $nsis -Destination (Join-Path $Destination "HyperSearch_${Version}_x64-setup.exe") -Force
    Copy-Item -LiteralPath $msi -Destination (Join-Path $Destination "HyperSearch_${Version}_x64_en-US.msi") -Force
    Copy-Item -LiteralPath $exe -Destination (Join-Path $Destination "hypersearch-desktop.exe") -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "docs\windows_installer_test_plan.md") -Destination (Join-Path $Destination "windows_installer_test_plan.md") -Force
    foreach ($docName in @("installer_1_1_postmortem.md", "windows_installation_wizard_1_1_design.md")) {
        $docPath = Join-Path $repoRoot "docs\$docName"
        if (Test-Path $docPath) {
            Copy-Item -LiteralPath $docPath -Destination (Join-Path $Destination $docName) -Force
        }
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot "LICENSE.md") -Destination (Join-Path $Destination "LICENSE.md") -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "COPYING") -Destination (Join-Path $Destination "COPYING") -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "THIRD_PARTY_NOTICES.md") -Destination (Join-Path $Destination "THIRD_PARTY_NOTICES.md") -Force
    Copy-Item -LiteralPath (Join-Path $repoRoot "SOURCE_OFFER.md") -Destination (Join-Path $Destination "SOURCE_OFFER.md") -Force
    if ($signingSummaryPath -and (Test-Path $signingSummaryPath)) {
        Copy-Item -LiteralPath $signingSummaryPath -Destination (Join-Path $Destination "signing-summary.json") -Force
    }
    $digestManifestMediaPath = ""
    if ($imageDigestManifestPath -and (Test-Path $imageDigestManifestPath)) {
        $digestManifestLeaf = Split-Path -Leaf $imageDigestManifestPath
        if ($MediaChannel -eq "Full") {
            $digestManifestMediaPath = "payload\\images\\$digestManifestLeaf"
        } else {
            Copy-Item -LiteralPath $imageDigestManifestPath -Destination (Join-Path $Destination $digestManifestLeaf) -Force
            $digestManifestMediaPath = $digestManifestLeaf
        }
    }
    $manifest = [ordered]@{
        product = "HyperSearch"
        version = $Version
        channel = $MediaChannel
        runName = $RunName
        createdAt = (Get-Date).ToString("o")
        installer = "HyperSearch_${Version}_x64-setup.exe"
        msi = "HyperSearch_${Version}_x64_en-US.msi"
        directExe = "hypersearch-desktop.exe"
        installationWizard = "HyperSearch Installation Wizard"
        standardInstallChannel = "Full"
        customInstallImageSources = @("bundled", "online", "skip")
        runtimePath = "%LOCALAPPDATA%\HyperSearch\runtime"
        installerLogPath = "%LOCALAPPDATA%\HyperSearch\logs\installer-*.log"
        installerTranscriptPath = "%LOCALAPPDATA%\HyperSearch\logs\installer-transcript-*.log"
        setupSummaryPath = "%LOCALAPPDATA%\HyperSearch\logs\setup-summary-*.json"
        desktopLogPath = "%LOCALAPPDATA%\HyperSearch\logs\desktop.log"
        commandLogPath = "%LOCALAPPDATA%\HyperSearch\logs\commands"
        diagnosticsPath = "%LOCALAPPDATA%\HyperSearch\diagnostics"
        imagePrimaryRegistry = $GhcrNamespace
        imageFallbackRegistry = if ($RegistryMode -in @("DockerHub", "Both")) { $DockerHubNamespace } else { "" }
        registryMode = $RegistryMode
        imageDigestManifest = $digestManifestMediaPath
        license = "LICENSE.md"
        licenseText = "COPYING"
        thirdPartyNotices = "THIRD_PARTY_NOTICES.md"
        sourceOffer = "SOURCE_OFFER.md"
        setupProfilePath = "%LOCALAPPDATA%\HyperSearch\install-profile.json"
        modelCatalog = [ordered]@{
            lowResource = "google/gemma-3-1B-it-QAT"
            standard = "qwen2.5-7b-1m"
            highResource = "openai/gpt-oss-20b"
        }
        signingMode = $SigningMode
        signingSummary = if ($signingSummaryPath) { "signing-summary.json" } else { "" }
        notes = @(
            "Full media is the default public 1.1 installer channel.",
            "Standard install uses bundled Docker images and does not require Docker Hub sign-in for HyperSearch startup.",
            "Custom install can choose bundled, online, or skipped Docker image setup.",
            "Release license, third-party notice, and source-offer files are included at the media root.",
            "The Installation Wizard records explicit component-license consent before passing third-party installer agreement flags.",
            "Signing metadata is included when the media build is run with a signing mode.",
            "The NSIS setup runs the HyperSearch Installation Wizard and passes the installer media folder to it.",
            "Docker Desktop installation or repair may require Windows administrator approval.",
            "Docker Desktop, WSL, and LM Studio downloads require internet access unless their installers are supplied in payload\\prereqs.",
            "Setup checks WSL status and prefers the bundled WSL MSI when present before falling back to wsl --install or wsl --update.",
            "LM Studio model download is optional and may be marked pending when non-interactive CLI download is unavailable.",
            "The installer writes install-profile.json so the desktop app can import first-run provider, model, and usage settings.",
            "The desktop launcher writes full command logs under %LOCALAPPDATA%\\HyperSearch\\logs\\commands."
        )
    }
    ($manifest | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $Destination "manifest.json") -Encoding UTF8
}

function Copy-FullPayload {
    param([Parameter(Mandatory=$true)][string]$Destination)
    $payloadRoot = Join-Path $Destination "payload"
    $imagePayload = Join-Path $payloadRoot "images"
    $prereqPayload = Join-Path $payloadRoot "prereqs"
    New-Item -ItemType Directory -Force -Path $imagePayload | Out-Null
    New-Item -ItemType Directory -Force -Path $prereqPayload | Out-Null
    if ($ImageArchivePath) {
        if (!(Test-Path $ImageArchivePath)) {
            throw "Image archive was requested for full media but was not found: $ImageArchivePath"
        }
        Copy-Item -LiteralPath $ImageArchivePath -Destination (Join-Path $imagePayload (Split-Path -Leaf $ImageArchivePath)) -Force
        if ($imageDigestManifestPath) {
            Copy-Item -LiteralPath $imageDigestManifestPath -Destination (Join-Path $imagePayload (Split-Path -Leaf $imageDigestManifestPath)) -Force
        }
    }
    if ($DockerDesktopInstallerPath) {
        if (!(Test-Path $DockerDesktopInstallerPath)) {
            throw "Docker Desktop installer path was not found: $DockerDesktopInstallerPath"
        }
        Copy-Item -LiteralPath $DockerDesktopInstallerPath -Destination (Join-Path $prereqPayload "Docker Desktop Installer.exe") -Force
    }
    if ($WslInstallerPath) {
        if (!(Test-Path $WslInstallerPath)) {
            throw "WSL installer path was not found: $WslInstallerPath"
        }
        Copy-Item -LiteralPath $WslInstallerPath -Destination (Join-Path $prereqPayload "WSL.msi") -Force
    }
    if ($LmStudioInstallerPath) {
        if (!(Test-Path $LmStudioInstallerPath)) {
            throw "LM Studio installer path was not found: $LmStudioInstallerPath"
        }
        Copy-Item -LiteralPath $LmStudioInstallerPath -Destination (Join-Path $prereqPayload "LM Studio.exe") -Force
    }
}

function Write-Checksums {
    param([Parameter(Mandatory=$true)][string]$Root)
    $checksumPath = Join-Path $Root "checksums.sha256"
    $lines = Get-ChildItem -Path $Root -Recurse -File |
        Where-Object { $_.FullName -ne $checksumPath } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($Root.Length).TrimStart("\", "/")
            $hash = Get-FileHash -Algorithm SHA256 -Path $_.FullName
            "$($hash.Hash.ToLowerInvariant())  $relative"
        }
    Set-Content -Path $checksumPath -Encoding UTF8 -Value $lines
}

if ($Channel -in @("Online", "Both")) {
    Copy-BaseArtifacts -Destination $onlineRoot -MediaChannel "Online"
    Write-Checksums -Root $onlineRoot
}

if ($Channel -in @("Full", "Both")) {
    Copy-BaseArtifacts -Destination $fullRoot -MediaChannel "Full"
    Copy-FullPayload -Destination $fullRoot
    Write-Checksums -Root $fullRoot
}

$summary = [ordered]@{
    product = "HyperSearch"
    version = $Version
    runName = $RunName
    channel = $Channel
    createdAt = (Get-Date).ToString("o")
    outputRoot = $runRoot
    onlineRoot = if (Test-Path $onlineRoot) { $onlineRoot } else { "" }
    fullRoot = if (Test-Path $fullRoot) { $fullRoot } else { "" }
    imageArchivePath = $ImageArchivePath
    registryMode = $RegistryMode
    ghcrNamespace = $GhcrNamespace
    dockerHubNamespace = if ($RegistryMode -in @("DockerHub", "Both")) { $DockerHubNamespace } else { "" }
}

($summary | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $runRoot "media-summary.json") -Encoding UTF8

Write-Host "Installation media created at: $runRoot" -ForegroundColor Green
