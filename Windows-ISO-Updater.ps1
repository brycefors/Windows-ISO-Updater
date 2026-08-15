# --- SCRIPT OVERVIEW ---
# This script builds a fully up-to-date ("slipstreamed") Windows 11 (or Windows 10) installation ISO.
# It downloads the latest official Microsoft ISO, downloads the latest cumulative update(s) from the
# Microsoft Update Catalog, integrates those updates directly into the Windows images inside the ISO,
# and then recompiles a brand-new, bootable ISO that already contains this month's patches.
#
# Building patched media means a fresh install (or in-place upgrade) starts already updated, instead of
# spending an hour downloading and installing the same cumulative update after Setup finishes.
#
# It performs the following actions:
#   1. Obtains the matching official Microsoft ISO (via the community "Fido" helper, which queries
#      Microsoft's own software-download servers) and downloads it - unless you supply one with -IsoPath.
#      Blocked link requests are retried with a backoff (-FidoRetryCount), and if they still fail the
#      script can open Microsoft's Media Creation Tool for you instead (-UseMct) - MCT talks to different
#      servers, but it has no headless mode, so you click through its last few pages yourself.
#      RECOMMENDED: download the ISO yourself and pass it with -IsoPath. Microsoft rate-limits and can
#      temporarily block IPs that make repeated ISO requests, which breaks the automatic download; using
#      your own ISO avoids this (the script also reuses any ISO already in the download folder).
#   2. Extracts the ISO to a writable working folder.
#   3. Detects the Windows feature-update (e.g. 24H2) and architecture from the image, then downloads the
#      latest combined Servicing Stack + Cumulative Update (LCU) - and the .NET cumulative update
#      (on by default; disable with -SkipDotNet) - from the Microsoft Update Catalog. You may
#      instead point at your own .msu/.cab files with -UpdatePath.
#   4. Integrates the update(s) offline with DISM into install.wim (by default only the highest edition
#      present - e.g. Pro over Home - is kept and serviced; use -KeepAllEditions or -KeepEditions to
#      change this), boot.wim (Windows Setup / WinPE), and optionally winre.wim (recovery).
#   5. Refreshes the loose Setup files on the media: first applies the Setup Dynamic Update to the
#      sources folder (on by default; disable with -SkipSetupDU), then overwrites sources\setup.exe,
#      sources\setuphost.exe and the boot managers from the serviced boot.wim - Windows Setup fails if
#      those binaries don't match the version inside boot.wim - then cleans up the component store
#      (/StartComponentCleanup /ResetBase) and re-exports install.wim to shrink it.
#   6. Recompiles a new bootable ISO with oscdimg (downloaded from Microsoft if not already installed
#      with the Windows ADK), preserving both the BIOS and
#      UEFI boot sectors so the new ISO boots on legacy and modern PCs alike. An answer file supplied with
#      -UnattendPath is placed at the root of the media as autounattend.xml, which Windows Setup reads
#      automatically when the ISO is booted.
#
# This is disk- and time-intensive: with the default parameters a full run normally takes an hour or two.
# It needs a lot of free space (the download, the extracted media, the mounted image, and the exported
# image all coexist) and DISM servicing/cleanup can take a long time.
# Nothing on the running machine is changed - all servicing happens against files in the working folder.
# -------------------------------------------------
# How to Run .PS1 Script with PowerShell:
# NOTE: It is recommended to use the "Run-Windows-ISO-Updater.bat" to invoke this script. However, you can run the .PS1 directly if needed.
# 1.  Open PowerShell as an Administrator: Right-click your Start Menu and select "Terminal (Admin)".
# 2.  Enable Script Execution (if needed): Set-ExecutionPolicy Bypass -Force
# 3.  Run the Script: Right-click the saved "Windows-ISO-Updater.ps1" file and select "Run with PowerShell".
# -------------------------------------------------
# Parameters for the script
param(
    [Parameter(HelpMessage = 'Runs the script without any confirmation prompts')]
    [switch]$Unattended,

    [Parameter(HelpMessage = 'Path to an existing Windows ISO to update instead of downloading one from Microsoft')]
    [string]$IsoPath,

    [Parameter(HelpMessage = 'Windows version to download/update: 10 or 11. Defaults to 11')]
    [ValidateSet('10', '11')]
    [string]$WindowsVersion = '11',

    [Parameter(HelpMessage = 'Fido release to request (e.g. 24H2, 23H2) or "Latest". Defaults to Latest')]
    [string]$Release = 'Latest',

    [Parameter(HelpMessage = 'ISO language as named by Microsoft/Fido (e.g. English, "English International"). Defaults to English')]
    [string]$Language = 'English',

    [Parameter(HelpMessage = 'Which edition inside install.wim to service: "All" (default) or an edition name like "Windows 11 Pro"')]
    [string]$Edition = 'All',

    [Parameter(HelpMessage = 'Editions to KEEP in the final ISO, removing the rest to slim it down. Accepts edition names like "Windows 11 Pro" (partial matches allowed) or index numbers, comma-separated. Overrides the default of keeping only the highest edition')]
    [string[]]$KeepEditions,

    [Parameter(HelpMessage = 'Keep every edition in the final ISO. By default only the highest edition present (e.g. Enterprise over Pro, or Pro over Home) is kept to speed up servicing and shrink the ISO')]
    [switch]$KeepAllEditions,

    [Parameter(HelpMessage = 'Only list the editions/indexes inside the ISO''s install.wim and exit (does not download updates or build anything). Useful for choosing -Edition/-KeepEditions values')]
    [switch]$ListEditions,

    [Parameter(HelpMessage = 'Folder containing your own .msu/.cab update packages to integrate instead of fetching from the Microsoft Update Catalog')]
    [string]$UpdatePath,

    [Parameter(HelpMessage = 'Skip downloading and integrating the latest .NET cumulative update. The .NET update is included by default; use this switch to leave it out')]
    [switch]$SkipDotNet,

    [Parameter(HelpMessage = 'Skip the Setup Dynamic Update that refreshes the loose Windows Setup files on the media. It is included by default; without it the Windows 11 24H2+ Setup engine can fail with "Windows 11 installation has failed"')]
    [switch]$SkipSetupDU,

    [Parameter(HelpMessage = 'Also service the recovery image (winre.wim). Off by default; the correct component for WinRE is the Safe OS Dynamic Update, which is fetched when available')]
    [switch]$ServiceWinRE,

    [Parameter(HelpMessage = 'Skip integrating updates entirely and simply extract and recompile the ISO (useful for testing the build pipeline)')]
    [switch]$SkipUpdates,

    [Parameter(HelpMessage = 'Export the finished image as install.esd (LZMS "recovery" compression) instead of install.wim. Typically 25-40% smaller, which can bring the image under the 4 GB FAT32 limit for UEFI USB sticks, but the export is slow and the finished media cannot be serviced again without converting it back')]
    [switch]$CompressEsd,

    [Parameter(HelpMessage = 'Path to an unattended answer file to place on the finished ISO as \autounattend.xml, so Windows Setup runs without prompting')]
    [string]$UnattendPath,

    [Parameter(HelpMessage = 'Directory to download the ISO/updates into (defaults to the script folder). Needs several GB free')]
    [string]$DownloadPath,

    [Parameter(HelpMessage = 'Working folder used to extract and service the media. Must be on a fast drive with lots of free space. Defaults to <SystemDrive>\WISO-Work')]
    [string]$WorkPath,

    [Parameter(HelpMessage = 'Full path for the recompiled ISO. Defaults to the download folder with an "-Updated" suffix')]
    [string]$OutputIsoPath,

    [Parameter(HelpMessage = 'Full path to oscdimg.exe if the Windows ADK is installed in a non-standard location')]
    [string]$OscdimgPath,

    [Parameter(HelpMessage = 'If oscdimg.exe (Windows ADK Deployment Tools) is not found, download and silently install it from Microsoft')]
    [switch]$InstallAdk,

    [Parameter(HelpMessage = 'Skip the standalone oscdimg.exe download from the Microsoft symbol server and require the Windows ADK instead')]
    [switch]$SkipOscdimgDownload,

    [Parameter(HelpMessage = 'Override the URL used to fetch the Fido download helper')]
    [string]$FidoUrl = 'https://github.com/pbatard/Fido/raw/master/Fido.ps1',

    [Parameter(HelpMessage = 'Expected SHA-256 of Fido.ps1. Set this to pin one reviewed version; by default the script only verifies its source and contents')]
    [string]$FidoSha256,

    [Parameter(HelpMessage = 'How many extra attempts to make if Fido cannot resolve a download link (Microsoft''s anti-bot check often clears on a later attempt). Defaults to 2')]
    [ValidateRange(0, 10)]
    [int]$FidoRetryCount = 2,

    [Parameter(HelpMessage = 'Skip Fido and get the ISO with Microsoft''s Media Creation Tool instead. MCT cannot run headless, so you click through its wizard and save the ISO into the download folder')]
    [switch]$UseMct,

    [Parameter(HelpMessage = 'Override the URL used to download the Media Creation Tool')]
    [string]$MctUrl,

    [Parameter(HelpMessage = 'Edition passed to the Media Creation Tool''s /MediaEdition switch (e.g. Professional, Enterprise, Education). Only used with -MctPreselect, and it makes MCT ask for a product key')]
    [string]$MctEdition,

    [Parameter(HelpMessage = 'Launch the Media Creation Tool with the architecture/language/edition switches pre-filled. Off by default because driving MCT that way makes it demand a product key')]
    [switch]$MctPreselect,

    [Parameter(HelpMessage = 'Language code passed to the Media Creation Tool''s /MediaLangCode switch (e.g. en-US). Derived from -Language when not set')]
    [string]$MctLangCode,

    [Parameter(HelpMessage = 'Override the URL used to download the Windows ADK setup bootstrapper (Deployment Tools)')]
    [string]$AdkSetupUrl = 'https://go.microsoft.com/fwlink/?linkid=2289980',

    [Parameter(HelpMessage = 'Override the Microsoft symbol server URL used to download a standalone oscdimg.exe')]
    [string]$OscdimgUrl = 'https://msdl.microsoft.com/download/symbols/oscdimg.exe/688CABB065000/oscdimg.exe',

    [Parameter(HelpMessage = 'Expected SHA-256 of the downloaded oscdimg.exe. Pass an empty string to skip the hash check (needed if you override -OscdimgUrl)')]
    [string]$OscdimgSha256 = '2000160B2C5044691B2F9A0AC308E5207F273D4880A572457AF16D05886BA861',

    [Parameter(HelpMessage = 'Directory to write log files to. Defaults to a "Logs" folder inside the working folder, so everything the script writes stays in one place')]
    [string]$LogPath,

    [switch]$SkipInteractive # Skips the interactive confirmation prompt
)

# Verify this is running on PowerShell 5 or higher
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "This script requires PowerShell 5.0 or higher. You are currently running $($PSVersionTable.PSVersion)." -ForegroundColor Red
    Write-Host "Please update your PowerShell version to proceed." -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 1
}

# Verify you are running on Windows 10 (or Windows Server 2016) or higher
$OsInfo = Get-CimInstance -Class Win32_OperatingSystem
if ([int]($OsInfo).BuildNumber -lt 10240) {
    Write-Host "This script is designed for Windows 10 or higher. You are running $($OsInfo.Caption) (Build $($OsInfo.BuildNumber))." -ForegroundColor Red
    Write-Host "Running on an unsupported OS may have unintended consequences." -ForegroundColor Yellow
    Write-Host "The script will exit in 10 seconds." -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 1
}

# Self-elevate the script if required
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    if ([int](Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty BuildNumber) -ge 6000) {
        $ArgumentList = @("-File", "`"$($MyInvocation.MyCommand.Path)`"")
        # Re-add any passed parameters
        foreach ($Parameter in $PSBoundParameters.Keys) {
            $Value = $PSBoundParameters[$Parameter]
            if ($Value -is [switch]) {
                if ($Value.IsPresent) { $ArgumentList += "-$Parameter" }
            }
            else {
                $ArgumentList += "-$Parameter"
                $ArgumentList += "`"$Value`""
            }
        }

        Start-Process -FilePath PowerShell.exe -Verb Runas -ArgumentList $ArgumentList
        exit
    }
}

# Add a Window Title
$Host.UI.RawUI.WindowTitle = "Windows ISO Updater - Running as Administrator - $env:COMPUTERNAME"

# --- Resolve working folders ---
# Everything this script writes lives under the working folder, so a single -WorkPath moves the whole
# build (downloads, extracted media, DISM mount, logs) to another drive. These MUST be on a local, fixed
# disk: cloud-synced folders (Google Drive, OneDrive, Dropbox, etc.) turn files into on-demand
# placeholders and sync them in the background, which makes DISM unable to read the .msu/.wim reliably
# ("An error occurred applying the Unattend.xml file from the .msu package"). They also need lots of free
# space and, ideally, no spaces in the path (oscdimg's -bootdata dislikes spaces; short paths are used to
# work around it regardless).
$WorkRoot   = if ($WorkPath) { $WorkPath } else { Join-Path -Path $env:SystemDrive -ChildPath 'WISO-Work' }
$ExtractDir = Join-Path -Path $WorkRoot -ChildPath 'ISO'
$MountDir   = Join-Path -Path $WorkRoot -ChildPath 'Mount'
# Where a standalone oscdimg.exe is cached if it has to be downloaded, so later runs reuse it.
$OscdimgLocalPath = Join-Path -Path $WorkRoot -ChildPath 'Tools\oscdimg.exe'
# Downloads and logs default under the work root - NOT the script folder, which may sit on a cloud-synced
# drive (this repo, for example, lives under a Google Drive "My Drive" path).
$DlDir      = if ($DownloadPath) { $DownloadPath } else { Join-Path -Path $WorkRoot -ChildPath 'Downloads' }
$LogDirWanted = if ($LogPath) { $LogPath } else { Join-Path -Path $WorkRoot -ChildPath 'Logs' }

# --- Start Logging ---
# Create the log folder, falling back to the script folder if it cannot be used.
$LogDir = $PSScriptRoot
try {
    if (-not (Test-Path $LogDirWanted)) {
        New-Item -ItemType Directory -Path $LogDirWanted -Force -ErrorAction Stop | Out-Null
    }
    $LogDir = $LogDirWanted
}
catch {
    Write-Warning "Could not use the log folder '$LogDirWanted': $($_.Exception.Message). Falling back to the script folder."
}
$LogFile = Join-Path -Path $LogDir -ChildPath "Windows-ISO-Updater_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
Start-Transcript -Path $LogFile | Out-Null

# Rotate logs: keep only the 30 most recent, delete the rest
Get-ChildItem -Path $LogDir -Filter 'Windows-ISO-Updater_*.log' -File |
    Sort-Object -Property LastWriteTime -Descending |
    Select-Object -Skip 30 |
    Remove-Item -Force -ErrorAction SilentlyContinue

$ProgressPreference = 'SilentlyContinue'
$LineBreakCharacter = '-'
$LineBreak = $null
1..$($Host.UI.RawUI.BufferSize.Width) | ForEach-Object {
    $LineBreak += $LineBreakCharacter
}

# Wall-clock start of the run plus the per-step durations collected by Invoke-Task, reported at the end.
$script:ScriptStartTime = Get-Date
$script:StepTimings = [System.Collections.Generic.List[psobject]]::new()
# Captured from the serviced image while it is still mounted, so the final report does not have to mount it again.
$script:FinalBuildString = $null

function Get-TimeStamp {
    return (Get-Date -Format '[MM/dd/yyyy|HH:mm:ss]')
}

function Format-Duration {
    param([TimeSpan]$Duration)
    if ($Duration.TotalHours -ge 1) { return ('{0}h {1:00}m {2:00}s' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds) }
    if ($Duration.TotalMinutes -ge 1) { return ('{0}m {1:00}s' -f $Duration.Minutes, $Duration.Seconds) }
    return ('{0:N1}s' -f $Duration.TotalSeconds)
}

function Write-HostTimestamp {
    param (
        [string]$Message,
        [consolecolor]$ForegroundColor = $(try { ((Get-Host).ui.rawui.ForegroundColor) } catch { 'White' })
    )

    # Get the current timestamp and combine it with the user's message.
    # The output is then sent to the console using Write-Host with the specified color.
    Write-Host "$(Get-TimeStamp) $Message" -ForegroundColor $ForegroundColor
}

function Invoke-Task {
    param(
        [string]$Description,
        [scriptblock]$ScriptBlock
    )

    Write-HostTimestamp $Description
    $StepStart = Get-Date
    try {
        & $ScriptBlock
    }
    finally {
        # Recorded in a finally block so a step that throws still contributes to the timing summary.
        $Elapsed = (Get-Date) - $StepStart
        $script:StepTimings.Add([pscustomobject]@{ Description = $Description; Duration = $Elapsed })
        Write-HostTimestamp "  Step finished in $(Format-Duration $Elapsed)." -ForegroundColor DarkGray
    }
    Write-Host $LineBreak
}

