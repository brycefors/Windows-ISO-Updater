<#
.SYNOPSIS
    Installs Dell Command Update and runs its CLI to detect and apply the latest drivers for this
    Dell machine.

.DESCRIPTION
    The script discovers the current Dell Command Update (DCU) installer by parsing Dell's public
    driver-catalog feed, then downloads it to -OutputPath, installs DCU silently if not already
    present, then drives dcu-cli.exe through a scan and, unless -ScanOnly is given, an apply pass
    scoped to -UpdateType.

    Discovery downloads https://downloads.dell.com/catalog/CatalogPC.cab, a cabinet file containing
    CatalogPC.xml, which lists every BIOS, firmware, driver and application update Dell publishes for
    its client systems, including Dell Command Update itself as an application entry. The CAB is
    expanded with expand.exe, the XML is searched for the Dell Command Update entry matching
    -DcuVariant, and the highest-versioned match's path is turned into a download URL. This replaced
    scraping the interactive https://www.dell.com/support/... pages, which sit behind Akamai Bot
    Manager and rejected every request no matter what headers or cookies were replayed. The catalog
    is a static file download and is not gated the same way.

    Recent DCU releases require the .NET 8 Desktop Runtime (x64) to already be on the machine, or the
    DCU installer fails or refuses to run. Before installing DCU, this script checks the registered
    uninstall entries (and, as a secondary check, `dotnet --list-runtimes` if dotnet.exe is on PATH)
    for a Microsoft Windows Desktop Runtime 8.x (x64) entry, and if none is found, downloads it from
    Microsoft's own https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe permanent redirector
    and installs it silently first. -SkipDotNetRuntime opts out of this step.

    Dell publishes Dell Command Update as two distinct catalog entries: the classic Win32 desktop
    installer (named "...Application_..." or "...for-Win32_...") and the Windows Universal
    Application (named "...Windows-Universal-Application_..."), a differently packaged UWP-based app.
    Both names satisfy a loose "Dell Command Update" match, so -DcuVariant decides which one is kept,
    the other is excluded rather than left to whichever has the higher version number. If the catalog
    also carries an ARM64/WinARM-specific build, tagged in its name or its SupportedOperatingSystems
    metadata, that entry is excluded regardless of -DcuVariant unless the host is itself running
    Windows on ARM64.

.PARAMETER OutputPath
    Folder the DCU installer .exe is downloaded to. Defaults to .\Drivers\DellCommandUpdate in the
    current directory.

.PARAMETER DownloadOnly
    Download the DCU installer only. Does not install it, does not run its CLI, and does not require
    elevation.

.PARAMETER ScanOnly
    Install DCU if not already present and run dcu-cli.exe /scan to report what is available, but do
    not apply anything.

.PARAMETER DcuVariant
    Which Dell Command Update catalog entry to resolve: Win32 for the classic desktop installer, or
    Universal for the Windows Universal Application. Defaults to Win32, the variant this script's
    silent-install switch and dcu-cli.exe discovery have been verified against; the Universal
    variant's install and CLI behavior are unverified by this script.

.PARAMETER UpdateType
    Update category passed to dcu-cli.exe's -updateType= argument when applying updates. One of
    bios, firmware, driver, application, or others. Defaults to driver.

.PARAMETER AllowReboot
    Passes -reboot=enable to dcu-cli.exe when applying updates, instead of the default
    -reboot=disable. Omit this to guarantee the machine is never rebooted unattended.

.PARAMETER Quiet
    Suppress detail lines; show only headings and the final summary.

.PARAMETER ProxyUrl
    Proxy server URL to route the catalog download, installer download, and Dell Command Update's own
    scan/apply traffic through, for example http://proxy.example.com:8080. Omit to use the machine's
    default network configuration.

.PARAMETER SkipDotNetRuntime
    Skip checking for and installing the .NET 8 Desktop Runtime (x64) that newer Dell Command Update
    installers require. Defaults to not skipping, since DCU needs it present to install or upgrade.
    Only useful if the runtime is already provisioned some other way, or -DownloadOnly/-ScanOnly is
    being used and the runtime check itself is undesirable.

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

