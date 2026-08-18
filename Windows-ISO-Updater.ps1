# Windows ISO Updater
# Version: 2026.08.17.1   (date-based, stamped automatically by tools\Update-Version.ps1 on commit)
#
#region Script overview
# This script builds a fully up-to-date ("slipstreamed") Windows 11 (or Windows 10, or with -Server a
# Windows Server 2016-2025) installation ISO.
# It downloads the latest official Microsoft ISO, downloads the latest cumulative update(s) from the
# Microsoft Update Catalog, integrates those updates directly into the Windows images inside the ISO,
# and then recompiles a brand-new, bootable ISO that already contains this month's patches.
#
# Building patched media means a fresh install (or in-place upgrade) starts already updated, instead of
# spending an hour downloading and installing the same cumulative update after Setup finishes.
#
# It performs the following actions:
#   1. Takes the ISO from you: -IsoPath, or any ISO already sitting in the download folder. Nothing is
#      downloaded automatically unless you ask for it, because Microsoft rate-limits and can temporarily
#      block IPs that make repeated ISO requests, which makes an automatic download the least dependable
#      part of a run. -UseFido opts into fetching the matching official Microsoft ISO with the community
#      "Fido" helper (which queries Microsoft's own software-download servers), retrying blocked link
#      requests with a backoff (-FidoRetryCount). -UseMct instead opens Microsoft's Media Creation Tool,
#      which talks to different servers but has no headless mode, so you click through its last few pages
#      yourself. Either way there is no automatic download for -Server, because neither source serves
#      Windows Server media.
#   2. Extracts the ISO to a writable working folder.
#   3. Detects the Windows feature-update (e.g. 24H2) and architecture from the image, then downloads the
#      latest combined Servicing Stack + Cumulative Update (LCU) - and the .NET cumulative update
#      (on by default, disable with -SkipDotNet) - from the Microsoft Update Catalog. You may
#      instead point at your own .msu/.cab files with -UpdatePath.
#   4. Integrates the update(s) offline with DISM into install.wim (by default the other editions are
#      dropped and only the kept ones are serviced - on client media Enterprise, Pro and Home, whichever
#      of them the media carries, or on Server media the most upgradeable one, Standard over Datacenter -
#      so use -KeepAllEditions or -KeepEditions to change this), boot.wim (Windows Setup / WinPE), and
#      optionally winre.wim (recovery). -DriverPath also injects a folder of .inf driver packages into
#      every serviced edition and into boot.wim index 2, so Setup itself can see the hardware.
#   5. Refreshes the loose Setup files on the media: first applies the Setup Dynamic Update to the
#      sources folder (on by default, disable with -SkipSetupDU), then overwrites sources\setup.exe,
#      sources\setuphost.exe and the boot managers from the serviced boot.wim - Windows Setup fails if
#      those binaries don't match the version inside boot.wim - then cleans up the component store
#      (/StartComponentCleanup /ResetBase) and re-exports install.wim to shrink it.
#   6. Recompiles a new bootable ISO with oscdimg (downloaded from Microsoft if not already installed
#      with the Windows ADK), preserving both the BIOS and
#      UEFI boot sectors so the new ISO boots on legacy and modern PCs alike. An answer file supplied with
#      -UnattendPath is placed at the root of the media as autounattend.xml, which Windows Setup reads
#      automatically when the ISO is booted, and -ExtraFilesPath copies a folder of your own files onto
#      the media, reporting anything it replaces. A \WISO-Build folder is also written onto the media (turn it
#      off with -SkipTattoo) recording what the ISO was made from, which updates applied or failed, what
#      was kept and stripped, who built it and when, plus a copy of the script that built it.
#   7. Records a "stamp" of the finished build (the source ISO's hash, the updates that went in, the
#      parameters used and the ISO that came out) and keeps a history of them. The next run compares
#      itself with that stamp first and exits in a minute or two when nothing has changed, which is what
#      makes it safe to run this from a scheduled task - see -Scheduled and -RegisterScheduledTask.
#      -AutoClean then prunes the update packages and generated ISOs that earlier builds left behind.
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
#endregion

#region Parameters
param(
    [Parameter(HelpMessage = 'Runs the script without any confirmation prompts')]
    [switch]$Unattended,

    [Parameter(HelpMessage = 'Path to an existing Windows ISO to update instead of downloading one from Microsoft. May also be a folder, in which case the largest .iso over 3 GB directly inside it is used (the search is not recursive)')]
    [string]$IsoPath,

    [Parameter(HelpMessage = 'Windows version to download/update: 10 or 11. Defaults to 11')]
    [ValidateSet('10', '11')]
    [string]$WindowsVersion = '11',

    [Parameter(HelpMessage = 'Service Windows Server media (2016 through 2025) instead of a client ISO. Server ISOs cannot be downloaded automatically, so supply one with -IsoPath or drop it into the download folder. -WindowsVersion, -Release and -Language are then ignored')]
    [switch]$Server,

    [Parameter(HelpMessage = 'Fido release to request (e.g. 24H2, 23H2) or "Latest". Defaults to Latest')]
    [string]$Release = 'Latest',

    [Parameter(HelpMessage = 'ISO language as named by Microsoft/Fido (e.g. English, "English International"). Defaults to English')]
    [string]$Language = 'English',

    [Parameter(HelpMessage = 'Which edition inside install.wim to service: "All" (default) or an edition name like "Windows 11 Pro"')]
    [string]$Edition = 'All',

    [Parameter(HelpMessage = 'Editions to KEEP in the final ISO, removing the rest to slim it down. Accepts edition names like "Windows 11 Pro" (partial matches allowed) or index numbers, comma-separated. Overrides the default of keeping Enterprise, Pro and Home')]
    [string[]]$KeepEditions,

    [Parameter(HelpMessage = 'Keep every edition in the final ISO. By default only some are kept to speed up servicing and shrink the ISO: on client media Enterprise, Pro and Home, whichever of them the media carries, or on Server media the most upgradeable one (Standard over Datacenter, since Standard can be upgraded in place but Datacenter cannot be downgraded)')]
    [switch]$KeepAllEditions,

    [Parameter(HelpMessage = 'Only list the editions/indexes inside the ISO''s install.wim and exit (does not download updates or build anything). Useful for choosing -Edition/-KeepEditions values')]
    [switch]$ListEditions,

    [Parameter(HelpMessage = 'Folder containing your own .msu/.cab update packages to integrate instead of fetching from the Microsoft Update Catalog')]
    [string]$UpdatePath,

    [Parameter(HelpMessage = 'Skip downloading and integrating the latest .NET cumulative update. The .NET update is included by default, so use this switch to leave it out')]
    [switch]$SkipDotNet,

    [Parameter(HelpMessage = 'Skip the Setup Dynamic Update that refreshes the loose Windows Setup files on the media. It is included by default, and without it the Windows 11 24H2+ Setup engine can fail with "Windows 11 installation has failed"')]
    [switch]$SkipSetupDU,

    [Parameter(HelpMessage = 'Also service the recovery image (winre.wim). Off by default. The correct component for WinRE is the Safe OS Dynamic Update, which is fetched when available')]
    [switch]$ServiceWinRE,

    [Parameter(HelpMessage = 'Skip integrating updates entirely and simply extract and recompile the ISO (useful for testing the build pipeline)')]
    [switch]$SkipUpdates,

    [Parameter(HelpMessage = 'Export the finished image as install.esd (LZMS "recovery" compression) instead of install.wim. Typically 25-40% smaller, which can bring the image under the 4 GB FAT32 limit for UEFI USB sticks, but the export is slow and the finished media cannot be serviced again without converting it back')]
    [switch]$CompressEsd,

    [Parameter(HelpMessage = 'Path to an unattended answer file to place on the finished ISO as \autounattend.xml, so Windows Setup runs without prompting')]
    [string]$UnattendPath,

    [Parameter(HelpMessage = 'Folder of driver packages (.inf and their .sys/.cat files) to inject into the images. Searched recursively. Every serviced edition of install.wim gets them, and so does boot.wim index 2, so Windows Setup itself can see storage controllers and network adapters the media has no driver for')]
    [string]$DriverPath,

    [Parameter(HelpMessage = 'Inject drivers even when they are unsigned or signed by a certificate the image does not trust. Off by default. 64-bit Windows refuses to load an unsigned driver at boot unless test signing is enabled, so this is only useful for drivers whose certificate is added separately')]
    [switch]$AllowUnsignedDrivers,

    [Parameter(HelpMessage = 'Folder whose contents are copied onto the root of the finished ISO, keeping the folder structure. Files that land on top of something the media already has are reported individually')]
    [string]$ExtraFilesPath,

    [Parameter(HelpMessage = 'Do not tattoo the finished ISO. By default a \WISO-Build folder is added to the media recording what this build was made from, which updates applied or failed, what was kept and stripped, who built it and when, plus a copy of the script that made it')]
    [switch]$SkipTattoo,

    [Parameter(HelpMessage = 'Directory to download the ISO/updates into. Defaults to a Downloads folder inside the working folder. Needs several GB free')]
    [string]$DownloadPath,

    [Parameter(HelpMessage = 'Working folder used to extract and service the media. Must be on a fast drive with lots of free space. Defaults to <SystemDrive>\WISO-Work')]
    [string]$WorkPath,

    [Parameter(HelpMessage = 'Where to write the recompiled ISO. Give it a full file path to name the ISO yourself, or a folder to keep the generated name and only change where it lands. Defaults to the Output folder under the working folder')]
    [string]$OutputIsoPath,

    [Parameter(HelpMessage = 'Volume label written into the finished ISO, which is what File Explorer shows and what Rufus and Ventoy copy onto the USB stick. Defaults to a label describing the contents, such as WIN11_MULTI_X64_26100_4652. Maximum 32 characters, no spaces')]
    [ValidatePattern('^[A-Za-z0-9._-]{1,32}$')]
    [string]$VolumeLabel,

    [Parameter(HelpMessage = 'Full path to oscdimg.exe if the Windows ADK is installed in a non-standard location')]
    [string]$OscdimgPath,

    [Parameter(HelpMessage = 'If oscdimg.exe (Windows ADK Deployment Tools) is not found, download and silently install it from Microsoft')]
    [switch]$InstallAdk,

    [Parameter(HelpMessage = 'Skip the standalone oscdimg.exe download from the Microsoft symbol server and require the Windows ADK instead')]
    [switch]$SkipOscdimgDownload,

    [Parameter(HelpMessage = 'Download the ISO with the Fido helper when you have not supplied one. Off by default, because Microsoft blocks the download-link requests Fido makes often enough that passing your own ISO with -IsoPath is the more reliable way to run this')]
    [switch]$UseFido,

    [Parameter(HelpMessage = 'Override the URL used to fetch the Fido download helper')]
    [string]$FidoUrl = 'https://github.com/pbatard/Fido/raw/master/Fido.ps1',

    [Parameter(HelpMessage = 'Expected SHA-256 of Fido.ps1. Set this to pin one reviewed version. By default the script only verifies its source and contents')]
    [string]$FidoSha256,

    [Parameter(HelpMessage = 'How many extra attempts to make if Fido cannot resolve a download link (Microsoft''s anti-bot check often clears on a later attempt). Defaults to 2')]
    [ValidateRange(0, 10)]
    [int]$FidoRetryCount = 2,

    [Parameter(HelpMessage = 'Get the ISO with Microsoft''s Media Creation Tool instead of supplying one yourself or using -UseFido. MCT cannot run headless, so you click through its wizard and save the ISO into the download folder')]
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

    [Parameter(HelpMessage = 'Directory to keep the build stamps in (the JSON record of what each finished build contained). Defaults to a "Stamps" folder inside the working folder')]
    [string]$StampPath,

    [Parameter(HelpMessage = 'How many past stamps to keep in the stamp history folder. Defaults to 30')]
    [ValidateRange(1, 1000)]
    [int]$StampHistoryCount = 30,

    [Parameter(HelpMessage = 'Run as a scheduled/unattended job: no prompts, no "press enter to exit", and the whole build is skipped when the last stamp shows that nothing has changed')]
    [switch]$Scheduled,

    [Parameter(HelpMessage = 'Rebuild even when the stamp says nothing has changed since the last build')]
    [switch]$Force,

    [Parameter(HelpMessage = 'Only report whether a rebuild is needed and exit without building anything. Exit code 0 = nothing to do, 10 = a rebuild is needed')]
    [switch]$CheckOnly,

    [Parameter(HelpMessage = 'Ignore the stamps completely: do not read one to skip the run, and do not write one at the end')]
    [switch]$NoStamp,

    [Parameter(HelpMessage = 'After a successful build, delete the update packages this script downloaded for previous builds and all but the newest generated ISOs')]
    [switch]$AutoClean,

    [Parameter(HelpMessage = 'Strip servicing residue from each image before committing it: DISM logs, temp files, and leftovers such as $Recycle.Bin that clean Microsoft media never contains. Off by default, so the images are committed exactly as DISM left them')]
    [switch]$StripImageResidue,

    [Parameter(HelpMessage = 'How many generated ISOs -AutoClean keeps (newest first). Defaults to 3')]
    [ValidateRange(1, 100)]
    [int]$KeepIsoCount = 3,

    [Parameter(HelpMessage = 'Create (or update) a scheduled task that runs this script with the other parameters you passed, then exit without building')]
    [switch]$RegisterScheduledTask,

    [Parameter(HelpMessage = 'Delete the scheduled task named by -TaskName, then exit')]
    [switch]$UnregisterScheduledTask,

    [Parameter(HelpMessage = 'How often the registered task runs: Hourly, Daily, Weekly, Monthly or PatchTuesday. Defaults to Monthly. PatchTuesday runs on the second Tuesday of every month, half an hour after Microsoft publishes that month''s updates')]
    [ValidateSet('Hourly', 'Daily', 'Weekly', 'Monthly', 'PatchTuesday')]
    [string]$Schedule = 'Monthly',

    [Parameter(HelpMessage = 'Time of day the registered task starts, as HH:mm (24-hour). Defaults to 03:00, or for -Schedule PatchTuesday to whatever 10:30 Pacific (DST included) is in this machine''s time zone')]
    [ValidatePattern('^\d{1,2}:\d{2}$')]
    [string]$ScheduleTime = '03:00',

    [Parameter(HelpMessage = 'Which day the registered task runs: a weekday name for -Schedule Weekly (default Sunday), or a day number 1-31 for -Schedule Monthly (default 15, a few days after Patch Tuesday). Ignored by -Schedule PatchTuesday, which picks the day itself')]
    [string]$ScheduleDay,

    [Parameter(HelpMessage = 'Name of the scheduled task to create or delete. Defaults to "Windows ISO Updater"')]
    [string]$TaskName = 'Windows ISO Updater',

    [switch]$SkipInteractive # Skips the interactive confirmation prompt
)
#endregion

#region Startup checks and elevation
# Remembered here because inside a function $PSBoundParameters/$MyInvocation describe that function, not
# the script - and the scheduled-task registration has to reproduce this exact command line.
$script:ScriptBoundParameters = $PSBoundParameters
$script:ScriptPath = $PSCommandPath

# Kept in step with the header comment by tools\Update-Version.ps1, and shown in the log and recorded in
# the build stamp so a finished ISO can be traced back to the exact script that built it.
$ScriptVersion = '2026.08.17.1'

# A scheduled run has nobody to answer a prompt.
if ($Scheduled) {
    $Unattended = $true
    $SkipInteractive = $true
}

# Verify this is running on Windows. $IsWindows only exists on PowerShell 6+, where it is the reliable
# test. Windows PowerShell 5.1 is Windows-only, so its absence is itself the answer. This has to come
# before anything that touches CIM, DISM or the registry, all of which are Windows-only.
if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
    Write-Host "This script must be run on Windows. You are currently running $($PSVersionTable.OS)." -ForegroundColor Red
    Write-Host "It relies on Windows-only components (DISM, CIM/WMI and the Windows ADK) to service the image." -ForegroundColor Red
    Start-Sleep -Seconds 10
    exit 1
}

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

#endregion

#region Resolve working folders
# Everything this script writes lives under the working folder, so a single -WorkPath moves the whole
# build (downloads, extracted media, DISM mount, logs) to another drive. These MUST be on a local, fixed
# disk: cloud-synced folders (Google Drive, OneDrive, Dropbox, etc.) turn files into on-demand
# placeholders and sync them in the background, which makes DISM unable to read the .msu/.wim reliably
# ("An error occurred applying the Unattend.xml file from the .msu package"). They also need lots of free
# space and, ideally, no spaces in the path (oscdimg's -bootdata dislikes spaces, so short paths are used
# to work around it regardless).
# Made absolute without requiring it to exist yet, so the drive checks further down see a qualifier even
# when a relative -WorkPath was passed.
$WorkRoot   = if ($WorkPath) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WorkPath) } else { Join-Path -Path $env:SystemDrive -ChildPath 'WISO-Work' }
$ExtractDir = Join-Path -Path $WorkRoot -ChildPath 'ISO'
$MountDir   = Join-Path -Path $WorkRoot -ChildPath 'Mount'
# Where a standalone oscdimg.exe is cached if it has to be downloaded, so later runs reuse it.
$OscdimgLocalPath = Join-Path -Path $WorkRoot -ChildPath 'Tools\oscdimg.exe'
# Downloads and logs default under the work root - NOT the script folder, which may sit on a cloud-synced
# drive (this repo, for example, lives under a Google Drive "My Drive" path).
$DlDir      = if ($DownloadPath) { $DownloadPath } else { Join-Path -Path $WorkRoot -ChildPath 'Downloads' }
$LogDirWanted = if ($LogPath) { $LogPath } else { Join-Path -Path $WorkRoot -ChildPath 'Logs' }
# The finished ISO gets its own folder so it is never mistaken for a source ISO sitting in Downloads.
$FinishedIsoDir = Join-Path -Path $WorkRoot -ChildPath 'Output'
if ($OutputIsoPath) {
    # Absolute from the start, so the run header, the write check, the stamp and the tattoo all quote one path.
    $OutputIsoPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputIsoPath)
    $OutputIsFolder = $false
    try {
        $OutputIsFolder = ($OutputIsoPath -match '[\\/]$') -or
            -not [System.IO.Path]::GetExtension($OutputIsoPath) -or
            (Test-Path -LiteralPath $OutputIsoPath -PathType Container -ErrorAction Stop)
    }
    catch { }   # a malformed or unreachable path is reported properly by the output check further down
    # A folder is shorthand for "put it there under the generated name". Clearing the path is what hands the
    # naming back to the default, so nothing downstream needs a special case.
    if ($OutputIsFolder) {
        $FinishedIsoDir = $OutputIsoPath
        $OutputIsoPath  = $null
    }
}
# Stamps record what each finished build contained, so a scheduled run can tell whether building again
# would produce anything new. -StampPath moves them (e.g. onto a share, so several machines share state).
$StampRoot       = if ($StampPath) { $StampPath } else { Join-Path -Path $WorkRoot -ChildPath 'Stamps' }
$StampHistoryDir = Join-Path -Path $StampRoot -ChildPath 'History'
$StampFile       = Join-Path -Path $StampRoot -ChildPath 'last-build.json'

#endregion

#region Start Logging
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
# Filled in as servicing happens, because by the time the tattoo is written the images are already
# dismounted and DISM's own log is the only other record of which package landed on which image.
$script:TattooServicing   = New-Object System.Collections.Generic.List[object]
$script:TattooResidueMB   = 0
$script:TattooResidueFound = New-Object System.Collections.Generic.List[string]
# The -DriverPath set, resolved once during validation and reused by every image the run services.
$script:DriverInfFiles = @()
$script:DriverHash     = $null
# Filled in while -ExtraFilesPath is copied, because by tattoo time the media already looks merged.
$script:ExtraFilesHash      = $null
$script:ExtraFilesCopied    = 0
$script:ExtraFileRecords    = @()
$script:ExtraFileOverwrites = New-Object System.Collections.Generic.List[string]
#endregion

#region Functions

#region Output and timing helpers
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
#endregion

#region Disk space and path checks
# Returns the free space (GB, rounded to two decimals) on the drive that holds the given path, or $null.
function Get-DriveFreeGB {
    param([string]$Path)
    try {
        $Qualifier = (Split-Path -Path $Path -Qualifier -ErrorAction SilentlyContinue)
        # A UNC path has no qualifier, and guessing the system drive would report a number for the wrong
        # volume, so say nothing rather than something false.
        if (-not $Qualifier) { return $null }
        $Drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$Qualifier'" -ErrorAction Stop
        if ($Drive -and $Drive.FreeSpace) {
            return [math]::Round($Drive.FreeSpace / 1GB, 2)
        }
    }
    catch { }
    return $null
}

# True when a path is not on a local disk: a UNC share, a mapped network drive, or a drive letter that does
# not exist in this session. Mappings are per-logon-session, so a mapped drive that works interactively is
# simply absent when the scheduled task runs.
function Test-RemotePath {
    param([Parameter(Mandatory)][string]$Path)
    if ("$Path" -match '^\\\\') { return $true }
    $Qualifier = try { Split-Path -Path $Path -Qualifier -ErrorAction SilentlyContinue } catch { $null }
    if (-not $Qualifier) { return $false }
    try {
        $Drive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$Qualifier'" -ErrorAction Stop
        if (-not $Drive) { return $true }
        return ([int]$Drive.DriveType -eq 4)
    }
    catch { return $false }   # WMI is not answering, so assume local and carry on as before
}

