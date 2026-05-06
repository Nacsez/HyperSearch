param(
    [string]$InstallDir = "",
    [string]$MediaDir = "",
    [switch]$DownloadModelOnly,
    [string]$ModelId = "",
    [string]$ModelLabel = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Add-Type -AssemblyName System.Windows.Forms

$dataRoot = Join-Path $env:LOCALAPPDATA "HyperSearch"
$runtimeRoot = Join-Path $dataRoot "runtime"
$logDir = Join-Path $dataRoot "logs"
$commandLogDir = Join-Path $logDir "commands"
$searchOnlyMemoryThresholdGb = 12
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
New-Item -ItemType Directory -Force -Path $commandLogDir | Out-Null
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$logPath = Join-Path $logDir ("installer-{0}.log" -f $runId)
$transcriptPath = Join-Path $logDir ("installer-transcript-{0}.log" -f $runId)
$summaryPath = Join-Path $logDir ("setup-summary-{0}.json" -f $runId)
$script:transcriptStarted = $false
$script:setupState = [ordered]@{
    runId = $runId
    startedAt = (Get-Date).ToString("o")
    completedAt = ""
    installDir = $InstallDir
    mediaDir = $MediaDir
    dataRoot = $dataRoot
    runtimeRoot = $runtimeRoot
    logPath = $logPath
    transcriptPath = $transcriptPath
    summaryPath = $summaryPath
    downloadModelOnly = [bool]$DownloadModelOnly
    runtimeCopy = [ordered]@{}
    docker = [ordered]@{}
    lmStudio = [ordered]@{}
    hardware = $null
    imageSetup = [ordered]@{}
    profile = [ordered]@{}
    modelDownload = [ordered]@{}
    warnings = @()
    errors = @()
}

function Write-SetupLog {
    param(
        [string]$Message,
        [ValidateSet("DEBUG", "INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message
    Add-Content -Path $logPath -Value $line
    Write-Output $line
}

function Add-SetupWarning {
    param([string]$Message)
    $script:setupState["warnings"] = @($script:setupState["warnings"]) + $Message
    Write-SetupLog $Message "WARN"
}

function Add-SetupError {
    param([string]$Message)
    $script:setupState["errors"] = @($script:setupState["errors"]) + $Message
    Write-SetupLog $Message "ERROR"
}

function Initialize-SetupLogging {
    try {
        Start-Transcript -Path $transcriptPath -Force | Out-Null
        $script:transcriptStarted = $true
    } catch {
        Add-SetupWarning "Failed to start setup transcript: $($_.Exception.Message)"
    }

    Write-SetupLog "HyperSearch prerequisite setup logging initialized. RunId=$runId"
    Write-SetupLog "InstallDir=$InstallDir"
    Write-SetupLog "MediaDir=$MediaDir"
    Write-SetupLog "DataRoot=$dataRoot"
    Write-SetupLog "RuntimeRoot=$runtimeRoot"
    Write-SetupLog "LogPath=$logPath"
    Write-SetupLog "TranscriptPath=$transcriptPath"
    Write-SetupLog "SummaryPath=$summaryPath"

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Write-SetupLog "Process user=$($identity.Name); elevated=$isAdmin"
        $script:setupState["process"] = [ordered]@{
            user = $identity.Name
            elevated = $isAdmin
            powershell = $PSVersionTable.PSVersion.ToString()
            pid = $PID
        }
    } catch {
        Add-SetupWarning "Failed to capture process identity: $($_.Exception.Message)"
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Write-SetupLog "OS=$($os.Caption) $($os.Version) build $($os.BuildNumber)"
        $script:setupState["os"] = [ordered]@{
            caption = $os.Caption
            version = $os.Version
            buildNumber = $os.BuildNumber
            architecture = $os.OSArchitecture
        }
    } catch {
        Add-SetupWarning "Failed to capture OS details: $($_.Exception.Message)"
    }
}

function Invoke-SetupCommand {
    param(
        [Parameter(Mandatory=$true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$Name = ""
    )
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = [IO.Path]::GetFileNameWithoutExtension($FilePath)
    }
    $safeName = ($Name -replace '[^a-zA-Z0-9._-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = "command"
    }
    $commandRunId = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $stdoutPath = Join-Path $commandLogDir "$commandRunId-$safeName.stdout.log"
    $stderrPath = Join-Path $commandLogDir "$commandRunId-$safeName.stderr.log"
    $commandPath = Join-Path $commandLogDir "$commandRunId-$safeName.command.log"
    $started = Get-Date
    Write-SetupLog "Command start: $FilePath $($Arguments -join ' ')"
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $finished = Get-Date
    $stdout = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw } else { "" }
    $stderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw } else { "" }
    Set-Content -Path $commandPath -Encoding UTF8 -Value @(
        "startedAt=$($started.ToString("o"))",
        "finishedAt=$($finished.ToString("o"))",
        "durationMs=$([int](New-TimeSpan -Start $started -End $finished).TotalMilliseconds)",
        "exitCode=$($process.ExitCode)",
        "filePath=$FilePath",
        "arguments=$($Arguments -join ' ')",
        "stdoutPath=$stdoutPath",
        "stderrPath=$stderrPath"
    )
    Write-SetupLog "Command complete: $FilePath exit=$($process.ExitCode) stdout=$stdoutPath stderr=$stderrPath"
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
        StdoutPath = $stdoutPath
        StderrPath = $stderrPath
        CommandPath = $commandPath
    }
}

function Get-PayloadRoots {
    $roots = @()
    if ($MediaDir) {
        $roots += (Join-Path $MediaDir "payload")
    }
    if ($InstallDir) {
        $roots += (Join-Path $InstallDir "installer\payload")
    }
    $roots += (Resolve-Path (Join-Path $PSScriptRoot "..\payload") -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path)
    return @($roots | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)
}

function Find-PayloadFile {
    param([string[]]$RelativeCandidates)
    foreach ($root in Get-PayloadRoots) {
        foreach ($relative in $RelativeCandidates) {
            $candidate = Join-Path $root $relative
            if (Test-Path $candidate) {
                return $candidate
            }
        }
    }
    return $null
}

function Write-SetupSummary {
    $script:setupState["completedAt"] = (Get-Date).ToString("o")
    try {
        ($script:setupState | ConvertTo-Json -Depth 8) | Set-Content -Path $summaryPath -Encoding UTF8
        Write-SetupLog "Setup summary written: $summaryPath"
    } catch {
        Write-SetupLog "Failed to write setup summary: $($_.Exception.Message)" "ERROR"
    }
}

function Show-YesNo {
    param(
        [string]$Title,
        [string]$Message
    )
    $result = [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    return $result -eq [System.Windows.Forms.DialogResult]::Yes
}

function Show-Info {
    param([string]$Title, [string]$Message)
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        $Title,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Find-LmStudio {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\LM Studio\LM Studio.exe"),
        "C:\Program Files\LM Studio\LM Studio.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }
    return $null
}

function Test-DockerInstalled {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        return $true
    }
    return (Test-Path "C:\Program Files\Docker\Docker\Docker Desktop.exe")
}

function Test-UsableGpu {
    try {
        $controllers = Get-CimInstance Win32_VideoController | Where-Object {
            $_.Name -notmatch "Microsoft Basic|Remote|Virtual" -and
            (($_.AdapterRAM -as [double]) -ge 3000000000 -or $_.Name -match "NVIDIA|GeForce|RTX|Radeon|AMD|Arc")
        }
        return @($controllers).Count -gt 0
    } catch {
        Add-SetupWarning "GPU detection failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-HardwareProfile {
    $totalMemoryGb = 0
    try {
        $computer = Get-CimInstance Win32_ComputerSystem
        $totalMemoryGb = [math]::Round(([double]$computer.TotalPhysicalMemory / 1GB), 1)
    } catch {
        Add-SetupWarning "Memory detection failed: $($_.Exception.Message)"
    }

    $gpuControllers = @()
    try {
        $gpuControllers = @(
            Get-CimInstance Win32_VideoController | Where-Object {
                $_.Name -notmatch "Microsoft Basic|Remote|Virtual" -and
                (($_.AdapterRAM -as [double]) -ge 3000000000 -or $_.Name -match "NVIDIA|GeForce|RTX|Radeon|AMD|Arc")
            }
        )
    } catch {
        Add-SetupWarning "GPU detection failed: $($_.Exception.Message)"
    }

    $hasGpu = $gpuControllers.Count -gt 0
    $gpuName = if ($hasGpu) { ($gpuControllers | Select-Object -First 1).Name } else { "" }
    $gpuProfiles = @($gpuControllers | ForEach-Object {
        $adapterRamGb = 0
        if ($_.AdapterRAM) {
            $adapterRamGb = [math]::Round(([double]$_.AdapterRAM / 1GB), 1)
        }
        [pscustomobject]@{
            Name = $_.Name
            AdapterRamGb = $adapterRamGb
        }
    })
    $maxVramGb = if ($gpuProfiles.Count -gt 0) { [double](($gpuProfiles | Measure-Object AdapterRamGb -Maximum).Maximum) } else { 0 }
    $searchOnlyRecommended = ($totalMemoryGb -gt 0 -and $totalMemoryGb -lt $searchOnlyMemoryThresholdGb -and $maxVramGb -lt 6)
    Write-SetupLog "Hardware profile: RAM=${totalMemoryGb}GB, usable_gpu=$hasGpu, gpu_name=$gpuName, max_vram=${maxVramGb}GB, search_only_recommended=$searchOnlyRecommended"
    $hardware = [pscustomobject]@{
        TotalMemoryGb = $totalMemoryGb
        HasUsableGpu = $hasGpu
        GpuName = $gpuName
        MaxVramGb = $maxVramGb
        Gpus = $gpuProfiles
        SearchOnlyRecommended = $searchOnlyRecommended
    }
    $script:setupState["hardware"] = $hardware
    return $hardware
}

function Copy-RuntimePayload {
    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        Add-SetupWarning "InstallDir was not provided; runtime payload copy skipped."
        $script:setupState["runtimeCopy"] = [ordered]@{
            skipped = $true
            reason = "InstallDir was not provided"
        }
        return
    }
    $source = Join-Path $InstallDir "hypersearch-stack"
    if (!(Test-Path $source)) {
        $source = Join-Path $InstallDir "resources\hypersearch-stack"
    }
    if (!(Test-Path $source)) {
        Add-SetupWarning "Runtime payload was not found at $source"
        $script:setupState["runtimeCopy"] = [ordered]@{
            skipped = $true
            reason = "Runtime payload was not found"
            source = $source
            destination = $runtimeRoot
        }
        return
    }
    New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
    Write-SetupLog "Copying runtime payload. Source=$source Destination=$runtimeRoot"
    robocopy $source $runtimeRoot /E /XF ".env" "hypersearch.db" /XD "data" ".docker" "node_modules" "target" "dist" "__pycache__" ".pytest_cache" /NFL /NDL /NJH /NJS /NP | Out-Null
    $robocopyExitCode = $LASTEXITCODE
    $script:setupState["runtimeCopy"] = [ordered]@{
        skipped = $false
        source = $source
        destination = $runtimeRoot
        robocopyExitCode = $robocopyExitCode
    }
    if ($robocopyExitCode -le 7) {
        Write-SetupLog "Runtime payload copied to $runtimeRoot with robocopy exit code $robocopyExitCode"
    } else {
        throw "Runtime payload copy failed with robocopy exit code $robocopyExitCode"
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $runtimeRoot "data\exports") | Out-Null
    Write-SetupLog "Ensured export directory exists under runtime data."
}

function Set-EnvValue {
    param([string]$Path, [string]$Name, [string]$Value)
    $redacted = if ($Name -match "TOKEN|SECRET|PASSWORD|KEY") { "<redacted>" } else { $Value }
    Write-SetupLog "Setting environment value. Path=$Path Name=$Name Value=$redacted" "DEBUG"
    $lines = @()
    if (Test-Path $Path) {
        $lines = Get-Content -Path $Path
    }
    $found = $false
    $updated = foreach ($line in $lines) {
        if ($line -like "$Name=*") {
            $found = $true
            "$Name=$Value"
        } else {
            $line
        }
    }
    if (!$found) {
        $updated += "$Name=$Value"
    }
    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Set-Content -Path $Path -Value $updated -Encoding UTF8
}

function Ensure-HyperSearchEnv {
    $rootEnv = Join-Path $runtimeRoot ".env"
    $template = Join-Path $runtimeRoot ".env.example"
    if (!(Test-Path $rootEnv)) {
        if (Test-Path $template) {
            Copy-Item $template $rootEnv
            Write-SetupLog "Created runtime .env from template: $template"
        } else {
            Set-Content -Path $rootEnv -Value @(
                "HYPERSEARCH_ENV=production",
                "HYPERSEARCH_LAN_ENABLED=false",
                "HYPERSEARCH_PROVIDER_DEFAULT=lmstudio",
                "HYPERSEARCH_LMSTUDIO_BASE_URL=http://host.docker.internal:1234",
                "HYPERSEARCH_LMSTUDIO_MODEL=qwen2.5-7b-instruct",
                "COMPOSE_PROJECT_NAME=hypersearch",
                "HYPERSEARCH_API_IMAGE=ghcr.io/nacsez/hypersearch-api:1.0.0",
                "HYPERSEARCH_UI_IMAGE=ghcr.io/nacsez/hypersearch-ui:1.0.0",
                "HYPERSEARCH_IMAGE_SOURCE=online",
                "HYPERSEARCH_PRIMARY_REGISTRY=ghcr.io/nacsez",
                "HYPERSEARCH_FALLBACK_REGISTRY=docker.io/nacsez"
            ) -Encoding UTF8
            Write-SetupLog "Created runtime .env from built-in defaults."
        }
    } else {
        Write-SetupLog "Runtime .env already exists; preserving existing user configuration."
    }
    $composeEnv = Join-Path $runtimeRoot "infra\docker\.env"
    if (!(Test-Path $composeEnv)) {
        Set-Content -Path $composeEnv -Value @(
            "COMPOSE_PROJECT_NAME=hypersearch",
            "HYPERSEARCH_BIND_HOST=127.0.0.1",
            "HYPERSEARCH_HTTP_PORT=8090",
            "HYPERSEARCH_LMSTUDIO_BASE_URL=http://host.docker.internal:1234",
            "HYPERSEARCH_API_IMAGE=ghcr.io/nacsez/hypersearch-api:1.0.0",
            "HYPERSEARCH_UI_IMAGE=ghcr.io/nacsez/hypersearch-ui:1.0.0",
            "HYPERSEARCH_SEARXNG_IMAGE=searxng/searxng:latest"
        ) -Encoding UTF8
        Write-SetupLog "Created Docker Compose .env from built-in defaults."
    } else {
        Write-SetupLog "Docker Compose .env already exists; preserving existing user configuration."
    }
    Set-EnvValue -Path $composeEnv -Name "COMPOSE_PROJECT_NAME" -Value "hypersearch"
    Set-EnvValue -Path $composeEnv -Name "HYPERSEARCH_API_IMAGE" -Value "ghcr.io/nacsez/hypersearch-api:1.0.0"
    Set-EnvValue -Path $composeEnv -Name "HYPERSEARCH_UI_IMAGE" -Value "ghcr.io/nacsez/hypersearch-ui:1.0.0"
    Set-EnvValue -Path $rootEnv -Name "COMPOSE_PROJECT_NAME" -Value "hypersearch"
    Set-EnvValue -Path $rootEnv -Name "HYPERSEARCH_API_IMAGE" -Value "ghcr.io/nacsez/hypersearch-api:1.0.0"
    Set-EnvValue -Path $rootEnv -Name "HYPERSEARCH_UI_IMAGE" -Value "ghcr.io/nacsez/hypersearch-ui:1.0.0"
    New-Item -ItemType Directory -Force -Path (Join-Path $runtimeRoot "data\exports") | Out-Null
}

function Configure-Model {
    param([string]$SelectedModel)
    if ([string]::IsNullOrWhiteSpace($SelectedModel)) {
        return
    }
    $rootEnv = Join-Path $runtimeRoot ".env"
    $composeEnv = Join-Path $runtimeRoot "infra\docker\.env"
    Set-EnvValue -Path $rootEnv -Name "HYPERSEARCH_PROVIDER_DEFAULT" -Value "lmstudio"
    Set-EnvValue -Path $rootEnv -Name "HYPERSEARCH_LMSTUDIO_BASE_URL" -Value "http://host.docker.internal:1234"
    Set-EnvValue -Path $rootEnv -Name "HYPERSEARCH_LMSTUDIO_MODEL" -Value $SelectedModel
    Set-EnvValue -Path $composeEnv -Name "HYPERSEARCH_LMSTUDIO_BASE_URL" -Value "http://host.docker.internal:1234"
    Set-Content -Path (Join-Path $dataRoot "install-profile.env") -Value @(
        "HYPERSEARCH_PROVIDER_DEFAULT=lmstudio",
        "HYPERSEARCH_LMSTUDIO_BASE_URL=http://host.docker.internal:1234",
        "HYPERSEARCH_COMPOSE_LMSTUDIO_BASE_URL=http://host.docker.internal:1234",
        "HYPERSEARCH_LMSTUDIO_MODEL=$SelectedModel"
    ) -Encoding UTF8
    $script:setupState["profile"] = [ordered]@{
        mode = "lmstudio"
        baseUrl = "http://host.docker.internal:1234"
        model = $SelectedModel
        profilePath = (Join-Path $dataRoot "install-profile.env")
    }
    Write-SetupLog "Configured LM Studio model: $SelectedModel"
}

function Configure-SearchOnly {
    param([string]$Reason)
    $rootEnv = Join-Path $runtimeRoot ".env"
    $composeEnv = Join-Path $runtimeRoot "infra\docker\.env"
    Set-EnvValue -Path $rootEnv -Name "HYPERSEARCH_PROVIDER_DEFAULT" -Value "lmstudio"
    Set-EnvValue -Path $rootEnv -Name "HYPERSEARCH_LMSTUDIO_BASE_URL" -Value "http://host.docker.internal:1234"
    Set-EnvValue -Path $rootEnv -Name "HYPERSEARCH_LMSTUDIO_MODEL" -Value ""
    Set-EnvValue -Path $composeEnv -Name "HYPERSEARCH_LMSTUDIO_BASE_URL" -Value "http://host.docker.internal:1234"
    Set-Content -Path (Join-Path $dataRoot "install-profile.env") -Value @(
        "HYPERSEARCH_PROVIDER_DEFAULT=lmstudio",
        "HYPERSEARCH_LMSTUDIO_BASE_URL=http://host.docker.internal:1234",
        "HYPERSEARCH_COMPOSE_LMSTUDIO_BASE_URL=http://host.docker.internal:1234",
        "HYPERSEARCH_LMSTUDIO_MODEL=",
        "HYPERSEARCH_RESEARCH_CAPABILITY=search-only",
        "HYPERSEARCH_INSTALL_PROFILE_REASON=$Reason"
    ) -Encoding UTF8
    $script:setupState["profile"] = [ordered]@{
        mode = "search-only"
        baseUrl = "http://host.docker.internal:1234"
        model = ""
        reason = $Reason
        profilePath = (Join-Path $dataRoot "install-profile.env")
    }
    Write-SetupLog "Configured search-only install profile. Reason: $Reason"
}

function Install-Docker {
    if (Test-DockerInstalled) {
        $dockerVersion = ""
        try {
            $dockerVersion = (& docker --version 2>&1 | Out-String).Trim()
        } catch {
            $dockerVersion = "Docker command was not callable yet: $($_.Exception.Message)"
        }
        $script:setupState["docker"] = [ordered]@{
            detectedBeforeInstall = $true
            installedBySetup = $false
            version = $dockerVersion
        }
        Write-SetupLog "Docker Desktop is already installed."
        Write-SetupLog "Docker version detail: $dockerVersion"
        return
    }
    $script:setupState["docker"]["detectedBeforeInstall"] = $false
    $install = Show-YesNo `
        -Title "Install Docker Desktop" `
        -Message "HyperSearch needs Docker Desktop to run its local search stack. Download and install Docker Desktop now? This may show a Windows administrator prompt."
    if (!$install) {
        $script:setupState["docker"]["installedBySetup"] = $false
        $script:setupState["docker"]["userSkipped"] = $true
        Add-SetupWarning "User skipped Docker Desktop installation."
        Show-Info "Docker Desktop Required" "HyperSearch was installed, but it will not run the local stack until Docker Desktop is installed."
        return
    }
    $url = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
    $bundledInstaller = Find-PayloadFile -RelativeCandidates @(
        "prereqs\Docker Desktop Installer.exe",
        "prereqs\DockerDesktopInstaller.exe",
        "prereqs\DockerDesktopInstaller-HyperSearch.exe"
    )
    if ($bundledInstaller) {
        $installer = $bundledInstaller
        Write-SetupLog "Using bundled Docker Desktop installer: $installer"
    } else {
        $installer = Join-Path $env:TEMP "DockerDesktopInstaller-HyperSearch.exe"
        Write-SetupLog "Downloading Docker Desktop from $url"
        Invoke-WebRequest -Uri $url -OutFile $installer
    }
    $installerSize = if (Test-Path $installer) { (Get-Item $installer).Length } else { 0 }
    Write-SetupLog "Docker Desktop installer downloaded. Path=$installer Bytes=$installerSize"
    $script:setupState["docker"]["download"] = [ordered]@{
        url = $url
        path = $installer
        bytes = $installerSize
        bundled = [bool]$bundledInstaller
    }
    Write-SetupLog "Starting Docker Desktop installer."
    $dockerInstall = Start-Process -FilePath $installer -ArgumentList @("install", "--quiet", "--accept-license", "--backend=wsl-2", "--always-run-service") -Verb RunAs -Wait -PassThru
    $script:setupState["docker"]["installedBySetup"] = $true
    $script:setupState["docker"]["installerExitCode"] = $dockerInstall.ExitCode
    Write-SetupLog "Docker Desktop installer exited with code $($dockerInstall.ExitCode)."
    try {
        Start-Process -FilePath "C:\Program Files\Docker\Docker\Docker Desktop.exe" -WindowStyle Hidden
        $script:setupState["docker"]["launchAttempted"] = $true
        Write-SetupLog "Docker Desktop launch requested after install."
    } catch {
        $script:setupState["docker"]["launchAttempted"] = $false
        Add-SetupWarning "Docker Desktop launch after install failed: $($_.Exception.Message)"
    }
    try {
        $dockerVersion = (& docker --version 2>&1 | Out-String).Trim()
        $script:setupState["docker"]["versionAfterInstall"] = $dockerVersion
        Write-SetupLog "Docker version after installer: $dockerVersion"
    } catch {
        Add-SetupWarning "Docker command was not callable after installer: $($_.Exception.Message)"
    }
}

function Get-DockerInfoVersion {
    try {
        $result = Invoke-SetupCommand -FilePath "docker" -Arguments @("info", "--format", "{{.ServerVersion}}") -Name "docker-info-version"
        $stdout = ($result.Stdout | Out-String).Trim()
        $stderr = ($result.Stderr | Out-String).Trim()
        $fatal = $stderr -match "Docker Desktop is unable to start|failed to connect to the docker API|request returned 500 Internal Server Error|daemon is running"
        if ($result.ExitCode -eq 0 -and $stdout -match "^\d+\.\d+" -and -not $fatal) {
            return $stdout
        }
        throw "Docker engine not ready. Exit=$($result.ExitCode) Stdout=$stdout Stderr=$stderr"
    } catch {
        throw $_
    }
}

function Wait-DockerReady {
    $script:setupState["docker"]["readiness"] = [ordered]@{
        ready = $false
        version = ""
        attempts = 0
        lastError = ""
    }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        $script:setupState["docker"]["readiness"]["lastError"] = "docker command not found"
        Add-SetupWarning "Docker command is not available on PATH yet."
        return $false
    }
    try {
        $version = Get-DockerInfoVersion
        $script:setupState["docker"]["readiness"]["ready"] = $true
        $script:setupState["docker"]["readiness"]["version"] = $version
        Write-SetupLog "Docker engine is ready. Version=$version"
        return $true
    } catch {
        $script:setupState["docker"]["readiness"]["lastError"] = $_.Exception.Message
    }
    if (Test-Path "C:\Program Files\Docker\Docker\Docker Desktop.exe") {
        try {
            Start-Process -FilePath "C:\Program Files\Docker\Docker\Docker Desktop.exe" -WindowStyle Hidden
            Write-SetupLog "Docker Desktop launch requested for readiness wait."
        } catch {
            Add-SetupWarning "Docker Desktop launch during readiness wait failed: $($_.Exception.Message)"
        }
    }
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $script:setupState["docker"]["readiness"]["attempts"] = [int]$script:setupState["docker"]["readiness"]["attempts"] + 1
        try {
            $version = Get-DockerInfoVersion
            $script:setupState["docker"]["readiness"]["ready"] = $true
            $script:setupState["docker"]["readiness"]["version"] = $version
            Write-SetupLog "Docker engine became ready. Version=$version"
            return $true
        } catch {
            $script:setupState["docker"]["readiness"]["lastError"] = $_.Exception.Message
            Write-SetupLog "Docker still not ready: $($_.Exception.Message)" "DEBUG"
        }
    }
    Add-SetupWarning "Docker Desktop did not become ready during setup. Last error: $($script:setupState["docker"]["readiness"]["lastError"])"
    return $false
}