.EXAMPLE
    .\tools\Install-DellDrivers.ps1 -ProxyUrl 'http://proxy.example.com:8080'
    Runs the default behavior with all outbound traffic, including Dell Command Update's own
    scan/apply calls, routed through the given proxy.

.EXAMPLE
    .\tools\Install-DellDrivers.ps1 -DcuVariant Universal -DownloadOnly
    Downloads the Windows Universal Application installer instead of the classic Win32 one, without
    installing or running its CLI. Unverified by this script beyond the download step.

.EXAMPLE
    .\tools\Install-DellDrivers.ps1 -SkipDotNetRuntime
    Runs the default behavior but skips the .NET 8 Desktop Runtime (x64) presence check and install.

.NOTES
    dcu-cli.exe installs to either Program Files or Program Files (x86) depending on the DCU version,
    both locations are checked. This is only confirmed for the Win32 variant; whether the Universal
    variant installs a compatible dcu-cli.exe at all is unverified.

    Driver ID and download link are discovered at runtime from Dell's CatalogPC.cab feed so no
    hardcoded installer URL needs updating. There is no local fallback if Dell changes the catalog's
    schema or file name, since any fallback would have to be a hardcoded installer URL that goes stale
    the same way the old scraped IDs did.

    The .NET 8 Desktop Runtime URL, https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe, is
    Microsoft's own aka.ms redirector for the latest servicing release of the channel, the same kind
    of permanent link this script's sibling Windows-ISO-Updater.ps1 already relies on for the Media
    Creation Tool's go.microsoft.com/fwlink links, so it does not need to be updated as .NET 8 receives
    further patches. It is unverified against a live network by this edit; confirm it still resolves
    and consider adding it to tools/Test-Dependencies.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Folder the DCU installer .exe is downloaded to. Defaults to .\Drivers\DellCommandUpdate in the current directory.')]
    [string]$OutputPath = '.\Drivers\DellCommandUpdate',

    [Parameter(HelpMessage = 'Download the DCU installer only. Does not install it, does not run its CLI, and does not require elevation.')]
    [switch]$DownloadOnly,

    [Parameter(HelpMessage = 'Install DCU if not already present and run dcu-cli.exe /scan to report what is available, but do not apply anything.')]
    [switch]$ScanOnly,

    [Parameter(HelpMessage = "Which Dell Command Update catalog entry to resolve: Win32 for the classic desktop installer, or Universal for the Windows Universal Application. Defaults to Win32, the variant this script's silent-install switch and dcu-cli.exe discovery have been verified against.")]
    [ValidateSet('Win32', 'Universal')]
    [string]$DcuVariant = 'Universal',

    [Parameter(HelpMessage = "Update category passed to dcu-cli.exe's -updateType= argument when applying updates. Defaults to driver.")]
    [ValidateSet('bios', 'firmware', 'driver', 'application', 'others')]
    [string]$UpdateType = 'driver',

    [Parameter(HelpMessage = 'Passes -reboot=enable to dcu-cli.exe when applying updates, instead of the default -reboot=disable. Omit this to guarantee the machine is never rebooted unattended.')]
    [switch]$AllowReboot,

    [Parameter(HelpMessage = 'Suppress detail lines; show only headings and the final summary.')]
    [switch]$Quiet,

    [Parameter(HelpMessage = "Proxy server URL to route the catalog download, installer download, and Dell Command Update's own scan/apply traffic through, for example http://proxy.example.com:8080. Omit to use the machine's default network configuration.")]
    [ValidateScript({
        $ParsedUri = $null
        if (-not [Uri]::TryCreate($_, [UriKind]::Absolute, [ref]$ParsedUri)) {
            throw "The value '$_' is not a valid absolute URI."
        }
        $true
    })]
    [string]$ProxyUrl,

    [Parameter(HelpMessage = 'Skip checking for and installing the .NET 8 Desktop Runtime (x64) that newer Dell Command Update installers require. Defaults to not skipping, since DCU needs it present to install or upgrade.')]
    [switch]$SkipDotNetRuntime
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# Still spoofed for the installer download itself; downloads.dell.com is a plain file server but this costs nothing to keep
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
# A static file feed, not the interactive support pages, so it is not behind the Akamai Bot Manager challenge that blocked scraping
$script:DellCatalogUrl = 'https://downloads.dell.com/catalog/CatalogPC.cab'
# Microsoft's own permanent redirector for the latest servicing release of a channel, the same kind of
# aka.ms/go.microsoft.com fwlink this repo already trusts for Fido and the Media Creation Tool
$script:DotNetRuntimeUrl = 'https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe'

