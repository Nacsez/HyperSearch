[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [Parameter(Mandatory = $true)][string]$IsoPath,
    [string]$LabRoot = "E:\HyperSearchInstallerLab",
    [string]$SwitchName = "Default Switch",
    [string]$ImageName = "",
    [int]$ImageIndex = 0,
    [string]$LocalAdminUser = "HyperSearchAdmin",
    [string]$LocalAdminPasswordEnv = "HYPERSEARCH_LAB_GUEST_PASSWORD",
    [string]$PasswordCredentialPath = "C:\tmp\hypersearch-lab-credential.xml",
    [string]$CredentialOutputPath = "C:\tmp\hypersearch-lab-credential.xml",
    [string]$CheckpointName = "clean-windows-docker-supported-ready",
    [int]$ProcessorCount = 8,
    [Int64]$MemoryStartupBytes = 17179869184,
    [UInt64]$VhdSizeBytes = 85899345920,
    [int]$GuestReadyTimeoutSeconds = 1800,
    [switch]$EnableTpm,
    [switch]$AllowUnsupportedBuild,
    [switch]$StartVM,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Utf8NoBom {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowNull()]$Value = "")
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, [string]$Value, [System.Text.UTF8Encoding]::new($false))
}

function Write-Step {
    param([string]$Message)
    Write-Host "[HyperSearchLab] $Message"
}

function Assert-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "ISO lab VM creation must run from an elevated PowerShell session."
    }
}

function Assert-PathInside {
    param([string]$Root, [string]$Path)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate on path outside lab root. Root=$rootFull Path=$pathFull"
    }
}

function ConvertFrom-SecureStringToPlainText {
    param([Security.SecureString]$SecureString)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        if ($ptr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
}

function Get-LabAdminPassword {
    param([string]$EnvName, [string]$CredentialPath)
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return $fromEnv
    }
    if ($CredentialPath -and (Test-Path $CredentialPath)) {
        $credential = Import-Clixml -LiteralPath $CredentialPath
        if ($credential -is [Management.Automation.PSCredential]) {
            return ConvertFrom-SecureStringToPlainText -SecureString $credential.Password
        }
    }
    throw "Set $EnvName or provide PasswordCredentialPath with a PSCredential so the unattended VM can create local admin '$LocalAdminUser'."
}

function Export-LabCredential {
    param([string]$Path, [string]$User, [string]$Password)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    [Management.Automation.PSCredential]::new($User, $secure) | Export-Clixml -Path $Path
}

function ConvertTo-XmlEscapedText {
    param([string]$Value)
    return [Security.SecurityElement]::Escape($Value)
}

function Get-ComputerNameForUnattend {
    param([string]$Name)
    $clean = ($Name -replace '[^A-Za-z0-9-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = "HSEARCHLAB" }
    if ($clean.Length -gt 15) { $clean = $clean.Substring(0, 15).Trim('-') }
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = "HSEARCHLAB" }
    return $clean
}

function New-UnattendXml {
    param([string]$ComputerName, [string]$AdminUser, [string]$AdminPassword)
    $computer = ConvertTo-XmlEscapedText $ComputerName
    $user = ConvertTo-XmlEscapedText $AdminUser
    $password = ConvertTo-XmlEscapedText $AdminPassword
    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>$computer</ComputerName>
      <RegisteredOrganization>HyperSearch Installer Lab</RegisteredOrganization>
      <RegisteredOwner>HyperSearch</RegisteredOwner>
      <TimeZone>Eastern Standard Time</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>$user</Name>
            <Group>Administrators</Group>
            <DisplayName>$user</DisplayName>
            <Password>
              <Value>$password</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <AutoLogon>
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
        <Username>$user</Username>
        <Password>
          <Value>$password</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <Description>Relax UAC for unattended HyperSearch lab automation</Description>
          <CommandLine>cmd /c reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLUA /t REG_DWORD /d 0 /f &amp; reg add HKLM\SOFTWARE\Policies\Microsoft\Windows\System /v EnableSmartScreen /t REG_DWORD /d 0 /f &amp; reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer /v SmartScreenEnabled /t REG_SZ /d Off /f</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <Description>Ensure HyperSearch lab user remains in Administrators</Description>
          <CommandLine>cmd /c net localgroup Administrators "$user" /add</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <Description>Enable built-in Administrator as an emergency elevated automation account</Description>
          <CommandLine>cmd /c net user Administrator "$password" /active:yes</CommandLine>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>4</Order>
          <Description>Mark HyperSearch lab bootstrap complete</Description>
          <CommandLine>cmd /c mkdir C:\HyperSearchInstallerLab &amp; echo ready&gt;C:\HyperSearchInstallerLab\first-logon-ready.txt</CommandLine>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
}

