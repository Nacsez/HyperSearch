[CmdletBinding()]
param(
  [ValidateSet("up", "down", "restart", "status", "logs", "doctor", "open")]
  [string]$Action = "up",
  [switch]$Build,
  [switch]$NoBuild,
  [switch]$Follow
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$composeDir = Join-Path $repoRoot "infra/docker"
$composeEnvPath = Join-Path $composeDir ".env"
$rootEnvPath = Join-Path $repoRoot ".env"
$dockerConfigPath = Join-Path $repoRoot ".docker"
$dockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"

New-Item -ItemType Directory -Force -Path $dockerConfigPath | Out-Null
$env:DOCKER_CONFIG = (Resolve-Path $dockerConfigPath).Path

function Get-EnvValue {
  param(
    [string]$Path,
    [string]$Name,
    [string]$DefaultValue
  )

  if (-not (Test-Path $Path)) {
    return $DefaultValue
  }

  $line = Get-Content $Path | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
  if (-not $line) {
    return $DefaultValue
  }

  return ($line -split "=", 2)[1]
}

function Invoke-DockerCompose {
  param(
    [string[]]$ComposeArgs,
    [switch]$UseDevBuild
  )

  New-Item -ItemType Directory -Force -Path $dockerConfigPath | Out-Null
  $env:DOCKER_CONFIG = $dockerConfigPath
  $env:COMPOSE_PROJECT_NAME = "hypersearch"
  Push-Location $composeDir
  try {
    $composeOptions = @("compose", "--ansi", "never", "--project-name", "hypersearch")
    if ($UseDevBuild) {
      $composeOptions += @("-f", "docker-compose.yml", "-f", "docker-compose.dev.yml")
    }
    $dockerArgs = $composeOptions + $ComposeArgs
    & docker @dockerArgs
    if ($LASTEXITCODE -ne 0) {
      throw "docker compose $($ComposeArgs -join ' ') failed with exit code $LASTEXITCODE"
    }
  }
  finally {
    Pop-Location
  }
}

function Test-DockerDesktopReady {
  New-Item -ItemType Directory -Force -Path $dockerConfigPath | Out-Null
  $env:DOCKER_CONFIG = $dockerConfigPath
  $ready = $false
  try {
    $stderrFile = New-TemporaryFile
    $serverVersion = & docker info --format "{{.ServerVersion}}" 2>$stderrFile
    $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
    Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
    $fatal = $stderr -match "Docker Desktop is unable to start|failed to connect to the docker API|request returned 500 Internal Server Error|daemon is running"
    $ready = $LASTEXITCODE -eq 0 -and $serverVersion -match "^\d+\.\d+" -and -not $fatal
  }
  catch {
    $ready = $false
  }

  if (-not $ready -and (Test-Path $dockerDesktopExe)) {
    Write-Host "Docker engine is not ready. Starting Docker Desktop..." -ForegroundColor Yellow
    Start-Process -FilePath $dockerDesktopExe -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 3
      try {
        $stderrFile = New-TemporaryFile
        $serverVersion = & docker info --format "{{.ServerVersion}}" 2>$stderrFile
        $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue
        Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
        $fatal = $stderr -match "Docker Desktop is unable to start|failed to connect to the docker API|request returned 500 Internal Server Error|daemon is running"
        if ($LASTEXITCODE -eq 0 -and $serverVersion -match "^\d+\.\d+" -and -not $fatal) {
          $ready = $true
          break
        }
      }
      catch {
        $ready = $false
      }
    }
  }

  if (-not $ready) {
    Write-DockerDoctor
    throw "Docker Desktop is installed but the Docker engine is not ready. Open Docker Desktop and wait for startup to complete, then retry."
  }
}