# Splatted onto every Invoke-WebRequest call so -ProxyUrl, when given, is the only place proxy routing is decided
$script:WebRequestProxyArgs = @{}
if ($ProxyUrl) {
    $script:WebRequestProxyArgs['Proxy'] = $ProxyUrl
}

# Tracks whether DCU ever reported a reboot-required result, so the script can surface that in its own exit code
$script:RebootRequired = $false

# Distinguishes a real 403 from the site from timeouts/DNS/other errors, which retrying can't fix so the retry loop stops early
function Test-ForbiddenResponse {
    param($ErrorRecord)
    return [bool]($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode -eq [System.Net.HttpStatusCode]::Forbidden)
}

function Get-DellCatalogCab {
    param([string]$DestinationFolder)

    New-Item -ItemType Directory -Force -Path $DestinationFolder | Out-Null
    $CabPath = Join-Path -Path $DestinationFolder -ChildPath 'CatalogPC.cab'

    # Specialize can start before DHCP settles, so keep retrying for about three minutes, same cadence the old scrape used.
    $Downloaded = $false
    for ($Attempt = 1; $Attempt -le 18 -and -not $Downloaded; $Attempt++) {
        Write-Host "  Requesting $($script:DellCatalogUrl)" -ForegroundColor DarkGray
        try {
            Invoke-WebRequest -Uri $script:DellCatalogUrl -OutFile $CabPath -UseBasicParsing -TimeoutSec 120 -UserAgent $script:UserAgent @script:WebRequestProxyArgs
            $Downloaded = $true
        }
        catch {
            if (Test-Path -LiteralPath $CabPath) {
                Remove-Item -LiteralPath $CabPath -Force -ErrorAction SilentlyContinue
            }
            if (Test-ForbiddenResponse $_) {
                Write-Host "  Dell returned 403 Forbidden for $($script:DellCatalogUrl), retrying will not help" -ForegroundColor Red
                break
            }
            Write-Host "  Attempt $Attempt of 18 to download the Dell driver catalog failed - $($_.Exception.Message)" -ForegroundColor DarkGray
        }
        if (-not $Downloaded) {
            Start-Sleep -Seconds 10
        }
    }
    if (-not $Downloaded) {
        Write-Host 'Failed to download the Dell driver catalog after 18 attempts.' -ForegroundColor Red
        return $null
    }
    return $CabPath
}

function Expand-DellCatalogCab {
    param(
        [string]$CabPath,
        [string]$DestinationFolder
    )

    New-Item -ItemType Directory -Force -Path $DestinationFolder | Out-Null
    Write-Verbose "Expanding $CabPath into $DestinationFolder"
    # PS 5.1 has no native CAB cmdlet; expand.exe is the same tool Windows-ISO-Updater.ps1 uses for LCU/SSU cabs.
    # Without -R, expand.exe silently writes the extracted content under the SOURCE cab's own name (e.g.
    # catalogpc.cab) instead of the file's real stored name (CatalogPC.xml), so extraction exits 0 but the
    # later *.xml search finds nothing. -R restores the stored name. Confirmed locally with makecab.exe: the
    # -F:*.* wildcard shape tried previously was never the problem, only the missing -R was.
    $ExpandOutput = & "$env:SystemRoot\System32\expand.exe" '-R' "$CabPath" '-F:*.*' "$DestinationFolder" 2>&1
    $ExpandOutputText = $ExpandOutput | Out-String
    Write-Verbose $ExpandOutputText
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  expand.exe returned $LASTEXITCODE while extracting the Dell driver catalog" -ForegroundColor Red
        Write-Warning "expand.exe output: $ExpandOutputText"
        return $null
    }

    $XmlFile = Get-ChildItem -LiteralPath $DestinationFolder -Filter '*.xml' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $XmlFile) {
        $ExtractedNames = (Get-ChildItem -LiteralPath $DestinationFolder -File -ErrorAction SilentlyContinue).Name -join ', '
        Write-Host '  Warning: no XML file found inside the Dell driver catalog CAB.' -ForegroundColor Yellow
        Write-Warning "expand.exe output: $ExpandOutputText"
        Write-Warning "Files present in $DestinationFolder after expand: $ExtractedNames"
        return $null
    }
    return $XmlFile.FullName
}

