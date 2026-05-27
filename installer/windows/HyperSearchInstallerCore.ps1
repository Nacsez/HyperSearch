Set-StrictMode -Version 2.0

$script:HyperSearchInstallerCoreLoaded = $true

function New-HyperSearchInstallerOptions {
    param(
        [string]$InstallDir = "",
        [string]$MediaDir = "",
        [string]$Version = "",
        [ValidateSet("standard", "custom")]
        [string]$InstallMode = "standard",
        [bool]$AcceptedLicenses = $false,
        [bool]$InstallDocker = $true,
        [ValidateSet("per-user", "all-users")]
        [string]$DockerInstallMode = "per-user",
        [bool]$RepairDocker = $true,
        [int]$DockerReadyTimeoutSeconds = 480,
        [bool]$InstallLmStudio = $true,
        [ValidateSet("bundled", "online", "skip")]
        [string]$ImageSource = "bundled",
        [bool]$StartStack = $true,
        [bool]$EnableLoginAutostart = $false,
        [string]$UsagePreset = "general-research",
        [string]$SelectedModel = "recommended",
        [bool]$DownloadModel = $true,
        [scriptblock]$OnStep = $null
    )

    [pscustomobject]@{
        InstallDir = $InstallDir
        MediaDir = $MediaDir
        Version = $Version
        InstallMode = $InstallMode
        AcceptedLicenses = $AcceptedLicenses
        InstallDocker = $InstallDocker
        DockerInstallMode = $DockerInstallMode
        RepairDocker = $RepairDocker
        DockerReadyTimeoutSeconds = $DockerReadyTimeoutSeconds
        InstallLmStudio = $InstallLmStudio
        ImageSource = $ImageSource
        StartStack = $StartStack
        EnableLoginAutostart = $EnableLoginAutostart
        UsagePreset = $UsagePreset
        SelectedModel = $SelectedModel
        DownloadModel = $DownloadModel
        OnStep = $OnStep
    }
}

function New-HyperSearchStep {
    param([string]$Status = "not_started", [string]$Message = "")
    [ordered]@{
        status = $Status
        message = $Message
        startedAt = ""
        completedAt = ""
    }
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -eq 0) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function ConvertTo-CommandText {
    param($Value)
    if ($null -eq $Value) {
        return ""
    }
    return ([string]$Value) -replace "`0", ""
}

function Initialize-HyperSearchInstallState {
    param([Parameter(Mandatory = $true)]$Options)

    $dataRoot = Join-Path $env:LOCALAPPDATA "HyperSearch"
    $runtimeRoot = Join-Path $dataRoot "runtime"
    $logDir = Join-Path $dataRoot "logs"
    $commandLogDir = Join-Path $logDir "commands"
    $diagnosticsDir = Join-Path $dataRoot "diagnostics"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    New-Item -ItemType Directory -Force -Path $commandLogDir | Out-Null
    New-Item -ItemType Directory -Force -Path $diagnosticsDir | Out-Null

    $runId = Get-Date -Format "yyyyMMdd-HHmmss"
    $logPath = Join-Path $logDir ("installer-{0}.log" -f $runId)
    $transcriptPath = Join-Path $logDir ("installer-transcript-{0}.log" -f $runId)
    $summaryPath = Join-Path $logDir ("setup-summary-{0}.json" -f $runId)

    $state = [ordered]@{
        runId = $runId
        startedAt = (Get-Date).ToString("o")
        completedAt = ""
        result = "running"
        installDir = $Options.InstallDir
        mediaDir = $Options.MediaDir
        version = ""
        dataRoot = $dataRoot
        runtimeRoot = $runtimeRoot
        logDir = $logDir
        commandLogDir = $commandLogDir
        diagnosticsDir = $diagnosticsDir
        logPath = $logPath
        transcriptPath = $transcriptPath
        summaryPath = $summaryPath
        installProfilePath = Join-Path $dataRoot "install-profile.json"
        installProfileEnvPath = Join-Path $dataRoot "install-profile.env"
        options = $Options
        process = [ordered]@{}
        os = [ordered]@{}
        media = [ordered]@{}
        hardware = [ordered]@{}
        wsl = [ordered]@{}
        docker = [ordered]@{}
        runtimeCopy = [ordered]@{}
        env = [ordered]@{}
        imageSetup = [ordered]@{}
        stack = [ordered]@{}
        lmStudio = [ordered]@{}
        profile = [ordered]@{}
        loginAutostart = [ordered]@{}
        modelDownload = [ordered]@{}
        diagnostics = [ordered]@{}
        steps = [ordered]@{
            prerequisites = New-HyperSearchStep
            runtime = New-HyperSearchStep
            wsl = New-HyperSearchStep
            docker = New-HyperSearchStep
            images = New-HyperSearchStep
            lmstudio = New-HyperSearchStep
            profile = New-HyperSearchStep
            autostart = New-HyperSearchStep
            stack = New-HyperSearchStep
            model = New-HyperSearchStep
            diagnostics = New-HyperSearchStep
        }
        warnings = @()
        errors = @()
        transcriptStarted = $false
    }

    try {
        Start-Transcript -Path $transcriptPath -Force | Out-Null
        $state.transcriptStarted = $true
    } catch {
        $state.warnings = @($state.warnings) + "Failed to start transcript: $($_.Exception.Message)"
    }

    return $state
}

function Write-SetupLog {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message
    Add-Content -Path $State.logPath -Value $line
    Write-Host $line
}

function Add-SetupWarning {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$Message)
    $State.warnings = @($State.warnings) + $Message
    Write-SetupLog -State $State -Message $Message -Level "WARN"
}

function Add-SetupError {
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$Message)
    $State.errors = @($State.errors) + $Message
    Write-SetupLog -State $State -Message $Message -Level "ERROR"
}

function Set-InstallStepStatus {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet("not_started", "running", "passed", "warning", "blocked", "failed")]
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Message = ""
    )
    if (-not $State.steps.Contains($Name)) {
        $State.steps[$Name] = New-HyperSearchStep
    }
    if ($Status -eq "running" -and [string]::IsNullOrWhiteSpace($State.steps[$Name].startedAt)) {
        $State.steps[$Name].startedAt = (Get-Date).ToString("o")
    }
    if ($Status -in @("passed", "warning", "blocked", "failed")) {
        $State.steps[$Name].completedAt = (Get-Date).ToString("o")
    }
    $State.steps[$Name].status = $Status
    $State.steps[$Name].message = $Message
    Write-SetupLog -State $State -Message ("Step {0}: {1}. {2}" -f $Name, $Status, $Message) -Level $(if ($Status -in @("blocked", "failed")) { "WARN" } else { "INFO" })
    if ($State.options.OnStep) {
        & $State.options.OnStep $Name $Status $Message
    }
}

function Redact-SetupText {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    $Value -replace '(?im)^([^=\r\n]*(token|secret|password|api[_-]?key|authorization)[^=\r\n]*=).+$', '$1<redacted>' `
           -replace '(?i)(Authorization:\s*Bearer\s+)[^\s\r\n]+', '$1<redacted>' `
           -replace '(?i)(hypersearch_token=)[^&\s\r\n]+', '$1<redacted>'
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()]$Value = ""
    )
    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if ($Value -is [System.Array]) {
        $text = ($Value | ForEach-Object { [string]$_ }) -join "`r`n"
        if ($Value.Count -gt 0) {
            $text = "$text`r`n"
        }
    } else {
        $text = [string]$Value
    }
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $text, $encoding)
}

function Get-SetupMapValue {
    param(
        [AllowNull()]$Map,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Default = ""
    )
    if ($null -eq $Map) { return $Default }
    if ($Map -is [System.Collections.IDictionary]) {
        if ($Map.Contains($Name)) { return $Map[$Name] }
        return $Default
    }
    if ($Map.PSObject -and $Map.PSObject.Properties[$Name]) {
        return $Map.PSObject.Properties[$Name].Value
    }
    return $Default
}

function Write-SetupSummary {
    param([Parameter(Mandatory = $true)]$State)
    $State.completedAt = (Get-Date).ToString("o")
    $errorCount = @($State.errors).Count
    $blockedCount = @($State.steps.Values | Where-Object { $_.status -eq "blocked" }).Count
    $warningStepCount = @($State.steps.Values | Where-Object { $_.status -eq "warning" }).Count
    $warningCount = @($State.warnings).Count
    if ($errorCount -gt 0) {
        $State.result = "failed"
    } elseif ($blockedCount -gt 0) {
        $State.result = "blocked"
    } elseif ($warningStepCount -gt 0 -or $warningCount -gt 0) {
        $State.result = "warning"
    } else {
        $State.result = "passed"
    }
    try {
        Write-Utf8NoBom -Path $State.summaryPath -Value ($State | ConvertTo-Json -Depth 12)
        Write-SetupLog -State $State -Message "Setup summary written: $($State.summaryPath)"
        Update-InstallProfileSetupResult -State $State
    } catch {
        Write-SetupLog -State $State -Message "Failed to write setup summary: $($_.Exception.Message)" -Level "ERROR"
    }
}

function Update-InstallProfileSetupResult {
    param([Parameter(Mandatory = $true)]$State)
    if (-not $State.installProfilePath -or -not (Test-Path $State.installProfilePath)) {
        return
    }
    try {
        $profile = Get-Content -Raw -Path $State.installProfilePath | ConvertFrom-Json
        if (-not $profile.PSObject.Properties["setup"]) {
            $profile | Add-Member -NotePropertyName "setup" -NotePropertyValue ([pscustomobject]@{}) -Force
        }
        $setup = $profile.setup
        $setup | Add-Member -NotePropertyName "result" -NotePropertyValue $State.result -Force
        $setup | Add-Member -NotePropertyName "runId" -NotePropertyValue $State.runId -Force
        $setup | Add-Member -NotePropertyName "logPath" -NotePropertyValue $State.logPath -Force
        $setup | Add-Member -NotePropertyName "summaryPath" -NotePropertyValue $State.summaryPath -Force
        $setup | Add-Member -NotePropertyName "commandLogDir" -NotePropertyValue $State.commandLogDir -Force
        $diagnosticsPath = if ($State.diagnostics.Contains("bundlePath")) { $State.diagnostics.bundlePath } else { "" }
        $setup | Add-Member -NotePropertyName "diagnosticsPath" -NotePropertyValue $diagnosticsPath -Force
        Write-Utf8NoBom -Path $State.installProfilePath -Value ($profile | ConvertTo-Json -Depth 10)
        if (Test-Path $State.installProfileEnvPath) {
            Set-EnvValue -State $State -Path $State.installProfileEnvPath -Name "HYPERSEARCH_INSTALL_RESULT" -Value $State.result
        }
    } catch {
        Write-SetupLog -State $State -Message "Failed to update install profile setup result: $($_.Exception.Message)" -Level "WARN"
    }
}

function Stop-SetupTranscript {
    param([Parameter(Mandatory = $true)]$State)
    if ($State.transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}

function Invoke-SetupCommand {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$Name = "",
        [string]$WorkingDirectory = ""
    )
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    }
    $safeName = ($Name -replace '[^a-zA-Z0-9._-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = "command" }
    $commandRunId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $stdoutPath = Join-Path $State.commandLogDir "$commandRunId-$safeName.stdout.log"
    $stderrPath = Join-Path $State.commandLogDir "$commandRunId-$safeName.stderr.log"
    $commandPath = Join-Path $State.commandLogDir "$commandRunId-$safeName.command.log"
    $started = Get-Date
    $exitCode = 9009
    $spawnError = ""
    $argumentLine = ($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Value ([string]$_) }) -join " "
    Write-SetupLog -State $State -Message "Command start: $FilePath $argumentLine"
    try {
        $startArgs = @{
            FilePath = $FilePath
            ArgumentList = $argumentLine
            Wait = $true
            PassThru = $true
            NoNewWindow = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError = $stderrPath
        }
        if ($WorkingDirectory) {
            $startArgs.WorkingDirectory = $WorkingDirectory
        }
        $process = Start-Process @startArgs
        $exitCode = $process.ExitCode
    } catch {
        $spawnError = $_.Exception.Message
        Write-Utf8NoBom -Path $stderrPath -Value $spawnError
    }
    $finished = Get-Date
    $stdout = if (Test-Path $stdoutPath) { ConvertTo-CommandText (Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue) } else { "" }
    $stderr = if (Test-Path $stderrPath) { ConvertTo-CommandText (Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue) } else { "" }
    Write-Utf8NoBom -Path $commandPath -Value @(
        "startedAt=$($started.ToString("o"))",
        "finishedAt=$($finished.ToString("o"))",
        "durationMs=$([int](New-TimeSpan -Start $started -End $finished).TotalMilliseconds)",
        "exitCode=$exitCode",
        "filePath=$FilePath",
        "workingDirectory=$WorkingDirectory",
        "arguments=$($Arguments -join ' ')",
        "argumentLine=$argumentLine",
        "stdoutPath=$stdoutPath",
        "stderrPath=$stderrPath",
        "spawnError=$spawnError"
    )
    Write-SetupLog -State $State -Message "Command complete: $FilePath exit=$exitCode stdout=$stdoutPath stderr=$stderrPath"
    return [pscustomobject]@{
        ExitCode = $exitCode
        Stdout = $stdout
        Stderr = $stderr
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        CommandPath = $commandPath
        SpawnError = $spawnError
        Error = if ($spawnError) { $spawnError } else { $stderr }
    }
}

