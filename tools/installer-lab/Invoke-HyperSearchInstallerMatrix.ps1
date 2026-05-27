[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "configs\lab.example.json"),
    [string[]]$ScenarioName = @(),
    [switch]$SkipMediaCopy,
    [switch]$KeepVmRunning
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

trap {
    Write-Host ("[FATAL] line={0} statement={1} error={2}" -f $_.InvocationInfo.ScriptLineNumber, $_.InvocationInfo.Line.Trim(), $_.Exception.Message)
    break
}

function Expand-LabPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    return [Environment]::ExpandEnvironmentVariables($Path)
}

function ConvertTo-ScalarString {
    param([AllowNull()][object]$Value)
    $current = $Value
    while ($current -is [System.Array]) {
        if ($current.Count -eq 0) { return "" }
        $current = $current[0]
    }
    if ($null -eq $current) { return "" }
    return [string]$current
}

function Write-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowNull()]$Value = "")
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    if ($Value -is [System.Array]) {
        $text = ($Value | ForEach-Object { [string]$_ }) -join "`r`n"
        if ($Value.Count -gt 0) { $text = "$text`r`n" }
    } else {
        $text = [string]$Value
    }
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

function Write-LabLog {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $encoding = [System.Text.UTF8Encoding]::new($false)
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($Path, "$line`r`n", $encoding)
            break
        } catch {
            if ($attempt -eq 12) { throw }
            Start-Sleep -Milliseconds (150 * $attempt)
        }
    }
    Write-Host $line
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Hyper-V installer matrix must be run from an elevated PowerShell session."
    }
}

function Read-LabConfig {
    param([string]$Path)
    if (!(Test-Path $Path)) { throw "Lab config was not found: $Path" }
    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function New-LabCredential {
    param($Config)
    $credentialPath = ""
    if ($Config.PSObject.Properties["guestCredentialPath"]) {
        $credentialPath = Expand-LabPath ([string]$Config.guestCredentialPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($credentialPath)) {
        if (!(Test-Path $credentialPath)) {
            throw "Guest credential file was not found: $credentialPath"
        }
        $credential = Import-Clixml -LiteralPath $credentialPath
        if ($credential -isnot [Management.Automation.PSCredential]) {
            throw "Guest credential file did not contain a PSCredential: $credentialPath"
        }
        return $credential
    }

    $user = [string]$Config.guestUser
    if ([string]::IsNullOrWhiteSpace($user)) {
        throw "Config must set guestUser when guestCredentialPath is not used."
    }
    $passwordEnv = [string]$Config.guestPasswordEnv
    if ([string]::IsNullOrWhiteSpace($passwordEnv)) {
        throw "Config must set guestPasswordEnv when guestCredentialPath is not used."
    }
    $password = [Environment]::GetEnvironmentVariable($passwordEnv)
    if ([string]::IsNullOrWhiteSpace($password)) {
        throw "Environment variable '$passwordEnv' must contain the guest password."
    }
    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    return [Management.Automation.PSCredential]::new($user, $secure)
}

function Wait-LabVmReady {
    param(
        [string]$VMName,
        [Management.Automation.PSCredential]$Credential,
        [int]$TimeoutSeconds,
        [string]$LogPath
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $result = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
                [pscustomobject]@{
                    ComputerName = $env:COMPUTERNAME
                    User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                    LocalAppData = $env:LOCALAPPDATA
                }
            } -ErrorAction Stop
            Write-LabLog -Path $LogPath -Message "PowerShell Direct ready for $VMName as $($result.User)."
            return $result
        } catch {
            Write-LabLog -Path $LogPath -Message "Waiting for PowerShell Direct on ${VMName}: $($_.Exception.Message)" -Level "DEBUG"
            Start-Sleep -Seconds 10
        }
    } while ((Get-Date) -lt $deadline)
    throw "VM '$VMName' did not become ready for PowerShell Direct within $TimeoutSeconds seconds."
}

function New-LabSession {
    param([string]$VMName, [Management.Automation.PSCredential]$Credential)
    return New-PSSession -VMName $VMName -Credential $Credential
}

function Invoke-LabGuestScript {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 3600,
        [string]$LogPath
    )
    $job = Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AsJob
    $completed = Wait-Job -Job $job -Timeout $TimeoutSeconds
    if (-not $completed) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw "Guest command timed out after $TimeoutSeconds seconds."
    }
    $output = Receive-Job -Job $job -Keep
    $state = $job.State
    $errorText = ($job.ChildJobs | ForEach-Object { $_.Error | Out-String }) -join "`n"
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    if ($state -ne "Completed") {
        if ($LogPath) { Write-LabLog -Path $LogPath -Message "Guest command state=$state error=$errorText" -Level "ERROR" }
        throw "Guest command failed with state $state. $errorText"
    }
    return $output
}

function Get-LabInstallerRunnerSupportScript {
    return @'
function Get-LabInstallerProgressSnapshot {
    param(
        [int]$RootProcessId,
        [string]$ScenarioRoot,
        [string]$StatePath,
        [datetime]$StartedAt
    )

    function Get-LabInstallerProgressProcessTreeIds {
        param([int]$RootProcessId)
        $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
        $ids = [System.Collections.ArrayList]::new()
        [void]$ids.Add($RootProcessId)
        $changed = $true
        while ($changed) {
            $changed = $false
            foreach ($process in $all) {
                if ($ids.Contains([int]$process.ParentProcessId) -and -not $ids.Contains([int]$process.ProcessId)) {
                    [void]$ids.Add([int]$process.ProcessId)
                    $changed = $true
                }
            }
        }
        return @($ids)
    }

    $startedUtc = $StartedAt.ToUniversalTime().AddMinutes(-10)
    $candidateRoots = @(
        $ScenarioRoot,
        (Join-Path $env:LOCALAPPDATA "HyperSearch"),
        (Join-Path $env:LOCALAPPDATA "Docker"),
        (Join-Path $env:LOCALAPPDATA "Docker Desktop Installer"),
        (Join-Path $env:ProgramData "DockerDesktop"),
        (Join-Path $env:TEMP "DockerDesktopInstaller")
    )

    $files = @()
    foreach ($root in $candidateRoots) {
        if ([string]::IsNullOrWhiteSpace($root) -or !(Test-Path -LiteralPath $root)) { continue }
        try {
            $files += @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -ge $startedUtc } |
                Select-Object FullName, Length, LastWriteTimeUtc)
        } catch {}
    }
    if (-not [string]::IsNullOrWhiteSpace($StatePath) -and (Test-Path -LiteralPath $StatePath)) {
        try {
            $files += @(Get-Item -LiteralPath $StatePath -ErrorAction Stop |
                Select-Object FullName, Length, LastWriteTimeUtc)
        } catch {}
    }

    $processIds = @(Get-LabInstallerProgressProcessTreeIds -RootProcessId $RootProcessId)
    $processes = @()
    foreach ($id in $processIds) {
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            $processes += [pscustomobject]@{
                Id = $p.Id
                Name = $p.ProcessName
                Cpu = if ($null -ne $p.CPU) { [math]::Round([double]$p.CPU, 3) } else { 0 }
                StartTime = try { $p.StartTime.ToString("o") } catch { "" }
            }
        } catch {}
    }

    $orderedFiles = @($files | Sort-Object FullName -Unique | Sort-Object LastWriteTimeUtc -Descending)
    $processFingerprint = (@($processes | Sort-Object Id | ForEach-Object { "{0}:{1}:{2}" -f $_.Id, $_.Name, $_.StartTime }) -join ";")
    $fileFingerprint = (@($orderedFiles | Sort-Object FullName | ForEach-Object { "{0}|{1}|{2}" -f $_.FullName, $_.Length, $_.LastWriteTimeUtc.Ticks }) -join ";")

    return [pscustomobject]@{
        CapturedAt = (Get-Date).ToString("o")
        ProcessCount = @($processes).Count
        FileCount = @($orderedFiles).Count
        NewestFile = if (@($orderedFiles).Count -gt 0) { $orderedFiles[0].FullName } else { "" }
        NewestFileWriteTime = if (@($orderedFiles).Count -gt 0) { $orderedFiles[0].LastWriteTimeUtc.ToString("o") } else { "" }
        Processes = @($processes | Sort-Object Id)
        Files = @($orderedFiles | Select-Object -First 40)
        Fingerprint = "$processFingerprint`n$fileFingerprint"
    }
}

function Get-LabInstallerFinalState {
    param([string]$StatePath)
    if ([string]::IsNullOrWhiteSpace($StatePath) -or !(Test-Path -LiteralPath $StatePath)) {
        return [pscustomobject]@{ Final = $false; Result = ""; CompletedAt = ""; Error = "" }
    }
    try {
        $state = Get-Content -Raw -LiteralPath $StatePath | ConvertFrom-Json
        $result = if ($state.PSObject.Properties["result"]) { [string]$state.result } else { "" }
        $completedAt = if ($state.PSObject.Properties["completedAt"]) { [string]$state.completedAt } else { "" }
        $final = (-not [string]::IsNullOrWhiteSpace($result) -and $result -ne "running" -and -not [string]::IsNullOrWhiteSpace($completedAt))
        return [pscustomobject]@{ Final = $final; Result = $result; CompletedAt = $completedAt; Error = "" }
    } catch {
        return [pscustomobject]@{ Final = $false; Result = ""; CompletedAt = ""; Error = $_.Exception.Message }
    }
}
'@
}