function Write-DockerDoctor {
  Write-Host "Docker doctor checks" -ForegroundColor Cyan
  Write-Host "Isolated DOCKER_CONFIG: $dockerConfigPath"
  try {
    $testPath = Join-Path $dockerConfigPath "hypersearch-write-test.tmp"
    Set-Content -Path $testPath -Value "ok" -ErrorAction Stop
    Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
    Write-Host "Local .docker config: writable" -ForegroundColor Green
  } catch {
    Write-Host "Local .docker config: not writable. Remediation: move HyperSearch to a user-writable folder or repair ACLs for $dockerConfigPath" -ForegroundColor Yellow
  }
  $userDockerConfig = Join-Path $env:USERPROFILE ".docker\config.json"
  $userDockerConfigExists = $false
  $userDockerConfigChecked = $true
  try {
    $userDockerConfigExists = Test-Path $userDockerConfig -ErrorAction Stop
  } catch {
    $userDockerConfigChecked = $false
    Write-Host "User Docker config: access denied while checking ($userDockerConfig). Remediation: repair that file's ACLs or remove the stale config." -ForegroundColor Yellow
  }
  if ($userDockerConfigExists) {
    try {
      Get-Content -Path $userDockerConfig -TotalCount 1 -ErrorAction Stop | Out-Null
      Write-Host "User Docker config: readable ($userDockerConfig)" -ForegroundColor Green
    } catch {
      Write-Host "User Docker config: access denied ($userDockerConfig). Remediation: repair that file's ACLs or remove the stale config." -ForegroundColor Yellow
    }
  } elseif ($userDockerConfigChecked) {
    Write-Host "User Docker config: not present"
  }
  try {
    Write-Host "Docker context: $((& docker context show 2>&1 | Out-String).Trim())"
  } catch {
    Write-Host "Docker context unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
  }
  try {
    $pipe = Get-Item "\\.\pipe\docker_engine" -ErrorAction Stop
    Write-Host "Docker named pipe: visible ($($pipe.FullName))" -ForegroundColor Green
  } catch {
    Write-Host "Docker named pipe: not accessible. Remediation: start Docker Desktop and verify this user can access the engine pipe." -ForegroundColor Yellow
  }
  if (Get-Command sc.exe -ErrorAction SilentlyContinue) {
    Write-Host "Docker Desktop service:"
    sc.exe query com.docker.service
  }
  try {
    $groups = (& whoami /groups 2>&1 | Out-String)
    if ($groups.ToLowerInvariant().Contains("docker-users")) {
      Write-Host "docker-users group: current user appears to be a member" -ForegroundColor Green
    } else {
      Write-Host "docker-users group: current user not reported as a member. Remediation: add this account to docker-users, sign out, then sign back in." -ForegroundColor Yellow
    }
  } catch {
    Write-Host "docker-users group check failed: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  throw "Docker is not installed or not on PATH."
}

if (-not (Test-Path $composeDir)) {
  throw "Compose directory not found: $composeDir"
}

$bindHost = Get-EnvValue -Path $composeEnvPath -Name "HYPERSEARCH_BIND_HOST" -DefaultValue "127.0.0.1"
$httpPort = Get-EnvValue -Path $composeEnvPath -Name "HYPERSEARCH_HTTP_PORT" -DefaultValue "8090"
$lmStudioBaseUrl = Get-EnvValue -Path $composeEnvPath -Name "HYPERSEARCH_LMSTUDIO_BASE_URL" -DefaultValue "http://host.docker.internal:1234"
$lanEnabled = Get-EnvValue -Path $rootEnvPath -Name "HYPERSEARCH_LAN_ENABLED" -DefaultValue "false"

if (-not (Test-Path $rootEnvPath)) {
  Write-Warning "Repo-root .env is missing. The API container may start with incomplete settings."
}

switch ($Action) {
  "up" {
    Test-DockerDesktopReady
    $composeArgs = @("up", "-d")
    $useBuild = $Build -and -not $NoBuild
    if ($useBuild) {
      $composeArgs += "--build"
    }
    Invoke-DockerCompose -ComposeArgs $composeArgs -UseDevBuild:$useBuild
    Write-Host ""
    Write-Host "HyperSearch is starting." -ForegroundColor Green
    Write-Host "App URL:   http://$bindHost`:$httpPort/" -ForegroundColor Cyan
    Write-Host "Help URL:  http://$bindHost`:$httpPort/help/index.html" -ForegroundColor Cyan
    Write-Host "LM Studio: $lmStudioBaseUrl" -ForegroundColor DarkCyan
  }
  "down" {
    Test-DockerDesktopReady
    Invoke-DockerCompose -ComposeArgs @("down", "--remove-orphans")
    Write-Host "HyperSearch stopped." -ForegroundColor Yellow
  }
  "restart" {
    Test-DockerDesktopReady
    Invoke-DockerCompose -ComposeArgs @("down", "--remove-orphans")
    $composeArgs = @("up", "-d")
    $useBuild = $Build -and -not $NoBuild
    if ($useBuild) {
      $composeArgs += "--build"
    }
    Invoke-DockerCompose -ComposeArgs $composeArgs -UseDevBuild:$useBuild
    Write-Host ""
    Write-Host "HyperSearch restarted." -ForegroundColor Green
    Write-Host "App URL:   http://$bindHost`:$httpPort/" -ForegroundColor Cyan
    Write-Host "Help URL:  http://$bindHost`:$httpPort/help/index.html" -ForegroundColor Cyan
  }
  "status" {
    Test-DockerDesktopReady
    Invoke-DockerCompose -ComposeArgs @("ps")
  }
  "logs" {
    Test-DockerDesktopReady
    $composeArgs = @("logs", "--tail", "100")
    if ($Follow) {
      $composeArgs += "-f"
    }
    Invoke-DockerCompose -ComposeArgs $composeArgs
  }
  "doctor" {
    Write-Host "HyperSearch doctor" -ForegroundColor Cyan
    Write-Host "Repo root:     $repoRoot"
    Write-Host "Compose dir:   $composeDir"
    Write-Host "Bind host:     $bindHost"
    Write-Host "HTTP port:     $httpPort"
    Write-Host "LAN enabled:   $lanEnabled"
    Write-Host "LM Studio URL: $lmStudioBaseUrl"
    if (Get-Command docker -ErrorAction SilentlyContinue) {
      & docker --version
    }
    Write-DockerDoctor
    Test-DockerDesktopReady
    Invoke-DockerCompose -ComposeArgs @("config", "--quiet")
    Write-Host "Compose config is valid." -ForegroundColor Green
  }
  "open" {
    $url = "http://$bindHost`:$httpPort/"
    Start-Process $url
    Write-Host "Opened $url" -ForegroundColor Cyan
  }
}