function Get-MediaManifest {
    param([Parameter(Mandatory = $true)]$State)
    $manifestPath = if ($State.mediaDir) { Join-Path $State.mediaDir "manifest.json" } else { "" }
    if ($manifestPath -and (Test-Path $manifestPath)) {
        try {
            $manifest = Get-Content -Raw -Path $manifestPath | ConvertFrom-Json
            $State.media = [ordered]@{
                manifestPath = $manifestPath
                channel = [string]$manifest.channel
                version = [string]$manifest.version
                imageDigestManifest = [string]$manifest.imageDigestManifest
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$manifest.version)) {
                return [string]$manifest.version
            }
        } catch {
            Add-SetupWarning -State $State -Message "Could not parse media manifest: $($_.Exception.Message)"
        }
    }
    return ""
}

function Initialize-SystemSnapshot {
    param([Parameter(Mandatory = $true)]$State)
    Set-InstallStepStatus -State $State -Name "prerequisites" -Status "running" -Message "Capturing system details."
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $State.process = [ordered]@{
            user = $identity.Name
            elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
            powershell = $PSVersionTable.PSVersion.ToString()
            pid = $PID
        }
    } catch {
        Add-SetupWarning -State $State -Message "Failed to capture process identity: $($_.Exception.Message)"
    }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $currentVersion = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
        $State.os = [ordered]@{
            caption = $os.Caption
            version = $os.Version
            buildNumber = $os.BuildNumber
            displayVersion = if ($currentVersion) { [string]$currentVersion.DisplayVersion } else { "" }
            editionId = if ($currentVersion) { [string]$currentVersion.EditionID } else { "" }
            installationType = if ($currentVersion) { [string]$currentVersion.InstallationType } else { "" }
            architecture = $os.OSArchitecture
        }
    } catch {
        Add-SetupWarning -State $State -Message "Failed to capture OS details: $($_.Exception.Message)"
    }
    $mediaVersion = Get-MediaManifest -State $State
    $State.version = if ($State.options.Version) { $State.options.Version } elseif ($mediaVersion) { $mediaVersion } else { "1.1.0" }
    Set-InstallStepStatus -State $State -Name "prerequisites" -Status "passed" -Message "System snapshot captured."
}

function Test-ProcessElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Test-RebootPending {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    )
    foreach ($path in $paths) {
        try {
            if ($path -like "*Session Manager") {
                $value = (Get-ItemProperty -Path $path -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
                if ($value) { return $true }
            } elseif (Test-Path $path) {
                return $true
            }
        } catch {}
    }
    return $false
}

function Register-ResumeAfterReboot {
    param([Parameter(Mandatory = $true)]$State)
    try {
        $scriptPath = Join-Path $PSScriptRoot "HyperSearchPrereqSetup.ps1"
        $powershell = Join-Path $PSHOME "powershell.exe"
        $command = '"{0}" -NoProfile -Sta -ExecutionPolicy Bypass -File "{1}" -InstallDir "{2}" -MediaDir "{3}"' -f $powershell, $scriptPath, $State.installDir, $State.mediaDir
        $runOncePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce"
        New-Item -Path $runOncePath -Force | Out-Null
        Set-ItemProperty -Path $runOncePath -Name "HyperSearchInstallationWizardResume" -Value $command
        $State.wsl.resumeRegistered = $true
        Write-SetupLog -State $State -Message "Registered installer resume after reboot through HKCU RunOnce."
    } catch {
        Add-SetupWarning -State $State -Message "Could not register installer resume after reboot: $($_.Exception.Message)"
    }
}

function Get-PayloadRoots {
    param([Parameter(Mandatory = $true)]$State)
    $roots = @()
    if ($State.mediaDir) {
        $roots += (Join-Path $State.mediaDir "payload")
    }
    if ($State.installDir) {
        $roots += (Join-Path $State.installDir "installer\payload")
    }
    $scriptPayload = Resolve-Path (Join-Path $PSScriptRoot "..\payload") -ErrorAction SilentlyContinue
    if ($scriptPayload) {
        $roots += @($scriptPayload | Select-Object -ExpandProperty Path)
    }
    return @($roots | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
}

function Find-PayloadFile {
    param([Parameter(Mandatory = $true)]$State, [string[]]$RelativeCandidates)
    foreach ($root in Get-PayloadRoots -State $State) {
        foreach ($relative in $RelativeCandidates) {
            $candidate = Join-Path $root $relative
            if (Test-Path $candidate) {
                return $candidate
            }
        }
    }
    return ""
}

function Find-ChecksumFileForPath {
    param([Parameter(Mandatory = $true)]$State, [string]$Path)
    foreach ($payloadRoot in Get-PayloadRoots -State $State) {
        $mediaRoot = Split-Path -Parent $payloadRoot
        $checksumPath = Join-Path $mediaRoot "checksums.sha256"
        if ((Test-Path $checksumPath) -and $Path.StartsWith($mediaRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $checksumPath
        }
    }
    return ""
}

function Test-MediaChecksum {
    param([Parameter(Mandatory = $true)]$State, [string]$Path)
    $checksumPath = Find-ChecksumFileForPath -State $State -Path $Path
    if (-not $checksumPath) {
        return [ordered]@{ checked = $false; ok = $false; reason = "No checksums.sha256 found for media path." }
    }
    $mediaRoot = Split-Path -Parent $checksumPath
    $relative = $Path.Substring($mediaRoot.Length).TrimStart("\", "/")
    $expected = ""
    foreach ($line in Get-Content -Path $checksumPath) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "\s+", 2
        if ($parts.Count -eq 2 -and $parts[1].Trim() -eq $relative) {
            $expected = $parts[0].Trim()
            break
        }
    }
    if (-not $expected) {
        return [ordered]@{ checked = $true; ok = $false; reason = "No checksum entry for $relative."; checksumFile = $checksumPath }
    }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
    return [ordered]@{
        checked = $true
        ok = ($actual -eq $expected.ToLowerInvariant())
        expected = $expected.ToLowerInvariant()
        actual = $actual
        checksumFile = $checksumPath
        relativePath = $relative
    }
}

function Assert-TrustedInstaller {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Component,
        [string]$ExpectedSignerPattern = "",
        [switch]$RequireMediaChecksum
    )
    if (!(Test-Path $Path)) {
        throw "$Component installer was not found: $Path"
    }
    $hash = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
    $signature = Get-AuthenticodeSignature -FilePath $Path
    $verification = [ordered]@{
        component = $Component
        path = $Path
        sha256 = $hash
        signatureStatus = [string]$signature.Status
        signer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { "" }
        checksum = Test-MediaChecksum -State $State -Path $Path
    }
    if (-not $State.Contains("installerVerification")) {
        $State["installerVerification"] = @()
    }
    $State.installerVerification = @($State.installerVerification) + $verification
    if ($RequireMediaChecksum -and -not ([bool]$verification.checksum.ok)) {
        $checksumReason = Get-SetupMapValue -Map $verification.checksum -Name "reason" -Default ""
        if ([string]::IsNullOrWhiteSpace($checksumReason)) {
            $relative = Get-SetupMapValue -Map $verification.checksum -Name "relativePath" -Default $Path
            $expected = Get-SetupMapValue -Map $verification.checksum -Name "expected" -Default ""
            $actual = Get-SetupMapValue -Map $verification.checksum -Name "actual" -Default $hash
            $checksumReason = "Checksum mismatch for $relative. Expected=$expected Actual=$actual"
        }
        throw "$Component bundled installer checksum verification failed: $checksumReason"
    }
    if ($signature.Status -ne "Valid") {
        throw "$Component installer Authenticode signature is not valid. Status=$($signature.Status) Path=$Path"
    }
    if ($ExpectedSignerPattern -and $verification.signer -notmatch $ExpectedSignerPattern) {
        throw "$Component installer signer did not match expected publisher pattern. Signer=$($verification.signer)"
    }
    Write-SetupLog -State $State -Message "$Component installer verified. SHA256=$hash Signer=$($verification.signer)"
}

function Copy-RuntimePayload {
    param([Parameter(Mandatory = $true)]$State)
    Set-InstallStepStatus -State $State -Name "runtime" -Status "running" -Message "Copying runtime payload."
    if ([string]::IsNullOrWhiteSpace($State.installDir)) {
        Add-SetupWarning -State $State -Message "InstallDir was not provided; runtime payload copy skipped."
        Set-InstallStepStatus -State $State -Name "runtime" -Status "warning" -Message "InstallDir missing."
        return
    }
    $source = Join-Path $State.installDir "hypersearch-stack"
    if (!(Test-Path $source)) {
        Add-SetupWarning -State $State -Message "Runtime source payload was not found: $source"
        Set-InstallStepStatus -State $State -Name "runtime" -Status "warning" -Message "Runtime source missing."
        return
    }
    New-Item -ItemType Directory -Force -Path $State.runtimeRoot | Out-Null
    $args = @(
        $source,
        $State.runtimeRoot,
        "/E",
        "/XD", "data", "node_modules", "target", "dist", "__pycache__", ".pytest_cache", ".docker",
        "/XF", ".env", "hypersearch.db", "hypersearch.db-shm", "hypersearch.db-wal",
        "/R:2",
        "/W:1",
        "/NFL",
        "/NDL",
        "/NP"
    )
    $copy = Invoke-SetupCommand -State $State -FilePath "robocopy.exe" -Arguments $args -Name "runtime-robocopy"
    $State.runtimeCopy = [ordered]@{
        source = $source
        destination = $State.runtimeRoot
        exitCode = $copy.ExitCode
        stdoutPath = $copy.StdoutPath
        stderrPath = $copy.StderrPath
    }
    if ($copy.ExitCode -gt 7) {
        throw "Runtime payload copy failed with robocopy exit code $($copy.ExitCode)."
    }
    Ensure-HyperSearchEnv -State $State
    Set-InstallStepStatus -State $State -Name "runtime" -Status "passed" -Message "Runtime payload ready."
}

function Set-EnvValue {
    param([Parameter(Mandatory = $true)]$State, [string]$Path, [string]$Name, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Name)) { return }
    $redacted = if ($Name -match "TOKEN|SECRET|PASSWORD|KEY") { "<redacted>" } else { $Value }
    Write-SetupLog -State $State -Message "Setting environment value. Path=$Path Name=$Name Value=$redacted" -Level "DEBUG"
    $lines = @()
    if (Test-Path $Path) {
        $lines = Get-Content -Path $Path
    } elseif (Split-Path -Parent $Path) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    }
    $found = $false
    $nextLines = @()
    foreach ($line in $lines) {
        if ($line -match "^\s*#") {
            $nextLines += $line
            continue
        }
        $parts = $line -split "=", 2
        if ($parts.Count -eq 2 -and $parts[0].Trim() -eq $Name) {
            $nextLines += "$Name=$Value"
            $found = $true
        } else {
            $nextLines += $line
        }
    }
    if (-not $found) {
        $nextLines += "$Name=$Value"
    }
    Write-Utf8NoBom -Path $Path -Value $nextLines
}

