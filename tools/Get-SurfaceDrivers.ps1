<#
.SYNOPSIS
    Downloads Microsoft Surface driver MSI packages and organises them into the folder structure
    required by Examples/autounattend-driver-install.xml.

.DESCRIPTION
    For each requested model, the script resolves the direct MSI download URL from the Microsoft
    Download Center, then downloads the package to:

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

    Verify and update the page ID table from the Microsoft Surface Driver and Firmware Lifecycle page
    at the URL in the catalog comment inside this script.
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
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Verify/update page IDs from: https://learn.microsoft.com/en-us/surface/surface-driver-and-firmware-lifecycle-for-surface-devices
$ModelCatalog = @{
    'Surface Pro 9'                 = @{ Win10 = 104679; Win11 = 104679 }
    'Surface Pro 9 with 5G'        = @{ Win11 = 104721 }
    'Surface Pro 10 for Business'  = @{ Win11 = 105937 }
    'Surface Laptop 5'              = @{ Win10 = 104678; Win11 = 104678 }
    'Surface Laptop 6 for Business' = @{ Win11 = 105938 }
    'Surface Go 3'                  = @{ Win10 = 103039; Win11 = 103039 }
    'Surface Go 4'                  = @{ Win11 = 105543 }
    'Surface Book 3'                = @{ Win10 = 101315; Win11 = 101315 }
    'Surface Studio 2+'             = @{ Win11 = 105067 }
}

function Resolve-MsiDownloadUrl {
    param(
        [int]$PageId,
        [string]$WindowsVersion
    )

    $ConfirmUrl = "https://www.microsoft.com/en-us/download/confirmation.aspx?id=$PageId&no_redirect=true"
    try {
        $Response = Invoke-WebRequest -Uri $ConfirmUrl -UseBasicParsing -TimeoutSec 30
        $MsiMatches = [regex]::Matches($Response.Content, 'https://download\.microsoft\.com/[^"'']+\.msi')
        if ($MsiMatches.Count -eq 0) {
            return $null
        }
        $VersionTag = if ($WindowsVersion -eq '10') { '_Win10_' } else { '_Win11_' }
        $Preferred = $MsiMatches | Where-Object { $_.Value -like "*$VersionTag*" } | Select-Object -First 1
        if ($Preferred) {
            return $Preferred.Value
        }
        return $MsiMatches[0].Value
    }
    catch {
        Write-Host "  Warning: could not resolve download URL for page ID $PageId - $_" -ForegroundColor Yellow
        return $null
    }
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
                Start-BitsTransfer -Source $Url -Destination $DestFile -DisplayName $FileName -ErrorAction Stop
            }
            catch {
                Write-Host "    BITS failed, falling back to WebRequest - $_" -ForegroundColor Yellow
                Invoke-WebRequest -Uri $Url -OutFile $DestFile -UseBasicParsing
            }
        }
        else {
            Invoke-WebRequest -Uri $Url -OutFile $DestFile -UseBasicParsing
        }
        Unblock-File -LiteralPath $DestFile -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        Write-Host "    Download failed - $_" -ForegroundColor Red
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
    Write-Host 'Available models:' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ('{0,-40} {1,-10} {2}' -f 'Model', 'Win10 ID', 'Win11 ID') -ForegroundColor Cyan
    Write-Host ('-' * 65) -ForegroundColor DarkGray
    foreach ($Name in ($ModelCatalog.Keys | Sort-Object)) {
        $Entry = $ModelCatalog[$Name]
        $W10 = if ($Entry.ContainsKey('Win10')) { $Entry['Win10'].ToString() } else { '-' }
        $W11 = if ($Entry.ContainsKey('Win11')) { $Entry['Win11'].ToString() } else { '-' }
        Write-Host ('{0,-40} {1,-10} {2}' -f $Name, $W10, $W11)
    }
    Write-Host ''
    exit 0
}

$VersionKey = "Win$WindowsVersion"

if ($Models -and $Models.Count -gt 0) {
    foreach ($RequestedName in $Models) {
        if (-not $ModelCatalog.ContainsKey($RequestedName)) {
            Write-Host "Warning: '$RequestedName' is not in the catalog; use -ListModels to see available models." -ForegroundColor Yellow
        }
    }
    $TargetModels = @($Models | Where-Object {
        $ModelCatalog.ContainsKey($_) -and $ModelCatalog[$_].ContainsKey($VersionKey)
    })
    $NoVersionModels = @($Models | Where-Object {
        $ModelCatalog.ContainsKey($_) -and -not $ModelCatalog[$_].ContainsKey($VersionKey)
    })
    foreach ($Name in $NoVersionModels) {
        Write-Host "Warning: '$Name' has no Windows $WindowsVersion driver in the catalog; skipping." -ForegroundColor Yellow
    }
}
else {
    $TargetModels = @($ModelCatalog.Keys | Where-Object { $ModelCatalog[$_].ContainsKey($VersionKey) })
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

    $PageId = $ModelCatalog[$ModelName][$VersionKey]
    $ModelFolder = Join-Path -Path $OutputPath -ChildPath $ModelName

    if (-not $Quiet) {
        Write-Host "    Resolving page ID $PageId ..." -ForegroundColor DarkGray
    }

    $MsiUrl = Resolve-MsiDownloadUrl -PageId $PageId -WindowsVersion $WindowsVersion
    if (-not $MsiUrl) {
        Write-Host "  Warning: no download URL found for '$ModelName' (page ID $PageId)." -ForegroundColor Yellow
        $SummaryRows.Add([pscustomobject]@{
            Model  = $ModelName
            Result = 'Failed - no URL'
            Detail = "Page ID $PageId"
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