# Proves the finished ISO can actually be written before the build starts, by creating the destination
# folder and writing a probe file into it. Returns a sentence describing the problem, or $null when the
# location is usable. oscdimg runs at the very end of a build measured in hours, so an unwritable output
# folder that is only discovered there throws away all of that work.
function Get-OutputPathProblem {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [string]$FilePath
    )
    if ($FilePath) {
        # Character checks come first: Test-Path itself throws on a path containing something like a pipe.
        $BadPathChar = @($FilePath.ToCharArray() | Where-Object { [System.IO.Path]::GetInvalidPathChars() -contains $_ })
        if ($BadPathChar.Count -gt 0) {
            return "'$FilePath' contains a character Windows does not allow in a path."
        }
        $Leaf = Split-Path -Path $FilePath -Leaf
        if (-not $Leaf) { return "'$FilePath' does not name a file. Pass -OutputIsoPath a full file name, such as D:\ISOs\Windows11.iso." }
        $BadNameChar = @($Leaf.ToCharArray() | Where-Object { [System.IO.Path]::GetInvalidFileNameChars() -contains $_ })
        if ($BadNameChar.Count -gt 0) {
            return "The file name '$Leaf' contains a character Windows does not allow in a file name."
        }
    }
    if (-not $Directory) { return "'$FilePath' has no folder part, so there is nowhere to write the ISO." }
    # -ErrorAction Stop inside a try is the only reliable way to quieten Test-Path here: an unreachable share
    # raises an IOException that SilentlyContinue does not suppress.
    $DirectoryExists = try { Test-Path -LiteralPath $Directory -ErrorAction Stop } catch { $false }
    if (-not $DirectoryExists) {
        try { New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null }
        catch { return "The output folder '$Directory' does not exist and could not be created: $($_.Exception.Message)" }
    }
    # An ISO left at the target path by a previous run is deleted before oscdimg writes, so a copy that is
    # mounted in Explorer or being read by something else blocks the build just as surely as a bad folder.
    $TargetExists = if ($FilePath) { try { Test-Path -LiteralPath $FilePath -PathType Leaf -ErrorAction Stop } catch { $false } } else { $false }
    if ($TargetExists) {
        try {
            $Handle = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
            $Handle.Close()
        }
        catch {
            return "An ISO already exists at '$FilePath' and something else has it open, so it cannot be replaced. Dismount it or close whatever is using it: $($_.Exception.Message)"
        }
    }
    $Probe = Join-Path -Path $Directory -ChildPath ('wiso-write-test-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($Probe, 'Windows-ISO-Updater write test')
    }
    catch {
        return "The output folder '$Directory' cannot be written to: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $Probe -Force -ErrorAction SilentlyContinue
    }
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
#endregion

#region Downloads
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
# execution. The parsed Host and path are checked (not a substring of the raw URL) so lookalikes such as
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
# signature to check, so instead this confirms the file really is Fido and contains nothing that Fido has
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

    # Fido resolves and downloads ISOs, so it never needs to run generated code, spawn shells, install
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
#endregion

#region Getting the ISO
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

    Write-HostTimestamp "  Could not map the language '$Name' to a Media Creation Tool locale code, so en-US is used. Override it with -MctLangCode." -ForegroundColor Yellow
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

    # Prefer an ISO that was not there before MCT ran, otherwise take the largest one in the folder.
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

# Picks the Windows ISO out of a folder: the largest .iso over 3 GB, so driver discs and other small images
# sharing the folder are skipped. Not recursive, because an ISO library is usually one folder deep and
# walking a whole drive to guess would be worse than being told.
function Find-LargestIso {
    param([Parameter(Mandatory)][string]$Directory)
    return (Get-ChildItem -LiteralPath $Directory -Filter '*.iso' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 3GB } |
            Sort-Object -Property Length -Descending |
            Select-Object -First 1)
}
#endregion

#region Identifying the media
# Maps a Windows build number to its marketing feature-update name (used to build catalog search queries).
function Get-FeatureUpdateName {
    param([Parameter(Mandatory)][int]$Build)
    switch ($Build) {
        26200  { '25H2'; break }
        26100  { '24H2'; break }   # also Windows Server 2025
        25398  { '23H2'; break }   # Windows Server, version 23H2
        22631  { '23H2'; break }
        22621  { '22H2'; break }
        22000  { '21H2'; break }
        20348  { '21H2'; break }   # Windows Server 2022
        19045  { '22H2'; break }   # Windows 10
        19044  { '21H2'; break }   # Windows 10
        17763  { '1809'; break }   # Windows Server 2019 / Windows 10 1809
        14393  { '1607'; break }   # Windows Server 2016
        default { $null }
    }
}

# The product wording the Microsoft Update Catalog uses in update titles, e.g. "Windows 11 Version 24H2".
# Microsoft stopped naming Server media after its year with Server 2022, so anything newer than Server
# 2019 is listed as "Microsoft server operating system version <feature update>" instead.
function Get-CatalogProductQuery {
    param([string]$FeatureUpdate)

    if (-not $Server) {
        return "Windows $WindowsVersion$(if ($FeatureUpdate) { " Version $FeatureUpdate" })"
    }
    switch ($FeatureUpdate) {
        '1607' { return 'Windows Server 2016' }
        '1809' { return 'Windows Server 2019' }
    }
    return "Microsoft server operating system$(if ($FeatureUpdate) { " version $FeatureUpdate" })"
}

# Marketing release name for a Windows Server build, used in the output ISO file name. Server images
# carry no branding of their own beyond the build number.
function Get-ServerReleaseName {
    param([int]$Build)
    switch ($Build) {
        26100  { 'Server2025'; break }
        25398  { 'Server23H2'; break }
        20348  { 'Server2022'; break }
        17763  { 'Server2019'; break }
        14393  { 'Server2016'; break }
        default { 'Server' }
    }
}

#endregion

#region Microsoft Update Catalog helpers
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

# Looks up which OS build(s) a KB article delivers, from the title of its Microsoft support page - e.g.
# "July 8, 2025-KB5062553 (OS Builds 26100.4652 and 26200.4652)". The Update Catalog itself never states
# the resulting build, and this is the only cheap way to know it BEFORE downloading a multi-GB package.
# Returns a hashtable of build -> UBR, or $null if the page could not be read or parsed.
function Get-KbTargetBuilds {
    param([Parameter(Mandatory)][string]$KbNumber)

    try {
        $Response = Invoke-WebRequest -Uri "https://support.microsoft.com/help/$KbNumber" -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    }
    catch { return $null }

    $Title = if ("$($Response.Content)" -match '(?is)<title>(.*?)</title>') { $Matches[1] } else { '' }
    if ($Title -notmatch '(?i)OS Build') { return $null }

    $Builds = @{}
    foreach ($M in [regex]::Matches($Title, '\b(\d{5})\.(\d{1,5})\b')) {
        $Builds[[int]$M.Groups[1].Value] = [int]$M.Groups[2].Value
    }
    if ($Builds.Count -eq 0) { return $null }
    return $Builds
}

# Finds the newest, non-preview cumulative update in the catalog for a given search query, downloads it
# to the download folder, and returns the local .msu path (or $null on failure).
function Get-LatestCatalogPackage {
    param(
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$DownloadDir,
        [string]$TitleInclude,   # regex the title MUST match (e.g. cumulative update wording)
        [string]$TitleExclude,   # regex the title must NOT match (e.g. ".net", "dynamic")
        [switch]$AllowPreview,
        [int]$CurrentBuild,      # OS build already in the image - set to enable the up-to-date check
        [int]$CurrentUbr,        # UBR from the WIM header (only a hint - it is confirmed before use)
        [string]$VerifyWimPath,  # WIM to mount read-only to confirm that UBR before anything is skipped
        [ref]$AlreadyCurrent     # receives the image's confirmed build when the update is not needed
    )

    Write-HostTimestamp "  Searching the Microsoft Update Catalog for: $Query"
    $Results = Search-UpdateCatalog -Query $Query
    if (-not $Results -or $Results.Count -eq 0) {
        Write-HostTimestamp '  No catalog results were returned for that query.' -ForegroundColor Yellow
        return $null
    }
    Write-HostTimestamp "  Found $($Results.Count) catalog result(s), selecting the best match..."

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

    $PrimaryKb = if ($Selected.Title -match '(?i)KB(\d{6,})') { $Matches[1] } else { $null }

    # If the image is already at (or past) the build this KB delivers, there is nothing to gain from
    # downloading and integrating it - that is the hour-long part of the run.
    if ($CurrentBuild -gt 0 -and $CurrentUbr -gt 0 -and $PrimaryKb) {
        $Targets = Get-KbTargetBuilds -KbNumber $PrimaryKb
        $TargetUbr = if ($Targets -and $Targets.ContainsKey($CurrentBuild)) { [int]$Targets[$CurrentBuild] } else { 0 }
        if ($TargetUbr -gt 0 -and $CurrentUbr -ge $TargetUbr) {
            # The WIM header's UBR is stale on some Microsoft media, and wrongly skipping the update would
            # quietly ship an unpatched ISO, so confirm against the image's own SOFTWARE hive first.
            Write-HostTimestamp "  The media claims to be at $CurrentBuild.$CurrentUbr already, and KB$PrimaryKb delivers $CurrentBuild.$TargetUbr. Confirming the image's real patch level before skipping it..."
            $Confirmed = if ($VerifyWimPath) { Get-WimBuildViaMount -WimPath $VerifyWimPath } else { $null }
            $ConfirmedUbr = if ("$Confirmed" -match '\b\d+\.\d+\.\d+\.(\d+)') { [int]$Matches[1] } else { 0 }
            if ($ConfirmedUbr -ge $TargetUbr) {
                Write-HostTimestamp "  Confirmed: the image is at $Confirmed, so KB$PrimaryKb adds nothing - skipping the download and the integration." -ForegroundColor Green
                if ($AlreadyCurrent) { $AlreadyCurrent.Value = $Confirmed }
                return $null
            }
            Write-HostTimestamp "  The image is really at $(if ($Confirmed) { $Confirmed } else { 'an unknown build' }), so the update is needed after all." -ForegroundColor Yellow
        }
    }

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

    # Extracts the numeric KB from a URL/filename for ordering (checkpoints ascending, LCU last).
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
        Write-HostTimestamp "  This update includes $($Downloaded.Count) package(s), which will be integrated in this order:"
        $Ordered | ForEach-Object { Write-HostTimestamp "    - $(Split-Path -Leaf $_.Path)$(if ($_.IsPrimary) { ' (main cumulative update)' })" }
    }

    return @($Ordered | ForEach-Object { $_.Path })
}

#endregion

#region Build stamps
# A stamp is a small JSON record of one finished build: the SHA-256 of the source ISO, the update packages
# that went into it, the build-affecting parameters, and the ISO that came out. A repeat run compares
# itself with the newest stamp and does nothing when all three still match - which is what makes it safe
# to point an hourly scheduled task at a job that takes an hour or two when it does run.

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash }
    catch { return $null }
}

function Get-TextSha256 {
    param([string]$Text)
    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join ($Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$Text")) | ForEach-Object { $_.ToString('x2') })) }
    finally { $Sha.Dispose() }
}

# Path, size and SHA-256 of every file under a folder, sorted, with the path relative to the folder itself.
# Hashing is the expensive part, so the records are produced once and then used both to decide whether the
# folder changed since the last build and to list what actually went onto the media.
function Get-FolderFileRecords {
    param([Parameter(Mandatory)][string]$Path)
    $Root = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\')
    $Records = New-Object System.Collections.Generic.List[object]
    $Files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object -Property FullName)
    foreach ($File in $Files) {
        [void]$Records.Add([ordered]@{
                Path   = $File.FullName.Substring($Root.Length)
                SizeKB = [math]::Round($File.Length / 1KB, 2)
                Sha256 = Get-Sha256 -Path $File.FullName
            })
    }
    return $Records.ToArray()
}

# One hash covering every file under a folder, so swapping a driver for a newer one forces a rebuild even
# though the folder path never changed.
function Get-FolderContentHash {
    param([AllowEmptyCollection()][object[]]$Records)
    $Parts = @($Records | ForEach-Object { "$($_.Path.TrimStart('\').ToLowerInvariant())=$($_.Sha256)" })
    return (Get-TextSha256 -Text ($Parts -join '|'))
}

function Format-ShortHash {
    param([string]$Hash)
    if ($Hash -and $Hash.Length -ge 12) { return $Hash.Substring(0, 12) }
    if ($Hash) { return $Hash }
    return '(none)'
}

# Describes the packages that went into a build. Hashing an LCU is not free, so this runs once and both
# the media tattoo and the build stamp use the result.
function Get-UpdateFileRecords {
    param(
        [string[]]$Paths,
        [string]$DownloadDir
    )
    $Records = @()
    foreach ($Path in @($Paths | Sort-Object -Unique)) {
        $Item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
        if (-not $Item) { continue }
        $Records += [ordered]@{
            FileName           = $Item.Name
            Kb                 = if ($Item.Name -match '(?i)kb(\d{6,})') { "KB$($Matches[1])" } else { '' }
            SizeMB             = [math]::Round($Item.Length / 1MB, 1)
            Sha256             = Get-Sha256 -Path $Item.FullName
            # Only packages this script downloaded itself are ever eligible for -AutoClean.
            FromDownloadFolder = ("$($Item.DirectoryName)".TrimEnd('\') -ieq "$DownloadDir".TrimEnd('\'))
        }
    }
    return $Records
}

# The parameters that change what ends up inside the ISO. Folder, logging and scheduling parameters are
# deliberately left out: moving the working folder does not make last month's ISO wrong.
$script:BuildAffectingParameters = @(
    'WindowsVersion', 'Server', 'Release', 'Language', 'Edition', 'KeepEditions', 'KeepAllEditions',
    'UpdatePath', 'SkipDotNet', 'SkipSetupDU', 'ServiceWinRE', 'SkipUpdates', 'CompressEsd', 'VolumeLabel',
    'SkipTattoo', 'StripImageResidue', 'DriverPath', 'AllowUnsignedDrivers', 'ExtraFilesPath'
)

# Flattens those parameters (current values, not just the ones that were passed) into comparable text.
function Get-BuildParameterSet {
    $Set = [ordered]@{}
    foreach ($Name in $script:BuildAffectingParameters) {
        $Value = Get-Variable -Name $Name -ValueOnly -ErrorAction SilentlyContinue
        $Set[$Name] =
            if ($null -eq $Value) { '' }
            elseif ($Value -is [switch]) { [string][bool]$Value.IsPresent }
            elseif ($Value -is [array]) { (@($Value) | ForEach-Object { "$_" }) -join ',' }
            else { "$Value" }
    }
    # The answer file is copied onto the media, so its CONTENT is part of the build - editing it in place
    # has to force a rebuild even though the path never changed.
    $Set['Unattend'] = if ($script:UnattendHash) { $script:UnattendHash } else { '' }
    # Same for the drivers, which are injected into the images rather than copied onto the media.
    $Set['Drivers'] = if ($script:DriverHash) { $script:DriverHash } else { '' }
    $Set['ExtraFiles'] = if ($script:ExtraFilesHash) { $script:ExtraFilesHash } else { '' }
    return $Set
}

function Get-BuildParameterHash {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Set)
    return (Get-TextSha256 -Text ((@($Set.Keys) | ForEach-Object { "$_=$($Set[$_])" }) -join '|'))
}

function Read-BuildStamp {
    if (-not (Test-Path -LiteralPath $StampFile -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $StampFile -Raw -ErrorAction Stop | ConvertFrom-Json) }
    catch {
        Write-HostTimestamp "  The stamp '$StampFile' could not be read ($($_.Exception.Message)), so this is treated as a first run." -ForegroundColor Yellow
        return $null
    }
}

# Every stamp still on disk, newest first. -AutoClean uses this to know which downloads and ISOs are ones
# this script produced, so it never touches anything else in those folders.
function Get-BuildStampHistory {
    $Stamps = New-Object System.Collections.Generic.List[object]
    foreach ($File in @(Get-ChildItem -LiteralPath $StampHistoryDir -Filter 'stamp_*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try { $Stamps.Add((Get-Content -LiteralPath $File.FullName -Raw -ErrorAction Stop | ConvertFrom-Json)) } catch { }
    }
    return $Stamps.ToArray()
}

# Windows PowerShell 5.1 indents nested JSON to the column of its opening brace, so the deeper parts of
# a stamp end up far off to the right. Re-indent the compressed form to a fixed two spaces instead.
function Format-Json {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Json,
        [int]$IndentWidth = 2
    )
    $Builder = New-Object System.Text.StringBuilder
    $Newline = [Environment]::NewLine
    $Depth = 0
    $InString = $false
    for ($i = 0; $i -lt $Json.Length; $i++) {
        $Char = $Json[$i]
        if ($InString) {
            [void]$Builder.Append($Char)
            # A backslash escapes whatever follows, so consume that before looking for the closing quote.
            if ($Char -eq '\' -and $i + 1 -lt $Json.Length) { [void]$Builder.Append($Json[++$i]) }
            elseif ($Char -eq '"') { $InString = $false }
            continue
        }
        if ($Char -eq '"') { $InString = $true; [void]$Builder.Append($Char); continue }
        if ($Char -eq ':') { [void]$Builder.Append(': '); continue }
        if ($Char -eq ',') { [void]$Builder.Append(",$Newline" + (' ' * ($Depth * $IndentWidth))); continue }
        if ($Char -eq '{' -or $Char -eq '[') {
            [void]$Builder.Append($Char)
            $Close = if ($Char -eq '{') { '}' } else { ']' }
            # An empty object or array stays on one line rather than spending three lines on nothing.
            if ($i + 1 -lt $Json.Length -and $Json[$i + 1] -eq $Close) { [void]$Builder.Append($Close); $i++; continue }
            $Depth++
            [void]$Builder.Append($Newline + (' ' * ($Depth * $IndentWidth)))
            continue
        }
        if ($Char -eq '}' -or $Char -eq ']') {
            $Depth--
            [void]$Builder.Append($Newline + (' ' * ($Depth * $IndentWidth)) + $Char)
            continue
        }
        [void]$Builder.Append($Char)
    }
    return $Builder.ToString()
}

function Write-BuildStamp {
    param([Parameter(Mandatory)]$Stamp)
    try {
        foreach ($Dir in @($StampRoot, $StampHistoryDir)) {
            if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null }
        }
        $Json = Format-Json -Json ($Stamp | ConvertTo-Json -Depth 8 -Compress)
        Set-Content -LiteralPath $StampFile -Value $Json -Encoding UTF8 -ErrorAction Stop
        $HistoryFile = Join-Path -Path $StampHistoryDir -ChildPath ("stamp_{0}.json" -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
        Set-Content -LiteralPath $HistoryFile -Value $Json -Encoding UTF8 -ErrorAction Stop
        Write-HostTimestamp "  Stamp written: $StampFile" -ForegroundColor Green
        Write-HostTimestamp "  History copy : $HistoryFile" -ForegroundColor DarkGray
        Get-ChildItem -LiteralPath $StampHistoryDir -Filter 'stamp_*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTime -Descending |
            Select-Object -Skip $StampHistoryCount |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-HostTimestamp "  Could not write the build stamp: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# SHA-256 of the source ISO, reused from the stamp when this is provably the same file that was hashed
# last time (same path, size and write time). Re-reading 8 GB on every hourly run buys nothing.
function Get-SourceIsoHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        $Stamp
    )
    $Item = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $Item) { return $null }
    if ($Stamp -and $Stamp.Source -and $Stamp.Source.Sha256 -and
        "$($Stamp.Source.Path)" -ieq $Item.FullName -and
        "$($Stamp.Source.Length)" -eq "$($Item.Length)" -and
        "$($Stamp.Source.LastWriteTimeUtc)" -eq $Item.LastWriteTimeUtc.ToString('o')) {
        Write-HostTimestamp '  The source ISO is untouched since the last run, so its recorded hash is reused.' -ForegroundColor DarkGray
        return "$($Stamp.Source.Sha256)"
    }
    Write-HostTimestamp "  Hashing the source ISO ($([math]::Round($Item.Length / 1GB, 2)) GB)..."
    return (Get-Sha256 -Path $Path)
}

# Resolves the newest catalog entry for a query WITHOUT downloading it - the cheap half of
# Get-LatestCatalogPackage, so a scheduled run can see what Microsoft is offering for the price of one
# web request. Returns $null when the catalog cannot be reached or nothing matches.
function Get-CatalogLatestEntry {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$TitleInclude,
        [string]$TitleExclude
    )
    $Results = Search-UpdateCatalog -Query $Query
    if (-not $Results -or $Results.Count -eq 0) { return $null }
    $Filtered = $Results
    if ($TitleInclude) { $Filtered = $Filtered | Where-Object { $_.Title -match $TitleInclude } }
    if ($TitleExclude) { $Filtered = $Filtered | Where-Object { $_.Title -notmatch $TitleExclude } }
    $Filtered = $Filtered | Where-Object { $_.Title -notmatch '(?i)preview' }
    if (-not $Filtered) { return $null }
    return ($Filtered |
        Sort-Object -Property @{ Expression = { $_.LastUpdated }; Descending = $true }, @{ Expression = { $_.SizeMB }; Descending = $true } |
        Select-Object -First 1)
}

# Identifies a catalog entry for comparison: the KB number plus the date Microsoft last touched it, since
# the same KB does get re-released and a re-release is a different package.
function Get-CatalogEntryTag {
    param($Entry)
    if (-not $Entry) { return 'none' }
    $Kb = if ($Entry.Title -match '(?i)KB(\d{6,})') { $Matches[1] } else { $Entry.Guid }
    $Date = if ($Entry.LastUpdated) { ([datetime]$Entry.LastUpdated).ToString('yyyy-MM-dd') } else { '' }
    return "KB$Kb@$Date"
}