# Returns the free space (GB, rounded to two decimals) on the drive that holds the given path, or $null.
function Get-DriveFreeGB {
    param([string]$Path)
    try {
        $Qualifier = (Split-Path -Path $Path -Qualifier -ErrorAction SilentlyContinue)
        if (-not $Qualifier) { $Qualifier = $env:SystemDrive }
        $Drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$Qualifier'" -ErrorAction Stop
        if ($Drive -and $Drive.FreeSpace) {
            return [math]::Round($Drive.FreeSpace / 1GB, 2)
        }
    }
    catch { }
    return $null
}

# An export stages a second copy of the image beside the original, so both must fit at the same time.
# Returns $false (and explains why) when the working drive no longer has room, so the caller can skip
# the shrink instead of failing a build that is otherwise finished.
function Test-RoomForExport {
    param(
        [Parameter(Mandatory)][string]$SourceImage,
        [string]$Label = 'image'
    )
    $Free = Get-DriveFreeGB -Path $WorkRoot
    if ($null -eq $Free) { return $true }
    $SourceGB = try { (Get-Item -LiteralPath $SourceImage -ErrorAction Stop).Length / 1GB } catch { return $true }
    $NeedGB = [math]::Round($SourceGB * 1.1, 2)
    if ($Free -lt $NeedGB) {
        Write-HostTimestamp "  Skipping the $Label re-export: staging a copy needs about $NeedGB GB, but only $Free GB is free on the working drive." -ForegroundColor Yellow
        return $false
    }
    return $true
}

# Detects the currently-installed Windows version/architecture so the Fido download request can reuse it.
function Get-InstalledWindowsInfo {
    $Arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }
        'ARM64' { 'arm64' }
        'x86'   { 'x86' }
        default { 'x64' }
    }
    [PSCustomObject]@{ Architecture = $Arch }
}

# Downloads a file with BITS when available (resumable, shows progress) and falls back to
# Invoke-WebRequest. Returns $true on success. Never throws.
function Get-FileDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination
    )

    # Prefer BITS: it is resumable and far more reliable for multi-GB downloads.
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        try {
            Write-HostTimestamp '  Downloading with BITS...'
            Start-BitsTransfer -Source $Url -Destination $Destination -Description 'Windows download' -ErrorAction Stop
            if (Test-Path -LiteralPath $Destination) { return $true }
        }
        catch {
            Write-HostTimestamp "  BITS transfer failed ($($_.Exception.Message)). Falling back to a direct download..." -ForegroundColor Yellow
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        }
    }

    # Fallback: Invoke-WebRequest. Slower and not resumable, but dependency-free.
    try {
        Write-HostTimestamp '  Downloading with Invoke-WebRequest...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -ErrorAction Stop
        if (Test-Path -LiteralPath $Destination) { return $true }
    }
    catch {
        Write-HostTimestamp "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    return $false
}

# Verifies a download URL points at an official Microsoft-owned host over HTTPS, so the script never
# downloads content from somewhere it should not. Microsoft serves ISOs and updates from hosts under
# microsoft.com, windowsupdate.com, and delivery.mp.microsoft.com. Returns $true only for an https:// URL
# whose host is one of those domains or a subdomain of them. Using the parsed Host (not a substring of
# the raw URL) avoids spoofing like "microsoft.com.evil.example".
function Test-MicrosoftDownloadUrl {
    param([string]$Url)
    if (-not $Url) { return $false }
    try { $Uri = [Uri]$Url } catch { return $false }
    if ($Uri.Scheme -ne 'https') { return $false }
    return ($Uri.Host -match '(?i)(^|\.)(microsoft\.com|windowsupdate\.com)$')
}

# Verifies the Fido helper is being fetched from the official pbatard/Fido repository on GitHub over
# HTTPS. Fido is downloaded and then executed, so a URL pointing anywhere else is arbitrary code
# execution; the parsed Host and path are checked (not a substring of the raw URL) so lookalikes such as
# "github.com.evil.example" or "/evil/pbatard/Fido/" are rejected.
function Test-FidoUrl {
    param([string]$Url)
    if (-not $Url) { return $false }
    try { $Uri = [Uri]$Url } catch { return $false }
    if ($Uri.Scheme -ne 'https') { return $false }
    if ($Uri.Host -notin @('github.com', 'raw.githubusercontent.com', 'objects.githubusercontent.com', 'codeload.github.com')) { return $false }
    return ($Uri.AbsolutePath -match '(?i)^/pbatard/Fido/')
}

# Validates a downloaded Fido.ps1 BEFORE it is executed. Fido is not code-signed, so there is no
# signature to check; instead this confirms the file really is Fido and contains nothing that Fido has
# any business doing. Checks, in order: an optional pinned SHA-256 (-FidoSha256), a sane file size, that
# it parses as PowerShell, that it carries Fido's header and -GetUrl parameter, and that it invokes no
# code-execution, persistence or security-tampering commands. Parsing only builds an AST - it never runs
# the script. Returns $true if the file passes.
function Test-FidoScript {
    param([Parameter(Mandatory)][string]$Path)

    $Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    Write-HostTimestamp "  Fido SHA-256: $Hash"
    if ($FidoSha256) {
        if ($Hash -ne $FidoSha256.Trim()) {
            Write-HostTimestamp "  Fido does not match the pinned SHA-256 ($($FidoSha256.Trim())). Refusing to run it." -ForegroundColor Red
            return $false
        }
        Write-HostTimestamp '  Fido matches the pinned SHA-256.' -ForegroundColor Green
    }

    # A 404/HTML error page or a truncated download is nothing like the real ~55 KB script.
    $Size = (Get-Item -LiteralPath $Path).Length
    if ($Size -lt 20KB -or $Size -gt 1MB) {
        Write-HostTimestamp "  The downloaded Fido helper is $Size bytes, which is not a plausible size for Fido.ps1. Refusing to run it." -ForegroundColor Red
        return $false
    }

    $ParseErrors = $null
    $Ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$ParseErrors)
    if ($ParseErrors) {
        Write-HostTimestamp "  The downloaded Fido helper is not valid PowerShell ($($ParseErrors.Count) parse error(s)). Refusing to run it." -ForegroundColor Red
        return $false
    }

    $Text = Get-Content -LiteralPath $Path -Raw
    if ($Text -notmatch '(?im)^#\s*Fido\s+v[\d.]+' -or $Text -notmatch '(?i)Copyright[^\r\n]*Pete Batard') {
        Write-HostTimestamp '  The downloaded file does not look like Fido (its header and copyright notice are missing). Refusing to run it.' -ForegroundColor Red
        return $false
    }

    $ParamNames = @($Ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    if ('GetUrl' -notin $ParamNames) {
        Write-HostTimestamp '  The downloaded Fido helper does not declare the -GetUrl parameter this script relies on. Refusing to run it.' -ForegroundColor Red
        return $false
    }

    # Fido resolves and downloads ISOs; it never needs to run generated code, spawn shells, install
    # services or scheduled tasks, or touch the registry, boot configuration or Defender.
    $Banned = @(
        'Invoke-Expression', 'iex', 'Set-ExecutionPolicy', 'Register-ScheduledTask', 'schtasks', 'schtasks.exe',
        'New-Service', 'Set-Service', 'sc.exe', 'Add-MpPreference', 'Set-MpPreference', 'New-LocalUser',
        'Add-LocalGroupMember', 'reg', 'reg.exe', 'regedit', 'regedit.exe', 'regsvr32', 'regsvr32.exe',
        'bcdedit', 'bcdedit.exe', 'certutil', 'certutil.exe', 'bitsadmin', 'bitsadmin.exe', 'mshta', 'mshta.exe',
        'rundll32', 'rundll32.exe', 'wmic', 'wmic.exe', 'vssadmin', 'vssadmin.exe', 'diskpart', 'diskpart.exe',
        'cmd', 'cmd.exe', 'powershell', 'powershell.exe', 'pwsh', 'pwsh.exe'
    )
    $Used = $Ast.FindAll({ param($Node) $Node -is [System.Management.Automation.Language.CommandAst] }, $true) |
        ForEach-Object { $_.GetCommandName() } | Where-Object { $_ }
    $Hits = @($Used | Where-Object { $Banned -contains $_ } | Sort-Object -Unique)
    if ($Hits.Count -gt 0) {
        Write-HostTimestamp "  The downloaded Fido helper calls commands Fido has no reason to use: $($Hits -join ', '). Refusing to run it." -ForegroundColor Red
        return $false
    }

    # Catch the same thing hidden behind obfuscation rather than a plain command call.
    if ($Text -match '(?i)FromBase64String|-\s*Encoded\s*Command|\benc\b\s+[A-Za-z0-9+/=]{40,}') {
        Write-HostTimestamp '  The downloaded Fido helper contains encoded/obfuscated code. Refusing to run it.' -ForegroundColor Red
        return $false
    }

    return $true
}

# Uses the community "Fido" helper (which queries Microsoft's own software-download servers) to resolve
# the official, matching Windows ISO download URL. The helper is fetched only from the official GitHub
# repository, validated before it runs (see Test-FidoScript), then run out-of-process with -GetUrl so it
# cannot touch this script's session. Returns the resulting URL string, or $null on failure. The
# resolved URL is verified to point at an official Microsoft host before being returned.
# Fido: https://github.com/pbatard/Fido
function Get-WindowsIsoUrl {
    param(
        [Parameter(Mandatory)][string]$Version,       # 10 or 11
        [Parameter(Mandatory)][string]$Release,        # e.g. Latest, 24H2
        [Parameter(Mandatory)][string]$Language,       # e.g. English
        [Parameter(Mandatory)][string]$Architecture    # x64 / arm64 / x86
    )

    if (-not (Test-FidoUrl -Url $FidoUrl)) {
        Write-HostTimestamp "  The Fido URL does not point at the official https://github.com/pbatard/Fido repository. Refusing to download and run it: $FidoUrl" -ForegroundColor Red
        Write-HostTimestamp '  Download an ISO yourself and re-run with -IsoPath "C:\path\to\Windows.iso".' -ForegroundColor Yellow
        return $null
    }

    $FidoScript = Join-Path -Path $env:TEMP -ChildPath "Fido_$(Get-Date -Format 'yyyyMMdd_HHmmss').ps1"
    Write-HostTimestamp '  Fetching the Fido download helper from GitHub...'
    if (-not (Get-FileDownload -Url $FidoUrl -Destination $FidoScript)) {
        Write-HostTimestamp '  Could not download the Fido helper. Provide an ISO manually with -IsoPath instead.' -ForegroundColor Red
        return $null
    }

    if (-not (Test-FidoScript -Path $FidoScript)) {
        Remove-Item -LiteralPath $FidoScript -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp '  Download an ISO yourself and re-run with -IsoPath "C:\path\to\Windows.iso".' -ForegroundColor Yellow
        return $null
    }
    Write-HostTimestamp '  Verified the Fido helper came from the official repository and passed its content checks.' -ForegroundColor Green

    Write-HostTimestamp "  Asking Microsoft (via Fido) for the Windows $Version ($Release, $Language, $Architecture) ISO link..."
    $Url = $null
    $Output = $null
    $FidoExit = $null
    $Attempts = $FidoRetryCount + 1
    try {
        for ($Attempt = 1; $Attempt -le $Attempts; $Attempt++) {
            if ($Attempt -gt 1) {
                # Microsoft's anti-bot check ("Sentinel") rejects bursts of requests but usually lets a
                # later one through, and Fido starts a fresh session each time, so backing off is worth it.
                $Wait = [Math]::Min(120, 20 * [Math]::Pow(3, $Attempt - 2))
                Write-HostTimestamp "  Attempt $($Attempt - 1) of $Attempts failed. Waiting $Wait seconds before retrying..." -ForegroundColor Yellow
                Start-Sleep -Seconds $Wait
                Write-HostTimestamp "  Retrying (attempt $Attempt of $Attempts)..."
            }

            $Output = $null
            $FidoExit = $null
            try {
                # -GetUrl makes Fido print only the resolved download URL and exit, without downloading anything.
                $FidoArgs = @{
                    Win    = $Version
                    Rel    = $Release
                    Lang   = $Language
                    Arch   = $Architecture
                    GetUrl = $true
                }
                if ($VerbosePreference -ne 'SilentlyContinue') { $FidoArgs['Verbose'] = $true }

                # Prefer running Fido in its own Windows PowerShell process: it keeps third-party code out of
                # this session, and Fido targets Windows PowerShell.
                $WinPs = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if (Test-Path -LiteralPath $WinPs) {
                    $ChildArgs = @(
                        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $FidoScript,
                        '-Win', $Version, '-Rel', $Release, '-Lang', $Language, '-Arch', $Architecture, '-GetUrl'
                    )
                    if ($VerbosePreference -ne 'SilentlyContinue') { $ChildArgs += '-Verbose' }
                    $Output = & $WinPs @ChildArgs 2>&1
                    $FidoExit = $LASTEXITCODE
                }
                else {
                    $Output = & $FidoScript @FidoArgs 2>&1
                }
                $Url = ($Output | Where-Object { $_ -match '^https?://' } | Select-Object -Last 1)
                if ($Url) { $Url = $Url.ToString().Trim(); break }
            }
            catch {
                Write-HostTimestamp "  Fido could not resolve a download URL: $($_.Exception.Message)" -ForegroundColor Red
            }

            $Reason = @($Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '(?i)^error' }) | Select-Object -Last 1
            if ($Reason) { Write-HostTimestamp "  Fido: $Reason" -ForegroundColor Yellow }
        }
    }
    finally {
        Remove-Item -LiteralPath $FidoScript -Force -ErrorAction SilentlyContinue
    }

    if (-not $Url) {
        Write-HostTimestamp "  Fido did not return a download URL after $Attempts attempt(s). Microsoft may have changed its download page, throttled this IP address, or the requested release/language is unavailable." -ForegroundColor Red

        # Fido explains the real reason on its own output (rate limiting, unknown release, HTTP errors), so
        # show it rather than leaving the user with only the generic message above.
        $Lines = @($Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        if ($Lines.Count -gt 0) {
            Write-HostTimestamp "  Fido reported$(if ($null -ne $FidoExit) { " (exit code $FidoExit)" }):" -ForegroundColor Yellow
            $Lines | Select-Object -Last 25 | ForEach-Object { Write-HostTimestamp "    $_" -ForegroundColor Gray }
        }
        else {
            Write-HostTimestamp "  Fido produced no output$(if ($null -ne $FidoExit) { " (exit code $FidoExit)" })." -ForegroundColor Yellow
        }

        Write-HostTimestamp '  Re-run this script with -Verbose to get Fido''s full diagnostics.' -ForegroundColor Yellow
        Write-HostTimestamp '  "Sentinel marked this request as rejected" or a "715-123130" error means Microsoft''s anti-bot check refused the request - usually because this IP address has asked for ISO links too often. Wait a while, try a different network, or just download the ISO yourself.' -ForegroundColor Yellow
        Write-HostTimestamp '  Microsoft''s Media Creation Tool uses different servers and usually still works - re-run with -UseMct to have this script open it for you.' -ForegroundColor Yellow
        Write-HostTimestamp '  Download an ISO yourself and re-run with -IsoPath "C:\path\to\Windows.iso".' -ForegroundColor Yellow
        return $null
    }

    if (-not (Test-MicrosoftDownloadUrl -Url $Url)) {
        $BadHost = try { ([Uri]$Url).Host } catch { '(unparseable)' }
        Write-HostTimestamp "  The resolved download URL does not point at an official Microsoft host (host: $BadHost). Refusing to download it." -ForegroundColor Red
        return $null
    }
    Write-HostTimestamp "  Verified the ISO download comes from an official Microsoft host: $(([Uri]$Url).Host)" -ForegroundColor Green
    return $Url
}

# Translates the Fido-style language name (-Language) into the locale code the Media Creation Tool wants
# for /MediaLangCode. Falls back to en-US when the name cannot be matched.
function Get-MctLanguageCode {
    param([Parameter(Mandatory)][string]$Name)

    if ($MctLangCode) { return $MctLangCode }

    # Names where Microsoft's ISO list and .NET's culture names disagree, or where the generic lookup
    # below would pick the wrong region.
    switch -Regex ($Name) {
        '(?i)^english international$'          { return 'en-GB' }
        '(?i)^english$'                        { return 'en-US' }
        '(?i)^chinese.*simplified'             { return 'zh-CN' }
        '(?i)^chinese.*traditional'            { return 'zh-TW' }
        '(?i)^(brazilian portuguese|portuguese \(brazil\))$' { return 'pt-BR' }
        '(?i)^portuguese( \(portugal\))?$'     { return 'pt-PT' }
        '(?i)^spanish \(mexico\)$'             { return 'es-MX' }
        '(?i)^serbian latin$'                  { return 'sr-Latn-RS' }
    }

    # Otherwise resolve the language name to its neutral culture and take that culture's default region
    # (e.g. French -> fr -> fr-FR), which matches how Microsoft names its media.
    $Neutral = [System.Globalization.CultureInfo]::GetCultures('NeutralCultures') |
        Where-Object { $_.EnglishName -eq $Name } | Select-Object -First 1
    if ($Neutral) {
        try { return [System.Globalization.CultureInfo]::CreateSpecificCulture($Neutral.Name).Name } catch { }
    }

    Write-HostTimestamp "  Could not map the language '$Name' to a Media Creation Tool locale code; using en-US. Override it with -MctLangCode." -ForegroundColor Yellow
    return 'en-US'
}

