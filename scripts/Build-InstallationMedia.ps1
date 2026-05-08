[CmdletBinding()]
param(
    [string]$RunName = ("TestRun_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss")),
    [ValidateSet("Online", "Full", "Both")]
    [string]$Channel = "Both",
    [string]$Version = "1.0.0",
    [string]$GhcrNamespace = "ghcr.io/nacsez",
    [string]$DockerHubNamespace = "docker.io/nacsez",
    [string]$ImageArchivePath = "",
    [string]$DockerDesktopInstallerPath = "",
    [string]$LmStudioInstallerPath = "",
    [switch]$BuildImages,
    [switch]$PushImages,
    [switch]$SkipTauriBuild
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$desktopRoot = Join-Path $repoRoot "apps\desktop"
$mediaRoot = Join-Path $repoRoot "Installation Media"
$runRoot = Join-Path $mediaRoot $RunName
$onlineRoot = Join-Path $runRoot "Online"
$fullRoot = Join-Path $runRoot "Full"

New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

if ($BuildImages) {
    $imageDir = Join-Path $runRoot "image-build"
    New-Item -ItemType Directory -Force -Path $imageDir | Out-Null
    $ImageArchivePath = Join-Path $imageDir "hypersearch-images-$Version.tar"
    & (Join-Path $PSScriptRoot "Build-ContainerImages.ps1") `
        -Version $Version `
        -RegistryMode Both `
        -GhcrNamespace $GhcrNamespace `
        -DockerHubNamespace $DockerHubNamespace `
        -SaveArchive `
        -ArchivePath $ImageArchivePath `
        -Push:$PushImages
    if ($LASTEXITCODE -ne 0) {
        throw "Container image build failed with exit code $LASTEXITCODE"
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
    $manifest = [ordered]@{
        product = "HyperSearch"
        version = $Version
        channel = $MediaChannel
        runName = $RunName
        createdAt = (Get-Date).ToString("o")
        installer = "HyperSearch_${Version}_x64-setup.exe"
        msi = "HyperSearch_${Version}_x64_en-US.msi"
        directExe = "hypersearch-desktop.exe"
        runtimePath = "%LOCALAPPDATA%\HyperSearch\runtime"
        installerLogPath = "%LOCALAPPDATA%\HyperSearch\logs\installer-*.log"
        installerTranscriptPath = "%LOCALAPPDATA%\HyperSearch\logs\installer-transcript-*.log"
        setupSummaryPath = "%LOCALAPPDATA%\HyperSearch\logs\setup-summary-*.json"
        desktopLogPath = "%LOCALAPPDATA%\HyperSearch\logs\desktop.log"
        commandLogPath = "%LOCALAPPDATA%\HyperSearch\logs\commands"
        diagnosticsPath = "%LOCALAPPDATA%\HyperSearch\diagnostics"
        imagePrimaryRegistry = $GhcrNamespace
        imageFallbackRegistry = $DockerHubNamespace
        imageDigestManifest = if ($imageDigestManifestPath) { "payload\\images\\$(Split-Path -Leaf $imageDigestManifestPath)" } else { "" }
        notes = @(
            "Online media pulls prebuilt Docker images during setup.",
            "During private beta, online media falls back to a local API/UI image build if registry access is denied.",
            "Full media loads image archives from payload\\images when present.",
            "The NSIS setup runs the prerequisite helper and passes the installer media folder to it.",
            "Docker Desktop installation may require Windows administrator approval.",
            "Setup checks WSL status and runs wsl --update before Docker image setup so Docker Desktop can start its WSL backend on freshly installed systems.",
            "LM Studio model download is asynchronous and may continue after installer completion.",
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
    ghcrNamespace = $GhcrNamespace
    dockerHubNamespace = $DockerHubNamespace
}

($summary | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $runRoot "media-summary.json") -Encoding UTF8

Write-Host "Installation media created at: $runRoot" -ForegroundColor Green
