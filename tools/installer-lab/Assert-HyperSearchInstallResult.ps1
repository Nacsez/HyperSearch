[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [string[]]$ExpectedResult = @("passed", "warning"),
    [string]$AssertionsPath = "",
    [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowNull()]$Value = "")
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, [string]$Value, [System.Text.UTF8Encoding]::new($false))
}

function Add-Finding {
    param([System.Collections.ArrayList]$Findings, [string]$Severity, [string]$Message)
    [void]$Findings.Add([ordered]@{ severity = $Severity; message = $Message })
}

function Test-NoUtf8Bom {
    param([string]$Path)
    if (!(Test-Path $Path)) { return $true }
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        if ($stream.Length -lt 3) { return $true }
        $bytes = [byte[]]::new(3)
        [void]$stream.Read($bytes, 0, 3)
        return -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    } finally {
        $stream.Dispose()
    }
}

if (!(Test-Path $StatePath)) {
    throw "Installer state was not found: $StatePath"
}

$state = Get-Content -Raw -Path $StatePath | ConvertFrom-Json
$assertions = if ($AssertionsPath -and (Test-Path $AssertionsPath)) {
    Get-Content -Raw -Path $AssertionsPath | ConvertFrom-Json
} else {
    [pscustomobject]@{}
}

$findings = [System.Collections.ArrayList]::new()
$expectedSet = @{}
foreach ($result in $ExpectedResult) { $expectedSet[[string]$result] = $true }

if (-not $expectedSet.ContainsKey([string]$state.result)) {
    Add-Finding -Findings $findings -Severity "error" -Message "Unexpected installer result '$($state.result)'. Expected: $($ExpectedResult -join ', ')."
}

if ($assertions.requireDockerReady -eq $true -and -not [bool]$state.docker.readiness.ready) {
    Add-Finding -Findings $findings -Severity "error" -Message "Docker readiness was required but not true."
}

if ($assertions.requireImagesVerified -eq $true -and -not [bool]$state.imageSetup.verified) {
    Add-Finding -Findings $findings -Severity "error" -Message "Docker image verification was required but not true."
}

if ($assertions.requireStackReady -eq $true) {
    if ($state.steps.stack.status -ne "passed") {
        Add-Finding -Findings $findings -Severity "error" -Message "Stack step did not pass. Status=$($state.steps.stack.status) Message=$($state.steps.stack.message)"
    }
    if ($state.stack.live.ok -ne $true -or $state.stack.ready.ok -ne $true) {
        Add-Finding -Findings $findings -Severity "error" -Message "HTTP live/ready probes did not both pass."
    }
}

if ($assertions.requireNoInstallerWarnings -eq $true) {
    $warningMessages = @($state.warnings)
    $warningSteps = @($state.steps.PSObject.Properties | Where-Object { $_.Value.status -eq "warning" } | ForEach-Object { "$($_.Name): $($_.Value.message)" })
    if ($warningMessages.Count -gt 0 -or $warningSteps.Count -gt 0) {
        Add-Finding -Findings $findings -Severity "error" -Message "Installer warnings were forbidden. Warnings=$($warningMessages -join '; ') WarningSteps=$($warningSteps -join '; ')"
    }
}

if ($assertions.requireLmStudioReady -eq $true) {
    if ($state.lmStudio.pending -eq $true) {
        Add-Finding -Findings $findings -Severity "error" -Message "LM Studio readiness was required but lmStudio.pending is true."
    }
    if ([string]::IsNullOrWhiteSpace([string]$state.lmStudio.path)) {
        Add-Finding -Findings $findings -Severity "error" -Message "LM Studio readiness was required but lmStudio.path is empty."
    }
    if ([string]::IsNullOrWhiteSpace([string]$state.lmStudio.lmsPath)) {
        Add-Finding -Findings $findings -Severity "error" -Message "LM Studio readiness was required but lmStudio.lmsPath is empty."
    }
    if ($state.lmStudio.lmsReady -ne $true) {
        Add-Finding -Findings $findings -Severity "error" -Message "LM Studio readiness was required but lmStudio.lmsReady is not true."
    }
}

if ($assertions.requireLoginAutostart -eq $true) {
    if ($state.loginAutostart.requested -ne $true) {
        Add-Finding -Findings $findings -Severity "error" -Message "Login autostart was required but not requested in installer state."
    }
    if ($state.loginAutostart.registered -ne $true) {
        Add-Finding -Findings $findings -Severity "error" -Message "Login autostart was required but not registered. Error=$($state.loginAutostart.error)"
    }
    if ([string]$state.loginAutostart.commandLine -notmatch "--hypersearch-autostart") {
        Add-Finding -Findings $findings -Severity "error" -Message "Login autostart command line does not include --hypersearch-autostart."
    }
    if ($state.steps.autostart.status -ne "passed") {
        Add-Finding -Findings $findings -Severity "error" -Message "Autostart step did not pass. Status=$($state.steps.autostart.status) Message=$($state.steps.autostart.message)"
    }
}

if ($assertions.forbidInvalidModelId -eq $true) {
    $stateText = Get-Content -Raw -Path $StatePath
    if ($stateText -match "qwen2\.5-7b-instruct") {
        Add-Finding -Findings $findings -Severity "error" -Message "Invalid old LM Studio model id qwen2.5-7b-instruct appears in installer state."
    }
}

if ($assertions.requireLmStudioPendingDisablesLlm -eq $true -and $state.lmStudio.pending -eq $true) {
    if ($state.profile.llmEnabled -eq $true) {
        Add-Finding -Findings $findings -Severity "error" -Message "LM Studio is pending but profile.llmEnabled is true."
    }
    if ($state.profile.mode -ne "lmstudio-pending") {
        Add-Finding -Findings $findings -Severity "error" -Message "LM Studio is pending but profile.mode is '$($state.profile.mode)' instead of 'lmstudio-pending'."
    }
}

if ($assertions.requireNoComposeEnvBom -eq $true) {
    $composeEnv = ""
    if ($state.runtimeRoot) {
        $candidate = Join-Path ([string]$state.runtimeRoot) "infra\docker\.env"
        if (Test-Path $candidate) { $composeEnv = $candidate }
    }
    if (-not $composeEnv) {
        $stateRoot = Split-Path -Parent $StatePath
        $candidate = Get-ChildItem -Path $stateRoot -Recurse -Filter ".env" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "infra\\docker" } |
            Select-Object -First 1
        if ($candidate) { $composeEnv = $candidate.FullName }
    }
    if ($composeEnv -and -not (Test-NoUtf8Bom -Path $composeEnv)) {
        Add-Finding -Findings $findings -Severity "error" -Message "Compose .env contains a UTF-8 BOM: $composeEnv"
    }
}

if (@($state.errors).Count -gt 0 -and $assertions.allowInstallerErrors -ne $true) {
    Add-Finding -Findings $findings -Severity "error" -Message "Installer recorded errors: $(@($state.errors) -join '; ')"
}

$errorCount = @($findings | Where-Object { $_.severity -eq "error" }).Count
$result = [ordered]@{
    statePath = $StatePath
    installerResult = $state.result
    passed = ($errorCount -eq 0)
    errorCount = $errorCount
    findings = $findings
}

if ($OutputPath) {
    Write-Utf8NoBom -Path $OutputPath -Value ($result | ConvertTo-Json -Depth 8)
}

if ($errorCount -gt 0) {
    $findings | ForEach-Object { Write-Host "[$($_.severity)] $($_.message)" }
    exit 1
}

Write-Host "Installer assertions passed for $StatePath"
exit 0
