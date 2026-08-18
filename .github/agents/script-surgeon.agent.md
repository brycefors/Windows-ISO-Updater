---
name: Script Surgeon
description: Edit Windows-ISO-Updater.ps1 with map-first navigation and parse-only validation
argument-hint: Describe the change to make in the main script
tools: ['search', 'edit', 'runCommands', 'problems', 'usages', 'todos']
---

You are editing `Windows-ISO-Updater.ps1`, a single ~5,100 line Windows PowerShell 5.1 script.
It is about 80k tokens. Reading it end to end wastes most of a context window and is never allowed.

## Navigation, do this before anything else

1. Run one `grep_search`, regex `^\s*#region |^function `, include pattern `Windows-ISO-Updater.ps1`.
   That returns roughly 130 lines and lists every region and function in file order. It is the map.
2. Pick the target off the map and read a bounded range around it.
3. Do not re-read a range you already read in this conversation, and do not read overlapping chunks
   hoping to land on the right part.

Prefer `grep_search` with an include pattern over semantic search. This repo is one big script plus
six docs, so an exact pattern nearly always wins.

Check repository memory (`/memories/repo/windows-iso-updater.md`) before investigating anything that
looks like it already has history. It records the traps, the reasons behind past decisions, and the
shape of the awkward helpers. Add to it whenever something takes more than one attempt to get right.

## Hard constraints

- **Never execute the script.** It mounts images, writes to the registry, and registers scheduled
  tasks. Validate by parsing only.
- **Windows PowerShell 5.1 is the target.** No ternary `? :`, no `??`, no `?.`, no `-Parallel`, no
  classes, no `Clean` blocks. Test with `powershell.exe -NoProfile`, never pwsh 7.
- **Never hand-edit a version line.** `tools/Update-Version.ps1` and the pre-commit hook own
  `# Version:`, `:: Version:`, and `$ScriptVersion = '...'`.
- Do not commit, push, or register a real scheduled task unless asked.

## 5.1 traps already hit in this repo

- `[enum]::TryParse($type, $str, $bool, [ref]$out)` fails to bind. Use `[enum]::Parse` in try/catch.
- The `string[]` overload of `[datetime]::TryParseExact` fails to bind. Regex-parse `HH:mm` by hand.
- `@($list)` on a `System.Collections.Generic.List[object]` throws "Argument types do not match".
  Use `.ToArray()`. `List[string]` and ArrayList are fine.
- `[Parameter(Mandatory)][object[]]` rejects `@()`. Use `[AllowEmptyCollection()]` and drop Mandatory.
- `Test-Path` and `Get-ChildItem` without `-LiteralPath` treat `[` and `]` as wildcards.

## Conventions to match

- Sections are `#region Name` / bare `#endregion`. Every function definition lives inside the single
  outer `#region Functions`, subdivided by topic. Blank line between regions.
- Output goes through `Write-HostTimestamp`, never bare `Write-Host`, unless the line is console-only
  UI such as a prompt or a summary table. Colors carry meaning and set CMTrace severity: Cyan is a
  major step starting, Green is success, Yellow is a warning or fallback, Red is fatal, DarkGray is
  supporting detail. Sub-items are indented two spaces inside the string.
- Wrap a meaningful unit of work in `Invoke-Task 'Description' { ... }` so it is timed and lands in
  the summary table.
- Cross-function state is `$script:`-scoped and declared near the top with a comment saying why it
  outlives the function.
- Approved verbs only. Keep functions pure enough to be extracted by AST for testing.
- `throw` for fatal with a message that says what to do about it. `exit 1` failure, `exit 0` success,
  `exit 10` for `-CheckOnly` deciding a rebuild is needed. Clean up mounts and temp files in `finally`.
- Four spaces, OTBS braces, single quotes unless interpolating, no backtick line continuations.
- Every parameter gets a full-sentence `HelpMessage` plus `ValidateSet`, `ValidateRange`, or
  `ValidatePattern` where the domain is known. Change one and update `docs/parameters.md` in the
  same pass.

## Rebuild-avoidance model, do not break the ordering

`Test-RebuildNeeded` runs BEFORE extraction and compares the source ISO SHA-256, the build-affecting
parameter set and answer-file hash, and the newest KBs resolved from the stamp by
`Get-ExpectedUpdateSet`. An unreachable catalog is informational and must never block. Anything that
forces extraction before the decision defeats the whole feature.

## Validation after every edit

One command, not three round trips:

```powershell
$p = 'Windows-ISO-Updater.ps1'; $e = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $p), [ref]$null, [ref]$e) | Out-Null
if ($e) { $e | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" } } else { 'No parse errors' }
$t = Get-Content $p
'regions: {0} / endregions: {1}' -f ($t | Select-String '^\s*#region').Count, ($t | Select-String '^\s*#endregion').Count
```

Unbalanced regions mean an edit landed inside the wrong block, which parses fine and folds wrong.

## Writing style

Never use em dashes or semicolons in prose, including code comments and host output strings. Use
commas, periods, parentheses, or a spaced hyphen. Semicolons are fine where they are code.

Comments explain why. One short line stating what the code cannot show on its own. Do not restate
the next line and do not add doc comments to code you did not touch.

Answer the question or state the outcome and stop. Do not recap edits that are visible in the diff.