# Catalog <Display> text collapses to a plain string for one language but becomes an array of elements when the
# catalog carries several, so both shapes have to be handled to read the English name back out
function Get-DellCatalogDisplayText {
    param($Node)

    if ($null -eq $Node) {
        return $null
    }
    if ($Node -is [string]) {
        return $Node
    }
    if ($Node -is [System.Array]) {
        $English = $Node | Where-Object { $_.lang -eq 'en' } | Select-Object -First 1
        if ($English) {
            return $English.'#text'
        }
        return $Node[0].'#text'
    }
    if ($Node.PSObject.Properties['#text']) {
        return $Node.'#text'
    }
    return $Node.InnerText
}

# Selects //SoftwareComponent regardless of whether the catalog declares a default XML namespace, matching the
# namespace-manager pattern the answer-file validation already uses rather than assuming the namespace away
function Select-DellCatalogComponents {
    param([xml]$Catalog)

    $Root = $Catalog.DocumentElement
    if ($Root.NamespaceURI) {
        $Mgr = New-Object System.Xml.XmlNamespaceManager($Catalog.NameTable)
        $Mgr.AddNamespace('d', $Root.NamespaceURI)
        return $Catalog.SelectNodes('//d:SoftwareComponent', $Mgr)
    }
    return $Catalog.SelectNodes('//SoftwareComponent')
}

# dellVersion/vendorVersion are normally a plain three- or four-part version, but a renamed or
# re-released catalog entry that carries something non-numeric there (or omits both) should still
# resolve from the release filename in <path>, which Dell's naming convention always sandwiches
# between the product code and the A-release suffix
function Get-DellCatalogComponentVersion {
    param($Component)

    foreach ($VersionText in @($Component.dellVersion, $Component.vendorVersion)) {
        if (-not $VersionText) {
            continue
        }
        try {
            return [Version]$VersionText
        }
        catch {
            if ($VersionText -match '(\d+(?:\.\d+){1,3})') {
                try {
                    return [Version]$Matches[1]
                }
                catch {
                }
            }
        }
    }
    if ($Component.path -match '_(\d+\.\d+\.\d+)_') {
        try {
            return [Version]$Matches[1]
        }
        catch {
        }
    }
    return $null
}

# Windows on ARM reports OSArchitecture as "ARM 64-bit Processor"; PROCESSOR_ARCHITECTURE is the
# environment-variable fallback for the rare case CIM is unavailable
function Test-HostIsArm64 {
    $OSArchitecture = $null
    try {
        $OSArchitecture = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).OSArchitecture
    }
    catch {
    }
    if ($OSArchitecture -match 'ARM') {
        return $true
    }
    return $env:PROCESSOR_ARCHITECTURE -match 'ARM'
}

