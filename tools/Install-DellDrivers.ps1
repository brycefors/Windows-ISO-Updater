<#
.SYNOPSIS
    Installs Dell Command Update and runs its CLI to detect and apply the latest drivers for this
    Dell machine.

.DESCRIPTION
    The script discovers the current Dell Command Update (DCU) driver listing by scraping the Dell
    support KB page for Dell Command Update, then resolves that listing to a direct installer
    download URL. It downloads the installer to -OutputPath, installs DCU silently if not already
    present, then drives dcu-cli.exe through a scan and, unless -ScanOnly is given, an apply pass
    scoped to -UpdateType.

    Discovery is two hops because Dell's dl.dell.com path segment and the version/build in the
    installer filename change over time, so neither can be hardcoded.

        1. https://www.dell.com/support/kbdoc/en-us/000177325/dell-command-update is scraped for a
           driversdetails?driverid= link, giving the current driver ID.
        2. https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=<id> is scraped
           for a direct dl.dell.com .EXE link.

    If the first hop fails for any reason, -DriverId supplies a fallback ID.

.PARAMETER OutputPath
    Folder the DCU installer .exe is downloaded to. Defaults to .\Drivers\DellCommandUpdate in the
    current directory.

.PARAMETER DriverId
    Fallback Dell driver ID for the DCU Windows Universal Application listing, used only if the KB
    page scrape fails to find one. Defaults to 'P0P70', the ID as of today. Dell can reassign IDs, so
    refresh this default if the fallback stops resolving.

.PARAMETER DownloadOnly
    Download the DCU installer only. Does not install it, does not run its CLI, and does not require
    elevation.

.PARAMETER ScanOnly
    Install DCU if not already present and run dcu-cli.exe /scan to report what is available, but do
    not apply anything.

.PARAMETER UpdateType
    Update category passed to dcu-cli.exe's -updateType= argument when applying updates. One of
    bios, firmware, driver, application, or others. Defaults to driver.

.PARAMETER AllowReboot
    Passes -reboot=enable to dcu-cli.exe when applying updates, instead of the default
    -reboot=disable. Omit this to guarantee the machine is never rebooted unattended.

.PARAMETER Quiet
    Suppress detail lines; show only headings and the final summary.

.EXAMPLE
    .\tools\Install-DellDrivers.ps1
    Installs Dell Command Update if needed, scans, and applies driver updates without rebooting. Must
    be run elevated. This is the default behavior.

.EXAMPLE
    .\tools\Install-DellDrivers.ps1 -DownloadOnly
    Downloads the current DCU installer into .\Drivers\DellCommandUpdate without installing anything.

.EXAMPLE
    .\tools\Install-DellDrivers.ps1 -ScanOnly
    Installs DCU if needed and reports available updates without applying any of them.

.EXAMPLE
    .\tools\Install-DellDrivers.ps1 -UpdateType bios -AllowReboot
    Applies only BIOS updates and allows DCU to reboot the machine if one of them requires it.

.NOTES
    dcu-cli.exe installs to either Program Files or Program Files (x86) depending on the DCU version,
    both locations are checked.

    Driver ID and download link are discovered at runtime from
    https://www.dell.com/support/kbdoc/en-us/000177325/dell-command-update so no hardcoded installer
    URL needs updating.
