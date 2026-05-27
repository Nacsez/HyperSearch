$ErrorActionPreference = "Stop"

$runtimeRoot = Join-Path $env:LOCALAPPDATA "HyperSearch\runtime"
$composeDir = Join-Path $runtimeRoot "infra\docker"
$composeEnv = Join-Path $composeDir ".env"
New-Item -ItemType Directory -Force -Path $composeDir | Out-Null

$content = @(
    "COMPOSE_PROJECT_NAME=hypersearch",
    "HYPERSEARCH_BIND_HOST=127.0.0.1",
    "HYPERSEARCH_HTTP_PORT=8090",
    "HYPERSEARCH_LMSTUDIO_BASE_URL=http://host.docker.internal:1234",
    "HYPERSEARCH_API_IMAGE=ghcr.io/nacsez/hypersearch-api:1.1.0",
    "HYPERSEARCH_UI_IMAGE=ghcr.io/nacsez/hypersearch-ui:1.1.0",
    "HYPERSEARCH_CADDY_IMAGE=caddy:2.11.2-alpine",
    "HYPERSEARCH_VALKEY_IMAGE=valkey/valkey:8.1.6-alpine",
    "HYPERSEARCH_SEARXNG_IMAGE=searxng/searxng:2026.4.13-ee66b070a"
) -join "`r`n"

$encoding = [System.Text.UTF8Encoding]::new($true)
[System.IO.File]::WriteAllText($composeEnv, "$content`r`n", $encoding)
Write-Host "Seeded UTF-8 BOM compose env at $composeEnv"