# Fallback for when Fido cannot get a link (usually because Microsoft's anti-bot check blocked this IP):
# downloads Microsoft's own Media Creation Tool and runs it. MCT has no switch to choose ISO output or a
# target path, so it cannot be driven headlessly - the user clicks through the wizard and saves the ISO
# into the download folder, which this function then picks up. Returns the ISO path, or $null.
function Get-IsoViaMct {
    param(
        [Parameter(Mandatory)][string]$Version,        # 10 or 11
        [Parameter(Mandatory)][string]$Language,
        [Parameter(Mandatory)][string]$Architecture,
        [Parameter(Mandatory)][string]$DownloadDir
    )

    # Microsoft's permanent fwlinks for the Media Creation Tool on the software-download pages.
    $Url = if ($MctUrl) { $MctUrl } elseif ($Version -eq '10') { 'https://go.microsoft.com/fwlink/?LinkId=691209' } else { 'https://go.microsoft.com/fwlink/?linkid=2156295' }
    if (-not (Test-MicrosoftDownloadUrl -Url $Url)) {
        Write-HostTimestamp "  The Media Creation Tool URL is not an official Microsoft URL. Refusing to download it: $Url" -ForegroundColor Red
        return $null
    }

    $Mct = Join-Path -Path $DownloadDir -ChildPath "MediaCreationTool_$(Get-Date -Format 'yyyyMMdd_HHmmss').exe"
    Write-HostTimestamp '  Downloading the Media Creation Tool from Microsoft...'
    if (-not (Get-FileDownload -Url $Url -Destination $Mct)) {
        Write-HostTimestamp '  Could not download the Media Creation Tool.' -ForegroundColor Red
        return $null
    }

    # Unlike Fido and oscdimg, MCT is Authenticode signed, so require a valid Microsoft signature.
    $Signature = Get-AuthenticodeSignature -LiteralPath $Mct -ErrorAction SilentlyContinue
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch '(?i)O=Microsoft Corporation') {
        Write-HostTimestamp "  The downloaded Media Creation Tool is not validly signed by Microsoft (status: $($Signature.Status)). Discarding it." -ForegroundColor Red
        Remove-Item -LiteralPath $Mct -Force -ErrorAction SilentlyContinue
        return $null
    }
    Write-HostTimestamp '  Verified the Media Creation Tool''s Microsoft signature.' -ForegroundColor Green

    $MctArch = switch ($Architecture) { 'arm64' { 'ARM64' } 'x86' { 'x86' } default { 'x64' } }
    $LangCode = Get-MctLanguageCode -Name $Language
    # Driving MCT with its channel/edition switches puts it in the "enter your product key" flow, so the
    # plain wizard is used unless -MctPreselect asks for the pre-filled one.
    $MctArgs = @('/Eula', 'Accept')
    if ($MctPreselect) {
        $MctArgs += @('/Retail', '/MediaArch', $MctArch, '/MediaLangCode', $LangCode)
        if ($MctEdition) { $MctArgs += @('/MediaEdition', $MctEdition) }
    }

    Write-Host ''
    if ($MctPreselect) {
        Write-Host 'The Media Creation Tool is about to open with your choices pre-selected:' -ForegroundColor Cyan
        Write-Host "  Windows $Version, $MctArch, $LangCode, $(if ($MctEdition) { $MctEdition } else { 'all editions' })"
        Write-Host ''
        Write-Host 'If it asks for a product key, enter one of Microsoft''s published generic edition-selection' -ForegroundColor Yellow
        Write-Host 'keys (Pro is VK7JG-NPHTM-C97JM-9MPGT-3V66T), or re-run without -MctPreselect to get the' -ForegroundColor Yellow
        Write-Host 'ordinary wizard, which never asks for one.' -ForegroundColor Yellow
        Write-Host ''
    }
    else {
        Write-Host 'The Media Creation Tool is about to open. Asked for these in its window:' -ForegroundColor Cyan
        Write-Host "  Windows $Version, $MctArch, $LangCode, all editions"
        Write-Host ''
    }
    Write-Host 'It cannot be automated any further - Microsoft provides no switch to pick ISO output or a' -ForegroundColor Yellow
    Write-Host 'save location - so in its window please:' -ForegroundColor Yellow
    Write-Host '  1. Accept the licence terms if prompted.'
    Write-Host '  2. Choose "Create installation media (USB flash drive, DVD, or ISO file) for another PC".'
    Write-Host "  3. Set the language and architecture ($LangCode, $MctArch), or leave the recommended options ticked."
    Write-Host '  4. Choose "ISO file".'
    Write-Host "  5. Save it into this folder: $DownloadDir" -ForegroundColor Green
    Write-Host '  6. Let the download finish, then click Finish.'
    Write-Host ''
    Write-Host 'This script waits until the Media Creation Tool closes, then continues on its own.' -ForegroundColor Cyan
    Write-Host ''
    if ($Unattended -or $SkipInteractive) {
        Write-HostTimestamp '  Note: the Media Creation Tool has no unattended ISO mode, so this step needs someone at the keyboard.' -ForegroundColor Yellow
    }

    $Existing = @(Get-ChildItem -Path $DownloadDir -Filter '*.iso' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    try {
        Write-HostTimestamp '  Waiting for the Media Creation Tool to finish...'
        Start-Process -FilePath $Mct -ArgumentList $MctArgs -Wait -ErrorAction Stop | Out-Null
    }
    catch {
        Write-HostTimestamp "  The Media Creation Tool could not be started: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
    finally {
        Remove-Item -LiteralPath $Mct -Force -ErrorAction SilentlyContinue
    }

    # Prefer an ISO that was not there before MCT ran; otherwise take the largest one in the folder.
    $Iso = Get-ChildItem -Path $DownloadDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 3GB -and $Existing -notcontains $_.FullName } |
        Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    if (-not $Iso) {
        $Iso = Get-ChildItem -Path $DownloadDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 3GB } | Sort-Object -Property Length -Descending | Select-Object -First 1
    }
    if ($Iso) {
        Write-HostTimestamp "  Found the ISO the Media Creation Tool produced: $($Iso.FullName) ($([math]::Round($Iso.Length / 1GB, 2)) GB)" -ForegroundColor Green
        return $Iso.FullName
    }

    Write-HostTimestamp "  No ISO turned up in $DownloadDir." -ForegroundColor Yellow
    if ($Unattended -or $SkipInteractive) { return $null }
    $Answer = Read-Host 'If you saved it somewhere else, enter the full path to the ISO now (or press Enter to cancel)'
    if ($Answer -and (Test-Path -LiteralPath $Answer.Trim('"'))) { return (Resolve-Path -LiteralPath $Answer.Trim('"')).Path }
    return $null
}

# Maps a Windows build number to its marketing feature-update name (used to build catalog search queries).
function Get-FeatureUpdateName {
    param([Parameter(Mandatory)][int]$Build)
    switch ($Build) {
        26200  { '25H2'; break }
        26100  { '24H2'; break }
        22631  { '23H2'; break }
        22621  { '22H2'; break }
        22000  { '21H2'; break }
        19045  { '22H2'; break }   # Windows 10
        19044  { '21H2'; break }   # Windows 10
        default { $null }
    }
}

# --- Microsoft Update Catalog helpers ---
# The Microsoft Update Catalog (catalog.update.microsoft.com) has no public API, so these functions use
# the same technique the community relies on: fetch the search results page and parse it, then POST to the
# download dialog to obtain the direct package URL. Every resolved URL is validated to be a Microsoft host
# before it is downloaded.

