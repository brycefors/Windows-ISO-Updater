# Sync Embedded Driver Scripts
# Version: 0000.00.00.0

<#
.SYNOPSIS
    Keeps the three payloads embedded in Examples\autounattend-ultimate.xml in sync with their real
    source files under tools\.

.DESCRIPTION
    Examples\autounattend-ultimate.xml embeds verbatim, XML-escaped copies of tools\Install-DellDrivers.ps1,
    tools\Install-SurfaceDrivers.ps1, and tools\Install-VMwareTools.ps1 inside three <File> elements, so
    the answer file's ExtractScript step can write them to disk during Windows specialize without
    reaching back into this repository. Those copies are hand-kept-in-sync today, so an edit to any
    source file is easy to forget to mirror into the XML.

    This script finds each tracked <File path="..."> ... </File> block by exact tag text (not by loading
    the XML into a DOM, which would re-serialize and disturb formatting elsewhere in the file),
    XML-escapes the current source file content the same way the payload already is, and compares the
    two. Out-of-sync blocks are rewritten in place, and every other line in the XML file is left untouched.

    Nothing in Examples\autounattend-ultimate.xml is ever executed. The rewritten payloads are only
    parsed, with [System.Management.Automation.Language.Parser]::ParseInput(), to confirm they are still
    valid PowerShell.

.PARAMETER RepositoryPath
    Repository to work on. Defaults to the repository this script lives in.

.PARAMETER WhatIfOnly
    Report which payloads are in sync or out of sync without writing anything.

.PARAMETER Quiet
    Suppress per-file detail output. The final summary line is always printed.

.EXAMPLE
    .\tools\Sync-EmbeddedDriverScripts.ps1 -WhatIfOnly
    Reports whether the Dell, Surface, and VMware Tools payloads currently match their source files.

.EXAMPLE
    .\tools\Sync-EmbeddedDriverScripts.ps1
    Rewrites whichever of the three payloads are out of sync, then validates the XML and all rewritten
    payloads still parse.
#>
[CmdletBinding()]
param(
    [Parameter(HelpMessage = 'Repository to work on. Defaults to the repository this script lives in')]
    [string]$RepositoryPath,

    [Parameter(HelpMessage = 'Report which payloads are in sync or out of sync without writing anything')]
    [switch]$WhatIfOnly,

    [Parameter(HelpMessage = 'Suppress per-file detail output. The final summary line is always printed')]
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# Each entry maps a source .ps1 to the exact <File> tag pair that embeds it in the answer file.
$Payloads = @(
    [pscustomobject]@{
        Name       = 'Dell'
        SourcePath = 'tools\Install-DellDrivers.ps1'
        OpenTag    = '<File path="C:\Windows\Setup\Scripts\Install-DellDrivers.ps1">'
        CloseTag   = '</File>'
    },
    [pscustomobject]@{
        Name       = 'Surface'
        SourcePath = 'tools\Install-SurfaceDrivers.ps1'
        OpenTag    = '<File path="C:\Windows\Setup\Scripts\Install-SurfaceDrivers.ps1">'
        CloseTag   = '</File>'
    },
    [pscustomobject]@{
        Name       = 'VMware Tools'
        SourcePath = 'tools\Install-VMwareTools.ps1'
        OpenTag    = '<File path="C:\Windows\Setup\Scripts\VMwareTools.ps1">'
        CloseTag   = '</File>'
    }
)

$XmlRelativePath = 'Examples\autounattend-ultimate.xml'

function Write-Info {
    param([string]$Message, [string]$Color = 'Gray')
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}

# Reads a text file without disturbing its encoding, matching the pattern in tools\Update-Version.ps1.
function Get-FileText {
    param([Parameter(Mandatory)][string]$Path)
    $Bytes = [System.IO.File]::ReadAllBytes($Path)
    $HasBom = ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
    return [pscustomobject]@{
        Text   = [System.IO.File]::ReadAllText($Path)
        HasBom = $HasBom
    }
}

function Set-FileText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [bool]$HasBom
    )
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($HasBom)))
}

# Element-content escaping only, so quotes are left alone since these payloads are never attribute values.
function ConvertTo-XmlEscapedText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $Escaped = $Text -replace '&', '&amp;'
    $Escaped = $Escaped -replace '<', '&lt;'
    $Escaped = $Escaped -replace '>', '&gt;'
    return $Escaped
}

# --- Locate the repository ---
if (-not $RepositoryPath) { $RepositoryPath = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $RepositoryPath)) { throw "The repository path '$RepositoryPath' does not exist." }
$RepositoryPath = (Resolve-Path -LiteralPath $RepositoryPath).Path

