<#
.SYNOPSIS
    Checks that everything Windows-ISO-Updater.ps1 depends on outside this repository is still there,
    still trustworthy, and still shaped the way the script expects.

.DESCRIPTION
    The main script pins a handful of external things it cannot control: a symbol-server URL and SHA-256
    for oscdimg.exe, a GitHub URL for the Fido helper plus a set of content checks it has to pass,
    Microsoft fwlinks for the Media Creation Tool and the ADK, and the HTML layout of the Microsoft Update
    Catalog and the KB support pages, neither of which has a public API. Any of those can change without
    warning, and the failure usually only shows up an hour into a build.

    This tester exercises all of them and says, in plain terms, what in the script has to change.

    It reads the pinned values straight out of Windows-ISO-Updater.ps1 and extracts the real parsing and
    validation functions from its AST, so it always tests the code as written rather than a copy that can
    drift. The main script is never run: only the extracted function definitions are materialised, and the
    downloaded Fido helper is parsed, never executed.

.EXAMPLE
    .\tools\Test-Dependencies.ps1
    Runs every check. Downloads oscdimg.exe (~140 KB) and Fido.ps1 (~55 KB) to the temp folder, and only
    resolves the Media Creation Tool and ADK links without fetching them.

.EXAMPLE
    .\tools\Test-Dependencies.ps1 -Deep
    Also downloads the Media Creation Tool and the ADK bootstrapper and verifies their Authenticode
    signatures, the way the script does at run time.

.EXAMPLE
    .\tools\Test-Dependencies.ps1 -Quiet
    Prints only the summary and the actions. Useful from a scheduled task.

.NOTES
    Exit codes: 0 when nothing is broken, 1 when at least one check failed, 2 when only warnings were
    raised. Network access is required, and a corporate proxy or a blocked catalog will look like a
    failure, so read the messages before changing anything.
#>
[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Path to Windows-ISO-Updater.ps1. Defaults to the copy next to this tools folder')]
    [string]$ScriptPath,

    [Parameter(HelpMessage = 'Also download the Media Creation Tool and the ADK bootstrapper and verify their Microsoft signatures')]
    [switch]$Deep,

    [Parameter(HelpMessage = 'Catalog search to test the Update Catalog parsing with. Defaults to the current client cumulative update')]
    [string]$CatalogQuery = 'Cumulative Update for Windows 11 Version 24H2 x64',

    [Parameter(HelpMessage = 'Seconds to wait on any single web request')]
    [ValidateRange(5, 600)]
    [int]$TimeoutSec = 60,

    [Parameter(HelpMessage = 'Print only the summary and the actions')]
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Resolve the script under test ---

if (-not $ScriptPath) {
    $ScriptPath = Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath 'Windows-ISO-Updater.ps1'
}
if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "Cannot find Windows-ISO-Updater.ps1 at '$ScriptPath'. Pass -ScriptPath." -ForegroundColor Red
    exit 1
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$TempRoot = Join-Path -Path $env:TEMP -ChildPath "WISO-DepCheck_$PID"

# --- Result collection ---

$Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Warn', 'Fail')][string]$Status,
        [Parameter(Mandatory)][string]$Message,
        [string]$Action
    )

    $Results.Add([PSCustomObject]@{
            Area    = $Area
            Status  = $Status
            Message = $Message
            Action  = $Action
        })

    if ($Quiet) { return }
    $Color = switch ($Status) { 'Pass' { 'Green' } 'Warn' { 'Yellow' } default { 'Red' } }
    Write-Host ('  [{0}] {1}' -f $Status.ToUpper(), $Message) -ForegroundColor $Color
}

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    if ($Quiet) { return }
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
}

function Write-Detail {
    param([Parameter(Mandatory)][string]$Message)
    if (-not $Quiet) { Write-Host "        $Message" -ForegroundColor DarkGray }
}

