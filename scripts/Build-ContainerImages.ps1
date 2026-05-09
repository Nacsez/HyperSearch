[CmdletBinding()]
param(
    [string]$Version = "1.0.0",
    [ValidateSet("GHCR", "DockerHub", "Both")]
    [string]$RegistryMode = "GHCR",
    [string]$GhcrNamespace = "ghcr.io/nacsez",
    [string]$DockerHubNamespace = "docker.io/nacsez",
    [switch]$Push,
    [switch]$SaveArchive,
    [string]$ArchivePath = "",
    [switch]$SkipThirdPartyPull,
    [switch]$SkipLicenseNoticeUpdate
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$apiContext = Join-Path $repoRoot "apps\api"
$uiContext = Join-Path $repoRoot "apps\ui"
$localApi = "hypersearch-api:$Version"
$localUi = "hypersearch-ui:$Version"
$sourceUrl = "https://github.com/Nacsez/HyperSearch"

if (-not $SkipLicenseNoticeUpdate) {
    try {
        & (Join-Path $PSScriptRoot "Update-LicenseNotices.ps1")
    } catch {
        throw "License notice update failed: $($_.Exception.Message)"
    }
}

$registryTags = @()
if ($RegistryMode -in @("GHCR", "Both")) {
    $registryTags += [ordered]@{
        Api = "$GhcrNamespace/hypersearch-api:$Version"
        Ui = "$GhcrNamespace/hypersearch-ui:$Version"
    }
}
if ($RegistryMode -in @("DockerHub", "Both")) {
    $registryTags += [ordered]@{
        Api = "$DockerHubNamespace/hypersearch-api:$Version"
        Ui = "$DockerHubNamespace/hypersearch-ui:$Version"
    }
}

function Invoke-Docker {
    param([string[]]$DockerArgs)
    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($DockerArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Invoke-DockerOutput {
    param([string[]]$DockerArgs)
    $output = & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "docker $($DockerArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
    return ($output -join "`n")
}

function Get-ImageDigestRecord {
    param([string]$Image)
    $imageId = Invoke-DockerOutput -DockerArgs @("image", "inspect", $Image, "--format", "{{.Id}}")
    $repoDigestsJson = Invoke-DockerOutput -DockerArgs @("image", "inspect", $Image, "--format", "{{json .RepoDigests}}")
    $repoDigests = @()
    if ($repoDigestsJson -and $repoDigestsJson -ne "<no value>") {
        $parsed = $repoDigestsJson | ConvertFrom-Json
        if ($parsed) {
            $repoDigests = @($parsed)
        }
    }
    [ordered]@{
        image = $Image
        image_id = $imageId.Trim()
        repo_digests = $repoDigests
    }
}

Write-Host "Building HyperSearch API image $localApi" -ForegroundColor Cyan
Invoke-Docker -DockerArgs @(
    "build",
    "--label", "org.opencontainers.image.title=HyperSearch API",
    "--label", "org.opencontainers.image.version=$Version",
    "--label", "org.opencontainers.image.source=$sourceUrl",
    "--label", "org.opencontainers.image.licenses=AGPL-3.0-only",
    "-t", $localApi,
    $apiContext
)

Write-Host "Building HyperSearch UI image $localUi" -ForegroundColor Cyan
Invoke-Docker -DockerArgs @(
    "build",
    "--label", "org.opencontainers.image.title=HyperSearch UI",
    "--label", "org.opencontainers.image.version=$Version",
    "--label", "org.opencontainers.image.source=$sourceUrl",
    "--label", "org.opencontainers.image.licenses=AGPL-3.0-only",
    "-t", $localUi,
    $uiContext
)

foreach ($tagSet in $registryTags) {
    Invoke-Docker -DockerArgs @("tag", $localApi, $tagSet.Api)
    Invoke-Docker -DockerArgs @("tag", $localUi, $tagSet.Ui)
    if ($Push) {
        Write-Host "Pushing $($tagSet.Api)" -ForegroundColor Cyan
        Invoke-Docker -DockerArgs @("push", $tagSet.Api)
        Write-Host "Pushing $($tagSet.Ui)" -ForegroundColor Cyan
        Invoke-Docker -DockerArgs @("push", $tagSet.Ui)
    }
}

$thirdPartyImages = @(
    "caddy:2.11.2-alpine",
    "valkey/valkey:8.1.6-alpine",
    "searxng/searxng:2026.4.13-ee66b070a"
)

if ($SaveArchive) {
    if (-not $ArchivePath) {
        $archiveDir = Join-Path $repoRoot "artifacts\images"
        New-Item -ItemType Directory -Force -Path $archiveDir | Out-Null
        $ArchivePath = Join-Path $archiveDir "hypersearch-images-$Version.tar"
    }
    $archiveParent = Split-Path -Parent $ArchivePath
    if ($archiveParent) {
        New-Item -ItemType Directory -Force -Path $archiveParent | Out-Null
    }
    if (-not $SkipThirdPartyPull) {
        foreach ($image in $thirdPartyImages) {
            Write-Host "Pulling third-party image $image" -ForegroundColor Cyan
            Invoke-Docker -DockerArgs @("pull", $image)
        }
    }
    $saveImages = @($localApi, $localUi)
    foreach ($tagSet in $registryTags) {
        $saveImages += @($tagSet.Api, $tagSet.Ui)
    }
    $saveImages += $thirdPartyImages
    $saveImages = @($saveImages | Select-Object -Unique)
    Write-Host "Saving image archive $ArchivePath" -ForegroundColor Cyan
    Invoke-Docker -DockerArgs (@("save", "-o", $ArchivePath) + $saveImages)
    Get-FileHash -Algorithm SHA256 -Path $ArchivePath | Format-List
    $manifestPath = "$ArchivePath.manifest.json"
    $manifest = [ordered]@{
        version = $Version
        created_at = (Get-Date).ToUniversalTime().ToString("o")
        archive = $ArchivePath
        archive_sha256 = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash
        images = @($saveImages | ForEach-Object { Get-ImageDigestRecord -Image $_ })
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $manifestPath
    Write-Host "Wrote image digest manifest $manifestPath" -ForegroundColor Cyan
}

Write-Host "Container image build complete." -ForegroundColor Green