function Ensure-HyperSearchEnv {
    param([Parameter(Mandatory = $true)]$State)
    $rootEnv = Join-Path $State.runtimeRoot ".env"
    $composeEnv = Join-Path $State.runtimeRoot "infra\docker\.env"
    $version = if ($State.version) { $State.version } else { "1.1.0" }
    if (!(Test-Path $rootEnv)) {
        $template = Join-Path $State.runtimeRoot ".env.example"
        if (Test-Path $template) {
            Copy-Item -LiteralPath $template -Destination $rootEnv -Force
        } else {
            Write-Utf8NoBom -Path $rootEnv -Value @(
                "HYPERSEARCH_ENV=production",
                "HYPERSEARCH_LAN_ENABLED=false",
                "HYPERSEARCH_LLM_ENABLED=true",
                "HYPERSEARCH_PROVIDER_DEFAULT=lmstudio",
                "HYPERSEARCH_LMSTUDIO_BASE_URL=http://host.docker.internal:1234",
                "HYPERSEARCH_LMSTUDIO_MODEL=qwen2.5-7b-1m",
                "COMPOSE_PROJECT_NAME=hypersearch",
                "HYPERSEARCH_IMAGE_SOURCE=bundled"
            )
        }
    }
    if (!(Test-Path $composeEnv)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $composeEnv) | Out-Null
        Write-Utf8NoBom -Path $composeEnv -Value @(
            "COMPOSE_PROJECT_NAME=hypersearch",
            "HYPERSEARCH_BIND_HOST=127.0.0.1",
            "HYPERSEARCH_HTTP_PORT=8090",
            "HYPERSEARCH_LMSTUDIO_BASE_URL=http://host.docker.internal:1234"
        )
    }
    Set-EnvValue -State $State -Path $rootEnv -Name "HYPERSEARCH_ENV" -Value "production"
    Set-EnvValue -State $State -Path $rootEnv -Name "COMPOSE_PROJECT_NAME" -Value "hypersearch"
    Set-EnvValue -State $State -Path $rootEnv -Name "HYPERSEARCH_IMAGE_SOURCE" -Value $State.options.ImageSource
    Set-EnvValue -State $State -Path $rootEnv -Name "HYPERSEARCH_API_IMAGE" -Value "ghcr.io/nacsez/hypersearch-api:$version"
    Set-EnvValue -State $State -Path $rootEnv -Name "HYPERSEARCH_UI_IMAGE" -Value "ghcr.io/nacsez/hypersearch-ui:$version"
    Set-EnvValue -State $State -Path $composeEnv -Name "COMPOSE_PROJECT_NAME" -Value "hypersearch"
    Set-EnvValue -State $State -Path $composeEnv -Name "HYPERSEARCH_API_IMAGE" -Value "ghcr.io/nacsez/hypersearch-api:$version"
    Set-EnvValue -State $State -Path $composeEnv -Name "HYPERSEARCH_UI_IMAGE" -Value "ghcr.io/nacsez/hypersearch-ui:$version"
    Set-EnvValue -State $State -Path $composeEnv -Name "HYPERSEARCH_CADDY_IMAGE" -Value "caddy:2.11.2-alpine"
    Set-EnvValue -State $State -Path $composeEnv -Name "HYPERSEARCH_VALKEY_IMAGE" -Value "valkey/valkey:8.1.6-alpine"
    Set-EnvValue -State $State -Path $composeEnv -Name "HYPERSEARCH_SEARXNG_IMAGE" -Value "searxng/searxng:2026.4.13-ee66b070a"
    New-Item -ItemType Directory -Force -Path (Join-Path $State.runtimeRoot "data\exports") | Out-Null
    $State.env = [ordered]@{ rootEnv = $rootEnv; composeEnv = $composeEnv }
}

function Get-WslCommandPath {
    $candidates = @(
        (Join-Path $env:SystemRoot "System32\wsl.exe"),
        (Join-Path $env:SystemRoot "Sysnative\wsl.exe"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\wsl.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    $command = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { return $command.Source }
    return ""
}

function Resolve-ElevatedExecutablePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([Environment]::Is64BitOperatingSystem -and [Environment]::Is64BitProcess -and $Path -match "\\Sysnative\\") {
        $candidate = $Path -replace "\\Sysnative\\", "\System32\"
        if (Test-Path $candidate) { return $candidate }
    }
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and $Path -match "\\System32\\") {
        $candidate = $Path -replace "\\System32\\", "\Sysnative\"
        if (Test-Path $candidate) { return $candidate }
    }
    return $Path
}

function Invoke-ElevatedWsl {
    param([Parameter(Mandatory = $true)]$State, [string]$WslPath, [string[]]$Arguments, [string]$Name)
    $resolvedWslPath = Resolve-ElevatedExecutablePath -Path $WslPath
    Write-SetupLog -State $State -Message "Starting elevated WSL command: $resolvedWslPath $($Arguments -join ' ')"
    try {
        $process = Start-Process -FilePath $resolvedWslPath -ArgumentList $Arguments -Verb RunAs -Wait -PassThru
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = ""; Stderr = ""; StdoutPath = ""; StderrPath = ""; CommandPath = ""; SpawnError = ""; Error = "" }
    } catch {
        return [pscustomobject]@{ ExitCode = 9009; Stdout = ""; Stderr = ""; StdoutPath = ""; StderrPath = ""; CommandPath = ""; SpawnError = $_.Exception.Message; Error = $_.Exception.Message }
    }
}

function Invoke-WslSetupAttempt {
    param([Parameter(Mandatory = $true)]$State, [string]$WslPath, [string[]]$Arguments, [string]$Name)
    if (Test-ProcessElevated) {
        return Invoke-SetupCommand -State $State -FilePath $WslPath -Arguments $Arguments -Name $Name
    }
    return Invoke-ElevatedWsl -State $State -WslPath $WslPath -Arguments $Arguments -Name "$Name-elevated"
}

function Invoke-WslUpdateAttempt {
    param([Parameter(Mandatory = $true)]$State, [string]$WslPath, [string]$NamePrefix = "wsl")
    $update = Invoke-WslSetupAttempt -State $State -WslPath $WslPath -Arguments @("--update", "--web-download") -Name "$NamePrefix-update"
    if ($update.ExitCode -ne 0 -and "$($update.Stdout)`n$($update.Stderr)`n$($update.Error)" -match "(?i)unrecognized option.*web-download") {
        Add-SetupWarning -State $State -Message "WSL update did not support --web-download. Retrying with wsl --update."
        $update = Invoke-WslSetupAttempt -State $State -WslPath $WslPath -Arguments @("--update") -Name "$NamePrefix-update-fallback"
    }
    return $update
}

function Install-BundledWslMsi {
    param([Parameter(Mandatory = $true)]$State)
    $installer = Find-PayloadFile -State $State -RelativeCandidates @(
        "prereqs\WSL.msi",
        "prereqs\wsl.msi",
        "prereqs\wsl.x64.msi",
        "prereqs\wsl.2.7.3.0.x64.msi"
    )
    if (-not $installer) { return $null }
    Assert-TrustedInstaller -State $State -Path $installer -Component "WSL" -ExpectedSignerPattern "Microsoft Corporation" -RequireMediaChecksum
    Write-SetupLog -State $State -Message "Installing bundled WSL MSI: $installer"
    $msi = Invoke-SetupCommand -State $State -FilePath "msiexec.exe" -Arguments @("/i", $installer, "/qn", "/norestart") -Name "wsl-msi-install"
    return [pscustomobject]@{
        installerPath = $installer
        exitCode = $msi.ExitCode
        stdoutPath = $msi.StdoutPath
        stderrPath = $msi.StderrPath
        error = $msi.Error
    }
}

function Test-WslVersionSupported {
    param($CommandResult)
    if ($null -eq $CommandResult) { return $false }
    return ($CommandResult.ExitCode -eq 0 -and "$($CommandResult.Stdout)`n$($CommandResult.Stderr)" -match "(?i)WSL version")
}

function Test-WslVirtualizationBlocked {
    param([string]$StatusText)
    if ([string]::IsNullOrWhiteSpace($StatusText)) { return $false }
    return ($StatusText -match "(?i)virtualization is not enabled|enablevirtualization|WSL2 is unable to start")
}

function Test-WslServiceMissing {
    param([string]$StatusText)
    if ([string]::IsNullOrWhiteSpace($StatusText)) { return $false }
    return ($StatusText -match "(?i)Wsl/ERROR_SERVICE_DOES_NOT_EXIST|specified service does not exist as an installed service")
}

function Get-WslVirtualizationBlockedMessage {
    return "Hardware virtualization is not enabled or is not available to Windows. HyperSearch uses Docker Desktop with WSL 2, so virtualization must be enabled in BIOS/UEFI before setup can continue. Restart this computer, enter BIOS/UEFI setup, enable Intel VT-x/VT-d or AMD SVM/AMD-V, save changes, then run the HyperSearch Installation Wizard again."
}

function Ensure-WslForDocker {
    param([Parameter(Mandatory = $true)]$State)
    Set-InstallStepStatus -State $State -Name "wsl" -Status "running" -Message "Checking WSL for Docker Desktop."
    $wslPath = Get-WslCommandPath
    $State.wsl = [ordered]@{
        path = $wslPath
        versionSupported = $false
        status = $null
        version = $null
        updateAttempt = $null
        installAttempt = $null
        msiInstallAttempt = $null
        rebootPending = Test-RebootPending
        resumeRegistered = $false
    }
    if ([string]::IsNullOrWhiteSpace($wslPath)) {
        Add-SetupWarning -State $State -Message "wsl.exe was not found. Docker Desktop may install WSL prerequisites, but HyperSearch cannot verify them yet."
        Set-InstallStepStatus -State $State -Name "wsl" -Status "warning" -Message "wsl.exe not found."
        return
    }
    $version = Invoke-SetupCommand -State $State -FilePath $wslPath -Arguments @("--version") -Name "wsl-version"
    $State.wsl.version = [ordered]@{
        exitCode = $version.ExitCode
        stdoutPath = $version.StdoutPath
        stderrPath = $version.StderrPath
        stdout = $version.Stdout.Trim()
        stderr = $version.Stderr.Trim()
    }
    $State.wsl.versionSupported = Test-WslVersionSupported -CommandResult $version
    $status = Invoke-SetupCommand -State $State -FilePath $wslPath -Arguments @("--status") -Name "wsl-status"
    $State.wsl.status = [ordered]@{
        exitCode = $status.ExitCode
        stdoutPath = $status.StdoutPath
        stderrPath = $status.StderrPath
        stdout = $status.Stdout.Trim()
        stderr = $status.Stderr.Trim()
    }
    $wslStatusText = "$($status.Stdout)`n$($status.Stderr)"
    $State.wsl.virtualizationBlocked = $false
    if (-not $State.wsl.versionSupported) {
        $msiInstall = Install-BundledWslMsi -State $State
        if ($null -ne $msiInstall) {
            $State.wsl.msiInstallAttempt = [ordered]@{
                installerPath = $msiInstall.installerPath
                exitCode = $msiInstall.exitCode
                error = $msiInstall.error
            }
            if ($msiInstall.exitCode -in @(0, 3010, 1641)) {
                if ($msiInstall.exitCode -in @(3010, 1641) -or (Test-RebootPending)) {
                    Register-ResumeAfterReboot -State $State
                    Set-InstallStepStatus -State $State -Name "wsl" -Status "blocked" -Message "Bundled WSL was installed and needs a Windows restart before Docker setup can continue."
                    return
                }
                $versionAfterMsi = Invoke-SetupCommand -State $State -FilePath $wslPath -Arguments @("--version") -Name "wsl-version-after-msi"
                $State.wsl.versionAfterMsi = [ordered]@{
                    exitCode = $versionAfterMsi.ExitCode
                    stdoutPath = $versionAfterMsi.StdoutPath
                    stderrPath = $versionAfterMsi.StderrPath
                    stdout = $versionAfterMsi.Stdout.Trim()
                    stderr = $versionAfterMsi.Stderr.Trim()
                }
                $State.wsl.versionSupported = Test-WslVersionSupported -CommandResult $versionAfterMsi
            } else {
                Add-SetupWarning -State $State -Message "Bundled WSL MSI exited with code $($msiInstall.exitCode). Falling back to WSL command-line setup."
            }
        }
    }
    $wslAlreadyPresent = ($wslStatusText -match "(?i)Default Version|Kernel version|Windows Subsystem|WSL 2 kernel file is not found|wsl --update")
    if (-not $State.wsl.versionSupported -and -not $wslAlreadyPresent) {
        $installArgs = @("--install", "--no-distribution", "--web-download")
        $install = Invoke-WslSetupAttempt -State $State -WslPath $wslPath -Arguments $installArgs -Name "wsl-install-no-distribution"
        $State.wsl.installAttempt = [ordered]@{ exitCode = $install.ExitCode; error = $install.Error }
        if ($install.ExitCode -ne 0 -and "$($install.Stdout)`n$($install.Stderr)`n$($install.Error)" -match "(?i)unrecognized option.*no-distribution") {
            Add-SetupWarning -State $State -Message "This WSL version does not support --no-distribution. Retrying with WSL kernel update instead of installing a default Linux distribution."
            $update = Invoke-WslUpdateAttempt -State $State -WslPath $wslPath -NamePrefix "wsl-install-fallback"
            $State.wsl.updateAttempt = [ordered]@{ exitCode = $update.ExitCode; error = $update.Error }
        }
        if ($install.ExitCode -ne 0) {
            Add-SetupWarning -State $State -Message "WSL install/update command did not complete cleanly. Exit=$($install.ExitCode) $($install.Error)"
        }
    } else {
        $update = Invoke-WslUpdateAttempt -State $State -WslPath $wslPath -NamePrefix "wsl"
        $State.wsl.updateAttempt = [ordered]@{ exitCode = $update.ExitCode; error = $update.Error }
        if ($update.ExitCode -ne 0) {
            Add-SetupWarning -State $State -Message "WSL update returned exit code $($update.ExitCode). Docker Desktop may still be able to initialize after restart."
        }
    }
    if (-not $State.wsl.versionSupported) {
        $versionAfterSetup = Invoke-SetupCommand -State $State -FilePath $wslPath -Arguments @("--version") -Name "wsl-version-after-setup"
        $State.wsl.versionAfterSetup = [ordered]@{
            exitCode = $versionAfterSetup.ExitCode
            stdoutPath = $versionAfterSetup.StdoutPath
            stderrPath = $versionAfterSetup.StderrPath
            stdout = $versionAfterSetup.Stdout.Trim()
            stderr = $versionAfterSetup.Stderr.Trim()
        }
        $State.wsl.versionSupported = Test-WslVersionSupported -CommandResult $versionAfterSetup
        if (-not $State.wsl.versionSupported -and (($State.wsl.installAttempt -and $State.wsl.installAttempt.exitCode -eq 0) -or ($State.wsl.updateAttempt -and $State.wsl.updateAttempt.exitCode -eq 0))) {
            Register-ResumeAfterReboot -State $State
            Set-InstallStepStatus -State $State -Name "wsl" -Status "blocked" -Message "WSL was installed or updated and needs a Windows restart before Docker setup can continue."
            return
        }
    }
    $State.wsl.rebootPending = Test-RebootPending
    if ($State.wsl.rebootPending) {
        Register-ResumeAfterReboot -State $State
        Set-InstallStepStatus -State $State -Name "wsl" -Status "blocked" -Message "Windows reports a reboot is pending. The wizard is registered to resume after sign-in."
        return
    }
    $statusAfterSetup = Invoke-SetupCommand -State $State -FilePath $wslPath -Arguments @("--status") -Name "wsl-status-after-setup"
    $State.wsl.statusAfterSetup = [ordered]@{
        exitCode = $statusAfterSetup.ExitCode
        stdoutPath = $statusAfterSetup.StdoutPath
        stderrPath = $statusAfterSetup.StderrPath
        stdout = $statusAfterSetup.Stdout.Trim()
        stderr = $statusAfterSetup.Stderr.Trim()
    }
    $wslStatusAfterSetupText = "$($statusAfterSetup.Stdout)`n$($statusAfterSetup.Stderr)"
    $State.wsl.virtualizationBlocked = Test-WslVirtualizationBlocked -StatusText $wslStatusAfterSetupText
    if ($State.wsl.virtualizationBlocked) {
        $message = Get-WslVirtualizationBlockedMessage
        Add-SetupWarning -State $State -Message $message
        Set-InstallStepStatus -State $State -Name "wsl" -Status "blocked" -Message $message
        return
    }
    $State.wsl.serviceMissing = Test-WslServiceMissing -StatusText $wslStatusAfterSetupText
    if ($State.wsl.serviceMissing) {
        Register-ResumeAfterReboot -State $State
        Set-InstallStepStatus -State $State -Name "wsl" -Status "blocked" -Message "WSL was installed or updated, but the WSL service is not available yet. Windows needs a restart before Docker Desktop setup can continue."
        return
    }
    if ($State.warnings.Count -gt 0 -and $State.warnings[-1] -match "WSL") {
        Set-InstallStepStatus -State $State -Name "wsl" -Status "warning" -Message "WSL checked with warnings."
    } else {
        Set-InstallStepStatus -State $State -Name "wsl" -Status "passed" -Message "WSL checked."
    }
}