function Get-BundledImageArchives {
    $archives = @()
    foreach ($root in Get-PayloadRoots) {
        $imageDir = Join-Path $root "images"
        if (Test-Path $imageDir) {
            $archives += Get-ChildItem -Path $imageDir -File -Include "*.tar", "*.tar.gz", "*.tgz" -Recurse
        }
    }
    return @($archives | Sort-Object FullName -Unique)
}

function Initialize-DockerImages {
    $archives = @(Get-BundledImageArchives)
    $script:setupState["imageSetup"] = [ordered]@{
        mode = if ($archives.Count -gt 0) { "bundled" } else { "online" }
        archiveCount = $archives.Count
        archives = @($archives | ForEach-Object { $_.FullName })
        loaded = @()
        pulled = $false
        verified = $false
        errors = @()
    }
    if (-not (Wait-DockerReady)) {
        $script:setupState["imageSetup"]["errors"] = @($script:setupState["imageSetup"]["errors"]) + "Docker engine was not ready."
        return
    }
    if ($archives.Count -gt 0) {
        Set-EnvValue -Path (Join-Path $runtimeRoot ".env") -Name "HYPERSEARCH_IMAGE_SOURCE" -Value "bundled"
        foreach ($archive in $archives) {
            Write-SetupLog "Loading bundled Docker image archive: $($archive.FullName)"
            $load = Invoke-SetupCommand -FilePath "docker" -Arguments @("load", "-i", $archive.FullName) -Name "docker-load"
            $script:setupState["imageSetup"]["loaded"] = @($script:setupState["imageSetup"]["loaded"]) + [ordered]@{
                path = $archive.FullName
                exitCode = $load.ExitCode
                stdoutPath = $load.StdoutPath
                stderrPath = $load.StderrPath
            }
            if ($load.ExitCode -ne 0) {
                $script:setupState["imageSetup"]["errors"] = @($script:setupState["imageSetup"]["errors"]) + "docker load failed for $($archive.FullName)"
                Add-SetupWarning "docker load failed for $($archive.FullName). See $($load.StderrPath)"
            }
        }
        $script:setupState["imageSetup"]["verified"] = $true
        return
    }
    Set-EnvValue -Path (Join-Path $runtimeRoot ".env") -Name "HYPERSEARCH_IMAGE_SOURCE" -Value "online"
    $composeDir = Join-Path $runtimeRoot "infra\docker"
    if (Test-Path $composeDir) {
        Push-Location $composeDir
        try {
            $pull = Invoke-SetupCommand -FilePath "docker" -Arguments @("compose", "--ansi", "never", "--project-name", "hypersearch", "pull") -Name "docker-compose-pull"
            $script:setupState["imageSetup"]["pulled"] = $pull.ExitCode -eq 0
            $script:setupState["imageSetup"]["stdoutPath"] = $pull.StdoutPath
            $script:setupState["imageSetup"]["stderrPath"] = $pull.StderrPath
            if ($pull.ExitCode -ne 0) {
                $script:setupState["imageSetup"]["errors"] = @($script:setupState["imageSetup"]["errors"]) + "docker compose pull failed"
                Add-SetupWarning "Docker image pull failed. Check Docker DNS, proxy, VPN, firewall, or private registry access. See $($pull.StderrPath)"
            }
        } finally {
            Pop-Location
        }
    }
}

