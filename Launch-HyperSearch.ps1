[CmdletBinding()]
param(
  [switch]$WebOnly,
  [switch]$NoBuild
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$releaseDesktopExe = Join-Path $repoRoot "apps\desktop\src-tauri\target\release\hypersearch-desktop.exe"
$debugDesktopExe = Join-Path $repoRoot "apps\desktop\src-tauri\target\debug\hypersearch-desktop.exe"
$desktopExe = if (Test-Path $releaseDesktopExe) { $releaseDesktopExe } else { $debugDesktopExe }
$deployScript = Join-Path $repoRoot "scripts\Deploy-HyperSearch.ps1"

function Start-WebConsole {
  param([switch]$SkipBuild)

  $args = @("-Action", "up")
  if ($SkipBuild) {
    $args += "-NoBuild"
  }
  & $deployScript @args
  if ($LASTEXITCODE -ne 0) {
    throw "HyperSearch backend failed to start."
  }
  & $deployScript -Action open
}

if ($WebOnly) {
  Start-WebConsole -SkipBuild:$NoBuild
  return
}

if (-not (Test-Path $desktopExe)) {
  Write-Host "Desktop executable not found. Building debug launcher..." -ForegroundColor Yellow
  Push-Location (Join-Path $repoRoot "apps\desktop")
  try {
    npm.cmd run build
    if ($LASTEXITCODE -ne 0) {
      throw "Desktop frontend build failed."
    }
  }
  finally {
    Pop-Location
  }

  Push-Location (Join-Path $repoRoot "apps\desktop\src-tauri")
  try {
    cargo build
    if ($LASTEXITCODE -ne 0) {
      throw "Desktop native build failed."
    }
  }
  finally {
    Pop-Location
  }
}

$desktopExe = if (Test-Path $releaseDesktopExe) { $releaseDesktopExe } else { $debugDesktopExe }

Start-Process -FilePath $desktopExe -WorkingDirectory $repoRoot
Write-Host "Started HyperSearch Desktop." -ForegroundColor Green
Write-Host "Desktop executable: $desktopExe" -ForegroundColor Cyan
Write-Host "Fallback browser launch: .\Launch-HyperSearch.ps1 -WebOnly" -ForegroundColor DarkCyan