function Invoke-LabGuestDirectInstaller {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$Installer,
        [string]$MediaRoot,
        [string]$GuestScenarioRoot,
        [string]$GuestResultPath,
        [int]$TimeoutSeconds,
        [int]$ProgressPollSeconds = 30,
        [int]$NoProgressPollLimit = 0,
        [string]$LogPath
    )
    $supportScript = Get-LabInstallerRunnerSupportScript
    $launchInfo = Invoke-LabGuestScript -Session $Session -TimeoutSeconds 180 -LogPath $LogPath -ArgumentList @($Installer, $MediaRoot, $GuestScenarioRoot, $GuestResultPath, $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, $supportScript) -ScriptBlock {
        param($Installer, $MediaRoot, $GuestScenarioRoot, $GuestResultPath, $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, $SupportScript)

        function Write-Utf8NoBomGuest {
            param([string]$Path, [AllowNull()]$Value = "")
            $parent = Split-Path -Parent $Path
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            [System.IO.File]::WriteAllText($Path, [string]$Value, [System.Text.UTF8Encoding]::new($false))
        }

        function Quote-PowerShellLiteral {
            param([string]$Value)
            return "'" + $Value.Replace("'", "''") + "'"
        }

        $resultPath = Join-Path $GuestScenarioRoot "installer-process-result.json"
        $diagnosticsPath = Join-Path $GuestScenarioRoot "installer-timeout-diagnostics.json"
        $watchdogPath = Join-Path $GuestScenarioRoot "installer-progress-watchdog.json"
        $runnerPath = Join-Path $GuestScenarioRoot "run-installer-direct.ps1"
        $supportPath = Join-Path $GuestScenarioRoot "installer-runner-support.ps1"
        $configPath = Join-Path $MediaRoot "hypersearch-install-automation.json"
        $installerLiteral = Quote-PowerShellLiteral $Installer
        $configLiteral = Quote-PowerShellLiteral $configPath
        $resultLiteral = Quote-PowerShellLiteral $resultPath
        $stateLiteral = Quote-PowerShellLiteral $GuestResultPath
        $diagnosticsLiteral = Quote-PowerShellLiteral $diagnosticsPath
        $watchdogLiteral = Quote-PowerShellLiteral $watchdogPath
        $mediaLiteral = Quote-PowerShellLiteral $MediaRoot
        $scenarioLiteral = Quote-PowerShellLiteral $GuestScenarioRoot
        $supportLiteral = Quote-PowerShellLiteral $supportPath

        Remove-Item -LiteralPath $resultPath, $diagnosticsPath, $watchdogPath -Force -ErrorAction SilentlyContinue
        Write-Utf8NoBomGuest -Path $supportPath -Value $SupportScript
        Write-Utf8NoBomGuest -Path $runnerPath -Value @"
`$ErrorActionPreference = "Continue"
`$env:HYPERSEARCH_INSTALL_AUTOMATED_CONFIG = $configLiteral
`$env:SEE_MASK_NOZONECHECKS = "1"
. $supportLiteral
function Get-LabProcessSnapshot {
    `$items = @()
    try {
        `$items = @(Get-CimInstance Win32_Process | Where-Object {
            `$_.CommandLine -match "HyperSearch|installer-lab|HyperSearch_1\.1\.0|WebView|msedge|setup|powershell|wsl|Docker|LM Studio" -or
            `$_.Name -match "setup|powershell|msiexec|wsl|Docker|msedge"
        } | Select-Object ProcessId, ParentProcessId, Name, CommandLine)
    } catch {
        `$items = @([pscustomobject]@{ ProcessId = 0; ParentProcessId = 0; Name = "process-snapshot-error"; CommandLine = `$_.Exception.Message })
    }
    return `$items
}
function Get-LabProcessTreeIds {
    param([int]`$RootProcessId)
    `$all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    `$ids = [System.Collections.ArrayList]::new()
    [void]`$ids.Add(`$RootProcessId)
    `$changed = `$true
    while (`$changed) {
        `$changed = `$false
        foreach (`$process in `$all) {
            if (`$ids.Contains([int]`$process.ParentProcessId) -and -not `$ids.Contains([int]`$process.ProcessId)) {
                [void]`$ids.Add([int]`$process.ProcessId)
                `$changed = `$true
            }
        }
    }
    return @(`$ids)
}
`$started = Get-Date
`$exitCode = 9009
`$errorText = ""
`$timedOut = `$false
`$stalled = `$false
`$progressPollSeconds = [Math]::Max(5, [int]$ProgressPollSeconds)
`$noProgressPollLimit = [Math]::Max(0, [int]$NoProgressPollLimit)
`$lastProgressAt = `$started
`$lastProgressSnapshot = `$null
`$lastProgressFingerprint = ""
`$noProgressPolls = 0
`$finalStateDetected = `$false
`$finalStateResult = ""
`$finalStateCompletedAt = ""
try {
    Unblock-File -LiteralPath $installerLiteral -ErrorAction SilentlyContinue
    `$process = Start-Process -FilePath $installerLiteral -ArgumentList @("/S", "/AllUsers") -WorkingDirectory $mediaLiteral -PassThru
    `$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    `$lastProgressSnapshot = Get-LabInstallerProgressSnapshot -RootProcessId `$process.Id -ScenarioRoot $scenarioLiteral -StatePath $stateLiteral -StartedAt `$started
    `$lastProgressFingerprint = `$lastProgressSnapshot.Fingerprint
    do {
        `$remainingSeconds = [int][Math]::Ceiling((`$deadline - (Get-Date)).TotalSeconds)
        `$sleepSeconds = [Math]::Max(1, [Math]::Min(`$progressPollSeconds, `$remainingSeconds))
        Start-Sleep -Seconds `$sleepSeconds
        `$process.Refresh()
        `$finalState = Get-LabInstallerFinalState -StatePath $stateLiteral
        if (-not `$process.HasExited -and `$finalState.Final) {
            `$finalStateDetected = `$true
            `$finalStateResult = `$finalState.Result
            `$finalStateCompletedAt = `$finalState.CompletedAt
            try {
                foreach (`$id in @(Get-LabProcessTreeIds -RootProcessId `$process.Id) | Sort-Object -Descending) {
                    Stop-Process -Id `$id -Force -ErrorAction SilentlyContinue
                }
            } catch {}
            `$exitCode = 0
            `$errorText = "Installer wrote final state result=`$finalStateResult at `$finalStateCompletedAt while process was still running; terminated stale process tree."
            break
        }
        if (-not `$process.HasExited -and `$noProgressPollLimit -gt 0) {
            `$currentProgressSnapshot = Get-LabInstallerProgressSnapshot -RootProcessId `$process.Id -ScenarioRoot $scenarioLiteral -StatePath $stateLiteral -StartedAt `$started
            if (`$currentProgressSnapshot.Fingerprint -ne `$lastProgressFingerprint) {
                `$lastProgressAt = Get-Date
                `$lastProgressSnapshot = `$currentProgressSnapshot
                `$lastProgressFingerprint = `$currentProgressSnapshot.Fingerprint
                `$noProgressPolls = 0
            } else {
                `$noProgressPolls++
                if (`$noProgressPolls -ge `$noProgressPollLimit) {
                    `$stalled = `$true
                    `$diagnostics = [ordered]@{
                        Reason = "installer-no-progress"
                        TimeoutSeconds = $TimeoutSeconds
                        ProgressPollSeconds = `$progressPollSeconds
                        NoProgressPollLimit = `$noProgressPollLimit
                        NoProgressSeconds = `$progressPollSeconds * `$noProgressPolls
                        LastProgressAt = `$lastProgressAt.ToString("o")
                        InstallerProcessId = `$process.Id
                        CapturedAt = (Get-Date).ToString("o")
                        LastProgress = `$lastProgressSnapshot
                        CurrentProgress = `$currentProgressSnapshot
                        Processes = @(Get-LabProcessSnapshot)
                    }
                    `$diagnostics | ConvertTo-Json -Depth 10 | Set-Content -Path $watchdogLiteral -Encoding UTF8
                    try {
                        foreach (`$id in @(Get-LabProcessTreeIds -RootProcessId `$process.Id) | Sort-Object -Descending) {
                            Stop-Process -Id `$id -Force -ErrorAction SilentlyContinue
                        }
                    } catch {}
                    `$exitCode = 125
                    `$errorText = "Installer made no observable progress for `$(`$progressPollSeconds * `$noProgressPolls) seconds."
                    break
                }
            }
        }
    } while (-not `$process.HasExited -and (Get-Date) -lt `$deadline)
    if (`$stalled) {
        `$timedOut = `$false
    } elseif (-not `$process.HasExited) {
        `$timedOut = `$true
        `$diagnostics = [ordered]@{
            Reason = "installer-timeout"
            TimeoutSeconds = $TimeoutSeconds
            InstallerProcessId = `$process.Id
            CapturedAt = (Get-Date).ToString("o")
            Processes = @(Get-LabProcessSnapshot)
        }
        `$diagnostics | ConvertTo-Json -Depth 8 | Set-Content -Path $diagnosticsLiteral -Encoding UTF8
        try {
            foreach (`$id in @(Get-LabProcessTreeIds -RootProcessId `$process.Id) | Sort-Object -Descending) {
                Stop-Process -Id `$id -Force -ErrorAction SilentlyContinue
            }
        } catch {}
        `$exitCode = 124
        `$errorText = "Installer timed out after $TimeoutSeconds seconds."
    } else {
        `$exitCode = `$process.ExitCode
    }
} catch {
    `$errorText = `$_.Exception.Message
}
`$completed = Get-Date
`$result = [ordered]@{
    ExitCode = `$exitCode
    Installer = $installerLiteral
    MediaRoot = $mediaLiteral
    ExecutionMode = "direct-psdirect"
    TimedOut = `$timedOut
    Stalled = `$stalled
    TimeoutSeconds = $TimeoutSeconds
    ProgressPollSeconds = `$progressPollSeconds
    NoProgressPollLimit = `$noProgressPollLimit
    FinalStateDetected = `$finalStateDetected
    FinalStateResult = `$finalStateResult
    FinalStateCompletedAt = `$finalStateCompletedAt
    DiagnosticsPath = $diagnosticsLiteral
    WatchdogPath = $watchdogLiteral
    LastProgressAt = `$lastProgressAt.ToString("o")
    Error = `$errorText
    StartedAt = `$started.ToString("o")
    CompletedAt = `$completed.ToString("o")
}
`$result | ConvertTo-Json -Depth 6 | Set-Content -Path $resultLiteral -Encoding UTF8
exit `$exitCode
"@

        $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $process = Start-Process -FilePath $powershell -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runnerPath) -PassThru -WindowStyle Hidden
        return [pscustomobject]@{
            ProcessId = $process.Id
            ResultPath = $resultPath
            RunnerPath = $runnerPath
            Installer = $Installer
            MediaRoot = $MediaRoot
            DiagnosticsPath = $diagnosticsPath
            WatchdogPath = $watchdogPath
            StartedAt = (Get-Date).ToString("o")
        }
    }

    $resultPath = [string]$launchInfo.ResultPath
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds + 300)
    $lastLogAt = Get-Date
    do {
        Start-Sleep -Seconds 5
        $resultJson = Invoke-Command -Session $Session -ScriptBlock {
            param($Path)
            if (Test-Path -LiteralPath $Path) {
                return Get-Content -Raw -LiteralPath $Path
            }
            return ""
        } -ArgumentList $resultPath
        if (-not [string]::IsNullOrWhiteSpace($resultJson)) {
            try {
                return ($resultJson | ConvertFrom-Json)
            } catch {
                if ($LogPath) {
                    Write-LabLog -Path $LogPath -Message "Direct installer result file exists but is not valid JSON yet: $($_.Exception.Message)" -Level "DEBUG"
                }
            }
        }

        $runnerAlive = Invoke-Command -Session $Session -ScriptBlock {
            param($ProcessId)
            return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
        } -ArgumentList ([int]$launchInfo.ProcessId)
        if (-not $runnerAlive) {
            $fallbackJson = Invoke-Command -Session $Session -ScriptBlock {
                param($ResultPath, $Installer, $MediaRoot, $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, $DiagnosticsPath, $WatchdogPath)
                if (Test-Path -LiteralPath $ResultPath) {
                    return Get-Content -Raw -LiteralPath $ResultPath
                }
                $fallback = [ordered]@{
                    ExitCode = 126
                    Installer = $Installer
                    MediaRoot = $MediaRoot
                    ExecutionMode = "direct-psdirect"
                    TimedOut = $false
                    Stalled = $false
                    TimeoutSeconds = $TimeoutSeconds
                    ProgressPollSeconds = $ProgressPollSeconds
                    NoProgressPollLimit = $NoProgressPollLimit
                    DiagnosticsPath = $DiagnosticsPath
                    WatchdogPath = $WatchdogPath
                    FinalStateDetected = $false
                    FinalStateResult = ""
                    FinalStateCompletedAt = ""
                    Error = "Direct installer runner exited without writing a process result file."
                    StartedAt = ""
                    CompletedAt = (Get-Date).ToString("o")
                }
                $json = $fallback | ConvertTo-Json -Depth 6
                [System.IO.File]::WriteAllText($ResultPath, $json, [System.Text.UTF8Encoding]::new($false))
                return $json
            } -ArgumentList $resultPath, ([string]$launchInfo.Installer), ([string]$launchInfo.MediaRoot), $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, ([string]$launchInfo.DiagnosticsPath), ([string]$launchInfo.WatchdogPath)
            return ($fallbackJson | ConvertFrom-Json)
        }

        if ($LogPath -and ((Get-Date) - $lastLogAt).TotalSeconds -ge 30) {
            Write-LabLog -Path $LogPath -Message "Direct NSIS installer still running in guest. RunnerPid=$($launchInfo.ProcessId) ResultPath=$resultPath"
            $lastLogAt = Get-Date
        }
    } while ((Get-Date) -lt $deadline)

    $timeoutJson = Invoke-Command -Session $Session -ScriptBlock {
        param($RunnerProcessId, $ResultPath, $Installer, $MediaRoot, $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, $DiagnosticsPath, $WatchdogPath)

        function Get-LabProcessTreeIdsGuest {
            param([int]$RootProcessId)
            $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
            $ids = [System.Collections.ArrayList]::new()
            [void]$ids.Add($RootProcessId)
            $changed = $true
            while ($changed) {
                $changed = $false
                foreach ($process in $all) {
                    if ($ids.Contains([int]$process.ParentProcessId) -and -not $ids.Contains([int]$process.ProcessId)) {
                        [void]$ids.Add([int]$process.ProcessId)
                        $changed = $true
                    }
                }
            }
            return @($ids)
        }

        if (Test-Path -LiteralPath $ResultPath) {
            return Get-Content -Raw -LiteralPath $ResultPath
        }

        try {
            foreach ($id in @(Get-LabProcessTreeIdsGuest -RootProcessId $RunnerProcessId) | Sort-Object -Descending) {
                Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            }
        } catch {}

        $fallback = [ordered]@{
            ExitCode = 124
            Installer = $Installer
            MediaRoot = $MediaRoot
            ExecutionMode = "direct-psdirect"
            TimedOut = $true
            Stalled = $false
            TimeoutSeconds = $TimeoutSeconds
            ProgressPollSeconds = $ProgressPollSeconds
            NoProgressPollLimit = $NoProgressPollLimit
            DiagnosticsPath = $DiagnosticsPath
            WatchdogPath = $WatchdogPath
            FinalStateDetected = $false
            FinalStateResult = ""
            FinalStateCompletedAt = ""
            Error = "Host-side direct installer poll timed out after $($TimeoutSeconds + 300) seconds."
            StartedAt = ""
            CompletedAt = (Get-Date).ToString("o")
        }
        $json = $fallback | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($ResultPath, $json, [System.Text.UTF8Encoding]::new($false))
        return $json
    } -ArgumentList ([int]$launchInfo.ProcessId), $resultPath, ([string]$launchInfo.Installer), ([string]$launchInfo.MediaRoot), $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, ([string]$launchInfo.DiagnosticsPath), ([string]$launchInfo.WatchdogPath)
    return ($timeoutJson | ConvertFrom-Json)
}