function Set-OfflineLabAutomationRegistry {
    param([string]$WindowsDrive)
    $hiveName = "HKLM\HyperSearchLabSoftware"
    $hivePath = "${WindowsDrive}:\Windows\System32\Config\SOFTWARE"
    & reg.exe load $hiveName $hivePath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not load offline SOFTWARE hive from $hivePath." }
    try {
        & reg.exe add "$hiveName\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLUA /t REG_DWORD /d 0 /f | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not set offline EnableLUA." }
        & reg.exe add "$hiveName\Policies\Microsoft\Windows\System" /v EnableSmartScreen /t REG_DWORD /d 0 /f | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not set offline EnableSmartScreen policy." }
        & reg.exe add "$hiveName\Microsoft\Windows\CurrentVersion\Explorer" /v SmartScreenEnabled /t REG_SZ /d Off /f | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not set offline SmartScreenEnabled." }
    } finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        & reg.exe unload $hiveName | Out-Null
    }
}

function Get-InstallImagePath {
    param([string]$IsoDrive)
    foreach ($relative in @("sources\install.wim", "sources\install.esd")) {
        $path = Join-Path "${IsoDrive}:\" $relative
        if (Test-Path $path) { return $path }
    }
    throw "No sources\install.wim or sources\install.esd was found in mounted ISO drive $IsoDrive."
}

function Select-InstallImage {
    param([string]$ImagePath, [string]$Name, [int]$Index)
    $images = @(Get-WindowsImage -ImagePath $ImagePath)
    if ($Index -gt 0) {
        $match = $images | Where-Object { [int]$_.ImageIndex -eq $Index } | Select-Object -First 1
        if ($match) { return $match }
        throw "Image index $Index was not found in $ImagePath."
    }
    if ($Name) {
        $match = $images | Where-Object { $_.ImageName -like $Name -or $_.ImageName -match [regex]::Escape($Name) } | Select-Object -First 1
        if ($match) { return $match }
        throw "Image name '$Name' was not found in $ImagePath. Available: $(@($images.ImageName) -join '; ')"
    }
    $preferred = @(
        "Windows 11 Enterprise Evaluation",
        "Windows 10 Enterprise Evaluation",
        "Windows 11 Enterprise",
        "Windows 10 Enterprise",
        "Windows 11 Pro",
        "Windows 10 Pro"
    )
    foreach ($candidate in $preferred) {
        $match = $images | Where-Object { $_.ImageName -eq $candidate } | Select-Object -First 1
        if ($match) { return $match }
    }
    return $images | Select-Object -First 1
}

function Test-DockerSupportedGuestOs {
    param($State)
    $caption = [string]$State.caption
    $build = [int]$State.buildNumber
    $edition = [string]$State.editionId
    $clientEdition = ($edition -match "Enterprise|Professional|Education")
    if ($caption -match "Windows 10") {
        return [pscustomobject]@{ supported = ($build -ge 19045 -and $clientEdition); reason = "Windows 10 requires build 19045+ on Pro, Enterprise, or Education for Docker Desktop."; buildNumber = $build; editionId = $edition }
    }
    if ($caption -match "Windows 11") {
        return [pscustomobject]@{ supported = ($build -ge 22631 -and $clientEdition); reason = "Windows 11 requires build 22631+ on Pro, Enterprise, or Education for Docker Desktop."; buildNumber = $build; editionId = $edition }
    }
    return [pscustomobject]@{ supported = $false; reason = "Docker Desktop release gate requires Windows 10 or Windows 11 client."; buildNumber = $build; editionId = $edition }
}