# Where a response actually came from, after redirects. Windows PowerShell hands back an HttpWebResponse
# with a ResponseUri, while PowerShell 7 hands back an HttpResponseMessage that has no such property and
# tracks the final hop on RequestMessage instead.
function Get-FinalUri {
    param($Response)

    if (-not $Response) { return $null }
    $Uri = $null
    try { $Uri = $Response.ResponseUri } catch { }
    if (-not $Uri) { try { $Uri = $Response.RequestMessage.RequestUri } catch { } }
    if ($Uri) { return $Uri.AbsoluteUri }
    return $null
}

# Follows a Microsoft fwlink to whatever it points at today, without pulling the payload down. A retired
# link still answers, so $Failure is set only when the request never completed at all, which is a network
# problem rather than anything to do with the link.
function Resolve-RedirectUrl {
    param(
        [Parameter(Mandatory)][string]$Url,
        [ref]$Failure
    )

    if ($Failure) { $Failure.Value = $null }
    $LastError = $null
    # Some CDN nodes reject HEAD outright, so GET is tried before the link is called dead.
    foreach ($Method in 'Head', 'Get') {
        try {
            $Response = Invoke-WebRequest -Uri $Url -Method $Method -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
            $Final = Get-FinalUri -Response $Response.BaseResponse
            if ($Final) { return $Final }
            $LastError = 'The response carried no final URI.'
        }
        catch {
            $LastError = $_.Exception.Message
            # A server that rejects the request still follows the redirect first, so the failed response knows where it landed.
            $Landed = Get-FinalUri -Response $_.Exception.Response
            if ($Landed -and $Landed -ne $Url) { return $Landed }
        }
    }
    if ($Failure) { $Failure.Value = $LastError }
    return $null
}

# --- Borrow the real functions from the script under test ---

Write-Section 'Reading Windows-ISO-Updater.ps1'

$ParseErrors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$ParseErrors)
if ($ParseErrors -and $ParseErrors.Count -gt 0) {
    Add-Result -Area 'Script' -Status 'Fail' -Message "$($ParseErrors.Count) parse error(s) in the script itself." -Action 'Fix the parse errors before trusting anything else in this report.'
    foreach ($E in $ParseErrors) { Write-Detail "line $($E.Extent.StartLineNumber): $($E.Message)" }
    exit 1
}
Add-Result -Area 'Script' -Status 'Pass' -Message 'The script parses cleanly under Windows PowerShell 5.1 rules.'

# Reads a parameter's default straight out of the param block, so a pinned value is never duplicated here.
function Get-ScriptParameterDefault {
    param([Parameter(Mandatory)][string]$Name)

    $Parameter = $Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq $Name }
    if (-not $Parameter -or -not $Parameter.DefaultValue) { return $null }
    if ($Parameter.DefaultValue -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $Parameter.DefaultValue.Value
    }
    return $Parameter.DefaultValue.Extent.Text.Trim("'`"")
}

function Get-ScriptFunctionText {
    param([Parameter(Mandatory)][string]$Name)

    $Found = $Ast.FindAll({
            param($Node)
            $Node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Node.Name -eq $Name
        }, $true)
    if (-not $Found -or $Found.Count -eq 0) { return $null }
    return $Found[0].Extent.Text
}

$Borrowed = @(
    'Test-MicrosoftDownloadUrl',
    'Test-FidoUrl',
    'Test-FidoScript',
    'Search-UpdateCatalog',
    'Get-UpdateCatalogDownloadUrl',
    'Get-KbTargetBuilds'
)
$Missing = @($Borrowed | Where-Object { -not (Get-ScriptFunctionText -Name $_) })
if ($Missing.Count -gt 0) {
    Add-Result -Area 'Script' -Status 'Fail' -Message "The script no longer defines: $($Missing -join ', ')." -Action 'These functions were renamed or removed. Update the $Borrowed list in this tester to match.'
    exit 1
}

# Test-FidoScript and the catalog functions report through the main script's logger, so stand one in.
function Write-HostTimestamp {
    param(
        [string]$Message,
        [consolecolor]$ForegroundColor = 'Gray'
    )
    Write-Detail $Message
}
# Test-FidoScript honours this pin when it is set, and the script leaves it empty by default.
$FidoSha256 = ''