function Invoke-LabGuestCoreInstaller {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$InstallDir,
        [string]$MediaRoot,
        [string]$GuestScenarioRoot,
        [string]$GuestResultPath,
        [int]$TimeoutSeconds,
        [int]$ProgressPollSeconds = 30,
        [int]$NoProgressPollLimit = 0,
        [string]$LogPath
    )
    $supportScript = Get-LabInstallerRunnerSupportScript
    $launchInfo = Invoke-LabGuestScript -Session $Session -TimeoutSeconds 180 -LogPath $LogPath -ArgumentList @($InstallDir, $MediaRoot, $GuestScenarioRoot, $GuestResultPath, $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, $supportScript) -ScriptBlock {
        param($InstallDir, $MediaRoot, $GuestScenarioRoot, $GuestResultPath, $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, $SupportScript)

        function Write-Utf8NoBomGuest {
            param([string]$Path, [AllowNull()]$Value = "")
            $parent = Split-Path -Parent $Path
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
            [System.IO.File]::WriteAllText($Path, [string]$Value, [System.Text.UTF8Encoding]::new($false))
        }

        function Quote-PowerShellLiteral {
            param([string]$Value)
            return "'" + $Value.Replace("'", "''") + "'"
        }

        $resultPath = Join-Path $GuestScenarioRoot "installer-process-result.json"
        $diagnosticsPath = Join-Path $GuestScenarioRoot "installer-timeout-diagnostics.json"
        $watchdogPath = Join-Path $GuestScenarioRoot "installer-progress-watchdog.json"
        $runnerPath = Join-Path $GuestScenarioRoot "run-installer-core.ps1"
        $supportPath = Join-Path $GuestScenarioRoot "installer-runner-support.ps1"
        $configPath = Join-Path $MediaRoot "hypersearch-install-automation.json"
        $wrapper = Join-Path $InstallDir "installer\windows\HyperSearchPrereqSetup.ps1"
        $wrapperLiteral = Quote-PowerShellLiteral $wrapper
        $configLiteral = Quote-PowerShellLiteral $configPath
        $resultLiteral = Quote-PowerShellLiteral $resultPath
        $stateLiteral = Quote-PowerShellLiteral $GuestResultPath
        $diagnosticsLiteral = Quote-PowerShellLiteral $diagnosticsPath
        $watchdogLiteral = Quote-PowerShellLiteral $watchdogPath
        $mediaLiteral = Quote-PowerShellLiteral $MediaRoot
        $installLiteral = Quote-PowerShellLiteral $InstallDir
        $scenarioLiteral = Quote-PowerShellLiteral $GuestScenarioRoot
        $supportLiteral = Quote-PowerShellLiteral $supportPath

        Remove-Item -LiteralPath $resultPath, $diagnosticsPath, $watchdogPath -Force -ErrorAction SilentlyContinue
        Write-Utf8NoBomGuest -Path $supportPath -Value $SupportScript
        Write-Utf8NoBomGuest -Path $runnerPath -Value @"
`$ErrorActionPreference = "Continue"
`$env:HYPERSEARCH_INSTALL_AUTOMATED_CONFIG = $configLiteral
`$env:SEE_MASK_NOZONECHECKS = "1"
. $supportLiteral
function Get-LabProcessSnapshot {
    `$items = @()
    try {
        `$items = @(Get-CimInstance Win32_Process | Where-Object {
            `$_.CommandLine -match "HyperSearch|installer-lab|HyperSearchPrereqSetup|HyperSearchInstallationWizard|Docker|DockerDesktop|wsl|winget|LM Studio|powershell" -or
            `$_.Name -match "powershell|wsl|Docker|winget|msiexec|setup"
        } | Select-Object ProcessId, ParentProcessId, Name, CommandLine)
    } catch {
        `$items = @([pscustomobject]@{ ProcessId = 0; ParentProcessId = 0; Name = "process-snapshot-error"; CommandLine = `$_.Exception.Message })
    }
    return `$items
}
function Get-LabProcessTreeIds {
    param([int]`$RootProcessId)
    `$all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    `$ids = [System.Collections.ArrayList]::new()
    [void]`$ids.Add(`$RootProcessId)
    `$changed = `$true
    while (`$changed) {
        `$changed = `$false
        foreach (`$process in `$all) {
            if (`$ids.Contains([int]`$process.ParentProcessId) -and -not `$ids.Contains([int]`$process.ProcessId)) {
                [void]`$ids.Add([int]`$process.ProcessId)
                `$changed = `$true
            }
        }
    }
    return @(`$ids)
}
`$started = Get-Date
`$exitCode = 9009
`$errorText = ""
`$timedOut = `$false
`$stalled = `$false
`$progressPollSeconds = [Math]::Max(5, [int]$ProgressPollSeconds)
`$noProgressPollLimit = [Math]::Max(0, [int]$NoProgressPollLimit)
`$lastProgressAt = `$started
`$lastProgressSnapshot = `$null
`$lastProgressFingerprint = ""
`$noProgressPolls = 0
`$finalStateDetected = `$false
`$finalStateResult = ""
`$finalStateCompletedAt = ""
`$finalStateError = ""
try {
    if (!(Test-Path $wrapperLiteral)) {
        throw "Prerequisite wrapper was not staged: $wrapperLiteral"
    }
    `$powershell = Join-Path `$env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    `$arguments = @(
        "-NoProfile",
        "-Sta",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $wrapperLiteral,
        "-InstallDir",
        $installLiteral,
        "-MediaDir",
        $mediaLiteral,
        "-Automated",
        "-ConfigPath",
        $configLiteral,
        "-ResultPath",
        $stateLiteral
    )
    `$process = Start-Process -FilePath `$powershell -ArgumentList `$arguments -PassThru -WindowStyle Hidden
    `$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    `$lastProgressSnapshot = Get-LabInstallerProgressSnapshot -RootProcessId `$process.Id -ScenarioRoot $scenarioLiteral -StatePath $stateLiteral -StartedAt `$started
    `$lastProgressFingerprint = `$lastProgressSnapshot.Fingerprint
    do {
        `$remainingSeconds = [int][Math]::Ceiling((`$deadline - (Get-Date)).TotalSeconds)
        `$sleepSeconds = [Math]::Max(1, [Math]::Min(`$progressPollSeconds, `$remainingSeconds))
        Start-Sleep -Seconds `$sleepSeconds
        `$process.Refresh()
        if (-not `$process.HasExited) {
            `$finalState = Get-LabInstallerFinalState -StatePath $stateLiteral
            if (`$finalState.Final) {
                `$finalStateDetected = `$true
                `$finalStateResult = `$finalState.Result
                `$finalStateCompletedAt = `$finalState.CompletedAt
                `$finalStateError = `$finalState.Error
                try {
                    foreach (`$id in @(Get-LabProcessTreeIds -RootProcessId `$process.Id) | Sort-Object -Descending) {
                        Stop-Process -Id `$id -Force -ErrorAction SilentlyContinue
                    }
                } catch {}
                `$exitCode = 0
                break
            }
        }
        if (-not `$process.HasExited -and `$noProgressPollLimit -gt 0) {
            `$currentProgressSnapshot = Get-LabInstallerProgressSnapshot -RootProcessId `$process.Id -ScenarioRoot $scenarioLiteral -StatePath $stateLiteral -StartedAt `$started
            if (`$currentProgressSnapshot.Fingerprint -ne `$lastProgressFingerprint) {
                `$lastProgressAt = Get-Date
                `$lastProgressSnapshot = `$currentProgressSnapshot
                `$lastProgressFingerprint = `$currentProgressSnapshot.Fingerprint
                `$noProgressPolls = 0
            } else {
                `$noProgressPolls++
                if (`$noProgressPolls -ge `$noProgressPollLimit) {
                    `$stalled = `$true
                    `$diagnostics = [ordered]@{
                        Reason = "installer-core-no-progress"
                        TimeoutSeconds = $TimeoutSeconds
                        ProgressPollSeconds = `$progressPollSeconds
                        NoProgressPollLimit = `$noProgressPollLimit
                        NoProgressSeconds = `$progressPollSeconds * `$noProgressPolls
                        LastProgressAt = `$lastProgressAt.ToString("o")
                        RootProcessId = `$process.Id
                        CapturedAt = (Get-Date).ToString("o")
                        LastProgress = `$lastProgressSnapshot
                        CurrentProgress = `$currentProgressSnapshot
                        Processes = @(Get-LabProcessSnapshot)
                    }
                    `$diagnostics | ConvertTo-Json -Depth 10 | Set-Content -Path $watchdogLiteral -Encoding UTF8
                    try {
                        foreach (`$id in @(Get-LabProcessTreeIds -RootProcessId `$process.Id) | Sort-Object -Descending) {
                            Stop-Process -Id `$id -Force -ErrorAction SilentlyContinue
                        }
                    } catch {}
                    `$exitCode = 125
                    `$errorText = "Installer core made no observable progress for `$(`$progressPollSeconds * `$noProgressPolls) seconds."
                    break
                }
            }
        }
    } while (-not `$process.HasExited -and (Get-Date) -lt `$deadline)
    if (`$finalStateDetected) {
        `$timedOut = `$false
    } elseif (`$stalled) {
        `$timedOut = `$false
    } elseif (-not `$process.HasExited) {
        `$timedOut = `$true
        `$diagnostics = [ordered]@{
            Reason = "installer-core-timeout"
            TimeoutSeconds = $TimeoutSeconds
            RootProcessId = `$process.Id
            CapturedAt = (Get-Date).ToString("o")
            Processes = @(Get-LabProcessSnapshot)
        }
        `$diagnostics | ConvertTo-Json -Depth 8 | Set-Content -Path $diagnosticsLiteral -Encoding UTF8
        try {
            foreach (`$id in @(Get-LabProcessTreeIds -RootProcessId `$process.Id) | Sort-Object -Descending) {
                Stop-Process -Id `$id -Force -ErrorAction SilentlyContinue
            }
        } catch {}
        `$exitCode = 124
        `$errorText = "Installer core timed out after $TimeoutSeconds seconds."
    } else {
        `$exitCode = `$process.ExitCode
    }
} catch {
    `$errorText = `$_.Exception.Message
}
`$completed = Get-Date
`$result = [ordered]@{
    ExitCode = `$exitCode
    Wrapper = $wrapperLiteral
    MediaRoot = $mediaLiteral
    InstallDir = $installLiteral
    ExecutionMode = "installer-core"
    TimedOut = `$timedOut
    Stalled = `$stalled
    TimeoutSeconds = $TimeoutSeconds
    ProgressPollSeconds = `$progressPollSeconds
    NoProgressPollLimit = `$noProgressPollLimit
    DiagnosticsPath = $diagnosticsLiteral
    WatchdogPath = $watchdogLiteral
    LastProgressAt = `$lastProgressAt.ToString("o")
    FinalStateDetected = `$finalStateDetected
    FinalStateResult = `$finalStateResult
    FinalStateCompletedAt = `$finalStateCompletedAt
    FinalStateError = `$finalStateError
    Error = `$errorText
    StartedAt = `$started.ToString("o")
    CompletedAt = `$completed.ToString("o")
}
`$result | ConvertTo-Json -Depth 6 | Set-Content -Path $resultLiteral -Encoding UTF8
exit `$exitCode
"@

        $powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $process = Start-Process -FilePath $powershell -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $runnerPath) -PassThru -WindowStyle Hidden
        return [pscustomobject]@{
            ProcessId = $process.Id
            ResultPath = $resultPath
            RunnerPath = $runnerPath
            Wrapper = $wrapper
            MediaRoot = $MediaRoot
            InstallDir = $InstallDir
            DiagnosticsPath = $diagnosticsPath
            WatchdogPath = $watchdogPath
            StartedAt = (Get-Date).ToString("o")
        }
    }

    $resultPath = [string]$launchInfo.ResultPath
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds + 300)
    $lastLogAt = Get-Date
    do {
        Start-Sleep -Seconds 5
        $resultJson = Invoke-Command -Session $Session -ScriptBlock {
            param($Path)
            if (Test-Path -LiteralPath $Path) {
                return Get-Content -Raw -LiteralPath $Path
            }
            return ""
        } -ArgumentList $resultPath
        if (-not [string]::IsNullOrWhiteSpace($resultJson)) {
            try {
                return ($resultJson | ConvertFrom-Json)
            } catch {
                if ($LogPath) {
                    Write-LabLog -Path $LogPath -Message "Installer core result file exists but is not valid JSON yet: $($_.Exception.Message)" -Level "DEBUG"
                }
            }
        }

        $runnerAlive = Invoke-Command -Session $Session -ScriptBlock {
            param($ProcessId)
            return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
        } -ArgumentList ([int]$launchInfo.ProcessId)
        if (-not $runnerAlive) {
            $fallbackJson = Invoke-Command -Session $Session -ScriptBlock {
                param($ResultPath, $Wrapper, $MediaRoot, $InstallDir, $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, $DiagnosticsPath, $WatchdogPath)
                if (Test-Path -LiteralPath $ResultPath) {
                    return Get-Content -Raw -LiteralPath $ResultPath
                }
                $fallback = [ordered]@{
                    ExitCode = 126
                    Wrapper = $Wrapper
                    MediaRoot = $MediaRoot
                    InstallDir = $InstallDir
                    ExecutionMode = "installer-core"
                    TimedOut = $false
                    Stalled = $false
                    TimeoutSeconds = $TimeoutSeconds
                    ProgressPollSeconds = $ProgressPollSeconds
                    NoProgressPollLimit = $NoProgressPollLimit
                    DiagnosticsPath = $DiagnosticsPath
                    WatchdogPath = $WatchdogPath
                    FinalStateDetected = $false
                    FinalStateResult = ""
                    FinalStateCompletedAt = ""
                    FinalStateError = ""
                    Error = "Installer core runner exited without writing a process result file."
                    StartedAt = ""
                    CompletedAt = (Get-Date).ToString("o")
                }
                $json = $fallback | ConvertTo-Json -Depth 6
                [System.IO.File]::WriteAllText($ResultPath, $json, [System.Text.UTF8Encoding]::new($false))
                return $json
            } -ArgumentList $resultPath, ([string]$launchInfo.Wrapper), ([string]$launchInfo.MediaRoot), ([string]$launchInfo.InstallDir), $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, ([string]$launchInfo.DiagnosticsPath), ([string]$launchInfo.WatchdogPath)
            return ($fallbackJson | ConvertFrom-Json)
        }

        if ($LogPath -and ((Get-Date) - $lastLogAt).TotalSeconds -ge 30) {
            Write-LabLog -Path $LogPath -Message "Installer core still running in guest. RunnerPid=$($launchInfo.ProcessId) ResultPath=$resultPath"
            $lastLogAt = Get-Date
        }
    } while ((Get-Date) -lt $deadline)

    $timeoutJson = Invoke-Command -Session $Session -ScriptBlock {
        param($RunnerProcessId, $ResultPath, $Wrapper, $MediaRoot, $InstallDir, $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, $DiagnosticsPath, $WatchdogPath)

        function Get-LabProcessTreeIdsGuest {
            param([int]$RootProcessId)
            $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
            $ids = [System.Collections.ArrayList]::new()
            [void]$ids.Add($RootProcessId)
            $changed = $true
            while ($changed) {
                $changed = $false
                foreach ($process in $all) {
                    if ($ids.Contains([int]$process.ParentProcessId) -and -not $ids.Contains([int]$process.ProcessId)) {
                        [void]$ids.Add([int]$process.ProcessId)
                        $changed = $true
                    }
                }
            }
            return @($ids)
        }

        if (Test-Path -LiteralPath $ResultPath) {
            return Get-Content -Raw -LiteralPath $ResultPath
        }

        try {
            foreach ($id in @(Get-LabProcessTreeIdsGuest -RootProcessId $RunnerProcessId) | Sort-Object -Descending) {
                Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            }
        } catch {}

        $fallback = [ordered]@{
            ExitCode = 124
            Wrapper = $Wrapper
            MediaRoot = $MediaRoot
            InstallDir = $InstallDir
            ExecutionMode = "installer-core"
            TimedOut = $true
            Stalled = $false
            TimeoutSeconds = $TimeoutSeconds
            ProgressPollSeconds = $ProgressPollSeconds
            NoProgressPollLimit = $NoProgressPollLimit
            DiagnosticsPath = $DiagnosticsPath
            WatchdogPath = $WatchdogPath
            FinalStateDetected = $false
            FinalStateResult = ""
            FinalStateCompletedAt = ""
            FinalStateError = ""
            Error = "Host-side installer core poll timed out after $($TimeoutSeconds + 300) seconds."
            StartedAt = ""
            CompletedAt = (Get-Date).ToString("o")
        }
        $json = $fallback | ConvertTo-Json -Depth 6
        [System.IO.File]::WriteAllText($ResultPath, $json, [System.Text.UTF8Encoding]::new($false))
        return $json
    } -ArgumentList ([int]$launchInfo.ProcessId), $resultPath, ([string]$launchInfo.Wrapper), ([string]$launchInfo.MediaRoot), ([string]$launchInfo.InstallDir), $TimeoutSeconds, $ProgressPollSeconds, $NoProgressPollLimit, ([string]$launchInfo.DiagnosticsPath), ([string]$launchInfo.WatchdogPath)
    return ($timeoutJson | ConvertFrom-Json)
}