function Wait-GuestReady {
    param([string]$Name, [Management.Automation.PSCredential]$Credential, [int]$TimeoutSeconds)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            return Invoke-Command -VMName $Name -Credential $Credential -ScriptBlock {
                $os = Get-CimInstance Win32_OperatingSystem
                $cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
                [pscustomobject]@{
                    computerName = $env:COMPUTERNAME
                    user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                    caption = $os.Caption
                    version = $os.Version
                    buildNumber = [int]$os.BuildNumber
                    displayVersion = [string]$cv.DisplayVersion
                    ubr = $cv.UBR
                    editionId = [string]$cv.EditionID
                    freeGb = [math]::Round((Get-PSDrive C).Free / 1GB, 2)
                }
            } -ErrorAction Stop
        } catch {
            Write-Step "Waiting for PowerShell Direct on ${Name}: $($_.Exception.Message)"
            Start-Sleep -Seconds 15
        }
    } while ((Get-Date) -lt $deadline)
    throw "PowerShell Direct did not become ready for '$Name' within $TimeoutSeconds seconds."
}

Assert-Admin
Import-Module Hyper-V -ErrorAction Stop
Import-Module Dism -ErrorAction Stop

if (!(Test-Path $IsoPath)) { throw "ISO was not found: $IsoPath" }

$labRootFull = [System.IO.Path]::GetFullPath($LabRoot)
$vmRoot = Join-Path $labRootFull "vms"
$vhdRoot = Join-Path $labRootFull "vhds"
$answerRoot = Join-Path $labRootFull "unattend"
New-Item -ItemType Directory -Force -Path $vmRoot, $vhdRoot, $answerRoot | Out-Null

$vhdPath = Join-Path $vhdRoot "$VMName.vhdx"
Assert-PathInside -Root $labRootFull -Path $vhdPath

$adminPassword = Get-LabAdminPassword -EnvName $LocalAdminPasswordEnv -CredentialPath $PasswordCredentialPath
Export-LabCredential -Path $CredentialOutputPath -User $LocalAdminUser -Password $adminPassword
$guestCredential = [Management.Automation.PSCredential]::new($LocalAdminUser, (ConvertTo-SecureString $adminPassword -AsPlainText -Force))

$existing = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existing) {
    if (-not $Force) { throw "VM '$VMName' already exists. Use -Force to replace it." }
    if ($PSCmdlet.ShouldProcess($VMName, "Remove existing VM")) {
        if ($existing.State -ne "Off") { Stop-VM -Name $VMName -TurnOff -Force }
        Remove-VM -Name $VMName -Force
    }
}

if ((Test-Path $vhdPath) -and $Force) {
    if ($PSCmdlet.ShouldProcess($vhdPath, "Remove existing VHDX")) {
        Remove-Item -LiteralPath $vhdPath -Force
    }
}
if (Test-Path $vhdPath) { throw "VHD already exists: $vhdPath" }

$iso = $null
$disk = $null
$windowsDrive = ""
$efiDrive = ""
$result = [ordered]@{
    vmName = $VMName
    isoPath = $IsoPath
    labRoot = $labRootFull
    vhdPath = $vhdPath
    imageName = ""
    imageIndex = 0
    checkpoint = $CheckpointName
    os = $null
    dockerSupport = $null
    credentialOutputPath = $CredentialOutputPath
}