function Get-KnownDockerCliCandidates {
    $candidates = @()
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe")
        $candidates += (Join-Path $env:ProgramFiles "Docker\Docker\docker.exe")
        $candidates += (Join-Path $env:ProgramFiles "DockerDesktop\resources\bin\docker.exe")
    }
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\resources\bin\docker.exe")
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\docker.exe")
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Docker\Docker\resources\bin\docker.exe")
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Docker\Docker\docker.exe")
    }
    $command = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { $candidates += $command.Source }
    return @($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
}

function Find-DockerCli {
    $candidates = @(Get-KnownDockerCliCandidates)
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return ""
}

function Find-DockerComposePlugin {
    param([string]$DockerCliPath = "")
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($DockerCliPath)) {
        $dockerBin = Split-Path -Parent $DockerCliPath
        $dockerResources = Split-Path -Parent $dockerBin
        $candidates += (Join-Path $dockerBin "docker-compose.exe")
        $candidates += (Join-Path $dockerResources "cli-plugins\docker-compose.exe")
    }
    foreach ($docker in @(Get-KnownDockerCliCandidates)) {
        $dockerBin = Split-Path -Parent $docker
        $dockerResources = Split-Path -Parent $dockerBin
        $candidates += (Join-Path $dockerBin "docker-compose.exe")
        $candidates += (Join-Path $dockerResources "cli-plugins\docker-compose.exe")
    }
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker-compose.exe")
        $candidates += (Join-Path $env:ProgramFiles "Docker\Docker\resources\cli-plugins\docker-compose.exe")
        $candidates += (Join-Path $env:ProgramFiles "DockerDesktop\resources\bin\docker-compose.exe")
        $candidates += (Join-Path $env:ProgramFiles "DockerDesktop\resources\cli-plugins\docker-compose.exe")
    }
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\resources\bin\docker-compose.exe")
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\resources\cli-plugins\docker-compose.exe")
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Docker\Docker\resources\bin\docker-compose.exe")
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Docker\Docker\resources\cli-plugins\docker-compose.exe")
    }
    $command = Get-Command docker-compose.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { $candidates += $command.Source }
    $matches = @($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
    if ($matches.Count -gt 0) { return [string]$matches[0] }
    return ""
}

function Ensure-DockerComposePluginForConfig {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$DockerConfig,
        [string]$DockerCliPath = ""
    )
    $pluginDir = Join-Path $DockerConfig "cli-plugins"
    $target = Join-Path $pluginDir "docker-compose.exe"
    if (Test-Path -LiteralPath $target) {
        $State.docker.composePluginPath = $target
        return $target
    }
    $source = Find-DockerComposePlugin -DockerCliPath $DockerCliPath
    if ([string]::IsNullOrWhiteSpace($source)) {
        $State.docker.composePluginPath = ""
        return ""
    }
    try {
        New-Item -ItemType Directory -Force -Path $pluginDir | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
        $State.docker.composePluginPath = $target
        Write-SetupLog -State $State -Message "Docker Compose CLI plugin staged for installer Docker config: $source -> $target"
        return $target
    } catch {
        Add-SetupWarning -State $State -Message "Could not stage Docker Compose CLI plugin from '$source' to '$target': $($_.Exception.Message)"
        $State.docker.composePluginPath = $source
        return $source
    }
}

function Find-DockerDesktopExe {
    $candidates = @()
    if ($env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe")
        $candidates += (Join-Path $env:ProgramFiles "DockerDesktop\Docker Desktop.exe")
    }
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\Docker Desktop.exe")
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\Docker\Docker\Docker Desktop.exe")
    }
    $matches = @($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
    if ($matches.Count -gt 0) { return [string]$matches[0] }
    return ""
}

function Test-DockerFatalOutput {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $lower = $Value.ToLowerInvariant()
    foreach ($pattern in @(
        "docker desktop is unable to start",
        "failed to connect to the docker api",
        "request returned 500 internal server error",
        "check if the daemon is running",
        "is the docker daemon running",
        "panic:",
        "indirection through nil pointer",
        "open //./pipe/docker"
    )) {
        if ($lower.Contains($pattern)) { return $true }
    }
    return $false
}

function Test-DockerDesktopOsSupported {
    param([Parameter(Mandatory = $true)]$State)
    $caption = ""
    $build = 0
    $edition = ""
    $installationType = ""
    if ($State.os.Contains("caption")) { $caption = [string]$State.os.caption }
    if ($State.os.Contains("buildNumber")) { [void][int]::TryParse([string]$State.os.buildNumber, [ref]$build) }
    if ($State.os.Contains("editionId")) { $edition = [string]$State.os.editionId }
    if ($State.os.Contains("installationType")) { $installationType = [string]$State.os.installationType }
    if ($installationType -and $installationType -ne "Client") {
        return [pscustomobject]@{
            Supported = $false
            BuildNumber = $build
            EditionId = $edition
            Reason = "Docker Desktop is supported on Windows client releases, not installation type '$installationType'."
        }
    }
    $knownClientEdition = ($edition -match "Enterprise|Professional|Education")
    if ($caption -match "Windows 10") {
        return [pscustomobject]@{
            Supported = ($build -ge 19045 -and $knownClientEdition)
            BuildNumber = $build
            EditionId = $edition
            Reason = "Docker Desktop requires Windows 10 22H2 build 19045 or newer on Pro, Enterprise, or Education."
        }
    }
    if ($caption -match "Windows 11") {
        return [pscustomobject]@{
            Supported = ($build -ge 22631 -and $knownClientEdition)
            BuildNumber = $build
            EditionId = $edition
            Reason = "Docker Desktop requires Windows 11 23H2 build 22631 or newer on Pro, Enterprise, or Education."
        }
    }
    return [pscustomobject]@{
        Supported = $false
        BuildNumber = $build
        EditionId = $edition
        Reason = "Docker Desktop supports current Windows 10/11 client releases, not '$caption'."
    }
}

function Invoke-DockerCli {
    param([Parameter(Mandatory = $true)]$State, [string[]]$Arguments, [string]$Name, [string]$WorkingDirectory = "")
    $docker = $State.docker.cliPath
    if ([string]::IsNullOrWhiteSpace($docker)) {
        $docker = Find-DockerCli
        $State.docker.cliPath = $docker
    }
    if ([string]::IsNullOrWhiteSpace($docker)) {
        return [pscustomobject]@{ ExitCode = 9009; Stdout = ""; Stderr = "docker.exe was not found"; StdoutPath = ""; StderrPath = ""; CommandPath = ""; SpawnError = "docker.exe was not found" }
    }
    $config = Join-Path $State.runtimeRoot ".docker"
    New-Item -ItemType Directory -Force -Path $config | Out-Null
    if ($Arguments.Count -gt 0 -and [string]$Arguments[0] -eq "compose") {
        Ensure-DockerComposePluginForConfig -State $State -DockerConfig $config -DockerCliPath $docker | Out-Null
    }
    return Invoke-SetupCommand -State $State -FilePath $docker -Arguments (@("--config", $config) + $Arguments) -Name $Name -WorkingDirectory $WorkingDirectory
}

function Test-DockerReadinessOnce {
    param([Parameter(Mandatory = $true)]$State)
    $version = Invoke-DockerCli -State $State -Arguments @("info", "--format", "{{.ServerVersion}}") -Name "docker-info-version"
    $combined = "$($version.Stdout)`n$($version.Stderr)"
    if ($version.ExitCode -ne 0 -or (Test-DockerFatalOutput -Value $combined) -or $version.Stdout.Trim() -notmatch '^\d+\.\d+') {
        return [pscustomobject]@{ Ready = $false; Detail = "Docker server version check failed. Exit=$($version.ExitCode) Stdout=$($version.Stdout.Trim()) Stderr=$($version.Stderr.Trim())"; Version = ""; LastCommand = $version }
    }
    $info = Invoke-DockerCli -State $State -Arguments @("info") -Name "docker-info"
    if ($info.ExitCode -ne 0 -or (Test-DockerFatalOutput -Value "$($info.Stdout)`n$($info.Stderr)")) {
        return [pscustomobject]@{ Ready = $false; Detail = "Docker info failed. Exit=$($info.ExitCode) Stderr=$($info.Stderr.Trim())"; Version = $version.Stdout.Trim(); LastCommand = $info }
    }
    $compose = Invoke-DockerCli -State $State -Arguments @("compose", "version") -Name "docker-compose-version"
    if ($compose.ExitCode -ne 0 -or (Test-DockerFatalOutput -Value "$($compose.Stdout)`n$($compose.Stderr)")) {
        return [pscustomobject]@{ Ready = $false; Detail = "Docker Compose check failed. Exit=$($compose.ExitCode) Stderr=$($compose.Stderr.Trim())"; Version = $version.Stdout.Trim(); LastCommand = $compose }
    }
    $context = Invoke-DockerCli -State $State -Arguments @("context", "show") -Name "docker-context-show"
    $pipeVisible = Test-Path "\\.\pipe\docker_engine"
    return [pscustomobject]@{
        Ready = $true
        Detail = "Docker engine and Compose are ready."
        Version = $version.Stdout.Trim()
        Compose = $compose.Stdout.Trim()
        Context = $context.Stdout.Trim()
        PipeVisible = $pipeVisible
        LastCommand = $compose
    }
}