function Install-LmStudio {
    $existing = Find-LmStudio
    if ($existing) {
        $script:setupState["lmStudio"] = [ordered]@{
            detectedBeforeInstall = $true
            installedBySetup = $false
            path = $existing
        }
        Write-SetupLog "LM Studio detected at $existing"
        return $existing
    }
    $script:setupState["lmStudio"]["detectedBeforeInstall"] = $false
    $install = Show-YesNo `
        -Title "Install LM Studio" `
        -Message "HyperSearch research mode needs a local OpenAI-compatible model provider. LM Studio was not found. Download and install LM Studio now?"
    if (!$install) {
        $script:setupState["lmStudio"]["installedBySetup"] = $false
        $script:setupState["lmStudio"]["userSkipped"] = $true
        Add-SetupWarning "User skipped LM Studio installation."
        Show-Info "LM Studio Not Installed" "You can install LM Studio later or configure another local OpenAI-compatible endpoint in HyperSearch settings."
        return $null
    }
    $bundledInstaller = Find-PayloadFile -RelativeCandidates @(
        "prereqs\LM Studio.exe",
        "prereqs\LMStudioSetup.exe",
        "prereqs\LM-Studio-Setup.exe"
    )
    if ($bundledInstaller) {
        Write-SetupLog "Starting bundled LM Studio installer: $bundledInstaller"
        $lmInstall = Start-Process -FilePath $bundledInstaller -Wait -PassThru
        $script:setupState["lmStudio"]["installedBySetup"] = $true
        $script:setupState["lmStudio"]["installer"] = "bundled"
        $script:setupState["lmStudio"]["installerPath"] = $bundledInstaller
        $script:setupState["lmStudio"]["installerExitCode"] = $lmInstall.ExitCode
        Write-SetupLog "Bundled LM Studio installer exited with code $($lmInstall.ExitCode)."
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-SetupLog "Installing LM Studio with winget."
        $lmInstall = Invoke-SetupCommand -FilePath "winget" -Arguments @("install", "--id", "ElementLabs.LMStudio", "-e", "--accept-package-agreements", "--accept-source-agreements") -Name "winget-lmstudio"
        $script:setupState["lmStudio"]["installedBySetup"] = $true
        $script:setupState["lmStudio"]["installer"] = "winget"
        $script:setupState["lmStudio"]["installerExitCode"] = $lmInstall.ExitCode
        $script:setupState["lmStudio"]["stdoutPath"] = $lmInstall.StdoutPath
        $script:setupState["lmStudio"]["stderrPath"] = $lmInstall.StderrPath
        Write-SetupLog "LM Studio winget installer exited with code $($lmInstall.ExitCode). Stdout=$($lmInstall.StdoutPath) Stderr=$($lmInstall.StderrPath)"
    } else {
        $script:setupState["lmStudio"]["installedBySetup"] = $false
        $script:setupState["lmStudio"]["installer"] = "manual-download-page"
        Add-SetupWarning "winget not available; opening LM Studio download page."
        Start-Process "https://lmstudio.ai/download?os=windows"
        Show-Info "Manual LM Studio Install" "The LM Studio download page was opened. Complete installation there, then launch HyperSearch."
    }
    $detectedAfter = Find-LmStudio
    $script:setupState["lmStudio"]["pathAfterInstall"] = $detectedAfter
    if ($detectedAfter) {
        Write-SetupLog "LM Studio detected after installation at $detectedAfter"
    } else {
        Add-SetupWarning "LM Studio was not detected after the installation step."
    }
    return $detectedAfter
}