$XmlPath = Join-Path -Path $RepositoryPath -ChildPath $XmlRelativePath
if (-not (Test-Path -LiteralPath $XmlPath)) { throw "'$XmlRelativePath' was not found under '$RepositoryPath'. Point -RepositoryPath at the repository root." }

$XmlFile = Get-FileText -Path $XmlPath
$XmlText = $XmlFile.Text

# --- Work out what each payload should contain, and whether it already does ---
$Plans = foreach ($Payload in $Payloads) {
    $SourcePath = Join-Path -Path $RepositoryPath -ChildPath $Payload.SourcePath
    if (-not (Test-Path -LiteralPath $SourcePath)) { throw "'$($Payload.SourcePath)' was not found. Restore it before running this script." }

    $OpenIndex = $XmlText.IndexOf($Payload.OpenTag)
    if ($OpenIndex -lt 0) { throw "Could not find the opening tag '$($Payload.OpenTag)' in '$XmlRelativePath'. The answer file's markup may have changed and this script's tag text needs updating." }
    $ContentStart = $OpenIndex + $Payload.OpenTag.Length
    $CloseIndex = $XmlText.IndexOf($Payload.CloseTag, $ContentStart)
    if ($CloseIndex -lt 0) { throw "Could not find the closing tag '$($Payload.CloseTag)' after the '$($Payload.Name)' payload in '$XmlRelativePath'." }

    $CurrentInner = $XmlText.Substring($ContentStart, $CloseIndex - $ContentStart)
    $SourceText = (Get-FileText -Path $SourcePath).Text
    $NewInner = ConvertTo-XmlEscapedText -Text $SourceText

    [pscustomobject]@{
        Name          = $Payload.Name
        ContentStart  = $ContentStart
        ContentEnd    = $CloseIndex
        CurrentInner  = $CurrentInner
        NewInner      = $NewInner
        SourceText    = $SourceText
        InSync        = ($CurrentInner.Trim() -eq $NewInner.Trim())
    }
}

# --- Report or apply, working back to front so earlier offsets stay valid after a replace ---
$OutOfSync = @($Plans | Where-Object { -not $_.InSync })

if ($WhatIfOnly) {
    foreach ($Plan in $Plans) {
        if ($Plan.InSync) { Write-Info "  $($Plan.Name): in sync." 'DarkGray' }
        else { Write-Info "  $($Plan.Name): out of sync, would update." 'Yellow' }
    }
    Write-Host "Sync-EmbeddedDriverScripts: $($OutOfSync.Count) of $($Plans.Count) payload(s) would be updated."
    exit 0
}

foreach ($Plan in $Plans) {
    if ($Plan.InSync) {
        Write-Info "  $($Plan.Name): unchanged." 'DarkGray'
        continue
    }
    Write-Info "  $($Plan.Name): updating." 'Green'
}

if ($OutOfSync.Count -gt 0) {
    # Replace furthest-from-start first so an earlier replacement never shifts a later block's offsets.
    $Ordered = $OutOfSync | Sort-Object -Property ContentStart -Descending
    foreach ($Plan in $Ordered) {
        $XmlText = $XmlText.Substring(0, $Plan.ContentStart) + $Plan.NewInner + $XmlText.Substring($Plan.ContentEnd)
    }
    Set-FileText -Path $XmlPath -Text $XmlText -HasBom $XmlFile.HasBom
}

# --- Validate, never execute ---
try {
    $ParsedXml = New-Object System.Xml.XmlDocument
    $ParsedXml.LoadXml($XmlText)
}
catch {
    throw "The rewritten '$XmlRelativePath' no longer parses as XML: $($_.Exception.Message)"
}

$ParseErrors = @()
foreach ($Plan in $OutOfSync) {
    $Errors = $null
    # $Plan.NewInner is XML-escaped text, not PowerShell. Parse the real unescaped source instead.
    [System.Management.Automation.Language.Parser]::ParseInput($Plan.SourceText, [ref]$null, [ref]$Errors) | Out-Null
    if ($Errors) {
        foreach ($ParseError in $Errors) {
            $ParseErrors += "$($Plan.Name): $($ParseError.Message)"
        }
    }
}

if ($ParseErrors.Count -gt 0) {
    $ParseErrors | ForEach-Object { Write-Warning $_ }
    throw "The updated payload(s) failed to parse as PowerShell. See the warnings above and fix the source file(s) before running this script again."
}

Write-Host "Sync-EmbeddedDriverScripts: $($OutOfSync.Count) of $($Plans.Count) payload(s) updated."
exit 0