function Get-DockerReadinessGuidance {
    param([Parameter(Mandatory = $true)][string]$Detail)
    $normalized = $Detail.ToLowerInvariant()
    if ($normalized -match "500 internal server error|api route.*docker_engine") {
        return "Docker Desktop is installed, but its backend is not accepting engine commands yet. Open Docker Desktop once and finish any first-run, license, update, or sign-in prompt, then retry setup. If this is a VM, verify virtualization and WSL are enabled."
    }
    if ($normalized -match "docker\.exe was not found") {
        return "Docker Desktop did not put docker.exe in a known install location. Install or repair Docker Desktop, then retry setup."
    }
    if ($normalized -match "pipe|daemon|docker engine|is the docker daemon running|failed to connect") {
        return "Docker Desktop is present, but the Docker engine is not running. Start Docker Desktop and wait for it to report that the engine is running, then retry setup."
    }
    return "Docker Desktop did not become ready. Start Docker Desktop, finish any prompts, verify WSL/virtualization are enabled, then retry setup."
}

function Wait-DockerReady {
    param([Parameter(Mandatory = $true)]$State, [int]$TimeoutSeconds = 480)
    $State.docker.readiness = [ordered]@{
        ready = $false
        attempts = 0
        version = ""
        compose = ""
        context = ""
        pipeVisible = $false
        lastError = ""
    }
    $desktop = Find-DockerDesktopExe
    if ($desktop) {
        $State.docker.desktopPath = $desktop
        try {
            Start-Process -FilePath $desktop -WindowStyle Hidden | Out-Null
            Write-SetupLog -State $State -Message "Docker Desktop launch requested: $desktop"
        } catch {
            Add-SetupWarning -State $State -Message "Docker Desktop launch failed: $($_.Exception.Message)"
        }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $State.docker.readiness.attempts = [int]$State.docker.readiness.attempts + 1
        $probe = Test-DockerReadinessOnce -State $State
        if ($probe.Ready) {
            $State.docker.readiness.ready = $true
            $State.docker.readiness.version = $probe.Version
            $State.docker.readiness.compose = $probe.Compose
            $State.docker.readiness.context = $probe.Context
            $State.docker.readiness.pipeVisible = $probe.PipeVisible
            return $true
        }
        $State.docker.readiness.lastError = $probe.Detail
        Write-SetupLog -State $State -Message "Docker still not ready: $($probe.Detail)" -Level "DEBUG"
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Install-OrRepairDocker {
    param([Parameter(Mandatory = $true)]$State, [bool]$ForceRepair = $false)
    Set-InstallStepStatus -State $State -Name "docker" -Status "running" -Message "Checking Docker Desktop."
    $State.docker = [ordered]@{
        installRequested = [bool]$State.options.InstallDocker
        installMode = $State.options.DockerInstallMode
        repairAttempted = $false
        installedBySetup = $false
        cliPath = Find-DockerCli
        desktopPath = Find-DockerDesktopExe
        installerPath = ""
        installerExitCode = $null
        readiness = [ordered]@{}
    }
    if (-not $State.options.InstallDocker) {
        Set-InstallStepStatus -State $State -Name "docker" -Status "warning" -Message "Docker installation was skipped by option."
        return
    }
    $installer = Find-PayloadFile -State $State -RelativeCandidates @(
        "prereqs\Docker Desktop Installer.exe",
        "prereqs\DockerDesktopInstaller.exe",
        "prereqs\DockerDesktopInstaller-HyperSearch.exe"
    )
    $needsInstall = [string]::IsNullOrWhiteSpace($State.docker.cliPath) -or [string]::IsNullOrWhiteSpace($State.docker.desktopPath)
    $osSupport = Test-DockerDesktopOsSupported -State $State
    $State.docker.osSupport = [ordered]@{
        supported = [bool]$osSupport.Supported
        buildNumber = $osSupport.BuildNumber
        editionId = $osSupport.EditionId
        reason = $osSupport.Reason
    }
    if (($needsInstall -or $ForceRepair) -and -not [bool]$osSupport.Supported) {
        Set-InstallStepStatus -State $State -Name "docker" -Status "blocked" -Message $osSupport.Reason
        return
    }
    if ($needsInstall -or $ForceRepair) {
        if (-not $installer) {
            $installer = Join-Path $env:TEMP "DockerDesktopInstaller-HyperSearch.exe"
            Write-SetupLog -State $State -Message "Downloading Docker Desktop installer."
            try {
                Invoke-WebRequest -Uri "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" -OutFile $installer -UseBasicParsing
            } catch {
                throw "Docker Desktop installer download failed: $($_.Exception.Message)"
            }
            Assert-TrustedInstaller -State $State -Path $installer -Component "Docker Desktop" -ExpectedSignerPattern "Docker Inc"
        } else {
            Assert-TrustedInstaller -State $State -Path $installer -Component "Docker Desktop" -ExpectedSignerPattern "Docker Inc" -RequireMediaChecksum
        }
        $State.docker.installerPath = $installer
        $args = @("install", "--quiet", "--accept-license", "--backend=wsl-2")
        if ($State.options.DockerInstallMode -eq "per-user") {
            $args += "--user"
        } else {
            $args += "--always-run-service"
        }
        Write-SetupLog -State $State -Message "Starting Docker Desktop installer with mode=$($State.options.DockerInstallMode)."
        if ($State.options.DockerInstallMode -eq "all-users" -and -not (Test-ProcessElevated)) {
            $process = Start-Process -FilePath $installer -ArgumentList $args -Verb RunAs -Wait -PassThru
        } else {
            $process = Start-Process -FilePath $installer -ArgumentList $args -Wait -PassThru
        }
        $State.docker.installerExitCode = $process.ExitCode
        $State.docker.installedBySetup = $needsInstall
        $State.docker.repairAttempted = $ForceRepair
        if ($process.ExitCode -ne 0) {
            Add-SetupWarning -State $State -Message "Docker Desktop installer exited with code $($process.ExitCode)."
        }
        $State.docker.cliPath = Find-DockerCli
        $State.docker.desktopPath = Find-DockerDesktopExe
    }
    $readyTimeoutSeconds = 480
    if ($State.options.PSObject.Properties["DockerReadyTimeoutSeconds"]) {
        $readyTimeoutSeconds = [Math]::Max(60, [int]$State.options.DockerReadyTimeoutSeconds)
    }
    if (Wait-DockerReady -State $State -TimeoutSeconds $readyTimeoutSeconds) {
        Set-InstallStepStatus -State $State -Name "docker" -Status "passed" -Message "Docker Desktop is ready."
        return
    }
    $readinessGuidance = Get-DockerReadinessGuidance -Detail ([string]$State.docker.readiness.lastError)
    $State.docker.readiness.guidance = $readinessGuidance
    if ($State.options.RepairDocker -and -not $State.docker.repairAttempted -and -not $needsInstall) {
        Add-SetupWarning -State $State -Message "Docker was detected but did not become ready. Attempting one repair/upgrade pass."
        Install-OrRepairDocker -State $State -ForceRepair $true
        return
    }
    if ($State.options.RepairDocker -and -not $State.docker.repairAttempted -and $needsInstall) {
        Add-SetupWarning -State $State -Message "Docker Desktop was freshly installed but did not become ready; skipping an immediate second installer pass and reporting readiness guidance."
    }
    Set-InstallStepStatus -State $State -Name "docker" -Status "blocked" -Message "Docker Desktop did not become ready. $readinessGuidance Detail: $($State.docker.readiness.lastError)"
}

function Get-BundledImageArchives {
    param([Parameter(Mandatory = $true)]$State)
    $archives = @()
    foreach ($root in Get-PayloadRoots -State $State) {
        $imageDir = Join-Path $root "images"
        if (Test-Path $imageDir) {
            $archives += Get-ChildItem -Path $imageDir -File -Include "*.tar", "*.tar.gz", "*.tgz" -Recurse
        }
    }
    return @($archives | Sort-Object FullName -Unique)
}

function Get-BundledImageDigestManifests {
    param([Parameter(Mandatory = $true)]$State)
    $manifests = @()
    foreach ($root in Get-PayloadRoots -State $State) {
        $imageDir = Join-Path $root "images"
        if (Test-Path $imageDir) {
            $manifests += Get-ChildItem -Path $imageDir -File -Filter "*.manifest.json" -Recurse
        }
    }
    return @($manifests | Sort-Object FullName -Unique)
}

function Get-ExpectedRuntimeImages {
    param([Parameter(Mandatory = $true)]$State)
    $images = @()
    $manifestRecords = @()
    foreach ($manifestPath in Get-BundledImageDigestManifests -State $State) {
        try {
            $manifest = Get-Content -Raw -Path $manifestPath.FullName | ConvertFrom-Json
            foreach ($record in @($manifest.images)) {
                if ($record.image) {
                    $manifestRecords += $record
                    $images += [string]$record.image
                }
            }
        } catch {
            Add-SetupWarning -State $State -Message "Could not parse image manifest $($manifestPath.FullName): $($_.Exception.Message)"
        }
    }
    if ($images.Count -eq 0) {
        $composeEnv = Join-Path $State.runtimeRoot "infra\docker\.env"
        $envMap = @{}
        if (Test-Path $composeEnv) {
            foreach ($line in Get-Content -Path $composeEnv) {
                if ($line -match "^\s*#" -or $line -notmatch "=") { continue }
                $parts = $line -split "=", 2
                $envMap[$parts[0].Trim()] = $parts[1].Trim()
            }
        }
        $images = @(
            $envMap["HYPERSEARCH_API_IMAGE"],
            $envMap["HYPERSEARCH_UI_IMAGE"],
            $envMap["HYPERSEARCH_CADDY_IMAGE"],
            $envMap["HYPERSEARCH_VALKEY_IMAGE"],
            $envMap["HYPERSEARCH_SEARXNG_IMAGE"]
        ) | Where-Object { $_ }
    }
    return [pscustomobject]@{
        Images = @($images | Select-Object -Unique)
        ManifestRecords = $manifestRecords
    }
}

function Test-RuntimeImagesPresent {
    param([Parameter(Mandatory = $true)]$State, [string[]]$Images)
    $verified = @()
    $missing = @()
    foreach ($image in $Images) {
        $inspect = Invoke-DockerCli -State $State -Arguments @("image", "inspect", $image, "--format", "{{.Id}}") -Name "docker-image-inspect"
        if ($inspect.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($inspect.Stdout)) {
            $verified += [ordered]@{ image = $image; imageId = $inspect.Stdout.Trim(); stdoutPath = $inspect.StdoutPath; stderrPath = $inspect.StderrPath }
        } else {
            $missing += [ordered]@{ image = $image; exitCode = $inspect.ExitCode; stderr = $inspect.Stderr.Trim(); stdoutPath = $inspect.StdoutPath; stderrPath = $inspect.StderrPath }
        }
    }
    return [pscustomobject]@{ Verified = $verified; Missing = $missing; Ok = ($missing.Count -eq 0) }
}

function Initialize-DockerImages {
    param([Parameter(Mandatory = $true)]$State)
    Set-InstallStepStatus -State $State -Name "images" -Status "running" -Message "Preparing Docker images."
    $State.imageSetup = [ordered]@{
        mode = $State.options.ImageSource
        archives = @()
        loaded = @()
        pulled = $false
        expectedImages = @()
        verifiedImages = @()
        missingImages = @()
        verified = $false
        errors = @()
    }
    if ($State.options.ImageSource -eq "skip") {
        Set-InstallStepStatus -State $State -Name "images" -Status "warning" -Message "Docker image setup skipped by option."
        return
    }
    if (-not [bool]$State.docker.readiness.ready) {
        $State.imageSetup.errors = @($State.imageSetup.errors) + "Docker engine was not ready."
        Set-InstallStepStatus -State $State -Name "images" -Status "blocked" -Message "Docker was not ready; image setup skipped."
        return
    }
    $expected = Get-ExpectedRuntimeImages -State $State
    $State.imageSetup.expectedImages = $expected.Images
    if (@($expected.Images).Count -eq 0) {
        $State.imageSetup.errors = @($State.imageSetup.errors) + "No expected Docker image references were resolved."
        Set-InstallStepStatus -State $State -Name "images" -Status "blocked" -Message "No expected Docker image references were resolved."
        return
    }
    if ($State.options.ImageSource -eq "bundled") {
        $archives = @(Get-BundledImageArchives -State $State)
        $State.imageSetup.archives = @($archives | ForEach-Object { $_.FullName })
        if ($archives.Count -eq 0) {
            $State.imageSetup.errors = @($State.imageSetup.errors) + "No bundled image archive was found."
            Set-InstallStepStatus -State $State -Name "images" -Status "blocked" -Message "Full installer image archive was not found."
            return
        }
        Set-EnvValue -State $State -Path (Join-Path $State.runtimeRoot ".env") -Name "HYPERSEARCH_IMAGE_SOURCE" -Value "bundled"
        foreach ($archive in $archives) {
            $checksum = Test-MediaChecksum -State $State -Path $archive.FullName
            if ($checksum.checked -and -not $checksum.ok) {
                $State.imageSetup.errors = @($State.imageSetup.errors) + "Checksum failed for $($archive.FullName)"
                Add-SetupWarning -State $State -Message "Docker image archive checksum failed: $($archive.FullName)"
                continue
            }
            $load = Invoke-DockerCli -State $State -Arguments @("load", "-i", $archive.FullName) -Name "docker-load"
            $State.imageSetup.loaded = @($State.imageSetup.loaded) + [ordered]@{
                path = $archive.FullName
                exitCode = $load.ExitCode
                stdoutPath = $load.StdoutPath
                stderrPath = $load.StderrPath
            }
            if ($load.ExitCode -ne 0) {
                $State.imageSetup.errors = @($State.imageSetup.errors) + "docker load failed for $($archive.FullName)"
                Add-SetupWarning -State $State -Message "docker load failed for $($archive.FullName). See $($load.StderrPath)"
            }
        }
    } elseif ($State.options.ImageSource -eq "online") {
        Set-EnvValue -State $State -Path (Join-Path $State.runtimeRoot ".env") -Name "HYPERSEARCH_IMAGE_SOURCE" -Value "online"
        $composeDir = Join-Path $State.runtimeRoot "infra\docker"
        $pull = Invoke-DockerCli -State $State -Arguments @("compose", "--ansi", "never", "--project-name", "hypersearch", "pull") -Name "docker-compose-pull" -WorkingDirectory $composeDir
        $State.imageSetup.pulled = $pull.ExitCode -eq 0
        if ($pull.ExitCode -ne 0) {
            $State.imageSetup.errors = @($State.imageSetup.errors) + "docker compose pull failed"
            Add-SetupWarning -State $State -Message "Docker image pull failed. See $($pull.StderrPath)"
        }
    }
    $present = Test-RuntimeImagesPresent -State $State -Images $expected.Images
    $State.imageSetup.verifiedImages = $present.Verified
    $State.imageSetup.missingImages = $present.Missing
    $State.imageSetup.verified = ($State.imageSetup.errors.Count -eq 0 -and $present.Ok)
    if ($State.imageSetup.verified) {
        Set-InstallStepStatus -State $State -Name "images" -Status "passed" -Message "All expected Docker images are present."
    } else {
        Set-InstallStepStatus -State $State -Name "images" -Status "blocked" -Message "Docker images are incomplete or failed verification."
    }
}

function Find-LmStudio {
    $candidates = @()
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\LM Studio\LM Studio.exe")
    }
    $candidates += "C:\Program Files\LM Studio\LM Studio.exe"
    $matches = @($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
    if ($matches.Count -gt 0) { return [string]$matches[0] }
    return ""
}

function ConvertTo-SetupExitCodeHex {
    param([AllowNull()]$ExitCode)
    if ($null -eq $ExitCode) { return "" }
    try {
        $value = [int64]$ExitCode
        if ($value -lt 0) {
            $value = 4294967296 + $value
        }
        return "0x{0:X8}" -f ([uint32]$value)
    } catch {
        return [string]$ExitCode
    }
}

function Find-LmsCli {
    $candidates = @()
    if ($env:USERPROFILE) {
        $candidates += (Join-Path $env:USERPROFILE ".lmstudio\bin\lms.exe")
        $candidates += (Join-Path $env:USERPROFILE ".cache\lm-studio\bin\lms.exe")
    }
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA "LM Studio\bin\lms.exe")
        $candidates += (Join-Path $env:LOCALAPPDATA "Programs\LM Studio\resources\app\.webpack\bin\lms.exe")
    }
    $command = Get-Command lms.exe -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { $candidates += $command.Source }
    $matches = @($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1)
    if ($matches.Count -gt 0) { return [string]$matches[0] }
    return ""
}