function Start-ModelDownload {
    param([string]$SelectedModel, [string]$SelectedLabel)
    if ([string]::IsNullOrWhiteSpace($SelectedModel)) {
        Write-SetupLog "Model download skipped because no model id was selected." "DEBUG"
        return
    }
    $script:setupState["modelDownload"] = [ordered]@{
        requestedModel = $SelectedModel
        requestedLabel = $SelectedLabel
        userAccepted = $false
        started = $false
    }
    $download = Show-YesNo `
        -Title "Download Local Model" `
        -Message "Start downloading $SelectedLabel in LM Studio now? The download can continue after this installer finishes."
    if (!$download) {
        $script:setupState["modelDownload"]["userAccepted"] = $false
        Write-SetupLog "User skipped model download."
        return
    }
    $script:setupState["modelDownload"]["userAccepted"] = $true
    $lmStudio = Find-LmStudio
    if ($lmStudio) {
        Write-SetupLog "Launching LM Studio before model download. Path=$lmStudio"
        Start-Process -FilePath $lmStudio | Out-Null
        Start-Sleep -Seconds 8
    } else {
        Add-SetupWarning "LM Studio executable was not found before model download attempt."
    }
    $lms = Join-Path $env:USERPROFILE ".lmstudio\bin\lms.exe"
    if (Test-Path $lms) {
        $modelRunId = Get-Date -Format "yyyyMMdd-HHmmss"
        $downloadLog = Join-Path $logDir ("model-download-{0}.log" -f $modelRunId)
        $downloadScript = Join-Path $logDir ("model-download-{0}.ps1" -f $modelRunId)
        $lmsLiteral = "'" + $lms.Replace("'", "''") + "'"
        $modelLiteral = "'" + $SelectedModel.Replace("'", "''") + "'"
        $logLiteral = "'" + $downloadLog.Replace("'", "''") + "'"
        Set-Content -Path $downloadScript -Encoding UTF8 -Value @(
            '$ErrorActionPreference = "Continue"',
            '$ProgressPreference = "SilentlyContinue"',
            "function Write-ModelLog { param([string]`$Message) Add-Content -Path $logLiteral -Value (`"[{0}] {1}`" -f (Get-Date -Format `"yyyy-MM-dd HH:mm:ss`"), `$Message) }",
            "Write-ModelLog `"Starting lms get $SelectedModel`"",
            "& $lmsLiteral get $modelLiteral *>> $logLiteral",
            'Write-ModelLog ("lms get exit code: {0}" -f $LASTEXITCODE)',
            'Write-ModelLog "Starting lms server start"',
            "& $lmsLiteral server start *>> $logLiteral",
            'Write-ModelLog ("lms server start exit code: {0}" -f $LASTEXITCODE)'
        )
        Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $downloadScript) -WindowStyle Hidden
        $script:setupState["modelDownload"]["started"] = $true
        $script:setupState["modelDownload"]["lmsPath"] = $lms
        $script:setupState["modelDownload"]["logPath"] = $downloadLog
        $script:setupState["modelDownload"]["scriptPath"] = $downloadScript
        Write-SetupLog "Started async LM Studio model download for $SelectedModel. Log: $downloadLog"
    } else {
        $script:setupState["modelDownload"]["started"] = $false
        $script:setupState["modelDownload"]["lmsPath"] = $lms
        Add-SetupWarning "lms.exe was not available; opening LM Studio for manual model download."
        Show-Info "Open LM Studio" "LM Studio is installed, but its CLI is not ready yet. LM Studio will open so you can download $SelectedLabel from the Discover tab."
    }
}

