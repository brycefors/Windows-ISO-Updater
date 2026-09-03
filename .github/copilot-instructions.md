# Copilot instructions for Windows-ISO-Updater

## What this repo is

A single-purpose Windows automation repo. `Windows-ISO-Updater.ps1` downloads a Windows 10 or 11 ISO,
services the images inside it offline with DISM (LCU, .NET, Setup Dynamic Update, optional WinRE), and
recompiles a bootable ISO with `oscdimg.exe`. `Run-Windows-ISO-Updater.bat` is the double-click entry
point, `docs/` is the manual, `Examples/` holds four answer files, `tools/Update-Version.ps1` stamps
versions from a git hook, `tools/Sync-EmbeddedDriverScripts.ps1` re-mirrors the driver payloads into
`Examples/autounattend-ultimate.xml`, and `tools/Test-Dependencies.ps1` checks that the external things
the script pins (oscdimg hash, Fido, the MCT and ADK fwlinks, the Update Catalog HTML) are still valid.

There is no build, no test suite, and no package manifest. The script is the product.

## Finding your way around, read this before searching

`Windows-ISO-Updater.ps1` is around 5,100 lines, roughly 80k tokens. Never read it end to end, and do not
read overlapping chunks hoping to land on the right part.

Start with the one search that returns the whole map:

- `grep_search`, regex `^\s*#region |^function `, include pattern `Windows-ISO-Updater.ps1`

That is about 130 lines and costs roughly 1k tokens, and it lists every region and every function in file
order. Pick the target off that map, then read a bounded range around it. One map plus one targeted read
beats five exploratory searches and is 60 times cheaper than reading the whole file.

Also worth doing:

- Check repository memory first. It already records the traps, the reasons behind past decisions, and the
  shape of the awkward helpers. Add to it whenever something takes more than one attempt to get right.
- Prefer `grep_search` with an include pattern over semantic search. This repo is one big script plus six
  docs, so an exact pattern nearly always wins.
- Do not re-read a region you have already read in this conversation.

## Writing style, applies to everything

**Never use em dashes or semicolons in prose.** This covers documentation, code comments, commit
messages, host output strings, and anything written in chat. Use commas, periods, parentheses, or a
spaced hyphen instead. Rewrite the sentence rather than swapping in one substitute character, so a
paired em dash usually becomes parentheses and a semicolon usually becomes "so", "and", "while", or a
full stop.

Semicolons are fine where they are code, not prose. Leave statement separators, hashtable literals such
as `@{ Description = $Description; Duration = $Elapsed }`, HTML and XML entities, and quoted code
samples inside comments exactly as they are.

Comments explain *why*. Write one short line stating what the code cannot show on its own. Do not
restate the next line, do not narrate the change for a reviewer, and do not add doc comments to code you
did not touch.

The same economy applies to chat replies. Answer the question or state the outcome and stop. Do not recap
edits that are already visible in the diff, do not restate the plan back, and do not list every test that
passed. Explaining a decision earns its words only when the choice was not obvious, for example a tradeoff
taken, a trap avoided, or a root cause worth remembering.

## Hard constraints

- **Windows PowerShell 5.1 is the target.** No ternary `? :`, no `??`, no `?.`, no `-Parallel`, no
  classes, no `Clean` blocks. Test edits with `powershell.exe -NoProfile`, not pwsh 7.
- **5.1 traps already hit in this repo.**
  - `[enum]::TryParse($type, $str, $bool, [ref]$out)` fails to bind. Use `[enum]::Parse` in try/catch.
  - The `string[]` overload of `[datetime]::TryParseExact` fails to bind. Regex-parse `HH:mm` by hand.
  - `@($list)` on a `System.Collections.Generic.List[object]` throws "Argument types do not match".
    Use `.ToArray()`. `List[string]` and ArrayList are fine.
  - `[Parameter(Mandatory)][object[]]` rejects `@()`. Use `[AllowEmptyCollection()]` and drop Mandatory.
  - `Test-Path` and `Get-ChildItem` without `-LiteralPath` treat `[` and `]` as wildcards, so a path
    containing brackets silently matches nothing.