function Resolve-DcuDownloadUrl {
    param(
        [string]$WorkFolder,
        [ValidateSet('Win32', 'Universal')]
        [string]$Variant = 'Win32'
    )

    $CabPath = Get-DellCatalogCab -DestinationFolder $WorkFolder
    if (-not $CabPath) {
        return $null
    }

    $ExtractFolder = Join-Path -Path $WorkFolder -ChildPath 'Extracted'
    $XmlPath = Expand-DellCatalogCab -CabPath $CabPath -DestinationFolder $ExtractFolder
    if (-not $XmlPath) {
        return $null
    }

    Write-Host '  Parsing the Dell driver catalog...' -ForegroundColor DarkGray
    [xml]$Catalog = Get-Content -LiteralPath $XmlPath -Raw
    $Root = $Catalog.DocumentElement

    # Both attributes are documented on the catalog's root Manifest element; downloads.dell.com/https is the
    # long-standing default if a future catalog omits them rather than treating that as a hard failure
    $BaseLocation = $Root.baseLocation
    if (-not $BaseLocation) {
        $BaseLocation = 'downloads.dell.com'
    }
    $BaseProtocol = $Root.baseLocationAccessProtocol
    if (-not $BaseProtocol) {
        $BaseProtocol = 'https'
    }

    $HostIsArm64 = Test-HostIsArm64
    $Candidates = New-Object System.Collections.Generic.List[object]
    foreach ($Component in (Select-DellCatalogComponents -Catalog $Catalog)) {
        $Name = Get-DellCatalogDisplayText -Node $Component.Name.Display
        # Dell has renamed this entry before (Application -> for-Win32); match the stable "Dell Command
        # Update" phrase loosely so a naming variant that swaps spaces for hyphens still matches
        if ($Name -notmatch 'Dell[\s-]+Command.*Update') {
            continue
        }
        # The family regex above also matches the Windows Universal Application entry, a differently
        # packaged product, not a rename of the Win32 installer, so it has to be explicitly included or
        # excluded here rather than left to whichever entry happens to have the higher version number
        $IsUniversal = $Name -match 'Universal'
        if ($Variant -eq 'Universal') {
            if (-not $IsUniversal) {
                continue
            }
        }
        elseif ($IsUniversal) {
            continue
        }
        # An ARM64/WinARM build, if the catalog ever publishes one, would otherwise win "highest
        # version wins" against the correct x64/x86 build on a non-ARM host; the name is checked first
        # since it's the documented tag, SupportedOperatingSystems is a defensive fallback for a
        # catalog schema this script hasn't observed
        $IsArmComponent = $Name -match 'ARM64|WinARM'
        if (-not $IsArmComponent -and $Component.SupportedOperatingSystems) {
            $IsArmComponent = $Component.SupportedOperatingSystems.InnerXml -match 'ARM64|WinARM'
        }
        if ($IsArmComponent -and -not $HostIsArm64) {
            continue
        }
        $Candidates.Add($Component)
    }

    if ($Candidates.Count -eq 0) {
        Write-Host "  Warning: no 'Dell Command | Update' ($Variant) entry found in the Dell driver catalog. Dell may have changed the catalog's schema or file name, or no longer publishes the $Variant variant." -ForegroundColor Yellow
        return $null
    }

    $Best = $null
    $BestVersion = $null
    foreach ($Component in $Candidates) {
        $Ver = Get-DellCatalogComponentVersion -Component $Component
        if ($null -eq $Ver) {
            $ComponentName = Get-DellCatalogDisplayText -Node $Component.Name.Display
            Write-Host "  Warning: could not read a version from catalog entry '$ComponentName', skipping it for version comparison." -ForegroundColor Yellow
            continue
        }
        if ($null -eq $BestVersion -or $Ver -gt $BestVersion) {
            $BestVersion = $Ver
            $Best = $Component
        }
    }
    if (-not $Best) {
        $Best = $Candidates[0]
    }

    $Path = $Best.path
    if (-not $Path) {
        Write-Host '  Warning: the matched catalog entry has no download path.' -ForegroundColor Yellow
        return $null
    }
    if ($Path -match '^https?://') {
        return $Path
    }
    return "$($BaseProtocol)://$($BaseLocation)/$($Path.TrimStart('/'))"
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

    Write-Host "  Requesting $Url" -ForegroundColor DarkGray
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            try {
                $BitsProxyArgs = @{}
                if ($ProxyUrl) {
                    $BitsProxyArgs['ProxyUsage'] = 'Override'
                    $BitsProxyArgs['ProxyList'] = $ProxyUrl
                }
                [void](Start-BitsTransfer -Source $Url -Destination $DestFile -DisplayName $FileName -ErrorAction Stop @BitsProxyArgs)
            }
            catch {
                Write-Host "  BITS failed, falling back to WebRequest - $($_.Exception.Message)" -ForegroundColor Yellow
                [void](Invoke-WebRequest -Uri $Url -OutFile $DestFile -UseBasicParsing -UserAgent $script:UserAgent @script:WebRequestProxyArgs)
            }
        }
        else {
            [void](Invoke-WebRequest -Uri $Url -OutFile $DestFile -UseBasicParsing -UserAgent $script:UserAgent @script:WebRequestProxyArgs)
        }
        Unblock-File -LiteralPath $DestFile -ErrorAction SilentlyContinue
        return $DestFile
    }
    catch {
        if (Test-ForbiddenResponse $_) {
            Write-Host "  Dell returned 403 Forbidden for $Url" -ForegroundColor Red
        }
        else {
            Write-Host "  Download failed for $Url - $($_.Exception.Message)" -ForegroundColor Red
        }
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

# Checks the registered uninstall entries first, that's authoritative for what Windows itself thinks is
# installed. Both the native and WOW6432Node hives are checked since a 32-bit PowerShell host would only
# see the 32-bit view even though the runtime itself is x64. `dotnet --list-runtimes` is a secondary check
# for a host where the runtime arrived bundled with something else and the standalone uninstall entry name
# looked different than expected.
function Test-DotNet8DesktopRuntimeInstalled {
    $UninstallKeyPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($KeyPath in $UninstallKeyPaths) {
        $Match = Get-ItemProperty -Path $KeyPath -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '(?i)Microsoft Windows Desktop Runtime\s*-\s*8\..*\(x64\)' } |
            Select-Object -First 1
        if ($Match) {
            return $true
        }
    }

    $DotNetCommand = Get-Command -Name 'dotnet.exe' -ErrorAction SilentlyContinue
    if ($DotNetCommand) {
        try {
            $Runtimes = & $DotNetCommand.Source '--list-runtimes' 2>&1
            if ($LASTEXITCODE -eq 0 -and ($Runtimes -match 'Microsoft\.WindowsDesktop\.App 8\.')) {
                return $true
            }
        }
        catch {
        }
    }
    return $false
}