function Copy-LabItemToGuest {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$VMName = "",
        [string]$Source,
        [string]$Destination,
        [switch]$Recurse,
        [string]$LogPath = ""
    )
    Invoke-Command -Session $Session -ScriptBlock {
        param($Path)
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    } -ArgumentList $Destination
    if ($Recurse -and -not [string]::IsNullOrWhiteSpace($VMName) -and (Get-Item -LiteralPath $Source).PSIsContainer) {
        $sourceRoot = (Get-Item -LiteralPath $Source).FullName
        $guestRoot = Join-Path $Destination (Split-Path -Leaf $sourceRoot)
        Invoke-Command -Session $Session -ScriptBlock {
            param($Path)
            if (Test-Path $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
        } -ArgumentList $guestRoot
        $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File)
        $index = 0
        foreach ($file in $files) {
            $index++
            $relative = $file.FullName.Substring($sourceRoot.Length).TrimStart("\", "/")
            $guestFile = Join-Path $guestRoot $relative
            if ($LogPath -and ($file.Length -gt 52428800 -or $index -eq 1 -or $index -eq $files.Count)) {
                Write-LabLog -Path $LogPath -Message "Copying media file to guest with Copy-VMFile ($index/$($files.Count)): $relative"
            }
            Copy-VMFile -Name $VMName -FileSource Host -SourcePath $file.FullName -DestinationPath $guestFile -CreateFullPath -Force
        }
        return
    }
    if ($Recurse) {
        Copy-Item -ToSession $Session -LiteralPath $Source -Destination $Destination -Recurse -Force
    } else {
        Copy-Item -ToSession $Session -LiteralPath $Source -Destination $Destination -Force
    }
}