#>
[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Folder the DCU installer .exe is downloaded to. Defaults to .\Drivers\DellCommandUpdate in the current directory.')]
    [string]$OutputPath = '.\Drivers\DellCommandUpdate',

    [Parameter(HelpMessage = "Fallback Dell driver ID for the DCU Windows Universal Application listing, used only if the KB page scrape fails to find one. Defaults to 'P0P70', the ID as of today. Dell can reassign IDs, so refresh this default if the fallback stops resolving.")]
    [string]$DriverId = 'P0P70',

    [Parameter(HelpMessage = 'Download the DCU installer only. Does not install it, does not run its CLI, and does not require elevation.')]
    [switch]$DownloadOnly,

    [Parameter(HelpMessage = 'Install DCU if not already present and run dcu-cli.exe /scan to report what is available, but do not apply anything.')]
    [switch]$ScanOnly,

    [Parameter(HelpMessage = "Update category passed to dcu-cli.exe's -updateType= argument when applying updates. Defaults to driver.")]
    [ValidateSet('bios', 'firmware', 'driver', 'application', 'others')]
    [string]$UpdateType = 'driver',

    [Parameter(HelpMessage = 'Passes -reboot=enable to dcu-cli.exe when applying updates, instead of the default -reboot=disable. Omit this to guarantee the machine is never rebooted unattended.')]
    [switch]$AllowReboot,

    [Parameter(HelpMessage = 'Suppress detail lines; show only headings and the final summary.')]
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# Dell's support site rejects PowerShell's default User-Agent as bot traffic, same defensive pattern as the Surface script
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

# Tracks whether DCU ever reported a reboot-required result, so the script can surface that in its own exit code
$script:RebootRequired = $false

function Get-DellDriverId {
    $KbUrl = 'https://www.dell.com/support/kbdoc/en-us/000177325/dell-command-update'

    # Specialize can start before DHCP settles, so keep retrying for about three minutes.
    $Response = $null
    for ($Attempt = 1; $Attempt -le 18 -and -not $Response; $Attempt++) {
        try {
            $Response = Invoke-WebRequest -Uri $KbUrl -UseBasicParsing -TimeoutSec 30 -UserAgent $script:UserAgent
        }
        catch {
            Write-Host "  Attempt $Attempt of 18 to fetch the Dell Command Update KB page failed - $($_.Exception.Message)" -ForegroundColor DarkGray
        }
        if (-not $Response) {
            Start-Sleep -Seconds 10
        }
    }
    if (-not $Response) {
        Write-Host 'Failed to fetch the Dell Command Update KB page after 18 attempts.' -ForegroundColor Red
        return $null
    }

    $IdMatch = [regex]::Match($Response.Content, 'driversdetails\?driverid=([A-Za-z0-9]+)')
    if ($IdMatch.Success) {
        return $IdMatch.Groups[1].Value
    }

    Write-Host '  Warning: no driver ID link found on the Dell Command Update KB page.' -ForegroundColor Yellow
    return $null
}

function Select-HighestVersionUrl {
    param([string[]]$Urls)

    $Best = $null
    $BestVersion = $null
    foreach ($Candidate in $Urls) {
        $FileName = $Candidate.Split('/')[-1]
        $VersionMatch = [regex]::Match($FileName, '(\d+\.\d+\.\d+)')
        if ($VersionMatch.Success) {
            try {
                $Ver = [Version]$VersionMatch.Groups[1].Value
                if ($null -eq $BestVersion -or $Ver -gt $BestVersion) {
                    $BestVersion = $Ver
                    $Best = $Candidate
                }
            }
            catch { }
        }
    }

    if ($Best) {
        return $Best
    }
    return $Urls[0]
}

function Resolve-DcuDownloadUrl {
    param([string]$DriverId)

    $DetailsUrl = "https://www.dell.com/support/home/en-us/drivers/driversdetails?driverid=$DriverId"

    # Specialize can start before DHCP settles, so keep retrying for about three minutes.
    $Response = $null
    for ($Attempt = 1; $Attempt -le 18 -and -not $Response; $Attempt++) {
        try {
            $Response = Invoke-WebRequest -Uri $DetailsUrl -UseBasicParsing -TimeoutSec 30 -UserAgent $script:UserAgent
        }
        catch {
            Write-Host "  Attempt $Attempt of 18 to fetch the Dell driver details page failed - $($_.Exception.Message)" -ForegroundColor DarkGray
        }
        if (-not $Response) {
            Start-Sleep -Seconds 10
        }
    }
    if (-not $Response) {
        Write-Host 'Failed to fetch the Dell driver details page after 18 attempts.' -ForegroundColor Red
        return $null
    }

    $UrlMatches = [regex]::Matches($Response.Content, 'https://dl\.dell\.com/[^"''\s]+\.EXE', 'IgnoreCase')
    if ($UrlMatches.Count -eq 0) {
        Write-Host "  Warning: no download link found on the driver details page for driver ID '$DriverId'." -ForegroundColor Yellow
        return $null
    }

    $Candidates = @($UrlMatches | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($Candidates.Count -eq 1) {
        return $Candidates[0]
    }

    return Select-HighestVersionUrl -Urls $Candidates
}

function Get-DcuInstaller {
    param(
        [string]$Url,
        [string]$DestinationFolder
    )

    New-Item -ItemType Directory -Force -Path $DestinationFolder | Out-Null
    $FileName = $Url.Split('/')[-1]
    $DestFile = Join-Path -Path $DestinationFolder -ChildPath $FileName

    if (Test-Path -LiteralPath $DestFile) {
        if (-not $Quiet) {
            Write-Host "  Already present: $FileName" -ForegroundColor DarkGray
        }
        return $DestFile
    }

    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            try {
                [void](Start-BitsTransfer -Source $Url -Destination $DestFile -DisplayName $FileName -ErrorAction Stop)
            }
            catch {
                Write-Host "  BITS failed, falling back to WebRequest - $($_.Exception.Message)" -ForegroundColor Yellow
                [void](Invoke-WebRequest -Uri $Url -OutFile $DestFile -UseBasicParsing -UserAgent $script:UserAgent)
            }
        }
        else {
            [void](Invoke-WebRequest -Uri $Url -OutFile $DestFile -UseBasicParsing -UserAgent $script:UserAgent)
        }
        Unblock-File -LiteralPath $DestFile -ErrorAction SilentlyContinue
        return $DestFile
    }
    catch {
        Write-Host "  Download failed - $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path -LiteralPath $DestFile) {
            Remove-Item -LiteralPath $DestFile -Force -ErrorAction SilentlyContinue
        }
        return $null
    }
}