function Show-SetupResult {
    $dockerReady = $false
    if ($script:setupState["docker"].Contains("readiness")) {
        $dockerReady = [bool]$script:setupState["docker"]["readiness"]["ready"]
    }
    $imageMode = if ($script:setupState["imageSetup"].Contains("mode")) { $script:setupState["imageSetup"]["mode"] } else { "not checked" }
    $imageErrors = if ($script:setupState["imageSetup"].Contains("errors")) { @($script:setupState["imageSetup"]["errors"]) } else { @() }
    $lmStatus = if ($script:setupState["lmStudio"].Contains("pathAfterInstall") -and $script:setupState["lmStudio"]["pathAfterInstall"]) {
        "Detected: $($script:setupState["lmStudio"]["pathAfterInstall"])"
    } elseif ($script:setupState["lmStudio"].Contains("path") -and $script:setupState["lmStudio"]["path"]) {
        "Detected: $($script:setupState["lmStudio"]["path"])"
    } else {
        "Not detected"
    }
    $profileMode = if ($script:setupState["profile"].Contains("mode")) { $script:setupState["profile"]["mode"] } else { "not configured" }
    $profileModel = if ($script:setupState["profile"].Contains("model")) { $script:setupState["profile"]["model"] } else { "" }
    $message = @(
        "HyperSearch setup finished.",
        "",
        "Docker engine ready: $dockerReady",
        "Image setup mode: $imageMode",
        "Image setup issues: $(if ($imageErrors.Count) { $imageErrors -join '; ' } else { 'none recorded' })",
        "LM Studio: $lmStatus",
        "Model profile: $profileMode $profileModel",
        "Runtime: $runtimeRoot",
        "Logs: $logDir",
        "Setup summary: $summaryPath"
    ) -join "`n"
    Show-Info "HyperSearch Setup Result" $message
}

