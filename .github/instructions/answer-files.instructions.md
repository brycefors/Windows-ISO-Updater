---
description: Semantics and editing rules for the autounattend answer files in Examples/
applyTo: 'Examples/**/*.xml'
---

# Answer files in `Examples/`

These are fed to the script via `-UnattendPath`. All four are hand-edited. The lab-admin, gold-image, and
ultimate files started as schneegans.de generator output and their header comments list every manual
change, so regenerating from the embedded URL discards them and is never the fix.

- `autounattend-lab-admin.xml` is the deployment file. It branches on hardware using `$isVirtualMachine`
  from SMBIOS and is authoritative for BitLocker policy.
- `autounattend-gold-image.xml` builds a reference image and must stay hardware-neutral, because
  `specialize` runs once on the reference machine and is baked into the capture.
- `autounattend-ultimate.xml` derives from the lab-admin file and adds driver installation dispatched by
  manufacturer. It stops short of full OOBE bypass on purpose, so an Autopilot device still checks in.
  It embeds verbatim copies of the three `tools/Install-*.ps1` scripts, which go stale the moment a
  source script is edited. Re-mirror with `tools/Sync-EmbeddedDriverScripts.ps1`.
- `autounattend-driver-install.xml` is minimal and only installs model-matched packages from
  `C:\Drivers\` during `specialize`.

## Rules

- **Add any new manual change to the header comment** in the same edit, so the list stays complete.
- Policy is to encrypt physical machines and not VMs, since encrypted guests defeat SAN block dedup.
  The gold image sets `PreventDeviceEncryption=1` as a build-only setting and `SEAL-THIS-IMAGE.txt`
  step 5 deletes it before sysprep.
- Payload scripts live in `<Extensions>/<File path=...>` and are unpacked by `ExtractScript` during
  `specialize`. `autounattend-gold-image.xml` uses tab indentation in places, so match it exactly when
  editing.
- These files apply `/IMAGE/INDEX 1`, which works because `Select-DefaultEditions` returns indexes
  highest-first so the top edition is renumbered to index 1 on re-export. Do not change the index
  without checking that still holds.

## Validate, parse only

Never execute a payload script to check it. Validate only the files you edited, and never widen `$targets`
to the whole folder, since parsing an untouched file proves nothing about your change.

```powershell
$ErrorActionPreference = 'Stop'
$ns = 'https://schneegans.de/windows/unattend-generator/'
$targets = @('Examples\autounattend-lab-admin.xml')   # list only the files you edited
foreach ($f in $targets) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.Load((Resolve-Path -LiteralPath $f))
    $mgr = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $mgr.AddNamespace('e', $ns)
    $bad = 0
    foreach ($node in $doc.SelectNodes('//e:File | //e:ExtractScript', $mgr)) {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseInput($node.InnerText, [ref]$null, [ref]$errs) | Out-Null
        if ($errs) { $bad++; $errs | ForEach-Object { "  $f : $($_.Message)" } }
    }
    "{0}: XML ok, {1} payload error(s)" -f $f, $bad
}
```

XML that fails to load and payloads that fail to parse are both blocking.
