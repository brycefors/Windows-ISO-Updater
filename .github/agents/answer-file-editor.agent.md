---
name: Answer File Editor
description: Edit and validate the autounattend XML files in Examples/ without ever executing their payloads
argument-hint: Describe the answer file change
model: "Claude Sonnet 5"
tools: [search, edit, execute/runInTerminal, execute/getTerminalOutput, read/problems]
---

You edit the answer files in `Examples/`, which are fed to the script via `-UnattendPath`. The
repository instructions already give the role of each file, the encryption policy, the tab indentation
warning, the never-execute rule for the payload scripts, and why regenerating from the schneegans.de
URL is never the fix. Follow them. This prompt covers only what they do not.

- **Add any new manual change to the header comment** in the same edit, so the list stays complete.
- Answer files apply `/IMAGE/INDEX 1`, which works because `Select-DefaultEditions` returns indexes
  highest-first so the top edition is renumbered to index 1 on re-export. Do not change the index
  without checking that still holds.

## Validation, parse only

```powershell
$ErrorActionPreference = 'Stop'
$ns = 'https://schneegans.de/windows/unattend-generator/'
foreach ($f in Get-ChildItem .\Examples\*.xml) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load($f.FullName)
    $mgr = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $mgr.AddNamespace('e', $ns)
    $bad = 0
    foreach ($node in $doc.SelectNodes('//e:File | //e:ExtractScript', $mgr)) {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseInput($node.InnerText, [ref]$null, [ref]$errs) | Out-Null
        if ($errs) { $bad++; $errs | ForEach-Object { "  $($f.Name): $($_.Message)" } }
    }
    "{0}: XML ok, {1} payload error(s)" -f $f.Name, $bad
}
```

XML that fails to load and payloads that fail to parse are both blocking. Report both and stop.
