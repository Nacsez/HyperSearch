[CmdletBinding()]
param(
    [string]$Version = "1.0.0",
    [ValidateSet("GHCR", "DockerHub", "Both")]
    [string]$RegistryMode = "Both",
    [string]$GhcrNamespace = "ghcr.io/nacsez",
    [string]$DockerHubNamespace = "docker.io/nacsez",
    [switch]$Push,
    [switch]$SaveArchive,
    [string]$ArchivePath = "",
    [switch]$SkipThirdPartyPull
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$apiContext = Join-Path $repoRoot "apps\api"
$uiContext = Join-Path $repoRoot "apps\ui"
$localApi = "hypersearch-api:$Version"
$localUi = "hypersearch-ui:$Version"

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

Write-Host "Building HyperSearch API image $localApi" -ForegroundColor Cyan
Invoke-Docker -DockerArgs @("build", "-t", $localApi, $apiContext)

Write-Host "Building HyperSearch UI image $localUi" -ForegroundColor Cyan
Invoke-Docker -DockerArgs @("build", "-t", $localUi, $uiContext)

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
    "caddy:2-alpine",
    "valkey/valkey:8-alpine",
    "searxng/searxng:latest"
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
}

Write-Host "Container image build complete." -ForegroundColor Green
