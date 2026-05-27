param(
    [string]$InstallDir = "",
    [string]$MediaDir = "",
    [switch]$DownloadModelOnly,
    [string]$ModelId = "",
    [string]$ModelLabel = "",
    [switch]$Automated,
    [string]$ConfigPath = "",
    [string]$ResultPath = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

. (Join-Path $PSScriptRoot "HyperSearchInstallerCore.ps1")

if ($DownloadModelOnly) {
    $state = Invoke-HyperSearchModelDownloadOnly -InstallDir $InstallDir -MediaDir $MediaDir -ModelId $ModelId -ModelLabel $ModelLabel
    if ($state.errors.Count -gt 0) { exit 1 }
    exit 0
}

function Get-AutomationValue {
    param($Config, [string]$Name, $Default)
    if ($null -ne $Config -and $Config.PSObject.Properties[$Name]) {
        return $Config.$Name
    }
    return $Default
}

function ConvertTo-AutomationBool {
    param($Value, [bool]$Default)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    return [System.Convert]::ToBoolean([string]$Value)
}

function Invoke-AutomatedInstall {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Automated install requires -ConfigPath."
    }
    if (!(Test-Path $Path)) {
        throw "Automated install config was not found: $Path"
    }
    $config = Get-Content -Raw -Path $Path | ConvertFrom-Json
    $acceptedLicenses = ConvertTo-AutomationBool -Value (Get-AutomationValue -Config $config -Name "acceptedLicenses" -Default $false) -Default $false
    if (-not $acceptedLicenses) {
        throw "Automated install config must set acceptedLicenses=true."
    }
    $effectiveInstallDir = if ($InstallDir) { $InstallDir } else { [string](Get-AutomationValue -Config $config -Name "installDir" -Default "") }
    $effectiveMediaDir = if ($MediaDir) { $MediaDir } else { [string](Get-AutomationValue -Config $config -Name "mediaDir" -Default "") }
    $effectiveResultPath = if ($ResultPath) { $ResultPath } else { [string](Get-AutomationValue -Config $config -Name "resultPath" -Default "") }
    $options = New-HyperSearchInstallerOptions `
        -InstallDir $effectiveInstallDir `
        -MediaDir $effectiveMediaDir `
        -Version ([string](Get-AutomationValue -Config $config -Name "version" -Default "")) `
        -InstallMode ([string](Get-AutomationValue -Config $config -Name "installMode" -Default "standard")) `
        -AcceptedLicenses:$acceptedLicenses `
        -InstallDocker:(ConvertTo-AutomationBool -Value (Get-AutomationValue -Config $config -Name "installDocker" -Default $true) -Default $true) `
        -DockerInstallMode ([string](Get-AutomationValue -Config $config -Name "dockerInstallMode" -Default "per-user")) `
        -RepairDocker:(ConvertTo-AutomationBool -Value (Get-AutomationValue -Config $config -Name "repairDocker" -Default $true) -Default $true) `
        -DockerReadyTimeoutSeconds ([int](Get-AutomationValue -Config $config -Name "dockerReadyTimeoutSeconds" -Default 480)) `
        -InstallLmStudio:(ConvertTo-AutomationBool -Value (Get-AutomationValue -Config $config -Name "installLmStudio" -Default $true) -Default $true) `
        -ImageSource ([string](Get-AutomationValue -Config $config -Name "imageSource" -Default "bundled")) `
        -StartStack:(ConvertTo-AutomationBool -Value (Get-AutomationValue -Config $config -Name "startStack" -Default $true) -Default $true) `
        -EnableLoginAutostart:(ConvertTo-AutomationBool -Value (Get-AutomationValue -Config $config -Name "enableLoginAutostart" -Default $false) -Default $false) `
        -UsagePreset ([string](Get-AutomationValue -Config $config -Name "usagePreset" -Default "general-research")) `
        -SelectedModel ([string](Get-AutomationValue -Config $config -Name "selectedModel" -Default "recommended")) `
        -DownloadModel:(ConvertTo-AutomationBool -Value (Get-AutomationValue -Config $config -Name "downloadModel" -Default $false) -Default $false)
    $state = Invoke-HyperSearchInstallation -Options $options
    if ($effectiveResultPath) {
        Write-Utf8NoBom -Path $effectiveResultPath -Value ($state | ConvertTo-Json -Depth 12)
    }
    if ($state.result -eq "failed") { exit 1 }
    if ($state.result -eq "blocked") { exit 2 }
    exit 0
}