- **`Register-ScheduledTask -Trigger` rejects client-only monthly CIM triggers** with 0x80070057 no
  matter which properties are set. Monthly schedules must register a placeholder weekly trigger, then
  `Export-ScheduledTask`, swap `<ScheduleByWeek>` for `<ScheduleByMonth>` or
  `<ScheduleByMonthDayOfWeek>`, and re-register with `-Xml`. Daily and weekly CIM triggers are fine.
- **Never execute the main script or the answer-file payloads to validate them.** They mount images,
  write to the registry, and register scheduled tasks. Parse instead:
  `[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)`.
  For the XML, load with `[xml]` and run each `//e:File` and `//e:ExtractScript` node through
  `Parser::ParseInput` under the namespace `https://schneegans.de/windows/unattend-generator/`.
- **Never hand-edit a version line.** `tools/Update-Version.ps1` owns `# Version:`, `:: Version:`, and
  `$ScriptVersion = '...'`, and the `.git/hooks/pre-commit` hook re-stamps and re-stages them on every
  commit. Versions are CalVer, `yyyy.MM.dd.<rev>`.
- Do not commit, push, or register a real scheduled task without being asked.

## Script conventions

**Layout.** Sections are wrapped in `#region Section Name` / `#endregion` so they fold in VS Code. Order
is header comment, `param()`, elevation and platform guards, folder resolution, transcript start, helper
functions, then the main flow. Every function definition lives inside the single outer `#region Functions`,
which is subdivided by topic (downloads, catalog, stamps, mount recovery, servicing and so on), so the
whole ~2,600 lines of helpers collapse to one line and leave the main flow readable. Close a region with a
bare `#endregion`, and put a blank line between one region and the next.

**Parameters.** Every parameter gets a `HelpMessage` written as a full sentence, plus `ValidateSet`,
`ValidateRange`, or `ValidatePattern` where the domain is known. Defaults are inline.

```powershell
[Parameter(HelpMessage = 'Windows version to download/update: 10 or 11. Defaults to 11')]
[ValidateSet('10', '11')]
[string]$WindowsVersion = '11',
```

**Output.** Use `Write-HostTimestamp`, never bare `Write-Host`, so the line lands in the transcript with
a `[MM/dd/yyyy|HH:mm:ss]` prefix. Colors carry meaning and should stay consistent.

| Color | Meaning |
| --- | --- |
| Cyan | A major step is starting |
| Green | Success or a verified result |
| Yellow | Warning or a fallback being taken |
| Red | Fatal error |
| DarkGray | Supporting detail, timings, catalog results |

Sub-items are indented two spaces inside the string itself. Durations go through `Format-Duration`.

**Steps.** Wrap any meaningful unit of work in `Invoke-Task`. It prints the description, times the block
in a `finally`, and appends to `$script:StepTimings` for the summary table at the end.

```powershell
Invoke-Task 'Mounting the install image' {
    # work
}
```

**State.** Cross-function state is `$script:`-scoped and declared near the top with a comment explaining
why it outlives the function. Everything else is PascalCase local scope.

**Functions.** Approved verbs only. Keep them pure enough to be extractable by AST for testing, which is
how this repo tests things.

**Errors.** `throw` for anything fatal, with a message that says what to do about it. `exit 1` for
failure, `exit 0` for success, and `exit 10` specifically for `-CheckOnly` deciding a rebuild is needed.
Clean up mounts and temp files in `finally` blocks, and `Stop-Transcript | Out-Null` before exiting.

**Formatting.** Four spaces, OTBS braces, single quotes unless interpolating, no backtick line
continuations.

## Rebuild-avoidance model