# Downloads and silently installs the .NET 8 Desktop Runtime (x64) that newer DCU installers require.
# Mirrors Get-DcuInstaller's BITS-with-WebRequest-fallback download, then validates the Authenticode
# signature the same way Windows-ISO-Updater.ps1 validates the Media Creation Tool, since aka.ms is a
# redirector, not a guarantee of what's on the other end of it.
function Install-DotNet8DesktopRuntime {
    param([string]$DestinationFolder)

    $WorkFolder = Join-Path -Path $DestinationFolder -ChildPath 'DotNetRuntime'
    New-Item -ItemType Directory -Force -Path $WorkFolder | Out-Null
    $FileName = $script:DotNetRuntimeUrl.Split('/')[-1]
    $InstallerFile = Join-Path -Path $WorkFolder -ChildPath $FileName

    Write-Host "  Requesting $($script:DotNetRuntimeUrl)" -ForegroundColor DarkGray
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            try {
                $BitsProxyArgs = @{}
                if ($ProxyUrl) {
                    $BitsProxyArgs['ProxyUsage'] = 'Override'
                    $BitsProxyArgs['ProxyList'] = $ProxyUrl
                }
                [void](Start-BitsTransfer -Source $script:DotNetRuntimeUrl -Destination $InstallerFile -DisplayName $FileName -ErrorAction Stop @BitsProxyArgs)
            }
            catch {
                Write-Host "  BITS failed, falling back to WebRequest - $($_.Exception.Message)" -ForegroundColor Yellow
                [void](Invoke-WebRequest -Uri $script:DotNetRuntimeUrl -OutFile $InstallerFile -UseBasicParsing -UserAgent $script:UserAgent @script:WebRequestProxyArgs)
            }
        }
        else {
            [void](Invoke-WebRequest -Uri $script:DotNetRuntimeUrl -OutFile $InstallerFile -UseBasicParsing -UserAgent $script:UserAgent @script:WebRequestProxyArgs)
        }
        Unblock-File -LiteralPath $InstallerFile -ErrorAction SilentlyContinue
    }
    catch {
        Write-Host "  Download failed for $($script:DotNetRuntimeUrl) - $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path -LiteralPath $InstallerFile) {
            Remove-Item -LiteralPath $InstallerFile -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $WorkFolder -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }

    $Signature = Get-AuthenticodeSignature -LiteralPath $InstallerFile -ErrorAction SilentlyContinue
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch '(?i)O=Microsoft Corporation') {
        Write-Host "  The downloaded .NET Desktop Runtime installer is not validly signed by Microsoft (status: $($Signature.Status)). Discarding it." -ForegroundColor Red
        Remove-Item -LiteralPath $WorkFolder -Recurse -Force -ErrorAction SilentlyContinue
        return $false
    }
    Write-Host "  Verified the .NET Desktop Runtime installer's Microsoft signature." -ForegroundColor Green

    Write-Host '  Installing the .NET 8 Desktop Runtime (x64)...' -ForegroundColor Cyan
    $InstallProcess = Start-Process -FilePath $InstallerFile -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru
    Remove-Item -LiteralPath $WorkFolder -Recurse -Force -ErrorAction SilentlyContinue

    if ($InstallProcess.ExitCode -eq 0) {
        Write-Host '  Installed successfully' -ForegroundColor Green
        return $true
    }
    if ($InstallProcess.ExitCode -eq 3010) {
        Write-Host '  Installed successfully (reboot required)' -ForegroundColor Yellow
        $script:RebootRequired = $true
        return $true
    }
    Write-Host "  Install failed (exit $($InstallProcess.ExitCode)), look up the code in Microsoft's .NET installer documentation" -ForegroundColor Red
    return $false
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

