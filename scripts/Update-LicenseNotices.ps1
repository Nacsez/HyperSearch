[CmdletBinding()]
param(
    [switch]$Check
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Get-PythonDependencyNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    $names = @{}
    foreach ($line in Get-Content -Path $Path) {
        if ($line -match '^\s*"([A-Za-z0-9_.-]+)') {
            $name = $Matches[1].ToLowerInvariant()
            $names[$name] = $name
        }
    }
    return @($names.Keys | Sort-Object)
}

function Get-CargoDependencyNames {
    param([Parameter(Mandatory = $true)][string]$Path)

    $names = @{}
    $section = ""
    foreach ($line in Get-Content -Path $Path) {
        if ($line -match '^\s*\[([^\]]+)\]') {
            $section = $Matches[1]
            continue
        }
        if ($section -notin @("dependencies", "build-dependencies")) {
            continue
        }
        if ($line -match '^\s*([A-Za-z0-9_-]+)\s*=') {
            $name = $Matches[1].ToLowerInvariant()
            $names[$name] = $name
        }
    }
    return @($names.Keys | Sort-Object)
}

function Get-NodeLicenseSummary {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) {
        return @()
    }
    $raw = Get-Content -Raw -Path $Path
    $counts = @{}
    foreach ($match in [regex]::Matches($raw, '"license"\s*:\s*"([^"]+)"')) {
        $license = [string]$match.Groups[1].Value
        if (-not $counts.ContainsKey($license)) {
            $counts[$license] = 0
        }
        $counts[$license] += 1
    }
    $packageJsonPath = Join-Path (Split-Path -Parent $Path) "package.json"
    if (Test-Path $packageJsonPath) {
        $packageJson = Get-Content -Raw -Path $packageJsonPath | ConvertFrom-Json
        $rootLicense = [string]$packageJson.license
        if ($rootLicense -and $counts.ContainsKey($rootLicense)) {
            $counts[$rootLicense] -= 1
            if ($counts[$rootLicense] -le 0) {
                $counts.Remove($rootLicense)
            }
        }
    }
    return @($counts.Keys | Sort-Object | ForEach-Object {
        [pscustomobject]@{
            License = $_
            Count = $counts[$_]
        }
    })
}

function Get-ComposeDefaultImages {
    param([Parameter(Mandatory = $true)][string]$Path)

    $images = @{}
    foreach ($line in Get-Content -Path $Path) {
        if ($line -match 'image:\s*\$\{[^:}]+:-([^}]+)\}') {
            $image = $Matches[1].Trim()
            $images[$image] = $image
        } elseif ($line -match 'image:\s*([^\s#]+)') {
            $image = $Matches[1].Trim()
            $images[$image] = $image
        }
    }
    return @($images.Keys | Sort-Object)
}

function Assert-KnownDependencies {
    param(
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][hashtable]$LicenseMap,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $unknown = @($Names | Where-Object { -not $LicenseMap.ContainsKey($_.ToLowerInvariant()) })
    if ($unknown.Count -gt 0) {
        throw "$Context has dependency license entries missing from scripts/Update-LicenseNotices.ps1: $($unknown -join ', ')"
    }
}

function Test-KnownImage {
    param([Parameter(Mandatory = $true)][string]$Image)

    if ($Image -match '/hypersearch-(api|ui):') {
        return $true
    }
    return (
        $Image -like "ghcr.io/nacsez/hypersearch-*" -or
        $Image -like "docker.io/nacsez/hypersearch-*" -or
        $Image -like "caddy:*" -or
        $Image -like "valkey/valkey:*" -or
        $Image -like "searxng/searxng:*"
    )
}

function Add-DirectDependencyRows {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][string[]]$Names,
        [Parameter(Mandatory = $true)][hashtable]$LicenseMap
    )

    foreach ($name in ($Names | Sort-Object)) {
        $record = $LicenseMap[$name.ToLowerInvariant()]
        $Lines.Add("| ``$name`` | $($record.Scope) | $($record.License) | $($record.Source) |") | Out-Null
    }
}