function Test-LabGuestMediaChecksums {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$MediaRoot
    )
    return Invoke-Command -Session $Session -ScriptBlock {
        param($Root)
        $checksumPath = Join-Path $Root "checksums.sha256"
        $result = [ordered]@{
            mediaRoot = $Root
            checksumPath = $checksumPath
            checkedAt = (Get-Date).ToString("o")
            checked = @()
            failures = @()
        }
        if (!(Test-Path $checksumPath)) {
            $result.failures += [ordered]@{ path = $checksumPath; reason = "checksums.sha256 missing" }
            return [pscustomobject]$result
        }
        foreach ($line in Get-Content -Path $checksumPath) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $parts = $line -split "\s+", 2
            if ($parts.Count -ne 2) { continue }
            $expected = $parts[0].Trim().ToLowerInvariant()
            $relative = $parts[1].Trim()
            $normalized = $relative -replace "/", "\"
            if ($normalized -notmatch "^(payload\\images\\|payload\\prereqs\\|HyperSearch_.*setup\.exe$|manifest\.json$)") { continue }
            $path = Join-Path $Root $relative
            if (!(Test-Path $path)) {
                $failure = [ordered]@{ path = $relative; reason = "missing"; expected = $expected; actual = "" }
                $result.failures += $failure
                $result.checked += $failure
                continue
            }
            $actual = (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLowerInvariant()
            $entry = [ordered]@{ path = $relative; expected = $expected; actual = $actual; ok = ($actual -eq $expected) }
            $result.checked += $entry
            if (-not $entry.ok) { $result.failures += $entry }
        }
        return [pscustomobject]$result
    } -ArgumentList $MediaRoot
}

function Copy-LabItemFromGuest {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$Source,
        [string]$Destination
    )
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Copy-Item -FromSession $Session -LiteralPath $Source -Destination $Destination -Recurse -Force -ErrorAction SilentlyContinue
}

function Copy-LabHyperSearchDataFromGuest {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$Destination,
        [string]$LogPath
    )
    try {
        $guestDataRoot = Invoke-Command -Session $Session -ScriptBlock { Join-Path $env:LOCALAPPDATA "HyperSearch" }
        if ([string]::IsNullOrWhiteSpace($guestDataRoot)) { return "" }
        $exists = Invoke-Command -Session $Session -ScriptBlock { param($Path) Test-Path -LiteralPath $Path } -ArgumentList $guestDataRoot
        if ($exists) {
            Copy-LabItemFromGuest -Session $Session -Source $guestDataRoot -Destination $Destination
            if ($LogPath) { Write-LabLog -Path $LogPath -Message "Collected guest HyperSearch data: $guestDataRoot -> $Destination" }
            return $guestDataRoot
        }
    } catch {
        if ($LogPath) { Write-LabLog -Path $LogPath -Message "Could not collect guest HyperSearch data: $($_.Exception.Message)" -Level "WARN" }
    }
    return ""
}

function Copy-LabPathToGuest {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$Source,
        [string]$Destination
    )
    if (!(Test-Path $Source)) {
        throw "Source path was not found for guest staging: $Source"
    }
    $parent = Split-Path -Parent $Destination
    if ($parent) {
        Invoke-Command -Session $Session -ScriptBlock {
            param($Path)
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
        } -ArgumentList $parent
    }
    if ((Get-Item -LiteralPath $Source).PSIsContainer) {
        Invoke-Command -Session $Session -ScriptBlock {
            param($Path)
            if (Test-Path $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
        } -ArgumentList $Destination
        Copy-Item -ToSession $Session -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
    } else {
        Copy-Item -ToSession $Session -LiteralPath $Source -Destination $Destination -Force
    }
}

function Copy-LabInstallSourceToGuest {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$RepoRoot,
        [string]$InstallDir,
        [string]$LogPath
    )
    Write-LabLog -Path $LogPath -Message "Staging direct installer-core payload from repo into guest install directory: $InstallDir"
    Invoke-Command -Session $Session -ScriptBlock {
        param($Path)
        if (Test-Path $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $Path "hypersearch-stack") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $Path "installer") | Out-Null
    } -ArgumentList $InstallDir

    Copy-LabPathToGuest -Session $Session -Source (Join-Path $RepoRoot "installer\windows") -Destination (Join-Path $InstallDir "installer\windows")
    $stackRoot = Join-Path $InstallDir "hypersearch-stack"
    $runtimeItems = @(
        ".env.example",
        "README.md",
        "LICENSE.md",
        "COPYING",
        "THIRD_PARTY_NOTICES.md",
        "SOURCE_OFFER.md",
        "SECURITY.md",
        "CHANGELOG.md",
        "docs",
        "infra",
        "apps\api\Dockerfile",
        "apps\api\pyproject.toml",
        "apps\api\hypersearch_api",
        "apps\ui\Dockerfile",
        "apps\ui\nginx.conf",
        "apps\ui\package.json",
        "apps\ui\package-lock.json",
        "apps\ui\index.html",
        "apps\ui\tsconfig.json",
        "apps\ui\tsconfig.node.json",
        "apps\ui\vite.config.ts",
        "apps\ui\src",
        "apps\ui\public"
    )
    foreach ($relative in $runtimeItems) {
        $source = Join-Path $RepoRoot $relative
        if (Test-Path $source) {
            Copy-LabPathToGuest -Session $Session -Source $source -Destination (Join-Path $stackRoot $relative)
        } else {
            Write-LabLog -Path $LogPath -Message "Skipping missing runtime staging path: $relative" -Level "WARN"
        }
    }
}

function Restore-LabCheckpoint {
    param([string]$VMName, [string]$CheckpointName, [string]$LogPath)
    $snapshot = Get-VMSnapshot -VMName $VMName -Name $CheckpointName -ErrorAction SilentlyContinue
    if (-not $snapshot) {
        throw "Checkpoint '$CheckpointName' was not found for VM '$VMName'."
    }
    Write-LabLog -Path $LogPath -Message "Restoring $VMName to checkpoint '$CheckpointName'."
    if ((Get-VM -Name $VMName).State -ne "Off") {
        Stop-VM -Name $VMName -TurnOff -Force
    }
    Restore-VMSnapshot -VMName $VMName -Name $CheckpointName -Confirm:$false
}