if ($Automated) {
    Invoke-AutomatedInstall -Path $ConfigPath
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function New-WizardFont {
    param([float]$Size, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    return [System.Drawing.Font]::new("Segoe UI", $Size, $Style)
}

function Add-WizardHatPanel {
    param([System.Windows.Forms.Control]$Parent)
    $panel = [System.Windows.Forms.Panel]::new()
    $panel.Width = 126
    $panel.Height = 112
    $panel.Left = 24
    $panel.Top = 22
    $panel.BackColor = [System.Drawing.Color]::Transparent
    $panel.Add_Paint({
        param($sender, $event)
        $g = $event.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $purple = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(82, 62, 160))
        $purpleDark = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(44, 38, 90))
        $gold = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(246, 189, 96))
        $line = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(35, 31, 63), 3)
        $points = [System.Drawing.Point[]]@(
            [System.Drawing.Point]::new(32, 80),
            [System.Drawing.Point]::new(66, 8),
            [System.Drawing.Point]::new(94, 80)
        )
        $g.FillPolygon($purple, $points)
        $g.DrawPolygon($line, $points)
        $g.FillEllipse($purpleDark, 12, 72, 100, 22)
        $g.DrawEllipse($line, 12, 72, 100, 22)
        foreach ($star in @(
            [System.Drawing.Rectangle]::new(58, 26, 8, 8),
            [System.Drawing.Rectangle]::new(74, 45, 7, 7),
            [System.Drawing.Rectangle]::new(49, 56, 6, 6)
        )) {
            $g.FillEllipse($gold, $star)
        }
        $purple.Dispose()
        $purpleDark.Dispose()
        $gold.Dispose()
        $line.Dispose()
    })
    $Parent.Controls.Add($panel)
    return $panel
}

function New-WizardForm {
    $form = [System.Windows.Forms.Form]::new()
    $form.Text = "HyperSearch Installation Wizard"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.Width = 760
    $form.Height = 560
    $form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 252)
    $form.Font = New-WizardFont -Size 9
    return $form
}

function Add-PageTitle {
    param(
        [System.Windows.Forms.Control]$Parent,
        [string]$Title,
        [string]$Subtitle = ""
    )
    $label = [System.Windows.Forms.Label]::new()
    $label.AutoSize = $false
    $label.Left = 176
    $label.Top = 28
    $label.Width = 520
    $label.Height = 38
    $label.Text = $Title
    $label.Font = New-WizardFont -Size 18 -Style ([System.Drawing.FontStyle]::Bold)
    $Parent.Controls.Add($label)
    if ($Subtitle) {
        $sub = [System.Windows.Forms.Label]::new()
        $sub.AutoSize = $false
        $sub.Left = 178
        $sub.Top = 70
        $sub.Width = 520
        $sub.Height = 52
        $sub.Text = $Subtitle
        $sub.Font = New-WizardFont -Size 10
        $Parent.Controls.Add($sub)
    }
}