function Join-Lines {
    param([AllowEmptyString()][string[]]$Lines)
    return ($Lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Write-Or-CheckFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][bool]$CheckOnly
    )

    if ($CheckOnly) {
        if (-not (Test-Path $Path)) {
            throw "Expected license artifact is missing: $Path"
        }
        $current = [System.IO.File]::ReadAllText($Path)
        if ($current.TrimEnd("`r", "`n") -ne $Content.TrimEnd("`r", "`n")) {
            throw "License artifact is stale. Run scripts/Update-LicenseNotices.ps1 and commit the result: $Path"
        }
        return
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

$pythonLicenseMap = @{
    "fastapi" = @{ Scope = "API runtime"; License = "MIT"; Source = "https://github.com/fastapi/fastapi" }
    "uvicorn" = @{ Scope = "API runtime"; License = "BSD-3-Clause"; Source = "https://github.com/encode/uvicorn" }
    "httpx" = @{ Scope = "API runtime"; License = "BSD-3-Clause"; Source = "https://github.com/encode/httpx" }
    "pydantic" = @{ Scope = "API runtime"; License = "MIT"; Source = "https://github.com/pydantic/pydantic" }
    "redis" = @{ Scope = "Optional cache client"; License = "MIT"; Source = "https://github.com/redis/redis-py" }
    "trafilatura" = @{ Scope = "Optional extraction"; License = "Apache-2.0"; Source = "https://github.com/adbar/trafilatura" }
    "opentelemetry-api" = @{ Scope = "Optional observability"; License = "Apache-2.0"; Source = "https://github.com/open-telemetry/opentelemetry-python" }
    "opentelemetry-sdk" = @{ Scope = "Optional observability"; License = "Apache-2.0"; Source = "https://github.com/open-telemetry/opentelemetry-python" }
    "opentelemetry-instrumentation-fastapi" = @{ Scope = "Optional observability"; License = "Apache-2.0"; Source = "https://github.com/open-telemetry/opentelemetry-python-contrib" }
    "playwright" = @{ Scope = "Optional JS fallback rendering"; License = "Apache-2.0"; Source = "https://github.com/microsoft/playwright-python" }
    "pytest" = @{ Scope = "Development/test"; License = "MIT"; Source = "https://github.com/pytest-dev/pytest" }
    "pytest-asyncio" = @{ Scope = "Development/test"; License = "Apache-2.0"; Source = "https://github.com/pytest-dev/pytest-asyncio" }
}

$rustLicenseMap = @{
    "rand" = @{ Scope = "Desktop runtime"; License = "MIT OR Apache-2.0"; Source = "https://github.com/rust-random/rand" }
    "serde" = @{ Scope = "Desktop runtime"; License = "MIT OR Apache-2.0"; Source = "https://github.com/serde-rs/serde" }
    "serde_json" = @{ Scope = "Desktop runtime"; License = "MIT OR Apache-2.0"; Source = "https://github.com/serde-rs/json" }
    "tauri" = @{ Scope = "Desktop runtime"; License = "MIT OR Apache-2.0"; Source = "https://github.com/tauri-apps/tauri" }
    "tauri-plugin-shell" = @{ Scope = "Desktop runtime"; License = "MIT OR Apache-2.0"; Source = "https://github.com/tauri-apps/plugins-workspace" }
    "tauri-build" = @{ Scope = "Desktop build"; License = "MIT OR Apache-2.0"; Source = "https://github.com/tauri-apps/tauri" }
}

$pythonDependencies = Get-PythonDependencyNames -Path (Join-Path $repoRoot "apps\api\pyproject.toml")
$cargoDependencies = Get-CargoDependencyNames -Path (Join-Path $repoRoot "apps\desktop\src-tauri\Cargo.toml")
$uiNodeSummary = Get-NodeLicenseSummary -Path (Join-Path $repoRoot "apps\ui\package-lock.json")
$desktopNodeSummary = Get-NodeLicenseSummary -Path (Join-Path $repoRoot "apps\desktop\package-lock.json")
$composeImages = Get-ComposeDefaultImages -Path (Join-Path $repoRoot "infra\docker\docker-compose.yml")
$projectLicensePath = Join-Path $repoRoot "LICENSE.md"
$copyingPath = Join-Path $repoRoot "COPYING"

if (-not (Test-Path $projectLicensePath)) {
    throw "LICENSE.md is missing."
}
if ((Get-Content -Raw -Path $projectLicensePath) -notmatch "SPDX-License-Identifier:\s*AGPL-3\.0-only") {
    throw "LICENSE.md must declare SPDX-License-Identifier: AGPL-3.0-only."
}
if (-not (Test-Path $copyingPath)) {
    throw "COPYING is missing. Add the full GNU AGPL v3 license text before release."
}
if ((Get-Content -Raw -Path $copyingPath) -notmatch "GNU AFFERO GENERAL PUBLIC LICENSE") {
    throw "COPYING does not appear to contain the GNU AGPL v3 license text."
}

Assert-KnownDependencies -Names $pythonDependencies -LicenseMap $pythonLicenseMap -Context "apps/api/pyproject.toml"
Assert-KnownDependencies -Names $cargoDependencies -LicenseMap $rustLicenseMap -Context "apps/desktop/src-tauri/Cargo.toml"

$missingNodeLicenses = @($uiNodeSummary + $desktopNodeSummary | Where-Object { $_.License -eq "<missing>" })
if ($missingNodeLicenses.Count -gt 0) {
    throw "One or more npm package-lock files contain packages without license metadata."
}

$unknownImages = @($composeImages | Where-Object { -not (Test-KnownImage -Image $_) })
if ($unknownImages.Count -gt 0) {
    throw "infra/docker/docker-compose.yml references images that need license notice review: $($unknownImages -join ', ')"
}

$noticeLines = [System.Collections.Generic.List[string]]::new()
$noticeLines.Add("# Third-Party Notices") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("This file is maintained by ``scripts/Update-LicenseNotices.ps1``. Run that script after dependency, image, or release-packaging changes, and run it with ``-Check`` in release validation to detect stale notices.") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("HyperSearch-owned source code is licensed under ``AGPL-3.0-only``. Third-party components remain under their own licenses.") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("## Runtime Service Images") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("| Component | Current image reference | License posture | Source |") | Out-Null
$noticeLines.Add("| --- | --- | --- | --- |") | Out-Null
foreach ($image in ($composeImages | Sort-Object)) {
    if ($image -like "caddy:*") {
        $noticeLines.Add("| Caddy | ``$image`` | Apache-2.0 | https://github.com/caddyserver/caddy |") | Out-Null
    } elseif ($image -like "valkey/valkey:*") {
        $noticeLines.Add("| Valkey | ``$image`` | BSD-3-Clause | https://github.com/valkey-io/valkey |") | Out-Null
    } elseif ($image -like "searxng/searxng:*") {
        $noticeLines.Add("| SearXNG | ``$image`` | AGPL-3.0-or-later upstream project posture | https://github.com/searxng/searxng |") | Out-Null
    } elseif ($image -like "*hypersearch-api:*") {
        $noticeLines.Add("| HyperSearch API image | ``$image`` | AGPL-3.0-only plus API dependencies below | This repository |") | Out-Null
    } elseif ($image -like "*hypersearch-ui:*") {
        $noticeLines.Add("| HyperSearch UI image | ``$image`` | AGPL-3.0-only plus UI dependencies below | This repository |") | Out-Null
    }
}
$noticeLines.Add("") | Out-Null
$noticeLines.Add("Docker base images and operating-system packages inside the built images are provided under their own upstream licenses. Release media should retain Docker image digest manifests so an end user can match shipped images to the corresponding upstream image and source package set.") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("## Python Direct Dependencies") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("| Package | Scope | License posture | Source |") | Out-Null
$noticeLines.Add("| --- | --- | --- | --- |") | Out-Null
Add-DirectDependencyRows -Lines $noticeLines -Names $pythonDependencies -LicenseMap $pythonLicenseMap
$noticeLines.Add("") | Out-Null
$noticeLines.Add("Python transitive dependencies are resolved by the installer/runtime build and remain under their own licenses. The release process should keep lockfile or image provenance artifacts with each binary/media release.") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("## npm Package License Summary") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("The npm package-lock files carry transitive package license metadata. This generated summary is intended to flag unusual drift before release; each package remains under its own license.") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("| Package lock | License expression | Package count |") | Out-Null
$noticeLines.Add("| --- | --- | ---: |") | Out-Null
foreach ($entry in $uiNodeSummary) {
    $noticeLines.Add("| ``apps/ui/package-lock.json`` | ``$($entry.License)`` | $($entry.Count) |") | Out-Null
}
foreach ($entry in $desktopNodeSummary) {
    $noticeLines.Add("| ``apps/desktop/package-lock.json`` | ``$($entry.License)`` | $($entry.Count) |") | Out-Null
}
$noticeLines.Add("") | Out-Null
$noticeLines.Add("## Rust Direct Dependencies") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("| Crate | Scope | License posture | Source |") | Out-Null
$noticeLines.Add("| --- | --- | --- | --- |") | Out-Null
Add-DirectDependencyRows -Lines $noticeLines -Names $cargoDependencies -LicenseMap $rustLicenseMap
$noticeLines.Add("") | Out-Null
$noticeLines.Add("Rust transitive dependencies are resolved through ``Cargo.lock`` and remain under their own licenses. Review ``cargo metadata`` or a cargo license report before each public release if dependency versions change.") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("## Optional External Installers") | Out-Null
$noticeLines.Add("") | Out-Null
$noticeLines.Add("Docker Desktop and LM Studio are optional external installers for full media workflows. They are not HyperSearch dependencies licensed by this repository. If they are bundled into release media, their redistribution terms, signatures, and SHA256 hashes must be verified and documented for that media build.") | Out-Null

$sourceLines = [System.Collections.Generic.List[string]]::new()
$sourceLines.Add("# Source Offer and Corresponding Source") | Out-Null
$sourceLines.Add("") | Out-Null
$sourceLines.Add("HyperSearch-owned source code is licensed under ``AGPL-3.0-only``. Public binary releases, installer media, and container images should be accompanied by the complete corresponding HyperSearch source for the exact release tag or commit used to build them.") | Out-Null
$sourceLines.Add("") | Out-Null
$sourceLines.Add("For public releases, provide source access through the GitHub release tag and keep these files in the release assets or repository root:") | Out-Null
$sourceLines.Add("") | Out-Null
$sourceLines.Add("- ``LICENSE.md``") | Out-Null
$sourceLines.Add("- ``COPYING``") | Out-Null
$sourceLines.Add("- ``THIRD_PARTY_NOTICES.md``") | Out-Null
$sourceLines.Add("- ``SOURCE_OFFER.md``") | Out-Null
$sourceLines.Add("- media ``manifest.json`` and ``checksums.sha256`` files") | Out-Null
$sourceLines.Add("- Docker image digest manifest files produced by ``scripts/Build-ContainerImages.ps1``") | Out-Null
$sourceLines.Add("") | Out-Null
$sourceLines.Add("The complete corresponding HyperSearch source includes the API, UI, desktop launcher, Docker/Compose configuration, build scripts, installer helper scripts, documentation, and test assets needed to rebuild the shipped HyperSearch binaries and images.") | Out-Null
$sourceLines.Add("") | Out-Null
$sourceLines.Add("Third-party service images and tools are provided under their own licenses. Their source-code locations are summarized in ``THIRD_PARTY_NOTICES.md``. SearXNG is an AGPL-licensed upstream service and must remain attributable with source access preserved in any redistributed media.") | Out-Null
$sourceLines.Add("") | Out-Null
$sourceLines.Add("If a binary or installer package is separated from its matching source release, the distributor should provide the matching source archive or release tag location for at least the period required by the applicable free-software licenses.") | Out-Null

$noticeContent = Join-Lines -Lines $noticeLines
$sourceContent = Join-Lines -Lines $sourceLines

Write-Or-CheckFile -Path (Join-Path $repoRoot "THIRD_PARTY_NOTICES.md") -Content $noticeContent -CheckOnly:$Check
Write-Or-CheckFile -Path (Join-Path $repoRoot "SOURCE_OFFER.md") -Content $sourceContent -CheckOnly:$Check

if ($Check) {
    Write-Host "License notices are current." -ForegroundColor Green
} else {
    Write-Host "Updated THIRD_PARTY_NOTICES.md and SOURCE_OFFER.md." -ForegroundColor Green
}