function Find-DcuCliPath {
    $Candidates = @(
        "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe",
        "${env:ProgramFiles}\Dell\CommandUpdate\dcu-cli.exe"
    )
    foreach ($Candidate in $Candidates) {
        if ($Candidate -and (Test-Path -LiteralPath $Candidate)) {
            return $Candidate
        }
    }
    return $null
}

# Resolve to an absolute path before any path operations.
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path -Path (Get-Location).Path -ChildPath $OutputPath
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

if (-not $DownloadOnly -and -not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    Write-Host 'Installing Dell Command Update and running dcu-cli.exe requires an elevated (Administrator) PowerShell session. Re-run from an elevated prompt, or pass -DownloadOnly to just download the installer.' -ForegroundColor Red
    exit 1
}

if (-not $DownloadOnly) {
    $Manufacturer = (Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
    if ($Manufacturer -notmatch 'Dell') {
        Write-Host "Warning: this does not look like a Dell system (Manufacturer reported as '$Manufacturer'). Continuing anyway, since Dell Command Update decides applicability for itself." -ForegroundColor Yellow
    }
}

Write-Host 'Discovering the current Dell Command Update driver ID...' -ForegroundColor Cyan
$ResolvedDriverId = Get-DellDriverId
if (-not $ResolvedDriverId) {
    Write-Host "  Falling back to driver ID '$DriverId'" -ForegroundColor Yellow
    $ResolvedDriverId = $DriverId
}
if (-not $Quiet) {
    Write-Host "  Driver ID: $ResolvedDriverId" -ForegroundColor DarkGray
}

Write-Host 'Resolving the Dell Command Update download URL...' -ForegroundColor Cyan
$DownloadUrl = Resolve-DcuDownloadUrl -DriverId $ResolvedDriverId
if (-not $DownloadUrl) {
    Write-Host 'Could not resolve a Dell Command Update download URL. Check network access and try again.' -ForegroundColor Red
    exit 1
}
if (-not $Quiet) {
    Write-Host "  $DownloadUrl" -ForegroundColor DarkGray
}

Write-Host 'Downloading Dell Command Update...' -ForegroundColor Cyan
$InstallerPath = Get-DcuInstaller -Url $DownloadUrl -DestinationFolder $OutputPath
if (-not $InstallerPath) {
    Write-Host 'Failed to download the Dell Command Update installer.' -ForegroundColor Red
    exit 1
}
Write-Host "  Saved to $InstallerPath" -ForegroundColor Green

if ($DownloadOnly) {
    Write-Host ''
    Write-Host 'Summary' -ForegroundColor Cyan
    Write-Host ('-' * 80) -ForegroundColor DarkGray
    Write-Host ('{0,-16} {1}' -f 'Downloaded', $InstallerPath) -ForegroundColor Green
    Write-Host ''
    exit 0
}

$DcuCliPath = Find-DcuCliPath
if ($DcuCliPath) {
    if (-not $Quiet) {
        Write-Host "Dell Command Update is already installed at $DcuCliPath" -ForegroundColor DarkGray
    }
}
else {
    Write-Host 'Installing Dell Command Update...' -ForegroundColor Cyan
    $InstallProcess = Start-Process -FilePath $InstallerPath -ArgumentList '/s' -Wait -PassThru
    if ($InstallProcess.ExitCode -eq 0) {
        Write-Host '  Installed successfully' -ForegroundColor Green
    }
    elseif ($InstallProcess.ExitCode -eq 3010) {
        Write-Host '  Installed successfully (reboot required)' -ForegroundColor Yellow
        $script:RebootRequired = $true
    }
    else {
        Write-Host "  Install failed (exit $($InstallProcess.ExitCode)), look up the code in Dell's DCU installer documentation" -ForegroundColor Red
        exit 1
    }

    $DcuCliPath = Find-DcuCliPath
    if (-not $DcuCliPath) {
        Write-Host 'Dell Command Update installed but dcu-cli.exe could not be found under Program Files or Program Files (x86).' -ForegroundColor Red
        exit 1
    }
}

# DCU CLI versions disagree on which code means reboot-required, so both documented values are treated the same
$RebootCodes = @(1, 5)

Write-Host "Scanning for updates with $DcuCliPath ..." -ForegroundColor Cyan
$ScanOutput = & $DcuCliPath /scan -silent 2>&1 | Out-String
$ScanExitCode = $LASTEXITCODE
Write-Host $ScanOutput.Trim()

if ($ScanExitCode -eq 0) {
    Write-Host '  Scan complete' -ForegroundColor Green
}
elseif ($RebootCodes -contains $ScanExitCode) {
    Write-Host '  Scan complete (reboot required)' -ForegroundColor Yellow
    $script:RebootRequired = $true
}
else {
    Write-Host "  Scan reported exit code $ScanExitCode, check the DCU log for details" -ForegroundColor Red
}

if ($ScanOnly) {
    Write-Host ''
    Write-Host 'Summary' -ForegroundColor Cyan
    Write-Host ('-' * 80) -ForegroundColor DarkGray
    Write-Host ('{0,-16} {1}' -f 'Scanned', $DcuCliPath) -ForegroundColor Green
    Write-Host ''
    if ($script:RebootRequired) {
        exit 3010
    }
    exit 0
}

$RebootArg = if ($AllowReboot) { '-reboot=enable' } else { '-reboot=disable' }
Write-Host "Applying updates ($UpdateType, $RebootArg)..." -ForegroundColor Cyan
$ApplyOutput = & $DcuCliPath /applyUpdates -silent "-updateType=$UpdateType" $RebootArg 2>&1 | Out-String
$ApplyExitCode = $LASTEXITCODE
Write-Host $ApplyOutput.Trim()

if ($ApplyExitCode -eq 0) {
    Write-Host '  Updates applied successfully' -ForegroundColor Green
}
elseif ($RebootCodes -contains $ApplyExitCode) {
    Write-Host '  Updates applied (reboot required)' -ForegroundColor Yellow
    $script:RebootRequired = $true
}
else {
    Write-Host "  Apply reported exit code $ApplyExitCode, check the DCU log for details" -ForegroundColor Red
}

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ('-' * 80) -ForegroundColor DarkGray
Write-Host ('{0,-16} {1}' -f 'Applied', $DcuCliPath) -ForegroundColor Green
Write-Host ''

if ($script:RebootRequired) {
    exit 3010
}
exit 0