# The extract is nothing but function definitions, so materialising it defines them and runs no script logic.
$Extract = ($Borrowed | ForEach-Object { Get-ScriptFunctionText -Name $_ }) -join "`r`n`r`n"
. ([scriptblock]::Create($Extract))
Add-Result -Area 'Script' -Status 'Pass' -Message "Borrowed $($Borrowed.Count) validation and parsing functions from the script."

$OscdimgUrl = Get-ScriptParameterDefault -Name 'OscdimgUrl'
$OscdimgSha256 = Get-ScriptParameterDefault -Name 'OscdimgSha256'
$FidoUrl = Get-ScriptParameterDefault -Name 'FidoUrl'
$AdkSetupUrl = Get-ScriptParameterDefault -Name 'AdkSetupUrl'

$MctText = Get-ScriptFunctionText -Name 'Get-IsoViaMct'
$MctUrls = @([regex]::Matches($MctText, '(?i)https://go\.microsoft\.com/fwlink/\?link(?:id)?=\d+') |
        ForEach-Object { $_.Value } | Select-Object -Unique)

try { New-Item -ItemType Directory -Path $TempRoot -Force -ErrorAction Stop | Out-Null } catch { }

try {
    # --- oscdimg.exe on the Microsoft symbol server ---

    Write-Section 'oscdimg.exe (Microsoft symbol server)'

    if (-not $OscdimgUrl) {
        Add-Result -Area 'oscdimg' -Status 'Fail' -Message 'Could not read the -OscdimgUrl default out of the script.' -Action 'The parameter was renamed. Update this tester.'
    }
    elseif (-not (Test-MicrosoftDownloadUrl -Url $OscdimgUrl)) {
        Add-Result -Area 'oscdimg' -Status 'Fail' -Message "The pinned URL is not an official Microsoft HTTPS URL: $OscdimgUrl" -Action 'Point -OscdimgUrl back at msdl.microsoft.com. The script refuses to download it as it stands.'
    }
    else {
        Write-Detail $OscdimgUrl
        $OscdimgFile = Join-Path -Path $TempRoot -ChildPath 'oscdimg.exe'
        $Downloaded = $false
        try {
            # The symbol server only serves the binary to a symbol-client User-Agent, exactly as the script does.
            Invoke-WebRequest -Uri $OscdimgUrl -OutFile $OscdimgFile -UseBasicParsing -UserAgent 'Microsoft-Symbol-Server/10.0.0.0' -TimeoutSec $TimeoutSec -ErrorAction Stop
            $Downloaded = Test-Path -LiteralPath $OscdimgFile
        }
        catch {
            Add-Result -Area 'oscdimg' -Status 'Fail' -Message "The symbol server did not serve oscdimg.exe: $($_.Exception.Message)" -Action 'Re-index a current oscdimg.exe (see the linked write-up in the script header) and update the -OscdimgUrl and -OscdimgSha256 defaults. Until then the script needs -InstallAdk or an installed ADK.'
        }

        if ($Downloaded) {
            $IsExe = $false
            try {
                $Stream = [System.IO.File]::OpenRead($OscdimgFile)
                try {
                    $Header = New-Object byte[] 2
                    $IsExe = ($Stream.Read($Header, 0, 2) -eq 2 -and $Header[0] -eq 0x4D -and $Header[1] -eq 0x5A)
                }
                finally { $Stream.Dispose() }
            }
            catch { }

            if (-not $IsExe) {
                Add-Result -Area 'oscdimg' -Status 'Fail' -Message 'The symbol server answered with something that is not a Windows executable.' -Action 'The pinned build has been de-indexed. Re-index a current oscdimg.exe and update -OscdimgUrl and -OscdimgSha256.'
            }
            else {
                $Info = Get-Item -LiteralPath $OscdimgFile
                $Hash = (Get-FileHash -LiteralPath $OscdimgFile -Algorithm SHA256).Hash
                Write-Detail "$([math]::Round($Info.Length / 1KB)) KB, $($Info.VersionInfo.CompanyName), version $($Info.VersionInfo.FileVersion)"
                Write-Detail "SHA-256 $Hash"

                if (-not $OscdimgSha256) {
                    Add-Result -Area 'oscdimg' -Status 'Warn' -Message 'The script pins no SHA-256, so it falls back to checking the version resource only.' -Action "Set the -OscdimgSha256 default to $Hash once you have satisfied yourself the binary is genuine."
                }
                elseif ($Hash -eq $OscdimgSha256) {
                    Add-Result -Area 'oscdimg' -Status 'Pass' -Message 'The download matches the SHA-256 pinned in the script.'
                }
                else {
                    Add-Result -Area 'oscdimg' -Status 'Fail' -Message "Hash mismatch. Pinned $OscdimgSha256, served $Hash." -Action "Microsoft replaced the binary at that symbol index. Verify the new file (it should be a Microsoft-signed oscdimg with a sane version resource), then update the -OscdimgSha256 default to $Hash. Every run currently discards the download and needs the ADK instead."
                }

                if ($Info.VersionInfo.CompanyName -notmatch '(?i)Microsoft') {
                    Add-Result -Area 'oscdimg' -Status 'Warn' -Message "The version resource does not name Microsoft (CompanyName: '$($Info.VersionInfo.CompanyName)')." -Action 'Do not update the pinned hash. Investigate what the symbol server is serving.'
                }
            }
        }
    }

    # --- The Fido helper on GitHub ---

    Write-Section 'Fido helper (GitHub)'

    if (-not $FidoUrl) {
        Add-Result -Area 'Fido' -Status 'Fail' -Message 'Could not read the -FidoUrl default out of the script.' -Action 'The parameter was renamed. Update this tester.'
    }
    elseif (-not (Test-FidoUrl -Url $FidoUrl)) {
        Add-Result -Area 'Fido' -Status 'Fail' -Message "The pinned URL does not pass the script's own repository check: $FidoUrl" -Action 'Point -FidoUrl back at https://github.com/pbatard/Fido. The script refuses to download it as it stands.'
    }
    else {
        Write-Detail $FidoUrl
        $FidoFile = Join-Path -Path $TempRoot -ChildPath 'Fido.ps1'
        $GotFido = $false
        try {
            Invoke-WebRequest -Uri $FidoUrl -OutFile $FidoFile -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
            $GotFido = Test-Path -LiteralPath $FidoFile
        }
        catch {
            Add-Result -Area 'Fido' -Status 'Fail' -Message "Could not download Fido: $($_.Exception.Message)" -Action 'If the repository moved or the branch was renamed, update the -FidoUrl default. Until then -UseFido cannot work and the ISO has to be supplied with -IsoPath.'
        }

        if ($GotFido) {
            $FidoHash = (Get-FileHash -LiteralPath $FidoFile -Algorithm SHA256).Hash
            $FidoText = Get-Content -LiteralPath $FidoFile -Raw
            $FidoVersion = if ($FidoText -match '(?im)^#\s*Fido\s+v([\d.]+)') { $Matches[1] } else { 'unknown' }
            Write-Detail "Fido v$FidoVersion, $([math]::Round((Get-Item -LiteralPath $FidoFile).Length / 1KB)) KB"
            Write-Detail "SHA-256 $FidoHash"

            # This is the script's own gate, so a failure here is exactly what a real run would hit.
            if (Test-FidoScript -Path $FidoFile) {
                Add-Result -Area 'Fido' -Status 'Pass' -Message "Fido v$FidoVersion passes every check the script makes before running it."
                Write-Detail "Pin this build with -FidoSha256 $FidoHash"
            }
            else {
                Add-Result -Area 'Fido' -Status 'Fail' -Message 'The published Fido no longer passes the script''s pre-execution checks (the reason is in the detail lines above).' -Action 'Read the failing check in Test-FidoScript. If Fido legitimately started using something on the $Banned list, that list needs revisiting. Do not relax the checks without reading the diff.'
            }
        }
    }

    # --- Media Creation Tool fwlinks ---

    Write-Section 'Media Creation Tool (Microsoft fwlink)'

    if ($MctUrls.Count -eq 0) {
        Add-Result -Area 'MCT' -Status 'Fail' -Message 'No fwlink URLs were found in Get-IsoViaMct.' -Action 'The function was rewritten. Update this tester.'
    }
    foreach ($Url in $MctUrls) {
        Write-Detail $Url
        if (-not (Test-MicrosoftDownloadUrl -Url $Url)) {
            Add-Result -Area 'MCT' -Status 'Fail' -Message "Not an official Microsoft HTTPS URL: $Url" -Action 'The script refuses to download this. Restore the go.microsoft.com fwlink in Get-IsoViaMct.'
            continue
        }

        $Failure = $null
        $Final = Resolve-RedirectUrl -Url $Url -Failure ([ref]$Failure)
        if (-not $Final) {
            if ($Failure) {
                Add-Result -Area 'MCT' -Status 'Warn' -Message "Could not reach the fwlink: $Failure" -Action 'The request never completed, so this says nothing about the link itself. A retired fwlink still answers. Check for a proxy, a firewall or a rate limit, and run the check again.'
            }
            else {
                Add-Result -Area 'MCT' -Status 'Fail' -Message "The fwlink answered but pointed nowhere: $Url" -Action 'Microsoft retired this fwlink. Find the current Media Creation Tool link on the software-download page and update Get-IsoViaMct. -UseMct is broken until then.'
            }
            continue
        }
        Write-Detail "-> $Final"

        if (-not (Test-MicrosoftDownloadUrl -Url $Final)) {
            Add-Result -Area 'MCT' -Status 'Warn' -Message "The fwlink now lands off a Microsoft host: $Final" -Action 'Check where it goes before trusting it. Get-FileDownload follows the redirect at run time.'
        }
        elseif ($Final -notmatch '(?i)\.exe(\?|$)') {
            Add-Result -Area 'MCT' -Status 'Warn' -Message "The fwlink no longer lands on an .exe: $Final" -Action 'It may now point at the download page rather than the tool. Confirm the link in Get-IsoViaMct.'
        }
        else {
            Add-Result -Area 'MCT' -Status 'Pass' -Message "Resolves to $(Split-Path -Leaf ([Uri]$Final).AbsolutePath) on a Microsoft host."
        }

        if ($Deep) {
            $MctFile = Join-Path -Path $TempRoot -ChildPath ('mct_{0}.exe' -f ([Uri]$Url).Query.TrimStart('?').Replace('=', '_'))
            try {
                Invoke-WebRequest -Uri $Url -OutFile $MctFile -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
                $Signature = Get-AuthenticodeSignature -LiteralPath $MctFile -ErrorAction SilentlyContinue
                if ($Signature.Status -eq 'Valid' -and $Signature.SignerCertificate.Subject -match '(?i)O=Microsoft Corporation') {
                    Add-Result -Area 'MCT' -Status 'Pass' -Message 'The downloaded tool carries a valid Microsoft Authenticode signature.'
                }
                else {
                    Add-Result -Area 'MCT' -Status 'Fail' -Message "Signature check failed (status: $($Signature.Status))." -Action 'The script discards the download and -UseMct fails. Confirm the link is still Microsoft''s before changing anything.'
                }
            }
            catch {
                Add-Result -Area 'MCT' -Status 'Warn' -Message "Could not download the tool for a signature check: $($_.Exception.Message)"
            }
        }
    }

    # --- Windows ADK bootstrapper ---

    Write-Section 'Windows ADK bootstrapper (Microsoft fwlink)'

    if (-not $AdkSetupUrl) {
        Add-Result -Area 'ADK' -Status 'Fail' -Message 'Could not read the -AdkSetupUrl default out of the script.' -Action 'The parameter was renamed. Update this tester.'
    }
    else {
        Write-Detail $AdkSetupUrl
        $Failure = $null
        $Final = Resolve-RedirectUrl -Url $AdkSetupUrl -Failure ([ref]$Failure)
        if ($Failure) {
            Add-Result -Area 'ADK' -Status 'Warn' -Message "Could not reach the ADK fwlink: $Failure" -Action 'The request never completed, so this says nothing about the link itself. A retired fwlink still answers. Check for a proxy, a firewall or a rate limit, and run the check again.'
        }
        elseif (-not $Final) {
            Add-Result -Area 'ADK' -Status 'Fail' -Message 'The ADK fwlink answered but pointed nowhere.' -Action 'Microsoft rotates the ADK fwlink with each release. Take the current "Download the Windows ADK" link from Microsoft Learn and update the -AdkSetupUrl default. Only -InstallAdk is affected, the symbol-server oscdimg path still works.'
        }
        else {
            Write-Detail "-> $Final"
            if ($Final -match '(?i)adksetup\.exe') {
                Add-Result -Area 'ADK' -Status 'Pass' -Message 'Resolves to adksetup.exe on a Microsoft host.'
            }
            else {
                Add-Result -Area 'ADK' -Status 'Warn' -Message "Resolves to something other than adksetup.exe: $Final" -Action 'Confirm the fwlink still points at the ADK bootstrapper and not at a landing page.'
            }

            if ($Deep) {
                $AdkFile = Join-Path -Path $TempRoot -ChildPath 'adksetup.exe'
                try {
                    Invoke-WebRequest -Uri $AdkSetupUrl -OutFile $AdkFile -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
                    $Signature = Get-AuthenticodeSignature -LiteralPath $AdkFile -ErrorAction SilentlyContinue
                    if ($Signature.Status -eq 'Valid' -and $Signature.SignerCertificate.Subject -match '(?i)O=Microsoft Corporation') {
                        Add-Result -Area 'ADK' -Status 'Pass' -Message 'The downloaded bootstrapper carries a valid Microsoft Authenticode signature.'
                    }
                    else {
                        Add-Result -Area 'ADK' -Status 'Fail' -Message "Signature check failed (status: $($Signature.Status))." -Action 'The script refuses to run an unsigned bootstrapper, so -InstallAdk fails.'
                    }
                }
                catch {
                    Add-Result -Area 'ADK' -Status 'Warn' -Message "Could not download the bootstrapper for a signature check: $($_.Exception.Message)"
                }
            }
        }
    }

    # --- Microsoft Update Catalog (no API, so the HTML layout is the contract) ---

    Write-Section 'Microsoft Update Catalog (HTML scraping)'
    Write-Detail "query: $CatalogQuery"

    $CatalogResults = @(Search-UpdateCatalog -Query $CatalogQuery)
    if ($CatalogResults.Count -eq 0) {
        Add-Result -Area 'Catalog' -Status 'Fail' -Message 'The catalog search returned no parseable results.' -Action 'Either the catalog is unreachable, or its result markup changed and the "<GUID>_link" anchor regex in Search-UpdateCatalog no longer matches. Without this the script cannot find any update. Open the search URL in a browser and compare the HTML.'
    }
    else {
        Add-Result -Area 'Catalog' -Status 'Pass' -Message "The search page parsed into $($CatalogResults.Count) result(s)."

        $WithDate = @($CatalogResults | Where-Object { $_.LastUpdated })
        $WithSize = @($CatalogResults | Where-Object { $_.SizeMB })
        $WithClass = @($CatalogResults | Where-Object { $_.Classification })

        if ($WithDate.Count -eq 0) {
            Add-Result -Area 'Catalog' -Status 'Fail' -Message 'No result had a readable "Last Updated" date.' -Action 'The column ids moved. Search-UpdateCatalog reads C4 for the date, and the script picks the newest update by that value, so it currently cannot tell which package is current.'
        }
        if ($WithSize.Count -eq 0) {
            Add-Result -Area 'Catalog' -Status 'Warn' -Message 'No result had a readable size.' -Action 'Search-UpdateCatalog reads C6 for the size. Only the reported download size is affected, not the choice of package.'
        }
        if ($WithClass.Count -eq 0) {
            Add-Result -Area 'Catalog' -Status 'Warn' -Message 'No result had a readable classification.' -Action 'Search-UpdateCatalog reads C3 for the classification.'
        }
        if ($WithDate.Count -gt 0 -and $WithSize.Count -gt 0 -and $WithClass.Count -gt 0) {
            Add-Result -Area 'Catalog' -Status 'Pass' -Message 'Classification, date and size cells all still parse.'
        }

        $Newest = $CatalogResults |
            Where-Object { $_.LastUpdated -and $_.Title -notmatch '(?i)preview|dynamic|\.net' } |
            Sort-Object LastUpdated -Descending |
            Select-Object -First 1
        if (-not $Newest) { $Newest = $CatalogResults[0] }
        Write-Detail $Newest.Title
        Write-Detail "$($Newest.LastUpdated), $($Newest.SizeMB) MB, $($Newest.Guid)"

        $DownloadUrls = @(Get-UpdateCatalogDownloadUrl -Guid $Newest.Guid)
        if ($DownloadUrls.Count -eq 0) {
            Add-Result -Area 'Catalog' -Status 'Fail' -Message 'The download dialog returned no package URL.' -Action 'DownloadDialog.aspx changed its response, so the "downloadInformation[n].files[n].url" regex in Get-UpdateCatalogDownloadUrl no longer matches. The script can find updates but cannot download them.'
        }
        else {
            Write-Detail $DownloadUrls[0]
            $BadHost = @($DownloadUrls | Where-Object { -not (Test-MicrosoftDownloadUrl -Url $_) })
            if ($BadHost.Count -gt 0) {
                Add-Result -Area 'Catalog' -Status 'Fail' -Message "The catalog handed back $($BadHost.Count) URL(s) the script will not download from." -Action "Microsoft moved package hosting. Add the new host to Test-MicrosoftDownloadUrl only after confirming it is Microsoft-owned. First offender: $($BadHost[0])"
            }
            elseif (@($DownloadUrls | Where-Object { $_ -match '(?i)\.(msu|cab|exe)(\?|$)' }).Count -eq 0) {
                Add-Result -Area 'Catalog' -Status 'Warn' -Message 'None of the returned URLs look like a .msu or .cab package.' -Action 'Check what the catalog is serving for this update before trusting the download step.'
            }
            else {
                Add-Result -Area 'Catalog' -Status 'Pass' -Message "The download dialog resolved $($DownloadUrls.Count) package URL(s) on Microsoft hosts."
            }
        }

        # --- KB support page title, the bridge between a KB number and an OS build ---

        Write-Section 'KB support page (already-patched check)'

        if ($Newest.Title -match '(?i)\bKB(\d{6,7})\b') {
            $Kb = $Matches[1]
            Write-Detail "https://support.microsoft.com/help/$Kb"
            $Builds = Get-KbTargetBuilds -KbNumber $Kb
            if (-not $Builds -or $Builds.Count -eq 0) {
                Add-Result -Area 'KB page' -Status 'Warn' -Message "Could not read an OS build out of KB$Kb's page title." -Action 'Microsoft changed the support page title format that Get-KbTargetBuilds relies on. The already-patched check fails open, so builds still come out correct, they just always download and apply the update. Compare the <title> against the "(OS Builds 26100.4652 and 26200.4652)" pattern.'
            }
            else {
                $Rendered = ($Builds.Keys | Sort-Object | ForEach-Object { "$_.$($Builds[$_])" }) -join ', '
                Add-Result -Area 'KB page' -Status 'Pass' -Message "KB$Kb still publishes its target build(s) in the page title: $Rendered"
            }
        }
        else {
            Add-Result -Area 'KB page' -Status 'Warn' -Message 'The newest catalog result carries no KB number in its title, so the support page could not be checked.' -Action 'The script pulls the KB out of the catalog title the same way. If titles really stopped carrying "KBnnnnnnn", the already-patched check stops working.'
        }
    }

    # --- The batch file's self-download of the script ---

    Write-Section 'Batch file self-download (GitHub)'

    $BatPath = Join-Path -Path (Split-Path -Parent $ScriptPath) -ChildPath 'Run-Windows-ISO-Updater.bat'
    if (-not (Test-Path -LiteralPath $BatPath)) {
        Add-Result -Area 'Self-update' -Status 'Warn' -Message 'Run-Windows-ISO-Updater.bat was not found next to the script, so its download URL was not checked.'
    }
    else {
        $BatText = Get-Content -LiteralPath $BatPath -Raw
        $RawMatch = [regex]::Match($BatText, "(?i)(https://raw\.githubusercontent\.com/[^']+\.ps1)")
        if (-not $RawMatch.Success) {
            Add-Result -Area 'Self-update' -Status 'Warn' -Message 'No raw.githubusercontent.com URL was found in the batch file.'
        }
        else {
            Write-Detail $RawMatch.Groups[1].Value
            try {
                $Published = (Invoke-WebRequest -Uri $RawMatch.Groups[1].Value -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop).Content
                $RemoteErrors = $null
                [System.Management.Automation.Language.Parser]::ParseInput($Published, [ref]$null, [ref]$RemoteErrors) | Out-Null
                if ($RemoteErrors -and $RemoteErrors.Count -gt 0) {
                    Add-Result -Area 'Self-update' -Status 'Fail' -Message "The published script has $($RemoteErrors.Count) parse error(s)." -Action 'A broken script is being served to anyone who double-clicks the batch file without the .ps1 next to it. Push a fix.'
                }
                else {
                    $RemoteVersion = if ($Published -match "(?m)^\s*\`$ScriptVersion\s*=\s*'([\d.]+)'") { $Matches[1] } else { 'unknown' }
                    $LocalVersion = if ((Get-Content -LiteralPath $ScriptPath -Raw) -match "(?m)^\s*\`$ScriptVersion\s*=\s*'([\d.]+)'") { $Matches[1] } else { 'unknown' }
                    if ($RemoteVersion -eq $LocalVersion) {
                        Add-Result -Area 'Self-update' -Status 'Pass' -Message "The published script parses and matches this working copy (version $LocalVersion)."
                    }
                    else {
                        Add-Result -Area 'Self-update' -Status 'Warn' -Message "The published script is version $RemoteVersion, this working copy is $LocalVersion." -Action 'Expected while you have unpushed work. Push when you are done, so the batch file hands out the current script.'
                    }
                }
            }
            catch {
                Add-Result -Area 'Self-update' -Status 'Fail' -Message "Could not fetch the published script: $($_.Exception.Message)" -Action 'The batch file cannot self-heal a missing .ps1 until this URL works again. Check the repository name, branch and visibility.'
            }
        }
    }
}
finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- Summary ---

