<#
.SYNOPSIS
    Downloads Microsoft Surface driver MSI packages and organises them into the folder structure
    required by Examples/autounattend-driver-install.xml.

.DESCRIPTION
    The script discovers all available Surface driver packages by scraping the Microsoft
    Surface drivers support page, then resolves each link to a direct MSI download URL. It downloads
    each package to:

        <OutputPath>\<WMI Model Name>\<filename>.msi

    Folder names are the exact strings returned by (Get-CimInstance Win32_ComputerSystem).Model on
    the target hardware, because Install-ModelDrivers.ps1 in the answer file does a substring match
    against that value.

    If a file is already present it is skipped, so re-runs are safe and incremental. BITS is used
    when available, with a fallback to Invoke-WebRequest.

.PARAMETER OutputPath
    Root folder to write driver packages into. Each model gets a subfolder named after its exact
    WMI model string. Defaults to .\Drivers in the current directory.

.PARAMETER WindowsVersion
    Windows version the drivers must target: 10 or 11. Defaults to 11.

.PARAMETER Models
    One or more model names to download, matching entries in the internal catalog. Omit to download
    all models that have a driver for the requested Windows version.

.PARAMETER ListModels
    List available models in the catalog and exit without downloading anything.

.PARAMETER Quiet
    Suppress detail lines; show only headings and the final summary.

.EXAMPLE
    .\tools\Get-SurfaceDrivers.ps1
    Downloads Windows 11 driver packages for every catalogued model into .\Drivers\.

.EXAMPLE
    .\tools\Get-SurfaceDrivers.ps1 -Models 'Surface Pro 9', 'Surface Laptop 5' -OutputPath D:\DriverStaging
    Downloads only the two named models to D:\DriverStaging.

.EXAMPLE
    .\tools\Get-SurfaceDrivers.ps1 -ListModels
    Prints the catalog table and exits without downloading anything.

.EXAMPLE
    .\tools\Get-SurfaceDrivers.ps1 -WindowsVersion 10 -Quiet
    Downloads Windows 10 packages for all supported models, showing only headings and the summary.

.NOTES
    Folder names match the exact string returned by (Get-CimInstance Win32_ComputerSystem).Model on
    the target hardware.

    Place the Drivers\ output under $OEM$\$1\ on your boot media. Windows Setup copies $OEM$\$1\
    to C:\ before the specialize pass runs, making C:\Drivers\ is populated when Install-ModelDrivers.ps1
    executes.

    Model names and download links are discovered at runtime from
    https://support.microsoft.com/en-us/surface/drivers-firmware/download-drivers-and-firmware-for-surface
    so the catalog is always current. No hardcoded ID table needs updating.