# Searches the catalog and returns matching updates as PSCustomObjects (Guid, Title, LastUpdated, SizeMB).
function Search-UpdateCatalog {
    param([Parameter(Mandatory)][string]$Query)

    $EncodedQuery = [System.Uri]::EscapeDataString($Query)
    $SearchUrl = "https://www.catalog.update.microsoft.com/Search.aspx?q=$EncodedQuery"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        $Response = Invoke-WebRequest -Uri $SearchUrl -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-HostTimestamp "  Could not query the Microsoft Update Catalog: $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }

    $Html = $Response.Content
    $Results = New-Object System.Collections.Generic.List[object]

    # The catalog renders each result as an anchor  <a id='<GUID>_link' ...>Title</a>  (note the SINGLE
    # quotes), and its column values live in separate cells whose ids follow the pattern
    # "<GUID>_C<col>_R<row>" - C1=Title, C3=Classification, C4=Last Updated, C6=Size. We find every result
    # by its "_link" anchor, then read that GUID's date/size/classification cells by id.
    $LinkMatches = [regex]::Matches($Html, "(?s)id=['`"]([0-9a-fA-F-]{36})_link['`"][^>]*>(.*?)</a>")
    foreach ($Link in $LinkMatches) {
        $Guid = $Link.Groups[1].Value
        $Title = [System.Net.WebUtility]::HtmlDecode((([regex]::Replace($Link.Groups[2].Value, '<[^>]+>', ' ')).Trim() -replace '\s+', ' '))
        $EscGuid = [regex]::Escape($Guid)

        # Helper to read the visible text of a specific column cell for this GUID.
        $GetCell = {
            param([int]$Col)
            $M = [regex]::Match($Html, "(?s)id=`"${EscGuid}_C${Col}_R\d+`"[^>]*>(.*?)</td>")
            if ($M.Success) {
                return [System.Net.WebUtility]::HtmlDecode((([regex]::Replace($M.Groups[1].Value, '<[^>]+>', ' ')).Trim() -replace '\s+', ' '))
            }
            return $null
        }

        $Classification = & $GetCell 3
        $DateText = & $GetCell 4
        $SizeText = & $GetCell 6

        $LastUpdated = $null
        if ($DateText -and $DateText -match '(\d{1,2}/\d{1,2}/\d{4})') {
            try { $LastUpdated = [datetime]::Parse($Matches[1]) } catch { }
        }

        $SizeMB = $null
        if ($SizeText -and $SizeText -match '([\d.,]+)\s*(KB|MB|GB)') {
            $Value = [double]($Matches[1] -replace ',', '')
            $SizeMB = switch ($Matches[2]) {
                'KB' { [math]::Round($Value / 1024, 2) }
                'MB' { $Value }
                'GB' { [math]::Round($Value * 1024, 2) }
            }
        }

        $Results.Add([PSCustomObject]@{
            Guid           = $Guid
            Title          = $Title
            Classification = $Classification
            LastUpdated    = $LastUpdated
            SizeMB         = $SizeMB
        })
    }

    return $Results
}

# Resolves the direct download URL(s) for a catalog update GUID by POSTing to the download dialog.
function Get-UpdateCatalogDownloadUrl {
    param([Parameter(Mandatory)][string]$Guid)

    $DialogUrl = 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx'
    $Body = "updateIDs=[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$Guid`",`"updateID`":`"$Guid`"}]&updateIDsBlockedForImport=&wsusApiPresent=&contentImport=&sqlserverImport=&updateID=$Guid"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    try {
        $Response = Invoke-WebRequest -Uri $DialogUrl -Method Post -Body $Body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -ErrorAction Stop
    }
    catch {
        Write-HostTimestamp "  Could not resolve the download link for $Guid : $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }

    # The dialog echoes the direct file URLs in JavaScript: downloadInformation[0].files[0].url = '...';
    $Urls = [regex]::Matches($Response.Content, "downloadInformation\[\d+\]\.files\[\d+\]\.url\s*=\s*'([^']+)'") |
        ForEach-Object { $_.Groups[1].Value } |
        Where-Object { $_ } |
        Select-Object -Unique

    return @($Urls)
}

# Finds the newest, non-preview cumulative update in the catalog for a given search query, downloads it
# to the download folder, and returns the local .msu path (or $null on failure).
function Get-LatestCatalogPackage {
    param(
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$DownloadDir,
        [string]$TitleInclude,   # regex the title MUST match (e.g. cumulative update wording)
        [string]$TitleExclude,   # regex the title must NOT match (e.g. ".net", "dynamic")
        [switch]$AllowPreview
    )

    Write-HostTimestamp "  Searching the Microsoft Update Catalog for: $Query"
    $Results = Search-UpdateCatalog -Query $Query
    if (-not $Results -or $Results.Count -eq 0) {
        Write-HostTimestamp '  No catalog results were returned for that query.' -ForegroundColor Yellow
        return $null
    }
    Write-HostTimestamp "  Found $($Results.Count) catalog result(s); selecting the best match..."

    # Narrow to the packages we actually want, then take the newest by date (largest as a tie-break).
    $Filtered = $Results
    if ($TitleInclude) { $Filtered = $Filtered | Where-Object { $_.Title -match $TitleInclude } }
    if ($TitleExclude) { $Filtered = $Filtered | Where-Object { $_.Title -notmatch $TitleExclude } }
    if (-not $AllowPreview) { $Filtered = $Filtered | Where-Object { $_.Title -notmatch '(?i)preview' } }
    if (-not $Filtered) {
        Write-HostTimestamp '  No catalog results matched the expected update type after filtering.' -ForegroundColor Yellow
        return $null
    }

    $Selected = $Filtered |
        Sort-Object -Property @{ Expression = { $_.LastUpdated }; Descending = $true }, @{ Expression = { $_.SizeMB }; Descending = $true } |
        Select-Object -First 1
    if (-not $Selected) {
        Write-HostTimestamp '  Could not select a suitable update from the catalog results.' -ForegroundColor Yellow
        return $null
    }

    Write-HostTimestamp "  Selected: $($Selected.Title)$(if ($Selected.LastUpdated) { " (released $($Selected.LastUpdated.ToString('yyyy-MM-dd')))" })" -ForegroundColor Green

    # A single catalog entry can resolve to MULTIPLE .msu files. For Windows 11 24H2/25H2, Microsoft uses
    # "checkpoint cumulative updates": the latest LCU download also includes one or more baseline/checkpoint
    # packages that MUST be integrated first. So download every file the dialog returns and order them so
    # the checkpoint/baseline packages come before the main LCU (identified by the KB in the title).
    $Urls = @(Get-UpdateCatalogDownloadUrl -Guid $Selected.Guid)
    $FileUrls = @($Urls | Where-Object { $_ -match '\.(msu|cab)(\?|$)' })
    if (-not $FileUrls) { $FileUrls = $Urls }
    if (-not $FileUrls -or $FileUrls.Count -eq 0) {
        Write-HostTimestamp '  The catalog did not return a download URL for the selected update.' -ForegroundColor Yellow
        return $null
    }

    $PrimaryKb = if ($Selected.Title -match '(?i)KB(\d{6,})') { $Matches[1] } else { $null }

    # Helper: extract the numeric KB from a URL/filename for ordering (checkpoints ascending, LCU last).
    $GetKb = { param($Text) if ($Text -match '(?i)kb(\d{6,})') { [int]$Matches[1] } else { 0 } }

    $Downloaded = New-Object System.Collections.Generic.List[object]
    foreach ($Url in $FileUrls) {
        if (-not (Test-MicrosoftDownloadUrl -Url $Url)) {
            $BadHost = try { ([Uri]$Url).Host } catch { '(unparseable)' }
            Write-HostTimestamp "  Skipping a download URL that is not an official Microsoft host (host: $BadHost)." -ForegroundColor Yellow
            continue
        }

        $FileName = $null
        try { $FileName = [System.IO.Path]::GetFileName(([Uri]$Url).AbsolutePath) } catch { }
        if (-not $FileName) { $FileName = "$($Selected.Guid)_$(& $GetKb $Url).msu" }
        $Destination = Join-Path -Path $DownloadDir -ChildPath $FileName

        if (Test-Path -LiteralPath $Destination) {
            Write-HostTimestamp "  Already downloaded - reusing: $FileName" -ForegroundColor DarkGray
        }
        else {
            Write-HostTimestamp "  Downloading $FileName ..."
            if (-not (Get-FileDownload -Url $Url -Destination $Destination)) {
                Write-HostTimestamp "  Failed to download $FileName." -ForegroundColor Red
                return $null
            }
            Write-HostTimestamp "    Downloaded ($([math]::Round((Get-Item -LiteralPath $Destination).Length / 1MB, 1)) MB)." -ForegroundColor Green
        }

        $Kb = & $GetKb $FileName
        $IsPrimary = ($PrimaryKb -and $FileName -match "(?i)kb$PrimaryKb")
        $Downloaded.Add([PSCustomObject]@{ Path = $Destination; Kb = $Kb; IsPrimary = [bool]$IsPrimary })
    }

    if ($Downloaded.Count -eq 0) {
        Write-HostTimestamp '  No update packages could be downloaded.' -ForegroundColor Red
        return $null
    }

    # Order: non-primary (checkpoints/SSU) first (oldest KB first), then the primary LCU last. If we could
    # not identify the primary KB, fall back to plain KB-ascending order.
    $Ordered = @(
        ($Downloaded | Where-Object { -not $_.IsPrimary } | Sort-Object Kb)
        ($Downloaded | Where-Object { $_.IsPrimary } | Sort-Object Kb)
    )
    if ($Downloaded.Count -gt 1) {
        Write-HostTimestamp "  This update includes $($Downloaded.Count) package(s); they will be integrated in this order:"
        $Ordered | ForEach-Object { Write-HostTimestamp "    - $(Split-Path -Leaf $_.Path)$(if ($_.IsPrimary) { ' (main cumulative update)' })" }
    }

    return @($Ordered | ForEach-Object { $_.Path })
}

# Locates oscdimg.exe (from the Windows ADK Deployment Tools), which is required to recompile the ISO.
# Checks -OscdimgPath, a previously downloaded copy in the work folder, then PATH, then the standard ADK
# install locations. Returns the full path or $null.
function Find-Oscdimg {
    if ($OscdimgPath -and (Test-Path -LiteralPath $OscdimgPath)) { return (Resolve-Path -LiteralPath $OscdimgPath).Path }

    if (Test-Path -LiteralPath $OscdimgLocalPath) { return (Resolve-Path -LiteralPath $OscdimgLocalPath).Path }

    $OnPath = Get-Command 'oscdimg.exe' -ErrorAction SilentlyContinue
    if ($OnPath) { return $OnPath.Source }

    $Roots = @(
        ${env:ProgramFiles(x86)},
        $env:ProgramFiles
    ) | Where-Object { $_ }
    foreach ($Root in $Roots) {
        $Base = Join-Path $Root 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools'
        if (Test-Path $Base) {
            $Found = Get-ChildItem -Path $Base -Filter 'oscdimg.exe' -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($Found) { return $Found.FullName }
        }
    }
    return $null
}

# Downloads a standalone oscdimg.exe from Microsoft's public symbol server (msdl.microsoft.com), which
# hosts the binary indexed by its PE TimeDateStamp + SizeOfImage - the technique described at
# https://pete.akeo.ie/2025/06/downloading-oscdimgexe-from-microsoft.html. This avoids installing the
# multi-hundred-MB Windows ADK just to get one ~140 KB executable. The symbol server only returns the
# file when the request carries a symbol-client User-Agent, so one is set explicitly. Because the URL
# pins one exact build, the download is verified against a known SHA-256 (the binary itself is not
# Authenticode signed) as well as its Microsoft version resource.
# Returns the path to the downloaded oscdimg.exe, or $null on failure.
function Get-OscdimgDownload {
    if (-not (Test-MicrosoftDownloadUrl -Url $OscdimgUrl)) {
        Write-HostTimestamp "  The oscdimg URL is not an official Microsoft URL. Refusing to download it: $OscdimgUrl" -ForegroundColor Red
        return $null
    }

    $ToolsDir = Split-Path -Parent $OscdimgLocalPath
    try {
        if (-not (Test-Path -LiteralPath $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force -ErrorAction Stop | Out-Null }
    }
    catch {
        Write-HostTimestamp "  Could not create the tools folder '$ToolsDir': $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $Temp = "$OscdimgLocalPath.download"
    Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
    Write-HostTimestamp "  Downloading oscdimg.exe from the Microsoft symbol server: $OscdimgUrl"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $OscdimgUrl -OutFile $Temp -UseBasicParsing -UserAgent 'Microsoft-Symbol-Server/10.0.0.0' -ErrorAction Stop
    }
    catch {
        Write-HostTimestamp "  Download failed: $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
        return $null
    }

    if (-not (Test-Path -LiteralPath $Temp)) {
        Write-HostTimestamp '  The symbol server did not return a file.' -ForegroundColor Red
        return $null
    }

    # The symbol server answers a miss with a small HTML/text body, so confirm this really is a PE image.
    # Read the two "MZ" header bytes directly - Get-Content's byte switch differs between PS 5 and 7.
    $IsExe = $false
    try {
        $Stream = [System.IO.File]::OpenRead($Temp)
        try {
            $Header = New-Object byte[] 2
            $IsExe = ($Stream.Read($Header, 0, 2) -eq 2 -and $Header[0] -eq 0x4D -and $Header[1] -eq 0x5A)
        }
        finally { $Stream.Dispose() }
    }
    catch { }
    if (-not $IsExe) {
        Write-HostTimestamp '  The downloaded file is not a Windows executable. Discarding it.' -ForegroundColor Red
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Only trust a binary that matches the pinned hash for this exact build. If the URL was overridden
    # (so the hash cannot match), fall back to checking the file's Microsoft version resource.
    if ($OscdimgSha256) {
        $Hash = (Get-FileHash -LiteralPath $Temp -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        if ($Hash -ne $OscdimgSha256) {
            Write-HostTimestamp "  The downloaded oscdimg.exe does not match the expected SHA-256 (got $Hash). Discarding it." -ForegroundColor Red
            Write-HostTimestamp '  If you deliberately pointed -OscdimgUrl at a different build, pass the matching -OscdimgSha256 (or an empty string to skip this check).' -ForegroundColor Yellow
            Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
            return $null
        }
    }
    elseif ((Get-Item -LiteralPath $Temp).VersionInfo.CompanyName -notmatch '(?i)Microsoft') {
        Write-HostTimestamp '  The downloaded file is not a Microsoft binary. Discarding it.' -ForegroundColor Red
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
        return $null
    }

    try {
        Move-Item -LiteralPath $Temp -Destination $OscdimgLocalPath -Force -ErrorAction Stop
    }
    catch {
        Write-HostTimestamp "  Could not save oscdimg.exe to '$OscdimgLocalPath': $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Clear the Mark of the Web so the downloaded binary is not blocked when it runs.
    Unblock-File -LiteralPath $OscdimgLocalPath -ErrorAction SilentlyContinue
    return $OscdimgLocalPath
}

# Downloads the Windows ADK bootstrapper and silently installs ONLY the Deployment Tools feature (which
# contains oscdimg.exe). Returns the oscdimg path on success, or $null.
function Install-AdkDeploymentTools {
    if (-not (Test-MicrosoftDownloadUrl -Url $AdkSetupUrl) -and $AdkSetupUrl -notmatch '(?i)^https://go\.microsoft\.com/') {
        Write-HostTimestamp "  The ADK setup URL is not an official Microsoft URL. Refusing to download it: $AdkSetupUrl" -ForegroundColor Red
        return $null
    }

    $Setup = Join-Path -Path $env:TEMP -ChildPath "adksetup_$(Get-Date -Format 'yyyyMMdd_HHmmss').exe"
    Write-HostTimestamp '  Downloading the Windows ADK setup bootstrapper from Microsoft...'
    if (-not (Get-FileDownload -Url $AdkSetupUrl -Destination $Setup)) {
        Write-HostTimestamp '  Could not download the ADK setup bootstrapper.' -ForegroundColor Red
        return $null
    }

    Write-HostTimestamp '  Installing the ADK Deployment Tools silently (this downloads a few hundred MB and takes a few minutes)...'
    try {
        $Proc = Start-Process -FilePath $Setup -ArgumentList @('/quiet', '/norestart', '/features', 'OptionId.DeploymentTools') -Wait -PassThru -ErrorAction Stop
        if ($Proc.ExitCode -ne 0) {
            Write-HostTimestamp "  ADK setup returned exit code $($Proc.ExitCode)." -ForegroundColor Yellow
        }
    }
    catch {
        Write-HostTimestamp "  ADK installation failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
    finally {
        Remove-Item -LiteralPath $Setup -Force -ErrorAction SilentlyContinue
    }

    return (Find-Oscdimg)
}

# Returns the 8.3 short path for a file, avoiding spaces in paths passed to oscdimg's -bootdata argument.
function Get-ShortPath {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $Fso = New-Object -ComObject Scripting.FileSystemObject
        $Short = $Fso.GetFile($Path).ShortPath
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($Fso) | Out-Null
        if ($Short) { return $Short }
    }
    catch { }
    return $Path
}

# Resolves a list of edition tokens (edition names, partial names, or index numbers) to the matching
# install.wim image indexes. Returns the distinct, sorted indexes that matched. Unmatched tokens are
# reported via the [ref]$Unmatched list so the caller can decide whether to fail.
function Resolve-EditionIndexes {
    param(
        [Parameter(Mandatory)][object[]]$Images,
        [Parameter(Mandatory)][string[]]$Tokens,
        [ref]$Unmatched
    )
    $Matched = New-Object System.Collections.Generic.List[int]
    $NoMatch = New-Object System.Collections.Generic.List[string]
    foreach ($Token in $Tokens) {
        $T = "$Token".Trim()
        if (-not $T) { continue }
        $Found = $null
        if ($T -match '^\d+$') {
            $Found = $Images | Where-Object { $_.ImageIndex -eq [int]$T }
        }
        else {
            $Found = $Images | Where-Object { $_.ImageName -eq $T }
            if (-not $Found) { $Found = $Images | Where-Object { $_.ImageName -like "*$T*" } }
        }
        if ($Found) { $Found | ForEach-Object { [void]$Matched.Add([int]$_.ImageIndex) } }
        else { [void]$NoMatch.Add($T) }
    }
    if ($Unmatched) { $Unmatched.Value = $NoMatch }
    return ($Matched | Sort-Object -Unique)
}

# Scores a Windows edition name so the "highest" edition can be picked automatically. Only Enterprise,
# Pro, and Home are considered (Enterprise > Pro > Home); Education and Workstation editions (including
# "Pro Education" and "Pro for Workstations") are deliberately excluded and scored lowest so they are
# never chosen when a plain Enterprise/Pro/Home edition is present. Within a tier, base editions are
# preferred over the "N" and "Single Language" variants.
function Get-EditionRank {
    param([string]$Name)
    $n = "$Name".ToLower()
    if ($n -match 'education|workstation') { $Rank = 5 }  # excluded tiers - lowest priority
    elseif ($n -match 'enterprise') { $Rank = 60 }
    elseif ($n -match 'pro') { $Rank = 40 }
    elseif ($n -match 'home|core') { $Rank = 20 }
    else { $Rank = 10 }
    if ($n -match '(^|\s)n(\s|$)') { $Rank -= 2 }   # prefer base over "N" variants
    if ($n -match 'single language') { $Rank -= 1 } # prefer base over Single Language
    return $Rank
}

# Shortens a WIM edition name ("Windows 11 Pro") to the tag used in the output ISO file name.
function Get-EditionShortName {
    param([string]$Name)
    $n = "$Name".ToLower()
    if ($n -match 'enterprise') { return 'Ent' }
    if ($n -match 'education') { return 'Edu' }
    if ($n -match 'pro') { return 'Pro' }
    if ($n -match 'home|core') { return 'Home' }
    $Short = ($Name -replace '(?i)^\s*windows\s*\d+\s*', '') -replace '[^A-Za-z0-9]', ''
    if ($Short) { return $Short } else { return 'Windows' }
}

# Builds the default output ISO name, e.g. Win11_Pro_x64_26100.4061_20260815-1332.iso. The build/UBR comes
# from the serviced image when available (that is the only place the post-update revision is known),
# otherwise from the source image's version. Several kept editions collapse to "Multi".
function Get-DefaultIsoName {
    param(
        [object[]]$Images,
        [int[]]$Indexes,
        [string]$BuildString,
        [string]$FallbackVersion,
        [string]$Architecture
    )

    $Kept = @($Images | Where-Object { $Indexes -contains [int]$_.ImageIndex })
    $Tags = @($Kept | ForEach-Object { Get-EditionShortName $_.ImageName } | Select-Object -Unique)
    $EditionTag = if ($Tags.Count -eq 1) { $Tags[0] } elseif ($Tags.Count -gt 1) { 'Multi' } else { 'Windows' }

    $BuildUbr = $null
    foreach ($Candidate in @($BuildString, $FallbackVersion)) {
        if ("$Candidate" -match '\b\d+\.\d+\.(\d+)\.(\d+)') { $BuildUbr = "$($Matches[1]).$($Matches[2])"; break }
    }
    $BuildNumber = if ("$BuildUbr" -match '^(\d+)') { [int]$Matches[1] } else { 0 }
    $WindowsTag = if ($BuildNumber -ge 22000) { 'Win11' } elseif ($BuildNumber -gt 0) { 'Win10' } else { 'Windows' }

    $Parts = @($WindowsTag, $EditionTag)
    if ($Architecture) { $Parts += ($Architecture -replace '[^A-Za-z0-9]', '') }
    if ($BuildUbr) { $Parts += $BuildUbr }
    $Parts += (Get-Date -Format 'yyyyMMdd-HHmm')
    return (($Parts -join '_') + '.iso')
}

# Ensures a mount directory is clean and ready to receive a fresh WIM mount. A previous run that crashed
# or was killed can leave an image still mounted (or a corrupt mount point) there, which makes the next
# Mount-WindowsImage fail. DISM tracks a mount by WIM file + index as well as by directory, so a mount
# left over at some other path still blocks the same index with "the specified image in the specified wim
# is already mounted for read/write access". Pass -ImagePath so both are released.
function Reset-MountDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ImagePath
    )

    $Normalized = $Path.TrimEnd('\')
    $TargetWim = if ($ImagePath) {
        try { (Get-Item -LiteralPath $ImagePath -ErrorAction Stop).FullName } catch { $ImagePath }
    }
    else { $null }

    $FindStale = {
        try {
            @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object {
                    ($_.Path -and $_.Path.TrimEnd('\') -ieq $Normalized) -or
                    ($TargetWim -and $_.ImagePath -and $_.ImagePath -ieq $TargetWim)
                })
        }
        catch { @() }
    }

    foreach ($M in (& $FindStale)) {
        $Leaf = if ($M.ImagePath) { Split-Path $M.ImagePath -Leaf } else { 'image' }
        Write-HostTimestamp "    A previous run left $Leaf index $($M.ImageIndex) mounted at $($M.Path) - discarding it..." -ForegroundColor Yellow
        if ($M.Path) {
            try { Dismount-WindowsImage -Path $M.Path -Discard -ErrorAction Stop | Out-Null }
            catch { Write-HostTimestamp "      Discard failed: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }

    # Releases mounts whose directory was deleted from under DISM; the only way back from an orphaned mount.
    try { Clear-WindowsCorruptMountPoint -ErrorAction SilentlyContinue | Out-Null } catch { }

    $Stale = & $FindStale
    if ($Stale) {
        $Detail = ($Stale | ForEach-Object { "$(if ($_.ImagePath) { Split-Path $_.ImagePath -Leaf } else { 'image' }) index $($_.ImageIndex)" }) -join ', '
        throw "An image is still mounted ($Detail) and DISM will reject the next mount. Run 'dism /Cleanup-Mountpoints' from an elevated prompt, or reboot, then start the build again."
    }

    # Only safe once nothing is mounted here - deleting a tracked mount directory is what orphans it.
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Path) {
            Start-Sleep -Seconds 2
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
}

# Applies ONE update "group" to a mounted image using Microsoft's documented checkpoint-cumulative-update
# method. A group is an ordered set of related packages with the TARGET package LAST (e.g. [checkpoint, LCU]
# or just [.NET CU]).
#
# Per Microsoft (learn.microsoft.com/windows/deployment/update/catalog-checkpoint-cumulative-updates), the
# correct procedure is: place the target .msu AND all its prior checkpoint .msu files in a clean folder with
# no other .msu present, then run "DISM /Add-Package" with ONLY the latest (target) .msu as the sole target.
# DISM pulls the differentials it needs from the checkpoint files automatically. Adding a checkpoint as its
# own /PackagePath target is NOT supported and corrupts the image (STATUS_SXS_FILE_HASH_MISMATCH / 0x80070228).
#
# Returns $true if DISM reported success (or the package was already present), $false on a real failure.
function Add-UpdateGroup {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][object[]]$Group,
        [string]$Label = 'update package'
    )

    if (-not $Group -or $Group.Count -eq 0) { return $true }

    # Stage the whole group in a clean, isolated folder so DISM sees ONLY these files (no unrelated .msu).
    $Stage = Join-Path -Path $WorkRoot -ChildPath ('pkgstage_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        New-Item -ItemType Directory -Path $Stage -Force -ErrorAction Stop | Out-Null

        $Target = $null
        foreach ($Pkg in $Group) {
            $Dest = Join-Path -Path $Stage -ChildPath (Split-Path -Leaf $Pkg)
            Copy-Item -LiteralPath $Pkg -Destination $Dest -Force -ErrorAction Stop
            $Target = $Dest  # the group is ordered target-last, so the final file copied is the target
        }

        $Extra = if ($Group.Count -gt 1) { " (+$($Group.Count - 1) prior checkpoint file(s) staged alongside)" } else { '' }
        Write-HostTimestamp "      Applying ${Label}: $(Split-Path -Leaf $Target)$Extra"
        Write-HostTimestamp '      Running DISM /Add-Package with the target as the sole package (this can take several minutes)...'

        # Run DISM, and if it fails on the first try, retry once - transient issues (locked files, a busy
        # servicing stack, a momentary I/O hiccup) often clear on a second attempt.
        $MaxAttempts = 2
        for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
            $Output = & dism.exe "/Image:$MountDir" '/Add-Package' "/PackagePath:$Target" 2>&1
            $ExitCode = $LASTEXITCODE

            if ($ExitCode -eq 0 -or $ExitCode -eq 3010) {
                Write-HostTimestamp '      Applied.' -ForegroundColor Green
                return $true
            }
            if ($Output -match '0x800f081e') {
                Write-HostTimestamp '      Already present / not applicable - skipping.' -ForegroundColor DarkGray
                return $true
            }

            if ($Attempt -lt $MaxAttempts) {
                Write-HostTimestamp "      DISM /Add-Package failed (exit code $ExitCode). Retrying once..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds 5
            }
        }

        Write-HostTimestamp "      This package didn't apply (DISM exit code $ExitCode). Details are in C:\Windows\Logs\DISM\dism.log." -ForegroundColor DarkYellow
        $Output | Where-Object { $_ -match '(?i)error|0x[0-9a-f]{8}' } | Select-Object -Last 8 | ForEach-Object {
            Write-Host "        $_" -ForegroundColor DarkGray
        }
        # A hash mismatch here just means the base image's files don't match their manifests - usually a
        # repacked/UUP ISO rather than a clean Microsoft one. It's informational, not a crash.
        if ($Output -match '0x80070228' -or $Output -match '(?i)Unattend\.xml') {
            Write-HostTimestamp '      Tip: this is typically the base image, not the update - the install.wim files did not match' -ForegroundColor DarkGray
            Write-HostTimestamp '      their manifests (common with repacked/UUP ISOs). A clean official Microsoft ISO usually resolves it.' -ForegroundColor DarkGray
        }
        return $false
    }
    catch {
        Write-HostTimestamp "      This package couldn't be staged/applied: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $false
    }
    finally {
        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Reads the exact build (with UBR) out of an ALREADY-MOUNTED image's offline SOFTWARE hive.
# Returns a version string, or $null if the hive could not be read.
function Get-MountedImageBuild {
    param([Parameter(Mandatory)][string]$MountPath)

    $Hive = 'HKLM\WISO_BUILD'
    $SoftwareHive = Join-Path $MountPath 'Windows\System32\config\SOFTWARE'
    if (-not (Test-Path -LiteralPath $SoftwareHive)) { return $null }
    try {
        & reg.exe load $Hive $SoftwareHive *> $null
        if ($LASTEXITCODE -ne 0) { return $null }
        try {
            $Cv = Get-ItemProperty -Path "Registry::$Hive\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
            return "10.0.$($Cv.CurrentBuildNumber).$($Cv.UBR)$(if ($Cv.DisplayVersion) { " ($($Cv.DisplayVersion))" })"
        }
        finally {
            # The hive will not unload while PowerShell still holds a handle to the key it just read.
            [gc]::Collect(); [gc]::WaitForPendingFinalizers()
            & reg.exe unload $Hive *> $null
        }
    }
    catch { return $null }
}

# Reports the editions (indexes) inside the finished install.wim and the exact OS build. The build number
# (including the revision/UBR set by the cumulative update) isn't stored in the WIM header, so it comes from
# the image's offline SOFTWARE hive - reusing the value captured during servicing, or mounting read-only if
# there is none (mounting a finished image, especially a recovery-compressed .esd, costs several minutes).
function Show-FinalImageInfo {
    param([Parameter(Mandatory)][string]$WimPath)

    $Images = $null
    try { $Images = @(Get-WindowsImage -ImagePath $WimPath -ErrorAction Stop) } catch { }
    if (-not $Images -or $Images.Count -eq 0) {
        Write-HostTimestamp '  Could not read the final image information.' -ForegroundColor DarkGray
        return
    }

    Write-HostTimestamp 'Editions (indexes) in the final ISO:' -ForegroundColor Cyan
    foreach ($Img in $Images) { Write-Host ("    [{0}] {1}" -f $Img.ImageIndex, $Img.ImageName) }

    # Read the exact build (with UBR) from the first index's SOFTWARE hive.
    $BuildStr = $script:FinalBuildString
    if (-not $BuildStr) {
        $Mnt = Join-Path -Path $WorkRoot -ChildPath 'BuildCheck'
        Write-HostTimestamp '  Nothing was serviced this run, so the image has to be mounted to read its exact build. This takes a few minutes...' -ForegroundColor DarkGray
        try {
            Reset-MountDirectory -Path $Mnt -ImagePath $WimPath
            Mount-WindowsImage -ImagePath $WimPath -Index $Images[0].ImageIndex -Path $Mnt -ReadOnly -ErrorAction Stop | Out-Null
            $BuildStr = Get-MountedImageBuild -MountPath $Mnt
            Dismount-WindowsImage -Path $Mnt -Discard -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Dismount-WindowsImage -Path $Mnt -Discard -ErrorAction SilentlyContinue | Out-Null
        }
        finally {
            # Removing a directory DISM still tracks as mounted is what orphans a mount point, so leave it alone
            # if the discard above did not take.
            if (-not (Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.TrimEnd('\') -ieq $Mnt.TrimEnd('\') })) {
                Remove-Item -LiteralPath $Mnt -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($BuildStr) { Write-HostTimestamp "Final OS build: $BuildStr" -ForegroundColor Cyan }
    else { Write-HostTimestamp "Final OS build: $($Images[0].Version) (revision unavailable)" -ForegroundColor Cyan }
}

Write-Host $LineBreak
Write-HostTimestamp "Windows ISO Updater (slipstream latest updates into a new ISO) on $($env:ComputerName)" -ForegroundColor Cyan
Write-Host $LineBreak

$WinInfo = Get-InstalledWindowsInfo

# Warn if a working/download/log path looks like a cloud-synced folder - servicing from there is unreliable.
$CloudPattern = '(?i)[\\/](My Drive|Google Drive|GoogleDrive|OneDrive|OneDrive - |Dropbox|iCloudDrive|Box)[\\/]'
foreach ($Pair in @(@{ Name = 'Working folder'; Path = $WorkRoot }, @{ Name = 'Download folder'; Path = $DlDir }, @{ Name = 'Log folder'; Path = $LogDir })) {
    if ($Pair.Path -match $CloudPattern -or $Pair.Path -match '(?i)OneDrive') {
        Write-HostTimestamp "WARNING: The $($Pair.Name.ToLower()) is on a cloud-synced path ($($Pair.Path))." -ForegroundColor Yellow
        Write-HostTimestamp "         DISM cannot reliably service files that a cloud client streams/dehydrates. Use -WorkPath and -DownloadPath to point at a LOCAL disk (e.g. C:\WISO-Work)." -ForegroundColor Yellow
    }
}

foreach ($Dir in @($WorkRoot, $DlDir)) {
    try {
        if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null }
    }
    catch {
        Write-HostTimestamp "Could not create the folder '$Dir': $($_.Exception.Message). Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
}

Write-HostTimestamp "Architecture   : $($WinInfo.Architecture)"
Write-HostTimestamp "Target         : Windows $WindowsVersion ($Release, $Language)"
Write-Host $LineBreak
Write-Host 'Everything this run writes goes under the working folder:' -ForegroundColor Cyan
Write-Host "  Working folder   : $WorkRoot"
Write-Host "    Extracted media: $ExtractDir"
Write-Host "    DISM mount     : $MountDir"
Write-Host "  Downloads        : $DlDir"
if (-not $IsoPath) { Write-Host '                     (drop your own .iso here and it is used instead of downloading one)' -ForegroundColor DarkGray }
Write-Host "  Logs             : $LogDir"
Write-Host "  Finished ISO     : $(if ($OutputIsoPath) { $OutputIsoPath } else { Join-Path $DlDir 'Win11_Pro_x64_<build>.<UBR>_<date-time>.iso' })"
Write-Host ''
Write-Host '  Nothing outside these folders is changed. -WorkPath moves all of it; -DownloadPath, -LogPath' -ForegroundColor DarkGray
Write-Host '  and -OutputIsoPath override the individual folders.' -ForegroundColor DarkGray
Write-Host $LineBreak

# --- Disk space check ---
# The download (~8 GB), extracted media (~8 GB), the mounted image, and the re-exported image all coexist
# during the build, so the working drive needs plenty of headroom.
$FreeGB = Get-DriveFreeGB -Path $WorkRoot
if ($null -eq $FreeGB) {
    Write-HostTimestamp 'Could not determine free disk space on the working drive. Continuing with caution.' -ForegroundColor Yellow
}
else {
    Write-HostTimestamp "Free space on the working drive: $FreeGB GB"
    $RequiredGB = 50
    if ($FreeGB -lt $RequiredGB) {
        Write-HostTimestamp "CRITICAL: Less than $RequiredGB GB free on the working drive. Building a patched ISO needs a lot of scratch space. Free up space, choose another drive with -WorkPath, and try again." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
}
Write-Host $LineBreak

# --- Validate the unattended answer file ---
$ResolvedUnattend = $null
$UnattendText = $null
if ($UnattendPath) {
    if (-not (Test-Path -LiteralPath $UnattendPath -PathType Leaf)) {
        Write-HostTimestamp "The answer file '$UnattendPath' does not exist. Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $ResolvedUnattend = (Resolve-Path -LiteralPath $UnattendPath).Path
    $UnattendDoc = New-Object System.Xml.XmlDocument
    $UnattendDoc.XmlResolver = $null  # do not resolve external entities (XXE)
    try {
        $UnattendDoc.Load($ResolvedUnattend)
    }
    catch {
        Write-HostTimestamp "The answer file '$ResolvedUnattend' is not valid XML: $($_.Exception.Message). Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $UnattendText = $UnattendDoc.OuterXml
    Write-HostTimestamp "Answer file    : $ResolvedUnattend" -ForegroundColor Green
    if ($UnattendDoc.DocumentElement.Name -ne 'unattend') {
        Write-HostTimestamp "  Warning: the root element is <$($UnattendDoc.DocumentElement.Name)>, not <unattend>. Windows Setup will ignore this file." -ForegroundColor Yellow
    }
    if ($UnattendText -match '(?i)<(Password|AdministratorPassword|ProductKey)\b') {
        Write-HostTimestamp '  NOTE: this answer file contains password/product key elements. Windows stores these in plain text or base64, and the finished ISO is not encrypted - anyone who can read the ISO can recover them.' -ForegroundColor Yellow
    }
    Write-Host $LineBreak
}

# --- Interactive confirmation ---
if (-not $Unattended -and -not $SkipInteractive -and -not $ListEditions) {
    Write-Host "This tool builds an updated Windows installation ISO. It will:"
    if (-not $IsoPath) {
        Write-Host "  - Download the matching official Windows $WindowsVersion ISO from Microsoft (~8 GB)"
        Write-Host "      TIP: Microsoft can rate-limit/block repeated ISO downloads. The script retries, and can" -ForegroundColor Yellow
        Write-Host "           then offer Microsoft's Media Creation Tool instead. To skip all that, download the" -ForegroundColor Yellow
        Write-Host "           ISO yourself and re-run with -IsoPath." -ForegroundColor Yellow
    }
    else {
        Write-Host "  - Use the ISO you provided: $IsoPath"
    }
    Write-Host "  - Extract it to $ExtractDir"
    if ($KeepEditions -and $KeepEditions.Count -gt 0) {
        Write-Host "  - Keep ONLY these editions in the final ISO (remove the rest): $($KeepEditions -join ', ')" -ForegroundColor Yellow
    }
    elseif ($KeepAllEditions) {
        Write-Host "  - Keep ALL editions in the final ISO (-KeepAllEditions)"
    }
    else {
        Write-Host "  - Keep ONLY the highest edition present (e.g. Enterprise over Pro, or Pro over Home) to speed up the build; use -KeepAllEditions to keep them all" -ForegroundColor Yellow
    }
    if (-not $SkipUpdates) {
        if ($UpdatePath) {
            Write-Host "  - Integrate the update packages found in: $UpdatePath"
        }
        else {
            Write-Host "  - Download the latest cumulative update(s)$(if (-not $SkipDotNet) { ' and the latest .NET cumulative update' }) from the Microsoft Update Catalog"
            if (-not $SkipSetupDU) { Write-Host "  - Download the latest Setup Dynamic Update and apply it to the media's sources folder" }
        }
        Write-Host "  - Integrate the update(s) into install.wim ($Edition), boot.wim$(if ($ServiceWinRE) { ', and winre.wim' })"
        Write-Host "  - Clean up and re-export the images to shrink them"
    }
    else {
        Write-Host "  - Skip update integration (-SkipUpdates) and just recompile the ISO"
    }
    if ($CompressEsd) {
        Write-Host "  - Export the image as install.esd with recovery compression (-CompressEsd): a much smaller ISO, but a slow export and the media cannot be serviced again afterwards" -ForegroundColor Yellow
    }
    if ($ResolvedUnattend) {
        Write-Host "  - Place your answer file on the media as autounattend.xml, so Setup runs unattended: $ResolvedUnattend" -ForegroundColor Yellow
    }
    Write-Host "  - Recompile a new bootable ISO with oscdimg"
    Write-Host ""
    Write-Host "With the default settings this normally takes an hour or two from start to finish." -ForegroundColor Yellow
    Write-Host "This is disk- and time-intensive and needs a lot of free space. Nothing on this PC is changed." -ForegroundColor Yellow
    Write-Host ""
    $Confirm = Read-Host "Type 'Y' to continue, or anything else to cancel"
    if ($Confirm -notin @('Y', 'y', 'Yes', 'yes')) {
        Write-HostTimestamp 'Operation cancelled by user.' -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit 0
    }
    Write-Host $LineBreak
}

# --- Locate oscdimg early so we fail fast if the ISO cannot be recompiled (not needed for -ListEditions) ---
$Oscdimg = $null
if (-not $ListEditions) {
    Invoke-Task -Description 'Locating oscdimg.exe (Windows ADK Deployment Tools)...' -ScriptBlock {
        $script:Oscdimg = Find-Oscdimg
        if ($script:Oscdimg) {
            Write-HostTimestamp "  Found oscdimg: $($script:Oscdimg)" -ForegroundColor Green
        }
        else {
            # Grab the single ~150 KB executable straight from Microsoft's symbol server first; only fall
            # back to the full ADK install (which is hundreds of MB) if that fails.
            if (-not $SkipOscdimgDownload) {
                Write-HostTimestamp '  oscdimg was not found. Downloading a standalone copy from Microsoft...' -ForegroundColor Yellow
                $script:Oscdimg = Get-OscdimgDownload
                if ($script:Oscdimg) { Write-HostTimestamp "  Downloaded oscdimg: $($script:Oscdimg)" -ForegroundColor Green }
            }
            if (-not $script:Oscdimg -and $InstallAdk) {
                Write-HostTimestamp '  Installing the Windows ADK Deployment Tools...' -ForegroundColor Yellow
                $script:Oscdimg = Install-AdkDeploymentTools
                if ($script:Oscdimg) { Write-HostTimestamp "  Installed. Found oscdimg: $($script:Oscdimg)" -ForegroundColor Green }
            }
        }
    }
    $Oscdimg = $script:Oscdimg
    if (-not $Oscdimg) {
        Write-HostTimestamp 'oscdimg.exe was not found and could not be downloaded. It is part of the Windows ADK "Deployment Tools" feature and is required to recompile the ISO.' -ForegroundColor Red
        Write-HostTimestamp 'Re-run with -InstallAdk to have this script download and install the ADK automatically, or install the Windows ADK (Deployment Tools) manually from Microsoft and re-run.' -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit 1
    }
    Write-Host $LineBreak
}

# --- Obtain the ISO ---
$ResolvedIso = $null
if ($IsoPath) {
    if (Test-Path -LiteralPath $IsoPath) {
        $ResolvedIso = (Resolve-Path -LiteralPath $IsoPath).Path
        Write-HostTimestamp "Using the provided ISO: $ResolvedIso" -ForegroundColor Green

        # If the ISO sits on a cloud-synced path, copy it to the local download folder first. Mounting and
        # reading a cloud placeholder during the long extraction is slow and unreliable; a local copy is not.
        if (($ResolvedIso -match $CloudPattern -or $ResolvedIso -match '(?i)OneDrive') -and
            -not ($DlDir -match $CloudPattern -or $DlDir -match '(?i)OneDrive')) {
            $LocalIso = Join-Path -Path $DlDir -ChildPath (Split-Path -Leaf $ResolvedIso)
            $SourceLen = (Get-Item -LiteralPath $ResolvedIso).Length
            if ((Test-Path -LiteralPath $LocalIso) -and ((Get-Item -LiteralPath $LocalIso).Length -eq $SourceLen)) {
                Write-HostTimestamp "  A local copy already exists - using it: $LocalIso" -ForegroundColor Green
                $ResolvedIso = $LocalIso
            }
            else {
                try {
                    Invoke-Task -Description "The ISO is on a cloud-synced path; copying it to a local disk first ($([math]::Round($SourceLen / 1GB, 2)) GB): $LocalIso ..." -ScriptBlock {
                        Copy-Item -LiteralPath $ResolvedIso -Destination $LocalIso -Force -ErrorAction Stop
                        Write-HostTimestamp '  Copy complete.' -ForegroundColor Green
                    }
                    $ResolvedIso = $LocalIso
                }
                catch {
                    Write-HostTimestamp "  Could not copy the ISO locally ($($_.Exception.Message)). Proceeding from the cloud path - this may be slow or fail." -ForegroundColor Yellow
                }
            }
        }
    }
    else {
        Write-HostTimestamp "The ISO path '$IsoPath' does not exist. Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
}
else {
    # Reuse an already-downloaded ISO in the download folder if present, otherwise resolve + download one.
    $ExistingIso = Get-ChildItem -Path $DlDir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Length -gt 3GB } |
        Sort-Object -Property Length -Descending |
        Select-Object -First 1
    if ($ExistingIso) {
        $ResolvedIso = $ExistingIso.FullName
        Write-HostTimestamp "An ISO is already downloaded - reusing it: $ResolvedIso ($([math]::Round($ExistingIso.Length / 1GB, 2)) GB)" -ForegroundColor Green
    }
    else {
        # -UseMct skips Fido entirely; otherwise Fido is tried first and MCT is offered if it is blocked.
        if ($UseMct) {
            $ResolvedIso = Get-IsoViaMct -Version $WindowsVersion -Language $Language -Architecture $WinInfo.Architecture -DownloadDir $DlDir
            if (-not $ResolvedIso) {
                Write-HostTimestamp 'No ISO was produced with the Media Creation Tool. Cannot continue.' -ForegroundColor Red
                Stop-Transcript | Out-Null
                exit 1
            }
        }
        else {
            Invoke-Task -Description 'Obtaining the Windows ISO download link from Microsoft...' -ScriptBlock {
                $script:IsoUrl = Get-WindowsIsoUrl -Version $WindowsVersion -Release $Release -Language $Language -Architecture $WinInfo.Architecture
            }
            if (-not $script:IsoUrl) {
                Write-HostTimestamp 'Could not obtain a download link. Microsoft may be rate-limiting/blocking your IP for repeated ISO requests.' -ForegroundColor Yellow

                # The Media Creation Tool uses different Microsoft endpoints, so it usually still works when
                # the download-link API is blocked - but it needs someone to click through its wizard.
                $CanPrompt = -not ($Unattended -or $SkipInteractive)
                if ($CanPrompt) {
                    Write-Host ''
                    $Answer = Read-Host "Microsoft's Media Creation Tool uses different servers and usually still works. Open it now? (Y/N)"
                    if ($Answer -match '(?i)^\s*(y|yes)\s*$') {
                        $ResolvedIso = Get-IsoViaMct -Version $WindowsVersion -Language $Language -Architecture $WinInfo.Architecture -DownloadDir $DlDir
                    }
                }
                else {
                    Write-HostTimestamp 'Re-run interactively (without -Unattended/-SkipInteractive) and this script can open the Media Creation Tool for you, or pass -UseMct.' -ForegroundColor Yellow
                }

                if (-not $ResolvedIso) {
                    Write-HostTimestamp 'Download the ISO yourself from https://www.microsoft.com/software-download, then either re-run with -IsoPath "C:\path\to\Windows.iso"' -ForegroundColor Yellow
                    Write-HostTimestamp "or simply drop the .iso into the download folder and re-run - it is picked up automatically: $DlDir" -ForegroundColor Yellow
                    Stop-Transcript | Out-Null
                    exit 1
                }
            }
        }

        if (-not $ResolvedIso) {
            $FileName = $null
            try { $FileName = [System.IO.Path]::GetFileName(([Uri]$script:IsoUrl).AbsolutePath) } catch { }
            if (-not $FileName -or $FileName -notmatch '\.iso$') {
                $FileName = "Windows$WindowsVersion`_$Language`_$($WinInfo.Architecture).iso"
            }
            $ResolvedIso = Join-Path -Path $DlDir -ChildPath $FileName

            Invoke-Task -Description "Downloading the Windows $WindowsVersion ISO to $ResolvedIso ..." -ScriptBlock {
                if (-not (Get-FileDownload -Url $script:IsoUrl -Destination $ResolvedIso)) {
                    Write-HostTimestamp 'ISO download failed. Microsoft may be rate-limiting/blocking your IP for repeated ISO requests.' -ForegroundColor Red
                    Write-HostTimestamp 'Download the ISO yourself from https://www.microsoft.com/software-download and re-run with -IsoPath "C:\path\to\Windows.iso".' -ForegroundColor Yellow
                    Stop-Transcript | Out-Null
                    exit 1
                }
                $SizeGB = [math]::Round((Get-Item -LiteralPath $ResolvedIso).Length / 1GB, 2)
                if ($SizeGB -lt 3) {
                    Write-HostTimestamp "The downloaded file is only $SizeGB GB - that is too small to be a Windows ISO. The download likely failed." -ForegroundColor Red
                    Stop-Transcript | Out-Null
                    exit 1
                }
                Write-HostTimestamp "  Download complete ($SizeGB GB)." -ForegroundColor Green
            }
        }
    }
}
Write-Host $LineBreak

# --- List editions and exit (-ListEditions) ---
# Mount the ISO (no full extraction needed) just to read the editions inside install.wim/esd, print them,
# then dismount and exit. Handy for picking -Edition / -KeepEditions values before a full build.
if ($ListEditions) {
    $ListMount = $null
    try {
        $ListMount = Mount-DiskImage -ImagePath $ResolvedIso -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
        $ListDrive = ($ListMount | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
        if (-not $ListDrive) { $ListDrive = (Get-DiskImage -ImagePath $ResolvedIso | Get-Volume -ErrorAction SilentlyContinue).DriveLetter }
        if (-not $ListDrive) { throw 'Could not determine the drive letter of the mounted ISO.' }

        $ListImg = "$($ListDrive):\sources\install.wim"
        if (-not (Test-Path -LiteralPath $ListImg)) { $ListImg = "$($ListDrive):\sources\install.esd" }
        if (-not (Test-Path -LiteralPath $ListImg)) { throw 'No install.wim or install.esd was found on the ISO.' }

        Write-HostTimestamp "Editions inside $(Split-Path -Leaf $ListImg):" -ForegroundColor Cyan
        Get-WindowsImage -ImagePath $ListImg -ErrorAction Stop | ForEach-Object {
            Write-Host ("    [{0}] {1}" -f $_.ImageIndex, $_.ImageName)
        }
        Write-Host ''
        Write-Host 'Use these with -Edition (which to service) or -KeepEditions (which to keep in the final ISO).'
        Write-Host 'Example: -KeepEditions "Windows 11 Pro","Windows 11 Home"   or   -KeepEditions 6,1'
    }
    catch {
        Write-HostTimestamp "Could not list the editions: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if ($ListMount) { Dismount-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue | Out-Null }
    }
    Write-Host $LineBreak
    Stop-Transcript | Out-Null
    exit 0
}

# --- Extract the ISO to the working folder ---
$MountedImage = $null
try {
    Invoke-Task -Description "Mounting the ISO to copy its contents: $ResolvedIso ..." -ScriptBlock {
        # If a previous attempt left this ISO mounted, dismount it before mounting again. If that
        # dismount fails (or the image will not release), do NOT proceed on a stale/duplicate mount -
        # throw so the outer catch aborts the whole run.
        $Existing = Get-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue
        if ($Existing -and $Existing.Attached) {
            Write-HostTimestamp '  This ISO is still mounted from a previous attempt - dismounting it first...' -ForegroundColor Yellow
            try {
                Dismount-DiskImage -ImagePath $ResolvedIso -ErrorAction Stop | Out-Null
                Start-Sleep -Seconds 2
            }
            catch {
                throw "The ISO is still mounted from a previous attempt and could not be dismounted: $($_.Exception.Message). Aborting."
            }
            if ((Get-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue).Attached) {
                throw 'The ISO is still mounted from a previous attempt and could not be dismounted. Aborting.'
            }
        }
        $script:MountedImage = Mount-DiskImage -ImagePath $ResolvedIso -PassThru -ErrorAction Stop
        Start-Sleep -Seconds 2
    }
    $MountedImage = $script:MountedImage

    $DriveLetter = ($MountedImage | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
    if (-not $DriveLetter) {
        $DriveLetter = (Get-DiskImage -ImagePath $ResolvedIso | Get-Volume -ErrorAction SilentlyContinue).DriveLetter
    }
    if (-not $DriveLetter) { throw 'Could not determine the drive letter of the mounted ISO.' }
    Write-HostTimestamp "  ISO mounted at $($DriveLetter):\" -ForegroundColor Green

    if (-not (Test-Path -LiteralPath "$($DriveLetter):\sources\install.wim") -and
        -not (Test-Path -LiteralPath "$($DriveLetter):\sources\install.esd")) {
        throw 'The mounted image has no sources\install.wim or install.esd - this is not a Windows installation ISO.'
    }

    Invoke-Task -Description "Extracting the ISO contents to $ExtractDir ..." -ScriptBlock {
        if (Test-Path $ExtractDir) { Remove-Item -LiteralPath $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $ExtractDir -Force -ErrorAction Stop | Out-Null
        # robocopy mirrors the whole media reliably (long paths, retries). /NP keeps the log readable.
        $RoboArgs = @("$($DriveLetter):\", $ExtractDir, '/E', '/COPY:DAT', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
        & robocopy.exe @RoboArgs | Out-Null
        # robocopy exit codes 0-7 indicate success; 8+ indicates a real failure.
        if ($LASTEXITCODE -ge 8) { throw "robocopy failed to copy the ISO contents (exit code $LASTEXITCODE)." }
        Write-HostTimestamp '  Extraction complete.' -ForegroundColor Green
    }
}
catch {
    Write-HostTimestamp "Could not extract the ISO: $($_.Exception.Message)" -ForegroundColor Red
    if ($MountedImage) { Dismount-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue | Out-Null }
    Stop-Transcript | Out-Null
    exit 1
}
finally {
    if ($MountedImage) {
        Dismount-DiskImage -ImagePath $ResolvedIso -ErrorAction SilentlyContinue | Out-Null
        Write-HostTimestamp '  Dismounted the source ISO.' -ForegroundColor DarkGray
    }
}
Write-Host $LineBreak

# The copied wim files inherit the read-only attribute from the optical media; clear it so DISM can mount
# and commit changes.
Get-ChildItem -Path (Join-Path $ExtractDir 'sources') -Filter '*.wim' -File -ErrorAction SilentlyContinue |
    ForEach-Object { try { Set-ItemProperty -LiteralPath $_.FullName -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue } catch { } }

$InstallWimExtracted = Join-Path $ExtractDir 'sources\install.wim'
$InstallEsdExtracted = Join-Path $ExtractDir 'sources\install.esd'
$BootWim = Join-Path $ExtractDir 'sources\boot.wim'

# If the media ships install.esd (compressed), convert it to an editable install.wim so DISM can service
# it. Servicing is done against a WIM; the ESD is a delivery-only format.
if (-not (Test-Path -LiteralPath $InstallWimExtracted) -and (Test-Path -LiteralPath $InstallEsdExtracted)) {
    Invoke-Task -Description 'The media uses install.esd - converting it to an editable install.wim...' -ScriptBlock {
        $Images = Get-WindowsImage -ImagePath $InstallEsdExtracted -ErrorAction Stop
        foreach ($Img in $Images) {
            Write-HostTimestamp "  Exporting index $($Img.ImageIndex): $($Img.ImageName) ..."
            Export-WindowsImage -SourceImagePath $InstallEsdExtracted -SourceIndex $Img.ImageIndex -DestinationImagePath $InstallWimExtracted -CompressionType Max -ErrorAction Stop | Out-Null
        }
        Remove-Item -LiteralPath $InstallEsdExtracted -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp '  Conversion complete.' -ForegroundColor Green
    }
    Write-Host $LineBreak
}

if (-not (Test-Path -LiteralPath $InstallWimExtracted)) {
    Write-HostTimestamp 'No editable install.wim is present after extraction. Cannot continue.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# --- Determine the feature update / architecture from the image (for catalog searches) ---
$ImageInfo = $null
try { $ImageInfo = Get-WindowsImage -ImagePath $InstallWimExtracted -Index 1 -ErrorAction Stop } catch { }
$ImageBuild = 0
if ($ImageInfo -and $ImageInfo.Version -match '^\d+\.\d+\.(\d+)') { $ImageBuild = [int]$Matches[1] }
$FeatureName = if ($ImageBuild) { Get-FeatureUpdateName -Build $ImageBuild } else { $null }
$ImageArch = switch ($ImageInfo.Architecture) { 0 { 'x86' } 9 { 'x64' } 12 { 'arm64' } default { $WinInfo.Architecture } }
$CatalogArch = switch ($ImageArch) { 'x64' { 'x64' } 'arm64' { 'ARM64' } 'x86' { 'x86' } default { 'x64' } }

Write-HostTimestamp "Image build    : $($ImageInfo.Version)$(if ($FeatureName) { " ($FeatureName)" })"
Write-HostTimestamp "Image arch     : $ImageArch"
Write-Host $LineBreak

# --- Gather the update packages to integrate ---
# Each entry in $UpdateGroups is an ordered array of related packages with the TARGET last (e.g. the LCU
# group is [checkpoint..., LCU]). Groups are applied independently with the documented sole-target method.
$UpdateGroups = New-Object System.Collections.Generic.List[object]
$SafeOsGroup = $null
$script:SetupDu = $null

if ($SkipUpdates) {
    Write-HostTimestamp 'Skipping update integration (-SkipUpdates was specified).' -ForegroundColor Yellow
    Write-Host $LineBreak
}
elseif ($UpdatePath) {
    $script:UpdateFiles = @()
    Invoke-Task -Description "Collecting update packages from $UpdatePath ..." -ScriptBlock {
        if (-not (Test-Path -LiteralPath $UpdatePath)) { throw "The update folder '$UpdatePath' does not exist." }
        $Found = Get-ChildItem -Path $UpdatePath -Include '*.msu', '*.cab' -File -Recurse -ErrorAction SilentlyContinue
        $script:UpdateFiles = @($Found | ForEach-Object { $_.FullName })
        if (-not $script:UpdateFiles -or $script:UpdateFiles.Count -eq 0) {
            throw "No .msu or .cab packages were found in '$UpdatePath'."
        }
        Write-HostTimestamp "  Found $($script:UpdateFiles.Count) package(s)." -ForegroundColor Green
    }
    # Treat the supplied files as one group ordered by KB ascending, so the latest (target) is applied last
    # and any prior checkpoints are staged alongside it.
    $OrderedUserFiles = @($script:UpdateFiles | Sort-Object { if ((Split-Path -Leaf $_) -match '(?i)kb(\d{6,})') { [int]$Matches[1] } else { 0 } })
    $UpdateGroups.Add($OrderedUserFiles)
    Write-Host $LineBreak
}
else {
    if (-not $FeatureName) {
        Write-HostTimestamp 'Could not determine the feature-update name from the image, so the catalog search may be less precise.' -ForegroundColor Yellow
    }

    Invoke-Task -Description 'Downloading the latest cumulative update from the Microsoft Update Catalog...' -ScriptBlock {
        $VerPart = if ($FeatureName) { "Version $FeatureName " } else { '' }
        # The monthly LCU is titled e.g. "2026-07 Cumulative Update for Windows 11 Version 24H2 for
        # x64-based Systems (KB...)" and classified as a Security Update. Restrict the match to real
        # cumulative updates and exclude the .NET / Dynamic Update entries the same query returns.
        $Query = "Cumulative Update for Windows $WindowsVersion ${VerPart}for $CatalogArch-based Systems"
        $Include = '(?i)cumulative update for windows'
        $Exclude = '(?i)\.net|dynamic update'
        $script:Lcu = Get-LatestCatalogPackage -Query $Query -DownloadDir $DlDir -TitleInclude $Include -TitleExclude $Exclude
        if (-not $script:Lcu) {
            # Retry with a looser query (some releases omit the "Version xxHx" token in the title).
            $Query2 = "Cumulative Update for Windows $WindowsVersion for $CatalogArch-based Systems"
            Write-HostTimestamp "  Retrying with a broader query: $Query2" -ForegroundColor Yellow
            $script:Lcu = Get-LatestCatalogPackage -Query $Query2 -DownloadDir $DlDir -TitleInclude $Include -TitleExclude $Exclude
        }
    }
    if ($script:Lcu) { $UpdateGroups.Add(@($script:Lcu)) }
    else {
        Write-HostTimestamp 'Could not obtain a cumulative update from the catalog. You can supply one with -UpdatePath, or use -SkipUpdates to just recompile the ISO.' -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    Write-Host $LineBreak

    if (-not $SkipDotNet) {
        Invoke-Task -Description 'Downloading the latest .NET cumulative update from the Microsoft Update Catalog...' -ScriptBlock {
            $VerPart = if ($FeatureName) { "Windows $WindowsVersion Version $FeatureName" } else { "Windows $WindowsVersion" }
            $Query = "Cumulative Update for .NET Framework $VerPart for $CatalogArch"
            $script:DotNet = Get-LatestCatalogPackage -Query $Query -DownloadDir $DlDir -TitleInclude '(?i)\.net framework' -TitleExclude '(?i)dynamic update'
        }
        if ($script:DotNet) { $UpdateGroups.Add(@($script:DotNet)) }
        else { Write-HostTimestamp '  No .NET cumulative update was integrated (none found).' -ForegroundColor Yellow }
        Write-Host $LineBreak
    }

    # The Setup Dynamic Update is NOT applied to an image - it is expanded over the media's sources
    # folder, which is what keeps the loose Setup binaries, compatibility database and component
    # manifests in step with the serviced boot.wim. It is therefore kept out of $UpdateGroups.
    if (-not $SkipSetupDU) {
        Invoke-Task -Description 'Downloading the latest Setup Dynamic Update from the Microsoft Update Catalog...' -ScriptBlock {
            $VerPart = if ($FeatureName) { "Version $FeatureName " } else { '' }
            $script:SetupDu = Get-LatestCatalogPackage -Query "Setup Dynamic Update Windows $WindowsVersion $VerPart$CatalogArch" -DownloadDir $DlDir -TitleInclude '(?i)setup dynamic update'
        }
        if (-not $script:SetupDu) {
            Write-HostTimestamp '  No Setup Dynamic Update was found. The media Setup files will only be refreshed from boot.wim, which can make Windows Setup fail on the finished ISO.' -ForegroundColor Yellow
        }
        Write-Host $LineBreak
    }

    if ($ServiceWinRE) {
        Invoke-Task -Description 'Looking for a Safe OS Dynamic Update for the recovery image (WinRE)...' -ScriptBlock {
            $VerPart = if ($FeatureName) { "Version $FeatureName " } else { '' }
            $script:SafeOs = Get-LatestCatalogPackage -Query "Safe OS Dynamic Update Windows $WindowsVersion $VerPart$CatalogArch" -DownloadDir $DlDir -TitleInclude '(?i)safe os dynamic update'
        }
        if ($script:SafeOs) { $SafeOsGroup = @($script:SafeOs) }
        else { Write-HostTimestamp '  No Safe OS Dynamic Update was found; WinRE update integration will be skipped (per Microsoft, the LCU does not apply to WinRE).' -ForegroundColor Yellow }
        Write-Host $LineBreak
    }
}

# --- Resolve which editions to keep and which to service ---
$InstallImages = @(Get-WindowsImage -ImagePath $InstallWimExtracted -ErrorAction Stop)

# Which editions to KEEP in the final ISO.
#   * -KeepEditions <list>  : keep exactly what the user named (highest precedence).
#   * -KeepAllEditions      : keep every edition in the media.
#   * default               : keep only the single highest edition (e.g. Pro over Home) to speed up
#                             servicing and shrink the ISO.
$KeepIndexes = @($InstallImages.ImageIndex)
if ($KeepEditions -and $KeepEditions.Count -gt 0) {
    $KeepUnmatched = $null
    $KeepIndexes = @(Resolve-EditionIndexes -Images $InstallImages -Tokens $KeepEditions -Unmatched ([ref]$KeepUnmatched))
    if ($KeepUnmatched -and $KeepUnmatched.Count -gt 0) {
        Write-HostTimestamp "These -KeepEditions values did not match any edition: $($KeepUnmatched -join ', ')" -ForegroundColor Red
        Write-HostTimestamp 'Available editions:' -ForegroundColor Yellow
        $InstallImages | ForEach-Object { Write-Host "    [$($_.ImageIndex)] $($_.ImageName)" }
        Stop-Transcript | Out-Null
        exit 1
    }
    if ($KeepIndexes.Count -eq 0) {
        Write-HostTimestamp '-KeepEditions matched no editions. Cannot continue.' -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $KeptNames = $InstallImages | Where-Object { $KeepIndexes -contains $_.ImageIndex } | ForEach-Object { $_.ImageName }
    $DroppedNames = $InstallImages | Where-Object { $KeepIndexes -notcontains $_.ImageIndex } | ForEach-Object { $_.ImageName }
    Write-HostTimestamp "Keeping $($KeepIndexes.Count) of $($InstallImages.Count) editions: $($KeptNames -join ', ')" -ForegroundColor Cyan
    if ($DroppedNames) { Write-HostTimestamp "Removing from the ISO: $($DroppedNames -join ', ')" -ForegroundColor Yellow }
    Write-Host $LineBreak
}
elseif ($KeepAllEditions) {
    Write-HostTimestamp "Keeping all $($InstallImages.Count) editions (-KeepAllEditions)." -ForegroundColor Cyan
    Write-Host $LineBreak
}
elseif ($InstallImages.Count -gt 1) {
    # Default: keep only the single highest-ranked edition. Sort by rank (desc), then prefer the shorter
    # (base) name, then the lowest index, and take the top one.
    $Top = $InstallImages |
        Sort-Object @{ Expression = { Get-EditionRank $_.ImageName }; Descending = $true },
        @{ Expression = { "$($_.ImageName)".Length } },
        @{ Expression = { [int]$_.ImageIndex } } |
        Select-Object -First 1
    $KeepIndexes = @([int]$Top.ImageIndex)
    $DroppedNames = $InstallImages | Where-Object { $_.ImageIndex -ne $Top.ImageIndex } | ForEach-Object { $_.ImageName }
    Write-HostTimestamp "Keeping only the highest edition to speed up the build: $($Top.ImageName). Use -KeepAllEditions to keep them all, or -KeepEditions to choose." -ForegroundColor Cyan
    if ($DroppedNames) { Write-HostTimestamp "Removing from the ISO: $($DroppedNames -join ', ')" -ForegroundColor Yellow }
    Write-Host $LineBreak
}
$TrimNeeded = ($KeepIndexes.Count -lt $InstallImages.Count)

# Which of the kept editions to actually service (apply updates to). -Edition narrows this further.
if ($Edition -eq 'All') {
    $ServiceIndexes = $KeepIndexes
}
else {
    $EdUnmatched = $null
    $EdIndexes = @(Resolve-EditionIndexes -Images $InstallImages -Tokens @($Edition) -Unmatched ([ref]$EdUnmatched))
    if ($EdIndexes.Count -eq 0) {
        Write-HostTimestamp "Edition '$Edition' was not found in the image. Available editions:" -ForegroundColor Red
        $InstallImages | ForEach-Object { Write-Host "    [$($_.ImageIndex)] $($_.ImageName)" }
        Stop-Transcript | Out-Null
        exit 1
    }
    # Only service editions we are keeping in the final ISO.
    $ServiceIndexes = @($EdIndexes | Where-Object { $KeepIndexes -contains $_ })
}

# Any edition that ships in the ISO but is not serviced installs at the ORIGINAL patch level, so warn.
$UnservicedKept = @($KeepIndexes | Where-Object { $ServiceIndexes -notcontains $_ })
if ($UnservicedKept.Count -gt 0 -and -not $SkipUpdates) {
    $UnservicedNames = $InstallImages | Where-Object { $UnservicedKept -contains [int]$_.ImageIndex } | ForEach-Object { $_.ImageName }
    Write-HostTimestamp "Warning: these editions stay in the ISO but will NOT be updated, so installing them gives an unpatched Windows: $($UnservicedNames -join ', ')" -ForegroundColor Yellow
    Write-HostTimestamp '  Drop -Edition (or add them to -KeepEditions) so every edition left in the ISO is serviced.' -ForegroundColor Yellow
    Write-Host $LineBreak
}

# --- Service the images ---
if ($UpdateGroups.Count -gt 0) {
    # Tracks editions whose update set failed to apply, so we can warn loudly at the end.
    $script:ServicingFailures = 0
    # Start from a clean mount directory, discarding any stale mount a previous crashed run left behind.
    Reset-MountDirectory -Path $MountDir -ImagePath $InstallWimExtracted

    # 1) Service install.wim (each targeted edition).
    foreach ($Index in $ServiceIndexes) {
        $EditionName = ($InstallImages | Where-Object { $_.ImageIndex -eq $Index }).ImageName
        Invoke-Task -Description "Servicing install.wim index $Index ($EditionName)..." -ScriptBlock {
            try {
                Reset-MountDirectory -Path $MountDir -ImagePath $InstallWimExtracted
                Write-HostTimestamp '    Mounting the image...'
                Mount-WindowsImage -ImagePath $InstallWimExtracted -Index $Index -Path $MountDir -ErrorAction Stop | Out-Null

                # Optionally service the recovery image (winre.wim) that lives inside this edition.
                if ($ServiceWinRE) {
                    $WinReWim = Join-Path $MountDir 'Windows\System32\Recovery\winre.wim'
                    if (Test-Path -LiteralPath $WinReWim) {
                        $WinReMount = Join-Path $WorkRoot 'WinREMount'
                        Reset-MountDirectory -Path $WinReMount -ImagePath $WinReWim
                        try {
                            Set-ItemProperty -LiteralPath $WinReWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                            Write-HostTimestamp '    Servicing the recovery image (winre.wim)...'
                            Mount-WindowsImage -ImagePath $WinReWim -Index 1 -Path $WinReMount -ErrorAction Stop | Out-Null
                            # Per Microsoft, WinRE is serviced with the Safe OS Dynamic Update - NOT the LCU.
                            if ($SafeOsGroup) {
                                Add-UpdateGroup -MountDir $WinReMount -Group $SafeOsGroup -Label 'Safe OS Dynamic Update' | Out-Null
                            }
                            else {
                                Write-HostTimestamp '      No Safe OS Dynamic Update available; skipping WinRE update integration.' -ForegroundColor DarkGray
                            }
                            Dismount-WindowsImage -Path $WinReMount -Save -ErrorAction Stop | Out-Null
                        }
                        catch {
                            Write-HostTimestamp "      WinRE servicing failed: $($_.Exception.Message)" -ForegroundColor Yellow
                            Dismount-WindowsImage -Path $WinReMount -Discard -ErrorAction SilentlyContinue | Out-Null
                        }
                    }
                }

                Write-HostTimestamp '    Applying updates to install.wim...'
                $script:InstallApplyOk = $true
                foreach ($Group in $UpdateGroups) {
                    if (-not (Add-UpdateGroup -MountDir $MountDir -Group $Group)) { $script:InstallApplyOk = $false }
                }
                if (-not $script:InstallApplyOk) {
                    $script:ServicingFailures++
                    Write-HostTimestamp "    Note: the cumulative update didn't apply to index $Index ($EditionName), so this edition kept its original patch level. The ISO will still build." -ForegroundColor DarkYellow
                }

                Write-HostTimestamp '    Cleaning up the component store (/StartComponentCleanup /ResetBase)...'
                # ResetBase permanently removes superseded components, shrinking the image. This is slow.
                & dism.exe /Image:"$MountDir" /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null

                # Grabbed here because the image is already mounted; mounting the finished image later just to
                # read this one value costs several minutes.
                if (-not $script:FinalBuildString) { $script:FinalBuildString = Get-MountedImageBuild -MountPath $MountDir }

                Write-HostTimestamp '    Committing and unmounting...'
                Dismount-WindowsImage -Path $MountDir -Save -ErrorAction Stop | Out-Null
                Write-HostTimestamp "    Index $Index done." -ForegroundColor Green
            }
            catch {
                Write-HostTimestamp "    Servicing index $Index failed: $($_.Exception.Message)" -ForegroundColor Red
                Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    # 2) Apply the Setup Dynamic Update to the media's sources folder. This refreshes the loose Windows
    # Setup binaries, the compatibility database and replacement component manifests. Step 3 then
    # overwrites setup.exe/setuphost.exe from the serviced boot.wim, matching Microsoft's documented order.
    if ($script:SetupDu) {
        Invoke-Task -Description 'Applying the Setup Dynamic Update to the media sources folder...' -ScriptBlock {
            $MediaSources = Join-Path $ExtractDir 'sources'
            Get-ChildItem -LiteralPath $MediaSources -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.IsReadOnly } |
                ForEach-Object { $_.IsReadOnly = $false }
            foreach ($Cab in $script:SetupDu) {
                & "$env:SystemRoot\System32\expand.exe" $Cab '-F:*' $MediaSources | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-HostTimestamp "  expand.exe returned $LASTEXITCODE for $(Split-Path -Leaf $Cab); the media Setup files were not fully refreshed." -ForegroundColor Yellow
                }
                else {
                    Write-HostTimestamp "  Applied $(Split-Path -Leaf $Cab) to sources\." -ForegroundColor Green
                }
            }
        }
    }

    # 3) Service boot.wim (Windows Setup / WinPE). Index 2 is the Setup environment; index 1 is WinPE.
    if (Test-Path -LiteralPath $BootWim) {
        Set-ItemProperty -LiteralPath $BootWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        # Staging folder for the serviced Setup/boot-manager binaries pulled out of boot.wim index 2.
        $SetupStage = Join-Path -Path $WorkRoot -ChildPath 'SetupFiles'
        if (Test-Path -LiteralPath $SetupStage) { Remove-Item -LiteralPath $SetupStage -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $SetupStage -Force -ErrorAction SilentlyContinue | Out-Null
        $BootImages = Get-WindowsImage -ImagePath $BootWim -ErrorAction SilentlyContinue
        foreach ($BootImg in $BootImages) {
            Invoke-Task -Description "Servicing boot.wim index $($BootImg.ImageIndex) ($($BootImg.ImageName))..." -ScriptBlock {
                try {
                    Reset-MountDirectory -Path $MountDir -ImagePath $BootWim
                    Mount-WindowsImage -ImagePath $BootWim -Index $BootImg.ImageIndex -Path $MountDir -ErrorAction Stop | Out-Null
                    foreach ($Group in $UpdateGroups) { Add-UpdateGroup -MountDir $MountDir -Group $Group | Out-Null }
                    & dism.exe /Image:"$MountDir" /Cleanup-Image /StartComponentCleanup | Out-Null

                    # Index 2 is the Windows Setup image. The cumulative update raises the version of the
                    # Setup and boot-manager binaries INSIDE this image, so the copies sitting loose on the
                    # media must be replaced with them. If they don't match, Windows Setup fails when it is
                    # launched from the media (e.g. "A media driver your computer needs is missing").
                    if ([int]$BootImg.ImageIndex -eq 2) {
                        Write-HostTimestamp '    Saving the serviced Setup and boot manager files for the media...'
                        $Grab = @(
                            @{ From = 'sources\setup.exe';                To = 'setup.exe';     Required = $true }
                            @{ From = 'sources\setuphost.exe';            To = 'setuphost.exe'; Required = $false } # Windows 11 24H2+
                            @{ From = 'Windows\boot\efi\bootmgfw.efi';    To = 'bootmgfw.efi';  Required = $false }
                            @{ From = 'Windows\boot\efi\bootmgr.efi';     To = 'bootmgr.efi';   Required = $false }
                            @{ From = 'Windows\boot\efi\boot.stl';        To = 'boot.stl';      Required = $false }
                        )
                        foreach ($Item in $Grab) {
                            $Src = Join-Path $MountDir $Item.From
                            if (Test-Path -LiteralPath $Src) {
                                Copy-Item -LiteralPath $Src -Destination (Join-Path $SetupStage $Item.To) -Force -ErrorAction SilentlyContinue
                            }
                            elseif ($Item.Required) {
                                Write-HostTimestamp "      $($Item.From) was not found in boot.wim index 2." -ForegroundColor Yellow
                            }
                        }
                    }

                    Dismount-WindowsImage -Path $MountDir -Save -ErrorAction Stop | Out-Null
                    Write-HostTimestamp "    boot.wim index $($BootImg.ImageIndex) done." -ForegroundColor Green
                }
                catch {
                    Write-HostTimestamp "    Servicing boot.wim index $($BootImg.ImageIndex) failed: $($_.Exception.Message)" -ForegroundColor Yellow
                    Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue | Out-Null
                }
            }
        }

        # Servicing inflates boot.wim and nothing else reclaims that space, so re-export it.
        if ($BootImages) {
            Invoke-Task -Description 'Re-exporting boot.wim to shrink it...' -ScriptBlock {
                if (-not (Test-RoomForExport -SourceImage $BootWim -Label 'boot.wim')) { return }
                # Staged outside the media folder so a failed export can never be baked into the ISO.
                $TempBoot = Join-Path -Path $WorkRoot -ChildPath 'boot_new.wim'
                try {
                    if (Test-Path -LiteralPath $TempBoot) { Remove-Item -LiteralPath $TempBoot -Force -ErrorAction SilentlyContinue }
                    $BeforeMB = (Get-Item -LiteralPath $BootWim).Length / 1MB
                    foreach ($Img in ($BootImages | Sort-Object ImageIndex)) {
                        # Index 2 (Windows Setup) carries the WIM's bootable flag; without -Setbootable the ISO will not boot.
                        $Boot = ([int]$Img.ImageIndex -eq 2)
                        Write-HostTimestamp "  Exporting index $($Img.ImageIndex) ($($Img.ImageName))$(if ($Boot) { ' [bootable]' }) ..."
                        Export-WindowsImage -SourceImagePath $BootWim -SourceIndex $Img.ImageIndex -DestinationImagePath $TempBoot -CompressionType Max -Setbootable:$Boot -ErrorAction Stop | Out-Null
                    }
                    Set-ItemProperty -LiteralPath $BootWim -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $BootWim -Force -ErrorAction Stop
                    Move-Item -LiteralPath $TempBoot -Destination $BootWim -Force -ErrorAction Stop
                    $AfterMB = (Get-Item -LiteralPath $BootWim).Length / 1MB
                    Write-HostTimestamp ('  boot.wim: {0:N0} MB -> {1:N0} MB (saved {2:N0} MB).' -f $BeforeMB, $AfterMB, ($BeforeMB - $AfterMB)) -ForegroundColor Green
                }
                catch {
                    Write-HostTimestamp "  Re-export failed: $($_.Exception.Message). The serviced boot.wim is used as-is." -ForegroundColor Yellow
                    Remove-Item -LiteralPath $TempBoot -Force -ErrorAction SilentlyContinue
                }
            }
        }

        # Push the serviced binaries onto the media so their versions match the serviced boot.wim.
        Invoke-Task -Description 'Updating the media Setup and boot manager files to match the serviced boot.wim...' -ScriptBlock {
            $StagedSetup = Join-Path $SetupStage 'setup.exe'
            if (-not (Test-Path -LiteralPath $StagedSetup)) {
                Write-HostTimestamp '  No serviced Setup files were captured; the media files are left as they are.' -ForegroundColor Yellow
                return
            }
            $MediaSources = Join-Path $ExtractDir 'sources'
            foreach ($Name in @('setup.exe', 'setuphost.exe')) {
                $Staged = Join-Path $SetupStage $Name
                if (Test-Path -LiteralPath $Staged) {
                    $Dest = Join-Path $MediaSources $Name
                    if (Test-Path -LiteralPath $Dest) { Set-ItemProperty -LiteralPath $Dest -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
                    Copy-Item -LiteralPath $Staged -Destination $Dest -Force -ErrorAction SilentlyContinue
                    Write-HostTimestamp "  Replaced sources\$Name." -ForegroundColor Green
                }
            }

            # The media's boot managers live under several names (bootmgfw.efi, bootx64.efi, ...); each is
            # the same binary, so every copy is refreshed from the serviced one.
            $StagedMgfw = Join-Path $SetupStage 'bootmgfw.efi'
            $StagedMgr  = Join-Path $SetupStage 'bootmgr.efi'
            foreach ($File in (Get-ChildItem -LiteralPath $ExtractDir -Force -Recurse -Filter 'b*.efi' -ErrorAction SilentlyContinue)) {
                $Source = switch -Regex ($File.Name) {
                    '^(bootmgfw|bootx64|bootia32|bootaa64)\.efi$' { $StagedMgfw }
                    '^bootmgr\.efi$' { $StagedMgr }
                    default { $null }
                }
                if ($Source -and (Test-Path -LiteralPath $Source)) {
                    Set-ItemProperty -LiteralPath $File.FullName -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                    Copy-Item -LiteralPath $Source -Destination $File.FullName -Force -ErrorAction SilentlyContinue
                    Write-HostTimestamp "  Replaced $($File.FullName.Substring($ExtractDir.Length).TrimStart('\'))." -ForegroundColor Green
                }
            }

            $StagedStl = Join-Path $SetupStage 'boot.stl'
            if (Test-Path -LiteralPath $StagedStl) {
                $StlDest = Join-Path $ExtractDir 'efi\microsoft\boot\boot.stl'
                if (Test-Path -LiteralPath $StlDest) { Set-ItemProperty -LiteralPath $StlDest -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
                Copy-Item -LiteralPath $StagedStl -Destination $StlDest -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $SetupStage -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 4) Re-export install.wim below (outside this block) to reclaim the space freed by the cleanup.
    Remove-Item -LiteralPath $MountDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Re-export install.wim (shrink after servicing and/or drop editions with -KeepEditions) ---
# Exporting only the kept indexes both reclaims the space freed by the component cleanup AND physically
# removes any editions the user chose not to keep. Runs when updates were applied or when trimming.
# Tracks what Setup will actually read, since -CompressEsd replaces install.wim with install.esd.
$FinalInstallImage = $InstallWimExtracted
if (($UpdateGroups.Count -gt 0) -or $TrimNeeded -or $CompressEsd) {
    $ExportDesc = if ($CompressEsd) { 'Exporting the image as install.esd (recovery compression - this is slow)...' }
                  elseif ($TrimNeeded) { 'Rebuilding install.wim with only the kept edition(s) and shrinking it...' }
                  else { 'Re-exporting install.wim to shrink it...' }
    Invoke-Task -Description $ExportDesc -ScriptBlock {
        if (-not (Test-RoomForExport -SourceImage $InstallWimExtracted -Label 'install image')) { return }
        $TempName    = if ($CompressEsd) { 'install_new.esd' } else { 'install_new.wim' }
        $FinalName   = if ($CompressEsd) { 'install.esd' } else { 'install.wim' }
        $Compression = if ($CompressEsd) { 'Recovery' } else { 'Max' }
        $Temp = Join-Path $ExtractDir "sources\$TempName"
        $Dest = Join-Path $ExtractDir "sources\$FinalName"
        try {
            if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
            $BeforeMB = (Get-Item -LiteralPath $InstallWimExtracted).Length / 1MB
            # Export the kept indexes in their original order into a fresh image (re-indexed 1..N).
            foreach ($Index in ($KeepIndexes | Sort-Object)) {
                $Name = ($InstallImages | Where-Object { $_.ImageIndex -eq $Index }).ImageName
                Write-HostTimestamp "  Exporting [$Index] $Name ..."
                Export-WindowsImage -SourceImagePath $InstallWimExtracted -DestinationImagePath $Temp -CompressionType $Compression -SourceIndex $Index -ErrorAction Stop | Out-Null
            }
            Remove-Item -LiteralPath $InstallWimExtracted -Force -ErrorAction Stop
            Move-Item -LiteralPath $Temp -Destination $Dest -Force -ErrorAction Stop
            $script:FinalInstallImage = $Dest
            $AfterMB = (Get-Item -LiteralPath $Dest).Length / 1MB
            Write-HostTimestamp ('  {0}: {1:N0} MB -> {2:N0} MB (saved {3:N0} MB).' -f $FinalName, $BeforeMB, $AfterMB, ($BeforeMB - $AfterMB)) -ForegroundColor Green
            if ($CompressEsd -and $AfterMB -ge 4096) {
                Write-HostTimestamp '  Still over 4 GB, so a FAT32 USB stick will need the image split. Consider -KeepEditions to drop more editions.' -ForegroundColor DarkYellow
            }
        }
        catch {
            Write-HostTimestamp "  Export failed: $($_.Exception.Message). The original serviced install.wim will be used as-is." -ForegroundColor Yellow
            Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host $LineBreak
}

# --- Add the unattended answer file to the media ---
# Windows Setup implicitly reads \autounattend.xml from the root of read-only boot media during the
# windowsPE pass, so no Setup switches are needed when the ISO is booted.
if ($ResolvedUnattend) {
    Invoke-Task -Description 'Adding the unattended answer file to the media...' -ScriptBlock {
        $UnattendDest = Join-Path $ExtractDir 'autounattend.xml'
        if (Test-Path -LiteralPath $UnattendDest) { Set-ItemProperty -LiteralPath $UnattendDest -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
        Copy-Item -LiteralPath $ResolvedUnattend -Destination $UnattendDest -Force -ErrorAction Stop
        Write-HostTimestamp '  Added autounattend.xml to the root of the media.' -ForegroundColor Green
        if ($TrimNeeded -and $UnattendText -match '(?i)/IMAGE/INDEX') {
            Write-HostTimestamp '  Warning: the answer file selects the edition by /IMAGE/INDEX, but install.wim was renumbered when the other editions were removed. Switch it to /IMAGE/NAME, or use -KeepAllEditions, if Setup cannot find the edition.' -ForegroundColor Yellow
        }
    }
    Write-Host $LineBreak
}

# --- Recompile the ISO with oscdimg ---
# Default the output path to the download folder, named after what the ISO actually contains:
# Win11_Pro_x64_26100.4061_20260815-1332.iso.
if (-not $OutputIsoPath) {
    $OutputIsoPath = Join-Path -Path $DlDir -ChildPath (Get-DefaultIsoName -Images $InstallImages -Indexes $KeepIndexes -BuildString $script:FinalBuildString -FallbackVersion $ImageInfo.Version -Architecture $ImageArch)
}
# Make sure the destination folder exists before oscdimg writes the ISO into it.
try {
    $OutDir = Split-Path -Path $OutputIsoPath -Parent
    if ($OutDir -and -not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction Stop | Out-Null }
}
catch { }

# The two boot sectors extracted from the source media: etfsboot.com boots the ISO on legacy BIOS PCs,
# efisys.bin boots it on modern UEFI PCs. Both are fed to oscdimg so the new ISO boots on either.
$EtfsBoot = Join-Path $ExtractDir 'boot\etfsboot.com'
$EfiSys   = Join-Path $ExtractDir 'efi\microsoft\boot\efisys.bin'

Invoke-Task -Description "Recompiling the bootable ISO to $OutputIsoPath ..." -ScriptBlock {
    # Remove any leftover ISO at the target path from a previous run so oscdimg starts clean.
    if (Test-Path -LiteralPath $OutputIsoPath) { Remove-Item -LiteralPath $OutputIsoPath -Force -ErrorAction SilentlyContinue }

    # Build the dual (BIOS + UEFI) boot data. Use 8.3 short paths for the boot files so any spaces in the
    # working path do not break oscdimg's -bootdata argument.
    $BootArg = $null
    if ((Test-Path -LiteralPath $EtfsBoot) -and (Test-Path -LiteralPath $EfiSys)) {
        # Both boot sectors present -> build dual-boot data: "2" entries, one for BIOS (p0) and one for
        # UEFI (pEF), each pointing at its (short-path) boot file.
        $EtfsShort = Get-ShortPath -Path $EtfsBoot
        $EfiShort  = Get-ShortPath -Path $EfiSys
        $BootArg = "2#p0,e,b$EtfsShort#pEF,e,b$EfiShort"
    }
    elseif (Test-Path -LiteralPath $EfiSys) {
        # UEFI-only media (no BIOS boot sector present): a single UEFI (pEF) boot entry.
        $BootArg = "1#pEF,e,b$(Get-ShortPath -Path $EfiSys)"
    }
    else {
        # Neither boot sector was found; oscdimg will still build the ISO, but it may not be bootable.
        Write-HostTimestamp '  No boot sectors were found in the extracted media; the resulting ISO may not be bootable.' -ForegroundColor Yellow
    }

    # oscdimg switches: -m (ignore the 4 GB image size limit), -o (de-duplicate identical files to save
    # space), -u2 (write a pure UDF file system, required for the large install.wim), -udfver102 (UDF
    # revision 1.02 for broad compatibility). -bootdata makes the ISO bootable; the last two arguments are
    # the source folder to package and the output ISO path.
    $OscdimgArgs = @('-m', '-o', '-u2', '-udfver102')
    if ($BootArg) { $OscdimgArgs += "-bootdata:$BootArg" }
    $OscdimgArgs += @($ExtractDir, $OutputIsoPath)

    # Run oscdimg and wait for it to finish, then verify it actually produced the ISO.
    Write-HostTimestamp "  Running: `"$Oscdimg`" $($OscdimgArgs -join ' ')"
    $Proc = Start-Process -FilePath $Oscdimg -ArgumentList $OscdimgArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
    if ($Proc.ExitCode -ne 0) {
        # A non-zero exit code means oscdimg failed to build the image.
        throw "oscdimg returned exit code $($Proc.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $OutputIsoPath)) {
        # Guard against the rare case where oscdimg exits 0 but no file was written.
        throw 'oscdimg reported success but the output ISO was not created.'
    }
    $SizeGB = [math]::Round((Get-Item -LiteralPath $OutputIsoPath).Length / 1GB, 2)
    Write-HostTimestamp "  New ISO created ($SizeGB GB)." -ForegroundColor Green
}
Write-Host $LineBreak

# --- Report the final image contents (editions + build) before the working files are removed ---
Invoke-Task -Description 'Reading the final image details...' -ScriptBlock {
    Show-FinalImageInfo -WimPath $FinalInstallImage
}

# --- Cleanup the working extraction folder ---
Invoke-Task -Description 'Cleaning up the working extraction folder...' -ScriptBlock {
    try {
        Remove-Item -LiteralPath $ExtractDir -Recurse -Force -ErrorAction Stop
        Write-HostTimestamp '  Removed the extracted media.' -ForegroundColor Green
    }
    catch {
        Write-HostTimestamp "  Could not fully remove $ExtractDir : $($_.Exception.Message). You can delete it manually." -ForegroundColor Yellow
    }
}
Write-Host $LineBreak

# --- Timing summary ---
$TotalElapsed = (Get-Date) - $script:ScriptStartTime
if ($script:StepTimings.Count -gt 0) {
    Write-HostTimestamp 'Time spent on each step:' -ForegroundColor Cyan
    $NameWidth = ($script:StepTimings | ForEach-Object { $_.Description.Length } | Measure-Object -Maximum).Maximum
    if ($NameWidth -gt 70) { $NameWidth = 70 }
    foreach ($Step in $script:StepTimings) {
        $Label = if ($Step.Description.Length -gt $NameWidth) { $Step.Description.Substring(0, $NameWidth - 3) + '...' } else { $Step.Description }
        Write-Host ("  {0,-$NameWidth}  {1,10}" -f $Label, (Format-Duration $Step.Duration))
    }
    $Slowest = $script:StepTimings | Sort-Object -Property Duration -Descending | Select-Object -First 1
    Write-Host ''
    Write-HostTimestamp "Longest step: $($Slowest.Description) ($(Format-Duration $Slowest.Duration))" -ForegroundColor DarkGray
}
Write-HostTimestamp "Total run time: $(Format-Duration $TotalElapsed) (started $($script:ScriptStartTime.ToString('HH:mm:ss')), finished $((Get-Date).ToString('HH:mm:ss')))" -ForegroundColor Cyan
Write-Host $LineBreak

Write-HostTimestamp 'Done. Your updated Windows installation ISO is ready:' -ForegroundColor Green
Write-HostTimestamp "  $OutputIsoPath" -ForegroundColor Green
Write-Host ''
if ($script:ServicingFailures -gt 0) {
    Write-HostTimestamp "Note: the cumulative update didn't apply to $($script:ServicingFailures) edition(s), so they kept their original patch level. The ISO is still valid and bootable - see C:\Windows\Logs\DISM\dism.log if you want the details." -ForegroundColor DarkYellow
    Write-Host ''
}
Write-Host 'You can write it to a USB drive (e.g. with Rufus) or use it for a clean install or in-place upgrade.'
Write-Host $LineBreak

Write-HostTimestamp 'Windows ISO Updater script finished.' -ForegroundColor Green
if (-not $Unattended -and -not $SkipInteractive) {
    Read-Host -Prompt 'Press enter to exit'
}

# Stop logging
Stop-Transcript
# --- End Logging ---