# The updates a build with the current parameters would integrate right now, as "Role=KB@date" strings.
# Comparing this list with the one in the last stamp is what tells a scheduled run whether anything new
# has been published. Returns $null when the catalog could not be reached at all, so the caller can tell
# "nothing new" apart from "could not find out".
function Get-ExpectedUpdateSet {
    param(
        [string]$FeatureName,
        [string]$CatalogArch
    )

    if ($SkipUpdates) { return @('None') }
    if ($UpdatePath) {
        # Locally supplied packages: their names and sizes are the identity, no catalog involved.
        $Files = @(Get-ChildItem -Path $UpdatePath -Include '*.msu', '*.cab' -File -Recurse -ErrorAction SilentlyContinue)
        return @($Files | ForEach-Object { "Local=$($_.Name):$($_.Length)" } | Sort-Object)
    }
    if (-not $CatalogArch) { return $null }
    # The server product name carries no branding of its own, so without a feature update it matches every
    # Server release in the catalog and no query can identify this media.
    if ($Server -and -not $FeatureName) { return $null }

    $Product = Get-CatalogProductQuery -FeatureUpdate $FeatureName
    $Include = '(?i)cumulative update for (windows|microsoft server operating system)'
    $Exclude = '(?i)\.net|dynamic update'
    $Set = New-Object System.Collections.Generic.List[string]

    # Same queries (including the broader fallback) the download step uses, so the two always agree.
    $Lcu = Get-CatalogLatestEntry -Query "Cumulative Update for $Product for $CatalogArch-based Systems" -TitleInclude $Include -TitleExclude $Exclude
    if (-not $Lcu -and -not $Server) {
        $Lcu = Get-CatalogLatestEntry -Query "Cumulative Update for $(Get-CatalogProductQuery) for $CatalogArch-based Systems" -TitleInclude $Include -TitleExclude $Exclude
    }
    if (-not $Lcu) { return $null }
    $Set.Add("LCU=$(Get-CatalogEntryTag -Entry $Lcu)")

    if (-not $SkipDotNet) {
        $DotNet = Get-CatalogLatestEntry -Query "Cumulative Update for .NET Framework $Product for $CatalogArch" -TitleInclude '(?i)\.net framework' -TitleExclude '(?i)dynamic update'
        $Set.Add("DotNet=$(Get-CatalogEntryTag -Entry $DotNet)")
    }
    if (-not $SkipSetupDU) {
        $SetupDu = Get-CatalogLatestEntry -Query "Setup Dynamic Update $Product $CatalogArch" -TitleInclude '(?i)setup dynamic update'
        $Set.Add("SetupDU=$(Get-CatalogEntryTag -Entry $SetupDu)")
    }
    if ($ServiceWinRE) {
        # Server media labels the Safe OS package plain "Dynamic Update", so the Setup one is excluded by
        # name instead of the Safe OS one being required by name.
        $SafeInclude = if ($Server) { '(?i)dynamic update' } else { '(?i)safe os dynamic update' }
        $SafeOs = Get-CatalogLatestEntry -Query "Safe OS Dynamic Update $Product $CatalogArch" -TitleInclude $SafeInclude -TitleExclude '(?i)setup dynamic update'
        $Set.Add("SafeOS=$(Get-CatalogEntryTag -Entry $SafeOs)")
    }
    return @($Set)
}

# Decides whether this run has anything to do. Returns the decision plus the reasons behind it, so the
# log always says why an hour of work is - or is not - about to start.
function Test-RebuildNeeded {
    param(
        $Stamp,
        [string]$SourceHash,
        [System.Collections.IDictionary]$ParameterSet,
        [string[]]$ExpectedUpdates
    )

    $Reasons = New-Object System.Collections.Generic.List[string]

    if (-not $Stamp) {
        $Reasons.Add('no previous stamp was found, so this is treated as a first build')
        return [pscustomobject]@{ Rebuild = $true; Reasons = @($Reasons) }
    }

    if ("$($Stamp.Source.Sha256)" -ne "$SourceHash") {
        $Reasons.Add("the source ISO changed (stamp: $(Format-ShortHash "$($Stamp.Source.Sha256)"), now: $(Format-ShortHash $SourceHash))")
    }

    if ("$($Stamp.ParametersHash)" -ne (Get-BuildParameterHash -Set $ParameterSet)) {
        $Changed = @()
        foreach ($Key in @($ParameterSet.Keys)) {
            $Old = if ($Stamp.Parameters -and ($Stamp.Parameters.PSObject.Properties.Name -contains $Key)) { "$($Stamp.Parameters.$Key)" } else { '(not recorded)' }
            if ($Old -ne "$($ParameterSet[$Key])") { $Changed += "$Key '$Old' -> '$($ParameterSet[$Key])'" }
        }
        $Reasons.Add("the build parameters changed$(if ($Changed) { ": $($Changed -join ', ')" })")
    }

    $Recorded = @()
    if ($Stamp.Updates -and $Stamp.Updates.Catalog) { $Recorded = @($Stamp.Updates.Catalog | ForEach-Object { "$_" } | Sort-Object) }
    if ($null -eq $ExpectedUpdates) {
        # A network blip must not trigger a two-hour rebuild, so the next scheduled run will look again.
        $Reasons.Add('the Microsoft Update Catalog could not be reached, so this run assumes nothing new has been published')
    }
    elseif ($Recorded.Count -eq 0) {
        $Reasons.Add('the last stamp did not record which updates were used')
    }
    else {
        $Now = @($ExpectedUpdates | ForEach-Object { "$_" } | Sort-Object)
        if (($Recorded -join '|') -ne ($Now -join '|')) {
            $Reasons.Add("the available updates changed (stamp: $($Recorded -join ', ') / now: $($Now -join ', '))")
        }
    }

    if (-not $Stamp.Output -or -not $Stamp.Output.Path) {
        $Reasons.Add('the last stamp does not name an output ISO')
    }
    elseif (-not (Test-Path -LiteralPath "$($Stamp.Output.Path)" -PathType Leaf)) {
        $Reasons.Add("the ISO from the last build is gone ($($Stamp.Output.Path))")
    }

    # The catalog-unreachable note is informational only - on its own it is not a reason to rebuild.
    $Blocking = @($Reasons | Where-Object { $_ -notmatch 'could not be reached' })
    return [pscustomobject]@{ Rebuild = ($Blocking.Count -gt 0); Reasons = @($Reasons) }
}

#endregion