#>
[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Root folder to write driver packages into. Each model gets a subfolder named after its exact WMI model string. Defaults to .\Drivers in the current directory.')]
    [string]$OutputPath = '.\Drivers',

    [Parameter(HelpMessage = 'Windows version the drivers must target: 10 or 11. Defaults to 11.')]
    [ValidateSet('10', '11')]
    [string]$WindowsVersion = '11',

    [Parameter(HelpMessage = 'One or more model names to download, matching entries in the internal catalog. Omit to download all models that have a driver for the requested Windows version.')]
    [string[]]$Models,

    [Parameter(HelpMessage = 'List available models in the catalog and exit without downloading anything.')]
    [switch]$ListModels,

    [Parameter(HelpMessage = 'Suppress detail lines; show only headings and the final summary.')]
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-CatalogFromSupportPage {
    param([string]$WindowsVersion)

    $MainUrl = 'https://support.microsoft.com/en-us/surface/drivers-firmware/download-drivers-and-firmware-for-surface'
    $FamilyBase = 'https://support.microsoft.com/en-us/surface/drivers-firmware/download-drivers-and-firmware-for-surface-'
    $Catalog = [ordered]@{}

    try {
        [void]($MainResponse = Invoke-WebRequest -Uri $MainUrl -UseBasicParsing -TimeoutSec 30)
    }
    catch {
        Write-Host "Failed to fetch Surface support page - $($_.Exception.Message)" -ForegroundColor Red
        return $Catalog
    }

    $MainText = $null
    $NextMatches = [regex]::Matches($MainResponse.Content, '<script id="__NEXT_DATA__"[^>]*>([\s\S]+?)</script>')
    if ($NextMatches.Count -gt 0) {
        $MainText = $NextMatches[0].Groups[1].Value
    }
    if (-not $MainText) {
        $MainText = $MainResponse.Content
    }
    $MainText = $MainText -replace '\\/', '/'

    # Family sub-pages carry the full path prefix plus a distinct slug
    $SlugMatches = [regex]::Matches($MainText, 'download-drivers-and-firmware-for-surface-([a-z][a-z0-9-]*)')
    $FamilyUrls = New-Object System.Collections.ArrayList
    $SeenSlugs = @{}
    foreach ($SlugMatch in $SlugMatches) {
        $FamilyUrl = $FamilyBase + $SlugMatch.Groups[1].Value
        if (-not $SeenSlugs.ContainsKey($FamilyUrl)) {
            [void]$FamilyUrls.Add($FamilyUrl)
            $SeenSlugs[$FamilyUrl] = $true
        }
    }

    # Guarantee well-known families are visited even if absent from the __NEXT_DATA__ blob
    foreach ($KnownSlug in @('book', 'go', 'hub', 'laptop', 'laptop-go', 'pro', 'studio')) {
        $FamilyUrl = $FamilyBase + $KnownSlug
        if (-not $SeenSlugs.ContainsKey($FamilyUrl)) {
            [void]$FamilyUrls.Add($FamilyUrl)
            $SeenSlugs[$FamilyUrl] = $true
        }
    }

    if ($FamilyUrls.Count -eq 0) {
        Write-Host '  Warning: no family sub-pages found on the main support page.' -ForegroundColor Yellow
        return $Catalog
    }

    # Use $FamilyUrls as the initial visit queue; grow it as sub-pages are found
    $Visited = @{}
    $QueueIndex = 0
    $InitialCount = $FamilyUrls.Count

    while ($QueueIndex -lt $FamilyUrls.Count) {
        $PageUrl = $FamilyUrls[$QueueIndex]
        $QueueIndex++

        if ($Visited.ContainsKey($PageUrl)) { continue }
        $Visited[$PageUrl] = $true

        if ($QueueIndex -le $InitialCount) {
            Write-Host "  Scanning: $PageUrl" -ForegroundColor DarkGray
        }

        $PageResponse = $null
        try {
            [void]($PageResponse = Invoke-WebRequest -Uri $PageUrl -UseBasicParsing -TimeoutSec 30)
        }
        catch {
            Write-Host "  Warning: failed to fetch '$PageUrl' - $($_.Exception.Message)" -ForegroundColor Yellow
            continue
        }

        $PageText = $PageResponse.Content
        $PageText = $PageText -replace '\\/', '/'

        # Discover model sub-pages linked from this family page and queue any not yet seen
        $SubSlugMatches = [regex]::Matches($PageText, 'download-drivers-and-firmware-for-surface-([a-z][a-z0-9-]*)')
        foreach ($SubSlugMatch in $SubSlugMatches) {
            $SubUrl = $FamilyBase + $SubSlugMatch.Groups[1].Value
            if (-not $Visited.ContainsKey($SubUrl) -and -not $SeenSlugs.ContainsKey($SubUrl)) {
                [void]$FamilyUrls.Add($SubUrl)
                $SeenSlugs[$SubUrl] = $true
            }
        }

        # Table rows pair model name (first td) with download link href (second td)
        $RowPattern = '<tr>\s*<td>\s*([^<>]{1,100}?)\s*</td>\s*<td>[^<]*<a[^>]+href="(https://www\.microsoft\.com/(?:[a-z-]+/)?download/details\.aspx\?id=\d+)"'
        $RowMatches = [regex]::Matches($PageText, $RowPattern)
        foreach ($RowMatch in $RowMatches) {
            $ModelName = $RowMatch.Groups[1].Value.Trim()
            $DownloadUrl = $RowMatch.Groups[2].Value
            if ($ModelName -and -not $Catalog.Contains($ModelName)) {
                $Catalog[$ModelName] = $DownloadUrl
            }
        }
    }

    return $Catalog
}

function Select-HighestVersionUrl {
    param(
        [string[]]$Urls,
        [string]$VersionTag
    )

    $Filtered = @($Urls | Where-Object { $_ -like "*$VersionTag*" })
    if ($Filtered.Count -eq 0) {
        $Filtered = $Urls
    }

    $Best = $null
    $BestVersion = $null
    foreach ($Candidate in $Filtered) {
        $FileName = $Candidate.Split('/')[-1]
        $VersionMatch = [regex]::Match($FileName, '(\d+\.\d+\.\d+\.\d+)')
        if ($VersionMatch.Success) {
            try {
                $Ver = [Version]$VersionMatch.Groups[1].Value
                if ($BestVersion -eq $null -or $Ver -gt $BestVersion) {
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
    return $Filtered[0]
}

function Resolve-MsiDownloadUrl {
    param(
        [string]$Url,
        [string]$WindowsVersion
    )

    $VersionTag = if ($WindowsVersion -eq '10') { '_Win10_' } else { '_Win11_' }
    $MsiPattern = 'https://download\.microsoft\.com/[^"'']+\.msi'

    # Extract ?id= for use in confirmation URL construction
    $Id = $null
    if ($Url -match '\?id=(\d+)') {
        $Id = $Matches[1]
    }

    # Fetch the no_redirect page to find direct download links
    $NoRedirectUrl = $null
    if ($Id) {
        $NoRedirectUrl = "https://www.microsoft.com/en-us/download/confirmation.aspx?id=$Id&no_redirect=true"
    }
    elseif ($Url -match 'go\.microsoft\.com/fwlink') {
        $NoRedirectUrl = if ($Url -match '&no_redirect=true') { $Url } else { "$Url&no_redirect=true" }
    }

    if (-not $NoRedirectUrl) {
        Write-Host "  Warning: cannot construct no_redirect URL for '$Url'" -ForegroundColor Yellow
        return $null
    }

    $SpaResponse = $null
    try {
        [void]($SpaResponse = Invoke-WebRequest -Uri $NoRedirectUrl -UseBasicParsing -TimeoutSec 30)
    }
    catch {
        Write-Host "  Warning: could not resolve download URL for '$Url' - $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }

    $SpaContent = $SpaResponse.Content -replace '\\/', '/'

    $Candidates = @()

    $UrlMatches = [regex]::Matches($SpaContent, $MsiPattern)
    foreach ($m in $UrlMatches) {
        $Candidates += $m.Value
    }

    if ($Candidates.Count -eq 0) {
        return $null
    }

    return Select-HighestVersionUrl -Urls $Candidates -VersionTag $VersionTag
}

function Get-DriverPackage {
    param(
        [string]$Url,
        [string]$DestinationFolder
    )

    New-Item -ItemType Directory -Force -Path $DestinationFolder | Out-Null
    $FileName = $Url.Split('/')[-1]
    $DestFile = Join-Path -Path $DestinationFolder -ChildPath $FileName

    if (Test-Path -LiteralPath $DestFile) {
        if (-not $Quiet) {
            Write-Host "    Already present: $FileName" -ForegroundColor DarkGray
        }
        return $true
    }

    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            try {
                [void](Start-BitsTransfer -Source $Url -Destination $DestFile -DisplayName $FileName -ErrorAction Stop)
            }
            catch {
                Write-Host "    BITS failed, falling back to WebRequest - $($_.Exception.Message)" -ForegroundColor Yellow
                [void](Invoke-WebRequest -Uri $Url -OutFile $DestFile -UseBasicParsing)
            }
        }
        else {
            [void](Invoke-WebRequest -Uri $Url -OutFile $DestFile -UseBasicParsing)
        }
        Unblock-File -LiteralPath $DestFile -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        Write-Host "    Download failed - $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path -LiteralPath $DestFile) {
            Remove-Item -LiteralPath $DestFile -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

# Resolve to an absolute path before any path operations.
if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path -Path (Get-Location).Path -ChildPath $OutputPath
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

if ($ListModels) {
    Write-Host 'Fetching model catalog from Microsoft Support...' -ForegroundColor DarkGray
    $LiveCatalog = Get-CatalogFromSupportPage -WindowsVersion $WindowsVersion
    if ($LiveCatalog.Count -eq 0) {
        Write-Host 'No driver links found on the support page. Check network access and try again.' -ForegroundColor Red
        exit 1
    }
    Write-Host 'Available models:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('{0,-40} {1}' -f 'Model', 'URL') -ForegroundColor Cyan
    Write-Host ('-' * 100) -ForegroundColor DarkGray
    foreach ($Name in ($LiveCatalog.Keys | Sort-Object)) {
        Write-Host ('{0,-40} {1}' -f $Name, $LiveCatalog[$Name])
    }
    Write-Host ''
    exit 0
}

Write-Host 'Fetching model catalog from Microsoft Support...' -ForegroundColor DarkGray
$LiveCatalog = Get-CatalogFromSupportPage -WindowsVersion $WindowsVersion

if ($LiveCatalog.Count -eq 0) {
    Write-Host 'No driver links found on the support page. Check network access and try again.' -ForegroundColor Red
    exit 1
}

if ($Models -and $Models.Count -gt 0) {
    foreach ($RequestedName in $Models) {
        if (-not $LiveCatalog.Contains($RequestedName)) {
            Write-Host "Warning: '$RequestedName' is not in the catalog; use -ListModels to see available models." -ForegroundColor Yellow
        }
    }
    $TargetModels = @($Models | Where-Object { $LiveCatalog.Contains($_) })
}
else {
    $TargetModels = @($LiveCatalog.Keys)
}

if ($TargetModels.Count -eq 0) {
    Write-Host "No models to process for Windows $WindowsVersion." -ForegroundColor Yellow
    exit 0
}

Write-Host "Surface driver download - Windows $WindowsVersion - $($TargetModels.Count) model(s)" -ForegroundColor Cyan
Write-Host "Output: $OutputPath" -ForegroundColor DarkGray
Write-Host ''

$SummaryRows = New-Object System.Collections.Generic.List[object]

foreach ($ModelName in ($TargetModels | Sort-Object)) {
    if (-not $Quiet) {
        Write-Host "  $ModelName" -ForegroundColor Cyan
    }

    $DriverUrl = $LiveCatalog[$ModelName]
    $ModelFolder = Join-Path -Path $OutputPath -ChildPath $ModelName

    if (-not $Quiet) {
        Write-Host "    Resolving $DriverUrl ..." -ForegroundColor DarkGray
    }

    $MsiUrl = Resolve-MsiDownloadUrl -Url $DriverUrl -WindowsVersion $WindowsVersion
    if (-not $MsiUrl) {
        Write-Host "  Warning: no download URL found for '$ModelName' ($DriverUrl)." -ForegroundColor Yellow
        $SummaryRows.Add([pscustomobject]@{
            Model  = $ModelName
            Result = 'Failed - no URL'
            Detail = $DriverUrl
        })
        continue
    }

    if (-not $Quiet) {
        Write-Host "    $MsiUrl" -ForegroundColor DarkGray
    }

    $FileName = $MsiUrl.Split('/')[-1]
    $DestFile = Join-Path -Path $ModelFolder -ChildPath $FileName
    $AlreadyPresent = Test-Path -LiteralPath $DestFile

    $Success = Get-DriverPackage -Url $MsiUrl -DestinationFolder $ModelFolder

    if ($Success) {
        $ResultLabel = if ($AlreadyPresent) { 'Already present' } else { 'Downloaded' }
        if ((-not $Quiet) -and (-not $AlreadyPresent)) {
            Write-Host "    Downloaded: $FileName" -ForegroundColor Green
        }
        $SummaryRows.Add([pscustomobject]@{
            Model  = $ModelName
            Result = $ResultLabel
            Detail = $DestFile
        })
    }
    else {
        $SummaryRows.Add([pscustomobject]@{
            Model  = $ModelName
            Result = 'Failed'
            Detail = $MsiUrl
        })
    }
}

Write-Host ''
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ('-' * 80) -ForegroundColor DarkGray

foreach ($Row in $SummaryRows) {
    $RowColor = switch ($Row.Result) {
        'Downloaded'      { 'Green' }
        'Already present' { 'DarkGray' }
        default           { 'Yellow' }
    }
    Write-Host ('{0,-40} {1,-16} {2}' -f $Row.Model, $Row.Result, $Row.Detail) -ForegroundColor $RowColor
}

Write-Host ''
exit 0