try {
    Write-Step "Mounting ISO: $IsoPath"
    $iso = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $isoVolume = $iso | Get-Volume | Select-Object -First 1
    if (-not $isoVolume.DriveLetter) { throw "Mounted ISO did not receive a drive letter." }
    $installImage = Get-InstallImagePath -IsoDrive $isoVolume.DriveLetter
    $selected = Select-InstallImage -ImagePath $installImage -Name $ImageName -Index $ImageIndex
    $result.imageName = [string]$selected.ImageName
    $result.imageIndex = [int]$selected.ImageIndex
    Write-Step "Selected image index $($selected.ImageIndex): $($selected.ImageName)"

    Write-Step "Creating VHDX: $vhdPath"
    New-VHD -Path $vhdPath -SizeBytes $VhdSizeBytes -Dynamic | Out-Null
    $disk = Mount-VHD -Path $vhdPath -PassThru | Get-Disk
    Initialize-Disk -Number $disk.Number -PartitionStyle GPT

    $efi = New-Partition -DiskNumber $disk.Number -Size 260MB -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -AssignDriveLetter
    Format-Volume -Partition $efi -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false | Out-Null
    $efiDrive = ($efi | Get-Volume).DriveLetter

    New-Partition -DiskNumber $disk.Number -Size 16MB -GptType "{e3c9e316-0b5c-4db8-817d-f92df00215ae}" | Out-Null

    $windows = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $windows -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null
    $windowsDrive = ($windows | Get-Volume).DriveLetter

    Write-Step "Applying Windows image to ${windowsDrive}:\"
    Expand-WindowsImage -ImagePath $installImage -Index ([int]$selected.ImageIndex) -ApplyPath "${windowsDrive}:\" | Out-Null

    $panther = "${windowsDrive}:\Windows\Panther"
    New-Item -ItemType Directory -Force -Path $panther | Out-Null
    $unattendPath = Join-Path $panther "Unattend.xml"
    Write-Utf8NoBom -Path $unattendPath -Value (New-UnattendXml -ComputerName (Get-ComputerNameForUnattend -Name $VMName) -AdminUser $LocalAdminUser -AdminPassword $adminPassword)

    Write-Step "Applying offline lab automation registry settings."
    Set-OfflineLabAutomationRegistry -WindowsDrive $windowsDrive

    Write-Step "Creating UEFI boot files."
    & bcdboot.exe "${windowsDrive}:\Windows" /s "${efiDrive}:" /f UEFI | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "bcdboot failed with exit code $LASTEXITCODE." }
} finally {
    if ($disk) {
        Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue
    }
    if ($iso) {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue
    }
}

Write-Step "Creating VM $VMName."
New-VM -Name $VMName -Generation 2 -MemoryStartupBytes $MemoryStartupBytes -VHDPath $vhdPath -Path $vmRoot -SwitchName $SwitchName | Out-Null
Set-VMProcessor -VMName $VMName -Count $ProcessorCount -ExposeVirtualizationExtensions $true
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes $MemoryStartupBytes
Set-VM -Name $VMName -CheckpointType Standard -AutomaticCheckpointsEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate "MicrosoftWindows"
Enable-VMIntegrationService -VMName $VMName -Name "Guest Service Interface" -ErrorAction SilentlyContinue

if ($EnableTpm) {
    Write-Step "Enabling VM TPM."
    Set-VMKeyProtector -VMName $VMName -NewLocalKeyProtector
    Enable-VMTPM -VMName $VMName
}

if ($StartVM -or $CheckpointName) {
    Write-Step "Starting VM and waiting for first boot."
    Start-VM -Name $VMName | Out-Null
    $guestState = Wait-GuestReady -Name $VMName -Credential $guestCredential -TimeoutSeconds $GuestReadyTimeoutSeconds
    $result.os = $guestState
    $result.dockerSupport = Test-DockerSupportedGuestOs -State $guestState
    Write-Step "Guest ready: $($guestState.caption) $($guestState.displayVersion) build $($guestState.buildNumber).$($guestState.ubr)"
    if (-not $result.dockerSupport.supported -and -not $AllowUnsupportedBuild) {
        throw "Guest does not meet Docker Desktop release-gate floor: $($result.dockerSupport.reason)"
    }
    if ($CheckpointName) {
        $existingSnapshot = Get-VMSnapshot -VMName $VMName -Name $CheckpointName -ErrorAction SilentlyContinue
        if ($existingSnapshot) {
            Remove-VMSnapshot -VMName $VMName -Name $CheckpointName -Confirm:$false
        }
        Write-Step "Creating checkpoint $CheckpointName."
        Checkpoint-VM -Name $VMName -SnapshotName $CheckpointName | Out-Null
    }
    if (-not $StartVM) {
        Stop-VM -Name $VMName -TurnOff -Force
    }
}

$result | ConvertTo-Json -Depth 8