function New-PrimaryButton {
    param([string]$Text, [int]$Left, [int]$Top)
    $button = [System.Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.Left = $Left
    $button.Top = $Top
    $button.Width = 112
    $button.Height = 34
    return $button
}

function Show-WelcomePage {
    $form = New-WizardForm
    Add-WizardHatPanel -Parent $form | Out-Null
    Add-PageTitle -Parent $form -Title "HyperSearch Installation Wizard" -Subtitle "This wizard installs HyperSearch and prepares the local services it needs. Standard install is the recommended full setup for version 1.1."

    $body = [System.Windows.Forms.Label]::new()
    $body.Left = 178
    $body.Top = 146
    $body.Width = 520
    $body.Height = 190
    $body.Text = @(
        "Standard install will check Windows, WSL, Docker Desktop, bundled Docker images, LM Studio, and HyperSearch service health in one guided run.",
        "",
        "The wizard writes detailed logs and a diagnostics bundle under your local HyperSearch data folder, so install failures can be reviewed without hunting for screenshots."
    ) -join "`r`n"
    $body.Font = New-WizardFont -Size 10
    $form.Controls.Add($body)

    $next = New-PrimaryButton -Text "Next" -Left 596 -Top 468
    $cancel = New-PrimaryButton -Text "Cancel" -Left 472 -Top 468
    $form.Controls.Add($next)
    $form.Controls.Add($cancel)
    $script:welcomeResult = $false
    $next.Add_Click({ $script:welcomeResult = $true; $form.Close() })
    $cancel.Add_Click({ $script:welcomeResult = $false; $form.Close() })
    [void]$form.ShowDialog()
    return $script:welcomeResult
}

function Show-LicensePage {
    $form = New-WizardForm
    Add-WizardHatPanel -Parent $form | Out-Null
    Add-PageTitle -Parent $form -Title "License Consent" -Subtitle "HyperSearch can pass silent installer agreement flags only after you explicitly accept the relevant license terms here."

    $box = [System.Windows.Forms.TextBox]::new()
    $box.Left = 178
    $box.Top = 128
    $box.Width = 520
    $box.Height = 236
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = "Vertical"
    $box.Text = @(
        "By continuing, you confirm that you accept the licenses and notices for the components selected on the next page.",
        "",
        "Components:",
        "- HyperSearch and bundled third-party notices",
        "- Docker Desktop, when Docker install or repair is selected",
        "- LM Studio, when LM Studio install is selected",
        "",
        "The wizard records this consent in the setup summary. Docker Desktop may still show its own first-run product prompts; HyperSearch avoids Docker Hub pulls in the Full installer so Docker sign-in is not required for HyperSearch startup."
    ) -join "`r`n"
    $form.Controls.Add($box)

    $check = [System.Windows.Forms.CheckBox]::new()
    $check.Left = 178
    $check.Top = 382
    $check.Width = 520
    $check.Height = 38
    $check.Text = "I accept the selected component licenses and allow the wizard to pass installer agreement flags."
    $form.Controls.Add($check)

    $back = New-PrimaryButton -Text "Back" -Left 348 -Top 468
    $next = New-PrimaryButton -Text "Next" -Left 596 -Top 468
    $cancel = New-PrimaryButton -Text "Cancel" -Left 472 -Top 468
    $next.Enabled = $false
    $check.Add_CheckedChanged({ $next.Enabled = $check.Checked })
    $form.Controls.Add($back)
    $form.Controls.Add($cancel)
    $form.Controls.Add($next)
    $script:licenseResult = "cancel"
    $back.Add_Click({ $script:licenseResult = "back"; $form.Close() })
    $cancel.Add_Click({ $script:licenseResult = "cancel"; $form.Close() })
    $next.Add_Click({ $script:licenseResult = "next"; $form.Close() })
    [void]$form.ShowDialog()
    return $script:licenseResult
}

function Show-ModePage {
    $form = New-WizardForm
    Add-WizardHatPanel -Parent $form | Out-Null
    Add-PageTitle -Parent $form -Title "Install Type" -Subtitle "Standard is the one-run Full installer path. Custom exposes component choices for controlled troubleshooting or advanced deployments."

    $standard = [System.Windows.Forms.RadioButton]::new()
    $standard.Left = 178
    $standard.Top = 130
    $standard.Width = 520
    $standard.Height = 32
    $standard.Text = "Standard install: Docker, bundled images, LM Studio, stack startup, and guided setup"
    $standard.Checked = $true
    $form.Controls.Add($standard)

    $custom = [System.Windows.Forms.RadioButton]::new()
    $custom.Left = 178
    $custom.Top = 166
    $custom.Width = 520
    $custom.Height = 32
    $custom.Text = "Custom install: choose which components and image source to use"
    $form.Controls.Add($custom)

    $group = [System.Windows.Forms.GroupBox]::new()
    $group.Left = 178
    $group.Top = 216
    $group.Width = 520
    $group.Height = 194
    $group.Text = "Custom options"
    $group.Enabled = $false
    $form.Controls.Add($group)

    $installDocker = [System.Windows.Forms.CheckBox]::new()
    $installDocker.Left = 18
    $installDocker.Top = 30
    $installDocker.Width = 228
    $installDocker.Text = "Install or repair Docker Desktop"
    $installDocker.Checked = $true
    $group.Controls.Add($installDocker)

    $installLm = [System.Windows.Forms.CheckBox]::new()
    $installLm.Left = 18
    $installLm.Top = 62
    $installLm.Width = 228
    $installLm.Text = "Install LM Studio"
    $installLm.Checked = $true
    $group.Controls.Add($installLm)

    $startStack = [System.Windows.Forms.CheckBox]::new()
    $startStack.Left = 18
    $startStack.Top = 94
    $startStack.Width = 228
    $startStack.Text = "Start HyperSearch after setup"
    $startStack.Checked = $true
    $group.Controls.Add($startStack)

    $dockerModeLabel = [System.Windows.Forms.Label]::new()
    $dockerModeLabel.Left = 280
    $dockerModeLabel.Top = 31
    $dockerModeLabel.Width = 200
    $dockerModeLabel.Text = "Docker install mode"
    $group.Controls.Add($dockerModeLabel)

    $dockerMode = [System.Windows.Forms.ComboBox]::new()
    $dockerMode.Left = 280
    $dockerMode.Top = 54
    $dockerMode.Width = 190
    $dockerMode.DropDownStyle = "DropDownList"
    [void]$dockerMode.Items.Add("per-user")
    [void]$dockerMode.Items.Add("all-users")
    $dockerMode.SelectedIndex = 0
    $group.Controls.Add($dockerMode)

    $imageLabel = [System.Windows.Forms.Label]::new()
    $imageLabel.Left = 280
    $imageLabel.Top = 92
    $imageLabel.Width = 200
    $imageLabel.Text = "Docker images"
    $group.Controls.Add($imageLabel)

    $imageSource = [System.Windows.Forms.ComboBox]::new()
    $imageSource.Left = 280
    $imageSource.Top = 116
    $imageSource.Width = 190
    $imageSource.DropDownStyle = "DropDownList"
    [void]$imageSource.Items.Add("bundled")
    [void]$imageSource.Items.Add("online")
    [void]$imageSource.Items.Add("skip")
    $imageSource.SelectedIndex = 0
    $group.Controls.Add($imageSource)

    $custom.Add_CheckedChanged({ $group.Enabled = $custom.Checked })
    $standard.Add_CheckedChanged({ $group.Enabled = $custom.Checked })

    $loginAutostart = [System.Windows.Forms.CheckBox]::new()
    $loginAutostart.Left = 178
    $loginAutostart.Top = 420
    $loginAutostart.Width = 520
    $loginAutostart.Height = 28
    $loginAutostart.Text = "Start HyperSearch when I sign into Windows"
    $loginAutostart.Checked = $false
    $form.Controls.Add($loginAutostart)

    $back = New-PrimaryButton -Text "Back" -Left 348 -Top 468
    $next = New-PrimaryButton -Text "Next" -Left 596 -Top 468
    $cancel = New-PrimaryButton -Text "Cancel" -Left 472 -Top 468
    $form.Controls.Add($back)
    $form.Controls.Add($cancel)
    $form.Controls.Add($next)

    $script:modeResult = @{ action = "cancel" }
    $back.Add_Click({ $script:modeResult = @{ action = "back" }; $form.Close() })
    $cancel.Add_Click({ $script:modeResult = @{ action = "cancel" }; $form.Close() })
    $next.Add_Click({
        if ($standard.Checked) {
            $script:modeResult = @{
                action = "next"
                installMode = "standard"
                installDocker = $true
                dockerInstallMode = "per-user"
                repairDocker = $true
                installLmStudio = $true
                imageSource = "bundled"
                startStack = $true
                enableLoginAutostart = [bool]$loginAutostart.Checked
            }
        } else {
            $script:modeResult = @{
                action = "next"
                installMode = "custom"
                installDocker = [bool]$installDocker.Checked
                dockerInstallMode = [string]$dockerMode.SelectedItem
                repairDocker = [bool]$installDocker.Checked
                installLmStudio = [bool]$installLm.Checked
                imageSource = [string]$imageSource.SelectedItem
                startStack = [bool]$startStack.Checked
                enableLoginAutostart = [bool]$loginAutostart.Checked
            }
        }
        $form.Close()
    })
    [void]$form.ShowDialog()
    return $script:modeResult
}

function Show-ProfilePage {
    $form = New-WizardForm
    Add-WizardHatPanel -Parent $form | Out-Null
    Add-PageTitle -Parent $form -Title "Setup Profile" -Subtitle "These choices are written to the HyperSearch install profile and imported by the desktop app on first launch."

    $usageLabel = [System.Windows.Forms.Label]::new()
    $usageLabel.Left = 178
    $usageLabel.Top = 132
    $usageLabel.Width = 220
    $usageLabel.Text = "How will you use HyperSearch?"
    $form.Controls.Add($usageLabel)

    $usage = [System.Windows.Forms.ComboBox]::new()
    $usage.Left = 178
    $usage.Top = 158
    $usage.Width = 320
    $usage.DropDownStyle = "DropDownList"
    [void]$usage.Items.Add("general-research")
    [void]$usage.Items.Add("document-review")
    [void]$usage.Items.Add("code-and-technical-search")
    [void]$usage.Items.Add("search-only")
    $usage.SelectedIndex = 0
    $form.Controls.Add($usage)

    $modelLabel = [System.Windows.Forms.Label]::new()
    $modelLabel.Left = 178
    $modelLabel.Top = 214
    $modelLabel.Width = 320
    $modelLabel.Text = "Local model"
    $form.Controls.Add($modelLabel)

    $model = [System.Windows.Forms.ComboBox]::new()
    $model.Left = 178
    $model.Top = 240
    $model.Width = 410
    $model.DropDownStyle = "DropDownList"
    [void]$model.Items.Add("recommended")
    [void]$model.Items.Add("google/gemma-3-1B-it-QAT")
    [void]$model.Items.Add("qwen2.5-7b-1m")
    [void]$model.Items.Add("openai/gpt-oss-20b")
    [void]$model.Items.Add("search-only")
    $model.SelectedIndex = 0
    $form.Controls.Add($model)

    $download = [System.Windows.Forms.CheckBox]::new()
    $download.Left = 178
    $download.Top = 296
    $download.Width = 430
    $download.Height = 34
    $download.Text = "Attempt non-interactive model download when LM Studio supports it"
    $download.Checked = $true
    $form.Controls.Add($download)

    $note = [System.Windows.Forms.Label]::new()
    $note.Left = 178
    $note.Top = 342
    $note.Width = 520
    $note.Height = 58
    $note.Text = "Model download is optional. If LM Studio cannot download non-interactively, the wizard marks the model as pending while keeping the search stack installed and verified."
    $form.Controls.Add($note)

    $back = New-PrimaryButton -Text "Back" -Left 348 -Top 468
    $next = New-PrimaryButton -Text "Install" -Left 596 -Top 468
    $cancel = New-PrimaryButton -Text "Cancel" -Left 472 -Top 468
    $form.Controls.Add($back)
    $form.Controls.Add($cancel)
    $form.Controls.Add($next)

    $script:profileResult = @{ action = "cancel" }
    $back.Add_Click({ $script:profileResult = @{ action = "back" }; $form.Close() })
    $cancel.Add_Click({ $script:profileResult = @{ action = "cancel" }; $form.Close() })
    $next.Add_Click({
        $script:profileResult = @{
            action = "next"
            usagePreset = [string]$usage.SelectedItem
            selectedModel = [string]$model.SelectedItem
            downloadModel = [bool]$download.Checked
        }
        $form.Close()
    })
    [void]$form.ShowDialog()
    return $script:profileResult
}

function Show-ProgressPage {
    param([hashtable]$Mode, [hashtable]$Profile)

    $form = New-WizardForm
    $form.ControlBox = $false
    Add-WizardHatPanel -Parent $form | Out-Null
    Add-PageTitle -Parent $form -Title "Installing HyperSearch" -Subtitle "The wizard is checking prerequisites, loading bundled images, starting services, and collecting diagnostics."

    $statusList = [System.Windows.Forms.ListView]::new()
    $statusList.Left = 178
    $statusList.Top = 128
    $statusList.Width = 520
    $statusList.Height = 206
    $statusList.View = "Details"
    $statusList.FullRowSelect = $true
    [void]$statusList.Columns.Add("Step", 130)
    [void]$statusList.Columns.Add("Status", 90)
    [void]$statusList.Columns.Add("Message", 290)
    $form.Controls.Add($statusList)

    $logBox = [System.Windows.Forms.TextBox]::new()
    $logBox.Left = 178
    $logBox.Top = 346
    $logBox.Width = 520
    $logBox.Height = 76
    $logBox.Multiline = $true
    $logBox.ReadOnly = $true
    $logBox.ScrollBars = "Vertical"
    $form.Controls.Add($logBox)

    $progress = [System.Windows.Forms.ProgressBar]::new()
    $progress.Left = 178
    $progress.Top = 438
    $progress.Width = 520
    $progress.Height = 16
    $progress.Style = "Marquee"
    $form.Controls.Add($progress)

    $finish = New-PrimaryButton -Text "Finish" -Left 596 -Top 468
    $finish.Enabled = $false
    $form.Controls.Add($finish)

    $items = @{}
    foreach ($step in @("prerequisites", "runtime", "wsl", "docker", "images", "lmstudio", "autostart", "profile", "stack", "model", "diagnostics")) {
        $item = [System.Windows.Forms.ListViewItem]::new($step)
        [void]$item.SubItems.Add("not_started")
        [void]$item.SubItems.Add("")
        [void]$statusList.Items.Add($item)
        $items[$step] = $item
    }

    $script:installState = $null
    $script:installDone = $false
    $onStep = {
        param($name, $status, $message)
        $update = {
            if ($items.ContainsKey($name)) {
                $items[$name].SubItems[1].Text = $status
                $items[$name].SubItems[2].Text = $message
            }
            $logBox.AppendText(("[{0}] {1}: {2}`r`n" -f (Get-Date -Format "HH:mm:ss"), $name, $status))
        }
        if ($form.InvokeRequired) {
            [void]$form.BeginInvoke([System.Action]$update)
        } else {
            & $update
        }
    }

    $form.Add_Shown({
        $worker = [System.ComponentModel.BackgroundWorker]::new()
        $worker.DoWork += {
            $options = New-HyperSearchInstallerOptions `
                -InstallDir $InstallDir `
                -MediaDir $MediaDir `
                -InstallMode $Mode.installMode `
                -AcceptedLicenses:$true `
                -InstallDocker:([bool]$Mode.installDocker) `
                -DockerInstallMode $Mode.dockerInstallMode `
                -RepairDocker:([bool]$Mode.repairDocker) `
                -InstallLmStudio:([bool]$Mode.installLmStudio) `
                -ImageSource $Mode.imageSource `
                -StartStack:([bool]$Mode.startStack) `
                -EnableLoginAutostart:([bool]$Mode.enableLoginAutostart) `
                -UsagePreset $Profile.usagePreset `
                -SelectedModel $Profile.selectedModel `
                -DownloadModel:([bool]$Profile.downloadModel) `
                -OnStep $onStep
            $script:installState = Invoke-HyperSearchInstallation -Options $options
        }
        $worker.RunWorkerCompleted += {
            $script:installDone = $true
            $progress.Style = "Blocks"
            $progress.Value = 100
            $finish.Enabled = $true
            $form.ControlBox = $true
            if ($script:installState) {
                $logBox.AppendText(("Result: {0}`r`nLogs: {1}`r`nDiagnostics: {2}`r`n" -f $script:installState.result, $script:installState.logPath, $script:installState.diagnostics.bundlePath))
            }
        }
        $worker.RunWorkerAsync()
    })

    $finish.Add_Click({ $form.Close() })
    [void]$form.ShowDialog()
    return $script:installState
}

function Show-FinishPage {
    param($State)
    $result = if ($State) { $State.result } else { "failed" }
    $message = if ($State) {
        @(
            "HyperSearch Installation Wizard finished with result: $result",
            "",
            "Setup summary: $($State.summaryPath)",
            "Installer log: $($State.logPath)",
            "Diagnostics: $($State.diagnostics.bundlePath)",
            "",
            "If the result is blocked or warning, the diagnostics bundle has the command logs and setup state needed for review."
        ) -join "`r`n"
    } else {
        "HyperSearch Installation Wizard did not return setup state. Check the installer logs under %LOCALAPPDATA%\HyperSearch\logs."
    }
    $icon = if ($result -eq "passed" -or $result -eq "warning") { [System.Windows.Forms.MessageBoxIcon]::Information } else { [System.Windows.Forms.MessageBoxIcon]::Warning }
    [System.Windows.Forms.MessageBox]::Show($message, "HyperSearch Installation Wizard", [System.Windows.Forms.MessageBoxButtons]::OK, $icon) | Out-Null
}

$page = "welcome"
$mode = $null
$profile = $null
while ($true) {
    switch ($page) {
        "welcome" {
            if (Show-WelcomePage) { $page = "license" } else { exit 0 }
        }
        "license" {
            $result = Show-LicensePage
            if ($result -eq "next") { $page = "mode" }
            elseif ($result -eq "back") { $page = "welcome" }
            else { exit 0 }
        }
        "mode" {
            $mode = Show-ModePage
            if ($mode.action -eq "next") { $page = "profile" }
            elseif ($mode.action -eq "back") { $page = "license" }
            else { exit 0 }
        }
        "profile" {
            $profile = Show-ProfilePage
            if ($profile.action -eq "next") { $page = "progress" }
            elseif ($profile.action -eq "back") { $page = "mode" }
            else { exit 0 }
        }
        "progress" {
            $state = Show-ProgressPage -Mode $mode -Profile $profile
            Show-FinishPage -State $state
            if ($state -and ($state.result -eq "failed")) { exit 1 }
            exit 0
        }
    }
}