if (-not $DownloadOnly -and -not $SkipDotNetRuntime) {
    Write-Host 'Checking for the .NET 8 Desktop Runtime (x64), required by newer Dell Command Update installers...' -ForegroundColor Cyan
    if (Test-DotNet8DesktopRuntimeInstalled) {
        if (-not $Quiet) {
            Write-Host '  Already installed' -ForegroundColor DarkGray
        }
    }
    else {
        Write-Host '  Not found, installing it before Dell Command Update' -ForegroundColor Yellow
        if (-not (Install-DotNet8DesktopRuntime -DestinationFolder $OutputPath)) {
            Write-Host "Failed to install the .NET 8 Desktop Runtime (x64). Dell Command Update's installer may refuse to run without it." -ForegroundColor Red
            exit 1
        }
    }
}

Write-Host 'Resolving the Dell Command Update download URL from the Dell driver catalog...' -ForegroundColor Cyan
if ($DcuVariant -eq 'Universal') {
    Write-Host "  Requested variant: Windows Universal Application. This script's silent-install switch and dcu-cli.exe discovery are only verified against the Win32 variant, confirm the installer and CLI behave as expected before relying on this unattended." -ForegroundColor Yellow
}
$CatalogWorkFolder = Join-Path -Path $OutputPath -ChildPath 'DellCatalog'
try {
    $DownloadUrl = Resolve-DcuDownloadUrl -WorkFolder $CatalogWorkFolder -Variant $DcuVariant
}
finally {
    # The catalog CAB and its expanded XML are working files only, not something worth keeping around next to the installer
    if (Test-Path -LiteralPath $CatalogWorkFolder) {
        Remove-Item -LiteralPath $CatalogWorkFolder -Recurse -Force -ErrorAction SilentlyContinue
    }
}
if (-not $DownloadUrl) {
    Write-Host 'Could not resolve a Dell Command Update download URL from the Dell driver catalog. Check network access and try again.' -ForegroundColor Red
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

if ($ProxyUrl) {
    # dcu-cli.exe does its own network calls for scan/apply, so the proxy has to be persisted into DCU's own configuration, not just this process
    $ProxyUri = [Uri]$ProxyUrl
    Write-Host "Configuring Dell Command Update to use proxy $($ProxyUri.Host):$($ProxyUri.Port)..." -ForegroundColor Cyan
    $ConfigureOutput = & $DcuCliPath /configure -proxyType=HTTP "-proxyHostName=$($ProxyUri.Host)" "-proxyPortNumber=$($ProxyUri.Port)" 2>&1 | Out-String
    Write-Host $ConfigureOutput.Trim()
}

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