function Wait-LmStudioDetected {
    param([int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    do {
        $path = Find-LmStudio
        if ($path) { return $path }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return ""
}

function Invoke-LmStudioInstallerAttempt {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [string[]]$Arguments = @(),
        [string]$Name = "lmstudio-installer"
    )
    $result = Invoke-SetupCommand -State $State -FilePath $InstallerPath -Arguments $Arguments -Name $Name
    $detectedPath = Wait-LmStudioDetected -TimeoutSeconds 20
    $record = [ordered]@{
        name = $Name
        arguments = @($Arguments)
        exitCode = $result.ExitCode
        exitCodeHex = ConvertTo-SetupExitCodeHex -ExitCode $result.ExitCode
        stdoutPath = $result.StdoutPath
        stderrPath = $result.StderrPath
        commandPath = $result.CommandPath
        detectedPath = $detectedPath
    }
    $State.lmStudio.installAttempts = @($State.lmStudio.installAttempts) + $record
    return $record
}

function Install-LmStudio {
    param([Parameter(Mandatory = $true)]$State)
    Set-InstallStepStatus -State $State -Name "lmstudio" -Status "running" -Message "Checking LM Studio."
    $existing = Find-LmStudio
    $State.lmStudio = [ordered]@{
        installRequested = [bool]$State.options.InstallLmStudio
        detectedBeforeInstall = [bool]$existing
        installedBySetup = $false
        installer = ""
        installerPath = ""
        installerExitCode = $null
        installerExitCodeHex = ""
        installAttempts = @()
        path = $existing
        detectedAfterInstall = [bool]$existing
        lmsPath = ""
        lmsReady = $false
        launchAttempted = $false
        launchError = ""
        pending = $false
        pendingReason = ""
        manualAction = ""
    }
    if (-not $State.options.InstallLmStudio) {
        Set-InstallStepStatus -State $State -Name "lmstudio" -Status "warning" -Message "LM Studio setup skipped by option."
        return
    }
    if (-not $existing) {
        $bundledInstaller = Find-PayloadFile -State $State -RelativeCandidates @(
            "prereqs\LM Studio.exe",
            "prereqs\LMStudioSetup.exe",
            "prereqs\LM-Studio-Setup.exe"
        )
        if ($bundledInstaller) {
            Assert-TrustedInstaller -State $State -Path $bundledInstaller -Component "LM Studio" -ExpectedSignerPattern "LM Studio|Element|Element Labs" -RequireMediaChecksum
            $State.lmStudio.installer = "bundled"
            $State.lmStudio.installerPath = $bundledInstaller
            $attempts = @(
                [pscustomobject]@{ Name = "lmstudio-bundled-silent-current-user"; Arguments = @("/S") },
                [pscustomobject]@{ Name = "lmstudio-bundled-silent-all-users"; Arguments = @("/S", "/allusers") }
            )
            foreach ($attempt in $attempts) {
                $record = Invoke-LmStudioInstallerAttempt -State $State -InstallerPath $bundledInstaller -Arguments @($attempt.Arguments) -Name $attempt.Name
                $State.lmStudio.installerExitCode = $record.exitCode
                $State.lmStudio.installerExitCodeHex = $record.exitCodeHex
                if ($record.detectedPath) {
                    $State.lmStudio.installedBySetup = $true
                    break
                }
                if ([int]$record.exitCode -eq 0) {
                    Write-SetupLog -State $State -Message "LM Studio installer exited 0 but LM Studio was not detected yet after attempt '$($attempt.Name)'."
                } else {
                    Write-SetupLog -State $State -Level "WARN" -Message "LM Studio installer attempt '$($attempt.Name)' exited with code $($record.exitCode) ($($record.exitCodeHex)); continuing with fallback attempts before classifying setup."
                }
            }
        } elseif (Get-Command winget.exe -ErrorAction SilentlyContinue) {
            $State.lmStudio.installer = "winget"
            $winget = Invoke-SetupCommand -State $State -FilePath "winget.exe" -Arguments @(
                "install",
                "--id", "ElementLabs.LMStudio",
                "-e",
                "--silent",
                "--disable-interactivity",
                "--accept-package-agreements",
                "--accept-source-agreements"
            ) -Name "winget-lmstudio"
            $State.lmStudio.installerExitCode = $winget.ExitCode
            $State.lmStudio.installerExitCodeHex = ConvertTo-SetupExitCodeHex -ExitCode $winget.ExitCode
            $State.lmStudio.installedBySetup = $winget.ExitCode -eq 0
            if ($winget.ExitCode -ne 0) {
                Add-SetupWarning -State $State -Message "LM Studio winget install failed with exit code $($winget.ExitCode) ($($State.lmStudio.installerExitCodeHex))."
            }
        } else {
            Add-SetupWarning -State $State -Message "LM Studio installer was not bundled and winget was not available."
        }
    }
    $lmStudioPath = Find-LmStudio
    $State.lmStudio.path = $lmStudioPath
    $State.lmStudio.detectedAfterInstall = [bool]$lmStudioPath
    if ($lmStudioPath) {
        try {
            $State.lmStudio.launchAttempted = $true
            Start-Process -FilePath $lmStudioPath | Out-Null
            Write-SetupLog -State $State -Message "Launched LM Studio once so lms.exe can initialize."
        } catch {
            $State.lmStudio.launchError = $_.Exception.Message
            Add-SetupWarning -State $State -Message "Could not launch LM Studio: $($_.Exception.Message)"
        }
        $deadline = (Get-Date).AddSeconds(90)
        do {
            $lms = Find-LmsCli
            if ($lms) {
                $State.lmStudio.lmsPath = $lms
                $State.lmStudio.lmsReady = $true
                Set-InstallStepStatus -State $State -Name "lmstudio" -Status "passed" -Message "LM Studio and lms.exe detected."
                return
            }
            Start-Sleep -Seconds 3
        } while ((Get-Date) -lt $deadline)
        $State.lmStudio.pending = $true
        $State.lmStudio.pendingReason = "LM Studio was detected, but lms.exe was not ready. LM Studio may need to finish first-run initialization."
        $State.lmStudio.manualAction = "Open LM Studio once after setup, finish its first-run prompts, then use HyperSearch Operations to enable the local model provider."
        Set-InstallStepStatus -State $State -Name "lmstudio" -Status "warning" -Message "LM Studio detected, but first-run CLI setup is pending."
        return
    }
    $exitDetail = if ($null -ne $State.lmStudio.installerExitCode) { " Last installer exit code: $($State.lmStudio.installerExitCode) ($($State.lmStudio.installerExitCodeHex))." } else { "" }
    $State.lmStudio.pending = $true
    $State.lmStudio.pendingReason = "LM Studio was requested but was not detected after installer attempts.$exitDetail"
    $State.lmStudio.manualAction = "HyperSearch search is ready. To enable local model synthesis, run the LM Studio installer manually or open LM Studio after setup, then enable the provider in HyperSearch Operations."
    Add-SetupWarning -State $State -Message $State.lmStudio.pendingReason
    Set-InstallStepStatus -State $State -Name "lmstudio" -Status "warning" -Message "LM Studio setup is pending user action.$exitDetail"
}

function Get-HardwareProfile {
    param([Parameter(Mandatory = $true)]$State)
    $totalMemoryGb = 0
    try {
        $computer = Get-CimInstance Win32_ComputerSystem
        $totalMemoryGb = [math]::Round(([double]$computer.TotalPhysicalMemory / 1GB), 1)
    } catch {
        Add-SetupWarning -State $State -Message "Memory detection failed: $($_.Exception.Message)"
    }
    $gpuProfiles = @()
    try {
        $gpuProfiles = @(Get-CimInstance Win32_VideoController | Where-Object {
            $_.Name -notmatch "Microsoft Basic|Remote|Virtual" -and
            (($_.AdapterRAM -as [double]) -ge 1000000000 -or $_.Name -match "NVIDIA|GeForce|RTX|Radeon|AMD|Arc")
        } | ForEach-Object {
            $adapterRamGb = if ($_.AdapterRAM) { [math]::Round(([double]$_.AdapterRAM / 1GB), 1) } else { 0 }
            [pscustomobject]@{ name = $_.Name; adapterRamGb = $adapterRamGb }
        })
    } catch {
        Add-SetupWarning -State $State -Message "GPU detection failed: $($_.Exception.Message)"
    }
    $maxVramGb = if ($gpuProfiles.Count -gt 0) { [double](($gpuProfiles | Measure-Object adapterRamGb -Maximum).Maximum) } else { 0 }
    $State.hardware = [ordered]@{
        totalMemoryGb = $totalMemoryGb
        maxVramGb = $maxVramGb
        gpus = $gpuProfiles
    }
    return $State.hardware
}

function Resolve-SelectedModel {
    param([Parameter(Mandatory = $true)]$State)
    $selection = $State.options.SelectedModel
    $catalog = [ordered]@{
        low = "google/gemma-3-1B-it-QAT"
        standard = "qwen2.5-7b-1m"
        high = "openai/gpt-oss-20b"
    }
    if ($selection -eq "search-only") { return "" }
    if (-not [string]::IsNullOrWhiteSpace($selection) -and $selection -ne "recommended") {
        return $selection
    }
    $hardware = Get-HardwareProfile -State $State
    if ([string]::IsNullOrWhiteSpace($selection) -or $selection -eq "recommended") {
        if ([double]$hardware.totalMemoryGb -lt 8) {
            return ""
        }
        if ([double]$hardware.totalMemoryGb -ge 24 -or [double]$hardware.maxVramGb -ge 12) {
            return $catalog.high
        }
        if ([double]$hardware.totalMemoryGb -ge 12 -or [double]$hardware.maxVramGb -ge 4) {
            return $catalog.standard
        }
        return $catalog.low
    }
    return ""
}

function Find-HyperSearchDesktopExecutable {
    param([Parameter(Mandatory = $true)]$State)
    $installDir = [string]$State.options.InstallDir
    if ([string]::IsNullOrWhiteSpace($installDir)) { return "" }
    foreach ($relative in @("hypersearch-desktop.exe", "HyperSearch.exe")) {
        $candidate = Join-Path $installDir $relative
        if (Test-Path $candidate) {
            return [string](Resolve-Path $candidate).Path
        }
    }
    return ""
}

function Configure-LoginAutostart {
    param([Parameter(Mandatory = $true)]$State)
    Set-InstallStepStatus -State $State -Name "autostart" -Status "running" -Message "Configuring Windows sign-in startup."
    $runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runValueName = "HyperSearch"
    $requested = [bool](Get-SetupMapValue -Map $State.options -Name "EnableLoginAutostart" -Default $false)
    $State.loginAutostart = [ordered]@{
        requested = $requested
        registered = $false
        runKeyPath = $runKeyPath
        runValueName = $runValueName
        executablePath = ""
        commandLine = ""
        error = ""
    }

    if (-not $requested) {
        try {
            if (Test-Path $runKeyPath) {
                Remove-ItemProperty -Path $runKeyPath -Name $runValueName -ErrorAction SilentlyContinue
            }
            Set-InstallStepStatus -State $State -Name "autostart" -Status "passed" -Message "Login autostart not selected."
        } catch {
            $State.loginAutostart.error = $_.Exception.Message
            Add-SetupWarning -State $State -Message "Could not clear HyperSearch login autostart: $($_.Exception.Message)"
            Set-InstallStepStatus -State $State -Name "autostart" -Status "warning" -Message "Could not clear login autostart."
        }
        return
    }

    $exePath = Find-HyperSearchDesktopExecutable -State $State
    $State.loginAutostart.executablePath = $exePath
    if ([string]::IsNullOrWhiteSpace($exePath)) {
        $State.loginAutostart.error = "Desktop executable was not found under installDir '$($State.options.InstallDir)'."
        Add-SetupWarning -State $State -Message "Login autostart was requested, but the HyperSearch desktop executable was not found under installDir '$($State.options.InstallDir)'."
        Set-InstallStepStatus -State $State -Name "autostart" -Status "warning" -Message "Desktop executable was not available for login autostart."
        return
    }

    $commandLine = "{0} --hypersearch-autostart" -f (ConvertTo-ProcessArgument $exePath)
    $State.loginAutostart.commandLine = $commandLine
    try {
        New-Item -Path $runKeyPath -Force | Out-Null
        New-ItemProperty -Path $runKeyPath -Name $runValueName -Value $commandLine -PropertyType String -Force | Out-Null
        $registeredValue = [string](Get-ItemPropertyValue -Path $runKeyPath -Name $runValueName -ErrorAction Stop)
        if ($registeredValue -ne $commandLine) {
            throw "Registry value did not match expected command line."
        }
        $State.loginAutostart.registered = $true
        Set-InstallStepStatus -State $State -Name "autostart" -Status "passed" -Message "HyperSearch will start when this Windows user signs in."
        Write-SetupLog -State $State -Message "Registered HyperSearch login autostart: $commandLine"
    } catch {
        $State.loginAutostart.error = $_.Exception.Message
        Add-SetupWarning -State $State -Message "Could not register HyperSearch login autostart: $($_.Exception.Message)"
        Set-InstallStepStatus -State $State -Name "autostart" -Status "warning" -Message "Could not register login autostart."
    }
}

function Configure-InstallProfile {
    param([Parameter(Mandatory = $true)]$State)
    Set-InstallStepStatus -State $State -Name "profile" -Status "running" -Message "Writing HyperSearch setup profile."
    $model = Resolve-SelectedModel -State $State
    $rootEnv = Join-Path $State.runtimeRoot ".env"
    $composeEnv = Join-Path $State.runtimeRoot "infra\docker\.env"
    $lmStudioPath = Get-SetupMapValue -Map $State.lmStudio -Name "path" -Default ""
    $lmsPath = Get-SetupMapValue -Map $State.lmStudio -Name "lmsPath" -Default ""
    $lmsReady = [bool](Get-SetupMapValue -Map $State.lmStudio -Name "lmsReady" -Default $false)
    $lmStudioPending = [bool](Get-SetupMapValue -Map $State.lmStudio -Name "pending" -Default $false)
    $lmStudioPendingReason = [string](Get-SetupMapValue -Map $State.lmStudio -Name "pendingReason" -Default "")
    $lmStudioManualAction = [string](Get-SetupMapValue -Map $State.lmStudio -Name "manualAction" -Default "")
    $lmStudioInstallAttempts = @(Get-SetupMapValue -Map $State.lmStudio -Name "installAttempts" -Default @())
    $llmConfigured = -not [string]::IsNullOrWhiteSpace($model)
    $llmEnabled = $llmConfigured -and $lmsReady
    $profileMode = if ($llmEnabled) {
        "lmstudio"
    } elseif ($llmConfigured -and [bool]$State.options.InstallLmStudio) {
        "lmstudio-pending"
    } else {
        "search-only"
    }
    Set-EnvValue -State $State -Path $rootEnv -Name "HYPERSEARCH_PROVIDER_DEFAULT" -Value "lmstudio"
    Set-EnvValue -State $State -Path $rootEnv -Name "HYPERSEARCH_LLM_ENABLED" -Value $(if ($llmEnabled) { "true" } else { "false" })
    Set-EnvValue -State $State -Path $rootEnv -Name "HYPERSEARCH_RESEARCH_CAPABILITY" -Value $(if ($llmEnabled) { "" } else { "search-only" })
    Set-EnvValue -State $State -Path $rootEnv -Name "HYPERSEARCH_LMSTUDIO_BASE_URL" -Value "http://host.docker.internal:1234"
    Set-EnvValue -State $State -Path $rootEnv -Name "HYPERSEARCH_LMSTUDIO_MODEL" -Value $model
    Set-EnvValue -State $State -Path $composeEnv -Name "HYPERSEARCH_LMSTUDIO_BASE_URL" -Value "http://host.docker.internal:1234"
    $State.profile = [ordered]@{
        usagePreset = $State.options.UsagePreset
        mode = $profileMode
        model = $model
        providerBaseUrl = "http://host.docker.internal:1234"
        llmConfigured = $llmConfigured
        llmEnabled = $llmEnabled
        lmStudioPending = $lmStudioPending
        downloadModelRequested = [bool]$State.options.DownloadModel
    }
    $dockerReady = $false
    $dockerVersion = ""
    $dockerCliPath = ""
    $dockerDesktopPath = ""
    if ($State.docker.Contains("cliPath")) { $dockerCliPath = $State.docker.cliPath }
    if ($State.docker.Contains("desktopPath")) { $dockerDesktopPath = $State.docker.desktopPath }
    if ($State.docker.Contains("readiness") -and $State.docker.readiness.Contains("ready")) {
        $dockerReady = [bool]$State.docker.readiness.ready
    }
    if ($State.docker.Contains("readiness") -and $State.docker.readiness.Contains("version")) {
        $dockerVersion = $State.docker.readiness.version
    }
    $loginAutostartState = Get-SetupMapValue -Map $State -Name "loginAutostart" -Default ([ordered]@{})
    $autostartRequested = [bool](Get-SetupMapValue -Map $State.options -Name "EnableLoginAutostart" -Default $false)
    $autostartRegistered = [bool](Get-SetupMapValue -Map $loginAutostartState -Name "registered" -Default $false)
    $profileJson = [ordered]@{
        schemaVersion = 1
        product = "HyperSearch"
        version = $State.version
        createdAt = (Get-Date).ToString("o")
        installMode = $State.options.InstallMode
        package = if ($State.options.ImageSource -eq "bundled") { "Full" } else { "Custom" }
        selectedComponents = [ordered]@{
            docker = [bool]$State.options.InstallDocker
            lmStudio = [bool]$State.options.InstallLmStudio
            dockerImages = $State.options.ImageSource
            startStack = [bool]$State.options.StartStack
            loginAutostart = $autostartRequested
            modelDownload = [bool]$State.options.DownloadModel
        }
        loginAutostart = [ordered]@{
            requested = $autostartRequested
            registered = $autostartRegistered
            executablePath = [string](Get-SetupMapValue -Map $loginAutostartState -Name "executablePath" -Default "")
            commandLine = [string](Get-SetupMapValue -Map $loginAutostartState -Name "commandLine" -Default "")
            runKeyPath = [string](Get-SetupMapValue -Map $loginAutostartState -Name "runKeyPath" -Default "")
            runValueName = [string](Get-SetupMapValue -Map $loginAutostartState -Name "runValueName" -Default "")
            error = [string](Get-SetupMapValue -Map $loginAutostartState -Name "error" -Default "")
        }
        docker = [ordered]@{
            installMode = $State.options.DockerInstallMode
            cliPath = $dockerCliPath
            desktopPath = $dockerDesktopPath
            ready = $dockerReady
            version = $dockerVersion
            imageSource = $State.options.ImageSource
        }
        lmStudio = [ordered]@{
            path = $lmStudioPath
            lmsPath = $lmsPath
            lmsReady = $lmsReady
            pending = $lmStudioPending
            pendingReason = $lmStudioPendingReason
            manualAction = $lmStudioManualAction
            installer = [string](Get-SetupMapValue -Map $State.lmStudio -Name "installer" -Default "")
            installerExitCode = Get-SetupMapValue -Map $State.lmStudio -Name "installerExitCode" -Default $null
            installerExitCodeHex = [string](Get-SetupMapValue -Map $State.lmStudio -Name "installerExitCodeHex" -Default "")
            installAttempts = $lmStudioInstallAttempts
        }
        provider = [ordered]@{
            name = "lmstudio"
            baseUrl = "http://host.docker.internal:1234"
            modelId = $model
            configured = $llmConfigured
            llmEnabled = $llmEnabled
            pendingReason = $(if ($llmEnabled) { "" } else { $lmStudioPendingReason })
        }
        usagePreset = $State.options.UsagePreset
        setup = [ordered]@{
            result = $State.result
            runId = $State.runId
            logPath = $State.logPath
            summaryPath = $State.summaryPath
            commandLogDir = $State.commandLogDir
        }
    }
    Write-Utf8NoBom -Path $State.installProfilePath -Value ($profileJson | ConvertTo-Json -Depth 10)
    $llmEnabledText = if ($llmEnabled) { "true" } else { "false" }
    $researchCapability = if ($llmEnabled) { "" } else { "search-only" }
    Write-Utf8NoBom -Path $State.installProfileEnvPath -Value @(
        "HYPERSEARCH_PROVIDER_DEFAULT=lmstudio",
        "HYPERSEARCH_LMSTUDIO_BASE_URL=http://host.docker.internal:1234",
        "HYPERSEARCH_COMPOSE_LMSTUDIO_BASE_URL=http://host.docker.internal:1234",
        "HYPERSEARCH_LMSTUDIO_MODEL=$model",
        "HYPERSEARCH_LLM_ENABLED=$llmEnabledText",
        "HYPERSEARCH_RESEARCH_CAPABILITY=$researchCapability",
        "HYPERSEARCH_LOGIN_AUTOSTART_ENABLED=$($autostartRegistered.ToString().ToLowerInvariant())"
    )
    Set-InstallStepStatus -State $State -Name "profile" -Status "passed" -Message "Install profile written."
}

function Invoke-HttpProbe {
    param([string]$Url)
    try {
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 4
        return [pscustomobject]@{ ok = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500); statusCode = $response.StatusCode; error = "" }
    } catch {
        return [pscustomobject]@{ ok = $false; statusCode = 0; error = $_.Exception.Message }
    }
}

function Start-HyperSearchStack {
    param([Parameter(Mandatory = $true)]$State)
    Set-InstallStepStatus -State $State -Name "stack" -Status "running" -Message "Starting HyperSearch Docker stack."
    $State.stack = [ordered]@{
        requested = [bool]$State.options.StartStack
        started = $false
        composeUp = $null
        composePs = $null
        live = $null
        ready = $null
        appUrl = "http://127.0.0.1:8090"
    }
    if (-not $State.options.StartStack) {
        Set-InstallStepStatus -State $State -Name "stack" -Status "warning" -Message "Stack start skipped by option."
        return
    }
    if (-not [bool]$State.imageSetup.verified) {
        Set-InstallStepStatus -State $State -Name "stack" -Status "blocked" -Message "Image setup did not verify, so stack start was skipped."
        return
    }
    $composeDir = Join-Path $State.runtimeRoot "infra\docker"
    $up = Invoke-DockerCli -State $State -Arguments @("compose", "--ansi", "never", "--project-name", "hypersearch", "up", "-d") -Name "docker-compose-up" -WorkingDirectory $composeDir
    $State.stack.composeUp = [ordered]@{ exitCode = $up.ExitCode; stdoutPath = $up.StdoutPath; stderrPath = $up.StderrPath }
    if ($up.ExitCode -ne 0) {
        Set-InstallStepStatus -State $State -Name "stack" -Status "blocked" -Message "docker compose up failed. See $($up.StderrPath)"
        return
    }
    $State.stack.started = $true
    $deadline = (Get-Date).AddSeconds(120)
    do {
        $ps = Invoke-DockerCli -State $State -Arguments @("compose", "--ansi", "never", "--project-name", "hypersearch", "ps", "--format", "json") -Name "docker-compose-ps" -WorkingDirectory $composeDir
        $State.stack.composePs = [ordered]@{ exitCode = $ps.ExitCode; stdoutPath = $ps.StdoutPath; stderrPath = $ps.StderrPath }
        $live = Invoke-HttpProbe -Url "http://127.0.0.1:8090/v1/live"
        $ready = Invoke-HttpProbe -Url "http://127.0.0.1:8090/v1/ready"
        $State.stack.live = $live
        $State.stack.ready = $ready
        if ($ps.ExitCode -eq 0 -and $live.ok -and $ready.ok) {
            Set-InstallStepStatus -State $State -Name "stack" -Status "passed" -Message "HyperSearch stack is running and ready."
            return
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    $logs = Invoke-DockerCli -State $State -Arguments @("compose", "--ansi", "never", "--project-name", "hypersearch", "logs", "--tail", "260") -Name "docker-compose-logs" -WorkingDirectory $composeDir
    $State.stack.logsPath = $logs.StdoutPath
    Set-InstallStepStatus -State $State -Name "stack" -Status "blocked" -Message "Stack did not become ready. Compose logs: $($logs.StdoutPath)"
}

function Start-ModelDownload {
    param([Parameter(Mandatory = $true)]$State)
    Set-InstallStepStatus -State $State -Name "model" -Status "running" -Message "Preparing optional model download."
    $model = $State.profile.model
    $State.modelDownload = [ordered]@{
        requested = [bool]$State.options.DownloadModel
        model = $model
        started = $false
        pending = $false
        reason = ""
        logPath = ""
        scriptPath = ""
    }
    if (-not $State.options.DownloadModel -or [string]::IsNullOrWhiteSpace($model)) {
        Set-InstallStepStatus -State $State -Name "model" -Status "passed" -Message "Model download skipped."
        return
    }
    $lms = $State.lmStudio.lmsPath
    if ([string]::IsNullOrWhiteSpace($lms) -or !(Test-Path $lms)) {
        $State.modelDownload.pending = $true
        $State.modelDownload.reason = "lms.exe was not ready."
        Set-InstallStepStatus -State $State -Name "model" -Status "warning" -Message "LM Studio CLI was not ready; model download is pending."
        return
    }
    $help = Invoke-SetupCommand -State $State -FilePath $lms -Arguments @("get", "--help") -Name "lms-get-help"
    if ($help.ExitCode -ne 0 -or "$($help.Stdout)`n$($help.Stderr)" -notmatch "--yes") {
        $State.modelDownload.pending = $true
        $State.modelDownload.reason = "lms get does not advertise non-interactive --yes support."
        Set-InstallStepStatus -State $State -Name "model" -Status "warning" -Message "Model download requires LM Studio UI confirmation."
        return
    }
    $modelRunId = Get-Date -Format "yyyyMMdd-HHmmss"
    $downloadLog = Join-Path $State.logDir ("model-download-{0}.log" -f $modelRunId)
    $downloadScript = Join-Path $State.logDir ("model-download-{0}.ps1" -f $modelRunId)
    $lmsLiteral = "'" + $lms.Replace("'", "''") + "'"
    $modelLiteral = "'" + $model.Replace("'", "''") + "'"
    $logLiteral = "'" + $downloadLog.Replace("'", "''") + "'"
    Write-Utf8NoBom -Path $downloadScript -Value @(
        '$ErrorActionPreference = "Continue"',
        '$ProgressPreference = "SilentlyContinue"',
        "function Write-ModelLog { param([string]`$Message) Add-Content -Path $logLiteral -Value (`"[{0}] {1}`" -f (Get-Date -Format `"yyyy-MM-dd HH:mm:ss`"), `$Message) }",
        "Write-ModelLog `"Starting lms get $model`"",
        "& $lmsLiteral get $modelLiteral --yes *>> $logLiteral",
        'Write-ModelLog ("lms get exit code: {0}" -f $LASTEXITCODE)',
        "Write-ModelLog `"Starting lms load $model`"",
        "& $lmsLiteral load $modelLiteral --identifier $modelLiteral *>> $logLiteral",
        'Write-ModelLog ("lms load exit code: {0}" -f $LASTEXITCODE)',
        'Write-ModelLog "Starting lms server start"',
        "& $lmsLiteral server start *>> $logLiteral",
        'Write-ModelLog ("lms server start exit code: {0}" -f $LASTEXITCODE)'
    )
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $downloadScript) -WindowStyle Hidden | Out-Null
    $State.modelDownload.started = $true
    $State.modelDownload.logPath = $downloadLog
    $State.modelDownload.scriptPath = $downloadScript
    Set-InstallStepStatus -State $State -Name "model" -Status "passed" -Message "Model download started in the background."
}

function Write-InstallerDiagnosticBundle {
    param([Parameter(Mandatory = $true)]$State)
    Set-InstallStepStatus -State $State -Name "diagnostics" -Status "running" -Message "Writing installer diagnostics bundle."
    $target = Join-Path $State.diagnosticsDir ("installer-diagnostics-{0}" -f $State.runId)
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    foreach ($path in @($State.logPath, $State.transcriptPath, $State.summaryPath)) {
        if ($path -and (Test-Path $path)) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $target (Split-Path -Leaf $path)) -Force
        }
    }
    if (Test-Path $State.commandLogDir) {
        Copy-Item -LiteralPath $State.commandLogDir -Destination (Join-Path $target "commands") -Recurse -Force
    }
    $dockerLogTarget = Join-Path $target "docker-installer-logs"
    New-Item -ItemType Directory -Force -Path $dockerLogTarget | Out-Null
    $dockerLogRoots = @(
        (Join-Path $env:LOCALAPPDATA "Docker\log"),
        (Join-Path $env:LOCALAPPDATA "Docker Desktop Installer"),
        (Join-Path $env:ProgramData "DockerDesktop"),
        (Join-Path $env:ProgramData "Docker")
    )
    foreach ($root in $dockerLogRoots) {
        if ([string]::IsNullOrWhiteSpace($root) -or !(Test-Path $root)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "(?i)log|install|setup|docker" } | Select-Object -First 80)) {
            $safeName = ($file.FullName -replace "^[A-Za-z]:\\", "" -replace "[\\/:*?`"<>|]", "_")
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dockerLogTarget $safeName) -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($envPath in @((Join-Path $State.runtimeRoot ".env"), (Join-Path $State.runtimeRoot "infra\docker\.env"), $State.installProfileEnvPath)) {
        if (Test-Path $envPath) {
            Write-Utf8NoBom -Path (Join-Path $target ((Split-Path -Leaf $envPath) + ".redacted.txt")) -Value (Redact-SetupText -Value (Get-Content -Raw -Path $envPath))
        }
    }
    if (Test-Path $State.installProfilePath) {
        Write-Utf8NoBom -Path (Join-Path $target "install-profile.redacted.json") -Value (Redact-SetupText -Value (Get-Content -Raw -Path $State.installProfilePath))
    }
    Write-Utf8NoBom -Path (Join-Path $target "README.txt") -Value "HyperSearch installer diagnostics. Secret-bearing values are redacted from copied env/profile files.`r`n"
    $State.diagnostics.bundlePath = $target
    Set-InstallStepStatus -State $State -Name "diagnostics" -Status "passed" -Message "Diagnostics bundle written: $target"
}

function Invoke-HyperSearchInstallation {
    param([Parameter(Mandatory = $true)]$Options)
    $State = Initialize-HyperSearchInstallState -Options $Options
    try {
        Write-SetupLog -State $State -Message "HyperSearch Installation Wizard core started. RunId=$($State.runId)"
        Initialize-SystemSnapshot -State $State
        Copy-RuntimePayload -State $State
        $deferUntilResume = $false
        $blockedBeforeDocker = $false
        $prereqBlockMessage = ""
        if ($State.options.InstallDocker) {
            Ensure-WslForDocker -State $State
            if ($State.steps.wsl.status -ne "blocked") {
                Install-OrRepairDocker -State $State
                if ($State.steps.docker.status -ne "blocked") {
                    Initialize-DockerImages -State $State
                } else {
                    Set-InstallStepStatus -State $State -Name "images" -Status "blocked" -Message "Docker was not ready."
                }
            } else {
                $prereqBlockMessage = $State.steps.wsl.message
                if ([string]::IsNullOrWhiteSpace($prereqBlockMessage)) {
                    $prereqBlockMessage = "WSL setup blocked Docker setup."
                }
                Set-InstallStepStatus -State $State -Name "docker" -Status "blocked" -Message $prereqBlockMessage
                Set-InstallStepStatus -State $State -Name "images" -Status "blocked" -Message $prereqBlockMessage
                $deferUntilResume = [bool]$State.wsl.resumeRegistered
                $blockedBeforeDocker = -not $deferUntilResume
            }
        } else {
            Set-InstallStepStatus -State $State -Name "wsl" -Status "warning" -Message "WSL setup skipped because Docker installation was skipped."
            Install-OrRepairDocker -State $State
            Initialize-DockerImages -State $State
        }
        if ($deferUntilResume -or $blockedBeforeDocker) {
            if ($State.options.InstallLmStudio) {
                $lmStudioMessage = if ($deferUntilResume) { "LM Studio setup deferred until WSL reboot resume." } else { "LM Studio setup skipped because prerequisite setup is blocked." }
                Set-InstallStepStatus -State $State -Name "lmstudio" -Status "blocked" -Message $lmStudioMessage
            } else {
                Set-InstallStepStatus -State $State -Name "lmstudio" -Status "warning" -Message "LM Studio setup skipped by option."
            }
            Configure-LoginAutostart -State $State
            Configure-InstallProfile -State $State
            $stackMessage = if ($deferUntilResume) { "Stack startup deferred until WSL reboot resume." } else { $prereqBlockMessage }
            $modelMessage = if ($deferUntilResume) { "Model setup deferred until WSL reboot resume." } else { "Model setup skipped because prerequisite setup is blocked." }
            Set-InstallStepStatus -State $State -Name "stack" -Status "blocked" -Message $stackMessage
            Set-InstallStepStatus -State $State -Name "model" -Status "warning" -Message $modelMessage
        } else {
            Install-LmStudio -State $State
            Configure-LoginAutostart -State $State
            Configure-InstallProfile -State $State
            if (-not $State.options.StartStack) {
                Start-HyperSearchStack -State $State
            } elseif ($State.steps.images.status -eq "passed") {
                Start-HyperSearchStack -State $State
            } else {
                Set-InstallStepStatus -State $State -Name "stack" -Status "blocked" -Message "Image setup did not pass."
            }
            Start-ModelDownload -State $State
        }
    } catch {
        Add-SetupError -State $State -Message "Setup failed: $($_.Exception.Message)"
        Add-SetupError -State $State -Message ($_ | Format-List * -Force | Out-String)
    } finally {
        Write-SetupSummary -State $State
        Write-InstallerDiagnosticBundle -State $State
        Write-SetupSummary -State $State
        Stop-SetupTranscript -State $State
    }
    return $State
}

function Invoke-HyperSearchModelDownloadOnly {
    param([string]$InstallDir = "", [string]$MediaDir = "", [string]$ModelId = "", [string]$ModelLabel = "")
    $options = New-HyperSearchInstallerOptions -InstallDir $InstallDir -MediaDir $MediaDir -InstallDocker:$false -InstallLmStudio:$false -ImageSource "skip" -StartStack:$false -SelectedModel $ModelId -DownloadModel:$true
    $state = Initialize-HyperSearchInstallState -Options $options
    try {
        $state.profile = [ordered]@{ model = $ModelId; modelLabel = $ModelLabel }
        $state.lmStudio = [ordered]@{ lmsPath = Find-LmsCli; lmsReady = [bool](Find-LmsCli); path = Find-LmStudio }
        Start-ModelDownload -State $state
    } catch {
        Add-SetupError -State $state -Message "Model download helper failed: $($_.Exception.Message)"
    } finally {
        Write-SetupSummary -State $state
        Stop-SetupTranscript -State $state
    }
    return $state
}