$All = $Results.ToArray()
$Failed = @($All | Where-Object { $_.Status -eq 'Fail' })
$Warned = @($All | Where-Object { $_.Status -eq 'Warn' })

Write-Host ''
Write-Host ('-' * 78) -ForegroundColor DarkGray
Write-Host 'Dependency check summary' -ForegroundColor Cyan
$All | Group-Object Area | ForEach-Object {
    $Worst = if (@($_.Group | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0) { 'Fail' }
    elseif (@($_.Group | Where-Object { $_.Status -eq 'Warn' }).Count -gt 0) { 'Warn' }
    else { 'Pass' }
    $Color = switch ($Worst) { 'Pass' { 'Green' } 'Warn' { 'Yellow' } default { 'Red' } }
    Write-Host ('  {0,-12} {1}' -f $_.Name, $Worst) -ForegroundColor $Color
}

$Actions = @($All | Where-Object { $_.Action })
if ($Actions.Count -eq 0) {
    Write-Host ''
    Write-Host 'Nothing in Windows-ISO-Updater.ps1 needs updating.' -ForegroundColor Green
}
else {
    Write-Host ''
    Write-Host 'What needs updating in Windows-ISO-Updater.ps1' -ForegroundColor Cyan
    foreach ($Item in $Actions) {
        $Color = if ($Item.Status -eq 'Fail') { 'Red' } else { 'Yellow' }
        Write-Host "  $($Item.Area): $($Item.Message)" -ForegroundColor $Color
        Write-Host "    $($Item.Action)" -ForegroundColor Gray
    }
}

Write-Host ''
Write-Host ("$($Failed.Count) failure(s), $($Warned.Count) warning(s), $($All.Count) check(s) total.") -ForegroundColor DarkGray

if ($Failed.Count -gt 0) { exit 1 }
if ($Warned.Count -gt 0) { exit 2 }
exit 0