function Test-LabScenarioRequiresNestedVirtualization {
    param($Scenario)
    if ($Scenario.PSObject.Properties["requireNestedVirtualization"]) {
        return Get-ScenarioBool -Scenario $Scenario -Name "requireNestedVirtualization" -Default $true
    }
    if ($Scenario.PSObject.Properties["automation"]) {
        $automation = $Scenario.automation
        if ($automation.PSObject.Properties["installDocker"] -and [System.Convert]::ToBoolean([string]$automation.installDocker)) {
            return $true
        }
        if ($automation.PSObject.Properties["startStack"] -and [System.Convert]::ToBoolean([string]$automation.startStack)) {
            return $true
        }
        if ($automation.PSObject.Properties["imageSource"] -and [string]$automation.imageSource -ne "skip") {
            return $true
        }
    }
    return $false
}

function Invoke-LabVmHostPreflight {
    param(
        [string]$VMName,
        $Scenario,
        [string]$LogPath
    )
    $requiresNested = Test-LabScenarioRequiresNestedVirtualization -Scenario $Scenario
    $beforeProcessor = Get-VMProcessor -VMName $VMName -ErrorAction Stop
    $beforeVm = Get-VM -Name $VMName -ErrorAction Stop
    $actions = @()

    if ($requiresNested -and -not [bool]$beforeProcessor.ExposeVirtualizationExtensions) {
        Write-LabLog -Path $LogPath -Message "Checkpoint restored with nested virtualization disabled. Enabling ExposeVirtualizationExtensions before VM boot." -Level "WARN"
        Set-VMProcessor -VMName $VMName -ExposeVirtualizationExtensions $true
        $actions += "enabled-nested-virtualization"
    }

    $guestService = Get-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue
    if ($guestService -and -not $guestService.Enabled) {
        Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue
        $actions += "enabled-guest-service-interface"
    }

    $afterProcessor = Get-VMProcessor -VMName $VMName -ErrorAction Stop
    if ($requiresNested -and -not [bool]$afterProcessor.ExposeVirtualizationExtensions) {
        throw "Scenario requires Docker/WSL2, but VM '$VMName' does not expose nested virtualization after host preflight. Run Repair-HyperSearchLabVmBaseline.ps1 with -ReplaceCheckpoint."
    }

    return [ordered]@{
        vmName = $VMName
        requiresNestedVirtualization = $requiresNested
        actions = $actions
        before = [ordered]@{
            state = [string]$beforeVm.State
            processorCount = [int]$beforeProcessor.Count
            exposeVirtualizationExtensions = [bool]$beforeProcessor.ExposeVirtualizationExtensions
        }
        after = [ordered]@{
            processorCount = [int]$afterProcessor.Count
            exposeVirtualizationExtensions = [bool]$afterProcessor.ExposeVirtualizationExtensions
        }
    }
}

function Invoke-LabGuestWslPreflight {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        $Scenario,
        [string]$LogPath
    )
    $requiresNested = Test-LabScenarioRequiresNestedVirtualization -Scenario $Scenario
    if (-not $requiresNested) {
        return [ordered]@{
            status = "skipped"
            requiresNestedVirtualization = $false
            message = "Scenario does not require Docker/WSL2 nested virtualization."
        }
    }

    $result = Invoke-Command -Session $Session -ScriptBlock {
        $ErrorActionPreference = "Stop"
        function Invoke-NativeText {
            param([string]$FilePath, [string[]]$Arguments = @())
            $oldPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                $text = (& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ } | Out-String).Trim()
                $exitCode = $LASTEXITCODE
            } catch {
                $text = $_.Exception.Message
                $exitCode = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 }
            } finally {
                $ErrorActionPreference = $oldPreference
            }
            $text = $text -replace "`0", ""
            return [ordered]@{ exitCode = $exitCode; output = $text }
        }
        $featureNames = @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform", "HypervisorPlatform")
        $features = @($featureNames | ForEach-Object {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $_ -ErrorAction Stop
            [ordered]@{ name = $_; state = [string]$feature.State }
        })
        $wslStatus = Invoke-NativeText -FilePath "wsl.exe" -Arguments @("--status")
        $wslVersion = Invoke-NativeText -FilePath "wsl.exe" -Arguments @("--version")
        $systemInfo = @(systeminfo.exe 2>&1 | Select-String -Pattern "Hyper-V|Virtualization|hypervisor" | ForEach-Object { $_.Line })
        $combined = @($wslStatus.output, $wslVersion.output, ($systemInfo -join "`n")) -join "`n"
        $featuresEnabled = @($features | Where-Object { [string]$_.state -ne "Enabled" }).Count -eq 0
        $virtualizationBlocked = $combined -match "(?i)(WSL2 is unable to start since virtualization is not enabled|virtualization is not enabled|aka\.ms/enablevirtualization|Virtual Machine Platform.*firmware settings)"
        $wslNotInstalled = $combined -match "(?i)(Windows Subsystem for Linux is not installed|wsl\.exe --install|wsl --install)"
        $status = if ($featuresEnabled -and $virtualizationBlocked) { "failed" } elseif ((-not $featuresEnabled) -or $wslNotInstalled) { "deferred" } else { "passed" }
        $message = switch ($status) {
            "failed" { "Guest has WSL/virtualization features enabled, but WSL2 still reports virtualization unavailable. Repair and recapture the VM baseline before running Docker scenarios." }
            "deferred" { "Guest WSL setup is incomplete; installer WSL setup will exercise this path." }
            default { "Guest WSL preflight passed." }
        }
        [pscustomobject][ordered]@{
            status = $status
            message = $message
            features = $features
            featuresEnabled = $featuresEnabled
            virtualizationBlocked = $virtualizationBlocked
            wslNotInstalled = $wslNotInstalled
            wslStatus = $wslStatus
            wslVersion = $wslVersion
            systemInfo = $systemInfo
        }
    }

    Write-LabLog -Path $LogPath -Message "Guest WSL preflight status=$($result.status) featuresEnabled=$($result.featuresEnabled) virtualizationBlocked=$($result.virtualizationBlocked)"
    return $result
}

function Resolve-LabScript {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path $PSScriptRoot $Path
}

function Get-ScenarioString {
    param($Scenario, [string]$Name, [string]$Default = "")
    if ($Scenario.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Scenario.$Name)) {
        return [string]$Scenario.$Name
    }
    return $Default
}

function Get-ScenarioBool {
    param($Scenario, [string]$Name, [bool]$Default = $false)
    if ($Scenario.PSObject.Properties[$Name]) {
        if ($Scenario.$Name -is [bool]) { return [bool]$Scenario.$Name }
        return [System.Convert]::ToBoolean([string]$Scenario.$Name)
    }
    return $Default
}

function Get-ScenarioInt {
    param($Scenario, [string]$Name, [int]$Default)
    if ($Scenario.PSObject.Properties[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Scenario.$Name)) {
        return [int]$Scenario.$Name
    }
    return $Default
}

function Save-LabGuestSnapshot {
    param(
        [System.Management.Automation.Runspaces.PSSession]$Session,
        [string]$GuestScenarioRoot,
        [string]$GuestResultPath,
        [string]$HostOutputPath,
        [string]$LogPath
    )
    try {
        $snapshot = Invoke-Command -Session $Session -ScriptBlock {
            param($ScenarioRoot, $ResultPath)
            [ordered]@{
                capturedAt = (Get-Date).ToString("o")
                computer = $env:COMPUTERNAME
                user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                installerStateExists = (Test-Path $ResultPath)
                localHyperSearchExists = (Test-Path (Join-Path $env:LOCALAPPDATA "HyperSearch"))
                installDirExists = (Test-Path "C:\Program Files\HyperSearch")
                scenarioFiles = @(Get-ChildItem -Path $ScenarioRoot -Recurse -File -ErrorAction SilentlyContinue | Select-Object FullName, Length, LastWriteTime)
                hyperSearchFiles = @(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA "HyperSearch") -Recurse -File -ErrorAction SilentlyContinue | Select-Object FullName, Length, LastWriteTime)
                processes = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
                    $_.CommandLine -match "HyperSearch|installer-lab|HyperSearchPrereqSetup|HyperSearchInstallationWizard|Docker|DockerDesktop|wsl|winget|LM Studio|powershell|WebView|msedge|setup" -or
                    $_.Name -match "powershell|wsl|Docker|winget|msiexec|setup|msedge"
                } | Select-Object ProcessId, ParentProcessId, Name, CommandLine)
            }
        } -ArgumentList $GuestScenarioRoot, $GuestResultPath
        Write-Utf8NoBom -Path $HostOutputPath -Value ($snapshot | ConvertTo-Json -Depth 8)
        Write-LabLog -Path $LogPath -Message "Collected guest snapshot: $HostOutputPath"
    } catch {
        Write-LabLog -Path $LogPath -Message "Guest snapshot collection failed: $($_.Exception.Message)" -Level "WARN"
    }
}

function New-AutomationConfig {
    param($Scenario, [string]$GuestMediaRoot, [string]$GuestResultPath)
    $automation = [ordered]@{
        acceptedLicenses = $true
        installMode = "standard"
        installDocker = $true
        dockerInstallMode = "per-user"
        repairDocker = $true
        installLmStudio = $true
        imageSource = "bundled"
        startStack = $true
        usagePreset = "general-research"
        selectedModel = "recommended"
        downloadModel = $false
        mediaDir = $GuestMediaRoot
        installDir = "C:\Program Files\HyperSearch"
        resultPath = $GuestResultPath
    }
    if ($Scenario.PSObject.Properties["automation"]) {
        foreach ($property in $Scenario.automation.PSObject.Properties) {
            $automation[$property.Name] = $property.Value
        }
    }
    $automation["mediaDir"] = $GuestMediaRoot
    $automation["resultPath"] = $GuestResultPath
    return $automation
}

function Get-ScenarioAssertionList {
    param($Config, $Scenario)
    $expected = @()
    if ($Scenario.PSObject.Properties["expectedResults"]) {
        $expected = @($Scenario.expectedResults)
    } elseif ($Config.PSObject.Properties["defaultExpectedResults"]) {
        $expected = @($Config.defaultExpectedResults)
    }
    if ($expected.Count -eq 0) { $expected = @("passed", "warning") }
    return @($expected | ForEach-Object { [string]$_ })
}

function Test-LabStateNeedsRebootResume {
    param($State)
    if ($null -eq $State) { return $false }
    if ([string]$State.result -ne "blocked") { return $false }
    if ($State.wsl.resumeRegistered -eq $true) { return $true }
    if ($State.steps.wsl.status -eq "blocked") { return $true }
    if ($State.steps.docker.message -match "reboot") { return $true }
    return $false
}