#region Housekeeping (-AutoClean)
# Only files this script recorded in a stamp are ever deleted, so anything else living in the same folders
# (a hand-placed ISO, someone else's .msu) is left completely alone.
function Invoke-AutoClean {
    param(
        $CurrentStamp,
        [object[]]$History,
        [int]$KeepIsoCount,
        [string[]]$Protected
    )

    $ProtectedPaths = @(@($Protected) | Where-Object { $_ } | ForEach-Object { "$_".TrimEnd('\').ToLowerInvariant() })

    # 1. Update packages: everything a stamp says was downloaded into the download folder, except the ones
    #    the newest build still uses.
    $Keep = @()
    if ($CurrentStamp -and $CurrentStamp.Updates -and $CurrentStamp.Updates.Files) {
        $Keep = @($CurrentStamp.Updates.Files | ForEach-Object { "$($_.FileName)" })
    }
    $Known = New-Object System.Collections.Generic.List[string]
    foreach ($Stamp in @($History)) {
        if (-not $Stamp -or -not $Stamp.Updates -or -not $Stamp.Updates.Files) { continue }
        foreach ($Entry in @($Stamp.Updates.Files)) {
            # Packages the user pointed at with -UpdatePath are not ours to delete.
            if ($Entry.FileName -and $Entry.FromDownloadFolder) { $Known.Add("$($Entry.FileName)") }
        }
    }

    $RemovedUpdates = 0
    $FreedMB = 0
    foreach ($Name in @($Known | Sort-Object -Unique)) {
        if ($Keep -contains $Name) { continue }
        # A stamp is written by this script, but it is still a file on disk: never let a name out of one
        # escape the download folder.
        if ($Name -match '[\\/:]' -or $Name -notmatch '(?i)\.(msu|cab)$') { continue }
        $Path = Join-Path -Path $DlDir -ChildPath $Name
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { continue }
        if ($ProtectedPaths -contains $Path.ToLowerInvariant()) { continue }
        try {
            $SizeMB = (Get-Item -LiteralPath $Path).Length / 1MB
            Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            $RemovedUpdates++
            $FreedMB += $SizeMB
            Write-HostTimestamp ('  Deleted superseded update: {0} ({1:N0} MB)' -f $Name, $SizeMB) -ForegroundColor DarkGray
        }
        catch { Write-HostTimestamp "  Could not delete '$Name': $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    if ($RemovedUpdates -eq 0) { Write-HostTimestamp '  No superseded update packages to remove.' -ForegroundColor DarkGray }

    # 2. Generated ISOs: keep the newest -KeepIsoCount, delete the rest. Candidates are the ISOs named in
    #    the stamps plus any still sitting in the output folder under this script's generated name pattern
    #    (their stamp may have aged out of the history).
    $Candidates = @{}
    foreach ($Stamp in (@($CurrentStamp) + @($History))) {
        if (-not $Stamp -or -not $Stamp.Output -or -not $Stamp.Output.Path) { continue }
        $Item = Get-Item -LiteralPath "$($Stamp.Output.Path)" -ErrorAction SilentlyContinue
        if ($Item) { $Candidates[$Item.FullName.ToLowerInvariant()] = $Item }
    }
    # Must track every tag Get-DefaultIsoName can emit, including the Server release names.
    $GeneratedName = '^(Win10|Win11|Windows|Server[A-Za-z0-9]*)_[A-Za-z0-9]+_[A-Za-z0-9]+(_[\d.]+)?_\d{8}-\d{4}\.iso$'
    foreach ($Item in @(Get-ChildItem -LiteralPath $FinishedIsoDir -Filter '*.iso' -File -ErrorAction SilentlyContinue)) {
        if ($Item.Name -match $GeneratedName) { $Candidates[$Item.FullName.ToLowerInvariant()] = $Item }
    }

    $Ordered = @($Candidates.Values | Sort-Object -Property LastWriteTime -Descending)
    $Stale = @($Ordered | Select-Object -Skip $KeepIsoCount | Where-Object { $ProtectedPaths -notcontains $_.FullName.ToLowerInvariant() })
    if ($Ordered.Count -gt 0) {
        Write-HostTimestamp "  Found $($Ordered.Count) generated ISO(s), keeping the newest $KeepIsoCount." -ForegroundColor DarkGray
    }
    $RemovedIsos = 0
    foreach ($Item in $Stale) {
        try {
            $SizeMB = $Item.Length / 1MB
            Remove-Item -LiteralPath $Item.FullName -Force -ErrorAction Stop
            $RemovedIsos++
            $FreedMB += $SizeMB
            Write-HostTimestamp ('  Deleted old ISO: {0} ({1:N0} MB)' -f $Item.Name, $SizeMB) -ForegroundColor DarkGray
        }
        catch { Write-HostTimestamp "  Could not delete '$($Item.FullName)': $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    if ($RemovedIsos -eq 0) { Write-HostTimestamp '  No old ISOs to remove.' -ForegroundColor DarkGray }

    Write-HostTimestamp ('  Cleanup removed {0} update package(s) and {1} ISO(s), freeing {2:N1} GB.' -f $RemovedUpdates, $RemovedIsos, ($FreedMB / 1024)) -ForegroundColor Green
}

#endregion

#region Scheduled task registration
# Rebuilds this run's command line for the task, dropping the parameters that only make sense when a human
# typed them and adding -Scheduled so the task never waits at a prompt.
function Get-ScheduledTaskArgumentString {
    $Excluded = @(
        'RegisterScheduledTask', 'UnregisterScheduledTask', 'Schedule', 'ScheduleTime', 'ScheduleDay',
        'TaskName', 'CheckOnly', 'Force', 'ListEditions', 'Unattended', 'SkipInteractive', 'Scheduled'
    )
    $Arguments = New-Object System.Collections.Generic.List[string]
    $Arguments.Add('-NoProfile')
    $Arguments.Add('-ExecutionPolicy')
    $Arguments.Add('Bypass')
    $Arguments.Add('-File')
    $Arguments.Add("`"$($script:ScriptPath)`"")
    $Arguments.Add('-Scheduled')

    foreach ($Name in @($script:ScriptBoundParameters.Keys)) {
        if ($Excluded -contains $Name) { continue }
        $Value = $script:ScriptBoundParameters[$Name]
        if ($Value -is [switch]) {
            if ($Value.IsPresent) { $Arguments.Add("-$Name") }
            continue
        }
        $Arguments.Add("-$Name")
        foreach ($Item in @($Value)) { $Arguments.Add("`"$Item`"") }
    }
    return ($Arguments -join ' ')
}

# Microsoft publishes Patch Tuesday updates around 10:00 Pacific, so -Schedule PatchTuesday aims for 10:30
# Pacific translated into this machine's time zone. Pacific and local DST rules drift apart during the
# year, so the latest local equivalent across the next twelve Patch Tuesdays is used: running late is
# harmless (the stamp check exits in a minute or two), running early misses that month's updates for a
# whole month. Returns $null when the Pacific zone cannot be resolved.
function Get-PatchTuesdayStart {
    $Pacific = $null
    foreach ($Id in @('Pacific Standard Time', 'America/Los_Angeles')) {
        try { $Pacific = [System.TimeZoneInfo]::FindSystemTimeZoneById($Id); break } catch { }
    }
    if (-not $Pacific) { return $null }

    $LatestSameDay = [timespan]::Zero
    $LatestNextDay = $null
    $FirstOfThisMonth = Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0 -Millisecond 0
    for ($Index = 0; $Index -lt 12; $Index++) {
        $FirstOfMonth = $FirstOfThisMonth.AddMonths($Index)
        $ToTuesday = ([int][System.DayOfWeek]::Tuesday - [int]$FirstOfMonth.DayOfWeek + 7) % 7
        $SecondTuesday = $FirstOfMonth.AddDays($ToTuesday + 7)
        $PacificStart = [datetime]::new($SecondTuesday.Year, $SecondTuesday.Month, $SecondTuesday.Day, 10, 30, 0, [System.DateTimeKind]::Unspecified)
        $LocalStart = [System.TimeZoneInfo]::ConvertTime($PacificStart, $Pacific, [System.TimeZoneInfo]::Local)
        if ($LocalStart.Date -ne $SecondTuesday.Date) {
            if ($null -eq $LatestNextDay -or $LocalStart.TimeOfDay -gt $LatestNextDay) { $LatestNextDay = $LocalStart.TimeOfDay }
        }
        elseif ($LocalStart.TimeOfDay -gt $LatestSameDay) {
            $LatestSameDay = $LocalStart.TimeOfDay
        }
    }

    # Where any month spills over midnight the whole schedule moves to the following local day, and only
    # those months set the time - any month that did land on the Tuesday is then at most a few hours late.
    $CrossesMidnight = ($null -ne $LatestNextDay)
    $StartTime = if ($CrossesMidnight) { $LatestNextDay } else { $LatestSameDay }
    $ZoneName = if ($Pacific.IsDaylightSavingTime((Get-Date))) { $Pacific.DaylightName } else { $Pacific.StandardName }

    return [pscustomobject]@{
        TimeOfDay       = $StartTime
        CrossesMidnight = $CrossesMidnight
        ZoneName        = $ZoneName
    }
}

function Register-UpdaterScheduledTask {
    if (-not (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'The ScheduledTasks PowerShell module is not available on this machine.'
    }
    if (-not $script:ScriptPath -or -not (Test-Path -LiteralPath $script:ScriptPath)) {
        throw 'The path of this script could not be determined, so a scheduled task cannot point at it.'
    }

    $TimeText = $ScheduleTime
    $PatchTuesday = $null
    if ($Schedule -eq 'PatchTuesday') {
        $PatchTuesday = Get-PatchTuesdayStart
        if (-not $script:ScriptBoundParameters.ContainsKey('ScheduleTime')) {
            $TimeText = if ($PatchTuesday) { ([datetime]::Today.Add($PatchTuesday.TimeOfDay)).ToString('HH:mm') } else { '10:30' }
        }
    }

    if ($TimeText -notmatch '^(\d{1,2}):(\d{2})$') {
        throw "-ScheduleTime '$TimeText' is not a valid 24-hour HH:mm time."
    }
    $Hour = [int]$Matches[1]
    $Minute = [int]$Matches[2]
    if ($Hour -gt 23 -or $Minute -gt 59) {
        throw "-ScheduleTime '$TimeText' is not a valid 24-hour HH:mm time."
    }
    # Anchor the trigger on today's date at that time.
    $Start = Get-Date -Hour $Hour -Minute $Minute -Second 0 -Millisecond 0

    # Register-ScheduledTask rejects the MSFT_Task*Monthly*Trigger CIM classes outright ("the parameter is
    # incorrect"), so a monthly schedule is registered with a placeholder weekly trigger and then rewritten
    # through the task's own XML, where Task Scheduler does accept a monthly calendar trigger.
    $CalendarXml = $null
    $MonthsXml = '<Months><January /><February /><March /><April /><May /><June /><July /><August /><September /><October /><November /><December /></Months>'

    switch ($Schedule) {
        'Hourly' {
            # No repetition duration = repeat indefinitely.
            $Trigger = New-ScheduledTaskTrigger -Once -At $Start -RepetitionInterval (New-TimeSpan -Hours 1)
            $When = "every hour, starting at $($Start.ToString('HH:mm'))"
        }
        'Daily' {
            $Trigger = New-ScheduledTaskTrigger -Daily -At $Start
            $When = "every day at $($Start.ToString('HH:mm'))"
        }
        'Weekly' {
            $DayName = if ($ScheduleDay) { $ScheduleDay } else { 'Sunday' }
            $Day = $null
            try { $Day = [System.DayOfWeek][enum]::Parse([System.DayOfWeek], $DayName, $true) }
            catch { throw "-ScheduleDay '$DayName' is not a weekday name (use e.g. Sunday, Monday...)." }
            $Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Day -At $Start
            $When = "every $Day at $($Start.ToString('HH:mm'))"
        }
        'Monthly' {
            $DayNumber = if ($ScheduleDay) { $ScheduleDay } else { '15' }
            if ($DayNumber -notmatch '^\d{1,2}$' -or [int]$DayNumber -lt 1 -or [int]$DayNumber -gt 31) {
                throw "-ScheduleDay '$DayNumber' is not a day of the month (use 1-31) for a monthly schedule."
            }
            $Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $Start
            $CalendarXml = "<ScheduleByMonth><DaysOfMonth><Day>$([int]$DayNumber)</Day></DaysOfMonth>$MonthsXml</ScheduleByMonth>"
            $When = "on day $DayNumber of every month at $($Start.ToString('HH:mm'))"
        }
        'PatchTuesday' {
            if ($ScheduleDay) {
                Write-HostTimestamp "-ScheduleDay '$ScheduleDay' is ignored by -Schedule PatchTuesday." -ForegroundColor Yellow
            }
            $PacificNote = ''
            if ($PatchTuesday -and -not $script:ScriptBoundParameters.ContainsKey('ScheduleTime') -and $PatchTuesday.TimeOfDay -ne [timespan]::new(10, 30, 0)) {
                $PacificNote = " (10:30 $($PatchTuesday.ZoneName) in local time)"
            }
            $Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At $Start
            if ($PatchTuesday -and $PatchTuesday.CrossesMidnight) {
                # 10:30 Pacific lands on the next local day here, and the Wednesday after the second Tuesday
                # is not always in week 2, so both weeks are triggered - the early one just exits.
                $CalendarXml = "<ScheduleByMonthDayOfWeek><Weeks><Week>2</Week><Week>3</Week></Weeks><DaysOfWeek><Wednesday /></DaysOfWeek>$MonthsXml</ScheduleByMonthDayOfWeek>"
                $When = "on the second and third Wednesday of every month at $($Start.ToString('HH:mm'))$PacificNote, which is the local morning after Patch Tuesday"
            }
            else {
                $CalendarXml = "<ScheduleByMonthDayOfWeek><Weeks><Week>2</Week></Weeks><DaysOfWeek><Tuesday /></DaysOfWeek>$MonthsXml</ScheduleByMonthDayOfWeek>"
                $When = "on the second Tuesday of every month at $($Start.ToString('HH:mm'))$PacificNote"
                if ($PatchTuesday -and $Start.TimeOfDay -lt $PatchTuesday.TimeOfDay) {
                    Write-HostTimestamp "-ScheduleTime $($Start.ToString('HH:mm')) is earlier than $(([datetime]::Today.Add($PatchTuesday.TimeOfDay)).ToString('HH:mm')) (10:30 $($PatchTuesday.ZoneName)), so the task may run before that month's updates are published." -ForegroundColor Yellow
                }
            }
        }
    }

    $Exe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path -Path $PSHOME -ChildPath 'pwsh.exe' } else { Join-Path -Path $PSHOME -ChildPath 'powershell.exe' }
    $ArgumentString = Get-ScheduledTaskArgumentString
    $Action = New-ScheduledTaskAction -Execute $Exe -Argument $ArgumentString -WorkingDirectory (Split-Path -Parent $script:ScriptPath)
    # SYSTEM so the task needs no stored password, and it is also already elevated, which DISM requires.
    $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 8)

    Register-ScheduledTask -TaskName $TaskName -Trigger $Trigger -Action $Action -Principal $Principal `
        -Settings $Settings -Description 'Rebuilds an up-to-date Windows installation ISO (Windows-ISO-Updater). Skips the build when nothing has changed.' -Force -ErrorAction Stop | Out-Null

    if ($CalendarXml) {
        # No -User here: the exported XML already carries the principal, settings and action unchanged.
        $TaskXml = (Export-ScheduledTask -TaskName $TaskName) -replace '(?s)<ScheduleByWeek>.*?</ScheduleByWeek>', $CalendarXml
        Register-ScheduledTask -TaskName $TaskName -Xml $TaskXml -Force -ErrorAction Stop | Out-Null
    }

    Write-HostTimestamp "Scheduled task '$TaskName' registered: runs $When as SYSTEM." -ForegroundColor Green
    Write-HostTimestamp "  Command: `"$Exe`" $ArgumentString" -ForegroundColor DarkGray
    Write-HostTimestamp '  It runs as SYSTEM, so every path it uses must be a local path SYSTEM can reach (not a mapped drive or a cloud-synced user folder).' -ForegroundColor Yellow
    Write-HostTimestamp "  Each run compares the build stamp in $StampRoot and exits in a minute or two when nothing has changed." -ForegroundColor DarkGray
    Write-HostTimestamp "  Remove it again with: -UnregisterScheduledTask -TaskName `"$TaskName`"" -ForegroundColor DarkGray
}
#endregion

#region oscdimg and the ADK
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
#endregion

#region Editions and output naming
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
# Pro, and Home are considered (Enterprise > Pro > Home). Education and Workstation editions (including
# "Pro Education" and "Pro for Workstations") are deliberately excluded and scored lowest so they are
# never chosen when a plain Enterprise/Pro/Home edition is present. Within a tier, base editions are
# preferred over the "N" and "Single Language" variants.
# Windows Server is ranked the other way up, Standard over Datacenter: an installed Standard server can be
# upgraded to Datacenter in place with DISM /Set-Edition, but Datacenter can never be taken back down. The
# Desktop Experience still wins over the bare (Server Core) name, because that choice cannot be changed
# after installation in either direction.
function Get-EditionRank {
    param([string]$Name)
    $n = "$Name".ToLower()
    if ($n -match 'standard') { $Rank = 70 }
    elseif ($n -match 'datacenter') { $Rank = 50 }
    elseif ($n -match 'education|workstation') { $Rank = 5 }  # excluded tiers - lowest priority
    elseif ($n -match 'enterprise') { $Rank = 60 }
    elseif ($n -match 'pro') { $Rank = 40 }
    elseif ($n -match 'home|core') { $Rank = 20 }
    else { $Rank = 10 }
    if ($n -match 'desktop experience') { $Rank += 1 } # prefer the full server install over Server Core
    if ($n -match '(^|\s)n(\s|$)') { $Rank -= 2 }   # prefer base over "N" variants
    if ($n -match 'single language') { $Rank -= 1 } # prefer base over Single Language
    return $Rank
}

# Chooses the editions to keep when the user has not named any: Enterprise, Pro and Home on client media,
# whichever of them the media actually carries, so one ISO covers the business and consumer tiers. Server
# media keeps one, because its tiers are a licence choice rather than something the person at the keyboard
# picks during Setup.
function Select-DefaultEditions {
    param(
        [Parameter(Mandatory)][object[]]$Images,
        [switch]$ServerMedia
    )

    # Shorter names sort first, so a base edition beats its "N" and "Single Language" variants.
    $Ranked = @($Images |
            Sort-Object @{ Expression = { Get-EditionRank $_.ImageName }; Descending = $true },
            @{ Expression = { "$($_.ImageName)".Length } },
            @{ Expression = { [int]$_.ImageIndex } })
    if ($Ranked.Count -eq 0) { return @() }

    $Keep = New-Object System.Collections.Generic.List[object]
    if ($ServerMedia) {
        [void]$Keep.Add($Ranked[0])
    }
    else {
        # Highest tier first, so the top edition lands at index 1 after the re-export renumbers the image
        # and an answer file selecting by /IMAGE/INDEX still gets the edition it used to.
        foreach ($Tier in '(?i)enterprise', '(?i)pro', '(?i)home|core') {
            $Best = $Ranked |
                Where-Object { "$($_.ImageName)" -match $Tier -and "$($_.ImageName)" -notmatch '(?i)education|workstation' } |
                Where-Object { $Keep.ImageIndex -notcontains [int]$_.ImageIndex } |
                Select-Object -First 1
            if ($Best) { [void]$Keep.Add($Best) }
        }
        # Media carrying none of the three (an Education- or LTSC-only build under another name) still
        # needs something to service.
        if ($Keep.Count -eq 0) { [void]$Keep.Add($Ranked[0]) }
    }
    return @($Keep | ForEach-Object { [int]$_.ImageIndex })
}

# Shortens a WIM edition name ("Windows 11 Pro") to the tag used in the output ISO file name.
function Get-EditionShortName {
    param([string]$Name)
    $n = "$Name".ToLower()
    # Server names carry no "Server Core" marker: the bare name IS Server Core, the other is the GUI.
    if ($n -match 'datacenter|standard') {
        $Tier = if ($n -match 'datacenter') { 'Datacenter' } else { 'Standard' }
        return $Tier + $(if ($n -match 'desktop experience') { 'GUI' } else { 'Core' })
    }
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
    $WindowsTag =
        if ($Server) { Get-ServerReleaseName -Build $BuildNumber }
        elseif ($BuildNumber -ge 22000) { 'Win11' }
        elseif ($BuildNumber -gt 0) { 'Win10' }
        else { 'Windows' }

    $Parts = @($WindowsTag, $EditionTag)
    if ($Architecture) { $Parts += ($Architecture -replace '[^A-Za-z0-9]', '') }
    if ($BuildUbr) { $Parts += $BuildUbr }
    $Parts += (Get-Date -Format 'yyyyMMdd-HHmm')
    return (($Parts -join '_') + '.iso')
}

# Builds the ISO's volume label from the generated file name, so the media describes itself the same way
# the file does. oscdimg writes no label unless -l is passed, and unlabelled media turns up as a generic
# "DVD_ROM" in File Explorer and in the Rufus volume label box.
function Get-IsoVolumeLabel {
    param([Parameter(Mandatory)][string]$IsoFileName)

    # Windows shows 32 characters, and only A-Z, 0-9 and underscore survive every reader, so the build
    # timestamp is dropped (the label describes contents, not when it was made) and the rest is folded.
    $MaxLength = 32
    $Base = [System.IO.Path]::GetFileNameWithoutExtension($IsoFileName) -replace '_\d{8}-\d{4}$', ''
    $Label = ($Base.ToUpperInvariant() -replace '[^A-Z0-9]', '_') -replace '_+', '_'

    # Too long drops the architecture first, then shortens the edition, so the Windows release and the
    # build number (the two things worth reading off a USB stick) always survive intact.
    if ($Label.Length -gt $MaxLength) { $Label = $Label -replace '_(X64|X86|ARM64|AMD64)_', '_' }
    if ($Label.Length -gt $MaxLength -and $Label -match '^([A-Z0-9]+)_([A-Z0-9]+)_(.+)$') {
        $Room = $MaxLength - ($Matches[1].Length + $Matches[3].Length + 2)
        if ($Room -ge 3) {
            $Label = '{0}_{1}_{2}' -f $Matches[1], $Matches[2].Substring(0, [Math]::Min($Matches[2].Length, $Room)), $Matches[3]
        }
    }
    if ($Label.Length -gt $MaxLength) { $Label = $Label.Substring(0, $MaxLength) }
    return $Label.Trim('_')
}
#endregion

#region Mount recovery
# Last resort for a mount that nothing in this session can release. At boot the WIM filter driver has not
# re-attached anything yet, so a task running as SYSTEM (which outranks the TrustedInstaller ACLs DISM
# leaves on the files) can clear the folder before anything claims it. The task deletes itself afterwards
# so a machine is never left with a stray task from a failed build.
function Register-MountCleanupTask {
    param([Parameter(Mandatory)][string[]]$Path)

    if (-not (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)) { return $false }

    $CleanupTaskName = 'Windows-ISO-Updater Mount Cleanup'
    $ToolsDir = Join-Path -Path $WorkRoot -ChildPath 'Tools'
    $CleanupScript = Join-Path -Path $ToolsDir -ChildPath 'Clear-StaleMount.ps1'
    $CleanupLog = Join-Path -Path $LogDir -ChildPath 'mount-cleanup.log'

    # Every mount folder goes in the list, not just the one that failed. By the time this runs the build is
    # long dead, so the siblings are stale too, and clearing them all is what makes the next run start clean.
    $Targets = New-Object System.Collections.Generic.List[string]
    foreach ($Item in @($Path) + @('Mount', 'WinREMount', 'BuildCheck' | ForEach-Object { Join-Path -Path $WorkRoot -ChildPath $_ })) {
        if ($Item -and -not ($Targets | Where-Object { $_ -ieq $Item })) { $Targets.Add($Item) }
    }
    $PathList = ($Targets | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '

    # Runs unattended at boot, so it leaves a log rather than failing silently. Everything here is the
    # teardown DISM should have done itself: strip the reparse point and attributes the WIM filter leaves
    # on a half-released mount, drop the registry entry that /Cleanup-Mountpoints skips when the mount is
    # too broken for DISM to recognise, and only then take ownership and delete.
    $Body = @"
`$ErrorActionPreference = 'SilentlyContinue'
Start-Transcript -Path '$CleanupLog' -Append | Out-Null
`$Targets = @($PathList)

foreach (`$Target in `$Targets) {
    if (-not (Test-Path -LiteralPath `$Target)) { continue }
    "Stripping reparse point and attributes from `$Target"
    & fsutil.exe reparsepoint delete "`$Target"
    & attrib.exe -R -S -H "`$Target" /S /D
}

# DISM's own list of mounts. An entry here that no longer matches reality is what makes every later mount
# fail, and it outlives both a reboot and /Cleanup-Mountpoints. Matched on any value holding the path
# rather than one named value, so a layout change cannot make this delete the wrong key.
`$MountedKey = 'HKLM:\SOFTWARE\Microsoft\WIMMount\Mounted Images'
foreach (`$Entry in (Get-ChildItem -LiteralPath `$MountedKey)) {
    `$Values = Get-ItemProperty -LiteralPath `$Entry.PSPath
    foreach (`$Prop in `$Values.PSObject.Properties) {
        if (`$Prop.Value -isnot [string]) { continue }
        foreach (`$Target in `$Targets) {
            if (`$Prop.Value.TrimEnd('\') -ieq `$Target.TrimEnd('\')) {
                "Removing orphaned WIMMount registration `$(`$Entry.PSChildName) for `$Target"
                Remove-Item -LiteralPath `$Entry.PSPath -Recurse -Force
            }
        }
    }
}

& dism.exe /English /Cleanup-Mountpoints

`$EmptyDir = Join-Path -Path `$env:TEMP -ChildPath 'wiso-empty'
New-Item -ItemType Directory -Path `$EmptyDir -Force | Out-Null
foreach (`$Target in `$Targets) {
    if (-not (Test-Path -LiteralPath `$Target)) { continue }
    "Taking ownership of `$Target and deleting it"
    & takeown.exe /F "`$Target" /A /R /D Y | Out-Null
    & icacls.exe "`$Target" /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q | Out-Null
    # Nothing else here reaches the WinSxS paths past 260 characters, and /B uses backup privileges.
    & robocopy.exe `$EmptyDir `$Target /MIR /B /R:0 /W:0 /NFL /NDL /NJH /NJS /NP | Out-Null
    `$DeleteError = `$null
    Remove-Item -LiteralPath `$Target -Recurse -Force -ErrorVariable DeleteError
    if (Test-Path -LiteralPath `$Target) {
        `$Remaining = @(Get-ChildItem -LiteralPath `$Target -Recurse -Force).Count
        "STILL PRESENT: `$Target (`$Remaining items left) `$(if (`$DeleteError) { `$DeleteError[0].Exception.Message })"
    }
    else { "Removed `$Target" }
}
Remove-Item -LiteralPath `$EmptyDir -Recurse -Force

Stop-Transcript | Out-Null
Unregister-ScheduledTask -TaskName '$CleanupTaskName' -Confirm:`$false
Remove-Item -LiteralPath '$CleanupScript' -Force
"@

    try {
        New-Item -ItemType Directory -Path $ToolsDir -Force -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath $CleanupScript -Value $Body -Encoding UTF8 -ErrorAction Stop
        # SYSTEM runs this file, so nobody below Administrator may be able to rewrite it first.
        & icacls.exe "$CleanupScript" /inheritance:r /grant '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' /Q 2>&1 | Out-Null

        # The inbox Windows PowerShell, not $PSHOME, so the task does not depend on whichever host started this run.
        $Exe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $Action = New-ScheduledTaskAction -Execute $Exe -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$CleanupScript`""
        $Trigger = New-ScheduledTaskTrigger -AtStartup
        $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $Settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
        Register-ScheduledTask -TaskName $CleanupTaskName -Trigger $Trigger -Action $Action -Principal $Principal `
            -Settings $Settings -Description 'One-shot cleanup of a stale DISM mount folder left behind by Windows-ISO-Updater. Removes itself after it runs.' `
            -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Write-HostTimestamp "    Could not register the boot-time cleanup task: $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }

    Write-HostTimestamp "    Registered the scheduled task '$CleanupTaskName' to clear it as SYSTEM at the next boot." -ForegroundColor Green
    Write-HostTimestamp "      It strips the reparse point, deletes the orphaned WIMMount registry entry, then takes ownership and deletes the folder, logging to $CleanupLog." -ForegroundColor DarkGray
    return $true
}

# Finds broken mounts that belong to someone else. Neither /Cleanup-Mountpoints nor
# Clear-WindowsCorruptMountPoint can be scoped to a folder, and both release every corrupt mount on the
# machine, so checking first is the only way to keep a recovery here from wrecking another run under a
# different -WorkPath, or somebody's MDT or ADK session. A mount reporting Ok is left out because the
# global cleanups do not touch healthy mounts, and a status that cannot be read counts as at risk.
function Get-ForeignBrokenMount {
    $Root = $WorkRoot.TrimEnd('\')
    try {
        return @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object {
                $_.Path -and
                -not (($_.Path.TrimEnd('\') -ieq $Root) -or ($_.Path -ilike "$Root\*")) -and
                ("$($_.MountStatus)" -ne 'Ok')
            })
    }
    catch { return @() }
}

# Throws away a mount without letting DISM's errors escape. Dismount-WindowsImage raises a terminating
# COMException that -ErrorAction cannot suppress, so every discard has to be wrapped or it fills the
# transcript with stack traces from cleanup paths that already know the mount may be gone. -Escalate then
# walks dism.exe up from a plain discard, to re-attaching a mount abandoned by a dead process (which
# answers the managed call with "The request is not supported"), to dropping the registration outright for
# one that survived a reboot and can no longer be re-attached at all.
function Dismount-ImageDiscard {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Escalate
    )

    try {
        Dismount-WindowsImage -Path $Path -Discard -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        if (-not $Escalate) { return $false }
        Write-HostTimestamp "      Discard failed: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # dism.exe reaches mounts the managed API will not touch, so ask it to discard before re-attaching
    # anything. Re-attaching a mount that did not need it is what turns a dormant mount back into a live one.
    Write-HostTimestamp '      Asking dism.exe to discard it...' -ForegroundColor Yellow
    & dism.exe /English /Unmount-Image "/MountDir:$Path" /Discard 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-HostTimestamp '      Released it.' -ForegroundColor Green
        return $true
    }
    $DiscardCode = $LASTEXITCODE

    Write-HostTimestamp ('      dism.exe could not discard it either (exit code 0x{0:X8}), re-attaching the mount first...' -f $DiscardCode) -ForegroundColor Yellow
    & dism.exe /English /Remount-Image "/MountDir:$Path" 2>&1 | Out-Null
    $RemountCode = $LASTEXITCODE
    if ($RemountCode -eq 0) {
        & dism.exe /English /Unmount-Image "/MountDir:$Path" /Discard 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-HostTimestamp '      Released it.' -ForegroundColor Green
            return $true
        }
        Write-HostTimestamp ('      It re-attached but still would not release (exit code 0x{0:X8}).' -f $LASTEXITCODE) -ForegroundColor Yellow
    }
    else {
        Write-HostTimestamp ('      It cannot be re-attached (exit code 0x{0:X8}), which is what a mount that outlived a reboot looks like.' -f $RemountCode) -ForegroundColor Yellow
    }

    # Nothing can revive this mount, so the registration itself is what has to go.
    $Foreign = @(Get-ForeignBrokenMount)
    if ($Foreign.Count -gt 0) {
        Write-HostTimestamp "      Not running /Cleanup-Mountpoints: it would also release $($Foreign.Count) broken mount(s) outside $WorkRoot." -ForegroundColor Yellow
        foreach ($Other in $Foreign) { Write-HostTimestamp "        $($Other.Path)" -ForegroundColor DarkGray }
        Write-HostTimestamp '        Clear those yourself, or run this build with a -WorkPath nothing else is using.' -ForegroundColor Yellow
        return $false
    }

    Write-HostTimestamp '      Dropping the mount point registration instead...' -ForegroundColor Yellow
    & dism.exe /English /Cleanup-Mountpoints 2>&1 | Out-Null
    $StillMounted = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.TrimEnd('\') -ieq $Path.TrimEnd('\') })
    if ($StillMounted.Count -eq 0) {
        Write-HostTimestamp '      Released it.' -ForegroundColor Green
        return $true
    }

    Write-HostTimestamp '      The mount is still registered with DISM.' -ForegroundColor Yellow
    return $false
}

# Deletes a directory that Administrator rights alone cannot touch. What DISM leaves behind when a mount
# is interrupted is owned by TrustedInstaller and carries the image's own ACLs, so Remove-Item fails with
# "You need permission from TrustedInstaller", and the WinSxS tree inside nests past 260 characters, which
# Windows PowerShell 5.1 cannot address at all. Well-known SIDs are used rather than account names so this
# still works on a non-English Windows.
function Remove-DirectoryForce {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $true }

    $TryRemove = {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        return (-not (Test-Path -LiteralPath $Path))
    }

    if (& $TryRemove) { return $true }

    Write-HostTimestamp "    Leftover files at $Path are locked down by TrustedInstaller, taking ownership of them..." -ForegroundColor Yellow
    & takeown.exe /F "$Path" /A /R /D Y 2>&1 | Out-Null
    & icacls.exe "$Path" /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>&1 | Out-Null
    & attrib.exe -R -S -H "$Path\*" /S /D 2>&1 | Out-Null
    if (& $TryRemove) {
        Write-HostTimestamp '    Removed them.' -ForegroundColor Green
        return $true
    }

    # Mirroring an empty folder over the target is the only thing here that walks paths longer than 260
    # characters, and /B uses backup privileges so whatever ACLs survived takeown stop mattering.
    Write-HostTimestamp '    Paths inside are too long for Remove-Item, emptying the folder with robocopy...' -ForegroundColor Yellow
    $EmptyDir = Join-Path -Path $env:TEMP -ChildPath ('wiso-empty-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $EmptyDir -Force -ErrorAction SilentlyContinue | Out-Null
    & robocopy.exe $EmptyDir $Path /MIR /B /R:0 /W:0 /NFL /NDL /NJH /NJS /NP 2>&1 | Out-Null
    Remove-Item -LiteralPath $EmptyDir -Recurse -Force -ErrorAction SilentlyContinue
    if (& $TryRemove) {
        Write-HostTimestamp '    Removed them.' -ForegroundColor Green
        return $true
    }

    # A handle held by the servicing stack usually goes away on its own a moment later.
    Start-Sleep -Seconds 3
    $DeleteError = $null
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable DeleteError
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-HostTimestamp '    Removed them.' -ForegroundColor Green
        return $true
    }
    if ($DeleteError) {
        Write-HostTimestamp "    It still will not delete: $($DeleteError[0].Exception.Message)" -ForegroundColor Yellow
    }
    return $false
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
        if ($M.Path) { Dismount-ImageDiscard -Path $M.Path -Escalate | Out-Null }
    }

    # Releases mounts whose directory was deleted from under DISM, the only way back from an orphaned mount.
    $ForeignBroken = @(Get-ForeignBrokenMount)
    if ($ForeignBroken.Count -gt 0) {
        Write-HostTimestamp "    Skipping the corrupt mount point cleanup: $($ForeignBroken.Count) broken mount(s) outside $WorkRoot would be released too." -ForegroundColor Yellow
        foreach ($Other in $ForeignBroken) { Write-HostTimestamp "      $($Other.Path)" -ForegroundColor DarkGray }
    }
    else {
        try { Clear-WindowsCorruptMountPoint -ErrorAction SilentlyContinue | Out-Null } catch { }
    }

    # Clearing a corrupt mount point can make a mount that refused to discard discardable, so try once more.
    foreach ($M in (& $FindStale)) {
        if ($M.Path) { Dismount-ImageDiscard -Path $M.Path -Escalate | Out-Null }
    }

    $Stale = & $FindStale
    if ($Stale) {
        $Detail = ($Stale | ForEach-Object { "$(if ($_.ImagePath) { Split-Path $_.ImagePath -Leaf } else { 'image' }) index $($_.ImageIndex)" }) -join ', '
        if (Register-MountCleanupTask -Path $Path) {
            throw "An image is still mounted ($Detail) and nothing this script can do from a running session will release it. Reboot and start the build again - the cleanup task clears it on the way up."
        }
        throw "An image is still mounted ($Detail) and DISM will reject the next mount. Every automatic recovery has already been tried, including 'dism /Cleanup-Mountpoints'. Reboot, then run 'dism /Cleanup-Mountpoints' from an elevated prompt before starting the build again."
    }

    # Only safe once nothing is mounted here - deleting a tracked mount directory is what orphans it.
    if (-not (Remove-DirectoryForce -Path $Path)) {
        if (Register-MountCleanupTask -Path $Path) {
            throw "The mount folder $Path could not be deleted, even after taking ownership. Reboot and start the build again - the cleanup task clears it on the way up."
        }
        throw "The mount folder $Path still holds files from a failed run and could not be deleted, even after taking ownership. Reboot to release the handles, then start the build again."
    }
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
}
#endregion

#region Image servicing
# Pulls the servicing stack update out of a combined SSU+LCU .msu and applies it on its own. Windows rejects
# a cumulative update with 0x800F0823 when the image's stack is older than the update needs, and DISM does
# not always take the stack out of the combined package by itself when servicing offline.
function Add-ServicingStack {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)][string]$StageDir
    )

    $SsuDir = Join-Path -Path $StageDir -ChildPath 'ssu'
    try {
        New-Item -ItemType Directory -Path $SsuDir -Force -ErrorAction Stop | Out-Null

        # Try the usual SSU-*.cab name first, because pulling every cab out unpacks the multi-GB LCU payload
        # as well.
        $Ssu = $null
        foreach ($Pattern in @('-F:*SSU*.cab', '-F:*.cab')) {
            & expand.exe "$PackagePath" $Pattern "$SsuDir" | Out-Null
            $Ssu = Get-ChildItem -LiteralPath $SsuDir -Filter '*.cab' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)ssu|servicingstack' } |
                Sort-Object -Property Length -Descending |
                Select-Object -First 1
            if ($Ssu) { break }
        }
        if (-not $Ssu) {
            Write-HostTimestamp '      No servicing stack package is bundled inside this update, so it cannot be applied on its own.' -ForegroundColor DarkYellow
            return $false
        }

        Write-HostTimestamp "      Applying the bundled servicing stack update first: $($Ssu.Name)" -ForegroundColor DarkYellow
        & dism.exe "/Image:$MountDir" '/Add-Package' "/PackagePath:$($Ssu.FullName)" | Out-Null
        if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3010) {
            Write-HostTimestamp '      Servicing stack updated.' -ForegroundColor Green
            return $true
        }
        Write-HostTimestamp "      The servicing stack update did not apply either (exit code $LASTEXITCODE)." -ForegroundColor DarkYellow
        return $false
    }
    catch {
        Write-HostTimestamp "      Could not extract the servicing stack from the update: $($_.Exception.Message)" -ForegroundColor DarkYellow
        return $false
    }
    finally {
        Remove-Item -LiteralPath $SsuDir -Recurse -Force -ErrorAction SilentlyContinue
    }
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
# One line of the servicing story: which package was tried against which image and how it ended.
function Add-ServicingResult {
    param(
        [string]$Image,
        [string]$Package,
        [string]$Result,
        [string]$Detail
    )
    if (-not $Image) { return }
    $Record = [ordered]@{ Image = $Image; Package = $Package; Result = $Result }
    if ($Detail) { $Record['Detail'] = $Detail }
    $script:TattooServicing.Add($Record)
}

function Add-UpdateGroup {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [Parameter(Mandatory)][object[]]$Group,
        [string]$Label = 'update package',
        [string]$ImageLabel
    )

    if (-not $Group -or $Group.Count -eq 0) { return $true }

    # The default label says nothing the package name does not, so it stays out of the build record.
    $RecordDetail = if ($Label -eq 'update package') { '' } else { $Label }

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
                Add-ServicingResult -Image $ImageLabel -Package (Split-Path -Leaf $Target) -Result 'Applied' -Detail $RecordDetail
                return $true
            }
            if ($Output -match '0x800f081e') {
                Write-HostTimestamp '      Already present / not applicable - skipping.' -ForegroundColor DarkGray
                Add-ServicingResult -Image $ImageLabel -Package (Split-Path -Leaf $Target) -Result 'Skipped' -Detail 'Already present or not applicable (0x800F081E)'
                return $true
            }

            if ($Attempt -lt $MaxAttempts) {
                Write-HostTimestamp "      DISM /Add-Package failed (exit code $ExitCode). Retrying once..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds 5
            }
        }

        # 0x800F0823 is CBS_E_NEW_SERVICING_STACK_REQUIRED, so retrying the same package can never work
        # until the image's servicing stack is brought forward.
        if (($Output -match '0x800f0823') -and (Add-ServicingStack -MountDir $MountDir -PackagePath $Target -StageDir $Stage)) {
            Write-HostTimestamp '      Retrying the update now the servicing stack is current...' -ForegroundColor DarkYellow
            $Output = & dism.exe "/Image:$MountDir" '/Add-Package' "/PackagePath:$Target" 2>&1
            $ExitCode = $LASTEXITCODE
            if ($ExitCode -eq 0 -or $ExitCode -eq 3010) {
                Write-HostTimestamp '      Applied.' -ForegroundColor Green
                Add-ServicingResult -Image $ImageLabel -Package (Split-Path -Leaf $Target) -Result 'Applied' -Detail 'Applied after the servicing stack was brought forward (0x800F0823)'
                return $true
            }
        }

        Write-HostTimestamp "      This package didn't apply (DISM exit code $ExitCode). Details are in C:\Windows\Logs\DISM\dism.log." -ForegroundColor DarkYellow
        Add-ServicingResult -Image $ImageLabel -Package (Split-Path -Leaf $Target) -Result 'Failed' -Detail "DISM /Add-Package returned exit code $ExitCode"
        $Output | Where-Object { $_ -match '(?i)error|0x[0-9a-f]{8}' } | Select-Object -Last 8 | ForEach-Object {
            Write-Host "        $_" -ForegroundColor DarkGray
        }
        # Both failures mention "Unattend.xml", which is a red herring, so the error code decides the advice.
        if ($Output -match '0x800f0823') {
            Write-HostTimestamp '      Tip: 0x800F0823 means the image needs a newer servicing stack than it has, and the one' -ForegroundColor DarkGray
            Write-HostTimestamp '      bundled in this update did not take. Base media several years older than the update is the' -ForegroundColor DarkGray
            Write-HostTimestamp '      usual cause. Try newer media, or apply the standalone SSU for this release to the mounted' -ForegroundColor DarkGray
            Write-HostTimestamp '      image by hand before re-running.' -ForegroundColor DarkGray
        }
        elseif ($Output -match '0x80070228' -or $Output -match '(?i)Unattend\.xml') {
            # A hash mismatch here just means the base image's files don't match their manifests - usually a
            # repacked/UUP ISO rather than a clean Microsoft one. It's informational, not a crash.
            Write-HostTimestamp '      Tip: this is typically the base image, not the update - the install.wim files did not match' -ForegroundColor DarkGray
            Write-HostTimestamp '      their manifests (common with repacked/UUP ISOs). A clean official Microsoft ISO usually resolves it.' -ForegroundColor DarkGray
        }
        return $false
    }
    catch {
        Write-HostTimestamp "      This package couldn't be staged/applied: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Add-ServicingResult -Image $ImageLabel -Package (Split-Path -Leaf $Group[$Group.Count - 1]) -Result 'Failed' -Detail $_.Exception.Message
        return $false
    }
    finally {
        Remove-Item -LiteralPath $Stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Injects the -DriverPath packages into a mounted image. Each .inf is added on its own rather than letting
# DISM recurse the folder, so one driver the image rejects cannot take the whole set down with it.
# Returns $true when every package went in.
function Add-ImageDrivers {
    param(
        [Parameter(Mandatory)][string]$MountDir,
        [AllowEmptyCollection()][object[]]$InfFiles,
        [string]$ImageLabel
    )

    if (-not $InfFiles -or $InfFiles.Count -eq 0) { return $true }

    Write-HostTimestamp "    Injecting $($InfFiles.Count) driver package(s)..."
    $Added  = 0
    $Failed = New-Object System.Collections.Generic.List[string]
    foreach ($Inf in $InfFiles) {
        try {
            Add-WindowsDriver -Path $MountDir -Driver $Inf.FullName -ForceUnsigned:$AllowUnsignedDrivers -ErrorAction Stop | Out-Null
            $Added++
        }
        catch {
            [void]$Failed.Add($Inf.Name)
            Write-HostTimestamp "      $($Inf.Name): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    if ($Failed.Count -eq 0) {
        Write-HostTimestamp "      $Added driver package(s) added." -ForegroundColor Green
        Add-ServicingResult -Image $ImageLabel -Package "$Added driver package(s)" -Result 'Applied' -Detail 'Injected from -DriverPath'
        return $true
    }

    Write-HostTimestamp "      $Added added, $($Failed.Count) rejected. A rejected driver is usually unsigned, built for another architecture, or not a real driver package." -ForegroundColor Yellow
    if (-not $AllowUnsignedDrivers) {
        Write-HostTimestamp '      Pass -AllowUnsignedDrivers if the rejected ones are unsigned and you accept that risk.' -ForegroundColor DarkGray
    }
    $Result = if ($Added -gt 0) { 'Partial' } else { 'Failed' }
    Add-ServicingResult -Image $ImageLabel -Package "$($InfFiles.Count) driver package(s)" -Result $Result -Detail "$Added added, rejected: $(($Failed | Select-Object -First 10) -join ', ')"
    return $false
}

# Deletes servicing residue from a mounted image before it is committed. Windows recreates all of it on
# first boot, and its size varies with how chatty DISM was, which is the main reason two builds from the
# same source ISO and the same update come out different sizes.
function Remove-ImageResidue {
    param([Parameter(Mandatory)][string]$MountDir)

    if (-not $StripImageResidue) {
        Write-HostTimestamp '    Leaving the servicing residue in place (pass -StripImageResidue to remove it).' -ForegroundColor DarkGray
        return
    }

    # Folder contents to clear, keeping the folder itself so nothing has to recreate it.
    $ClearFolders = @(
        'Windows\Logs\CBS'
        'Windows\Logs\DISM'
        'Windows\Logs\DPX'
        'Windows\Logs\MoSetup'
        'Windows\Logs\WindowsUpdate'
        'Windows\Temp'
        'Windows\SoftwareDistribution\Download'
    )
    # Whole items to remove.
    $DeleteItems = @('$WinREAgent')
    # None of these belong in clean Microsoft media, so finding one says the source ISO was built from a
    # captured image rather than downloaded from Microsoft. They are removed either way.
    $Suspect = @(
        'Windows.old'
        '$WINDOWS.~BT'
        '$WINDOWS.~WS'
        '$Recycle.Bin'
        'System Volume Information'
        'pagefile.sys'
        'hiberfil.sys'
        'swapfile.sys'
    )

    $FreedMB = 0
    $Found = New-Object System.Collections.Generic.List[string]
    $Stuck = New-Object System.Collections.Generic.List[string]

    # Get-ChildItem on a file path returns that file, so one expression sizes folders and files alike.
    $Measure = {
        param($Path)
        $Sum = (Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
        if ($Sum) { return ($Sum / 1MB) }
        return 0
    }

    foreach ($Relative in $ClearFolders) {
        $Full = Join-Path -Path $MountDir -ChildPath $Relative
        if (-not (Test-Path -LiteralPath $Full -PathType Container)) { continue }
        foreach ($Child in @(Get-ChildItem -LiteralPath $Full -Force -ErrorAction SilentlyContinue)) {
            # The image's TrustedInstaller permissions can defeat Remove-Item, so only count what really went.
            $ChildMB = & $Measure $Child.FullName
            Remove-Item -LiteralPath $Child.FullName -Recurse -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $Child.FullName)) { $FreedMB += $ChildMB }
        }
    }

    # Only the logs in Panther, because a captured image can keep the answer file that built it there.
    $Panther = Join-Path -Path $MountDir -ChildPath 'Windows\Panther'
    if (Test-Path -LiteralPath $Panther -PathType Container) {
        foreach ($Log in @(Get-ChildItem -LiteralPath $Panther -File -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in '.log', '.etl', '.evtx' })) {
            Remove-Item -LiteralPath $Log.FullName -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path -LiteralPath $Log.FullName)) { $FreedMB += ($Log.Length / 1MB) }
        }
    }

    foreach ($Relative in ($DeleteItems + $Suspect)) {
        $Full = Join-Path -Path $MountDir -ChildPath $Relative
        if (-not (Test-Path -LiteralPath $Full)) { continue }
        $Before = & $Measure $Full
        Remove-Item -LiteralPath $Full -Recurse -Force -ErrorAction SilentlyContinue
        # Windows.old is a full Windows tree, so parts of it can refuse to go and would otherwise be counted.
        $Survived = Test-Path -LiteralPath $Full
        $FreedMB += if ($Survived) { $Before - (& $Measure $Full) } else { $Before }
        if ($Suspect -contains $Relative) {
            $Found.Add($Relative)
            if ($Survived) { $Stuck.Add($Relative) }
        }
    }

    if ($Found.Count -gt 0) {
        Write-HostTimestamp "    Found leftovers that clean Microsoft media never contains: $($Found -join ', ')" -ForegroundColor Yellow
        Write-HostTimestamp '      These come from the source image, not from this build, so it was captured from an installed machine. Exclude them at capture time, or use official Microsoft media.' -ForegroundColor Yellow
    }
    if ($Stuck.Count -gt 0) {
        Write-HostTimestamp "      Could not fully remove $($Stuck -join ', '). The image's permissions denied it, so what is left will ship in the ISO." -ForegroundColor Yellow
    }
    if ($FreedMB -ge 1) {
        Write-HostTimestamp ('    Stripped {0:N0} MB of servicing residue (logs and temp files Windows recreates on first boot).' -f $FreedMB) -ForegroundColor DarkGray
    }

    # Totalled across every image so the tattoo can state what this build removed.
    $script:TattooResidueMB += $FreedMB
    foreach ($Item in $Found) {
        if (-not $script:TattooResidueFound.Contains($Item)) { $script:TattooResidueFound.Add($Item) }
    }
}
#endregion

#region Image inspection and final report
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

# Mounts a WIM read-only just long enough to read its true build/UBR, because the WIM header's SPBuild is
# stale on some Microsoft media and the SOFTWARE hive is the only trustworthy source. Costs a few minutes.
# Returns a version string, or $null if it could not be read.
function Get-WimBuildViaMount {
    param(
        [Parameter(Mandatory)][string]$WimPath,
        [int]$Index = 1
    )

    $Mnt = Join-Path -Path $WorkRoot -ChildPath 'BuildCheck'
    $Build = $null
    try {
        Reset-MountDirectory -Path $Mnt -ImagePath $WimPath
        Mount-WindowsImage -ImagePath $WimPath -Index $Index -Path $Mnt -ReadOnly -ErrorAction Stop | Out-Null
        $Build = Get-MountedImageBuild -MountPath $Mnt
    }
    catch { }
    finally {
        Dismount-ImageDiscard -Path $Mnt | Out-Null
        # Removing a directory DISM still tracks as mounted is what orphans a mount point, so leave it
        # alone if the discard above did not take.
        if (-not (Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.TrimEnd('\') -ieq $Mnt.TrimEnd('\') })) {
            Remove-Item -LiteralPath $Mnt -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $Build
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
            Dismount-ImageDiscard -Path $Mnt | Out-Null
        }
        catch {
            Dismount-ImageDiscard -Path $Mnt | Out-Null
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

#endregion

#region Build tattoo
# The stamp lives on the build machine, which is no help to whoever is holding the ISO a year from now.
# The tattoo is the same story written onto the media itself, so the finished ISO explains itself.

# The parameters this run was started with, rebuilt as a command line. Only what was passed on the command
# line appears, so defaults stay out of it and the answer file's contents are never reproduced here.
function Get-ScriptCommandLine {
    $Arguments = New-Object System.Collections.Generic.List[string]
    $Arguments.Add((Split-Path -Leaf $script:ScriptPath))
    foreach ($Name in @($script:ScriptBoundParameters.Keys)) {
        $Value = $script:ScriptBoundParameters[$Name]
        if ($Value -is [switch]) {
            if ($Value.IsPresent) { $Arguments.Add("-$Name") }
            continue
        }
        $Arguments.Add("-$Name")
        foreach ($Item in @($Value)) { $Arguments.Add("`"$Item`"") }
    }
    return ($Arguments -join ' ')
}

# Renders the record as indented text. Deliberately generic, so a field added to the record shows up in
# the report without this having to know about it.
function Format-TattooText {
    param(
        $Value,
        [int]$Indent = 0
    )

    $Pad = ' ' * ($Indent * 2)
    $Lines = New-Object System.Collections.Generic.List[string]

    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($Key in @($Value.Keys)) {
            $Item = $Value[$Key]
            if ($Item -is [System.Collections.IDictionary]) {
                $Lines.Add("$Pad${Key}:")
                $Lines.AddRange([string[]]@(Format-TattooText -Value $Item -Indent ($Indent + 1)))
                continue
            }
            if ($Item -is [System.Array] -or $Item -is [System.Collections.IList]) {
                $Entries = @($Item)
                if ($Entries.Count -eq 0) { $Lines.Add("$Pad${Key}: (none)"); continue }
                $Lines.Add("$Pad${Key}:")
                foreach ($Entry in $Entries) {
                    if ($Entry -is [System.Collections.IDictionary]) {
                        # Indented one level deeper than the bullet so the rest of the entry lines up under it.
                        $Block = @(Format-TattooText -Value $Entry -Indent ($Indent + 2))
                        if ($Block.Count -gt 0) { $Block[0] = "$Pad  - " + $Block[0].Substring(($Indent + 2) * 2) }
                        $Lines.AddRange([string[]]$Block)
                        $Lines.Add('')
                    }
                    else { $Lines.Add("$Pad  - $Entry") }
                }
                continue
            }
            $Text = if ($null -eq $Item -or "$Item" -eq '') { '(none)' } else { "$Item" }
            $Lines.Add("$Pad${Key}: $Text")
        }
    }
    else {
        $Lines.Add("$Pad$Value")
    }

    return $Lines.ToArray()
}

# Writes the record folder into the extracted media, just before oscdimg packages it. Failing to do so
# must never cost the build, so everything in here is best-effort.
function Write-BuildTattoo {
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Info,
        [string]$FolderName = 'WISO-Build',
        [string]$ScriptSource
    )

    $Folder = Join-Path -Path $MediaRoot -ChildPath $FolderName
    try {
        if (Test-Path -LiteralPath $Folder) { Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop | Out-Null

        $Header = @(
            'Windows ISO Updater - build record'
            ('=' * 60)
            'This folder was added by Windows-ISO-Updater and is not part of the original'
            'Microsoft media. Windows Setup ignores it, and deleting it changes nothing.'
            ''
        )
        Set-Content -LiteralPath (Join-Path $Folder 'build-info.txt') -Value ($Header + @(Format-TattooText -Value $Info)) -Encoding UTF8 -ErrorAction Stop
        Set-Content -LiteralPath (Join-Path $Folder 'build-info.json') -Value (Format-Json -Json ($Info | ConvertTo-Json -Depth 8 -Compress)) -Encoding UTF8 -ErrorAction Stop

        if ($ScriptSource -and (Test-Path -LiteralPath $ScriptSource -PathType Leaf)) {
            Copy-Item -LiteralPath $ScriptSource -Destination (Join-Path $Folder (Split-Path -Leaf $ScriptSource)) -Force -ErrorAction Stop
        }

        $SizeKB = [math]::Round((Get-ChildItem -LiteralPath $Folder -File -Recurse -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum / 1KB, 1)
        Write-HostTimestamp "  Wrote \$FolderName to the media ($SizeKB KB): build-info.txt, build-info.json and a copy of the script." -ForegroundColor Green
        return $true
    }
    catch {
        Write-HostTimestamp "  Could not write the build record onto the media: $($_.Exception.Message). The ISO is unaffected." -ForegroundColor Yellow
        return $false
    }
}
#endregion
#endregion

#region Run header
Write-Host $LineBreak
Write-HostTimestamp "Windows ISO Updater v$ScriptVersion (slipstream latest updates into a new ISO) on $($env:ComputerName)" -ForegroundColor Cyan
Write-Host $LineBreak

#endregion

#region Scheduled task registration (-RegisterScheduledTask / -UnregisterScheduledTask)
# Both of these only touch Task Scheduler and then exit, with nothing downloaded or built.
if ($UnregisterScheduledTask) {
    try {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-HostTimestamp "Scheduled task '$TaskName' removed." -ForegroundColor Green
        }
        else {
            Write-HostTimestamp "No scheduled task named '$TaskName' exists." -ForegroundColor Yellow
        }
    }
    catch {
        Write-HostTimestamp "Could not remove the scheduled task '$TaskName': $($_.Exception.Message)" -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    Stop-Transcript | Out-Null
    exit 0
}

if ($RegisterScheduledTask) {
    try {
        Register-UpdaterScheduledTask
    }
    catch {
        Write-HostTimestamp "Could not register the scheduled task: $($_.Exception.Message)" -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    Write-Host $LineBreak
    Stop-Transcript | Out-Null
    exit 0
}

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

# These two lines describe the download request, so they are misleading once a local ISO exists: it
# decides the architecture and release, not the host or the parameters.
$LocalIsoAvailable = if ($IsoPath) {
    [bool]((Test-Path -LiteralPath $IsoPath -PathType Leaf) -or
        ((Test-Path -LiteralPath $IsoPath -PathType Container) -and (Find-LargestIso -Directory $IsoPath)))
}
else {
    [bool](Find-LargestIso -Directory $DlDir)
}
if (-not $LocalIsoAvailable) {
    Write-HostTimestamp "Architecture   : $($WinInfo.Architecture)"
    if ($Server) { Write-HostTimestamp 'Target         : Windows Server (whatever release the ISO you supply contains)' }
    else { Write-HostTimestamp "Target         : Windows $WindowsVersion ($Release, $Language)" }
    Write-Host $LineBreak
}
Write-Host 'Everything this run writes goes under the working folder:' -ForegroundColor Cyan
Write-Host "  Working folder   : $WorkRoot"
Write-Host "    Extracted media: $ExtractDir"
Write-Host "    DISM mount     : $MountDir"
Write-Host "  Downloads        : $DlDir"
if (-not $IsoPath) { Write-Host '                     (drop your own .iso here and it is used instead of downloading one)' -ForegroundColor DarkGray }
Write-Host "  Logs             : $LogDir"
if (-not $NoStamp) { Write-Host "  Build stamps     : $StampRoot" }
$IsoNameExample = if ($Server) { 'Server2025_StandardGUI_x64_<build>.<UBR>_<date-time>.iso' } else { 'Win11_Multi_x64_<build>.<UBR>_<date-time>.iso' }
Write-Host "  Finished ISO     : $(if ($OutputIsoPath) { $OutputIsoPath } else { Join-Path $FinishedIsoDir $IsoNameExample })"
Write-Host ''
Write-Host '  Nothing outside these folders is changed. -WorkPath moves all of it, and -DownloadPath, -LogPath' -ForegroundColor DarkGray
Write-Host '  and -OutputIsoPath override the individual folders.' -ForegroundColor DarkGray
Write-Host $LineBreak

#endregion

#region One run at a time per work folder
# Everything past this point assumes it owns the mount directories, so a second run sharing a work folder
# would discard the first one's live mount as if it were stale. Keyed on the work folder, so runs pointed
# at different -WorkPath folders are still free to go side by side. The mutex is never released explicitly:
# Windows drops it when the process ends, and a waiter that inherits an abandoned one is the owner anyway.
$WorkKeyBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [System.Text.Encoding]::Unicode.GetBytes($WorkRoot.TrimEnd('\').ToLowerInvariant()))
$WorkKey = ([System.BitConverter]::ToString($WorkKeyBytes) -replace '-', '').Substring(0, 16)
$script:RunMutex = New-Object System.Threading.Mutex($false, "Global\WindowsIsoUpdater_$WorkKey")
$HaveRunMutex = $false
try { $HaveRunMutex = $script:RunMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $HaveRunMutex = $true }
if (-not $HaveRunMutex) {
    Write-HostTimestamp "Another Windows-ISO-Updater run is already using $WorkRoot." -ForegroundColor Red
    Write-HostTimestamp '  Wait for it to finish, or start this one with a different -WorkPath so the two do not share a mount folder.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

#endregion

#region Clean up leftovers from an interrupted run
# Add-UpdateGroup stages each package in its own pkgstage_* folder and deletes it in a finally block, but a
# run that was killed outright never reaches that, leaving several GB behind. Cleared before the free space
# check so the reading reflects what is really available.
$StaleStages = @(Get-ChildItem -LiteralPath $WorkRoot -Directory -Filter 'pkgstage_*' -ErrorAction SilentlyContinue)
if ($StaleStages.Count -gt 0) {
    $StageFreedMB = 0
    $StageRemoved = 0
    foreach ($Stale in $StaleStages) {
        try {
            $StageSizeMB = (Get-ChildItem -LiteralPath $Stale.FullName -File -Recurse -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum / 1MB
            Remove-Item -LiteralPath $Stale.FullName -Recurse -Force -ErrorAction Stop
            $StageRemoved++
            $StageFreedMB += $StageSizeMB
        }
        catch {
            Write-HostTimestamp "  Could not remove the leftover staging folder '$($Stale.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if ($StageRemoved -gt 0) {
        Write-HostTimestamp ('Removed {0} update staging folder(s) left behind by an interrupted run, freeing {1:N0} MB.' -f $StageRemoved, $StageFreedMB) -ForegroundColor DarkGray
        Write-Host $LineBreak
    }
}

# A run killed while an image was mounted leaves the mount folders full of files owned by TrustedInstaller,
# and DISM will not mount into a directory that is not empty. Released here rather than at first use so the
# problem surfaces in seconds instead of after the download and extraction have already run.
$MountsCleared = $false
foreach ($StaleName in @('Mount', 'WinREMount', 'BuildCheck')) {
    $StalePath = Join-Path -Path $WorkRoot -ChildPath $StaleName
    if (-not (Test-Path -LiteralPath $StalePath)) { continue }

    if (-not (Get-ChildItem -LiteralPath $StalePath -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $StalePath -Force -ErrorAction SilentlyContinue
        continue
    }

    Write-HostTimestamp "A previous run left files behind in $StalePath, clearing them..." -ForegroundColor Yellow
    try {
        # Releases any mount DISM still tracks there first, because deleting a tracked mount folder orphans it.
        Reset-MountDirectory -Path $StalePath
        Remove-Item -LiteralPath $StalePath -Force -ErrorAction SilentlyContinue
        Write-HostTimestamp '  Cleared.' -ForegroundColor Green
        $MountsCleared = $true
    }
    catch {
        Write-HostTimestamp "  $($_.Exception.Message)" -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
}
if ($MountsCleared) { Write-Host $LineBreak }

#endregion

#region Disk space check
# DISM mounts and services images inside the working folder, which a network share cannot support.
if (Test-RemotePath -Path $WorkRoot) {
    Write-HostTimestamp "The working folder is not on a local disk: $WorkRoot" -ForegroundColor Red
    Write-HostTimestamp '  A UNC path, a mapped network drive, or a drive letter that does not exist in this session cannot be used to mount and service images. Point -WorkPath at a local drive with plenty of free space.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

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
        if ($CheckOnly) {
            # -CheckOnly builds nothing, so it only needs to say that a build would not fit right now.
            Write-HostTimestamp "Less than $RequiredGB GB is free on the working drive, so a build could not run here as things stand." -ForegroundColor Yellow
        }
        else {
            Write-HostTimestamp "CRITICAL: Less than $RequiredGB GB free on the working drive. Building a patched ISO needs a lot of scratch space. Free up space, choose another drive with -WorkPath, and try again." -ForegroundColor Red
            Stop-Transcript | Out-Null
            exit 1
        }
    }
}
Write-Host $LineBreak

#endregion

#region Validate the output ISO location
# The rest of the build takes hours and oscdimg is the last thing it runs, so a missing folder, a share
# that is not writable, or an ISO still mounted from a previous run has to be caught here instead.
if (-not $ListEditions -and -not $CheckOnly) {
    $OutputDir = if ($OutputIsoPath) { Split-Path -Path $OutputIsoPath -Parent } else { $FinishedIsoDir }
    $OutputProblem = Get-OutputPathProblem -Directory $OutputDir -FilePath $OutputIsoPath
    if ($OutputProblem) {
        Write-HostTimestamp 'The finished ISO could not be written where it is meant to go.' -ForegroundColor Red
        Write-HostTimestamp "  $OutputProblem" -ForegroundColor Red
        Write-HostTimestamp '  Fix the destination or point -OutputIsoPath somewhere else, then run again.' -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    if ($OutputIsoPath) {
        Write-HostTimestamp "Output ISO     : $OutputIsoPath" -ForegroundColor Green
        if ($OutputIsoPath -notmatch '(?i)\.iso$') {
            Write-HostTimestamp '  That name does not end in .iso, so nothing will recognise the file as an image.' -ForegroundColor Yellow
        }
        if (Test-Path -LiteralPath $OutputIsoPath -PathType Leaf) {
            Write-HostTimestamp '  An ISO already exists at that path and will be replaced.' -ForegroundColor Yellow
        }
    }
    else {
        Write-HostTimestamp "Output folder  : $OutputDir" -ForegroundColor Green
    }
    # A mapped drive or a share is writable here yet absent under the scheduled task's logon session.
    if (Test-RemotePath -Path $OutputDir) {
        Write-HostTimestamp '  That is a network location. Drive mappings belong to a logon session, so a scheduled run may not see it. A UNC path is the safer choice.' -ForegroundColor Yellow
    }
    # Only worth saying when the ISO lands somewhere other than the working drive, which was measured above.
    $OutputQualifier = try { Split-Path -Path $OutputDir -Qualifier -ErrorAction SilentlyContinue } catch { $null }
    $WorkQualifier   = try { Split-Path -Path $WorkRoot -Qualifier -ErrorAction SilentlyContinue } catch { $null }
    if ($OutputQualifier -and $OutputQualifier -ne $WorkQualifier) {
        $OutputFreeGB = Get-DriveFreeGB -Path $OutputDir
        if ($null -ne $OutputFreeGB -and $OutputFreeGB -lt 12) {
            Write-HostTimestamp "  Only $OutputFreeGB GB is free there, and a finished ISO is usually 5 to 8 GB." -ForegroundColor Yellow
        }
    }
    Write-Host $LineBreak
}

#endregion

#region Validate the unattended answer file
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
    # Hashed for the build stamp: editing the answer file in place has to force a rebuild even though its
    # path never changed.
    $script:UnattendHash = Get-TextSha256 -Text $UnattendText
    Write-HostTimestamp "Answer file    : $ResolvedUnattend" -ForegroundColor Green
    if ($UnattendDoc.DocumentElement.Name -ne 'unattend') {
        Write-HostTimestamp "  Warning: the root element is <$($UnattendDoc.DocumentElement.Name)>, not <unattend>. Windows Setup will ignore this file." -ForegroundColor Yellow
    }
    if ($UnattendText -match '(?i)<(Password|AdministratorPassword|ProductKey)\b') {
        Write-HostTimestamp '  NOTE: this answer file contains password/product key elements. Windows stores these in plain text or base64, and the finished ISO is not encrypted - anyone who can read the ISO can recover them.' -ForegroundColor Yellow
    }
    Write-Host $LineBreak
}

#endregion

#region Validate the driver folder
$ResolvedDriverPath = $null
if ($DriverPath) {
    if (-not (Test-Path -LiteralPath $DriverPath -PathType Container)) {
        Write-HostTimestamp "The driver folder '$DriverPath' does not exist. Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $ResolvedDriverPath = (Resolve-Path -LiteralPath $DriverPath).Path
    $script:DriverInfFiles = @(Get-ChildItem -LiteralPath $ResolvedDriverPath -Filter '*.inf' -File -Recurse -Force -ErrorAction SilentlyContinue |
            Sort-Object -Property FullName)
    if ($script:DriverInfFiles.Count -eq 0) {
        Write-HostTimestamp "No .inf files were found anywhere under '$ResolvedDriverPath'. Extract the vendor's driver package first - an .exe or .msi installer cannot be injected into an image." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    # Hashed for the build stamp: dropping a newer driver in has to force a rebuild even though the path
    # never changed.
    $script:DriverHash = Get-FolderContentHash -Records @(Get-FolderFileRecords -Path $ResolvedDriverPath)
    $DriverSizeMB = [math]::Round((Get-ChildItem -LiteralPath $ResolvedDriverPath -File -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum / 1MB, 1)
    Write-HostTimestamp "Drivers        : $($script:DriverInfFiles.Count) .inf package(s) in $ResolvedDriverPath ($DriverSizeMB MB)" -ForegroundColor Green
    if ($AllowUnsignedDrivers) {
        Write-HostTimestamp '  -AllowUnsignedDrivers is set, so DISM will accept drivers the image does not trust. 64-bit Windows still refuses to load an unsigned driver at boot unless test signing is on.' -ForegroundColor Yellow
    }
    # WinPE runs entirely from a RAM disk, so a large driver set in boot.wim can leave a machine unable to
    # start Setup at all.
    if ($DriverSizeMB -gt 500) {
        Write-HostTimestamp "  That is a large set to add to boot.wim, which Windows Setup loads into memory. Consider narrowing it to the storage and network drivers Setup actually needs." -ForegroundColor Yellow
    }
    Write-Host $LineBreak
}

#endregion

#region Validate the extra files folder
$ResolvedExtraFiles = $null
if ($ExtraFilesPath) {
    if (-not (Test-Path -LiteralPath $ExtraFilesPath -PathType Container)) {
        Write-HostTimestamp "The extra files folder '$ExtraFilesPath' does not exist. Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $ResolvedExtraFiles = (Resolve-Path -LiteralPath $ExtraFilesPath).Path
    # Hashed and listed here rather than during the copy, so the run is priced and the rebuild decision is
    # made before anything is extracted.
    $script:ExtraFileRecords = @(Get-FolderFileRecords -Path $ResolvedExtraFiles)
    if ($script:ExtraFileRecords.Count -eq 0) {
        Write-HostTimestamp "The extra files folder '$ResolvedExtraFiles' is empty. Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    $script:ExtraFilesHash = Get-FolderContentHash -Records $script:ExtraFileRecords
    $ExtraSizeMB = [math]::Round((($script:ExtraFileRecords | Measure-Object -Property SizeKB -Sum).Sum) / 1024, 1)
    Write-HostTimestamp "Extra files    : $($script:ExtraFileRecords.Count) file(s) in $ResolvedExtraFiles ($ExtraSizeMB MB), copied to the root of the ISO" -ForegroundColor Green
    Write-Host $LineBreak
}

#endregion

#region Interactive confirmation
if (-not $Unattended -and -not $SkipInteractive -and -not $ListEditions -and -not $CheckOnly) {
    Write-Host "This tool builds an updated Windows installation ISO. It will:"
    if ($IsoPath) {
        Write-Host "  - Use the ISO you provided: $IsoPath"
    }
    elseif ($Server) {
        Write-Host "  - Use the Windows Server ISO it finds in the download folder: $DlDir"
        Write-Host "      NOTE: Server media cannot be downloaded automatically, so drop the ISO in that folder" -ForegroundColor Yellow
        Write-Host "            or re-run with -IsoPath." -ForegroundColor Yellow
    }
    elseif ($UseFido) {
        Write-Host "  - Download the matching official Windows $WindowsVersion ISO from Microsoft (~8 GB)"
        Write-Host "      TIP: Microsoft can rate-limit/block repeated ISO downloads. The script retries, and can" -ForegroundColor Yellow
        Write-Host "           then offer Microsoft's Media Creation Tool instead. To skip all that, download the" -ForegroundColor Yellow
        Write-Host "           ISO yourself and re-run with -IsoPath." -ForegroundColor Yellow
    }
    elseif ($UseMct) {
        Write-Host "  - Open Microsoft's Media Creation Tool so you can download the ISO with it (~8 GB)"
        Write-Host "      NOTE: MCT has no headless mode, so you click through its last few pages and save the" -ForegroundColor Yellow
        Write-Host "            ISO into the download folder. The script waits, then picks it up." -ForegroundColor Yellow
    }
    else {
        Write-Host "  - Use the ISO it finds in the download folder: $DlDir"
        Write-Host "      NOTE: no ISO is downloaded automatically. Drop one into that folder or re-run with" -ForegroundColor Yellow
        Write-Host "            -IsoPath, or add -UseFido to have the script fetch one from Microsoft." -ForegroundColor Yellow
    }
    Write-Host "  - Extract it to $ExtractDir"
    if ($KeepEditions -and $KeepEditions.Count -gt 0) {
        Write-Host "  - Keep ONLY these editions in the final ISO (remove the rest): $($KeepEditions -join ', ')" -ForegroundColor Yellow
    }
    elseif ($KeepAllEditions) {
        Write-Host "  - Keep ALL editions in the final ISO (-KeepAllEditions)"
    }
    else {
        $EditionRule = if ($Server) { 'the most upgradeable edition (Standard over Datacenter, and the Desktop Experience over Server Core)' } else { 'Enterprise, Pro and Home, whichever of them this media carries' }
        Write-Host "  - Keep ONLY $EditionRule to speed up the build. Use -KeepAllEditions to keep them all" -ForegroundColor Yellow
    }
    if (-not $SkipUpdates) {
        if ($UpdatePath) {
            Write-Host "  - Integrate the update packages found in: $UpdatePath"
        }
        else {
            Write-Host "  - Download the latest cumulative update(s)$(if (-not $SkipDotNet) { ' and the latest .NET cumulative update' }) from the Microsoft Update Catalog"
            Write-Host "      (the cumulative update is skipped entirely if the image already has that build)" -ForegroundColor DarkGray
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
    if ($ResolvedDriverPath) {
        Write-Host "  - Inject $($script:DriverInfFiles.Count) driver package(s) from $ResolvedDriverPath into every serviced edition and into boot.wim index 2 (Windows Setup)" -ForegroundColor Yellow
    }
    if ($ResolvedUnattend) {
        Write-Host "  - Place your answer file on the media as autounattend.xml, so Setup runs unattended: $ResolvedUnattend" -ForegroundColor Yellow
    }
    if ($ResolvedExtraFiles) {
        Write-Host "  - Copy the contents of $ResolvedExtraFiles onto the root of the ISO, replacing anything the media already had at the same path" -ForegroundColor Yellow
    }
    Write-Host "  - Recompile a new bootable ISO with oscdimg"
    if (-not $NoStamp) {
        Write-Host "  - Record a stamp of the finished build in $StampRoot, so a later run can tell that nothing has changed" -ForegroundColor DarkGray
    }
    if ($AutoClean) {
        Write-Host "  - DELETE the update packages earlier builds downloaded, and every generated ISO except the newest $KeepIsoCount (-AutoClean)" -ForegroundColor Yellow
    }
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

#endregion

#region Locate oscdimg early so we fail fast if the ISO cannot be recompiled (not needed for -ListEditions)
$Oscdimg = $null
if (-not $ListEditions -and -not $CheckOnly) {
    Invoke-Task -Description 'Locating oscdimg.exe (Windows ADK Deployment Tools)...' -ScriptBlock {
        $script:Oscdimg = Find-Oscdimg
        if ($script:Oscdimg) {
            Write-HostTimestamp "  Found oscdimg: $($script:Oscdimg)" -ForegroundColor Green
        }
        else {
            # Grab the single ~150 KB executable straight from Microsoft's symbol server first, and only
            # fall back to the full ADK install (which is hundreds of MB) if that fails.
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

#endregion

#region Obtain the ISO
$ResolvedIso = $null
if ($IsoPath) {
    if (Test-Path -LiteralPath $IsoPath -PathType Container) {
        $FolderIso = Find-LargestIso -Directory $IsoPath
        if (-not $FolderIso) {
            Write-HostTimestamp "-IsoPath '$IsoPath' is a folder, but it holds no .iso larger than 3 GB. The search is not recursive, so an ISO in a subfolder is not found. Cannot continue." -ForegroundColor Red
            Stop-Transcript | Out-Null
            exit 1
        }
        $ResolvedIso = $FolderIso.FullName
        Write-HostTimestamp "Using the largest ISO in '$IsoPath': $ResolvedIso ($([math]::Round($FolderIso.Length / 1GB, 2)) GB)" -ForegroundColor Green
    }
    elseif (Test-Path -LiteralPath $IsoPath -PathType Leaf) {
        $ResolvedIso = (Resolve-Path -LiteralPath $IsoPath).Path
        Write-HostTimestamp "Using the provided ISO: $ResolvedIso" -ForegroundColor Green
    }
    else {
        Write-HostTimestamp "The ISO path '$IsoPath' does not exist. Cannot continue." -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }

    # If the ISO sits on a cloud-synced or network path, copy it to the local download folder first.
    # Mounting and reading a placeholder or an SMB share during the long extraction is slow and unreliable,
    # while a local copy is not, and Mount-DiskImage wants a local file anyway. -CheckOnly only ever reads
    # the file to hash it, so it is not worth moving gigabytes for.
    $IsoIsCloud = ($ResolvedIso -match $CloudPattern -or $ResolvedIso -match '(?i)OneDrive')
    $IsoIsRemote = Test-RemotePath -Path $ResolvedIso
    $DlDirIsCloud = ($DlDir -match $CloudPattern -or $DlDir -match '(?i)OneDrive')
    if (($IsoIsCloud -or $IsoIsRemote) -and -not $DlDirIsCloud -and -not (Test-RemotePath -Path $DlDir) -and -not $CheckOnly) {
        $RemoteKind = if ($IsoIsRemote) { 'a network path' } else { 'a cloud-synced path' }
        $LocalIso = Join-Path -Path $DlDir -ChildPath (Split-Path -Leaf $ResolvedIso)
        $SourceLen = (Get-Item -LiteralPath $ResolvedIso).Length
        if ((Test-Path -LiteralPath $LocalIso) -and ((Get-Item -LiteralPath $LocalIso).Length -eq $SourceLen)) {
            Write-HostTimestamp "  A local copy already exists - using it: $LocalIso" -ForegroundColor Green
            $ResolvedIso = $LocalIso
        }
        else {
            try {
                Invoke-Task -Description "The ISO is on $RemoteKind, so it is copied to a local disk first ($([math]::Round($SourceLen / 1GB, 2)) GB): $LocalIso ..." -ScriptBlock {
                    Copy-Item -LiteralPath $ResolvedIso -Destination $LocalIso -Force -ErrorAction Stop
                    Write-HostTimestamp '  Copy complete.' -ForegroundColor Green
                }
                $ResolvedIso = $LocalIso
            }
            catch {
                Write-HostTimestamp "  Could not copy the ISO locally ($($_.Exception.Message)). Proceeding from $RemoteKind - this may be slow or fail." -ForegroundColor Yellow
            }
        }
    }
}
else {
    # Reuse an already-downloaded ISO in the download folder if present, otherwise resolve + download one.
    $ExistingIso = Find-LargestIso -Directory $DlDir
    if ($ExistingIso) {
        $ResolvedIso = $ExistingIso.FullName
        Write-HostTimestamp "An ISO is already downloaded - reusing it: $ResolvedIso ($([math]::Round($ExistingIso.Length / 1GB, 2)) GB)" -ForegroundColor Green
    }
    else {
        # Neither Fido nor the Media Creation Tool offers Windows Server media, so -Server has nowhere to
        # download from and the run cannot go any further without an ISO from the user.
        if ($Server) {
            Write-HostTimestamp 'No Windows Server ISO was found, and Server media cannot be downloaded automatically (neither Fido nor the Media Creation Tool serves it).' -ForegroundColor Red
            Write-HostTimestamp '  Get the ISO from the Microsoft Evaluation Center, your Volume Licensing Service Center, or a Visual Studio subscription, then re-run with -IsoPath "C:\path\to\Server.iso"' -ForegroundColor Yellow
            Write-HostTimestamp "  or drop the .iso into the download folder and re-run - it is picked up automatically: $DlDir" -ForegroundColor Yellow
            Stop-Transcript | Out-Null
            exit 1
        }
        # -CheckOnly answers a question, so it never spends 8 GB of bandwidth to do it.
        if ($CheckOnly) {
            Write-HostTimestamp 'No ISO is available locally, so there is nothing to compare against - a build is needed.' -ForegroundColor Yellow
            Stop-Transcript | Out-Null
            exit 10
        }
        # Fido is opt-in, so without -UseFido this lands on the same fallbacks a blocked link request
        # would: the Media Creation Tool, or instructions for supplying the ISO by hand.
        if ($UseMct) {
            $ResolvedIso = Get-IsoViaMct -Version $WindowsVersion -Language $Language -Architecture $WinInfo.Architecture -DownloadDir $DlDir
            if (-not $ResolvedIso) {
                Write-HostTimestamp 'No ISO was produced with the Media Creation Tool. Cannot continue.' -ForegroundColor Red
                Stop-Transcript | Out-Null
                exit 1
            }
        }
        else {
            if ($UseFido) {
                Invoke-Task -Description 'Obtaining the Windows ISO download link from Microsoft...' -ScriptBlock {
                    $script:IsoUrl = Get-WindowsIsoUrl -Version $WindowsVersion -Release $Release -Language $Language -Architecture $WinInfo.Architecture
                }
            }
            else {
                Write-HostTimestamp 'No ISO was supplied or found in the download folder, and nothing is downloaded automatically unless you ask for it.' -ForegroundColor Yellow
                Write-HostTimestamp '  Add -UseFido to have the script fetch the ISO from Microsoft, or -UseMct to get it with the Media Creation Tool.' -ForegroundColor Yellow
            }
            if (-not $script:IsoUrl) {
                if ($UseFido) {
                    Write-HostTimestamp 'Could not obtain a download link. Microsoft may be rate-limiting/blocking your IP for repeated ISO requests.' -ForegroundColor Yellow
                }

                # The Media Creation Tool uses different Microsoft endpoints, so it usually still works when
                # the download-link API is blocked - but it needs someone to click through its wizard.
                $CanPrompt = -not ($Unattended -or $SkipInteractive)
                if ($CanPrompt) {
                    Write-Host ''
                    $Answer = Read-Host "Microsoft's Media Creation Tool uses different servers and can fetch the ISO instead. Open it now? (Y/N)"
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

#endregion

#region List editions and exit (-ListEditions)
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

#endregion

#region Has anything actually changed? (build stamp check)
# A full build is an hour or more of disk and CPU, so before any of it starts this run is compared with
# the stamp the last successful build left behind: the source ISO's hash, the build-affecting parameters,
# and the newest packages the Microsoft Update Catalog is offering. If all of those still match and last
# run's ISO is still on disk, there is nothing to gain from doing it again.
$script:PreviousStamp      = $null
$script:StampSourceHash    = $null
$script:ExpectedUpdateSet  = $null
$script:ExpectedUpdateFor  = $null
$script:StampUpdateFiles   = @()
if (-not $NoStamp) {
    Invoke-Task -Description 'Checking the build stamp to see whether anything has changed...' -ScriptBlock {
        $script:PreviousStamp = Read-BuildStamp
        $script:StampSourceHash = Get-SourceIsoHash -Path $ResolvedIso -Stamp $script:PreviousStamp

        # The catalog queries need the feature update and architecture of the image, and reading those
        # means extracting the ISO - the very thing we are trying to avoid. The last stamp already knows
        # them, and they cannot change while the source ISO's hash stays the same.
        if ($script:PreviousStamp -and $script:PreviousStamp.Image) {
            $StampFeature = "$($script:PreviousStamp.Image.FeatureUpdate)"
            $StampArch    = "$($script:PreviousStamp.Image.CatalogArch)"
            $script:ExpectedUpdateSet = Get-ExpectedUpdateSet -FeatureName $StampFeature -CatalogArch $StampArch
            $script:ExpectedUpdateFor = "$StampFeature|$StampArch"

            # Says out loud that the catalog really was queried - a run that finishes in a second
            # otherwise looks like it only compared local files and never asked Microsoft anything.
            if ($script:ExpectedUpdateSet -and -not $SkipUpdates -and -not $UpdatePath) {
                $Listed = @($script:ExpectedUpdateSet | ForEach-Object { $_ -replace '^(\w+)=(.+)@(.+)$', '$1 $2 (published $3)' })
                Write-HostTimestamp "  The Microsoft Update Catalog was checked for $(Get-CatalogProductQuery -FeatureUpdate $StampFeature) $StampArch, newest available:" -ForegroundColor DarkGray
                foreach ($Item in $Listed) { Write-HostTimestamp "    $Item" -ForegroundColor DarkGray }
            }
        }

        $script:StampDecision = Test-RebuildNeeded -Stamp $script:PreviousStamp -SourceHash $script:StampSourceHash `
            -ParameterSet (Get-BuildParameterSet) -ExpectedUpdates $script:ExpectedUpdateSet
        foreach ($Reason in $script:StampDecision.Reasons) { Write-HostTimestamp "  - $Reason" }
        if (-not $script:StampDecision.Rebuild) { Write-HostTimestamp '  Everything matches the last build.' -ForegroundColor Green }
    }

    if ($CheckOnly) {
        if ($script:StampDecision.Rebuild) {
            Write-HostTimestamp 'A rebuild is needed (exit code 10).' -ForegroundColor Yellow
            Stop-Transcript | Out-Null
            exit 10
        }
        Write-HostTimestamp 'Nothing has changed, so no rebuild is needed (exit code 0).' -ForegroundColor Green
        Stop-Transcript | Out-Null
        exit 0
    }

    if (-not $script:StampDecision.Rebuild) {
        if ($Force) {
            Write-HostTimestamp 'Nothing has changed since the last build, but -Force was specified - building anyway.' -ForegroundColor Yellow
        }
        else {
            Write-HostTimestamp 'Nothing has changed since the last build, so this run has nothing to do.' -ForegroundColor Green
            if ($script:PreviousStamp -and $script:PreviousStamp.Output) {
                Write-HostTimestamp "The ISO from that build is still current: $($script:PreviousStamp.Output.Path)" -ForegroundColor Green
            }
            Write-HostTimestamp 'Use -Force to build anyway.' -ForegroundColor DarkGray
            if ($AutoClean) {
                Invoke-Task -Description 'Cleaning up old downloads and ISOs (-AutoClean)...' -ScriptBlock {
                    Invoke-AutoClean -CurrentStamp $script:PreviousStamp -History (Get-BuildStampHistory) -KeepIsoCount $KeepIsoCount -Protected @($ResolvedIso)
                }
            }
            Write-Host $LineBreak
            Stop-Transcript | Out-Null
            exit 0
        }
    }
    Write-Host $LineBreak
}
elseif ($CheckOnly) {
    Write-HostTimestamp '-CheckOnly needs the build stamps to compare against, but -NoStamp turned them off. Assuming a rebuild is needed (exit code 10).' -ForegroundColor Yellow
    Stop-Transcript | Out-Null
    exit 10
}

#endregion

#region Extract the ISO to the working folder
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
        # robocopy exit codes 0-7 indicate success, while 8+ indicates a real failure.
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

# The copied wim files inherit the read-only attribute from the optical media, so clear it to let DISM
# mount and commit changes.
Get-ChildItem -Path (Join-Path $ExtractDir 'sources') -Filter '*.wim' -File -ErrorAction SilentlyContinue |
    ForEach-Object { try { Set-ItemProperty -LiteralPath $_.FullName -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue } catch { } }

$InstallWimExtracted = Join-Path $ExtractDir 'sources\install.wim'
$InstallEsdExtracted = Join-Path $ExtractDir 'sources\install.esd'
$BootWim = Join-Path $ExtractDir 'sources\boot.wim'

# If the media ships install.esd (compressed), convert it to an editable install.wim so DISM can service
# it. Servicing is done against a WIM, and the ESD is a delivery-only format. Only the editions that will
# survive into the final ISO are exported - each one costs several minutes, so exporting the rest just to
# delete them later is wasted time.
$script:EsdPreTrimmed = $false
# The install.wim that gets built here holds only the kept editions, so the ones the source media shipped
# are recorded before the export or nothing downstream can report them.
$script:SourceMediaEditions = @()
$script:SourceMediaDropped = @()
if (-not (Test-Path -LiteralPath $InstallWimExtracted) -and (Test-Path -LiteralPath $InstallEsdExtracted)) {
    Invoke-Task -Description 'The media uses install.esd - converting it to an editable install.wim...' -ScriptBlock {
        $Images = @(Get-WindowsImage -ImagePath $InstallEsdExtracted -ErrorAction Stop)
        $script:SourceMediaEditions = @($Images | ForEach-Object { "[$($_.ImageIndex)] $($_.ImageName)" })
        $Wanted = @($Images.ImageIndex)
        if ($KeepEditions -and $KeepEditions.Count -gt 0) {
            $EsdUnmatched = $null
            $Resolved = @(Resolve-EditionIndexes -Images $Images -Tokens $KeepEditions -Unmatched ([ref]$EsdUnmatched))
            # Anything unmatched is reported (and aborts the run) by the edition resolution further down.
            if ($Resolved.Count -gt 0 -and -not $EsdUnmatched) { $Wanted = $Resolved }
        }
        elseif (-not $KeepAllEditions -and $Images.Count -gt 1) {
            $Wanted = @(Select-DefaultEditions -Images $Images -ServerMedia:$Server)
        }

        $Skipped = @($Images | Where-Object { $Wanted -notcontains [int]$_.ImageIndex })
        if ($Skipped.Count -gt 0) {
            Write-HostTimestamp "  Not exporting $($Skipped.Count) edition(s) that would only be removed again: $(($Skipped.ImageName) -join ', ')" -ForegroundColor Yellow
            $script:EsdPreTrimmed = $true
            $script:SourceMediaDropped = @($Skipped | ForEach-Object { "$($_.ImageName)" })
        }
        foreach ($Want in $Wanted) {
            $Img = $Images | Where-Object { [int]$_.ImageIndex -eq [int]$Want } | Select-Object -First 1
            if (-not $Img) { continue }
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

#endregion

#region Determine the feature update / architecture from the image (for catalog searches)
$ImageInfo = $null
try { $ImageInfo = Get-WindowsImage -ImagePath $InstallWimExtracted -Index 1 -ErrorAction Stop } catch { }
$ImageBuild = 0
if ($ImageInfo -and $ImageInfo.Version -match '^\d+\.\d+\.(\d+)') { $ImageBuild = [int]$Matches[1] }
# The WIM header carries the UBR as the "service pack build", so the image's exact patch level is known
# without mounting anything.
$ImageUbr = if ($ImageInfo -and $null -ne $ImageInfo.SPBuild) { [int]$ImageInfo.SPBuild } else { 0 }
$FeatureName = if ($ImageBuild) { Get-FeatureUpdateName -Build $ImageBuild } else { $null }
$ImageArch = switch ($ImageInfo.Architecture) { 0 { 'x86' } 9 { 'x64' } 12 { 'arm64' } default { $WinInfo.Architecture } }
$CatalogArch = switch ($ImageArch) { 'x64' { 'x64' } 'arm64' { 'ARM64' } 'x86' { 'x86' } default { 'x64' } }

# Version is usually already 4-part (10.0.26200.9168), but is 3-part on some media, so only add the UBR
# when it is missing.
$ImageVersionText = "$($ImageInfo.Version)"
if ($ImageUbr -and $ImageVersionText -match '^\d+\.\d+\.\d+$') { $ImageVersionText = "$ImageVersionText.$ImageUbr" }

Write-HostTimestamp "Image build    : $ImageVersionText$(if ($FeatureName) { " ($FeatureName)" })"
Write-HostTimestamp "Image arch     : $ImageArch"

# -Server picks an entirely different family of catalog queries, so a mismatch would fetch an update that
# DISM then refuses to apply. Stop now rather than an hour into the run. EditionId is not localised, so
# this holds on non-English media too.
$ImageIsServer = "$($ImageInfo.ImageName) $($ImageInfo.EditionId)" -match '(?i)server'
if ($ImageIsServer -and -not $Server) {
    Write-HostTimestamp "This is Windows Server media, but -Server was not passed: $($ImageInfo.ImageName) (edition '$($ImageInfo.EditionId)')." -ForegroundColor Red
    Write-HostTimestamp '  Client updates would be downloaded and DISM would refuse to apply them, so this run stops here. Re-run with -Server.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
elseif ($Server -and $ImageInfo -and -not $ImageIsServer) {
    Write-HostTimestamp "-Server was passed, but this is client media, not Windows Server: $($ImageInfo.ImageName) (edition '$($ImageInfo.EditionId)')." -ForegroundColor Red
    Write-HostTimestamp '  Server updates would be downloaded and DISM would refuse to apply them, so this run stops here. Re-run without -Server, or point -IsoPath at Windows Server media.' -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}

# DISM on a Windows 10 or later host cannot service a Vista, 7 or 8 era image, and Microsoft never
# published cumulative updates for those releases either, so all that is possible on media that old is a
# straight repack.
if ($ImageBuild -gt 0 -and $ImageBuild -lt 10240) {
    $WillService = (-not $SkipUpdates) -or $DriverPath
    Write-HostTimestamp "This image is build $ImageBuild, older than Windows 10 and Windows Server 2016 (build 10240)." -ForegroundColor $(if ($WillService) { 'Red' } else { 'Yellow' })
    if ($WillService) {
        Write-HostTimestamp '  DISM on this host cannot service an image that old, and the Microsoft Update Catalog has no cumulative update for it, so this run stops here.' -ForegroundColor Red
        Write-HostTimestamp '  Re-run with -SkipUpdates and without -DriverPath to repack the media unchanged, which still applies -UnattendPath, -ExtraFilesPath and the new volume label.' -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit 1
    }
    Write-HostTimestamp '  Nothing will be serviced, so no image is mounted and the media is only repacked.' -ForegroundColor Yellow
}
Write-Host $LineBreak

# The stamp check ran against the feature update/architecture recorded last time (or nothing at all on a
# first run). Now that the image itself has been read, the list of updates recorded in the new stamp is
# refreshed so the next run compares against the right thing.
if (-not $NoStamp -and $script:ExpectedUpdateFor -ne "$FeatureName|$CatalogArch") {
    Invoke-Task -Description 'Checking which updates the Microsoft Update Catalog is offering for this image...' -ScriptBlock {
        $script:ExpectedUpdateSet = Get-ExpectedUpdateSet -FeatureName $FeatureName -CatalogArch $CatalogArch
        $script:ExpectedUpdateFor = "$FeatureName|$CatalogArch"
        if ($script:ExpectedUpdateSet) { Write-HostTimestamp "  $($script:ExpectedUpdateSet -join ', ')" -ForegroundColor DarkGray }
    }
}

#endregion

#region Gather the update packages to integrate
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
    # Dropping the version token narrows a client query to the right product family, but the server one
    # becomes "Microsoft server operating system", which matches every release and would hand back the
    # newest Server LCU no matter how old this media is.
    if ($Server -and -not $FeatureName) {
        Write-HostTimestamp "Build $ImageBuild is not a Windows Server release this script recognises, so there is no catalog query that can identify it." -ForegroundColor Red
        Write-HostTimestamp '  Searching on the product name alone would return an update for a different Server release, which DISM would refuse to apply, so this run stops here.' -ForegroundColor Red
        Write-HostTimestamp '  Supply the packages yourself with -UpdatePath, or use -SkipUpdates to repack the media unchanged.' -ForegroundColor Yellow
        Stop-Transcript | Out-Null
        exit 1
    }
    if (-not $FeatureName) {
        Write-HostTimestamp 'Could not determine the feature-update name from the image, so the catalog search may be less precise.' -ForegroundColor Yellow
    }

    Invoke-Task -Description 'Downloading the latest cumulative update from the Microsoft Update Catalog...' -ScriptBlock {
        # The monthly LCU is titled e.g. "2026-07 Cumulative Update for Windows 11 Version 24H2 for
        # x64-based Systems (KB...)" and classified as a Security Update. Restrict the match to real
        # cumulative updates and exclude the .NET / Dynamic Update entries the same query returns.
        $Query = "Cumulative Update for $(Get-CatalogProductQuery -FeatureUpdate $FeatureName) for $CatalogArch-based Systems"
        $Include = '(?i)cumulative update for (windows|microsoft server operating system)'
        $Exclude = '(?i)\.net|dynamic update'
        $script:LcuUpToDate = $null
        $script:Lcu = Get-LatestCatalogPackage -Query $Query -DownloadDir $DlDir -TitleInclude $Include -TitleExclude $Exclude -CurrentBuild $ImageBuild -CurrentUbr $ImageUbr -VerifyWimPath $InstallWimExtracted -AlreadyCurrent ([ref]$script:LcuUpToDate)
        if (-not $script:Lcu -and -not $script:LcuUpToDate -and -not $Server) {
            # Retry with a looser query (some releases omit the "Version xxHx" token in the title). Server
            # media is excluded because its product name without the version matches every Server release.
            $Query2 = "Cumulative Update for $(Get-CatalogProductQuery) for $CatalogArch-based Systems"
            Write-HostTimestamp "  Retrying with a broader query: $Query2" -ForegroundColor Yellow
            $script:Lcu = Get-LatestCatalogPackage -Query $Query2 -DownloadDir $DlDir -TitleInclude $Include -TitleExclude $Exclude -CurrentBuild $ImageBuild -CurrentUbr $ImageUbr -VerifyWimPath $InstallWimExtracted -AlreadyCurrent ([ref]$script:LcuUpToDate)
        }
    }
    if ($script:Lcu) { $UpdateGroups.Add(@($script:Lcu)) }
    elseif ($script:LcuUpToDate) {
        # Nothing will change the OS build now, so reuse the build already confirmed by the check.
        if (-not $script:FinalBuildString) { $script:FinalBuildString = $script:LcuUpToDate }
        Write-HostTimestamp "The image is already fully patched ($script:LcuUpToDate), so no cumulative update is needed." -ForegroundColor Green
    }
    else {
        Write-HostTimestamp 'Could not obtain a cumulative update from the catalog. You can supply one with -UpdatePath, or use -SkipUpdates to just recompile the ISO.' -ForegroundColor Red
        Stop-Transcript | Out-Null
        exit 1
    }
    Write-Host $LineBreak

    if (-not $SkipDotNet) {
        Invoke-Task -Description 'Downloading the latest .NET cumulative update from the Microsoft Update Catalog...' -ScriptBlock {
            $Query = "Cumulative Update for .NET Framework $(Get-CatalogProductQuery -FeatureUpdate $FeatureName) for $CatalogArch"
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
            $script:SetupDu = Get-LatestCatalogPackage -Query "Setup Dynamic Update $(Get-CatalogProductQuery -FeatureUpdate $FeatureName) $CatalogArch" -DownloadDir $DlDir -TitleInclude '(?i)setup dynamic update'
        }
        if (-not $script:SetupDu) {
            Write-HostTimestamp '  No Setup Dynamic Update was found. The media Setup files will only be refreshed from boot.wim, which can make Windows Setup fail on the finished ISO.' -ForegroundColor Yellow
            if ($Server) {
                Write-HostTimestamp '  Microsoft only publishes one for Server 2025 and newer, so this is expected on older Server media.' -ForegroundColor DarkGray
            }
        }
        Write-Host $LineBreak
    }

    if ($ServiceWinRE) {
        Invoke-Task -Description 'Looking for a Safe OS Dynamic Update for the recovery image (WinRE)...' -ScriptBlock {
            # Server media labels the Safe OS package plain "Dynamic Update", so the Setup one is excluded
            # by name instead of the Safe OS one being required by name.
            $SafeInclude = if ($Server) { '(?i)dynamic update' } else { '(?i)safe os dynamic update' }
            $script:SafeOs = Get-LatestCatalogPackage -Query "Safe OS Dynamic Update $(Get-CatalogProductQuery -FeatureUpdate $FeatureName) $CatalogArch" -DownloadDir $DlDir -TitleInclude $SafeInclude -TitleExclude '(?i)setup dynamic update'
        }
        if ($script:SafeOs) { $SafeOsGroup = @($script:SafeOs) }
        else { Write-HostTimestamp '  No Safe OS Dynamic Update was found, so WinRE update integration will be skipped (per Microsoft, the LCU does not apply to WinRE).' -ForegroundColor Yellow }
        Write-Host $LineBreak
    }
}

# Everything that will be integrated, flattened for the build stamp (and so -AutoClean later knows which
# downloads belong to which build).
$script:StampUpdateFiles = @()
foreach ($Group in $UpdateGroups) { $script:StampUpdateFiles += @($Group) }
if ($script:SetupDu) { $script:StampUpdateFiles += @($script:SetupDu) }
if ($SafeOsGroup) { $script:StampUpdateFiles += @($SafeOsGroup) }
# Hashed here, once, because both the media tattoo and the build stamp describe the same packages.
$script:UpdateFileRecords = @(Get-UpdateFileRecords -Paths $script:StampUpdateFiles -DownloadDir $DlDir)

#endregion

#region Resolve which editions to keep and which to service
$InstallImages = @(Get-WindowsImage -ImagePath $InstallWimExtracted -ErrorAction Stop)

# Which editions to KEEP in the final ISO.
#   * -KeepEditions <list>  : keep exactly what the user named (highest precedence).
#   * -KeepAllEditions      : keep every edition in the media.
#   * default               : keep Enterprise, Pro and Home on client media (whichever of them it carries),
#                             or the most upgradeable single edition on Server, to speed up servicing and
#                             shrink the ISO.
$KeepIndexes = @($InstallImages.ImageIndex)
if ($script:EsdPreTrimmed) {
    # The ESD conversion already exported only the editions to keep, and dropping editions renumbers the
    # indexes, so re-resolving the same tokens against this WIM would not line up.
    Write-HostTimestamp "Keeping the $($InstallImages.Count) edition(s) exported from install.esd: $(($InstallImages.ImageName) -join ', ')" -ForegroundColor Cyan
    Write-Host $LineBreak
}
elseif ($KeepEditions -and $KeepEditions.Count -gt 0) {
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
    $KeepIndexes = @(Select-DefaultEditions -Images $InstallImages -ServerMedia:$Server)
    $KeptNames = $InstallImages | Where-Object { $KeepIndexes -contains [int]$_.ImageIndex } | ForEach-Object { $_.ImageName }
    $DroppedNames = $InstallImages | Where-Object { $KeepIndexes -notcontains [int]$_.ImageIndex } | ForEach-Object { $_.ImageName }
    $EditionRule = if ($Server) { 'the most upgradeable edition' } elseif ($KeepIndexes.Count -gt 1) { 'the Enterprise, Pro and Home editions the media carries' } else { 'one edition' }
    Write-HostTimestamp "Keeping only $EditionRule to speed up the build: $($KeptNames -join ', '). Use -KeepAllEditions to keep them all, or -KeepEditions to choose." -ForegroundColor Cyan
    if ($Server) { Write-HostTimestamp '  Standard can be upgraded to Datacenter in place with DISM /Set-Edition, but Datacenter can never be downgraded, so Standard is the safer edition to ship.' -ForegroundColor DarkGray }
    if ($DroppedNames) { Write-HostTimestamp "Removing from the ISO: $($DroppedNames -join ', ')" -ForegroundColor Yellow }
    Write-Host $LineBreak
}
$TrimNeeded = ($KeepIndexes.Count -lt $InstallImages.Count)

# Which of the kept editions to actually service (apply updates to). -Edition narrows this further.
# Index numbers cannot be honoured after an ESD pre-trim renumbered them, so everything kept is serviced.
if ($Edition -eq 'All' -or ($script:EsdPreTrimmed -and $Edition -match '^\d+$')) {
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

#endregion

#region Service the images
# Drivers alone are reason enough to mount everything, so this runs with no updates to apply too.
if ($UpdateGroups.Count -gt 0 -or $script:DriverInfFiles.Count -gt 0) {
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
                                Add-UpdateGroup -MountDir $WinReMount -Group $SafeOsGroup -Label 'Safe OS Dynamic Update' -ImageLabel "winre.wim (inside index $Index, $EditionName)" | Out-Null
                            }
                            else {
                                Write-HostTimestamp '      No Safe OS Dynamic Update available, so WinRE update integration is skipped.' -ForegroundColor DarkGray
                            }
                            Remove-ImageResidue -MountDir $WinReMount
                            Dismount-WindowsImage -Path $WinReMount -Save -ErrorAction Stop | Out-Null
                        }
                        catch {
                            Write-HostTimestamp "      WinRE servicing failed: $($_.Exception.Message)" -ForegroundColor Yellow
                            Dismount-ImageDiscard -Path $WinReMount | Out-Null
                        }
                    }
                }

                Write-HostTimestamp '    Applying updates to install.wim...'
                $script:InstallApplyOk = $true
                foreach ($Group in $UpdateGroups) {
                    if (-not (Add-UpdateGroup -MountDir $MountDir -Group $Group -ImageLabel "install.wim index $Index ($EditionName)")) { $script:InstallApplyOk = $false }
                }
                if (-not $script:InstallApplyOk) {
                    $script:ServicingFailures++
                    Write-HostTimestamp "    Note: the cumulative update didn't apply to index $Index ($EditionName), so this edition kept its original patch level. The ISO will still build." -ForegroundColor DarkYellow
                }

                # After the updates, so a driver is never superseded by an inbox one the cumulative update brings in.
                Add-ImageDrivers -MountDir $MountDir -InfFiles $script:DriverInfFiles -ImageLabel "install.wim index $Index ($EditionName)" | Out-Null

                if ($UpdateGroups.Count -gt 0) {
                    Write-HostTimestamp '    Cleaning up the component store (/StartComponentCleanup /ResetBase)...'
                    # ResetBase permanently removes superseded components, shrinking the image. This is slow.
                    & dism.exe /Image:"$MountDir" /Cleanup-Image /StartComponentCleanup /ResetBase | Out-Null
                }

                Remove-ImageResidue -MountDir $MountDir

                # Grabbed here because the image is already mounted, since mounting the finished image later
                # just to read this one value costs several minutes.
                if (-not $script:FinalBuildString) { $script:FinalBuildString = Get-MountedImageBuild -MountPath $MountDir }

                Write-HostTimestamp '    Committing and unmounting...'
                Dismount-WindowsImage -Path $MountDir -Save -ErrorAction Stop | Out-Null
                Write-HostTimestamp "    Index $Index done." -ForegroundColor Green
            }
            catch {
                Write-HostTimestamp "    Servicing index $Index failed: $($_.Exception.Message)" -ForegroundColor Red
                Dismount-ImageDiscard -Path $MountDir | Out-Null
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
                    Write-HostTimestamp "  expand.exe returned $LASTEXITCODE for $(Split-Path -Leaf $Cab), so the media Setup files were not fully refreshed." -ForegroundColor Yellow
                    Add-ServicingResult -Image 'media sources folder' -Package (Split-Path -Leaf $Cab) -Result 'Failed' -Detail "expand.exe returned $LASTEXITCODE"
                }
                else {
                    Write-HostTimestamp "  Applied $(Split-Path -Leaf $Cab) to sources\." -ForegroundColor Green
                    Add-ServicingResult -Image 'media sources folder' -Package (Split-Path -Leaf $Cab) -Result 'Applied' -Detail 'Setup Dynamic Update'
                }
            }
        }
    }

    # 3) Service boot.wim (Windows Setup / WinPE). Index 2 is the Setup environment, index 1 is WinPE.
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
                    foreach ($Group in $UpdateGroups) { Add-UpdateGroup -MountDir $MountDir -Group $Group -ImageLabel "boot.wim index $($BootImg.ImageIndex) ($($BootImg.ImageName))" | Out-Null }
                    # Only index 2 needs the drivers: that is the image Setup boots into, and it has to see
                    # the disk and the network card. Index 1 is loaded into a RAM disk and never installs.
                    if ([int]$BootImg.ImageIndex -eq 2) {
                        Add-ImageDrivers -MountDir $MountDir -InfFiles $script:DriverInfFiles -ImageLabel "boot.wim index 2 ($($BootImg.ImageName))" | Out-Null
                    }
                    if ($UpdateGroups.Count -gt 0) { & dism.exe /Image:"$MountDir" /Cleanup-Image /StartComponentCleanup | Out-Null }
                    Remove-ImageResidue -MountDir $MountDir

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
                    Dismount-ImageDiscard -Path $MountDir | Out-Null
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
                        # Index 2 (Windows Setup) carries the WIM's bootable flag, and without -Setbootable the ISO will not boot.
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
                Write-HostTimestamp '  No serviced Setup files were captured, so the media files are left as they are.' -ForegroundColor Yellow
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

            # The media's boot managers live under several names (bootmgfw.efi, bootx64.efi, ...), each of
            # them the same binary, so every copy is refreshed from the serviced one.
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
    Remove-DirectoryForce -Path $MountDir | Out-Null
}

#endregion

#region Re-export install.wim (shrink after servicing and/or drop editions with -KeepEditions)
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
            # Export in the order the indexes were chosen, which is ascending for -KeepEditions and
            # highest-edition-first for the default.
            foreach ($Index in $KeepIndexes) {
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

#endregion

#region Add the unattended answer file to the media
# Windows Setup implicitly reads \autounattend.xml from the root of read-only boot media during the
# windowsPE pass, so no Setup switches are needed when the ISO is booted.
if ($ResolvedUnattend) {
    Invoke-Task -Description 'Adding the unattended answer file to the media...' -ScriptBlock {
        $UnattendDest = Join-Path $ExtractDir 'autounattend.xml'
        if (Test-Path -LiteralPath $UnattendDest) { Set-ItemProperty -LiteralPath $UnattendDest -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
        Copy-Item -LiteralPath $ResolvedUnattend -Destination $UnattendDest -Force -ErrorAction Stop
        Write-HostTimestamp '  Added autounattend.xml to the root of the media.' -ForegroundColor Green
        if (($TrimNeeded -or $script:EsdPreTrimmed) -and $UnattendText -match '(?i)/IMAGE/INDEX') {
            Write-HostTimestamp '  Warning: the answer file selects the edition by /IMAGE/INDEX, but install.wim was renumbered when the other editions were removed. Switch it to /IMAGE/NAME, or use -KeepAllEditions, if Setup cannot find the edition.' -ForegroundColor Yellow
        }
    }
    Write-Host $LineBreak
}

#endregion

#region Copy the extra files onto the media (-ExtraFilesPath)
# Last of the content steps, so anything here deliberately wins over the media's own copy and over the
# answer file -UnattendPath just placed.
if ($ResolvedExtraFiles) {
    Invoke-Task -Description 'Copying your extra files onto the media...' -ScriptBlock {
        $Root = $ResolvedExtraFiles.TrimEnd('\')
        # Validation already hashed every file, so the copy only has to find its record and flag it.
        $ByPath = @{}
        foreach ($Record in $script:ExtraFileRecords) { $ByPath[$Record.Path.ToLowerInvariant()] = $Record }

        foreach ($Item in (Get-ChildItem -LiteralPath $Root -Recurse -Force -ErrorAction Stop)) {
            $Relative = $Item.FullName.Substring($Root.Length).TrimStart('\')
            $Dest = Join-Path -Path $ExtractDir -ChildPath $Relative
            if ($Item.PSIsContainer) {
                if (-not (Test-Path -LiteralPath $Dest)) { New-Item -ItemType Directory -Path $Dest -Force -ErrorAction Stop | Out-Null }
                continue
            }
            $Replaced = Test-Path -LiteralPath $Dest -PathType Leaf
            if ($Replaced) {
                [void]$script:ExtraFileOverwrites.Add($Relative)
                # Files copied off the source ISO are read-only, so Copy-Item -Force alone is not enough.
                Set-ItemProperty -LiteralPath $Dest -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
            }
            Copy-Item -LiteralPath $Item.FullName -Destination $Dest -Force -ErrorAction Stop
            $script:ExtraFilesCopied++

            $Record = $ByPath["\$($Relative.ToLowerInvariant())"]
            if ($Record) { $Record['Replaced'] = $Replaced }
            $SizeKB = if ($Record) { $Record.SizeKB } else { [math]::Round($Item.Length / 1KB, 2) }
            if ($Replaced) {
                Write-HostTimestamp "    \$Relative ($SizeKB KB) REPLACED" -ForegroundColor Yellow
            }
            else {
                Write-HostTimestamp "    \$Relative ($SizeKB KB)" -ForegroundColor DarkGray
            }
        }
        Write-HostTimestamp "  Copied $($script:ExtraFilesCopied) file(s) to the root of the media." -ForegroundColor Green

        if ($script:ExtraFileOverwrites.Count -eq 0) {
            Write-HostTimestamp '  Nothing the media already had was replaced.' -ForegroundColor DarkGray
            return
        }

        Write-HostTimestamp "  $($script:ExtraFileOverwrites.Count) of them REPLACED a file the media already had, marked above and listed in the build record." -ForegroundColor Yellow

        # Replacing one of these throws away everything this run just spent an hour producing.
        $Serviced = @($script:ExtraFileOverwrites | Where-Object { $_ -match '(?i)^sources\\(install|boot)\.(wim|esd)$' })
        if ($Serviced.Count -gt 0) {
            Write-HostTimestamp "  WARNING: $($Serviced -join ', ') came from your folder, so the ISO ships YOUR image, not the one this run serviced. The updates and drivers applied above are not in the finished ISO." -ForegroundColor Red
        }
        $SetupFiles = @($script:ExtraFileOverwrites | Where-Object { $_ -match '(?i)^(sources\\setup(host)?\.exe|boot\\|efi\\|bootmgr)' })
        if ($SetupFiles.Count -gt 0) {
            Write-HostTimestamp '  Warning: boot or Setup files were replaced. Windows Setup fails if those do not match the version inside boot.wim, and the wrong boot sector makes the ISO unbootable.' -ForegroundColor Yellow
        }
        if ($script:ExtraFileOverwrites -contains 'autounattend.xml') {
            Write-HostTimestamp '  Note: autounattend.xml was replaced, so your folder''s copy is on the ISO rather than the one -UnattendPath supplied.' -ForegroundColor Yellow
        }
    }
    if (-not $SkipTattoo -and @($script:ExtraFileOverwrites | Where-Object { $_ -match '(?i)^WISO-Build\\' }).Count -gt 0) {
        Write-HostTimestamp '  Note: files under \WISO-Build are about to be replaced by the build record. Pass -SkipTattoo to keep yours.' -ForegroundColor Yellow
    }
    Write-Host $LineBreak
}

#endregion

#region Decide the output ISO name and volume label
# The name describes what the ISO actually contains: Win11_Pro_x64_26100.4061_20260815-1332.iso. It is
# built even when -OutputIsoPath overrides the path, because the volume label is derived from it.
$DefaultIsoName = Get-DefaultIsoName -Images $InstallImages -Indexes $KeepIndexes -BuildString $script:FinalBuildString -FallbackVersion $ImageInfo.Version -Architecture $ImageArch
if (-not $OutputIsoPath) {
    $OutputIsoPath = Join-Path -Path $FinishedIsoDir -ChildPath $DefaultIsoName
}
$IsoVolumeLabel = if ($VolumeLabel) { $VolumeLabel } else { Get-IsoVolumeLabel -IsoFileName $DefaultIsoName }
# Make sure the destination folder exists before oscdimg writes the ISO into it.
try {
    $OutDir = Split-Path -Path $OutputIsoPath -Parent
    if ($OutDir -and -not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force -ErrorAction Stop | Out-Null }
}
catch { }

#endregion

#region Tattoo the build details onto the media (-SkipTattoo)
# Written into the extracted folder now, while oscdimg has not packaged it yet, so the finished ISO can
# answer "where did this come from and what is in it" without the build machine being around.
if (-not $SkipTattoo) {
    Invoke-Task -Description 'Writing the build record onto the media...' -ScriptBlock {
        $SourceItem = Get-Item -LiteralPath $ResolvedIso -ErrorAction SilentlyContinue
        # Source indexes, because these are the editions as the ISO shipped them. Re-exporting renumbers
        # whatever survives, which is why the kept list is by name. An install.esd was already trimmed
        # during its conversion, so its pre-trim lists are the only record of what the media carried.
        $SourceEditions = if ($script:SourceMediaEditions.Count -gt 0) { @($script:SourceMediaEditions) } else { @($InstallImages | ForEach-Object { "[$($_.ImageIndex)] $($_.ImageName)" }) }
        $KeptNames      = @($InstallImages | Where-Object { $KeepIndexes -contains [int]$_.ImageIndex } | ForEach-Object { "$($_.ImageName)" })
        $RemovedNames   = @($script:SourceMediaDropped) + @($InstallImages | Where-Object { $KeepIndexes -notcontains [int]$_.ImageIndex } | ForEach-Object { "$($_.ImageName)" })
        $UnpatchedNames = @($InstallImages | Where-Object { ($KeepIndexes -contains [int]$_.ImageIndex) -and ($ServiceIndexes -notcontains [int]$_.ImageIndex) } | ForEach-Object { "$($_.ImageName)" })
        $Failed         = @($script:TattooServicing | Where-Object { $_.Result -eq 'Failed' })

        $TattooInfo = [ordered]@{
            Build       = [ordered]@{
                Date          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss K')
                DateUtc       = (Get-Date).ToUniversalTime().ToString('o')
                Outcome       = if ($Failed.Count -gt 0 -or [int]$script:ServicingFailures -gt 0) { 'Completed with servicing warnings' } else { 'Completed' }
                ScriptVersion = $ScriptVersion
                IsoFileName   = Split-Path -Leaf $OutputIsoPath
                VolumeLabel   = $IsoVolumeLabel
                Started       = $script:ScriptStartTime.ToString('yyyy-MM-dd HH:mm:ss')
                LogFile       = $LogFile
            }
            BuiltBy     = [ordered]@{
                Computer        = $env:COMPUTERNAME
                User            = "$env:USERDOMAIN\$env:USERNAME"
                OperatingSystem = "$($OsInfo.Caption) ($($OsInfo.Version))"
                PowerShell      = "$($PSVersionTable.PSVersion)"
                ScriptPath      = $script:ScriptPath
                CommandLine     = Get-ScriptCommandLine
            }
            SourceMedia = [ordered]@{
                FileName      = if ($SourceItem) { $SourceItem.Name } else { Split-Path -Leaf $ResolvedIso }
                SizeGB        = if ($SourceItem) { [math]::Round($SourceItem.Length / 1GB, 2) } else { 0 }
                Sha256        = $script:StampSourceHash
                Product       = "$($ImageInfo.ProductName)"
                Version       = $ImageVersionText
                FeatureUpdate = $FeatureName
                Architecture  = $ImageArch
                Language      = "$($ImageInfo.DefaultLanguage)"
                ImageCreated  = if ($ImageInfo.CreatedTime) { ([datetime]$ImageInfo.CreatedTime).ToString('yyyy-MM-dd') } else { '' }
                Editions      = $SourceEditions
            }
            Contents    = [ordered]@{
                FinalBuild         = if ($script:FinalBuildString) { $script:FinalBuildString } else { "$ImageVersionText (unchanged)" }
                InstallImage       = Split-Path -Leaf $FinalInstallImage
                EditionsKept       = $KeptNames
                EditionsRemoved    = $RemovedNames
                EditionsNotUpdated = $UnpatchedNames
                AnswerFile         = if ($ResolvedUnattend) { "autounattend.xml (from $(Split-Path -Leaf $ResolvedUnattend), SHA-256 $(Format-ShortHash $script:UnattendHash))" } else { '' }
                RecoveryImage      = if ($ServiceWinRE) { 'winre.wim serviced with the Safe OS Dynamic Update' } else { 'winre.wim left as it shipped (-ServiceWinRE was not used)' }
            }
            Drivers     = if ($ResolvedDriverPath) {
                [ordered]@{
                    Source   = $ResolvedDriverPath
                    Sha256   = $script:DriverHash
                    Signing  = if ($AllowUnsignedDrivers) { 'Unsigned and untrusted drivers accepted (-AllowUnsignedDrivers)' } else { 'Signed drivers only' }
                    Injected = 'Every serviced edition of install.wim, plus boot.wim index 2 (Windows Setup)'
                    Packages = @($script:DriverInfFiles | ForEach-Object { $_.Name })
                }
            }
            else { '' }
            ExtraFiles  = if ($ResolvedExtraFiles) {
                [ordered]@{
                    Source        = $ResolvedExtraFiles
                    Sha256        = $script:ExtraFilesHash
                    FileCount     = $script:ExtraFilesCopied
                    ReplacedCount = $script:ExtraFileOverwrites.Count
                    # Paths are relative to the root of the ISO, so this is exactly what a stock Microsoft
                    # ISO would have had instead.
                    Replaced      = $script:ExtraFileOverwrites.ToArray()
                    # Every file that went on, hashed, so what is on the media can be told apart from what
                    # the folder holds today.
                    Files         = $script:ExtraFileRecords
                }
            }
            else { '' }
            Stripped    = [ordered]@{
                ComponentStore     = if ($UpdateGroups.Count -gt 0) { 'Superseded components removed (/StartComponentCleanup /ResetBase), so the images cannot be rolled back to their original patch level' } else { 'Untouched (nothing was serviced)' }
                ServicingResidueMB = [math]::Round($script:TattooResidueMB, 0)
                ResidueDetail      = if ($StripImageResidue) { 'CBS/DISM/DPX/MoSetup/WindowsUpdate logs, Windows\Temp, SoftwareDistribution\Download, WinREAgent and Panther logs. Windows recreates all of it on first boot' } else { 'Nothing was stripped, so the images still carry their servicing logs and temp files. Pass -StripImageResidue to remove them' }
                # Only ever populated when the source ISO was captured from an installed machine rather
                # than downloaded from Microsoft, which is worth knowing about the media you are holding.
                # .ToArray() rather than @(), which throws "Argument types do not match" on 5.1.
                CaptureLeftovers   = $script:TattooResidueFound.ToArray()
            }
            Updates     = [ordered]@{
                CatalogSelection = @($script:ExpectedUpdateSet | Where-Object { $_ })
                Packages         = @($script:UpdateFileRecords)
                Servicing        = $script:TattooServicing.ToArray()
                FailedCount      = $Failed.Count
            }
            Parameters  = Get-BuildParameterSet
        }

        Write-BuildTattoo -MediaRoot $ExtractDir -Info $TattooInfo -ScriptSource $script:ScriptPath | Out-Null
    }
}

#endregion

#region Recompile the ISO with oscdimg
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
        # Neither boot sector was found, so oscdimg will still build the ISO, but it may not be bootable.
        Write-HostTimestamp '  No boot sectors were found in the extracted media, so the resulting ISO may not be bootable.' -ForegroundColor Yellow
    }

    # oscdimg switches: -m (ignore the 4 GB image size limit), -o (de-duplicate identical files to save
    # space), -u2 (write a pure UDF file system, required for the large install.wim), -udfver102 (UDF
    # revision 1.02 for broad compatibility), -l (volume label). -bootdata makes the ISO bootable, and the
    # last two arguments are the source folder to package and the output ISO path.
    $OscdimgArgs = @('-m', '-o', '-u2', '-udfver102', "-l$IsoVolumeLabel")
    if ($BootArg) { $OscdimgArgs += "-bootdata:$BootArg" }
    $OscdimgArgs += @($ExtractDir, $OutputIsoPath)
    Write-HostTimestamp "  Volume label: $IsoVolumeLabel" -ForegroundColor DarkGray

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

#endregion

#region Report the final image contents (editions + build) before the working files are removed
Invoke-Task -Description 'Reading the final image details...' -ScriptBlock {
    Show-FinalImageInfo -WimPath $FinalInstallImage
}

#endregion

#region Cleanup the working extraction folder
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

#endregion

#region Write the build stamp
# The record the next run compares itself against: what went in, what came out, and under which settings.
if (-not $NoStamp) {
    Invoke-Task -Description 'Writing the build stamp...' -ScriptBlock {
        $SourceItem = Get-Item -LiteralPath $ResolvedIso -ErrorAction SilentlyContinue
        $OutputItem = Get-Item -LiteralPath $OutputIsoPath -ErrorAction SilentlyContinue

        $UpdateRecords = @($script:UpdateFileRecords)

        $ParameterSet = Get-BuildParameterSet
        $OutputHash = $null
        if ($OutputItem) {
            Write-HostTimestamp "  Hashing the finished ISO ($([math]::Round($OutputItem.Length / 1GB, 2)) GB)..."
            $OutputHash = Get-Sha256 -Path $OutputItem.FullName
        }
        # Taken from the image list read before the working folder was removed.
        $KeptEditionNames = @($InstallImages | Where-Object { $KeepIndexes -contains [int]$_.ImageIndex } | ForEach-Object { "$($_.ImageName)" })
        $Stamp = [ordered]@{
            SchemaVersion   = 1
            ScriptVersion   = $ScriptVersion
            CreatedUtc      = (Get-Date).ToUniversalTime().ToString('o')
            Computer        = $env:COMPUTERNAME
            Result          = if ($script:ServicingFailures -gt 0) { 'SuccessWithWarnings' } else { 'Success' }
            DurationMinutes = [math]::Round(((Get-Date) - $script:ScriptStartTime).TotalMinutes, 1)
            Source          = [ordered]@{
                Path             = if ($SourceItem) { $SourceItem.FullName } else { $ResolvedIso }
                FileName         = if ($SourceItem) { $SourceItem.Name } else { Split-Path -Leaf $ResolvedIso }
                Length           = if ($SourceItem) { $SourceItem.Length } else { 0 }
                LastWriteTimeUtc = if ($SourceItem) { $SourceItem.LastWriteTimeUtc.ToString('o') } else { '' }
                Sha256           = $script:StampSourceHash
            }
            Image           = [ordered]@{
                Version       = $ImageVersionText
                Build         = $ImageBuild
                Ubr           = $ImageUbr
                FeatureUpdate = $FeatureName
                Architecture  = $ImageArch
                CatalogArch   = $CatalogArch
                FinalBuild    = $script:FinalBuildString
            }
            Updates         = [ordered]@{
                # What the catalog was offering at build time - this is what a later run compares against.
                Catalog = @($script:ExpectedUpdateSet | Where-Object { $_ })
                Files   = $UpdateRecords
            }
            Output          = [ordered]@{
                Path     = $OutputIsoPath
                FileName = if ($OutputItem) { $OutputItem.Name } else { Split-Path -Leaf $OutputIsoPath }
                SizeGB   = if ($OutputItem) { [math]::Round($OutputItem.Length / 1GB, 2) } else { 0 }
                Sha256   = $OutputHash
                Editions = $KeptEditionNames
            }
            Parameters      = $ParameterSet
            ParametersHash  = Get-BuildParameterHash -Set $ParameterSet
        }
        Write-BuildStamp -Stamp $Stamp
    }
    Write-Host $LineBreak
}

#endregion

#region Housekeeping (-AutoClean)
if ($AutoClean) {
    Invoke-Task -Description 'Cleaning up old downloads and ISOs (-AutoClean)...' -ScriptBlock {
        Invoke-AutoClean -CurrentStamp (Read-BuildStamp) -History (Get-BuildStampHistory) -KeepIsoCount $KeepIsoCount -Protected @($ResolvedIso, $OutputIsoPath)
    }
    Write-Host $LineBreak
}

#endregion

#region Timing summary
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
if (-not $SkipTattoo) {
    Write-HostTimestamp '  Open \WISO-Build on the ISO for the record of how it was built.' -ForegroundColor DarkGray
}
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

#endregion

#region End Logging
# Stop logging
Stop-Transcript
#endregion