`Stamps\last-build.json` plus `Stamps\History\` record what the last build was made from. `Test-RebuildNeeded`
runs *before* extraction and compares the source ISO SHA-256, the build-affecting parameter set and
answer-file hash, and the newest KBs from the Microsoft Update Catalog, which `Get-ExpectedUpdateSet`
resolves from the stamp so nothing has to be mounted. A catalog that cannot be reached is informational
and must not block. `-AutoClean` deletes only files a stamp recorded.

Keep that ordering. Anything that forces extraction before the decision defeats the whole feature.

## Testing approach

Extract the functions under test from the AST into a temp script, stub the external calls, run it with
`powershell.exe -NoProfile`, then delete the temp file. When testing scheduled-task code,
`Import-Module ScheduledTasks` *before* defining stubs, otherwise module auto-loading shadows them and
the real cmdlets run. The same applies to `Import-Module Dism` before stubbing `Mount-WindowsImage` or
`Get-WindowsImage`.

Write the harness with the create-file tool, never as a here-string inside a terminal command. A
here-string sent through the terminal is truncated at its first line and the command then runs twice.

Validate an edit with one command instead of three round trips:

```powershell
$p = 'Windows-ISO-Updater.ps1'; $e = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $p), [ref]$null, [ref]$e) | Out-Null
if ($e) { $e | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" } } else { 'No parse errors' }
$t = Get-Content $p
'regions: {0} / endregions: {1}' -f ($t | Select-String '^\s*#region').Count, ($t | Select-String '^\s*#endregion').Count
```

Unbalanced regions mean an edit landed inside the wrong block, which parses fine and folds wrong.

## Answer files in `Examples/`

All four are hand-edited. The lab-admin, gold-image, and ultimate files started as schneegans.de
generator output and their header comments list every manual change, so regenerating from the embedded
URL discards them.

- `autounattend-lab-admin.xml` is the deployment file. It branches on hardware using `$isVirtualMachine`
  from SMBIOS and is authoritative for BitLocker policy.
- `autounattend-gold-image.xml` builds a reference image and must stay hardware-neutral, because
  `specialize` runs once on the reference machine and is baked into the capture.
- `autounattend-ultimate.xml` derives from the lab-admin file and adds driver installation dispatched by
  manufacturer. It stops short of full OOBE bypass on purpose, so an Autopilot device still checks in.
  It embeds verbatim copies of the three `tools/Install-*.ps1` scripts, which go stale the moment a
  source script is edited.
- `autounattend-driver-install.xml` is minimal and only installs model-matched packages from
  `C:\Drivers\` during `specialize`.
- Policy is to encrypt physical machines and not VMs, since encrypted guests defeat SAN block dedup.
  The gold image sets `PreventDeviceEncryption=1` as a build-only setting and `SEAL-THIS-IMAGE.txt`
  step 5 deletes it before sysprep.
- Payload scripts live in `<Extensions>/<File path=...>` and are unpacked by `ExtractScript` during
  `specialize`. `autounattend-gold-image.xml` uses tab indentation in places, so match it exactly when
  editing.

## Documentation

`README.md` is the front door and stays skimmable. Detail lives in `docs/`. Open the one file that owns
the subject rather than reading the folder to work out where something goes.

| File | Owns |
| --- | --- |
| `usage.md` | How to run it, worked examples, scenario walkthroughs |
| `parameters.md` | The parameter tables. Change one and update its `HelpMessage` in the same pass |
| `reference.md` | Flow diagram, folder layout, logging, disk space, the build record written onto the ISO |
| `scheduled-runs.md` | Task registration, build stamps, rebuild decisions, `-AutoClean` |
| `design-notes.md` | Why something works the way it does, tradeoffs taken, alternatives rejected |
| `unattended-installs.md` | The `Examples/` answer files and how to use them |

Each doc ends with a `[← Back to README](../README.md)` link, paths and parameters are in backticks, and
parameter listings are tables. Do not create new markdown files to describe changes you just made.

Commit messages are a single imperative sentence, for example "Add logging for Microsoft Update Catalog
query results".