Assert-Admin
Import-Module Hyper-V -ErrorAction Stop

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\.."))
$config = Read-LabConfig -Path $ConfigPath
$credential = New-LabCredential -Config $config
$labRoot = Expand-LabPath $config.labRoot
if ([string]::IsNullOrWhiteSpace($labRoot)) {
    $labRoot = Join-Path $env:LOCALAPPDATA "HyperSearch\installer-lab"
}
$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$runRoot = Join-Path $labRoot "runs\$runId"
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$matrixLog = Join-Path $runRoot "matrix.log"
Write-LabLog -Path $matrixLog -Message "HyperSearch installer matrix started. RunId=$runId"

$mediaRoot = Expand-LabPath $config.mediaRoot
if (!(Test-Path $mediaRoot)) {
    throw "Release media root was not found: $mediaRoot"
}
$installerExe = if ($config.installerExe) { [string]$config.installerExe } else { "HyperSearch_1.1.0_x64-setup.exe" }
$hostInstaller = Join-Path $mediaRoot $installerExe
if (!(Test-Path $hostInstaller)) {
    throw "Installer EXE was not found in media root: $hostInstaller"
}

$guestWorkRoot = if ($config.guestWorkRoot) { [string]$config.guestWorkRoot } else { "C:\HyperSearchInstallerLab" }
$defaultGuestTimeout = if ($config.defaultGuestTimeoutSeconds) { [int]$config.defaultGuestTimeoutSeconds } else { 7200 }
$defaultVmReadyTimeout = if ($config.defaultVmReadyTimeoutSeconds) { [int]$config.defaultVmReadyTimeoutSeconds } else { 900 }
$defaultProgressPollSeconds = if ($config.PSObject.Properties["defaultProgressPollSeconds"]) { [int]$config.defaultProgressPollSeconds } else { 30 }
$defaultNoProgressPollLimit = if ($config.PSObject.Properties["defaultNoProgressPollLimit"]) { [int]$config.defaultNoProgressPollLimit } else { 0 }
$scenarios = @($config.scenarios)
if ($ScenarioName.Count -gt 0) {
    $selected = @{}
    foreach ($name in $ScenarioName) { $selected[$name] = $true }
    $scenarios = @($scenarios | Where-Object { $selected.ContainsKey([string]$_.name) })
}
if ($scenarios.Count -eq 0) {
    throw "No scenarios selected."
}

