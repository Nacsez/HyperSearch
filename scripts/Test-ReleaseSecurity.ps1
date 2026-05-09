[CmdletBinding()]
param(
    [switch]$SkipNetworkAudits
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $failures.Add($Message) | Out-Null
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    try {
        & $Command
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Add-Failure "$Description failed with exit code $LASTEXITCODE."
        }
    } catch {
        Add-Failure "$Description failed: $($_.Exception.Message)"
    }
}

Push-Location $repoRoot
try {
    Invoke-CheckedCommand -Description "License notice check" -Command {
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\Update-LicenseNotices.ps1" -Check
    }

    $securityPolicy = Get-Content -Raw -Path "SECURITY.md"
    if ($securityPolicy -match "Before public release|maintainer channel used for this local repository") {
        Add-Failure "SECURITY.md still contains temporary/private-release reporting language."
    }
    if ($securityPolicy -notmatch "Report a vulnerability") {
        Add-Failure "SECURITY.md does not describe GitHub private vulnerability reporting."
    }

    $tracked = @(& git ls-files)
    if ($LASTEXITCODE -ne 0) {
        Add-Failure "git ls-files failed."
        $tracked = @()
    }

    foreach ($path in $tracked) {
        $leaf = Split-Path -Leaf $path
        if ($leaf -eq ".env") {
            Add-Failure "Tracked .env file found: $path"
        }
        if ($path -match '\.(pfx|p12|p7b|p7c|key|pem|ppk)$') {
            Add-Failure "Tracked certificate/key-like file requires review before release: $path"
        }
        if ($path -match '(diagnostics|setup-summary|desktop\.log|commands/|commands\\)') {
            Add-Failure "Tracked diagnostics/log artifact requires review before release: $path"
        }
    }

    $patterns = @(
        @{ Name = "private key"; Pattern = '-----BEGIN (?:RSA |DSA |EC |OPENSSH |)?PRIVATE KEY-----' },
        @{ Name = "GitHub token"; Pattern = 'gh[pousr]_[A-Za-z0-9_]{30,}' },
        @{ Name = "GitHub fine-grained token"; Pattern = 'github_pat_[A-Za-z0-9_]{20,}' },
        @{ Name = "OpenAI-style API key"; Pattern = 'sk-[A-Za-z0-9]{20,}' },
        @{ Name = "AWS access key"; Pattern = 'AKIA[0-9A-Z]{16}' },
        @{ Name = "Docker auth config"; Pattern = '"auths"\s*:\s*\{' }
    )

    $textExtensions = @(".md", ".txt", ".ps1", ".psm1", ".cmd", ".json", ".yml", ".yaml", ".toml", ".py", ".ts", ".tsx", ".js", ".css", ".html", ".nsh", ".env", ".example", ".sh", ".rs", ".lock")
    foreach ($path in $tracked) {
        if (-not (Test-Path $path)) {
            continue
        }
        $item = Get-Item $path
        if ($item.Length -gt 2MB) {
            continue
        }
        $extension = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        $leaf = Split-Path -Leaf $path
        if ($extension -notin $textExtensions -and $leaf -notin @("Dockerfile", "Caddyfile", "COPYING", "LICENSE")) {
            continue
        }
        $content = Get-Content -Raw -Path $path -ErrorAction SilentlyContinue
        foreach ($rule in $patterns) {
            if ($content -match $rule.Pattern) {
                Add-Failure "Possible $($rule.Name) found in tracked file: $path"
            }
        }
    }

    if (-not $SkipNetworkAudits) {
        $env:npm_config_cache = Join-Path $repoRoot ".npm-cache"
        Invoke-CheckedCommand -Description "UI npm production audit" -Command {
            Push-Location "apps\ui"
            try { npm.cmd audit --omit=dev --audit-level=high } finally { Pop-Location }
        }
        Invoke-CheckedCommand -Description "Desktop npm production audit" -Command {
            Push-Location "apps\desktop"
            try { npm.cmd audit --omit=dev --audit-level=high } finally { Pop-Location }
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host "Release security check failed:" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host " - $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "Release security check passed." -ForegroundColor Green
} finally {
    Pop-Location
}