if ($DownloadModelOnly) {
    try {
        Initialize-SetupLogging
        Write-SetupLog "Running model-download-only setup helper. ModelId=$ModelId ModelLabel=$ModelLabel"
        Start-ModelDownload -SelectedModel $ModelId -SelectedLabel $ModelLabel
    } catch {
        Add-SetupError "Model-download-only helper failed: $($_.Exception.Message)"
        Add-SetupError ($_ | Format-List * -Force | Out-String)
    } finally {
        Write-SetupSummary
        if ($script:transcriptStarted) {
            try { Stop-Transcript | Out-Null } catch {}
        }
    }
    exit 0
}

try {
    Initialize-SetupLogging
    Write-SetupLog "HyperSearch prerequisite setup started."
    Copy-RuntimePayload
    Ensure-HyperSearchEnv
    Install-Docker
    Initialize-DockerImages
    $lmStudioPath = Install-LmStudio
    $hardware = Get-HardwareProfile
    if ($hardware.SearchOnlyRecommended) {
        $reason = "RAM below ${searchOnlyMemoryThresholdGb}GB and no GPU with at least 6GB adapter RAM detected"
        Configure-SearchOnly -Reason $reason
        Show-Info "HyperSearch Search-Only Setup" "This computer has $($hardware.TotalMemoryGb)GB RAM and $($hardware.MaxVramGb)GB detected adapter RAM. HyperSearch search is ready, but research synthesis will stay disabled until you choose and validate a small local model in settings."
    } elseif ($hardware.MaxVramGb -ge 16) {
        $modelId = "openai/gpt-oss-20b"
        $modelLabel = "GPT-OSS 20B"
        Configure-Model -SelectedModel $modelId
        if ($lmStudioPath) {
            Start-ModelDownload -SelectedModel $modelId -SelectedLabel $modelLabel
        }
    } else {
        $modelId = "qwen2.5-7b-instruct"
        $modelLabel = "Qwen 2.5 7B Instruct"
        Configure-Model -SelectedModel $modelId
        if ($lmStudioPath) {
            Start-ModelDownload -SelectedModel $modelId -SelectedLabel $modelLabel
        }
    }
    Write-SetupLog "HyperSearch prerequisite setup completed."
    Show-SetupResult
} catch {
    Add-SetupError "Setup failed: $($_.Exception.Message)"
    Add-SetupError ($_ | Format-List * -Force | Out-String)
    [System.Windows.Forms.MessageBox]::Show(
        "HyperSearch was installed, but prerequisite setup hit an error:`n`n$($_.Exception.Message)`n`nLog: $logPath`nSummary: $summaryPath",
        "HyperSearch Setup Warning",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
} finally {
    Write-SetupSummary
    if ($script:transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch {}
    }
}