$summary = @()
foreach ($scenario in $scenarios) {
    $scenario = @($scenario)[0]
    [string]$scenarioName = ConvertTo-ScalarString -Value ($scenario.PSObject.Properties["name"].Value)
    if ($ScenarioName.Count -eq 1) {
        $scenarioName = ConvertTo-ScalarString -Value $ScenarioName
    }
    $scenarioRoot = Join-Path $runRoot $scenarioName
    New-Item -ItemType Directory -Force -Path $scenarioRoot | Out-Null
    $scenarioLog = Join-Path $scenarioRoot "host-scenario.log"
    $scenarioStatus = "failed"
    $scenarioError = ""
    $vmName = [string]$scenario.vmName
    $checkpoint = [string]$scenario.checkpoint
    $session = $null
    $guestScenarioRoot = ""
    $guestResultPath = ""
    try {
        if ([string]::IsNullOrWhiteSpace($vmName)) { throw "Scenario '$scenarioName' is missing vmName." }
        if ([string]::IsNullOrWhiteSpace($checkpoint)) { throw "Scenario '$scenarioName' is missing checkpoint." }
        Write-LabLog -Path $scenarioLog -Message "Scenario started: $scenarioName VM=$vmName checkpoint=$checkpoint"
        Restore-LabCheckpoint -VMName $vmName -CheckpointName $checkpoint -LogPath $scenarioLog
        $hostPreflight = Invoke-LabVmHostPreflight -VMName $vmName -Scenario $scenario -LogPath $scenarioLog
        Write-Utf8NoBom -Path (Join-Path $scenarioRoot "vm-host-preflight.json") -Value ($hostPreflight | ConvertTo-Json -Depth 8)
        Write-LabLog -Path $scenarioLog -Message "VM host preflight complete. RequiresNestedVirtualization=$($hostPreflight.requiresNestedVirtualization) ExposeVirtualizationExtensions=$($hostPreflight.after.exposeVirtualizationExtensions)"
        Start-VM -Name $vmName | Out-Null
        Wait-LabVmReady -VMName $vmName -Credential $credential -TimeoutSeconds $defaultVmReadyTimeout -LogPath $scenarioLog | Out-Null
        $session = New-LabSession -VMName $vmName -Credential $credential
        $guestWslPreflight = Invoke-LabGuestWslPreflight -Session $session -Scenario $scenario -LogPath $scenarioLog
        Write-Utf8NoBom -Path (Join-Path $scenarioRoot "guest-wsl-preflight.json") -Value ($guestWslPreflight | ConvertTo-Json -Depth 8)
        if ([string]$guestWslPreflight.status -eq "failed") {
            throw $guestWslPreflight.message
        }
        $guestScenarioRoot = Join-Path $guestWorkRoot $scenarioName
        $guestMediaRoot = Join-Path $guestScenarioRoot "media"
        $guestResultPath = Join-Path $guestScenarioRoot "installer-state.json"
        $executionMode = (Get-ScenarioString -Scenario $scenario -Name "executionMode" -Default "nsis").ToLowerInvariant()
        $defaultGuestInstallDir = if ($executionMode -in @("core", "installer-core")) { Join-Path $guestScenarioRoot "install\HyperSearch" } else { "C:\Program Files\HyperSearch" }
        $guestInstallDir = Get-ScenarioString -Scenario $scenario -Name "guestInstallDir" -Default $defaultGuestInstallDir
        $scenarioTimeout = Get-ScenarioInt -Scenario $scenario -Name "installerTimeoutSeconds" -Default $defaultGuestTimeout
        $resumeTimeout = Get-ScenarioInt -Scenario $scenario -Name "resumeTimeoutSeconds" -Default $scenarioTimeout
        $progressPollSeconds = Get-ScenarioInt -Scenario $scenario -Name "progressPollSeconds" -Default $defaultProgressPollSeconds
        $noProgressPollLimit = Get-ScenarioInt -Scenario $scenario -Name "noProgressPollLimit" -Default $defaultNoProgressPollLimit
        Invoke-Command -Session $session -ScriptBlock {
            param($Path)
            if (Test-Path $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $Path | Out-Null
        } -ArgumentList $guestScenarioRoot

        if ($SkipMediaCopy -and $scenario.PSObject.Properties["guestMediaRoot"]) {
            $guestMediaRoot = [string]$scenario.guestMediaRoot
            Write-LabLog -Path $scenarioLog -Message "Using pre-staged guest media: $guestMediaRoot"
        } else {
            Write-LabLog -Path $scenarioLog -Message "Copying media to guest: $mediaRoot -> $guestMediaRoot"
            Copy-LabItemToGuest -Session $session -VMName $vmName -Source $mediaRoot -Destination $guestMediaRoot -Recurse -LogPath $scenarioLog
            $guestMediaRoot = Join-Path $guestMediaRoot (Split-Path -Leaf $mediaRoot)
            $guestMediaChecksums = Test-LabGuestMediaChecksums -Session $session -MediaRoot $guestMediaRoot
            Write-Utf8NoBom -Path (Join-Path $scenarioRoot "guest-media-checksums.json") -Value ($guestMediaChecksums | ConvertTo-Json -Depth 8)
            if (@($guestMediaChecksums.failures).Count -gt 0) {
                throw "Guest media checksum verification failed after copy. See $(Join-Path $scenarioRoot "guest-media-checksums.json")."
            }
        }

        $automation = New-AutomationConfig -Scenario $scenario -GuestMediaRoot $guestMediaRoot -GuestResultPath $guestResultPath
        $automation["installDir"] = $guestInstallDir
        $automationHostPath = Join-Path $scenarioRoot "automation-config.json"
        Write-Utf8NoBom -Path $automationHostPath -Value ($automation | ConvertTo-Json -Depth 8)
        Copy-Item -ToSession $session -LiteralPath $automationHostPath -Destination (Join-Path $guestMediaRoot "hypersearch-install-automation.json") -Force

        if ($scenario.PSObject.Properties["guestPrepareScript"] -and -not [string]::IsNullOrWhiteSpace([string]$scenario.guestPrepareScript)) {
            $prepareScript = Resolve-LabScript -Path ([string]$scenario.guestPrepareScript)
            if (!(Test-Path $prepareScript)) { throw "Guest prepare script was not found: $prepareScript" }
            $guestPrepare = Join-Path $guestScenarioRoot "prepare.ps1"
            Copy-Item -ToSession $session -LiteralPath $prepareScript -Destination $guestPrepare -Force
            Write-LabLog -Path $scenarioLog -Message "Running guest prepare script: $prepareScript"
            $prepareOutput = Invoke-LabGuestScript -Session $session -TimeoutSeconds 900 -LogPath $scenarioLog -ArgumentList @($guestPrepare) -ScriptBlock {
                param($ScriptPath)
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath
            } | Out-String
            Write-Utf8NoBom -Path (Join-Path $scenarioRoot "guest-prepare-output.txt") -Value $prepareOutput
        }

        if ($executionMode -in @("core", "installer-core")) {
            Copy-LabInstallSourceToGuest -Session $session -RepoRoot $repoRoot -InstallDir $guestInstallDir -LogPath $scenarioLog
            Write-LabLog -Path $scenarioLog -Message "Running direct HyperSearch installer core: InstallDir=$guestInstallDir MediaRoot=$guestMediaRoot TimeoutSeconds=$scenarioTimeout ProgressPollSeconds=$progressPollSeconds NoProgressPollLimit=$noProgressPollLimit"
            $installResult = Invoke-LabGuestCoreInstaller -Session $session -InstallDir $guestInstallDir -MediaRoot $guestMediaRoot -GuestScenarioRoot $guestScenarioRoot -GuestResultPath $guestResultPath -TimeoutSeconds $scenarioTimeout -ProgressPollSeconds $progressPollSeconds -NoProgressPollLimit $noProgressPollLimit -LogPath $scenarioLog
        } elseif ($executionMode -eq "nsis") {
            $guestInstaller = Join-Path $guestMediaRoot $installerExe
            Write-LabLog -Path $scenarioLog -Message "Running silent NSIS installer through direct PowerShell Direct process: $guestInstaller TimeoutSeconds=$scenarioTimeout ProgressPollSeconds=$progressPollSeconds NoProgressPollLimit=$noProgressPollLimit"
            $installResult = Invoke-LabGuestDirectInstaller -Session $session -Installer $guestInstaller -MediaRoot $guestMediaRoot -GuestScenarioRoot $guestScenarioRoot -GuestResultPath $guestResultPath -TimeoutSeconds $scenarioTimeout -ProgressPollSeconds $progressPollSeconds -NoProgressPollLimit $noProgressPollLimit -LogPath $scenarioLog
        } else {
            throw "Unknown scenario executionMode '$executionMode'. Expected nsis or core."
        }
        Write-Utf8NoBom -Path (Join-Path $scenarioRoot "installer-process-result.json") -Value ($installResult | ConvertTo-Json -Depth 6)
        if ($installResult.PSObject.Properties["Stalled"] -and [bool]$installResult.Stalled) {
            throw "Installer progress watchdog failed the scenario after no observable progress. See $($installResult.WatchdogPath)"
        }
        if ($installResult.PSObject.Properties["TimedOut"] -and [bool]$installResult.TimedOut) {
            throw "Installer process timed out. See $($installResult.DiagnosticsPath)"
        }

        if (Get-ScenarioBool -Scenario $scenario -Name "skipStateAssertions" -Default $false) {
            Save-LabGuestSnapshot -Session $session -GuestScenarioRoot $guestScenarioRoot -GuestResultPath $guestResultPath -HostOutputPath (Join-Path $scenarioRoot "guest-snapshot.json") -LogPath $scenarioLog
            Copy-LabItemFromGuest -Session $session -Source $guestScenarioRoot -Destination (Join-Path $scenarioRoot "guest-scenario-root")
            $expectedTimedOut = Get-ScenarioBool -Scenario $scenario -Name "expectedInstallerTimedOut" -Default $false
            if ([bool]$installResult.TimedOut -ne $expectedTimedOut) {
                throw "Installer timeout expectation mismatch. ExpectedTimedOut=$expectedTimedOut ActualTimedOut=$([bool]$installResult.TimedOut)."
            }
            if ($scenario.PSObject.Properties["expectedInstallerExitCodes"]) {
                $expectedExitCodes = @($scenario.expectedInstallerExitCodes | ForEach-Object { [int]$_ })
                if ($expectedExitCodes.Count -gt 0 -and $expectedExitCodes -notcontains [int]$installResult.ExitCode) {
                    throw "Installer exit code $($installResult.ExitCode) was not in expected set: $($expectedExitCodes -join ', ')."
                }
            }
            $scenarioStatus = "passed"
            Write-LabLog -Path $scenarioLog -Message "Scenario passed without installer-state assertions by configuration: $scenarioName"
            continue
        }

        $allowRebootResume = $true
        if ($scenario.PSObject.Properties["allowRebootResume"] -and $scenario.allowRebootResume -eq $false) {
            $allowRebootResume = $false
        }
        $stateText = Invoke-Command -Session $session -ScriptBlock {
            param($Path)
            if (Test-Path $Path) { Get-Content -Raw -Path $Path } else { "" }
        } -ArgumentList $guestResultPath
        if ($allowRebootResume -and -not [string]::IsNullOrWhiteSpace($stateText)) {
            $firstState = $stateText | ConvertFrom-Json
            if (Test-LabStateNeedsRebootResume -State $firstState) {
                Write-LabLog -Path $scenarioLog -Message "Installer requested reboot/resume. Restarting VM and rerunning installed automated prerequisite wrapper."
                Remove-PSSession $session -ErrorAction SilentlyContinue
                $session = $null
                Restart-VM -Name $vmName -Force
                Start-Sleep -Seconds 20
                Wait-LabVmReady -VMName $vmName -Credential $credential -TimeoutSeconds $defaultVmReadyTimeout -LogPath $scenarioLog | Out-Null
                $session = New-LabSession -VMName $vmName -Credential $credential
                Write-LabLog -Path $scenarioLog -Message "Running reboot/resume installer core: InstallDir=$guestInstallDir MediaRoot=$guestMediaRoot TimeoutSeconds=$resumeTimeout ProgressPollSeconds=$progressPollSeconds NoProgressPollLimit=$noProgressPollLimit"
                $resumeResult = Invoke-LabGuestCoreInstaller -Session $session -InstallDir $guestInstallDir -MediaRoot $guestMediaRoot -GuestScenarioRoot $guestScenarioRoot -GuestResultPath $guestResultPath -TimeoutSeconds $resumeTimeout -ProgressPollSeconds $progressPollSeconds -NoProgressPollLimit $noProgressPollLimit -LogPath $scenarioLog
                Write-Utf8NoBom -Path (Join-Path $scenarioRoot "installer-resume-result.json") -Value ($resumeResult | ConvertTo-Json -Depth 6)
                if ($resumeResult.PSObject.Properties["Stalled"] -and [bool]$resumeResult.Stalled) {
                    throw "Installer resume progress watchdog failed the scenario after no observable progress. See $($resumeResult.WatchdogPath)"
                }
                if ($resumeResult.PSObject.Properties["TimedOut"] -and [bool]$resumeResult.TimedOut) {
                    throw "Installer resume process timed out. See $($resumeResult.DiagnosticsPath)"
                }
            }
        }

        Copy-LabHyperSearchDataFromGuest -Session $session -Destination (Join-Path $scenarioRoot "guest-data") -LogPath $scenarioLog | Out-Null
        $statePath = Join-Path $scenarioRoot "installer-state.json"
        $copiedExplicitState = $false
        if ((Invoke-Command -Session $session -ScriptBlock { param($Path) Test-Path $Path } -ArgumentList $guestResultPath)) {
            Copy-Item -FromSession $session -LiteralPath $guestResultPath -Destination $statePath -Force
            $copiedExplicitState = $true
            Write-LabLog -Path $scenarioLog -Message "Collected explicit installer result file: $guestResultPath"
        }
        if (-not $copiedExplicitState) {
            $statePath = Join-Path $scenarioRoot "guest-data\HyperSearch\installer-state.json"
        }
        if (!(Test-Path $statePath)) {
            $candidate = Get-ChildItem -Path (Join-Path $scenarioRoot "guest-data") -Recurse -Filter "installer-state.json" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($candidate) { $statePath = $candidate.FullName }
        }
        if (!(Test-Path $statePath)) {
            Save-LabGuestSnapshot -Session $session -GuestScenarioRoot $guestScenarioRoot -GuestResultPath $guestResultPath -HostOutputPath (Join-Path $scenarioRoot "guest-snapshot.json") -LogPath $scenarioLog
            Copy-LabItemFromGuest -Session $session -Source $guestScenarioRoot -Destination (Join-Path $scenarioRoot "guest-scenario-root")
            throw "Installer state was not collected from guest. Expected $guestResultPath"
        }
        $assertionsPath = Join-Path $scenarioRoot "assertions.json"
        $assertions = if ($scenario.PSObject.Properties["assertions"]) { $scenario.assertions } else { [pscustomobject]@{} }
        Write-Utf8NoBom -Path $assertionsPath -Value ($assertions | ConvertTo-Json -Depth 6)
        $expectedResults = Get-ScenarioAssertionList -Config $config -Scenario $scenario
        Write-LabLog -Path $scenarioLog -Message "Running host assertions."
        & (Join-Path $PSScriptRoot "Assert-HyperSearchInstallResult.ps1") `
            -StatePath $statePath `
            -ExpectedResult $expectedResults `
            -AssertionsPath $assertionsPath `
            -OutputPath (Join-Path $scenarioRoot "assertion-result.json")
        if ($LASTEXITCODE -ne 0) {
            throw "Host assertions failed with exit code $LASTEXITCODE."
        }
        $scenarioStatus = "passed"
        Write-LabLog -Path $scenarioLog -Message "Scenario passed: $scenarioName"
    } catch {
        $scenarioError = $_.Exception.Message
        Write-LabLog -Path $scenarioLog -Message "Scenario failed: $scenarioError" -Level "ERROR"
        if ($session -and $guestScenarioRoot) {
            Save-LabGuestSnapshot -Session $session -GuestScenarioRoot $guestScenarioRoot -GuestResultPath $guestResultPath -HostOutputPath (Join-Path $scenarioRoot "guest-snapshot-on-error.json") -LogPath $scenarioLog
            Copy-LabHyperSearchDataFromGuest -Session $session -Destination (Join-Path $scenarioRoot "guest-data-on-error") -LogPath $scenarioLog | Out-Null
            Copy-LabItemFromGuest -Session $session -Source $guestScenarioRoot -Destination (Join-Path $scenarioRoot "guest-scenario-root-on-error")
        }
    } finally {
        if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
        if (-not $KeepVmRunning -and $vmName) {
            try {
                if ((Get-VM -Name $vmName -ErrorAction SilentlyContinue).State -eq "Running") {
                    Stop-VM -Name $vmName -TurnOff -Force
                }
            } catch {}
        }
        $summary += [ordered]@{
            name = $scenarioName
            vmName = $vmName
            checkpoint = $checkpoint
            status = $scenarioStatus
            error = $scenarioError
            scenarioRoot = $scenarioRoot
        }
    }
}

$matrixResult = [ordered]@{
    runId = $runId
    configPath = (Resolve-Path $ConfigPath).Path
    mediaRoot = $mediaRoot
    startedAt = $runId
    completedAt = (Get-Date).ToString("o")
    scenarios = $summary
    passed = (@($summary | Where-Object { $_.status -eq "passed" }).Count)
    failed = (@($summary | Where-Object { $_.status -ne "passed" }).Count)
}
Write-Utf8NoBom -Path (Join-Path $runRoot "matrix-summary.json") -Value ($matrixResult | ConvertTo-Json -Depth 8)
Write-LabLog -Path $matrixLog -Message "Matrix completed. Passed=$($matrixResult.passed) Failed=$($matrixResult.failed) Root=$runRoot"
if ($matrixResult.failed -gt 0) { exit 1 }
exit 0
